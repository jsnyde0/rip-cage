#!/usr/bin/env bash
# test-pi-dcg-gate.sh — Regression suite for pi-cage DCG + compound-blocker parity (rip-cage-bl1)
#
# Tests that the dcg-gate.ts extension:
#   - Exists at the cage-owned auto-discovery path
#   - Properly invokes dcg-guard with tool_name="bash" (pinning, so MCP/custom tool names
#     don't cause dcg to fail open)
#   - Blocks destructive DCG core-pack class commands
#   - Allows safe commands (rm -rf /tmp/..., push --force-with-lease, checkout -b)
#   - Blocks compound commands (&&, ;, ||)
#   - Does NOT block single legitimate commands
#
# This test exercises the guard LOGIC (via the underlying dcg-guard + compound-check scripts
# it delegates to) rather than pi itself — a headless pi session with auth is deferred to
# the e2e harness. The structural + delegation tests here are the regression guard (acceptance #7).
#
# Conditional: pi-specific checks are guarded on pi being present so non-pi cages don't fail.

set -uo pipefail

FAILURES=0
TOTAL=0

check() {
  local name="$1" result="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "pass" ]]; then
    echo "PASS  [$TOTAL] $name${detail:+ — $detail}"
  else
    echo "FAIL  [$TOTAL] $name${detail:+ — $detail}"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "=== Pi DCG Gate (dcg-gate.ts) — Safety Parity Suite ==="
echo ""

# Guard: only run pi-specific tests if pi is installed.
if ! command -v pi >/dev/null 2>&1; then
  echo "INFO: pi not installed — skipping pi-dcg-gate checks (non-pi cage)"
  echo "=== Results: $TOTAL checks, 0 failed (pi not present — skipped) ==="
  exit 0
fi

# -----------------------------------------------------------------------
# 1. Structural: dcg-gate.ts exists at cage-owned auto-discovery path
# -----------------------------------------------------------------------
echo "-- Structural checks --"
DCG_GATE="/home/agent/.pi/agent/extensions/dcg-gate.ts"
if [[ -f "$DCG_GATE" ]]; then
  check "dcg-gate.ts exists at cage-owned extensions path" "pass" "$DCG_GATE"
else
  check "dcg-gate.ts exists at cage-owned extensions path" "fail" "missing: $DCG_GATE"
fi

# 1b. Extension does NOT reference /pi-agent (host-mounted path)
if [[ -f "$DCG_GATE" ]]; then
  if grep -q '/pi-agent' "$DCG_GATE" 2>/dev/null; then
    check "dcg-gate.ts has no /pi-agent path reference" "fail" "found /pi-agent in extension source"
  else
    check "dcg-gate.ts has no /pi-agent path reference" "pass"
  fi
fi

# 1c. Extension calls dcg-guard wrapper, not raw dcg
# Grep for the const assignment (code), not merely the string appearing in header comments.
# Strips // and block-comment (* prefix) lines before matching.
if [[ -f "$DCG_GATE" ]]; then
  if grep -v '^\s*//' "$DCG_GATE" 2>/dev/null | grep -v '^\s*\*' | grep -q 'DCG_GUARD\s*=.*dcg-guard'; then
    check "dcg-gate.ts invokes dcg-guard (not raw dcg)" "pass"
  else
    check "dcg-gate.ts invokes dcg-guard (not raw dcg)" "fail" "DCG_GUARD const assignment with dcg-guard path not found in non-comment code"
  fi
fi

# 1d. Extension pins tool_name to "bash" in dcg envelope (call site, not comment)
# Grep for the actual object property: tool_name: "bash" (not a comment mention).
if [[ -f "$DCG_GATE" ]]; then
  if grep -v '^\s*//' "$DCG_GATE" 2>/dev/null | grep -v '^\s*\*' | grep -q 'tool_name.*"bash"'; then
    check "dcg-gate.ts pins tool_name to bash in dcg envelope" "pass"
  else
    check "dcg-gate.ts pins tool_name to bash in dcg envelope" "fail" "tool_name:\"bash\" property not found in non-comment code"
  fi
fi

# 1e. Extension reads permissionDecision from JSON (call site, not comment)
# Grep for the actual comparison expression: permissionDecision === (only in code, not comments).
if [[ -f "$DCG_GATE" ]]; then
  if grep -v '^\s*//' "$DCG_GATE" 2>/dev/null | grep -v '^\s*\*' | grep -q 'permissionDecision\s*==='; then
    check "dcg-gate.ts reads permissionDecision from stdout JSON" "pass"
  else
    check "dcg-gate.ts reads permissionDecision from stdout JSON" "fail" "permissionDecision === comparison not found in non-comment code"
  fi
fi

# -----------------------------------------------------------------------
# 2. DCG guard present + functional (via dcg-guard wrapper)
# -----------------------------------------------------------------------
echo ""
echo "-- DCG guard delegation --"

DCG_GUARD="/usr/local/lib/rip-cage/bin/dcg-guard"
if [[ -x "$DCG_GUARD" ]]; then
  check "dcg-guard wrapper present and executable" "pass"
else
  check "dcg-guard wrapper present and executable" "fail" "missing or not executable: $DCG_GUARD"
fi

# 2a. Destructive command denied (rm -rf /)
# This is what dcg-gate.ts delegates to via dcg-guard with tool_name=bash.
dcg_rm_rf=$(printf '{"tool_name":"bash","tool_input":{"command":"rm -rf /"}}' | "$DCG_GUARD" 2>/dev/null || true)
if echo "$dcg_rm_rf" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG gate: rm -rf / denied (destructive — root path)" "pass"
else
  check "DCG gate: rm -rf / denied (destructive — root path)" "fail" "$dcg_rm_rf"
fi

# 2b. Destructive command denied (git reset --hard)
dcg_git_reset=$(printf '{"tool_name":"bash","tool_input":{"command":"git reset --hard HEAD~1"}}' | "$DCG_GUARD" 2>/dev/null || true)
if echo "$dcg_git_reset" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG gate: git reset --hard denied" "pass"
else
  check "DCG gate: git reset --hard denied" "fail" "$dcg_git_reset"
fi

# 2c. Destructive command denied (git push --force)
dcg_git_push_force=$(printf '{"tool_name":"bash","tool_input":{"command":"git push --force origin main"}}' | "$DCG_GUARD" 2>/dev/null || true)
if echo "$dcg_git_push_force" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG gate: git push --force denied" "pass"
else
  check "DCG gate: git push --force denied" "fail" "$dcg_git_push_force"
fi

# 2d. Destructive command denied (git clean -f)
dcg_git_clean=$(printf '{"tool_name":"bash","tool_input":{"command":"git clean -f"}}' | "$DCG_GUARD" 2>/dev/null || true)
if echo "$dcg_git_clean" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG gate: git clean -f denied" "pass"
else
  check "DCG gate: git clean -f denied" "fail" "$dcg_git_clean"
fi

# -----------------------------------------------------------------------
# 3. Safe commands ALLOWED by dcg (via wrapper with tool_name=bash)
# -----------------------------------------------------------------------
echo ""
echo "-- Safe command allowlist --"

# 3a. rm -rf /tmp/... allowed (temp path)
dcg_rm_tmp=$(printf '{"tool_name":"bash","tool_input":{"command":"rm -rf /tmp/myproject-build"}}' | "$DCG_GUARD" 2>/dev/null || true)
if echo "$dcg_rm_tmp" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG gate: rm -rf /tmp/... allowed (temp path)" "fail" "$dcg_rm_tmp"
else
  check "DCG gate: rm -rf /tmp/... allowed (temp path)" "pass"
fi

# 3b. git push --force-with-lease allowed
dcg_fwl=$(printf '{"tool_name":"bash","tool_input":{"command":"git push --force-with-lease origin feature"}}' | "$DCG_GUARD" 2>/dev/null || true)
if echo "$dcg_fwl" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG gate: git push --force-with-lease allowed" "fail" "$dcg_fwl"
else
  check "DCG gate: git push --force-with-lease allowed" "pass"
fi

# 3c. git checkout -b (new branch) allowed
dcg_checkout=$(printf '{"tool_name":"bash","tool_input":{"command":"git checkout -b feature/my-branch"}}' | "$DCG_GUARD" 2>/dev/null || true)
if echo "$dcg_checkout" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG gate: git checkout -b allowed" "fail" "$dcg_checkout"
else
  check "DCG gate: git checkout -b allowed" "pass"
fi

# -----------------------------------------------------------------------
# 4. tool_name pinning proof — MCP/custom tool name still guarded
#    The extension passes tool_name="bash" to dcg regardless of the
#    originating pi tool name. We simulate a custom tool by verifying
#    that dcg's is_supported_shell_tool accepts "bash" (the value dcg-gate
#    always sends) — and rejects an arbitrary MCP tool name like "mcp_exec".
# -----------------------------------------------------------------------
echo ""
echo "-- tool_name pinning (non-bash tool guarded via bash pinning) --"

# 4a. "bash" (lowercase) accepted: dcg evaluates the command → destructive → deny
dcg_pin_bash=$(printf '{"tool_name":"bash","tool_input":{"command":"rm -rf /"}}' | "$DCG_GUARD" 2>/dev/null || true)
if echo "$dcg_pin_bash" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG pinning: tool_name=bash (lowercase) evaluated and denied destructive" "pass"
else
  check "DCG pinning: tool_name=bash (lowercase) evaluated and denied destructive" "fail" "$dcg_pin_bash"
fi

# 4b. Verify dcg FAILS OPEN on unknown tool name (proves pinning is load-bearing)
# A MCP tool name that is NOT in dcg's is_supported_shell_tool → no-command → allow
dcg_no_eval=$(printf '{"tool_name":"mcp_exec","tool_input":{"command":"rm -rf /"}}' | "$DCG_GUARD" 2>/dev/null || true)
if echo "$dcg_no_eval" | grep -qE '"permissionDecision".*"deny"'; then
  # dcg denied it — unexpected, but not a regression (conservative)
  check "DCG pinning: unknown tool_name mcp_exec fails open without pinning (sensitivity proof)" "fail" \
    "dcg denied mcp_exec — sensitivity proof inconclusive (dcg may have extended allowlist)"
else
  check "DCG pinning: unknown tool_name mcp_exec fails open without pinning (sensitivity proof)" "pass" \
    "mcp_exec NOT evaluated by dcg — confirms dcg-gate MUST pin to bash for MCP tools"
fi

# -----------------------------------------------------------------------
# 5. Compound-command blocker delegation
# -----------------------------------------------------------------------
echo ""
echo "-- Compound-command blocker --"

COMPOUND_SCRIPT="/usr/local/lib/rip-cage/hooks/block-compound-commands.sh"
if [[ ! -x "$COMPOUND_SCRIPT" ]]; then
  check "compound blocker script present" "fail" "missing: $COMPOUND_SCRIPT"
fi

# 5a. && chain denied
cmp_and=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls /tmp && rm -rf /"}}' | "$COMPOUND_SCRIPT" 2>/dev/null || true)
if echo "$cmp_and" | grep -qE '"permissionDecision".*"deny"'; then
  check "Compound gate: && chain denied" "pass"
else
  check "Compound gate: && chain denied" "fail" "$cmp_and"
fi

# 5b. ; chain denied (single ; not ;;)
cmp_semi=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls /tmp; rm -rf /"}}' | "$COMPOUND_SCRIPT" 2>/dev/null || true)
if echo "$cmp_semi" | grep -qE '"permissionDecision".*"deny"'; then
  check "Compound gate: ; chain denied" "pass"
else
  check "Compound gate: ; chain denied" "fail" "$cmp_semi"
fi

# 5c. || chain denied
cmp_or=$(printf '{"tool_name":"Bash","tool_input":{"command":"false || rm -rf /"}}' | "$COMPOUND_SCRIPT" 2>/dev/null || true)
if echo "$cmp_or" | grep -qE '"permissionDecision".*"deny"'; then
  check "Compound gate: || chain denied" "pass"
else
  check "Compound gate: || chain denied" "fail" "$cmp_or"
fi

# 5d. Quoted ; does NOT trigger (quote-aware)
cmp_quoted=$(printf '{"tool_name":"Bash","tool_input":{"command":"echo \"hello;world\""}}' | "$COMPOUND_SCRIPT" 2>/dev/null || true)
if [[ -z "$cmp_quoted" ]]; then
  check "Compound gate: quoted ; not blocked (quote-aware)" "pass"
else
  check "Compound gate: quoted ; not blocked (quote-aware)" "fail" "$cmp_quoted"
fi

# 5e. Single legitimate command allowed
cmp_legit=$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | "$COMPOUND_SCRIPT" 2>/dev/null || true)
if [[ -z "$cmp_legit" ]]; then
  check "Compound gate: single git status allowed" "pass"
else
  check "Compound gate: single git status allowed" "fail" "$cmp_legit"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "=== Results: $TOTAL checks, $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]] || exit 1
