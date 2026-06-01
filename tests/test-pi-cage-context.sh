#!/usr/bin/env bash
# Tests for ADR-019 D3 (post-c1p.1 evolution): cage-pi topology surfaced via
# reference in ~/.claude/CLAUDE.md rather than appended to host AGENTS.md.
# Post-hhh.12: container-local PI_CODING_AGENT_DIR (/home/agent/.pi/agent).
#
# Contract under test:
#   - Host ~/.pi/agent/AGENTS.md is NEVER mutated by init (content + mtime unchanged)
#   - Cage ~/.claude/CLAUDE.md contains the literal string /etc/rip-cage/cage-pi.md
#     inside the <!-- begin:rip-cage-topology --> fence
#   - /etc/rip-cage/cage-pi.md is readable inside the cage
#   - init exits 0 when pi auth mount is absent
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

# ---- Set up fake ~/.pi/agent state (auth.json + AGENTS.md) ----
PI_AGENT_DIR="${HOME}/.pi/agent"
PI_AGENT_BACKUP=""
PI_AGENT_EXISTED=false
if [[ -d "$PI_AGENT_DIR" ]]; then
  PI_AGENT_EXISTED=true
  PI_AGENT_BACKUP=$(mktemp -d)
  cp -a "$PI_AGENT_DIR/." "$PI_AGENT_BACKUP/"
else
  mkdir -p "$PI_AGENT_DIR"
fi

# Ensure AGENTS.md exists with known content so we can compare it later
AGENTS_MD_PATH="${PI_AGENT_DIR}/AGENTS.md"
AGENTS_MD_SENTINEL="# Test sentinel — must not be modified by init"
printf '%s\n' "$AGENTS_MD_SENTINEL" > "$AGENTS_MD_PATH"

# Also create a fake auth.json so rc up doesn't skip the mount
printf '{"fake":true}\n' > "${PI_AGENT_DIR}/auth.json"

cleanup_pi() {
  cleanup
  if [[ "$PI_AGENT_EXISTED" == "true" && -n "$PI_AGENT_BACKUP" ]]; then
    mv "$PI_AGENT_DIR" "${PI_AGENT_DIR}.evicting" 2>/dev/null || true
    mv "$PI_AGENT_BACKUP" "$PI_AGENT_DIR"
    rm -rf "${PI_AGENT_DIR}.evicting" 2>/dev/null || true
  elif [[ "$PI_AGENT_EXISTED" == "false" && -d "$PI_AGENT_DIR" ]]; then
    rm -rf "$PI_AGENT_DIR"
  fi
}
trap cleanup_pi EXIT

# Capture host AGENTS.md content and mtime BEFORE rc up
AGENTS_CONTENT_BEFORE=$(cat "$AGENTS_MD_PATH")
AGENTS_MTIME_BEFORE=$(stat -f '%m' "$AGENTS_MD_PATH" 2>/dev/null || stat -c '%Y' "$AGENTS_MD_PATH" 2>/dev/null || true)

TEST_WS=$(mktemp -d)

# ---- Bring up the container ----
echo ""
echo "=== Bringing up container (rc up) ==="
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true

CONTAINER=$(_resolve_container "$TEST_WS")
if [[ -z "$CONTAINER" ]]; then
  fail "container did not come up (fatal — cannot continue)"
  echo "$FAILURES test(s) FAILED (fatal — cannot continue without container)."
  exit 1
fi

# ---- Test 1: Host ~/.pi/agent/AGENTS.md content + mtime unchanged after rc up ----
echo ""
echo "=== Test 1: Host ~/.pi/agent/AGENTS.md content + mtime unchanged after rc up ==="

AGENTS_CONTENT_AFTER=$(cat "$AGENTS_MD_PATH")
AGENTS_MTIME_AFTER=$(stat -f '%m' "$AGENTS_MD_PATH" 2>/dev/null || stat -c '%Y' "$AGENTS_MD_PATH" 2>/dev/null || true)

if [[ "$AGENTS_CONTENT_AFTER" == "$AGENTS_CONTENT_BEFORE" ]]; then
  pass "Test 1a: ~/.pi/agent/AGENTS.md content unchanged after rc up"
else
  fail "Test 1a: ~/.pi/agent/AGENTS.md content was mutated by init" \
    "before='$AGENTS_CONTENT_BEFORE' after='$AGENTS_CONTENT_AFTER'"
fi

if [[ "$AGENTS_MTIME_AFTER" == "$AGENTS_MTIME_BEFORE" ]]; then
  pass "Test 1b: ~/.pi/agent/AGENTS.md mtime unchanged after rc up"
else
  fail "Test 1b: ~/.pi/agent/AGENTS.md mtime changed (file was written)" \
    "before=$AGENTS_MTIME_BEFORE after=$AGENTS_MTIME_AFTER"
fi

# ---- Test 2: Cage ~/.claude/CLAUDE.md contains /etc/rip-cage/cage-pi.md reference ----
echo ""
echo "=== Test 2: Cage ~/.claude/CLAUDE.md contains /etc/rip-cage/cage-pi.md inside topology fence ==="

# Check the reference string is present anywhere in CLAUDE.md
if docker exec "$CONTAINER" grep -q '/etc/rip-cage/cage-pi.md' /home/agent/.claude/CLAUDE.md; then
  pass "Test 2a: /etc/rip-cage/cage-pi.md reference found in ~/.claude/CLAUDE.md"
else
  fail "Test 2a: /etc/rip-cage/cage-pi.md reference missing from ~/.claude/CLAUDE.md"
fi

# Check the reference is inside the rip-cage-topology fence (not outside it)
inside_fence=$(docker exec "$CONTAINER" awk '
  /^<!-- begin:rip-cage-topology -->/ { inside=1; next }
  /^<!-- end:rip-cage-topology -->/   { inside=0; next }
  inside && /\/etc\/rip-cage\/cage-pi\.md/ { found=1 }
  END { print (found ? "yes" : "no") }
' /home/agent/.claude/CLAUDE.md 2>/dev/null || true)

if [[ "$inside_fence" == "yes" ]]; then
  pass "Test 2b: /etc/rip-cage/cage-pi.md reference is inside the rip-cage-topology fence"
else
  fail "Test 2b: /etc/rip-cage/cage-pi.md reference is NOT inside the rip-cage-topology fence"
fi

# ---- Test 3: /etc/rip-cage/cage-pi.md is readable inside the cage ----
echo ""
echo "=== Test 3: /etc/rip-cage/cage-pi.md is readable inside the cage ==="

if docker exec "$CONTAINER" test -r /etc/rip-cage/cage-pi.md; then
  pass "Test 3: /etc/rip-cage/cage-pi.md is readable inside the cage"
else
  fail "Test 3: /etc/rip-cage/cage-pi.md not readable inside the cage"
fi

# ---- Test 4: CLAUDE.md marker count is exactly 1 (no duplication) ----
echo ""
echo "=== Test 4: CLAUDE.md has exactly one begin:rip-cage-topology (unsuffixed) marker ==="

# Count the unsuffixed marker (must not match -pi suffix markers separately)
claude_count=$(docker exec "$CONTAINER" grep -c '^<!-- begin:rip-cage-topology -->' /home/agent/.claude/CLAUDE.md 2>/dev/null || true)
[[ -z "$claude_count" ]] && claude_count=0
if [[ "$claude_count" -eq 1 ]]; then
  pass "Test 4: exactly one begin:rip-cage-topology marker in CLAUDE.md"
else
  fail "Test 4: expected 1 marker, got $claude_count" "$claude_count"
fi

# ---- Test 5: No pi-topology fence markers in CLAUDE.md (pi path is reference-only) ----
echo ""
echo "=== Test 5: No rip-cage-topology-pi fence markers in CLAUDE.md ==="

pi_in_claude=$(docker exec "$CONTAINER" grep -c 'begin:rip-cage-topology-pi' /home/agent/.claude/CLAUDE.md 2>/dev/null || true)
[[ -z "$pi_in_claude" ]] && pi_in_claude=0
if [[ "$pi_in_claude" -eq 0 ]]; then
  pass "Test 5: no pi-topology fence markers in CLAUDE.md (reference-only path is clean)"
else
  fail "Test 5: pi-topology fence marker found in CLAUDE.md — should be reference-only" "$pi_in_claude"
fi

# ---- Test 6: init log line emitted when PI_CODING_AGENT_DIR=/home/agent/.pi/agent ----
echo ""
echo "=== Test 6: init log line mentions cage-pi.md when PI_CODING_AGENT_DIR=/home/agent/.pi/agent ==="

init_log_output=$(docker exec "$CONTAINER" bash -c "PI_CODING_AGENT_DIR=/home/agent/.pi/agent /usr/local/bin/init-rip-cage.sh 2>&1" || true)
if echo "$init_log_output" | grep -q '/etc/rip-cage/cage-pi.md'; then
  pass "Test 6: init log line mentions /etc/rip-cage/cage-pi.md when PI_CODING_AGENT_DIR=/home/agent/.pi/agent"
else
  fail "Test 6: init log line missing cage-pi.md reference" "$init_log_output"
fi

# ---- Test 7: mount-absent guard — init exits 0, no AGENTS.md error ----
echo ""
echo "=== Test 7: mount-absent guard — init exits 0 when pi mount was skipped ==="

# Temporarily rename ~/.pi/agent so rc up skips the mount
PI_AGENT_BACKUP_TMP="${HOME}/.pi/agent.bak-test-pi-cage-$$"
if [[ -d "$PI_AGENT_DIR" ]]; then
  mv "$PI_AGENT_DIR" "$PI_AGENT_BACKUP_TMP"
fi

TEST_WS2=$(mktemp -d)
RC_ALLOWED_ROOTS="$TEST_WS2" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS2" </dev/null >/dev/null 2>&1 || true

# Restore the pi agent dir immediately after rc up
if [[ -d "$PI_AGENT_BACKUP_TMP" ]]; then
  mv "$PI_AGENT_BACKUP_TMP" "$PI_AGENT_DIR"
fi

CONTAINER2=$(_resolve_container "$TEST_WS2")
if [[ -z "$CONTAINER2" ]]; then
  fail "Test 7: container2 did not come up"
else
  # Re-run init explicitly and capture exit code
  init_exit=0
  docker exec "$CONTAINER2" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || init_exit=$?
  if [[ $init_exit -eq 0 ]]; then
    pass "Test 7: init exits 0 even when pi mount was not wired"
  else
    fail "Test 7: init exited $init_exit (expected 0)" "$init_exit"
  fi

  # 7b: /home/agent/.pi/agent/AGENTS.md must NOT exist when auth mount was skipped
  # (init must not create host files when the auth.json sub-mount is absent)
  if ! docker exec "$CONTAINER2" test -f /home/agent/.pi/agent/AGENTS.md; then
    pass "Test 7b: /home/agent/.pi/agent/AGENTS.md not created when auth mount was skipped"
  else
    fail "Test 7b: /home/agent/.pi/agent/AGENTS.md exists but mount was skipped — init wrote to it"
  fi

  # 7c: /etc/rip-cage/cage-pi.md must still be readable (it's image-baked)
  if docker exec "$CONTAINER2" test -r /etc/rip-cage/cage-pi.md; then
    pass "Test 7c: /etc/rip-cage/cage-pi.md still readable even without pi mount"
  else
    fail "Test 7c: /etc/rip-cage/cage-pi.md not readable in mount-absent container"
  fi

  # 7d: Negative case — init log line must NOT be emitted when PI_CODING_AGENT_DIR is unset
  # (PI_CODING_AGENT_DIR unset means pi support is not active)
  init_log_output2=$(docker exec "$CONTAINER2" bash -c "unset PI_CODING_AGENT_DIR; /usr/local/bin/init-rip-cage.sh 2>&1" || true)
  if echo "$init_log_output2" | grep -q '/etc/rip-cage/cage-pi.md'; then
    fail "Test 7d: init log line emitted on no-pi-mount container (guard should suppress it)" "$init_log_output2"
  else
    pass "Test 7d: init log line correctly absent on no-pi-mount container"
  fi

  docker rm -f "$CONTAINER2" >/dev/null 2>&1 || true
fi

# ---- Summary ----
echo ""
# recount: 1a=1,1b=2,2a=3,2b=4,3=5,4=6,5=7,6=8,7=9,7b=10,7c=11,7d=12 = 12 total
TOTAL=12
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All $TOTAL pi-cage-context tests passed."
else
  echo "$FAILURES of $TOTAL test(s) FAILED."
  exit 1
fi
