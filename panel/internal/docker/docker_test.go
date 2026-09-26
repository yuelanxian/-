package docker

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func frame(stream byte, s string) []byte {
	b := make([]byte, 8+len(s))
	b[0] = stream
	binary.BigEndian.PutUint32(b[4:8], uint32(len(s)))
	copy(b[8:], s)
	return b
}

func TestDemux(t *testing.T) {
	var in bytes.Buffer
	in.Write(frame(StreamStdout, "hello\n"))
	in.Write(frame(StreamStderr, "oops\n"))
	in.Write(frame(StreamStdout, ""))
	in.Write(frame(StreamStdout, strings.Repeat("x", 70000)+"\n"))
	var out, errOut bytes.Buffer
	if err := DemuxStreams(&out, &errOut, &in); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.String(), "hello\nxxx") || errOut.String() != "oops\n" || out.Len() != 6+70001 {
		t.Fatalf("stdout=%d %q stderr=%q", out.Len(), out.String()[:10], errOut.String())
	}
}

func TestDemuxErrors(t *testing.T) {
	cases := map[string][]byte{
		"truncated header": {1, 0, 0},
		"bad header":       append([]byte{1, 9, 0, 0, 0, 0, 0, 1}, 'x'),
		"bad stream":       append([]byte{7, 0, 0, 0, 0, 0, 0, 1}, 'x'),
		"truncated frame":  append([]byte{1, 0, 0, 0, 0, 0, 0, 10}, 'x'),
	}
	for name, b := range cases {
		var out bytes.Buffer
		if err := Demux(&out, bytes.NewReader(b)); !errors.Is(err, ErrBadFrame) {
			t.Errorf("%s: err = %v, want ErrBadFrame", name, err)
		}
	}
}

type mockDocker struct {
	mu        sync.Mutex
	restarted []string
	paths     []string
}

func (m *mockDocker) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		m.paths = append(m.paths, r.Method+" "+r.URL.Path)
		m.mu.Unlock()
		switch {
		case r.Method == "GET" && r.URL.Path == "/containers/json":
			var f map[string][]string
			_ = json.Unmarshal([]byte(r.URL.Query().Get("filters")), &f)
			if len(f["label"]) != 1 || f["label"][0] != "com.docker.compose.project=homevault" || r.URL.Query().Get("all") != "1" {
				t.Errorf("unexpected filters %v", r.URL.RawQuery)
			}
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"Id": "aaa111", "Names": []string{"/homevault-app-1"}, "Image": "nextcloud", "State": "running", "Status": "Up",
					"Labels": map[string]string{"com.docker.compose.project": "homevault", "com.docker.compose.service": "app"}},
				{"Id": "bbb222", "Names": []string{"/homevault-caddy-1"}, "Image": "caddy", "State": "running", "Status": "Up",
					"Labels": map[string]string{"com.docker.compose.project": "homevault", "com.docker.compose.service": "caddy"}},
				{"Id": "ccc333", "Names": []string{"/homevault-backup-run-x"}, "Image": "restic", "State": "running",
					"Labels": map[string]string{"com.docker.compose.project": "homevault", "com.docker.compose.service": "backup", "com.docker.compose.oneoff": "True"}},
				{"Id": "ddd444", "Names": []string{"/other"}, "Image": "x", "State": "running",
					"Labels": map[string]string{"com.docker.compose.project": "other", "com.docker.compose.service": "app"}},
			})
		case r.Method == "GET" && r.URL.Path == "/containers/aaa111/json":
			_, _ = w.Write([]byte(`{"Id":"aaa111","State":{"Status":"running","StartedAt":"2026-09-26T08:00:00.123Z","Health":{"Status":"healthy"}},"RestartCount":2,"Config":{"Tty":false}}`))
		case r.Method == "GET" && r.URL.Path == "/containers/bbb222/json":
			_, _ = w.Write([]byte(`{"Id":"bbb222","State":{"Status":"running","StartedAt":"2026-09-26T08:00:00Z"},"Config":{"Tty":true}}`))
		case r.Method == "GET" && r.URL.Path == "/containers/aaa111/logs":
			if r.URL.Query().Get("tail") != "50" || r.URL.Query().Get("stdout") != "1" || r.URL.Query().Get("stderr") != "1" {
				t.Errorf("unexpected logs query %s", r.URL.RawQuery)
			}
			w.Header().Set("Content-Type", "application/vnd.docker.multiplexed-stream")
			_, _ = w.Write(frame(1, "out line\n"))
			_, _ = w.Write(frame(2, "err line\n"))
		case r.Method == "GET" && r.URL.Path == "/containers/bbb222/logs":
			_, _ = w.Write([]byte("raw tty line\n"))
		case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/restart"):
			m.mu.Lock()
			m.restarted = append(m.restarted, r.URL.Path)
			m.mu.Unlock()
			w.WriteHeader(http.StatusNoContent)
		case r.URL.Path == "/info":
			_, _ = w.Write([]byte(`{"ServerVersion":"28.4.0","NCPU":4,"MemTotal":8000000000,"OperatingSystem":"Debian"}`))
		default:
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte("<html><body><h1>403 Forbidden</h1></body></html>"))
		}
	})
}

func TestServicesLogsRestart(t *testing.T) {
	m := &mockDocker{}
	srv := httptest.NewServer(m.handler(t))
	defer srv.Close()
	c, err := New("tcp://"+strings.TrimPrefix(srv.URL, "http://"), "homevault")
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	list, err := c.Services(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || list[0].Service != "app" || list[1].Service != "caddy" {
		t.Fatalf("services = %+v", list)
	}
	if list[0].Health != "healthy" || list[0].RestartCount != 2 || list[0].StartedAt.IsZero() || !list[1].Tty {
		t.Fatalf("inspect not merged: %+v", list)
	}
	out, trunc, err := c.Logs(ctx, &list[0], 50, false, 1<<20)
	if err != nil || trunc || string(out) != "out line\nerr line\n" {
		t.Fatalf("logs = %q %v %v", out, trunc, err)
	}
	out, _, err = c.Logs(ctx, &list[1], 50, false, 1<<20)
	if err != nil || string(out) != "raw tty line\n" {
		t.Fatalf("tty logs = %q %v", out, err)
	}
	out, trunc, err = c.Logs(ctx, &list[0], 50, false, 5)
	if err != nil || !trunc || string(out) != "out l" {
		t.Fatalf("limited logs = %q %v %v", out, trunc, err)
	}
	if err := c.Restart(ctx, &list[0], 30); err != nil {
		t.Fatal(err)
	}
	if len(m.restarted) != 1 || m.restarted[0] != "/containers/aaa111/restart" {
		t.Fatalf("restart = %v", m.restarted)
	}
	if _, err := c.Find(ctx, "nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Find: %v", err)
	}
	info, err := c.Info(ctx)
	if err != nil || info.ServerVersion != "28.4.0" || info.NCPU != 4 {
		t.Fatalf("info %+v %v", info, err)
	}
	// Proxy denial is surfaced as APIError 403.
	err = c.Ping(ctx)
	var ae *APIError
	if !errors.As(err, &ae) || ae.Status != 403 {
		t.Fatalf("ping err = %v", err)
	}
	if err := c.Restart(ctx, &Container{ID: "../../images/create"}, 1); err == nil {
		t.Fatal("invalid id accepted")
	}
}
