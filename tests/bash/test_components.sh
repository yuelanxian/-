# shellcheck shell=bash disable=SC2034,SC2016 # test globals are read by the sourced modules
# vpn hooks / init env, restic arguments, firewall rules, ddns yaml, requests, helpers

_vpn_vars() {
	HV_PLATFORM=linux HV_VPN_ENABLED=true HV_VPN_CIDR=10.99.77.0/24 HV_LAN_IP=192.168.1.10 HV_LAN_CIDR=192.168.1.0/24
	HV_VPN_DNS=223.5.5.5,119.29.29.29 HV_VPN_KEEPALIVE=0 WG_HOST=vpn.example.com WG_PORT=34567 HV_VPN_LAN_ACCESS=host
}

test_vpn_hooks_host_mode() {
	_vpn_vars
	local up down
	up=$(vpn_hooks up)
	down=$(vpn_hooks down)
	assert_eq 'iptables -t nat -A POSTROUTING -s {{ipv4Cidr}} -o {{device}} -j MASQUERADE; iptables -A INPUT -p udp -m udp --dport {{port}} -j ACCEPT; iptables -A INPUT -i wg0 -p tcp --dport {{uiPort}} -j DROP; iptables -A FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -A FORWARD -i wg0 -d 192.168.1.10/32 -j ACCEPT; iptables -A FORWARD -i wg0 -j DROP;' "$up"
	assert_eq "${up//-A /-D }" "$down" "PostDown mirrors PostUp"
	assert_not_contains "$up" 'FORWARD -i wg0 -j ACCEPT'
}

test_vpn_hooks_full_mode() {
	_vpn_vars
	HV_VPN_LAN_ACCESS=full
	local up
	up=$(vpn_hooks up)
	assert_contains "$up" 'iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT;'
	assert_contains "$up" 'iptables -A INPUT -i wg0 -p tcp --dport {{uiPort}} -j DROP'
	assert_eq '10.99.77.0/24,192.168.1.0/24' "$(vpn_allowed_ips)"
}

test_vpn_init_env() {
	_vpn_vars
	local out
	out=$(vpn_render_init_env 'Pw123456789012345678')
	assert_contains "$out" $'INIT_ENABLED=true\nINIT_USERNAME=hvadmin\nINIT_PASSWORD=Pw123456789012345678'
	assert_contains "$out" 'INIT_HOST=vpn.example.com'
	assert_contains "$out" 'INIT_PORT=34567'
	assert_contains "$out" 'INIT_DNS=223.5.5.5,119.29.29.29'
	assert_contains "$out" 'INIT_IPV4_CIDR=10.99.77.0/24'
	assert_contains "$out" 'INIT_IPV6_CIDR=fdcc:ad94:bacf:61a4::cafe:0/112'
	assert_contains "$out" 'INIT_ALLOWED_IPS=10.99.77.0/24,192.168.1.10/32'
}

test_vpn_finalize_payload_is_json() {
	_vpn_vars
	local p
	p=$(vpn_finalize_payload 'se"cr\et')
	json_valid <<<"$p" || fail "invalid JSON: $p"
	command -v python3 >/dev/null || return 0
	assert_eq 'se"cr\et' "$(json_get "d['pass']" <<<"$p")"
	assert_eq "['10.99.77.0/24', '192.168.1.10/32']" "$(json_get "d['allowedIps']" <<<"$p")"
	assert_eq "['223.5.5.5', '119.29.29.29']" "$(json_get "d['dns']" <<<"$p")"
	assert_eq 34567 "$(json_get "d['port']" <<<"$p")"
	assert_eq "$(vpn_hooks up)" "$(json_get "d['postUp']" <<<"$p")"
}

test_vpn_node_scripts_parse() {
	command -v node >/dev/null || return 0
	local s
	for s in "$HV_WG_NODE_FINALIZE" "$HV_WG_NODE_PING" "$HV_WG_NODE_ADD"; do
		printf '%s' "$s" >"$TMP_ROOT/n.js"
		node --check "$TMP_ROOT/n.js" 2>/dev/null || fail "node syntax error in: ${s:0:60}"
	done
}

test_restic_repo_args() {
	local -a r
	HV_BACKUP_TARGET=local HV_BACKUP_LOCAL_PATH=/mnt/backup
	restic_repo_args r
	assert_eq '-r /repo' "${r[*]}"
	HV_BACKUP_TARGET=s3 HV_BACKUP_S3_REPO='s3:https://oss-cn-hangzhou.aliyuncs.com/bkt/hv'
	HV_BACKUP_S3_OPTIONS='-o s3.bucket-lookup=dns -o s3.region=oss-cn-hangzhou'
	restic_repo_args r
	assert_eq 6 "${#r[@]}"
	assert_eq 's3:https://oss-cn-hangzhou.aliyuncs.com/bkt/hv' "${r[1]}"
	assert_eq 's3.region=oss-cn-hangzhou' "${r[5]}"
	HV_BACKUP_S3_OPTIONS='-o x=$(id)'
	restic_repo_args r
	assert_eq 'x=$(id)' "${r[3]}" "no evaluation of options"
}

test_restic_backup_args() {
	local -a a
	HV_PLATFORM=linux HV_VPN_ENABLED=true HV_STORAGE_CONF=$FIXTURES/storage-valid.conf
	storage_parse_conf "$FIXTURES/storage-valid.conf"
	restic_backup_args a
	assert_eq backup "${a[0]}"
	local joined=" ${a[*]} "
	assert_contains "$joined" ' /src/nextcloud-html/config /src/nextcloud-html/custom_apps /src/nextcloud-html/themes /src/nextcloud-data /src/caddy-data /src/dumps /src/project /src/wg-easy '
	assert_contains "$joined" ' /src/storage/s24d68919 '
	assert_not_contains "$joined" "/src/storage/$(storage_slug '/mnt/media/影视 资料')"
	assert_contains "$joined" ' --tag homevault '
	assert_contains "$joined" " --exclude /src/nextcloud-data/appdata_*/preview "
	assert_contains "$joined" ' --exclude /src/project/.git '
	HV_VPN_ENABLED=false
	restic_backup_args a
	assert_not_contains " ${a[*]} " '/src/wg-easy'
	local -a f
	HV_BACKUP_KEEP_DAILY=3 HV_BACKUP_KEEP_WEEKLY=2 HV_BACKUP_KEEP_MONTHLY=6
	restic_forget_args f
	assert_eq 'forget --host homevault --tag homevault --group-by host,tags --keep-daily 3 --keep-weekly 2 --keep-monthly 6 --prune' "${f[*]}"
}

test_restic_exit_messages() {
	assert_contains "$(restic_exit_msg 3)" '不完整'
	assert_contains "$(restic_exit_msg 10)" '初始化'
	assert_contains "$(restic_exit_msg 12)" '密码'
	assert_contains "$(restic_exit_msg 11)" '锁'
	assert_contains "$(restic_exit_msg 99)" '99'
}

test_backup_configured() {
	HV_BACKUP_TARGET=local HV_BACKUP_LOCAL_PATH=''
	assert_fail backup_configured
	HV_BACKUP_LOCAL_PATH=/mnt/b
	assert_ok backup_configured
	HV_BACKUP_TARGET=s3 HV_BACKUP_S3_REPO=''
	assert_fail backup_configured
}

test_firewall_rules() {
	HV_ALLOWED_CIDRS='private_ranges 100.64.0.0/10'
	HV_HTTP_PORT=80 HV_HTTPS_PORT=443 HV_ADMIN_PORT=8443 HV_PANEL_PORT=9443
	local out
	out=$(fw_rules)
	local expected='-m conntrack ! --ctstate NEW -j RETURN
-s 10.0.0.0/8 -j RETURN
-s 172.16.0.0/12 -j RETURN
-s 192.168.0.0/16 -j RETURN
-s 127.0.0.0/8 -j RETURN
-s 100.64.0.0/10 -j RETURN
-p tcp -m conntrack --ctorigdstport 80 -j DROP
-p tcp -m conntrack --ctorigdstport 443 -j DROP
-p tcp -m conntrack --ctorigdstport 8443 -j DROP
-p tcp -m conntrack --ctorigdstport 9443 -j DROP
-j RETURN'
	assert_eq "$expected" "$out"
	HV_ALLOWED_CIDRS='192.168.5.0/24 fd00::/8 10.1.1.1 bogus' HV_HTTPS_PORT=80
	out=$(fw_rules)
	assert_contains "$out" '-s 192.168.5.0/24 -j RETURN'
	assert_contains "$out" '-s 10.1.1.1/32 -j RETURN'
	assert_not_contains "$out" 'fd00'
	assert_not_contains "$out" 'bogus'
	assert_eq 1 "$(grep -c 'ctorigdstport 80 ' <<<"$out")" "ports de-duplicated"
}

test_ip_helpers() {
	assert_eq 192.168.1.0/24 "$(cidr_network 192.168.1.77/24)"
	assert_eq 10.0.0.0/8 "$(cidr_network 10.20.30.40/8)"
	assert_eq 10.99.77.1 "$(cidr_first_host 10.99.77.0/24)"
	assert_ok ip_in_cidr 192.168.1.10 192.168.1.0/24
	assert_fail ip_in_cidr 192.168.2.10 192.168.1.0/24
	assert_ok is_ipv4 255.255.255.255
	assert_fail is_ipv4 256.1.1.1
	assert_fail is_ipv4 nas.example.com
	assert_ok is_ipv4_cidr 10.0.0.0/8
	assert_fail is_ipv4_cidr 10.0.0.0/33
}

test_json_helpers() {
	assert_eq 'a\"b\\c\nd\u0001' "$(json_escape $'a"b\\c\nd\x01')"
	local j
	j=$(json_array 'x' 'y"z' '中文')
	json_valid <<<"$j" || fail "json_array invalid: $j"
	assert_eq '["x","y\"z","中文"]' "$j"
}

test_yaml_and_url_helpers() {
	assert_eq '"a\"b\\c"' "$(yaml_dq 'a"b\c')"
	assert_eq '"a$$b"' "$(yaml_dq 'a$b' compose)"
	assert_eq '%E5%A4%96%E9%83%A8/x%20y' "$(urlencode '外部/x y' path)"
	assert_eq 'a%2Fb' "$(urlencode 'a/b')"
}

test_table_width() {
	assert_eq 4 "$(str_width '中文')"
	assert_eq 4 "$(str_width 'ab中')"
	local out
	out=$(printf '名称\tB\n照片归档\tx\n' | print_table)
	assert_contains "$out" '名称     | B'
	assert_contains "$out" '照片归档 | x'
}

test_ddns_yaml() {
	local y
	y=$(ddns_render_yaml alidns 'LTAIxxx' 'se"cret' vpn.example.com)
	assert_contains "$y" 'name: alidns'
	assert_contains "$y" 'id: "LTAIxxx"'
	assert_contains "$y" 'secret: "se\"cret"'
	assert_contains "$y" '- "vpn.example.com"'
	assert_contains "$y" 'url: https://ddns.oray.com/checkip, https://4.ipw.cn'
	assert_contains "$y" 'notallowwanaccess: true'
	if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
		assert_eq 'se"cret' "$(python3 -c 'import yaml,sys; print(yaml.safe_load(sys.stdin)["dnsconf"][0]["dns"]["secret"])' <<<"$y")"
	fi
	assert_ok ddns_valid_domain vpn.example.com
	assert_fail ddns_valid_domain 'bad domain'
}

test_requests_parse() {
	local f=$TMP_ROOT/r.json
	printf '{"type":"backup","id":"1"}' >"$f"
	assert_eq $'backup\t' "$(requests_parse "$f")"
	printf '{"type":"log-retention","days":14}' >"$f"
	assert_eq $'log-retention\t14' "$(requests_parse "$f")"
	printf '{"type":"log-retention","days":0}' >"$f"
	assert_fail requests_parse "$f"
	printf '{"type":"shell","cmd":"rm -rf /"}' >"$f"
	assert_fail requests_parse "$f"
	ln -sf /etc/passwd "$TMP_ROOT/link.json"
	assert_fail requests_parse "$TMP_ROOT/link.json"
}

test_retention_valid() {
	assert_ok retention_valid 1
	assert_ok retention_valid 365
	assert_fail retention_valid 0
	assert_fail retention_valid 366
	assert_fail retention_valid 7d
}

test_expand_allowed_cidrs() {
	assert_eq $'10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16\n127.0.0.0/8' "$(expand_allowed_cidrs private_ranges)"
}

test_systemd_units_render() {
	local HV_ROOT=/opt/homevault HV_BACKUP_TIME=04:15 u out
	for u in "$TESTS_DIR"/../../systemd/*; do
		out=$(systemd_render "$u")
		assert_not_contains "$out" '@HV_' "placeholders substituted in $(basename "$u")"
	done
	out=$(systemd_render "$TESTS_DIR/../../systemd/homevault-backup.timer")
	assert_contains "$out" 'OnCalendar=*-*-* 04:15:00'
	assert_contains "$out" 'Persistent=true'
	out=$(systemd_render "$TESTS_DIR/../../systemd/homevault-backup.service")
	assert_contains "$out" 'ExecStart=/opt/homevault/hv backup'
	HV_ROOT='/opt/home vault'
	assert_fail systemd_render "$TESTS_DIR/../../systemd/homevault-backup.service"
}

test_hv_cli_help_runs() {
	local out
	out=$("$HV_ROOT/hv" help 2>&1) || fail "hv help failed"
	assert_contains "$out" '用法'
	for c in install storage backup restore vpn firewall logs ddns user; do
		out=$("$HV_ROOT/hv" help "$c" 2>&1) || fail "hv help $c failed"
		assert_contains "$out" '用法' "help $c"
	done
	"$HV_ROOT/hv" no-such-cmd >/dev/null 2>&1 && fail "unknown command must fail"
	return 0
}
