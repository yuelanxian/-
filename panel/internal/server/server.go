// Package server wires the HTTP API, authentication and static frontend together.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	"homevault/panel/internal/audit"
	"homevault/panel/internal/auth"
	"homevault/panel/internal/config"
	"homevault/panel/internal/docker"
	"homevault/panel/internal/hoststate"
	"homevault/panel/internal/logfiles"
	"homevault/panel/internal/nextcloud"
)

const (
	sessionCookie = "__Host-hvpanel"
	flowCookie    = "__Host-hvflow"
	maxJSONBody   = 16 << 10
)

// Server is the management panel.
type Server struct {
	cfg      *config.Config
	version  string
	nc       *nextcloud.Client
	docker   *docker.Client
	logs     *logfiles.Dir
	state    *hoststate.Store
	audit    *audit.Logger
	sessions *auth.Store
	flows    *auth.Flows
	static   *staticFiles

	flowLimiter   *auth.Limiter // flow starts per IP
	pwFailLimiter *auth.Limiter // failed app-password logins per IP
	pwGlobal      *auth.Limiter // failed app-password logins overall

	cache   ttlCache
	handler http.Handler
	now     func() time.Time
}

// New creates a server from configuration.
func New(cfg *config.Config, version string) (*Server, error) {
	dc, err := docker.New(cfg.DockerHost, cfg.ComposeProject)
	if err != nil {
		return nil, err
	}
	static, err := newStaticFiles(version)
	if err != nil {
		return nil, err
	}
	s := &Server{
		cfg:           cfg,
		version:       version,
		nc:            nextcloud.New(cfg.NCInternalURL, cfg.PublicURL, cfg.NCHostHeader, "HomeVault 管理面板"),
		docker:        dc,
		logs:          &logfiles.Dir{Root: cfg.LogDir, MaxGzipInput: cfg.MaxGzipInputBytes},
		state:         hoststate.New(cfg.StateDir),
		audit:         audit.New(cfg.AuditLog),
		sessions:      auth.NewStore(cfg.SessionTTL, cfg.MaxSessions),
		static:        static,
		flowLimiter:   auth.NewLimiter(10, 10*time.Minute),
		pwFailLimiter: auth.NewLimiter(5, 15*time.Minute),
		pwGlobal:      auth.NewLimiter(30, 15*time.Minute),
		now:           time.Now,
	}
	s.sessions.OnEnd = s.onSessionEnd
	s.flows = auth.NewFlows(s.nc, s.authorize, s.revoke, cfg.FlowPollInterval, cfg.FlowLifetime, cfg.MaxPendingFlows)
	s.handler = s.routes()
	return s, nil
}

// Handler returns the root HTTP handler.
func (s *Server) Handler() http.Handler { return s.handler }

// Run starts background maintenance until ctx is done.
func (s *Server) Run(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.sessions.Sweep()
			s.flowLimiter.Sweep()
			s.pwFailLimiter.Sweep()
			s.pwGlobal.Sweep()
		}
	}
}

// Shutdown stops login flows and revokes the app passwords of all live sessions.
func (s *Server) Shutdown(ctx context.Context) {
	s.flows.Shutdown()
	var wg sync.WaitGroup
	for _, sess := range s.sessions.DrainAll() {
		if !sess.RevokeOnEnd {
			continue
		}
		wg.Go(func() {
			rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			if err := s.nc.RevokeAppPassword(rctx, &sess.Creds); err != nil {
				slog.Warn("revoke app password at shutdown failed", "user", sess.UserID, "err", err)
			}
		})
	}
	wg.Wait()
	s.audit.Close()
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()

	// public
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /api/info", s.handleInfo)
	mux.HandleFunc("GET /ca.crt", s.handleCACert)
	mux.HandleFunc("GET /download/android", s.handleAPK)
	mux.HandleFunc("GET /api/me", s.handleMe)
	mux.HandleFunc("POST /api/auth/flow", s.handleFlowStart)
	mux.HandleFunc("POST /api/auth/flow/poll", s.handleFlowPoll)
	mux.HandleFunc("POST /api/auth/flow/cancel", s.handleFlowCancel)
	mux.HandleFunc("POST /api/auth/password", s.handlePasswordLogin)

	// authenticated
	mux.Handle("POST /api/auth/logout", s.authed(s.handleLogout))
	mux.Handle("GET /api/overview", s.authed(s.handleOverview))
	mux.Handle("GET /api/storage", s.authed(s.handleStorage))
	mux.Handle("GET /api/backup", s.authed(s.handleBackup))
	mux.Handle("POST /api/backup/run", s.authed(s.handleBackupRun))
	mux.Handle("GET /api/logs", s.authed(s.handleLogs))
	mux.Handle("GET /api/logs/file", s.authed(s.handleLogFile))
	mux.Handle("GET /api/logs/download", s.authed(s.handleLogDownload))
	mux.Handle("GET /api/logs/container/{service}", s.authed(s.handleContainerLogs))
	mux.Handle("GET /api/logs/container/{service}/download", s.authed(s.handleContainerLogsDownload))
	mux.Handle("POST /api/logs/clean", s.authed(s.handleLogClean))
	mux.Handle("GET /api/settings/log-retention", s.authed(s.handleRetentionGet))
	mux.Handle("POST /api/settings/log-retention", s.authed(s.handleRetentionSet))
	mux.Handle("GET /api/vpn", s.authed(s.handleVPN))
	mux.Handle("POST /api/services/{name}/restart", s.authed(s.handleRestart))
	mux.Handle("GET /api/requests", s.authed(s.handleRequests))
	mux.Handle("GET /api/about", s.authed(s.handleAbout))

	// Fallback: unknown API paths get JSON 404s; everything else is the embedded frontend.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/"):
			writeError(w, http.StatusNotFound, "接口不存在")
		case r.Method == http.MethodGet || r.Method == http.MethodHead:
			s.static.ServeHTTP(w, r)
		default:
			w.Header().Set("Allow", "GET, HEAD")
			writeError(w, http.StatusMethodNotAllowed, "不支持的请求方法")
		}
	})

	cop := http.NewCrossOriginProtection()
	cop.SetDenyHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusForbidden, "跨站请求被拒绝")
	}))
	return s.securityHeaders(cop.Handler(mux))
}

// securityHeaders adds strict headers to every response (HSTS is added by Caddy).
func (s *Server) securityHeaders(next http.Handler) http.Handler {
	const csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; " +
		"connect-src 'self'; font-src 'self'; manifest-src 'self'; frame-ancestors 'none'; " +
		"base-uri 'none'; form-action 'self'"
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", csp)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
		if strings.HasPrefix(r.URL.Path, "/api/") {
			h.Set("Cache-Control", "no-store")
		}
		next.ServeHTTP(w, r)
	})
}

// ---------------------------------------------------------------- auth middleware

type authedHandler func(w http.ResponseWriter, r *http.Request, sess *auth.Session)

func (s *Server) sessionFrom(r *http.Request) *auth.Session {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return nil
	}
	return s.sessions.Get(c.Value)
}

func (s *Server) authed(h authedHandler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sess := s.sessionFrom(r)
		if sess == nil {
			writeError(w, http.StatusUnauthorized, "请先登录")
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if !sess.CheckCSRF(r.Header.Get("X-CSRF-Token")) {
				writeError(w, http.StatusForbidden, "CSRF 校验失败，请刷新页面后重试")
				return
			}
		}
		if sess.NeedsRecheck(s.now(), s.cfg.RecheckInterval) {
			ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
			u, err := s.nc.CurrentUser(ctx, &sess.Creds, s.clientIP(r))
			cancel()
			switch {
			case errors.Is(err, nextcloud.ErrUnauthorized):
				s.sessions.Delete(sess.ID)
				s.audit.Log("session_revoked", false, sess.UserID, s.clientIP(r), "应用密码已失效")
				clearCookie(w, sessionCookie)
				writeError(w, http.StatusUnauthorized, "登录已失效，请重新登录")
				return
			case err == nil && !u.InGroup(s.cfg.AdminGroup):
				s.sessions.Delete(sess.ID)
				s.audit.Log("session_revoked", false, sess.UserID, s.clientIP(r), "不再属于管理员组")
				clearCookie(w, sessionCookie)
				writeError(w, http.StatusForbidden, "该账户已不是管理员")
				return
			case err != nil:
				// Nextcloud unreachable: keep the session so the panel stays usable for diagnosis.
				slog.Warn("admin recheck failed", "user", sess.UserID, "err", err)
			}
		}
		h(w, r, sess)
	})
}

// authorize verifies fresh credentials: valid and member of the admin group.
func (s *Server) authorize(ctx context.Context, cr *nextcloud.Credentials, ip string) (*nextcloud.User, error) {
	u, err := s.nc.CurrentUser(ctx, cr, ip)
	if err != nil {
		if errors.Is(err, nextcloud.ErrUnauthorized) {
			return nil, &authError{http.StatusUnauthorized, "用户名或应用密码错误（请使用 Nextcloud 应用密码，而不是登录密码）"}
		}
		slog.Warn("nextcloud user check failed", "err", err)
		return nil, &authError{http.StatusBadGateway, "无法连接 Nextcloud，请稍后重试"}
	}
	if !u.InGroup(s.cfg.AdminGroup) {
		return nil, &authError{http.StatusForbidden, "只有 Nextcloud 管理员（admin 组成员）可以登录管理面板"}
	}
	return u, nil
}

// authError carries a user-facing message and the HTTP status to answer with.
type authError struct {
	Status int
	Msg    string
}

func (e *authError) Error() string { return e.Msg }

func (s *Server) revoke(cr *nextcloud.Credentials) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := s.nc.RevokeAppPassword(ctx, cr); err != nil {
		slog.Warn("revoke app password failed", "err", err)
	}
}

func (s *Server) onSessionEnd(sess *auth.Session) {
	if sess.RevokeOnEnd {
		s.revoke(&sess.Creds)
	}
}

// ---------------------------------------------------------------- helpers

// clientIP returns the client address; X-Forwarded-For is honoured only from trusted proxies (Caddy).
func (s *Server) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	addr = addr.Unmap()
	if s.trusted(addr) {
		if xff := r.Header.Values("X-Forwarded-For"); len(xff) > 0 {
			parts := strings.Split(strings.Join(xff, ","), ",")
			// Walk from the right, skipping our own trusted proxies.
			for i := len(parts) - 1; i >= 0; i-- {
				a, err := netip.ParseAddr(strings.TrimSpace(parts[i]))
				if err != nil {
					break
				}
				a = a.Unmap()
				if !s.trusted(a) || i == 0 {
					return a.String()
				}
			}
		}
	}
	return addr.String()
}

func (s *Server) trusted(a netip.Addr) bool {
	for _, p := range s.cfg.TrustedProxies {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// readJSON decodes a small JSON request body strictly.
func readJSON(w http.ResponseWriter, r *http.Request, out any) bool {
	ct, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if ct != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "请求格式必须为 JSON")
		return false
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxJSONBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(out); err != nil {
		writeError(w, http.StatusBadRequest, "请求内容无效")
		return false
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "请求内容无效")
		return false
	}
	return true
}

func setCookie(w http.ResponseWriter, name, value string, maxAge time.Duration) {
	http.SetCookie(w, &http.Cookie{
		Name:     name,
		Value:    value,
		Path:     "/",
		MaxAge:   int(maxAge.Seconds()),
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
	})
}

func clearCookie(w http.ResponseWriter, name string) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, Secure: true,
		SameSite: http.SameSiteStrictMode})
}

// ttlCache caches small computed values for a short time (shared by all admins).
type ttlCache struct {
	mu sync.Mutex
	m  map[string]cacheEntry
}

type cacheEntry struct {
	v   any
	exp time.Time
}

func (c *ttlCache) get(k string) (any, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[k]
	if !ok || time.Now().After(e.exp) {
		return nil, false
	}
	return e.v, true
}

func (c *ttlCache) set(k string, v any, ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.m == nil {
		c.m = map[string]cacheEntry{}
	}
	c.m[k] = cacheEntry{v: v, exp: time.Now().Add(ttl)}
}
