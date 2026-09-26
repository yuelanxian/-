# 管理面板集成说明（给 compose / Caddy / Linux CLI / Windows CLI / 安卓应用的维护者）

本文件是 `panel/` 与仓库其余部分之间的**接口约定**，内容以代码为准（`panel/internal/config/config.go`、
`panel/internal/hoststate/types.go`），并已在真实环境（Nextcloud 34 + PostgreSQL 18 + Caddy 2.11 + socket-proxy）
中用 `panel/test/smoke/run.sh` 验证。

- 镜像：`homevault/panel:1.0.0`（本机构建，`scratch` 基础镜像，约 12 MB，uid/gid 65532，只读根文件系统，无外部依赖）
- 容器内监听：`:8080`（纯 HTTP，只在 compose 网络内可达；由 Caddy 在 `https://HV_HOST:HV_PANEL_PORT` 提供 HTTPS）
- 健康检查：镜像自带 `HEALTHCHECK CMD ["/panel","healthcheck"]`（请求 `http://127.0.0.1:8080/healthz`）
- 子命令：`/panel serve`（默认）、`/panel healthcheck`、`/panel version`

---------------------------------------------------------------------------------------------------
## 1. 构建镜像

```sh
# 仓库根目录；Go 只用标准库，构建时不下载任何依赖（GOPROXY=off、GOTOOLCHAIN=local）
docker build -t homevault/panel:1.0.0 panel/
# 国内：基础镜像 golang:1.26-alpine 走 Docker Hub 镜像站
docker build -t homevault/panel:1.0.0 --build-arg REGISTRY=docker.m.daocloud.io/library panel/
```

构建参数：`REGISTRY`（默认 `docker.io/library`，即 `<HV_MIRROR_HUB>/library`）、`GO_IMAGE`（默认 `golang:1.26-alpine`）、
`VERSION`（默认 `1.0.0`，写入二进制，`/panel version` 与页面“管理面板版本”显示）。

**不要从镜像仓库拉取 `homevault/panel`**：Docker Hub 上的 `homevault/*` 不属于本项目（可能被他人抢注）。
compose 里请写 `pull_policy: never` + `build:`（已验证：镜像不存在时 `docker compose up` 会自动构建；
`docker compose pull` 会跳过它、退出码 0）。升级时 CLI 执行 `docker compose build panel`（有缓存，几秒钟）。

---------------------------------------------------------------------------------------------------
## 2. compose.yaml 片段（服务名 `panel`、`socket-proxy` 被脚本引用，请勿改名）

```yaml
services:
  socket-proxy:
    # 只读 Docker API 代理（HAProxy）。只放行：_ping、version、info、containers 列表/详情/日志、restart。
    image: ${SOCKET_PROXY_IMAGE:-docker.io/linuxserver/socket-proxy:3.4.5-r0-ls99}
    restart: unless-stopped
    read_only: true
    tmpfs: [/run]
    security_opt: ["no-new-privileges:true"]
    environment:
      CONTAINERS: "1"      # GET /containers/json、/containers/{id}/json
      ALLOW_LOGS: "1"      # GET /containers/{id}/logs
      ALLOW_RESTARTS: "1"  # POST /containers/{id}/restart（注意：同一开关也放行 stop/kill，见 §9）
      INFO: "1"
      VERSION: "1"
      PING: "1"
      EVENTS: "0"
      POST: "0"            # 其余所有写操作（create/exec/start/update/build/images/volumes…）一律 403
      DISABLE_IPV6: "1"
      LOG_LEVEL: warning
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro   # 只挂载到 socket-proxy，绝不挂到 panel
    networks: [dockerapi]
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:2375/_ping"]
      interval: 30s
      timeout: 5s
      retries: 3
    logging: *default-logging   # 与其他服务相同的 json-file 10m×3

  panel:
    image: ${PANEL_IMAGE:-homevault/panel:1.0.0}
    pull_policy: never
    build:
      context: ./panel
      args:
        REGISTRY: ${HV_MIRROR_HUB:-docker.io}/library
    restart: unless-stopped
    user: "65532:65532"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    depends_on: [socket-proxy]      # 不依赖 app：Nextcloud 故障时面板仍可用于排查
    environment:
      HV_HOST: ${HV_HOST}
      HV_PUBLIC_URL: ${HV_OVERWRITE_CLI_URL}          # 浏览器访问 Nextcloud 的地址（端口≠443 时带端口）
      NC_INTERNAL_URL: http://app:80
      DOCKER_HOST: tcp://socket-proxy:2375
      COMPOSE_PROJECT: ${COMPOSE_PROJECT_NAME:-homevault}
      PANEL_TRUSTED_PROXIES: ${HV_FRONTEND_SUBNET:-172.31.250.0/24}
      HV_LOG_RETENTION_DAYS: ${HV_LOG_RETENTION_DAYS:-7}
      TZ: ${HV_TZ:-Asia/Shanghai}
    volumes:
      - ${HV_LOG_DIR}:/logs:ro
      - ${HV_LOG_DIR}/panel:/logs/panel     # 唯一可写的日志目录：审计日志 panel.log
      - ./state:/state                       # 读状态文件；只写 state/requests/
    networks: [frontend, dockerapi]
    logging: *default-logging

networks:
  dockerapi:
    internal: true      # 只有 panel 与 socket-proxy
```

要点：
- `panel` 必须在 `frontend` 网络（Caddy 反代到 `panel:8080`，面板访问 `http://app:80`）和 `dockerapi` 网络。
  `frontend` 子网 = `HV_FRONTEND_SUBNET`，已在 Nextcloud 的 `TRUSTED_PROXIES` 中 → Nextcloud 接受面板转发的
  `X-Forwarded-For`（真实客户端 IP 进入 Nextcloud 的防暴力破解和审计日志）。
- 不要发布（`ports:`）panel 或 socket-proxy 的任何端口。
- 面板不需要 caddy 数据卷（见 §5 根证书）。
- 面板不属于任何 profile；Windows 与 Linux 都启用。

### compose.storage.yaml（两个 CLI 生成，已约定）
```yaml
services:
  panel:
    volumes:
      - {type: bind, source: <storage.conf>,          target: /config/storage.conf,   read_only: true}
      - {type: bind, source: <HV_NC_DATA_PATH>,       target: /stat/data,             read_only: true}
      - {type: bind, source: <HV_BACKUP_LOCAL_PATH>,  target: /stat/backup,           read_only: true}  # 仅 local 备份
      - {type: bind, source: <每个扩展存储的主机路径>, target: /stat/storage/<slug>,    read_only: true}
```
- slug = `s` + sha256(主机路径原样 UTF-8 字节) 的前 8 位十六进制（`D:\Photos` → `sea173462`，`/srv/photos` → `s79bc008a`）。
  面板用同一算法把 `/stat/storage/<slug>` 与 storage.conf 里的“名称”对应；对不上时显示 slug。
- 面板只对挂载点做 `statfs`（总量/已用/可用），**不读取文件内容**；Nextcloud 数据目录 0750 属主 33 也没关系。
- 若同一文件系统出现在多个角色中（例如备份目标与主数据在同一块盘），面板会提示“备份目标与…位于同一块磁盘”。
- 完全没有 `/stat/*` 挂载时，面板改用 `state/status.json` 里可选的 `disks` 数组（§4.1）。

---------------------------------------------------------------------------------------------------
## 3. Caddy

仓库的 `caddy/Caddyfile` 已包含（与主站共用证书与 IP 兜底过滤；HTTP/1.1+2；不限制请求体）：

```caddyfile
https://{$HV_HOST}:{$HV_PANEL_PORT} {
	import access_log
	route {
		@outside not remote_ip {$HV_ALLOWED_CIDRS}
		abort @outside
		header Strict-Transport-Security "max-age=15552000"
		header -Server
		reverse_proxy panel:8080
	}
}
```
- caddy 服务需要发布 `${HV_BIND_IP}:${HV_PANEL_PORT}:${HV_PANEL_PORT}`（TCP），并获得环境变量 `HV_PANEL_PORT`（默认 9443）。
- 不要在 Caddy 设置 `trusted_proxies`：Caddy 会把 `X-Forwarded-For` 设为真实来源 IP，面板只信任来自
  `PANEL_TRUSTED_PROXIES`（frontend 子网）的该请求头。
- 面板自身发送严格的安全头（CSP `default-src 'none'; script-src 'self'…`、`X-Frame-Options: DENY`、`nosniff`、
  `Referrer-Policy: no-referrer`、COOP/CORP）；HSTS 由 Caddy 添加。
- Windows 的 VPN 兜底地址（`https://<VPN 服务器 IP>`）如也要打开面板，需要在该站点列表中同样加上 `:HV_PANEL_PORT`。

---------------------------------------------------------------------------------------------------
## 4. 主机 → 面板：状态文件（`state/`，面板只读）

**规范格式 = `panel/internal/hoststate/types.go` 的 json 标签。** Linux（`scripts/`）与 Windows（`windows/lib/`）
写入方必须使用下列字段名。时间字段接受 RFC 3339 字符串（推荐，带时区）、`YYYY-MM-DD HH:MM:SS`、Unix 秒/毫秒或 `null`。
文件 UTF-8（PowerShell 写的 BOM 可接受），先写临时文件再改名，权限 0644，单个文件 ≤ 4 MiB。
解码器另外容忍少数旧字段名（见各节“别名”），**仅作兜底，写入方不要依赖**。

### 4.1 `state/status.json`（每日维护、处理请求后写入）
```json
{
  "updated": "2026-09-26T03:00:05+08:00",
  "version": "1.0.0",
  "platform": "linux",
  "hostname": "homevault",
  "log_retention_days": 7,
  "log_dir": "/srv/homevault/logs",
  "maintenance": {"last_run": "2026-09-26T03:00:05+08:00", "ok": true, "message": "每日维护完成"},
  "requests": {"last_run": "2026-09-26T10:02:00+08:00"},
  "disks": [
    {"role": "data", "name": "Nextcloud 数据", "path": "/srv/homevault/data", "total": 2000398934016, "free": 1500000000000, "mounted": true}
  ]
}
```
- `log_retention_days` 是面板“日志保留天数”的**当前值**来源（缺失时用环境变量 `HV_LOG_RETENTION_DAYS`）。
- `version` 显示为“HomeVault 版本”；`platform` 为 `linux` 或 `windows`。
- `disks`（可选）：`role` 为 `data|storage|backup|system`（也接受 `主数据|扩展存储|备份|系统数据`），`total`/`free` 为字节。
  只在面板没有任何 `/stat/*` 挂载时使用。
- 超过 36 小时未更新 → 概览提示“每日维护任务可能未运行”。
- 别名：`generated`/`updated_at` → `updated`，`homevault_version` → `version`。

### 4.2 `state/backup-status.json`（每次备份结束写入；开始时可写 `"state":"running"`）
```json
{
  "updated": "2026-09-26T03:41:02+08:00",
  "state": "ok",
  "last_run": "2026-09-26T03:30:00+08:00",
  "last_finished": "2026-09-26T03:41:02+08:00",
  "last_success": "2026-09-26T03:41:02+08:00",
  "duration_seconds": 662,
  "message": "备份成功",
  "log_file": "backup/backup-20260926-033000.log",
  "target": "local",
  "repository": "/mnt/backup/restic",
  "schedule": "03:30",
  "next_run": "2026-09-27T03:30:00+08:00",
  "exit_code": 0,
  "stats": {"files_new": 12, "files_changed": 3, "data_added": 104857600, "total_files_processed": 120000, "total_bytes_processed": 812345678901}
}
```
- `state`：`ok | partial | failed | running | never`（小写）。
- `last_success` 缺失时面板也读取 `state/last-backup-ok`（ISO 时间文本，SPEC §10）。超过 48 小时 → 概览报警。
- `log_file` 必须是**相对 `HV_LOG_DIR` 的路径**（面板据此提供“查看备份日志”链接）。
- `target`：`local | s3`；`repository` 不要包含密钥（S3 URL 本身可以）。`stats`、`next_run`、`exit_code` 可省略。
- 别名：`result`/`status` → `state`，`finished` → `last_finished`，`last_ok` → `last_success`，`log` → `log_file`，`generated` → `updated`。

### 4.3 `state/snapshots.json`
`restic snapshots --json` 的**原始输出**（数组，含 `id`、`short_id`、`time`、`hostname`、`paths`、`tags`，restic ≥0.17 另有 `summary`）。
面板按时间倒序显示最近 60 个。

### 4.4 `state/vpn-status.json`（每隔几分钟写入；**绝不包含任何密钥**）
```json
{
  "updated": "2026-09-26T10:00:00+08:00",
  "platform": "linux",
  "interface": "wg0",
  "listen_port": 51820,
  "peers": [
    {"name": "妈妈的手机", "address": "10.99.77.2/32", "enabled": true, "latest_handshake": 1790388000,
     "rx_bytes": 1048576, "tx_bytes": 2097152, "endpoint": "203.0.113.9:40000"}
  ]
}
```
- `latest_handshake`：Unix 秒（`wg show … dump` 原样）或 RFC 3339；`0`/`null` = 从未握手。3 分钟内握手视为在线。
- `rx_bytes`/`tx_bytes` 以服务器视角（`wg show` 的 transfer-rx/tx）。`endpoint`、`enabled`、`listen_port` 可省略（`enabled` 默认 true）。
- 面板在解析时**丢弃**任何其它字段（`public_key`、`preshared_key`… 即使误写入也不会返回给浏览器）。
- 超过 15 分钟未更新 → VPN 页提示“状态可能已过时”。
- 别名：`generated`/`updated_at`/`time` → `updated`；`device` → `interface`；peer 的 `client` → `name`，`ip`/`allowed_ips` → `address`，
  `transfer_rx`/`transfer_tx` → `rx_bytes`/`tx_bytes`，`last_handshake` → `latest_handshake`。

### 4.5 其它文件
| 路径 | 用途 | 写入方 |
|---|---|---|
| `state/ca.crt` | `/ca.crt` 下载的根证书（**只放 root.crt**，0644）。IP 模式（`HV_TLS_MODE=internal`）时每次 install/up/maintenance 从 caddy 容器复制 `/data/caddy/pki/authorities/local/root.crt`；域名模式请删除该文件 | Linux/Windows CLI |
| `state/app/homevault.apk` | `/download/android` 提供的安卓安装包 | `hv android fetch` / `hv.ps1 android fetch` |
| `state/last-backup-ok` | 上次成功备份时间（ISO 文本，可选） | 备份 |
| `/config/storage.conf` | 扩展存储名称/路径/读写/备份（compose.storage.yaml 挂载） | `storage apply` |

面板对 `ca.crt` 只输出其中的 `CERTIFICATE` 块（即使文件里误混入私钥也不会被下载）。

---------------------------------------------------------------------------------------------------
## 5. 面板 → 主机：请求文件（`state/requests/`）

面板只写这一个目录（Linux：`install -d -m 0750 -o 65532 -g 65532 state/requests`）。文件名与内容：

```
state/requests/20260926T101500123Z-log-retention.json      (0640，临时文件 .tmp-* + rename 原子写入)
{"id":"20260926T101500123Z-log-retention","type":"log-retention","days":14,
 "created":"2026-09-26T10:15:00.123Z","requested_by":"hvadmin","client_ip":"10.99.77.2","source":"panel"}
```
- 文件名 = `<id>.json`，`id` = `<UTC 时间 YYYYMMDDTHHMMSSmmmZ>-<type>`，按字典序 = 时间顺序。
- 允许的 `type`（主机也必须只执行这些）：`backup`、`log-clean`、`log-retention`（仅此类型带整数 `days`，1–365）。
- 面板对 `backup`、`log-clean` 去重（已有同类待处理请求时不再新建）；待处理超过 20 个时拒绝新请求。
- 忽略以 `.` 开头的文件（写入中的临时文件）。

**主机结果**（Linux `hv requests process` 已按此实现；Windows 请保持一致）：
把请求文件移动到 `state/requests/done/<id>.json`，**然后**执行，完成后写 `state/requests/done/<id>.result.json`：
```json
{"request":"20260926T101500123Z-log-retention.json","type":"log-retention","ok":true,
 "finished":"2026-09-26T10:15:31+08:00","message":"完成"}
```
面板把两者合并显示：有结果文件 → `ok`/`failed`（依据 `ok`，也接受 `status`/`result`/`state` 字符串）；
只有已移动的请求、没有结果 → “执行中”（超过 6 小时 → “结果未知”）；仍在 `requests/` 下 → “等待主机执行”。
也接受把 `status`/`ok`/`finished`/`message` 直接写回 `done/<id>.json` 的做法。无效请求请同样移入 `done/` 并写 `ok:false`。
请求超过 15 分钟未被处理 → 概览提示“主机上的请求处理任务可能未运行”。

---------------------------------------------------------------------------------------------------
## 6. 环境变量（名称固定，勿改名）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PANEL_LISTEN` | `:8080` | 监听地址 |
| `HV_HOST` | —（与 `HV_PUBLIC_URL` 至少设一个） | 服务器地址（IP 或域名），页面显示用 |
| `HV_PUBLIC_URL` | `https://HV_HOST` | 浏览器访问 Nextcloud 的 URL（Login Flow v2 登录页基于它）。HTTPS 端口≠443 时**必须带端口**，建议 = `HV_OVERWRITE_CLI_URL` |
| `NC_INTERNAL_URL` | `http://app:80` | 面板访问 Nextcloud 的内部地址 |
| `NC_HOST_HEADER` | `HV_PUBLIC_URL` 的 host[:port] | 发给 Nextcloud 的 Host 头（必须在 trusted_domains 中） |
| `ADMIN_GROUP` | `admin` | 允许登录的 Nextcloud 组 |
| `DOCKER_HOST` | `tcp://socket-proxy:2375` | Docker API（只经 socket-proxy） |
| `COMPOSE_PROJECT`（或 `COMPOSE_PROJECT_NAME`） | `homevault` | 按标签 `com.docker.compose.project` 过滤容器 |
| `LOG_DIR` | `/logs` | 日志根目录（只读） |
| `AUDIT_LOG` | `/logs/panel/panel.log` | 审计日志 |
| `STATE_DIR` | `/state` | 状态/请求目录 |
| `STAT_DIR` | `/stat` | 磁盘统计挂载根 |
| `STORAGE_CONF` | `/config/storage.conf,/state/storage.conf` | 取第一个存在的 |
| `CA_CERT_FILE` | `/state/ca.crt` | `/ca.crt` 的来源 |
| `APK_FILE` | `/state/app/homevault.apk` | `/download/android` 的来源 |
| `SESSION_TTL` | `12h` | 会话有效期（1m–168h） |
| `ADMIN_RECHECK` | `5m` | 重新核对应用密码有效且仍是管理员的间隔 |
| `PANEL_TRUSTED_PROXIES` | `HV_FRONTEND_SUBNET`，再缺省 `172.31.250.0/24` | 信任其 `X-Forwarded-For` 的代理网段（逗号/空格分隔） |
| `HV_LOG_RETENTION_DAYS` | `7` | 日志保留天数的缺省值（1–365；status.json 有值时以其为准） |
| `HV_VERSION` | 空 | HomeVault 版本（status.json 有 `version` 时以其为准） |
| `PANEL_RESTART_ALLOW` | 全部 | 只能**缩小**重启白名单（`app,cron,redis,db,caddy,wg-easy,ddns-go`） |
| `TZ` | UTC | 时区（镜像内置时区数据库） |

---------------------------------------------------------------------------------------------------
## 7. 挂载与权限

| 容器路径 | 主机 | 模式 | Linux 权限要求 |
|---|---|---|---|
| `/logs` | `HV_LOG_DIR` | ro | uid 65532 可遍历/读取（`logs_prepare_dirs` 已设置 ACL/0755 目录 + 0644/0640 文件） |
| `/logs/panel` | `HV_LOG_DIR/panel` | rw | 目录属主 65532:65532、0750（**须在 `up` 前创建**，否则 Docker 以 root 创建，审计日志只能输出到容器日志） |
| `/state` | `./state` | rw | 目录可被 65532 遍历（0755）；状态文件 0644；`state/requests` 属主 65532、0750 |
| `/config/storage.conf` | `storage.conf` | ro | 0644 |
| `/stat/...` | 见 §2 | ro | 只需挂载点存在 |

Windows（Docker Desktop）bind mount 没有 uid 限制；`.env` 里的 Windows 路径建议使用正斜杠（`D:/HomeVault/logs`），
并确保 `HV_LOG_DIR\panel` 与 `state\requests` 目录在 `up` 前存在。

审计日志：`/logs/panel/panel.log`，JSON 行 `{"time","action","ok","user","ip","detail"}`（action：`login`、`logout`、
`login_flow_start`、`session_revoked`、`request_backup`、`request_log-clean`、`request_log-retention`、`restart`、`log_download`），
日期变化时面板把旧文件改名为 `panel-YYYY-MM-DD.log`（单文件 20 MiB 上限），由主机的日志保留任务按天数删除。
审计内容同时输出到容器 stdout。

---------------------------------------------------------------------------------------------------
## 8. HTTP 接口（JSON；所有 `/api/*` 带 `Cache-Control: no-store`）

无需登录：
| 方法 路径 | 说明 |
|---|---|
| `GET /healthz` | `ok` |
| `GET /api/info` | `{"app":"homevault-panel","name","version","nextcloud_url","login":"nextcloud-login-flow-v2"}`（安卓应用可用来确认地址是面板） |
| `GET /ca.crt` | 根证书（`application/x-x509-ca-cert`；没有时 404 + 中文说明） |
| `GET /download/android` | APK（`application/vnd.android.package-archive`，支持 Range；没有时 404 + 中文说明） |
| `GET /api/me` | `{"authenticated":false}` 或 `{"authenticated":true,"user","display_name","csrf","expires","method"}` |
| `POST /api/auth/flow` | 开始 Login Flow v2 → `{"login_url","expires_in"}`，并设置 `__Host-hvflow` Cookie |
| `POST /api/auth/flow/poll` | `{"state":"none|pending|failed|ok",...}`；`ok` 时创建会话 |
| `POST /api/auth/flow/cancel` | 取消 |
| `POST /api/auth/password` | 备用：`{"user","app_password"}`（Nextcloud 应用密码） |

需要登录（Cookie `__Host-hvpanel`；POST 另需 `X-CSRF-Token` 头，值来自 `/api/me` 的 `csrf`）：
| 方法 路径 | 说明 |
|---|---|
| `POST /api/auth/logout` | 退出（吊销 Login Flow 创建的设备密码） |
| `GET /api/overview` | 服务（状态/健康/启动时间/重启次数/能否重启）、Docker 信息、磁盘、备份、VPN 摘要、Nextcloud 统计、告警 |
| `GET /api/storage` | 磁盘（角色 主数据/扩展存储/备份、名称、路径、总/已用/可用、同盘提示）、每用户用量与配额（OCS provisioning）、serverinfo、storage.conf |
| `GET /api/backup` | backup-status + 快照 + 备份请求 |
| `POST /api/backup/run` | 写 `backup` 请求（202） |
| `GET /api/logs` | `/logs` 下的 `*.log`、`*.txt`、`*.log.N`、`*.gz` 文件（深度≤4，不跟随符号链接）+ 容器列表 + 保留天数 |
| `GET /api/logs/file?path=&lines=&q=` | 文件尾部 N 行（≤5000，响应≤4 MiB），可搜索，支持 .gz；路径防穿越（`os.Root`，拒绝 `..`、绝对路径、符号链接、隐藏文件） |
| `GET /api/logs/download?path=` | 下载原文件 |
| `GET /api/logs/container/{service}?lines=&q=` | 容器日志（Docker 多路复用流已解码，带时间戳） |
| `GET /api/logs/container/{service}/download?lines=` | 下载容器日志 |
| `POST /api/logs/clean` | 写 `log-clean` 请求 |
| `GET /api/settings/log-retention` | `{"days","min":1,"max":365,"default":7,"pending","recent"}` |
| `POST /api/settings/log-retention` | `{"days":N}`（JSON 整数 1–365）→ 写 `log-retention` 请求 |
| `GET /api/vpn` | 设备名、地址、在线、最近握手、收发流量（无密钥） |
| `POST /api/services/{name}/restart` | 白名单：`app, cron, redis, db, caddy, wg-easy, ddns-go` |
| `GET /api/requests` | 待处理与已完成的请求 |
| `GET /api/about` | 版本、平台、会话信息、APK/根证书可用性与根证书 SHA-256 指纹 |

错误统一为 `{"error":"中文说明"}` + 相应 HTTP 状态码（401 未登录/失效，403 CSRF/跨站/非管理员，429 限速带 `Retry-After`）。

---------------------------------------------------------------------------------------------------
## 9. 登录与安全模型

- **Login Flow v2**：面板在服务端 `POST http://app:80/index.php/login/v2`（`Host: <NC_HOST_HEADER>`，User-Agent
  “HomeVault 管理面板（客户端 IP）”——Nextcloud 授权页显示此名称，也作为设备密码名称），把 `login` 地址改写到
  `HV_PUBLIC_URL` 返回给浏览器，并在后台每 2 秒轮询 `/login/v2/poll`（最长 20 分钟）。用户在 Nextcloud 登录（含两步验证）
  并授权后，面板拿到 `loginName + appPassword`，用 `GET /ocs/v2.php/cloud/user`（`OCS-APIRequest: true`）核对是否为
  `admin` 组成员：不是 → 立即 `DELETE /ocs/v2.php/core/apppassword` 吊销并提示“只有 Nextcloud 管理员可以登录”。
- **安卓 WebView**：页面检测 User-Agent 中的 `HomeVaultApp/`，用 `location.assign(login_url)` 打开登录页——应用的
  `shouldOverrideUrlLoading` 会把其它源（Nextcloud 在 443，面板在 9443）交给手机浏览器打开，WebView 留在面板页面继续轮询；
  用户回到应用（`visibilitychange`/`pageshow`）立即再轮询一次并进入面板。普通浏览器在新标签页打开（点击时同步
  `window.open`，被拦截时退回同窗口跳转，返回键回到面板后继续）。
- **备用方式**：“用户名 + 应用密码”（Nextcloud → 个人设置 → 安全 → 创建新应用密码）。这种密码由用户自己管理，退出时**不会**被吊销。
- **会话**：仅内存；Cookie `__Host-hvpanel`（HttpOnly、Secure、SameSite=Strict、Path=/，12 小时）；服务端只保存 SHA-256 后的 ID；
  最多 100 个会话。应用密码只在内存中用于 OCS 调用；退出、过期、面板停止（SIGTERM）时吊销 Login Flow 创建的设备密码。
  每 5 分钟核对一次：应用密码被删除或用户被移出 admin 组 → 会话立即失效。
- **CSRF**：所有非 GET 请求需 `X-CSRF-Token`，并经 Go `http.CrossOriginProtection`（`Sec-Fetch-Site`/`Origin`）拒绝跨站请求。
- **限速**：开始 Login Flow 每 IP 10 次/10 分钟；应用密码登录失败每 IP 5 次/15 分钟、全局 30 次/15 分钟；同时等待中的 Flow ≤ 50。
  面板把真实客户端 IP 通过 `X-Forwarded-For` 交给 Nextcloud，Nextcloud 自身的防暴力破解按真实 IP 生效。
- **Docker**：面板容器没有 docker.sock；socket-proxy 只放行只读接口与 restart。注意 linuxserver/socket-proxy 的
  `ALLOW_RESTARTS=1` 同时放行 `stop`/`kill`（同一正则）——因此 `dockerapi` 必须是只连接 panel 与 socket-proxy 的 `internal` 网络；
  面板代码只调用 `restart`，且只对白名单服务、本 compose 项目（标签过滤）中的容器。
- **根证书**：没有把 caddy 数据卷挂进面板——Caddy 以 0600/0700（root）保存 `pki/`，uid 65532 本来就读不到，而且那里有 CA 私钥。
  改为由主机把 `root.crt` 复制到 `state/ca.crt`（§4.5）。

---------------------------------------------------------------------------------------------------
## 10. 测试

```sh
cd panel && go vet ./... && go test ./...                 # 单元/集成测试（模拟 Nextcloud 与 Docker）
panel/test/smoke/run.sh [--browser] [--keep] [--no-build] # 真实环境冒烟测试（需要 Docker；--browser 需要 Playwright）
# 多个测试并行时改端口/子网/项目名：
SMOKE_PROJECT=hvpanel SMOKE_NC_PORT=19443 SMOKE_PANEL_PORT=19444 SMOKE_SUBNET=172.31.232.0/24 panel/test/smoke/run.sh
```
冒烟测试覆盖：socket-proxy 放行/拒绝矩阵；真实 Nextcloud 34 Login Flow v2（管理员成功、普通用户被拒且设备密码被吊销）；
应用密码登录与限速；全部 API（使用本文 §4 规范格式的示例状态文件）；请求文件格式与权限；主机结果文件合并；
经 socket-proxy 重启 redis；`/ca.crt` 只含证书；`/download/android`；跨站/缺 CSRF 的 POST 被拒；审计日志；
退出登录与优雅停机时吊销设备密码；可选的 Playwright 手机/深色/桌面页面截图与 CSP 报错检查。

---------------------------------------------------------------------------------------------------
## 11. 与 SPEC §15 的差异

1. `/ca.crt` 的来源是 `state/ca.crt`（主机复制），而不是把 caddy 数据卷只读挂进面板（原因见 §9，已实测 Caddy 的 pki 文件为 root 0600）。
2. 面板写请求文件时带 `id`、`created`、`requested_by`、`client_ip`、`source` 字段；主机只需读取 `type` 与 `days`。
3. `status.json` 增加可选 `disks`（无 `/stat` 挂载时的兜底），`backup-status.json` 增加可选 `exit_code`。
