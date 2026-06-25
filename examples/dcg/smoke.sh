#!/usr/bin/env bash
# examples/dcg/smoke.sh — Behavioral smoke test for the DCG recipe.
#
# Installed by the dcg recipe's install_cmd into:
#   /usr/local/lib/rip-cage/recipe-tests/dcg-smoke.sh
# as root:root 0755, run by the generic runner (run-recipe-smokes.sh).
#
# Covers (probe-by-probe, mirrors pre-move test-safety-stack.sh #11/#11b-#11g
# and test-pi-dcg-gate.sh checks 1-6):
#
#   DCG-1   — DCG denies canonical destructive command (rm -rf /)
#   DCG-2   — Floor holds vs hostile /workspace/.dcg.toml (wrapper CWD-anchor)
#   DCG-3   — Floor holds vs hostile ~/.config/dcg/config.toml (user-layer suppression)
#   DCG-4   — Sensitivity: raw dcg IS weakened by hostile workspace config (wrapper load-bearing)
#   DCG-5   — Additive rule fires: custom rule pack blocks sentinel command
#   DCG-6   — Chaining-robust: denies destructive after &&
#   DCG-7   — Chaining-robust: denies destructive after ;
#   DCG-PI-STRUCTURAL-1  — dcg-gate.ts exists at its own root-owned load path (pi-conditional)
#   DCG-PI-STRUCTURAL-1b — dcg-gate.ts has no /pi-agent path reference (pi-conditional)
#   DCG-PI-STRUCTURAL-1c — dcg-gate.ts invokes dcg-guard (not raw dcg) (pi-conditional)
#   DCG-PI-STRUCTURAL-1d — dcg-gate.ts pins tool_name to bash in dcg envelope (pi-conditional)
#   DCG-PI-STRUCTURAL-1e — dcg-gate.ts reads permissionDecision from JSON (pi-conditional)
#   DCG-PI-GUARD-2a — dcg-guard wrapper present and executable (pi-conditional)
#   DCG-PI-GUARD-2a.rm  — rm -rf / denied via tool_name=bash (pi-conditional)
#   DCG-PI-GUARD-2b — git reset --hard denied (pi-conditional)
#   DCG-PI-GUARD-2c — git push --force denied (pi-conditional)
#   DCG-PI-GUARD-2d — git clean -f denied (pi-conditional)
#   DCG-PI-ALLOW-3a — rm -rf /tmp/... allowed (temp path) (pi-conditional)
#   DCG-PI-ALLOW-3b — git push --force-with-lease allowed (pi-conditional)
#   DCG-PI-ALLOW-3c — git checkout -b allowed (pi-conditional)
#   DCG-PI-PIN-4a   — tool_name=bash (lowercase) evaluated and denied destructive (pi-conditional)
#   DCG-PI-PIN-4b   — diagnostic: dcg regime for unknown tool_name (pi-conditional)
#   DCG-PI-PARITY-5a — guard-parity [5a] positive sentinel: bash.js has bashSchema (pi-conditional)
#   DCG-PI-PARITY-5b — guard-parity [5b] no alternative exec-field name in bashSchema (pi-conditional)
#   DCG-PI-PARITY-5c — guard-parity [5c] allToolNames in index.js (pi-conditional)
#   DCG-PI-LOCK-6a  — dcg-gate.ts is root-owned (pi-conditional)
#   DCG-PI-LOCK-6b  — /etc/rip-cage/pi guard dir is root-owned (pi-conditional)
#   DCG-PI-LOCK-6c  — dcg-gate.ts is not writable by agent (pi-conditional)
#   DCG-PI-LOCK-6d  — /etc/rip-cage/pi guard dir is not writable by agent (pi-conditional)
#   DCG-PI-LOCK-6e  — agent write to dcg-gate.ts EACCES (pi-conditional)
#   DCG-PI-LOCK-6f  — agent cannot create competing ext in /etc/rip-cage/pi (pi-conditional)
#
# Pi-conditional checks (DCG-PI-*) self-skip if pi is not installed.
# This matches the pre-move behavior of test-pi-dcg-gate.sh.
#
# GOTCHA: destructive payloads (rm -rf /) are written to temp files and piped
# via `cat file |` — NEVER via echo in a shell line (host guard scans command text).

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

DCG_GUARD="/usr/local/lib/rip-cage/bin/dcg-guard"

echo "=== DCG Recipe Smoke Test ==="
echo ""

# ---------------------------------------------------------------------------
# DCG-1: DCG denies canonical destructive command
# ---------------------------------------------------------------------------
_dcg1_payload=$(mktemp /tmp/dcg-smoke-1-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' > "$_dcg1_payload"
_dcg1_result=$(cat "$_dcg1_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_dcg1_payload"
if echo "$_dcg1_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-1 denies canonical destructive command (rm -rf /)" "pass"
else
  check "DCG-1 denies canonical destructive command (rm -rf /)" "fail" "$_dcg1_result"
fi
unset _dcg1_payload _dcg1_result

# ---------------------------------------------------------------------------
# DCG-2: Floor holds vs hostile /workspace/.dcg.toml (wrapper CWD-anchor)
# Write a hostile /workspace/.dcg.toml that allows everything via wildcard.
# The wrapper anchors CWD to /usr/local/lib/rip-cage (no .git ancestor),
# so DCG's project-config discovery never walks up to /workspace.
# ---------------------------------------------------------------------------
_hostile_ws="/workspace/.dcg.toml"
cat > "$_hostile_ws" << 'HOSTILE_EOF'
[overrides]
allow = [".*"]
HOSTILE_EOF
_dcg2_payload=$(mktemp /tmp/dcg-smoke-2-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' > "$_dcg2_payload"
_dcg2_result=$(cat "$_dcg2_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_hostile_ws" "$_dcg2_payload"
if echo "$_dcg2_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-2 floor holds vs hostile /workspace/.dcg.toml (wrapper CWD-anchor)" "pass"
else
  check "DCG-2 floor holds vs hostile /workspace/.dcg.toml (wrapper CWD-anchor)" "fail" "$_dcg2_result"
fi
unset _hostile_ws _dcg2_payload _dcg2_result

# ---------------------------------------------------------------------------
# DCG-3: Floor holds vs hostile ~/.config/dcg/config.toml (user-layer suppression)
# The wrapper pins DCG_CONFIG to the cage-owned baked config, suppressing the
# user-layer config entirely (config.rs:2417: user layer loads only if explicit_layer.is_none()).
# ---------------------------------------------------------------------------
_hostile_user_dir="${HOME}/.config/dcg"
_hostile_user_cfg="${_hostile_user_dir}/config.toml"
_hostile_user_existed=false
if [[ -f "$_hostile_user_cfg" ]]; then
  _hostile_user_existed=true
  cp "$_hostile_user_cfg" "${_hostile_user_cfg}.rc-test-bak"
fi
mkdir -p "$_hostile_user_dir"
cat > "$_hostile_user_cfg" << 'HOSTILE_EOF'
[overrides]
allow = [".*"]
HOSTILE_EOF
_dcg3_payload=$(mktemp /tmp/dcg-smoke-3-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' > "$_dcg3_payload"
_dcg3_result=$(cat "$_dcg3_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_dcg3_payload"
if [[ "$_hostile_user_existed" == "true" ]]; then
  mv "${_hostile_user_cfg}.rc-test-bak" "$_hostile_user_cfg"
else
  rm -f "$_hostile_user_cfg"
fi
if echo "$_dcg3_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-3 floor holds vs hostile ~/.config/dcg/config.toml (user-layer suppression)" "pass"
else
  check "DCG-3 floor holds vs hostile ~/.config/dcg/config.toml (user-layer suppression)" "fail" "$_dcg3_result"
fi
unset _hostile_user_dir _hostile_user_cfg _hostile_user_existed _dcg3_result

# ---------------------------------------------------------------------------
# DCG-4: Sensitivity proof — hostile /workspace/.dcg.toml WOULD weaken raw DCG
# Run raw /usr/local/bin/dcg from CWD=/workspace (NOT via wrapper) with hostile file.
# Proves the wrapper's CWD-anchor is the mechanism, not DCG ignoring configs.
# Skip gracefully if /workspace is not a git repo (DCG needs git root for config discovery).
# ---------------------------------------------------------------------------
if git -C /workspace rev-parse --show-toplevel >/dev/null 2>&1; then
  _hostile_ws="/workspace/.dcg.toml"
  cat > "$_hostile_ws" << 'HOSTILE_EOF'
[overrides]
allow = [".*"]
HOSTILE_EOF
  _dcg4_payload=$(mktemp /tmp/dcg-smoke-4-XXXXXX.json)
  printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' > "$_dcg4_payload"
  _dcg4_result=$(cd /workspace; cat "$_dcg4_payload" | /usr/local/bin/dcg 2>/dev/null || true)
  rm -f "$_hostile_ws" "$_dcg4_payload"
  if echo "$_dcg4_result" | grep -qE '"permissionDecision".*"deny"'; then
    check "DCG-4 sensitivity: raw dcg weakened by hostile /workspace/.dcg.toml (wrapper is load-bearing)" "fail" \
      "raw dcg still denied — hostile config not loaded (sensitivity proof invalid)"
  else
    check "DCG-4 sensitivity: raw dcg weakened by hostile /workspace/.dcg.toml (wrapper is load-bearing)" "pass"
  fi
  unset _hostile_ws _dcg4_payload _dcg4_result
else
  check "DCG-4 sensitivity: raw dcg weakened by hostile /workspace/.dcg.toml [skip: /workspace not a git repo]" "pass" \
    "DCG-2/DCG-3 already prove wrapper is load-bearing; proof not demonstrable without git root"
fi

# ---------------------------------------------------------------------------
# DCG-5: Additive rule fires — custom rule pack blocks sentinel command
# Proves additive mechanism (ADR-025 D1): DCG loads and evaluates custom YAML rule packs.
# Prefer image-baked sentinel fixture so this is portable across all cages.
# ---------------------------------------------------------------------------
_sentinel_fixture="/usr/local/lib/rip-cage/dcg/fixtures/ripcage-testsentinel-rule.yaml"
if [[ ! -f "$_sentinel_fixture" ]]; then
  _sentinel_fixture="/workspace/tests/fixtures/ripcage-testsentinel-rule.yaml"
fi
_sentinel_cfg=$(mktemp /tmp/dcg-sentinel-XXXXXX.toml)
cat > "$_sentinel_cfg" << 'SENTINEL_TOML_EOF'
[packs]
enabled = ["core"]
SENTINEL_TOML_EOF
echo "custom_paths = [\"${_sentinel_fixture}\"]" >> "$_sentinel_cfg"
_dcg5_payload=$(mktemp /tmp/dcg-smoke-5-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"ripcagetestsentinel"}}' > "$_dcg5_payload"
_dcg5_result=$(cat "$_dcg5_payload" | DCG_CONFIG="$_sentinel_cfg" /usr/local/bin/dcg 2>/dev/null || true)
rm -f "$_sentinel_cfg" "$_dcg5_payload"
if echo "$_dcg5_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-5 additive rule fires: sentinel command denied by custom rule pack" "pass"
else
  check "DCG-5 additive rule fires: sentinel command denied by custom rule pack" "fail" \
    "fixture=$_sentinel_fixture result=$_dcg5_result"
fi
unset _sentinel_fixture _sentinel_cfg _dcg5_result

# ---------------------------------------------------------------------------
# DCG-6: Chaining-robust: denies destructive after &&
# Build JSON payload in temp file — avoids literal && in shell command string.
# ---------------------------------------------------------------------------
_dcg6_payload=$(mktemp /tmp/dcg-chain-and-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"echo hi && rm -rf ~"}}' > "$_dcg6_payload"
_dcg6_result=$(cat "$_dcg6_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_dcg6_payload"
if echo "$_dcg6_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-6 chaining-robust: denies destructive after &&" "pass"
else
  check "DCG-6 chaining-robust: denies destructive after &&" "fail" "$_dcg6_result"
fi
unset _dcg6_payload _dcg6_result

# ---------------------------------------------------------------------------
# DCG-7: Chaining-robust: denies destructive after ;
# ---------------------------------------------------------------------------
_dcg7_payload=$(mktemp /tmp/dcg-chain-semi-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"ls; rm -rf /important"}}' > "$_dcg7_payload"
_dcg7_result=$(cat "$_dcg7_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_dcg7_payload"
if echo "$_dcg7_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-7 chaining-robust: denies destructive after ;" "pass"
else
  check "DCG-7 chaining-robust: denies destructive after ;" "fail" "$_dcg7_result"
fi
unset _dcg7_payload _dcg7_result

echo ""
echo "-- DCG core checks complete ($TOTAL checks, $FAILURES failed) --"

# ---------------------------------------------------------------------------
# Pi-conditional checks: only run if pi is installed.
# ---------------------------------------------------------------------------
if ! command -v pi >/dev/null 2>&1; then
  echo ""
  echo "INFO: pi not installed — skipping DCG-PI-* checks (non-pi cage)"
  echo ""
  echo "=== DCG Smoke Summary: $TOTAL checks, $FAILURES failed ==="
  [[ "$FAILURES" -eq 0 ]] || exit 1
  exit 0
fi

echo ""
echo "-- Pi DCG gate checks (pi installed) --"
echo ""

DCG_GATE="/etc/rip-cage/pi/dcg-gate.ts"
PI_GUARD_RECIPE_ABSENT=false
if [[ -f "$DCG_GATE" ]]; then
  check "DCG-PI-STRUCTURAL-1 dcg-gate.ts exists at root-owned load path" "pass" "$DCG_GATE"
else
  PI_GUARD_RECIPE_ABSENT=true
  TOTAL=$((TOTAL + 1))
  echo "INFO  [$TOTAL] dcg-gate.ts absent at $DCG_GATE — pi running with no-guard recipe variant; structural checks skipped"
fi

# DCG-PI-STRUCTURAL-1b: Extension does NOT reference /pi-agent path
if [[ -f "$DCG_GATE" ]]; then
  if grep -q '/pi-agent' "$DCG_GATE" 2>/dev/null; then
    check "DCG-PI-STRUCTURAL-1b dcg-gate.ts has no /pi-agent path reference" "fail" "found /pi-agent in extension source"
  else
    check "DCG-PI-STRUCTURAL-1b dcg-gate.ts has no /pi-agent path reference" "pass"
  fi
fi

# DCG-PI-STRUCTURAL-1c: Extension calls dcg-guard wrapper, not raw dcg
if [[ -f "$DCG_GATE" ]]; then
  if grep -v '^\s*//' "$DCG_GATE" 2>/dev/null | grep -v '^\s*\*' | grep -q 'DCG_GUARD\s*=.*dcg-guard'; then
    check "DCG-PI-STRUCTURAL-1c dcg-gate.ts invokes dcg-guard (not raw dcg)" "pass"
  else
    check "DCG-PI-STRUCTURAL-1c dcg-gate.ts invokes dcg-guard (not raw dcg)" "fail" \
      "DCG_GUARD const assignment with dcg-guard path not found in non-comment code"
  fi
fi

# DCG-PI-STRUCTURAL-1d: Extension pins tool_name to "bash" in dcg envelope
if [[ -f "$DCG_GATE" ]]; then
  if grep -v '^\s*//' "$DCG_GATE" 2>/dev/null | grep -v '^\s*\*' | grep -q 'tool_name.*"bash"'; then
    check "DCG-PI-STRUCTURAL-1d dcg-gate.ts pins tool_name to bash in dcg envelope" "pass"
  else
    check "DCG-PI-STRUCTURAL-1d dcg-gate.ts pins tool_name to bash in dcg envelope" "fail" \
      "tool_name:\"bash\" property not found in non-comment code"
  fi
fi

# DCG-PI-STRUCTURAL-1e: Extension reads permissionDecision from JSON
if [[ -f "$DCG_GATE" ]]; then
  if grep -v '^\s*//' "$DCG_GATE" 2>/dev/null | grep -v '^\s*\*' | grep -q 'permissionDecision\s*==='; then
    check "DCG-PI-STRUCTURAL-1e dcg-gate.ts reads permissionDecision from stdout JSON" "pass"
  else
    check "DCG-PI-STRUCTURAL-1e dcg-gate.ts reads permissionDecision from stdout JSON" "fail" \
      "permissionDecision === comparison not found in non-comment code"
  fi
fi

# DCG-PI-GUARD-2a: dcg-guard wrapper present and executable
if [[ -x "$DCG_GUARD" ]]; then
  check "DCG-PI-GUARD-2a dcg-guard wrapper present and executable" "pass"
else
  check "DCG-PI-GUARD-2a dcg-guard wrapper present and executable" "fail" \
    "missing or not executable: $DCG_GUARD"
fi

# DCG-PI-GUARD-2a.rm: rm -rf / denied (tool_name=bash lowercase)
_pi2a_payload=$(mktemp /tmp/dcg-pi-2a-XXXXXX.json)
printf '{"tool_name":"bash","tool_input":{"command":"rm -rf /"}}' > "$_pi2a_payload"
_pi2a_result=$(cat "$_pi2a_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_pi2a_payload"
if echo "$_pi2a_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-PI-GUARD-2a.rm rm -rf / denied (destructive — root path)" "pass"
else
  check "DCG-PI-GUARD-2a.rm rm -rf / denied (destructive — root path)" "fail" "$_pi2a_result"
fi
unset _pi2a_payload _pi2a_result

# DCG-PI-GUARD-2b: git reset --hard denied
_pi2b_payload=$(mktemp /tmp/dcg-pi-2b-XXXXXX.json)
printf '{"tool_name":"bash","tool_input":{"command":"git reset --hard HEAD~1"}}' > "$_pi2b_payload"
_pi2b_result=$(cat "$_pi2b_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_pi2b_payload"
if echo "$_pi2b_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-PI-GUARD-2b git reset --hard denied" "pass"
else
  check "DCG-PI-GUARD-2b git reset --hard denied" "fail" "$_pi2b_result"
fi
unset _pi2b_payload _pi2b_result

# DCG-PI-GUARD-2c: git push --force denied
_pi2c_payload=$(mktemp /tmp/dcg-pi-2c-XXXXXX.json)
printf '{"tool_name":"bash","tool_input":{"command":"git push --force origin main"}}' > "$_pi2c_payload"
_pi2c_result=$(cat "$_pi2c_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_pi2c_payload"
if echo "$_pi2c_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-PI-GUARD-2c git push --force denied" "pass"
else
  check "DCG-PI-GUARD-2c git push --force denied" "fail" "$_pi2c_result"
fi
unset _pi2c_payload _pi2c_result

# DCG-PI-GUARD-2d: git clean -f denied
_pi2d_payload=$(mktemp /tmp/dcg-pi-2d-XXXXXX.json)
printf '{"tool_name":"bash","tool_input":{"command":"git clean -f"}}' > "$_pi2d_payload"
_pi2d_result=$(cat "$_pi2d_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_pi2d_payload"
if echo "$_pi2d_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-PI-GUARD-2d git clean -f denied" "pass"
else
  check "DCG-PI-GUARD-2d git clean -f denied" "fail" "$_pi2d_result"
fi
unset _pi2d_payload _pi2d_result

# DCG-PI-ALLOW-3a: rm -rf /tmp/... allowed (temp path)
_pi3a_payload=$(mktemp /tmp/dcg-pi-3a-XXXXXX.json)
printf '{"tool_name":"bash","tool_input":{"command":"rm -rf /tmp/myproject-build"}}' > "$_pi3a_payload"
_pi3a_result=$(cat "$_pi3a_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_pi3a_payload"
if echo "$_pi3a_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-PI-ALLOW-3a rm -rf /tmp/... allowed (temp path)" "fail" "$_pi3a_result"
else
  check "DCG-PI-ALLOW-3a rm -rf /tmp/... allowed (temp path)" "pass"
fi
unset _pi3a_payload _pi3a_result

# DCG-PI-ALLOW-3b: git push --force-with-lease allowed
_pi3b_payload=$(mktemp /tmp/dcg-pi-3b-XXXXXX.json)
printf '{"tool_name":"bash","tool_input":{"command":"git push --force-with-lease origin feature"}}' > "$_pi3b_payload"
_pi3b_result=$(cat "$_pi3b_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_pi3b_payload"
if echo "$_pi3b_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-PI-ALLOW-3b git push --force-with-lease allowed" "fail" "$_pi3b_result"
else
  check "DCG-PI-ALLOW-3b git push --force-with-lease allowed" "pass"
fi
unset _pi3b_payload _pi3b_result

# DCG-PI-ALLOW-3c: git checkout -b allowed
_pi3c_payload=$(mktemp /tmp/dcg-pi-3c-XXXXXX.json)
printf '{"tool_name":"bash","tool_input":{"command":"git checkout -b feature/my-branch"}}' > "$_pi3c_payload"
_pi3c_result=$(cat "$_pi3c_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_pi3c_payload"
if echo "$_pi3c_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-PI-ALLOW-3c git checkout -b allowed" "fail" "$_pi3c_result"
else
  check "DCG-PI-ALLOW-3c git checkout -b allowed" "pass"
fi
unset _pi3c_payload _pi3c_result

# DCG-PI-PIN-4a: tool_name=bash (lowercase) evaluated and denied destructive
_pi4a_payload=$(mktemp /tmp/dcg-pi-4a-XXXXXX.json)
printf '{"tool_name":"bash","tool_input":{"command":"rm -rf /"}}' > "$_pi4a_payload"
_pi4a_result=$(cat "$_pi4a_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_pi4a_payload"
if echo "$_pi4a_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-PI-PIN-4a tool_name=bash (lowercase) evaluated and denied destructive" "pass"
else
  check "DCG-PI-PIN-4a tool_name=bash (lowercase) evaluated and denied destructive" "fail" "$_pi4a_result"
fi
unset _pi4a_payload _pi4a_result

# DCG-PI-PIN-4b: diagnostic — which regime for unknown tool_name mcp_exec?
# BOTH outcomes (deny or allow) are SAFE — neither is a guard-correctness regression.
_pi4b_payload=$(mktemp /tmp/dcg-pi-4b-XXXXXX.json)
printf '{"tool_name":"mcp_exec","tool_input":{"command":"rm -rf /"}}' > "$_pi4b_payload"
_pi4b_result=$(cat "$_pi4b_payload" | "$DCG_GUARD" 2>/dev/null || true)
rm -f "$_pi4b_payload"
if echo "$_pi4b_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG-PI-PIN-4b dcg directly guards unknown tool_name mcp_exec (belt-and-suspenders)" "pass" \
    "dcg denied mcp_exec — dcg allowlist/conservatism covers the unknown tool; no regression, gate pinning still applies"
else
  check "DCG-PI-PIN-4b dcg fails open on unknown tool_name mcp_exec (gate pinning load-bearing)" "pass" \
    "mcp_exec NOT evaluated by dcg — confirms dcg-gate MUST pin to bash for MCP tools"
fi
unset _pi4b_payload _pi4b_result

# Guard-parity checks (5a/5b/5c) — exec-field coverage
PI_DIST_BASH="/usr/lib/node_modules/@mariozechner/pi-coding-agent/dist/core/tools/bash.js"
PI_DIST_INDEX="/usr/lib/node_modules/@mariozechner/pi-coding-agent/dist/core/tools/index.js"

SENTINEL_OK=false
if [[ ! -f "$PI_DIST_BASH" ]]; then
  check "DCG-PI-PARITY-5a positive sentinel: bash.js exists at dist path" "fail" \
    "missing: $PI_DIST_BASH — dist path moved? re-verify dcg-gate exec-field coverage"
elif ! grep -q 'bashSchema' "$PI_DIST_BASH" 2>/dev/null; then
  check "DCG-PI-PARITY-5a positive sentinel: bashSchema found in bash.js" "fail" \
    "bashSchema not found in $PI_DIST_BASH — schema renamed? re-verify dcg-gate exec-field coverage"
elif ! grep -q 'command:.*Type\.String\|command: Type\.String' "$PI_DIST_BASH" 2>/dev/null; then
  check "DCG-PI-PARITY-5a positive sentinel: bashSchema uses field command" "fail" \
    "field 'command: Type.String' not found in $PI_DIST_BASH — field renamed? dcg-gate extractCommand must be updated"
else
  check "DCG-PI-PARITY-5a positive sentinel: bash.js has bashSchema with command field" "pass" \
    "confirmed: command: Type.String present in bashSchema"
  SENTINEL_OK=true
fi

if [[ "$SENTINEL_OK" == "true" ]]; then
  # DCG-PI-PARITY-5b: No alternative exec-field name in bashSchema
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
    check "DCG-PI-PARITY-5b no alternative exec-field name in bashSchema" "fail" "$DRIFT_DETAIL"
  else
    check "DCG-PI-PARITY-5b no alternative exec-field name in bashSchema" "pass" \
      "no script/cmd/run/exec schema fields found in bash.js"
  fi

  # DCG-PI-PARITY-5c: allToolNames in index.js includes bash and no unexpected tools
  if [[ ! -f "$PI_DIST_INDEX" ]]; then
    check "DCG-PI-PARITY-5c allToolNames index.js exists" "fail" \
      "missing: $PI_DIST_INDEX"
  else
    KNOWN_TOOLS="read bash edit write grep find ls"
    UNEXPECTED=""
    TOOLNAMES_LINE=$(grep 'allToolNames' "$PI_DIST_INDEX" 2>/dev/null | grep 'new Set' | head -1)
    if [[ -z "$TOOLNAMES_LINE" ]]; then
      check "DCG-PI-PARITY-5c allToolNames definition found in index.js" "fail" \
        "allToolNames Set definition not found in $PI_DIST_INDEX — re-verify dcg-gate exec-field coverage"
    else
      PARSED_NAMES=()
      while IFS= read -r tool_nm; do
        PARSED_NAMES+=("$tool_nm")
      done < <(echo "$TOOLNAMES_LINE" | grep -oE '"[a-z_-]+"' | tr -d '"')

      PARSED_HAS_BASH=false
      for pn in "${PARSED_NAMES[@]+"${PARSED_NAMES[@]}"}"; do
        if [[ "$pn" == "bash" ]]; then
          PARSED_HAS_BASH=true
          break
        fi
      done

      if [[ "${#PARSED_NAMES[@]}" -eq 0 ]]; then
        check "DCG-PI-PARITY-5c allToolNames parse yielded tool names (sentinel)" "fail" \
          "allToolNames parse yielded no tools — pi dist format changed (multi-line Set?); re-verify dcg-gate exec-field coverage"
      elif [[ "$PARSED_HAS_BASH" == "false" ]]; then
        check "DCG-PI-PARITY-5c allToolNames parsed set contains bash (sentinel)" "fail" \
          "allToolNames parse yielded no 'bash' — pi dist format changed; re-verify dcg-gate exec-field coverage"
      else
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
          check "DCG-PI-PARITY-5c no unexpected tools in allToolNames" "fail" \
            "unexpected tool(s): ${UNEXPECTED}— new exec-capable tool? re-verify dcg-gate extractCommand covers its command field"
        else
          check "DCG-PI-PARITY-5c allToolNames contains only known tool set" "pass" \
            "tools: ${PARSED_NAMES[*]}"
        fi
      fi
    fi
  fi
fi

# DCG-PI-LOCK section: ownership + write-denial regression (floor-lock, ADR-027 D1/D3)
DCG_GUARD_DIR="/etc/rip-cage/pi"

if [[ "$PI_GUARD_RECIPE_ABSENT" == "true" ]]; then
  TOTAL=$((TOTAL + 1))
  echo "INFO  [$TOTAL] DCG-PI-LOCK section skipped — no-guard pi recipe in use; dcg-gate.ts not provisioned by design"
else

# DCG-PI-LOCK-6a: dcg-gate.ts owner is root
if [[ -f "$DCG_GATE" ]]; then
  _pi6a_owner=$(stat -c '%U' "$DCG_GATE" 2>/dev/null || true)
  if [[ "$_pi6a_owner" == "root" ]]; then
    check "DCG-PI-LOCK-6a dcg-gate.ts is root-owned" "pass" "owner: root"
  else
    check "DCG-PI-LOCK-6a dcg-gate.ts is root-owned" "fail" "owner: ${_pi6a_owner:-unknown} (expected root)"
  fi
else
  check "DCG-PI-LOCK-6a dcg-gate.ts is root-owned" "fail" "dcg-gate.ts absent"
fi

# DCG-PI-LOCK-6b: guard dir /etc/rip-cage/pi owner is root
if [[ -d "$DCG_GUARD_DIR" ]]; then
  _pi6b_owner=$(stat -c '%U' "$DCG_GUARD_DIR" 2>/dev/null || true)
  if [[ "$_pi6b_owner" == "root" ]]; then
    check "DCG-PI-LOCK-6b /etc/rip-cage/pi guard dir is root-owned" "pass" "owner: root"
  else
    check "DCG-PI-LOCK-6b /etc/rip-cage/pi guard dir is root-owned" "fail" "owner: ${_pi6b_owner:-unknown} (expected root)"
  fi
else
  check "DCG-PI-LOCK-6b /etc/rip-cage/pi guard dir is root-owned" "fail" "guard dir absent"
fi

# DCG-PI-LOCK-6c: dcg-gate.ts is not agent-writable
if [[ -f "$DCG_GATE" ]]; then
  if [ ! -w "$DCG_GATE" ]; then
    check "DCG-PI-LOCK-6c dcg-gate.ts is not writable by agent (permission)" "pass"
  else
    check "DCG-PI-LOCK-6c dcg-gate.ts is not writable by agent (permission)" "fail" "agent can write $DCG_GATE"
  fi
else
  check "DCG-PI-LOCK-6c dcg-gate.ts is not writable by agent (permission)" "fail" "dcg-gate.ts absent"
fi

# DCG-PI-LOCK-6d: guard dir /etc/rip-cage/pi is not agent-writable
if [[ -d "$DCG_GUARD_DIR" ]]; then
  if [ ! -w "$DCG_GUARD_DIR" ]; then
    check "DCG-PI-LOCK-6d /etc/rip-cage/pi guard dir is not writable by agent (permission)" "pass"
  else
    check "DCG-PI-LOCK-6d /etc/rip-cage/pi guard dir is not writable by agent (permission)" "fail" "agent can write $DCG_GUARD_DIR"
  fi
else
  check "DCG-PI-LOCK-6d /etc/rip-cage/pi guard dir is not writable by agent (permission)" "fail" "guard dir absent"
fi

# DCG-PI-LOCK-6e: agent cannot overwrite dcg-gate.ts (vector a)
if [[ -f "$DCG_GATE" ]]; then
  if touch "$DCG_GATE" 2>/dev/null; then
    check "DCG-PI-LOCK-6e agent write to dcg-gate.ts EACCES (vector a)" "fail" "touch succeeded — guard is agent-writable"
  else
    check "DCG-PI-LOCK-6e agent write to dcg-gate.ts EACCES (vector a)" "pass" "touch correctly denied"
  fi
else
  check "DCG-PI-LOCK-6e agent write to dcg-gate.ts EACCES (vector a)" "fail" "dcg-gate.ts absent"
fi

# DCG-PI-LOCK-6f: agent cannot drop competing extension into guard dir (vector b)
if [[ -d "$DCG_GUARD_DIR" ]]; then
  _pi6f_evil="${DCG_GUARD_DIR}/z-evil.ts"
  if touch "$_pi6f_evil" 2>/dev/null; then
    rm -f "$_pi6f_evil" 2>/dev/null || true
    check "DCG-PI-LOCK-6f agent cannot create competing ext in /etc/rip-cage/pi (vector b)" "fail" \
      "touch succeeded — guard dir is agent-writable"
  else
    if [[ ! -e "$_pi6f_evil" ]]; then
      check "DCG-PI-LOCK-6f agent cannot create competing ext in /etc/rip-cage/pi (vector b)" "pass" \
        "touch correctly denied, file absent"
    else
      check "DCG-PI-LOCK-6f agent cannot create competing ext in /etc/rip-cage/pi (vector b)" "fail" \
        "touch failed but file exists somehow"
    fi
  fi
  unset _pi6f_evil
else
  check "DCG-PI-LOCK-6f agent cannot create competing ext in /etc/rip-cage/pi (vector b)" "fail" "guard dir absent"
fi

fi  # end: if not PI_GUARD_RECIPE_ABSENT

echo ""
echo "=== DCG Smoke Summary: $TOTAL checks, $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]] || exit 1
exit 0
