# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# hv doctor — health / security checks (SPEC §11).

_DOC_FAIL=0
_DOC_WARN=0
doc_ok() { printf '  %s✔%s %s\n' "$_C_GRN" "$_C_RST" "$*"; }
doc_fail() {
	printf '  %s✘%s %s\n' "$_C_RED" "$_C_RST" "$*"
	_DOC_FAIL=$((_DOC_FAIL + 1))
	hv_log "DOCTOR FAIL $*"
}
doc_warn() {
	printf '  %s!%s %s\n' "$_C_YEL" "$_C_RST" "$*"
	_DOC_WARN=$((_DOC_WARN + 1))
	hv_log "DOCTOR WARN $*"
}

doctor_containers() {
	local svc st
	local -a svcs=(app cron db redis caddy)
	vpn_enabled && svcs+=(wg-easy)
	is_true "${HV_DDNS_ENABLED:-false}" && svcs+=(ddns-go)
	while IFS= read -r svc; do
		[[ $svc == panel || $svc == socket-proxy ]] && svcs+=("$svc")
	done < <(compose_services)
	for svc in "${svcs[@]}"; do
		st=$(dc_state "$svc")
		case $st in
		healthy) doc_ok "容器 $svc：健康" ;;
		running) doc_ok "容器 $svc：运行中" ;;
		starting) doc_warn "容器 $svc：启动中" ;;
		*) doc_fail "容器 $svc：$st" ;;
		esac
	done
}

doctor_ports() {
	local cid line hostpart bad=0 svc
	for svc in caddy wg-easy; do
		cid=$(dc_cid "$svc")
		[[ -n $cid ]] || continue
		while IFS= read -r line; do
			[[ -n $line ]] || continue
			# e.g. "443/tcp -> 192.168.1.10:443" or "51820/udp -> [::]:51820"
			hostpart=${line##*-> }
			if [[ $hostpart == \[* || $hostpart == ::* ]]; then
				doc_fail "$svc 端口发布在 IPv6 上：$line（应只绑定 IPv4）"
				bad=1
			elif [[ $line == */tcp* && ${hostpart%:*} != "$HV_BIND_IP" ]]; then
				doc_fail "$svc TCP 端口未绑定到 HV_BIND_IP（$HV_BIND_IP）：$line"
				bad=1
			fi
		done < <(docker port "$cid" 2>/dev/null)
	done
	((bad)) || doc_ok "发布的端口均为 IPv4，TCP 仅绑定在 $HV_BIND_IP"
	for svc in app db redis panel socket-proxy; do
		cid=$(dc_cid "$svc")
		[[ -n $cid && -n $(docker port "$cid" 2>/dev/null) ]] && doc_fail "$svc 不应发布任何端口"
	done
	return 0
}

doctor_firewall() {
	if [[ $(id -u) -ne 0 ]]; then
		doc_warn "非 root 运行，跳过防火墙检查"
		return 0
	fi
	if ! have iptables; then
		doc_warn "未找到 iptables，无法检查防火墙"
		return 0
	fi
	if fw_is_applied; then
		doc_ok "防火墙：DOCKER-USER → HOMEVAULT 规则已生效"
	else
		doc_warn "防火墙：HOMEVAULT 规则未生效（sudo $HV_SELF firewall --apply）"
	fi
	if systemd_available && [[ $(systemctl is-enabled homevault-firewall.service 2>/dev/null) != enabled ]]; then
		doc_warn "homevault-firewall.service 未启用：重启后防火墙规则会丢失"
	fi
}

doctor_nextcloud() {
	local out
	if ! out=$(occ status --output=json 2>/dev/null); then
		doc_fail "occ status 执行失败"
		return 0
	fi
	if [[ $out == *'"installed":true'* ]]; then
		doc_ok "Nextcloud 已安装（$(grep -o '"versionstring":"[^"]*"' <<<"$out" | cut -d'"' -f4)）"
	else
		doc_fail "Nextcloud 未安装"
	fi
	if [[ $out == *'"maintenance":false'* ]]; then
		doc_ok "未处于维护模式"
	else
		doc_fail "Nextcloud 处于维护模式（$HV_SELF occ maintenance:mode --off）"
	fi
	[[ $out == *'"needsDbUpgrade":true'* ]] && doc_fail "数据库需要升级（$HV_SELF occ upgrade）"
	out=$(occ twofactorauth:enforce 2>/dev/null | tr -d '\r') || out=''
	if [[ $out == *'is enforced'* ]]; then doc_ok "两步验证：强制启用"; else doc_fail "两步验证未强制（$HV_SELF harden）"; fi
	out=$(occ config:system:get token_auth_enforced 2>/dev/null | tr -d '\r') || out=''
	if [[ $out == true ]]; then
		doc_ok "token_auth_enforced：已启用（客户端必须使用应用密码）"
	else
		doc_fail "token_auth_enforced 未启用"
	fi
	out=$(occ config:app:get core shareapi_allow_links 2>/dev/null | tr -d '\r') || out=''
	if is_true "${HV_ALLOW_PUBLIC_LINKS:-false}"; then
		doc_warn "公开分享链接：已允许（HV_ALLOW_PUBLIC_LINKS=true）"
	elif [[ $out == no ]]; then
		doc_ok "公开分享链接：已关闭"
	else
		doc_fail "公开分享链接未关闭（$HV_SELF harden）"
	fi
	out=$(occ setupchecks --output=json 2>/dev/null) || out=''
	if [[ -n $out ]]; then
		local e w
		e=$(grep -o '"severity":"error"' <<<"$out" | wc -l || true)
		w=$(grep -o '"severity":"warning"' <<<"$out" | wc -l || true)
		if ((e > 0)); then
			doc_warn "Nextcloud 安全与设置检查：$e 个错误、$w 个警告（$HV_SELF occ setupchecks 查看详情）"
		elif ((w > 0)); then
			doc_warn "Nextcloud 安全与设置检查：$w 个警告（$HV_SELF occ setupchecks）"
		else
			doc_ok "Nextcloud 安全与设置检查：无错误与警告"
		fi
	fi
}

# Nextcloud data directory: compose never creates it (create_host_path: false), so a missing or empty
# directory means the data disk is not mounted — explain instead of letting the app container fail.
doctor_ncdata() {
	local p=${HV_NC_DATA_PATH:-}
	if [[ $p != /* ]]; then
		doc_fail "HV_NC_DATA_PATH 未设置或不是绝对路径：${p:-（空）}"
		return 0
	fi
	if [[ ! -d $p ]]; then
		doc_fail "Nextcloud 文件目录不存在：$p —— 数据盘可能没有挂载（检查 lsblk、findmnt、/etc/fstab；挂载：sudo mount -a）。为避免把文件写到系统盘，HomeVault 不会自动创建它；挂载后运行 sudo $HV_SELF up"
	elif [[ -f $HV_STATE_DIR/installed && ! -e $p/.ncdata ]]; then
		doc_fail "Nextcloud 文件目录中没有 .ncdata：$p —— 数据盘可能没有挂载到这里，或目录被换成了空目录（检查 findmnt $p；挂载后运行 sudo $HV_SELF up）"
	else
		doc_ok "Nextcloud 文件目录：$p"
	fi
}

# Only Caddy (fixed address) and the panel are trusted proxies for Nextcloud / the panel
doctor_proxy() {
	local cid ip net=${COMPOSE_PROJECT_NAME}_frontend
	cid=$(dc_cid caddy)
	[[ -n $cid && -n ${HV_CADDY_IP:-} ]] || return 0
	ip=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$net\"}}{{.IPAddress}}{{end}}" "$cid" 2>/dev/null || true)
	if [[ -z $ip ]]; then
		return 0
	elif [[ $ip == "$HV_CADDY_IP" ]]; then
		doc_ok "Caddy 固定地址 $ip（Nextcloud / 管理面板只信任它转发的客户端 IP）"
	else
		doc_fail "Caddy 的地址是 $ip，而 HV_CADDY_IP=$HV_CADDY_IP：Nextcloud 将看不到真实客户端 IP（sudo $HV_SELF up 重建）"
	fi
}

doctor_disks() {
	local label path st total free pct i
	storage_parse_conf >/dev/null 2>&1 || true
	while IFS=$'\t' read -r label path; do
		[[ -n $path ]] || continue
		# a missing primary data directory is reported (with a hint) by doctor_ncdata
		[[ $label == 主数据 && ! -d $path ]] && continue
		if [[ ! -d $path ]]; then
			doc_fail "$label 目录不存在：$path（硬盘未挂载？）"
			continue
		fi
		st=$(fs_stats "$path")
		total=${st%% *}
		free=$(awk '{print $2}' <<<"$st")
		[[ $total =~ ^[0-9]+$ && $total -gt 0 ]] || continue
		pct=$((free * 100 / total))
		if ((pct < 10)); then
			doc_warn "$label 剩余空间不足 10%：$(human_bytes "$free") / $(human_bytes "$total")（$path）"
		else
			doc_ok "$label 剩余 $(human_bytes "$free") / $(human_bytes "$total")（${pct}%）"
		fi
	done < <(
		printf '主数据\t%s\n' "${HV_NC_DATA_PATH:-}"
		printf 'HomeVault 数据目录\t%s\n' "${HV_DATA_DIR:-}"
		for i in "${!ST_NAME[@]}"; do printf '存储「%s」\t%s\n' "${ST_NAME[i]}" "${ST_PATH[i]}"; done
		[[ ${HV_BACKUP_TARGET:-local} == local && -n ${HV_BACKUP_LOCAL_PATH:-} ]] && printf '备份目标\t%s\n' "$HV_BACKUP_LOCAL_PATH"
		printf 'Docker 数据目录\t%s\n' "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
	)
	return 0
}

doctor_backup() {
	local last age
	if ! backup_configured; then
		doc_warn "未配置备份目标（强烈建议配置：$HV_SELF install 或编辑 .env 的 HV_BACKUP_LOCAL_PATH）"
		return 0
	fi
	if [[ ! -f $HV_STATE_DIR/last-backup-ok ]]; then
		doc_warn "还没有成功的备份（运行：sudo $HV_SELF backup）"
	else
		last=$(cat "$HV_STATE_DIR/last-backup-ok")
		age=$(($(date +%s) - $(date -d "$last" +%s 2>/dev/null || echo 0)))
		if ((age > 48 * 3600)); then
			doc_fail "最近一次成功备份超过 48 小时：$last"
		else
			doc_ok "最近一次成功备份：$last"
		fi
	fi
	if systemd_available; then
		if [[ $(systemctl is-enabled homevault-backup.timer 2>/dev/null) == enabled ]]; then
			doc_ok "定时备份已启用（每日 ${HV_BACKUP_TIME}）"
		else
			doc_warn "定时备份未启用（sudo $HV_SELF schedule-backup）"
		fi
	fi
}

doctor_tls() {
	local end days secs sni=()
	have openssl || {
		doc_warn "未安装 openssl，跳过证书检查"
		return 0
	}
	is_ipv4 "$HV_HOST" || sni=(-servername "$HV_HOST")
	end=$(openssl s_client -connect "$HV_BIND_IP:$HV_HTTPS_PORT" "${sni[@]}" </dev/null 2>/dev/null |
		openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2) || end=''
	if [[ -z $end ]]; then
		doc_fail "无法从 https://$HV_BIND_IP:$HV_HTTPS_PORT 获取证书"
		return 0
	fi
	secs=$(($(date -d "$end" +%s) - $(date +%s)))
	days=$((secs / 86400))
	if ((secs <= 0)); then
		doc_fail "TLS 证书已过期（$end）：查看 $HV_SELF logs caddy"
	elif [[ $HV_TLS_MODE == internal ]]; then
		# Caddy's local CA issues short-lived (12 h) certificates and renews them automatically
		doc_ok "TLS 证书有效（本地 CA 签发，Caddy 自动续期；当前证书到期：$end）"
	elif ((days < 3)); then
		doc_fail "TLS 证书将在 $days 天后过期（$end）：自动续期可能失败，查看 $HV_SELF logs caddy"
	elif ((days < 14)); then
		doc_warn "TLS 证书将在 $days 天后过期（$end）：Caddy 通常在到期前 30 天续期，请检查 DNS API 凭据"
	else
		doc_ok "TLS 证书有效，剩余 $days 天（Caddy 会自动续期）"
	fi
}

doctor_perms() {
	local m f
	m=$(stat -c %a "$HV_ENV_FILE" 2>/dev/null || echo '?')
	if [[ $m == 600 || $m == 400 ]]; then doc_ok ".env 权限 $m"; else doc_warn ".env 权限为 $m（建议 600：chmod 600 .env）"; fi
	if [[ -d $HV_ROOT/secrets ]]; then
		m=$(stat -c %a "$HV_ROOT/secrets")
		if [[ $m == 700 ]]; then doc_ok "secrets/ 目录权限 700"; else doc_fail "secrets/ 目录权限为 $m（应为 700：chmod 700 secrets）"; fi
		for f in "$HV_ROOT"/secrets/* "$HV_ROOT"/secrets/caddy-dns "$HV_ROOT"/secrets/caddy-dns/*; do
			[[ -e $f ]] || continue
			m=$(stat -c %a "$f")
			((8#$m & 8#022)) && doc_fail "密钥文件可被他人写入：$f（$m）"
		done
	else
		doc_fail "secrets/ 目录不存在"
	fi
	[[ -f $HV_ROOT/secrets/caddy-dns.env ]] &&
		doc_warn "旧的 secrets/caddy-dns.env 仍然存在（DNS 凭据会以环境变量传给 Caddy 的旧方式）：运行 sudo $HV_SELF up 自动迁移到 secrets/caddy-dns/"
	if [[ ${HV_TLS_MODE:-internal} == acme-dns ]]; then
		if caddy_dns_have_creds "${HV_DNS_PROVIDER:-}"; then
			doc_ok "DNS API 凭据文件齐全（secrets/caddy-dns/，$HV_DNS_PROVIDER）"
		else
			doc_fail "域名模式缺少 DNS API 凭据文件：$(caddy_dns_keys "${HV_DNS_PROVIDER:-}" | sed 's#^#secrets/caddy-dns/#' | paste -sd ' ' -)（sudo $HV_SELF install 重新输入）"
		fi
	fi
	[[ -f $HV_ROOT/secrets/wg-easy-init.env && -f $HV_STATE_DIR/wg-easy-finalized ]] &&
		doc_warn "secrets/wg-easy-init.env 仍然存在（sudo $HV_SELF vpn finalize --skip-api 会删除它）"
	return 0
}

doctor_network() {
	local cur
	cur=$(detect_lan | awk '{print $1}')
	if [[ -z $cur ]]; then
		doc_warn "无法检测当前局域网 IP"
	elif [[ $cur != "$HV_LAN_IP" ]]; then
		doc_warn "局域网 IP 已变化：当前 $cur，配置为 $HV_LAN_IP（请在路由器中为本机设置固定 IP / DHCP 保留，然后重新运行 install）"
	else
		doc_ok "局域网 IP 未变化（$HV_LAN_IP）"
	fi
	if vpn_enabled; then
		if dc exec -T wg-easy wg show wg0 >/dev/null 2>&1; then
			doc_ok "WireGuard 接口 wg0 已启动（UDP $WG_PORT）"
		else
			doc_fail "WireGuard 接口未启动（$HV_SELF logs wg-easy）"
		fi
		[[ -f $HV_STATE_DIR/wg-easy-finalized ]] || doc_warn "VPN 尚未完成初始化（sudo $HV_SELF vpn finalize）"
	fi
}

# Management panel (SPEC §15): reachable through Caddy, host-side status files and request runner alive
doctor_panel() {
	local code target age f
	compose_services | grep -qx panel || return 0
	if have curl; then
		target=$HV_BIND_IP
		[[ $target == 0.0.0.0 ]] && target=127.0.0.1
		# liveness only (-k): the certificate itself is checked by doctor_tls
		code=$(curl -sk --max-time 8 -o /dev/null -w '%{http_code}' --resolve "$HV_HOST:$HV_PANEL_PORT:$target" \
			"https://$HV_HOST:$HV_PANEL_PORT/healthz" 2>/dev/null || true)
		if [[ $code == 200 ]]; then
			doc_ok "管理面板可访问：$(hv_panel_url)"
		else
			doc_fail "管理面板无法访问（HTTP ${code:-000}）：$(hv_panel_url)（查看：$HV_SELF logs panel）"
		fi
	fi
	f=$HV_STATE_DIR/status.json
	if [[ ! -f $f ]]; then
		doc_warn "尚未生成 state/status.json（sudo $HV_SELF status-update）"
	else
		age=$(($(date +%s) - $(stat -c %Y "$f")))
		if ((age > 36 * 3600)); then
			doc_warn "state/status.json 已 $((age / 3600)) 小时未更新：每日维护任务可能未运行（systemctl status homevault-maintenance.timer）"
		else
			doc_ok "状态文件已更新（$((age / 60)) 分钟前）"
		fi
	fi
	if [[ -n $(find "$HV_STATE_DIR/requests" -maxdepth 1 -name '*.json' -mmin +15 -print -quit 2>/dev/null) ]]; then
		doc_warn "有管理面板请求超过 15 分钟未处理（sudo $HV_SELF requests process；systemctl status homevault-requests.path）"
	fi
	if [[ $(stat -c %u "$HV_STATE_DIR/requests" 2>/dev/null) != "$HV_PANEL_UID" ]]; then
		doc_warn "state/requests 不属于管理面板用户（uid $HV_PANEL_UID），面板无法提交请求（sudo $HV_SELF up 会修复）"
	fi
}

doctor_logs() {
	if [[ -z ${HV_LOG_DIR:-} || ! -d $HV_LOG_DIR ]]; then
		doc_fail "日志目录不存在：${HV_LOG_DIR:-未设置}（sudo $HV_SELF up 会创建）"
		return 0
	fi
	doc_ok "日志目录：$HV_LOG_DIR（保留 $(logs_retention_days) 天）"
	retention_valid "${HV_LOG_RETENTION_DAYS:-7}" || doc_warn "HV_LOG_RETENTION_DAYS 无效（${HV_LOG_RETENTION_DAYS}），按 7 天处理"
	if [[ $(stat -c %u "$HV_LOG_DIR/panel" 2>/dev/null) != "$HV_PANEL_UID" ]]; then
		doc_warn "日志目录 panel/ 不属于管理面板用户（uid $HV_PANEL_UID），面板审计日志无法写入（sudo $HV_SELF up 会修复）"
	fi
	if systemd_available; then
		local u
		for u in homevault-maintenance.timer homevault-status.timer homevault-requests.path; do
			[[ $(systemctl is-enabled "$u" 2>/dev/null) == enabled ]] ||
				doc_warn "$u 未启用：日志清理 / 面板状态 / 面板请求将不会自动执行（sudo $HV_SELF install 会安装）"
		done
	fi
	return 0
}

cmd_doctor() {
	hv_require_env
	title "HomeVault 健康检查"
	if ! docker info >/dev/null 2>&1; then
		doc_fail "无法连接 Docker（是否已启动？是否有权限？）"
	else
		doc_ok "Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null)，Compose $(docker compose version --short 2>/dev/null)"
		doctor_containers
		doctor_ports
		doctor_proxy
		[[ $(dc_state app) == healthy || $(dc_state app) == running ]] && doctor_nextcloud
		doctor_tls
		doctor_panel
		doctor_network
	fi
	doctor_logs
	doctor_firewall
	doctor_ncdata
	doctor_disks
	doctor_backup
	doctor_perms
	printf '\n'
	if ((_DOC_FAIL)); then
		err "发现 $_DOC_FAIL 个问题、$_DOC_WARN 个警告"
		return 1
	fi
	if ((_DOC_WARN)); then warn "没有严重问题，$_DOC_WARN 个警告"; else ok "一切正常"; fi
}
