package config

import (
	"net/netip"
	"testing"
	"time"
)

func env(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func TestDefaults(t *testing.T) {
	c, err := FromLookup(env(map[string]string{"HV_HOST": "192.168.1.10"}))
	if err != nil {
		t.Fatal(err)
	}
	if c.PublicURL.String() != "https://192.168.1.10" || c.NCHostHeader != "192.168.1.10" || c.NCInternalURL.String() != "http://app:80" {
		t.Fatalf("urls: %s %s %s", c.PublicURL, c.NCHostHeader, c.NCInternalURL)
	}
	if c.DockerHost != "tcp://socket-proxy:2375" || c.ComposeProject != "homevault" || c.SessionTTL != 12*time.Hour ||
		c.DefaultRetention != 7 || c.AuditLog != "/logs/panel/panel.log" || c.ListenPort() != "8080" || c.AdminGroup != "admin" {
		t.Fatalf("defaults: %+v", c)
	}
	if !c.TrustedProxies[0].Contains(netip.MustParseAddr("172.31.250.5")) {
		t.Fatal("trusted proxy default")
	}
	if len(c.RestartAllowList) != 7 {
		t.Fatal(c.RestartAllowList)
	}
	if len(c.CACertFiles) != 2 || c.CACertFiles[0] != "/ca/root.crt" || c.CACertFiles[1] != "/state/ca.crt" {
		t.Fatalf("ca cert candidates: %v", c.CACertFiles)
	}
	c, err = FromLookup(env(map[string]string{"HV_HOST": "h", "CA_CERT_FILE": "/x/root.crt"}))
	if err != nil || len(c.CACertFiles) != 1 || c.CACertFiles[0] != "/x/root.crt" {
		t.Fatalf("CA_CERT_FILE override: %v %v", c, err)
	}
}

func TestOverrides(t *testing.T) {
	c, err := FromLookup(env(map[string]string{
		"HV_PUBLIC_URL": "https://nas.example.com:8443/", "HV_LOG_RETENTION_DAYS": "30", "SESSION_TTL": "2h",
		"PANEL_TRUSTED_PROXIES": "10.0.0.0/8, 192.168.1.1", "PANEL_RESTART_ALLOW": "app,exec,db", "PANEL_LISTEN": "9000",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if c.Host != "nas.example.com" || c.NCHostHeader != "nas.example.com:8443" || c.DefaultRetention != 30 || c.SessionTTL != 2*time.Hour {
		t.Fatalf("%+v", c)
	}
	if len(c.TrustedProxies) != 2 || !c.TrustedProxies[1].Contains(netip.MustParseAddr("192.168.1.1")) {
		t.Fatal(c.TrustedProxies)
	}
	if len(c.RestartAllowList) != 2 || c.RestartAllowList[0] != "app" || c.RestartAllowList[1] != "db" {
		t.Fatalf("allow list must only narrow: %v", c.RestartAllowList)
	}
	if c.ListenAddr() != ":9000" {
		t.Fatal(c.ListenAddr())
	}
}

func TestInvalid(t *testing.T) {
	bad := []map[string]string{
		{},
		{"HV_HOST": "h", "SESSION_TTL": "1s"},
		{"HV_HOST": "h", "HV_PUBLIC_URL": "ftp://x"},
		{"HV_HOST": "h", "HV_PUBLIC_URL": "https://user:pw@x"},
		{"HV_HOST": "h", "DOCKER_HOST": "ssh://x"},
		{"HV_HOST": "h", "PANEL_TRUSTED_PROXIES": "notacidr"},
	}
	for _, m := range bad {
		if _, err := FromLookup(env(m)); err == nil {
			t.Errorf("accepted %v", m)
		}
	}
}

// HV_LOG_RETENTION_DAYS is only a display fallback: a bad value falls back to 7 with a warning
// instead of crash-looping the panel.
func TestBadRetentionFallsBack(t *testing.T) {
	for _, v := range []string{"0", "366", "7d", "abc"} {
		c, err := FromLookup(env(map[string]string{"HV_HOST": "h", "HV_LOG_RETENTION_DAYS": v}))
		if err != nil || c.DefaultRetention != 7 || len(c.Warnings) != 1 {
			t.Errorf("%q: %v %+v", v, err, c)
		}
	}
}
