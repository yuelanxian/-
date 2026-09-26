// Package logfiles lists and reads log files under a single root directory
// (path-traversal safe via os.Root, regular files only, size limits, gzip support).
package logfiles

import (
	"bytes"
	"compress/gzip"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	// ErrInvalidPath is returned for paths that are not allowed (traversal, bad extension...).
	ErrInvalidPath = errors.New("logfiles: invalid path")
	// ErrNotRegular is returned for symlinks, directories and devices.
	ErrNotRegular = errors.New("logfiles: not a regular file")
	// ErrTooLarge is returned when a compressed file exceeds the configured limit.
	ErrTooLarge = errors.New("logfiles: file too large")
)

// allowed file names: *.log, *.txt, optionally followed by .N and/or .gz; also *.gz
var nameRe = regexp.MustCompile(`(?i)^[^/\x00]+\.(log|txt)(\.[0-9]{1,4})?(\.gz)?$|^[^/\x00]+\.gz$`)

const (
	maxDepth      = 4
	maxEntries    = 5000
	maxLineBytes  = 16 << 10
	tailScanLimit = 32 << 20  // bytes scanned backwards for a plain tail
	grepScanLimit = 256 << 20 // bytes scanned forwards when filtering
	gzOutputLimit = 1 << 30   // decompressed bytes processed for .gz files
)

// Dir gives read-only access to log files under Root.
type Dir struct {
	Root          string
	MaxGzipInput  int64 // max compressed size of a .gz file that may be read
	GzOutputLimit int64
}

// Entry describes one log file.
type Entry struct {
	Path    string    `json:"path"` // slash-separated, relative to Root
	Dir     string    `json:"dir"`
	Name    string    `json:"name"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"mtime"`
	Gzip    bool      `json:"gzip"`
}

// CleanPath validates a user supplied relative path and returns its clean form.
func CleanPath(p string) (string, error) {
	if p == "" || len(p) > 512 || strings.ContainsAny(p, "\\\x00") || !utf8.ValidString(p) {
		return "", ErrInvalidPath
	}
	if strings.HasPrefix(p, "/") {
		return "", ErrInvalidPath
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == ".." || seg == "." || seg == "" || strings.HasPrefix(seg, ".") {
			return "", ErrInvalidPath
		}
	}
	c := path.Clean(p)
	if c != p || !fs.ValidPath(c) {
		return "", ErrInvalidPath
	}
	if strings.Count(c, "/") > maxDepth {
		return "", ErrInvalidPath
	}
	if !nameRe.MatchString(path.Base(c)) {
		return "", ErrInvalidPath
	}
	return c, nil
}

// List returns all allowed log files, newest first.
func (d *Dir) List() ([]Entry, error) {
	root, err := os.OpenRoot(d.Root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	var out []Entry
	err = fs.WalkDir(root.FS(), ".", func(p string, de fs.DirEntry, err error) error {
		if err != nil {
			if p == "." {
				return err
			}
			return nil // unreadable subdirectory: skip
		}
		if p == "." {
			return nil
		}
		if strings.HasPrefix(de.Name(), ".") {
			if de.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if de.IsDir() {
			if strings.Count(p, "/") >= maxDepth {
				return fs.SkipDir
			}
			return nil
		}
		if !de.Type().IsRegular() || !nameRe.MatchString(de.Name()) {
			return nil
		}
		info, ierr := de.Info()
		if ierr != nil {
			return nil
		}
		dir := path.Dir(p)
		if dir == "." {
			dir = ""
		}
		out = append(out, Entry{Path: p, Dir: dir, Name: de.Name(), Size: info.Size(), ModTime: info.ModTime(),
			Gzip: strings.HasSuffix(strings.ToLower(de.Name()), ".gz")})
		if len(out) >= maxEntries {
			return fs.SkipAll
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].ModTime.Equal(out[j].ModTime) {
			return out[i].ModTime.After(out[j].ModTime)
		}
		return out[i].Path < out[j].Path
	})
	return out, nil
}

// Open opens a validated log file for reading. The caller must close it.
func (d *Dir) Open(rel string) (*os.File, fs.FileInfo, error) {
	c, err := CleanPath(rel)
	if err != nil {
		return nil, nil, err
	}
	root, err := os.OpenRoot(d.Root)
	if err != nil {
		return nil, nil, err
	}
	defer root.Close()
	li, err := root.Lstat(c)
	if err != nil {
		return nil, nil, err
	}
	if !li.Mode().IsRegular() {
		return nil, nil, ErrNotRegular
	}
	f, err := root.Open(c)
	if err != nil {
		return nil, nil, err
	}
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() || !os.SameFile(li, fi) {
		f.Close()
		return nil, nil, ErrNotRegular
	}
	return f, fi, nil
}

// TailResult is the output of Tail.
type TailResult struct {
	Path      string    `json:"path"`
	Size      int64     `json:"size"`
	ModTime   time.Time `json:"mtime"`
	Lines     []string  `json:"lines"`
	Truncated bool      `json:"truncated"` // older content exists that was not scanned/returned
	Query     string    `json:"query,omitempty"`
}

// Tail returns the last n lines of a log file, optionally only lines containing query
// (case-insensitive). Gzip files are decompressed on the fly.
func (d *Dir) Tail(rel string, n int, query string) (*TailResult, error) {
	f, fi, err := d.Open(rel)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if n < 1 {
		n = 1
	}
	res := &TailResult{Path: rel, Size: fi.Size(), ModTime: fi.ModTime(), Query: query}
	isGz := strings.HasSuffix(strings.ToLower(rel), ".gz")
	switch {
	case isGz:
		if d.MaxGzipInput > 0 && fi.Size() > d.MaxGzipInput {
			return nil, ErrTooLarge
		}
		zr, err := gzip.NewReader(f)
		if err != nil {
			return nil, err
		}
		defer zr.Close()
		limit := d.GzOutputLimit
		if limit <= 0 {
			limit = gzOutputLimit
		}
		lr := &io.LimitedReader{R: zr, N: limit}
		res.Lines, err = scanLast(lr, n, query)
		if lr.N <= 0 {
			res.Truncated = true
		}
		if err != nil && !errors.Is(err, gzip.ErrChecksum) {
			return nil, err
		}
	case query != "":
		start := int64(0)
		if fi.Size() > grepScanLimit {
			start = fi.Size() - grepScanLimit
			res.Truncated = true
		}
		sr := io.NewSectionReader(f, start, fi.Size()-start)
		lines, err := scanLast(sr, n, query)
		if err != nil {
			return nil, err
		}
		res.Lines = lines
	default:
		lines, more, err := tailPlain(f, fi.Size(), n)
		if err != nil {
			return nil, err
		}
		res.Lines, res.Truncated = lines, more
	}
	if res.Lines == nil {
		res.Lines = []string{}
	}
	return res, nil
}

// tailPlain reads backwards from the end until n lines were found.
func tailPlain(f io.ReaderAt, size int64, n int) ([]string, bool, error) {
	const chunk = 64 << 10
	var chunks [][]byte
	pos := size
	newlines := 0
	for pos > 0 && newlines <= n && size-pos < tailScanLimit {
		sz := int64(chunk)
		if pos < sz {
			sz = pos
		}
		pos -= sz
		b := make([]byte, sz)
		if _, err := f.ReadAt(b, pos); err != nil && !errors.Is(err, io.EOF) {
			return nil, false, err
		}
		newlines += bytes.Count(b, []byte{'\n'})
		chunks = append(chunks, b)
	}
	var buf bytes.Buffer
	for i := len(chunks) - 1; i >= 0; i-- {
		buf.Write(chunks[i])
	}
	data := buf.Bytes()
	if pos > 0 { // drop the partial first line
		if i := bytes.IndexByte(data, '\n'); i >= 0 {
			data = data[i+1:]
		} else {
			data = nil
		}
	}
	data = bytes.TrimSuffix(data, []byte{'\n'})
	if len(data) == 0 {
		return []string{}, pos > 0, nil
	}
	parts := bytes.Split(data, []byte{'\n'})
	more := pos > 0
	if len(parts) > n {
		parts = parts[len(parts)-n:]
		more = true
	}
	out := make([]string, len(parts))
	for i, p := range parts {
		out[i] = cleanLine(p)
	}
	return out, more, nil
}

// scanLast streams r and keeps the last n (matching) lines in a ring buffer.
func scanLast(r io.Reader, n int, query string) ([]string, error) {
	q := []byte(strings.ToLower(query))
	ring := make([]string, n)
	count := 0
	err := forEachLine(r, func(line []byte) {
		if len(q) > 0 && !bytes.Contains(bytes.ToLower(line), q) {
			return
		}
		ring[count%n] = cleanLine(line)
		count++
	})
	if count <= n {
		return ring[:count], err
	}
	out := make([]string, 0, n)
	start := count % n
	out = append(out, ring[start:]...)
	out = append(out, ring[:start]...)
	return out, err
}

// forEachLine calls fn for each line (without the newline); overlong lines are truncated.
func forEachLine(r io.Reader, fn func([]byte)) error {
	buf := make([]byte, 64<<10)
	var line []byte
	overflow := false
	for {
		k, err := r.Read(buf)
		data := buf[:k]
		for len(data) > 0 {
			i := bytes.IndexByte(data, '\n')
			if i < 0 {
				if !overflow {
					line = append(line, data...)
					if len(line) > maxLineBytes {
						line, overflow = line[:maxLineBytes], true
					}
				}
				break
			}
			if !overflow {
				line = append(line, data[:i]...)
				if len(line) > maxLineBytes {
					line = line[:maxLineBytes]
				}
			}
			fn(line)
			line, overflow = line[:0], false
			data = data[i+1:]
		}
		if err != nil {
			if len(line) > 0 {
				fn(line)
			}
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
	}
}

func cleanLine(b []byte) string {
	b = bytes.TrimSuffix(b, []byte{'\r'})
	if len(b) > maxLineBytes {
		b = b[:maxLineBytes]
	}
	s := string(b)
	if !utf8.ValidString(s) {
		s = strings.ToValidUTF8(s, "\uFFFD")
	}
	return s
}
