#!/usr/bin/env bash
set -euo pipefail
PASS=0
FAIL=0

echo "=== Rip Cage Safety Stack Smoke Test ==="

# (a) DCG denies a destructive command
echo -n "Test 1: DCG blocks destructive command... "
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /usr/local/bin/dcg 2>/dev/null || true)
if echo "$RESULT" | grep -qE '"permissionDecision".*"deny"'; then
  echo "PASS"
  PASS=$((PASS + 1))
else
  echo "FAIL: dcg did not deny 'rm -rf /'"
  echo "  Got: $RESULT"
  FAIL=$((FAIL + 1))
fi

# (b) block-compound denies a compound command
echo -n "Test 2: block-compound blocks compound command... "
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls && rm foo"}}' | /usr/local/lib/rip-cage/hooks/block-compound-commands.sh 2>/dev/null || true)
if echo "$RESULT" | grep -qE '"permissionDecision".*"deny"'; then
  echo "PASS"
  PASS=$((PASS + 1))
else
  echo "FAIL: block-compound did not deny 'ls && rm foo'"
  echo "  Got: $RESULT"
  FAIL=$((FAIL + 1))
fi

# (c) settings.json contains expected hooks and auto mode
echo -n "Test 3: settings.json has auto mode... "
if jq -e '.permissions.defaultMode == "auto"' ~/.claude/settings.json > /dev/null 2>&1; then
  echo "PASS"
  PASS=$((PASS + 1))
else
  echo "FAIL: defaultMode is not 'auto' in ~/.claude/settings.json"
  FAIL=$((FAIL + 1))
fi

echo -n "Test 4: settings.json has DCG hook... "
if jq -e '.hooks.PreToolUse[] | select(.hooks[].command == "/usr/local/bin/dcg")' ~/.claude/settings.json > /dev/null 2>&1; then
  echo "PASS"
  PASS=$((PASS + 1))
else
  echo "FAIL: DCG hook not found in settings.json"
  FAIL=$((FAIL + 1))
fi

echo -n "Test 5: settings.json has block-compound hook... "
if jq -e '.hooks.PreToolUse[] | select(.hooks[].command == "/usr/local/lib/rip-cage/hooks/block-compound-commands.sh")' ~/.claude/settings.json > /dev/null 2>&1; then
  echo "PASS"
  PASS=$((PASS + 1))
else
  echo "FAIL: block-compound hook not found in settings.json"
  FAIL=$((FAIL + 1))
fi

# (d) Claude Code is installed
echo -n "Test 6: claude --version succeeds... "
if claude --version > /dev/null 2>&1; then
  echo "PASS ($(claude --version))"
  PASS=$((PASS + 1))
else
  echo "FAIL: claude --version failed"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
