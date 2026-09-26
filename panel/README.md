# HomeVault 管理面板（`panel/`）

HomeVault 自带的轻量管理面板，也是安卓应用「HomeVault 家庭归档」的服务端。用手机或电脑浏览器打开
`https://<服务器地址>:9443`（端口 = `.env` 里的 `HV_PANEL_PORT`），用 **Nextcloud 管理员账户**登录后可以：

| 页面 | 内容 |
|---|---|
| 概览 | 各服务（Nextcloud、后台任务、数据库、Redis、Caddy、VPN…）的运行状态、健康检查、运行时长、重启次数；HomeVault / Nextcloud 版本；告警（磁盘剩余 < 10%、超过 48 小时没有成功备份、服务异常、主机任务未运行）；可重启白名单内的服务 |
| 存储 | 每块硬盘的角色（主数据 / 扩展存储 / 备份）、名称、路径、总量 / 已用 / 可用，备份与数据同盘提示；Nextcloud 每个用户的用量与配额 |
| 备份 | 最近一次备份的结果、耗时、新增数据量，restic 快照列表；「立即备份」按钮 |
| 日志 | `HV_LOG_DIR` 下的全部日志文件（含 `.gz`）和各容器的日志：查看末尾 N 行、搜索、下载；「立即清理过期日志」 |
| VPN | 手机 / 电脑等 VPN 设备：是否在线、VPN 地址、最近握手时间、收发流量（不显示任何密钥） |
| 设置 | 日志保留天数（1–365，默认 7）、安卓应用下载二维码、根证书下载（IP 模式）、外观（浅色 / 深色 / 跟随系统）、最近提交给主机的请求、关于 |

界面为简体中文、手机优先，支持深色模式，可“添加到主屏幕”（PWA）。

## 登录

- **推荐：使用 Nextcloud 登录**（Nextcloud Login Flow v2）。点击后会打开 Nextcloud 的登录页（包括两步验证），
  点「授权访问」（英文界面是 Grant access）后回到面板即自动进入。在安卓应用里登录页会用手机浏览器打开，登录后切回应用即可。
  授权页显示的名称是「HomeVault 管理面板（你的 IP）」——**只在自己发起登录时授权**。
- **备用：用户名 + 应用密码**。在 Nextcloud 网页：头像 → 个人设置 → 安全 → 创建新应用密码。
- 只有 Nextcloud **`admin` 组**成员可以登录；普通用户即使在 Nextcloud 授权也会被拒绝（面板会立即删除为其创建的设备密码）。
- 会话 12 小时；每 5 分钟核对一次账户：在 Nextcloud 里删除设备密码或把用户移出 admin 组，会话立即失效。
- 退出登录时，面板会删除登录时在 Nextcloud 创建的设备密码（自己手动创建的应用密码不会被删除）。

## 面板能做什么、不能做什么

面板只做“查看 + 少量安全的操作”，不会、也无法执行任意命令：

- **Docker**：面板本身没有 `docker.sock`。它只能通过 `socket-proxy`（只读 Docker API 代理，只连接一个内部网络）
  查看容器状态和日志，并重启白名单中的服务：`app`、`cron`、`redis`、`db`、`caddy`、`wg-easy`、`ddns-go`。
- **需要在主机上执行的操作**（立即备份、清理日志、修改日志保留天数）：面板只在 `state/requests/` 写一个请求文件，
  由主机上的任务处理（Linux：`homevault-requests.path` → `hv requests process`，几秒内执行；
  Windows：计划任务 `HomeVault-Requests`，每 2 分钟一次 → `hv.ps1 requests process`）。主机只执行这三种请求。
- **磁盘容量**：只对只读挂载的目录做 `statfs`，不读取任何文件内容。
- **日志**：只读；只能访问 `HV_LOG_DIR` 下的 `*.log`、`*.txt`、`*.log.N`、`*.gz`，拒绝 `..`、绝对路径、符号链接和隐藏文件。
- 所有登录、退出、重启、下载日志、提交请求都记录在审计日志 `HV_LOG_DIR/panel/panel.log`。

## 无需登录即可访问的地址

| 地址 | 用途 |
|---|---|
| `https://<服务器>:9443/ca.crt` | 下载 HomeVault 根证书（IP 模式；手机安装后才信任服务器证书）。域名模式不需要，会返回 404 说明 |
| `https://<服务器>:9443/download/android` | 下载安卓应用安装包（先在服务器上运行 `hv android fetch` / `hv.ps1 android fetch`） |
| `https://<服务器>:9443/healthz` | 健康检查 |
| `https://<服务器>:9443/api/info` | 面板标识与版本（`{"app":"homevault-panel","version":…,"nextcloud_url":…}`），安卓应用“测试连接”用它确认地址填对了；不含任何状态信息 |

## 常见问题

| 现象 | 原因与处理 |
|---|---|
| 浏览器提示证书不受信任 | IP 模式需要在手机 / 电脑上安装根证书（见 `docs/05-安卓手机备份.md`）。 |
| 「无法连接 Nextcloud」 | `app` 容器未运行或仍在启动（首次安装 / 升级时可能需要几分钟）。在「概览」查看或运行 `hv status`。 |
| 「只有 Nextcloud 管理员（admin 组成员）可以登录管理面板」 | 用管理员账户（默认 `hvadmin`）登录，或在 Nextcloud 把该用户加入 `admin` 组。 |
| 「无法连接 Docker」/「Docker 代理拒绝了请求」 | `socket-proxy` 服务未运行：`hv up`（Windows：菜单「2 启动」）。 |
| 「有请求超过 15 分钟未被主机处理」 | 主机上的请求处理任务未运行。Linux：`systemctl status homevault-requests.path`；Windows：检查计划任务 `HomeVault-Requests`；或手动运行 `hv requests process`。 |
| 「主机状态文件超过 36 小时未更新」 | 每日维护任务未运行。Linux：`systemctl status homevault-maintenance.timer`；Windows：计划任务 `HomeVault-Maintenance`。 |
| 存储页没有硬盘 | 运行一次 `hv storage apply`（会生成 `compose.storage.yaml` 中给面板的只读挂载）后 `hv up`。 |
| 修改了日志保留天数但显示的还是旧值 | 请求要等主机处理（Linux 几秒，Windows 最多约 2 分钟），处理后刷新页面即可。 |
| 打开日志提示「管理面板没有权限读取该日志文件」 | Linux 宿主机缺少 `setfacl`：安装 `acl`（`apt install acl` / `dnf install acl`）后运行 `sudo ./hv up`。 |
| 在面板里重启「HTTPS 网关（Caddy）」后页面短暂打不开 | 正常：面板本身经过 Caddy，重启期间连接会中断几秒钟，之后刷新即可。 |
| 电脑给 Docker 配置了代理 | 不影响面板：Compose 会把代理设置注入容器，但面板访问 Nextcloud 和 Docker 时始终直连。 |

## 开发者

- Go 1.26，**只用标准库**，编译为静态二进制；前端为原生 JS/CSS（无构建步骤），用 `embed` 打包进二进制；严格 CSP（无内联脚本）。
- 镜像在本机构建（`scratch` 基础镜像，uid 65532，只读根文件系统，约 12 MB）：
  ```sh
  docker build -t homevault/panel:1.0.0 panel/
  # 国内：docker build -t homevault/panel:1.0.0 --build-arg REGISTRY=docker.m.daocloud.io/library panel/
  ```
  `hv install` / `hv up` 在镜像不存在时自动构建（compose 里 `pull_policy: never` + `build:`）。
- 子命令：`/panel serve`（默认）、`/panel healthcheck`（Docker 健康检查）、`/panel version`。
- 测试：
  ```sh
  cd panel && go vet ./... && go test ./...
  panel/test/smoke/run.sh [--browser] [--keep] [--no-build]   # 真实 Nextcloud 34 + PostgreSQL 18 + Caddy + socket-proxy
  ```
- 目录：`cmd/panel`（入口）· `internal/server`（路由、接口、静态文件）· `internal/auth`（会话、Login Flow、限速）·
  `internal/nextcloud`（Login Flow v2、OCS）· `internal/docker`（经 socket-proxy 的 Docker API）· `internal/hoststate`
  （主机状态文件与请求文件，**规范格式见 `types.go`**）· `internal/logfiles` · `internal/diskstat` · `internal/audit` ·
  `internal/config` · `web/`（前端）· `test/smoke/`（真实环境冒烟测试）。
- 与 compose、Caddy、Linux/Windows 命令行、安卓应用之间的接口约定（环境变量、挂载、状态文件格式、请求文件、HTTP 接口）：
  见 [INTEGRATION.md](INTEGRATION.md)。
