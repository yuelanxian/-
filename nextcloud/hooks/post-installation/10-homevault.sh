#!/bin/sh
# HomeVault post-installation hook: one-time initialisation right after the automatic install.
# Security hardening is NOT done here: the before-starting hook runs right after this one (and on
# every later start). Only one-time preferences that users may change later belong here.
set -eu

# shellcheck source=nextcloud/hooks/lib/common.sh
. /opt/homevault/hooks-lib/common.sh
hv_as_www_data "$0"

hv_log "首次安装完成，执行一次性初始化"

umask 077
tmp=$(mktemp "${TMPDIR:-/tmp}/homevault-init.XXXXXX")
trap 'rm -f "$tmp"' EXIT
# No sample files/templates in new accounts: this is an archive, users start with an empty drive.
# Drop the temporary pre-installation config file first, so the import really writes config.php.
rm -f "$HV_NC_ROOT/config/homevault-init.config.php"
cat >"$tmp" <<'EOF'
{
  "system": {
    "skeletondirectory": "",
    "templatedirectory": ""
  }
}
EOF
if hv_occ config:import "$tmp" >/dev/null; then
	hv_log "新用户不再复制示例文件（skeletondirectory 置空）"
else
	hv_warn "设置 skeletondirectory 失败（不影响使用）"
fi

# On an empty instance the expensive repair (mimetype migrations etc.) takes ~1 s and clears the
# "mimetype migrations available" setup warning; on big instances it is opt-in (post-upgrade hook).
if hv_occ maintenance:repair --include-expensive >/dev/null 2>&1; then
	hv_log "已完成 maintenance:repair --include-expensive（新实例，耗时很短）"
else
	hv_warn "maintenance:repair --include-expensive 失败（不影响使用，可稍后手动执行）"
fi

hv_log "管理员账号：${NEXTCLOUD_ADMIN_USER:-?}（首次登录时需绑定两步验证 TOTP）"
exit 0
