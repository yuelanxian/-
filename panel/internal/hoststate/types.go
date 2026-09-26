package hoststate

import (
	"encoding/json"
	"strconv"
	"strings"
)

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
	Stats           *BackupStats `json:"stats,omitempty"`
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
	_ = json.Unmarshal(pick(raw, "updated", "updated_at", "time"), &v.Updated)
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
