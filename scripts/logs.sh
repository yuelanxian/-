# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# Logs (SPEC §14), daily maintenance, status files for the panel, panel request runner (§15), android APK (§16).
# The state/*.json shapes are CANONICAL = panel/internal/hoststate/types.go (json tags); keep them in sync.

HV_LOG_SERVICES=(app cron db redis caddy wg-easy ddns-go panel socket-proxy scrutiny)
HV_PANEL_UID=65532
# files that services keep writing: never deleted by the retention cleanup (they are rotated instead)
HV_LOG_ACTIVE=(access.log nextcloud.log audit.log panel.log)

# logs_prepare_dirs [verbose] — create HV_LOG_DIR/* with the owners the containers need
logs_prepare_dirs() {
	[[ -n ${HV_LOG_DIR:-} ]] || return 0
	[[ $(id -u) -eq 0 ]] || return 0
	install -d -m 0755 "$HV_LOG_DIR"
	install -d -m 0750 "$HV_LOG_DIR/homevault" "$HV_LOG_DIR/backup" "$HV_LOG_DIR/containers" "$HV_LOG_DIR/caddy"
	install -d -m 0750 -o 33 -g 33 "$HV_LOG_DIR/nextcloud"
	install -d -m 0750 -o "$HV_PANEL_UID" -g "$HV_PANEL_UID" "$HV_LOG_DIR/panel"
	# the panel (uid 65532) reads /logs read-only: allow traversal/reading of the log tree
	if have setfacl && setfacl -R -m "u:$HV_PANEL_UID:rX" -m "d:u:$HV_PANEL_UID:rX" "$HV_LOG_DIR" 2>/dev/null; then
		return 0
	fi
	chmod 0755 "$HV_LOG_DIR"/{homevault,backup,containers,caddy,nextcloud} 2>/dev/null || true
	if [[ ${1:-} == verbose ]]; then
		info "未找到 setfacl（或文件系统不支持 ACL）：日志子目录设为 0755，管理面板才能查看日志。" \
			"想要更严格的权限可安装 acl（apt install acl / dnf install acl）后运行 sudo $HV_SELF up"
	fi
	return 0
}

# state/ (0755 root: status files the panel reads), state/requests (owned by the panel, which writes requests),
# state/requests/done (root 0755: only the host runner writes results there).
state_prepare_dirs() {
	[[ $(id -u) -eq 0 ]] || return 0
	install -d -m 0755 "$HV_STATE_DIR"
	install -d -m 0750 -o "$HV_PANEL_UID" -g "$HV_PANEL_UID" "$HV_STATE_DIR/requests"
	requests_check_done "$HV_STATE_DIR/requests" || true
	return 0
}

# retention_valid N → 1..365
retention_valid() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 365)); }

# current retention (validated, default 7)
logs_retention_days() {
	if retention_valid "${HV_LOG_RETENTION_DAYS:-7}"; then
		printf '%d\n' $((10#${HV_LOG_RETENTION_DAYS:-7}))
	else
		printf '7\n'
	fi
}

# Delete managed log files older than HV_LOG_RETENTION_DAYS (only *.log, *.log.*, *.gz, *.txt; never active files)
logs_clean() {
	local days n=0 f
	local -a keep=()
	[[ -n ${HV_LOG_DIR:-} && -d $HV_LOG_DIR ]] || return 0
	days=$(logs_retention_days)
	for f in "${HV_LOG_ACTIVE[@]}"; do keep+=(! -name "$f"); done
	# find -delete (unlinkat relative to the directory being walked), not "find | rm": panel/ and nextcloud/
	# belong to container users, who could otherwise swap a directory for a symlink between listing and rm
	n=$({ find "$HV_LOG_DIR" -xdev -type f \( -name '*.log' -o -name '*.log.*' -o -name '*.gz' -o -name '*.txt' \) \
		"${keep[@]}" -mmin +$((days * 1440)) -delete -printf . 2>/dev/null || true; } | wc -c)
	HV_LOGS_CLEANED=$((n + 0))
	ok "已清理 $n 个超过 $days 天的日志文件"
}

# Export yesterday's container logs to logs/containers/<svc>-YYYY-MM-DD.log
logs_export_containers() {
	local day since until svc out rc=0
	[[ -n ${HV_LOG_DIR:-} ]] || return 0
	day=$(date -d yesterday +%F)
	since="${day}T00:00:00"
	until="$(date +%F)T00:00:00"
	mkdir -p "$HV_LOG_DIR/containers"
	for svc in "${HV_LOG_SERVICES[@]}"; do
		[[ -n $(dc_cid "$svc") ]] || continue
		out=$HV_LOG_DIR/containers/$svc-$day.log
		[[ -s $out ]] && continue
		dc logs --no-color --timestamps --since "$since" --until "$until" "$svc" >"$out" 2>/dev/null || rc=1
		[[ -s $out ]] || rm -f "$out"
	done
	return $rc
}

# Rotate nextcloud.log / audit.log into <name>-<day of the first entry>.log once they contain entries from
# before today (Nextcloud opens the file for every write, so renaming is safe; the retention cleanup then
# deletes the dated files after HV_LOG_RETENTION_DAYS).
logs_rotate_nextcloud() {
	local d=$HV_LOG_DIR/nextcloud f head day today target i
	[[ -d $d ]] || return 0
	today=$(date +%F)
	for f in nextcloud audit; do
		[[ -f $d/$f.log && ! -L $d/$f.log && -s $d/$f.log ]] || continue
		head=$(head -c 400 -- "$d/$f.log")
		if [[ $head =~ \"time\":\"([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
			day=${BASH_REMATCH[1]}
		else
			day=$(date -r "$d/$f.log" +%F)
		fi
		[[ $day < $today ]] || continue
		target=$d/$f-$day.log
		i=1
		while [[ -e $target ]]; do
			i=$((i + 1))
			target=$d/$f-$day.$i.log
		done
		mv -f -T -- "$d/$f.log" "$target"
	done
	return 0
}

# json_time "iso" → "iso" or null
json_time() { if [[ -n ${1:-} ]]; then json_str "$1"; else printf 'null'; fi; }
# json_int value → value when it is a non-negative integer, else 0
json_int() { if [[ ${1:-} =~ ^[0-9]{1,18}$ ]]; then printf '%d' $((10#$1)); else printf '0'; fi; }

# write stdin to state/<name> atomically (0644)
state_write() {
	local name=$1 tmp
	mkdir -p "$HV_STATE_DIR"
	tmp=$HV_STATE_DIR/.$name.tmp
	cat >"$tmp"
	chmod 0644 "$tmp"
	mv -f -- "$tmp" "$HV_STATE_DIR/$name"
}

# state/status.json — canonical shape: hoststate.Status
status_write_json() {
	local m_last='' m_ok='' m_msg='' r_last='' host
	if [[ -f $HV_STATE_DIR/maintenance.last ]]; then
		{
			IFS= read -r m_last
			IFS= read -r m_ok
			IFS= read -r m_msg
		} <"$HV_STATE_DIR/maintenance.last" || true
	fi
	[[ $m_ok == true || $m_ok == false ]] || m_ok=null
	[[ -f $HV_STATE_DIR/requests.last ]] && r_last=$(head -n1 "$HV_STATE_DIR/requests.last")
	host=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo homevault)
	storage_parse_conf >/dev/null 2>&1 || true
	{
		printf '{"updated":%s,"version":%s,"platform":"linux","hostname":%s,"log_retention_days":%d,"log_dir":%s,' \
			"$(json_str "$(date -Iseconds)")" "$(json_str "$(hv_version)")" "$(json_str "$host")" \
			"$(logs_retention_days)" "$(json_str "${HV_LOG_DIR:-}")"
		printf '"maintenance":{"last_run":%s,"ok":%s,"message":%s},"requests":{"last_run":%s},"disks":[' \
			"$(json_time "$m_last")" "$m_ok" "$(json_str "$m_msg")" "$(json_time "$r_last")"
		status_disks_json
		printf ']}\n'
	} | state_write status.json
}

# disks array entries (role: data|storage|backup|system; sizes in bytes)
status_disks_json() {
	local role name path st total free first=1 i
	{
		printf 'data\tNextcloud 数据\t%s\n' "${HV_NC_DATA_PATH:-}"
		for i in "${!ST_NAME[@]}"; do printf 'storage\t%s\t%s\n' "${ST_NAME[i]}" "${ST_PATH[i]}"; done
		if [[ ${HV_BACKUP_TARGET:-local} == local && -n ${HV_BACKUP_LOCAL_PATH:-} ]]; then
			printf 'backup\trestic 备份仓库\t%s\n' "$HV_BACKUP_LOCAL_PATH"
		fi
		[[ -n ${HV_DATA_DIR:-} ]] && printf 'system\tHomeVault 数据目录\t%s\n' "$HV_DATA_DIR"
	} | while IFS=$'\t' read -r role name path; do
		[[ -n $path ]] || continue
		total=0 free=0
		if [[ -d $path ]]; then
			st=$(fs_stats "$path")
			read -r total free _ <<<"$st"
		fi
		((first)) || printf ','
		first=0
		printf '{"role":%s,"name":%s,"path":%s,"total":%s,"free":%s,"mounted":%s}' \
			"$(json_str "$role")" "$(json_str "$name")" "$(json_str "$path")" "$(json_int "$total")" "$(json_int "$free")" \
			"$([[ -d $path ]] && echo true || echo false)"
	done
}

# vpn_render_status CONF DUMP → state/vpn-status.json content — canonical shape: hoststate.VPNStatus
#   CONF: "# Client: <name> (<id>)" / "PublicKey = …" lines of wg0.conf
#   DUMP: listen port, then peer lines "pub endpoint allowed-ips latest-handshake rx tx" (no preshared keys)
vpn_render_status() {
	local conf=$1 dump=$2 port first=1 line pub name ep addr hs rx tx
	local -A names=()
	name=''
	while IFS= read -r line; do
		line=${line%$'\r'}
		if [[ $line =~ ^\#\ Client:\ (.*)\ \([^\)]*\)$ ]]; then
			name=${BASH_REMATCH[1]}
		elif [[ $line =~ ^PublicKey[[:space:]]*=[[:space:]]*([^[:space:]]+) && -n $name ]]; then
			names[${BASH_REMATCH[1]}]=$name
			name=''
		fi
	done <<<"$conf"
	port=$(head -n1 <<<"$dump" | tr -d '\r')
	printf '{"updated":%s,"platform":"linux","interface":"wg0","listen_port":%s,"peers":[' \
		"$(json_str "$(date -Iseconds)")" "$(json_int "$port")"
	while IFS=$'\t' read -r pub ep addr hs rx tx; do
		[[ -n $pub ]] || continue
		tx=${tx%$'\r'}
		((first)) || printf ','
		first=0
		printf '{"name":%s,"address":%s,"enabled":true,"latest_handshake":%s,"rx_bytes":%s,"tx_bytes":%s' \
			"$(json_str "${names[$pub]:-未命名设备}")" "$(json_str "$addr")" "$(json_int "$hs")" "$(json_int "$rx")" "$(json_int "$tx")"
		[[ -n $ep && $ep != '(none)' ]] && printf ',"endpoint":%s' "$(json_str "$ep")"
		printf '}'
	done < <(tail -n +2 <<<"$dump")
	printf ']}\n'
}

# state/vpn-status.json (removed when the VPN is disabled; never any key material)
vpn_write_status() {
	local conf dump
	if ! vpn_enabled; then
		rm -f -- "$HV_STATE_DIR/vpn-status.json"
		return 0
	fi
	[[ -n $(dc_cid wg-easy) ]] || return 0
	# only the "# Client: <name> (<id>)" comments and the peers' public keys leave the container
	conf=$(dc exec -T wg-easy sh -c "grep -E '^(# Client: |PublicKey)' /etc/wireguard/wg0.conf" 2>/dev/null) || return 1
	# dump columns: pub psk endpoint allowed-ips handshake rx tx keepalive → drop the preshared key
	dump=$(dc exec -T wg-easy sh -c 'wg show wg0 listen-port && wg show wg0 dump | tail -n +2 | cut -f1,3-7' 2>/dev/null) || return 1
	vpn_render_status "$conf" "$dump" | state_write vpn-status.json
}

cmd_status_update() {
	hv_require_env
	require_root
	status_write_json
	vpn_write_status || warn "无法读取 VPN 状态"
}

cmd_maintenance() {
	local okv=true message='每日维护完成' problems=()
	hv_require_env
	require_root
	logs_prepare_dirs
	state_prepare_dirs
	logs_export_containers || problems+=('部分容器日志导出失败')
	logs_rotate_nextcloud || problems+=('Nextcloud 日志轮转失败')
	logs_clean || problems+=('日志清理失败')
	vpn_write_status || problems+=('无法读取 VPN 状态')
	if ((${#problems[@]})); then
		okv=false
		message=$(printf '%s；' "${problems[@]}")
		message=${message%；}
	fi
	printf '%s\n%s\n%s\n' "$(date -Iseconds)" "$okv" "$message" >"$HV_STATE_DIR/maintenance.last"
	status_write_json
	if [[ $okv == true ]]; then ok "$message"; else warn "每日维护完成，但有问题：$message"; fi
}
# ---------------------------------------------------------------------------
# hv logs …
# ---------------------------------------------------------------------------
logs_list() {
	[[ -n ${HV_LOG_DIR:-} && -d $HV_LOG_DIR ]] || die "日志目录不存在（HV_LOG_DIR=${HV_LOG_DIR:-未设置}）"
	msg "日志目录：$HV_LOG_DIR（保留 ${HV_LOG_RETENTION_DAYS:-7} 天）"
	find "$HV_LOG_DIR" -type f \( -name '*.log' -o -name '*.log.*' -o -name '*.gz' -o -name '*.txt' \) \
		-printf '%TY-%Tm-%Td %TH:%TM\t%s\t%P\n' 2>/dev/null | sort -r | head -n 200 |
		while IFS=$'\t' read -r t s p; do printf '%s  %8s  %s\n' "$t" "$(human_bytes "$s")" "$p"; done
	msg "容器：${HV_LOG_SERVICES[*]}（用 $HV_SELF logs show <服务> 查看）"
}

logs_show() {
	local target='' lines=200 f svc
	while (($#)); do
		case $1 in
		--lines | -n) lines=${2:?}; shift ;;
		*) target=$1 ;;
		esac
		shift
	done
	[[ $lines =~ ^[0-9]+$ ]] || die "--lines 必须是数字"
	[[ -n $target ]] || die "用法：$HV_SELF logs show <文件|服务> [--lines N]"
	for svc in "${HV_LOG_SERVICES[@]}"; do
		if [[ $target == "$svc" ]]; then
			dc logs --no-color --tail "$lines" "$svc"
			return
		fi
	done
	[[ -n ${HV_LOG_DIR:-} ]] || die "HV_LOG_DIR 未设置"
	[[ $target != *..* ]] || die "非法路径"
	f=$HV_LOG_DIR/${target#/}
	[[ -f $f ]] || die "找不到日志：$target（用 $HV_SELF logs list 查看）"
	if [[ $f == *.gz ]]; then zcat -- "$f" | tail -n "$lines"; else tail -n "$lines" -- "$f"; fi
}

logs_retention() {
	local days=${1:-}
	if [[ -z $days ]]; then
		msg "当前日志保留天数：$(logs_retention_days)（修改：sudo $HV_SELF logs retention <1-365>）"
		return 0
	fi
	retention_valid "$days" || die "天数必须在 1–365 之间：$days"
	days=$((10#$days))
	env_set HV_LOG_RETENTION_DAYS "$days"
	ok "日志保留天数已设为 $days 天（每日维护时删除更早的日志文件）"
	# Caddy reads the value from its environment (roll_keep_for): recreate only caddy
	if [[ -n $(dc_cid caddy 2>/dev/null) ]]; then
		dc up -d --no-deps caddy >/dev/null 2>&1 || warn "caddy 重建失败，访问日志的保留天数将在下次 $HV_SELF up 后生效"
	fi
	status_write_json || true
}

cmd_logs() {
	local sub=${1:-}
	hv_require_env
	case $sub in
	list) logs_list ;;
	show)
		shift
		logs_show "$@"
		;;
	retention)
		shift
		require_root
		logs_retention "${1:-}"
		;;
	clean)
		require_root
		logs_clean
		;;
	-h | --help | help) help_cmd logs ;;
	*)
		# hv logs [服务…] [docker compose logs 参数]
		if [[ -t 1 ]]; then dc logs -f --tail 200 "$@"; else dc logs --tail 200 "$@"; fi
		;;
	esac
}

# ---------------------------------------------------------------------------
# Panel request runner (§15): allow-listed request types only
# ---------------------------------------------------------------------------
# The panel (uid 65532) owns state/requests and writes <id>.json there. The runner (root) first moves each
# request into state/requests/done/ (owned by root, so the panel can no longer change it), validates it,
# executes it and writes done/<id>.result.json: {"id","request","type","ok","finished","message"}.

# requests_parse FILE → prints "type<TAB>days" (validated) or fails
requests_parse() {
	local f=$1 body type='' days=''
	[[ -f $f && ! -L $f ]] || return 1
	(($(stat -c %s -- "$f") <= 4096)) || return 1
	body=$(tr -d '\r\n' <"$f")
	[[ $body =~ \"type\"[[:space:]]*:[[:space:]]*\"([a-z-]+)\" ]] && type=${BASH_REMATCH[1]}
	[[ $body =~ \"days\"[[:space:]]*:[[:space:]]*\"?([0-9]+)\"? ]] && days=${BASH_REMATCH[1]}
	case $type in
	backup | log-clean) printf '%s\t\n' "$type" ;;
	log-retention)
		retention_valid "$days" || return 1
		printf '%s\t%s\n' "$type" "$((10#$days))"
		;;
	*) return 1 ;;
	esac
}

# requests_check_done DIR — make sure DIR/done is a real directory owned by us = root (the panel owns DIR and
# could otherwise replace done/ with a symlink to make root write elsewhere)
requests_check_done() {
	local dir=$1 d=$1/done
	if [[ -L $d || (-e $d && ! -d $d) ]] || { [[ -d $d ]] && [[ $(stat -c %u -- "$d") != "$(id -u)" ]]; }; then
		warn "state/requests/done 不是 root 拥有的目录，已移走并重建"
		mv -f -T -- "$d" "$dir/.done-invalid-$(date +%s)-$$" 2>/dev/null || rm -rf -- "$d"
	fi
	[[ -d $d ]] || install -d -m 0755 -- "$d"
	chmod 0755 -- "$d"
}

# requests_result BASE TYPE OK MESSAGE — written into the current directory (= verified done/)
requests_result() {
	local base=$1 type=$2 okv=$3 message=$4 id=${1%.json}
	printf '{"id":%s,"request":%s,"type":%s,"ok":%s,"finished":%s,"message":%s}\n' "$(json_str "$id")" \
		"$(json_str "$base")" "$(json_str "$type")" "$okv" "$(json_str "$(date -Iseconds)")" "$(json_str "$message")" \
		>"./.$id.result.tmp"
	chmod 0644 "./.$id.result.tmp"
	mv -f -T -- "./.$id.result.tmp" "./$id.result.json"
}

# last error line ("✘ …") of a captured command output, without colours
requests_last_error() {
	sed 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null | grep '✘' | tail -n1 | sed 's/^.*✘[[:space:]]*//' | cut -c1-300 || true
}

# requests_run_one BASE — the request file is already in the current directory (done/)
requests_run_one() {
	local base=$1 parsed type days rc=0 out msg
	if ! parsed=$(requests_parse "./$base"); then
		[[ -f ./$base && ! -L ./$base ]] || rm -rf -- "./$base"
		requests_result "$base" unknown false "请求无效，或类型不在允许列表中（只允许 backup、log-clean、log-retention）"
		hv_log "REQUEST rejected $base"
		return 0
	fi
	IFS=$'\t' read -r type days <<<"$parsed"
	hv_log "REQUEST $type ${days:-} ($base)"
	out=$(hv_mktemp)
	# subshells: a "die" inside must not end the runner (temp files live in HV_TMP_DIR of this process)
	case $type in
	backup) (cmd_backup) >"$out" 2>&1 || rc=$? ;;
	log-clean) logs_clean >"$out" 2>&1 || rc=$? ;;
	log-retention) (logs_retention "$days") >"$out" 2>&1 || rc=$? ;;
	esac
	if ((rc == 0)); then
		case $type in
		backup) msg='备份完成' ;;
		log-clean) msg="已清理 ${HV_LOGS_CLEANED:-0} 个超过 $(logs_retention_days) 天的日志文件" ;;
		log-retention)
			HV_LOG_RETENTION_DAYS=$days
			msg="日志保留天数已设为 $days 天"
			;;
		esac
		requests_result "$base" "$type" true "$msg"
		info "请求 $base（$type）：$msg"
	else
		msg=$(requests_last_error "$out")
		requests_result "$base" "$type" false "失败（退出码 $rc）${msg:+：$msg}"
		warn "请求 $base（$type）失败（退出码 $rc）${msg:+：$msg}"
	fi
	return 0
}

requests_process_all() {
	local dir=$HV_STATE_DIR/requests real f base n=0
	real=$(cd -P -- "$dir" && pwd -P) || die "无法进入 $dir"
	requests_check_done "$real"
	cd -P -- "$real/done" || die "无法进入 $real/done"
	# the cwd is now pinned to the verified directory, even if the entry is swapped afterwards
	[[ $(pwd -P) == "$real/done" && $(stat -c %u .) == "$(id -u)" ]] || die "state/requests/done 目录异常，拒绝处理请求"
	while ((n < 100)); do
		f=''
		for f in "$real"/*.json; do
			[[ -e $f || -L $f ]] && break
			f=''
		done
		[[ -n $f ]] || break
		n=$((n + 1))
		base=${f##*/}
		if ! [[ $base =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json$ ]] || [[ $base == *.result.json || -e ./$base ]]; then
			rm -rf -- "$f"
			continue
		fi
		mv -f -T -- "$f" "./$base" 2>/dev/null || {
			rm -rf -- "$f"
			continue
		}
		requests_run_one "$base"
	done
	# keep the 200 newest files in done/
	find . -maxdepth 1 -type f -printf '%T@ %f\n' 2>/dev/null | sort -rn | tail -n +201 | cut -d' ' -f2- |
		while IFS= read -r f; do rm -f -- "./$f"; done
	cd "$HV_ROOT" || true
	((n == 0)) || ok "已处理 $n 个管理面板请求"
}

cmd_requests() {
	local sub=${1:-process}
	[[ $sub == process ]] || die "用法：$HV_SELF requests process"
	hv_require_env
	require_root
	[[ -d $HV_STATE_DIR/requests ]] || state_prepare_dirs
	exec 8>"$HV_STATE_DIR/requests.lock"
	if ! flock -n 8; then
		info "另一个请求处理任务正在运行"
		return 0
	fi
	requests_process_all
	date -Iseconds >"$HV_STATE_DIR/requests.last"
	status_write_json || true
}

# ---------------------------------------------------------------------------
# Android APK (§16)
# ---------------------------------------------------------------------------
android_repo_slug() {
	local url
	url=$(git -C "$HV_ROOT" remote get-url origin 2>/dev/null) || return 1
	[[ $url =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]] || return 1
	printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

cmd_android() {
	local sub=${1:-fetch} url='' file='' slug api dest tmp
	(($#)) && shift
	[[ $sub == fetch ]] || die "用法：$HV_SELF android fetch [--url <APK下载地址>] [--file <本地APK>]"
	while (($#)); do
		case $1 in
		--url) url=${2:?}; shift ;;
		--file) file=${2:?}; shift ;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	hv_require_env
	dest=$HV_STATE_DIR/app/homevault.apk
	install -d -m 0755 "$HV_STATE_DIR/app"
	tmp=$(hv_mktemp)
	if [[ -n $file ]]; then
		cp -- "$file" "$tmp"
	else
		if [[ -z $url ]]; then
			slug=${HV_ANDROID_RELEASE_REPO:-${HV_ANDROID_REPO:-$(android_repo_slug || true)}}
			[[ -n $slug ]] || die "无法确定 GitHub 仓库，请用 --url 指定 APK 下载地址"
			api="https://api.github.com/repos/$slug/releases/latest"
			info "查询最新发布：$api"
			url=$(curl -fsSL --max-time 30 "$api" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.apk"' | head -n1 | cut -d'"' -f4) ||
				true
			[[ -n $url ]] || die "最新发布中没有 APK（或无法访问 GitHub）。可手动下载后用 --file 指定"
		fi
		[[ $url == https://* ]] || die "只允许 https 下载地址"
		info "下载 $url …"
		curl -fSL --max-time 600 -o "$tmp" "$url" || die "下载失败"
	fi
	[[ $(head -c 2 "$tmp") == PK ]] || die "文件不是有效的 APK"
	install -m 0644 "$tmp" "$dest"
	ok "已保存：$dest（$(human_bytes "$(stat -c %s "$dest")")），手机可在管理面板「设置」中扫码下载"
}
