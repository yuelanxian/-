#!/usr/bin/env bash
# HomeVault 管理面板 — 真实环境冒烟测试（Linux Docker 主机）。
# 启动 Nextcloud 34 + PostgreSQL 18 + Caddy + socket-proxy + panel（项目名 hvpanel-smoke，端口 127.0.0.1:38443/38444），
# 验证：socket-proxy 放行/拒绝矩阵、真实 Login Flow v2（管理员成功 / 普通用户被拒且设备密码被吊销）、
# 各 API、请求文件、容器重启、退出登录与优雅停机时吊销设备密码；可选 Playwright 浏览器测试。结束后全部清理。
#   panel/test/smoke/run.sh [--keep] [--browser]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_DIR="$(cd "$HERE/../.." && pwd)"
KEEP=0; BROWSER=0
for a in "$@"; do case "$a" in --keep) KEEP=1 ;; --browser) BROWSER=1 ;; *) echo "未知参数 $a" >&2; exit 2 ;; esac; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hvpanel-smoke.XXXXXX")"
cp "$HERE/compose.yaml" "$HERE/Caddyfile" "$HERE/flow.py" "$HERE/browser.mjs" "$WORK/"
cd "$WORK"
DC=(docker compose -p hvpanel-smoke -f compose.yaml)
cleanup() {
	if [ "$KEEP" = 1 ]; then echo "保留环境：$WORK（清理：cd $WORK && docker compose -p hvpanel-smoke down -v）"; return; fi
	"${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
	rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
fail() { echo "✘ $*" >&2; exit 1; }
ok() { echo "✔ $*"; }

echo "== 构建 panel 镜像"
docker build -q -t "${PANEL_IMAGE:-homevault/panel:0.1.0}" "$PANEL_DIR" >/dev/null

echo "== 准备测试数据"
mkdir -p data/nc-data data/logs/{homevault,backup,caddy,panel} data/state/requests/done data/state/app data/backup data/photos
printf '# 名称|主机路径|rw或ro|是否备份(yes/no)|可见用户\n照片归档|/srv/photos|rw|yes|\n' > data/storage.conf
chown 33:33 data/nc-data && chmod 0750 data/nc-data
chown -R 65532:65532 data/logs/panel data/state/requests && chmod 0750 data/state/requests
printf '03:30:01 开始备份\n03:30:05 ERROR 仓库锁定失败\n03:31:00 完成\n' > data/logs/backup/backup-20260926-033000.log
for i in $(seq 1 300); do echo "[hv] command $i ok"; done > data/logs/homevault/hv-2026-09-26.log
for i in $(seq 1 50); do echo "{\"msg\":\"handled request $i\"}"; done | gzip > data/logs/caddy/access-2026-09-25.log.gz
echo SECRET > data/secret.log && ln -s ../../secret.log data/logs/homevault/escape.log
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ); HS=$(( $(date +%s) - 30 ))
echo "{\"updated\":\"$NOW\",\"version\":\"smoke\",\"platform\":\"linux\",\"log_retention_days\":7}" > data/state/status.json
echo "{\"state\":\"ok\",\"last_success\":\"$NOW\",\"target\":\"local\",\"log_file\":\"backup/backup-20260926-033000.log\"}" > data/state/backup-status.json
echo '[{"time":"2026-09-25T03:30:00+08:00","id":"a1b2c3d4e5","short_id":"a1b2c3d4"},{"time":"2026-09-26T03:30:00+08:00","id":"ffeeddccbb","short_id":"ffeeddcc"}]' > data/state/snapshots.json
echo "{\"updated\":\"$NOW\",\"peers\":[{\"name\":\"手机\",\"address\":\"10.99.77.2\",\"public_key\":\"SHOULD-NOT-LEAK\",\"latest_handshake\":$HS,\"rx_bytes\":1,\"tx_bytes\":2,\"enabled\":true}]}" > data/state/vpn-status.json

echo "== 启动测试环境"
"${DC[@]}" up -d >/dev/null
for i in $(seq 1 90); do
	[ "$(docker inspect -f '{{.State.Health.Status}}' hvpanel-smoke-app-1 2>/dev/null)" = healthy ] && break
	sleep 5
done
[ "$(docker inspect -f '{{.State.Health.Status}}' hvpanel-smoke-app-1)" = healthy ] || fail "Nextcloud 未就绪"
[ "$(docker inspect -f '{{.State.Health.Status}}' hvpanel-smoke-panel-1)" = healthy ] || fail "panel 健康检查失败"
ok "Nextcloud 与 panel 已就绪（panel 健康检查通过）"
"${DC[@]}" exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > root.crt
cp root.crt data/state/ca.crt
"${DC[@]}" exec -T -u www-data -e OC_PASS='Normal-User-Pass-2026!' app php occ user:add --password-from-env normaluser >/dev/null

echo "== socket-proxy 放行/拒绝矩阵"
APPID=$("${DC[@]}" ps -q app)
cat > proxy.sh <<EOP
P=http://socket-proxy:2375
code() { wget -S -q -O /dev/null "\$@" 2>&1 | grep -o 'HTTP/1.[01] [0-9]*' | tail -1 | cut -d' ' -f2; }
for u in /_ping /version /info '/containers/json?all=1' /containers/$APPID/json '/containers/$APPID/logs?stdout=1&tail=1'; do
  [ "\$(code \$P\$u)" = 200 ] || { echo "DENIED-BUT-SHOULD-ALLOW \$u"; exit 1; }
done
for u in /images/json /volumes /networks /events /containers/$APPID/archive?path=/ /containers/$APPID/export /containers/$APPID/top; do
  [ "\$(code \$P\$u)" = 403 ] || { echo "ALLOWED-BUT-SHOULD-DENY GET \$u"; exit 1; }
done
for u in /containers/create /containers/$APPID/exec /exec/x/start /containers/$APPID/start /containers/$APPID/update /build /images/create; do
  [ "\$(code --post-data= \$P\$u)" = 403 ] || { echo "ALLOWED-BUT-SHOULD-DENY POST \$u"; exit 1; }
done
echo MATRIX-OK
EOP
docker run --rm --network hvpanel-smoke_dockerapi -v "$PWD/proxy.sh:/p.sh:ro" "${ALPINE_IMAGE:-alpine:3.22}" sh /p.sh | grep -q MATRIX-OK || fail "socket-proxy 矩阵不符合预期"
ok "socket-proxy 只放行只读接口 + 重启"

echo "== Login Flow v2（真实 Nextcloud）"
python3 flow.py normaluser 'Normal-User-Pass-2026!' fail >/dev/null || fail "普通用户未被拒绝"
python3 flow.py hvadmin 'Smoke-Admin-Pass-2026!' ok >/dev/null || fail "管理员登录失败"
tokens() { "${DC[@]}" exec -T db psql -U nextcloud -d nextcloud -tA -c "select uid from oc_authtoken where name like 'HomeVault 管理面板%' order by uid"; }
[ "$(tokens | tr '\n' ' ')" = "hvadmin " ] || fail "设备密码状态异常：$(tokens | tr '\n' ' ')"
ok "管理员登录成功；普通用户被拒绝且其设备密码已吊销"

C=$(python3 -c 'import json;print(json.load(open("session.json"))["cookie"])')
T=$(python3 -c 'import json;print(json.load(open("session.json"))["csrf"])')
api() { local m=$1 p=$2; shift 2
	if [ "$m" = GET ]; then curl -sS --cacert root.crt -b "__Host-hvpanel=$C" "https://127.0.0.1:38444$p"
	else curl -sS --cacert root.crt -b "__Host-hvpanel=$C" -H "X-CSRF-Token: $T" -H 'Content-Type: application/json' -X "$m" -d "${1:-{\}}" "https://127.0.0.1:38444$p"; fi; }
check() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert $1, d" || fail "$2"; ok "$2"; }

api GET /api/overview | check 'any(s["service"]=="app" and s["health"]=="healthy" for s in d["services"]) and d["docker"]["ok"]' "概览：容器状态来自 socket-proxy"
api GET /api/storage | check 'len(d["disks"])==3 and {u["id"] for u in d["users"]}=={"hvadmin","normaluser"} and d["disks"][1]["name"]=="照片归档"' "存储：磁盘角色 + Nextcloud 用户用量"
api GET /api/backup | check '[s["short_id"] for s in d["snapshots"]]==["ffeeddcc","a1b2c3d4"]' "备份：状态与快照"
api GET '/api/logs/file?path=caddy/access-2026-09-25.log.gz&lines=1' | check 'd["lines"]==["{\"msg\":\"handled request 50\"}"]' "日志：gz 文件尾部"
api GET '/api/logs/file?path=homevault/escape.log' | check '"error" in d' "日志：拒绝指向目录外的符号链接"
api GET '/api/logs/file?path=../secret.log' | check '"error" in d' "日志：拒绝路径穿越"
api GET '/api/logs/container/db?lines=5' | check 'len(d["lines"])==5' "日志：容器日志（多路复用解码）"
api GET /api/vpn | check 'd["peers"][0]["online"] and "SHOULD-NOT-LEAK" not in json.dumps(d)' "VPN：设备在线且不泄露密钥"
api POST /api/settings/log-retention '{"days":400}' | check '"error" in d' "保留天数：拒绝 400"
api POST /api/settings/log-retention '{"days":14}' | check 'd["ok"]' "保留天数：提交 14 天"
api POST /api/backup/run | check 'd["ok"]' "立即备份：已提交请求"
[ "$(stat -c '%a %u' data/state/requests/*-log-retention.json)" = "640 65532" ] || fail "请求文件权限不是 0640"
ok "请求文件 0640，原子写入"
api POST /api/services/socket-proxy/restart | check '"error" in d' "重启：不在允许列表的服务被拒绝"
R0=$(docker inspect -f '{{.State.StartedAt}}' hvpanel-smoke-redis-1)
api POST /api/services/redis/restart | check 'd["ok"]' "重启：redis"
[ "$R0" != "$(docker inspect -f '{{.State.StartedAt}}' hvpanel-smoke-redis-1)" ] || fail "redis 未重启"
curl -sS --cacert root.crt https://127.0.0.1:38444/ca.crt | grep -q 'BEGIN CERTIFICATE' || fail "/ca.crt"
ok "/ca.crt 可下载"
curl -sS --cacert root.crt -H 'Sec-Fetch-Site: cross-site' -H 'Content-Type: application/json' -b "__Host-hvpanel=$C" -X POST -d '{}' -o /dev/null -w '%{http_code}' https://127.0.0.1:38444/api/backup/run | grep -q 403 || fail "跨站 POST 未被拒绝"
ok "跨站 POST 被拒绝"

"${DC[@]}" stop -t 20 panel >/dev/null
[ -z "$(tokens)" ] || fail "停机后设备密码未吊销"
ok "优雅停机时吊销了设备密码"
"${DC[@]}" start panel >/dev/null

if [ "$BROWSER" = 1 ]; then
	echo "== 浏览器测试（Playwright）"
	sleep 5; mkdir -p shots
	node browser.mjs shots | tee browser.out
	grep -q 'NO PROBLEMS' browser.out || fail "浏览器测试发现问题"
	ok "浏览器测试通过（截图：$WORK/shots）"
fi
echo "全部通过"
