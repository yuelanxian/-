// Package nextcloud talks to the Nextcloud instance: Login Flow v2, OCS provisioning API,
// serverinfo and app password revocation.
package nextcloud

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

var (
	// ErrPending means the login flow has not been completed yet (poll returned 404).
	ErrPending = errors.New("nextcloud: login flow pending")
	// ErrUnauthorized means Nextcloud rejected the credentials.
	ErrUnauthorized = errors.New("nextcloud: unauthorized")
	// ErrForbidden means the user is authenticated but not allowed.
	ErrForbidden = errors.New("nextcloud: forbidden")
)

const maxBody = 8 << 20

// Client is a small Nextcloud HTTP client. It always connects to the internal URL and
// sends the public Host header so trusted_domains and generated URLs match.
type Client struct {
	Internal   *url.URL
	Public     *url.URL
	HostHeader string
	UserAgent  string
	HTTP       *http.Client
}

// Credentials are a login name plus an app password (device token).
type Credentials struct {
	LoginName   string `json:"loginName"`
	AppPassword string `json:"appPassword"`
}

// Flow is an initiated Login Flow v2.
type Flow struct {
	LoginURL  string // public URL the browser opens
	PollToken string
	PollPath  string // path of the poll endpoint (requested on the internal URL)
}

// Quota as returned by the provisioning API. Quota < 0 means unlimited/unknown.
type Quota struct {
	Free     int64   `json:"free"`
	Used     int64   `json:"used"`
	Total    int64   `json:"total"`
	Relative float64 `json:"relative"`
	Quota    int64   `json:"quota"`
}

// User is the subset of provisioning API user data the panel uses.
type User struct {
	ID          string   `json:"id"`
	DisplayName string   `json:"displayname"`
	Email       string   `json:"email"`
	Groups      []string `json:"groups"`
	Enabled     bool     `json:"enabled"`
	LastLogin   int64    `json:"lastLogin"` // milliseconds since epoch, 0 = never
	Quota       Quota    `json:"quota"`
}

// InGroup reports whether the user is a member of group g.
func (u *User) InGroup(g string) bool {
	for _, x := range u.Groups {
		if x == g {
			return true
		}
	}
	return false
}

// ServerInfo is a small subset of the serverinfo app output.
type ServerInfo struct {
	Version     string `json:"version"`
	NumUsers    int64  `json:"num_users"`
	NumFiles    int64  `json:"num_files"`
	NumStorages int64  `json:"num_storages"`
	DBSize      int64  `json:"db_size"`
	DBType      string `json:"db_type"`
	PHPVersion  string `json:"php_version"`
	Active5Min  int64  `json:"active_5min"`
	Active24h   int64  `json:"active_24h"`
	FreeSpace   int64  `json:"free_space"`
}

// New returns a client with sane timeouts.
func New(internal, public *url.URL, hostHeader, userAgent string) *Client {
	// Own transport WITHOUT proxy: Docker Compose injects the client's configured proxies
	// (HTTP_PROXY/HTTPS_PROXY) into every container, and http.DefaultTransport would send the
	// internal Nextcloud requests — Basic-auth app passwords included — to that proxy.
	tr := &http.Transport{
		Proxy:                 nil,
		MaxIdleConns:          8,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		ForceAttemptHTTP2:     false,
	}
	return &Client{
		Internal:   internal,
		Public:     public,
		HostHeader: hostHeader,
		UserAgent:  userAgent,
		HTTP: &http.Client{
			Transport: tr,
			Timeout:   30 * time.Second,
			// Never follow redirects: a redirect usually means a login page or a misconfiguration.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
}

// StatusError is returned for unexpected HTTP statuses.
type StatusError struct {
	Op     string
	Status int
}

func (e *StatusError) Error() string { return fmt.Sprintf("nextcloud: %s: HTTP %d", e.Op, e.Status) }

func (c *Client) newRequest(ctx context.Context, method, path string, query url.Values, body io.Reader, clientIP string) (*http.Request, error) {
	u := *c.Internal
	u.Path = strings.TrimRight(c.Internal.Path, "/") + path
	u.RawQuery = query.Encode()
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return nil, err
	}
	if c.HostHeader != "" {
		req.Host = c.HostHeader
	}
	req.Header.Set("User-Agent", c.UserAgent)
	req.Header.Set("Accept", "application/json")
	// The panel is a trusted proxy for Nextcloud (same frontend subnet): pass the real
	// client IP so Nextcloud's brute-force protection and audit log see it.
	if clientIP != "" {
		req.Header.Set("X-Forwarded-For", clientIP)
	}
	return req, nil
}

func (c *Client) do(req *http.Request) (*http.Response, []byte, error) {
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxBody+1))
	if err != nil {
		return resp, nil, err
	}
	if len(b) > maxBody {
		return resp, nil, errors.New("nextcloud: response too large")
	}
	return resp, b, nil
}

// StartFlow initiates Login Flow v2 (POST /index.php/login/v2).
func (c *Client) StartFlow(ctx context.Context, clientIP string) (*Flow, error) {
	req, err := c.newRequest(ctx, http.MethodPost, "/index.php/login/v2", nil, nil, clientIP)
	if err != nil {
		return nil, err
	}
	// Nextcloud shows this name on the grant page and uses it as the app password name.
	// Including the requesting IP lets the admin spot a flow started by someone else.
	if clientIP != "" {
		req.Header.Set("User-Agent", c.UserAgent+"（"+clientIP+"）")
	}
	resp, body, err := c.do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, &StatusError{Op: "login flow init", Status: resp.StatusCode}
	}
	var r struct {
		Poll struct {
			Token    string `json:"token"`
			Endpoint string `json:"endpoint"`
		} `json:"poll"`
		Login string `json:"login"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, fmt.Errorf("nextcloud: login flow init: %w", err)
	}
	if r.Poll.Token == "" || r.Poll.Endpoint == "" || r.Login == "" {
		return nil, errors.New("nextcloud: login flow init: incomplete response")
	}
	loginU, err := url.Parse(r.Login)
	if err != nil || !strings.Contains(loginU.Path, "/login/v2/flow/") {
		return nil, errors.New("nextcloud: login flow init: unexpected login URL")
	}
	pollU, err := url.Parse(r.Poll.Endpoint)
	if err != nil || !strings.HasSuffix(pollU.Path, "/login/v2/poll") {
		return nil, errors.New("nextcloud: login flow init: unexpected poll endpoint")
	}
	// Rebase both URLs: the browser uses the public URL, the panel polls internally.
	pub := *c.Public
	pub.Path = strings.TrimRight(c.Public.Path, "/") + stripBase(loginU.Path, c.Internal.Path)
	pub.RawQuery = loginU.RawQuery
	return &Flow{
		LoginURL:  pub.String(),
		PollToken: r.Poll.Token,
		PollPath:  stripBase(pollU.Path, c.Internal.Path),
	}, nil
}

func stripBase(p, base string) string {
	base = strings.TrimRight(base, "/")
	if base != "" && strings.HasPrefix(p, base+"/") {
		return strings.TrimPrefix(p, base)
	}
	return p
}

// PollFlow polls a login flow once. It returns ErrPending until the user granted access.
func (c *Client) PollFlow(ctx context.Context, f *Flow) (*Credentials, error) {
	form := url.Values{"token": {f.PollToken}}
	req, err := c.newRequest(ctx, http.MethodPost, f.PollPath, nil, strings.NewReader(form.Encode()), "")
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, body, err := c.do(req)
	if err != nil {
		return nil, err
	}
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		return nil, ErrPending
	default:
		return nil, &StatusError{Op: "login flow poll", Status: resp.StatusCode}
	}
	var cr Credentials
	if err := json.Unmarshal(body, &cr); err != nil {
		return nil, fmt.Errorf("nextcloud: login flow poll: %w", err)
	}
	if cr.LoginName == "" || cr.AppPassword == "" {
		return nil, errors.New("nextcloud: login flow poll: incomplete credentials")
	}
	return &cr, nil
}

// ocs performs an authenticated OCS v2 call and decodes ocs.data into out.
func (c *Client) ocs(ctx context.Context, method, path string, q url.Values, cr *Credentials, clientIP string, out any) error {
	if q == nil {
		q = url.Values{}
	}
	q.Set("format", "json")
	req, err := c.newRequest(ctx, method, "/ocs/v2.php"+path, q, nil, clientIP)
	if err != nil {
		return err
	}
	req.Header.Set("OCS-APIRequest", "true")
	req.SetBasicAuth(cr.LoginName, cr.AppPassword)
	resp, body, err := c.do(req)
	if err != nil {
		return err
	}
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusUnauthorized:
		return ErrUnauthorized
	case http.StatusForbidden:
		return ErrForbidden
	default:
		return &StatusError{Op: "OCS " + path, Status: resp.StatusCode}
	}
	var env struct {
		OCS struct {
			Meta struct {
				StatusCode int `json:"statuscode"`
			} `json:"meta"`
			Data json.RawMessage `json:"data"`
		} `json:"ocs"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return fmt.Errorf("nextcloud: OCS %s: %w", path, err)
	}
	if out == nil {
		return nil
	}
	return decodeLoose(env.OCS.Data, out)
}

// CurrentUser returns the authenticated user (GET /ocs/v2.php/cloud/user).
func (c *Client) CurrentUser(ctx context.Context, cr *Credentials, clientIP string) (*User, error) {
	var raw map[string]json.RawMessage
	if err := c.ocs(ctx, http.MethodGet, "/cloud/user", nil, cr, clientIP, &raw); err != nil {
		return nil, err
	}
	u := userFromRaw(raw)
	if u.ID == "" {
		return nil, errors.New("nextcloud: current user: missing id")
	}
	return u, nil
}

// UsersDetails lists users with quota/usage (GET /ocs/v2.php/cloud/users/details, admin only).
func (c *Client) UsersDetails(ctx context.Context, cr *Credentials, clientIP string, limit int) ([]User, error) {
	var data struct {
		Users json.RawMessage `json:"users"`
	}
	q := url.Values{"limit": {strconv.Itoa(limit)}, "offset": {"0"}}
	if err := c.ocs(ctx, http.MethodGet, "/cloud/users/details", q, cr, clientIP, &data); err != nil {
		return nil, err
	}
	var users []User
	trimmed := bytes.TrimSpace(data.Users)
	if len(trimmed) == 0 || trimmed[0] == '[' { // PHP empty array
		return users, nil
	}
	var m map[string]map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &m); err != nil {
		return nil, fmt.Errorf("nextcloud: users details: %w", err)
	}
	for id, raw := range m {
		u := userFromRaw(raw)
		if u.ID == "" {
			u.ID = id
		}
		users = append(users, *u)
	}
	return users, nil
}

// ServerInfo fetches statistics from the serverinfo app (admin only). Optional.
func (c *Client) ServerInfo(ctx context.Context, cr *Credentials, clientIP string) (*ServerInfo, error) {
	var d struct {
		Nextcloud struct {
			System struct {
				Version   string  `json:"version"`
				FreeSpace flexInt `json:"freespace"`
			} `json:"system"`
			Storage struct {
				NumUsers    flexInt `json:"num_users"`
				NumFiles    flexInt `json:"num_files"`
				NumStorages flexInt `json:"num_storages"`
			} `json:"storage"`
		} `json:"nextcloud"`
		Server struct {
			PHP struct {
				Version string `json:"version"`
			} `json:"php"`
			Database struct {
				Type string  `json:"type"`
				Size flexInt `json:"size"`
			} `json:"database"`
		} `json:"server"`
		ActiveUsers struct {
			Last5Minutes flexInt `json:"last5minutes"`
			Last24Hours  flexInt `json:"last24hours"`
		} `json:"activeUsers"`
	}
	q := url.Values{"skipApps": {"true"}, "skipUpdate": {"true"}}
	if err := c.ocs(ctx, http.MethodGet, "/apps/serverinfo/api/v1/info", q, cr, clientIP, &d); err != nil {
		return nil, err
	}
	return &ServerInfo{
		Version:     d.Nextcloud.System.Version,
		NumUsers:    int64(d.Nextcloud.Storage.NumUsers),
		NumFiles:    int64(d.Nextcloud.Storage.NumFiles),
		NumStorages: int64(d.Nextcloud.Storage.NumStorages),
		DBSize:      int64(d.Server.Database.Size),
		DBType:      d.Server.Database.Type,
		PHPVersion:  d.Server.PHP.Version,
		Active5Min:  int64(d.ActiveUsers.Last5Minutes),
		Active24h:   int64(d.ActiveUsers.Last24Hours),
		FreeSpace:   int64(d.Nextcloud.System.FreeSpace),
	}, nil
}

// RevokeAppPassword deletes the app password used for authentication
// (DELETE /ocs/v2.php/core/apppassword).
func (c *Client) RevokeAppPassword(ctx context.Context, cr *Credentials) error {
	err := c.ocs(ctx, http.MethodDelete, "/core/apppassword", nil, cr, "", nil)
	if errors.Is(err, ErrUnauthorized) {
		return nil // already gone
	}
	return err
}

// ---------------------------------------------------------------- loose JSON helpers

// flexInt accepts JSON numbers, numeric strings, booleans and null.
type flexInt int64

func (f *flexInt) UnmarshalJSON(b []byte) error {
	*f = 0
	s := strings.TrimSpace(string(b))
	if s == "null" || s == "" || s == "false" {
		return nil
	}
	if s == "true" {
		*f = 1
		return nil
	}
	s = strings.Trim(s, `"`)
	if i, err := strconv.ParseInt(s, 10, 64); err == nil {
		*f = flexInt(i)
		return nil
	}
	if fl, err := strconv.ParseFloat(s, 64); err == nil {
		*f = flexInt(int64(fl))
		return nil
	}
	return nil // non-numeric strings such as "none" → 0
}

func decodeLoose(raw json.RawMessage, out any) error {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	return json.Unmarshal(raw, out)
}

func rawString(m map[string]json.RawMessage, k string) string {
	var s string
	if v, ok := m[k]; ok {
		if err := json.Unmarshal(v, &s); err != nil {
			var n json.Number
			if json.Unmarshal(v, &n) == nil {
				return n.String()
			}
		}
	}
	return s
}

func rawInt(m map[string]json.RawMessage, k string) int64 {
	var f flexInt
	if v, ok := m[k]; ok {
		_ = f.UnmarshalJSON(v)
	}
	return int64(f)
}

func rawFloat(m map[string]json.RawMessage, k string) float64 {
	v, ok := m[k]
	if !ok {
		return 0
	}
	s := strings.Trim(strings.TrimSpace(string(v)), `"`)
	f, _ := strconv.ParseFloat(s, 64)
	return f
}

func userFromRaw(m map[string]json.RawMessage) *User {
	u := &User{
		ID:          rawString(m, "id"),
		DisplayName: rawString(m, "displayname"),
		Email:       rawString(m, "email"),
		LastLogin:   rawInt(m, "lastLogin"),
		Enabled:     true,
	}
	if u.DisplayName == "" {
		u.DisplayName = rawString(m, "display-name")
	}
	if v, ok := m["enabled"]; ok {
		s := strings.Trim(strings.TrimSpace(string(v)), `"`)
		u.Enabled = s == "true" || s == "1"
	}
	if v, ok := m["groups"]; ok {
		var g []string
		if json.Unmarshal(v, &g) != nil {
			var gm map[string]string
			if json.Unmarshal(v, &gm) == nil {
				for _, x := range gm {
					g = append(g, x)
				}
			}
		}
		u.Groups = g
	}
	if v, ok := m["quota"]; ok {
		var q map[string]json.RawMessage
		if json.Unmarshal(v, &q) == nil {
			u.Quota = Quota{
				Free:     rawInt(q, "free"),
				Used:     rawInt(q, "used"),
				Total:    rawInt(q, "total"),
				Relative: rawFloat(q, "relative"),
				Quota:    quotaValue(q["quota"]),
			}
		}
	}
	return u
}

// quotaValue: numbers are bytes (negative = unlimited); "none"/"default"/missing → -3 (unlimited).
func quotaValue(v json.RawMessage) int64 {
	s := strings.Trim(strings.TrimSpace(string(v)), `"`)
	if s == "" || s == "null" || s == "none" || s == "default" {
		return -3
	}
	if i, err := strconv.ParseInt(s, 10, 64); err == nil {
		return i
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return int64(f)
	}
	return -3
}
