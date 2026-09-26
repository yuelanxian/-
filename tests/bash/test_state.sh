# shellcheck shell=bash disable=SC2034,SC2016,SC2329 # test globals are read by the sourced modules
# Host → panel status files (canonical shapes = panel/internal/hoststate/types.go), request runner, log retention.

# json_keys_ok FILE PYTHON_CHECK — the check gets d (parsed JSON) and must evaluate to True
json_check() {
	command -v python3 >/dev/null || return 0
	local file=$1 expr=$2 out
	out=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); print($expr)" "$file" 2>&1) ||
		fail "invalid JSON in $file: $out"
	[[ $out == True ]] || fail "check failed on $(basename "$file"): $expr → $out ($(head -c 600 "$file"))"
}

_state_env() {
	HV_STATE_DIR=$TMP_ROOT/state-$RANDOM
	mkdir -p "$HV_STATE_DIR"
	HV_PLATFORM=linux HV_VPN_ENABLED=false
	HV_DATA_DIR=$TMP_ROOT HV_NC_DATA_PATH=$TMP_ROOT HV_LOG_DIR=$TMP_ROOT/logs HV_LOG_RETENTION_DAYS=14
	HV_BACKUP_TARGET=local HV_BACKUP_LOCAL_PATH=$TMP_ROOT/not-mounted HV_BACKUP_TIME=03:30
	HV_STORAGE_CONF=$TMP_ROOT/state-storage.conf
	printf '照片 "归档"|%s|rw|yes|\n' "$TMP_ROOT" >"$HV_STORAGE_CONF"
}

test_status_json_canonical() {
	_state_env
	printf '2026-09-26T00:10:00+08:00\ntrue\n每日维护完成\n' >"$HV_STATE_DIR/maintenance.last"
	printf '2026-09-26T10:00:00+08:00\n' >"$HV_STATE_DIR/requests.last"
	status_write_json
	local f=$HV_STATE_DIR/status.json
	[[ -f $f ]] || {
		fail "status.json not written"
		return
	}
	assert_eq 644 "$(stat -c %a "$f")"
	json_check "$f" "set(d) == {'updated','version','platform','hostname','log_retention_days','log_dir','maintenance','requests','disks'}"
	json_check "$f" "d['platform'] == 'linux' and d['version'] == 'test' and d['log_retention_days'] == 14"
	json_check "$f" "d['maintenance'] == {'last_run':'2026-09-26T00:10:00+08:00','ok':True,'message':'每日维护完成'}"
	json_check "$f" "d['requests'] == {'last_run':'2026-09-26T10:00:00+08:00'}"
	json_check "$f" "[x['role'] for x in d['disks']] == ['data','storage','backup','system']"
	json_check "$f" "all(set(x) == {'role','name','path','total','free','mounted'} for x in d['disks'])"
	json_check "$f" "d['disks'][0]['total'] > 0 and d['disks'][0]['mounted'] is True and d['disks'][1]['name'] == '照片 \"归档\"'"
	json_check "$f" "d['disks'][2]['mounted'] is False and d['disks'][2]['total'] == 0"
	# never written maintenance → nulls
	rm -f "$HV_STATE_DIR/maintenance.last" "$HV_STATE_DIR/requests.last"
	HV_LOG_RETENTION_DAYS=bogus
	status_write_json
	json_check "$f" "d['maintenance'] == {'last_run':None,'ok':None,'message':''} and d['requests']['last_run'] is None"
	json_check "$f" "d['log_retention_days'] == 7"
}

_snapshots_fixture() {
	printf '[{"time":"2026-09-25T03:30:01.1+08:00","tree":"aa","paths":["/src/dumps"],"hostname":"homevault","username":"root","tags":["homevault"],"program_version":"restic 0.19.1","summary":{"backup_start":"x","backup_end":"y","files_new":1,"files_changed":2,"files_unmodified":3,"dirs_new":0,"dirs_changed":1,"dirs_unmodified":0,"data_blobs":1,"tree_blobs":1,"data_added":10,"data_added_packed":9,"total_files_processed":6,"total_bytes_processed":600},"id":"%s","short_id":"1111aaaa"},' "$(printf '1%.0s' {1..64})"
	printf '{"time":"2026-09-26T03:30:01.1+08:00","tree":"bb","paths":["/src/dumps"],"hostname":"homevault","username":"root","tags":["homevault"],"program_version":"restic 0.19.1","summary":{"backup_start":"x","backup_end":"y","files_new":12,"files_changed":3,"files_unmodified":0,"dirs_new":0,"dirs_changed":1,"dirs_unmodified":0,"data_blobs":1,"tree_blobs":1,"data_added":104857600,"data_added_packed":9,"total_files_processed":120000,"total_bytes_processed":812345678901},"id":"%s","short_id":"2222bbbb"}]\n' "$(printf '2%.0s' {1..64})"
}

test_backup_status_canonical() {
	_state_env
	local f=$HV_STATE_DIR/backup-status.json started
	started=$(($(date +%s) - 90))
	backup_write_status running 0 "备份进行中" "$started" backup/backup-1.log
	json_check "$f" "d['state'] == 'running' and d['last_finished'] is None and 'exit_code' not in d and d['last_success'] is None"
	_snapshots_fixture >"$HV_STATE_DIR/snapshots.json"
	date -Iseconds >"$HV_STATE_DIR/last-backup-ok"
	backup_write_status ok 0 "备份成功" "$started" backup/backup-1.log 2222bbbb
	json_check "$f" "set(d) <= {'updated','state','last_run','last_finished','last_success','duration_seconds','message','log_file','target','repository','schedule','next_run','exit_code','stats'}"
	json_check "$f" "d['state'] == 'ok' and d['exit_code'] == 0 and d['log_file'] == 'backup/backup-1.log' and d['target'] == 'local'"
	json_check "$f" "90 <= d['duration_seconds'] <= 100 and all(d[k] for k in ('last_success','last_finished','last_run'))"
	json_check "$f" "d['stats'] == {'files_new':12,'files_changed':3,'data_added':104857600,'total_files_processed':120000,'total_bytes_processed':812345678901}"
	json_check "$f" "d['repository'] == '$TMP_ROOT/not-mounted' and d['schedule'] == '' and d['next_run'] is None"
	backup_write_status failed 1 '备份目录不存在："x"' "$started" backup/backup-2.log ffffffff
	json_check "$f" "d['state'] == 'failed' and d['exit_code'] == 1 and d['message'] == '备份目录不存在：\"x\"' and 'stats' not in d"
	assert_eq '' "$(backup_stats_json "$HV_STATE_DIR/snapshots.json" 'not-an-id')"
}

test_vpn_status_render() {
	local conf dump out f=$TMP_ROOT/vpn.json
	conf=$'# Client: 妈妈的手机 (1)\nPublicKey = PUB1=\n# Client: laptop "x" (2)\nPublicKey = PUB2=\nPublicKey = ORPHAN='
	dump=$'51820\nPUB1=\t203.0.113.9:40000\t10.99.77.2/32\t1790388000\t1048576\t2097152\nPUB2=\t(none)\t10.99.77.3/32\t0\t0\t0\r\nORPHAN=\t(none)\t10.99.77.4/32\t0\t0\t0'
	vpn_render_status "$conf" "$dump" >"$f"
	json_check "$f" "set(d) == {'updated','platform','interface','listen_port','peers'} and d['listen_port'] == 51820 and d['interface'] == 'wg0'"
	json_check "$f" "d['peers'][0] == {'name':'妈妈的手机','address':'10.99.77.2/32','enabled':True,'latest_handshake':1790388000,'rx_bytes':1048576,'tx_bytes':2097152,'endpoint':'203.0.113.9:40000'}"
	json_check "$f" "d['peers'][1]['name'] == 'laptop \"x\"' and 'endpoint' not in d['peers'][1] and d['peers'][1]['tx_bytes'] == 0"
	json_check "$f" "d['peers'][2]['name'] == '未命名设备' and len(d['peers']) == 3"
	out=$(cat "$f")
	assert_not_contains "$out" 'PUB1' "no key material in vpn-status.json"
}

# fake command implementations for the runner
_req_mocks() {
	cmd_backup() {
		echo "backup ran" >>"$TMP_ROOT/req-calls"
		[[ ${REQ_BACKUP_FAIL:-0} == 0 ]] || die "备份目录不存在：/mnt/usb"
	}
	logs_retention() {
		echo "retention $1" >>"$TMP_ROOT/req-calls"
	}
	logs_clean() {
		echo "clean" >>"$TMP_ROOT/req-calls"
		HV_LOGS_CLEANED=3
	}
	status_write_json() { :; }
	hv_log() { :; }
}

test_requests_runner() {
	_state_env
	_req_mocks
	local r=$HV_STATE_DIR/requests d
	d=$r/done
	rm -f "$TMP_ROOT/req-calls"
	mkdir -p "$r"
	printf '{\n  "id": "20260926T101500123Z-log-retention",\n  "type": "log-retention",\n  "days": 14\n}\n' >"$r/20260926T101500123Z-log-retention.json"
	printf '{"type":"backup"}' >"$r/20260926T101501000Z-backup.json"
	printf '{"type":"log-clean"}' >"$r/20260926T101502000Z-log-clean.json"
	printf '{"type":"shell","cmd":"id"}' >"$r/20260926T101503000Z-shell.json"
	printf '{"type":"log-retention","days":999}' >"$r/20260926T101504000Z-log-retention.json"
	printf '{"type":"backup"}' >"$r/.tmp-20260926T101505000Z-backup.json"
	ln -s /etc/passwd "$r/20260926T101506000Z-backup.json"
	(requests_process_all) >/dev/null 2>&1 || fail "runner failed"
	assert_eq $'retention 14\nbackup ran\nclean' "$(cat "$TMP_ROOT/req-calls" 2>/dev/null)" "only valid requests executed, in order"
	json_check "$d/20260926T101500123Z-log-retention.result.json" "d['ok'] is True and d['type'] == 'log-retention' and d['id'] == '20260926T101500123Z-log-retention' and d['request'] == '20260926T101500123Z-log-retention.json' and d['finished'] and '14' in d['message']"
	json_check "$d/20260926T101501000Z-backup.result.json" "d['ok'] is True and d['type'] == 'backup'"
	json_check "$d/20260926T101502000Z-log-clean.result.json" "d['ok'] is True and '3' in d['message']"
	json_check "$d/20260926T101503000Z-shell.result.json" "d['ok'] is False and d['type'] == 'unknown'"
	json_check "$d/20260926T101504000Z-log-retention.result.json" "d['ok'] is False"
	json_check "$d/20260926T101506000Z-backup.result.json" "d['ok'] is False"
	[[ -e $d/20260926T101500123Z-log-retention.json ]] || fail "request not moved into done/"
	[[ -e $r/.tmp-20260926T101505000Z-backup.json ]] || fail "temporary (dot) files must be left alone"
	[[ -z $(find "$r" -maxdepth 1 -name '2*.json') ]] || fail "requests left behind"
	# a failing request reports the error message
	REQ_BACKUP_FAIL=1
	printf '{"type":"backup"}' >"$r/20260926T101600000Z-backup.json"
	(requests_process_all) >/dev/null 2>&1 || fail "runner failed (2)"
	json_check "$d/20260926T101600000Z-backup.result.json" "d['ok'] is False and '/mnt/usb' in d['message']"
}

test_requests_done_symlink_is_replaced() {
	_state_env
	_req_mocks
	local r=$HV_STATE_DIR/requests evil=$TMP_ROOT/evil-$RANDOM
	mkdir -p "$r" "$evil"
	ln -s "$evil" "$r/done"
	printf '{"type":"log-clean"}' >"$r/20260926T101502000Z-log-clean.json"
	(requests_process_all) >/dev/null 2>&1 || fail "runner failed"
	[[ -d $r/done && ! -L $r/done ]] || fail "done/ must be a real directory"
	[[ -z $(ls -A "$evil") ]] || fail "nothing may be written through the symlink: $(ls -A "$evil")"
	[[ -f $r/done/20260926T101502000Z-log-clean.result.json ]] || fail "result missing"
}

test_logs_clean_retention() {
	local HV_LOG_DIR=$TMP_ROOT/lc-$RANDOM HV_LOG_RETENTION_DAYS=7 f
	mkdir -p "$HV_LOG_DIR"/{homevault,caddy,nextcloud,containers,backup}
	for f in homevault/hv-2020-01-01.log containers/app-2020-01-01.log backup/backup-20200101-033000.log \
		caddy/access-2020-01-01T00-00-00.000.log.gz nextcloud/nextcloud.log.1 homevault/old.txt \
		caddy/access.log nextcloud/nextcloud.log nextcloud/audit.log homevault/keep.conf; do
		echo x >"$HV_LOG_DIR/$f"
		touch -d '10 days ago' "$HV_LOG_DIR/$f"
	done
	echo new >"$HV_LOG_DIR/homevault/hv-today.log"
	touch -d '6 days ago' "$HV_LOG_DIR/containers/app-recent.log"
	logs_clean >/dev/null
	assert_eq 6 "$HV_LOGS_CLEANED"
	for f in caddy/access.log nextcloud/nextcloud.log nextcloud/audit.log homevault/keep.conf homevault/hv-today.log containers/app-recent.log; do
		[[ -f $HV_LOG_DIR/$f ]] || fail "must be kept: $f"
	done
	[[ -e $HV_LOG_DIR/homevault/hv-2020-01-01.log ]] && fail "old log not deleted"
	HV_LOG_RETENTION_DAYS=5
	logs_clean >/dev/null
	[[ -e $HV_LOG_DIR/containers/app-recent.log ]] && fail "6-day-old log must go with 5 days retention"
	return 0
}

test_logs_rotate_nextcloud() {
	local HV_LOG_DIR=$TMP_ROOT/lr-$RANDOM y t
	y=$(date -d yesterday +%F)
	t=$(date +%F)
	mkdir -p "$HV_LOG_DIR/nextcloud"
	printf '{"reqId":"a","level":1,"time":"%sT23:59:00+08:00","message":"old"}\n' "$y" >"$HV_LOG_DIR/nextcloud/nextcloud.log"
	printf '{"reqId":"b","level":1,"time":"%sT00:01:00+08:00","message":"today"}\n' "$t" >"$HV_LOG_DIR/nextcloud/audit.log"
	logs_rotate_nextcloud
	[[ -f $HV_LOG_DIR/nextcloud/nextcloud-$y.log && ! -e $HV_LOG_DIR/nextcloud/nextcloud.log ]] || fail "nextcloud.log not rotated"
	[[ -f $HV_LOG_DIR/nextcloud/audit.log ]] || fail "a log that starts today must not be rotated"
	# a second file for the same day never overwrites the first one
	printf '{"time":"%sT23:59:59+08:00"}\n' "$y" >"$HV_LOG_DIR/nextcloud/nextcloud.log"
	logs_rotate_nextcloud
	assert_contains "$(cat "$HV_LOG_DIR/nextcloud/nextcloud-$y.log")" '"old"'
	[[ -f $HV_LOG_DIR/nextcloud/nextcloud-$y.2.log ]] || fail "second rotation must get a numbered name"
	# unparsable content: falls back to the modification date
	echo 'plain text' >"$HV_LOG_DIR/nextcloud/nextcloud.log"
	touch -d '3 days ago' "$HV_LOG_DIR/nextcloud/nextcloud.log"
	logs_rotate_nextcloud
	[[ -f $HV_LOG_DIR/nextcloud/nextcloud-$(date -d '3 days ago' +%F).log ]] || fail "mtime fallback"
}

test_env_new_keys_and_ports() {
	HV_ENV_FILE=$TMP_ROOT/nk-$RANDOM.env
	printf 'HV_DATA_DIR=/srv/hv\nHV_LOG_DIR=\n' >"$HV_ENV_FILE"
	HV_DATA_DIR=/srv/hv HV_LOG_DIR='' HV_PANEL_PORT=9443 HV_LOG_RETENTION_DAYS=7
	hv_ensure_env_keys
	assert_eq /srv/hv/logs "$(env_get_file HV_LOG_DIR "$HV_ENV_FILE")"
	assert_eq 9443 "$(env_get_file HV_PANEL_PORT "$HV_ENV_FILE")"
	assert_eq 7 "$(env_get_file HV_LOG_RETENTION_DAYS "$HV_ENV_FILE")"
	HV_PANEL_PORT=19443
	hv_ensure_env_keys
	assert_eq 9443 "$(env_get_file HV_PANEL_PORT "$HV_ENV_FILE")" "existing values are never changed"
	HV_HOST=192.168.1.10 HV_TLS_MODE=internal HV_HTTP_PORT=80 HV_HTTPS_PORT=443 HV_ADMIN_PORT=8443 HV_PANEL_PORT=9443
	assert_ok hv_validate_env
	HV_PANEL_PORT=443
	assert_fail hv_validate_env
	HV_PANEL_PORT=9443 HV_LOG_RETENTION_DAYS=0
	assert_fail hv_validate_env
	assert_eq 'https://192.168.1.10:9443' "$(hv_panel_url)"
}

test_panel_src_hash_changes() {
	local HV_ROOT=$TMP_ROOT/ph-$RANDOM a b
	mkdir -p "$HV_ROOT/panel/cmd" "$HV_ROOT/panel/internal/x" "$HV_ROOT/panel/web"
	echo 'FROM scratch' >"$HV_ROOT/panel/Dockerfile"
	echo 'module x' >"$HV_ROOT/panel/go.mod"
	echo 'package main' >"$HV_ROOT/panel/cmd/main.go"
	a=$(panel_src_hash)
	[[ $a =~ ^[0-9a-f]{64}$ ]] || fail "bad hash: $a"
	echo 'package x // test' >"$HV_ROOT/panel/internal/x/x_test.go"
	assert_eq "$a" "$(panel_src_hash)" "tests do not change the image"
	echo '/* */' >"$HV_ROOT/panel/web/app.css"
	b=$(panel_src_hash)
	[[ $a != "$b" ]] || fail "web change must change the hash"
	HV_MIRROR_HUB=docker.m.daocloud.io/
	[[ $(panel_src_hash) != "$b" ]] || fail "registry prefix must change the hash"
}
