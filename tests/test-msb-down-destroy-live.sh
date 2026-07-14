#!/usr/bin/env bash
# tests/test-msb-down-destroy-live.sh -- LIVE effect-based proof for bead
# rip-cage-tsf2.1 criterion 2: "rc down performs a graceful stop that
# PERSISTS a completed guest write (real read-back after a later rc up),
# never a force-kill on a state-bearing cage; rc destroy removes the msb
# sandbox and cleans named volumes per the destroy policy, verified by real
# absence."
#
# Drives the REAL `rc up` + `rc down` + `rc destroy` verbs end-to-end (not
# a direct `msb stop`/`msb remove` bypass) -- cli/down_destroy.sh was still
# docker-only after S6 (rip-cage-rj68) rewired create/resume/reload/doctor
# onto msb; this test proves the rewrite this bead makes.
#
# msb behavioral fact this test is built around: `msb remove` has NO
# volume-deletion flag (named volumes SURVIVE remove+recreate) -- so
# cmd_destroy must explicitly call `msb volume remove` for the cage's own
# named volumes (rc-state-<name>, rc-history-<name>), mirroring the
# existing docker `docker volume rm` behavior it replaces. Verified here by
# a real `msb volume list` absence check, not by trusting the reported exit
# code alone.
#
# Coverage:
#   DOWN1  a real guest write, made via a running rc-up cage, PERSISTS
#          across `rc down` (graceful stop) + a later `rc up` resume --
#          real independent read-back, not exit-0
#   DOWN2  `rc down` against an already-stopped cage fails loud (not a
#          silent no-op / not a force-kill fallback)
#   DESTROY1 `rc destroy --force` removes the REAL msb sandbox (verified
#          absent via independent `msb inspect`) AND the cage's two named
#          volumes (verified absent via independent `msb volume list`)
#   DESTROY2 `rc destroy` against an already-absent cage fails loud
#          (CONTAINER_NOT_FOUND), not a silent success
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

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-down-destroy-live-XXXXXX")
WS="${TEST_HOME}/workspace"
mkdir -p "${TEST_HOME}/.config/rip-cage" "$WS"
CAGE_NAME=""
cleanup() {
  [[ -n "$CAGE_NAME" ]] && msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
  [[ -n "$CAGE_NAME" ]] && msb volume remove "rc-state-${CAGE_NAME}" "rc-history-${CAGE_NAME}" >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

git -C "$WS" init -q
touch "${WS}/README.md"
git -C "$WS" add README.md
git -C "$WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial"

cat > "${WS}/.rip-cage.yaml" <<'EOF'
version: 2
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
  echo "=== test-msb-down-destroy-live.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
pass "setup: rc up created a real running msb sandbox ${CAGE_NAME}"

# ---------------------------------------------------------------------------
# DOWN1: a real guest write persists across rc down (graceful) + rc up (resume).
# ---------------------------------------------------------------------------
echo ""
echo "=== DOWN1: a real guest write survives rc down + rc up resume ==="
msb exec "$CAGE_NAME" -- sh -c 'echo tsf21-down-persist-marker > /home/agent/down-marker.txt && sync'
WRITE_RC=$?
if [[ "$WRITE_RC" -eq 0 ]]; then
  pass "DOWN1: guest write reported success before rc down (exit 0)"
else
  fail "DOWN1: guest write did not report success" "rc=$WRITE_RC"
fi

DOWN_OUT=$(run_rc down "$CAGE_NAME" 2>&1)
DOWN_RC=$?
if [[ "$DOWN_RC" -eq 0 ]]; then
  pass "DOWN1: rc down exits 0"
else
  fail "DOWN1: rc down failed" "rc=$DOWN_RC out=$DOWN_OUT"
fi

DOWN_STATE=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -r '.status')
if [[ "$DOWN_STATE" == "Stopped" ]]; then
  pass "DOWN1: independent msb inspect confirms the sandbox is genuinely stopped (graceful, not gone)"
else
  fail "DOWN1: expected Stopped after rc down" "got '$DOWN_STATE'"
fi

RESUME_OUT=$(run_rc up "$WS" 2>&1)
RESUME_RC=$?
RESUME_ACTION=$(echo "$RESUME_OUT" | tail -1 | jq -r '.action' 2>/dev/null)
if [[ "$RESUME_RC" -eq 0 && "$RESUME_ACTION" == "resumed" ]]; then
  pass "DOWN1: rc up resumes the rc-down'd sandbox (action=resumed)"
else
  fail "DOWN1: expected action=resumed, exit 0" "rc=$RESUME_RC out=$RESUME_OUT"
fi

READBACK=$(msb exec "$CAGE_NAME" -- cat /home/agent/down-marker.txt 2>/dev/null)
if [[ "$READBACK" == "tsf21-down-persist-marker" ]]; then
  pass "DOWN1: independent post-resume read-back confirms the write survived rc down + resume: '${READBACK}'"
else
  fail "DOWN1: write did not survive rc down + resume" "got '${READBACK}'"
fi

# ---------------------------------------------------------------------------
# DOWN2: rc down against an already-stopped cage fails loud.
# ---------------------------------------------------------------------------
echo ""
echo "=== DOWN2: rc down against an already-stopped cage fails loud ==="
msb stop "$CAGE_NAME" >/dev/null 2>&1
DOWN2_OUT=$(run_rc down "$CAGE_NAME" 2>&1)
DOWN2_RC=$?
if [[ "$DOWN2_RC" -ne 0 ]] && echo "$DOWN2_OUT" | grep -qi "not running"; then
  pass "DOWN2: rc down against an already-stopped cage fails loud (not running)"
else
  fail "DOWN2: expected non-zero + not-running error" "rc=$DOWN2_RC out=$DOWN2_OUT"
fi

# ---------------------------------------------------------------------------
# DESTROY1: rc destroy --force removes the REAL sandbox AND its named
# volumes (verified by real independent absence).
# ---------------------------------------------------------------------------
echo ""
echo "=== DESTROY1: rc destroy --force removes the sandbox + named volumes (real absence) ==="
PRE_VOLS=$(msb volume list --format json 2>/dev/null | jq -r '.[].name')
if echo "$PRE_VOLS" | grep -qF "rc-state-${CAGE_NAME}" && echo "$PRE_VOLS" | grep -qF "rc-history-${CAGE_NAME}"; then
  pass "DESTROY1 setup: the cage's named volumes genuinely exist before destroy"
else
  fail "DESTROY1 setup: expected rc-state-/rc-history- volumes to exist pre-destroy" "$PRE_VOLS"
fi

DESTROY_OUT=$(run_rc destroy --force "$CAGE_NAME" 2>&1)
DESTROY_RC=$?
if [[ "$DESTROY_RC" -eq 0 ]]; then
  pass "DESTROY1: rc destroy --force exits 0"
else
  fail "DESTROY1: rc destroy --force failed" "rc=$DESTROY_RC out=$DESTROY_OUT"
fi

if ! msb inspect "$CAGE_NAME" --format json >/dev/null 2>&1; then
  pass "DESTROY1: independent msb inspect confirms the sandbox is REALLY gone"
else
  fail "DESTROY1: sandbox still exists after rc destroy" "$(msb inspect "$CAGE_NAME" 2>&1)"
fi

POST_VOLS=$(msb volume list --format json 2>/dev/null | jq -r '.[].name')
if ! echo "$POST_VOLS" | grep -qF "rc-state-${CAGE_NAME}" && ! echo "$POST_VOLS" | grep -qF "rc-history-${CAGE_NAME}"; then
  pass "DESTROY1: independent msb volume list confirms both named volumes are REALLY gone"
else
  fail "DESTROY1: a named volume survived rc destroy" "$POST_VOLS"
fi

# ---------------------------------------------------------------------------
# DESTROY2: rc destroy against an already-absent cage fails loud.
# ---------------------------------------------------------------------------
echo ""
echo "=== DESTROY2: rc destroy against an already-absent cage fails loud ==="
DESTROY2_OUT=$(run_rc destroy --force "$CAGE_NAME" 2>&1)
DESTROY2_RC=$?
DESTROY2_CODE=$(echo "$DESTROY2_OUT" | jq -r '.code' 2>/dev/null)
if [[ "$DESTROY2_RC" -ne 0 && "$DESTROY2_CODE" == "CONTAINER_NOT_FOUND" ]]; then
  pass "DESTROY2: rc destroy against an already-absent cage fails loud (CONTAINER_NOT_FOUND)"
else
  fail "DESTROY2: expected non-zero + CONTAINER_NOT_FOUND" "rc=$DESTROY2_RC out=$DESTROY2_OUT"
fi

echo ""
echo "=== test-msb-down-destroy-live.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
