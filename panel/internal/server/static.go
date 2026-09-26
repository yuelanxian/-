package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"mime"
	"net/http"
	"path"
	"strings"
	"time"

	"homevault/panel/web"
)

type staticFile struct {
	data  []byte
	ctype string
	etag  string
}

// staticFiles serves the embedded frontend with strong ETags.
type staticFiles struct {
	files map[string]staticFile
}

var extTypes = map[string]string{
	".html":        "text/html; charset=utf-8",
	".js":          "text/javascript; charset=utf-8",
	".css":         "text/css; charset=utf-8",
	".png":         "image/png",
	".svg":         "image/svg+xml",
	".webmanifest": "application/manifest+json",
	".json":        "application/json",
	".txt":         "text/plain; charset=utf-8",
}

func newStaticFiles(version string) (*staticFiles, error) {
	sf := &staticFiles{files: map[string]staticFile{}}
	err := fs.WalkDir(web.FS, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.HasSuffix(p, ".go") {
			return err
		}
		b, err := fs.ReadFile(web.FS, p)
		if err != nil {
			return err
		}
		ext := path.Ext(p)
		ct := extTypes[ext]
		if ct == "" {
			ct = mime.TypeByExtension(ext)
		}
		if ct == "" {
			ct = "application/octet-stream"
		}
		if p == "index.html" {
			b = bytes.ReplaceAll(b, []byte("{{VERSION}}"), []byte(version))
		}
		sum := sha256.Sum256(b)
		sf.files["/"+p] = staticFile{data: b, ctype: ct, etag: `"` + hex.EncodeToString(sum[:12]) + `"`}
		return nil
	})
	return sf, err
}

func (sf *staticFiles) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	if p == "/" || p == "/index.html" {
		p = "/index.html"
	}
	f, ok := sf.files[p]
	if !ok {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte("404 页面不存在\n"))
		return
	}
	h := w.Header()
	h.Set("Content-Type", f.ctype)
	h.Set("ETag", f.etag)
	h.Set("Cache-Control", "no-cache")
	http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(f.data))
}
