#!/usr/bin/env bash
# Verification test for bead rip-cage-tha:
#   - sudoers chown is pinned to exact paths (no wildcard)
#   - .claude and .claude-state dirs are pre-created after USER agent
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Dockerfile Sudoers & Pre-Created Dirs Tests ==="
echo ""

# --- Test 1: sudoers does NOT use chown wildcard ---
echo "-- Test 1: sudoers does not use chown wildcard --"
SUDOERS_LINE=$(grep 'sudoers.d/agent' "$DOCKERFILE")
if echo "$SUDOERS_LINE" | grep -q 'chown \*'; then
  fail "sudoers still uses chown wildcard"
  echo "  Line: $SUDOERS_LINE"
else
  pass "sudoers does not use chown wildcard"
fi

# --- Test 2: sudoers pins chown to /home/agent/.claude ---
echo ""
echo "-- Test 2: sudoers allows chown for /home/agent/.claude --"
if echo "$SUDOERS_LINE" | grep -q 'chown agent\\:agent /home/agent/.claude,'; then
  pass "sudoers allows chown for /home/agent/.claude"
else
  fail "sudoers missing chown for /home/agent/.claude"
  echo "  Line: $SUDOERS_LINE"
fi

# --- Test 3: sudoers pins chown to /home/agent/.claude-state ---
echo ""
echo "-- Test 3: sudoers allows chown for /home/agent/.claude-state --"
if echo "$SUDOERS_LINE" | grep -q 'chown agent\\:agent /home/agent/.claude-state'; then
  pass "sudoers allows chown for /home/agent/.claude-state"
else
  fail "sudoers missing chown for /home/agent/.claude-state"
  echo "  Line: $SUDOERS_LINE"
fi

# --- Test 4: Dockerfile pre-creates .claude and .claude-state dirs ---
echo ""
echo "-- Test 4: Dockerfile pre-creates .claude and .claude-state after USER agent --"
# Check that mkdir appears after USER agent line
AFTER_USER=$(sed -n '/^USER agent/,$ p' "$DOCKERFILE")
if echo "$AFTER_USER" | grep -q 'mkdir.*\.claude.*\.claude-state'; then
  pass "Dockerfile pre-creates .claude and .claude-state dirs after USER agent"
else
  fail "Dockerfile does not pre-create .claude and .claude-state after USER agent"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
