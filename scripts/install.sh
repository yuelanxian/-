# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# hv install — interactive (Chinese prompts) or --non-interactive installation (SPEC §11).

HV_MIN_COMPOSE=2.24.0
HV_MIN_ENGINE=${HV_MIN_ENGINE:-28.0.0}
HV_SECRET_FILES=(postgres_password redis_password nextcloud_admin_password restic_password)

# mirror_rewrite IMAGE HUB_PREFIX GHCR_PREFIX OLD_HUB OLD_GHCR → image with registry prefix swapped
mirror_rewrite() {
	local img=$1 hub=$2 ghcr=$3 old_hub=${4:-} old_ghcr=${5:-}
	# canonicalise a previously applied mirror back to the upstream registry
	if [[ -n $old_hub && $old_hub != docker.io/ && $img == "$old_hub"* ]]; then
		img="docker.io/${img#"$old_hub"}"
	elif [[ -n $old_ghcr && $old_ghcr != ghcr.io/ && $img == "$old_ghcr"* ]]; then
		img="ghcr.io/${img#"$old_ghcr"}"
	fi
	if [[ $img == docker.io/* ]]; then
		img="${hub}${img#docker.io/}"
	elif [[ $img == ghcr.io/* ]]; then
		img="${ghcr}${img#ghcr.io/}"
	fi
	printf '%s\n' "$img"
}

# Apply registry prefixes to every *_IMAGE key in .env
mirror_apply() {
	local hub=$1 ghcr=$2 key val new line
	[[ $hub == */ ]] || hub+=/
	[[ $ghcr == */ ]] || ghcr+=/
	while IFS= read -r line; do
		[[ $line =~ ^([A-Z0-9_]+_IMAGE)= ]] || continue
		key=${BASH_REMATCH[1]}
		val=$(env_get "$key" || true)
		[[ -n $val ]] || continue
		new=$(mirror_rewrite "$val" "$hub" "$ghcr" "${HV_MIRROR_HUB:-}" "${HV_MIRROR_GHCR:-}")
		[[ $new == "$val" ]] || env_set "$key" "$new"
	done <"$HV_ENV_FILE"
	env_set HV_MIRROR_HUB "$hub"
	env_set HV_MIRROR_GHCR "$ghcr"
	if [[ $hub == docker.io/ ]]; then
		env_set HV_GOPROXY 'https://proxy.golang.org,direct'
	else
		env_set HV_GOPROXY 'https://goproxy.cn,direct'
	fi
}

install_preflight() {
	local v
	title "环境检查"
	[[ $(uname -s) == Linux ]] || die "此脚本仅支持 Linux（Windows 请使用 windows\\hv.ps1）"
	[[ -r /etc/os-release ]] && ok "系统：$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}")"
	have docker || die "未安装 Docker。请先安装 Docker Engine ≥ 28（国内可用阿里云镜像：https://mirrors.aliyun.com/docker-ce/）"
	docker info >/dev/null 2>&1 || die "无法连接 Docker 守护进程（systemctl start docker）"
	v=$(docker version -f '{{.Server.Version}}' 2>/dev/null || echo 0)
	version_ge "$v" "$HV_MIN_ENGINE" || die "Docker Engine 版本 $v 过低，需要 ≥ $HV_MIN_ENGINE（旧版本同一局域网的主机可以访问绑定到 127.0.0.1 的端口）"
	ok "Docker Engine $v"
	v=$(docker compose version --short 2>/dev/null || echo 0)
	v=${v#v}
	version_ge "$v" "$HV_MIN_COMPOSE" || die "Docker Compose 版本 $v 过低，需要 ≥ $HV_MIN_COMPOSE（安装 docker-compose-plugin）"
	ok "Docker Compose $v"
	have curl || warn "未安装 curl（部分功能需要）"
	have openssl || warn "未安装 openssl（证书指纹将用备用方法计算）"
	[[ -f $HV_ROOT/compose.yaml ]] || die "缺少 compose.yaml"
	[[ -f $HV_ROOT/.env.example ]] || die "缺少 .env.example"
}

install_check_ports() {
	local p
	[[ -n $(dc_cid caddy 2>/dev/null) ]] && return 0 # our own stack already holds the ports
	for p in "$HV_HTTP_PORT" "$HV_HTTPS_PORT" "$HV_ADMIN_PORT" "$HV_PANEL_PORT"; do
		if port_in_use "$p" "$HV_BIND_IP"; then
			die "端口 $p 已被占用（可用 --http-port/--https-port/--admin-port/--panel-port 更换）"
		fi
	done
	ok "端口 $HV_HTTP_PORT/$HV_HTTPS_PORT/$HV_ADMIN_PORT/$HV_PANEL_PORT 可用"
}

install_secret() {
	local f=$HV_ROOT/secrets/$1
	if [[ ! -s $f ]]; then
		(umask 022 && gen_secret 32 >"$f")
		chmod 0644 "$f"
		return 0
	fi
	return 1
}

# mkdir with owner/mode for bind-mount paths (only absolute paths)
install_dir() {
	local path=$1 mode=$2 owner=${3:-}
	[[ $path == /* ]] || return 0
	if [[ ! -d $path ]]; then
		install -d -m "$mode" "$path"
		[[ -n $owner ]] && chown "$owner" "$path"
	elif [[ -n $owner && $(stat -c '%u:%g' "$path") != "$owner" ]]; then
		chown "$owner" "$path"
		chmod "$mode" "$path"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# DNS provider credentials (domain mode): one file per value in secrets/caddy-dns/<NAME>, mounted read-only
# into Caddy by compose.acme.yaml and read with {file.*} placeholders — never environment variables
# (the panel can inspect containers through the socket proxy, and inspect shows the environment).
# Files 0644 like the other secrets: the 0700 secrets/ directory protects them on the host.
# ---------------------------------------------------------------------------
HV_CADDY_DNS_KEYS=(ALIYUN_ACCESS_KEY_ID ALIYUN_ACCESS_KEY_SECRET TENCENTCLOUD_SECRET_ID TENCENTCLOUD_SECRET_KEY CF_API_TOKEN)

caddy_dns_dir() { printf '%s\n' "$HV_ROOT/secrets/caddy-dns"; }

# caddy_dns_keys PROVIDER → credential names (one per line)
caddy_dns_keys() {
	case $1 in
	alidns) printf '%s\n' ALIYUN_ACCESS_KEY_ID ALIYUN_ACCESS_KEY_SECRET ;;
	tencentcloud) printf '%s\n' TENCENTCLOUD_SECRET_ID TENCENTCLOUD_SECRET_KEY ;;
	cloudflare) printf '%s\n' CF_API_TOKEN ;;
	esac
}

# caddy_dns_write NAME VALUE — atomic, single line
caddy_dns_write() {
	local d f
	d=$(caddy_dns_dir)
	install -d -m 0700 "$HV_ROOT/secrets"
	install -d -m 0755 "$d"
	f=$d/$1
	(umask 022 && printf '%s\n' "$2" >"$f.tmp") || return 1
	chmod 0644 "$f.tmp" && mv -f "$f.tmp" "$f"
}

# caddy_dns_have_creds PROVIDER — every credential file present and non-empty
caddy_dns_have_creds() {
	local k d any=0
	d=$(caddy_dns_dir)
	while IFS= read -r k; do
		[[ -n $k ]] || continue
		any=1
		[[ -s $d/$k ]] || return 1
	done < <(caddy_dns_keys "$1")
	((any))
}

install_write_provider_env() { # provider id secret
	case $1 in
	alidns) caddy_dns_write ALIYUN_ACCESS_KEY_ID "$2" && caddy_dns_write ALIYUN_ACCESS_KEY_SECRET "$3" ;;
	tencentcloud) caddy_dns_write TENCENTCLOUD_SECRET_ID "$2" && caddy_dns_write TENCENTCLOUD_SECRET_KEY "$3" ;;
	cloudflare) caddy_dns_write CF_API_TOKEN "$3" ;;
	*) return 1 ;;
	esac
}

# Older installations kept the credentials in secrets/caddy-dns.env (compose env_file → container environment):
# move them into secrets/caddy-dns/<NAME> (existing files win) and delete the old file. Idempotent.
caddy_dns_migrate() {
	local old=$HV_ROOT/secrets/caddy-dns.env k v n=0
	[[ -f $old ]] || return 0
	for k in "${HV_CADDY_DNS_KEYS[@]}"; do
		v=$(env_get_file "$k" "$old") || continue
		v=$(trim "$v")
		[[ -n $v ]] || continue
		if [[ ! -s $(caddy_dns_dir)/$k ]]; then
			caddy_dns_write "$k" "$v" || die "无法写入 secrets/caddy-dns/$k"
		fi
		n=$((n + 1))
	done
	rm -f "$old"
	info "DNS API 凭据已从 secrets/caddy-dns.env 迁移到 secrets/caddy-dns/（$n 项；不再以环境变量传给 Caddy）"
}

# Domain mode: compose.acme.yaml mounts secrets/caddy-dns (never auto-created) — make sure it exists and
# warn when the provider's credentials are missing (Caddy then cannot obtain certificates).
caddy_dns_check() {
	[[ ${HV_TLS_MODE:-internal} == acme-dns ]] || return 0
	install -d -m 0700 "$HV_ROOT/secrets"
	install -d -m 0755 "$(caddy_dns_dir)"
	caddy_dns_have_creds "${HV_DNS_PROVIDER:-}" && return 0
	warn "域名模式缺少 DNS API 凭据文件：$(caddy_dns_keys "${HV_DNS_PROVIDER:-}" | sed 's#^#secrets/caddy-dns/#' | paste -sd ' ' -)"
	warn "  Caddy 将无法申请证书。请重新运行 sudo $HV_SELF install 输入凭据，或把每一项写入同名文件（只写该值）后运行 sudo $HV_SELF up"
	return 1
}

install_summary() {
	local first=$1 fp='' ca=$HV_ROOT/clients/HomeVault-CA.crt
	printf '\n%s================ HomeVault 安装完成 ================%s\n' "$_C_BLD" "$_C_RST"
	msg "访问地址（手机/电脑/浏览器统一使用）：$HV_OVERWRITE_CLI_URL"
	msg "管理面板（手机 App / 浏览器，用 Nextcloud 管理员登录）：$(hv_panel_url)"
	msg "日志目录：${HV_LOG_DIR}（保留 $(logs_retention_days) 天；修改：sudo $HV_SELF logs retention <天数>）"
	if ((first)); then
		msg "Nextcloud 管理员：$HV_ADMIN_USER"
		msg "初始密码（只显示这一次）：$(cat "$HV_ROOT/secrets/nextcloud_admin_password")"
		msg "  → 首次登录后按提示绑定两步验证（TOTP，例如「Google 身份验证器」/「Microsoft Authenticator」）"
		if backup_configured; then
			msg "restic 备份密码（只显示这一次，请抄在纸上离线保存！丢失后任何备份都无法恢复）："
			msg "  $(cat "$HV_ROOT/secrets/restic_password")"
		fi
	else
		msg "管理员：$HV_ADMIN_USER（密码未变化；忘记可运行 sudo $HV_SELF user reset-password $HV_ADMIN_USER）"
	fi
	if [[ $HV_TLS_MODE == internal && -f $ca ]]; then
		fp=$(cert_fingerprint "$ca")
		msg "根证书：$ca"
		msg "  SHA-256 指纹：$fp"
		msg "  每台手机/电脑需安装一次（$HV_SELF ca 显示安装方法；手机也可浏览器打开 $(hv_panel_url)/ca.crt 下载）"
	fi
	if vpn_enabled; then
		msg "VPN 管理界面：https://$HV_HOST:$HV_ADMIN_PORT （用户 hvadmin，密码见 secrets/wg_easy_admin_password）"
		msg "路由器设置：只需把 UDP $WG_PORT 转发到 $HV_LAN_IP:$WG_PORT（不要转发 TCP 端口，不要开 DMZ）"
		msg "手机 VPN 连接地址：$WG_HOST:$WG_PORT"
	fi
	msg "手机自动备份设置清单：docs/05-安卓手机备份.md"
	msg "下一步：sudo $HV_SELF doctor（健康检查）· $HV_SELF user add <名字>（添加家人）· $HV_SELF storage list（硬盘）"
	printf '%s====================================================%s\n' "$_C_BLD" "$_C_RST"
}

cmd_install() {
	local o_host='' o_lan_ip='' o_lan_cidr='' o_bind='' o_https='' o_http='' o_admin='' o_panel='' o_data='' o_ncdata=''
	local o_tls='' o_provider='' o_email='' o_dns_id='' o_dns_secret_file='' o_mirror='' o_mirror_hub='' o_mirror_ghcr=''
	local o_backup_target='' o_backup_path='' o_s3_repo='' o_s3_opts='' o_s3_id='' o_s3_secret_file=''
	local o_admin_user='' o_project=${COMPOSE_PROJECT_NAME:-} o_wg_host='' o_wg_port='' o_vpn=1 o_vpn_access='' o_extra_hosts=''
	local o_log_days='' o_firewall=1 o_ufw=0 o_systemd=1 o_timeout=1800 o_retention_set=0 o_subnet='' o_start=1
	local first=1 lan det_ip det_cidr domain v secret changed_vpn=0 rc=0 prev_backup='' prev_ncdata=''
	while (($#)); do
		case $1 in
		--non-interactive) HV_NONINTERACTIVE=1 ;;
		--yes | -y) HV_YES=1 ;;
		--host) o_host=${2:?}; shift ;;
		--lan-ip) o_lan_ip=${2:?}; shift ;;
		--lan-cidr) o_lan_cidr=${2:?}; shift ;;
		--bind-ip) o_bind=${2:?}; shift ;;
		--extra-hosts) o_extra_hosts=${2-}; shift ;;
		--https-port) o_https=${2:?}; shift ;;
		--http-port) o_http=${2:?}; shift ;;
		--admin-port) o_admin=${2:?}; shift ;;
		--panel-port) o_panel=${2:?}; shift ;;
		--data-dir) o_data=${2:?}; shift ;;
		--nc-data-path) o_ncdata=${2:?}; shift ;;
		--tls-mode) o_tls=${2:?}; shift ;;
		--dns-provider) o_provider=${2:?}; shift ;;
		--acme-email) o_email=${2:?}; shift ;;
		--dns-id) o_dns_id=${2:?}; shift ;;
		--dns-secret-file) o_dns_secret_file=${2:?}; shift ;;
		--mirror) o_mirror=${2:?}; shift ;;
		--mirror-hub) o_mirror_hub=${2:?}; shift ;;
		--mirror-ghcr) o_mirror_ghcr=${2:?}; shift ;;
		--backup-target) o_backup_target=${2:?}; shift ;;
		--backup-local-path) o_backup_path=${2:?}; shift ;;
		--s3-repo) o_s3_repo=${2:?}; shift ;;
		--s3-options) o_s3_opts=${2-}; shift ;;
		--s3-key-id) o_s3_id=${2:?}; shift ;;
		--s3-secret-file) o_s3_secret_file=${2:?}; shift ;;
		--admin-user) o_admin_user=${2:?}; shift ;;
		--project-name) o_project=${2:?}; shift ;;
		--wg-host) o_wg_host=${2:?}; shift ;;
		--wg-port) o_wg_port=${2:?}; shift ;;
		--vpn-lan-access) o_vpn_access=${2:?}; shift ;;
		--no-vpn) o_vpn=0 ;;
		--log-retention) o_log_days=${2:?}; o_retention_set=1; shift ;;
		--no-firewall) o_firewall=0 ;;
		--ufw) o_ufw=1 ;;
		--no-systemd | --no-schedule) o_systemd=0 ;;
		--timeout) o_timeout=${2:?}; shift ;;
		--frontend-subnet) o_subnet=${2:?}; shift ;;
		--no-start) o_start=0 ;;
		-h | --help) help_cmd install; return 0 ;;
		*) die "未知参数：$1（$HV_SELF install --help 查看用法）" ;;
		esac
		shift
	done
	require_root
	install_preflight

	# ---- .env ---------------------------------------------------------------
	install -d -m 0755 "$HV_STATE_DIR"
	[[ -f $HV_STATE_DIR/installed ]] && first=0
	local fresh_env=0
	if [[ ! -f $HV_ENV_FILE ]]; then
		(umask 077 && cp "$HV_ROOT/.env.example" "$HV_ENV_FILE")
		info "已根据 .env.example 创建 .env"
		fresh_env=1
	fi
	chmod 0600 "$HV_ENV_FILE"
	env_load
	if ((fresh_env)); then
		# .env.example contains placeholder addresses/paths: use detection and --data-dir instead
		HV_HOST='' HV_LAN_IP='' HV_LAN_CIDR='' HV_BIND_IP='' HV_NC_DATA_PATH='' HV_DUMP_DIR='' HV_LOG_DIR=''
	fi
	env_defaults
	env_set HV_PLATFORM linux

	if [[ -n $o_project ]]; then
		[[ $o_project =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "项目名只能包含小写字母、数字、- 和 _：$o_project"
		env_set COMPOSE_PROJECT_NAME "$o_project"
	fi

	# ---- network ------------------------------------------------------------
	title "网络"
	lan=$(detect_lan)
	det_ip=$(awk '{print $1}' <<<"$lan")
	det_cidr=$(awk '{print $3}' <<<"$lan")
	v=${o_lan_ip:-$(ask "本机局域网 IP（建议在路由器中设为固定/DHCP 保留）" "${HV_LAN_IP:-$det_ip}")}
	is_ipv4 "$v" || die "无效的局域网 IP：$v"
	env_set HV_LAN_IP "$v"
	if [[ -n $o_lan_cidr ]]; then
		v=$o_lan_cidr
	elif [[ -n $HV_LAN_CIDR ]] && ip_in_cidr "$HV_LAN_IP" "$HV_LAN_CIDR"; then
		v=$HV_LAN_CIDR
	elif [[ -n $det_cidr ]] && ip_in_cidr "$HV_LAN_IP" "$det_cidr"; then
		v=$det_cidr
	else
		v=$(cidr_network "$HV_LAN_IP/24")
	fi
	is_ipv4_cidr "$v" || die "无效的局域网网段：$v"
	env_set HV_LAN_CIDR "$(cidr_network "$v")"
	env_set HV_BIND_IP "${o_bind:-${HV_BIND_IP:-$HV_LAN_IP}}"
	is_ipv4 "$HV_BIND_IP" || die "无效的绑定 IP：$HV_BIND_IP"
	[[ -n $o_http ]] && env_set HV_HTTP_PORT "$o_http"
	[[ -n $o_https ]] && env_set HV_HTTPS_PORT "$o_https"
	[[ -n $o_admin ]] && env_set HV_ADMIN_PORT "$o_admin"
	[[ -n $o_panel ]] && env_set HV_PANEL_PORT "$o_panel"
	[[ -n $o_extra_hosts ]] && env_set HV_EXTRA_HOSTS "$o_extra_hosts"
	if [[ -n $o_subnet ]]; then
		is_ipv4_cidr "$o_subnet" || die "无效的 Docker 网段：$o_subnet"
		env_set HV_FRONTEND_SUBNET "$(cidr_network "$o_subnet")"
	fi
	ip_in_cidr "$HV_LAN_IP" "$HV_FRONTEND_SUBNET" && die "Docker 网段 $HV_FRONTEND_SUBNET 与局域网 IP 冲突（用 --frontend-subnet 更换）"

	# ---- host / TLS ---------------------------------------------------------
	title "访问地址与证书"
	if [[ -n $o_host ]]; then
		domain=$o_host
	else
		msg "IP 模式：用局域网 IP 访问（https://$HV_LAN_IP），需要在每台设备上安装一次根证书。"
		msg "域名模式：用自己的域名访问（该域名的 A 记录指向局域网 IP），证书自动申请，设备无需安装证书；需要 DNS 服务商 API 密钥。"
		v=${HV_HOST:-}
		is_ipv4 "$v" && v=''
		domain=$(ask "输入域名（留空 = IP 模式）" "$v")
		[[ -n $domain ]] || domain=$HV_LAN_IP
	fi
	# people paste URLs ("https://nas.example.com/"): keep only the host name
	domain=$(hv_normalize_host "$domain")
	valid_host "$domain" || die "访问地址格式不正确：$domain（只填 IP 或域名，例如 nas.example.com）"
	env_set HV_HOST "$domain"
	if [[ -n $o_tls ]]; then
		env_set HV_TLS_MODE "$o_tls"
	elif is_ipv4 "$HV_HOST"; then
		env_set HV_TLS_MODE internal
	else
		env_set HV_TLS_MODE acme-dns
	fi
	if [[ $HV_TLS_MODE == acme-dns ]]; then
		is_ipv4 "$HV_HOST" && die "域名模式需要域名（--host example.com）"
		env_set HV_DNS_PROVIDER "${o_provider:-$(ask_choice "DNS 服务商" "${HV_DNS_PROVIDER:-alidns}" alidns tencentcloud cloudflare)}"
		env_set HV_ACME_EMAIL "$(trim "${o_email:-$(ask "证书通知邮箱（可留空）" "${HV_ACME_EMAIL:-}")}")"
		[[ -z $HV_ACME_EMAIL ]] || valid_email "$HV_ACME_EMAIL" || die "邮箱格式不正确：$HV_ACME_EMAIL（可以留空）"
		caddy_dns_migrate
		if ! caddy_dns_have_creds "$HV_DNS_PROVIDER" || [[ -n $o_dns_secret_file ]]; then
			install -d -m 0700 "$HV_ROOT/secrets"
			if [[ -n $o_dns_secret_file ]]; then
				secret=$(tr -d '\r\n' <"$o_dns_secret_file")
			else
				secret=$(ask_secret "DNS API 密钥（AccessKey Secret / SecretKey / Cloudflare Token）")
			fi
			[[ $HV_DNS_PROVIDER == cloudflare || -n $o_dns_id ]] || o_dns_id=$(ask "DNS API ID（AccessKey ID / SecretId）" "")
			[[ -n $secret ]] || die "域名模式需要 DNS API 凭据（--dns-id / --dns-secret-file）"
			[[ $HV_DNS_PROVIDER == cloudflare || -n $o_dns_id ]] || die "域名模式需要 DNS API ID（--dns-id）"
			install_write_provider_env "$HV_DNS_PROVIDER" "$o_dns_id" "$secret" || die "无法写入 DNS API 凭据（secrets/caddy-dns/）"
		fi
		warn "请在 DNS 中把 $HV_HOST 的 A 记录设为局域网 IP $HV_LAN_IP（外网通过 VPN 访问同一地址）。"
	fi

	# ---- storage ------------------------------------------------------------
	title "存储"
	if is_interactive && [[ -z $o_data ]]; then
		storage_disk_table
		msg "请为数据选择一块容量足够的数据盘（最好不是系统盘），备份请放在另一块硬盘上。"
	fi
	v=${o_data:-$(ask "HomeVault 数据目录（数据库、配置、日志等）" "${HV_DATA_DIR:-/srv/homevault}")}
	[[ $v == /* ]] || die "数据目录必须是绝对路径：$v"
	env_set HV_DATA_DIR "$(realpath -m -- "$v")"
	[[ $HV_DATA_DIR != / ]] || die "数据目录不能是 /"
	prev_ncdata=${HV_NC_DATA_PATH:-}
	v=${o_ncdata:-$(ask "Nextcloud 文件目录（照片、视频等，占用最大）" "${HV_NC_DATA_PATH:-$HV_DATA_DIR/nextcloud-data}")}
	[[ $v == /* ]] || die "路径必须是绝对路径：$v"
	env_set HV_NC_DATA_PATH "$(realpath -m -- "$v")"
	((first)) && {
		[[ -n $HV_VOL_HTML ]] || env_set HV_VOL_HTML "$HV_DATA_DIR/nextcloud-html"
		[[ -n $HV_VOL_DB ]] || env_set HV_VOL_DB "$HV_DATA_DIR/postgres"
		[[ -n $HV_VOL_REDIS ]] || env_set HV_VOL_REDIS "$HV_DATA_DIR/redis"
		[[ -n $HV_VOL_CADDY_DATA ]] || env_set HV_VOL_CADDY_DATA "$HV_DATA_DIR/caddy-data"
		[[ -n $HV_VOL_CADDY_CONFIG ]] || env_set HV_VOL_CADDY_CONFIG "$HV_DATA_DIR/caddy-config"
		[[ -n $HV_VOL_WGEASY ]] || env_set HV_VOL_WGEASY "$HV_DATA_DIR/wg-easy"
	}
	[[ -n $HV_DUMP_DIR ]] || env_set HV_DUMP_DIR "$HV_DATA_DIR/dumps"
	[[ -n $HV_LOG_DIR ]] || env_set HV_LOG_DIR "$HV_DATA_DIR/logs"
	if ((o_retention_set)) || [[ $first == 1 ]]; then
		v=${o_log_days:-$(ask "日志保留天数（1-365）" "${HV_LOG_RETENTION_DAYS:-7}")}
		retention_valid "$v" || die "日志保留天数必须在 1–365 之间"
		env_set HV_LOG_RETENTION_DAYS "$((10#$v))"
	fi

	# ---- backup -------------------------------------------------------------
	title "备份"
	prev_backup=${HV_BACKUP_LOCAL_PATH:-}
	if [[ -n $o_backup_path ]]; then
		env_set HV_BACKUP_TARGET local
		[[ $o_backup_path == /* ]] || die "备份目录必须是绝对路径：$o_backup_path"
		env_set HV_BACKUP_LOCAL_PATH "$(realpath -m -- "$o_backup_path")"
	elif [[ -n $o_backup_target || -n $o_s3_repo ]]; then
		env_set HV_BACKUP_TARGET "${o_backup_target:-s3}"
	elif is_interactive; then
		v=$(ask_choice "备份到：local=本机另一块硬盘/USB 硬盘，s3=阿里云 OSS/腾讯云 COS 等，none=暂不配置" \
			"$(backup_configured && echo "$HV_BACKUP_TARGET" || echo local)" local s3 none)
		if [[ $v == local ]]; then
			env_set HV_BACKUP_TARGET local
			v=$(ask "备份目录（请选择另一块物理硬盘上的目录，例如 /mnt/backup/homevault）" "${HV_BACKUP_LOCAL_PATH:-}")
			[[ -z $v || $v == /* ]] || die "必须是绝对路径"
			[[ -z $v ]] || v=$(realpath -m -- "$v")
			env_set HV_BACKUP_LOCAL_PATH "$v"
		elif [[ $v == s3 ]]; then
			env_set HV_BACKUP_TARGET s3
		fi
	fi
	if [[ $HV_BACKUP_TARGET == s3 ]]; then
		env_set HV_BACKUP_S3_REPO "${o_s3_repo:-$(ask "restic 仓库地址（例如 s3:https://oss-cn-hangzhou.aliyuncs.com/桶名/homevault）" "${HV_BACKUP_S3_REPO:-}")}"
		env_set HV_BACKUP_S3_OPTIONS "${o_s3_opts:-$(ask "restic 附加选项" "${HV_BACKUP_S3_OPTIONS:--o s3.bucket-lookup=dns}")}"
		if [[ ! -s $HV_ROOT/secrets/backup.env || -n $o_s3_secret_file ]]; then
			[[ -n $o_s3_id ]] || o_s3_id=$(ask "AccessKey ID" "")
			if [[ -n $o_s3_secret_file ]]; then secret=$(tr -d '\r\n' <"$o_s3_secret_file"); else secret=$(ask_secret "AccessKey Secret"); fi
			[[ -n $o_s3_id && -n $secret ]] || die "S3 备份需要 AccessKey（--s3-key-id / --s3-secret-file）"
			install -d -m 0700 "$HV_ROOT/secrets"
			(umask 077 && printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$(env_quote "$o_s3_id")" "$(env_quote "$secret")" >"$HV_ROOT/secrets/backup.env")
		fi
	fi
	backup_configured || warn "暂未配置备份。以后可编辑 .env 的 HV_BACKUP_LOCAL_PATH 后运行 sudo $HV_SELF backup --init"

	# ---- VPN ----------------------------------------------------------------
	title "VPN（外网访问）"
	if ((o_vpn == 0)); then
		env_set HV_VPN_ENABLED false
	elif is_interactive && ! confirm "启用 WireGuard VPN（在外面时手机通过 VPN 回家备份，推荐）？" y; then
		env_set HV_VPN_ENABLED false
	else
		env_set HV_VPN_ENABLED true
	fi
	if vpn_enabled; then
		if [[ -z $o_wg_host && -z $WG_HOST ]]; then
			v=$(curl -fsS --max-time 6 https://4.ipw.cn 2>/dev/null | grep -oE '^[0-9]+(\.[0-9]+){3}$' || true)
			[[ -n $v ]] && msg "检测到当前公网 IPv4：$v（动态 IP 请使用 DDNS 域名：sudo $HV_SELF ddns setup）"
			o_wg_host=$(ask "VPN 连接地址（DDNS 域名或公网 IP）" "$v")
		fi
		[[ -n $o_wg_host ]] && env_set WG_HOST "$(hv_normalize_host "$o_wg_host")"
		[[ -z $WG_HOST ]] || valid_host "$WG_HOST" || die "VPN 连接地址格式不正确：$WG_HOST（只填 DDNS 域名或公网 IP，端口用 --wg-port）"
		[[ -n $WG_HOST ]] || die "需要 VPN 连接地址（--wg-host 域名或公网IP），或使用 --no-vpn"
		if [[ -n $o_wg_port ]]; then
			env_set WG_PORT "$o_wg_port"
		elif [[ ! $WG_PORT =~ ^[0-9]+$ ]] || ((first && WG_PORT == 51820)); then
			env_set WG_PORT "$(rand_int 20000 60000)"
		fi
		[[ -n $o_vpn_access ]] && env_set HV_VPN_LAN_ACCESS "$o_vpn_access"
		if is_interactive && [[ -z $o_vpn_access ]]; then
			env_set HV_VPN_LAN_ACCESS "$(ask_choice "VPN 可访问范围：host=仅本机（推荐），full=整个家庭局域网" "$HV_VPN_LAN_ACCESS" host full)"
		fi
		[[ $HV_VPN_LAN_ACCESS == host || $HV_VPN_LAN_ACCESS == full ]] || die "HV_VPN_LAN_ACCESS 只能是 host 或 full"
		# shellcheck disable=SC2153 # loaded from .env
		ip_in_cidr "$HV_LAN_IP" "$HV_VPN_CIDR" && die "VPN 网段 $HV_VPN_CIDR 与局域网冲突，请修改 .env 的 HV_VPN_CIDR"
		changed_vpn=1
	fi

	# ---- misc ---------------------------------------------------------------
	if [[ -n $o_admin_user ]]; then
		((first)) || [[ $o_admin_user == "$HV_ADMIN_USER" ]] || warn "安装后修改 HV_ADMIN_USER 不会重命名已存在的管理员"
		valid_uid "$o_admin_user" || die "管理员用户名格式不正确"
		env_set HV_ADMIN_USER "$o_admin_user"
	fi
	if [[ -n $o_mirror ]]; then
		case $o_mirror in
		none) mirror_apply docker.io/ ghcr.io/ ;;
		daocloud) mirror_apply docker.m.daocloud.io/ ghcr.m.daocloud.io/ ;;
		custom)
			[[ -n $o_mirror_hub ]] || o_mirror_hub=$(ask "Docker Hub 镜像前缀（例如 docker.m.daocloud.io/）" "${HV_MIRROR_HUB:-}")
			[[ -n $o_mirror_ghcr ]] || o_mirror_ghcr=$(ask "ghcr.io 镜像前缀（例如 ghcr.m.daocloud.io/）" "${HV_MIRROR_GHCR:-}")
			[[ -n $o_mirror_hub && -n $o_mirror_ghcr ]] || die "--mirror custom 需要 --mirror-hub 和 --mirror-ghcr"
			mirror_apply "$o_mirror_hub" "$o_mirror_ghcr"
			;;
		*) die "--mirror 只能是 none / daocloud / custom" ;;
		esac
	elif is_interactive && ((first)); then
		v=$(ask_choice "镜像加速（中国大陆无法直接访问 Docker Hub）：none=不使用，daocloud=DaoCloud 公共镜像" none none daocloud)
		[[ $v == daocloud ]] && mirror_apply docker.m.daocloud.io/ ghcr.m.daocloud.io/
	fi

	env_load
	env_defaults
	hv_ensure_env_keys
	hv_validate_env || die ".env 配置有误"
	hv_write_derived
	install_check_ports

	# ---- secrets & directories ----------------------------------------------
	title "生成密钥与目录"
	install -d -m 0700 "$HV_ROOT/secrets"
	chmod 0700 "$HV_ROOT/secrets"
	for v in "${HV_SECRET_FILES[@]}"; do
		install_secret "$v" && info "已生成 secrets/$v"
	done
	install -d -m 0755 "$HV_DATA_DIR"
	install_dir "$HV_VOL_HTML" 0750 33:33
	# compose never creates the data directory (create_host_path: false); install does, but on a re-run with
	# the same path a missing/empty directory means an unmounted data disk: never create it on the system disk.
	if ((first == 0)) && [[ $HV_NC_DATA_PATH == "$prev_ncdata" ]]; then
		hv_check_nc_data || die "Nextcloud 文件目录不可用（数据盘未挂载？），安装已中止"
	fi
	install_dir "$HV_NC_DATA_PATH" 0750 33:33
	# PostgreSQL 18 mounts /var/lib/postgresql itself: the image's postgres user must be able to traverse it.
	# The entrypoint chowns only PGDATA (18/docker, kept 0700); a 0700 root-owned mount makes initdb fail.
	install_dir "$HV_VOL_DB" 0755
	if [[ $HV_VOL_DB == /* && $(stat -c '%u %a' "$HV_VOL_DB" 2>/dev/null) == '0 700' ]]; then
		chmod 0755 "$HV_VOL_DB"
	fi
	install_dir "$HV_VOL_REDIS" 0700
	install_dir "$HV_VOL_CADDY_DATA" 0700
	install_dir "$HV_VOL_CADDY_CONFIG" 0700
	vpn_enabled && install_dir "$HV_VOL_WGEASY" 0700
	install_dir "$HV_DUMP_DIR" 0700
	if [[ $HV_BACKUP_TARGET == local && -n $HV_BACKUP_LOCAL_PATH ]]; then
		# re-run with an unplugged backup disk: never create the repository directory on the system disk
		# (install would then initialise a fresh repository there and backups would silently land on it)
		if [[ -d $HV_BACKUP_LOCAL_PATH ]] || ((first)) || [[ $HV_BACKUP_LOCAL_PATH != "$prev_backup" ]]; then
			install_dir "$HV_BACKUP_LOCAL_PATH" 0700
		else
			warn "备份目录不存在：$HV_BACKUP_LOCAL_PATH（备份硬盘未挂载？）。为避免把备份写到系统盘，不会自动创建；挂载硬盘后运行：sudo $HV_SELF backup"
		fi
	fi
	state_prepare_dirs
	install -d -m 0700 "$HV_ROOT/clients"
	logs_prepare_dirs verbose
	if [[ -n $(find "$HV_NC_DATA_PATH" -mindepth 1 -maxdepth 1 ! -name '.ncdata' -print -quit 2>/dev/null) && ! -e $HV_NC_DATA_PATH/.ncdata ]]; then
		warn "Nextcloud 文件目录非空：$HV_NC_DATA_PATH 中已有的文件不会自动出现在 Nextcloud 中（请用「额外存储」挂载已有数据）"
	fi
	ok "目录已就绪：$HV_DATA_DIR"

	# ---- extra storages -----------------------------------------------------
	storage_parse_conf || die "storage.conf 有错误"
	if is_interactive && ((first)); then
		while confirm "是否添加额外存储（把其他硬盘上的已有目录挂载到 Nextcloud，例如照片库、影视资料）？" n; do
			storage_cmd_add --no-apply || true
		done
	fi
	storage_parse_conf || die "storage.conf 有错误"
	storage_check_warnings

	# ---- render & start -----------------------------------------------------
	hv_write_derived
	caddy_dns_migrate
	caddy_dns_check || true
	storage_render_if_needed
	vpn_prepare_init
	if ((o_start == 0)); then
		dc config -q || die "compose 配置校验失败"
		ok "配置已写入（未启动服务）。启动：sudo $HV_SELF up，然后重新运行 install 完成初始化"
		return 0
	fi
	if [[ $HV_TLS_MODE == acme-dns ]]; then
		info "构建带 DNS 插件的 Caddy 镜像（首次需要几分钟）…"
		dc build caddy || die "Caddy 构建失败（国内请使用 --mirror，确认 HV_GOPROXY）"
	fi
	panel_build_if_needed || die "无法构建管理面板镜像"
	title "启动服务"
	hv_migrate_frontend_network
	dc up -d || die "启动失败（查看：$HV_SELF logs）"
	wait_app_ready "$o_timeout" || die "Nextcloud 未能就绪"

	if ((${#ST_NAME[@]})); then
		storage_occ_sync || warn "额外存储同步失败，可稍后运行：sudo $HV_SELF storage apply"
	fi
	if vpn_enabled && ((changed_vpn)); then
		if [[ -f $HV_WG_INIT_ENV ]]; then
			vpn_finalize 0 || warn "VPN 自动配置未完成（见上方步骤）"
		fi
	fi
	if backup_configured; then
		info "初始化备份仓库…"
		rc=0
		restic_run -- cat config >/dev/null 2>&1 || rc=$?
		if ((rc == 10)); then
			if restic_run -- init >/dev/null; then ok "restic 仓库已初始化"; else warn "仓库初始化失败，可稍后运行：sudo $HV_SELF backup --init"; fi
		elif ((rc != 0)); then
			warn "无法打开备份仓库：$(restic_exit_msg "$rc")"
		fi
	fi
	if ((o_firewall)) && have iptables; then
		if is_interactive && ! confirm "应用主机防火墙规则（阻止局域网/VPN 以外的来源访问 HomeVault 端口）？" y; then
			:
		else
			local -a fwargs=(--apply)
			((o_ufw)) || is_interactive || fwargs+=(--no-ufw)
			((o_systemd)) || HV_FW_FROM_SYSTEMD=1
			cmd_firewall "${fwargs[@]}" || warn "防火墙设置失败"
			HV_FW_FROM_SYSTEMD=0
		fi
	fi
	if ((o_systemd)) && systemd_available; then
		systemd_install_units homevault-maintenance.service homevault-maintenance.timer \
			homevault-status.service homevault-status.timer homevault-requests.service homevault-requests.path
		systemctl enable --now homevault-maintenance.timer homevault-status.timer homevault-requests.path >/dev/null 2>&1 ||
			warn "启用维护定时任务失败"
		if backup_configured; then
			cmd_schedule_backup || warn "定时备份设置失败"
		fi
	fi
	if [[ $HV_TLS_MODE == internal ]]; then
		ca_fetch "$HV_ROOT/clients/HomeVault-CA.crt" 60 || warn "暂时无法导出根证书，稍后运行：$HV_SELF ca"
	fi
	status_write_json || true
	date -Iseconds >"$HV_STATE_DIR/installed"
	install_summary "$first"
}
