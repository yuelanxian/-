package audit

import (
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	os.Exit(m.Run())
}

func TestLogAndDailyRotation(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "panel", "panel.log")
	now := time.Date(2026, 9, 25, 23, 59, 0, 0, time.Local)
	l := New(p)
	l.Now = func() time.Time { return now }
	l.Log("login", true, "hvadmin", "10.99.77.2", "line1\nINJECTED {\"action\":\"fake\"}")
	l.Close()
	// make the file look like it was written yesterday, then log "today"
	yesterday := now
	if err := os.Chtimes(p, yesterday, yesterday); err != nil {
		t.Fatal(err)
	}
	now = now.Add(2 * time.Minute)
	l.Log("logout", true, "hvadmin", "10.99.77.2", "")
	l.Close()

	rotated := filepath.Join(dir, "panel", "panel-2026-09-25.log")
	b, err := os.ReadFile(rotated)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) != 1 {
		t.Fatalf("log injection produced %d lines: %s", len(lines), b)
	}
	var e Entry
	if err := json.Unmarshal([]byte(lines[0]), &e); err != nil || e.Action != "login" || !e.OK || strings.ContainsAny(e.Detail, "\n\r") {
		t.Fatalf("entry %+v %v", e, err)
	}
	cur, _ := os.ReadFile(p)
	if !strings.Contains(string(cur), `"action":"logout"`) || strings.Contains(string(cur), `"action":"login"`) {
		t.Fatalf("current log %s", cur)
	}
	fi, _ := os.Stat(p)
	if fi.Mode().Perm() != 0o640 {
		t.Fatalf("perm %v", fi.Mode().Perm())
	}
}

func TestUnwritableDoesNotPanic(t *testing.T) {
	l := New("/proc/definitely/not/writable/panel.log")
	l.Log("x", true, "", "", "")
	l.Close()
}
