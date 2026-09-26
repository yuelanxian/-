// statecheck decodes the state files written by windows/lib (unit.ps1 artifacts) with the panel's own
// hoststate types, so a field-name drift between hv.ps1 and the panel fails the test.
// Run by tests/pwsh/run.sh inside golang:1.26-alpine next to a copy of panel/internal/hoststate.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"homevault/panel/internal/hoststate"
)

var failures int

func exists(dir, name string) bool {
	_, err := os.Stat(filepath.Join(dir, name))
	return err == nil
}

func check(dir, name string, out any, verify func() string) {
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		fmt.Printf("  FAIL %s: %v\n", name, err)
		failures++
		return
	}
	if err := json.Unmarshal(b, out); err != nil {
		fmt.Printf("  FAIL %s: decode: %v\n", name, err)
		failures++
		return
	}
	if msg := verify(); msg != "" {
		fmt.Printf("  FAIL %s: %s\n", name, msg)
		failures++
		return
	}
	fmt.Printf("  ok   %s decodes with the panel's hoststate types\n", name)
}

func main() {
	dir := os.Args[1]

	var ok hoststate.BackupStatus
	check(dir, "backup-status.json", &ok, func() string {
		switch {
		case ok.State != "ok":
			return "state " + ok.State
		case ok.Updated.IsZero() || ok.LastRun.IsZero() || ok.LastFinished.IsZero() || ok.LastSuccess.IsZero() || ok.NextRun.IsZero():
			return fmt.Sprintf("zero time in %+v", ok)
		case ok.DurationSeconds != 662 || ok.LogFile != "backup/backup-20260926-033000.log" || ok.Target != "local" || ok.Schedule != "03:30":
			return fmt.Sprintf("fields %+v", ok)
		case ok.Repository != `E:\HomeVault-Backup\restic`:
			return "repository " + ok.Repository
		case ok.ExitCode == nil || *ok.ExitCode != 0:
			return "exit_code"
		case ok.Stats == nil || ok.Stats.FilesNew != 12 || ok.Stats.DataAdded != 104857600 || ok.Stats.TotalBytesProcessed != 812345678901:
			return fmt.Sprintf("stats %+v", ok.Stats)
		case ok.LastFinished.Sub(ok.LastRun.Time).Seconds() != 662:
			return "time zone handling"
		}
		return ""
	})

	var running hoststate.BackupStatus
	check(dir, "backup-status-running.json", &running, func() string {
		if running.State != "running" || running.LastRun.IsZero() || !running.LastFinished.IsZero() || !running.LastSuccess.IsZero() {
			return fmt.Sprintf("%+v", running)
		}
		return ""
	})

	var failed hoststate.BackupStatus
	check(dir, "backup-status-failed.json", &failed, func() string {
		if failed.State != "failed" || failed.ExitCode == nil || *failed.ExitCode != 1 || failed.Message == "" {
			return fmt.Sprintf("%+v", failed)
		}
		return ""
	})

	var snaps []hoststate.Snapshot
	check(dir, "snapshots.json", &snaps, func() string {
		if len(snaps) != 2 || snaps[1].Time.IsZero() || snaps[1].ShortID != "bbb1" || snaps[1].Summary == nil || snaps[1].Summary.FilesNew != 12 {
			return fmt.Sprintf("%+v", snaps)
		}
		return ""
	})

	// status.json / vpn-status.json come from windows/lib/status.ps1 (unit-ux.ps1 artifacts); checked when present.
	if exists(dir, "status.json") {
		var st hoststate.Status
		check(dir, "status.json", &st, func() string {
			switch {
			case st.Updated.IsZero() || st.Platform != "windows" || st.Version == "" || st.LogRetentionDays < 1 || st.LogRetentionDays > 365:
				return fmt.Sprintf("header %+v", st)
			case st.Maintenance.LastRun.IsZero() || st.Maintenance.OK == nil:
				return fmt.Sprintf("maintenance %+v", st.Maintenance)
			case len(st.Disks) == 0 || st.Disks[0].Role == "" || st.Disks[0].Total <= 0:
				return fmt.Sprintf("disks %+v", st.Disks)
			}
			return ""
		})
	}
	if !exists(dir, "vpn-status.json") {
		if failures > 0 {
			os.Exit(1)
		}
		return
	}
	var vpn hoststate.VPNStatus
	check(dir, "vpn-status.json", &vpn, func() string {
		switch {
		case vpn.Updated.IsZero() || vpn.Platform != "windows" || vpn.Interface != "homevault" || vpn.ListenPort != 43210:
			return fmt.Sprintf("header %+v", vpn)
		case len(vpn.Peers) != 2:
			return "peers"
		case vpn.Peers[0].Name != "phone1" || vpn.Peers[0].Address != "10.99.77.2/32" || !vpn.Peers[0].Enabled ||
			vpn.Peers[0].LatestHandshake.Unix() != 1790388000 || vpn.Peers[0].RxBytes != 1048576 || vpn.Peers[0].TxBytes != 2097152 ||
			vpn.Peers[0].Endpoint != "203.0.113.9:40000":
			return fmt.Sprintf("peer0 %+v", vpn.Peers[0])
		case !vpn.Peers[1].LatestHandshake.IsZero():
			return "peer1 handshake should be zero"
		}
		return ""
	})

	if failures > 0 {
		os.Exit(1)
	}
}
