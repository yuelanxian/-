# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# Chinese help texts.

help_main() {
	if [[ -n ${1:-} ]]; then
		help_cmd "$1"
		return
	fi
	cat <<EOF
HomeVault 家庭归档服务器 —— Linux 管理工具 v$HV_VERSION

用法：$HV_SELF <命令> [参数]      （需要 root 的命令请加 sudo）

安装与运行
  install              交互式安装（或 --non-interactive 配合参数）；可重复运行，不会重新生成密码
  up | down | restart  启动 / 停止（保留数据）/ 重启全部服务
  status               查看容器状态
  logs [服务…]         查看容器日志；logs list|show|retention|clean 管理日志文件
  pull                 拉取镜像
  update [--major]     先备份再升级（--major：Nextcloud 升一个大版本）
  doctor               健康与安全检查（✔/✘/!）

Nextcloud
  occ <参数…>          执行 Nextcloud occ 命令（以 www-data 身份）
  harden               重新执行安全加固并显示关键设置
  user add|list|reset-2fa|reset-password   用户管理
  ca [--export 路径]   导出本地根证书（IP 模式），显示指纹与安装方法

存储与备份
  storage list|add|remove|apply   多硬盘：额外存储挂载
  backup [--init] [--check]       立即备份（restic）
  restore [--files 路径 | --full] [--snapshot ID]   从备份恢复
  schedule-backup [--time HH:MM]  安装每日定时备份（systemd）

网络与安全
  vpn [info|status|finalize|list|qr|add|reset-password]   WireGuard（wg-easy）
  ddns setup|status|disable       动态域名（ddns-go）
  firewall [--apply|--show|--remove]   主机防火墙（DOCKER-USER → HOMEVAULT）

其他
  maintenance          每日维护（日志导出/轮转/清理、状态文件），由 systemd 定时执行
  android fetch        下载 HomeVault 安卓 App 到 state/app/，供手机从管理面板下载
  compose <参数…>      以正确的文件/项目参数调用 docker compose（高级）
  help <命令>          查看某个命令的详细说明

通用参数：--yes/-y 跳过确认；--non-interactive 不提问（使用默认值）
文档：README.md 与 docs/ 目录（手机设置见 docs/05-安卓手机备份.md）
EOF
}

help_cmd() {
	case ${1:-} in
	install)
		cat <<EOF
用法：sudo $HV_SELF install [参数]

不带参数时逐项提问（回车使用默认值）。可重复运行：已有的密钥和 .env 设置会保留。
  --non-interactive        不提问，未指定的项使用 .env 中的值或默认值
  --yes                    自动确认
  --host <域名或IP>        客户端访问地址（IP = IP 模式；域名 = 域名模式，自动申请证书）
  --lan-ip <IP>            本机局域网 IP（默认自动检测）
  --lan-cidr <网段>        局域网网段（默认自动检测，如 192.168.1.0/24）
  --bind-ip <IP>           端口绑定的 IPv4（默认 = 局域网 IP）
  --extra-hosts "<名称…>"  额外的访问名称（空格分隔）
  --http-port / --https-port / --admin-port / --panel-port <端口>   默认 80 / 443 / 8443 / 9443
  --data-dir <目录>        HomeVault 数据目录（默认 /srv/homevault）
  --nc-data-path <目录>    Nextcloud 文件目录（默认 <数据目录>/nextcloud-data）
  --tls-mode internal|acme-dns   证书模式（默认按 --host 自动选择）
  --dns-provider alidns|tencentcloud|cloudflare  --acme-email <邮箱>
  --dns-id <ID> --dns-secret-file <文件>          DNS API 凭据（域名模式）
  --mirror none|daocloud|custom [--mirror-hub 前缀 --mirror-ghcr 前缀]   镜像加速
  --backup-local-path <目录>   本地备份目录（请用另一块硬盘）
  --backup-target s3 --s3-repo <仓库> [--s3-options "<选项>"] --s3-key-id <ID> --s3-secret-file <文件>
  --admin-user <用户名>    Nextcloud 管理员（默认 hvadmin）
  --project-name <名称>    Compose 项目名（默认 homevault，也可用环境变量 COMPOSE_PROJECT_NAME）
  --no-vpn                 不启用 VPN
  --wg-host <域名或IP> --wg-port <端口> --vpn-lan-access host|full
  --log-retention <天数>   日志保留天数（1–365，默认 7）
  --no-firewall            不设置主机防火墙；--ufw 非交互时也配置 ufw
  --no-systemd             不安装 systemd 定时任务（维护/状态/备份）
  --frontend-subnet <网段> Docker 前端网络网段（默认 172.31.250.0/24，与现有网络冲突时更换）
  --timeout <秒>           等待 Nextcloud 就绪的最长时间（默认 1800）
  --no-start               只写入配置与密钥，不启动服务
EOF
		;;
	storage)
		cat <<EOF
用法：
  $HV_SELF storage list                          显示硬盘表和已配置的存储
  sudo $HV_SELF storage add [--name 名称 --path 目录 --mode rw|ro --backup yes|no --users "a,b,@组"] [--apply|--no-apply]
  sudo $HV_SELF storage remove <名称> [--apply]  从 HomeVault 移除（不删除文件）
  sudo $HV_SELF storage apply [--acl]            生成 compose.storage.yaml，重建容器并同步 Nextcloud 挂载
storage.conf 格式：名称|主机路径|rw或ro|是否备份(yes/no)|可见用户(空=所有用户; 逗号分隔; @开头为群组)
EOF
		;;
	backup)
		cat <<EOF
用法：sudo $HV_SELF backup [--init] [--check]
  --init       仓库不存在时先初始化
  --check      备份后校验 5% 的数据（每周日自动执行）
  --list       列出快照
  --unlock     清除残留的仓库锁
流程：维护模式 → 导出数据库 → 关闭维护模式（总会执行）→ restic 备份 → 按保留策略清理 → 写入 state/last-backup-ok
EOF
		;;
	restore)
		cat <<EOF
用法：
  sudo $HV_SELF restore                                   列出快照
  sudo $HV_SELF restore --ls <目录> [--snapshot ID]       查看快照内容（如 /src 或 alice/files）
  sudo $HV_SELF restore --files <路径> [--snapshot ID]    恢复文件到 restore/<时间>/（不覆盖现有数据）
      <路径> 可写成「用户名/files/照片/2024」（相对 Nextcloud 数据目录）或快照内绝对路径（/src/...）
  sudo $HV_SELF restore --full [--snapshot ID]            整机灾难恢复（双重确认；非交互需 --yes --force）
EOF
		;;
	schedule-backup)
		msg "用法：sudo $HV_SELF schedule-backup [--time HH:MM] [--remove]   （默认使用 .env 的 HV_BACKUP_TIME）"
		;;
	update)
		msg "用法：sudo $HV_SELF update [--major] [--skip-backup]   先备份，再拉取镜像并重建；--major 把 Nextcloud 升一个主版本"
		;;
	firewall)
		cat <<EOF
用法：sudo $HV_SELF firewall [--apply|--show|--remove] [--ssh-port 22] [--no-ufw]
  --apply   在 DOCKER-USER 链插入 HOMEVAULT 链：来自 HV_ALLOWED_CIDRS 以外来源、访问 HomeVault TCP 端口的新连接被丢弃；
            安装 homevault-firewall.service 开机自动应用；如有 ufw，设置默认拒绝入站、仅局域网可 SSH
  --show    显示当前规则（默认）
  --remove  移除规则
EOF
		;;
	vpn)
		cat <<EOF
用法：
  $HV_SELF vpn [info]              管理地址、账号、路由器设置
  $HV_SELF vpn status              同上并显示容器状态
  sudo $HV_SELF vpn finalize [--skip-api]   通过 API 设置钩子/默认参数，删除初始化密码文件并重建容器
  $HV_SELF vpn list                列出设备
  $HV_SELF vpn qr <ID>             在终端显示设备二维码
  sudo $HV_SELF vpn add <设备名>   新建设备（仅在未启用 wg-easy 两步验证时可用）
  sudo $HV_SELF vpn reset-password 重置 wg-easy 管理员密码（同时清除两步验证）
EOF
		;;
	ddns)
		cat <<EOF
用法：
  sudo $HV_SELF ddns setup [--provider alidns|tencentcloud|dnspod|cloudflare|huaweicloud --domain 域名 --id ID --secret-file 文件]
  $HV_SELF ddns status
  sudo $HV_SELF ddns disable
EOF
		;;
	user)
		cat <<EOF
用法：
  $HV_SELF user add <用户名> [--admin] [--quota 500GB] [--display-name 名字]   （初始密码只显示一次）
  $HV_SELF user list
  $HV_SELF user reset-2fa <用户名>
  $HV_SELF user reset-password <用户名>
EOF
		;;
	ca) msg "用法：$HV_SELF ca [--export 路径]   导出 Caddy 本地根证书（默认 clients/HomeVault-CA.crt）并显示指纹与安装方法" ;;
	logs)
		cat <<EOF
用法：
  $HV_SELF logs [服务…]                  跟随容器日志（app caddy db …）
  $HV_SELF logs list                     列出日志文件（HV_LOG_DIR）
  $HV_SELF logs show <文件|服务> [--lines N]
  sudo $HV_SELF logs retention [天数]    查看/设置日志保留天数（1–365）
  sudo $HV_SELF logs clean               立即清理过期日志
EOF
		;;
	*) help_main "" ;;
	esac
}
