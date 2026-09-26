# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# Backup with restic (SPEC §10) + systemd schedule.

HV_STATE_DIR=${HV_STATE_DIR:-$HV_ROOT/state}
_HV_MAINT_ON=0

backup_configured() {
	case ${HV_BACKUP_TARGET:-local} in
	local) [[ -n ${HV_BACKUP_LOCAL_PATH:-} ]] ;;
	s3) [[ -n ${HV_BACKUP_S3_REPO:-} ]] ;;
	*) return 1 ;;
	esac
}

# restic_repo_args OUT_ARRAY — repository selection (+ backend options)
restic_repo_args() {
	local -n _r=$1
	local -a opts=()
	case ${HV_BACKUP_TARGET:-local} in
	s3)
		_r=(-r "$HV_BACKUP_S3_REPO")
		read -r -a opts <<<"${HV_BACKUP_S3_OPTIONS:-}"
		_r+=("${opts[@]}")
		;;
	*) _r=(-r /repo) ;;
	esac
}

# restic_backup_paths OUT_ARRAY — container paths to back up (requires ST_* parsed)
restic_backup_paths() {
	local -n _p=$1
	local i
	_p=(/src/nextcloud-html/config /src/nextcloud-html/custom_apps /src/nextcloud-html/themes
		/src/nextcloud-data /src/caddy-data /src/dumps /src/project)
	if [[ ${HV_PLATFORM:-linux} == linux ]] && is_true "${HV_VPN_ENABLED:-true}"; then
		_p+=(/src/wg-easy)
	fi
	if [[ ${HV_PLATFORM:-linux} == windows && -n ${HV_WIN_WG_DIR:-} ]]; then
		_p+=(/src/windows-wireguard)
	fi
	for i in "${!ST_NAME[@]}"; do
		[[ ${ST_BACKUP[i]} == yes ]] && _p+=("/src/storage/${ST_SLUG[i]}")
	done
	return 0
}

# restic_backup_args OUT_ARRAY — full "backup …" argument list
restic_backup_args() {
	local -n _a=$1
	local -a paths
	restic_backup_paths paths
	_a=(backup "${paths[@]}" --host homevault --tag homevault
		--exclude '/src/nextcloud-data/appdata_*/preview'
		--exclude '/src/nextcloud-data/*.log'
		--exclude '/src/project/.git'
		--exclude '/src/project/restore'
		--exclude '/src/project/data')
}

restic_forget_args() {
	local -n _f=$1
	_f=(forget --host homevault --tag homevault --group-by 'host,tags'
		--keep-daily "${HV_BACKUP_KEEP_DAILY:-7}"
		--keep-weekly "${HV_BACKUP_KEEP_WEEKLY:-4}"
		--keep-monthly "${HV_BACKUP_KEEP_MONTHLY:-12}"
		--prune)
}

restic_exit_msg() {
	case $1 in
	0) echo "成功" ;;
	1) echo "失败（详见上方 restic 输出）" ;;
	2) echo "restic 内部错误（Go 运行时错误）" ;;
	3) echo "部分源文件无法读取，快照不完整" ;;
	10) echo "备份仓库不存在或尚未初始化（运行：hv backup --init）" ;;
	11) echo "无法锁定仓库：可能有另一个备份正在运行；确认没有后可运行 hv backup --unlock" ;;
	12) echo "仓库密码错误（secrets/restic_password 与仓库不匹配）" ;;
	130) echo "已取消" ;;
	*) echo "未知错误（退出码 $1）" ;;
	esac
}

# docker compose with the tools profile enabled (for the one-off backup container)
dc_tools() {
	local -a a
	hv_compose_args a
	docker compose "${a[@]}" --profile tools "$@"
}

# restic_run [--compose-file F] [-v host:ctr] -- restic args…
restic_run() {
	local -a pre=() files=() repo
	while (($#)); do
		case $1 in
		-v)
			pre+=(-v "$2")
			shift 2
			;;
		--compose-file)
			files+=(-f "$2")
			shift 2
			;;
		--)
			shift
			break
			;;
		*) break ;;
		esac
	done
	restic_repo_args repo
	if ((${#files[@]})); then
		local -a a
		hv_compose_args a
		# insert extra -f after the existing ones (before --project-directory)
		local -a b=() x inserted=0
		for x in "${a[@]}"; do
			if [[ $x == --project-directory && $inserted == 0 ]]; then
				b+=("${files[@]}")
				inserted=1
			fi
			b+=("$x")
		done
		docker compose "${b[@]}" --profile tools run --rm --no-deps -T "${pre[@]}" backup "${repo[@]}" "$@"
	else
		dc_tools run --rm --no-deps -T "${pre[@]}" backup "${repo[@]}" "$@"
	fi
}

backup_maint_off() {
	((_HV_MAINT_ON)) || return 0
	local i
	for i in 1 2 3; do
		if occ maintenance:mode --off >/dev/null 2>&1; then
			_HV_MAINT_ON=0
			info "已关闭维护模式"
			return 0
		fi
		sleep 3
	done
	err "无法关闭维护模式！请手动运行：$HV_SELF occ maintenance:mode --off"
	return 1
}

backup_dump_db() {
	local dir=${HV_DUMP_DIR:-} tmp
	[[ $dir == /* ]] || die "HV_DUMP_DIR 未设置或不是绝对路径（.env）"
	install -d -m 0700 "$dir"
	tmp="$dir/.nextcloud.sql.tmp"
	rm -f "$tmp"
	(umask 077 && : >"$tmp")
	if ! dc exec -T db pg_dump -U nextcloud -d nextcloud --no-password >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	if [[ ! -s $tmp ]] || ! grep -q 'PostgreSQL database dump complete' "$tmp"; then
		rm -f "$tmp"
		err "数据库导出不完整"
		return 1
	fi
	mv -f "$tmp" "$dir/nextcloud.sql"
	ok "数据库已导出：$dir/nextcloud.sql ($(human_bytes "$(stat -c %s "$dir/nextcloud.sql")"))"
}

# Write state/backup-status.json
backup_write_status() {
	local result=$1 code=$2 message=$3 started=$4 logrel=$5 last_ok='null' repo
	[[ -f $HV_STATE_DIR/last-backup-ok ]] && last_ok=$(json_str "$(cat "$HV_STATE_DIR/last-backup-ok")")
	if [[ ${HV_BACKUP_TARGET:-local} == s3 ]]; then repo=${HV_BACKUP_S3_REPO:-}; else repo=${HV_BACKUP_LOCAL_PATH:-}; fi
	mkdir -p "$HV_STATE_DIR"
	{
		printf '{"last_run":%s,"finished":%s,"result":%s,"exit_code":%d,"message":%s,' \
			"$(json_str "$started")" "$(json_str "$(date -Iseconds)")" "$(json_str "$result")" "$code" "$(json_str "$message")"
		printf '"last_ok":%s,"target":%s,"repository":%s,"log":%s,"schedule":%s}\n' \
			"$last_ok" "$(json_str "${HV_BACKUP_TARGET:-local}")" "$(json_str "$repo")" "$(json_str "$logrel")" \
			"$(json_str "${HV_BACKUP_TIME:-03:30}")"
	} >"$HV_STATE_DIR/backup-status.json.tmp"
	chmod 0644 "$HV_STATE_DIR/backup-status.json.tmp"
	mv -f "$HV_STATE_DIR/backup-status.json.tmp" "$HV_STATE_DIR/backup-status.json"
}

backup_write_snapshots() {
	local tmp=$HV_STATE_DIR/snapshots.json.tmp
	if restic_run -- snapshots --json --host homevault --tag homevault >"$tmp" 2>/dev/null && [[ -s $tmp ]]; then
		chmod 0644 "$tmp"
		mv -f "$tmp" "$HV_STATE_DIR/snapshots.json"
	else
		rm -f "$tmp"
	fi
}

# The actual backup (runs inside a subshell with its own EXIT trap)
backup_run() {
	local do_init=$1 do_check=$2 rc=0 started
	local -a args
	started=$(date -Iseconds)
	storage_parse_conf || die "storage.conf 有错误"
	mkdir -p "$HV_STATE_DIR"
	exec 9>"$HV_STATE_DIR/backup.lock"
	flock -n 9 || die "另一个备份任务正在运行"

	if [[ ${HV_BACKUP_TARGET:-local} == local ]]; then
		[[ -d $HV_BACKUP_LOCAL_PATH ]] || die "备份目录不存在：$HV_BACKUP_LOCAL_PATH（硬盘是否已挂载？）"
		if have mountpoint && [[ -n ${HV_BACKUP_REQUIRE_MOUNT:-} ]] && ! mountpoint -q "$HV_BACKUP_REQUIRE_MOUNT"; then
			die "备份硬盘未挂载：$HV_BACKUP_REQUIRE_MOUNT"
		fi
	fi

	info "检查备份仓库…"
	restic_run -- cat config >/dev/null 2>&1 || rc=$?
	if ((rc == 10)); then
		if ((do_init)); then
			info "初始化 restic 仓库…"
			restic_run -- init || die "仓库初始化失败"
			ok "仓库已初始化（请务必离线保存 secrets/restic_password，丢失将无法恢复任何备份）"
		else
			die "$(restic_exit_msg 10)"
		fi
	elif ((rc != 0)); then
		die "无法打开备份仓库：$(restic_exit_msg "$rc")"
	fi
	rc=0

	[[ $(dc_state db) == healthy || $(dc_state db) == running ]] || die "数据库容器未运行，无法导出（先运行 $HV_SELF up）"
	if [[ $(dc_state app) == healthy || $(dc_state app) == running ]]; then
		info "开启维护模式（仅在导出数据库期间）…"
		occ maintenance:mode --on >/dev/null || die "无法开启维护模式"
		_HV_MAINT_ON=1
	fi
	backup_dump_db || rc=$?
	backup_maint_off || rc=1
	((rc == 0)) || die "数据库导出失败，本次备份中止"

	info "运行 restic 备份…"
	restic_backup_args args
	restic_run -- "${args[@]}" || rc=$?
	if ((rc == 3)); then
		warn "restic：$(restic_exit_msg 3)"
	elif ((rc != 0)); then
		err "restic 备份失败：$(restic_exit_msg "$rc")"
		return "$rc"
	fi

	info "按保留策略清理旧快照（每日 ${HV_BACKUP_KEEP_DAILY:-7} / 每周 ${HV_BACKUP_KEEP_WEEKLY:-4} / 每月 ${HV_BACKUP_KEEP_MONTHLY:-12}）…"
	restic_forget_args args
	local frc=0
	restic_run -- "${args[@]}" || frc=$?
	((frc == 0)) || {
		err "清理旧快照失败：$(restic_exit_msg "$frc")"
		((rc == 0)) && rc=$frc
	}

	if ((do_check)) || [[ $(date +%u) == 7 ]]; then
		info "校验仓库（随机抽查 5% 数据）…"
		local crc=0
		restic_run -- check --read-data-subset=5% || crc=$?
		if ((crc == 0)); then
			ok "仓库校验通过"
		else
			err "仓库校验失败：$(restic_exit_msg "$crc")"
			((rc == 0)) && rc=$crc
		fi
	fi
	if ((rc == 0)); then
		date -Iseconds >"$HV_STATE_DIR/last-backup-ok"
		ok "备份完成（开始于 $started）"
	fi
	return "$rc"
}

cmd_backup() {
	local do_init=0 do_check=0 rc=0 logfile='' logrel='' started
	while (($#)); do
		case $1 in
		--init) do_init=1 ;;
		--check) do_check=1 ;;
		--unlock)
			hv_require_env
			restic_run -- unlock
			return
			;;
		--snapshots | --list)
			hv_require_env
			restic_run -- snapshots --host homevault --tag homevault
			return
			;;
		-h | --help)
			help_cmd backup
			return 0
			;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	hv_require_env
	require_root
	backup_configured || die "尚未配置备份目标（.env 中的 HV_BACKUP_LOCAL_PATH 或 HV_BACKUP_S3_REPO）"
	started=$(date -Iseconds)
	if [[ -n ${HV_LOG_DIR:-} ]]; then
		mkdir -p "$HV_LOG_DIR/backup"
		logrel="backup/backup-$(date +%Y%m%d-%H%M%S).log"
		logfile=$HV_LOG_DIR/$logrel
	else
		logfile=/dev/null
	fi
	set +e
	(
		set -e
		HV_TMP_PATHS=()
		HV_CLEANUP_FUNCS=()
		trap 'backup_maint_off; hv_run_cleanup' EXIT
		trap 'exit 130' INT TERM
		backup_run "$do_init" "$do_check"
	) 2>&1 | (
		trap '' INT TERM
		tee -a "$logfile"
	)
	rc=${PIPESTATUS[0]}
	set -e
	if ((rc == 0)); then
		backup_write_status ok 0 "备份成功" "$started" "$logrel"
	elif ((rc == 3)); then
		backup_write_status partial 3 "$(restic_exit_msg 3)" "$started" "$logrel"
	else
		backup_write_status failed "$rc" "$(restic_exit_msg "$rc")" "$started" "$logrel"
	fi
	backup_write_snapshots || true
	((rc == 0)) || err "备份未成功（退出码 $rc）。日志：${logfile}"
	return "$rc"
}

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------
systemd_available() { have systemctl && [[ -d /run/systemd/system ]]; }

# systemd_render TEMPLATE → content with @HV_ROOT@ / @HV_BACKUP_TIME@ substituted
systemd_render() {
	local content
	[[ $HV_ROOT =~ ^[A-Za-z0-9/._+-]+$ ]] || die "目录路径包含 systemd 不支持的字符（空格等）：$HV_ROOT，请把 HomeVault 放到简单路径下（如 /opt/homevault）"
	content=$(<"$1")
	content=${content//@HV_ROOT@/$HV_ROOT}
	content=${content//@HV_BACKUP_TIME@/${HV_BACKUP_TIME:-03:30}}
	printf '%s\n' "$content"
}

# systemd_install_unit NAME… — copy rendered units to /etc/systemd/system
systemd_install_units() {
	local u
	for u in "$@"; do
		[[ -f $HV_ROOT/systemd/$u ]] || die "缺少模板：systemd/$u"
		systemd_render "$HV_ROOT/systemd/$u" >"/etc/systemd/system/$u.tmp"
		chmod 0644 "/etc/systemd/system/$u.tmp"
		mv -f "/etc/systemd/system/$u.tmp" "/etc/systemd/system/$u"
	done
	systemctl daemon-reload
}

cmd_schedule_backup() {
	local t='' remove=0
	while (($#)); do
		case $1 in
		--time)
			t=${2:?}
			shift
			;;
		--remove | --disable) remove=1 ;;
		-h | --help)
			help_cmd schedule-backup
			return 0
			;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	hv_require_env
	require_root
	systemd_available || die "未检测到 systemd，无法安装定时任务（可改用 cron：每天执行 $HV_ROOT/hv backup）"
	if ((remove)); then
		systemctl disable --now homevault-backup.timer 2>/dev/null || true
		rm -f /etc/systemd/system/homevault-backup.timer /etc/systemd/system/homevault-backup.service
		systemctl daemon-reload
		ok "已移除定时备份"
		return 0
	fi
	backup_configured || die "尚未配置备份目标"
	if [[ -n $t ]]; then
		[[ $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "时间格式应为 HH:MM（24 小时制），例如 03:30"
		env_set HV_BACKUP_TIME "$t"
	fi
	systemd_install_units homevault-backup.service homevault-backup.timer
	systemctl enable --now homevault-backup.timer >/dev/null
	ok "已设置每日 ${HV_BACKUP_TIME} 自动备份（关机错过时开机后补做）"
	systemctl list-timers homevault-backup.timer --no-pager 2>/dev/null | head -n 3 || true
}
