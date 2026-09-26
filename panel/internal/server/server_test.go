package server

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"homevault/panel/internal/config"
)

func TestMain(m *testing.M) {
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	os.Exit(m.Run())
}

// ---------------------------------------------------------------- mocks

type mockNC struct {
	mu        sync.Mutex
	grantAt   int // poll number at which access is granted
	polls     int
	user      string
	groups    []string
	password  string
	revoked   map[string]bool
	xff       []string
	hosts     []string
	pollToken string
	userCalls int           // GET /ocs/v2.php/cloud/user requests
	delay     time.Duration // artificial latency of every request
}

func newMockNC() *mockNC {
	return &mockNC{grantAt: 2, user: "hvadmin", groups: []string{"admin"}, password: "FLOW-APP-PASSWORD",
		revoked: map[string]bool{}, pollToken: "PT"}
}

func (m *mockNC) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	d := m.delay
	m.mu.Unlock()
	time.Sleep(d)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.hosts = append(m.hosts, r.Host)
	if x := r.Header.Get("X-Forwarded-For"); x != "" {
		m.xff = append(m.xff, x)
	}
	ocs := func(status int, data any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{"ocs": map[string]any{"meta": map[string]any{"statuscode": status}, "data": data}})
	}
	authOK := func() bool {
		u, p, ok := r.BasicAuth()
		valid := ok && u == m.user && !m.revoked[p] && (p == m.password || p == "MANUAL-APP-PASSWORD")
		return valid && r.Header.Get("OCS-APIRequest") == "true"
	}
	switch r.Method + " " + r.URL.Path {
	case "POST /index.php/login/v2":
		_, _ = w.Write([]byte(`{"poll":{"token":"` + m.pollToken + `","endpoint":"https://nas.example:8443/login/v2/poll"},"login":"https://nas.example:8443/login/v2/flow/LT"}`))
	case "POST /login/v2/poll":
		_ = r.ParseForm()
		if r.PostForm.Get("token") != m.pollToken {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		m.polls++
		if m.polls < m.grantAt {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(`{"server":"https://nas.example:8443","loginName":"` + m.user + `","appPassword":"` + m.password + `"}`))
	case "GET /ocs/v2.php/cloud/user":
		m.userCalls++
		if !authOK() {
			ocs(http.StatusUnauthorized, []any{})
			return
		}
		ocs(http.StatusOK, map[string]any{"id": m.user, "displayname": "管理员", "groups": m.groups, "quota": map[string]any{"used": 1}})
	case "GET /ocs/v2.php/cloud/users/details":
		if !authOK() {
			ocs(http.StatusUnauthorized, []any{})
			return
		}
		ocs(http.StatusOK, map[string]any{"users": map[string]any{
			"hvadmin": map[string]any{"id": "hvadmin", "displayname": "管理员", "groups": []string{"admin"}, "enabled": true, "quota": map[string]any{"used": 100, "quota": -3}},
			"mom":     map[string]any{"id": "mom", "displayname": "妈妈", "groups": []string{}, "enabled": true, "quota": map[string]any{"used": 5000, "free": 5000, "quota": 10000, "relative": 50}},
		}})
	case "GET /ocs/v2.php/apps/serverinfo/api/v1/info":
		ocs(http.StatusOK, map[string]any{"nextcloud": map[string]any{"system": map[string]any{"version": "34.0.4.1"}, "storage": map[string]any{"num_users": 2, "num_files": 10}}})
	case "DELETE /ocs/v2.php/core/apppassword":
		if !authOK() {
			ocs(http.StatusUnauthorized, []any{})
			return
		}
		_, p, _ := r.BasicAuth()
		m.revoked[p] = true
		ocs(http.StatusOK, []any{})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (m *mockNC) isRevoked(p string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.revoked[p]
}

type mockDocker struct {
	mu        sync.Mutex
	restarted []string
	withCaddy bool
}

func dframe(stream byte, s string) []byte {
	b := make([]byte, 8+len(s))
	b[0] = stream
	binary.BigEndian.PutUint32(b[4:8], uint32(len(s)))
	copy(b[8:], s)
	return b
}

func (m *mockDocker) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	lbl := func(svc string) map[string]string {
		return map[string]string{"com.docker.compose.project": "homevault", "com.docker.compose.service": svc}
	}
	switch {
	case r.Method == "GET" && r.URL.Path == "/containers/json":
		list := []map[string]any{
			{"Id": "app1", "Names": []string{"/homevault-app-1"}, "State": "running", "Labels": lbl("app")},
			{"Id": "db1", "Names": []string{"/homevault-db-1"}, "State": "running", "Labels": lbl("db")},
			{"Id": "panel1", "Names": []string{"/homevault-panel-1"}, "State": "running", "Labels": lbl("panel")},
		}
		m.mu.Lock()
		if m.withCaddy {
			list = append(list, map[string]any{"Id": "caddy1", "Names": []string{"/homevault-caddy-1"}, "State": "running", "Labels": lbl("caddy")})
		}
		m.mu.Unlock()
		_ = json.NewEncoder(w).Encode(list)
	case r.Method == "GET" && strings.HasSuffix(r.URL.Path, "/json"):
		_, _ = w.Write([]byte(`{"State":{"Status":"running","StartedAt":"2026-09-26T00:00:00Z","Health":{"Status":"healthy"}},"Config":{"Tty":false}}`))
	case r.Method == "GET" && r.URL.Path == "/containers/app1/logs":
		_, _ = w.Write(dframe(1, "AH00558: apache started\n"))
		_, _ = w.Write(dframe(2, "PHP Warning: something\n"))
		_, _ = w.Write(dframe(1, "GET /status.php 200\n"))
	case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/restart"):
		m.mu.Lock()
		m.restarted = append(m.restarted, r.URL.Path)
		m.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	case r.URL.Path == "/info":
		_, _ = w.Write([]byte(`{"ServerVersion":"28.4.0"}`))
	default:
		w.WriteHeader(http.StatusForbidden)
	}
}

// ---------------------------------------------------------------- harness

type harness struct {
	t     *testing.T
	s     *Server
	nc    *mockNC
	dk    *mockDocker
	root  string
	cfg   *config.Config
	jar   map[string]string
	csrf  string
	extra map[string]string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	nc := newMockNC()
	dk := &mockDocker{}
	ncSrv := httptest.NewServer(nc)
	dkSrv := httptest.NewServer(dk)
	t.Cleanup(ncSrv.Close)
	t.Cleanup(dkSrv.Close)
	root := t.TempDir()
	for _, d := range []string{"logs/homevault", "logs/panel", "state", "stat/data", "stat/backup"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.WriteFile(filepath.Join(root, "logs/homevault/hv-2026-09-26.log"), []byte("start\nERROR 备份失败\nend\n"), 0o644)
	_ = os.WriteFile(filepath.Join(root, "outside.log"), []byte("SECRET\n"), 0o644)
	env := map[string]string{
		"HV_HOST":               "nas.example",
		"HV_PUBLIC_URL":         "https://nas.example:8443",
		"NC_INTERNAL_URL":       ncSrv.URL,
		"DOCKER_HOST":           "tcp://" + strings.TrimPrefix(dkSrv.URL, "http://"),
		"LOG_DIR":               filepath.Join(root, "logs"),
		"STATE_DIR":             filepath.Join(root, "state"),
		"STAT_DIR":              filepath.Join(root, "stat"),
		"PANEL_TRUSTED_PROXIES": "192.0.2.0/24",
		"HV_LOG_RETENTION_DAYS": "7",
	}
	cfg, err := config.FromLookup(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if err != nil {
		t.Fatal(err)
	}
	cfg.FlowPollInterval = 10 * time.Millisecond
	s, err := New(cfg, "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Shutdown(context.Background()) })
	return &harness{t: t, s: s, nc: nc, dk: dk, root: root, cfg: cfg, jar: map[string]string{}}
}

func (h *harness) do(method, path string, body any, hdr ...string) *http.Response {
	h.t.Helper()
	var rd io.Reader
	if body != nil {
		switch b := body.(type) {
		case string:
			rd = strings.NewReader(b)
		default:
			j, _ := json.Marshal(b)
			rd = bytes.NewReader(j)
		}
	}
	req := httptest.NewRequest(method, "https://nas.example:9443"+path, rd)
	req.RemoteAddr = "192.0.2.10:44444" // Caddy (trusted proxy)
	req.Header.Set("X-Forwarded-For", "10.99.77.2")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if method != http.MethodGet && h.csrf != "" {
		req.Header.Set("X-CSRF-Token", h.csrf)
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		if hdr[i+1] == "" {
			req.Header.Del(hdr[i])
		} else {
			req.Header.Set(hdr[i], hdr[i+1])
		}
	}
	for k, v := range h.jar {
		req.AddCookie(&http.Cookie{Name: k, Value: v})
	}
	rec := httptest.NewRecorder()
	h.s.Handler().ServeHTTP(rec, req)
	res := rec.Result()
	for _, c := range res.Cookies() {
		if c.MaxAge < 0 {
			delete(h.jar, c.Name)
		} else {
			h.jar[c.Name] = c.Value
		}
		if !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteStrictMode || c.Path != "/" {
			h.t.Errorf("cookie %s lacks security attributes: %+v", c.Name, c)
		}
	}
	return res
}

func decode(t *testing.T, res *http.Response) map[string]any {
	t.Helper()
	var m map[string]any
	b, _ := io.ReadAll(res.Body)
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("not JSON (%d): %s", res.StatusCode, b)
	}
	return m
}

// loginFlow performs the full Login Flow v2 against the mock Nextcloud.
func (h *harness) loginFlow() {
	h.t.Helper()
	res := h.do("POST", "/api/auth/flow", nil)
	if res.StatusCode != 200 {
		h.t.Fatalf("flow start: %d", res.StatusCode)
	}
	m := decode(h.t, res)
	if m["login_url"] != "https://nas.example:8443/login/v2/flow/LT" {
		h.t.Fatalf("login_url = %v", m["login_url"])
	}
	if h.jar[flowCookie] == "" {
		h.t.Fatal("no flow cookie")
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		m = decode(h.t, h.do("POST", "/api/auth/flow/poll", nil))
		if m["state"] == "ok" {
			h.csrf = m["csrf"].(string)
			return
		}
		if m["state"] != "pending" {
			h.t.Fatalf("flow state %v", m)
		}
		time.Sleep(20 * time.Millisecond)
	}
	h.t.Fatal("flow did not complete")
}

// ---------------------------------------------------------------- tests

func TestLoginFlowV2EndToEnd(t *testing.T) {
	h := newHarness(t)
	if res := h.do("GET", "/api/overview", nil); res.StatusCode != 401 {
		t.Fatalf("unauthenticated overview: %d", res.StatusCode)
	}
	h.loginFlow()
	if h.jar[sessionCookie] == "" || h.jar[flowCookie] != "" {
		t.Fatalf("cookies after login: %v", h.jar)
	}
	me := decode(t, h.do("GET", "/api/me", nil))
	if me["authenticated"] != true || me["user"] != "hvadmin" || me["csrf"] != h.csrf || me["method"] != "flow" {
		t.Fatalf("me = %v", me)
	}
	// Nextcloud saw the public Host and the real client IP
	h.nc.mu.Lock()
	for _, host := range h.nc.hosts {
		if host != "nas.example:8443" {
			t.Errorf("Host header sent to Nextcloud: %q", host)
		}
	}
	if len(h.nc.xff) == 0 || h.nc.xff[0] != "10.99.77.2" {
		t.Errorf("X-Forwarded-For to Nextcloud: %v", h.nc.xff)
	}
	h.nc.mu.Unlock()

	// CSRF: POST without token → 403
	tok := h.csrf
	h.csrf = ""
	if res := h.do("POST", "/api/backup/run", nil); res.StatusCode != 403 {
		t.Fatalf("POST without CSRF: %d", res.StatusCode)
	}
	h.csrf = tok
	// logout revokes the app password created by the flow
	if res := h.do("POST", "/api/auth/logout", nil); res.StatusCode != 200 {
		t.Fatalf("logout %d", res.StatusCode)
	}
	deadline := time.Now().Add(2 * time.Second)
	for !h.nc.isRevoked("FLOW-APP-PASSWORD") && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !h.nc.isRevoked("FLOW-APP-PASSWORD") {
		t.Fatal("app password not revoked on logout")
	}
	if m := decode(t, h.do("GET", "/api/me", nil)); m["authenticated"] != false {
		t.Fatalf("session survived logout: %v", m)
	}
}

func TestLoginFlowNonAdmin(t *testing.T) {
	h := newHarness(t)
	h.nc.groups = []string{"family"}
	h.do("POST", "/api/auth/flow", nil)
	deadline := time.Now().Add(3 * time.Second)
	var m map[string]any
	for time.Now().Before(deadline) {
		m = decode(t, h.do("POST", "/api/auth/flow/poll", nil))
		if m["state"] != "pending" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if m["state"] != "failed" || !strings.Contains(m["message"].(string), "管理员") {
		t.Fatalf("state = %v", m)
	}
	if !h.nc.isRevoked("FLOW-APP-PASSWORD") {
		t.Fatal("non-admin app password must be revoked")
	}
	if h.jar[sessionCookie] != "" {
		t.Fatal("session created for non-admin")
	}
}

func TestPasswordLoginAndRateLimit(t *testing.T) {
	h := newHarness(t)
	for i := 0; i < 5; i++ {
		res := h.do("POST", "/api/auth/password", map[string]string{"user": "hvadmin", "app_password": "wrong"})
		if res.StatusCode != 401 {
			t.Fatalf("attempt %d: %d", i, res.StatusCode)
		}
	}
	res := h.do("POST", "/api/auth/password", map[string]string{"user": "hvadmin", "app_password": "MANUAL-APP-PASSWORD"})
	if res.StatusCode != 429 || res.Header.Get("Retry-After") == "" {
		t.Fatalf("expected 429, got %d", res.StatusCode)
	}
	// another client IP is not blocked
	res = h.do("POST", "/api/auth/password", map[string]string{"user": "hvadmin", "app_password": "MANUAL-APP-PASSWORD"},
		"X-Forwarded-For", "10.99.77.9")
	if res.StatusCode != 200 {
		t.Fatalf("other IP: %d", res.StatusCode)
	}
	m := decode(t, h.do("GET", "/api/me", nil))
	if m["method"] != "app-password" {
		t.Fatalf("me %v", m)
	}
	h.csrf = m["csrf"].(string)
	h.do("POST", "/api/auth/logout", nil)
	time.Sleep(50 * time.Millisecond)
	if h.nc.isRevoked("MANUAL-APP-PASSWORD") {
		t.Fatal("user-supplied app password must not be revoked")
	}
	// strict JSON: unknown fields and wrong content type rejected
	if res := h.do("POST", "/api/auth/password", `{"user":"a","app_password":"b","x":1}`, "X-Forwarded-For", "10.99.77.10"); res.StatusCode != 400 {
		t.Fatalf("unknown field: %d", res.StatusCode)
	}
	if res := h.do("POST", "/api/auth/password", `user=a`, "Content-Type", "application/x-www-form-urlencoded", "X-Forwarded-For", "10.99.77.10"); res.StatusCode != 415 {
		t.Fatalf("form body: %d", res.StatusCode)
	}
}

// Parallel wrong guesses must not slip past the per-IP limit while earlier attempts are still
// being checked against Nextcloud (check-then-act race).
func TestPasswordLoginRateLimitConcurrent(t *testing.T) {
	h := newHarness(t)
	h.nc.mu.Lock()
	h.nc.delay = 50 * time.Millisecond
	h.nc.mu.Unlock()
	var wg sync.WaitGroup
	var mu sync.Mutex
	codes := map[int]int{}
	for i := 0; i < 40; i++ {
		wg.Go(func() {
			req := httptest.NewRequest("POST", "https://nas.example:9443/api/auth/password",
				strings.NewReader(`{"user":"hvadmin","app_password":"guess"}`))
			req.RemoteAddr = "192.0.2.10:44444"
			req.Header.Set("X-Forwarded-For", "10.99.77.66")
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			h.s.Handler().ServeHTTP(rec, req)
			mu.Lock()
			codes[rec.Code]++
			mu.Unlock()
		})
	}
	wg.Wait()
	h.nc.mu.Lock()
	calls := h.nc.userCalls
	h.nc.mu.Unlock()
	if calls > 5 || codes[401] > 5 || codes[429] < 35 {
		t.Fatalf("per-IP limit bypassed by parallel requests: %d Nextcloud checks, status codes %v", calls, codes)
	}
	// a correct app password afterwards from another IP still works and does not use up the global budget
	res := h.do("POST", "/api/auth/password", map[string]string{"user": "hvadmin", "app_password": "MANUAL-APP-PASSWORD"},
		"X-Forwarded-For", "10.99.77.67")
	if res.StatusCode != 200 {
		t.Fatalf("valid login from another IP: %d", res.StatusCode)
	}
}

// Clicking "使用 Nextcloud 登录" again replaces the browser's previous flow instead of leaving it
// polling for 20 minutes (and occupying one of the MaxPendingFlows slots).
func TestFlowRestartCancelsPrevious(t *testing.T) {
	h := newHarness(t)
	h.nc.mu.Lock()
	h.nc.grantAt = 1 << 30
	h.nc.mu.Unlock()
	for i := 0; i < 3; i++ {
		if res := h.do("POST", "/api/auth/flow", nil); res.StatusCode != 200 {
			t.Fatalf("flow start %d: %d", i, res.StatusCode)
		}
	}
	deadline := time.Now().Add(2 * time.Second)
	for h.s.flows.Pending() != 1 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if n := h.s.flows.Pending(); n != 1 {
		t.Fatalf("pending flows = %d, want 1", n)
	}
}

func TestCrossOriginRejected(t *testing.T) {
	h := newHarness(t)
	res := h.do("POST", "/api/auth/flow", nil, "Sec-Fetch-Site", "cross-site")
	if res.StatusCode != 403 {
		t.Fatalf("cross-site POST: %d", res.StatusCode)
	}
	res = h.do("POST", "/api/auth/flow", nil, "Origin", "https://evil.example")
	if res.StatusCode != 403 {
		t.Fatalf("foreign Origin POST: %d", res.StatusCode)
	}
	res = h.do("POST", "/api/auth/flow", nil, "Sec-Fetch-Site", "same-origin")
	if res.StatusCode != 200 {
		t.Fatalf("same-origin POST: %d", res.StatusCode)
	}
}

func TestSecurityHeadersAndStatic(t *testing.T) {
	h := newHarness(t)
	res := h.do("GET", "/", nil)
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 || !strings.Contains(string(body), "HomeVault") || strings.Contains(string(body), "{{VERSION}}") {
		t.Fatalf("index: %d", res.StatusCode)
	}
	csp := res.Header.Get("Content-Security-Policy")
	for _, want := range []string{"default-src 'none'", "script-src 'self'", "style-src 'self'", "frame-ancestors 'none'"} {
		if !strings.Contains(csp, want) {
			t.Errorf("CSP missing %q: %s", want, csp)
		}
	}
	if strings.Contains(csp, "unsafe-inline") || strings.Contains(csp, "unsafe-eval") {
		t.Errorf("CSP too weak: %s", csp)
	}
	if !strings.Contains(string(body), `<script type="module" src="/js/app.js`) || strings.Contains(string(body), "<script>") ||
		strings.Contains(string(body), "style=") || strings.Contains(string(body), "<style") {
		t.Error("index.html must not contain inline scripts or styles")
	}
	for _, hname := range []string{"X-Content-Type-Options", "X-Frame-Options", "Referrer-Policy", "Cross-Origin-Opener-Policy"} {
		if res.Header.Get(hname) == "" {
			t.Errorf("missing %s", hname)
		}
	}
	etag := res.Header.Get("ETag")
	if res := h.do("GET", "/", nil, "If-None-Match", etag); res.StatusCode != 304 {
		t.Errorf("etag revalidation: %d", res.StatusCode)
	}
	for _, p := range []string{"/js/app.js", "/css/app.css", "/manifest.webmanifest", "/icons/icon-192.png", "/vendor/qrcode.js"} {
		if res := h.do("GET", p, nil); res.StatusCode != 200 {
			t.Errorf("%s: %d", p, res.StatusCode)
		}
	}
	if res := h.do("GET", "/web/embed.go", nil); res.StatusCode != 404 {
		t.Error("source files must not be served")
	}
	if res := h.do("GET", "/api/nope", nil); res.StatusCode != 404 || res.Header.Get("Cache-Control") != "no-store" {
		t.Errorf("api 404: %d %q", res.StatusCode, res.Header.Get("Cache-Control"))
	}
	if res := h.do("GET", "/healthz", nil); res.StatusCode != 200 {
		t.Error("healthz")
	}
	info := decode(t, h.do("GET", "/api/info", nil))
	if info["app"] != "homevault-panel" || info["nextcloud_url"] != "https://nas.example:8443" {
		t.Errorf("info %v", info)
	}
}

func TestLogsAPI(t *testing.T) {
	h := newHarness(t)
	h.loginFlow()
	m := decode(t, h.do("GET", "/api/logs", nil))
	var paths []string
	for _, f := range m["files"].([]any) {
		paths = append(paths, f.(map[string]any)["path"].(string))
	}
	// the hv log plus the panel's own audit log (written by the login above)
	if strings.Join(paths, ",") != "panel/panel.log,homevault/hv-2026-09-26.log" {
		t.Fatalf("files %v", paths)
	}
	if len(m["containers"].([]any)) != 3 || m["retention_days"] != float64(7) {
		t.Fatalf("logs %v", m)
	}
	m = decode(t, h.do("GET", "/api/logs/file?path=homevault/hv-2026-09-26.log&lines=2", nil))
	if lines := m["lines"].([]any); len(lines) != 2 || lines[1] != "end" {
		t.Fatalf("tail %v", m)
	}
	m = decode(t, h.do("GET", "/api/logs/file?path=homevault/hv-2026-09-26.log&q=error", nil))
	if lines := m["lines"].([]any); len(lines) != 1 || lines[0] != "ERROR 备份失败" {
		t.Fatalf("filter %v", m)
	}
	for _, p := range []string{"../outside.log", "..%2Foutside.log", "/etc/passwd", "homevault/../../outside.log", "..\\outside.log", "x.sh"} {
		res := h.do("GET", "/api/logs/file?path="+p, nil)
		if res.StatusCode != 400 {
			t.Errorf("path %q: %d", p, res.StatusCode)
		}
		res = h.do("GET", "/api/logs/download?path="+p, nil)
		if res.StatusCode != 400 {
			t.Errorf("download %q: %d", p, res.StatusCode)
		}
	}
	if res := h.do("GET", "/api/logs/file?path=homevault/missing.log", nil); res.StatusCode != 404 {
		t.Errorf("missing: %d", res.StatusCode)
	}
	res := h.do("GET", "/api/logs/download?path=homevault/hv-2026-09-26.log", nil)
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 || !strings.Contains(res.Header.Get("Content-Disposition"), "attachment") || !strings.Contains(string(body), "备份失败") {
		t.Fatalf("download %d %v", res.StatusCode, res.Header)
	}
	// container logs are demultiplexed
	m = decode(t, h.do("GET", "/api/logs/container/app?lines=10", nil))
	lines := m["lines"].([]any)
	if len(lines) != 3 || lines[1] != "PHP Warning: something" {
		t.Fatalf("container logs %v", m)
	}
	m = decode(t, h.do("GET", "/api/logs/container/app?q=warning", nil))
	if len(m["lines"].([]any)) != 1 {
		t.Fatalf("container filter %v", m)
	}
	if res := h.do("GET", "/api/logs/container/nope", nil); res.StatusCode != 404 {
		t.Errorf("unknown service: %d", res.StatusCode)
	}
	// audit log written
	b, _ := os.ReadFile(filepath.Join(h.root, "logs/panel/panel.log"))
	if !strings.Contains(string(b), `"action":"log_download"`) || !strings.Contains(string(b), `"action":"login"`) {
		t.Fatalf("audit log: %s", b)
	}
}

func TestRetentionValidation(t *testing.T) {
	h := newHarness(t)
	h.loginFlow()
	for _, body := range []string{`{"days":0}`, `{"days":366}`, `{"days":"7"}`, `{"days":7.5}`, `{"days":1e1}`, `{"days":-3}`, `{}`, `{"days":7,"x":1}`, `[]`, `{"days":7}{"days":8}`} {
		if res := h.do("POST", "/api/settings/log-retention", body); res.StatusCode != 400 {
			t.Errorf("%s: %d", body, res.StatusCode)
		}
	}
	res := h.do("POST", "/api/settings/log-retention", `{"days":30}`)
	if res.StatusCode != 202 {
		t.Fatalf("valid: %d", res.StatusCode)
	}
	ents, _ := os.ReadDir(filepath.Join(h.root, "state/requests"))
	if len(ents) != 1 || !strings.HasSuffix(ents[0].Name(), "-log-retention.json") {
		t.Fatalf("request files %v", ents)
	}
	b, _ := os.ReadFile(filepath.Join(h.root, "state/requests", ents[0].Name()))
	var req map[string]any
	_ = json.Unmarshal(b, &req)
	if req["days"] != float64(30) || req["type"] != "log-retention" || req["requested_by"] != "hvadmin" || req["client_ip"] != "10.99.77.2" {
		t.Fatalf("request %s", b)
	}
	m := decode(t, h.do("GET", "/api/settings/log-retention", nil))
	if m["days"] != float64(7) || m["pending_days"] != float64(30) {
		t.Fatalf("get %v", m)
	}
	// host applied it and reports it via status.json
	_ = os.WriteFile(filepath.Join(h.root, "state/status.json"), []byte(`{"updated":"2026-09-26T10:00:00Z","log_retention_days":30}`), 0o644)
	m = decode(t, h.do("GET", "/api/settings/log-retention", nil))
	if m["days"] != float64(30) {
		t.Fatalf("after apply %v", m)
	}
}

func TestBackupRunAndRestartAllowList(t *testing.T) {
	h := newHarness(t)
	h.loginFlow()
	m := decode(t, h.do("POST", "/api/backup/run", nil))
	if m["ok"] != true || m["duplicate"] != false {
		t.Fatalf("backup run %v", m)
	}
	m = decode(t, h.do("POST", "/api/backup/run", nil))
	if m["duplicate"] != true {
		t.Fatalf("second run should be deduplicated %v", m)
	}
	m = decode(t, h.do("GET", "/api/backup", nil))
	if len(m["pending"].([]any)) != 1 {
		t.Fatalf("pending %v", m)
	}
	if res := h.do("POST", "/api/services/panel/restart", nil); res.StatusCode != 403 {
		t.Fatalf("panel restart must be forbidden: %d", res.StatusCode)
	}
	if res := h.do("POST", "/api/services/..%2F..%2Fimages/restart", nil); res.StatusCode != 403 && res.StatusCode != 404 {
		t.Fatalf("traversal restart: %d", res.StatusCode)
	}
	if res := h.do("POST", "/api/services/app/restart", nil); res.StatusCode != 200 {
		t.Fatalf("app restart: %d", res.StatusCode)
	}
	if res := h.do("POST", "/api/services/redis/restart", nil); res.StatusCode != 404 {
		t.Fatalf("missing container: %d", res.StatusCode)
	}
	h.dk.mu.Lock()
	if len(h.dk.restarted) != 1 || h.dk.restarted[0] != "/containers/app1/restart" {
		t.Fatalf("restarted %v", h.dk.restarted)
	}
	h.dk.withCaddy = true
	h.dk.mu.Unlock()
	// Caddy carries this very request: the panel answers first and restarts in the background.
	if res := h.do("POST", "/api/services/caddy/restart", nil); res.StatusCode != 202 {
		t.Fatalf("caddy restart: %d", res.StatusCode)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		h.dk.mu.Lock()
		n := len(h.dk.restarted)
		last := h.dk.restarted[n-1]
		h.dk.mu.Unlock()
		if n == 2 && last == "/containers/caddy1/restart" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("caddy not restarted: %d %s", n, last)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestOverviewStorageVPN(t *testing.T) {
	h := newHarness(t)
	h.loginFlow()
	st := filepath.Join(h.root, "state")
	now := time.Now().UTC()
	_ = os.WriteFile(filepath.Join(st, "backup-status.json"), []byte(`{"state":"ok","last_success":"`+now.Add(-72*time.Hour).Format(time.RFC3339)+`","target":"local"}`), 0o644)
	_ = os.WriteFile(filepath.Join(st, "snapshots.json"), []byte(`[{"id":"aaaa","short_id":"aaaa","time":"2026-09-20T03:30:00Z","paths":["/src"]},{"id":"bbbb","short_id":"bbbb","time":"2026-09-25T03:30:00Z"}]`), 0o644)
	_ = os.WriteFile(filepath.Join(st, "vpn-status.json"), []byte(`{"updated":"`+now.Format(time.RFC3339)+`","peers":[{"name":"手机","address":"10.99.77.2","public_key":"SECRETKEY","latest_handshake":`+
		itoa(now.Add(-30*time.Second).Unix())+`,"rx_bytes":10,"tx_bytes":20,"enabled":true},{"name":"旧平板","address":"10.99.77.3","latest_handshake":0,"enabled":true}]}`), 0o644)

	m := decode(t, h.do("GET", "/api/overview", nil))
	alerts, _ := json.Marshal(m["alerts"])
	for _, want := range []string{"48 小时", "cron", "redis", "caddy"} {
		if !strings.Contains(string(alerts), want) && !strings.Contains(string(alerts), label(want)) {
			t.Errorf("alerts missing %q: %s", want, alerts)
		}
	}
	vpn := m["vpn"].(map[string]any)
	if vpn["online"] != float64(1) || vpn["devices"] != float64(2) {
		t.Fatalf("vpn summary %v", vpn)
	}
	m = decode(t, h.do("GET", "/api/backup", nil))
	snaps := m["snapshots"].([]any)
	if len(snaps) != 2 || snaps[0].(map[string]any)["short_id"] != "bbbb" {
		t.Fatalf("snapshots not sorted newest first: %v", snaps)
	}
	res := h.do("GET", "/api/vpn", nil)
	raw, _ := io.ReadAll(res.Body)
	if strings.Contains(string(raw), "SECRETKEY") || !strings.Contains(string(raw), `"online":true`) {
		t.Fatalf("vpn: %s", raw)
	}
	m = decode(t, h.do("GET", "/api/storage", nil))
	if len(m["disks"].([]any)) != 2 || len(m["users"].([]any)) != 2 {
		t.Fatalf("storage %v", m)
	}
	first := m["users"].([]any)[0].(map[string]any)
	if first["id"] != "mom" || first["quota"] != float64(10000) {
		t.Fatalf("users not sorted by usage: %v", first)
	}
	if m["nextcloud"].(map[string]any)["version"] != "34.0.4.1" {
		t.Fatalf("serverinfo %v", m["nextcloud"])
	}
}

func itoa(n int64) string { return big.NewInt(n).String() }

func TestCACertOnlyCertificates(t *testing.T) {
	h := newHarness(t)
	if res := h.do("GET", "/ca.crt", nil); res.StatusCode != 404 {
		t.Fatalf("missing CA: %d", res.StatusCode)
	}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "HomeVault Local CA - 2026 ECC Root"},
		NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true}
	der, _ := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	kb, _ := x509.MarshalECPrivateKey(key)
	mixed := append(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})...)
	_ = os.WriteFile(filepath.Join(h.root, "state/ca.crt"), mixed, 0o644)
	res := h.do("GET", "/ca.crt", nil)
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 || strings.Contains(string(body), "PRIVATE") || !strings.Contains(string(body), "BEGIN CERTIFICATE") {
		t.Fatalf("ca.crt %d: %s", res.StatusCode, body)
	}
	h.loginFlow()
	m := decode(t, h.do("GET", "/api/about", nil))
	ca := m["ca"].(map[string]any)
	if ca["available"] != true || len(ca["sha256"].(string)) != 95 {
		t.Fatalf("about ca %v", ca)
	}
	if m["apk"].(map[string]any)["available"] != false {
		t.Fatal("apk should be unavailable")
	}
	if res := h.do("GET", "/download/android", nil); res.StatusCode != 404 {
		t.Fatalf("apk: %d", res.StatusCode)
	}
	_ = os.MkdirAll(filepath.Join(h.root, "state/app"), 0o755)
	_ = os.WriteFile(filepath.Join(h.root, "state/app/homevault.apk"), []byte("PK\x03\x04fake"), 0o644)
	res = h.do("GET", "/download/android", nil)
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "application/vnd.android.package-archive" {
		t.Fatalf("apk download %d %v", res.StatusCode, res.Header)
	}
}

func TestAdminRecheckRevokesSession(t *testing.T) {
	h := newHarness(t)
	h.cfg.RecheckInterval = time.Nanosecond
	h.loginFlow()
	if res := h.do("GET", "/api/overview", nil); res.StatusCode != 200 {
		t.Fatalf("overview %d", res.StatusCode)
	}
	h.nc.mu.Lock()
	h.nc.groups = []string{"family"}
	h.nc.mu.Unlock()
	time.Sleep(time.Millisecond)
	if res := h.do("GET", "/api/overview", nil); res.StatusCode != 403 {
		t.Fatalf("demoted admin: %d", res.StatusCode)
	}
	if m := decode(t, h.do("GET", "/api/me", nil)); m["authenticated"] != false {
		t.Fatalf("session should be gone: %v", m)
	}
}

func TestClientIP(t *testing.T) {
	h := newHarness(t)
	cases := []struct{ remote, xff, want string }{
		{"192.0.2.10:1", "10.99.77.2", "10.99.77.2"},
		{"192.0.2.10:1", "6.6.6.6, 10.99.77.2", "10.99.77.2"},
		{"203.0.113.5:1", "10.99.77.2", "203.0.113.5"}, // untrusted peer: XFF ignored
		{"192.0.2.10:1", "", "192.0.2.10"},
		{"192.0.2.10:1", "garbage", "192.0.2.10"},
	}
	for _, c := range cases {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = c.remote
		if c.xff != "" {
			r.Header.Set("X-Forwarded-For", c.xff)
		}
		if got := h.s.clientIP(r); got != c.want {
			t.Errorf("%v: got %s", c, got)
		}
	}
}

func TestTrimToBytes(t *testing.T) {
	lines := []string{"aaaa", "bbbb", "cccc"}
	got, cut := trimToBytes(lines, 10)
	if !cut || len(got) != 2 || got[0] != "bbbb" {
		t.Fatalf("%v %v", got, cut)
	}
	got, cut = trimToBytes(lines, 100)
	if cut || len(got) != 3 {
		t.Fatalf("%v %v", got, cut)
	}
}

func TestStorageFallsBackToHostDisks(t *testing.T) {
	h := newHarness(t)
	h.loginFlow()
	if err := os.RemoveAll(filepath.Join(h.root, "stat")); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(h.root, "state", "status.json"), []byte(`{"generated":"2026-09-26T03:00:00+08:00","platform":"windows",`+
		`"disks":[{"role":"主数据","name":"Nextcloud 数据","path":"D:\\HomeVault\\nextcloud-data","total":1000,"free":50,"mounted":true},`+
		`{"role":"backup","name":"restic 仓库","path":"E:\\Backup","total":0,"free":0,"mounted":false}]}`), 0o644)
	m := decode(t, h.do("GET", "/api/storage", nil))
	disks := m["disks"].([]any)
	if m["disks_source"] != "host" || len(disks) != 2 {
		t.Fatalf("storage %v", m)
	}
	d0 := disks[0].(map[string]any)
	if d0["role"] != "data" || d0["used"] != float64(950) || d0["used_pct"] != float64(95) || d0["host_path"] != `D:\HomeVault\nextcloud-data` {
		t.Fatalf("disk0 %v", d0)
	}
	if disks[1].(map[string]any)["error"] == nil {
		t.Fatalf("disk1 %v", disks[1])
	}
	alerts, _ := json.Marshal(m["alerts"])
	if !strings.Contains(string(alerts), "10%") {
		t.Fatalf("low-space alert missing: %s", alerts)
	}
}

// A log the panel user may not read (host without setfacl: Nextcloud writes 0640 files) must be
// reported as a permission problem, not as an invalid path.
func TestLogFileErrorPermission(t *testing.T) {
	rec := httptest.NewRecorder()
	logFileError(rec, &fs.PathError{Op: "openat", Path: "nextcloud/nextcloud.log", Err: syscall.EACCES})
	var m map[string]string
	_ = json.Unmarshal(rec.Body.Bytes(), &m)
	if rec.Code != http.StatusForbidden || !strings.Contains(m["error"], "权限") {
		t.Fatalf("permission error mapped to %d %q", rec.Code, m["error"])
	}
	rec = httptest.NewRecorder()
	logFileError(rec, &fs.PathError{Op: "openat", Path: "../x.log", Err: errors.New("path escapes from parent")})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("escape mapped to %d", rec.Code)
	}
}
