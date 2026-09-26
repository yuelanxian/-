# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# .env handling: read / write single keys preserving comments and order; derived variables.

HV_ENV_FILE=${HV_ENV_FILE:-$HV_ROOT/.env}

# Parse the raw value part of a dotenv line (after "KEY=").
env_unquote() {
	local v=$1
	v=${v#"${v%%[![:space:]]*}"}
	if [[ $v == \'* ]]; then
		v=${v#\'}
		v=${v%%\'*}
	elif [[ $v == \"* ]]; then
		v=${v#\"}
		# strip up to the closing unescaped quote
		local out='' i c
		for ((i = 0; i < ${#v}; i++)); do
			c=${v:i:1}
			if [[ $c == \\ && $((i + 1)) -lt ${#v} ]]; then
				i=$((i + 1))
				c=${v:i:1}
				case $c in
				n) out+=$'\n' ;;
				t) out+=$'\t' ;;
				*) out+=$c ;;
				esac
			elif [[ $c == \" ]]; then
				break
			else
				out+=$c
			fi
		done
		v=$out
	else
		# unquoted: strip inline comment (" #") and trailing spaces
		if [[ $v == \#* ]]; then
			v=''
		elif [[ $v == *[[:space:]]#* ]]; then
			v=${v%%[[:space:]]#*}
		fi
		v=${v%"${v##*[![:space:]]}"}
	fi
	printf '%s' "$v"
}

# Format a value for .env (compose dotenv): bare when safe, else single/double quoted.
env_quote() {
	local v=$1
	if [[ $v =~ ^[A-Za-z0-9_./:,@%+=-]*$ ]]; then
		printf '%s' "$v"
	elif [[ $v != *\'* && $v != *$'\n'* ]]; then
		printf "'%s'" "$v"
	else
		[[ $v == *\$* || $v == *$'\n'* ]] && die "值中不能同时包含单引号和 \$ 或换行：$1"
		v=${v//\\/\\\\}
		v=${v//\"/\\\"}
		printf '"%s"' "$v"
	fi
}

# env_get_file KEY FILE → value (status 1 when the key is absent)
env_get_file() {
	local key=$1 file=$2 line found=1 val=''
	[[ -f $file ]] || return 1
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		[[ $line =~ ^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=(.*)$ ]] || continue
		val=$(env_unquote "${BASH_REMATCH[2]}")
		found=0
	done <"$file"
	printf '%s' "$val"
	return $found
}

# env_set_file KEY VALUE FILE — replace the (last) KEY= line in place, or append.
env_set_file() {
	local key=$1 value=$2 file=$3 tmp line quoted replaced=0 last=-1 n=0
	[[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "非法的变量名：$key"
	quoted=$(env_quote "$value")
	[[ -f $file ]] || { (umask 077 && : >"$file"); }
	# locate the last matching line
	while IFS= read -r line || [[ -n $line ]]; do
		[[ ${line%$'\r'} =~ ^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*= ]] && last=$n
		n=$((n + 1))
	done <"$file"
	tmp=$(umask 077 && mktemp "$(dirname "$file")/.env.XXXXXX")
	n=0
	while IFS= read -r line || [[ -n $line ]]; do
		if ((n == last)); then
			printf '%s=%s\n' "$key" "$quoted"
			replaced=1
		else
			printf '%s\n' "$line"
		fi
		n=$((n + 1))
	done <"$file" >"$tmp"
	((replaced)) || printf '%s=%s\n' "$key" "$quoted" >>"$tmp"
	chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
	mv -f "$tmp" "$file"
}

env_get() { env_get_file "$1" "$HV_ENV_FILE"; }

# env_set KEY VALUE — writes .env and updates the in-memory variable.
env_set() {
	env_set_file "$1" "$2" "$HV_ENV_FILE"
	printf -v "$1" '%s' "$2"
}

# Load every KEY=VALUE of a file into (non-exported) shell variables.
env_load() {
	local file=${1:-$HV_ENV_FILE} line key
	[[ -f $file ]] || return 1
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		[[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
		key=${BASH_REMATCH[2]}
		# never clobber internal lowercase/underscore state; only UPPER_CASE config keys
		printf -v "$key" '%s' "$(env_unquote "${BASH_REMATCH[3]}")"
	done <"$file"
}

# Defaults for keys that may be missing from an older .env (never overrides loaded values).
env_defaults() {
	: "${COMPOSE_PROJECT_NAME:=homevault}"
	: "${HV_PLATFORM:=linux}"
	: "${HV_HTTP_PORT:=80}" "${HV_HTTPS_PORT:=443}" "${HV_ADMIN_PORT:=8443}" "${HV_PANEL_PORT:=9443}"
	: "${HV_ALLOWED_CIDRS:=private_ranges 100.64.0.0/10}"
	: "${HV_FRONTEND_SUBNET:=172.31.250.0/24}"
	: "${HV_CADDY_IP:=}" "${HV_PANEL_IP:=}" "${HV_FRONTEND_IP_RANGE:=}"
	: "${HV_TZ:=Asia/Shanghai}"
	: "${HV_TLS_MODE:=internal}" "${HV_DNS_PROVIDER:=alidns}"
	: "${HV_ADMIN_USER:=hvadmin}"
	: "${HV_VPN_ENABLED:=true}" "${HV_VPN_CIDR:=10.99.77.0/24}" "${HV_VPN_LAN_ACCESS:=host}"
	: "${HV_VPN_DNS:=223.5.5.5,119.29.29.29}" "${HV_VPN_KEEPALIVE:=0}"
	: "${HV_DDNS_ENABLED:=false}" "${HV_MONITOR_ENABLED:=false}"
	: "${HV_BACKUP_TARGET:=local}" "${HV_BACKUP_TIME:=03:30}"
	: "${HV_BACKUP_KEEP_DAILY:=7}" "${HV_BACKUP_KEEP_WEEKLY:=4}" "${HV_BACKUP_KEEP_MONTHLY:=12}"
	: "${HV_LOG_RETENTION_DAYS:=7}"
	: "${HV_EXTRA_HOSTS:=}" "${HV_HOST:=}" "${HV_LAN_IP:=}" "${HV_LAN_CIDR:=}" "${HV_BIND_IP:=}"
	: "${HV_DATA_DIR:=}" "${HV_NC_DATA_PATH:=}" "${HV_DUMP_DIR:=}" "${HV_LOG_DIR:=}"
	: "${HV_BACKUP_LOCAL_PATH:=}" "${HV_BACKUP_S3_REPO:=}" "${HV_BACKUP_S3_OPTIONS:=}"
	: "${WG_HOST:=}" "${WG_PORT:=}" "${HV_DDNS_PROVIDER:=}" "${HV_DDNS_DOMAIN:=}" "${HV_ACME_EMAIL:=}"
	: "${HV_VOL_HTML:=}" "${HV_VOL_DB:=}" "${HV_VOL_REDIS:=}" "${HV_VOL_CADDY_DATA:=}" "${HV_VOL_CADDY_CONFIG:=}" "${HV_VOL_WGEASY:=}"
	: "${HV_ALLOW_PUBLIC_LINKS:=false}"
	: "${NEXTCLOUD_IMAGE:=docker.io/library/nextcloud:34-apache}"
	: "${RESTIC_IMAGE:=docker.io/restic/restic:0.19.1}"
	: "${PANEL_IMAGE:=homevault/panel:1.0.0}" "${HV_MIRROR_HUB:=}" "${HV_MIRROR_GHCR:=}"
	: "${HV_ANDROID_RELEASE_REPO:=}"
}

# ---------------------------------------------------------------------------
# Derived variables (SPEC §5): pure — computed from the loaded globals.
# ---------------------------------------------------------------------------
# List canonical hosts (HV_HOST + extras [+ Windows VPN server IP]) de-duplicated.
hv_canonical_hosts() {
	local -A seen=()
	local h
	for h in $HV_HOST $HV_EXTRA_HOSTS; do
		[[ -n $h && -z ${seen[$h]:-} ]] || continue
		seen[$h]=1
		printf '%s\n' "$h"
	done
	if [[ $HV_PLATFORM == windows && -n ${HV_VPN_CIDR:-} ]] && is_ipv4_cidr "$HV_VPN_CIDR"; then
		h=$(cidr_first_host "$HV_VPN_CIDR")
		[[ -z ${seen[$h]:-} ]] && printf '%s\n' "$h"
	fi
	return 0
}

# Fixed frontend addresses (only Caddy and the panel are trusted proxies): Caddy = network + 2,
# panel = network + 3; dynamic addresses come from the upper half of the subnet (ip_range), so a
# recreated container can never take a fixed address. Leaves the values unchanged for an invalid subnet.
hv_compute_frontend() {
	local net len base sub=${HV_FRONTEND_SUBNET:-172.31.250.0/24}
	is_ipv4_cidr "$sub" || return 0
	net=$(cidr_network "$sub")
	len=$((10#${net#*/}))
	((len >= 1 && len <= 29)) || return 0
	base=$(ip_to_int "${net%/*}")
	HV_CADDY_IP=$(int_to_ip $((base + 2)))
	HV_PANEL_IP=$(int_to_ip $((base + 3)))
	HV_FRONTEND_IP_RANGE="$(int_to_ip $((base + (1 << (31 - len)))))/$((len + 1))"
}

hv_compute_derived() {
	local h port=$HV_HTTPS_PORT sites='' trusted=''
	hv_compute_frontend
	while IFS= read -r h; do
		[[ -n $h ]] || continue
		sites+="${sites:+, }https://$h:$port"
		trusted+="${trusted:+ }$h"
		[[ $port != 443 ]] && trusted+=" $h:$port"
	done < <(hv_canonical_hosts)
	HV_SITE_ADDRESSES=$sites
	HV_TRUSTED_DOMAINS=$trusted
	if [[ $port == 443 ]]; then
		HV_OVERWRITE_CLI_URL="https://$HV_HOST"
	else
		HV_OVERWRITE_CLI_URL="https://$HV_HOST:$port"
	fi
	if [[ $HV_TLS_MODE == acme-dns ]]; then
		HV_TLS_SNIPPET="acme-$HV_DNS_PROVIDER"
	else
		HV_TLS_SNIPPET=internal
	fi
	if [[ $HV_PLATFORM == linux ]] && is_true "$HV_VPN_ENABLED"; then
		HV_ADMIN_SNIPPET=wgeasy
	else
		HV_ADMIN_SNIPPET=none
	fi
}

# Management panel URL (served by Caddy on HV_PANEL_PORT for HV_HOST only)
hv_panel_url() { printf 'https://%s:%s\n' "$HV_HOST" "${HV_PANEL_PORT:-9443}"; }

# Keys introduced after the first release: write them into an older .env so that compose
# (which requires HV_LOG_DIR) and the panel get consistent values. Never changes existing values.
hv_ensure_env_keys() {
	local k
	[[ -f $HV_ENV_FILE ]] || return 0
	if [[ -z ${HV_LOG_DIR:-} && ${HV_DATA_DIR:-} == /* ]]; then
		env_set HV_LOG_DIR "$HV_DATA_DIR/logs"
	fi
	for k in HV_PANEL_PORT HV_LOG_RETENTION_DAYS; do
		env_get "$k" >/dev/null || env_set "$k" "${!k}"
	done
}

hv_write_derived() {
	hv_compute_derived
	local k
	for k in HV_SITE_ADDRESSES HV_TRUSTED_DOMAINS HV_OVERWRITE_CLI_URL HV_TLS_SNIPPET HV_ADMIN_SNIPPET \
		HV_CADDY_IP HV_PANEL_IP HV_FRONTEND_IP_RANGE; do
		if [[ $(env_get "$k" || true) != "${!k}" ]]; then
			env_set "$k" "${!k}"
		fi
	done
}

# hv_normalize_host "https://NAS.Example.com:443/x" → nas.example.com (users often paste a URL; IPv6 unsupported)
hv_normalize_host() {
	local h
	h=$(trim "$1")
	h=${h#*://}
	h=${h%%/*}
	h=${h%%:*}
	printf '%s\n' "${h,,}"
}

# IPv4 or DNS name (these values end up in Caddy site addresses and Nextcloud trusted_domains)
valid_host() {
	is_ipv4 "$1" && return 0
	[[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] &&
		! [[ $1 =~ ^[0-9.]+$ ]]
}

valid_email() { [[ $1 =~ ^[^@[:space:]\"\'{}]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

# Validation of the fields the CLI relies on (returns non-zero with messages).
hv_validate_env() {
	local rc=0 p h
	[[ -n $HV_HOST ]] || {
		err "HV_HOST 未设置"
		rc=1
	}
	if [[ -n $HV_HOST ]] && ! valid_host "$HV_HOST"; then
		err "HV_HOST 格式不正确：$HV_HOST（只填 IP 或域名，不要带 https:// 或端口）"
		rc=1
	fi
	for h in ${HV_EXTRA_HOSTS:-}; do
		valid_host "$h" || {
			err "HV_EXTRA_HOSTS 中的地址格式不正确：$h（只填 IP 或域名，空格分隔）"
			rc=1
		}
	done
	# empty = compose default (env_defaults fills it in anyway)
	local sub=${HV_FRONTEND_SUBNET:-172.31.250.0/24}
	if ! is_ipv4_cidr "$sub"; then
		err "HV_FRONTEND_SUBNET 不是有效的 IPv4 网段：$sub（例如 172.31.250.0/24）"
		rc=1
	elif ((10#${sub#*/} < 16 || 10#${sub#*/} > 28)); then
		err "HV_FRONTEND_SUBNET 的前缀长度必须在 16–28 之间：$sub（例如 172.31.250.0/24）"
		rc=1
	elif [[ $(cidr_network "$sub") != "$sub" ]]; then
		err "HV_FRONTEND_SUBNET 必须写网段地址：$sub（应为 $(cidr_network "$sub")）"
		rc=1
	fi
	if [[ -n ${HV_BIND_IP:-} ]] && ! is_ipv4 "$HV_BIND_IP"; then
		err "HV_BIND_IP 必须是 IPv4 地址：$HV_BIND_IP（不要留空或写 IPv6，否则可能暴露到公网 IPv6）"
		rc=1
	fi
	if [[ ${HV_PLATFORM:-linux} == linux ]] && is_true "${HV_VPN_ENABLED:-false}" && [[ -n ${WG_HOST:-} ]] && ! valid_host "$WG_HOST"; then
		err "WG_HOST 格式不正确：$WG_HOST（只填 DDNS 域名或公网 IP，不要带端口）"
		rc=1
	fi
	local -A used=()
	for p in HV_HTTP_PORT HV_HTTPS_PORT HV_ADMIN_PORT HV_PANEL_PORT; do
		if ! [[ ${!p} =~ ^[0-9]+$ ]] || ((${!p} < 1 || ${!p} > 65535)); then
			err "$p 不是有效端口：${!p}"
			rc=1
		elif [[ -n ${used[${!p}]:-} ]]; then
			err "$p 与 ${used[${!p}]} 使用了同一个端口 ${!p}（HTTP/HTTPS/VPN 管理/管理面板端口必须互不相同）"
			rc=1
		else
			used[${!p}]=$p
		fi
	done
	if ! [[ ${HV_LOG_RETENTION_DAYS:-7} =~ ^[0-9]+$ ]] || ((10#${HV_LOG_RETENTION_DAYS:-7} < 1 || 10#${HV_LOG_RETENTION_DAYS:-7} > 365)); then
		err "HV_LOG_RETENTION_DAYS 必须是 1–365 之间的整数：${HV_LOG_RETENTION_DAYS}"
		rc=1
	fi
	[[ $HV_TLS_MODE == internal || $HV_TLS_MODE == acme-dns ]] || {
		err "HV_TLS_MODE 只能是 internal 或 acme-dns"
		rc=1
	}
	if [[ $HV_TLS_MODE == acme-dns ]]; then
		[[ $HV_DNS_PROVIDER =~ ^(alidns|tencentcloud|cloudflare)$ ]] || {
			err "HV_DNS_PROVIDER 只能是 alidns / tencentcloud / cloudflare"
			rc=1
		}
		is_ipv4 "$HV_HOST" && {
			err "域名模式（acme-dns）下 HV_HOST 必须是域名，而不是 IP"
			rc=1
		}
		if [[ -n ${HV_ACME_EMAIL:-} ]] && ! valid_email "$HV_ACME_EMAIL"; then
			err "HV_ACME_EMAIL 不是有效的邮箱地址：$HV_ACME_EMAIL（可以留空）"
			rc=1
		fi
	fi
	return $rc
}
