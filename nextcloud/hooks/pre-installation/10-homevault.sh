#!/bin/sh
# HomeVault pre-installation hook: runs once, right before `occ maintenance:install`.
# - Checks that the data directory is writable by www-data (clear message instead of a cryptic install error).
# - No skeleton/sample files, not even for the admin account the installer creates: a temporary
#   config/homevault-init.config.php is merged by the installer; post-installation removes it.
# - Windows (Docker Desktop, NTFS bind mount): chmod has no effect there, so Nextcloud's data-directory
#   permission check would always fail → write config/datadir.permission.config.php (same as Nextcloud AIO).
set -eu

# shellcheck source=nextcloud/hooks/lib/common.sh
. /opt/homevault/hooks-lib/common.sh
hv_as_www_data "$0"

datadir=${NEXTCLOUD_DATA_DIR:-/var/www/data}
if [ ! -d "$datadir" ] || [ ! -w "$datadir" ]; then
	hv_err "数据目录 $datadir 不存在或 www-data (uid 33) 无写权限。"
	hv_err "Linux 请在宿主机执行：sudo chown -R 33:33 <HV_NC_DATA_PATH> && sudo chmod 0750 <HV_NC_DATA_PATH>"
	exit 1
fi

umask 027

# write_config <file> <php body>: atomic write of a small config file
write_config() {
	printf '%s\n' "$2" >"$1.tmp.$$"
	mv -f "$1.tmp.$$" "$1"
}

write_config "$HV_NC_ROOT/config/homevault-init.config.php" "<?php
// HomeVault: temporary file, removed by the post-installation hook.
\$CONFIG = array (
  'skeletondirectory' => '',
  'templatedirectory' => '',
);"

case "${HV_PLATFORM:-linux}" in
windows)
	cfg="$HV_NC_ROOT/config/datadir.permission.config.php"
	write_config "$cfg" "<?php
// HomeVault: Docker Desktop (Windows) NTFS bind mount — chmod has no effect there,
// so Nextcloud's data directory permission check cannot pass. See config.sample.php.
\$CONFIG = array (
  'check_data_directory_permissions' => false,
);"
	hv_log "Windows 平台：已写入 $cfg（check_data_directory_permissions=false）"
	;;
*)
	hv_log "安装前检查通过（数据目录 $datadir 可写）"
	;;
esac
exit 0
