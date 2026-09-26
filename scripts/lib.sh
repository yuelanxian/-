# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# HomeVault Linux CLI — common helpers (sourced by ./hv; never executed directly).
# Conventions: user-facing text is Simplified Chinese; functions prefixed per module.

# ---------------------------------------------------------------------------
# Output / logging
# ---------------------------------------------------------------------------
HV_QUIET=${HV_QUIET:-0}
HV_YES=${HV_YES:-0}
HV_NONINTERACTIVE=${HV_NONINTERACTIVE:-0}
HV_TMP_PATHS=()
HV_CLEANUP_FUNCS=()

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	_C_RED=$'\033[31m' _C_GRN=$'\033[32m' _C_YEL=$'\033[33m' _C_BLU=$'\033[36m' _C_BLD=$'\033[1m' _C_RST=$'\033[0m'
else
	_C_RED='' _C_GRN='' _C_YEL='' _C_BLU='' _C_BLD='' _C_RST=''
fi

# Append one line to logs/homevault/hv-YYYY-MM-DD.log (never pass secrets here).
hv_log() {
	local dir=${HV_LOG_DIR:-}
	[[ -n $dir && -d $dir ]] || return 0
	[[ -d $dir/homevault ]] || mkdir -p "$dir/homevault" 2>/dev/null || return 0
	printf '%s [%s] %s\n' "$(date '+%F %T')" "$$" "$*" >>"$dir/homevault/hv-$(date +%F).log" 2>/dev/null || true
}

msg() { printf '%s\n' "$*"; }
info() {
	[[ $HV_QUIET == 1 ]] || printf '%s==>%s %s\n' "$_C_BLU" "$_C_RST" "$*"
	hv_log "INFO $*"
}
ok() {
	[[ $HV_QUIET == 1 ]] || printf '%s✔%s %s\n' "$_C_GRN" "$_C_RST" "$*"
	hv_log "OK   $*"
}
warn() {
	printf '%s!%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2
	hv_log "WARN $*"
}
err() {
	printf '%s✘%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2
	hv_log "ERR  $*"
}
die() {
	err "$*"
	exit 1
}
title() { [[ $HV_QUIET == 1 ]] || printf '\n%s%s%s\n' "$_C_BLD" "$*" "$_C_RST"; }

# ---------------------------------------------------------------------------
# Cleanup / temp files
# ---------------------------------------------------------------------------
hv_add_cleanup() { HV_CLEANUP_FUNCS+=("$1"); }

hv_run_cleanup() {
	local i f
	for ((i = ${#HV_CLEANUP_FUNCS[@]} - 1; i >= 0; i--)); do
		f=${HV_CLEANUP_FUNCS[i]}
		"$f" || true
	done
	HV_CLEANUP_FUNCS=()
	for f in "${HV_TMP_PATHS[@]}"; do
		[[ -n $f ]] && rm -rf -- "$f"
	done
	HV_TMP_PATHS=()
}

# Per-process temp directory, created in the MAIN shell (hv calls hv_tmpdir_init before any command) and
# removed on exit. hv_mktemp is mostly called as f=$(hv_mktemp): that runs in a subshell which cannot
# register paths for cleanup, so every temp file lives inside this directory instead.
HV_TMP_DIR=${HV_TMP_DIR:-}
hv_tmpdir_init() {
	[[ -n $HV_TMP_DIR && -d $HV_TMP_DIR ]] && return 0
	HV_TMP_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/homevault.XXXXXXXX") || die "无法创建临时目录"
	HV_TMP_PATHS+=("$HV_TMP_DIR")
}

# mktemp with 0600 inside HV_TMP_DIR (falls back to a registered file when not initialised)
hv_mktemp() {
	local f
	if [[ -n $HV_TMP_DIR && -d $HV_TMP_DIR ]]; then
		f=$(umask 077 && mktemp "$HV_TMP_DIR/t.XXXXXXXX") || die "无法创建临时文件"
	else
		f=$(umask 077 && mktemp "${TMPDIR:-/tmp}/homevault.XXXXXXXX") || die "无法创建临时文件"
		HV_TMP_PATHS+=("$f")
	fi
	printf '%s\n' "$f"
}

hv_mktempdir() {
	local d
	if [[ -n $HV_TMP_DIR && -d $HV_TMP_DIR ]]; then
		d=$(umask 077 && mktemp -d "$HV_TMP_DIR/d.XXXXXXXX") || die "无法创建临时目录"
	else
		d=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/homevault.XXXXXXXX") || die "无法创建临时目录"
		HV_TMP_PATHS+=("$d")
	fi
	printf '%s\n' "$d"
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------
is_interactive() { [[ $HV_NONINTERACTIVE != 1 && -t 0 ]]; }

# confirm "问题" [default y|n]  → 0 = yes
confirm() {
	local q=$1 def=${2:-n} ans hint
	[[ $HV_YES == 1 ]] && return 0
	if ! is_interactive; then
		[[ $def == y ]]
		return
	fi
	[[ $def == y ]] && hint='[Y/n]' || hint='[y/N]'
	read -r -p "$q $hint " ans || ans=''
	ans=${ans:-$def}
	[[ $ans == [yY] || $ans == [yY][eE][sS] || $ans == 是 ]]
}

# ask "提示" "默认值"  → prints answer (default when non-interactive)
ask() {
	local q=$1 def=${2:-} ans
	if ! is_interactive; then
		printf '%s\n' "$def"
		return 0
	fi
	if [[ -n $def ]]; then
		read -r -p "$q [$def]: " ans || ans=''
	else
		read -r -p "$q: " ans || ans=''
	fi
	printf '%s\n' "${ans:-$def}"
}

# ask_secret "提示" → prints answer (no echo); empty when non-interactive
ask_secret() {
	local q=$1 ans=''
	is_interactive || {
		printf '\n'
		return 0
	}
	read -r -s -p "$q: " ans || ans=''
	printf '\n' >&2
	printf '%s\n' "$ans"
}

# ask_choice "提示" default opt1 opt2 ...  → validated choice
ask_choice() {
	local q=$1 def=$2 ans o
	shift 2
	while :; do
		ans=$(ask "$q ($(
			IFS=/
			printf '%s' "$*"
		))" "$def")
		for o in "$@"; do
			[[ $ans == "$o" ]] && {
				printf '%s\n' "$ans"
				return 0
			}
		done
		is_interactive || die "无效的选项：$ans（可选：$*）"
		warn "请输入以下之一：$*"
	done
}

# ---------------------------------------------------------------------------
# Random / crypto
# ---------------------------------------------------------------------------
# gen_secret [len=32] → CSPRNG alnum string
gen_secret() {
	local len=${1:-32} out='' chunk
	while ((${#out} < len)); do
		chunk=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9') || true
		out+=$chunk
	done
	printf '%s\n' "${out:0:len}"
}

# rand_int min max (inclusive), from /dev/urandom
rand_int() {
	local min=$1 max=$2 n
	n=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
	printf '%d\n' $((min + n % (max - min + 1)))
}

sha256_hex() { printf '%s' "$1" | sha256sum | cut -c1-64; }

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
	[[ $(id -u) -eq 0 ]] || die "此命令需要 root 权限，请使用：sudo $HV_SELF ${HV_CMD:-} …"
}

# version_ge 2.24.1 2.24 → 0 when $1 >= $2
version_ge() {
	[[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1) == "$2" ]]
}

trim() {
	local s=$1
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s\n' "$s"
}

is_true() { [[ ${1,,} == true || ${1,,} == yes || $1 == 1 || ${1,,} == on ]]; }

# human_bytes 1099511627776 → 1.0T
human_bytes() {
	local b=${1:-0}
	[[ $b =~ ^[0-9]+$ ]] || {
		printf '%s\n' "-"
		return 0
	}
	awk -v b="$b" 'BEGIN{ split("B K M G T P", u, " "); i=1; while (b>=1024 && i<6) { b/=1024; i++ }
		if (i==1) printf "%dB\n", b; else printf "%.1f%s\n", b, u[i] }'
}

# display width (CJK characters count as 2 columns)
str_width() {
	local s=$1 ascii
	ascii=${s//[![:ascii:]]/}
	printf '%d\n' $((${#ascii} + 2 * (${#s} - ${#ascii})))
}

# pad "文本" width → text padded with spaces to width columns
pad() {
	local s=$1 w=$2 cur
	cur=$(str_width "$s")
	printf '%s' "$s"
	((cur < w)) && printf '%*s' $((w - cur)) ''
	return 0
}

# print_table: reads rows (fields separated by TAB) from stdin; first row = header
print_table() {
	local -a rows widths
	local line i f w n
	local IFS=$'\t'
	mapfile -t rows
	for line in "${rows[@]}"; do
		read -r -a f <<<"$line"
		for i in "${!f[@]}"; do
			w=$(str_width "${f[i]}")
			((w > ${widths[i]:-0})) && widths[i]=$w
		done
	done
	n=0
	for line in "${rows[@]}"; do
		read -r -a f <<<"$line"
		for i in "${!f[@]}"; do
			pad "${f[i]}" "${widths[i]}"
			((i < ${#f[@]} - 1)) && printf ' | '
		done
		printf '\n'
		if ((n == 0)); then
			for i in "${!widths[@]}"; do
				printf '%*s' "${widths[i]}" '' | tr ' ' '-'
				((i < ${#widths[@]} - 1)) && printf '%s' '-+-'
			done
			printf '\n'
		fi
		n=$((n + 1))
	done
}

# JSON string escaping (no surrounding quotes)
json_escape() {
	local s=$1 out='' c i o
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/\\n}
	s=${s//$'\r'/\\r}
	s=${s//$'\t'/\\t}
	if [[ $s == *[$'\x01'-$'\x1f']* ]]; then
		for ((i = 0; i < ${#s}; i++)); do
			c=${s:i:1}
			if [[ $c == [$'\x01'-$'\x1f'] ]]; then
				printf -v o '\\u%04x' "'$c"
				out+=$o
			else
				out+=$c
			fi
		done
		s=$out
	fi
	printf '%s' "$s"
}

# json_str "text" → "text" (quoted JSON string)
json_str() { printf '"%s"' "$(json_escape "$1")"; }

# json_array a b c → ["a","b","c"]
json_array() {
	local first=1 x
	printf '['
	for x in "$@"; do
		((first)) || printf ','
		first=0
		json_str "$x"
	done
	printf ']'
}

# YAML double-quoted scalar (also escapes $ for compose interpolation when $2=compose)
yaml_dq() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	[[ ${2:-} == compose ]] && s=${s//\$/\$\$}
	printf '"%s"' "$s"
}

# url-encode (RFC 3986 unreserved kept, '/' kept when $2=path)
urlencode() {
	local LC_ALL=C s=$1 keep_slash=${2:-} i c out=''
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		case $c in
		[a-zA-Z0-9.~_-]) out+=$c ;;
		/) if [[ $keep_slash == path ]]; then out+=/; else out+=%2F; fi ;;
		*) out+=$(printf '%%%02X' "'$c") ;;
		esac
	done
	printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# IPv4 helpers
# ---------------------------------------------------------------------------
is_ipv4() {
	local ip=$1 o
	[[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	for o in "${BASH_REMATCH[@]:1}"; do
		((10#$o <= 255)) || return 1
	done
}

is_ipv4_cidr() {
	[[ $1 == */* ]] || return 1
	is_ipv4 "${1%/*}" || return 1
	[[ ${1#*/} =~ ^[0-9]{1,2}$ ]] && ((10#${1#*/} <= 32))
}

ip_to_int() {
	local IFS=. a b c d
	read -r a b c d <<<"$1"
	printf '%d\n' $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

int_to_ip() {
	local n=$1
	printf '%d.%d.%d.%d\n' $(((n >> 24) & 255)) $(((n >> 16) & 255)) $(((n >> 8) & 255)) $((n & 255))
}

# cidr_network 192.168.1.10/24 → 192.168.1.0/24
cidr_network() {
	local ip=${1%/*} len=${1#*/} n mask
	n=$(ip_to_int "$ip")
	if ((len == 0)); then mask=0; else mask=$(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF)); fi
	printf '%s/%s\n' "$(int_to_ip $((n & mask)))" "$len"
}

# cidr_first_host 10.99.77.0/24 → 10.99.77.1
cidr_first_host() {
	local net
	net=$(cidr_network "$1")
	int_to_ip $(($(ip_to_int "${net%/*}") + 1))
}

# ip_in_cidr 192.168.1.5 192.168.1.0/24
ip_in_cidr() {
	local ip=$1 cidr=$2 len n net mask
	is_ipv4 "$ip" && is_ipv4_cidr "$cidr" || return 1
	len=${cidr#*/}
	if ((len == 0)); then mask=0; else mask=$(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF)); fi
	n=$(ip_to_int "$ip")
	net=$(ip_to_int "${cidr%/*}")
	(((n & mask) == (net & mask)))
}

# Expand Caddy-style allow list ("private_ranges 100.64.0.0/10") to IPv4 CIDRs.
expand_allowed_cidrs() {
	local tok
	for tok in $1; do
		case $tok in
		private_ranges) printf '%s\n' 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 ;;
		*:*) ;; # IPv6: published ports are IPv4-only, ignore
		*/*) is_ipv4_cidr "$tok" && printf '%s\n' "$tok" ;;
		*) is_ipv4 "$tok" && printf '%s/32\n' "$tok" ;;
		esac
	done
	return 0
}

# Detect primary LAN IPv4 (route to the internet) → "ip dev cidr" or empty
detect_lan() {
	local line ip='' dev='' cidr=''
	if have ip; then
		line=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1) || true
		[[ $line =~ src[[:space:]]+([0-9.]+) ]] && ip=${BASH_REMATCH[1]}
		[[ $line =~ dev[[:space:]]+([^[:space:]]+) ]] && dev=${BASH_REMATCH[1]}
		if [[ -n $dev && -n $ip ]]; then
			line=$(ip -o -4 addr show dev "$dev" 2>/dev/null | grep -F " $ip/" | head -n1) || true
			[[ $line =~ inet[[:space:]]+([0-9.]+/[0-9]+) ]] && cidr=$(cidr_network "${BASH_REMATCH[1]}")
		fi
	fi
	if [[ -z $ip ]] && have hostname; then
		ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10|172|192)\.' | head -n1) || true
	fi
	[[ -z $cidr && -n $ip ]] && cidr=$(cidr_network "$ip/24")
	[[ -n $ip ]] && printf '%s %s %s\n' "$ip" "${dev:--}" "$cidr"
	return 0
}

# Is a TCP port in use on the given IPv4 (or any address)?
port_in_use() {
	local port=$1 bind=${2:-0.0.0.0} hex f line local_addr st a p
	if have ss; then
		ss -Htln 2>/dev/null | awk '{print $4}' | while read -r a; do
			p=${a##*:}
			a=${a%:*}
			[[ $p == "$port" ]] || continue
			if [[ $a == '*' || $a == 0.0.0.0 || $a == '[::]' || $a == "$bind" || $bind == 0.0.0.0 ]]; then
				echo hit
			fi
		done | grep -q hit
		return
	fi
	# Fallback: /proc/net/tcp{,6} (LISTEN = 0A)
	printf -v hex '%04X' "$port"
	for f in /proc/net/tcp /proc/net/tcp6; do
		[[ -r $f ]] || continue
		while read -r _ local_addr _ st _; do
			[[ $st == 0A && ${local_addr##*:} == "$hex" ]] && return 0
		done < <(tail -n +2 "$f")
	done
	return 1
}

# Free bytes / total bytes of the filesystem holding a path (nearest existing parent)
fs_stats() {
	local p=$1
	while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
	{ df -B1 -P "$p" 2>/dev/null || true; } | awk 'NR==2 {print $2, $4, $6}'
}
