// Package diskstat reports disk usage of the stat mounts (/stat/data, /stat/backup,
// /stat/storage/<slug>) and parses storage.conf to label extra storages.
package diskstat

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ErrUnsupported is returned by Statfs on platforms without statfs(2).
var ErrUnsupported = errors.New("diskstat: statfs not supported on this platform")

// Usage is filesystem usage in bytes.
type Usage struct {
	Total uint64 // size of the filesystem
	Free  uint64 // available to unprivileged users
	Used  uint64 // total - free-for-root
	FSID  string // filesystem id ("" if unknown)
	Key   string // identity used to detect "same disk" (fsid or size fingerprint)
}

// Role identifiers and their Chinese labels.
const (
	RoleData    = "data"
	RoleStorage = "storage"
	RoleBackup  = "backup"
)

// RoleLabel maps a role to its display label.
var RoleLabel = map[string]string{RoleData: "主数据", RoleStorage: "扩展存储", RoleBackup: "备份"}

// Disk is one role-labelled mount.
type Disk struct {
	Role      string   `json:"role"`
	RoleLabel string   `json:"role_label"`
	Name      string   `json:"name"`
	Slug      string   `json:"slug,omitempty"`
	HostPath  string   `json:"host_path,omitempty"`
	Access    string   `json:"access,omitempty"` // rw | ro (storages)
	Backup    bool     `json:"backup,omitempty"` // storage included in backups
	Total     uint64   `json:"total"`
	Used      uint64   `json:"used"`
	Free      uint64   `json:"free"`
	UsedPct   float64  `json:"used_pct"`
	FreePct   float64  `json:"free_pct"`
	SameDisk  []string `json:"same_disk,omitempty"` // names of other entries on the same filesystem
	Error     string   `json:"error,omitempty"`
	key       string
}

// StorageEntry is one line of storage.conf: 名称|主机路径|rw或ro|是否备份|可见用户
type StorageEntry struct {
	Name     string
	HostPath string
	Access   string
	Backup   bool
	Users    string
	Slugs    []string // candidate slugs (raw and trimmed host path)
}

// Slug computes the storage slug: "s" + first 8 hex chars of sha256(host path bytes).
func Slug(hostPath string) string {
	h := sha256.Sum256([]byte(hostPath))
	return "s" + hex.EncodeToString(h[:])[:8]
}

var slugRe = regexp.MustCompile(`^s[0-9a-f]{8}$`)

// ParseStorageConf parses storage.conf (UTF-8, optional BOM, '#' comments, '|' separated).
func ParseStorageConf(r io.Reader) ([]StorageEntry, error) {
	var out []StorageEntry
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	first := true
	for sc.Scan() {
		line := sc.Text()
		if first {
			line = strings.TrimPrefix(line, "\uFEFF")
			first = false
		}
		line = strings.TrimRight(line, "\r")
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		f := strings.Split(line, "|")
		if len(f) < 2 {
			continue
		}
		for len(f) < 5 {
			f = append(f, "")
		}
		e := StorageEntry{
			Name:     strings.TrimSpace(f[0]),
			HostPath: strings.TrimSpace(f[1]),
			Access:   strings.ToLower(strings.TrimSpace(f[2])),
			Backup:   strings.EqualFold(strings.TrimSpace(f[3]), "yes"),
			Users:    strings.TrimSpace(f[4]),
		}
		if e.Access != "ro" {
			e.Access = "rw"
		}
		e.Slugs = []string{Slug(e.HostPath)}
		if raw := f[1]; raw != e.HostPath {
			e.Slugs = append(e.Slugs, Slug(raw))
		}
		out = append(out, e)
	}
	return out, sc.Err()
}

// LoadStorageConf reads the first existing file of paths.
func LoadStorageConf(paths []string) []StorageEntry {
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		fi, err := f.Stat()
		if err != nil || !fi.Mode().IsRegular() {
			f.Close()
			continue
		}
		entries, _ := ParseStorageConf(io.LimitReader(f, 1<<20))
		f.Close()
		return entries
	}
	return nil
}

// Collect stats every role mount below statDir.
func Collect(statDir string, conf []StorageEntry) []Disk {
	var disks []Disk
	add := func(role, name, p string) *Disk {
		d := Disk{Role: role, RoleLabel: RoleLabel[role], Name: name}
		u, err := Statfs(p)
		if err != nil {
			d.Error = "无法读取磁盘信息"
		} else {
			d.Total, d.Used, d.Free, d.key = u.Total, u.Used, u.Free, u.Key
			if denom := u.Used + u.Free; denom > 0 {
				d.UsedPct = round1(float64(u.Used) * 100 / float64(denom))
				d.FreePct = round1(100 - d.UsedPct)
			}
		}
		disks = append(disks, d)
		return &disks[len(disks)-1]
	}
	if isDir(filepath.Join(statDir, "data")) {
		add(RoleData, "Nextcloud 数据", filepath.Join(statDir, "data"))
	}
	bySlug := map[string]StorageEntry{}
	for _, e := range conf {
		for _, s := range e.Slugs {
			bySlug[s] = e
		}
	}
	if ents, err := os.ReadDir(filepath.Join(statDir, "storage")); err == nil {
		sort.Slice(ents, func(i, j int) bool { return ents[i].Name() < ents[j].Name() })
		for _, de := range ents {
			slug := de.Name()
			if !slugRe.MatchString(slug) || !isDir(filepath.Join(statDir, "storage", slug)) {
				continue
			}
			name := slug
			e, ok := bySlug[slug]
			if ok && e.Name != "" {
				name = e.Name
			}
			d := add(RoleStorage, name, filepath.Join(statDir, "storage", slug))
			d.Slug = slug
			if ok {
				d.HostPath, d.Access, d.Backup = e.HostPath, e.Access, e.Backup
			}
		}
	}
	if isDir(filepath.Join(statDir, "backup")) {
		add(RoleBackup, "本地备份", filepath.Join(statDir, "backup"))
	}
	// Mark entries living on the same filesystem.
	for i := range disks {
		for j := range disks {
			if i != j && disks[i].key != "" && disks[i].key == disks[j].key {
				disks[i].SameDisk = append(disks[i].SameDisk, disks[j].Name)
			}
		}
	}
	return disks
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func round1(f float64) float64 {
	return float64(int64(f*10+0.5)) / 10
}
