# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# Restore from restic (SPEC §10): single files into restore/<时间>/ or full disaster recovery.

# restore_norm_path "alice/files/x" → /src/nextcloud-data/alice/files/x (absolute kept)
restore_norm_path() {
	local p=$1
	[[ $p == /* ]] || p=/src/nextcloud-data/$p
	while [[ $p == */ && $p != / ]]; do p=${p%/}; done
	printf '%s\n' "$p"
}

# Resolve a snapshot reference to its full id (latest by default)
restore_resolve_snapshot() {
	local ref=${1:-latest} json id
	if [[ $ref == latest ]]; then
		json=$(restic_run -- snapshots --json --latest 1 --group-by 'host,tags' --host homevault --tag homevault) || return 1
	else
		[[ $ref =~ ^[0-9a-f]{8,64}$ ]] || die "快照 ID 格式不正确：$ref"
		json=$(restic_run -- snapshots --json "$ref") || return 1
	fi
	id=$(grep -o '"id":"[0-9a-f]\{64\}"' <<<"$json" | tail -n1 | cut -d'"' -f4 || true)
	[[ -n $id ]] || return 1
	printf '%s\n' "$id"
}

# Long-syntax volume entry for the restore override (rw)
_restore_vol() {
	local src=$1 target=$2
	if [[ $src == /* || $src == ./* || $src == ../* ]]; then
		printf '      - type: bind\n        source: %s\n' "$(yaml_dq "$src" compose)"
	else
		printf '      - type: volume\n        source: %s\n' "$src"
	fi
	printf '        target: %s\n        read_only: false\n' "$target"
}

# Compose override making the backup container's source mounts writable
restore_render_override() {
	printf 'services:\n  backup:\n    volumes:\n'
	_restore_vol "${HV_VOL_HTML:-nc_html}" /src/nextcloud-html
	_restore_vol "$HV_NC_DATA_PATH" /src/nextcloud-data
	_restore_vol "${HV_VOL_CADDY_DATA:-caddy_data}" /src/caddy-data
	_restore_vol "${HV_DUMP_DIR:-hv_dumps}" /src/dumps
	if [[ ${HV_PLATFORM:-linux} == linux ]] && is_true "${HV_VPN_ENABLED:-true}"; then
		_restore_vol "${HV_VOL_WGEASY:-wg_easy}" /src/wg-easy
	fi
}

restore_list() {
	info "备份快照列表："
	restic_run -- snapshots --host homevault --tag homevault
	msg ""
	msg "恢复单个文件/目录：$HV_SELF restore --files <用户>/files/<路径> [--snapshot ID]"
	msg "整机灾难恢复：    $HV_SELF restore --full [--snapshot ID]"
}

restore_files() {
	local path=$1 snap=$2 ts dest id found
	path=$(restore_norm_path "$path")
	id=$(restore_resolve_snapshot "$snap") || die "找不到快照：$snap"
	ts=$(date +%Y%m%d-%H%M%S)
	dest=$HV_ROOT/restore/$ts
	install -d -m 0700 "$HV_ROOT/restore" "$dest"
	info "从快照 ${id:0:8} 恢复 $path …"
	restic_run -v "$dest:/restore" -- restore "$id" --target /restore --include "$path" || die "恢复失败"
	found=$(find "$dest" -mindepth 1 -print -quit 2>/dev/null || true)
	if [[ -z $found ]]; then
		rmdir "$dest" 2>/dev/null || true
		die "快照中没有找到：$path（可用 $HV_SELF restore --ls <目录> 查看快照内容）"
	fi
	ok "已恢复到：$dest$path"
	msg "请确认后自行复制回原位置（例如复制到 Nextcloud 数据目录后运行：$HV_SELF occ files:scan --all）。"
}

restore_ls() {
	local path=$1 snap=$2 id
	path=$(restore_norm_path "$path")
	id=$(restore_resolve_snapshot "$snap") || die "找不到快照：$snap"
	restic_run -- ls "$id" "$path"
}

# Read dbuser / dbpassword / dbname from the (restored) config.php inside a one-off app container.
restore_read_db_config() {
	local -n _db=$1
	local out
	# shellcheck disable=SC2016 # PHP code, not shell
	out=$(dc run --rm --no-deps -T --entrypoint php app -r \
		'include "/var/www/html/config/config.php"; echo ($CONFIG["dbuser"]??""),"\n",($CONFIG["dbpassword"]??""),"\n",($CONFIG["dbname"]??"nextcloud"),"\n";') || return 1
	mapfile -t _db <<<"$out"
	[[ -n ${_db[0]:-} && -n ${_db[2]:-} ]]
}

restore_db() {
	local dump=$1 user pass name
	local -a dbc
	restore_read_db_config dbc || die "无法从恢复的 config.php 读取数据库配置"
	user=${dbc[0]} pass=${dbc[1]} name=${dbc[2]}
	[[ $user =~ ^[A-Za-z0-9_]+$ && $name =~ ^[A-Za-z0-9_]+$ ]] || die "config.php 中的数据库用户名/库名格式异常"
	info "重建数据库 $name …"
	{
		if [[ $user != nextcloud ]]; then
			printf "DO \$hv\$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') THEN CREATE ROLE \"%s\" LOGIN PASSWORD '%s'; ELSE ALTER ROLE \"%s\" WITH LOGIN PASSWORD '%s'; END IF; END\$hv\$;\n" \
				"$user" "$user" "${pass//\'/\'\'}" "$user" "${pass//\'/\'\'}"
		fi
		printf 'DROP DATABASE IF EXISTS "%s" WITH (FORCE);\n' "$name"
		printf 'CREATE DATABASE "%s" OWNER "%s";\n' "$name" "$user"
	} | dc exec -T db psql -q -U nextcloud -d postgres -v ON_ERROR_STOP=1 >/dev/null || die "重建数据库失败"
	info "导入数据库转储（$(human_bytes "$(stat -c %s "$dump")")）…"
	dc exec -T db psql -q -U nextcloud -d "$name" -v ON_ERROR_STOP=1 <"$dump" >/dev/null || die "导入数据库失败"
	ok "数据库已恢复"
}

restore_full() {
	local snap=$1 force=$2 id override sub dump ans
	local -a optional=(/src/nextcloud-html/custom_apps /src/nextcloud-html/themes /src/caddy-data)
	warn "整机恢复会用快照内容【覆盖】当前的 Nextcloud 配置、数据目录、数据库、证书（以及 VPN 配置），快照之后的新文件会被删除！"
	if ! ((force)); then
		confirm "确定要继续吗？" n || die "已取消"
		if is_interactive; then
			read -r -p "请输入「确认恢复」四个字以继续：" ans || ans=''
			[[ $ans == 确认恢复 ]] || die "已取消"
		else
			die "非交互模式下整机恢复需要同时指定 --yes 和 --force"
		fi
	fi
	id=$(restore_resolve_snapshot "$snap") || die "找不到快照：$snap"
	info "使用快照 ${id:0:8}"
	override=$(hv_mktemp)
	restore_render_override >"$override"
	[[ ${HV_PLATFORM:-linux} == linux ]] && is_true "${HV_VPN_ENABLED:-true}" && optional+=(/src/wg-easy)

	info "停止 Nextcloud / Caddy …"
	local -a stop=(app cron caddy)
	[[ ${HV_PLATFORM:-linux} == linux ]] && is_true "${HV_VPN_ENABLED:-true}" && stop+=(wg-easy)
	dc stop "${stop[@]}" >/dev/null 2>&1 || true
	hv_add_cleanup restore_cleanup_start

	info "恢复数据库转储…"
	restic_run --compose-file "$override" -- restore "$id:/src/dumps" --target /src/dumps --delete || die "恢复 /src/dumps 失败"
	[[ ${HV_DUMP_DIR:-} == /* ]] || die "HV_DUMP_DIR 未设置或不是绝对路径（.env）"
	dump=$HV_DUMP_DIR/nextcloud.sql
	[[ -s $dump ]] || die "快照中没有数据库转储（nextcloud.sql），无法整机恢复"

	for sub in /src/nextcloud-html/config /src/nextcloud-data; do
		info "恢复 $sub …"
		restic_run --compose-file "$override" -- restore "$id:$sub" --target "$sub" --delete || die "恢复 $sub 失败"
	done
	for sub in "${optional[@]}"; do
		info "恢复 $sub …"
		restic_run --compose-file "$override" -- restore "$id:$sub" --target "$sub" --delete ||
			warn "快照中没有 $sub 或恢复失败，已跳过"
	done

	dc up -d db redis >/dev/null
	wait_service db 180 || die "数据库未能启动"
	restore_db "$dump"
	# shellcheck disable=SC2016 # expanded inside the container
	dc exec -T redis sh -c 'REDISCLI_AUTH="$(cat /run/secrets/redis_password 2>/dev/null)" redis-cli FLUSHALL' >/dev/null 2>&1 ||
		dc restart redis >/dev/null 2>&1 || warn "无法清空 Redis 缓存"

	info "启动全部服务…"
	HV_CLEANUP_FUNCS=()
	dc up -d
	wait_app_ready 1800 || die "Nextcloud 未就绪，请查看：$HV_SELF logs app"
	occ maintenance:mode --off >/dev/null 2>&1 || true
	info "更新文件指纹，通知客户端重新同步…"
	occ maintenance:data-fingerprint || warn "data-fingerprint 失败"
	info "重新扫描所有文件（文件多时需要较长时间）…"
	occ files:scan --all || warn "files:scan 失败"
	ok "整机恢复完成（快照 ${id:0:8}）。手机/电脑客户端可能提示冲突，请按提示处理。"
}

restore_cleanup_start() {
	warn "恢复中断，尝试重新启动服务…"
	dc up -d >/dev/null 2>&1 || true
}

cmd_restore() {
	local mode=list path='' snap=latest force=0
	while (($#)); do
		case $1 in
		--files)
			mode=files
			path=${2:?请指定快照中的路径}
			shift
			;;
		--ls)
			mode='ls'
			path=${2:?请指定快照中的目录，例如 /src 或 <用户>/files}
			shift
			;;
		--full) mode=full ;;
		--list) mode=list ;;
		--snapshot)
			snap=${2:?}
			shift
			;;
		--force) force=1 ;;
		-h | --help)
			help_cmd restore
			return 0
			;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	hv_require_env
	require_root
	backup_configured || die "尚未配置备份目标"
	storage_parse_conf || true
	case $mode in
	list) restore_list ;;
	ls) restore_ls "$path" "$snap" ;;
	files) restore_files "$path" "$snap" ;;
	full)
		((force)) && [[ $HV_YES != 1 ]] && force=0
		restore_full "$snap" "$force"
		;;
	esac
}
