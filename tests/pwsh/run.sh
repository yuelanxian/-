#!/usr/bin/env bash
# PowerShell tests for the Windows CLI (windows/hv.ps1 + windows/lib/*.ps1).
#   1. static checks in mcr.microsoft.com/powershell: parse, UTF-8 BOM, PS 5.1 compatibility, templates
#   2. unit tests of the pure functions (slug vectors computed here in bash): unit.ps1 (CLI core), unit-ux.ps1 (logs/status/menu)
#   3. integration tests: hv.ps1 install --config-only / storage / ddns against throwaway copies
#   4. host side: `docker compose config` of the generated compose.storage.yaml / restore overlay /
#      generated .env with the real compose.yaml; node check of the rendered QR page (if node exists)
#   5. the state files hv.ps1 writes (backup-status / snapshots / status / vpn-status) decode with the panel's Go types
# Exits non-zero on any failure. Needs Docker. Env: HV_PWSH_IMAGE (default mcr.microsoft.com/powershell:latest),
# HV_GO_IMAGE (default golang:1.26-alpine; the Go check is skipped when the image is not available).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${HV_PWSH_IMAGE:-mcr.microsoft.com/powershell:latest}
GO_IMAGE=${HV_GO_IMAGE:-golang:1.26-alpine}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/hv-pwsh.XXXXXX")
cleanup() { rm -rf "$OUT"; }
trap cleanup EXIT

failures=0
step() { printf '\n== %s\n' "$*"; }
bad() {
	printf '  FAIL %s\n' "$*"
	failures=$((failures + 1))
}

command -v docker >/dev/null 2>&1 || {
	echo "tests/pwsh/run.sh: docker is required" >&2
	exit 1
}
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	docker pull "$IMAGE" >/dev/null || {
		echo "tests/pwsh/run.sh: cannot pull $IMAGE" >&2
		exit 1
	}
fi

run_pwsh() {
	docker run --rm -v "$ROOT":/w:ro -v "$OUT":"$OUT" -w /w "$IMAGE" pwsh -NoProfile -NonInteractive -File "$@"
}

# slug test vectors: must equal `printf '%s' "$path" | sha256sum` (the bash CLI's algorithm)
paths=('D:\Photos' 'E:\影视资料\2024' '/srv/archive/照片' "/tmp/it's dir" 'C:\Users\张 三\Pictures' "F:\\")
for p in "${paths[@]}"; do
	h=$(printf '%s' "$p" | sha256sum)
	printf '%s\t%s\n' "$p" "s${h:0:8}"
done >"$OUT/slug-vectors.tsv"

step "PowerShell static checks"
run_pwsh /w/tests/pwsh/checks.ps1 -Root /w || bad "checks.ps1"

step "PowerShell unit tests"
run_pwsh /w/tests/pwsh/unit.ps1 -Root /w -OutDir "$OUT" || bad "unit.ps1"

if [[ -f $ROOT/tests/pwsh/unit-ux.ps1 ]]; then
	step "PowerShell unit tests (logs / status / requests / menu modules)"
	run_pwsh /w/tests/pwsh/unit-ux.ps1 -Root /w -OutDir "$OUT" || bad "unit-ux.ps1"
fi

if [[ -f $ROOT/tests/pwsh/unit-sec.ps1 ]]; then
	step "PowerShell unit tests (review fixes: PS 5.1 arguments, panel mounts, planted links, backup lock)"
	run_pwsh /w/tests/pwsh/unit-sec.ps1 -Root /w -OutDir "$OUT/sec" || bad "unit-sec.ps1"
fi

step "PowerShell integration tests (repo .env.example)"
run_pwsh /w/tests/pwsh/integ.ps1 -Root /w -OutDir "$OUT/integ" || bad "integ.ps1"

step "PowerShell integration tests (fixture .env.example)"
run_pwsh /w/tests/pwsh/integ.ps1 -Root /w -OutDir "$OUT/integ-fixture" -UseFixtureEnvExample || bad "integ.ps1 -UseFixtureEnvExample"

step "compose validation of generated files"
cat >"$OUT/compose.min.yaml" <<'EOF'
services:
  app:
    image: alpine:3
    volumes:
      - html:/var/www/html
  cron:
    image: alpine:3
    volumes:
      - html:/var/www/html
  panel:
    image: alpine:3
    volumes:
      - ./state:/state
  backup:
    profiles: ["tools"]
    image: alpine:3
    volumes:
      - html:/src/nextcloud-html:ro
      - ${HV_NC_DATA_PATH:-/tmp/ncdata}:/src/nextcloud-data:ro
      - ${HV_VOL_CADDY_DATA:-caddy_data}:/src/caddy-data:ro
      - ${HV_DUMP_DIR:-hv_dumps}:/src/dumps:ro
volumes:
  html:
  nc_html:
  caddy_data:
  hv_dumps:
EOF
compose_ok() {
	local label=$1
	shift
	if docker compose -p hvpwshtest --project-directory "$OUT" "$@" config -q; then
		printf '  ok   %s\n' "$label"
	else
		bad "$label"
	fi
}
for variant in linux windows empty panelonly; do
	compose_ok "compose.storage.$variant.yaml" -f "$OUT/compose.min.yaml" -f "$OUT/compose.storage.$variant.yaml" --profile tools
done
# the Linux-path render must produce the expected mounts after merging
if merged=$(docker compose -p hvpwshtest --project-directory "$OUT" -f "$OUT/compose.min.yaml" -f "$OUT/compose.storage.linux.yaml" --profile tools config 2>/dev/null); then
	while IFS=$'\t' read -r slug path mode backup; do
		[[ -n $slug ]] || continue
		grep -qF "target: /mnt/hv/$slug" <<<"$merged" || bad "merged config lacks /mnt/hv/$slug ($path)"
		if [[ $backup == True || $backup == true ]]; then
			grep -qF "target: /src/storage/$slug" <<<"$merged" || bad "merged config lacks /src/storage/$slug"
		else
			grep -qF "target: /src/storage/$slug" <<<"$merged" && bad "/src/storage/$slug must not be mounted (backup=no)"
		fi
		grep -qF "source: $path" <<<"$merged" || grep -qF "source: '$path'" <<<"$merged" || grep -qF "source: \"$path\"" <<<"$merged" || bad "merged config lacks source $path"
		grep -qF "target: /stat/storage/$slug" <<<"$merged" || bad "merged config lacks panel stat mount /stat/storage/$slug"
		: "$mode"
	done <"$OUT/compose.storage.linux.expect"
	for t in /stat/data /stat/backup /config/storage.conf; do
		grep -qF "target: $t" <<<"$merged" || bad "merged config lacks panel mount $t"
	done
	printf '  ok   merged storage mounts\n'
	# the panel's ./state:/state from compose.yaml must be replaced (merged by target), not duplicated:
	# state read-only, only state/requests writable, state/requests/done read-only again
	if json=$(docker compose -p hvpwshtest --project-directory "$OUT" -f "$OUT/compose.min.yaml" -f "$OUT/compose.storage.linux.yaml" --profile tools config --format json 2>/dev/null) &&
		python3 - "$json" <<'PY'
import json, sys
vols = json.loads(sys.argv[1])["services"]["panel"]["volumes"]
by = {}
for v in vols:
    by.setdefault(v["target"], []).append(bool(v.get("read_only", False)))
ok = by.get("/state") == [True] and by.get("/state/requests") == [False] and by.get("/state/requests/done") == [True]
ok = ok and all(ro for t, l in by.items() for ro in l if t not in ("/state/requests",))
sys.exit(0 if ok else 1)
PY
	then printf '  ok   panel: state read-only, only state/requests writable\n'; else bad "panel state mounts after merge"; fi
else
	bad "merge of compose.storage.linux.yaml"
fi
# restore overlay must turn the backup sources read-write (merged by target path)
if merged=$(HV_NC_DATA_PATH=/tmp/ncdata docker compose -p hvpwshtest --project-directory "$OUT" -f "$OUT/compose.min.yaml" -f "$OUT/compose.restore.yaml" --profile tools config --format json 2>/dev/null); then
	if python3 - "$merged" <<'PY'
import json, sys
cfg = json.loads(sys.argv[1])
vols = cfg["services"]["backup"]["volumes"]
targets = {v["target"]: v.get("read_only", False) for v in vols}
need = ["/src/nextcloud-html", "/src/nextcloud-data", "/src/caddy-data", "/src/dumps"]
missing = [t for t in need if t not in targets]
ro = [t for t in need if targets.get(t)]
dup = len(vols) != len(targets)
sys.exit(1 if (missing or ro or dup) else 0)
PY
	then printf '  ok   restore overlay makes backup sources read-write\n'; else bad "restore overlay merge"; fi
else
	bad "restore overlay config"
fi
# generated .env + compose.storage.yaml against the real compose files (if the core files exist)
if [[ -f $ROOT/compose.yaml ]]; then
	for d in "$OUT/integ/main" "$OUT/integ-fixture/main"; do
		[[ -f $d/.env ]] || {
			bad "$d/.env missing"
			continue
		}
		compose_ok "real compose.yaml + generated .env ($(basename "$(dirname "$d")"))" \
			--project-directory "$d" -f "$d/compose.yaml" -f "$d/compose.storage.yaml" --env-file "$d/.env" --profile tools --profile ddns
	done
	d="$OUT/integ/acme"
	if [[ -f $d/compose.acme.yaml && -f $d/.env ]]; then
		compose_ok "real compose.yaml + compose.acme.yaml + generated .env (acme)" \
			--project-directory "$d" -f "$d/compose.yaml" -f "$d/compose.acme.yaml" -f "$d/compose.storage.yaml" --env-file "$d/.env"
	fi
fi

step "state files vs. the panel's Go types"
if [[ -d $ROOT/panel/internal/hoststate ]] && ! docker image inspect "$GO_IMAGE" >/dev/null 2>&1; then
	docker pull -q "$GO_IMAGE" >/dev/null 2>&1 || true
fi
if [[ -d $ROOT/panel/internal/hoststate ]] && docker image inspect "$GO_IMAGE" >/dev/null 2>&1; then
	mkdir -p "$OUT/gocheck/internal/hoststate" "$OUT/gocheck/cmd/statecheck"
	cp "$ROOT/panel/go.mod" "$OUT/gocheck/"
	for f in "$ROOT"/panel/internal/hoststate/*.go; do
		[[ $f == *_test.go ]] || cp "$f" "$OUT/gocheck/internal/hoststate/"
	done
	cp "$ROOT/tests/pwsh/statecheck/main.go" "$OUT/gocheck/cmd/statecheck/"
	docker run --rm -e GOTOOLCHAIN=local -e GOPROXY=off -e GOFLAGS=-mod=mod -e CGO_ENABLED=0 -e GOCACHE=/tmp/gocache \
		-v "$OUT":"$OUT" -w "$OUT/gocheck" "$GO_IMAGE" go run ./cmd/statecheck "$OUT/state" || bad "state files decode (Go)"
else
	printf '  skip panel sources or %s not available\n' "$GO_IMAGE"
fi

step "QR page (node)"
if command -v node >/dev/null 2>&1; then
	node "$ROOT/tests/pwsh/qr-check.js" "$OUT/vpn-qr.html" "$OUT/vpn-qr.expected.conf" || bad "qr-check.js"
else
	printf '  skip node not installed\n'
fi

echo
if ((failures > 0)); then
	echo "tests/pwsh: $failures failure(s)"
	exit 1
fi
echo "tests/pwsh: all passed"
