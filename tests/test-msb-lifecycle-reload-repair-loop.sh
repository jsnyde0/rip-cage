#!/usr/bin/env bash
# tests/test-msb-lifecycle-reload-repair-loop.sh -- LIVE effect-based proof
# for bead rip-cage-rj68 (S6) criterion 1: "A cage survives a full deny ->
# fix -> reload cycle with real data: an initially-denied host returns no
# data, the loop applies an amended rule, the same host then returns real
# application data on retry, with pre-existing overlay/session state intact
# where snapshot-amend was used." Drives the REAL `rc up` + `rc reload`
# verbs end-to-end (docs/2026-07-10-tsf2-decomposition.md S6 "Verification
# note" -- unlike S4/S5's siblings, S6 IS the create/reload verb).
#
# DESIGN DECISION documented here AND in cli/reload.sh: this bead chooses
# COLD-RECREATE (not snapshot-amend) as rip-cage's default repair-loop
# mechanic, because rip-cage cages are mount-projected by construction
# (workspace/.claude-session-state/pi-auth are host bind mounts;
# rc-state-*/rc-history-*/rc-mise-cache are msb NAMED VOLUMES that persist
# independent of the sandbox's own OCI overlay). This test proves BOTH
# halves honestly: (a) HOST-MOUNTED session state (a workspace file)
# survives the cold-recreate repair cycle -- the real continuity claim
# cold-recreate makes here; (b) a marker written into the guest's OWN
# ephemeral overlay does NOT survive -- the documented, expected cost of
# choosing cold-recreate over snapshot-amend. Neither half is glossed over.
#
# Coverage:
#   DENY   an initially-denied host returns ZERO bytes (not connect-success)
#   CTRL   a positive control (an already-allowed host) returns REAL data
#          on the SAME cage, ruling out a dead-network false positive
#   FIX    editing .rip-cage.yaml + `rc reload` applies the amended
#          net-rule set to a REAL, re-inspectable sandbox
#   RETRY  the SAME previously-denied host now returns REAL bidirectional
#          application data on retry (the core repair-loop claim)
#   STATE  host-mounted session state (a workspace file) survives the
#          repair cycle intact
#   OVERLAY (honest negative) a guest-overlay-only marker does NOT survive
#          cold-recreate -- proves the design decision is real, not just
#          asserted
#
# NEEDS_CONTAINER (docker, rc up's image-provisioning preflight) + NEEDS_MSB
# + a live network path to example.com / www.wikipedia.org. Self-skips
# otherwise.

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

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-lifecycle-reload-XXXXXX")
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

CR_OUT=$(run_rc up "$WS" 2>&1)
CR_RC=$?
if [[ "$CR_RC" -ne 0 ]]; then
  fail "setup: rc up failed" "$CR_OUT"
  echo ""
  echo "=== test-msb-lifecycle-reload-repair-loop.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
pass "setup: rc up created ${CAGE_NAME} with allowed_hosts=[example.com]"

# ---------------------------------------------------------------------------
# DENY + CTRL: initially-denied host = zero bytes; allowed host = real data.
# ---------------------------------------------------------------------------
echo ""
echo "=== DENY + CTRL: initial state -- wikipedia denied, example.com allowed ==="
DENY1=$(msb exec "$CAGE_NAME" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 https://www.wikipedia.org 2>/dev/null)
if [[ "$DENY1" == "000 0" ]]; then
  pass "DENY: www.wikipedia.org yields ZERO bytes before the reload (HTTP ${DENY1})"
else
  fail "DENY: expected zero-byte denial before reload" "$DENY1"
fi
CTRL1=$(msb exec "$CAGE_NAME" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 https://example.com 2>&1)
CTRL1_SIZE="${CTRL1#* }"
if [[ "$CTRL1" == 200\ * && "$CTRL1_SIZE" -gt 0 ]]; then
  pass "CTRL: example.com (allowed) returns real bidirectional data before reload (HTTP ${CTRL1}) -- rules out a dead network"
else
  fail "CTRL: expected real data from the allowed host" "$CTRL1"
fi

# ---------------------------------------------------------------------------
# STATE + OVERLAY setup: plant a host-mounted marker (should survive) and a
# guest-overlay-only marker (should NOT survive cold-recreate).
# ---------------------------------------------------------------------------
echo "pre-reload-workspace-marker" > "${WS}/reload-marker.txt"
msb exec "$CAGE_NAME" -- sh -c 'echo pre-reload-overlay-marker > /home/agent/overlay-only-marker.txt'

# ---------------------------------------------------------------------------
# FIX: amend .rip-cage.yaml, run the REAL `rc reload` verb.
# ---------------------------------------------------------------------------
echo ""
echo "=== FIX: amend .rip-cage.yaml + rc reload ==="
cat > "${WS}/.rip-cage.yaml" <<'EOF'
version: 1
network:
  allowed_hosts: [example.com, www.wikipedia.org]
EOF
RELOAD_OUT=$(cd "$WS" && run_rc reload "$CAGE_NAME" 2>&1)
RELOAD_RC=$?
if [[ "$RELOAD_RC" -eq 0 ]]; then
  pass "FIX: rc reload exits 0"
else
  fail "FIX: rc reload failed" "$RELOAD_OUT"
fi

POLICY_JSON=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -c '.config.network.policy.rules')
if echo "$POLICY_JSON" | grep -q "www.wikipedia.org"; then
  pass "FIX: the recreated sandbox's DECLARED policy now includes www.wikipedia.org (${POLICY_JSON})"
else
  fail "FIX: expected www.wikipedia.org in the recreated sandbox's declared policy" "$POLICY_JSON"
fi

# ---------------------------------------------------------------------------
# RETRY: the SAME previously-denied host now returns real data.
# ---------------------------------------------------------------------------
echo ""
echo "=== RETRY: the same host now returns real application data ==="
RETRY_OUT=$(msb exec "$CAGE_NAME" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 https://www.wikipedia.org 2>&1)
RETRY_SIZE="${RETRY_OUT#* }"
if [[ "$RETRY_OUT" == 200\ * && "$RETRY_SIZE" -gt 0 ]]; then
  pass "RETRY: www.wikipedia.org now returns REAL bidirectional data on retry (HTTP ${RETRY_OUT})"
else
  fail "RETRY: expected real data from the newly-allowed host" "$RETRY_OUT"
fi
CTRL2=$(msb exec "$CAGE_NAME" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 https://example.com 2>&1)
CTRL2_SIZE="${CTRL2#* }"
if [[ "$CTRL2" == 200\ * && "$CTRL2_SIZE" -gt 0 ]]; then
  pass "RETRY: the original allowed host (example.com) still returns real data post-reload"
else
  fail "RETRY: original allowed host regressed post-reload" "$CTRL2"
fi

# ---------------------------------------------------------------------------
# STATE: host-mounted session state survives; OVERLAY marker does not
# (the honest, documented cold-recreate tradeoff).
# ---------------------------------------------------------------------------
echo ""
echo "=== STATE: host-mounted state intact; guest-overlay-only state (documented tradeoff) lost ==="
STATE_READBACK=$(cat "${WS}/reload-marker.txt" 2>/dev/null)
if [[ "$STATE_READBACK" == "pre-reload-workspace-marker" ]]; then
  pass "STATE: host-mounted workspace marker survived the repair cycle intact: '${STATE_READBACK}'"
else
  fail "STATE: host-mounted marker did not survive" "got '${STATE_READBACK}'"
fi
IN_GUEST_STATE=$(msb exec "$CAGE_NAME" -- cat /workspace/reload-marker.txt 2>/dev/null)
if [[ "$IN_GUEST_STATE" == "pre-reload-workspace-marker" ]]; then
  pass "STATE: the recreated cage's /workspace mount also sees the same marker (real re-mount, not host-only)"
else
  fail "STATE: recreated cage's workspace mount does not see the marker" "got '${IN_GUEST_STATE}'"
fi

OVERLAY_READBACK=$(msb exec "$CAGE_NAME" -- cat /home/agent/overlay-only-marker.txt 2>/dev/null)
if [[ -z "$OVERLAY_READBACK" ]]; then
  pass "OVERLAY (honest negative): the guest-overlay-only marker did NOT survive cold-recreate, exactly as documented"
else
  fail "OVERLAY: expected the overlay-only marker to be GONE under cold-recreate (design-decision claim would be false otherwise)" "got '${OVERLAY_READBACK}'"
fi

echo ""
echo "=== test-msb-lifecycle-reload-repair-loop.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
