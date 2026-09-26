# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# Logs (SPEC §14), daily maintenance, status files for the panel, panel request runner (§15), android APK (§16).

HV_LOG_SERVICES=(app cron db redis caddy wg-easy ddns-go panel socket-proxy scrutiny)

logs_prepare_dirs() {
	[[ -n ${HV_LOG_DIR:-} ]] || return 0
	[[ $(id -u) -eq 0 ]] || return 0
	install -d -m 0755 "$HV_LOG_DIR"
	install -d -m 0750 "$HV_LOG_DIR/homevault" "$HV_LOG_DIR/backup" "$HV_LOG_DIR/containers" "$HV_LOG_DIR/caddy"
	install -d -m 0750 -o 33 -g 33 "$HV_LOG_DIR/nextcloud"
	install -d -m 0750 -o 65532 -g 65532 "$HV_LOG_DIR/panel"
	# panel (uid 65532) reads /logs read-only: allow traversal/reading of the log tree
	if have setfacl; then
		setfacl -R -m u:65532:rX -m d:u:65532:rX "$HV_LOG_DIR" 2>/dev/null || true
	else
		chmod 0755 "$HV_LOG_DIR"/{homevault,backup,containers,caddy} 2>/dev/null || true
		chmod 0755 "$HV_LOG_DIR/nextcloud" 2>/dev/null || true
	fi
}

# retention_valid N → 1..365
retention_valid() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 365)); }

# Delete managed log files older than HV_LOG_RETENTION_DAYS (only *.log, *.log.*, *.gz, *.txt)
logs_clean() {
	local days=${HV_LOG_RETENTION_DAYS:-7} n=0 f
	[[ -n ${HV_LOG_DIR:-} && -d $HV_LOG_DIR ]] || return 0
	retention_valid "$days" || days=7
	while IFS= read -r -d '' f; do
		rm -f -- "$f" && n=$((n + 1))
	done < <(find "$HV_LOG_DIR" -xdev -type f \( -name '*.log' -o -name '*.log.*' -o -name '*.gz' -o -name '*.txt' \) \
		-mmin +$((10#$days * 1440)) -print0 2>/dev/null)
	info "已清理 $n 个超过 $days 天的日志文件"
}

# Export yesterday's container logs to logs/containers/<svc>-YYYY-MM-DD.log
logs_export_containers() {
	local day since until svc out
	[[ -n ${HV_LOG_DIR:-} ]] || return 0
	day=$(date -d yesterday +%F)
	since="${day}T00:00:00"
	until="$(date +%F)T00:00:00"
	mkdir -p "$HV_LOG_DIR/containers"
	for svc in "${HV_LOG_SERVICES[@]}"; do
		[[ -n $(dc_cid "$svc") ]] || continue
		out=$HV_LOG_DIR/containers/$svc-$day.log
		[[ -s $out ]] && continue
		dc logs --no-color --timestamps --since "$since" --until "$until" "$svc" >"$out" 2>/dev/null || true
		[[ -s $out ]] || rm -f "$out"
	done
}

# Rotate nextcloud.log / audit.log once per day (Nextcloud re-creates them)
logs_rotate_nextcloud() {
	local d=$HV_LOG_DIR/nextcloud f stamp
	[[ -d $d ]] || return 0
	stamp=$(date -d yesterday +%F)
	for f in nextcloud audit; do
		[[ -s $d/$f.log && ! -e $d/$f-$stamp.log ]] || continue
		# only rotate when the file was last written before today
		if [[ $(date -r "$d/$f.log" +%F) != "$(date +%F)" ]] || [[ ${1:-} == force ]]; then
			mv -f "$d/$f.log" "$d/$f-$stamp.log"
		fi
	done
}

# state/status.json (read by the panel)
status_write_json() {
	local tmp dir role name path st total free first=1 i last_ok=null lan
	mkdir -p "$HV_STATE_DIR"
	tmp=$HV_STATE_DIR/status.json.tmp
	[[ -f $HV_STATE_DIR/last-backup-ok ]] && last_ok=$(json_str "$(cat "$HV_STATE_DIR/last-backup-ok")")
	lan=$(detect_lan | awk '{print $1}')
	storage_parse_conf >/dev/null 2>&1 || true
	{
		printf '{"generated":%s,"platform":"linux","hostname":%s,"homevault_version":%s,' \
			"$(json_str "$(date -Iseconds)")" "$(json_str "$(hostname 2>/dev/null || echo homevault)")" "$(json_str "$(hv_version)")"
		printf '"host":%s,"lan_ip":%s,"lan_ip_detected":%s,"url":%s,"log_retention_days":%s,' \
			"$(json_str "${HV_HOST:-}")" "$(json_str "${HV_LAN_IP:-}")" "$(json_str "$lan")" \
			"$(json_str "${HV_OVERWRITE_CLI_URL:-}")" "${HV_LOG_RETENTION_DAYS:-7}"
		printf '"backup":{"configured":%s,"target":%s,"last_ok":%s,"schedule":%s},"disks":[' \
			"$(backup_configured && echo true || echo false)" "$(json_str "${HV_BACKUP_TARGET:-local}")" "$last_ok" \
			"$(json_str "${HV_BACKUP_TIME:-03:30}")"
		{
			printf '主数据\tNextcloud 数据\t%s\n' "${HV_NC_DATA_PATH:-}"
			for i in "${!ST_NAME[@]}"; do printf '扩展存储\t%s\t%s\n' "${ST_NAME[i]}" "${ST_PATH[i]}"; done
			if [[ ${HV_BACKUP_TARGET:-local} == local && -n ${HV_BACKUP_LOCAL_PATH:-} ]]; then
				printf '备份\trestic 仓库\t%s\n' "$HV_BACKUP_LOCAL_PATH"
			fi
			[[ -n ${HV_DATA_DIR:-} ]] && printf '系统数据\tHomeVault 数据目录\t%s\n' "$HV_DATA_DIR"
		} | while IFS=$'\t' read -r role name path; do
			[[ -n $path ]] || continue
			st=$(fs_stats "$path")
			total=${st%% *}
			free=$(awk '{print $2}' <<<"$st")
			((first)) || printf ','
			first=0
			printf '{"role":%s,"name":%s,"path":%s,"total":%s,"free":%s,"mounted":%s}' \
				"$(json_str "$role")" "$(json_str "$name")" "$(json_str "$path")" "${total:-0}" "${free:-0}" \
				"$([[ -d $path ]] && echo true || echo false)"
		done
		printf ']}\n'
	} >"$tmp"
	chmod 0644 "$tmp"
	mv -f "$tmp" "$HV_STATE_DIR/status.json"
}

# state/vpn-status.json: device name, VPN address, last handshake, rx/tx (no keys)
vpn_write_status() {
	local tmp=$HV_STATE_DIR/vpn-status.json.tmp conf dump first=1 line pub name addr hs rx tx
	local -A names=()
	vpn_enabled || return 0
	[[ -n $(dc_cid wg-easy) ]] || return 0
	conf=$(dc exec -T wg-easy cat /etc/wireguard/wg0.conf 2>/dev/null) || return 0
	dump=$(dc exec -T wg-easy wg show wg0 dump 2>/dev/null) || return 0
	name=''
	while IFS= read -r line; do
		if [[ $line =~ ^\#\ Client:\ (.*)\ \([0-9]+\)$ ]]; then
			name=${BASH_REMATCH[1]}
		elif [[ $line =~ ^PublicKey[[:space:]]*=[[:space:]]*([^[:space:]]+) && -n $name ]]; then
			names[${BASH_REMATCH[1]}]=$name
			name=''
		fi
	done <<<"$conf"
	{
		printf '{"generated":%s,"interface":"wg0","endpoint":%s,"peers":[' "$(json_str "$(date -Iseconds)")" \
			"$(json_str "${WG_HOST:-}:${WG_PORT:-}")"
		# dump peer lines: pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
		while IFS=$'\t' read -r pub _ _ addr hs rx tx _; do
			[[ -n ${names[$pub]+x} ]] || continue
			((first)) || printf ','
			first=0
			printf '{"name":%s,"address":%s,"latest_handshake":%s,"rx_bytes":%s,"tx_bytes":%s}' \
				"$(json_str "${names[$pub]}")" "$(json_str "$addr")" "${hs:-0}" "${rx:-0}" "${tx:-0}"
		done < <(tail -n +2 <<<"$dump")
		printf ']}\n'
	} >"$tmp"
	chmod 0644 "$tmp"
	mv -f "$tmp" "$HV_STATE_DIR/vpn-status.json"
}

cmd_status_update() {
	hv_require_env
	status_write_json
	vpn_write_status || true
}

cmd_maintenance() {
	hv_require_env
	require_root
	logs_prepare_dirs
	logs_export_containers
	logs_rotate_nextcloud
	logs_clean
	status_write_json
	vpn_write_status || true
	ok "每日维护完成"
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
		msg "当前日志保留天数：${HV_LOG_RETENTION_DAYS:-7}"
		return 0
	fi
	retention_valid "$days" || die "天数必须在 1–365 之间"
	env_set HV_LOG_RETENTION_DAYS "$((10#$days))"
	ok "日志保留天数已设为 $((10#$days)) 天（Caddy 访问日志在 caddy 重建后生效）"
	if [[ -n $(dc_cid caddy 2>/dev/null) ]]; then
		dc up -d caddy >/dev/null 2>&1 || true
	fi
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
# requests_parse FILE → prints "type<TAB>days" (validated) or fails
requests_parse() {
	local f=$1 body type='' days=''
	[[ -f $f && ! -L $f ]] || return 1
	(($(stat -c %s "$f") <= 4096)) || return 1
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

requests_result() {
	local done_dir=$1 base=$2 type=$3 okv=$4 message=$5
	printf '{"request":%s,"type":%s,"ok":%s,"finished":%s,"message":%s}\n' "$(json_str "$base")" \
		"$(json_str "$type")" "$okv" "$(json_str "$(date -Iseconds)")" "$(json_str "$message")" >"$done_dir/${base%.json}.result.json"
	chmod 0644 "$done_dir/${base%.json}.result.json"
}

cmd_requests() {
	local sub=${1:-process} dir done_dir f base parsed type days rc
	[[ $sub == process ]] || die "用法：$HV_SELF requests process"
	hv_require_env
	require_root
	dir=$HV_STATE_DIR/requests
	done_dir=$dir/done
	[[ -d $dir ]] || return 0
	mkdir -p "$done_dir"
	for f in "$dir"/*.json; do
		[[ -e $f ]] || continue
		base=$(basename "$f")
		[[ $base =~ ^[A-Za-z0-9._-]{1,128}\.json$ ]] || {
			rm -f -- "$f"
			continue
		}
		if ! parsed=$(requests_parse "$f"); then
			mv -f -- "$f" "$done_dir/$base"
			requests_result "$done_dir" "$base" unknown false "请求无效或类型不在允许列表中"
			continue
		fi
		IFS=$'\t' read -r type days <<<"$parsed"
		mv -f -- "$f" "$done_dir/$base"
		hv_log "REQUEST $type ${days:-}"
		rc=0
		case $type in
		backup) (cmd_backup) >/dev/null 2>&1 || rc=$? ;;
		log-clean) (logs_clean) >/dev/null 2>&1 || rc=$? ;;
		log-retention) (logs_retention "$days") >/dev/null 2>&1 || rc=$? ;;
		esac
		if ((rc == 0)); then
			requests_result "$done_dir" "$base" "$type" true "完成"
		else
			requests_result "$done_dir" "$base" "$type" false "失败（退出码 $rc），详见日志"
		fi
	done
	# keep only 100 newest results
	find "$done_dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +201 | cut -d' ' -f2- |
		while IFS= read -r f; do rm -f -- "$f"; done
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
			slug=${HV_ANDROID_REPO:-$(android_repo_slug || true)}
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
