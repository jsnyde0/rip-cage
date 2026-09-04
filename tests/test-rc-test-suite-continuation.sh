#!/usr/bin/env bash
# tests/test-rc-test-suite-continuation.sh -- regression guard for
# rip-cage-83y6: `rc test <cage>` (human/non-json output path) must run
# ALL FOUR in-cage suites (test-safety-stack.sh, test-skills.sh,
# test-bd-roundtrip.sh, run-recipe-smokes.sh) even when an earlier one
# fails, and must still exit non-zero overall when any of them failed.
#
# Root cause: `rc` runs `set -euo pipefail`; cli/test.sh's non-json branch
# called the four suites bare (`_msb_exec ... suiteN.sh`, no `||`/`if`
# guard), so a non-zero exit from an earlier suite aborted the function
# before later suites -- in particular run-recipe-smokes.sh -- ever ran.
# The json branch immediately above already collected exit status per
# suite and never let one abort the rest; this test pins the non-json
# branch to the same shape.
#
# Drives the REAL `rc` entrypoint (so the real `set -euo pipefail` context
# that causes the bug is in effect) against a PATH-stubbed `msb` binary --
# HOST_ONLY, no live cage, no credentials, no composed image (bead
# rip-cage-83y6's hard constraint). `msb exec ... <suite>.sh` is stubbed to
# print a distinctive header line for each of the four suites and exit
# with a caller-controlled status, so each scenario below can force any
# suite red without depending on the real in-guest scripts at all.
#
# Coverage:
#   T1 suite 1 (test-safety-stack.sh) forced red -> all four suite headers
#      still appear in stdout, AND `rc test` exits non-zero overall.
#   T2 all four suites green -> exit 0 (positive control: the fix must not
#      turn a genuinely all-passing run into a false failure).
#   T3 suite 4 (run-recipe-smokes.sh) forced red, suites 1-3 green -> all
#      four headers still appear (guards against a fix that only handles
#      the FIRST suite's exit status) AND exit non-zero.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

echo "=== test-rc-test-suite-continuation.sh ==="
echo ""

RTC_TMP=$(mktemp -d)
trap 'rm -rf "$RTC_TMP"' EXIT

CAGE_NAME="rtc-stub-cage"
WS_SOURCE_PATH="${RTC_TMP}/ws"
mkdir -p "$WS_SOURCE_PATH"
XDG_HOME="${RTC_TMP}/xdg-config"
mkdir -p "$XDG_HOME"

STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-rtc-stub-XXXXXX")
cat > "${STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" --version"*)
    echo "msb 0.0.0-stub"
    exit 0
    ;;
  *" inspect "*"--format json"*)
    cat <<JSON
{"status":"Running","config":{"labels":{"rc.source.path":"${WS_SOURCE_PATH}"}}}
JSON
    exit 0
    ;;
  *"test-safety-stack.sh"*)
    echo "=== STUB HEADER: test-safety-stack.sh ==="
    exit "${RTC_SUITE1_EXIT:-0}"
    ;;
  *"test-skills.sh"*)
    echo "=== STUB HEADER: test-skills.sh ==="
    exit "${RTC_SUITE2_EXIT:-0}"
    ;;
  *"test-bd-roundtrip.sh"*)
    echo "=== STUB HEADER: test-bd-roundtrip.sh ==="
    exit "${RTC_SUITE3_EXIT:-0}"
    ;;
  *"run-recipe-smokes.sh"*)
    echo "=== STUB HEADER: run-recipe-smokes.sh ==="
    exit "${RTC_SUITE4_EXIT:-0}"
    ;;
  *)
    echo "stub msb: unhandled args: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "${STUB_DIR}/msb"
# The inspect JSON above embeds WS_SOURCE_PATH literally (heredoc written
# with the quoted 'STUB' delimiter so it is NOT expanded at write time --
# only at the stub's own runtime, once WS_SOURCE_PATH is exported below).
export WS_SOURCE_PATH

_run_rc_test() {
  PATH="${STUB_DIR}:$PATH" XDG_CONFIG_HOME="$XDG_HOME" HOME="$RTC_TMP" \
    "$RC" test "$CAGE_NAME"
}

# ---------------------------------------------------------------------------
# T1: suite 1 (test-safety-stack.sh) forced red.
# ---------------------------------------------------------------------------
echo "-- T1: earlier suite (test-safety-stack.sh) forced red --"
RTC_SUITE1_EXIT=1 RTC_SUITE2_EXIT=0 RTC_SUITE3_EXIT=0 RTC_SUITE4_EXIT=0
export RTC_SUITE1_EXIT RTC_SUITE2_EXIT RTC_SUITE3_EXIT RTC_SUITE4_EXIT
T1_EXIT=0
T1_OUT=$(_run_rc_test 2>&1) || T1_EXIT=$?

for hdr in "test-safety-stack.sh" "test-skills.sh" "test-bd-roundtrip.sh" "run-recipe-smokes.sh"; do
  if echo "$T1_OUT" | grep -q "STUB HEADER: ${hdr}"; then
    pass "T1 suite header present despite earlier red: ${hdr}"
  else
    fail "T1 suite header present despite earlier red: ${hdr}" "missing from output: $T1_OUT"
  fi
done

if [[ "$T1_EXIT" -ne 0 ]]; then
  pass "T1 rc test exits non-zero overall when suite 1 failed"
else
  fail "T1 rc test exits non-zero overall when suite 1 failed" "got exit 0"
fi

# ---------------------------------------------------------------------------
# T2: all four suites green (positive control).
# ---------------------------------------------------------------------------
echo ""
echo "-- T2: all four suites green (positive control) --"
RTC_SUITE1_EXIT=0 RTC_SUITE2_EXIT=0 RTC_SUITE3_EXIT=0 RTC_SUITE4_EXIT=0
export RTC_SUITE1_EXIT RTC_SUITE2_EXIT RTC_SUITE3_EXIT RTC_SUITE4_EXIT
T2_EXIT=0
T2_OUT=$(_run_rc_test 2>&1) || T2_EXIT=$?

if [[ "$T2_EXIT" -eq 0 ]]; then
  pass "T2 rc test exits 0 when all four suites pass"
else
  fail "T2 rc test exits 0 when all four suites pass" "got exit $T2_EXIT; output: $T2_OUT"
fi

# ---------------------------------------------------------------------------
# T3: a LATER suite (run-recipe-smokes.sh) forced red, earlier ones green.
# ---------------------------------------------------------------------------
echo ""
echo "-- T3: later suite (run-recipe-smokes.sh) forced red --"
RTC_SUITE1_EXIT=0 RTC_SUITE2_EXIT=0 RTC_SUITE3_EXIT=0 RTC_SUITE4_EXIT=1
export RTC_SUITE1_EXIT RTC_SUITE2_EXIT RTC_SUITE3_EXIT RTC_SUITE4_EXIT
T3_EXIT=0
T3_OUT=$(_run_rc_test 2>&1) || T3_EXIT=$?

for hdr in "test-safety-stack.sh" "test-skills.sh" "test-bd-roundtrip.sh" "run-recipe-smokes.sh"; do
  if echo "$T3_OUT" | grep -q "STUB HEADER: ${hdr}"; then
    pass "T3 suite header present when a later suite is red: ${hdr}"
  else
    fail "T3 suite header present when a later suite is red: ${hdr}" "missing from output: $T3_OUT"
  fi
done

if [[ "$T3_EXIT" -ne 0 ]]; then
  pass "T3 rc test exits non-zero overall when suite 4 failed"
else
  fail "T3 rc test exits non-zero overall when suite 4 failed" "got exit 0"
fi

echo ""
echo "=== $((TOTAL - FAILURES))/$TOTAL passed ==="
if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
exit 0
