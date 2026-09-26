#!/usr/bin/env bash
# HomeVault static checks (Linux host with Docker; used locally and in CI).
#   1. shellcheck -x over every bash/sh file (hv, scripts/*.sh, nextcloud/hooks/**/*.sh, tests/**/*.sh,
#      panel/**/*.sh)
#   2. hook sanity (shebang, php -l of the planner, planner log settings)
#   3. .env.example covers every variable referenced by the compose files
#   4. docker compose config matrix: profiles × compose.acme.yaml × sample compose.storage.yaml,
#      Linux + Windows env; published ports must carry an explicit IPv4 host_ip; default services;
#      panel / socket-proxy hardening (docker.sock only in socket-proxy, dockerapi internal, ...)
#   5. Caddy: fmt check, validate tls-internal (stock image) and every acme snippet (image built
#      through compose.acme.yaml)
#   6. .gitattributes coverage, CR check, binary attributes, exec bits, runtime files not tracked
#   7. tests/pwsh/run.sh (PowerShell parse/unit tests) when present
#   8. panel (Go): gofmt, go vet, go test (host Go with GOTOOLCHAIN=auto, else golang:1.26-alpine)
#   9. android: skipped (needs the Android SDK; built by .github/workflows/android.yml)
#
# Environment:
#   HV_LINT_SKIP_ACME_BUILD=1  do not build the DNS-plugin Caddy image (acme snippets are validated
#                              only if homevault/caddy-dns:2.11.4 already exists, else skipped)
#   HV_BUILD_EXTRA_CA_FILE=F   PEM bundle with extra root CAs for the Caddy build behind a
#                              TLS-intercepting proxy (only certs missing from the builder are used)
#   HV_LINT_KEEP=1             keep the temporary directory
#   HV_LINT_SKIP_GO=1          skip the panel Go checks
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

failures=0
warnings=0
section() { printf '\n== %s\n' "$*"; }
ok() { printf '  ok   %s\n' "$*"; }
fail() {
	printf '  FAIL %s\n' "$*"
	failures=$((failures + 1))
}
warn() {
	printf '  warn %s\n' "$*"
	warnings=$((warnings + 1))
}
skip() { printf '  skip %s\n' "$*"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hv-lint.XXXXXX")
cleanup() {
	if [[ ${HV_LINT_KEEP:-0} == 1 ]]; then
		printf '\n(kept %s)\n' "$TMP"
	else
		rm -rf "$TMP"
	fi
}
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }
have_docker() { have docker && docker info >/dev/null 2>&1; }

# Non-ignored files of the working tree (tracked + untracked).
repo_files() {
	git -C "$ROOT" ls-files --cached --others --exclude-standard 2>/dev/null | sort -u
}

# ------------------------------------------------------------------------------------------ 1
section "shellcheck"
sh_files=()
[[ -f hv ]] && sh_files+=(hv)
while IFS= read -r f; do sh_files+=("$f"); done < <(
	{
		find scripts -maxdepth 1 -type f -name '*.sh' 2>/dev/null
		find nextcloud/hooks -type f -name '*.sh' 2>/dev/null
		find tests -type f -name '*.sh' 2>/dev/null
		find panel -type f -name '*.sh' 2>/dev/null
	} | sort -u
)
if ! have shellcheck; then
	fail "shellcheck not installed"
elif [[ ${#sh_files[@]} -eq 0 ]]; then
	warn "no shell files found"
else
	if shellcheck -x "${sh_files[@]}"; then
		ok "shellcheck -x: ${#sh_files[@]} files"
	else
		fail "shellcheck reported problems"
	fi
fi

# ------------------------------------------------------------------------------------------ 2
section "Nextcloud hooks"
for stage in pre-installation post-installation before-starting post-upgrade; do
	f=nextcloud/hooks/$stage/10-homevault.sh
	if [[ ! -f $f ]]; then
		fail "$f missing"
		continue
	fi
	[[ $(head -n1 "$f") == '#!/bin/sh' ]] || fail "$f: first line must be #!/bin/sh (runs via su -s /bin/sh)"
done
# the entrypoint only runs top-level *.sh; anything else there is a mistake
while IFS= read -r f; do
	fail "unexpected file in a hook stage directory: $f"
done < <(find nextcloud/hooks -mindepth 2 -maxdepth 2 -type f ! -name '*.sh' ! -path 'nextcloud/hooks/lib/*' 2>/dev/null)
NC_IMAGE=$(sed -n 's/^NEXTCLOUD_IMAGE=//p' .env.example)
if have php; then
	if php -l nextcloud/hooks/lib/plan.php >/dev/null; then ok "php -l plan.php"; else fail "php -l plan.php"; fi
elif have_docker && docker image inspect "$NC_IMAGE" >/dev/null 2>&1; then
	if docker run --rm -v "$ROOT/nextcloud/hooks/lib:/l:ro" --entrypoint php "$NC_IMAGE" -l /l/plan.php >/dev/null; then
		ok "php -l plan.php ($NC_IMAGE)"
	else
		fail "php -l plan.php"
	fi
else
	warn "php not available (host or local $NC_IMAGE image): plan.php not syntax-checked"
fi
# planner: Nextcloud log settings (SPEC §14) when the log directory is writable
plan_dir=$TMP/plan
mkdir -p "$plan_dir/logs"
chmod 0777 "$plan_dir" "$plan_dir/logs"
printf '{"system":{},"apps":{}}\n' >"$plan_dir/current.json"
plan_rc=skip
if have php; then
	HV_NC_LOG_DIR=$plan_dir/logs HV_TRUSTED_DOMAINS=192.168.77.10 HV_TZ=Asia/Shanghai \
		php nextcloud/hooks/lib/plan.php "$plan_dir/current.json" "$plan_dir/import.json" >"$plan_dir/out" 2>&1
	plan_rc=$?
elif have_docker && docker image inspect "$NC_IMAGE" >/dev/null 2>&1; then
	docker run --rm --network none -u 33:33 -v "$ROOT/nextcloud/hooks/lib:/l:ro" -v "$plan_dir:$plan_dir" \
		-e HV_NC_LOG_DIR="$plan_dir/logs" -e HV_TRUSTED_DOMAINS=192.168.77.10 -e HV_TZ=Asia/Shanghai \
		--entrypoint php "$NC_IMAGE" /l/plan.php "$plan_dir/current.json" "$plan_dir/import.json" >"$plan_dir/out" 2>&1
	plan_rc=$?
fi
if [[ $plan_rc == skip ]]; then
	warn "php not available: plan.php log settings not checked"
elif [[ $plan_rc == 0 ]] && grep -q '^SYS ' "$plan_dir/out" &&
	grep -qF "\"logfile\": \"$plan_dir/logs/nextcloud.log\"" "$plan_dir/import.json" &&
	grep -qF "\"logfile_audit\": \"$plan_dir/logs/audit.log\"" "$plan_dir/import.json" &&
	grep -qF '"log_rotate_size": 52428800' "$plan_dir/import.json" &&
	grep -qF '"log_type": "file"' "$plan_dir/import.json" &&
	grep -qF '"logtimezone": "Asia/Shanghai"' "$plan_dir/import.json"; then
	ok "plan.php plans logfile / logfile_audit / log_rotate_size / logtimezone"
else
	fail "plan.php log settings: rc=$plan_rc $(cat "$plan_dir/out") $(cat "$plan_dir/import.json" 2>/dev/null)"
fi

# ------------------------------------------------------------------------------------------ 3
section ".env.example"
env_keys=$(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' .env.example | sort)
dups=$(printf '%s\n' "$env_keys" | uniq -d)
if [[ -z $dups ]]; then ok "no duplicate keys"; else fail "duplicate keys in .env.example: $dups"; fi
if grep -q $'\r' .env.example; then fail ".env.example contains CR characters"; fi
# build-time only (multi-line PEM, passed through the shell environment); HV_VERSION is exported by
# hv / hv.ps1 when they run compose (informational for the panel, may be empty)
not_in_env='HV_BUILD_EXTRA_CA_PEM HV_VERSION'
missing=''
while IFS= read -r v; do
	[[ " $not_in_env " == *" $v "* ]] && continue
	printf '%s\n' "$env_keys" | grep -qx "$v" || missing+=" $v"
done < <(cat compose.yaml compose.acme.yaml | grep -v '^[[:space:]]*#' | grep -oE '\$\{[A-Z_][A-Z0-9_]*' | sed 's/^\${//' | sort -u)
if [[ -z $missing ]]; then ok "every compose variable is documented"; else fail "missing from .env.example:$missing"; fi

# ------------------------------------------------------------------------------------------ 4
section "docker compose config matrix"
make_env() { # dir platform [extra args...]
	local dir=$1 platform=$2
	shift 2
	bash tests/lib/make-test-env.sh "$dir" --platform "$platform" --copy-repo --no-chown \
		--project "hvlint-$platform" --host 192.168.77.10 --bind-ip 192.168.77.10 \
		--https-port 443 --http-port 80 --admin-port 8443 "$@" >/dev/null
}
write_storage_sample() { # dir
	local d=$1
	mkdir -p "$d/data/storage-rw" "$d/data/storage-ro"
	cat >"$d/compose.storage.yaml" <<EOF
# sample of the file generated by "hv storage apply"
services:
  app:
    volumes:
      - type: bind
        source: $d/data/storage-rw
        target: /mnt/hv/s0123abcd
      - type: bind
        source: $d/data/storage-ro
        target: /mnt/hv/s4567ef01
        read_only: true
  cron:
    volumes:
      - type: bind
        source: $d/data/storage-rw
        target: /mnt/hv/s0123abcd
      - type: bind
        source: $d/data/storage-ro
        target: /mnt/hv/s4567ef01
        read_only: true
  backup:
    volumes:
      - type: bind
        source: $d/data/storage-rw
        target: /src/storage/s0123abcd
        read_only: true
  panel:
    volumes:
      - type: bind
        source: $d/data/nextcloud-data
        target: /stat/data
        read_only: true
      - type: bind
        source: $d/data/backup-repo
        target: /stat/backup
        read_only: true
      - type: bind
        source: $d/data/storage-rw
        target: /stat/storage/s0123abcd
        read_only: true
      - type: bind
        source: $d/data/storage-ro
        target: /stat/storage/s4567ef01
        read_only: true
      - type: bind
        source: $d/storage.conf
        target: /config/storage.conf
        read_only: true
EOF
	printf '# 名称|主机路径|rw或ro|是否备份(yes/no)|可见用户\n' >"$d/storage.conf"
}

if ! have_docker || ! docker compose version >/dev/null 2>&1; then
	fail "docker / docker compose not available"
else
	for platform in linux windows; do
		d=$TMP/compose-$platform
		if [[ $platform == linux ]]; then
			make_env "$d" linux --vpn || fail "make-test-env ($platform)"
			profiles=(none vpn ddns tools monitor all)
		else
			make_env "$d" windows || fail "make-test-env ($platform)"
			profiles=(none ddns tools)
		fi
		write_storage_sample "$d"
		n=0
		for p in "${profiles[@]}"; do
			for acme in 0 1; do
				for storage in 0 1; do
					files=(-f "$d/compose.yaml")
					((acme)) && files+=(-f "$d/compose.acme.yaml")
					((storage)) && files+=(-f "$d/compose.storage.yaml")
					case "$p" in
					none) prof=() ;;
					all) prof=(--profile vpn --profile ddns --profile tools --profile monitor) ;;
					*) prof=(--profile "$p") ;;
					esac
					if out=$(docker compose --project-directory "$d" "${files[@]}" --env-file "$d/.env" "${prof[@]}" config -q 2>&1) && [[ -z $out ]]; then
						n=$((n + 1))
					else
						fail "compose config ($platform, profile=$p, acme=$acme, storage=$storage): $out"
					fi
				done
			done
		done
		ok "$platform: $n profile/overlay combinations valid"

		# published ports: explicit host_ip, never IPv6/any-v6
		json=$(docker compose --project-directory "$d" -f "$d/compose.yaml" --env-file "$d/.env" \
			--profile vpn --profile ddns --profile tools --profile monitor config --format json 2>/dev/null)
		published=$(grep -c '"published"' <<<"$json" || true)
		hostips=$(grep -c '"host_ip": "[0-9.]*"' <<<"$json" || true)
		if [[ $published -gt 0 && $published == "$hostips" ]]; then
			ok "$platform: all $published published ports have an explicit IPv4 host_ip"
		else
			fail "$platform: $published published ports but $hostips IPv4 host_ip entries"
		fi
		services=$(docker compose --project-directory "$d" -f "$d/compose.yaml" --env-file "$d/.env" config --services 2>/dev/null | sort | tr '\n' ' ')
		if [[ $services == 'app caddy cron db panel redis socket-proxy ' ]]; then
			ok "$platform: default services: $services"
		else
			fail "$platform: unexpected default services: $services"
		fi

		# management panel + Docker API proxy hardening (SPEC §15), with the sample storage overlay
		docker compose --project-directory "$d" -f "$d/compose.yaml" -f "$d/compose.storage.yaml" --env-file "$d/.env" \
			--profile vpn --profile ddns --profile tools --profile monitor config --format json >"$d/config.json" 2>/dev/null
		if ! have python3; then
			warn "$platform: python3 not available: panel/socket-proxy hardening not checked"
		elif msg=$(python3 - "$d/config.json" <<'PYCHECK'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
s, nets = d["services"], d["networks"]
errs = []
vols = lambda name: s[name].get("volumes", [])
for name in s:
    for v in vols(name):
        if "docker.sock" in str(v.get("source", "")) and name != "socket-proxy":
            errs.append(name + " mounts the Docker socket")
    if name not in ("panel", "socket-proxy") and "dockerapi" in (s[name].get("networks") or {}):
        errs.append(name + " is on the dockerapi network")
p, sp = s["panel"], s["socket-proxy"]
if str(p.get("user")) != "65532:65532":
    errs.append("panel: user must be 65532:65532")
for name in ("panel", "socket-proxy"):
    svc = s[name]
    if not svc.get("read_only"):
        errs.append(name + ": read_only missing")
    if svc.get("cap_drop") != ["ALL"] or svc.get("cap_add"):
        errs.append(name + ": must drop ALL capabilities")
    if "no-new-privileges:true" not in svc.get("security_opt", []):
        errs.append(name + ": no-new-privileges missing")
    if svc.get("ports"):
        errs.append(name + ": must not publish ports")
if sorted(p.get("networks") or {}) != ["dockerapi", "frontend"]:
    errs.append("panel networks: %s" % sorted(p.get("networks") or {}))
if sorted(sp.get("networks") or {}) != ["dockerapi"]:
    errs.append("socket-proxy networks: %s" % sorted(sp.get("networks") or {}))
if not nets.get("dockerapi", {}).get("internal"):
    errs.append("dockerapi network must be internal")
sock = [v for v in vols("socket-proxy") if v.get("target") == "/var/run/docker.sock"]
if not sock or not sock[0].get("read_only"):
    errs.append("socket-proxy: docker.sock must be mounted read-only")
env = sp.get("environment") or {}
want = {"CONTAINERS": "1", "ALLOW_LOGS": "1", "ALLOW_RESTARTS": "1", "INFO": "1", "VERSION": "1", "PING": "1",
        "POST": "0", "EXEC": "0", "IMAGES": "0", "VOLUMES": "0", "NETWORKS": "0", "BUILD": "0", "EVENTS": "0",
        "SYSTEM": "0", "ALLOW_ARCHIVE": "0", "ALLOW_EXPORT": "0", "ALLOW_START": "0", "ALLOW_STOP": "0"}
for k, v in want.items():
    if env.get(k) != v:
        errs.append("socket-proxy: %s=%r (want %r)" % (k, env.get(k), v))
pv = {v.get("target"): v for v in vols("panel")}
for t in ("/logs", "/ca", "/stat/data", "/stat/backup", "/config/storage.conf"):
    if not pv.get(t, {}).get("read_only"):
        errs.append("panel: %s must be mounted read-only" % t)
for t, v in pv.items():
    if str(t).startswith("/stat") and not v.get("read_only"):
        errs.append("panel: %s must be read-only" % t)
    if str(v.get("source", "")).rstrip("/").endswith(("caddy_data", "caddy-data")):
        errs.append("panel must not mount the Caddy data (CA private key)")
if "/state" not in pv or "/logs/panel" not in pv:
    errs.append("panel: /state and /logs/panel mounts required")
penv = p.get("environment") or {}
if penv.get("DOCKER_HOST") != "tcp://socket-proxy:2375":
    errs.append("panel: DOCKER_HOST must be tcp://socket-proxy:2375")
if penv.get("CA_CERT_FILE") != "/ca/root.crt":
    errs.append("panel: CA_CERT_FILE must be /ca/root.crt")
hc = (p.get("healthcheck") or {}).get("test") or []
if "/panel" not in hc or "healthcheck" not in hc:
    errs.append("panel healthcheck: %s" % hc)
print("; ".join(errs))
sys.exit(1 if errs else 0)
PYCHECK
		); then
			ok "$platform: panel / socket-proxy hardening"
		else
			fail "$platform: $msg"
		fi
	done
fi

# ------------------------------------------------------------------------------------------ 5
section "Caddy"
CADDY_IMAGE=$(sed -n 's/^CADDY_IMAGE=//p' .env.example)
ACME_IMAGE=homevault/caddy-dns:2.11.4

caddy_validate() { # image tls_snippet admin_snippet site_addresses host [extra -e args...]
	local image=$1 tls=$2 admin=$3 sites=$4 host=$5
	shift 5
	docker run --rm --network none -v "$ROOT/caddy:/etc/caddy:ro" \
		-e HV_HOST="$host" -e HV_SITE_ADDRESSES="$sites" \
		-e HV_ALLOWED_CIDRS='private_ranges 100.64.0.0/10' \
		-e HV_HTTP_PORT=80 -e HV_HTTPS_PORT=443 -e HV_ADMIN_PORT=8443 -e HV_PANEL_PORT=9443 -e HV_LOG_RETENTION_DAYS=7 \
		-e HV_TLS_SNIPPET="$tls" -e HV_ADMIN_SNIPPET="$admin" -e HV_ACME_EMAIL=hv-lint@homevault.test \
		"$@" "$image" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >"$TMP/caddy.out" 2>&1
}

# minimal extra CA set: certs of $1 that are not already in the builder image's bundle
extra_ca_pem() {
	local src=$1 builder=$2
	docker run --rm --entrypoint cat "$builder" /etc/ssl/certs/ca-certificates.crt >"$TMP/builder-ca.pem" 2>/dev/null || : >"$TMP/builder-ca.pem"
	awk -v known="$TMP/builder-ca.pem" '
		BEGIN { while ((getline l < known) > 0) { if (l ~ /BEGIN CERT/) c = ""; c = c l "\n"; if (l ~ /END CERT/) seen[c] = 1 } }
		/BEGIN CERT/ { c = "" } { c = c $0 "\n" } /END CERT/ { if (!(c in seen)) printf "%s", c }
	' "$src"
}

if ! have_docker; then
	fail "docker not available: Caddy checks skipped"
else
	fmt_bad=0
	for f in caddy/Caddyfile caddy/snippets/*.caddy; do
		if ! docker run --rm --network none -v "$ROOT/caddy:/etc/caddy:ro" "$CADDY_IMAGE" \
			caddy fmt "/etc/$f" >"$TMP/fmt.out" 2>&1 || ! cmp -s "$f" "$TMP/fmt.out"; then
			fail "caddy fmt would change $f"
			fmt_bad=1
		fi
	done
	((fmt_bad)) || ok "caddy fmt: all files formatted"

	for admin in none wgeasy; do
		for sites in 'https://192.168.77.10:443' 'https://192.168.77.10:18443, https://10.99.77.1:18443'; do
			if caddy_validate "$CADDY_IMAGE" internal "$admin" "$sites" 192.168.77.10; then
				ok "validate tls-internal admin=$admin sites=[$sites]"
			else
				fail "validate tls-internal admin=$admin sites=[$sites]: $(tail -n 3 "$TMP/caddy.out")"
			fi
		done
	done

	built=0
	if [[ ${HV_LINT_SKIP_ACME_BUILD:-0} == 1 ]]; then
		if docker image inspect "$ACME_IMAGE" >/dev/null 2>&1; then
			built=1
			warn "HV_LINT_SKIP_ACME_BUILD=1: using existing $ACME_IMAGE"
		else
			warn "HV_LINT_SKIP_ACME_BUILD=1 and no $ACME_IMAGE: acme snippets not validated"
		fi
	else
		d=$TMP/acme-build
		bash tests/lib/make-test-env.sh "$d" --copy-repo --no-chown --project hvlint-acme \
			--host nas.homevault.test --tls-mode acme-alidns >/dev/null
		if [[ -n ${HV_BUILD_EXTRA_CA_FILE:-} ]]; then
			builder=$(sed -n 's/^CADDY_BUILDER_IMAGE=//p' .env.example)
			HV_BUILD_EXTRA_CA_PEM=$(extra_ca_pem "$HV_BUILD_EXTRA_CA_FILE" "$builder")
			export HV_BUILD_EXTRA_CA_PEM
		fi
		printf '  ...  building %s via compose.acme.yaml (first build takes a few minutes)\n' "$ACME_IMAGE"
		if docker compose --project-directory "$d" -f "$d/compose.yaml" -f "$d/compose.acme.yaml" \
			--env-file "$d/.env" build caddy >"$TMP/build.log" 2>&1; then
			built=1
			ok "built $ACME_IMAGE"
		else
			fail "building $ACME_IMAGE failed: $(tail -n 5 "$TMP/build.log")"
		fi
		unset HV_BUILD_EXTRA_CA_PEM
	fi
	if ((built)); then
		mods=$(docker run --rm --network none "$ACME_IMAGE" caddy list-modules 2>/dev/null | grep -c '^dns\.providers\.\(alidns\|tencentcloud\|cloudflare\)$')
		if [[ $mods == 3 ]]; then
			ok "$ACME_IMAGE has dns.providers alidns/tencentcloud/cloudflare"
		else
			fail "$ACME_IMAGE: expected 3 DNS provider modules, found $mods"
		fi
		for p in alidns tencentcloud cloudflare; do
			for admin in none wgeasy; do
				if caddy_validate "$ACME_IMAGE" "acme-$p" "$admin" 'https://nas.homevault.test:443' nas.homevault.test \
					-e ALIYUN_ACCESS_KEY_ID=dummy -e ALIYUN_ACCESS_KEY_SECRET=dummy \
					-e TENCENTCLOUD_SECRET_ID=dummy -e TENCENTCLOUD_SECRET_KEY=dummy \
					-e CF_API_TOKEN=dummy-cloudflare-token-0123456789abcdef; then
					ok "validate tls-acme-$p admin=$admin"
				else
					fail "validate tls-acme-$p admin=$admin: $(tail -n 3 "$TMP/caddy.out")"
				fi
			done
		done
	fi
fi

# ------------------------------------------------------------------------------------------ 6
section ".gitattributes / line endings / exec bits"
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	warn "not a git work tree: attribute checks skipped"
else
	lf_re='(\.(sh|caddy|php|yaml|yml|conf|service|timer|path|html|js|mjs|css|json|md|go|kt|kts|xml|properties|webmanifest)$|(^|/)(hv|Caddyfile|Dockerfile|gradlew|go\.mod|\.env\.example)$)'
	crlf_re='\.(ps1|cmd|bat)$'
	bin_re='\.(png|jpg|webp|ico|jar|apk|jks|keystore)$'
	bad_attr=0
	checked=0
	while IFS= read -r f; do
		[[ -f $f ]] || continue
		want=''
		if [[ $f =~ $crlf_re ]]; then
			want=crlf
		elif [[ $f =~ $lf_re ]]; then
			want=lf
		fi
		[[ -n $want ]] || continue
		checked=$((checked + 1))
		got=$(git -C "$ROOT" check-attr eol -- "$f" | sed 's/.*: eol: //')
		if [[ $got != "$want" ]]; then
			fail "$f: eol=$got (want $want)"
			bad_attr=1
		fi
		if [[ $want == lf ]] && grep -q $'\r' "$f"; then
			fail "$f contains CR characters"
			bad_attr=1
		fi
	done < <(repo_files)
	((bad_attr)) || ok "eol attributes correct for $checked files"

	bad_bin=0
	while IFS= read -r f; do
		[[ $f =~ $bin_re ]] || continue
		if [[ $(git -C "$ROOT" check-attr binary -- "$f" | sed 's/.*: binary: //') != set ]]; then
			fail "$f is not marked binary in .gitattributes"
			bad_bin=1
		fi
	done < <(repo_files)
	((bad_bin)) || ok "binary files marked binary"

	bad_x=0
	nx=0
	while IFS= read -r f; do
		[[ -f $f ]] || continue
		case "$f" in
		hv | scripts/*.sh | nextcloud/hooks/*.sh | tests/*.sh | panel/*.sh | android/gradlew) ;; # case * also matches "/"
		*) continue ;;
		esac
		nx=$((nx + 1))
		if [[ ! -x $f ]]; then
			fail "$f is not executable (chmod +x)"
			bad_x=1
		fi
		mode=$(git -C "$ROOT" ls-files -s -- "$f" | awk '{print $1}')
		if [[ -n $mode && $mode != 100755 ]]; then
			fail "$f is tracked with mode $mode (git update-index --chmod=+x)"
			bad_x=1
		fi
	done < <(repo_files)
	((bad_x)) || ok "exec bit set on $nx scripts"

	tracked_runtime=$(git -C "$ROOT" ls-files -- .env secrets state clients data restore storage.conf compose.storage.yaml 2>/dev/null)
	if [[ -z $tracked_runtime ]]; then ok "no runtime files tracked"; else fail "runtime files are tracked: $tracked_runtime"; fi
	for p in .env secrets/x storage.conf compose.storage.yaml state/x clients/x data/x restore/x; do
		git -C "$ROOT" check-ignore -q "$p" || fail ".gitignore does not ignore $p"
	done
fi

# ------------------------------------------------------------------------------------------ 7
section "PowerShell"
if [[ -f tests/pwsh/run.sh ]]; then
	if bash tests/pwsh/run.sh; then ok "tests/pwsh/run.sh"; else fail "tests/pwsh/run.sh"; fi
else
	warn "tests/pwsh/run.sh not present"
fi

# ------------------------------------------------------------------------------------------ 8
section "panel (Go)"
# gofmt + vet + tests of the stdlib-only module in panel/ (run from panel/)
go_checks() {
	local bad
	bad=$(gofmt -l .) || return 1
	if [[ -n $bad ]]; then
		printf 'gofmt: not formatted:\n%s\n' "$bad"
		return 1
	fi
	go vet ./... && go test -count=1 ./...
}
if [[ ${HV_LINT_SKIP_GO:-0} == 1 ]]; then
	skip "HV_LINT_SKIP_GO=1"
elif [[ ! -f panel/go.mod ]]; then
	warn "panel/go.mod missing: Go checks skipped"
elif have go; then
	# go.mod says "go 1.26": an older host Go downloads that toolchain (GOTOOLCHAIN=auto)
	go_toolchain=${GOTOOLCHAIN:-auto}
	if (cd panel && GOTOOLCHAIN=$go_toolchain CGO_ENABLED=0 go_checks) >"$TMP/go.log" 2>&1; then
		ok "panel: gofmt / go vet / go test ($(cd panel && GOTOOLCHAIN=$go_toolchain go env GOVERSION 2>/dev/null))"
	else
		fail "panel Go checks: $(tail -n 30 "$TMP/go.log")"
	fi
elif have_docker; then
	go_image=golang:1.26-alpine
	# stdlib only: no module download, no network
	if docker run --rm --network none -v "$ROOT/panel:/src:ro" -w /src \
		-e CGO_ENABLED=0 -e GOTOOLCHAIN=local -e GOPROXY=off -e GOFLAGS=-buildvcs=false -e GOCACHE=/tmp/gocache \
		"$go_image" sh -c 'bad=$(gofmt -l .) && [ -z "$bad" ] || { echo "gofmt: $bad"; exit 1; }; go vet ./... && go test -count=1 ./...' \
		>"$TMP/go.log" 2>&1; then
		ok "panel: gofmt / go vet / go test ($go_image)"
	else
		fail "panel Go checks ($go_image): $(tail -n 30 "$TMP/go.log")"
	fi
else
	warn "neither Go nor Docker available: panel Go checks skipped"
fi

# ------------------------------------------------------------------------------------------ 9
section "android"
skip "Android lint/build needs the Android SDK: see .github/workflows/android.yml (./gradlew lint assembleDebug)"

# ------------------------------------------------------------------------------------------
printf '\n'
if ((failures)); then
	printf 'lint: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
	exit 1
fi
printf 'lint: OK (%d warning(s))\n' "$warnings"
