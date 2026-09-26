#!/usr/bin/env bash
# Unit tests for the pure functions of the Linux CLI (no Docker daemon needed; `docker compose config` is used when available).
# shellcheck disable=SC2034 # globals consumed by the sourced modules and test files
# Usage: tests/bash/run.sh [name-filter]
set -Eeuo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HV_ROOT=$(cd "$TESTS_DIR/../.." && pwd)
FIXTURES=$TESTS_DIR/fixtures
FILTER=${1:-}
HV_SELF=./hv
HV_VERSION='test'
for _l in C.UTF-8 C.utf8 en_US.UTF-8; do
	if locale -a 2>/dev/null | grep -qx "$_l"; then
		export LC_ALL=$_l
		break
	fi
done
export NO_COLOR=1

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hv-unit.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
# hv_mktemp inside the (sub-shelled) tests must not leave files in /tmp
export TMPDIR=$TMP_ROOT

# --- load the CLI modules (definitions only) -------------------------------
HV_ENV_FILE=$TMP_ROOT/unused.env
HV_STORAGE_CONF=$TMP_ROOT/storage.conf
HV_STORAGE_COMPOSE=$TMP_ROOT/compose.storage.yaml
HV_STATE_DIR=$TMP_ROOT/state
for m in lib env compose storage backup restore firewall vpn ddns users logs doctor install help; do
	# shellcheck source=/dev/null
	. "$HV_ROOT/scripts/$m.sh"
done
hv_version() { echo test; }
hv_tmpdir_init

# --- tiny assertion framework ----------------------------------------------
_T_FAILS=0
_T_CUR=''
fail() {
	printf '    ✘ %s\n' "$*" >&2
	_T_FAILS=$((_T_FAILS + 1))
}
assert_eq() { # expected actual [message]
	if [[ $1 != "$2" ]]; then
		fail "${3:-assert_eq}: expected [$1] got [$2]"
	fi
}
assert_contains() { # haystack needle [message]
	[[ $1 == *"$2"* ]] || fail "${3:-assert_contains}: [$2] not found in [$1]"
}
assert_not_contains() {
	[[ $1 != *"$2"* ]] || fail "${3:-assert_not_contains}: [$2] unexpectedly found"
}
assert_ok() { # command… (must succeed)
	("$@") >/dev/null 2>&1 || fail "expected success: $*"
}
assert_fail() {
	if ("$@") >/dev/null 2>&1; then fail "expected failure: $*"; fi
}
have_compose() { docker compose version >/dev/null 2>&1; }
json_valid() { # uses python3 / node / php when present, else skipped
	if command -v python3 >/dev/null; then
		python3 -c 'import json,sys; json.load(sys.stdin)'
	elif command -v node >/dev/null; then
		node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>JSON.parse(d))'
	elif command -v php >/dev/null; then
		php -r 'json_decode(stream_get_contents(STDIN), false, 512, JSON_THROW_ON_ERROR);'
	else
		cat >/dev/null
	fi
}
json_get() { # json_get <python-expr on d> ; reads JSON from stdin
	python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# --- run ---------------------------------------------------------------------
for f in "$TESTS_DIR"/test_*.sh; do
	# shellcheck source=/dev/null
	. "$f"
done

passed=0
failed=0
while IFS= read -r t; do
	[[ -z $FILTER || $t == *"$FILTER"* ]] || continue
	_T_CUR=$t
	before=$_T_FAILS
	# each test in a subshell: isolated globals; failures counted via exit status
	if (
		_T_FAILS=0
		set +e
		"$t"
		exit $((_T_FAILS > 0))
	); then
		printf '  ✔ %s\n' "$t"
		passed=$((passed + 1))
	else
		printf '  ✘ %s\n' "$t"
		failed=$((failed + 1))
	fi
	_T_FAILS=$before
done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
