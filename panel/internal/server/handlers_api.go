package server

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"homevault/panel/internal/auth"
	"homevault/panel/internal/diskstat"
	"homevault/panel/internal/docker"
	"homevault/panel/internal/hoststate"
	"homevault/panel/internal/logfiles"
	"homevault/panel/internal/nextcloud"
)

// serviceLabels are Chinese display names of compose services.
var serviceLabels = map[string]string{
	"app":          "Nextcloud 应用",
	"cron":         "Nextcloud 后台任务",
	"db":           "数据库（PostgreSQL）",
	"redis":        "缓存（Redis）",
	"caddy":        "HTTPS 网关（Caddy）",
	"wg-easy":      "VPN（wg-easy）",
	"ddns-go":      "动态域名（ddns-go）",
	"panel":        "管理面板",
	"socket-proxy": "Docker 只读代理",
	"scrutiny":     "硬盘健康监控",
	"backup":       "备份工具（restic）",
}

// coreServices must always exist.
var coreServices = []string{"app", "cron", "db", "redis", "caddy"}

type alert struct {
	Level   string `json:"level"` // error | warn | info
	Message string `json:"message"`
	Page    string `json:"page,omitempty"`
}

type serviceView struct {
	Service      string     `json:"service"`
	Label        string     `json:"label"`
	State        string     `json:"state"`
	Health       string     `json:"health"`
	Status       string     `json:"status"`
	StartedAt    *time.Time `json:"started_at"`
	RestartCount int        `json:"restart_count"`
	Image        string     `json:"image"`
	CanRestart   bool       `json:"can_restart"`
}

func label(svc string) string {
	if l, ok := serviceLabels[svc]; ok {
		return l
	}
	return svc
}

func timePtr(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func (s *Server) canRestart(svc string) bool {
	for _, a := range s.cfg.RestartAllowList {
		if a == svc {
			return true
		}
	}
	return false
}

func (s *Server) serviceViews(ctx context.Context) ([]serviceView, error) {
	list, err := s.docker.Services(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]serviceView, 0, len(list))
	for _, c := range list {
		out = append(out, serviceView{Service: c.Service, Label: label(c.Service), State: c.State, Health: c.Health,
			Status: c.Status, StartedAt: timePtr(c.StartedAt), RestartCount: c.RestartCount, Image: c.Image,
			CanRestart: s.canRestart(c.Service)})
	}
	return out, nil
}

func dockerErrorMessage(err error) string {
	var ae *docker.APIError
	if errors.As(err, &ae) && ae.Status == http.StatusForbidden {
		return "Docker 代理拒绝了请求（请检查 socket-proxy 配置）"
	}
	return "无法连接 Docker（socket-proxy 未运行？）"
}

// ---------------------------------------------------------------- overview

func (s *Server) handleOverview(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	now := s.now()
	var alerts []alert

	var st hoststate.Status
	stMod, stErr := s.state.ReadJSON("status.json", &st)
	statusUpdated := st.Updated.Time
	if statusUpdated.IsZero() && stErr == nil {
		statusUpdated = stMod
	}
	version := st.Version
	if version == "" {
		version = s.cfg.Version
	}

	services, derr := s.serviceViews(ctx)
	dockerView := map[string]any{"ok": derr == nil}
	if derr != nil {
		dockerView["error"] = dockerErrorMessage(derr)
		alerts = append(alerts, alert{"error", dockerView["error"].(string), "overview"})
		slog.Warn("docker services failed", "err", derr)
	} else {
		present := map[string]bool{}
		for _, sv := range services {
			present[sv.Service] = true
			switch {
			case sv.State != "running":
				alerts = append(alerts, alert{"error", fmt.Sprintf("服务「%s」未运行（%s）", sv.Label, stateText(sv.State)), "overview"})
			case sv.Health == "unhealthy":
				alerts = append(alerts, alert{"error", fmt.Sprintf("服务「%s」健康检查失败", sv.Label), "logs"})
			}
		}
		for _, c := range coreServices {
			if !present[c] {
				alerts = append(alerts, alert{"error", fmt.Sprintf("服务「%s」不存在（容器未创建）", label(c)), "overview"})
			}
		}
		if info, err := s.dockerInfo(ctx); err == nil {
			dockerView["info"] = info
		}
	}

	disks, _ := s.collectDisks(diskstat.LoadStorageConf(s.cfg.StorageConf))
	alerts = append(alerts, diskAlerts(disks)...)

	bv := s.backupView()
	alerts = append(alerts, bv.alerts(now)...)

	vpn := s.vpnSummary(now)

	pending, _ := s.state.Requests(0)
	for _, p := range pending {
		if p.Created != nil && now.Sub(p.Created.Time) > 15*time.Minute {
			alerts = append(alerts, alert{"warn", "有请求超过 15 分钟未被主机处理（主机上的请求处理任务可能未运行）", "settings"})
			break
		}
	}
	if stErr == nil && !statusUpdated.IsZero() && now.Sub(statusUpdated) > 36*time.Hour {
		alerts = append(alerts, alert{"warn", "主机状态文件超过 36 小时未更新（每日维护任务可能未运行）", "logs"})
	}

	resp := map[string]any{
		"now":            now.Format(time.RFC3339),
		"panel_version":  s.version,
		"version":        version,
		"platform":       st.Platform,
		"host":           s.cfg.Host,
		"nextcloud_url":  s.cfg.PublicURL.String(),
		"status_updated": timePtr(statusUpdated),
		"services":       services,
		"docker":         dockerView,
		"disks":          disks,
		"backup":         bv,
		"vpn":            vpn,
		"pending":        len(pending),
		"alerts":         nonNil(alerts),
		"user":           sess.UserID,
	}
	if si := s.serverInfo(ctx, sess, s.clientIP(r)); si != nil {
		resp["nextcloud"] = si
	}
	writeJSON(w, http.StatusOK, resp)
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func stateText(st string) string {
	switch st {
	case "running":
		return "运行中"
	case "exited":
		return "已停止"
	case "restarting":
		return "正在重启"
	case "paused":
		return "已暂停"
	case "created":
		return "已创建未启动"
	case "dead":
		return "已失效"
	}
	return st
}

func (s *Server) dockerInfo(ctx context.Context) (*docker.Info, error) {
	if v, ok := s.cache.get("dockerinfo"); ok {
		return v.(*docker.Info), nil
	}
	info, err := s.docker.Info(ctx)
	if err != nil {
		return nil, err
	}
	s.cache.set("dockerinfo", info, 5*time.Minute)
	return info, nil
}

// collectDisks stats the /stat mounts; when none are mounted it falls back to the optional
// "disks" array of state/status.json written by the host. source is "panel", "host" or "".
func (s *Server) collectDisks(conf []diskstat.StorageEntry) ([]diskstat.Disk, string) {
	disks := diskstat.Collect(s.cfg.StatDir, conf)
	if len(disks) > 0 {
		return disks, "panel"
	}
	var st hoststate.Status
	if _, err := s.state.ReadJSON("status.json", &st); err != nil || len(st.Disks) == 0 {
		return disks, ""
	}
	for _, hd := range st.Disks {
		role, lbl := hostDiskRole(hd.Role)
		d := diskstat.Disk{Role: role, RoleLabel: lbl, Name: hd.Name, HostPath: hd.Path}
		if d.Name == "" {
			d.Name = lbl
		}
		switch {
		case hd.Mounted != nil && !*hd.Mounted:
			d.Error = "目录不存在或硬盘未连接"
		case hd.Total <= 0:
			d.Error = "无法读取磁盘信息"
		default:
			free := max(hd.Free, 0)
			d.Total, d.Free = uint64(hd.Total), uint64(min(free, hd.Total))
			d.Used = d.Total - d.Free
			d.UsedPct = float64(int64(float64(d.Used)*1000/float64(d.Total)+0.5)) / 10
			d.FreePct = float64(int64((100-d.UsedPct)*10+0.5)) / 10
		}
		disks = append(disks, d)
	}
	return disks, "host"
}

func hostDiskRole(r string) (string, string) {
	switch strings.ToLower(strings.TrimSpace(r)) {
	case "data", "主数据":
		return diskstat.RoleData, diskstat.RoleLabel[diskstat.RoleData]
	case "storage", "扩展存储":
		return diskstat.RoleStorage, diskstat.RoleLabel[diskstat.RoleStorage]
	case "backup", "备份":
		return diskstat.RoleBackup, diskstat.RoleLabel[diskstat.RoleBackup]
	case "system", "系统数据":
		return "system", "系统数据"
	}
	return "other", r
}

func diskAlerts(disks []diskstat.Disk) []alert {
	var out []alert
	for _, d := range disks {
		if d.Error != "" {
			out = append(out, alert{"warn", fmt.Sprintf("无法读取「%s」（%s）的磁盘信息", d.Name, d.RoleLabel), "storage"})
			continue
		}
		if d.Total > 0 && d.FreePct < 10 {
			out = append(out, alert{"error", fmt.Sprintf("「%s」（%s）剩余空间不足 10%%（剩余 %s）", d.Name, d.RoleLabel, humanBytes(d.Free)), "storage"})
		}
	}
	for _, d := range disks {
		if d.Role != diskstat.RoleBackup {
			continue
		}
		for _, o := range disks {
			if o.Role != diskstat.RoleBackup && contains(d.SameDisk, o.Name) && (o.Role == diskstat.RoleData || o.Access == "rw") {
				out = append(out, alert{"warn", fmt.Sprintf("备份目标与「%s」位于同一块磁盘，磁盘损坏时会同时丢失", o.Name), "storage"})
			}
		}
	}
	return out
}

func contains(ss []string, v string) bool {
	for _, s := range ss {
		if s == v {
			return true
		}
	}
	return false
}

func humanBytes(b uint64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := uint64(unit), 0
	for n := b / unit; n >= unit && exp < 5; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}

// ---------------------------------------------------------------- storage

type userView struct {
	ID          string     `json:"id"`
	DisplayName string     `json:"display_name"`
	Used        int64      `json:"used"`
	Quota       int64      `json:"quota"` // bytes; < 0 = unlimited
	Free        int64      `json:"free"`
	Relative    float64    `json:"relative"`
	Enabled     bool       `json:"enabled"`
	LastLogin   *time.Time `json:"last_login"`
	Admin       bool       `json:"admin"`
}

func (s *Server) handleStorage(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	ip := s.clientIP(r)
	conf := diskstat.LoadStorageConf(s.cfg.StorageConf)
	disks, source := s.collectDisks(conf)
	resp := map[string]any{"disks": nonNil(disks), "disks_source": source, "alerts": nonNil(diskAlerts(disks))}

	if v, ok := s.cache.get("users"); ok {
		resp["users"] = v
	} else if users, err := s.nc.UsersDetails(ctx, &sess.Creds, ip, 500); err != nil {
		slog.Warn("users details failed", "err", err)
		resp["users"] = []userView{}
		resp["users_error"] = "无法从 Nextcloud 读取用户用量"
	} else {
		views := make([]userView, 0, len(users))
		for _, u := range users {
			v := userView{ID: u.ID, DisplayName: u.DisplayName, Used: u.Quota.Used, Quota: u.Quota.Quota,
				Free: u.Quota.Free, Relative: u.Quota.Relative, Enabled: u.Enabled, Admin: u.InGroup(s.cfg.AdminGroup)}
			if u.LastLogin > 0 {
				v.LastLogin = timePtr(time.UnixMilli(u.LastLogin))
			}
			views = append(views, v)
		}
		sort.Slice(views, func(i, j int) bool {
			if views[i].Used != views[j].Used {
				return views[i].Used > views[j].Used
			}
			return views[i].ID < views[j].ID
		})
		s.cache.set("users", views, 30*time.Second)
		resp["users"] = views
	}
	if si := s.serverInfo(ctx, sess, ip); si != nil {
		resp["nextcloud"] = si
	}
	storages := make([]map[string]any, 0, len(conf))
	for _, e := range conf {
		storages = append(storages, map[string]any{"name": e.Name, "host_path": e.HostPath, "access": e.Access,
			"backup": e.Backup, "users": e.Users, "slug": e.Slugs[0]})
	}
	resp["storage_conf"] = storages
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) serverInfo(ctx context.Context, sess *auth.Session, ip string) *nextcloud.ServerInfo {
	if v, ok := s.cache.get("serverinfo"); ok {
		return v.(*nextcloud.ServerInfo)
	}
	if _, ok := s.cache.get("serverinfo-miss"); ok {
		return nil
	}
	si, err := s.nc.ServerInfo(ctx, &sess.Creds, ip)
	if err != nil {
		s.cache.set("serverinfo-miss", true, 5*time.Minute)
		return nil
	}
	s.cache.set("serverinfo", si, time.Minute)
	return si
}

// ---------------------------------------------------------------- backup

type backupView struct {
	Configured   bool                    `json:"configured"`
	Status       *hoststate.BackupStatus `json:"status"`
	LastSuccess  *time.Time              `json:"last_success"`
	AgeHours     float64                 `json:"age_hours"` // -1 = never
	Stale        bool                    `json:"stale"`
	StatusError  string                  `json:"status_error,omitempty"`
	StatusFileAt *time.Time              `json:"status_file_time,omitempty"`
}

func (s *Server) backupView() backupView {
	now := s.now()
	bv := backupView{AgeHours: -1}
	var bs hoststate.BackupStatus
	mod, err := s.state.ReadJSON("backup-status.json", &bs)
	switch {
	case err == nil:
		bv.Configured = true
		bv.Status = &bs
		bv.StatusFileAt = timePtr(mod)
	case !errors.Is(err, fs.ErrNotExist):
		bv.StatusError = "备份状态文件无法解析"
	}
	last := bs.LastSuccess.Time
	if last.IsZero() && strings.EqualFold(bs.State, "ok") {
		last = bs.LastFinished.Time
	}
	if txt, _, err := s.state.ReadText("last-backup-ok"); err == nil {
		bv.Configured = true
		if t := hoststate.ParseTime(txt); t.After(last) {
			last = t
		}
	}
	if !last.IsZero() {
		bv.LastSuccess = &last
		bv.AgeHours = float64(int64(now.Sub(last).Hours()*10)) / 10
		bv.Stale = now.Sub(last) > 48*time.Hour
	}
	return bv
}

func (bv backupView) alerts(now time.Time) []alert {
	var out []alert
	if bv.LastSuccess == nil {
		out = append(out, alert{"warn", "还没有成功的备份记录", "backup"})
	} else if bv.Stale {
		out = append(out, alert{"error", fmt.Sprintf("上次成功备份已超过 48 小时（%.0f 小时前）", bv.AgeHours), "backup"})
	}
	if bv.Status != nil {
		switch strings.ToLower(bv.Status.State) {
		case "failed", "error":
			msg := "最近一次备份失败"
			if bv.Status.Message != "" {
				msg += "：" + bv.Status.Message
			}
			out = append(out, alert{"error", msg, "backup"})
		case "partial":
			out = append(out, alert{"warn", "最近一次备份不完整（部分文件无法读取）", "backup"})
		}
	}
	return out
}

func (s *Server) handleBackup(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	bv := s.backupView()
	var snaps []hoststate.Snapshot
	snapMod, serr := s.state.ReadJSON("snapshots.json", &snaps)
	sort.Slice(snaps, func(i, j int) bool { return snaps[i].Time.After(snaps[j].Time.Time) })
	total := len(snaps)
	if len(snaps) > 60 {
		snaps = snaps[:60]
	}
	pending, done := s.state.Requests(50)
	resp := map[string]any{
		"backup":          bv,
		"alerts":          nonNil(bv.alerts(s.now())),
		"snapshots":       nonNil(snaps),
		"snapshots_total": total,
		"pending":         filterReq(pending, hoststate.TypeBackup),
		"recent":          limit(filterReq(done, hoststate.TypeBackup), 10),
	}
	if serr == nil {
		resp["snapshots_updated"] = timePtr(snapMod)
	} else if !errors.Is(serr, fs.ErrNotExist) {
		resp["snapshots_error"] = "快照列表文件无法解析"
	}
	writeJSON(w, http.StatusOK, resp)
}

func filterReq(in []hoststate.RequestStatus, typ string) []hoststate.RequestStatus {
	out := []hoststate.RequestStatus{}
	for _, r := range in {
		if r.Type == typ {
			out = append(out, r)
		}
	}
	return out
}

func limit[T any](s []T, n int) []T {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func (s *Server) submit(w http.ResponseWriter, r *http.Request, sess *auth.Session, typ string, days int, msg string) {
	req, dup, err := s.state.Submit(typ, days, sess.UserID, s.clientIP(r))
	detail := typ
	if days > 0 {
		detail += " days=" + strconv.Itoa(days)
	}
	if err != nil {
		s.audit.Log("request_"+typ, false, sess.UserID, s.clientIP(r), detail+": "+err.Error())
		switch {
		case errors.Is(err, hoststate.ErrDays):
			writeError(w, http.StatusBadRequest, "天数必须是 1 到 365 之间的整数")
		case errors.Is(err, hoststate.ErrTooManyPending):
			writeError(w, http.StatusServiceUnavailable, "待处理的请求过多，主机上的请求处理任务可能未运行")
		default:
			slog.Error("write request failed", "type", typ, "err", err)
			writeError(w, http.StatusInternalServerError, "无法写入请求文件（请检查 state/requests 目录权限）")
		}
		return
	}
	s.audit.Log("request_"+typ, true, sess.UserID, s.clientIP(r), detail+" id="+req.ID)
	if dup {
		msg = "已有相同的请求在等待执行"
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true, "id": req.ID, "duplicate": dup, "message": msg})
}

func (s *Server) handleBackupRun(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	s.submit(w, r, sess, hoststate.TypeBackup, 0, "已提交备份请求，主机将在约 2 分钟内开始备份")
}

func (s *Server) handleRequests(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	pending, done := s.state.Requests(30)
	writeJSON(w, http.StatusOK, map[string]any{"pending": nonNil(pending), "done": nonNil(done)})
}

// ---------------------------------------------------------------- logs

type containerLogView struct {
	Service string `json:"service"`
	Label   string `json:"label"`
	State   string `json:"state"`
	Health  string `json:"health"`
}

func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	resp := map[string]any{"retention_days": s.retentionDays()}
	files, err := s.logs.List()
	if err != nil {
		resp["files_error"] = "无法读取日志目录"
		slog.Warn("list logs failed", "err", err)
		files = nil
	}
	resp["files"] = nonNil(files)
	list, derr := s.docker.Services(ctx)
	cv := []containerLogView{}
	if derr != nil {
		resp["containers_error"] = dockerErrorMessage(derr)
	}
	for _, c := range list {
		cv = append(cv, containerLogView{Service: c.Service, Label: label(c.Service), State: c.State, Health: c.Health})
	}
	resp["containers"] = cv
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) parseLines(r *http.Request, def int) int {
	n, err := strconv.Atoi(r.URL.Query().Get("lines"))
	if err != nil || n <= 0 {
		return def
	}
	if n > s.cfg.MaxLogLines {
		return s.cfg.MaxLogLines
	}
	return n
}

func parseQuery(r *http.Request) (string, bool) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if len(q) > 200 {
		return "", false
	}
	for _, c := range q {
		if unicode.IsControl(c) {
			return "", false
		}
	}
	return q, true
}

func logFileError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, logfiles.ErrInvalidPath):
		writeError(w, http.StatusBadRequest, "无效的日志路径")
	case errors.Is(err, logfiles.ErrNotRegular):
		writeError(w, http.StatusBadRequest, "不是普通日志文件")
	case errors.Is(err, logfiles.ErrTooLarge):
		writeError(w, http.StatusRequestEntityTooLarge, "压缩日志过大，请下载后查看")
	case errors.Is(err, fs.ErrNotExist):
		writeError(w, http.StatusNotFound, "日志文件不存在")
	default:
		// os.Root reports escapes (symlinks out of /logs, "..") as path errors
		var pe *fs.PathError
		if errors.As(err, &pe) {
			writeError(w, http.StatusBadRequest, "无效的日志路径")
			return
		}
		slog.Warn("log read failed", "err", err)
		writeError(w, http.StatusInternalServerError, "读取日志失败")
	}
}

func (s *Server) handleLogFile(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	q, ok := parseQuery(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "搜索内容无效")
		return
	}
	res, err := s.logs.Tail(r.URL.Query().Get("path"), s.parseLines(r, 500), q)
	if err != nil {
		logFileError(w, err)
		return
	}
	var cut bool
	res.Lines, cut = trimToBytes(res.Lines, maxViewBytes)
	res.Truncated = res.Truncated || cut
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleLogDownload(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	p := r.URL.Query().Get("path")
	f, fi, err := s.logs.Open(p)
	if err != nil {
		logFileError(w, err)
		return
	}
	defer f.Close()
	name := path.Base(p)
	ctype := "text/plain; charset=utf-8"
	if strings.HasSuffix(strings.ToLower(name), ".gz") {
		ctype = "application/gzip"
	}
	s.audit.Log("log_download", true, sess.UserID, s.clientIP(r), p)
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Content-Disposition", attachment(name))
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

func attachment(name string) string {
	return mime.FormatMediaType("attachment", map[string]string{"filename": name})
}

func (s *Server) findService(w http.ResponseWriter, r *http.Request, name string) *docker.Container {
	if name == "" || len(name) > 64 {
		writeError(w, http.StatusBadRequest, "无效的服务名")
		return nil
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	ct, err := s.docker.Find(ctx, name)
	if err != nil {
		if errors.Is(err, docker.ErrNotFound) {
			writeError(w, http.StatusNotFound, "没有找到该服务的容器")
			return nil
		}
		writeError(w, http.StatusBadGateway, dockerErrorMessage(err))
		return nil
	}
	return ct
}

func (s *Server) containerLines(ctx context.Context, ct *docker.Container, n int, q string, maxBytes int64) ([]string, bool, error) {
	tail := n
	if q != "" {
		tail = 50000
	}
	raw, truncated, err := s.docker.Logs(ctx, ct, tail, true, maxBytes)
	if err != nil {
		return nil, false, err
	}
	text := strings.TrimRight(strings.ToValidUTF8(string(raw), "\uFFFD"), "\n")
	var lines []string
	if text != "" {
		lines = strings.Split(text, "\n")
	}
	if q != "" {
		lq := strings.ToLower(q)
		filtered := lines[:0]
		for _, l := range lines {
			if strings.Contains(strings.ToLower(l), lq) {
				filtered = append(filtered, l)
			}
		}
		lines = filtered
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
		truncated = true
	}
	for i, l := range lines {
		lines[i] = strings.TrimSuffix(l, "\r")
	}
	lines, cut := trimToBytes(lines, maxViewBytes)
	return nonNil(lines), truncated || cut, nil
}

// maxViewBytes bounds a log view response (phones on VPN/mobile data).
const maxViewBytes = 4 << 20

// trimToBytes drops the oldest lines until the total size fits into max bytes.
func trimToBytes(lines []string, max int) ([]string, bool) {
	total := 0
	for i := len(lines) - 1; i >= 0; i-- {
		total += len(lines[i]) + 1
		if total > max {
			return lines[i+1:], true
		}
	}
	return lines, false
}

func (s *Server) handleContainerLogs(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	q, ok := parseQuery(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "搜索内容无效")
		return
	}
	ct := s.findService(w, r, r.PathValue("service"))
	if ct == nil {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	n := s.parseLines(r, 500)
	lines, truncated, err := s.containerLines(ctx, ct, n, q, 32<<20)
	if err != nil {
		writeError(w, http.StatusBadGateway, dockerErrorMessage(err))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"service": ct.Service, "label": label(ct.Service), "state": ct.State,
		"lines": lines, "truncated": truncated, "query": q})
}

func (s *Server) handleContainerLogsDownload(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	ct := s.findService(w, r, r.PathValue("service"))
	if ct == nil {
		return
	}
	n, err := strconv.Atoi(r.URL.Query().Get("lines"))
	if err != nil || n <= 0 || n > 100000 {
		n = 20000
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	raw, _, err := s.docker.Logs(ctx, ct, n, true, 64<<20)
	if err != nil {
		writeError(w, http.StatusBadGateway, dockerErrorMessage(err))
		return
	}
	s.audit.Log("log_download", true, sess.UserID, s.clientIP(r), "container "+ct.Service)
	name := fmt.Sprintf("%s-%s.log", ct.Service, s.now().Format("20060102-150405"))
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", attachment(name))
	_, _ = w.Write(raw)
}

func (s *Server) handleLogClean(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	s.submit(w, r, sess, hoststate.TypeLogClean, 0, "已提交清理请求，主机将删除超过保留天数的日志")
}

// ---------------------------------------------------------------- retention

func (s *Server) retentionDays() int {
	var st hoststate.Status
	if _, err := s.state.ReadJSON("status.json", &st); err == nil && hoststate.ValidDays(st.LogRetentionDays) == nil {
		return st.LogRetentionDays
	}
	return s.cfg.DefaultRetention
}

func (s *Server) handleRetentionGet(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	pending, done := s.state.Requests(50)
	p := filterReq(pending, hoststate.TypeLogRetention)
	resp := map[string]any{"days": s.retentionDays(), "min": 1, "max": 365, "default": 7,
		"pending": p, "recent": limit(filterReq(done, hoststate.TypeLogRetention), 5)}
	if len(p) > 0 {
		resp["pending_days"] = p[0].Days
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleRetentionSet(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	var req struct {
		Days jsonInt `json:"days"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !req.Days.set || hoststate.ValidDays(req.Days.v) != nil {
		writeError(w, http.StatusBadRequest, "天数必须是 1 到 365 之间的整数")
		return
	}
	s.submit(w, r, sess, hoststate.TypeLogRetention, req.Days.v,
		fmt.Sprintf("已提交：日志保留 %d 天（主机约 2 分钟内生效）", req.Days.v))
}

// jsonInt accepts only a plain JSON integer (no strings, fractions or exponents).
type jsonInt struct {
	v   int
	set bool
}

func (j *jsonInt) UnmarshalJSON(b []byte) error {
	s := string(b)
	if len(s) == 0 || len(s) > 6 {
		return errors.New("invalid integer")
	}
	for i, c := range s {
		if !(c >= '0' && c <= '9') && !(i == 0 && c == '-') {
			return errors.New("invalid integer")
		}
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return err
	}
	j.v, j.set = n, true
	return nil
}

// ---------------------------------------------------------------- vpn

type peerView struct {
	hoststate.VPNPeer
	Online bool `json:"online"`
}

func (s *Server) readVPN() (*hoststate.VPNStatus, time.Time, error) {
	var vs hoststate.VPNStatus
	mod, err := s.state.ReadJSON("vpn-status.json", &vs)
	if err != nil {
		return nil, time.Time{}, err
	}
	updated := vs.Updated.Time
	if updated.IsZero() {
		updated = mod
	}
	return &vs, updated, nil
}

func (s *Server) vpnSummary(now time.Time) map[string]any {
	vs, updated, err := s.readVPN()
	if err != nil {
		return map[string]any{"available": false}
	}
	online := 0
	for _, p := range vs.Peers {
		if isOnline(p, now) {
			online++
		}
	}
	return map[string]any{"available": true, "devices": len(vs.Peers), "online": online, "updated": timePtr(updated)}
}

func isOnline(p hoststate.VPNPeer, now time.Time) bool {
	return p.Enabled && !p.LatestHandshake.IsZero() && now.Sub(p.LatestHandshake.Time) < 3*time.Minute
}

func (s *Server) handleVPN(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	now := s.now()
	vs, updated, err := s.readVPN()
	if err != nil {
		resp := map[string]any{"available": false, "peers": []peerView{}}
		if !errors.Is(err, fs.ErrNotExist) {
			resp["error"] = "VPN 状态文件无法解析"
		}
		writeJSON(w, http.StatusOK, resp)
		return
	}
	peers := make([]peerView, 0, len(vs.Peers))
	for _, p := range vs.Peers {
		peers = append(peers, peerView{VPNPeer: p, Online: isOnline(p, now)})
	}
	sort.SliceStable(peers, func(i, j int) bool {
		if peers[i].Online != peers[j].Online {
			return peers[i].Online
		}
		if !peers[i].LatestHandshake.Equal(peers[j].LatestHandshake.Time) {
			return peers[i].LatestHandshake.After(peers[j].LatestHandshake.Time)
		}
		return peers[i].Name < peers[j].Name
	})
	writeJSON(w, http.StatusOK, map[string]any{
		"available":   true,
		"updated":     timePtr(updated),
		"stale":       !updated.IsZero() && now.Sub(updated) > 15*time.Minute,
		"platform":    vs.Platform,
		"interface":   vs.Interface,
		"listen_port": vs.ListenPort,
		"peers":       peers,
	})
}

// ---------------------------------------------------------------- services

func (s *Server) handleRestart(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	name := r.PathValue("name")
	if !s.canRestart(name) {
		s.audit.Log("restart", false, sess.UserID, s.clientIP(r), name+": not allowed")
		writeError(w, http.StatusForbidden, "该服务不允许从面板重启")
		return
	}
	ct := s.findService(w, r, name)
	if ct == nil {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	if err := s.docker.Restart(ctx, ct, 30); err != nil {
		s.audit.Log("restart", false, sess.UserID, s.clientIP(r), name+": "+err.Error())
		writeError(w, http.StatusBadGateway, "重启失败："+dockerErrorMessage(err))
		return
	}
	s.audit.Log("restart", true, sess.UserID, s.clientIP(r), name)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "message": "已重启「" + label(name) + "」"})
}

// ---------------------------------------------------------------- downloads

func (s *Server) readCA() ([]byte, *x509.Certificate, error) {
	f, err := os.Open(s.cfg.CACertFile)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return nil, nil, fs.ErrNotExist
	}
	b, err := io.ReadAll(io.LimitReader(f, 64<<10))
	if err != nil {
		return nil, nil, err
	}
	// Re-encode certificate blocks only: never serve anything else (e.g. a key by mistake).
	var out []byte
	var first *x509.Certificate
	for {
		var blk *pem.Block
		blk, b = pem.Decode(b)
		if blk == nil {
			break
		}
		if blk.Type != "CERTIFICATE" {
			continue
		}
		c, err := x509.ParseCertificate(blk.Bytes)
		if err != nil {
			continue
		}
		if first == nil {
			first = c
		}
		out = append(out, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: blk.Bytes})...)
	}
	if first == nil {
		return nil, nil, fs.ErrNotExist
	}
	return out, first, nil
}

func (s *Server) handleCACert(w http.ResponseWriter, r *http.Request) {
	pemBytes, _, err := s.readCA()
	if err != nil {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte("没有可下载的根证书（域名模式使用公共证书，无需安装）。\n"))
		return
	}
	w.Header().Set("Content-Type", "application/x-x509-ca-cert")
	w.Header().Set("Content-Disposition", attachment("homevault-ca.crt"))
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(pemBytes)
}

func (s *Server) apkInfo() (os.FileInfo, bool) {
	fi, err := os.Stat(s.cfg.APKFile)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() == 0 {
		return nil, false
	}
	return fi, true
}

func (s *Server) handleAPK(w http.ResponseWriter, r *http.Request) {
	f, err := os.Open(s.cfg.APKFile)
	if err != nil {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte("服务器上还没有安卓应用安装包。请在服务器上运行 hv android fetch（Windows：hv.ps1 android fetch）。\n"))
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.android.package-archive")
	w.Header().Set("Content-Disposition", attachment("HomeVault.apk"))
	w.Header().Set("Cache-Control", "no-cache")
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

func (s *Server) handleAbout(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	var st hoststate.Status
	_, _ = s.state.ReadJSON("status.json", &st)
	version := st.Version
	if version == "" {
		version = s.cfg.Version
	}
	resp := map[string]any{
		"panel_version":   s.version,
		"version":         version,
		"platform":        st.Platform,
		"host":            s.cfg.Host,
		"nextcloud_url":   s.cfg.PublicURL.String(),
		"user":            sess.UserID,
		"display_name":    sess.DisplayName,
		"login_method":    sess.Method,
		"session_expires": sess.Expires.Format(time.RFC3339),
	}
	if fi, ok := s.apkInfo(); ok {
		resp["apk"] = map[string]any{"available": true, "size": fi.Size(), "mtime": fi.ModTime(), "url": "/download/android"}
	} else {
		resp["apk"] = map[string]any{"available": false}
	}
	if _, cert, err := s.readCA(); err == nil {
		sum := sha256.Sum256(cert.Raw)
		hexs := strings.ToUpper(hex.EncodeToString(sum[:]))
		var pairs []string
		for i := 0; i < len(hexs); i += 2 {
			pairs = append(pairs, hexs[i:i+2])
		}
		resp["ca"] = map[string]any{"available": true, "url": "/ca.crt", "subject": cert.Subject.CommonName,
			"sha256": strings.Join(pairs, ":"), "not_after": cert.NotAfter}
	} else {
		resp["ca"] = map[string]any{"available": false}
	}
	writeJSON(w, http.StatusOK, resp)
}
