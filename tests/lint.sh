#!/usr/bin/env bash
# HomeVault static checks (Linux host with Docker; used locally and in CI).
#   1. shellcheck -x over every bash/sh file (hv, scripts/*.sh, nextcloud/hooks/**/*.sh, tests/**/*.sh)
#   2. hook sanity (shebang, php -l of the planner)
#   3. .env.example covers every variable referenced by the compose files
#   4. docker compose config matrix: profiles × compose.acme.yaml × sample compose.storage.yaml,
#      Linux + Windows env; published ports must carry an explicit IPv4 host_ip
#   5. Caddy: fmt check, validate tls-internal (stock image) and every acme snippet (image built
#      through compose.acme.yaml)
#   6. .gitattributes coverage, CR check, exec bits, runtime files not tracked
#   7. tests/pwsh/run.sh (PowerShell parse/unit tests) when present
#
# Environment:
#   HV_LINT_SKIP_ACME_BUILD=1  do not build the DNS-plugin Caddy image (acme snippets are validated
#                              only if homevault/caddy-dns:2.11.4 already exists, else skipped)
#   HV_BUILD_EXTRA_CA_FILE=F   PEM bundle with extra root CAs for the Caddy build behind a
#                              TLS-intercepting proxy (only certs missing from the builder are used)
#   HV_LINT_KEEP=1             keep the temporary directory
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

# ------------------------------------------------------------------------------------------ 3
section ".env.example"
env_keys=$(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' .env.example | sort)
dups=$(printf '%s\n' "$env_keys" | uniq -d)
if [[ -z $dups ]]; then ok "no duplicate keys"; else fail "duplicate keys in .env.example: $dups"; fi
if grep -q $'\r' .env.example; then fail ".env.example contains CR characters"; fi
# build-time only (multi-line PEM, passed through the shell environment)
not_in_env='HV_BUILD_EXTRA_CA_PEM'
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
EOF
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
		if [[ $services == 'app caddy cron db redis ' ]]; then
			ok "$platform: default services: $services"
		else
			fail "$platform: unexpected default services: $services"
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
		-e HV_HTTP_PORT=80 -e HV_HTTPS_PORT=443 -e HV_ADMIN_PORT=8443 \
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
	lf_re='(\.(sh|caddy|php|yaml|yml|conf|service|timer|html|js|md)$|(^|/)(hv|Caddyfile|\.env\.example)$)'
	crlf_re='\.ps1$'
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

	bad_x=0
	nx=0
	while IFS= read -r f; do
		[[ -f $f ]] || continue
		case "$f" in
		hv | scripts/*.sh | nextcloud/hooks/*.sh | tests/*.sh) ;; # case * also matches "/"
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

# ------------------------------------------------------------------------------------------
printf '\n'
if ((failures)); then
	printf 'lint: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
	exit 1
fi
printf 'lint: OK (%d warning(s))\n' "$warnings"
