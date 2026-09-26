#!/usr/bin/env bash
# Optional, heavy: drive windows/hv.ps1 against a REAL stack on a Linux Docker host.
# pwsh runs in mcr.microsoft.com/powershell with the host's docker CLI + compose plugin and socket mounted;
# the throwaway copy of the repo is mounted at the same path so bind mounts resolve on the host.
# Windows-only parts (ACLs, firewall, WireGuard, Task Scheduler) are not exercised here.
# Covers: install --config-only, up --wait, status, occ, storage add/apply/remove (files_external sync),
# user add, harden, ca --export, backup --init (+ state/backup-status.json, snapshots.json, backup log),
# management panel (built image, stat mounts, /healthz through Caddy), CLI log, restore (list/--ls/--files/--full), down.
# Env: HV_E2E_KEEP=1 keep the temp dir and the stack; HV_E2E_PROJECT (default hvwin-e2e);
#      HV_E2E_PORT_BASE (default 28440 -> https 28443, http 28480, admin 28444, panel 28445).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${HV_PWSH_IMAGE:-mcr.microsoft.com/powershell:latest}
PROJECT=${HV_E2E_PROJECT:-hvwin-e2e}
BASE=${HV_E2E_PORT_BASE:-28440}
HTTPS=$((BASE + 3)) HTTP=$((BASE + 40)) ADMIN=$((BASE + 4)) PANEL=$((BASE + 5))
DOCKER_BIN=$(command -v docker)
PLUGIN=""
for d in /usr/libexec/docker/cli-plugins /usr/local/lib/docker/cli-plugins "$HOME/.docker/cli-plugins"; do
	[[ -x $d/docker-compose ]] && PLUGIN=$d/docker-compose && break
done
[[ -n $PLUGIN ]] || {
	echo "docker compose plugin not found" >&2
	exit 1
}

W=$(mktemp -d "${TMPDIR:-/tmp}/hv-pwsh-e2e.XXXXXX")
R=$W/repo
failures=0
ok() { printf '  ok   %s\n' "$*"; }
bad() {
	printf '  FAIL %s\n' "$*"
	failures=$((failures + 1))
}
# expect <description> <command...>: ok when the command succeeds
expect() {
	local desc=$1
	shift
	if "$@"; then ok "$desc"; else bad "$desc"; fi
}
has() { grep -qF -- "$2" <<<"$1"; }
hasre() { grep -qE -- "$2" <<<"$1"; }
# occ files_external:list --output=json escapes non-ASCII (\uXXXX): decode it -> "mount_point ro=<readonly> users=<a,b>"
mount_info() {
	python3 -c '
import json, sys
t = sys.stdin.read()
i = t.find("[")
for m in (json.loads(t[i:]) if i >= 0 else []):
    o = m.get("options") or {}
    ro = o.get("readonly", "") if isinstance(o, dict) else ""
    print(m["mount_point"], "ro=" + str(ro).lower(), "users=" + ",".join(m.get("applicable_users") or []))
'
}
lacks() { ! grep -qF -- "$2" <<<"$1"; }
cleanup() {
	if [[ ${HV_E2E_KEEP:-0} == 1 ]]; then
		echo "(kept $W, project $PROJECT)"
		return
	fi
	if [[ -f $R/.env ]]; then
		COMPOSE_PROJECT_NAME=$PROJECT docker compose -p "$PROJECT" --project-directory "$R" -f "$R/compose.yaml" -f "$R/compose.storage.yaml" \
			--env-file "$R/.env" --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
	fi
	docker run --rm -v "$W":"$W" alpine:3 rm -rf "$W/repo" "$W/photos" "$W/docs" >/dev/null 2>&1 || true
	rm -rf "$W"
}
trap cleanup EXIT

mkdir -p "$R" "$W/photos" "$W/docs"
cp -r "$ROOT/windows" "$ROOT/compose.yaml" "$ROOT/caddy" "$ROOT/nextcloud" "$ROOT/panel" "$ROOT/.env.example" "$R/"
[[ -f $ROOT/compose.acme.yaml ]] && cp "$ROOT/compose.acme.yaml" "$R/"
echo "hello from e2e" >"$W/photos/hello.txt"

hv() {
	docker run --rm -i -v "$W":"$W" -w "$R" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$DOCKER_BIN":/usr/local/bin/docker:ro -v "$PLUGIN":/usr/local/lib/docker/cli-plugins/docker-compose:ro \
		-e COMPOSE_PROJECT_NAME="$PROJECT" \
		"$IMAGE" pwsh -NoProfile -NonInteractive -File "$R/windows/hv.ps1" "$@"
}
dc() { COMPOSE_PROJECT_NAME=$PROJECT docker compose -p "$PROJECT" --project-directory "$R" -f "$R/compose.yaml" -f "$R/compose.storage.yaml" --env-file "$R/.env" "$@"; }

echo "== install --config-only"
hv install --config-only --non-interactive --host 127.0.0.1 --lan-ip 127.0.0.1 --lan-cidr 127.0.0.0/8 \
	--data-dir "$W/repo/hvdata" --backup-target local --backup-path "$W/repo/hvbackup" --no-vpn \
	--https-port "$HTTPS" --http-port "$HTTP" --admin-port "$ADMIN" --panel-port "$PANEL" --log-retention 10 \
	--storage "照片|$W/photos|rw|yes|" || bad "install --config-only"
LOGS=$R/hvdata/logs
# test-host tweaks: unique project/subnet; Linux bind mount must be writable by www-data (33)
sed -i "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$PROJECT/; s#^HV_FRONTEND_SUBNET=.*#HV_FRONTEND_SUBNET=172.31.207.0/24#" "$R/.env"
docker run --rm -v "$W":"$W" alpine:3 chown -R 33:33 "$R/hvdata/nextcloud-data" "$W/photos" "$W/docs" "$LOGS/nextcloud"
# Linux only (Docker Desktop bind mounts have no uid checks): the panel (uid 65532) writes its audit log and requests
docker run --rm -v "$W":"$W" alpine:3 chown -R 65532:65532 "$LOGS/panel" "$R/state/requests"
for d in homevault backup nextcloud caddy containers panel; do expect "log dir $d created" test -d "$LOGS/$d"; done
expect "retention written" grep -q '^HV_LOG_RETENTION_DAYS=10$' "$R/.env"
expect "panel port written" grep -q "^HV_PANEL_PORT=$PANEL\$" "$R/.env"
expect "panel stat mounts generated" grep -q 'target: /stat/storage/' "$R/compose.storage.yaml"

echo "== up --wait"
hv up --wait || bad "up --wait"
hv status >/dev/null || bad "status"
panel_state=missing
for _ in $(seq 1 40); do
	panel_state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$PROJECT-panel-1" 2>/dev/null || echo missing)
	[[ $panel_state == healthy ]] && break
	sleep 3
done
expect "panel container healthy ($panel_state)" test "$panel_state" = healthy
mounts=$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$PROJECT-panel-1" 2>/dev/null || true)
for t in /stat/data /stat/backup /config/storage.conf; do expect "panel mount $t read-only" has "$mounts" "$t false"; done
expect "panel mount /stat/storage/<slug>" has "$mounts" "/stat/storage/s"
hz=$(curl -sk --max-time 10 "https://127.0.0.1:$PANEL/healthz" || true)
expect "panel /healthz through Caddy on the panel port" test "$hz" = ok
expect "CLI log written" test -s "$LOGS/homevault/hv-$(date +%F).log"
out=$(hv occ status --output=json) || bad "occ status"
expect "occ status installed" has "$out" '"installed":true'

echo "== storage (files_external sync)"
hv storage apply || bad "storage apply"
list=$(hv occ files_external:list --output=json | mount_info)
expect "mount created" has "$list" '/照片 ro='
hv storage add --name 文档 --path "$W/docs" --mode ro --backup no --users hvadmin || bad "storage add + apply"
list=$(hv occ files_external:list --output=json | mount_info)
expect "second mount created" has "$list" '/文档 '
expect "second mount read-only" hasre "$list" '/文档 ro=(true|1) '
expect "second mount applicable user" hasre "$list" '/文档 ro=(true|1) users=hvadmin$'
expect "first mount stays read-write" hasre "$list" '/照片 ro=(false|0|) '
out=$(hv storage apply) || bad "storage apply (idempotent)"
expect "storage apply idempotent" has "$out" '已是最新'
hv storage remove 文档 --yes || bad "storage remove"
list=$(hv occ files_external:list --output=json | mount_info)
expect "mount deleted" lacks "$list" '/文档'
mounts=$(dc exec -T -u www-data app ls /mnt/hv/ 2>&1 || true)
expect "bind visible in app (/mnt/hv/s*)" has "$mounts" 's'

echo "== users / harden / ca"
out=$(hv user add alice --quota 1GB --display-name 测试用户) || bad "user add"
expect "user add prints password once" has "$out" '初始密码'
info=$(hv occ user:info alice || true)
expect "quota set" has "$info" 'quota: 1 GB'
hv harden >/dev/null || bad "harden"
out=$(hv ca --export "$R/state/ca.crt" || true)
expect "ca export + fingerprint" has "$out" 'SHA-256'

echo "== backup / restore"
hv backup --init || bad "backup --init"
expect "pg_dump written" test -s "$R/hvdata/dumps/nextcloud.sql"
expect "state/last-backup-ok written" test -f "$R/state/last-backup-ok"
bs=$(cat "$R/state/backup-status.json" 2>/dev/null || true)
expect "backup-status.json state ok" has "$bs" '"state": "ok"'
expect "backup-status.json stats" has "$bs" '"files_new":'
expect "backup-status.json exit code" has "$bs" '"exit_code": 0'
blog=$(sed -n 's/.*"log_file": "\(backup\/[^"]*\)".*/\1/p' <<<"$bs")
expect "backup log file ($blog)" test -s "$LOGS/$blog"
expect "snapshots.json is the restic JSON array" grep -q '^\[{"time"' "$R/state/snapshots.json"
hv backup >/dev/null || bad "second backup"
out=$(hv restore) || bad "restore (list)"
expect "snapshots listed" has "$out" 'homevault'
hv restore --ls /src/storage >/dev/null || bad "restore --ls"
hv restore --files /src/project/storage.conf || bad "restore --files"
restored=$(find "$R/restore" -path '*/src/project/storage.conf' 2>/dev/null | head -n1)
expect "file restored into restore/" test -n "$restored"
hv occ user:delete alice >/dev/null || bad "delete alice"
hv restore --full --yes || bad "restore --full"
after=$(hv occ user:list --output=json || true)
expect "restore --full brought back the deleted user" has "$after" '"alice"'

echo "== down"
hv down || bad "down"

echo
if ((failures > 0)); then
	echo "tests/pwsh/e2e.sh: $failures failure(s)"
	exit 1
fi
echo "tests/pwsh/e2e.sh: all passed"
