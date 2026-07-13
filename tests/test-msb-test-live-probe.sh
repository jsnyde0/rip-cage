#!/usr/bin/env bash
# tests/test-msb-test-live-probe.sh -- LIVE effect-based proof for bead
# rip-cage-tsf2.1 criterion 3: "cli/test.sh operate[s] against msb cages
# (no docker-only assumption on the msb path)."
#
# Drives the REAL `rc up` + `rc test` verbs end-to-end (not a direct `msb
# exec` bypass) -- cli/test.sh was still docker-only after S6 (rip-cage-
# rj68) rewired create/resume/reload/doctor onto msb (workspace-mount
# source discovery via `docker inspect -f '{{ range .Mounts }}...'` and
# four `docker exec` calls into the baked in-guest safety-stack/skills/bd/
# recipe-smoke scripts); this test proves the rewrite this bead makes.
#
# Coverage:
#   TEST1  `rc test <cage>` (human mode) reaches the REAL in-guest
#          test-safety-stack.sh via msb exec and relays its REAL PASS
#          lines (specific, named checks -- not just "some output
#          appeared"), proving the workspace-mount-source label read
#          (rc.source.path) and the msb-exec dispatch both work for real
#   TEST2  `rc --output json test <cage>` parses the REAL in-guest
#          PASS/FAIL lines into a structured checks array with actual
#          named entries (not an empty/fabricated array)
#   TEST3  `rc test <cage>` against a cage that does not exist fails loud
#          (CONTAINER_NOT_FOUND), proven via msb-backed resolution (not a
#          leftover docker inspect codepath)
#
# DESIGN FINDING (not fixed by this bead -- see the bead's own final
# report): two of test-safety-stack.sh's BAKED in-guest checks ("DNS
# resolution (github.com)", "CAGE_HOST_ADDR resolves") assume Docker's
# network model (unrestricted DNS, host.docker.internal) and correctly
# FAIL under msb's default-deny egress + LAN-IP-only guest->host delivery
# (ADR-029 D2/D6) on a cage whose .rip-cage.yaml does not allowlist
# github.com. This is a real, expected consequence of the stricter msb
# network model, not a regression in cli/test.sh's CLI wiring -- the baked
# script's own assertions are a downstream cleanup item (out of this
# bead's cli/test.sh scope: the wiring correctly relays whatever the
# in-guest script reports, real data either way). This test therefore does
# NOT assert overall=pass; it asserts the wiring is real (named checks
# present, human+JSON both reach the guest for real).
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

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-test-live-probe-XXXXXX")
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
  echo "=== test-msb-test-live-probe.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
pass "setup: rc up created a real running msb sandbox ${CAGE_NAME}"

# ---------------------------------------------------------------------------
# TEST1: rc test (human) reaches the real in-guest safety-stack script.
# ---------------------------------------------------------------------------
echo ""
echo "=== TEST1: rc test (human) relays REAL named in-guest PASS lines ==="
T1_OUT=$(run_rc_human test "$CAGE_NAME" 2>&1)
if echo "$T1_OUT" | grep -q "PASS  \[1\] Container user is agent"; then
  pass "TEST1: real in-guest check 'Container user is agent' relayed verbatim (msb exec reached the real script)"
else
  fail "TEST1: expected the real named safety-stack PASS line" "$T1_OUT"
fi
if echo "$T1_OUT" | grep -qE "PASS[[:space:]]+\[[0-9]+\] git identity set"; then
  pass "TEST1: real in-guest check 'git identity set' relayed (a DIFFERENT script, test-safety-stack.sh, reached for real)"
else
  fail "TEST1: expected the git-identity PASS line" "$T1_OUT"
fi

# ---------------------------------------------------------------------------
# TEST2: rc --output json test parses real named checks into a structured array.
# ---------------------------------------------------------------------------
echo ""
echo "=== TEST2: rc --output json test parses REAL named checks ==="
T2_OUT=$(run_rc test "$CAGE_NAME" 2>&1)
T2_CHECK_COUNT=$(echo "$T2_OUT" | tail -1 | jq '.checks | length' 2>/dev/null || echo 0)
if [[ "$T2_CHECK_COUNT" -gt 30 ]]; then
  pass "TEST2: JSON checks array has ${T2_CHECK_COUNT} real entries (a fabricated/empty wiring would show 0)"
else
  fail "TEST2: expected a substantial real checks array (>30 entries)" "count=${T2_CHECK_COUNT} out=${T2_OUT}"
fi
T2_NAMED=$(echo "$T2_OUT" | tail -1 | jq -e '.checks[] | select(.name == "Container user is agent")' >/dev/null 2>&1; echo $?)
if [[ "$T2_NAMED" -eq 0 ]]; then
  pass "TEST2: the real named check 'Container user is agent' is present in the parsed JSON checks array"
else
  fail "TEST2: expected the real named check in the JSON checks array" "$T2_OUT"
fi

# ---------------------------------------------------------------------------
# TEST3: rc test against a nonexistent cage fails loud (msb-backed resolution).
# ---------------------------------------------------------------------------
echo ""
echo "=== TEST3: rc test against a nonexistent cage fails loud ==="
T3_OUT=$(run_rc test "tsf21-test-live-probe-does-not-exist" 2>&1)
T3_RC=$?
T3_CODE=$(echo "$T3_OUT" | jq -r '.code' 2>/dev/null)
if [[ "$T3_RC" -ne 0 && "$T3_CODE" == "CONTAINER_NOT_FOUND" ]]; then
  pass "TEST3: rc test against a nonexistent cage fails loud (CONTAINER_NOT_FOUND, msb-backed resolution)"
else
  fail "TEST3: expected non-zero + CONTAINER_NOT_FOUND" "rc=$T3_RC out=$T3_OUT"
fi

echo ""
echo "=== test-msb-test-live-probe.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
