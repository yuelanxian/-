#!/usr/bin/env bash
# Generate a throwaway HomeVault environment (.env + secrets/ + data dirs) for tests.
# The .env is derived from .env.example (every key set here must exist there) and the derived
# variables are computed the same way the CLIs do (simplified).
#
# Usage: tests/lib/make-test-env.sh <target-dir> [options]
#   --platform linux|windows    default linux
#   --host H                    HV_HOST (IP or domain), default 127.0.0.1
#   --lan-ip IP                 HV_LAN_IP, default: --host if it is an IPv4, else 127.0.0.1
#   --bind-ip IP                HV_BIND_IP, default 127.0.0.1
#   --http-port N               default 18080
#   --https-port N              default 18443
#   --admin-port N              default 18444
#   --panel-port N              HV_PANEL_PORT, default 18445
#   --log-days N                HV_LOG_RETENTION_DAYS, default 7
#   --data-dir DIR              default <target>/data (created; nextcloud-data gets 33:33 0750;
#                               logs/ = HV_LOG_DIR like "hv logs" creates it: nextcloud 33:33, panel 65532)
#   --tls-mode M                internal | acme-alidns | acme-tencentcloud | acme-cloudflare (default internal)
#   --project NAME              COMPOSE_PROJECT_NAME, default hvtest
#   --subnet CIDR               HV_FRONTEND_SUBNET, default 172.31.250.0/24 (HV_CADDY_IP / HV_PANEL_IP /
#                               HV_FRONTEND_IP_RANGE derived from it)
#   --allowed-cidrs STR         HV_ALLOWED_CIDRS, default from .env.example
#   --vpn                       HV_VPN_ENABLED=true + HV_ADMIN_SNIPPET=wgeasy (Linux only; default: VPN off)
#   --no-chown                  do not chown nextcloud-data / logs (static checks only)
#   --copy-repo                 also copy compose*.yaml, caddy/, nextcloud/ and panel/ into <target>
#                               (then run: docker compose --project-directory <target> -f <target>/compose.yaml --env-file <target>/.env …)
#   --repo DIR                  repository root (default: two levels above this script)
set -euo pipefail

die() {
	printf 'make-test-env: %s\n' "$*" >&2
	exit 1
}

[[ $# -ge 1 ]] || die "usage: $0 <target-dir> [options]"
target=$1
shift

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
platform=linux
host=127.0.0.1
lan_ip=''
bind_ip=127.0.0.1
http_port=18080
https_port=18443
admin_port=18444
panel_port=18445
log_days=7
data_dir=''
tls_mode=internal
project=hvtest
subnet=172.31.250.0/24
allowed=''
vpn=0
copy_repo=0
do_chown=1

while [[ $# -gt 0 ]]; do
	case "$1" in
	--platform) platform=$2; shift 2 ;;
	--host) host=$2; shift 2 ;;
	--lan-ip) lan_ip=$2; shift 2 ;;
	--bind-ip) bind_ip=$2; shift 2 ;;
	--http-port) http_port=$2; shift 2 ;;
	--https-port) https_port=$2; shift 2 ;;
	--admin-port) admin_port=$2; shift 2 ;;
	--panel-port) panel_port=$2; shift 2 ;;
	--log-days) log_days=$2; shift 2 ;;
	--data-dir) data_dir=$2; shift 2 ;;
	--tls-mode) tls_mode=$2; shift 2 ;;
	--project) project=$2; shift 2 ;;
	--subnet) subnet=$2; shift 2 ;;
	--allowed-cidrs) allowed=$2; shift 2 ;;
	--vpn) vpn=1; shift ;;
	--copy-repo) copy_repo=1; shift ;;
	--no-chown) do_chown=0; shift ;;
	--repo) repo=$2; shift 2 ;;
	*) die "unknown option: $1" ;;
	esac
done

is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

case "$platform" in linux | windows) ;; *) die "--platform must be linux or windows" ;; esac
case "$tls_mode" in
internal) tls_snippet=internal hv_tls_mode=internal dns_provider=alidns ;;
acme-alidns | acme-tencentcloud | acme-cloudflare)
	tls_snippet=$tls_mode hv_tls_mode=acme-dns dns_provider=${tls_mode#acme-} ;;
*) die "--tls-mode must be internal|acme-alidns|acme-tencentcloud|acme-cloudflare" ;;
esac
[[ -f $repo/.env.example ]] || die "no .env.example in $repo"
if [[ -z $lan_ip ]]; then
	if is_ipv4 "$host"; then lan_ip=$host; else lan_ip=127.0.0.1; fi
fi

mkdir -p "$target"
target=$(cd "$target" && pwd)
[[ -n $data_dir ]] || data_dir=$target/data

# ---------------------------------------------------------------- derived values
vpn_cidr=10.99.77.0/24
vpn_server_ip=${vpn_cidr%.*}.1
hosts=("$host")
if [[ $platform == windows ]]; then
	hosts+=("$vpn_server_ip") # Windows: tunnel IP as fallback address
fi
sites=()
trusted=()
for h in "${hosts[@]}"; do
	sites+=("https://$h:$https_port")
	trusted+=("$h")
	[[ $https_port == 443 ]] || trusted+=("$h:$https_port")
done
site_addresses=$(printf '%s, ' "${sites[@]}")
site_addresses=${site_addresses%, }
cli_url="https://$host"
[[ $https_port == 443 ]] || cli_url+=":$https_port"
# fixed frontend addresses (same rule as the CLIs): Caddy = network+2, panel = network+3, ip_range = upper half
ip2int() {
	local IFS=. a b c d
	read -r a b c d <<<"$1"
	echo $(((a << 24) | (b << 16) | (c << 8) | d))
}
int2ip() { echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"; }
sub_len=${subnet#*/}
sub_base=$(($(ip2int "${subnet%/*}") & ((0xFFFFFFFF << (32 - sub_len)) & 0xFFFFFFFF)))
caddy_ip=$(int2ip $((sub_base + 2)))
panel_ip=$(int2ip $((sub_base + 3)))
ip_range="$(int2ip $((sub_base + (1 << (31 - sub_len)))))/$((sub_len + 1))"
admin_snippet=none
vpn_enabled=false
if [[ $vpn == 1 && $platform == linux ]]; then
	admin_snippet=wgeasy
	vpn_enabled=true
fi

# ---------------------------------------------------------------- .env
env_file=$target/.env
cp "$repo/.env.example" "$env_file"

set_kv() {
	local key=$1 val=$2 tmp
	if ! grep -q "^${key}=" "$env_file"; then
		die ".env.example has no line for $key"
	fi
	if [[ $val == *[[:space:]]* ]]; then
		[[ $val != *"'"* ]] || die "value for $key contains a single quote"
		val="'$val'"
	fi
	tmp=$(mktemp)
	KV_KEY=$key KV_VAL=$val awk 'BEGIN { k = ENVIRON["KV_KEY"]; v = ENVIRON["KV_VAL"] }
		index($0, k "=") == 1 { print k "=" v; next } { print }' "$env_file" >"$tmp"
	cat "$tmp" >"$env_file"
	rm -f "$tmp"
}

set_kv COMPOSE_PROJECT_NAME "$project"
set_kv HV_PLATFORM "$platform"
set_kv HV_HOST "$host"
set_kv HV_LAN_IP "$lan_ip"
set_kv HV_LAN_CIDR "${lan_ip%.*}.0/24"
set_kv HV_BIND_IP "$bind_ip"
set_kv HV_HTTP_PORT "$http_port"
set_kv HV_HTTPS_PORT "$https_port"
set_kv HV_ADMIN_PORT "$admin_port"
set_kv HV_PANEL_PORT "$panel_port"
[[ -z $allowed ]] || set_kv HV_ALLOWED_CIDRS "$allowed"
set_kv HV_FRONTEND_SUBNET "$subnet"
set_kv HV_CADDY_IP "$caddy_ip"
set_kv HV_PANEL_IP "$panel_ip"
set_kv HV_FRONTEND_IP_RANGE "$ip_range"
set_kv HV_SITE_ADDRESSES "$site_addresses"
set_kv HV_TRUSTED_DOMAINS "${trusted[*]}"
set_kv HV_OVERWRITE_CLI_URL "$cli_url"
set_kv HV_TLS_SNIPPET "$tls_snippet"
set_kv HV_ADMIN_SNIPPET "$admin_snippet"
set_kv HV_TLS_MODE "$hv_tls_mode"
set_kv HV_DNS_PROVIDER "$dns_provider"
[[ $hv_tls_mode == internal ]] || set_kv HV_ACME_EMAIL "hv-test@homevault.test"
set_kv HV_DATA_DIR "$data_dir"
set_kv HV_NC_DATA_PATH "$data_dir/nextcloud-data"
set_kv HV_DUMP_DIR "$data_dir/dumps"
set_kv HV_LOG_DIR "$data_dir/logs"
set_kv HV_LOG_RETENTION_DAYS "$log_days"
set_kv HV_VPN_ENABLED "$vpn_enabled"
set_kv HV_MONITOR_ENABLED false
set_kv HV_BACKUP_LOCAL_PATH "$data_dir/backup-repo"
set_kv HV_VPN_CIDR "$vpn_cidr"
set_kv WG_HOST "vpn.homevault.test"
[[ $platform == windows ]] && set_kv HV_WIN_WG_DIR "$data_dir/windows-wireguard"

# ---------------------------------------------------------------- secrets/
rand32() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true; }
mkdir -p "$target/secrets"
chmod 0700 "$target/secrets"
for s in postgres_password redis_password nextcloud_admin_password restic_password; do
	[[ -s $target/secrets/$s ]] || rand32 >"$target/secrets/$s"
	chmod 0644 "$target/secrets/$s"
done
# DNS provider credentials: one file per value in secrets/caddy-dns/ (mounted by compose.acme.yaml)
dns_file() {
	mkdir -p "$target/secrets/caddy-dns"
	chmod 0755 "$target/secrets/caddy-dns"
	printf '%s\n' "$2" >"$target/secrets/caddy-dns/$1"
	chmod 0644 "$target/secrets/caddy-dns/$1"
}
case "$tls_mode" in
acme-alidns) dns_file ALIYUN_ACCESS_KEY_ID dummy-id && dns_file ALIYUN_ACCESS_KEY_SECRET dummy-secret ;;
acme-tencentcloud) dns_file TENCENTCLOUD_SECRET_ID dummy-id && dns_file TENCENTCLOUD_SECRET_KEY dummy-key ;;
acme-cloudflare) dns_file CF_API_TOKEN dummy-cloudflare-token-0123456789abcdef ;;
esac

# ---------------------------------------------------------------- data dirs
mkdir -p "$data_dir/nextcloud-data" "$data_dir/dumps" "$data_dir/backup-repo"
[[ $platform != windows ]] || mkdir -p "$data_dir/windows-wireguard"
chmod 0750 "$data_dir/nextcloud-data"
if [[ $do_chown == 1 ]] && ! chown 33:33 "$data_dir/nextcloud-data" 2>/dev/null; then
	sudo -n chown 33:33 "$data_dir/nextcloud-data" 2>/dev/null ||
		printf 'make-test-env: warning: could not chown %s to 33:33\n' "$data_dir/nextcloud-data" >&2
fi

# logs (SPEC §14) — same layout/ownership as "hv logs" creates on Linux
logs=$data_dir/logs
mkdir -p "$logs"/{homevault,backup,containers,caddy,nextcloud,panel}
chmod 0755 "$logs" "$logs"/{homevault,backup,containers,caddy}
chmod 0750 "$logs/nextcloud" "$logs/panel"
if [[ $do_chown == 1 ]]; then
	for pair in nextcloud:33 panel:65532; do
		d=$logs/${pair%%:*} id=${pair#*:}
		chown "$id:$id" "$d" 2>/dev/null || sudo -n chown "$id:$id" "$d" 2>/dev/null ||
			printf 'make-test-env: warning: could not chown %s to %s\n' "$d" "$id" >&2
	done
	# the panel (uid 65532) reads every log read-only
	if command -v setfacl >/dev/null 2>&1 && setfacl -R -m u:65532:rX -m d:u:65532:rX "$logs" 2>/dev/null; then
		:
	else
		chmod 0755 "$logs/nextcloud"
	fi
fi

# state/ (panel request files) — relative to the compose project directory (= <target> with --copy-repo)
mkdir -p "$target/state/requests/done"
chmod 0755 "$target/state"
if [[ $do_chown == 1 ]]; then
	chown 65532:65532 "$target/state/requests" 2>/dev/null ||
		sudo -n chown 65532:65532 "$target/state/requests" 2>/dev/null || chmod 1777 "$target/state/requests"
fi

# ---------------------------------------------------------------- optional repo copy
if [[ $copy_repo == 1 ]]; then
	for f in compose.yaml compose.acme.yaml; do
		cp "$repo/$f" "$target/$f"
	done
	rm -rf "$target/caddy" "$target/nextcloud" "$target/panel"
	cp -a "$repo/caddy" "$target/caddy"
	cp -a "$repo/nextcloud" "$target/nextcloud"
	# build context of the panel image (docker compose build panel)
	[[ ! -d $repo/panel ]] || cp -a "$repo/panel" "$target/panel"
fi

printf '%s\n' "$env_file"
