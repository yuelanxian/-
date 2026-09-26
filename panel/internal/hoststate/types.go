package hoststate

import (
	"encoding/json"
	"strconv"
	"strings"
)

// Canonical host → panel status files. The json tags below are the CANONICAL field names that
// scripts/ (Linux) and windows/lib/ (Windows) must emit. For robustness the decoders also accept
// a few older spellings (listed in each UnmarshalJSON); writers must not rely on them.

// Status is state/status.json (written by `hv maintenance` / `hv.ps1 maintenance`).
type Status struct {
	Updated          FlexTime `json:"updated"`
	Version          string   `json:"version"`
	Platform         string   `json:"platform"`
	Hostname         string   `json:"hostname"`
	LogRetentionDays int      `json:"log_retention_days"`
	LogDir           string   `json:"log_dir"`
	Maintenance      struct {
		LastRun FlexTime `json:"last_run"`
		OK      *bool    `json:"ok"`
		Message string   `json:"message"`
	} `json:"maintenance"`
	Requests struct {
		LastRun FlexTime `json:"last_run"`
	} `json:"requests"`
	// Disks is optional: host-side disk usage, used by the panel only when no /stat mounts exist.
	Disks []HostDisk `json:"disks,omitempty"`
}

// HostDisk is one entry of Status.Disks (sizes in bytes).
type HostDisk struct {
	Role    string `json:"role"` // data | storage | backup | system (Chinese labels 主数据/扩展存储/备份/系统数据 accepted)
	Name    string `json:"name"`
	Path    string `json:"path"`
	Total   int64  `json:"total"`
	Free    int64  `json:"free"`
	Mounted *bool  `json:"mounted,omitempty"`
}

// UnmarshalJSON decodes the canonical shape and accepts the aliases generated/updated_at (updated)
// and homevault_version (version).
func (s *Status) UnmarshalJSON(b []byte) error {
	type plain Status
	var p plain
	if err := json.Unmarshal(b, &p); err != nil {
		return err
	}
	var alt struct {
		Generated FlexTime `json:"generated"`
		UpdatedAt FlexTime `json:"updated_at"`
		HVVersion string   `json:"homevault_version"`
	}
	_ = json.Unmarshal(b, &alt)
	if p.Updated.IsZero() {
		p.Updated = firstTime(alt.Generated, alt.UpdatedAt)
	}
	if p.Version == "" {
		p.Version = alt.HVVersion
	}
	*s = Status(p)
	return nil
}

// BackupStats are restic summary numbers of the last backup.
type BackupStats struct {
	FilesNew            int64 `json:"files_new"`
	FilesChanged        int64 `json:"files_changed"`
	DataAdded           int64 `json:"data_added"`
	TotalFilesProcessed int64 `json:"total_files_processed"`
	TotalBytesProcessed int64 `json:"total_bytes_processed"`
}

// BackupStatus is state/backup-status.json (written by `hv backup`).
type BackupStatus struct {
	Updated         FlexTime     `json:"updated"`
	State           string       `json:"state"` // ok | failed | partial | running | never
	LastRun         FlexTime     `json:"last_run"`
	LastFinished    FlexTime     `json:"last_finished"`
	LastSuccess     FlexTime     `json:"last_success"`
	DurationSeconds float64      `json:"duration_seconds"`
	Message         string       `json:"message"`
	LogFile         string       `json:"log_file"`
	Target          string       `json:"target"`
	Repository      string       `json:"repository"`
	Schedule        string       `json:"schedule"`
	NextRun         FlexTime     `json:"next_run"`
	ExitCode        *int         `json:"exit_code,omitempty"`
	Stats           *BackupStats `json:"stats,omitempty"`
}

// UnmarshalJSON decodes the canonical shape and accepts the aliases result/status (state),
// finished (last_finished), last_ok (last_success), log (log_file) and generated (updated).
func (s *BackupStatus) UnmarshalJSON(b []byte) error {
	type plain BackupStatus
	var p plain
	if err := json.Unmarshal(b, &p); err != nil {
		return err
	}
	var alt struct {
		Result    string   `json:"result"`
		Status    string   `json:"status"`
		Finished  FlexTime `json:"finished"`
		LastOK    FlexTime `json:"last_ok"`
		Log       string   `json:"log"`
		Generated FlexTime `json:"generated"`
	}
	_ = json.Unmarshal(b, &alt)
	if p.State == "" {
		p.State = alt.Result
	}
	if p.State == "" {
		p.State = alt.Status
	}
	p.State = strings.ToLower(strings.TrimSpace(p.State))
	if p.LastFinished.IsZero() {
		p.LastFinished = alt.Finished
	}
	if p.LastSuccess.IsZero() {
		p.LastSuccess = alt.LastOK
	}
	if p.LogFile == "" {
		p.LogFile = alt.Log
	}
	if p.Updated.IsZero() {
		p.Updated = alt.Generated
	}
	p.Repository = stripUserinfo(p.Repository)
	*s = BackupStatus(p)
	return nil
}

// stripUserinfo removes "user:password@" from URL-like repository strings (s3:https://k:s@host/…)
// so credentials written there by mistake never reach the browser.
func stripUserinfo(repo string) string {
	i := strings.Index(repo, "://")
	if i < 0 {
		return repo
	}
	rest := repo[i+3:]
	end := len(rest)
	if j := strings.IndexAny(rest, "/?#"); j >= 0 {
		end = j
	}
	if at := strings.LastIndex(rest[:end], "@"); at >= 0 {
		return repo[:i+3] + rest[at+1:]
	}
	return repo
}

func firstTime(ts ...FlexTime) FlexTime {
	for _, t := range ts {
		if !t.IsZero() {
			return t
		}
	}
	return FlexTime{}
}

// Snapshot is one entry of `restic snapshots --json` (state/snapshots.json).
type Snapshot struct {
	ID       string   `json:"id"`
	ShortID  string   `json:"short_id"`
	Time     FlexTime `json:"time"`
	Hostname string   `json:"hostname"`
	Paths    []string `json:"paths"`
	Tags     []string `json:"tags"`
	Summary  *struct {
		FilesNew            int64 `json:"files_new"`
		FilesChanged        int64 `json:"files_changed"`
		DataAdded           int64 `json:"data_added"`
		TotalFilesProcessed int64 `json:"total_files_processed"`
		TotalBytesProcessed int64 `json:"total_bytes_processed"`
	} `json:"summary,omitempty"`
}

// VPNPeer is a sanitized VPN device (never contains keys).
type VPNPeer struct {
	Name            string   `json:"name"`
	Address         string   `json:"address"`
	Enabled         bool     `json:"enabled"`
	LatestHandshake FlexTime `json:"latest_handshake"`
	RxBytes         int64    `json:"rx_bytes"`
	TxBytes         int64    `json:"tx_bytes"`
	Endpoint        string   `json:"endpoint,omitempty"`
}

// VPNStatus is state/vpn-status.json (written by the host).
type VPNStatus struct {
	Updated    FlexTime  `json:"updated"`
	Platform   string    `json:"platform"`
	Interface  string    `json:"interface"`
	ListenPort int       `json:"listen_port"`
	Peers      []VPNPeer `json:"peers"`
}

// UnmarshalJSON accepts several field-name spellings and silently drops key material.
func (v *VPNStatus) UnmarshalJSON(b []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	*v = VPNStatus{}
	_ = json.Unmarshal(pick(raw, "updated", "updated_at", "generated", "time"), &v.Updated)
	v.Platform = str(pick(raw, "platform"))
	v.Interface = str(pick(raw, "interface", "device"))
	v.ListenPort = int(num(pick(raw, "listen_port", "port")))
	var peers []map[string]json.RawMessage
	_ = json.Unmarshal(pick(raw, "peers", "clients", "devices"), &peers)
	for _, p := range peers {
		peer := VPNPeer{
			Name:     str(pick(p, "name", "client", "device")),
			Address:  str(pick(p, "address", "ip", "ipv4", "ipv4_address", "allowed_ips")),
			Enabled:  true,
			RxBytes:  num(pick(p, "rx_bytes", "transfer_rx", "rx")),
			TxBytes:  num(pick(p, "tx_bytes", "transfer_tx", "tx")),
			Endpoint: str(pick(p, "endpoint")),
		}
		if e := pick(p, "enabled"); e != nil {
			s := strings.Trim(strings.TrimSpace(string(e)), `"`)
			peer.Enabled = s == "true" || s == "1"
		}
		_ = json.Unmarshal(pick(p, "latest_handshake", "last_handshake", "latest_handshake_at", "handshake"), &peer.LatestHandshake)
		if peer.Endpoint == "(none)" {
			peer.Endpoint = ""
		}
		v.Peers = append(v.Peers, peer)
	}
	return nil
}

func pick(m map[string]json.RawMessage, keys ...string) json.RawMessage {
	for _, k := range keys {
		if v, ok := m[k]; ok && string(v) != "null" {
			return v
		}
	}
	return nil
}

func str(b json.RawMessage) string {
	if b == nil {
		return ""
	}
	var s string
	if json.Unmarshal(b, &s) == nil {
		return s
	}
	var arr []string
	if json.Unmarshal(b, &arr) == nil {
		return strings.Join(arr, ", ")
	}
	return strings.Trim(string(b), `"`)
}

func num(b json.RawMessage) int64 {
	if b == nil {
		return 0
	}
	s := strings.Trim(strings.TrimSpace(string(b)), `"`)
	if i, err := strconv.ParseInt(s, 10, 64); err == nil {
		return i
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return int64(f)
	}
	return 0
}
