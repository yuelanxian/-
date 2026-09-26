package hoststate

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestSubmitAtomicAndPerms(t *testing.T) {
	dir := t.TempDir()
	s := New(dir)
	s.Now = func() time.Time { return time.Date(2026, 9, 26, 10, 15, 0, 123e6, time.UTC) }
	req, dup, err := s.Submit(TypeLogRetention, 14, "hvadmin", "10.99.77.2")
	if err != nil || dup {
		t.Fatal(err, dup)
	}
	if req.ID != "20260926T101500123Z-log-retention" {
		t.Fatalf("id = %s", req.ID)
	}
	p := filepath.Join(dir, "requests", req.ID+".json")
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o640 {
		t.Fatalf("perm = %v", fi.Mode().Perm())
	}
	var got map[string]any
	b, _ := os.ReadFile(p)
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got["type"] != "log-retention" || got["days"] != float64(14) || got["requested_by"] != "hvadmin" || got["id"] != req.ID {
		t.Fatalf("content = %s", b)
	}
	ents, _ := os.ReadDir(filepath.Join(dir, "requests"))
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), ".tmp-") {
			t.Fatal("temp file left behind")
		}
	}
	// same millisecond → unique id
	req2, _, err := s.Submit(TypeLogRetention, 30, "hvadmin", "")
	if err != nil || req2.ID == req.ID {
		t.Fatalf("second id %v %v", req2, err)
	}
	if !regexp.MustCompile(`^\d{8}T\d{9}Z-log-retention$`).MatchString(req2.ID) {
		t.Fatalf("id format %s", req2.ID)
	}
}

func TestSubmitValidationAndDedupe(t *testing.T) {
	s := New(t.TempDir())
	for _, d := range []int{0, -1, 366, 100000} {
		if _, _, err := s.Submit(TypeLogRetention, d, "u", ""); !errors.Is(err, ErrDays) {
			t.Errorf("days %d: %v", d, err)
		}
	}
	if _, _, err := s.Submit("exec", 0, "u", ""); !errors.Is(err, ErrType) {
		t.Fatal("unknown type accepted")
	}
	if _, _, err := s.Submit("../../x", 0, "u", ""); !errors.Is(err, ErrType) {
		t.Fatal("traversal type accepted")
	}
	a, dup, err := s.Submit(TypeBackup, 0, "u", "")
	if err != nil || dup {
		t.Fatal(err)
	}
	b, dup, err := s.Submit(TypeBackup, 0, "u", "")
	if err != nil || !dup || b.ID != a.ID {
		t.Fatalf("dedupe failed: %v %v %v", b, dup, err)
	}
	pending, done := s.Requests(10)
	if len(pending) != 1 || pending[0].State != "pending" || len(done) != 0 {
		t.Fatalf("pending=%v done=%v", pending, done)
	}
	// host processes it
	must(t, os.MkdirAll(filepath.Join(s.Dir, "requests", "done"), 0o755))
	must(t, os.Rename(filepath.Join(s.Dir, "requests", a.ID+".json"), filepath.Join(s.Dir, "requests", "done", a.ID+".json")))
	must(t, os.WriteFile(filepath.Join(s.Dir, "requests", "done", "20260101T000000000Z-log-clean.json"),
		[]byte("\xef\xbb\xbf{\"id\":\"x\",\"type\":\"log-clean\",\"status\":\"ok\",\"finished\":\"2026-01-01 00:01:00\",\"message\":\"删除 3 个文件\"}"), 0o644))
	pending, done = s.Requests(10)
	if len(pending) != 0 || len(done) != 2 || done[0].Type != "backup" || done[1].State != "ok" || done[1].Finished == nil {
		t.Fatalf("pending=%v done=%+v", pending, done)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestFlexTime(t *testing.T) {
	cases := map[string]bool{
		`"2026-09-26T10:00:00+08:00"`: true, `"2026-09-26T02:00:00Z"`: true, `"2026-09-26 10:00:00"`: true,
		`1790000000`: true, `1790000000000`: true, `"1790000000"`: true, `null`: false, `""`: false, `0`: false, `"garbage"`: false,
	}
	for in, ok := range cases {
		var ft FlexTime
		if err := json.Unmarshal([]byte(in), &ft); err != nil {
			t.Fatalf("%s: %v", in, err)
		}
		if ft.IsZero() == ok {
			t.Errorf("%s: zero=%v", in, ft.IsZero())
		}
	}
	b, _ := json.Marshal(FlexTime{})
	if string(b) != "null" {
		t.Fatal(string(b))
	}
}

func TestVPNStatusSanitized(t *testing.T) {
	in := `{"updated":"2026-09-26T10:00:00Z","interface":"wg0","listen_port":"51820","peers":[
	 {"name":"手机","ip":"10.99.77.2","public_key":"PUBKEY","preshared_key":"PSK","private_key":"PRIV","latest_handshake":1790000000,"transfer_rx":"123","transfer_tx":456,"endpoint":"1.2.3.4:5555","enabled":true},
	 {"client":"平板","allowed_ips":["10.99.77.3/32"],"last_handshake":0,"enabled":"false","endpoint":"(none)"}]}`
	var v VPNStatus
	if err := json.Unmarshal([]byte(in), &v); err != nil {
		t.Fatal(err)
	}
	out, _ := json.Marshal(v)
	s := string(out)
	for _, secret := range []string{"PUBKEY", "PSK", "PRIV", "key"} {
		if strings.Contains(s, secret) {
			t.Fatalf("key material leaked: %s", s)
		}
	}
	if len(v.Peers) != 2 || v.Peers[0].RxBytes != 123 || v.Peers[0].TxBytes != 456 || v.Peers[0].LatestHandshake.IsZero() ||
		v.Peers[1].Name != "平板" || v.Peers[1].Address != "10.99.77.3/32" || v.Peers[1].Enabled || v.Peers[1].Endpoint != "" || v.ListenPort != 51820 {
		t.Fatalf("parsed %+v", v)
	}
}

func TestReadJSONRejectsNames(t *testing.T) {
	s := New(t.TempDir())
	var x any
	for _, n := range []string{"../etc/passwd", "a/b.json", ".hidden"} {
		if _, err := s.ReadJSON(n, &x); err == nil {
			t.Errorf("%s accepted", n)
		}
	}
	if _, err := s.ReadJSON("status.json", &x); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing file: %v", err)
	}
}
