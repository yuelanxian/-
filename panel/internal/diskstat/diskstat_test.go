package diskstat

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSlug(t *testing.T) {
	// Reference computed with: printf '%s' 'D:\Photos' | sha256sum | cut -c1-8  → ea173462
	if got := Slug(`D:\Photos`); got != "sea173462" {
		t.Fatalf("slug %q", got)
	}
	if Slug("/srv/a") == Slug("/srv/b") {
		t.Fatal("collision")
	}
	if Slug("/mnt/照片") != Slug("/mnt/照片") {
		t.Fatal("not deterministic")
	}
}

func TestParseStorageConf(t *testing.T) {
	in := "\uFEFF# 名称|主机路径|rw或ro|是否备份(yes/no)|可见用户\r\n" +
		"照片归档|D:\\Photos|rw|no|\r\n" +
		"\r\n" +
		"影视资料|E:\\Movies|ro|YES|@family\r\n" +
		"bad line without separator\n"
	got, err := ParseStorageConf(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("%+v", got)
	}
	if got[0].Name != "照片归档" || got[0].HostPath != `D:\Photos` || got[0].Access != "rw" || got[0].Backup || got[0].Slugs[0] != Slug(`D:\Photos`) {
		t.Fatalf("%+v", got[0])
	}
	if got[1].Access != "ro" || !got[1].Backup || got[1].Users != "@family" {
		t.Fatalf("%+v", got[1])
	}
}

func TestCollect(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("statfs is linux-only")
	}
	stat := t.TempDir()
	slug := Slug("/srv/photos")
	for _, d := range []string{"data", "backup", "storage/" + slug, "storage/notaslug"} {
		if err := os.MkdirAll(filepath.Join(stat, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	disks := Collect(stat, []StorageEntry{{Name: "照片", HostPath: "/srv/photos", Access: "rw", Backup: true, Slugs: []string{slug}}})
	if len(disks) != 3 {
		t.Fatalf("%+v", disks)
	}
	if disks[0].Role != RoleData || disks[1].Role != RoleStorage || disks[1].Name != "照片" || disks[2].Role != RoleBackup {
		t.Fatalf("%+v", disks)
	}
	for _, d := range disks {
		if d.Error != "" || d.Total == 0 || d.UsedPct < 0 || d.UsedPct > 100 {
			t.Fatalf("%+v", d)
		}
		// all on the same tmpfs → each lists the two others
		if len(d.SameDisk) != 2 {
			t.Fatalf("same disk detection: %+v", d)
		}
	}
	if len(Collect(filepath.Join(stat, "missing"), nil)) != 0 {
		t.Fatal("expected no disks")
	}
}
