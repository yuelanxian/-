#!/bin/sh
# HomeVault before-starting hook: idempotent hardening on EVERY start of the app container.
# Runs as www-data (entrypoint: su -p www-data -s /bin/sh -c <script>); also usable via `hv harden`.
# Warm restart = one `occ config:list` + a pure-PHP diff; occ writes happen only for drifted settings.
# Exit 1 (container does not start) only when security-critical settings cannot be applied.
set -eu

# shellcheck source=nextcloud/hooks/lib/common.sh
. /opt/homevault/hooks-lib/common.sh
hv_as_www_data "$0"

t0=$(hv_now_ms)

if ! hv_is_installed; then
	hv_log "Nextcloud 尚未安装，跳过加固（首次自动安装完成后会自动执行）"
	exit 0
fi

maint=0
if hv_in_maintenance; then
	maint=1
	hv_warn "Nextcloud 处于维护模式：仍应用配置项，但跳过启用/停用应用"
fi

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/homevault-harden.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

if ! hv_occ config:list --private >"$work/current.json" 2>"$work/err"; then
	hv_err "occ config:list 失败，无法检查安全配置："
	cat "$work/err" >&2
	exit 1
fi

if ! php "$HV_HOOKS_LIB/plan.php" "$work/current.json" "$work/import.json" >"$work/plan" 2>"$work/err"; then
	hv_err "生成加固计划失败："
	cat "$work/err" >&2
	exit 1
fi
rm -f "$work/current.json"

rc=0
fails=0
steps=0

while read -r op a b c d; do
	case "$op" in
	INFO)
		hv_log "$a${b:+ $b}${c:+ $c}${d:+ $d}"
		;;
	ENABLE)
		steps=$((steps + 1))
		if [ "$maint" = 1 ]; then
			hv_warn "维护模式下跳过启用应用：$a $b $c $d"
			continue
		fi
		apps="$a${b:+ $b}${c:+ $c}${d:+ $d}"
		hv_log "启用应用：$apps"
		# shellcheck disable=SC2086 # word splitting of the app list is intended
		if ! hv_occ app:enable $apps >"$work/out" 2>&1; then
			fails=$((fails + 1))
			hv_warn "启用应用失败（$apps）："
			cat "$work/out" >&2
		fi
		;;
	SYS)
		steps=$((steps + 1))
		hv_log "写入 $a 项系统配置：$b"
		if ! hv_occ config:import "$work/import.json" >"$work/out" 2>&1; then
			hv_err "occ config:import 失败："
			cat "$work/out" >&2
			rc=1
		fi
		;;
	APPSET)
		# a=critical b=app c=key d=value
		steps=$((steps + 1))
		hv_log "设置 $b/$c = $d"
		if ! hv_occ config:app:set "$b" "$c" --value="$d" >"$work/out" 2>&1; then
			cat "$work/out" >&2
			if [ "$a" = 1 ]; then
				hv_err "关键配置 $b/$c 设置失败"
				rc=1
			else
				fails=$((fails + 1))
				hv_warn "配置 $b/$c 设置失败（非关键，继续）"
			fi
		fi
		;;
	DISABLE)
		steps=$((steps + 1))
		if [ "$maint" = 1 ]; then
			hv_warn "维护模式下跳过停用应用：$a $b $c $d"
			continue
		fi
		# read put the tail of the list into $d; rebuild it from the plan line instead
		apps=$(sed -n 's/^DISABLE //p' "$work/plan")
		hv_log "停用不需要/会联网上报的应用：$apps"
		# shellcheck disable=SC2086 # word splitting of the app list is intended
		if ! hv_occ app:disable $apps >"$work/out" 2>&1; then
			fails=$((fails + 1))
			hv_warn "停用应用失败（$apps）："
			cat "$work/out" >&2
		fi
		;;
	ENFORCE2FA)
		steps=$((steps + 1))
		hv_log "对所有用户强制启用两步验证"
		if ! hv_occ twofactorauth:enforce --on >"$work/out" 2>&1; then
			hv_err "强制两步验证失败："
			cat "$work/out" >&2
			rc=1
		fi
		;;
	'') ;;
	*)
		hv_warn "未知计划步骤：$op"
		;;
	esac
done <"$work/plan"

t1=$(hv_now_ms)
elapsed=$((t1 - t0))

if [ "$rc" -ne 0 ]; then
	hv_err "安全加固未完成（耗时 ${elapsed} ms）。为避免在不安全配置下运行，容器将停止启动；请检查上面的错误。"
	exit 1
fi
if [ "$steps" -eq 0 ]; then
	hv_log "安全加固检查完成：所有设置均已符合（耗时 ${elapsed} ms）"
else
	hv_log "安全加固完成：执行 $steps 步，非关键失败 $fails 个（耗时 ${elapsed} ms）"
fi
exit 0
