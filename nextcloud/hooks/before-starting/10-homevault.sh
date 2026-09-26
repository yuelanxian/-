#!/bin/sh
# HomeVault before-starting hook: idempotent hardening on EVERY start of the app container.
# Runs as www-data (entrypoint: su -p www-data -s /bin/sh -c <script>); also used by `hv harden`.
# Warm restart = one `occ config:list` + a pure-PHP diff (lib/plan.php); occ writes happen only
# for settings that drifted. Exit 1 (container does not start) only when security-critical
# settings cannot be applied; everything else is logged and skipped.
set -eu

# shellcheck source=nextcloud/hooks/lib/common.sh
. /opt/homevault/hooks-lib/common.sh
hv_as_www_data "$0"

t0=$(hv_now_ms)

if ! hv_is_installed; then
	hv_log "Nextcloud 尚未安装，跳过安全加固（自动安装完成后会执行）"
	exit 0
fi

maint=0
if hv_in_maintenance; then
	maint=1
	hv_warn "Nextcloud 处于维护模式：仍写入配置项，但跳过启用/停用应用"
fi

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/homevault-harden.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' INT TERM

# --private: sensitive values (e.g. trusted_proxies) are masked otherwise and would always "differ".
# The dump stays in a 0700 temp dir and is deleted right after planning.
if ! hv_occ config:list --private >"$work/current.json" 2>"$work/err"; then
	# Pending upgrade (e.g. an app update): only a few occ commands work. Do not block the start,
	# otherwise the admin could not even `docker compose exec app php occ upgrade`.
	if hv_occ status --output=json 2>/dev/null | grep -q '"needsDbUpgrade":true'; then
		hv_warn "Nextcloud 需要升级（needsDbUpgrade），本次跳过安全加固；请执行 ./hv occ upgrade 后重启"
		exit 0
	fi
	hv_err "occ config:list 失败，无法检查安全配置："
	cat "$work/err" >&2
	exit 1
fi
if ! php "$HV_HOOKS_LIB/plan.php" "$work/current.json" "$work/import.json" >"$work/plan" 2>"$work/err"; then
	rm -f "$work/current.json"
	hv_err "生成加固计划失败："
	cat "$work/err" >&2
	exit 1
fi
rm -f "$work/current.json"

rc=0
fails=0
steps=0
set -f # plan values are plain words; never glob them

while IFS= read -r line; do
	op=${line%% *}
	rest=${line#"$op"}
	rest=${rest# }
	case "$op" in
	INFO)
		hv_log "$rest"
		;;
	ENABLE)
		steps=$((steps + 1))
		if [ "$maint" = 1 ]; then
			hv_warn "维护模式下跳过启用应用：$rest"
			continue
		fi
		hv_log "启用应用：$rest"
		# shellcheck disable=SC2086 # the app list is split on purpose
		if ! hv_occ app:enable $rest >"$work/out" 2>&1; then
			fails=$((fails + 1))
			hv_warn "启用应用失败（$rest）："
			cat "$work/out" >&2
		fi
		;;
	SYS)
		steps=$((steps + 1))
		# shellcheck disable=SC2086
		set -- $rest
		hv_log "写入 ${1:-?} 项系统配置：${2:-}"
		if ! hv_occ config:import "$work/import.json" >"$work/out" 2>&1; then
			hv_err "occ config:import 失败："
			cat "$work/out" >&2
			rc=1
		fi
		;;
	APPSET)
		steps=$((steps + 1))
		# shellcheck disable=SC2086
		set -- $rest # critical app key value
		hv_log "设置 $2/$3 = $4"
		if ! hv_occ config:app:set "$2" "$3" --value="$4" >"$work/out" 2>&1; then
			cat "$work/out" >&2
			if [ "$1" = 1 ]; then
				hv_err "关键配置 $2/$3 设置失败"
				rc=1
			else
				fails=$((fails + 1))
				hv_warn "配置 $2/$3 设置失败（非关键，继续）"
			fi
		fi
		;;
	DISABLE)
		steps=$((steps + 1))
		if [ "$maint" = 1 ]; then
			hv_warn "维护模式下跳过停用应用：$rest"
			continue
		fi
		hv_log "停用不需要或会联网上报的应用：$rest"
		# shellcheck disable=SC2086 # the app list is split on purpose
		if ! hv_occ app:disable $rest >"$work/out" 2>&1; then
			fails=$((fails + 1))
			hv_warn "停用应用失败（$rest）："
			cat "$work/out" >&2
		fi
		;;
	ENFORCE2FA)
		steps=$((steps + 1))
		hv_log "对所有用户强制启用两步验证（twofactorauth:enforce --on）"
		if ! hv_occ twofactorauth:enforce --on >"$work/out" 2>&1; then
			hv_err "强制两步验证失败："
			cat "$work/out" >&2
			rc=1
		fi
		;;
	'') ;;
	*)
		hv_warn "未知的计划步骤：$line"
		;;
	esac
done <"$work/plan"

elapsed=$(($(hv_now_ms) - t0))

if [ "$rc" -ne 0 ] && hv_occ status --output=json 2>/dev/null | grep -q '"needsDbUpgrade":true'; then
	hv_warn "Nextcloud 需要升级（needsDbUpgrade），部分加固未完成；请执行 ./hv occ upgrade 后重启（耗时 ${elapsed} ms）"
	exit 0
fi
if [ "$rc" -ne 0 ]; then
	hv_err "安全加固未完成（耗时 ${elapsed} ms）。为避免在不安全的配置下运行，本次不启动 Nextcloud；请根据上面的错误处理后重启。"
	exit 1
fi
if [ "$steps" -eq 0 ]; then
	hv_log "安全加固检查完成：全部设置已符合要求（耗时 ${elapsed} ms）"
else
	hv_log "安全加固完成：执行 ${steps} 步，非关键失败 ${fails} 个（耗时 ${elapsed} ms）"
fi
exit 0
