#!/usr/bin/env bash
# tests/test-msb-attach-exec-live.sh -- LIVE effect-based proof for bead
# rip-cage-tsf2.1 criterion 1: "rc attach and rc exec drive a cage created
# by the new msb rc up -- a command run through rc exec returns its ACTUAL
# in-guest output read back (real data, not attach-liveness/exit-0)."
#
# Drives the REAL `rc up` + `rc exec` + `rc attach` verbs end-to-end (not a
# direct `msb exec` bypass) -- cli/attach_exec.sh was still docker-only
# after S6 (rip-cage-rj68) rewired create/resume/reload/doctor onto msb;
# this test proves the rewrite this bead makes.
#
# Coverage:
#   EXEC1  `rc exec <cage> -- <cmd>` writes a REAL file in-guest and a
#          SECOND `rc exec` call reads the REAL content back (round-trip
#          real data, not just exit-0)
#   EXEC2  `rc --output json exec` reports exit_code/status for a real
#          nonzero-exiting in-guest command (propagates the real exit code,
#          not a swallowed 0)
#   EXEC3  `rc exec` against a cage that is NOT running fails loud
#          (CONTAINER_NOT_RUNNING), proven via a genuinely stopped msb
#          sandbox (not a docker-state simulation)
#   ATTACH1 `rc attach` against the SAME real running msb cage recognizes
#          it as running (the msb-backed state check, not docker) and (in
#          non-TTY test mode) prints the exec hint rather than erroring
#          "not running"
#   ATTACH2 `rc attach` against a genuinely stopped msb sandbox fails loud
#          "not running" (same real-state check as EXEC3)
#
# NEEDS_CONTAINER (docker, rc up's image-provisioning preflight) + NEEDS_MSB
# + a pre-built rip-cage:latest image already `msb load`-ed. Self-skips
# (exit 0, SKIP: ...) when any prerequisite is missing -- never fakes a PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker not available/responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-attach-exec-live-XXXXXX")
WS="${TEST_HOME}/workspace"
mkdir -p "${TEST_HOME}/.config/rip-cage" "$WS"
CAGE_NAME=""
cleanup() {
  [[ -n "$CAGE_NAME" ]] && msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

git -C "$WS" init -q
touch "${WS}/README.md"
git -C "$WS" add README.md
git -C "$WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial"

cat > "${WS}/.rip-cage.yaml" <<'EOF'
version: 1
network:
  allowed_hosts: [example.com]
EOF

run_rc() {
  XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$WS" "$RC" --output json "$@"
}
run_rc_human() {
  XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$WS" "$RC" "$@"
}

CR_OUT=$(run_rc up "$WS" 2>&1)
CR_RC=$?
if [[ "$CR_RC" -ne 0 ]]; then
  fail "setup: rc up failed" "$CR_OUT"
  echo ""
  echo "=== test-msb-attach-exec-live.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
pass "setup: rc up created a real running msb sandbox ${CAGE_NAME}"

# ---------------------------------------------------------------------------
# EXEC1: real round-trip -- write via one rc exec call, read back via another.
# ---------------------------------------------------------------------------
echo ""
echo "=== EXEC1: rc exec writes + reads back REAL in-guest data ==="
WRITE_OUT=$(run_rc exec "$CAGE_NAME" -- sh -c 'echo tsf21-exec-roundtrip-marker > /home/agent/exec-marker.txt' 2>&1)
WRITE_RC=$?
if [[ "$WRITE_RC" -eq 0 ]]; then
  pass "EXEC1: rc exec write call exits 0"
else
  fail "EXEC1: rc exec write call failed" "rc=$WRITE_RC out=$WRITE_OUT"
fi
READ_OUT=$(run_rc_human exec "$CAGE_NAME" -- cat /home/agent/exec-marker.txt 2>&1)
if [[ "$READ_OUT" == "tsf21-exec-roundtrip-marker" ]]; then
  pass "EXEC1: rc exec reads back the REAL in-guest content: '${READ_OUT}'"
else
  fail "EXEC1: expected the real written content back" "got '${READ_OUT}'"
fi

# ---------------------------------------------------------------------------
# EXEC2: a real nonzero-exiting in-guest command propagates its ACTUAL exit
# code through --output json (not a swallowed 0).
# ---------------------------------------------------------------------------
echo ""
echo "=== EXEC2: rc --output json exec propagates a REAL nonzero exit code ==="
EXEC2_OUT=$(run_rc exec "$CAGE_NAME" -- sh -c 'exit 37' 2>&1)
EXEC2_CODE=$(echo "$EXEC2_OUT" | tail -1 | jq -r '.exit_code' 2>/dev/null)
EXEC2_STATUS=$(echo "$EXEC2_OUT" | tail -1 | jq -r '.status' 2>/dev/null)
if [[ "$EXEC2_CODE" == "37" && "$EXEC2_STATUS" == "error" ]]; then
  pass "EXEC2: JSON reports the real exit_code=37, status=error"
else
  fail "EXEC2: expected exit_code=37, status=error" "$EXEC2_OUT"
fi

# ---------------------------------------------------------------------------
# EXEC3 / ATTACH2: stop the cage for real, prove both verbs refuse a
# genuinely-not-running msb sandbox (msb-backed state check, not docker).
# ---------------------------------------------------------------------------
echo ""
echo "=== EXEC3 / ATTACH2: stopped msb sandbox -- both verbs fail loud ==="
msb stop "$CAGE_NAME" >/dev/null 2>&1
STOPPED_STATE=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -r '.status')
if [[ "$STOPPED_STATE" == "Stopped" ]]; then
  pass "setup: sandbox genuinely stopped (independent msb inspect confirms)"
else
  fail "setup: expected Stopped" "got '$STOPPED_STATE'"
fi

EXEC3_OUT=$(run_rc exec "$CAGE_NAME" -- echo should-not-run 2>&1)
EXEC3_RC=$?
if [[ "$EXEC3_RC" -ne 0 ]] && echo "$EXEC3_OUT" | grep -qi "not running"; then
  pass "EXEC3: rc exec against a stopped msb sandbox fails loud (not running)"
else
  fail "EXEC3: expected non-zero + not-running error" "rc=$EXEC3_RC out=$EXEC3_OUT"
fi

ATTACH2_OUT=$(run_rc_human attach "$CAGE_NAME" 2>&1)
ATTACH2_RC=$?
if [[ "$ATTACH2_RC" -ne 0 ]] && echo "$ATTACH2_OUT" | grep -qi "not running"; then
  pass "ATTACH2: rc attach against a stopped msb sandbox fails loud (not running)"
else
  fail "ATTACH2: expected non-zero + not-running error" "rc=$ATTACH2_RC out=$ATTACH2_OUT"
fi

# ---------------------------------------------------------------------------
# ATTACH1: resume the cage for real, prove rc attach recognizes it as
# running via the msb-backed state check (non-TTY test harness: prints the
# exec hint rather than erroring "not running").
# ---------------------------------------------------------------------------
echo ""
echo "=== ATTACH1: rc attach recognizes a REAL running msb sandbox (non-TTY hint path) ==="
msb start "$CAGE_NAME" >/dev/null 2>&1
RUNNING_STATE=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -r '.status')
if [[ "$RUNNING_STATE" == "Running" ]]; then
  pass "setup: sandbox genuinely running again (independent msb inspect confirms)"
else
  fail "setup: expected Running" "got '$RUNNING_STATE'"
fi

ATTACH1_OUT=$(run_rc_human attach "$CAGE_NAME" < /dev/null 2>&1)
ATTACH1_RC=$?
if [[ "$ATTACH1_RC" -eq 0 ]] && echo "$ATTACH1_OUT" | grep -qi "rc exec"; then
  pass "ATTACH1: rc attach against a real running msb sandbox exits 0 and points at rc exec (non-TTY)"
else
  fail "ATTACH1: expected exit 0 + exec hint for a running msb sandbox" "rc=$ATTACH1_RC out=$ATTACH1_OUT"
fi

echo ""
echo "=== test-msb-attach-exec-live.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
