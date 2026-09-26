package nextcloud

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
)

// Docker Compose copies the client's ~/.docker/config.json "proxies" into every container as
// HTTP_PROXY/HTTPS_PROXY (common in China). The panel must still talk to http://app:80 directly:
// a proxy would break the login and receive the Basic-auth app password in clear text.
func TestIgnoresProxyEnvironment(t *testing.T) {
	if os.Getenv("HV_PROXY_CHILD") == "1" {
		proxyChild(t)
		return
	}
	var mu sync.Mutex
	var seen []string
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.Method+" "+r.URL.String()+" auth="+r.Header.Get("Authorization"))
		mu.Unlock()
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer proxy.Close()
	cmd := exec.Command(os.Args[0], "-test.run=^TestIgnoresProxyEnvironment$", "-test.count=1")
	cmd.Env = append(os.Environ(), "HV_PROXY_CHILD=1", "HTTP_PROXY="+proxy.URL, "http_proxy="+proxy.URL,
		"HTTPS_PROXY="+proxy.URL, "NO_PROXY=", "no_proxy=")
	out, _ := cmd.CombinedOutput()
	mu.Lock()
	defer mu.Unlock()
	if len(seen) > 0 {
		t.Fatalf("requests went through HTTP_PROXY (credentials leaked): %v\n%s", seen, out)
	}
	if !strings.Contains(string(out), "PASS") {
		t.Fatalf("child failed:\n%s", out)
	}
}

func proxyChild(t *testing.T) {
	// A non-loopback host (loopback is never proxied): the dial is redirected to a local server,
	// so the request only reaches "Nextcloud" when it is NOT sent to the proxy.
	nc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ocs":{"meta":{"statuscode":200},"data":{"id":"hvadmin","groups":["admin"]}}}`))
	}))
	defer nc.Close()
	in, _ := url.Parse("http://app:80")
	pub, _ := url.Parse("https://192.168.1.10")
	c := New(in, pub, "192.168.1.10", "HomeVault 管理面板")
	rt := c.HTTP.Transport
	if rt == nil {
		rt = http.DefaultTransport
	}
	tr, ok := rt.(*http.Transport)
	if !ok {
		t.Fatalf("unexpected transport %T", rt)
	}
	addr := strings.TrimPrefix(nc.URL, "http://")
	dial := tr.DialContext
	if dial == nil {
		dial = (&net.Dialer{}).DialContext
	}
	tr.DialContext = func(ctx context.Context, network, a string) (net.Conn, error) {
		if a == "app:80" {
			a = addr
		}
		return dial(ctx, network, a)
	}
	u, err := c.CurrentUser(context.Background(), &Credentials{LoginName: "hvadmin", AppPassword: "SECRET-APP-PASSWORD"}, "")
	if err != nil || u.ID != "hvadmin" {
		t.Fatalf("CurrentUser via direct connection: %v %v", u, err)
	}
}
