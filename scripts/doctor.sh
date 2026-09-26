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
	for svc in app db redis; do
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

doctor_disks() {
	local label path st total free pct i
	storage_parse_conf >/dev/null 2>&1 || true
	while IFS=$'\t' read -r label path; do
		[[ -n $path ]] || continue
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
	local end days sni=()
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
	days=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
	if ((days < 7)); then
		doc_fail "TLS 证书将在 $days 天后过期（$end）"
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
		for f in "$HV_ROOT"/secrets/*; do
			[[ -f $f ]] || continue
			m=$(stat -c %a "$f")
			((8#$m & 8#022)) && doc_fail "密钥文件可被他人写入：$f（$m）"
		done
	else
		doc_fail "secrets/ 目录不存在"
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

cmd_doctor() {
	hv_require_env
	title "HomeVault 健康检查"
	if ! docker info >/dev/null 2>&1; then
		doc_fail "无法连接 Docker（是否已启动？是否有权限？）"
	else
		doc_ok "Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null)，Compose $(docker compose version --short 2>/dev/null)"
		doctor_containers
		doctor_ports
		[[ $(dc_state app) == healthy || $(dc_state app) == running ]] && doctor_nextcloud
		doctor_tls
		doctor_network
	fi
	doctor_firewall
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
