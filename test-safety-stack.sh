#!/usr/bin/env bash
set -euo pipefail
PASS=0
FAIL=0
TOTAL=0

check() {
  local name="$1" result="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "pass" ]]; then
    echo "PASS  [$TOTAL] $name${detail:+ — $detail}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  [$TOTAL] $name${detail:+ — $detail}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Rip Cage Health Check ==="
echo ""

# --- User & Environment ---
echo "-- User & Environment --"

# 1. Container user is agent
user=$(whoami 2>/dev/null || echo "unknown")
check "Container user is agent" "$([[ "$user" == "agent" ]] && echo pass || echo fail)" "$user"

# 2. Not running as root
uid=$(id -u 2>/dev/null || echo "0")
check "Not running as root" "$([[ "$uid" != "0" ]] && echo pass || echo fail)" "uid=$uid"

# 3. /workspace is mounted
check "/workspace is mounted" "$([[ -d /workspace ]] && echo pass || echo fail)"

# 4. /workspace is writable
if touch /workspace/.rc-test-write 2>/dev/null && rm -f /workspace/.rc-test-write; then
  check "/workspace is writable" "pass"
else
  check "/workspace is writable" "fail"
fi

echo ""
echo "-- Settings & Safety Stack --"

# 5. settings.json exists
check "settings.json exists" "$([[ -f ~/.claude/settings.json ]] && echo pass || echo fail)"

# 6. settings.json is valid JSON
if jq . < ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json is valid JSON" "pass"
else
  check "settings.json is valid JSON" "fail"
fi

# 7. settings.json has auto mode
if jq -e '.permissions.defaultMode == "auto"' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json has auto mode" "pass"
else
  check "settings.json has auto mode" "fail"
fi

# 8. settings.json has DCG hook wired
if jq -e '.hooks.PreToolUse[] | select(.hooks[].command == "/usr/local/bin/dcg")' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json wires DCG hook" "pass"
else
  check "settings.json wires DCG hook" "fail"
fi

# 9. settings.json has compound blocker hook wired
if jq -e '.hooks.PreToolUse[] | select(.hooks[].command == "/usr/local/lib/rip-cage/hooks/block-compound-commands.sh")' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json wires compound blocker" "pass"
else
  check "settings.json wires compound blocker" "fail"
fi

# 10. settings.json denies .git/hooks writes
if jq -e '.permissions.deny[] | select(startswith("Write(.git/hooks")))' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json denies .git/hooks writes" "pass"
else
  check "settings.json denies .git/hooks writes" "fail"
fi

# 11. DCG denies destructive command
dcg_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /usr/local/bin/dcg 2>/dev/null || true)
if echo "$dcg_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG denies destructive command" "pass"
else
  check "DCG denies destructive command" "fail" "$dcg_result"
fi

# 12. Compound blocker denies chain
compound_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls && rm foo"}}' | /usr/local/lib/rip-cage/hooks/block-compound-commands.sh 2>/dev/null || true)
if echo "$compound_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "Compound blocker denies chain" "pass"
else
  check "Compound blocker denies chain" "fail" "$compound_result"
fi

echo ""
echo "-- Auth --"

# 13. Auth present (credentials file OR API key)
if [[ -s ~/.claude/.credentials.json ]] || [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  check "Auth present" "pass" "$([[ -s ~/.claude/.credentials.json ]] && echo "OAuth" || echo "API key")"
else
  check "Auth present" "fail" "no credentials file and no ANTHROPIC_API_KEY"
fi

# 14. Token not expired (skip if using API key only)
if [[ -s ~/.claude/.credentials.json ]] && command -v jq &>/dev/null; then
  expiry=$(jq -r '.expiry // .expiresAt // empty' ~/.claude/.credentials.json 2>/dev/null || true)
  if [[ -n "$expiry" ]]; then
    expiry_epoch=$(date -d "$expiry" "+%s" 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${expiry%%.*}" "+%s" 2>/dev/null || true)
    now_epoch=$(date "+%s")
    if [[ -n "$expiry_epoch" ]] && [[ "$expiry_epoch" -gt "$now_epoch" ]]; then
      remaining=$(( (expiry_epoch - now_epoch) / 60 ))
      check "Token not expired" "pass" "${remaining}m remaining"
    elif [[ -n "$expiry_epoch" ]]; then
      check "Token not expired" "fail" "expired"
    else
      check "Token not expired" "pass" "could not parse expiry (skipped)"
    fi
  else
    check "Token not expired" "pass" "no expiry field (skipped)"
  fi
else
  check "Token not expired" "pass" "no credentials file (skipped)"
fi

echo ""
echo "-- Git --"

# 15. git available and identity set
git_name=$(git config user.name 2>/dev/null || true)
git_email=$(git config user.email 2>/dev/null || true)
if [[ -n "$git_name" ]] && [[ -n "$git_email" ]]; then
  check "git identity set" "pass" "$git_name <$git_email>"
else
  check "git identity set" "fail" "name='$git_name' email='$git_email'"
fi

echo ""
echo "-- Tools --"

# 16-24. Tool availability checks
for tool_check in \
  "claude:claude --version" \
  "jq:jq --version" \
  "tmux:tmux -V" \
  "bd:bd --version" \
  "python3:python3 --version" \
  "uv:uv --version" \
  "node:node --version" \
  "bun:bun --version" \
  "gh:gh --version"; do
  tool_name="${tool_check%%:*}"
  tool_cmd="${tool_check#*:}"
  if command -v "$tool_name" &>/dev/null; then
    version=$($tool_cmd 2>&1 | head -1 || true)
    check "$tool_name available" "pass" "$version"
  else
    check "$tool_name available" "fail" "not installed"
  fi
done

echo ""
echo "-- Beads (functional) --"

# 25. bd can connect to Dolt and list issues (requires host Dolt server running)
if [ -d /workspace/.beads ]; then
  bd_output=$(cd /workspace && bd list 2>&1 || true)
  if echo "$bd_output" | grep -qE "(Total:|No issues found)"; then
    issue_count=$(echo "$bd_output" | sed -n 's/.*Total: \([0-9]*\).*/\1/p')
    check "bd connects to Dolt server" "pass" "${issue_count} issues"
  else
    # Extract first line of error for detail
    bd_err=$(echo "$bd_output" | head -1)
    check "bd connects to Dolt server" "fail" "$bd_err"
  fi
else
  check "bd connects to Dolt server" "pass" "no .beads/ in workspace (skipped)"
fi

echo ""
echo "-- Network & Disk --"

# 26. DNS resolution
if getent hosts github.com >/dev/null 2>&1 || dig +short github.com >/dev/null 2>&1 || host github.com >/dev/null 2>&1; then
  check "DNS resolution (github.com)" "pass"
else
  check "DNS resolution (github.com)" "fail"
fi

# 27. Sufficient disk space (>1GB free on /workspace)
avail_kb=$(df /workspace 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
avail_gb=$(( avail_kb / 1048576 ))
if [[ "$avail_kb" -gt 1048576 ]]; then
  check "Disk space >1GB on /workspace" "pass" "${avail_gb}GB free"
else
  check "Disk space >1GB on /workspace" "fail" "${avail_gb}GB free"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
[[ "$FAIL" -eq 0 ]] || exit 1
