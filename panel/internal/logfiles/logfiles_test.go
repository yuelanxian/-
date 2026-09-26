package logfiles

import (
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCleanPath(t *testing.T) {
	good := []string{"homevault/hv-2026-09-26.log", "backup/backup-20260926-033000.log", "nextcloud/nextcloud.log",
		"nextcloud/nextcloud.log.1", "caddy/access-2026-09-25T03-00-00.000.log.gz", "containers/app-2026-09-25.log",
		"panel/panel.log", "top.log", "notes.txt", "x.gz", "a/b/c/d/e.log"}
	for _, p := range good {
		if _, err := CleanPath(p); err != nil {
			t.Errorf("CleanPath(%q) unexpected error %v", p, err)
		}
	}
	bad := []string{"", "../etc/passwd", "../../etc/shadow.log", "a/../../x.log", "a/../x.log", "/etc/x.log",
		"a\\..\\x.log", "a//b.log", "./a.log", "a/./b.log", ".hidden.log", "a/.git/x.log", "x.conf", "x.log.sh",
		"a/b/c/d/e/f.log", "x.log\x00.txt", "secrets/postgres_password", "x.log/", strings.Repeat("a", 600) + ".log",
		"x.log.12345"}
	for _, p := range bad {
		if _, err := CleanPath(p); !errors.Is(err, ErrInvalidPath) {
			t.Errorf("CleanPath(%q) = %v, want ErrInvalidPath", p, err)
		}
	}
}

func setup(t *testing.T) (string, string) {
	t.Helper()
	base := t.TempDir()
	root := filepath.Join(base, "logs")
	must(t, os.MkdirAll(filepath.Join(root, "homevault"), 0o755))
	must(t, os.MkdirAll(filepath.Join(root, "caddy"), 0o755))
	outside := filepath.Join(base, "secret.log")
	must(t, os.WriteFile(outside, []byte("TOP SECRET\n"), 0o644))
	var b strings.Builder
	for i := 1; i <= 1000; i++ {
		fmt.Fprintf(&b, "line %d level=%s\n", i, map[bool]string{true: "error", false: "info"}[i%100 == 0])
	}
	must(t, os.WriteFile(filepath.Join(root, "homevault", "hv-2026-09-26.log"), []byte(b.String()), 0o644))
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	_, _ = zw.Write([]byte(b.String()))
	must(t, zw.Close())
	must(t, os.WriteFile(filepath.Join(root, "caddy", "access.log.gz"), gz.Bytes(), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "caddy", "config.json"), []byte("{}"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, ".hidden.log"), []byte("x"), 0o644))
	// symlinks: one escaping the root, one inside
	must(t, os.Symlink(outside, filepath.Join(root, "escape.log")))
	must(t, os.Symlink(filepath.Join(root, "homevault", "hv-2026-09-26.log"), filepath.Join(root, "inside.log")))
	must(t, os.Symlink(base, filepath.Join(root, "dirlink")))
	return root, outside
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestListSkipsNonLogsHiddenAndSymlinks(t *testing.T) {
	root, _ := setup(t)
	d := &Dir{Root: root}
	list, err := d.List()
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, e := range list {
		paths = append(paths, e.Path)
	}
	got := strings.Join(paths, ",")
	if len(list) != 2 || !strings.Contains(got, "homevault/hv-2026-09-26.log") || !strings.Contains(got, "caddy/access.log.gz") {
		t.Fatalf("unexpected list: %s", got)
	}
}

func TestOpenRejectsTraversalAndSymlinks(t *testing.T) {
	root, _ := setup(t)
	d := &Dir{Root: root}
	for _, p := range []string{"escape.log", "inside.log", "dirlink/secret.log", "../secret.log"} {
		f, _, err := d.Open(p)
		if err == nil {
			f.Close()
			t.Errorf("Open(%q) succeeded, want error", p)
		}
	}
	f, fi, err := d.Open("homevault/hv-2026-09-26.log")
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if fi.Size() == 0 {
		t.Fatal("empty file")
	}
}

func TestTailPlain(t *testing.T) {
	root, _ := setup(t)
	d := &Dir{Root: root}
	r, err := d.Tail("homevault/hv-2026-09-26.log", 5, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Lines) != 5 || r.Lines[0] != "line 996 level=info" || r.Lines[4] != "line 1000 level=error" || !r.Truncated {
		t.Fatalf("tail = %#v truncated=%v", r.Lines, r.Truncated)
	}
	r, err = d.Tail("homevault/hv-2026-09-26.log", 5000, "")
	if err != nil || len(r.Lines) != 1000 || r.Truncated || r.Lines[0] != "line 1 level=info" {
		t.Fatalf("full tail: n=%d truncated=%v err=%v", len(r.Lines), r.Truncated, err)
	}
}

func TestTailFilterAndGzip(t *testing.T) {
	root, _ := setup(t)
	d := &Dir{Root: root, MaxGzipInput: 1 << 20}
	for _, p := range []string{"homevault/hv-2026-09-26.log", "caddy/access.log.gz"} {
		r, err := d.Tail(p, 3, "LEVEL=ERROR")
		if err != nil {
			t.Fatal(p, err)
		}
		want := []string{"line 800 level=error", "line 900 level=error", "line 1000 level=error"}
		if strings.Join(r.Lines, "|") != strings.Join(want, "|") {
			t.Fatalf("%s: got %q", p, r.Lines)
		}
	}
	r, err := d.Tail("caddy/access.log.gz", 2, "")
	if err != nil || len(r.Lines) != 2 || r.Lines[1] != "line 1000 level=error" {
		t.Fatalf("gz tail: %q %v", r.Lines, err)
	}
	small := &Dir{Root: root, MaxGzipInput: 10}
	if _, err := small.Tail("caddy/access.log.gz", 2, ""); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("want ErrTooLarge, got %v", err)
	}
}

func TestLongLinesAndInvalidUTF8(t *testing.T) {
	root := t.TempDir()
	long := strings.Repeat("x", maxLineBytes*3)
	content := "first\n" + long + "\n\xff\xfebad\nlast"
	must(t, os.WriteFile(filepath.Join(root, "a.log"), []byte(content), 0o644))
	d := &Dir{Root: root}
	for _, q := range []string{"", "a"} {
		r, err := d.Tail("a.log", 10, q)
		if err != nil {
			t.Fatal(err)
		}
		for _, l := range r.Lines {
			if len(l) > maxLineBytes {
				t.Fatalf("line too long: %d", len(l))
			}
		}
		if q == "" && (len(r.Lines) != 4 || r.Lines[3] != "last" || !strings.Contains(r.Lines[2], "�")) {
			t.Fatalf("unexpected lines: %d %q", len(r.Lines), r.Lines[2])
		}
	}
}

func TestScanLastRing(t *testing.T) {
	var b strings.Builder
	for i := 0; i < 10; i++ {
		fmt.Fprintf(&b, "%d\n", i)
	}
	got, err := scanLast(strings.NewReader(b.String()), 3, "")
	if err != nil || strings.Join(got, ",") != "7,8,9" {
		t.Fatalf("got %v %v", got, err)
	}
}
