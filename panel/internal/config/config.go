// Package config reads the panel configuration from environment variables.
package config

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds every runtime setting of the panel.
type Config struct {
	Listen string // PANEL_LISTEN, e.g. ":8080"

	Host          string   // HV_HOST (IP or domain clients use)
	PublicURL     *url.URL // HV_PUBLIC_URL: Nextcloud URL as seen by browsers
	NCInternalURL *url.URL // NC_INTERNAL_URL: Nextcloud URL reachable from the panel (http://app:80)
	NCHostHeader  string   // NC_HOST_HEADER: Host header sent to Nextcloud (default: host[:port] of PublicURL)
	AdminGroup    string   // ADMIN_GROUP (default "admin")

	DockerHost     string // DOCKER_HOST: tcp://socket-proxy:2375 or unix:///var/run/docker.sock
	ComposeProject string // COMPOSE_PROJECT (label com.docker.compose.project)

	LogDir      string // LOG_DIR (/logs)
	AuditLog    string // AUDIT_LOG (/logs/panel/panel.log)
	StateDir    string // STATE_DIR (/state)
	StatDir     string // STAT_DIR (/stat)
	StorageConf []string
	CACertFiles []string // CA_CERT_FILE, else /ca/root.crt (ca_public volume) then STATE_DIR/ca.crt
	APKFile     string   // APK_FILE

	SessionTTL        time.Duration // SESSION_TTL (12h)
	RecheckInterval   time.Duration // ADMIN_RECHECK (5m)
	TrustedProxies    []netip.Prefix
	DefaultRetention  int    // HV_LOG_RETENTION_DAYS
	Version           string // HV_VERSION (HomeVault version, informational)
	RestartAllowList  []string
	FlowPollInterval  time.Duration
	FlowLifetime      time.Duration
	MaxPendingFlows   int
	MaxSessions       int
	MaxLogLines       int
	MaxGzipInputBytes int64

	// Warnings are non-fatal configuration problems (logged at startup).
	Warnings []string
}

// DefaultRestartAllowList are the compose services the panel may restart (SPEC §15).
var DefaultRestartAllowList = []string{"app", "cron", "redis", "db", "caddy", "wg-easy", "ddns-go"}

// Load builds a Config from the process environment.
func Load() (*Config, error) { return FromLookup(os.LookupEnv) }

// FromLookup builds a Config from an arbitrary lookup function (used by tests).
func FromLookup(lookup func(string) (string, bool)) (*Config, error) {
	get := func(k, def string) string {
		if v, ok := lookup(k); ok && strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
		return def
	}
	c := &Config{
		Listen:            get("PANEL_LISTEN", ":8080"),
		Host:              get("HV_HOST", ""),
		AdminGroup:        get("ADMIN_GROUP", "admin"),
		DockerHost:        get("DOCKER_HOST", "tcp://socket-proxy:2375"),
		ComposeProject:    get("COMPOSE_PROJECT", get("COMPOSE_PROJECT_NAME", "homevault")),
		LogDir:            get("LOG_DIR", "/logs"),
		StateDir:          get("STATE_DIR", "/state"),
		StatDir:           get("STAT_DIR", "/stat"),
		Version:           get("HV_VERSION", ""),
		FlowPollInterval:  2 * time.Second,
		FlowLifetime:      20 * time.Minute,
		MaxPendingFlows:   50,
		MaxSessions:       100,
		MaxLogLines:       5000,
		MaxGzipInputBytes: 64 << 20,
	}
	c.AuditLog = get("AUDIT_LOG", strings.TrimRight(c.LogDir, "/")+"/panel/panel.log")
	if v := get("CA_CERT_FILE", ""); v != "" {
		c.CACertFiles = []string{v}
	} else {
		c.CACertFiles = []string{"/ca/root.crt", strings.TrimRight(c.StateDir, "/") + "/ca.crt"}
	}
	c.APKFile = get("APK_FILE", strings.TrimRight(c.StateDir, "/")+"/app/homevault.apk")
	c.StorageConf = splitList(get("STORAGE_CONF", "/config/storage.conf,"+strings.TrimRight(c.StateDir, "/")+"/storage.conf"))

	var err error
	pub := get("HV_PUBLIC_URL", "")
	if pub == "" && c.Host != "" {
		pub = "https://" + c.Host
	}
	if pub == "" {
		return nil, errors.New("HV_PUBLIC_URL or HV_HOST must be set")
	}
	if c.PublicURL, err = parseBaseURL(pub); err != nil {
		return nil, fmt.Errorf("HV_PUBLIC_URL: %w", err)
	}
	if c.Host == "" {
		c.Host = c.PublicURL.Hostname()
	}
	if c.NCInternalURL, err = parseBaseURL(get("NC_INTERNAL_URL", "http://app:80")); err != nil {
		return nil, fmt.Errorf("NC_INTERNAL_URL: %w", err)
	}
	c.NCHostHeader = get("NC_HOST_HEADER", c.PublicURL.Host)

	if c.SessionTTL, err = parseDuration(get("SESSION_TTL", "12h"), time.Minute, 7*24*time.Hour); err != nil {
		return nil, fmt.Errorf("SESSION_TTL: %w", err)
	}
	if c.RecheckInterval, err = parseDuration(get("ADMIN_RECHECK", "5m"), 10*time.Second, 24*time.Hour); err != nil {
		return nil, fmt.Errorf("ADMIN_RECHECK: %w", err)
	}

	proxies := get("PANEL_TRUSTED_PROXIES", get("HV_FRONTEND_SUBNET", "172.31.250.0/24"))
	for _, p := range splitList(proxies) {
		pfx, perr := parsePrefix(p)
		if perr != nil {
			return nil, fmt.Errorf("PANEL_TRUSTED_PROXIES: %w", perr)
		}
		c.TrustedProxies = append(c.TrustedProxies, pfx)
	}

	// Only a display fallback (state/status.json wins): a hand-edited bad value must not stop the panel.
	c.DefaultRetention = 7
	if v := get("HV_LOG_RETENTION_DAYS", ""); v != "" {
		n, perr := strconv.Atoi(v)
		if perr != nil || n < 1 || n > 365 {
			c.Warnings = append(c.Warnings, fmt.Sprintf("HV_LOG_RETENTION_DAYS=%q is not an integer 1-365, using 7", v))
		} else {
			c.DefaultRetention = n
		}
	}

	c.RestartAllowList = DefaultRestartAllowList
	if v := get("PANEL_RESTART_ALLOW", ""); v != "" {
		// May only narrow the default list, never widen it.
		var narrowed []string
		for _, s := range splitList(v) {
			for _, d := range DefaultRestartAllowList {
				if s == d {
					narrowed = append(narrowed, s)
				}
			}
		}
		c.RestartAllowList = narrowed
	}

	switch {
	case strings.HasPrefix(c.DockerHost, "tcp://"), strings.HasPrefix(c.DockerHost, "unix://"),
		strings.HasPrefix(c.DockerHost, "http://"):
	default:
		return nil, fmt.Errorf("DOCKER_HOST: unsupported scheme in %q", c.DockerHost)
	}
	if _, _, err := net.SplitHostPort(normalizeListen(c.Listen)); err != nil {
		return nil, fmt.Errorf("PANEL_LISTEN: %w", err)
	}
	return c, nil
}

// ListenPort returns the TCP port the panel listens on (used by the healthcheck).
func (c *Config) ListenPort() string {
	_, port, err := net.SplitHostPort(normalizeListen(c.Listen))
	if err != nil || port == "" {
		return "8080"
	}
	return port
}

// ListenAddr returns Listen normalised to host:port form.
func (c *Config) ListenAddr() string { return normalizeListen(c.Listen) }

func normalizeListen(s string) string {
	if !strings.Contains(s, ":") {
		return ":" + s
	}
	return s
}

func parseBaseURL(s string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimRight(s, "/"))
	if err != nil {
		return nil, err
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("scheme must be http or https: %q", s)
	}
	if u.Host == "" {
		return nil, fmt.Errorf("missing host: %q", s)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, fmt.Errorf("must not contain credentials, query or fragment: %q", s)
	}
	return u, nil
}

func parseDuration(s string, min, max time.Duration) (time.Duration, error) {
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, err
	}
	if d < min || d > max {
		return 0, fmt.Errorf("%s out of range [%s, %s]", d, min, max)
	}
	return d, nil
}

func parsePrefix(s string) (netip.Prefix, error) {
	if strings.Contains(s, "/") {
		p, err := netip.ParsePrefix(s)
		if err != nil {
			return netip.Prefix{}, err
		}
		return p.Masked(), nil
	}
	a, err := netip.ParseAddr(s)
	if err != nil {
		return netip.Prefix{}, err
	}
	return netip.PrefixFrom(a.Unmap(), a.Unmap().BitLen()), nil
}

func splitList(s string) []string {
	var out []string
	for _, f := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' || r == ';' }) {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}
