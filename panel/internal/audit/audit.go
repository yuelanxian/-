// Package audit writes the panel audit log (JSON lines) with daily/size rotation:
// panel.log is renamed to panel-YYYY-MM-DD.log when the day changes, so the host's
// retention job (delete *.log older than HV_LOG_RETENTION_DAYS) can clean it up.
package audit

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const maxSize = 20 << 20

// Entry is one audit record.
type Entry struct {
	Time   time.Time `json:"time"`
	Action string    `json:"action"`
	OK     bool      `json:"ok"`
	User   string    `json:"user,omitempty"`
	IP     string    `json:"ip,omitempty"`
	Detail string    `json:"detail,omitempty"`
}

// Logger appends audit entries to a file; failures fall back to the process log.
type Logger struct {
	Path string
	Now  func() time.Time

	mu     sync.Mutex
	f      *os.File
	day    string
	warned bool
}

// New creates an audit logger for path (the directory must exist or be creatable).
func New(path string) *Logger { return &Logger{Path: path, Now: time.Now} }

// Log writes an entry. It never fails the caller.
func (l *Logger) Log(action string, ok bool, user, ip, detail string) {
	e := Entry{Time: l.Now(), Action: action, OK: ok, User: user, IP: ip, Detail: sanitize(detail)}
	b, _ := json.Marshal(e)
	b = append(b, '\n')
	slog.Info("audit", "action", action, "ok", ok, "user", user, "ip", ip, "detail", e.Detail)
	if l.Path == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.ensure(e.Time); err != nil {
		if !l.warned {
			slog.Warn("audit log not writable, logging to stdout only", "path", l.Path, "err", err)
			l.warned = true
		}
		return
	}
	if _, err := l.f.Write(b); err != nil {
		l.f.Close()
		l.f = nil
	}
}

func (l *Logger) ensure(now time.Time) error {
	day := now.Format("2006-01-02")
	if l.f != nil && l.day == day {
		if fi, err := l.f.Stat(); err == nil && fi.Size() < maxSize {
			return nil
		}
	}
	if l.f != nil {
		l.f.Close()
		l.f = nil
	}
	if err := os.MkdirAll(filepath.Dir(l.Path), 0o750); err != nil {
		return err
	}
	// Rotate an existing file from a previous day or one that grew too large.
	if fi, err := os.Stat(l.Path); err == nil {
		fday := fi.ModTime().Format("2006-01-02")
		if fday != day || fi.Size() >= maxSize {
			base := strings.TrimSuffix(l.Path, filepath.Ext(l.Path))
			target := fmt.Sprintf("%s-%s.log", base, fday)
			if _, err := os.Stat(target); err == nil {
				target = fmt.Sprintf("%s-%s-%s.log", base, fday, fi.ModTime().Format("150405"))
			}
			_ = os.Rename(l.Path, target)
		}
	}
	f, err := os.OpenFile(l.Path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o640)
	if err != nil {
		return err
	}
	l.f, l.day, l.warned = f, day, false
	return nil
}

// Close closes the file.
func (l *Logger) Close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f != nil {
		l.f.Close()
		l.f = nil
	}
}

func sanitize(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, s)
	if len(s) > 500 {
		s = strings.ToValidUTF8(s[:500], "")
	}
	return s
}
