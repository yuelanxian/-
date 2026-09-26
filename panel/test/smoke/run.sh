#!/usr/bin/env bash
# HomeVault 管理面板 — 真实环境冒烟测试（Linux Docker 主机）。
# 启动 Nextcloud 34 + PostgreSQL 18 + Redis + Caddy + socket-proxy + panel（不是正式的 compose.yaml），
# 验证：socket-proxy 放行/拒绝矩阵、真实 Login Flow v2（管理员成功 / 普通用户被拒且设备密码被吊销）、
# 应用密码登录（备用方式）、各 API（按规范格式的示例状态文件）、请求文件与主机结果合并、容器重启、
# /ca.crt、/download/android、跨站拒绝、退出登录与优雅停机时吊销设备密码；可选 Playwright 浏览器测试。结束后全部清理。
#   panel/test/smoke/run.sh [--keep] [--browser] [--no-build]
# 环境变量：SMOKE_PROJECT（默认 hvpanel-smoke）SMOKE_NC_PORT（19443）SMOKE_PANEL_PORT（19444）
#           SMOKE_SUBNET（172.31.232.0/24）PANEL_IMAGE（homevault/panel:1.0.0）TMPDIR（工作目录位置）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_DIR="$(cd "$HERE/../.." && pwd)"
KEEP=0 BROWSER=0 BUILD=1
for a in "$@"; do
	case "$a" in
	--keep) KEEP=1 ;;
	--browser) BROWSER=1 ;;
	--no-build) BUILD=0 ;;
	*) echo "未知参数 $a" >&2; exit 2 ;;
	esac
done
export COMPOSE_PROJECT_NAME="${SMOKE_PROJECT:-hvpanel-smoke}"
export SMOKE_NC_PORT="${SMOKE_NC_PORT:-19443}" SMOKE_PANEL_PORT="${SMOKE_PANEL_PORT:-19444}"
export SMOKE_SUBNET="${SMOKE_SUBNET:-172.31.232.0/24}" PANEL_IMAGE="${PANEL_IMAGE:-homevault/panel:1.0.0}"
SMOKE_SLUG="s$(printf '%s' /srv/photos | sha256sum | cut -c1-8)"
export SMOKE_SLUG
PANEL="https://127.0.0.1:$SMOKE_PANEL_PORT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hvpanel-smoke.XXXXXX")"
cp "$HERE/compose.yaml" "$HERE/Caddyfile" "$HERE/flow.py" "$HERE/browser.mjs" "$WORK/"
cd "$WORK"
DC=(docker compose -f compose.yaml)
cleanup() {
	if [ "$KEEP" = 1 ]; then
		echo "保留环境：$WORK（清理：cd $WORK && COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME docker compose down -v）"
		return
	fi
	"${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
	docker run --rm -v "$WORK:/w" "${ALPINE_IMAGE:-alpine:3.22}" rm -rf /w/data >/dev/null 2>&1 || true
	rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
fail() { echo "✘ $*" >&2; exit 1; }
ok() { echo "✔ $*"; }
cid() { "${DC[@]}" ps -q "$1"; }

if [ "$BUILD" = 1 ]; then
	echo "== 构建 panel 镜像 $PANEL_IMAGE"
	docker build -q -t "$PANEL_IMAGE" "$PANEL_DIR" >/dev/null
fi

echo "== 准备测试数据（状态文件使用 panel/internal/hoststate/types.go 的规范字段）"
mkdir -p data/nc-data data/logs/{homevault,backup,caddy,panel,nextcloud,containers} data/state/requests/done data/state/app data/backup data/photos
printf '# 名称|主机路径|rw或ro|是否备份(yes/no)|可见用户\n照片归档|/srv/photos|rw|yes|\n' >data/storage.conf
chown 33:33 data/nc-data && chmod 0750 data/nc-data
chown -R 65532:65532 data/logs/panel data/state/requests && chmod 0750 data/state/requests
printf '03:30:01 开始备份\n03:30:05 ERROR 仓库锁定失败\n03:31:00 完成\n' >data/logs/backup/backup-20260926-033000.log
for i in $(seq 1 300); do echo "[hv] command $i ok"; done >data/logs/homevault/hv-2026-09-26.log
for i in $(seq 1 50); do echo "{\"msg\":\"handled request $i\"}"; done | gzip >data/logs/caddy/access-2026-09-25.log.gz
echo '{"level":3,"message":"数据库连接失败"}' >data/logs/nextcloud/nextcloud.log
echo SECRET >data/secret.log && ln -s ../../secret.log data/logs/homevault/escape.log
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ) HS=$(($(date +%s) - 30))
cat >data/state/status.json <<EOF
{"updated":"$NOW","version":"1.0.0","platform":"linux","hostname":"smoke","log_retention_days":7,"log_dir":"/srv/homevault/logs",
 "maintenance":{"last_run":"$NOW","ok":true,"message":"完成"},"requests":{"last_run":"$NOW"}}
EOF
cat >data/state/backup-status.json <<EOF
{"updated":"$NOW","state":"ok","last_run":"$NOW","last_finished":"$NOW","last_success":"$NOW","duration_seconds":61.5,
 "message":"备份成功","log_file":"backup/backup-20260926-033000.log","target":"local","repository":"/srv/backup/restic",
 "schedule":"03:30","next_run":null,"stats":{"files_new":3,"files_changed":1,"data_added":1048576,"total_files_processed":1200,"total_bytes_processed":5368709120}}
EOF
# raw `restic snapshots --json` (restic 0.19 incl. summary)
cat >data/state/snapshots.json <<'EOF'
[{"time":"2026-09-25T03:30:00.123456789+08:00","tree":"t1","paths":["/src/nextcloud-data"],"hostname":"homevault","username":"root","tags":["homevault"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-25T03:30:00+08:00","backup_end":"2026-09-25T03:31:00+08:00","files_new":10,"files_changed":0,"files_unmodified":5,"dirs_new":1,"dirs_changed":0,"dirs_unmodified":3,"data_blobs":10,"tree_blobs":1,"data_added":2048,"data_added_packed":1500,"total_files_processed":15,"total_bytes_processed":4096},"id":"a1b2c3d4e5f6","short_id":"a1b2c3d4"},
 {"time":"2026-09-26T03:30:00.5+08:00","tree":"t2","paths":["/src/nextcloud-data"],"hostname":"homevault","username":"root","tags":["homevault"],"program_version":"restic 0.19.1","id":"ffeeddccbbaa","short_id":"ffeeddcc"}]
EOF
cat >data/state/vpn-status.json <<EOF
{"updated":"$NOW","platform":"linux","interface":"wg0","listen_port":51820,"peers":[
 {"name":"手机","address":"10.99.77.2/32","enabled":true,"latest_handshake":$HS,"rx_bytes":1048576,"tx_bytes":2097152,"endpoint":"203.0.113.9:40000","public_key":"SHOULD-NOT-LEAK","preshared_key":"PSK-SHOULD-NOT-LEAK"},
 {"name":"平板","address":"10.99.77.3/32","enabled":true,"latest_handshake":0,"rx_bytes":0,"tx_bytes":0}]}
EOF
# a finished request in the Linux runner format (request moved to done/ + <id>.result.json)
echo '{"id":"20260925T010000000Z-backup","type":"backup","created":"2026-09-25T01:00:00Z","requested_by":"hvadmin"}' >data/state/requests/done/20260925T010000000Z-backup.json
echo '{"request":"20260925T010000000Z-backup.json","type":"backup","ok":false,"finished":"2026-09-25T01:05:00+00:00","message":"失败（退出码 1），详见日志"}' >data/state/requests/done/20260925T010000000Z-backup.result.json
head -c 4096 /dev/urandom >data/state/app/homevault.apk

echo "== 启动测试环境（项目 $COMPOSE_PROJECT_NAME，端口 $SMOKE_NC_PORT/$SMOKE_PANEL_PORT，子网 $SMOKE_SUBNET）"
"${DC[@]}" up -d >/dev/null
for _ in $(seq 1 90); do
	[ "$(docker inspect -f '{{.State.Health.Status}}' "$(cid app)" 2>/dev/null)" = healthy ] && break
	sleep 5
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$(cid app)")" = healthy ] || fail "Nextcloud 未就绪"
for _ in $(seq 1 20); do
	[ "$(docker inspect -f '{{.State.Health.Status}}' "$(cid panel)" 2>/dev/null)" = healthy ] && break
	sleep 3
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$(cid panel)")" = healthy ] || fail "panel 健康检查（panel healthcheck 子命令）失败"
[ "$(docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}}' "$(cid panel)")" = "65532:65532 true" ] || fail "panel 未以 65532 只读运行"
ok "Nextcloud 与 panel 已就绪（panel 以 uid 65532、只读根文件系统运行，健康检查通过）"
"${DC[@]}" exec -T caddy cat /data/caddy/pki/authorities/local/root.crt >root.crt
{ cat root.crt; printf -- '-----BEGIN PRIVATE KEY-----\nMUST-NOT-BE-SERVED\n-----END PRIVATE KEY-----\n'; } >data/state/ca.crt
"${DC[@]}" exec -T -u www-data -e OC_PASS='Normal-User-Pass-2026!' app php occ user:add --password-from-env normaluser >/dev/null

echo "== socket-proxy 放行/拒绝矩阵"
APPID=$(cid app)
cat >proxy.sh <<EOP
P=http://socket-proxy:2375
code() { wget -S -q -O /dev/null "\$@" 2>&1 | grep -o 'HTTP/1.[01] [0-9]*' | tail -1 | cut -d' ' -f2; }
for u in /_ping /version /info '/containers/json?all=1' /containers/$APPID/json '/containers/$APPID/logs?stdout=1&tail=1'; do
  [ "\$(code \$P\$u)" = 200 ] || { echo "DENIED-BUT-SHOULD-ALLOW \$u"; exit 1; }
done
for u in /images/json /volumes /networks /events /secrets /containers/$APPID/archive?path=/ /containers/$APPID/export /containers/$APPID/top; do
  [ "\$(code \$P\$u)" = 403 ] || { echo "ALLOWED-BUT-SHOULD-DENY GET \$u"; exit 1; }
done
for u in /containers/create /containers/$APPID/exec /exec/x/start /containers/$APPID/start /containers/$APPID/update /containers/$APPID/pause /build /images/create /volumes/create; do
  [ "\$(code --post-data= \$P\$u)" = 403 ] || { echo "ALLOWED-BUT-SHOULD-DENY POST \$u"; exit 1; }
done
echo MATRIX-OK
EOP
docker run --rm --network "${COMPOSE_PROJECT_NAME}_dockerapi" -v "$PWD/proxy.sh:/p.sh:ro" "${ALPINE_IMAGE:-alpine:3.22}" sh /p.sh | grep -q MATRIX-OK || fail "socket-proxy 矩阵不符合预期"
ok "socket-proxy 只放行只读接口 + 重启（exec/create/start/images/volumes 等均为 403）"

echo "== Login Flow v2（真实 Nextcloud，模拟浏览器）"
python3 flow.py normaluser 'Normal-User-Pass-2026!' fail || fail "普通用户未被拒绝"
python3 flow.py hvadmin 'Smoke-Admin-Pass-2026!' ok || fail "管理员登录失败"
tokens() { "${DC[@]}" exec -T db psql -U nextcloud -d nextcloud -tA -c "select uid from oc_authtoken where name like 'HomeVault 管理面板%' order by uid"; }
[ "$(tokens | tr '\n' ' ')" = "hvadmin " ] || fail "设备密码状态异常：$(tokens | tr '\n' ' ')"
ok "管理员登录成功；普通用户被拒绝且其设备密码已吊销"

C=$(python3 -c 'import json;print(json.load(open("session.json"))["cookie"])')
T=$(python3 -c 'import json;print(json.load(open("session.json"))["csrf"])')
api() {
	local m=$1 p=$2
	shift 2
	if [ "$m" = GET ]; then
		curl -sS --cacert root.crt -b "__Host-hvpanel=$C" "$PANEL$p"
	else
		curl -sS --cacert root.crt -b "__Host-hvpanel=$C" -H "X-CSRF-Token: $T" -H 'Content-Type: application/json' -X "$m" -d "${1:-{\}}" "$PANEL$p"
	fi
}
check() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert $1, d" || fail "$2"; ok "$2"; }

api GET /api/me | check 'd["authenticated"] and d["user"]=="hvadmin" and d["method"]=="flow"' "会话：/api/me"
api GET /api/overview | check 'any(s["service"]=="app" and s["health"]=="healthy" for s in d["services"]) and d["docker"]["ok"] and d["version"]=="1.0.0" and d["vpn"]["online"]==1 and d["backup"]["last_success"] and d["nextcloud"]["version"].startswith("34.")' "概览：容器状态/健康/运行时长 + 版本 + VPN + 备份 + serverinfo"
api GET /api/storage | check 'len(d["disks"])==3 and [x["role"] for x in d["disks"]]==["data","storage","backup"] and d["disks"][1]["name"]=="照片归档" and d["disks"][0]["total"]>0 and {u["id"] for u in d["users"]}=={"hvadmin","normaluser"} and all("used" in u for u in d["users"])' "存储：statfs /stat/* 角色 + Nextcloud 每用户用量（OCS）"
api GET /api/backup | check '[s["short_id"] for s in d["snapshots"]]==["ffeeddcc","a1b2c3d4"] and d["backup"]["status"]["state"]=="ok" and d["backup"]["status"]["stats"]["data_added"]==1048576 and not d["backup"]["stale"] and d["recent"][0]["state"]=="failed"' "备份：状态 + restic 快照 + 主机结果文件合并"
api GET /api/logs | check 'any(f["path"]=="nextcloud/nextcloud.log" for f in d["files"]) and any(c["service"]=="db" for c in d["containers"]) and not any("escape" in f["path"] for f in d["files"])' "日志：文件列表 + 容器列表（不列出符号链接）"
api GET '/api/logs/file?path=caddy/access-2026-09-25.log.gz&lines=1' | check 'd["lines"]==["{\"msg\":\"handled request 50\"}"]' "日志：gz 文件尾部"
api GET '/api/logs/file?path=homevault/hv-2026-09-26.log&lines=5&q=command%2029' | check 'd["lines"][-1]=="[hv] command 299 ok" and all("command 29" in l for l in d["lines"])' "日志：搜索"
api GET '/api/logs/file?path=homevault/escape.log' | check '"error" in d' "日志：拒绝指向目录外的符号链接"
api GET '/api/logs/file?path=../secret.log' | check '"error" in d' "日志：拒绝路径穿越"
api GET '/api/logs/file?path=%2Fetc%2Fpasswd' | check '"error" in d' "日志：拒绝绝对路径"
[ "$(curl -sS --cacert root.crt -b "__Host-hvpanel=$C" -o /dev/null -w '%{http_code} %{content_type}' "$PANEL/api/logs/download?path=backup/backup-20260926-033000.log")" = "200 text/plain; charset=utf-8" ] || fail "日志下载"
ok "日志：下载"
api GET '/api/logs/container/db?lines=5' | check 'len(d["lines"])==5' "日志：容器日志（多路复用解码）"
api GET '/api/logs/container/nosuch?lines=5' | check '"error" in d' "日志：未知服务 404"
api GET /api/vpn | check 'd["peers"][0]["online"] and d["peers"][0]["name"]=="手机" and not d["peers"][1]["online"] and "LEAK" not in json.dumps(d)' "VPN：设备在线状态，且不泄露密钥"
api GET /api/settings/log-retention | check 'd["days"]==7' "保留天数：读取 7 天"
api POST /api/settings/log-retention '{"days":400}' | check '"error" in d' "保留天数：拒绝 400"
api POST /api/settings/log-retention '{"days":"14"}' | check '"error" in d' "保留天数：拒绝字符串"
api POST /api/settings/log-retention '{"days":14}' | check 'd["ok"]' "保留天数：提交 14 天"
api POST /api/backup/run | check 'd["ok"] and not d["duplicate"]' "立即备份：已提交请求"
api POST /api/backup/run | check 'd["ok"] and d["duplicate"]' "立即备份：重复请求合并"
api POST /api/logs/clean | check 'd["ok"]' "清理日志：已提交请求"
[ "$(stat -c '%a %u' data/state/requests/*-log-retention.json)" = "640 65532" ] || fail "请求文件权限不是 0640"
python3 - <<'EOP' || fail "请求文件格式"
import glob, json
seen = set()
for f in glob.glob("data/state/requests/*.json"):
    d = json.load(open(f))
    assert f.endswith("-" + d["type"] + ".json") and f.split("/")[-1] == d["id"] + ".json", f
    assert d["type"] in ("backup", "log-clean", "log-retention"), d
    if d["type"] == "log-retention":
        assert d["days"] == 14, d
    seen.add(d["type"])
assert seen == {"backup", "log-clean", "log-retention"}, seen
EOP
ok "请求文件：state/requests/<时间>-<类型>.json，0640，原子写入"
api GET /api/requests | check 'len(d["pending"])==3 and d["done"][0]["state"]=="failed"' "请求列表：待处理 + 已完成"
api POST /api/services/socket-proxy/restart | check '"error" in d' "重启：不在允许列表的服务被拒绝"
api POST /api/services/panel/restart | check '"error" in d' "重启：面板自身不在允许列表"
R0=$(docker inspect -f '{{.State.StartedAt}}' "$(cid redis)")
api POST /api/services/redis/restart | check 'd["ok"]' "重启：redis（经 socket-proxy）"
[ "$R0" != "$(docker inspect -f '{{.State.StartedAt}}' "$(cid redis)")" ] || fail "redis 未重启"
curl -sS --cacert root.crt "$PANEL/ca.crt" >ca.out
if ! grep -q 'BEGIN CERTIFICATE' ca.out || grep -q 'PRIVATE KEY' ca.out; then fail "/ca.crt"; fi
ok "/ca.crt 无需登录即可下载，且只包含证书"
[ "$(curl -sS --cacert root.crt -o apk.out -w '%{http_code} %{content_type}' "$PANEL/download/android")" = "200 application/vnd.android.package-archive" ] || fail "/download/android"
cmp -s apk.out data/state/app/homevault.apk || fail "/download/android 内容不一致"
ok "/download/android 提供 state/app/homevault.apk"
[ "$(curl -sS --cacert root.crt -o /dev/null -w '%{http_code}' "$PANEL/api/overview")" = 401 ] || fail "未登录访问未被拒绝"
ok "未登录访问 API 返回 401"
curl -sS --cacert root.crt -H 'Sec-Fetch-Site: cross-site' -H 'Content-Type: application/json' -H "X-CSRF-Token: $T" -b "__Host-hvpanel=$C" -X POST -d '{}' -o /dev/null -w '%{http_code}' "$PANEL/api/backup/run" | grep -q 403 || fail "跨站 POST 未被拒绝"
curl -sS --cacert root.crt -H 'Content-Type: application/json' -b "__Host-hvpanel=$C" -X POST -d '{}' -o /dev/null -w '%{http_code}' "$PANEL/api/backup/run" | grep -q 403 || fail "缺少 CSRF 头的 POST 未被拒绝"
ok "跨站 POST 与缺少 CSRF 头的 POST 被拒绝"
HDR=$(curl -sS --cacert root.crt -D - -o /dev/null "$PANEL/")
grep -qi "content-security-policy: default-src 'none'; script-src 'self'" <<<"$HDR" || fail "CSP 响应头"
grep -qi 'strict-transport-security' <<<"$HDR" || fail "HSTS 响应头"
ok "安全响应头（严格 CSP、HSTS）"
grep -q '"action":"login","ok":true,"user":"hvadmin"' data/logs/panel/panel.log || fail "审计日志（登录）"
grep -q '"action":"restart","ok":true' data/logs/panel/panel.log || fail "审计日志（重启）"
ok "审计日志写入 /logs/panel/panel.log"

echo "== 应用密码登录（备用方式）"
APPPW=$("${DC[@]}" exec -T -u www-data -e OC_PASS='Smoke-Admin-Pass-2026!' app php occ user:auth-tokens:add --password-from-env hvadmin | tail -n 1 | tr -d '\r')
[ -n "$APPPW" ] || fail "无法创建应用密码"
pwlogin() { curl -sS --cacert root.crt -c cj.txt -H 'Content-Type: application/json' -X POST -d "{\"user\":\"$1\",\"app_password\":\"$2\"}" "$PANEL/api/auth/password"; }
pwlogin hvadmin "$APPPW" | check 'd["state"]=="ok" and d["user"]=="hvadmin"' "应用密码登录成功"
C2=$(awk '$6=="__Host-hvpanel"{print $7}' cj.txt)
T2=$(curl -sS --cacert root.crt -b "__Host-hvpanel=$C2" "$PANEL/api/me" | python3 -c 'import json,sys;print(json.load(sys.stdin)["csrf"])')
curl -sS --cacert root.crt -b "__Host-hvpanel=$C2" -H "X-CSRF-Token: $T2" -H 'Content-Type: application/json' -X POST -d '{}' "$PANEL/api/auth/logout" | check 'd["ok"]' "应用密码会话退出"
[ "$(curl -sS -u "hvadmin:$APPPW" -H 'OCS-APIRequest: true' --cacert root.crt -o /dev/null -w '%{http_code}' "https://127.0.0.1:$SMOKE_NC_PORT/ocs/v2.php/cloud/user?format=json")" = 200 ] || fail "用户自己的应用密码不应被吊销"
ok "用户手动创建的应用密码在退出后仍然有效（不会被面板吊销）"
NPW=$("${DC[@]}" exec -T -u www-data -e OC_PASS='Normal-User-Pass-2026!' app php occ user:auth-tokens:add --password-from-env normaluser | tail -n 1 | tr -d '\r')
pwlogin normaluser "$NPW" | check '"管理员" in d["error"]' "非管理员的应用密码被拒绝（403）"
for i in 1 2 3 4; do pwlogin hvadmin "wrong-$i" >/dev/null; done
[ "$(curl -sS --cacert root.crt -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST -d '{"user":"hvadmin","app_password":"x"}' "$PANEL/api/auth/password")" = 429 ] || fail "登录限速未生效"
ok "连续失败后登录被限速（429）"

echo "== 退出登录 / 停机时吊销设备密码"
python3 flow.py hvadmin 'Smoke-Admin-Pass-2026!' ok >/dev/null || fail "第二次登录失败"
[ "$(tokens | wc -l)" = 2 ] || fail "应有两个面板设备密码：$(tokens | tr '\n' ' ')"
C3=$(python3 -c 'import json;print(json.load(open("session.json"))["cookie"])')
T3=$(python3 -c 'import json;print(json.load(open("session.json"))["csrf"])')
curl -sS --cacert root.crt -b "__Host-hvpanel=$C3" -H "X-CSRF-Token: $T3" -H 'Content-Type: application/json' -X POST -d '{}' "$PANEL/api/auth/logout" | check 'd["ok"]' "退出登录"
sleep 2
[ "$(tokens | wc -l)" = 1 ] || fail "退出登录后设备密码未吊销：$(tokens | tr '\n' ' ')"
ok "退出登录时吊销了该会话的设备密码"
"${DC[@]}" stop -t 20 panel >/dev/null
[ -z "$(tokens)" ] || fail "停机后设备密码未吊销"
ok "优雅停机时吊销了剩余会话的设备密码"
"${DC[@]}" start panel >/dev/null

if [ "$BROWSER" = 1 ]; then
	echo "== 浏览器测试（Playwright）"
	for _ in $(seq 1 20); do
		[ "$(docker inspect -f '{{.State.Health.Status}}' "$(cid panel)")" = healthy ] && break
		sleep 2
	done
	mkdir -p shots
	# Chromium puts its singleton socket under TMPDIR: keep that path short
	TMPDIR=/tmp node browser.mjs shots | tee browser.out
	grep -q 'NO PROBLEMS' browser.out || fail "浏览器测试发现问题"
	ok "浏览器测试通过（截图：$WORK/shots）"
fi
echo "全部通过"
