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
	// the host is running the backup (moved to done/, no result yet): pressing again must not queue a second one
	c, dup, err := s.Submit(TypeBackup, 0, "u", "")
	if err != nil || !dup || c.ID != a.ID {
		t.Fatalf("running backup not deduplicated: %v %v %v", c, dup, err)
	}
	if pending, _ = s.Requests(10); len(pending) != 0 {
		t.Fatalf("second backup queued: %v", pending)
	}
	// finished → a new request is accepted
	must(t, os.WriteFile(filepath.Join(s.Dir, "requests", "done", a.ID+".result.json"), []byte(`{"ok":true}`), 0o644))
	d, dup, err := s.Submit(TypeBackup, 0, "u", "")
	if err != nil || dup || d.ID == a.ID {
		t.Fatalf("new backup after completion: %v %v %v", d, dup, err)
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

func TestStatusAndBackupAliases(t *testing.T) {
	// Canonical names win; older spellings are accepted as a fallback.
	var st Status
	if err := json.Unmarshal([]byte(`{"generated":"2026-09-26T03:00:00+08:00","homevault_version":"1.0.0","platform":"linux",`+
		`"log_retention_days":14,"disks":[{"role":"主数据","name":"Nextcloud 数据","path":"/srv/hv/data","total":1000,"free":100,"mounted":true}]}`), &st); err != nil {
		t.Fatal(err)
	}
	if st.Updated.IsZero() || st.Version != "1.0.0" || st.LogRetentionDays != 14 || len(st.Disks) != 1 || st.Disks[0].Total != 1000 {
		t.Fatalf("%+v", st)
	}
	var canon Status
	_ = json.Unmarshal([]byte(`{"updated":"2026-09-26T01:00:00Z","generated":"2020-01-01T00:00:00Z","version":"a","homevault_version":"b"}`), &canon)
	if canon.Version != "a" || canon.Updated.Year() != 2026 {
		t.Fatalf("canonical must win: %+v", canon)
	}

	var bs BackupStatus
	if err := json.Unmarshal([]byte(`{"last_run":"2026-09-26T03:30:00+08:00","finished":"2026-09-26T03:40:00+08:00","result":"partial",`+
		`"exit_code":3,"message":"部分文件无法读取","last_ok":"2026-09-25T03:40:00+08:00","target":"local","log":"backup/backup-20260926-033000.log"}`), &bs); err != nil {
		t.Fatal(err)
	}
	if bs.State != "partial" || bs.LastFinished.IsZero() || bs.LastSuccess.Day() != 25 || bs.LogFile != "backup/backup-20260926-033000.log" ||
		bs.ExitCode == nil || *bs.ExitCode != 3 {
		t.Fatalf("%+v", bs)
	}
	var bc BackupStatus
	_ = json.Unmarshal([]byte(`{"state":"OK","result":"failed","last_success":"2026-09-26T00:00:00Z"}`), &bc)
	if bc.State != "ok" || bc.LastSuccess.IsZero() {
		t.Fatalf("%+v", bc)
	}

	var vs VPNStatus
	_ = json.Unmarshal([]byte(`{"generated":"2026-09-26T03:00:00+08:00","interface":"wg0","peers":[{"name":"p","address":"10.99.77.2/32","latest_handshake":0}]}`), &vs)
	if vs.Updated.IsZero() || len(vs.Peers) != 1 || vs.Peers[0].Address != "10.99.77.2/32" {
		t.Fatalf("%+v", vs)
	}
}

func TestDoneResultsMerged(t *testing.T) {
	dir := t.TempDir()
	s := New(dir)
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	done := filepath.Join(dir, "requests", "done")
	if err := os.MkdirAll(done, 0o755); err != nil {
		t.Fatal(err)
	}
	w := func(name, body string) {
		if err := os.WriteFile(filepath.Join(done, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Linux runner: request moved to done/ + <id>.result.json
	w("20260926T100000000Z-backup.json", `{"id":"20260926T100000000Z-backup","type":"backup","created":"2026-09-26T10:00:00Z","requested_by":"hvadmin"}`)
	w("20260926T100000000Z-backup.result.json", `{"request":"20260926T100000000Z-backup.json","type":"backup","ok":false,"finished":"2026-09-26T10:05:00+00:00","message":"失败（退出码 1），详见日志"}`)
	w("20260926T110000000Z-log-retention.json", `{"id":"20260926T110000000Z-log-retention","type":"log-retention","days":30,"created":"2026-09-26T11:00:00Z"}`)
	w("20260926T110000000Z-log-retention.result.json", `{"request":"20260926T110000000Z-log-retention.json","type":"log-retention","ok":true,"finished":"2026-09-26T11:00:30Z","message":"完成"}`)
	// moved but no result yet → running; very old → unknown
	w("20260926T115900000Z-log-clean.json", `{"id":"20260926T115900000Z-log-clean","type":"log-clean","created":"2026-09-26T11:59:00Z"}`)
	w("20260925T000000000Z-log-clean.json", `{"id":"20260925T000000000Z-log-clean","type":"log-clean","created":"2026-09-25T00:00:00Z"}`)
	// Windows-style: status written into the request file itself (with BOM)
	w("20260926T090000000Z-backup.json", "\xef\xbb\xbf"+`{"id":"20260926T090000000Z-backup","type":"backup","status":"ok","finished_at":"2026-09-26T09:10:00Z"}`)
	// rejected unknown request
	w("bogus.json", `{"type":"exec"}`)
	w("bogus.result.json", `{"request":"bogus.json","type":"unknown","ok":false,"message":"请求无效或类型不在允许列表中"}`)

	_, got := s.Requests(50)
	byID := map[string]RequestStatus{}
	for _, r := range got {
		byID[r.ID] = r
	}
	if len(got) != 6 {
		t.Fatalf("want 6 merged entries, got %d: %+v", len(got), got)
	}
	if r := byID["20260926T100000000Z-backup"]; r.State != "failed" || r.Finished == nil || r.Message == "" || r.RequestedBy != "hvadmin" {
		t.Fatalf("backup: %+v", r)
	}
	if r := byID["20260926T110000000Z-log-retention"]; r.State != "ok" || r.Days != 30 {
		t.Fatalf("retention: %+v", r)
	}
	if r := byID["20260926T115900000Z-log-clean"]; r.State != "running" {
		t.Fatalf("running: %+v", r)
	}
	if r := byID["20260925T000000000Z-log-clean"]; r.State != "unknown" {
		t.Fatalf("stale: %+v", r)
	}
	if r := byID["20260926T090000000Z-backup"]; r.State != "ok" || r.Finished == nil {
		t.Fatalf("inline status: %+v", r)
	}
	if r := byID["bogus"]; r.State != "failed" || r.Type != "exec" {
		t.Fatalf("bogus: %+v", r)
	}
	// newest first
	if got[0].ID != "bogus" && got[0].ID != "20260926T115900000Z-log-clean" {
		t.Fatalf("order: %v", got[0].ID)
	}
	// result files are never listed as pending requests
	pdir := filepath.Join(dir, "requests")
	_ = os.WriteFile(filepath.Join(pdir, "x.result.json"), []byte(`{"ok":true}`), 0o644)
	if p, _ := s.Requests(0); len(p) != 0 {
		t.Fatalf("pending %+v", p)
	}
}

// A request in done/ without "created" and without a result must not look "running" forever
// (that would also block every new backup request through the dedupe).
func TestRunningWithoutCreatedGoesStale(t *testing.T) {
	s := New(t.TempDir())
	done := filepath.Join(s.Dir, "requests", "done")
	must(t, os.MkdirAll(done, 0o755))
	f := filepath.Join(done, "20260101T000000000Z-backup.json")
	must(t, os.WriteFile(f, []byte(`{"type":"backup"}`), 0o644))
	old := time.Now().Add(-7 * time.Hour)
	must(t, os.Chtimes(f, old, old))
	_, list := s.Requests(10)
	if len(list) != 1 || list[0].State != "unknown" {
		t.Fatalf("done = %+v", list)
	}
	if _, dup, err := s.Submit(TypeBackup, 0, "u", ""); err != nil || dup {
		t.Fatalf("new backup blocked by a stale entry: dup=%v err=%v", dup, err)
	}
}

func TestBackupRepositoryCredentialsStripped(t *testing.T) {
	for in, want := range map[string]string{
		"s3:https://AKID:SECRET@oss-cn-hangzhou.aliyuncs.com/bucket/hv": "s3:https://oss-cn-hangzhou.aliyuncs.com/bucket/hv",
		"s3:https://oss-cn-hangzhou.aliyuncs.com/bucket/a@b":            "s3:https://oss-cn-hangzhou.aliyuncs.com/bucket/a@b",
		"/mnt/backup/restic":    "/mnt/backup/restic",
		"D:\\HomeVault\\backup": "D:\\HomeVault\\backup",
	} {
		var bs BackupStatus
		b, _ := json.Marshal(map[string]string{"repository": in})
		if err := json.Unmarshal(b, &bs); err != nil || bs.Repository != want {
			t.Errorf("%q → %q (%v)", in, bs.Repository, err)
		}
	}
}
