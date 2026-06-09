#!/usr/bin/env bash
# test-pi-dcg-gate.sh — Regression suite for pi-cage DCG parity (rip-cage-bl1)
#
# Tests that the dcg-gate.ts extension:
#   - Exists at the cage-owned auto-discovery path
#   - Properly invokes dcg-guard with tool_name="bash" (pinning, so MCP/custom tool names
#     don't cause dcg to fail open)
#   - Blocks destructive DCG core-pack class commands
#   - Allows safe commands (rm -rf /tmp/..., push --force-with-lease, checkout -b)
#   - Does NOT block single legitimate commands
#
# NOTE: compound-blocker section removed in rip-cage-4r8. DCG is chaining-robust
# (unanchored whole-command regex matching); see rip-cage-4r8 regression tests in
# test-safety-stack.sh (checks 11f/11g/11h) for the chaining-robustness assertions.
#
# This test exercises the guard LOGIC (via the underlying dcg-guard script
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
# 5. Guard-parity re-verify check (rip-cage-9yg0)
#
# PI_VERSION=latest means pi can bump on any rebuild. The dcg-gate's
# extractCommand reads ONLY the "command" field. If a future pi release
# adds an exec-capable tool with a different field name (e.g. "script",
# "cmd"), it would pass UNGUARDED.
#
# This check fires on REAL exec-surface drift (content/schema parity check —
# Option 1), NOT on every harmless version bump. It is FAIL altitude because
# it is a true safety-parity assertion, not a soft warning.
#
# False-green protection: the positive sentinel (5a) asserts the known schema
# IS FOUND first. If the dist path moves or the schema is renamed, 5a FAILS
# LOUD — the check cannot pass vacuously by absence-against-empty-source.
# -----------------------------------------------------------------------
echo ""
echo "-- Guard-parity re-verify check (exec-field coverage, rip-cage-9yg0) --"

PI_DIST_BASH="/usr/lib/node_modules/@mariozechner/pi-coding-agent/dist/core/tools/bash.js"
PI_DIST_INDEX="/usr/lib/node_modules/@mariozechner/pi-coding-agent/dist/core/tools/index.js"

# 5a. POSITIVE SENTINEL: bash.js exists at the stable dist path AND contains
#     bashSchema with the "command:" field.
#     MUST pass before 5b/5c are meaningful — proves the check has a real target.
#     If this FAILs, 5b/5c are vacuous (absence-against-empty-source would
#     trivially "pass" a missing file). We only advance to 5b/5c if 5a passes.
SENTINEL_OK=false
if [[ ! -f "$PI_DIST_BASH" ]]; then
  check "guard-parity [5a] positive sentinel: bash.js exists at dist path" "fail" \
    "missing: $PI_DIST_BASH — dist path moved? re-verify dcg-gate exec-field coverage"
elif ! grep -q 'bashSchema' "$PI_DIST_BASH" 2>/dev/null; then
  check "guard-parity [5a] positive sentinel: bashSchema found in bash.js" "fail" \
    "bashSchema not found in $PI_DIST_BASH — schema renamed? re-verify dcg-gate exec-field coverage"
elif ! grep -q 'command:.*Type\.String\|command: Type\.String' "$PI_DIST_BASH" 2>/dev/null; then
  check "guard-parity [5a] positive sentinel: bashSchema uses field 'command'" "fail" \
    "field 'command: Type.String' not found in $PI_DIST_BASH — field renamed? dcg-gate extractCommand must be updated"
else
  check "guard-parity [5a] positive sentinel: bash.js has bashSchema with command field" "pass" \
    "confirmed: command: Type.String present in bashSchema"
  SENTINEL_OK=true
fi

if [[ "$SENTINEL_OK" == "true" ]]; then
  # 5b. DRIFT CHECK: no alternative exec-field name appears in schema context in bash.js.
  #     If pi adds an exec-capable tool using "script" or "cmd" as the shell-command field,
  #     dcg-gate's extractCommand would miss it (silent guard bypass).
  #     We check for the typebox schema-definition pattern: <fieldname>: Type.String(
  #     Non-exec fields (e.g. "path", "content") legitimately use Type.String — we target
  #     only the names that would represent an alternative bash-exec input field.
  DRIFT_FOUND=false
  DRIFT_DETAIL=""
  for alt_field in "script" "cmd" "command_string" "shell_command" "run" "exec"; do
    if grep -qE "^\s+${alt_field}:\s+Type\.String" "$PI_DIST_BASH" 2>/dev/null; then
      DRIFT_FOUND=true
      DRIFT_DETAIL="field '${alt_field}: Type.String' found in bash.js — dcg-gate extractCommand does not read '${alt_field}'; re-verify coverage"
      break
    fi
  done
  if [[ "$DRIFT_FOUND" == "true" ]]; then
    check "guard-parity [5b] no alternative exec-field name in bashSchema" "fail" "$DRIFT_DETAIL"
  else
    check "guard-parity [5b] no alternative exec-field name in bashSchema" "pass" \
      "no script/cmd/run/exec schema fields found in bash.js"
  fi

  # 5c. COVERAGE COMPLETENESS: allToolNames in index.js includes "bash" (positive sentinel)
  #     and does not include any new tool name that could be exec-capable beyond the known set.
  #     Known non-exec tools: read, edit, write, grep, find, ls. If a new name appears
  #     (e.g. "execute", "shell", "run"), it warrants re-verifying its schema.
  #     This catches the case where a brand-new exec tool is ADDED alongside bash.
  if [[ ! -f "$PI_DIST_INDEX" ]]; then
    check "guard-parity [5c] allToolNames index.js exists" "fail" \
      "missing: $PI_DIST_INDEX"
  else
    # Extract allToolNames content and check for unexpected tool names.
    # allToolNames = new Set(["read", "bash", "edit", "write", "grep", "find", "ls"])
    KNOWN_TOOLS="read bash edit write grep find ls"
    UNEXPECTED=""
    # Extract the Set literal from allToolNames assignment.
    # NOTE: grep only the line(s) containing 'allToolNames' and 'new Set'; if the Set
    # spans multiple lines we may capture only the opener — the parse-yield check below
    # catches that by failing closed (zero names → FAIL, no vacuous pass).
    TOOLNAMES_LINE=$(grep 'allToolNames' "$PI_DIST_INDEX" 2>/dev/null | grep 'new Set' | head -1)
    if [[ -z "$TOOLNAMES_LINE" ]]; then
      check "guard-parity [5c] allToolNames definition found in index.js" "fail" \
        "allToolNames Set definition not found in $PI_DIST_INDEX — re-verify dcg-gate exec-field coverage"
    else
      # Extract tool name strings from the Set literal into an array.
      PARSED_NAMES=()
      while IFS= read -r tool_name; do
        PARSED_NAMES+=("$tool_name")
      done < <(echo "$TOOLNAMES_LINE" | grep -oE '"[a-z_-]+"' | tr -d '"')

      # Positive sentinel (parsed-set check, NOT a whole-file grep):
      # The extracted set must be non-empty AND must contain "bash".
      # If parsing yields zero names the Set format changed (multi-line, etc.) — fail-closed
      # to force re-verify rather than passing vacuously.
      PARSED_HAS_BASH=false
      for pn in "${PARSED_NAMES[@]+"${PARSED_NAMES[@]}"}"; do
        if [[ "$pn" == "bash" ]]; then
          PARSED_HAS_BASH=true
          break
        fi
      done

      if [[ "${#PARSED_NAMES[@]}" -eq 0 ]]; then
        check "guard-parity [5c] allToolNames parse yielded tool names (sentinel)" "fail" \
          "allToolNames parse yielded no tools — pi dist format changed (multi-line Set?); re-verify dcg-gate exec-field coverage and update the parser"
      elif [[ "$PARSED_HAS_BASH" == "false" ]]; then
        check "guard-parity [5c] allToolNames parsed set contains 'bash' (sentinel)" "fail" \
          "allToolNames parse yielded no 'bash' — pi dist format changed; re-verify dcg-gate exec-field coverage and update the parser"
      else
        # Sentinel passed — now check for unexpected tool names.
        for pn in "${PARSED_NAMES[@]}"; do
          found_in_known=false
          for known in $KNOWN_TOOLS; do
            if [[ "$pn" == "$known" ]]; then
              found_in_known=true
              break
            fi
          done
          if [[ "$found_in_known" == "false" ]]; then
            UNEXPECTED="${UNEXPECTED}${pn} "
          fi
        done

        if [[ -n "$UNEXPECTED" ]]; then
          check "guard-parity [5c] no unexpected tools in allToolNames" "fail" \
            "unexpected tool(s): ${UNEXPECTED}— new exec-capable tool? re-verify dcg-gate extractCommand covers its command field"
        else
          check "guard-parity [5c] allToolNames contains only known tool set" "pass" \
            "tools: ${PARSED_NAMES[*]}"
        fi
      fi
    fi
  fi
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "=== Results: $TOTAL checks, $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]] || exit 1
