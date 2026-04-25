#!/usr/bin/env bash
# Tests for ADR-019 D3: cage-pi.md fenced block injected into /pi-agent/AGENTS.md.
# Verifies idempotency, user-content preservation, Claude-marker isolation, and
# graceful handling of the pi-mount-absent case.
#
# Requires docker + the rip-cage image already built (./rc build).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_WS=""
TEST_WS2=""
CONTAINER=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

# Resolve the container name from the workspace label — robust against
# rc's collision-hash fallback and tr/sed name normalization.
_resolve_container() {
  local ws="${1:-$TEST_WS}"
  docker ps -a --filter "label=rc.source.path=$(realpath "$ws" 2>/dev/null || echo "$ws")" \
    --format '{{.Names}}' | head -1
}

cleanup() {
  local _c
  _c=$(_resolve_container "$TEST_WS" 2>/dev/null || true)
  if [[ -n "$_c" ]]; then
    docker rm -f "$_c" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEST_WS2" ]]; then
    _c=$(_resolve_container "$TEST_WS2" 2>/dev/null || true)
    if [[ -n "$_c" ]]; then
      docker rm -f "$_c" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$TEST_WS" && -d "$TEST_WS" ]]; then
    rm -rf "$TEST_WS"
  fi
  if [[ -n "$TEST_WS2" && -d "$TEST_WS2" ]]; then
    rm -rf "$TEST_WS2"
  fi
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest image not built — run ./rc build first"
  exit 0
fi

TEST_WS=$(mktemp -d)

# ---- Test 1: /pi-agent/AGENTS.md exists after rc up ----
echo ""
echo "=== Test 1: /pi-agent/AGENTS.md exists inside container after rc up ==="
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true

CONTAINER=$(_resolve_container "$TEST_WS")
if [[ -z "$CONTAINER" ]]; then
  fail "Test 1: container did not come up"
  echo "$FAILURES test(s) FAILED (fatal — cannot continue without container)."
  exit 1
fi

if docker exec "$CONTAINER" test -f /pi-agent/AGENTS.md; then
  pass "Test 1: /pi-agent/AGENTS.md exists"
else
  fail "Test 1: /pi-agent/AGENTS.md missing"
fi

# ---- Test 2 & 3: fenced cage-pi block is present ----
echo ""
echo "=== Tests 2-3: fenced cage-pi block present in /pi-agent/AGENTS.md ==="

if docker exec "$CONTAINER" grep -q 'begin:rip-cage-topology-pi' /pi-agent/AGENTS.md; then
  pass "Test 2: begin:rip-cage-topology-pi marker found in AGENTS.md"
else
  fail "Test 2: begin:rip-cage-topology-pi marker missing from AGENTS.md"
fi

if docker exec "$CONTAINER" grep -q 'end:rip-cage-topology-pi' /pi-agent/AGENTS.md; then
  pass "Test 3: end:rip-cage-topology-pi marker found in AGENTS.md"
else
  fail "Test 3: end:rip-cage-topology-pi marker missing from AGENTS.md"
fi

# ---- Test 4: idempotency — running init a second time leaves exactly one block ----
echo ""
echo "=== Test 4: idempotency — second init run leaves exactly one pi topology block ==="

docker exec "$CONTAINER" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

count=$(docker exec "$CONTAINER" grep -c 'begin:rip-cage-topology-pi' /pi-agent/AGENTS.md 2>/dev/null || echo "0")
if [[ "$count" -eq 1 ]]; then
  pass "Test 4: exactly one begin:rip-cage-topology-pi block after second init"
else
  fail "Test 4: expected 1 block, got $count" "$count"
fi

# ---- Test 5: Claude markers in CLAUDE.md are untouched by the pi init ----
echo ""
echo "=== Test 5: Claude CLAUDE.md markers untouched after pi init ==="

claude_count=$(docker exec "$CONTAINER" grep -c 'begin:rip-cage-topology$' /home/agent/.claude/CLAUDE.md 2>/dev/null || echo "0")
if [[ "$claude_count" -eq 1 ]]; then
  pass "Test 5: exactly one begin:rip-cage-topology (unsuffixed) in CLAUDE.md — no drift"
else
  fail "Test 5: expected 1 Claude marker, got $claude_count" "$claude_count"
fi

# Also confirm the pi marker is NOT present in CLAUDE.md
pi_in_claude=$(docker exec "$CONTAINER" grep -c 'begin:rip-cage-topology-pi' /home/agent/.claude/CLAUDE.md 2>/dev/null || echo "0")
if [[ "$pi_in_claude" -eq 0 ]]; then
  pass "Test 5b: pi marker absent from CLAUDE.md (no cross-contamination)"
else
  fail "Test 5b: pi marker found in CLAUDE.md — awk regex cross-matched" "$pi_in_claude"
fi

# ---- Test 6: user content preservation ----
echo ""
echo "=== Test 6: user content preserved after re-running init ==="

docker exec "$CONTAINER" sh -c 'printf "# My pi notes\n" >> /pi-agent/AGENTS.md'
docker exec "$CONTAINER" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

if docker exec "$CONTAINER" grep -q 'My pi notes' /pi-agent/AGENTS.md; then
  pass "Test 6: user content (My pi notes) survives re-init"
else
  fail "Test 6: user content lost after re-init"
fi

count=$(docker exec "$CONTAINER" grep -c 'begin:rip-cage-topology-pi' /pi-agent/AGENTS.md 2>/dev/null || echo "0")
if [[ "$count" -eq 1 ]]; then
  pass "Test 6b: still exactly one pi topology block after re-init with user content"
else
  fail "Test 6b: expected 1 block after user-content + re-init, got $count" "$count"
fi

# ---- Test 7: mount-absent guard — init exits 0, no AGENTS.md error ----
echo ""
echo "=== Test 7: mount-absent guard — init exits 0 when pi mount was skipped ==="

# Temporarily rename ~/.pi/agent so rc up skips the mount
PI_AGENT_DIR="${HOME}/.pi/agent"
PI_AGENT_BACKUP="${HOME}/.pi/agent.bak-test-pi-cage-$$"
_pi_was_present=0
if [[ -d "$PI_AGENT_DIR" ]]; then
  mv "$PI_AGENT_DIR" "$PI_AGENT_BACKUP"
  _pi_was_present=1
fi

TEST_WS2=$(mktemp -d)
RC_ALLOWED_ROOTS="$TEST_WS2" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS2" </dev/null >/dev/null 2>&1 || true

# Restore the pi agent dir immediately after rc up
if [[ $_pi_was_present -eq 1 && -d "$PI_AGENT_BACKUP" ]]; then
  mv "$PI_AGENT_BACKUP" "$PI_AGENT_DIR"
fi

CONTAINER2=$(_resolve_container "$TEST_WS2")
if [[ -z "$CONTAINER2" ]]; then
  fail "Test 7: container2 did not come up"
else
  # Re-run init explicitly and capture exit code + output
  init_output=$(docker exec "$CONTAINER2" /usr/local/bin/init-rip-cage.sh 2>&1) || true
  init_exit=$?
  if [[ $init_exit -eq 0 ]]; then
    pass "Test 7: init exits 0 even when pi mount was not wired"
  else
    fail "Test 7: init exited $init_exit (expected 0)" "$init_exit"
  fi
  # Assert no error-level AGENTS.md message
  if echo "$init_output" | grep -qi 'error.*AGENTS.md\|AGENTS.md.*error'; then
    fail "Test 7b: init logged AGENTS.md error despite mount-absent case" "$(echo "$init_output" | grep -i 'AGENTS.md')"
  else
    pass "Test 7b: no AGENTS.md error in init output"
  fi
fi

# ---- Summary ----
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All pi-cage-context tests passed."
else
  echo "$FAILURES test(s) FAILED."
  exit 1
fi
