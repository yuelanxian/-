package nextcloud

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func newTestClient(t *testing.T, h http.HandlerFunc) *Client {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	in, _ := url.Parse(srv.URL)
	pub, _ := url.Parse("https://192.168.1.10:8443")
	return New(in, pub, "192.168.1.10:8443", "HomeVault 管理面板")
}

func TestStartAndPollFlow(t *testing.T) {
	polls := 0
	c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Host != "192.168.1.10:8443" {
			t.Errorf("Host = %q", r.Host)
		}
		switch r.URL.Path {
		case "/index.php/login/v2":
			if r.Method != http.MethodPost || r.Header.Get("User-Agent") != "HomeVault 管理面板（10.99.77.2）" || r.Header.Get("X-Forwarded-For") != "10.99.77.2" {
				t.Errorf("init: method=%s ua=%q xff=%q", r.Method, r.Header.Get("User-Agent"), r.Header.Get("X-Forwarded-For"))
			}
			_, _ = w.Write([]byte(`{"poll":{"token":"POLLTOKEN","endpoint":"https://192.168.1.10:8443/login/v2/poll"},"login":"https://192.168.1.10:8443/login/v2/flow/LOGINTOKEN"}`))
		case "/login/v2/poll":
			_ = r.ParseForm()
			if r.PostForm.Get("token") != "POLLTOKEN" {
				t.Errorf("poll token %q", r.PostForm.Get("token"))
			}
			polls++
			if polls < 2 {
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte("[]"))
				return
			}
			_, _ = w.Write([]byte(`{"server":"https://192.168.1.10:8443","loginName":"hvadmin","appPassword":"APP-PASS"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	ctx := context.Background()
	f, err := c.StartFlow(ctx, "10.99.77.2")
	if err != nil {
		t.Fatal(err)
	}
	if f.LoginURL != "https://192.168.1.10:8443/login/v2/flow/LOGINTOKEN" || f.PollPath != "/login/v2/poll" || f.PollToken != "POLLTOKEN" {
		t.Fatalf("flow = %+v", f)
	}
	if _, err := c.PollFlow(ctx, f); !errors.Is(err, ErrPending) {
		t.Fatalf("first poll: %v", err)
	}
	cr, err := c.PollFlow(ctx, f)
	if err != nil || cr.LoginName != "hvadmin" || cr.AppPassword != "APP-PASS" {
		t.Fatalf("second poll: %+v %v", cr, err)
	}
}

func TestStartFlowRejectsUnexpectedURLs(t *testing.T) {
	c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"poll":{"token":"x","endpoint":"https://evil/steal"},"login":"https://evil/phish"}`))
	})
	if _, err := c.StartFlow(context.Background(), ""); err == nil {
		t.Fatal("unexpected URLs accepted")
	}
}

func TestOCS(t *testing.T) {
	var deleted bool
	c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || u != "hvadmin" || p != "APP-PASS" || r.Header.Get("OCS-APIRequest") != "true" || r.URL.Query().Get("format") != "json" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"ocs":{"meta":{"statuscode":997},"data":[]}}`))
			return
		}
		switch r.Method + " " + r.URL.Path {
		case "GET /ocs/v2.php/cloud/user":
			_, _ = w.Write([]byte(`{"ocs":{"meta":{"status":"ok","statuscode":200},"data":{"id":"hvadmin","displayname":"管理员","groups":["admin","family"],"enabled":true,"quota":{"free":100,"used":"50","total":150,"relative":33.3,"quota":-3}}}}`))
		case "GET /ocs/v2.php/cloud/users/details":
			if r.URL.Query().Get("limit") != "500" {
				t.Errorf("limit %s", r.URL.RawQuery)
			}
			_, _ = w.Write([]byte(`{"ocs":{"meta":{"statuscode":200},"data":{"users":{"hvadmin":{"id":"hvadmin","displayname":"A","groups":["admin"],"quota":{"used":10,"quota":"none"},"lastLogin":1790000000000},"mom":{"id":"mom","enabled":false,"quota":{"used":5000,"free":5000,"quota":10000,"relative":50}}},"groups":[]}}}`))
		case "GET /ocs/v2.php/apps/serverinfo/api/v1/info":
			_, _ = w.Write([]byte(`{"ocs":{"meta":{"statuscode":200},"data":{"nextcloud":{"system":{"version":"34.0.4.1","freespace":12345},"storage":{"num_users":2,"num_files":"1000","num_storages":3}},"server":{"php":{"version":"8.3"},"database":{"type":"pgsql","size":"2048"}},"activeUsers":{"last5minutes":1,"last24hours":2}}}}`))
		case "DELETE /ocs/v2.php/core/apppassword":
			deleted = true
			_, _ = w.Write([]byte(`{"ocs":{"meta":{"statuscode":200},"data":[]}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	ctx := context.Background()
	cr := &Credentials{LoginName: "hvadmin", AppPassword: "APP-PASS"}
	u, err := c.CurrentUser(ctx, cr, "")
	if err != nil || u.ID != "hvadmin" || !u.InGroup("admin") || u.InGroup("adm") || u.Quota.Used != 50 || u.Quota.Quota != -3 {
		t.Fatalf("user %+v %v", u, err)
	}
	if _, err := c.CurrentUser(ctx, &Credentials{LoginName: "hvadmin", AppPassword: "wrong"}, ""); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("want ErrUnauthorized, got %v", err)
	}
	users, err := c.UsersDetails(ctx, cr, "", 500)
	if err != nil || len(users) != 2 {
		t.Fatalf("users %+v %v", users, err)
	}
	for _, x := range users {
		if x.ID == "mom" && (x.Enabled || x.Quota.Quota != 10000 || x.Quota.Used != 5000) {
			t.Fatalf("mom %+v", x)
		}
		if x.ID == "hvadmin" && (x.Quota.Quota != -3 || x.LastLogin != 1790000000000) {
			t.Fatalf("hvadmin %+v", x)
		}
	}
	si, err := c.ServerInfo(ctx, cr, "")
	if err != nil || si.Version != "34.0.4.1" || si.NumFiles != 1000 || si.DBSize != 2048 || si.Active24h != 2 {
		t.Fatalf("serverinfo %+v %v", si, err)
	}
	if err := c.RevokeAppPassword(ctx, cr); err != nil || !deleted {
		t.Fatalf("revoke: %v deleted=%v", err, deleted)
	}
}

func TestUsersDetailsEmptyArray(t *testing.T) {
	c := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"ocs":{"meta":{"statuscode":200},"data":{"users":[],"groups":[]}}}`))
	})
	users, err := c.UsersDetails(context.Background(), &Credentials{LoginName: "a", AppPassword: "b"}, "", 10)
	if err != nil || len(users) != 0 {
		t.Fatalf("%v %v", users, err)
	}
}
