#!/usr/bin/env bash
# HomeVault end-to-end test (SPEC §13): real stack on a Linux Docker host, without WireGuard.
#
# Runs against an isolated temporary copy of the repository with a unique compose project name,
# unique ports and a unique Docker subnet, and always tears everything down (trap), unless E2E_KEEP=1.
# Needs root (bind mounts owned by uid 33): run as root or via `sudo -E tests/e2e.sh`.
#
# Environment:
#   E2E_KEEP=1            keep the stack and temp dir for debugging (prints how to clean up)
#   E2E_TMPDIR=/path      where to create the temp dir (default: $TMPDIR or /tmp)
#   E2E_HTTPS_PORT etc.   override ports (default 18443/18080/18444/18445 or random free ones)
#   E2E_SUBNET=a.b.c.0/24 Docker frontend subnet (default: a random free 10.x.y.0/24)
#   E2E_PROJECT_PREFIX    compose project name prefix (default hve2e)
#   E2E_MIRROR=daocloud   pass --mirror to install (e.g. behind the Great Firewall)
#   E2E_SKIP_FULL_RESTORE=1  skip the disaster-recovery round trip
set -Eeuo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $(id -u) -eq 0 ]] || {
	echo "e2e: 需要 root（请用 sudo -E $0）" >&2
	exit 1
}
for c in docker curl sha256sum tar python3; do
	command -v "$c" >/dev/null || {
		echo "e2e: 缺少命令 $c" >&2
		exit 1
	}
done
docker info >/dev/null 2>&1 || {
	echo "e2e: Docker 不可用" >&2
	exit 1
}

# shellcheck source=scripts/lib.sh
. "$REPO/scripts/lib.sh"
export NO_COLOR=1

T0=$SECONDS
WORK=$(mktemp -d "${E2E_TMPDIR:-${TMPDIR:-/tmp}}/hv-e2e.XXXXXX")
APP=$WORK/repo
PROJECT="${E2E_PROJECT_PREFIX:-hve2e}$(date +%s)$$"
PROJECT=${PROJECT:0:30}
LOG=$WORK/e2e.log
STEP=''

step() {
	STEP=$*
	printf '\n[e2e %4ds] ▶ %s\n' $((SECONDS - T0)) "$*"
}
pass() { printf '[e2e %4ds]   ✔ %s\n' $((SECONDS - T0)) "$*"; }
bail() {
	printf '[e2e %4ds]   ✘ %s\n' $((SECONDS - T0)) "$*" >&2
	exit 1
}
hvc() { (cd "$APP" && ./hv "$@"); }

cleanup() {
	local rc=$?
	set +e
	if ((rc != 0)); then
		printf '\n[e2e] 失败于步骤：%s（退出码 %d）\n' "$STEP" "$rc" >&2
		if [[ -f $APP/.env ]]; then
			(cd "$APP" && ./hv compose ps -a) >&2
			(cd "$APP" && ./hv compose logs --no-color --tail 60 app caddy db) >&2
		fi
		[[ -f $LOG ]] && tail -n 80 "$LOG" >&2
	fi
	if [[ ${E2E_KEEP:-0} == 1 ]]; then
		printf '\n[e2e] 保留现场：%s（清理：cd %s && ./hv compose down -v; rm -rf %s）\n' "$WORK" "$APP" "$WORK" >&2
		return
	fi
	if [[ -f $APP/.env ]]; then
		(cd "$APP" && ./hv compose --profile tools down -v --remove-orphans) >/dev/null 2>&1
	fi
	docker compose -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1
	docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" | xargs -r docker volume rm >/dev/null 2>&1
	docker network ls -q --filter "label=com.docker.compose.project=$PROJECT" | xargs -r docker network rm >/dev/null 2>&1
	rm -rf "$WORK"
	printf '[e2e] 已清理（%s）\n' "$PROJECT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------- helpers
free_port() { # preferred → a free port
	local p=$1
	if ! port_in_use "$p"; then
		echo "$p"
		return
	fi
	for _ in $(seq 50); do
		p=$(rand_int 20000 32000)
		port_in_use "$p" || {
			echo "$p"
			return
		}
	done
	bail "找不到空闲端口"
}

used_subnets() {
	docker network ls -q | xargs -r docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+/[0-9]+$' || true
}

free_subnet() {
	local cand s ok
	for _ in $(seq 50); do
		cand="10.$(rand_int 200 250).$(rand_int 0 255).0/24"
		ok=1
		while IFS= read -r s; do
			[[ -n $s ]] || continue
			if ip_in_cidr "${cand%/*}" "$s" || ip_in_cidr "${s%/*}" "$cand"; then ok=0; fi
		done < <(used_subnets)
		((ok)) && {
			echo "$cand"
			return
		}
	done
	bail "找不到空闲的 Docker 网段"
}

HTTPS=$(free_port "${E2E_HTTPS_PORT:-18443}")
HTTP=$(free_port "${E2E_HTTP_PORT:-18080}")
ADMIN=$(free_port "${E2E_ADMIN_PORT:-18444}")
PANEL=$(free_port "${E2E_PANEL_PORT:-18445}")
SUBNET=${E2E_SUBNET:-$(free_subnet)}
BASE=https://127.0.0.1:$HTTPS
PBASE=https://127.0.0.1:$PANEL
LOGDIR=$WORK/data/logs
JAR=$WORK/panel.cookies
USER_NAME=hvadmin
DAV=$BASE/remote.php/dav/files/$USER_NAME

ccurl() { curl -sS --max-time 120 --cacert "$WORK/ca.crt" "$@"; }
dav() { ccurl -u "$USER_NAME:$APPPW" "$@"; }
http_code() { ccurl -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }

# jcheck FILE|- "python expression on d" — JSON assertion (d = parsed JSON)
jcheck() {
	local src=$1 expr=$2 out
	if [[ $src == - ]]; then src=$WORK/.jcheck.json && cat >"$src"; fi
	out=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); print(bool($expr))" "$src" 2>&1) || out="error: $out"
	[[ $out == True ]] || {
		printf '[e2e] JSON 检查失败：%s\n  → %s\n  %s\n' "$expr" "$out" "$(head -c 1500 "$src")" >&2
		return 1
	}
}
storage_slug_e2e() { printf 's%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-8)"; }
# (re-)login to the panel with the app password: sessions live in the panel's memory and end whenever the
# panel container is recreated (e.g. storage apply adds /stat mounts)
panel_login() {
	local code
	rm -f "$JAR"
	code=$(ccurl -o "$WORK/login.json" -w '%{http_code}' -c "$JAR" -H 'Content-Type: application/json' -X POST \
		-d "{\"user\":\"$USER_NAME\",\"app_password\":\"$APPPW\"}" "$PBASE/api/auth/password")
	[[ $code == 200 ]] || {
		printf '[e2e] 面板登录失败（HTTP %s）：%s\n' "$code" "$(cat "$WORK/login.json")" >&2
		return 1
	}
	CSRF=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["csrf"])' "$WORK/login.json")
}
wait_panel() { # until the panel answers through Caddy (after a recreate)
	for _ in $(seq 60); do
		[[ $(ccurl "$PBASE/healthz" 2>/dev/null) == ok ]] && return 0
		sleep 2
	done
	return 1
}
# panel API with the session cookie (+ CSRF header once logged in)
papi() { ccurl -b "$JAR" -c "$JAR" -H "X-CSRF-Token: ${CSRF:-}" "$@"; }
# write a request file exactly like the panel does (tmp + rename, 0640, owned by uid 65532)
panel_request() { # type [days]
	local id tmp
	id="$(date -u +%Y%m%dT%H%M%S)000Z-$1"
	tmp=$APP/state/requests/.tmp-$id.json
	if [[ -n ${2:-} ]]; then
		printf '{"id":"%s","type":"%s","days":%d,"created":"%s","requested_by":"e2e","source":"panel"}\n' "$id" "$1" "$2" "$(date -u -Iseconds)" >"$tmp"
	else
		printf '{"id":"%s","type":"%s","created":"%s","requested_by":"e2e","source":"panel"}\n' "$id" "$1" "$(date -u -Iseconds)" >"$tmp"
	fi
	chown 65532:65532 "$tmp"
	chmod 0640 "$tmp"
	mv "$tmp" "$APP/state/requests/$id.json"
	printf '%s\n' "$id"
}

wait_status_ok() { # wait until status.php via Caddy reports installed:true
	local out
	for _ in $(seq 60); do
		out=$(ccurl "$BASE/status.php" 2>/dev/null || true)
		[[ $out == *'"installed":true'* ]] && return 0
		sleep 3
	done
	return 1
}

# ---------------------------------------------------------------------------- 0. isolated copy
step "准备隔离的仓库副本（项目 $PROJECT，端口 $HTTP/$HTTPS/$ADMIN/$PANEL，网段 $SUBNET）"
mkdir -p "$APP"
tar -C "$REPO" --exclude=./.git --exclude=./.env --exclude=./secrets --exclude=./state --exclude=./storage.conf \
	--exclude=./compose.storage.yaml --exclude=./clients --exclude=./restore --exclude=./data -cf - . | tar -C "$APP" -xf -
chmod 0755 "$WORK"
pass "副本：$APP"

# ---------------------------------------------------------------------------- 1. install
step "hv install（非交互）"
mirror=()
[[ -n ${E2E_MIRROR:-} ]] && mirror=(--mirror "$E2E_MIRROR")
if ! hvc install --non-interactive --yes --no-vpn --no-firewall --no-systemd \
	--host 127.0.0.1 --lan-ip 127.0.0.1 --lan-cidr 127.0.0.0/8 --bind-ip 127.0.0.1 \
	--https-port "$HTTPS" --http-port "$HTTP" --admin-port "$ADMIN" --panel-port "$PANEL" \
	--frontend-subnet "$SUBNET" --data-dir "$WORK/data" --backup-local-path "$WORK/restic-repo" \
	--project-name "$PROJECT" --admin-user "$USER_NAME" --log-retention 7 --timeout 1800 "${mirror[@]}" >"$LOG" 2>&1; then
	bail "install 失败（日志见上）"
fi
grep -q '安装完成' "$LOG" || bail "install 未输出安装摘要"
grep -qF "$(cat "$APP/secrets/nextcloud_admin_password")" "$LOG" || bail "安装摘要未显示初始管理员密码"
pass "安装完成（$(grep -c . "$LOG") 行输出）"

step "重复运行 install 不会重新生成密钥"
sum_before=$(cat "$APP"/secrets/* | sha256sum)
hvc install --non-interactive --yes --no-vpn --no-firewall --no-systemd --timeout 600 >"$LOG.2" 2>&1 || bail "第二次 install 失败"
[[ $(cat "$APP"/secrets/* | sha256sum) == "$sum_before" ]] || bail "密钥被重新生成"
grep -qF "$(cat "$APP/secrets/nextcloud_admin_password")" "$LOG.2" && bail "第二次 install 不应再次显示密码"
pass "密钥未变化"

# ---------------------------------------------------------------------------- 2. TLS + status
step "导出根证书并通过 Caddy 访问 status.php"
hvc ca --export "$WORK/ca.crt" >/dev/null || bail "hv ca 失败"
grep -q 'BEGIN CERTIFICATE' "$WORK/ca.crt" || bail "根证书无效"
wait_status_ok || bail "status.php 未返回 installed:true"
hdr=$(ccurl -sI "$BASE/status.php")
grep -qi '^strict-transport-security: max-age=15552000' <<<"$hdr" || bail "缺少 HSTS 头"
[[ $(http_code "$BASE/.well-known/carddav") == 301 ]] || bail ".well-known/carddav 未重定向"
pass "HTTPS 正常（证书由本地 CA 签发，HSTS 已设置）"

step "管理面板经 Caddy 提供（/healthz、/api/info、/ca.crt）"
[[ $(ccurl "$PBASE/healthz") == ok ]] || bail "面板 /healthz 异常"
ccurl "$PBASE/api/info" | jcheck - "d['app'] == 'homevault-panel'" || bail "/api/info 异常"
hdr=$(ccurl -sI "$PBASE/healthz")
grep -qi '^strict-transport-security: max-age=15552000' <<<"$hdr" || bail "面板缺少 HSTS 头"
got_ca=''
for _ in $(seq 30); do # the caddy healthcheck copies root.crt into the ca_public volume
	got_ca=$(ccurl -f "$PBASE/ca.crt" 2>/dev/null || true)
	[[ -n $got_ca ]] && break
	sleep 2
done
[[ $got_ca == "$(cat "$WORK/ca.crt")" ]] || bail "面板提供的 /ca.crt 与 Caddy 根证书不一致"
[[ $(stat -c %u "$APP/state/requests") == 65532 ]] || bail "state/requests 不属于面板用户 65532"
[[ $(stat -c %u "$LOGDIR/panel") == 65532 ]] || bail "logs/panel 不属于面板用户 65532"
[[ -s $APP/state/panel-build.sha ]] || bail "install 未构建面板镜像（state/panel-build.sha 缺失）"
grep -q 'target: "/stat/data"' "$APP/compose.storage.yaml" || bail "compose.storage.yaml 缺少面板的 /stat/data 挂载"
grep -q 'target: "/stat/backup"' "$APP/compose.storage.yaml" || bail "compose.storage.yaml 缺少面板的 /stat/backup 挂载"
pass "面板可访问，根证书一致，目录属主正确"

# ---------------------------------------------------------------------------- 3. hardening
step "检查 Nextcloud 加固"
out=$(hvc occ twofactorauth:enforce)
[[ $out == *'is enforced'* ]] || bail "两步验证未强制：$out"
[[ $(hvc occ config:system:get token_auth_enforced | tr -d '\r') == true ]] || bail "token_auth_enforced 未启用"
[[ $(hvc occ config:app:get core shareapi_allow_links | tr -d '\r') == no ]] || bail "公开链接未关闭"
hvc occ app:list --enabled --output=json | grep -q '"admin_audit"' || bail "admin_audit 未启用"
pass "2FA 强制 / token_auth_enforced / 公开链接关闭 / admin_audit"

# ---------------------------------------------------------------------------- 4. abort path
step "IP 白名单：不匹配的来源被 Caddy 直接断开"
HV_ROOT=$APP # read by env.sh
export HV_ROOT
# shellcheck source=scripts/env.sh
. "$APP/scripts/env.sh"
orig_cidrs=$(env_get_file HV_ALLOWED_CIDRS "$APP/.env")
env_set_file HV_ALLOWED_CIDRS '192.0.2.0/24' "$APP/.env"
hvc up >/dev/null 2>&1 || bail "hv up 失败"
aborted=0
for _ in $(seq 40); do
	code=$(http_code "$BASE/status.php")
	if [[ $code == 000 ]]; then
		aborted=1
		break
	fi
	sleep 2
done
((aborted)) || bail "连接未被中止（HTTP $code）"
env_set_file HV_ALLOWED_CIDRS "$orig_cidrs" "$APP/.env"
hvc up >/dev/null 2>&1 || bail "hv up 失败"
wait_status_ok || bail "恢复白名单后无法访问"
pass "白名单外来源被中止，恢复后正常"

# ---------------------------------------------------------------------------- 5. app password + WebDAV
step "创建应用密码并通过 WebDAV 上传/下载 50 MB 文件"
ADMIN_PASS=$(cat "$APP/secrets/nextcloud_admin_password")
APPPW=$(hvc compose exec -T -e NC_PASS="$ADMIN_PASS" -u www-data app php occ user:auth-tokens:add --password-from-env --name e2e "$USER_NAME" |
	tr -d '\r' | tail -n1)
[[ $APPPW =~ ^[A-Za-z0-9]{20,}$ ]] || bail "未获得应用密码"
# login password must be rejected for DAV (token_auth_enforced)
[[ $(http_code -u "$USER_NAME:$ADMIN_PASS" -X PROPFIND "$DAV/") == 401 ]] || bail "登录密码不应能访问 WebDAV"
[[ $(http_code -u "$USER_NAME:$APPPW" -X MKCOL "$DAV/e2e") =~ ^(201|405)$ ]] || bail "MKCOL 失败"
head -c $((50 * 1024 * 1024)) /dev/urandom >"$WORK/big.bin"
SUM=$(sha256sum "$WORK/big.bin" | cut -c1-64)
code=$(http_code -u "$USER_NAME:$APPPW" -T "$WORK/big.bin" "$DAV/e2e/big.bin")
[[ $code =~ ^(201|204)$ ]] || bail "PUT 失败（HTTP $code）"
dav -f -o "$WORK/big.down" "$DAV/e2e/big.bin" || bail "GET 失败"
[[ $(sha256sum "$WORK/big.down" | cut -c1-64) == "$SUM" ]] || bail "下载的文件校验和不一致"
rm -f "$WORK/big.down"
pass "50 MB 往返一致（sha256 ${SUM:0:12}…）"

step "用应用密码登录管理面板"
panel_login || bail "面板登录失败"
papi "$PBASE/api/overview" | jcheck - "d['version'] == '1.0.0' and d['platform'] == 'linux' and d['docker']['ok'] and any(s['service'] == 'app' for s in d['services'])" ||
	bail "/api/overview 异常"
pass "面板登录成功，概览显示 HomeVault 1.0.0 / linux"

# ---------------------------------------------------------------------------- 6. extra storage
step "额外存储：添加一个可写目录并通过 WebDAV 访问"
EXT=$WORK/ext1
EXT_NAME='E2E外部存储'
mkdir -p "$EXT"
echo "hello-from-disk" >"$EXT/hello.txt"
chown -R 33:33 "$EXT"
hvc storage add --name "$EXT_NAME" --path "$EXT" --mode rw --backup yes --apply --yes >>"$LOG" 2>&1 || bail "storage add 失败"
[[ -f $APP/compose.storage.yaml ]] || bail "未生成 compose.storage.yaml"
ENC=$(urlencode "$EXT_NAME")
got=''
for _ in $(seq 20); do
	got=$(dav -f "$DAV/$ENC/hello.txt" 2>/dev/null || true)
	[[ $got == hello-from-disk ]] && break
	sleep 3
done
[[ $got == hello-from-disk ]] || bail "挂载中的文件不可见（得到：$got）"
echo "written-via-dav" >"$WORK/w.txt"
code=$(http_code -u "$USER_NAME:$APPPW" -T "$WORK/w.txt" "$DAV/$ENC/w.txt")
[[ $code =~ ^(201|204)$ ]] || bail "写入挂载失败（HTTP $code）"
[[ $(cat "$EXT/w.txt" 2>/dev/null) == written-via-dav ]] || bail "写入未落到宿主机目录"
hvc storage apply --yes >>"$LOG" 2>&1 || bail "重复 storage apply 失败"
[[ $(hvc occ files_external:list --output=json | grep -o '"mount_id"' | wc -l) == 1 ]] || bail "重复 apply 产生了重复挂载"
grep -q "target: \"/stat/storage/$(storage_slug_e2e "$EXT")\"" "$APP/compose.storage.yaml" || bail "compose.storage.yaml 缺少面板的扩展存储挂载"
wait_panel || bail "面板重建后不可用"
panel_login || bail "面板重建后无法登录"
papi "$PBASE/api/storage" | jcheck - "d['disks_source'] == 'panel' and {'data','storage','backup'} <= {x['role'] for x in d['disks']} and all(x['total'] > 0 for x in d['disks'])" ||
	bail "面板 /api/storage 未显示主数据/扩展存储/备份三个角色"
pass "挂载可读写，apply 幂等；面板显示各硬盘容量"

# ---------------------------------------------------------------------------- 7. backup
step "备份（--init --check）"
hvc backup --init --check >>"$LOG" 2>&1 || bail "backup 失败"
[[ -s $APP/state/last-backup-ok ]] || bail "未写入 state/last-backup-ok"
jcheck "$APP/state/backup-status.json" "d['state'] == 'ok' and d['exit_code'] == 0 and d['last_success'] and d['log_file'].startswith('backup/') and d['stats']['total_files_processed'] > 0" ||
	bail "backup-status.json 格式/内容不对"
[[ -f $LOGDIR/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["log_file"])' "$APP/state/backup-status.json") ]] ||
	bail "backup-status.json 的 log_file 不存在"
jcheck "$APP/state/snapshots.json" "len(d) >= 1 and d[0]['hostname'] == 'homevault' and 'homevault' in d[0]['tags']" || bail "snapshots.json 异常"
papi "$PBASE/api/backup" | jcheck - "d['backup']['status']['state'] == 'ok' and d['snapshots_total'] >= 1 and not d['backup']['stale']" ||
	bail "面板 /api/backup 未显示备份成功"
[[ -s $WORK/data/dumps/nextcloud.sql ]] || bail "数据库转储不存在"
[[ $(hvc occ maintenance:mode | tr -d '\r') == *disabled* ]] || bail "备份后维护模式未关闭"
ls "$WORK/data/logs/backup/"backup-*.log >/dev/null 2>&1 || bail "未写入备份日志"
pass "快照已创建，维护模式已关闭"

# ---------------------------------------------------------------------------- 8. restore --files
step "删除文件后用 restore --files 找回"
[[ $(http_code -u "$USER_NAME:$APPPW" -X DELETE "$DAV/e2e/big.bin") == 204 ]] || bail "DELETE 失败"
[[ $(http_code -u "$USER_NAME:$APPPW" "$DAV/e2e/big.bin") == 404 ]] || bail "文件仍然存在"
hvc restore --files "$USER_NAME/files/e2e/big.bin" --yes >>"$LOG" 2>&1 || bail "restore --files 失败"
restored=$(find "$APP/restore" -type f -path "*/src/nextcloud-data/$USER_NAME/files/e2e/big.bin" | head -n1)
[[ -n $restored ]] || bail "restore/ 中没有找到文件"
[[ $(sha256sum "$restored" | cut -c1-64) == "$SUM" ]] || bail "恢复的文件校验和不一致"
pass "已恢复到 ${restored#"$APP"/}"

# ---------------------------------------------------------------------------- 9. restore --full
if [[ ${E2E_SKIP_FULL_RESTORE:-0} != 1 ]]; then
	step "整机恢复（restore --full）"
	echo "created-after-backup" >"$WORK/after.txt"
	code=$(http_code -u "$USER_NAME:$APPPW" -T "$WORK/after.txt" "$DAV/after.txt")
	[[ $code =~ ^(201|204)$ ]] || bail "上传 after.txt 失败"
	hvc restore --full --yes --force >>"$LOG" 2>&1 || bail "restore --full 失败"
	wait_status_ok || bail "恢复后 status.php 不可用"
	dav -f -o "$WORK/big.down" "$DAV/e2e/big.bin" || bail "恢复后 big.bin 不存在"
	[[ $(sha256sum "$WORK/big.down" | cut -c1-64) == "$SUM" ]] || bail "恢复后 big.bin 校验和不一致"
	[[ $(http_code -u "$USER_NAME:$APPPW" "$DAV/after.txt") == 404 ]] || bail "快照之后的文件应被移除"
	[[ $(dav -f "$DAV/$ENC/hello.txt" 2>/dev/null) == hello-from-disk ]] || bail "恢复后额外存储不可访问"
	[[ $(hvc occ maintenance:mode | tr -d '\r') == *disabled* ]] || bail "恢复后仍在维护模式"
	pass "数据库、数据目录、配置已恢复到快照状态；应用密码仍有效"
fi

# ---------------------------------------------------------------------------- 10. logs
step "日志文件与保留天数清理"
hvc maintenance >>"$LOG" 2>&1 || bail "hv maintenance 失败"
for f in homevault/hv-"$(date +%F)".log caddy/access.log nextcloud/audit.log panel/panel.log; do
	[[ -s $LOGDIR/$f ]] || bail "缺少日志文件：$f（$(cd "$LOGDIR" && find . -type f | sort | tr '\n' ' ')）"
done
ls "$LOGDIR/backup/"backup-*.log >/dev/null 2>&1 || bail "缺少备份日志"
[[ $(stat -c %a "$LOGDIR/caddy/access.log") == 644 && $(stat -c %a "$LOGDIR/nextcloud/audit.log") == 644 ]] || bail "日志文件权限不是 0644"
grep -q '"login"' "$LOGDIR/panel/panel.log" || bail "面板审计日志没有登录记录"
grep -qF "$APPPW" "$LOGDIR"/caddy/access.log "$LOGDIR"/panel/panel.log && bail "应用密码出现在日志中"
grep -qF "$(cat "$APP/secrets/nextcloud_admin_password")" -r "$LOGDIR" && bail "日志中出现了管理员密码"
grep -qF "$(cat "$APP/secrets/restic_password")" -r "$LOGDIR" && bail "日志中出现了 restic 密码"
hvc logs list >"$WORK/logs-list.txt" 2>&1 || bail "hv logs list 失败"
grep -q 'caddy/access.log' "$WORK/logs-list.txt" || bail "hv logs list 未列出 access.log"
hvc logs show caddy/access.log --lines 3 | grep -q '"request"' || bail "hv logs show 失败"
# retention: fake old files are removed, active and recent files stay
echo old >"$LOGDIR/homevault/e2e-old.log"
echo old >"$LOGDIR/containers/app-2000-01-01.log"
echo old >"$LOGDIR/backup/e2e-old.txt"
echo keep >"$LOGDIR/homevault/e2e-keep.conf"
touch -d '30 days ago' "$LOGDIR/homevault/e2e-old.log" "$LOGDIR/containers/app-2000-01-01.log" "$LOGDIR/backup/e2e-old.txt" \
	"$LOGDIR/homevault/e2e-keep.conf" "$LOGDIR/caddy/access.log"
echo recent >"$LOGDIR/homevault/e2e-recent.log"
touch -d '3 days ago' "$LOGDIR/homevault/e2e-recent.log"
hvc logs clean >>"$LOG" 2>&1 || bail "hv logs clean 失败"
[[ ! -e $LOGDIR/homevault/e2e-old.log && ! -e $LOGDIR/containers/app-2000-01-01.log && ! -e $LOGDIR/backup/e2e-old.txt ]] ||
	bail "超过保留天数的日志未被删除"
[[ -e $LOGDIR/homevault/e2e-keep.conf && -e $LOGDIR/homevault/e2e-recent.log && -e $LOGDIR/caddy/access.log ]] ||
	bail "不应删除的文件被删除了"
pass "日志齐全（CLI/备份/Nextcloud/Caddy/面板），无密钥；过期日志已清理"

# ---------------------------------------------------------------------------- 10b. panel requests
step "面板请求：log-retention（经面板 API）、backup、非法请求"
code=$(papi -o "$WORK/ret.json" -w '%{http_code}' -H 'Content-Type: application/json' -X POST -d '{"days":5}' "$PBASE/api/settings/log-retention")
[[ $code == 202 ]] || bail "面板提交保留天数失败（HTTP $code）：$(cat "$WORK/ret.json")"
req=$(find "$APP/state/requests" -maxdepth 1 -name '*-log-retention.json' | head -n1)
[[ -n $req && $(stat -c %u "$req") == 65532 ]] || bail "面板没有写入 log-retention 请求文件"
bad=$(panel_request shell)
snaps_before=$(python3 -c 'import json,sys; print(" ".join(x["id"] for x in json.load(open(sys.argv[1]))))' "$APP/state/snapshots.json")
code=$(papi -o /dev/null -w '%{http_code}' -X POST "$PBASE/api/backup/run")
[[ $code == 202 ]] || bail "面板提交备份请求失败（HTTP $code）"
hvc requests process >>"$LOG" 2>&1 || bail "hv requests process 失败"
[[ -z $(find "$APP/state/requests" -maxdepth 1 -name '*.json') ]] || bail "仍有未处理的请求"
[[ $(env_get_file HV_LOG_RETENTION_DAYS "$APP/.env") == 5 ]] || bail ".env 中的保留天数未更新为 5"
jcheck "$APP/state/requests/done/$(basename "${req%.json}").result.json" "d['ok'] is True and d['type'] == 'log-retention'" || bail "log-retention 结果不对"
jcheck "$APP/state/requests/done/$bad.result.json" "d['ok'] is False" || bail "非法请求没有被拒绝"
done_backup=$(find "$APP/state/requests/done" -name '*-backup.result.json' | head -n1)
[[ -n $done_backup ]] || bail "backup 请求没有结果文件"
jcheck "$done_backup" "d['ok'] is True and d['type'] == 'backup'" || bail "backup 请求未成功执行：$(cat "$done_backup")"
jcheck "$APP/state/snapshots.json" "any(x['id'] not in '$snaps_before'.split() for x in d)" || bail "backup 请求没有产生新快照"
papi "$PBASE/api/settings/log-retention" | jcheck - "d['days'] == 5 and not d['pending']" || bail "面板显示的保留天数不是 5"
papi "$PBASE/api/backup" | jcheck - "any(r['state'] == 'ok' for r in d['recent'])" || bail "面板未显示备份请求结果"
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(hvc compose ps -q caddy)" | grep -qx 'HV_LOG_RETENTION_DAYS=5' ||
	bail "caddy 未以新的保留天数重建"
wait_status_ok || bail "caddy 重建后无法访问"
pass "请求已执行：保留天数 5（.env、面板、Caddy）、备份成功、非法请求被拒绝"

# ---------------------------------------------------------------------------- 10c. status files
step "状态文件（规范格式：panel/internal/hoststate/types.go）"
hvc status-update >>"$LOG" 2>&1 || bail "hv status-update 失败"
S=$APP/state/status.json
jcheck "$S" "set(d) == {'updated','version','platform','hostname','log_retention_days','log_dir','maintenance','requests','disks'}" || bail "status.json 字段不对"
jcheck "$S" "d['version'] == '1.0.0' and d['platform'] == 'linux' and d['log_retention_days'] == 5 and d['log_dir'] == '$LOGDIR'" || bail "status.json 内容不对"
jcheck "$S" "d['maintenance']['ok'] is True and d['maintenance']['last_run'] and d['requests']['last_run']" || bail "status.json 维护/请求时间缺失"
jcheck "$S" "{x['role'] for x in d['disks']} == {'data','storage','backup','system'} and all(set(x) == {'role','name','path','total','free','mounted'} for x in d['disks'])" ||
	bail "status.json disks 不对"
[[ ! -e $APP/state/vpn-status.json ]] || bail "未启用 VPN 时不应有 vpn-status.json"
[[ $(stat -c %a "$S") == 644 ]] || bail "status.json 权限不是 0644"
# error alerts other than "less than 10 % free" (CI runners and sandboxes often have full disks)
papi "$PBASE/api/overview" | jcheck - "d['status_updated'] and d['version'] == '1.0.0' and not [a for a in d['alerts'] if a['level'] == 'error' and '剩余空间不足' not in a['message']]" ||
	bail "面板概览有错误告警"
pass "status.json / backup-status.json / snapshots.json 与面板一致"

# ---------------------------------------------------------------------------- 11. doctor
step "hv doctor"
if ! hvc doctor >"$WORK/doctor.txt" 2>&1; then
	cat "$WORK/doctor.txt" >&2
	bail "doctor 报告了问题"
fi
grep -q '✔ 容器 app' "$WORK/doctor.txt" || bail "doctor 输出异常"
grep -q '✔ 容器 panel' "$WORK/doctor.txt" || bail "doctor 未检查面板容器"
grep -q '管理面板可访问' "$WORK/doctor.txt" || bail "doctor 未检查面板"
pass "doctor 通过（警告：$(grep -c '^  !' "$WORK/doctor.txt" || true) 个）"

printf '\n[e2e] 全部通过，用时 %d 秒\n' $((SECONDS - T0))
