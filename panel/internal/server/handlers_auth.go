package server

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"homevault/panel/internal/auth"
	"homevault/panel/internal/nextcloud"
)

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte("ok\n"))
}

// handleInfo is public: lets the Android app validate that a URL points to a HomeVault panel.
func (s *Server) handleInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"app":           "homevault-panel",
		"name":          "HomeVault 管理面板",
		"version":       s.version,
		"nextcloud_url": s.cfg.PublicURL.String(),
		"login":         "nextcloud-login-flow-v2",
	})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	sess := s.sessionFrom(r)
	if sess == nil {
		writeJSON(w, http.StatusOK, map[string]any{"authenticated": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"authenticated": true,
		"user":          sess.UserID,
		"display_name":  sess.DisplayName,
		"csrf":          sess.CSRF,
		"expires":       sess.Expires.Format(time.RFC3339),
		"method":        sess.Method,
	})
}

func (s *Server) handleFlowStart(w http.ResponseWriter, r *http.Request) {
	ip := s.clientIP(r)
	if !s.flowLimiter.Allow(ip) {
		tooMany(w, s.flowLimiter.RetryAfter(ip))
		s.audit.Log("login_flow_start", false, "", ip, "rate limited")
		return
	}
	// A new start from the same browser supersedes its previous flow (stops polling, frees the slot).
	if c, err := r.Cookie(flowCookie); err == nil && c.Value != "" {
		s.flows.Cancel(c.Value)
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	p, err := s.flows.Start(ctx, ip)
	if err != nil {
		if errors.Is(err, auth.ErrTooManyFlows) {
			writeError(w, http.StatusServiceUnavailable, "当前等待中的登录过多，请稍后再试")
			return
		}
		slog.Warn("login flow start failed", "err", err)
		writeError(w, http.StatusBadGateway, "无法连接 Nextcloud，请确认 Nextcloud 正在运行")
		return
	}
	setCookie(w, flowCookie, p.ID, s.cfg.FlowLifetime)
	s.audit.Log("login_flow_start", true, "", ip, "")
	writeJSON(w, http.StatusOK, map[string]any{"login_url": p.LoginURL, "expires_in": int(s.cfg.FlowLifetime.Seconds())})
}

// handleFlowPoll reports the flow state; when the user completed the Nextcloud login it creates the session.
func (s *Server) handleFlowPoll(w http.ResponseWriter, r *http.Request) {
	c, err := r.Cookie(flowCookie)
	if err != nil || c.Value == "" {
		writeJSON(w, http.StatusOK, map[string]any{"state": "none"})
		return
	}
	p := s.flows.Get(c.Value)
	if p == nil {
		clearCookie(w, flowCookie)
		writeJSON(w, http.StatusOK, map[string]any{"state": "none"})
		return
	}
	st, msg := p.State()
	switch st {
	case auth.FlowPending:
		writeJSON(w, http.StatusOK, map[string]any{"state": "pending", "login_url": p.LoginURL})
	case auth.FlowFailed:
		clearCookie(w, flowCookie)
		s.flows.Cancel(c.Value)
		s.audit.Log("login", false, "", s.clientIP(r), "login flow: "+msg)
		writeJSON(w, http.StatusOK, map[string]any{"state": "failed", "message": msg})
	case auth.FlowDone:
		cr, u, ok := s.flows.Take(c.Value)
		clearCookie(w, flowCookie)
		if !ok {
			writeJSON(w, http.StatusOK, map[string]any{"state": "none"})
			return
		}
		sess := s.sessions.Create(u.ID, u.DisplayName, *cr, true, "flow", s.clientIP(r))
		setCookie(w, sessionCookie, sess.ID, s.cfg.SessionTTL)
		s.audit.Log("login", true, u.ID, s.clientIP(r), "Nextcloud Login Flow v2")
		writeJSON(w, http.StatusOK, map[string]any{"state": "ok", "user": u.ID, "display_name": u.DisplayName,
			"csrf": sess.CSRF})
	}
}

func (s *Server) handleFlowCancel(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(flowCookie); err == nil {
		s.flows.Cancel(c.Value)
	}
	clearCookie(w, flowCookie)
	writeJSON(w, http.StatusOK, map[string]any{"state": "none"})
}

// handlePasswordLogin is the fallback: Nextcloud login name + app password.
func (s *Server) handlePasswordLogin(w http.ResponseWriter, r *http.Request) {
	ip := s.clientIP(r)
	if d := s.pwFailLimiter.RetryAfter(ip); d > 0 {
		tooMany(w, d)
		return
	}
	if d := s.pwGlobal.RetryAfter("*"); d > 0 {
		tooMany(w, d)
		return
	}
	var req struct {
		User        string `json:"user"`
		AppPassword string `json:"app_password"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	req.User = strings.TrimSpace(req.User)
	req.AppPassword = strings.TrimSpace(req.AppPassword)
	if req.User == "" || req.AppPassword == "" || len(req.User) > 256 || len(req.AppPassword) > 512 {
		writeError(w, http.StatusBadRequest, "请输入用户名和应用密码")
		return
	}
	// Reserve the attempt BEFORE asking Nextcloud: otherwise parallel requests all pass the
	// check above while the first ones are still in flight. A successful login gives it back.
	if !s.pwFailLimiter.Allow(ip) {
		tooMany(w, s.pwFailLimiter.RetryAfter(ip))
		return
	}
	if !s.pwGlobal.Allow("*") {
		s.pwFailLimiter.Undo(ip)
		tooMany(w, s.pwGlobal.RetryAfter("*"))
		return
	}
	cr := nextcloud.Credentials{LoginName: req.User, AppPassword: req.AppPassword}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	u, err := s.authorize(ctx, &cr, ip)
	if err != nil {
		s.audit.Log("login", false, req.User, ip, "app password: "+err.Error())
		status := http.StatusUnauthorized
		var ae *authError
		if errors.As(err, &ae) {
			status = ae.Status
		}
		writeError(w, status, err.Error())
		return
	}
	s.pwFailLimiter.Reset(ip)
	s.pwGlobal.Undo("*")
	// A user-supplied app password is not revoked on logout (it may be used elsewhere).
	sess := s.sessions.Create(u.ID, u.DisplayName, cr, false, "app-password", ip)
	setCookie(w, sessionCookie, sess.ID, s.cfg.SessionTTL)
	s.audit.Log("login", true, u.ID, ip, "app password")
	writeJSON(w, http.StatusOK, map[string]any{"state": "ok", "user": u.ID, "display_name": u.DisplayName, "csrf": sess.CSRF})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	s.sessions.Delete(sess.ID) // OnEnd revokes the app password created by Login Flow v2
	clearCookie(w, sessionCookie)
	s.audit.Log("logout", true, sess.UserID, s.clientIP(r), "")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func tooMany(w http.ResponseWriter, d time.Duration) {
	secs := int(math.Ceil(d.Seconds()))
	if secs < 1 {
		secs = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(secs))
	mins := (secs + 59) / 60
	writeError(w, http.StatusTooManyRequests, "尝试次数过多，请 "+strconv.Itoa(mins)+" 分钟后再试")
}
