# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# Multi-disk storage (SPEC §9): disk table, storage.conf, compose.storage.yaml, files_external sync.

HV_STORAGE_CONF=${HV_STORAGE_CONF:-$HV_ROOT/storage.conf}
HV_STORAGE_COMPOSE=${HV_STORAGE_COMPOSE:-$HV_ROOT/compose.storage.yaml}
ST_NAME=() ST_PATH=() ST_MODE=() ST_BACKUP=() ST_USERS=() ST_SLUG=()

# slug = 's' + first 8 hex chars of sha256(UTF-8 bytes of the path exactly as written)
storage_slug() {
	local h
	h=$(printf '%s' "$1" | sha256sum)
	printf 's%s\n' "${h:0:8}"
}

storage_conf_header() {
	cat <<'EOF'
# HomeVault 额外存储配置（由 hv storage add/remove 维护，也可手动编辑；修改后运行 hv storage apply）
# 名称|主机路径|rw或ro|是否备份(yes/no)|可见用户(空=所有用户; 逗号分隔; @开头为群组)
EOF
}

# storage_path_problem PATH → prints why PATH must not become a Nextcloud storage (status 0), else status 1.
# Linux only. Every Nextcloud user who sees the mount could otherwise read (or, rw, change) HomeVault's own
# secrets, database files or the Caddy CA private key, or the host system.
storage_path_problem() {
	local p s label
	p=$(realpath -m -- "$1" 2>/dev/null) || p=$1
	case $p in
	/ | /etc | /etc/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /run | /run/* | /boot | /boot/* | /root | /root/* | \
		/usr | /usr/* | /bin | /bin/* | /sbin | /sbin/* | /lib | /lib/* | /lib64 | /lib64/* | /var/lib/docker | /var/lib/docker/* | \
		/var/run | /var/run/*)
		printf '系统目录 %s\n' "$p"
		return 0
		;;
	esac
	while IFS='|' read -r label s; do
		[[ $s == /* ]] || continue
		s=$(realpath -m -- "$s" 2>/dev/null) || continue
		# the data root may contain storages (e.g. /mnt/disk1/照片), but must not itself be (inside) one
		if [[ $label == data-root ]]; then
			[[ $p == "$s" || $s == "$p"/* ]] && { printf 'HomeVault 数据目录 %s\n' "$s"; return 0; }
			continue
		fi
		if [[ $p == "$s" || $p == "$s"/* || $s == "$p"/* ]]; then
			printf '%s %s\n' "$label" "$s"
			return 0
		fi
	done < <(
		printf '%s|%s\n' 'HomeVault 程序目录（含密钥）' "${HV_ROOT:-}" 'Nextcloud 主数据目录' "${HV_NC_DATA_PATH:-}" \
			data-root "${HV_DATA_DIR:-}" 'Nextcloud 程序目录' "${HV_VOL_HTML:-}" '数据库目录' "${HV_VOL_DB:-}" \
			'Redis 目录' "${HV_VOL_REDIS:-}" 'Caddy 数据目录（含 CA 私钥）' "${HV_VOL_CADDY_DATA:-}" \
			'Caddy 配置目录' "${HV_VOL_CADDY_CONFIG:-}" 'wg-easy 目录（含 VPN 密钥）' "${HV_VOL_WGEASY:-}" \
			'数据库导出目录' "${HV_DUMP_DIR:-}" '日志目录' "${HV_LOG_DIR:-}"
		[[ ${HV_BACKUP_TARGET:-local} == local ]] && printf '%s|%s\n' '备份仓库' "${HV_BACKUP_LOCAL_PATH:-}"
	)
	return 1
}

# storage_parse_conf [file] → fills ST_* arrays; returns 1 on validation errors
storage_parse_conf() {
	local file=${1:-$HV_STORAGE_CONF} line n=0 rc=0 name path mode backup users extra problem
	local -A seen_name=() seen_path=()
	ST_NAME=() ST_PATH=() ST_MODE=() ST_BACKUP=() ST_USERS=() ST_SLUG=()
	[[ -f $file ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		line=${line%$'\r'}
		[[ $n == 1 ]] && line=${line#$'\xef\xbb\xbf'}
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		IFS='|' read -r name path mode backup users extra <<<"$line"
		name=$(trim "$name")
		path=$(trim "$path")
		mode=$(trim "${mode,,}")
		backup=$(trim "${backup,,}")
		users=$(trim "$users")
		users=${users// /}
		if [[ -n ${extra:-} ]]; then
			err "storage.conf 第 $n 行：字段过多（应为 5 列）"
			rc=1
			continue
		fi
		if [[ -z $name || $name == *[/\\$'\t']* || $name == .* ]]; then
			err "storage.conf 第 $n 行：名称为空或包含非法字符（/ \\ 制表符，或以 . 开头）：$name"
			rc=1
			continue
		fi
		if [[ $HV_PLATFORM != windows && $path != /* ]]; then
			err "storage.conf 第 $n 行：主机路径必须是绝对路径：$path"
			rc=1
			continue
		fi
		if [[ $HV_PLATFORM != windows ]] && problem=$(storage_path_problem "$path"); then
			err "storage.conf 第 $n 行：不能把 $path 作为额外存储：与$problem 重叠（Nextcloud 用户将能访问其中的文件）"
			rc=1
			continue
		fi
		[[ $mode == rw || $mode == ro ]] || {
			err "storage.conf 第 $n 行：第 3 列必须是 rw 或 ro：$mode"
			rc=1
			continue
		}
		[[ $backup == yes || $backup == no ]] || {
			err "storage.conf 第 $n 行：第 4 列必须是 yes 或 no：$backup"
			rc=1
			continue
		}
		if [[ -n ${seen_name[$name]:-} ]]; then
			err "storage.conf 第 $n 行：名称重复：$name"
			rc=1
			continue
		fi
		if [[ -n ${seen_path[$path]:-} ]]; then
			err "storage.conf 第 $n 行：路径重复：$path"
			rc=1
			continue
		fi
		seen_name[$name]=1
		seen_path[$path]=1
		ST_NAME+=("$name")
		ST_PATH+=("$path")
		ST_MODE+=("$mode")
		ST_BACKUP+=("$backup")
		ST_USERS+=("$users")
		ST_SLUG+=("$(storage_slug "$path")")
	done <"$file"
	return $rc
}

# Top-level services defined in compose.yaml (simple YAML scan; 2-space indent keys)
compose_services() {
	local file=${1:-$HV_ROOT/compose.yaml}
	[[ -f $file ]] || return 0
	awk '/^services:[[:space:]]*$/ {s=1; next}
		/^[^[:space:]#]/ {s=0}
		s && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {k=$1; sub(/:$/, "", k); print k}' "$file"
}

_st_bind() {
	# _st_bind source target ro(true|false)
	printf '      - type: bind\n'
	printf '        source: %s\n' "$(yaml_dq "$1" compose)"
	printf '        target: %s\n' "$(yaml_dq "$2" compose)"
	printf '        read_only: %s\n' "$3"
	printf '        bind:\n          create_host_path: false\n'
}

# _st_panel_bind source target check_exists — panel stat mounts are skipped when the source is missing
# (an unplugged backup disk must not prevent the panel from starting; it then shows the disk as missing)
_st_panel_bind() {
	if [[ $3 == 1 ]]; then
		[[ -e $1 ]] || return 0
	fi
	_st_bind "$1" "$2" true
}

# _st_scrutiny_devices [check_exists:1|0] — Scrutiny (profile monitor, Linux): HV_SCRUTINY_DEVICES →
# services.scrutiny.devices. Missing devices are skipped with a warning (they would stop the container).
_st_scrutiny_devices() {
	local d any=0
	is_true "${HV_MONITOR_ENABLED:-false}" || return 0
	for d in ${HV_SCRUTINY_DEVICES:-}; do
		if ! [[ $d =~ ^/dev/[A-Za-z0-9/_.-]+$ && $d != *..* ]]; then
			warn "HV_SCRUTINY_DEVICES：忽略无效的设备名 $d（例如 /dev/sda /dev/nvme0）" >&2
			continue
		fi
		if [[ ${1:-1} == 1 && ! -b $d && ! -c $d ]]; then
			warn "HV_SCRUTINY_DEVICES：设备 $d 不存在，已跳过" >&2
			continue
		fi
		((any)) || printf '  scrutiny:\n    devices:\n'
		any=1
		printf '      - %s\n' "$(yaml_dq "$d:$d" compose)"
	done
	return 0
}

# storage_render_compose <with_backup:0|1> <with_panel:0|1> [check_exists:1|0] [with_scrutiny:0|1] → YAML on stdout
# (empty when nothing to add).
# Panel mounts (SPEC §15): /config/storage.conf, /stat/data, /stat/backup (local target), /stat/storage/<slug>, all read-only.
storage_render_compose() {
	local with_backup=${1:-1} with_panel=${2:-0} chk=${3:-1} with_scrutiny=${4:-0} i svc ro any_backup=0 out panel
	out=$(
		if ((${#ST_NAME[@]})); then
			for svc in app cron; do
				printf '  %s:\n    volumes:\n' "$svc"
				for i in "${!ST_NAME[@]}"; do
					[[ ${ST_MODE[i]} == ro ]] && ro=true || ro=false
					_st_bind "${ST_PATH[i]}" "/mnt/hv/${ST_SLUG[i]}" "$ro"
				done
			done
		fi
		if ((with_backup)); then
			for i in "${!ST_NAME[@]}"; do
				[[ ${ST_BACKUP[i]} == yes ]] && any_backup=1
			done
			if ((any_backup)); then
				printf '  backup:\n    volumes:\n'
				for i in "${!ST_NAME[@]}"; do
					[[ ${ST_BACKUP[i]} == yes ]] || continue
					_st_bind "${ST_PATH[i]}" "/src/storage/${ST_SLUG[i]}" true
				done
			fi
		fi
		if ((with_panel)); then
			panel=$(
				[[ -f $HV_STORAGE_CONF ]] && _st_bind "$HV_STORAGE_CONF" /config/storage.conf true
				[[ -n ${HV_NC_DATA_PATH:-} ]] && _st_panel_bind "$HV_NC_DATA_PATH" /stat/data "$chk"
				if [[ ${HV_BACKUP_TARGET:-local} == local && -n ${HV_BACKUP_LOCAL_PATH:-} ]]; then
					_st_panel_bind "$HV_BACKUP_LOCAL_PATH" /stat/backup "$chk"
				fi
				for i in "${!ST_NAME[@]}"; do
					_st_panel_bind "${ST_PATH[i]}" "/stat/storage/${ST_SLUG[i]}" "$chk"
				done
			)
			if [[ -n $panel ]]; then
				printf '  panel:\n    volumes:\n%s\n' "$panel"
			fi
		fi
		((with_scrutiny)) && _st_scrutiny_devices "$chk"
		true
	)
	[[ -n $out ]] || return 0
	printf '# 由 hv storage apply 根据 storage.conf 自动生成，请勿手动编辑（重新生成会覆盖）\n'
	printf 'services:\n%s\n' "$out"
}

# Regenerate compose.storage.yaml. Returns 0 when the file changed, 1 when unchanged.
storage_render_file() {
	local tmp has_backup=0 has_panel=0 has_scrutiny=0 svc
	storage_parse_conf || die "storage.conf 有错误，请修正后重试"
	while IFS= read -r svc; do
		[[ $svc == backup ]] && has_backup=1
		[[ $svc == panel ]] && has_panel=1
		[[ $svc == scrutiny ]] && has_scrutiny=1
	done < <(compose_services)
	tmp=$(hv_mktemp)
	storage_render_compose "$has_backup" "$has_panel" 1 "$has_scrutiny" >"$tmp"
	if [[ ! -s $tmp ]]; then
		if [[ -f $HV_STORAGE_COMPOSE ]]; then
			rm -f "$HV_STORAGE_COMPOSE"
			return 0
		fi
		return 1
	fi
	if [[ -f $HV_STORAGE_COMPOSE ]] && cmp -s "$tmp" "$HV_STORAGE_COMPOSE"; then
		return 1
	fi
	install -m 0644 "$tmp" "$HV_STORAGE_COMPOSE"
	return 0
}

storage_render_if_needed() { storage_render_file || true; }

# ---------------------------------------------------------------------------
# Block devices (lsblk -P parsing, no jq)
# ---------------------------------------------------------------------------
declare -gA BLK_PK=() BLK_SIZE=() BLK_FS=() BLK_MP=() BLK_LABEL=() BLK_UUID=() BLK_ROTA=() BLK_TRAN=() BLK_TYPE=()
BLK_NAMES=()

# lsblk_parse < "lsblk -P -b -o NAME,PKNAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID,ROTA,TRAN,TYPE" output
lsblk_parse() {
	local line rest key val name
	local -A kv
	BLK_PK=() BLK_SIZE=() BLK_FS=() BLK_MP=() BLK_LABEL=() BLK_UUID=() BLK_ROTA=() BLK_TRAN=() BLK_TYPE=()
	BLK_NAMES=()
	while IFS= read -r line || [[ -n $line ]]; do
		kv=()
		rest=$line
		while [[ $rest =~ ^[[:space:]]*([A-Z:_-]+)=\"([^\"]*)\"(.*)$ ]]; do
			key=${BASH_REMATCH[1]}
			val=${BASH_REMATCH[2]}
			rest=${BASH_REMATCH[3]}
			[[ $val == *'\x'* ]] && val=$(printf '%b' "$val")
			kv[$key]=$val
		done
		name=${kv[NAME]:-}
		[[ -n $name ]] || continue
		[[ -n ${BLK_TYPE[$name]+x} ]] || BLK_NAMES+=("$name")
		BLK_PK[$name]=${kv[PKNAME]:-}
		BLK_SIZE[$name]=${kv[SIZE]:-0}
		BLK_FS[$name]=${kv[FSTYPE]:-}
		# keep an existing mountpoint when a device is listed twice
		[[ -n ${kv[MOUNTPOINT]:-} || -z ${BLK_MP[$name]:-} ]] && BLK_MP[$name]=${kv[MOUNTPOINT]:-}
		BLK_LABEL[$name]=${kv[LABEL]:-}
		BLK_UUID[$name]=${kv[UUID]:-}
		BLK_ROTA[$name]=${kv[ROTA]:-}
		BLK_TRAN[$name]=${kv[TRAN]:-}
		BLK_TYPE[$name]=${kv[TYPE]:-}
	done
}

lsblk_load() {
	have lsblk || return 1
	lsblk_parse < <(lsblk -P -b -o NAME,PKNAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID,ROTA,TRAN,TYPE 2>/dev/null)
}

# blk_disk_of NAME → top-level physical disk name
blk_disk_of() {
	local n=$1 i
	for ((i = 0; i < 16; i++)); do
		[[ ${BLK_TYPE[$n]:-} == disk || -z ${BLK_PK[$n]:-} ]] && break
		n=${BLK_PK[$n]}
	done
	printf '%s\n' "$n"
}

# blk_of_path PATH → lsblk NAME of the device holding PATH ('' if not a block device)
blk_of_path() {
	local p=$1 src
	while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
	src=$(findmnt -n -o SOURCE --target "$p" 2>/dev/null | head -n1) || true
	src=${src%%\[*}
	[[ $src == /dev/* ]] || return 0
	src=$(basename "$src")
	[[ -n ${BLK_TYPE[$src]+x} ]] && printf '%s\n' "$src"
	return 0
}

# disk_of_path PATH → physical disk name ('' if unknown)
disk_of_path() {
	local b
	b=$(blk_of_path "$1")
	[[ -n $b ]] && blk_disk_of "$b"
	return 0
}

blk_kind() {
	local d
	d=$(blk_disk_of "$1")
	case ${BLK_ROTA[$d]:-} in
	0) echo SSD ;;
	1) echo HDD ;;
	*) echo - ;;
	esac
}

blk_is_usb() {
	local d
	d=$(blk_disk_of "$1")
	[[ ${BLK_TRAN[$d]:-} == usb ]]
}

# Role labels for a mountpoint
_storage_roles() {
	local mp=$1 roles='' i sysdisk d
	d=$(disk_of_path "$mp")
	sysdisk=$(disk_of_path /)
	[[ -n $d && $d == "$sysdisk" && $mp == / ]] && roles+='系统盘 '
	if [[ -n ${HV_NC_DATA_PATH:-} && $(_mp_of "$HV_NC_DATA_PATH") == "$mp" ]]; then roles+='主数据 '; fi
	for i in "${!ST_PATH[@]}"; do
		if [[ $(_mp_of "${ST_PATH[i]}") == "$mp" ]]; then
			roles+="存储:${ST_NAME[i]} "
		fi
	done
	if [[ ${HV_BACKUP_TARGET:-} == local && -n ${HV_BACKUP_LOCAL_PATH:-} && $(_mp_of "$HV_BACKUP_LOCAL_PATH") == "$mp" ]]; then roles+='备份 '; fi
	printf '%s\n' "${roles% }"
}

_mp_of() {
	local p=$1
	while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
	{ findmnt -n -o TARGET --target "$p" 2>/dev/null || true; } | head -n1
}

# Print the Chinese disk table (SPEC §9)
storage_disk_table() {
	local n mp st total avail disk
	lsblk_load || {
		warn "未找到 lsblk，无法列出磁盘"
		return 0
	}
	{
		printf '挂载点\t设备\t文件系统\t总容量\t可用\t物理磁盘\tSSD/HDD\tUSB\t用途\n'
		for n in "${BLK_NAMES[@]}"; do
			mp=${BLK_MP[$n]}
			[[ -n $mp && $mp == /* ]] || continue
			case $mp in /boot | /boot/* | /snap/* | /run/* | /var/lib/docker/* | /proc/* | /sys/*) continue ;; esac
			[[ ${BLK_FS[$n]} == squashfs ]] && continue
			st=$(fs_stats "$mp")
			total=${st%% *}
			avail=$(awk '{print $2}' <<<"$st")
			disk=$(blk_disk_of "$n")
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mp" "/dev/$n" "${BLK_FS[$n]:--}" \
				"$(human_bytes "$total")" "$(human_bytes "$avail")" "$disk" "$(blk_kind "$n")" \
				"$(blk_is_usb "$n" && echo 是 || echo 否)" "$(_storage_roles "$mp")"
		done
	} | print_table
}

# Warnings about the chosen layout (SPEC §9)
storage_check_warnings() {
	local data_disk sys_disk bdisk b fs i sdisk
	lsblk_load || return 0
	sys_disk=$(disk_of_path /)
	if [[ -n ${HV_NC_DATA_PATH:-} ]]; then
		data_disk=$(disk_of_path "$HV_NC_DATA_PATH")
		b=$(blk_of_path "$HV_NC_DATA_PATH")
		if [[ -n $data_disk && $data_disk == "$sys_disk" ]]; then
			warn "主数据目录 $HV_NC_DATA_PATH 位于系统盘（$sys_disk）上：系统盘损坏或重装会波及数据，建议使用单独的数据盘。"
		fi
		if [[ -n $b ]]; then
			fs=${BLK_FS[$b]:-}
			[[ $fs == vfat || $fs == exfat ]] && warn "主数据目录所在分区是 $fs：不支持 Linux 权限，FAT32 单文件最大 4 GB，强烈不建议。"
			blk_is_usb "$b" && warn "主数据目录位于 USB 移动硬盘：断开或休眠会导致 Nextcloud 出错，不建议作为主数据盘。"
		fi
	fi
	for i in "${!ST_PATH[@]}"; do
		b=$(blk_of_path "${ST_PATH[i]}")
		[[ -n $b ]] || continue
		fs=${BLK_FS[$b]:-}
		[[ $fs == vfat || $fs == exfat ]] && warn "存储「${ST_NAME[i]}」所在分区是 $fs：无权限控制，FAT32 单文件最大 4 GB。"
	done
	if [[ ${HV_BACKUP_TARGET:-} == local && -n ${HV_BACKUP_LOCAL_PATH:-} ]]; then
		bdisk=$(disk_of_path "$HV_BACKUP_LOCAL_PATH")
		if [[ -n $bdisk && -n ${data_disk:-} && $bdisk == "$data_disk" ]]; then
			warn "【严重】备份目标 $HV_BACKUP_LOCAL_PATH 与主数据在同一块物理磁盘（$bdisk）上：磁盘损坏时数据和备份会一起丢失！请改用另一块硬盘。"
		fi
		for i in "${!ST_PATH[@]}"; do
			[[ ${ST_MODE[i]} == rw ]] || continue
			sdisk=$(disk_of_path "${ST_PATH[i]}")
			if [[ -n $bdisk && $sdisk == "$bdisk" ]]; then
				warn "【严重】备份目标与可写存储「${ST_NAME[i]}」在同一块物理磁盘（$bdisk）上，请改用另一块硬盘。"
			fi
		done
	fi
	return 0
}

# ---------------------------------------------------------------------------
# files_external synchronisation (runs occ inside the app container)
# ---------------------------------------------------------------------------
# PHP (fixed code, no user input) turning `files_external:list --output=json` into TSV lines:
# id \t mount_point \t datadir \t readonly(0|1) \t users(csv) \t groups(csv)
# shellcheck disable=SC2016 # PHP code
HV_PHP_MOUNTS_TSV='$j=json_decode(stream_get_contents(STDIN),true);
if(!is_array($j)){fwrite(STDERR,"invalid json\n");exit(1);}
foreach($j as $m){$c=$m["configuration"]??[];$o=$m["options"]??[];
echo $m["mount_id"],"\t",$m["mount_point"],"\t",($c["datadir"]??""),"\t",(empty($o["readonly"])?"0":"1"),"\t",
implode(",",$m["applicable_users"]??[]),"\t",implode(",",$m["applicable_groups"]??[]),"\n";}'

storage_occ_sync() {
	local json tsv id mp dd ro cu cg i target want_ro n_ok=0
	local -A cur_id=() cur_mp=() cur_users=() cur_groups=()
	local -a args
	occ app:enable files_external >/dev/null || die "无法启用 files_external 应用"
	json=$(occ files_external:list --output=json) || die "files_external:list 执行失败"
	tsv=$(printf '%s' "$json" | dc exec -T -u www-data app php -r "$HV_PHP_MOUNTS_TSV") || die "解析挂载列表失败"
	while IFS=$'\t' read -r id mp dd ro cu cg; do
		[[ -n $id && $dd == /mnt/hv/* ]] || continue
		cur_id[$dd]=$id
		cur_mp[$dd]=$mp
		cur_users[$dd]=$cu
		cur_groups[$dd]=$cg
	done <<<"$tsv"

	for i in "${!ST_NAME[@]}"; do
		target=/mnt/hv/${ST_SLUG[i]}
		id=${cur_id[$target]:-}
		if [[ -n $id && ${cur_mp[$target]} != "/${ST_NAME[i]}" ]]; then
			warn "存储「${ST_NAME[i]}」名称已变更，重新创建挂载（原有分享会失效）"
			occ files_external:delete -y "$id" >/dev/null || warn "删除旧挂载 $id 失败"
			id=''
			cur_users[$target]=''
			cur_groups[$target]=''
		fi
		if [[ -z $id ]]; then
			id=$(occ files_external:create --output=json "/${ST_NAME[i]}" local null::null -c "datadir=$target" | tr -dc '0-9')
			[[ -n $id ]] || {
				err "创建挂载「${ST_NAME[i]}」失败"
				continue
			}
			cur_users[$target]=''
			cur_groups[$target]=''
			info "已创建挂载「${ST_NAME[i]}」（ID $id）"
		fi
		[[ ${ST_MODE[i]} == ro ]] && want_ro=true || want_ro=false
		occ files_external:option "$id" readonly "$want_ro" >/dev/null || warn "设置只读选项失败（ID $id）"
		occ files_external:option "$id" filesystem_check_changes 1 >/dev/null || warn "设置变更检测失败（ID $id）"
		mapfile -t args < <(storage_applicable_args "${ST_USERS[i]}" "${cur_users[$target]:-}" "${cur_groups[$target]:-}")
		if ((${#args[@]})); then
			occ files_external:applicable "$id" "${args[@]}" >/dev/null || err "设置可见用户失败（ID $id）：${ST_USERS[i]}"
		fi
		unset "cur_id[$target]"
		n_ok=$((n_ok + 1))
	done
	# remove HomeVault-managed mounts no longer configured
	for dd in "${!cur_id[@]}"; do
		info "删除已不在 storage.conf 中的挂载 ${cur_mp[$dd]}（ID ${cur_id[$dd]}）"
		occ files_external:delete -y "${cur_id[$dd]}" >/dev/null || warn "删除挂载失败（ID ${cur_id[$dd]}）"
	done
	ok "已同步 $n_ok 个额外存储挂载"
}

# storage_applicable_args "<desired csv>" "<current users csv>" "<current groups csv>"
# → one occ argument per line (empty output = nothing to change)
storage_applicable_args() {
	local desired=$1 cu=$2 cg=$3 x
	local -A want_u=() want_g=() have_u=() have_g=()
	local IFS=,
	for x in $desired; do
		[[ -n $x ]] || continue
		if [[ $x == @* ]]; then want_g[${x#@}]=1; else want_u[$x]=1; fi
	done
	for x in $cu; do [[ -n $x ]] && have_u[$x]=1; done
	for x in $cg; do [[ -n $x ]] && have_g[$x]=1; done
	unset IFS
	if ((${#want_u[@]} == 0 && ${#want_g[@]} == 0)); then
		((${#have_u[@]} || ${#have_g[@]})) && printf '%s\n' --remove-all
		return 0
	fi
	for x in "${!want_u[@]}"; do [[ -n ${have_u[$x]:-} ]] || printf '%s\n%s\n' --add-user "$x"; done
	for x in "${!want_g[@]}"; do [[ -n ${have_g[$x]:-} ]] || printf '%s\n%s\n' --add-group "$x"; done
	for x in "${!have_u[@]}"; do [[ -n ${want_u[$x]:-} ]] || printf '%s\n%s\n' --remove-user "$x"; done
	for x in "${!have_g[@]}"; do [[ -n ${want_g[$x]:-} ]] || printf '%s\n%s\n' --remove-group "$x"; done
	return 0
}

storage_offer_acl() {
	local i perm
	for i in "${!ST_NAME[@]}"; do
		[[ -d ${ST_PATH[i]} ]] || {
			warn "路径不存在：${ST_PATH[i]}（请先挂载硬盘/创建目录）"
			continue
		}
		[[ ${ST_MODE[i]} == rw ]] && perm=rwX || perm=rX
		if have setfacl; then
			if [[ ${HV_STORAGE_ACL:-ask} == yes ]] || { [[ ${HV_STORAGE_ACL:-ask} == ask ]] && is_interactive &&
				confirm "为「${ST_NAME[i]}」(${ST_PATH[i]}) 授予 Nextcloud(www-data, uid 33) $perm 权限（setfacl -R）？" n; }; then
				setfacl -R -m "u:33:$perm" -m "d:u:33:$perm" -- "${ST_PATH[i]}" && ok "已设置 ACL：${ST_PATH[i]}"
			fi
		else
			msg "提示：Nextcloud 以 uid 33 运行，需要对「${ST_PATH[i]}」有 $perm 权限。可安装 acl 后执行："
			msg "  setfacl -R -m u:33:$perm -m d:u:33:$perm '${ST_PATH[i]}'"
		fi
	done
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_storage() {
	local sub=${1:-list}
	(($#)) && shift
	case $sub in
	list) storage_cmd_list "$@" ;;
	add) storage_cmd_add "$@" ;;
	remove | rm) storage_cmd_remove "$@" ;;
	apply) storage_cmd_apply "$@" ;;
	-h | --help | help) help_cmd storage ;;
	*) die "未知子命令：storage $sub（可用：list add remove apply）" ;;
	esac
}

storage_cmd_list() {
	local i
	storage_parse_conf || true
	title "磁盘与挂载点"
	storage_disk_table
	title "HomeVault 存储"
	{
		printf '角色\t名称\t主机路径\t模式\t备份\t可见用户\t容器内路径\n'
		printf '主数据\tNextcloud 数据\t%s\trw\tyes\t-\t/var/www/data\n' "${HV_NC_DATA_PATH:-未设置}"
		for i in "${!ST_NAME[@]}"; do
			printf '扩展存储\t%s\t%s\t%s\t%s\t%s\t/mnt/hv/%s\n' "${ST_NAME[i]}" "${ST_PATH[i]}" "${ST_MODE[i]}" \
				"${ST_BACKUP[i]}" "${ST_USERS[i]:-所有用户}" "${ST_SLUG[i]}"
		done
		if [[ $HV_BACKUP_TARGET == s3 ]]; then
			printf '备份\trestic (S3)\t%s\t-\t-\t-\t-\n' "${HV_BACKUP_S3_REPO:-未设置}"
		else
			printf '备份\trestic\t%s\t-\t-\t-\t/repo\n' "${HV_BACKUP_LOCAL_PATH:-未设置}"
		fi
	} | print_table
	storage_check_warnings
}

storage_cmd_add() {
	local name='' path='' mode='' backup='' users='' apply=ask line
	while (($#)); do
		case $1 in
		--name) name=${2:?}; shift ;;
		--path) path=${2:?}; shift ;;
		--mode) mode=${2:?}; shift ;;
		--ro) mode=ro ;;
		--rw) mode=rw ;;
		--backup) backup=${2:?}; shift ;;
		--users) users=${2:-}; shift ;;
		--apply) apply=yes ;;
		--no-apply) apply=no ;;
		-h | --help) help_cmd storage; return 0 ;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	hv_require_env
	if [[ -z $path ]] && is_interactive; then
		storage_disk_table
		msg "提示：选择一个已挂载硬盘上的目录（例如 /mnt/disk2/照片）。"
	fi
	[[ -n $name ]] || name=$(ask "存储名称（在 Nextcloud 中显示为文件夹名）" "")
	[[ -n $path ]] || path=$(ask "主机上的目录（绝对路径）" "")
	[[ -n $mode ]] || mode=$(ask_choice "访问模式：rw=可读写，ro=只读" rw rw ro)
	[[ -n $backup ]] || backup=$(ask_choice "是否纳入每日备份" no yes no)
	if [[ -z $users ]] && is_interactive; then
		users=$(ask "可见用户（留空=所有用户；多个用逗号分隔；群组以 @ 开头）" "")
	fi
	[[ -n $name && -n $path ]] || die "必须提供 --name 和 --path"
	[[ $path == /* ]] || die "路径必须是绝对路径：$path"
	[[ $name != *'|'* && $path != *'|'* && $users != *'|'* ]] || die "名称/路径/用户中不能包含 |"
	[[ -d $path ]] || die "目录不存在：$path（请先挂载硬盘并创建目录）"
	if [[ -n ${HV_NC_DATA_PATH:-} && ($path == "$HV_NC_DATA_PATH" || $path == "$HV_NC_DATA_PATH"/*) ]]; then
		die "不能把 Nextcloud 主数据目录内部作为额外存储：$path"
	fi
	line="$name|$path|${mode,,}|${backup,,}|$users"
	if [[ ! -f $HV_STORAGE_CONF ]]; then
		(umask 022 && storage_conf_header >"$HV_STORAGE_CONF")
	fi
	# validate the resulting file before writing
	local tmp
	tmp=$(hv_mktemp)
	cat "$HV_STORAGE_CONF" >"$tmp"
	printf '%s\n' "$line" >>"$tmp"
	storage_parse_conf "$tmp" || die "未添加（见上方错误）"
	printf '%s\n' "$line" >>"$HV_STORAGE_CONF"
	ok "已添加存储「$name」→ $path（slug $(storage_slug "$path")）"
	if [[ $apply == yes ]] || { [[ $apply == ask ]] && confirm "现在应用（重建容器并同步 Nextcloud 挂载）？" y; }; then
		storage_cmd_apply
	else
		msg "稍后运行：$HV_SELF storage apply"
	fi
}

storage_cmd_remove() {
	local name='' apply=ask tmp line found=0 n
	while (($#)); do
		case $1 in
		--apply) apply=yes ;;
		--no-apply) apply=no ;;
		-h | --help) help_cmd storage; return 0 ;;
		*) name=$1 ;;
		esac
		shift
	done
	hv_require_env
	[[ -n $name ]] || die "用法：$HV_SELF storage remove <名称>"
	[[ -f $HV_STORAGE_CONF ]] || die "storage.conf 不存在"
	tmp=$(hv_mktemp)
	while IFS= read -r line || [[ -n $line ]]; do
		IFS='|' read -r n _ <<<"$line"
		if [[ ! ${line%$'\r'} =~ ^[[:space:]]*# && $(trim "$n") == "$name" ]]; then
			found=1
			continue
		fi
		printf '%s\n' "$line"
	done <"$HV_STORAGE_CONF" >"$tmp"
	((found)) || die "未找到名为「$name」的存储"
	confirm "从 HomeVault 移除存储「$name」？（不会删除硬盘上的文件）" y || die "已取消"
	cat "$tmp" >"$HV_STORAGE_CONF"
	ok "已从 storage.conf 移除「$name」"
	if [[ $apply == yes ]] || { [[ $apply == ask ]] && confirm "现在应用？" y; }; then
		storage_cmd_apply
	fi
}

storage_cmd_apply() {
	local no_occ=0 changed=0
	while (($#)); do
		case $1 in
		--no-occ) no_occ=1 ;;
		--acl) HV_STORAGE_ACL=yes ;;
		-h | --help) help_cmd storage; return 0 ;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	hv_require_env
	storage_render_file && changed=1
	if ((changed)); then ok "已更新 compose.storage.yaml"; else info "compose.storage.yaml 无变化"; fi
	storage_check_warnings
	((no_occ)) && return 0
	if ! stack_running; then
		warn "服务未运行，已只生成配置。启动后再运行：$HV_SELF storage apply"
		return 0
	fi
	if ((changed)); then
		info "重建 Nextcloud 容器以加载新的挂载…"
		dc up -d
		wait_app_ready 600 || die "Nextcloud 未就绪"
	fi
	storage_occ_sync
	storage_offer_acl
	((${#ST_NAME[@]})) && msg "如果硬盘上已有文件，可运行扫描：$HV_SELF occ files:scan --all"
	return 0
}
