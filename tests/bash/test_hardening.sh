# shellcheck shell=bash disable=SC2034,SC2016 # test globals are read by the sourced modules
# trusted proxies (fixed Caddy / panel addresses), DNS credentials as files, Nextcloud data directory guard

test_frontend_fixed_addresses() {
	HV_FRONTEND_SUBNET=172.31.250.0/24
	hv_compute_frontend
	assert_eq 172.31.250.2 "$HV_CADDY_IP"
	assert_eq 172.31.250.3 "$HV_PANEL_IP"
	assert_eq 172.31.250.128/25 "$HV_FRONTEND_IP_RANGE"
	HV_FRONTEND_SUBNET=10.20.0.0/16
	hv_compute_frontend
	assert_eq 10.20.0.2 "$HV_CADDY_IP"
	assert_eq 10.20.0.3 "$HV_PANEL_IP"
	assert_eq 10.20.128.0/17 "$HV_FRONTEND_IP_RANGE"
	HV_FRONTEND_SUBNET=192.168.200.64/28
	hv_compute_frontend
	assert_eq 192.168.200.66 "$HV_CADDY_IP"
	assert_eq 192.168.200.72/29 "$HV_FRONTEND_IP_RANGE"
	# invalid subnet: values untouched (hv_validate_env reports it)
	HV_FRONTEND_SUBNET=bogus HV_CADDY_IP=keep
	hv_compute_frontend
	assert_eq keep "$HV_CADDY_IP"
}

test_frontend_subnet_validation() {
	HV_HOST=192.168.1.10 HV_TLS_MODE=internal HV_HTTP_PORT=80 HV_HTTPS_PORT=443 HV_ADMIN_PORT=8443 HV_PANEL_PORT=9443
	HV_LOG_RETENTION_DAYS=7 HV_EXTRA_HOSTS='' HV_BIND_IP=192.168.1.10 HV_PLATFORM=linux HV_VPN_ENABLED=false
	HV_FRONTEND_SUBNET=172.31.250.0/24 assert_ok hv_validate_env
	HV_FRONTEND_SUBNET=10.30.0.0/16 assert_ok hv_validate_env
	HV_FRONTEND_SUBNET=172.31.250.0/28 assert_ok hv_validate_env
	HV_FRONTEND_SUBNET=172.31.250.5/24 assert_fail hv_validate_env
	HV_FRONTEND_SUBNET=172.31.250.0/29 assert_fail hv_validate_env
	HV_FRONTEND_SUBNET=10.0.0.0/8 assert_fail hv_validate_env
	HV_FRONTEND_SUBNET='' assert_fail hv_validate_env
	HV_FRONTEND_SUBNET=172.31.250.0 assert_fail hv_validate_env
}

test_compose_trusts_only_caddy_and_panel() {
	have_compose || return 0
	command -v python3 >/dev/null || return 0
	local d=$TMP_ROOT/proxy json
	bash "$HV_ROOT/tests/lib/make-test-env.sh" "$d" --no-chown --subnet 172.31.200.0/24 >/dev/null
	json=$(docker compose --project-directory "$HV_ROOT" -f "$HV_ROOT/compose.yaml" --env-file "$d/.env" \
		--profile tools config --format json 2>/dev/null) || {
		fail "compose config"
		return
	}
	assert_eq 172.31.200.2 "$(json_get "d['services']['caddy']['networks']['frontend']['ipv4_address']" <<<"$json")"
	assert_eq 172.31.200.3 "$(json_get "d['services']['panel']['networks']['frontend']['ipv4_address']" <<<"$json")"
	assert_eq '172.31.200.2/32 172.31.200.3/32' "$(json_get "d['services']['app']['environment']['TRUSTED_PROXIES']" <<<"$json")"
	assert_eq '172.31.200.2/32 172.31.200.3/32' "$(json_get "d['services']['cron']['environment']['TRUSTED_PROXIES']" <<<"$json")"
	assert_eq 172.31.200.2/32 "$(json_get "d['services']['panel']['environment']['PANEL_TRUSTED_PROXIES']" <<<"$json")"
	assert_eq 172.31.200.128/25 "$(json_get "d['networks']['frontend']['ipam']['config'][0]['ip_range']" <<<"$json")"
	assert_eq "False False False" "$(json_get "' '.join(str([v for v in d['services'][s]['volumes'] if v['target'] in ('/var/www/data', '/src/nextcloud-data')][0]['bind']['create_host_path']) for s in ('app', 'cron', 'backup'))" <<<"$json")"
	assert_eq True "$(json_get "[v for v in d['services']['backup']['volumes'] if v['target'] == '/src/nextcloud-data'][0]['read_only']" <<<"$json")"
	assert_eq False "$(json_get "'env_file' in d['services']['caddy']" <<<"$json")"
}

test_restore_override_makes_nc_data_writable() {
	have_compose || return 0
	command -v python3 >/dev/null || return 0
	local d=$TMP_ROOT/restore-ov json
	bash "$HV_ROOT/tests/lib/make-test-env.sh" "$d" --no-chown >/dev/null
	env_load "$d/.env"
	restore_render_override >"$d/override.yaml"
	json=$(docker compose --project-directory "$HV_ROOT" -f "$HV_ROOT/compose.yaml" -f "$d/override.yaml" --env-file "$d/.env" \
		--profile tools config --format json 2>/dev/null) || {
		fail "compose config with the restore override"
		return
	}
	assert_eq "1 False" "$(json_get "(lambda m: '%d %s' % (len(m), bool(m[0].get('read_only'))))([v for v in d['services']['backup']['volumes'] if v['target'] == '/src/nextcloud-data'])" <<<"$json")"
}

_dns_root() {
	HV_ROOT=$TMP_ROOT/dns-$1
	rm -rf "$HV_ROOT"
	mkdir -p "$HV_ROOT/secrets"
	chmod 0700 "$HV_ROOT/secrets"
}

test_caddy_dns_credentials_are_files() {
	_dns_root write
	assert_fail caddy_dns_have_creds alidns
	install_write_provider_env alidns 'LTAI5tId' 'se cr$et"x' || fail "write alidns"
	assert_ok caddy_dns_have_creds alidns
	assert_fail caddy_dns_have_creds cloudflare
	assert_fail caddy_dns_have_creds unknown
	assert_eq 'LTAI5tId' "$(cat "$HV_ROOT/secrets/caddy-dns/ALIYUN_ACCESS_KEY_ID")"
	assert_eq 'se cr$et"x' "$(cat "$HV_ROOT/secrets/caddy-dns/ALIYUN_ACCESS_KEY_SECRET")"
	assert_eq 1 "$(wc -l <"$HV_ROOT/secrets/caddy-dns/ALIYUN_ACCESS_KEY_SECRET")" "single line"
	assert_eq 644 "$(stat -c %a "$HV_ROOT/secrets/caddy-dns/ALIYUN_ACCESS_KEY_ID")"
	assert_eq 755 "$(stat -c %a "$HV_ROOT/secrets/caddy-dns")"
	assert_eq 700 "$(stat -c %a "$HV_ROOT/secrets")"
	install_write_provider_env cloudflare '' 'cf-token-0123456789' || fail "write cloudflare"
	assert_ok caddy_dns_have_creds cloudflare
	assert_eq '' "$(find "$HV_ROOT/secrets/caddy-dns" -name '*.tmp')" "no temp files left"
	assert_eq $'TENCENTCLOUD_SECRET_ID\nTENCENTCLOUD_SECRET_KEY' "$(caddy_dns_keys tencentcloud)"
}

test_caddy_dns_migrates_old_env_file() {
	_dns_root migrate
	cat >"$HV_ROOT/secrets/caddy-dns.env" <<'EOT'
# old format
TENCENTCLOUD_SECRET_ID=AKIDxyz
TENCENTCLOUD_SECRET_KEY='k$y with space'
CF_API_TOKEN=
EOT
	# an already migrated value wins over the old file
	mkdir -p "$HV_ROOT/secrets/caddy-dns"
	printf 'newer\n' >"$HV_ROOT/secrets/caddy-dns/TENCENTCLOUD_SECRET_ID"
	caddy_dns_migrate >/dev/null 2>&1 || fail "migrate"
	assert_eq newer "$(cat "$HV_ROOT/secrets/caddy-dns/TENCENTCLOUD_SECRET_ID")"
	assert_eq 'k$y with space' "$(cat "$HV_ROOT/secrets/caddy-dns/TENCENTCLOUD_SECRET_KEY")"
	assert_ok caddy_dns_have_creds tencentcloud
	[[ ! -e $HV_ROOT/secrets/caddy-dns.env ]] || fail "old caddy-dns.env must be removed"
	[[ ! -e $HV_ROOT/secrets/caddy-dns/CF_API_TOKEN ]] || fail "empty values are not migrated"
	caddy_dns_migrate >/dev/null 2>&1 || fail "migrate is idempotent"
}

test_caddy_dns_check_creates_dir_and_warns() {
	_dns_root check
	HV_TLS_MODE=internal
	caddy_dns_check >/dev/null 2>&1 || fail "internal mode needs nothing"
	[[ ! -e $HV_ROOT/secrets/caddy-dns ]] || fail "internal mode must not create secrets/caddy-dns"
	HV_TLS_MODE=acme-dns HV_DNS_PROVIDER=cloudflare
	assert_fail caddy_dns_check
	[[ -d $HV_ROOT/secrets/caddy-dns ]] || fail "acme mode: the mounted directory must exist"
	printf 'tok\n' >"$HV_ROOT/secrets/caddy-dns/CF_API_TOKEN"
	assert_ok caddy_dns_check
}

test_nc_data_guard() {
	local p=$TMP_ROOT/ncdata
	HV_STATE_DIR=$TMP_ROOT/ncstate
	rm -rf "$p" "$HV_STATE_DIR"
	mkdir -p "$HV_STATE_DIR"
	HV_NC_DATA_PATH=$p
	assert_fail hv_check_nc_data
	assert_contains "$(hv_check_nc_data 2>&1)" '数据盘可能没有挂载'
	[[ ! -e $p ]] || fail "the check must never create the directory"
	mkdir -p "$p"
	assert_ok hv_check_nc_data # not installed yet: an empty directory is fine
	date -Iseconds >"$HV_STATE_DIR/installed"
	assert_fail hv_check_nc_data # installed + empty = unmounted disk (mount point only)
	: >"$p/.ncdata"
	assert_ok hv_check_nc_data
	HV_NC_DATA_PATH='' assert_ok hv_check_nc_data
}
