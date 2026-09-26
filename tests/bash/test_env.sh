# shellcheck shell=bash disable=SC2034,SC2016 # test globals are read by the sourced modules
# .env read/write, quoting, derived variables

test_env_set_preserves_comments_and_order() {
	local f=$TMP_ROOT/t1.env
	cat >"$f" <<'EOF'
# 注释一
HV_HOST=192.168.1.10

# 注释二：端口
HV_HTTPS_PORT=443   # 行尾注释
HV_HTTP_PORT=80
EOF
	env_set_file HV_HTTPS_PORT 8443 "$f"
	env_set_file HV_NEW 'hello world' "$f"
	env_set_file HV_HOST 10.0.0.2 "$f"
	local expected
	expected=$'# 注释一\nHV_HOST=10.0.0.2\n\n# 注释二：端口\nHV_HTTPS_PORT=8443\nHV_HTTP_PORT=80\nHV_NEW=\'hello world\''
	assert_eq "$expected" "$(cat "$f")" "file content"
	assert_eq 8443 "$(env_get_file HV_HTTPS_PORT "$f")"
	assert_eq 'hello world' "$(env_get_file HV_NEW "$f")"
	assert_fail env_get_file HV_MISSING "$f"
}

test_env_unquote_variants() {
	assert_eq 'abc' "$(env_unquote 'abc')"
	assert_eq 'abc' "$(env_unquote 'abc # comment')"
	assert_eq 'a#b' "$(env_unquote 'a#b')"
	assert_eq '' "$(env_unquote '# only comment')"
	assert_eq 'private_ranges 100.64.0.0/10' "$(env_unquote "'private_ranges 100.64.0.0/10'")"
	assert_eq 'x $y "z"' "$(env_unquote "'x \$y \"z\"' # c")"
	assert_eq 'say "hi"' "$(env_unquote '"say \"hi\""')"
	assert_eq 'spaced' "$(env_unquote '  spaced   ')"
}

test_env_quote_roundtrip() {
	local f=$TMP_ROOT/t2.env v
	: >"$f"
	local -a vals=('plain' 'https://a:443, https://b:443' 'private_ranges 100.64.0.0/10' 'a$b' "it's" 'x #y' '-o s3.bucket-lookup=dns -o s3.region=oss-cn-hangzhou' '' '中文值')
	local i=0
	for v in "${vals[@]}"; do
		env_set_file "K$i" "$v" "$f"
		i=$((i + 1))
	done
	i=0
	for v in "${vals[@]}"; do
		assert_eq "$v" "$(env_get_file "K$i" "$f")" "roundtrip K$i"
		i=$((i + 1))
	done
}

test_env_quote_matches_docker_compose() {
	have_compose || return 0
	local d=$TMP_ROOT/cmp v out i=0
	mkdir -p "$d"
	local -a vals=('https://a:443, https://b:443' 'private_ranges 100.64.0.0/10' 'a$b' "it's" 'x #y' '中文 值')
	: >"$d/.env"
	{
		echo 'services:'
		echo '  t:'
		echo '    image: busybox'
		echo '    environment:'
		for v in "${vals[@]}"; do
			echo "      V$i: \${K$i}"
			i=$((i + 1))
		done
	} >"$d/compose.yaml"
	i=0
	for v in "${vals[@]}"; do
		env_set_file "K$i" "$v" "$d/.env"
		i=$((i + 1))
	done
	out=$(docker compose --project-directory "$d" -f "$d/compose.yaml" --env-file "$d/.env" -p t config --format json 2>&1) || {
		fail "compose config failed: $out"
		return
	}
	command -v python3 >/dev/null || return 0
	i=0
	for v in "${vals[@]}"; do
		# compose config re-escapes a literal "$" as "$$" in its output
		assert_eq "${v//\$/\$\$}" "$(json_get "d['services']['t']['environment']['V$i']" <<<"$out")" "compose sees V$i"
		i=$((i + 1))
	done
}

test_env_load_sets_globals() {
	local f=$TMP_ROOT/t3.env
	printf 'HV_HOST=nas.example.com\nexport HV_TZ=Asia/Shanghai\nlower=ignored\nHV_ALLOWED_CIDRS="private_ranges 100.64.0.0/10"\n' >"$f"
	env_load "$f"
	assert_eq nas.example.com "$HV_HOST"
	assert_eq Asia/Shanghai "$HV_TZ"
	assert_eq 'private_ranges 100.64.0.0/10' "$HV_ALLOWED_CIDRS"
	assert_eq '' "${lower:-}" "lowercase keys ignored"
}

test_derived_ip_mode_default_port() {
	HV_PLATFORM=linux HV_HOST=192.168.1.10 HV_EXTRA_HOSTS='' HV_HTTPS_PORT=443 HV_TLS_MODE=internal HV_VPN_ENABLED=true
	HV_DNS_PROVIDER=alidns HV_VPN_CIDR=10.99.77.0/24
	hv_compute_derived
	assert_eq 'https://192.168.1.10:443' "$HV_SITE_ADDRESSES"
	assert_eq '192.168.1.10' "$HV_TRUSTED_DOMAINS"
	assert_eq 'https://192.168.1.10' "$HV_OVERWRITE_CLI_URL"
	assert_eq internal "$HV_TLS_SNIPPET"
	assert_eq wgeasy "$HV_ADMIN_SNIPPET"
}

test_derived_custom_port_extras_domain() {
	HV_PLATFORM=linux HV_HOST=nas.example.com HV_EXTRA_HOSTS='192.168.1.10 nas.example.com' HV_HTTPS_PORT=8443
	HV_TLS_MODE=acme-dns HV_DNS_PROVIDER=tencentcloud HV_VPN_ENABLED=false HV_VPN_CIDR=10.99.77.0/24
	hv_compute_derived
	assert_eq 'https://nas.example.com:8443, https://192.168.1.10:8443' "$HV_SITE_ADDRESSES"
	assert_eq 'nas.example.com nas.example.com:8443 192.168.1.10 192.168.1.10:8443' "$HV_TRUSTED_DOMAINS"
	assert_eq 'https://nas.example.com:8443' "$HV_OVERWRITE_CLI_URL"
	assert_eq acme-tencentcloud "$HV_TLS_SNIPPET"
	assert_eq none "$HV_ADMIN_SNIPPET"
}

test_derived_windows_adds_vpn_server_ip() {
	HV_PLATFORM=windows HV_HOST=192.168.1.20 HV_EXTRA_HOSTS='' HV_HTTPS_PORT=443 HV_TLS_MODE=internal
	HV_VPN_ENABLED=true HV_VPN_CIDR=10.99.77.0/24 HV_DNS_PROVIDER=alidns
	hv_compute_derived
	assert_eq 'https://192.168.1.20:443, https://10.99.77.1:443' "$HV_SITE_ADDRESSES"
	assert_eq '192.168.1.20 10.99.77.1' "$HV_TRUSTED_DOMAINS"
	assert_eq none "$HV_ADMIN_SNIPPET" "no wg-easy on windows"
}

test_write_derived_updates_env_file() {
	HV_ENV_FILE=$TMP_ROOT/t4.env
	printf '# 派生变量\nHV_SITE_ADDRESSES=\nHV_TRUSTED_DOMAINS=\nOTHER=1\n' >"$HV_ENV_FILE"
	HV_PLATFORM=linux HV_HOST=10.1.2.3 HV_EXTRA_HOSTS='' HV_HTTPS_PORT=443 HV_TLS_MODE=internal HV_VPN_ENABLED=true
	HV_DNS_PROVIDER=alidns HV_VPN_CIDR=10.99.77.0/24
	hv_write_derived
	assert_eq 'https://10.1.2.3:443' "$(env_get_file HV_SITE_ADDRESSES "$HV_ENV_FILE")"
	assert_eq wgeasy "$(env_get_file HV_ADMIN_SNIPPET "$HV_ENV_FILE")"
	assert_eq '# 派生变量' "$(head -n1 "$HV_ENV_FILE")"
	assert_eq 1 "$(env_get_file OTHER "$HV_ENV_FILE")"
}

test_bump_nc_major() {
	assert_eq 'docker.io/library/nextcloud:35-apache' "$(bump_nc_major docker.io/library/nextcloud:34-apache)"
	assert_eq 'docker.m.daocloud.io/library/nextcloud:35-apache' "$(bump_nc_major docker.m.daocloud.io/library/nextcloud:34.0.4-apache)"
	assert_eq 'nextcloud:36' "$(bump_nc_major nextcloud:35)"
	assert_fail bump_nc_major docker.io/library/nextcloud:stable-apache
	assert_fail bump_nc_major nextcloud
}

test_mirror_rewrite() {
	assert_eq 'docker.m.daocloud.io/library/nextcloud:34-apache' \
		"$(mirror_rewrite docker.io/library/nextcloud:34-apache docker.m.daocloud.io/ ghcr.m.daocloud.io/)"
	assert_eq 'ghcr.m.daocloud.io/wg-easy/wg-easy:15' \
		"$(mirror_rewrite ghcr.io/wg-easy/wg-easy:15 docker.m.daocloud.io/ ghcr.m.daocloud.io/)"
	# switching back to upstream
	assert_eq 'docker.io/restic/restic:0.19.1' \
		"$(mirror_rewrite docker.m.daocloud.io/restic/restic:0.19.1 docker.io/ ghcr.io/ docker.m.daocloud.io/ ghcr.m.daocloud.io/)"
	# custom → other custom
	assert_eq 'hub.example.cn/library/redis:8-alpine' \
		"$(mirror_rewrite mirror.a/library/redis:8-alpine hub.example.cn/ ghcr.example.cn/ mirror.a/ ghcr.a/)"
	# locally built image untouched
	assert_eq 'homevault/caddy-dns:2.11.4' "$(mirror_rewrite homevault/caddy-dns:2.11.4 docker.m.daocloud.io/ ghcr.m.daocloud.io/)"
}

test_host_normalize_and_validate() {
	assert_eq nas.example.com "$(hv_normalize_host '  https://NAS.Example.com:443/index.php ')"
	assert_eq 192.168.1.10 "$(hv_normalize_host 'http://192.168.1.10:8080')"
	assert_eq vpn.example.com "$(hv_normalize_host 'vpn.example.com:51820')"
	local h
	for h in 192.168.1.10 nas.example.com localhost a-b.c1.cn; do assert_ok valid_host "$h"; done
	for h in '' 999.1.1.1 1.2.3 'a b' 'https://x.cn' 'x.cn:443' '*.x.cn' '-x.cn' 'x_y.cn' 'x.cn{' '::1'; do assert_fail valid_host "$h"; done
	for h in a@b.cn first.last+tag@mail.example.com; do assert_ok valid_email "$h"; done
	for h in 'a b@c.cn' 'a@b' '@b.cn' "a'@b.cn" 'a@b.cn}'; do assert_fail valid_email "$h"; done
	HV_HOST=192.168.1.10 HV_TLS_MODE=internal HV_HTTP_PORT=80 HV_HTTPS_PORT=443 HV_ADMIN_PORT=8443 HV_PANEL_PORT=9443
	HV_LOG_RETENTION_DAYS=7 HV_EXTRA_HOSTS='' HV_BIND_IP=192.168.1.10 HV_PLATFORM=linux HV_VPN_ENABLED=true WG_HOST=vpn.example.com
	assert_ok hv_validate_env
	HV_EXTRA_HOSTS='nas.lan https://oops' assert_fail hv_validate_env
	HV_BIND_IP='::' assert_fail hv_validate_env
	HV_BIND_IP='' assert_ok hv_validate_env
	WG_HOST='vpn.example.com:51820' assert_fail hv_validate_env
	HV_VPN_ENABLED=false WG_HOST='bad host' assert_ok hv_validate_env
	HV_HOST=https://nas.example.com assert_fail hv_validate_env
	HV_HOST=nas.example.com HV_TLS_MODE=acme-dns HV_DNS_PROVIDER=alidns HV_ACME_EMAIL='' assert_ok hv_validate_env
	HV_HOST=nas.example.com HV_TLS_MODE=acme-dns HV_DNS_PROVIDER=alidns HV_ACME_EMAIL='me@example.cn' assert_ok hv_validate_env
	HV_HOST=nas.example.com HV_TLS_MODE=acme-dns HV_DNS_PROVIDER=alidns HV_ACME_EMAIL='me at example' assert_fail hv_validate_env
}
