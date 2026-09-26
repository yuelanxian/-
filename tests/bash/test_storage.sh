# shellcheck shell=bash disable=SC2034,SC2016 # test globals are read by the sourced modules
# storage: slug, storage.conf, compose.storage.yaml, lsblk parsing, applicable args

test_slug_vectors() {
	# printf '%s' 'D:\Photos' | sha256sum → ea173462…  (shared vector with the PowerShell implementation)
	assert_eq sea173462 "$(storage_slug 'D:\Photos')"
	assert_eq s24d68919 "$(storage_slug '/mnt/photos')"
	local expected
	expected=s$(printf '%s' '/mnt/影视 资料' | sha256sum | cut -c1-8)
	assert_eq "$expected" "$(storage_slug '/mnt/影视 资料')" "utf-8 path"
}

test_storage_parse_valid() {
	HV_PLATFORM=linux
	storage_parse_conf "$FIXTURES/storage-valid.conf" || fail "parse returned error"
	assert_eq 3 "${#ST_NAME[@]}" "row count"
	assert_eq '照片归档' "${ST_NAME[0]}"
	assert_eq '/mnt/photos' "${ST_PATH[0]}"
	assert_eq rw "${ST_MODE[0]}"
	assert_eq yes "${ST_BACKUP[0]}"
	assert_eq '' "${ST_USERS[0]}"
	assert_eq '影视资料' "${ST_NAME[1]}"
	assert_eq '/mnt/media/影视 资料' "${ST_PATH[1]}"
	assert_eq ro "${ST_MODE[1]}" "mode lower-cased"
	assert_eq 'alice,@family' "${ST_USERS[1]}" "spaces removed from users"
	assert_eq 'Work$Dir' "${ST_NAME[2]}"
	assert_eq s24d68919 "${ST_SLUG[0]}"
}

test_storage_parse_invalid_reports_lines() {
	HV_PLATFORM=linux
	local out
	out=$(storage_parse_conf "$FIXTURES/storage-invalid.conf" 2>&1) && fail "expected failure"
	assert_contains "$out" '第 2 行'
	assert_contains "$out" '第 3 行'
	assert_contains "$out" '名称重复'
	assert_contains "$out" '路径重复'
	assert_contains "$out" '第 6 行：字段过多'
	assert_contains "$out" '第 7 行'
	storage_parse_conf "$FIXTURES/storage-invalid.conf" 2>/dev/null
	assert_eq 1 "${#ST_NAME[@]}" "only the valid row is kept"
}

test_storage_windows_paths_accepted() {
	HV_PLATFORM=windows
	local f=$TMP_ROOT/win.conf
	printf '\xef\xbb\xbf照片归档|D:\\Photos|rw|no|\r\n影视资料|E:\\Movies|ro|no|@family\r\n' >"$f"
	storage_parse_conf "$f" || fail "parse failed"
	assert_eq '照片归档' "${ST_NAME[0]}" "BOM stripped"
	assert_eq 'D:\Photos' "${ST_PATH[0]}"
	assert_eq sea173462 "${ST_SLUG[0]}"
	assert_eq '@family' "${ST_USERS[1]}" "CR stripped"
}

test_storage_render_compose() {
	HV_PLATFORM=linux
	HV_NC_DATA_PATH=/srv/hv/nextcloud-data HV_BACKUP_TARGET=local HV_BACKUP_LOCAL_PATH=/mnt/backup/hv
	HV_STORAGE_CONF=$FIXTURES/storage-valid.conf
	storage_parse_conf "$FIXTURES/storage-valid.conf"
	local y
	y=$(storage_render_compose 1 1 0)
	assert_contains "$y" 'target: "/mnt/hv/s24d68919"'
	assert_contains "$y" 'source: "/mnt/media/影视 资料"'
	assert_contains "$y" 'source: "/mnt/a \"quoted\"/$$HOME"'
	assert_contains "$y" '  backup:'
	assert_contains "$y" 'target: "/src/storage/s24d68919"'
	assert_not_contains "$y" "/src/storage/$(storage_slug '/mnt/media/影视 资料')" "backup=no row not in backup"
	assert_contains "$y" 'target: "/stat/backup"'
	assert_contains "$y" 'target: "/config/storage.conf"'
	assert_contains "$y" 'create_host_path: false'
	assert_contains "$y" 'target: "/stat/data"'
	assert_contains "$y" 'target: "/stat/storage/s24d68919"'
	# no storage + no panel → nothing
	ST_NAME=() ST_PATH=() ST_MODE=() ST_BACKUP=() ST_USERS=() ST_SLUG=()
	assert_eq '' "$(storage_render_compose 1 0)"
}

test_storage_render_validates_with_compose() {
	have_compose || return 0
	HV_PLATFORM=linux
	HV_NC_DATA_PATH=/srv/hv/nextcloud-data HV_BACKUP_TARGET=local HV_BACKUP_LOCAL_PATH=/mnt/backup/hv
	HV_STORAGE_CONF=$FIXTURES/storage-valid.conf
	storage_parse_conf "$FIXTURES/storage-valid.conf"
	local d=$TMP_ROOT/cs out
	mkdir -p "$d"
	cp "$FIXTURES/compose-minimal.yaml" "$d/compose.yaml"
	printf 'HV_NC_DATA_PATH=/srv/hv/nextcloud-data\nHV_DUMP_DIR=/srv/hv/dumps\n' >"$d/.env"
	storage_render_compose 1 1 0 >"$d/compose.storage.yaml"
	out=$(docker compose --project-directory "$d" -f "$d/compose.yaml" -f "$d/compose.storage.yaml" --env-file "$d/.env" -p t config 2>&1) ||
		fail "compose config rejected the rendered file: $out"
	assert_contains "$out" 'target: /mnt/hv/s24d68919'
	assert_contains "$out" 'target: /src/storage/s24d68919'
	# read-only row is read_only in app
	command -v python3 >/dev/null || return 0
	out=$(docker compose --project-directory "$d" -f "$d/compose.yaml" -f "$d/compose.storage.yaml" --env-file "$d/.env" -p t config --format json)
	assert_eq True "$(json_get "any(v['target']=='/mnt/hv/$(storage_slug '/mnt/media/影视 资料')' and v.get('read_only') for v in d['services']['app']['volumes'])" <<<"$out")" "ro mount"
	assert_eq True "$(json_get "any(v['target']=='/mnt/hv/s24d68919' and not v.get('read_only') for v in d['services']['cron']['volumes'])" <<<"$out")" "rw mount"
	assert_eq True "$(json_get "any(v['source']=='/mnt/a \"quoted\"/\$\$HOME' for v in d['services']['app']['volumes'])" <<<"$out")" "quoted path with literal \$"
}

test_storage_render_panel_skips_missing_sources() {
	HV_PLATFORM=linux HV_BACKUP_TARGET=local
	local d=$TMP_ROOT/pstat y
	mkdir -p "$d/data" "$d/photos"
	HV_NC_DATA_PATH=$d/data HV_BACKUP_LOCAL_PATH=$d/usb-not-plugged
	HV_STORAGE_CONF=$d/storage.conf
	printf '照片|%s|rw|yes|\n缺失|%s|ro|no|\n' "$d/photos" "$d/missing" >"$HV_STORAGE_CONF"
	storage_parse_conf "$HV_STORAGE_CONF"
	y=$(storage_render_compose 1 1)
	assert_contains "$y" 'target: "/stat/data"'
	assert_contains "$y" "target: \"/stat/storage/$(storage_slug "$d/photos")\""
	assert_not_contains "$y" '/stat/backup' "missing backup target not mounted into the panel"
	assert_not_contains "$y" "/stat/storage/$(storage_slug "$d/missing")"
	assert_contains "$y" "target: \"/mnt/hv/$(storage_slug "$d/missing")\"" "app/cron keep every configured storage"
	# panel only (no storages, nothing exists) → no empty "volumes:" key
	ST_NAME=() ST_PATH=() ST_MODE=() ST_BACKUP=() ST_USERS=() ST_SLUG=()
	HV_NC_DATA_PATH=$d/nope HV_STORAGE_CONF=$d/none.conf
	assert_eq '' "$(storage_render_compose 1 1)"
	# slug vector shared with Windows (SPEC: 'D:\Photos' → sea173462)
	assert_eq sea173462 "$(storage_slug 'D:\Photos')"
}

test_storage_render_file_changes() {
	HV_PLATFORM=linux HV_NC_DATA_PATH='' HV_BACKUP_LOCAL_PATH=''
	HV_STORAGE_CONF=$TMP_ROOT/rf.conf
	HV_STORAGE_COMPOSE=$TMP_ROOT/rf.yaml
	local HV_ROOT=$TMP_ROOT/rfroot
	mkdir -p "$HV_ROOT"
	cp "$FIXTURES/compose-minimal.yaml" "$HV_ROOT/compose.yaml"
	sed -i '/^  panel:/,/^    image: busybox/d' "$HV_ROOT/compose.yaml"
	printf 'a|/mnt/a|rw|no|\n' >"$HV_STORAGE_CONF"
	storage_render_file || fail "first render should report change"
	storage_render_file && fail "second render should report no change"
	assert_contains "$(cat "$HV_STORAGE_COMPOSE")" '/mnt/hv/'
	: >"$HV_STORAGE_CONF"
	storage_render_file || fail "emptying should report change"
	[[ -e $HV_STORAGE_COMPOSE ]] && fail "file should be removed when no storages"
	return 0
}

test_compose_services_scan() {
	local out
	out=$(compose_services "$FIXTURES/compose-minimal.yaml" | paste -sd' ' -)
	assert_eq 'app cron backup panel' "$out"
}

test_lsblk_parse_fixture() {
	lsblk_parse <"$FIXTURES/lsblk.txt"
	assert_eq 11 "${#BLK_NAMES[@]}" "device count"
	assert_eq sda "$(blk_disk_of sda1)"
	assert_eq sdb "$(blk_disk_of hvbackup)" "crypt → partition → disk"
	assert_eq nvme0n1 "$(blk_disk_of nvme0n1p2)"
	assert_eq 'My Backup' "${BLK_LABEL[hvbackup]}" "\\x20 decoded"
	assert_eq 'U"SB' "${BLK_LABEL[sdc1]}" "\\x22 decoded"
	assert_eq '/media/u盘' "${BLK_MP[sdc1]}"
	assert_eq exfat "${BLK_FS[sdc1]}"
	assert_eq SSD "$(blk_kind nvme0n1p2)"
	assert_eq HDD "$(blk_kind sda1)"
	assert_ok blk_is_usb hvbackup
	assert_fail blk_is_usb sda1
	assert_eq 2000397795328 "${BLK_SIZE[sda1]}"
}

test_storage_applicable_args() {
	local out
	out=$(storage_applicable_args 'alice,@family' '' '' | sort | paste -sd' ' -)
	assert_eq '--add-group --add-user alice family' "$out"
	out=$(storage_applicable_args '' 'alice' '')
	assert_eq '--remove-all' "$out"
	out=$(storage_applicable_args '' '' '')
	assert_eq '' "$out"
	out=$(storage_applicable_args 'alice' 'alice,bob' 'family' | paste -sd' ' -)
	assert_contains "$out" '--remove-user bob'
	assert_contains "$out" '--remove-group family'
	assert_not_contains "$out" '--add-user'
}

test_restore_override_merges_rw() {
	have_compose || return 0
	command -v python3 >/dev/null || return 0
	HV_PLATFORM=linux HV_VPN_ENABLED=true
	HV_VOL_HTML=/srv/hv/nextcloud-html HV_NC_DATA_PATH=/srv/hv/nextcloud-data HV_VOL_CADDY_DATA='' HV_DUMP_DIR=/srv/hv/dumps HV_VOL_WGEASY=''
	local d=$TMP_ROOT/ro out
	mkdir -p "$d"
	cp "$FIXTURES/compose-minimal.yaml" "$d/compose.yaml"
	printf 'HV_VOL_HTML=/srv/hv/nextcloud-html\nHV_NC_DATA_PATH=/srv/hv/nextcloud-data\nHV_DUMP_DIR=/srv/hv/dumps\n' >"$d/.env"
	restore_render_override >"$d/override.yaml"
	out=$(docker compose --project-directory "$d" -f "$d/compose.yaml" -f "$d/override.yaml" --env-file "$d/.env" -p t config --format json 2>&1) ||
		{
			fail "compose config failed: $out"
			return
		}
	local t
	for t in /src/nextcloud-html /src/nextcloud-data /src/caddy-data /src/dumps /src/wg-easy; do
		assert_eq False "$(json_get "any(v['target']=='$t' and v.get('read_only') for v in d['services']['backup']['volumes'])" <<<"$out")" "$t writable"
		assert_eq 1 "$(json_get "sum(1 for v in d['services']['backup']['volumes'] if v['target']=='$t')" <<<"$out")" "$t once"
	done
	assert_eq True "$(json_get "any(v['target']=='/src/project' and v.get('read_only') for v in d['services']['backup']['volumes'])" <<<"$out")" "project stays ro"
	assert_eq volume "$(json_get "[v['type'] for v in d['services']['backup']['volumes'] if v['target']=='/src/caddy-data'][0]" <<<"$out")"
}

test_restore_norm_path() {
	assert_eq /src/nextcloud-data/alice/files/照片 "$(restore_norm_path 'alice/files/照片/')"
	assert_eq /src/caddy-data "$(restore_norm_path /src/caddy-data)"
}

test_storage_render_scrutiny_devices() {
	HV_PLATFORM=linux HV_NC_DATA_PATH='' HV_BACKUP_LOCAL_PATH='' HV_STORAGE_CONF=$TMP_ROOT/none-scrutiny.conf
	ST_NAME=() ST_PATH=() ST_MODE=() ST_BACKUP=() ST_USERS=() ST_SLUG=()
	local y HV_MONITOR_ENABLED=false HV_SCRUTINY_DEVICES='/dev/sda /dev/nvme0'
	assert_eq '' "$(storage_render_compose 1 1 0 1)" "monitor disabled → no devices"
	HV_MONITOR_ENABLED=true
	y=$(storage_render_compose 1 1 0 1 2>/dev/null)
	assert_contains "$y" $'  scrutiny:\n    devices:\n      - "/dev/sda:/dev/sda"\n      - "/dev/nvme0:/dev/nvme0"'
	HV_SCRUTINY_DEVICES='/dev/../etc/shadow sda /dev/null'
	y=$(storage_render_compose 1 1 1 1 2>/dev/null)
	assert_eq $'# 由 hv storage apply 根据 storage.conf 自动生成，请勿手动编辑（重新生成会覆盖）\nservices:\n  scrutiny:\n    devices:\n      - "/dev/null:/dev/null"' "$y" "invalid names dropped, existing device kept"
	HV_SCRUTINY_DEVICES='/dev/hv-does-not-exist'
	assert_eq '' "$(storage_render_compose 1 1 1 1 2>/dev/null)" "missing device skipped"
}

test_storage_path_guard() {
	HV_PLATFORM=linux HV_BACKUP_TARGET=local
	local HV_DATA_DIR=/mnt/disk1/homevault HV_NC_DATA_PATH=/mnt/disk1/homevault/nextcloud-data
	local HV_VOL_CADDY_DATA=/mnt/disk1/homevault/caddy-data HV_VOL_DB=/mnt/disk1/homevault/postgres
	local HV_BACKUP_LOCAL_PATH=/mnt/usb/restic HV_LOG_DIR=/mnt/disk1/homevault/logs HV_DUMP_DIR=/mnt/disk1/homevault/dumps
	local p
	for p in / /etc /etc/ssh /var/lib/docker/volumes /proc /root/x "$HV_ROOT" "$HV_ROOT/secrets" "${HV_ROOT%/*}" \
		/mnt/disk1/homevault /mnt/disk1 /mnt /mnt/disk1/homevault/caddy-data/caddy /mnt/disk1/homevault/postgres \
		/mnt/usb /mnt/usb/restic/data /mnt/disk1/homevault/nextcloud-data/alice /mnt/disk1/homevault/../homevault/caddy-data \
		/mnt/disk1/homevault/logs/panel /mnt/disk1/homevault/dumps; do
		storage_path_problem "$p" >/dev/null || fail "must be refused: $p"
	done
	for p in /mnt/disk1/照片 /mnt/disk1/homevault/extra-photos /srv/media /home/alice/Pictures /mnt/usb2; do
		if storage_path_problem "$p" >/dev/null; then fail "must be allowed: $p ($(storage_path_problem "$p"))"; fi
	done
	# enforced when storage.conf is parsed (hand-edited file)
	printf '密钥|%s|ro|no|\n照片|/mnt/disk1/照片|rw|no|\n' "$HV_VOL_CADDY_DATA" >"$TMP_ROOT/guard.conf"
	assert_fail storage_parse_conf "$TMP_ROOT/guard.conf"
	storage_parse_conf "$TMP_ROOT/guard.conf" 2>/dev/null || true
	assert_eq '照片' "${ST_NAME[*]}" "only the allowed row is kept"
	# Windows paths are validated by hv.ps1
	HV_PLATFORM=windows
	printf '系统|C:\\Windows|ro|no|\n' >"$TMP_ROOT/guard-win.conf"
	assert_ok storage_parse_conf "$TMP_ROOT/guard-win.conf"
}
