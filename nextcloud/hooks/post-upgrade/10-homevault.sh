#!/bin/sh
# HomeVault post-upgrade hook: runs after the entrypoint's `occ upgrade` (image major/minor update).
# Adds DB indices/columns/primary keys that new versions expect (setup checks warn otherwise).
# `occ maintenance:repair --include-expensive` can take a very long time on large instances and is
# therefore skipped unless HV_REPAIR_EXPENSIVE=true (or run it later: ./hv occ maintenance:repair --include-expensive).
# Never blocks the container start: failures are logged only.
set -eu

# shellcheck source=nextcloud/hooks/lib/common.sh
. /opt/homevault/hooks-lib/common.sh
hv_as_www_data "$0"

t0=$(hv_now_ms)
hv_log "升级完成，补齐数据库索引/列/主键"
for cmd in db:add-missing-indices db:add-missing-columns db:add-missing-primary-keys; do
	if hv_occ "$cmd"; then
		hv_log "$cmd 完成"
	else
		hv_warn "$cmd 失败（可稍后手动执行：./hv occ $cmd）"
	fi
done

if hv_truthy "${HV_REPAIR_EXPENSIVE:-false}"; then
	hv_log "执行 maintenance:repair --include-expensive（可能耗时较长）"
	hv_occ maintenance:repair --include-expensive || hv_warn "maintenance:repair --include-expensive 失败"
else
	hv_log "已跳过耗时的 maintenance:repair --include-expensive（需要时：./hv occ maintenance:repair --include-expensive）"
fi

hv_log "升级后处理完成（耗时 $(($(hv_now_ms) - t0)) ms）"
exit 0
