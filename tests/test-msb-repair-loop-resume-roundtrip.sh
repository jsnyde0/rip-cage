#!/usr/bin/env bash
# tests/test-msb-repair-loop-resume-roundtrip.sh -- Fold-4a REQUIRED test
# (Fable ruling 2026-07-12, folded into bead rip-cage-tsf2.1's notes).
#
# The full repair round-trip INCLUDING a post-reload session RESUME was
# UNTESTED before this file: tests/test-msb-lifecycle-reload-repair-loop.sh
# (S6, rip-cage-rj68) proves DENY -> FIX (rc reload, cold-recreate) -> RETRY
# with real data, but stops there -- no resume leg.
# tests/test-msb-lifecycle-create-resume.sh proves create -> stop -> `rc up`
# RESUME with a real in-guest commit, but has no deny/reload/net-readback at
# all. Neither file chains BOTH halves. This file closes that gap: it
# chains DENY -> FIX (rc reload) -> RETRY -> STOP -> RESUME (`rc up`) ->
# RETRY AGAIN, proving the amended network policy the reload applied
# SURVIVES a real stop+resume cycle on the recreated cage, not just the
# immediate post-reload state.
#
# msb fake-accepts denied/unreachable TCP (connect() succeeds, zero bytes)
# -- every claim below rests on REAL bidirectional application data (a
# nonzero HTTP response body), never connect-success alone, plus a
# POSITIVE CONTROL (an always-allowed host) on the SAME booted cage at
# every stage, ruling out a dead-network false positive.
#
# Coverage:
#   DENY    initially-denied host (www.wikipedia.org) yields ZERO bytes
#   CTRL1   positive control (example.com, allowed) yields REAL data on the
#           SAME cage before any fix — rules out a dead network
#   FIX     `rc reload` (cold-recreate) applies the amended allowlist to a
#           REAL, re-inspectable sandbox
#   RETRY1  the SAME previously-denied host now returns REAL bidirectional
#           data immediately post-reload (mirrors the existing repair-loop
#           test's own claim, re-proven here as this test's own baseline
#           before the NEW leg below)
#   CTRL2   positive control still real post-reload
#   STOP    the RECREATED (post-reload) sandbox is genuinely stopped via
#           the graceful primitive (independent msb inspect)
#   RESUME  `rc up` resumes the stopped, post-reload sandbox for real
#           (action=resumed, independent msb inspect confirms Running)
#   RETRY2  *** the Fold-4a core claim *** — after stop+resume, the
#           previously-denied host STILL returns REAL bidirectional data
#           on the SAME resumed cage (the amended net-rule policy survived
#           the resume, not just the initial post-reload boot)
#   CTRL3   positive control still real post-resume — rules out resume
#           having silently broken egress entirely (which would make
#           RETRY2 a false negative pass via a dead network, not a real
#           policy-survival proof)
#
# NEEDS_CONTAINER (docker, rc up's image-provisioning preflight) + NEEDS_MSB
# + a pre-built rip-cage:latest image already `msb load`-ed + a live network
# path to example.com / www.wikipedia.org. Self-skips otherwise.

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

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-repair-resume-roundtrip-XXXXXX")
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

CR_OUT=$(run_rc up "$WS" 2>&1)
CR_RC=$?
if [[ "$CR_RC" -ne 0 ]]; then
  fail "setup: rc up failed" "$CR_OUT"
  echo ""
  echo "=== test-msb-repair-loop-resume-roundtrip.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
pass "setup: rc up created ${CAGE_NAME} with allowed_hosts=[example.com]"

fetch() {
  msb exec "$CAGE_NAME" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# DENY + CTRL1: initial state.
# ---------------------------------------------------------------------------
echo ""
echo "=== DENY + CTRL1: initial state -- wikipedia denied, example.com allowed ==="
DENY1=$(fetch https://www.wikipedia.org)
if [[ "$DENY1" == "000 0" ]]; then
  pass "DENY: www.wikipedia.org yields ZERO bytes before the reload (HTTP ${DENY1})"
else
  fail "DENY: expected zero-byte denial before reload" "$DENY1"
fi
CTRL1=$(fetch https://example.com)
CTRL1_SIZE="${CTRL1#* }"
if [[ "$CTRL1" == 200\ * && "$CTRL1_SIZE" -gt 0 ]]; then
  pass "CTRL1: example.com (allowed) returns real bidirectional data before reload (HTTP ${CTRL1})"
else
  fail "CTRL1: expected real data from the allowed host" "$CTRL1"
fi

# ---------------------------------------------------------------------------
# FIX: amend .rip-cage.yaml, run the REAL `rc reload` verb (cold-recreate).
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
  echo ""
  echo "=== test-msb-repair-loop-resume-roundtrip.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

# ---------------------------------------------------------------------------
# RETRY1 + CTRL2: immediately post-reload (this is the EXISTING repair-loop
# test's own claim -- re-proven here as this test's baseline before the NEW
# stop+resume leg below).
# ---------------------------------------------------------------------------
echo ""
echo "=== RETRY1 + CTRL2: immediately post-reload, both hosts return real data ==="
RETRY1=$(fetch https://www.wikipedia.org)
RETRY1_SIZE="${RETRY1#* }"
if [[ "$RETRY1" == 200\ * && "$RETRY1_SIZE" -gt 0 ]]; then
  pass "RETRY1: www.wikipedia.org returns REAL bidirectional data immediately post-reload (HTTP ${RETRY1})"
else
  fail "RETRY1: expected real data from the newly-allowed host post-reload" "$RETRY1"
fi
CTRL2=$(fetch https://example.com)
CTRL2_SIZE="${CTRL2#* }"
if [[ "$CTRL2" == 200\ * && "$CTRL2_SIZE" -gt 0 ]]; then
  pass "CTRL2: example.com still returns real data immediately post-reload"
else
  fail "CTRL2: original allowed host regressed post-reload" "$CTRL2"
fi

# ---------------------------------------------------------------------------
# STOP: graceful stop of the RECREATED (post-reload) sandbox.
# ---------------------------------------------------------------------------
echo ""
echo "=== STOP: graceful stop of the recreated, post-reload sandbox ==="
msb stop "$CAGE_NAME" >/dev/null 2>&1
STOP_STATE=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -r '.status')
if [[ "$STOP_STATE" == "Stopped" ]]; then
  pass "STOP: independent msb inspect confirms the post-reload sandbox is genuinely stopped"
else
  fail "STOP: expected Stopped" "got '$STOP_STATE'"
fi

# ---------------------------------------------------------------------------
# RESUME: `rc up` resumes the stopped, post-reload sandbox for real.
# ---------------------------------------------------------------------------
echo ""
echo "=== RESUME: rc up resumes the post-reload sandbox ==="
RESUME_OUT=$(run_rc up "$WS" 2>&1)
RESUME_RC=$?
RESUME_ACTION=$(echo "$RESUME_OUT" | tail -1 | jq -r '.action' 2>/dev/null)
if [[ "$RESUME_RC" -eq 0 && "$RESUME_ACTION" == "resumed" ]]; then
  pass "RESUME: rc up resumes the post-reload sandbox for real (action=resumed)"
else
  fail "RESUME: expected action=resumed, exit 0" "rc=$RESUME_RC out=$RESUME_OUT"
fi
RESUME_STATE=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -r '.status')
if [[ "$RESUME_STATE" == "Running" ]]; then
  pass "RESUME: independent msb inspect confirms Running after resume"
else
  fail "RESUME: expected Running after resume" "got '$RESUME_STATE'"
fi

# ---------------------------------------------------------------------------
# *** RETRY2 (Fold-4a core claim) + CTRL3 ***: the previously-denied host
# STILL returns REAL bidirectional data on the SAME resumed cage -- the
# amended net-rule policy survived a real stop+resume cycle, not just the
# initial post-reload boot. CTRL3 rules out RETRY2 passing via a dead
# network (which would make ANY host request look "not denied").
# ---------------------------------------------------------------------------
echo ""
echo "=== RETRY2 (Fold-4a core claim) + CTRL3: post-RESUME, the amended policy still holds ==="
RETRY2=$(fetch https://www.wikipedia.org)
RETRY2_SIZE="${RETRY2#* }"
if [[ "$RETRY2" == 200\ * && "$RETRY2_SIZE" -gt 0 ]]; then
  pass "RETRY2 (Fold-4a): www.wikipedia.org STILL returns REAL bidirectional data after stop+resume (HTTP ${RETRY2}) -- the reload-applied policy survived the resume"
else
  fail "RETRY2 (Fold-4a): expected real data from the previously-denied host after stop+resume -- the repair-loop's fix did NOT survive resume" "$RETRY2"
fi
CTRL3=$(fetch https://example.com)
CTRL3_SIZE="${CTRL3#* }"
if [[ "$CTRL3" == 200\ * && "$CTRL3_SIZE" -gt 0 ]]; then
  pass "CTRL3: example.com still returns real data post-resume (rules out a dead-network false positive on RETRY2)"
else
  fail "CTRL3: original allowed host regressed post-resume (RETRY2 would be unreliable)" "$CTRL3"
fi

echo ""
echo "=== test-msb-repair-loop-resume-roundtrip.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
