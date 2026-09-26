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
#   E2E_MIRROR=daocloud   pass --mirror to install (e.g. behind the Great Firewall)
#   E2E_SKIP_FULL_RESTORE=1  skip the disaster-recovery round trip
set -Eeuo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $(id -u) -eq 0 ]] || {
	echo "e2e: 需要 root（请用 sudo -E $0）" >&2
	exit 1
}
for c in docker curl sha256sum tar; do
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
PROJECT="hve2e$(date +%s)$$"
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
SUBNET=$(free_subnet)
BASE=https://127.0.0.1:$HTTPS
USER_NAME=hvadmin
DAV=$BASE/remote.php/dav/files/$USER_NAME

ccurl() { curl -sS --max-time 120 --cacert "$WORK/ca.crt" "$@"; }
dav() { ccurl -u "$USER_NAME:$APPPW" "$@"; }
http_code() { ccurl -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }

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
pass "挂载可读写，apply 幂等"

# ---------------------------------------------------------------------------- 7. backup
step "备份（--init --check）"
hvc backup --init --check >>"$LOG" 2>&1 || bail "backup 失败"
[[ -s $APP/state/last-backup-ok ]] || bail "未写入 state/last-backup-ok"
grep -q '"result":"ok"' "$APP/state/backup-status.json" || bail "backup-status.json 未标记成功"
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

# ---------------------------------------------------------------------------- 10. logs / status files
step "日志与状态文件"
hvc maintenance >>"$LOG" 2>&1 || bail "hv maintenance 失败"
[[ -s $APP/state/status.json ]] || bail "缺少 state/status.json"
grep -q '"disks":\[' "$APP/state/status.json" || bail "status.json 格式异常"
ls "$WORK/data/logs/homevault/"hv-*.log >/dev/null 2>&1 || bail "缺少 CLI 日志"
grep -qF "$(cat "$APP/secrets/nextcloud_admin_password")" "$WORK/data/logs/homevault/"hv-*.log && bail "CLI 日志中出现了密码"
grep -qF "$(cat "$APP/secrets/restic_password")" "$WORK/data/logs/homevault/"hv-*.log "$WORK/data/logs/backup/"*.log && bail "日志中出现了 restic 密码"
pass "日志目录与状态文件正常，未泄露密钥"

# ---------------------------------------------------------------------------- 11. doctor
step "hv doctor"
if ! hvc doctor >"$WORK/doctor.txt" 2>&1; then
	cat "$WORK/doctor.txt" >&2
	bail "doctor 报告了问题"
fi
grep -q '✔ 容器 app' "$WORK/doctor.txt" || bail "doctor 输出异常"
pass "doctor 通过（警告：$(grep -c '^  !' "$WORK/doctor.txt" || true) 个）"

printf '\n[e2e] 全部通过，用时 %d 秒\n' $((SECONDS - T0))
