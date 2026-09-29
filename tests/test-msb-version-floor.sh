#!/usr/bin/env bash
set -uo pipefail

# tests/test-msb-version-floor.sh -- rc's msb version floor (rip-cage-mssj).
# msb 0.7.3's --secret substitution drops any TLS request whose body contains
# '%' (superradcompany/microsandbox#1664, fixed in 0.7.4), so `rc up` refuses
# an msb below RC_MSB_MIN_VERSION and `rc doctor --host` reports the installed
# version against it. Host-only: every rc call runs behind the fake docker +
# msb of tests/_fake-runtime-lib.sh, whose `msb --version` answers
# FAKE_MSB_VERSION.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

FAKE_BIN=$(fake_runtime_bin)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/rc-vfl.XXXXXX")
trap 'rm -rf "$FAKE_BIN" "$SCRATCH"' EXIT
mkdir -p "${SCRATCH}/proj" "${SCRATCH}/home/.config"

# _rc VERSION ARGS... -- rc behind the fakes, with a scratch HOME and
# XDG_CONFIG_HOME so no real config or secret is read. Sets OUT, ERR, RC_EXIT.
_rc() {
  local _v="$1"; shift
  RC_EXIT=0
  OUT=$(cd "${SCRATCH}/proj" && PATH="${FAKE_BIN}:${PATH}" HOME="${SCRATCH}/home" \
    XDG_CONFIG_HOME="${SCRATCH}/home/.config" FAKE_MSB_VERSION="$_v" \
    "$RC" "$@" 2>"${SCRATCH}/err") || RC_EXIT=$?
  ERR=$(cat "${SCRATCH}/err")
}

# 1. The floor is one constant.
_n=$(grep -rn 'RC_MSB_MIN_VERSION=' "${REPO_ROOT}/rc" "${REPO_ROOT}/cli" | wc -l | tr -d ' ')
if [[ "$_n" == "1" ]] && grep -q 'RC_MSB_MIN_VERSION="0.7.4"' "${REPO_ROOT}/cli/lib/msb_runtime.sh"; then
  pass "one floor constant, 0.7.4, in cli/lib/msb_runtime.sh"
else
  fail "expected exactly one RC_MSB_MIN_VERSION=\"0.7.4\" assignment, found ${_n}"
fi

# 2. Below the floor: rc up refuses, naming the floor, the upstream issue and the upgrade.
_rc 0.7.3 --dry-run up "${SCRATCH}/proj"
if [[ "$RC_EXIT" -ne 0 ]] && [[ "$ERR" == *"0.7.4"* ]] && [[ "$ERR" == *"#1664"* ]] && [[ "$ERR" == *"msb update"* ]]; then
  pass "msb 0.7.3: rc up exits ${RC_EXIT}, naming floor 0.7.4, #1664 and 'msb update'"
else
  fail "msb 0.7.3: rc up exit=${RC_EXIT} stderr=${ERR}"
fi

# 3. Same refusal as JSON.
_rc 0.7.3 --dry-run --output json up "${SCRATCH}/proj"
if [[ "$RC_EXIT" -ne 0 ]] && [[ "$(printf '%s' "$OUT" | jq -r '.code' 2>/dev/null)" == "MSB_BELOW_FLOOR" ]]; then
  pass "msb 0.7.3: rc up --output json reports code MSB_BELOW_FLOOR"
else
  fail "msb 0.7.3 json: exit=${RC_EXIT} out=${OUT}"
fi

# 4. At or above the floor (numeric compare, not lexical): behaviour
#    unchanged -- rc up reaches cmd_up (its missing-config refusal), no floor
#    message, same exit code as at the floor itself.
_rc 0.7.4 --dry-run up "${SCRATCH}/proj"
_base_exit=$RC_EXIT
for _v in 0.7.4 0.7.10 0.8.0 1.0.0; do
  _rc "$_v" --dry-run up "${SCRATCH}/proj"
  if [[ "$RC_EXIT" -eq "$_base_exit" ]] && [[ "$ERR" == *"no cage config"* ]] && [[ "$ERR" != *"floor"* ]] && [[ "$ERR" != *"#1664"* ]]; then
    pass "msb ${_v}: rc up passes the floor (exit ${RC_EXIT}, no floor message)"
  else
    fail "msb ${_v}: exit=${RC_EXIT} (at-floor exit ${_base_exit}) stderr=${ERR}"
  fi
done

# 5. Only rc up checks the floor: rc destroy on an old msb never names it.
_rc 0.7.3 destroy no-such-cage
if [[ "$ERR" != *"floor"* ]]; then
  pass "msb 0.7.3: rc destroy is not gated by the floor"
else
  fail "msb 0.7.3: rc destroy refused on the floor: ${ERR}"
fi

# 6. rc doctor --host shows installed vs floor, and fails below it.
_rc 0.7.3 doctor --host
if [[ "$RC_EXIT" -ne 0 ]] && grep -qE '^msb version: +FAIL — 0\.7\.3 is below the floor 0\.7\.4' <<<"$OUT"; then
  pass "msb 0.7.3: rc doctor --host prints FAIL 0.7.3 vs floor 0.7.4 and exits non-zero"
else
  fail "msb 0.7.3 doctor: exit=${RC_EXIT} out=${OUT}"
fi
_rc 0.7.4 doctor --host
if grep -qE '^msb version: +OK — 0\.7\.4 \(floor 0\.7\.4\)' <<<"$OUT"; then
  pass "msb 0.7.4: rc doctor --host prints OK 0.7.4 (floor 0.7.4)"
else
  fail "msb 0.7.4 doctor: out=${OUT}"
fi
_rc 0.7.3 --output json doctor --host
if [[ "$(printf '%s' "$OUT" | jq -r '.msb_version + " " + .msb_floor' 2>/dev/null)" == "0.7.3 0.7.4" ]]; then
  pass "rc doctor --host --output json carries msb_version and msb_floor"
else
  fail "doctor json: out=${OUT}"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All msb version floor tests passed."
  exit 0
fi
echo "${FAILURES} msb version floor test(s) failed."
exit 1
