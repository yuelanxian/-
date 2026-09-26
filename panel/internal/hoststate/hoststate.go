// Package hoststate reads the status files the host writes into state/ and writes
// request files (state/requests/<时间>-<type>.json) for the host runner.
package hoststate

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Request types the host runner executes (allow-list shared with hv / hv.ps1).
const (
	TypeBackup       = "backup"
	TypeLogClean     = "log-clean"
	TypeLogRetention = "log-retention"
)

var allowedTypes = map[string]bool{TypeBackup: true, TypeLogClean: true, TypeLogRetention: true}

var (
	// ErrType is returned for request types outside the allow-list.
	ErrType = errors.New("hoststate: request type not allowed")
	// ErrDays is returned for an invalid retention value.
	ErrDays = errors.New("hoststate: days must be an integer between 1 and 365")
	// ErrTooManyPending is returned when the host runner is not keeping up.
	ErrTooManyPending = errors.New("hoststate: too many pending requests")
)

const (
	maxStateFile   = 4 << 20
	maxPending     = 20
	requestsDir    = "requests"
	doneDir        = "done"
	requestPerm    = 0o640
	requestDirPerm = 0o750
)

// ---------------------------------------------------------------- flexible time

// FlexTime accepts RFC 3339 strings, "YYYY-MM-DD HH:MM:SS", unix seconds/milliseconds and null.
type FlexTime struct{ time.Time }

// UnmarshalJSON implements json.Unmarshaler.
func (t *FlexTime) UnmarshalJSON(b []byte) error {
	t.Time = time.Time{}
	s := strings.TrimSpace(string(b))
	if s == "null" || s == `""` || s == "" || s == "0" {
		return nil
	}
	if s[0] != '"' {
		f, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return nil
		}
		t.Time = fromUnix(f)
		return nil
	}
	var str string
	if err := json.Unmarshal(b, &str); err != nil {
		return nil
	}
	t.Time = ParseTime(str)
	return nil
}

// MarshalJSON writes RFC 3339 or null.
func (t FlexTime) MarshalJSON() ([]byte, error) {
	if t.IsZero() {
		return []byte("null"), nil
	}
	return json.Marshal(t.Time.Format(time.RFC3339))
}

// ParseTime parses the time formats host scripts may produce (zero on failure).
func ParseTime(s string) time.Time {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}
	}
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02T15:04:05.9999999Z07:00", "2006-01-02 15:04:05Z07:00",
		"2006-01-02T15:04:05", "2006-01-02 15:04:05", "20060102-150405"} {
		if tt, err := time.ParseInLocation(layout, s, time.Local); err == nil {
			return tt
		}
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil && f > 0 {
		return fromUnix(f)
	}
	return time.Time{}
}

func fromUnix(f float64) time.Time {
	if f <= 0 {
		return time.Time{}
	}
	if f > 1e12 { // milliseconds
		return time.UnixMilli(int64(f))
	}
	return time.Unix(int64(f), 0)
}

// ---------------------------------------------------------------- store

// Store reads/writes below the state directory.
type Store struct {
	Dir string
	Now func() time.Time
	mu  sync.Mutex
}

// New returns a store for dir.
func New(dir string) *Store { return &Store{Dir: dir, Now: time.Now} }

// ReadJSON decodes state/<name> into out. It returns os.ErrNotExist when missing.
func (s *Store) ReadJSON(name string, out any) (time.Time, error) {
	if strings.ContainsAny(name, `/\`) || strings.HasPrefix(name, ".") {
		return time.Time{}, errors.New("hoststate: invalid name")
	}
	b, mtime, err := s.readFile(name)
	if err != nil {
		return time.Time{}, err
	}
	b = bytes.TrimPrefix(b, []byte("\xef\xbb\xbf")) // PowerShell may write a BOM
	if err := json.Unmarshal(b, out); err != nil {
		return mtime, fmt.Errorf("hoststate: %s: %w", name, err)
	}
	return mtime, nil
}

// ReadText returns the trimmed content of a small text file in state/.
func (s *Store) ReadText(name string) (string, time.Time, error) {
	b, mtime, err := s.readFile(name)
	if err != nil {
		return "", time.Time{}, err
	}
	b = bytes.TrimPrefix(b, []byte("\xef\xbb\xbf"))
	return strings.TrimSpace(string(b)), mtime, nil
}

func (s *Store) readFile(name string) ([]byte, time.Time, error) {
	root, err := os.OpenRoot(s.Dir)
	if err != nil {
		return nil, time.Time{}, err
	}
	defer root.Close()
	f, err := root.Open(name)
	if err != nil {
		return nil, time.Time{}, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, time.Time{}, err
	}
	if !fi.Mode().IsRegular() {
		return nil, time.Time{}, errors.New("hoststate: not a regular file")
	}
	b, err := io.ReadAll(io.LimitReader(f, maxStateFile+1))
	if err != nil {
		return nil, time.Time{}, err
	}
	if len(b) > maxStateFile {
		return nil, time.Time{}, errors.New("hoststate: file too large")
	}
	return b, fi.ModTime(), nil
}

// OpenFile opens a regular file below state/ (e.g. app/homevault.apk) for serving.
func (s *Store) OpenFile(rel string) (*os.File, os.FileInfo, error) {
	root, err := os.OpenRoot(s.Dir)
	if err != nil {
		return nil, nil, err
	}
	defer root.Close()
	f, err := root.Open(rel)
	if err != nil {
		return nil, nil, err
	}
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		f.Close()
		return nil, nil, os.ErrNotExist
	}
	return f, fi, nil
}

// ---------------------------------------------------------------- requests

// Request is the JSON written to state/requests/<id>.json.
type Request struct {
	ID          string    `json:"id"`
	Type        string    `json:"type"`
	Days        int       `json:"days,omitempty"`
	Created     time.Time `json:"created"`
	RequestedBy string    `json:"requested_by"`
	ClientIP    string    `json:"client_ip,omitempty"`
	Source      string    `json:"source"`
}

// RequestStatus is a request as seen by the panel (pending or finished).
type RequestStatus struct {
	ID          string    `json:"id"`
	Type        string    `json:"type"`
	Days        int       `json:"days,omitempty"`
	State       string    `json:"state"` // pending | running | ok | failed | rejected | unknown
	Created     *FlexTime `json:"created,omitempty"`
	Finished    *FlexTime `json:"finished,omitempty"`
	Message     string    `json:"message,omitempty"`
	RequestedBy string    `json:"requested_by,omitempty"`
}

// ValidDays validates a retention value.
func ValidDays(d int) error {
	if d < 1 || d > 365 {
		return ErrDays
	}
	return nil
}

// Submit writes a request atomically (temp file + rename, mode 0640).
// For backup and log-clean an identical pending request is reused instead of duplicated.
func (s *Store) Submit(typ string, days int, user, ip string) (*Request, bool, error) {
	if !allowedTypes[typ] {
		return nil, false, ErrType
	}
	if typ == TypeLogRetention {
		if err := ValidDays(days); err != nil {
			return nil, false, err
		}
	} else {
		days = 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	dir := filepath.Join(s.Dir, requestsDir)
	if err := os.MkdirAll(dir, requestDirPerm); err != nil {
		return nil, false, err
	}
	pending, _ := s.pendingLocked()
	if len(pending) >= maxPending {
		return nil, false, ErrTooManyPending
	}
	if typ != TypeLogRetention {
		// Reuse a waiting request of the same type, or one the host is executing right now
		// (moved to done/ without a result yet): a second backup would only repeat the first.
		running, _ := readRequestDir(filepath.Join(dir, doneDir), false, s.Now())
		for _, p := range append(pending, running...) {
			if p.Type == typ && (p.State == "pending" || p.State == "running") {
				r := &Request{ID: p.ID, Type: p.Type, RequestedBy: p.RequestedBy, Source: "panel"}
				if p.Created != nil {
					r.Created = p.Created.Time
				}
				return r, true, nil
			}
		}
	}
	now := s.Now().UTC()
	var id, final string
	for i := 0; ; i++ {
		ts := now.Add(time.Duration(i) * time.Millisecond)
		id = fmt.Sprintf("%s%03dZ-%s", ts.Format("20060102T150405"), ts.Nanosecond()/1e6, typ)
		final = filepath.Join(dir, id+".json")
		if _, err := os.Lstat(final); errors.Is(err, os.ErrNotExist) {
			if _, err := os.Lstat(filepath.Join(dir, doneDir, id+".json")); errors.Is(err, os.ErrNotExist) {
				break
			}
		}
		if i > 1000 {
			return nil, false, errors.New("hoststate: cannot allocate request id")
		}
	}
	req := &Request{ID: id, Type: typ, Days: days, Created: now, RequestedBy: user, ClientIP: ip, Source: "panel"}
	b, err := json.MarshalIndent(req, "", "  ")
	if err != nil {
		return nil, false, err
	}
	b = append(b, '\n')
	if err := writeAtomic(dir, id+".json", b); err != nil {
		return nil, false, err
	}
	return req, false, nil
}

func writeAtomic(dir, name string, data []byte) error {
	tmp, err := os.OpenFile(filepath.Join(dir, ".tmp-"+name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, requestPerm)
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	ok := false
	defer func() {
		if !ok {
			tmp.Close()
			os.Remove(tmpName)
		}
	}()
	if _, err := tmp.Write(data); err != nil {
		return err
	}
	// Best effort: some bind-mount filesystems (Docker Desktop file sharing) may reject fsync;
	// a lost request file only means the user presses the button again.
	_ = tmp.Sync()
	if err := tmp.Close(); err != nil {
		return err
	}
	_ = os.Chmod(tmpName, requestPerm) // enforce 0640 regardless of umask
	if err := os.Rename(tmpName, filepath.Join(dir, name)); err != nil {
		return err
	}
	ok = true
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
}

func (s *Store) pendingLocked() ([]RequestStatus, error) {
	return readRequestDir(filepath.Join(s.Dir, requestsDir), true, s.Now())
}

// Requests returns pending requests and the most recent finished ones (newest first).
func (s *Store) Requests(doneLimit int) (pending, done []RequestStatus) {
	s.mu.Lock()
	pending, _ = s.pendingLocked()
	s.mu.Unlock()
	if doneLimit <= 0 {
		return pending, nil
	}
	done, _ = readRequestDir(filepath.Join(s.Dir, requestsDir, doneDir), false, s.Now())
	if len(done) > doneLimit {
		done = done[:doneLimit]
	}
	return pending, done
}

// resultSuffix marks a result file written by the host runner next to the moved request:
// done/<id>.json (the original request) + done/<id>.result.json ({"ok":bool,"finished","message"}).
const resultSuffix = ".result.json"

// A request moved to done/ without any result for this long is reported as "unknown".
const staleRunning = 6 * time.Hour

type rawRequest struct {
	ID          string          `json:"id"`
	Request     string          `json:"request"`
	Type        string          `json:"type"`
	Days        any             `json:"days"`
	Created     *FlexTime       `json:"created"`
	Finished    *FlexTime       `json:"finished"`
	FinishedAt  *FlexTime       `json:"finished_at"`
	OK          json.RawMessage `json:"ok"`
	Status      string          `json:"status"`
	Result      string          `json:"result"`
	State       string          `json:"state"`
	Message     string          `json:"message"`
	Error       string          `json:"error"`
	RequestedBy string          `json:"requested_by"`
}

func (r *rawRequest) outcome() string {
	switch strings.Trim(strings.TrimSpace(string(r.OK)), `"`) {
	case "true", "1":
		return "ok"
	case "false", "0":
		return "failed"
	}
	for _, v := range []string{r.Status, r.Result, r.State} {
		if v != "" {
			return normState(v)
		}
	}
	return ""
}

func readRequestDir(dir string, pendingDir bool, now time.Time) ([]RequestStatus, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	type pair struct {
		req, res string
		mtime    time.Time // of the request file (fallback when it has no "created")
	}
	byKey := map[string]*pair{}
	for _, e := range ents {
		n := e.Name()
		if !e.Type().IsRegular() || !strings.HasSuffix(n, ".json") || strings.HasPrefix(n, ".") {
			continue
		}
		key, isResult := strings.TrimSuffix(n, ".json"), false
		if strings.HasSuffix(n, resultSuffix) {
			if pendingDir {
				continue
			}
			key, isResult = strings.TrimSuffix(n, resultSuffix), true
		}
		p := byKey[key]
		if p == nil {
			p = &pair{}
			byKey[key] = p
		}
		if isResult {
			p.res = n
		} else {
			p.req = n
			if fi, err := e.Info(); err == nil {
				p.mtime = fi.ModTime()
			}
		}
	}
	keys := make([]string, 0, len(byKey))
	for k := range byKey {
		keys = append(keys, k)
	}
	sort.Sort(sort.Reverse(sort.StringSlice(keys)))
	if len(keys) > 200 {
		keys = keys[:200]
	}
	var out []RequestStatus
	for _, k := range keys {
		p := byKey[k]
		var req, res rawRequest
		haveReq, haveRes := false, false
		if p.req != "" {
			haveReq = decodeRequestFile(filepath.Join(dir, p.req), &req)
		}
		if p.res != "" {
			haveRes = decodeRequestFile(filepath.Join(dir, p.res), &res)
		}
		if !haveReq && !haveRes {
			continue
		}
		rs := RequestStatus{ID: firstNonEmpty(req.ID, res.ID, req.Request, strings.TrimSuffix(res.Request, ".json"), k),
			Type: firstNonEmpty(req.Type, res.Type), Created: req.Created, RequestedBy: req.RequestedBy}
		if rs.Type == "unknown" {
			rs.Type = ""
		}
		switch v := req.Days.(type) {
		case float64:
			rs.Days = int(v)
		case string:
			rs.Days, _ = strconv.Atoi(v)
		}
		// Outcome: result file first, then status fields written into the request file itself.
		state := ""
		if haveRes {
			state = res.outcome()
			rs.Finished = firstFlex(res.Finished, res.FinishedAt)
			rs.Message = firstNonEmpty(res.Message, res.Error)
			if state == "" {
				state = "ok"
			}
		}
		if state == "" && haveReq {
			state = req.outcome()
			rs.Finished = firstFlex(req.Finished, req.FinishedAt)
			rs.Message = firstNonEmpty(req.Message, req.Error)
		}
		switch {
		case pendingDir:
			state = "pending"
		case state == "":
			// Moved to done/ but no result yet: the host is executing it (or crashed doing so).
			state = "running"
			started := p.mtime
			if rs.Created != nil && !rs.Created.IsZero() {
				started = rs.Created.Time
			}
			if !started.IsZero() && now.Sub(started) > staleRunning {
				state = "unknown"
			}
		}
		rs.State = state
		out = append(out, rs)
	}
	return out, nil
}

func decodeRequestFile(p string, out *rawRequest) bool {
	b, err := readSmall(p)
	if err != nil {
		return false
	}
	return json.Unmarshal(bytes.TrimPrefix(b, []byte("\xef\xbb\xbf")), out) == nil
}

func firstNonEmpty(ss ...string) string {
	for _, s := range ss {
		if s != "" {
			return s
		}
	}
	return ""
}

func firstFlex(ts ...*FlexTime) *FlexTime {
	for _, t := range ts {
		if t != nil && !t.IsZero() {
			return t
		}
	}
	return nil
}

func normState(s string) string {
	switch strings.ToLower(s) {
	case "ok", "success", "succeeded", "done":
		return "ok"
	case "pending", "queued":
		return "pending"
	case "running":
		return "running"
	case "rejected", "denied":
		return "rejected"
	default:
		return "failed"
	}
}

func readSmall(p string) ([]byte, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, 64<<10))
}
