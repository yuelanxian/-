# shellcheck shell=sh
# HomeVault — shared helpers for the Nextcloud entrypoint hooks (POSIX sh, sourced).
# Mounted read-only at /opt/homevault/hooks-lib; the entrypoint ignores this sub-directory.

HV_NC_ROOT=${HV_NC_ROOT:-/var/www/html}
HV_HOOKS_LIB=${HV_HOOKS_LIB:-/opt/homevault/hooks-lib}

hv_log() { printf '[homevault] %s\n' "$*"; }
hv_warn() { printf '[homevault] 警告: %s\n' "$*" >&2; }
hv_err() { printf '[homevault] 错误: %s\n' "$*" >&2; }

# Re-exec the calling script as www-data when started as root (e.g. `docker compose exec app <hook>`).
# Usage: hv_as_www_data "$0"
hv_as_www_data() {
	if [ "$(id -u)" = 0 ]; then
		exec su -p www-data -s /bin/sh -c "$1"
	fi
}

# Run occ non-interactively (hooks already run as www-data).
hv_occ() {
	php "$HV_NC_ROOT/occ" --no-interaction "$@"
}

hv_is_installed() {
	[ -f "$HV_NC_ROOT/config/config.php" ] &&
		grep -Eq "'installed'[[:space:]]*=>[[:space:]]*true" "$HV_NC_ROOT/config/config.php"
}

hv_in_maintenance() {
	grep -Eq "'maintenance'[[:space:]]*=>[[:space:]]*true" "$HV_NC_ROOT/config/config.php" 2>/dev/null
}

# true/yes/on/1 (case-insensitive) → success
hv_truthy() {
	case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
	1 | true | yes | on) return 0 ;;
	*) return 1 ;;
	esac
}

# Milliseconds since epoch (GNU date in the Debian-based image; falls back to seconds).
hv_now_ms() {
	_ms=$(date +%s%3N 2>/dev/null) || _ms=''
	case "$_ms" in
	'' | *N*) _ms=$(($(date +%s) * 1000)) ;;
	esac
	printf '%s' "$_ms"
}
