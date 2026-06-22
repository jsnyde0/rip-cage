#!/usr/bin/env bash
# test-cc-managed-settings-probe.sh — CC managed-settings anchor probe (rip-cage-wlwc.1 / D8)
#
# ANCHOR PROBE: answers the D8 question against the SHIPPED claude binary:
#   Does /etc/claude-code/managed-settings.json enforce PreToolUse hooks
#   un-suppressibly + deny-wins on the shipped CC binary?
#
# What this test does:
#   1. EARLY AUTH CHECK: detect missing/invalid auth fast; fail loudly without hanging.
#   2. POSITIVE CONTROL: benign claude -p (no tools) must return PROBE_ALLOWED,
#      proving the agent actually ran. A test that only checks "denied" can pass
#      vacuously if the agent never ran.
#      (anti-pattern: auth-precondition-presence-not-validity-silent-timeout)
#   3. MANAGED ENFORCEMENT: bake a sentinel deny hook into
#      /etc/claude-code/managed-settings.json; strip hooks from EVERY agent-writable
#      settings layer; ask claude to run a bash command; confirm the hook WAS called
#      and the bash command was NOT executed.
#   4. DENY-WINS: add an agent-level ALLOW hook to the probe session settings.json;
#      re-run; confirm the managed deny still wins (agent allow cannot un-block it).
#   5. VERDICT: emit GREEN or RED. Exit $FAILURES.
#
# Non-negotiable guardrails wired in (repo scars):
#   - Positive control gates all subsequent assertions.
#   - Loud-fail on missing auth with exact missing artifact named.
#   - exit $FAILURES — never "FAIL prose + exit 0"
#     (rip-cage-test-fail-prose-without-exit-silent-red).
#   - Own-shell, cold build: do not carry forward from a prior/destroyed container.
#   - Portable timeout (macOS-compatible: background job + kill after N seconds).
#
# Usage:
#   RC_TEST_CONTAINER=<name> ./tests/test-cc-managed-settings-probe.sh
#   # auto-detects a running rip-cage:latest container if RC_TEST_CONTAINER is unset
#
# Wired into run-host.sh as NEEDS_CONTAINER (auth-gated).

set -uo pipefail

FAILURES=0
TOTAL=0

# Unique suffix to avoid collisions between concurrent probe runs
PROBE_SUFFIX=$$
PROBE_SESSION_DIR="/tmp/probe-cc-managed-settings-${PROBE_SUFFIX}"
SENTINEL_HOOK="/tmp/probe-sentinel-deny-${PROBE_SUFFIX}.sh"
AGENT_ALLOW_HOOK="/tmp/probe-agent-allow-${PROBE_SUFFIX}.sh"
HOOK_CALLED_WITNESS="/tmp/probe-hook-called-${PROBE_SUFFIX}.txt"
BASH_EXECUTED_FILE="/tmp/probe-bash-ran-${PROBE_SUFFIX}.txt"
WS_CLAUDE_SETTINGS_BACKUP="/tmp/probe-ws-claude-settings-backup-${PROBE_SUFFIX}.json"
WS_SETTINGS_LOCAL_BACKUP="/tmp/probe-settings-local-backup-${PROBE_SUFFIX}.json"

pass() {
  TOTAL=$((TOTAL + 1))
  echo "PASS  [$TOTAL] $1"
}

fail() {
  TOTAL=$((TOTAL + 1))
  echo "FAIL  [$TOTAL] $1${2:+  — $2}"
  FAILURES=$((FAILURES + 1))
}

info() {
  echo "INFO: $1"
}

# Portable timeout: run a command in background; kill it if it exceeds N seconds.
# Usage: run_with_timeout <seconds> <outfile> <command...>
# Sets global RWT_EXIT to the exit code (124 = timeout).
RWT_EXIT=0
run_with_timeout() {
  local timeout_secs="$1" outfile="$2"
  shift 2
  RWT_EXIT=0

  # Run command in background, capturing output to file
  "$@" >"$outfile" 2>&1 &
  local cmd_pid=$!

  # Start a watchdog in the background that kills the command after timeout_secs
  ( sleep "$timeout_secs" && kill "$cmd_pid" 2>/dev/null ) &
  local watchdog_pid=$!

  # Wait for the command to finish
  wait "$cmd_pid" 2>/dev/null && RWT_EXIT=$? || RWT_EXIT=$?

  # Kill the watchdog (it may have already fired)
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  # If command was killed (exit code 143 = SIGTERM, or 130 = SIGINT from kill),
  # or if the kill happened cleanly (128+signal), report as timeout (exit 124).
  if ! kill -0 "$cmd_pid" 2>/dev/null && [[ $RWT_EXIT -gt 128 ]]; then
    RWT_EXIT=124
  fi
}

# Cleanup: remove probe artifacts from the container
_cleanup_probe() {
  # Best-effort: ignore errors during cleanup
  cexec rm -rf "$PROBE_SESSION_DIR" 2>/dev/null || true
  cexec rm -f "$HOOK_CALLED_WITNESS" "$BASH_EXECUTED_FILE" 2>/dev/null || true
  cexec rm -f "$SENTINEL_HOOK" "$AGENT_ALLOW_HOOK" 2>/dev/null || true

  # Restore /workspace/.claude/settings.json if we backed it up
  if cexec test -f "$WS_CLAUDE_SETTINGS_BACKUP" 2>/dev/null; then
    cexec cp "$WS_CLAUDE_SETTINGS_BACKUP" /workspace/.claude/settings.json 2>/dev/null || true
    cexec rm -f "$WS_CLAUDE_SETTINGS_BACKUP" 2>/dev/null || true
    info "Restored /workspace/.claude/settings.json"
  fi

  # Restore settings.local.json if we backed it up
  if cexec test -f "$WS_SETTINGS_LOCAL_BACKUP" 2>/dev/null; then
    cexec cp "$WS_SETTINGS_LOCAL_BACKUP" /workspace/settings.local.json 2>/dev/null || true
    cexec rm -f "$WS_SETTINGS_LOCAL_BACKUP" 2>/dev/null || true
    info "Restored /workspace/settings.local.json"
  fi

  # Remove managed-settings.json created by the probe
  cexec_root rm -f /etc/claude-code/managed-settings.json 2>/dev/null || true
  info "Probe cleanup complete"
}

echo "=== CC Managed-Settings Anchor Probe (rip-cage-wlwc.1 / D8) ==="
echo ""

# ---------------------------------------------------------------------------
# Guard: skip if docker unavailable
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: skip if no rip-cage image built
# ---------------------------------------------------------------------------
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest not built — run ./rc build first"
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve test container: prefer explicit RC_TEST_CONTAINER; else find running
# ---------------------------------------------------------------------------
CONTAINER="${RC_TEST_CONTAINER:-}"
if [[ -z "$CONTAINER" ]]; then
  CONTAINER=$(docker ps --format '{{.Names}}' --filter 'ancestor=rip-cage:latest' | head -1)
fi
if [[ -z "$CONTAINER" ]]; then
  echo "SKIP: no running rip-cage container found; pass RC_TEST_CONTAINER=<name> or start one with rc up"
  exit 0
fi
echo "Container: $CONTAINER"
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a command inside the container as agent user
cexec() { docker exec "$CONTAINER" "$@"; }

# Run a command inside the container as root
cexec_root() { docker exec --user root "$CONTAINER" "$@"; }

# ---------------------------------------------------------------------------
# EARLY AUTH CHECK
# Detect missing/invalid auth fast; fail loudly with exact missing artifact.
# Per guardrail: do NOT hang the full timeout on bad auth.
# (auth-precondition-presence-not-validity-silent-timeout)
# ---------------------------------------------------------------------------
echo "-- Auth pre-flight --"

# Check file presence first (fast, no network)
# SC2016 disabled: single quotes intentional — vars expand inside the container, not on the host.
# shellcheck disable=SC2016
CRED_FILE_PRESENT=$(cexec bash -c '
  if [[ -s /home/agent/.claude/.credentials.json ]]; then
    echo "present"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "apikey"
  else
    echo "absent"
  fi
')

if [[ "$CRED_FILE_PRESENT" == "absent" ]]; then
  echo ""
  echo "FATAL: Auth credentials absent in container $CONTAINER"
  echo "  Missing artifact: ~/.claude/.credentials.json (non-empty) OR ANTHROPIC_API_KEY"
  echo "  This probe requires a live authenticated cage. Start one with: rc up <workspace>"
  exit 1
fi
info "Auth file present ($CRED_FILE_PRESENT) — proceeding to validity check"

# Validity check: quick claude -p with a short timeout.
# Auth-file PRESENCE is NOT validity — an expired token will hang without this check.
AUTH_CHECK_DIR="/tmp/probe-auth-check-${PROBE_SUFFIX}"
cexec mkdir -p "$AUTH_CHECK_DIR"
cexec bash -c "printf '{\"permissions\":{\"defaultMode\":\"bypassPermissions\"}}' > ${AUTH_CHECK_DIR}/settings.json"

AUTH_OUT=$(mktemp)
run_with_timeout 45 "$AUTH_OUT" \
  docker exec \
    -e CLAUDE_CONFIG_DIR="$AUTH_CHECK_DIR" \
    "$CONTAINER" \
    /usr/local/bin/claude -p "print only the word AUTH_OK, nothing else, no tools"

AUTH_EXIT=$RWT_EXIT
AUTH_OUTPUT_CONTENT=$(cat "$AUTH_OUT")
rm -f "$AUTH_OUT"
cexec rm -rf "$AUTH_CHECK_DIR" 2>/dev/null || true

if [[ $AUTH_EXIT -eq 124 ]]; then
  echo ""
  echo "FATAL: Auth validity check TIMED OUT (45s) for container $CONTAINER"
  echo "  Missing artifact: valid/non-expired Claude API auth"
  echo "  The credentials file exists but may be expired or the API is unreachable."
  echo "  Run: rc auth <workspace> to refresh"
  exit 1
elif [[ $AUTH_EXIT -ne 0 ]]; then
  echo ""
  echo "FATAL: Auth validity check FAILED (exit $AUTH_EXIT) for container $CONTAINER"
  echo "  Output: $(echo "$AUTH_OUTPUT_CONTENT" | head -5)"
  echo "  Missing artifact: working Claude API credentials"
  echo "  Run: rc auth <workspace> to refresh"
  exit 1
elif ! echo "$AUTH_OUTPUT_CONTENT" | grep -q "AUTH_OK"; then
  echo ""
  echo "FATAL: Auth validity check returned unexpected output for container $CONTAINER"
  echo "  Expected 'AUTH_OK' in output; got: $AUTH_OUTPUT_CONTENT"
  echo "  Missing artifact: confirmed working Claude API auth"
  exit 1
fi

info "Auth validity confirmed — claude responded with AUTH_OK"
echo ""

# ---------------------------------------------------------------------------
# SETUP: Sentinel hook + probe session dir
# ---------------------------------------------------------------------------

echo "-- Probe setup --"

# Create probe session dir
cexec mkdir -p "$PROBE_SESSION_DIR"

# Sentinel deny hook: denies ALL Bash PreToolUse calls + writes witness file.
# Created as root so it lives at a predictable root-owned path.
# The hook needs to be executable by the agent user (world-readable /tmp path).
cexec_root bash -c "cat > ${SENTINEL_HOOK} << 'SENTINEL_EOF'
#!/usr/bin/env bash
# Sentinel deny hook — D8 CC managed-settings anchor probe.
# Called by CC PreToolUse for Bash tool calls when managed-settings.json is loaded.
# Writes a witness file (proves the hook was called), then denies.
touch ${HOOK_CALLED_WITNESS}
printf '{\"permissionDecision\":\"deny\",\"reason\":\"D8 managed-settings sentinel deny (probe)\"}\n'
exit 2
SENTINEL_EOF"
cexec_root chmod 755 "$SENTINEL_HOOK"

if cexec test -x "$SENTINEL_HOOK"; then
  pass "Sentinel deny hook created and executable: $SENTINEL_HOOK"
else
  fail "Sentinel deny hook NOT executable" "path: $SENTINEL_HOOK"
fi

# ---------------------------------------------------------------------------
# MANAGED-SETTINGS SETUP
# Create /etc/claude-code/managed-settings.json with the sentinel deny hook.
# Requires root (docker exec --user root).
# The /etc/claude-code/ path is CC's documented managed-settings directory.
# ---------------------------------------------------------------------------

echo ""
echo "-- Creating /etc/claude-code/managed-settings.json (root) --"

cexec_root mkdir -p /etc/claude-code

# Write managed-settings.json with the sentinel hook
# Using a heredoc passed to bash avoids quoting issues with the hook path
cexec_root bash -c "cat > /etc/claude-code/managed-settings.json << MANAGED_EOF
{
  \"hooks\": {
    \"PreToolUse\": [
      {
        \"matcher\": \"Bash\",
        \"hooks\": [
          {
            \"type\": \"command\",
            \"command\": \"${SENTINEL_HOOK}\"
          }
        ]
      }
    ]
  }
}
MANAGED_EOF"
cexec_root chmod 644 /etc/claude-code/managed-settings.json

if cexec test -f /etc/claude-code/managed-settings.json; then
  pass "managed-settings.json created at /etc/claude-code/"
else
  fail "managed-settings.json was NOT created" "/etc/claude-code/managed-settings.json absent"
fi

if cexec jq . /etc/claude-code/managed-settings.json >/dev/null 2>&1; then
  pass "managed-settings.json is valid JSON"
  info "Content: $(cexec cat /etc/claude-code/managed-settings.json)"
else
  fail "managed-settings.json is NOT valid JSON" "$(cexec cat /etc/claude-code/managed-settings.json 2>/dev/null | head -5)"
fi

# ---------------------------------------------------------------------------
# PROBE SESSION: Strip hooks from ALL agent-writable layers
# The probe session dir has bypassPermissions but ZERO PreToolUse hooks.
# This eliminates dcg-guard and ssh-bypass hooks from the probe run —
# so any denial comes ONLY from the managed-settings sentinel.
# ---------------------------------------------------------------------------

echo ""
echo "-- Stripping agent-writable hook layers --"

# Probe session settings.json: no hooks (bypassPermissions for clean tool use)
cexec bash -c "printf '{\"permissions\":{\"defaultMode\":\"bypassPermissions\"},\"hooks\":{}}\n' > ${PROBE_SESSION_DIR}/settings.json"

# Back up and clear /workspace/.claude/settings.json (project-level hook layer)
if cexec test -f /workspace/.claude/settings.json 2>/dev/null; then
  cexec cp /workspace/.claude/settings.json "$WS_CLAUDE_SETTINGS_BACKUP"
  cexec bash -c 'printf "{}\n" > /workspace/.claude/settings.json'
  info "Cleared /workspace/.claude/settings.json (backed up)"
fi

# Back up and clear settings.local.json (workspace-local hook layer)
if cexec test -f /workspace/settings.local.json 2>/dev/null; then
  cexec cp /workspace/settings.local.json "$WS_SETTINGS_LOCAL_BACKUP"
  cexec bash -c 'printf "{}\n" > /workspace/settings.local.json'
  info "Cleared /workspace/settings.local.json (backed up)"
fi

pass "All agent-writable hook layers cleared for probe run"

# ---------------------------------------------------------------------------
# SECTION 1: POSITIVE CONTROL
# Benign claude -p that produces text WITHOUT any tool use.
# MUST pass to prove the agent ran and auth is valid.
# Without this, a "no denial" result could be vacuous (agent never ran).
# ---------------------------------------------------------------------------

echo ""
echo "-- Section 1: Positive control --"

POS_CTRL_OUT=$(mktemp)
run_with_timeout 60 "$POS_CTRL_OUT" \
  docker exec \
    -e CLAUDE_CONFIG_DIR="$PROBE_SESSION_DIR" \
    "$CONTAINER" \
    /usr/local/bin/claude -p "print only the word PROBE_ALLOWED, nothing else, do not use any tools"

POS_CTRL_EXIT=$RWT_EXIT
POS_CTRL_CONTENT=$(cat "$POS_CTRL_OUT")
rm -f "$POS_CTRL_OUT"

POSITIVE_CONTROL_OK=false

if [[ $POS_CTRL_EXIT -eq 124 ]]; then
  fail "Positive control TIMED OUT (60s)" "All subsequent assertions SKIPPED"
elif [[ $POS_CTRL_EXIT -ne 0 ]]; then
  fail "Positive control exited $POS_CTRL_EXIT" "$(echo "$POS_CTRL_CONTENT" | head -3)"
elif echo "$POS_CTRL_CONTENT" | grep -q "PROBE_ALLOWED"; then
  pass "Positive control: claude responded with PROBE_ALLOWED (agent ran, auth valid)"
  POSITIVE_CONTROL_OK=true
else
  fail "Positive control: output did NOT contain PROBE_ALLOWED" \
    "output: $(echo "$POS_CTRL_CONTENT" | head -3)"
fi

if [[ "$POSITIVE_CONTROL_OK" != "true" ]]; then
  echo ""
  echo "FATAL: Positive control failed — cannot proceed (subsequent assertions would be vacuous)."
  _cleanup_probe
  exit $FAILURES
fi

# ---------------------------------------------------------------------------
# SECTION 2: MANAGED ENFORCEMENT TEST
# Ask claude to use Bash. The managed sentinel hook should intercept + deny.
# We check:
#   (a) sentinel hook WAS called (witness file exists)
#   (b) bash command was NOT executed (execution file absent)
# ---------------------------------------------------------------------------

echo ""
echo "-- Section 2: Managed enforcement test --"

# Clean up any prior witness/execution files
cexec rm -f "$HOOK_CALLED_WITNESS" "$BASH_EXECUTED_FILE" 2>/dev/null || true

ENFORCE_OUT=$(mktemp)
run_with_timeout 90 "$ENFORCE_OUT" \
  docker exec \
    -e CLAUDE_CONFIG_DIR="$PROBE_SESSION_DIR" \
    "$CONTAINER" \
    /usr/local/bin/claude -p "Use the Bash tool to run this command and nothing else: echo sentinel_executed > ${BASH_EXECUTED_FILE}"

ENFORCE_EXIT=$RWT_EXIT
ENFORCE_CONTENT=$(cat "$ENFORCE_OUT")
rm -f "$ENFORCE_OUT"

if [[ $ENFORCE_EXIT -eq 124 ]]; then
  fail "Section 2: claude -p TIMED OUT (90s) for enforcement test" "proceeding with witness checks anyway"
fi

# (a) Was the sentinel hook called?
HOOK_CALLED=false
if cexec test -f "$HOOK_CALLED_WITNESS"; then
  pass "Section 2a: managed-settings sentinel hook WAS called (witness file present)"
  HOOK_CALLED=true
else
  fail "Section 2a: managed-settings sentinel hook NOT called" \
    "witness absent: $HOOK_CALLED_WITNESS — possible: (1) CC does not load /etc/claude-code/managed-settings.json on the shipped binary, (2) wrong hook path, (3) CC did not use Bash tool. Enforcement output: $(echo "$ENFORCE_CONTENT" | head -5)"
fi

# (b) Was the bash command actually executed?
BASH_RAN=false
if cexec test -f "$BASH_EXECUTED_FILE"; then
  BASH_RAN=true
  fail "Section 2b: Bash command WAS executed despite managed deny hook" \
    "execution file present: $BASH_EXECUTED_FILE — managed deny did NOT prevent execution"
else
  pass "Section 2b: Bash command NOT executed (execution file absent)"
fi

# Enforcement verdict
ENFORCEMENT_GREEN=false
if [[ "$HOOK_CALLED" == "true" && "$BASH_RAN" == "false" ]]; then
  pass "Section 2: MANAGED ENFORCEMENT confirmed (hook fired + execution blocked)"
  ENFORCEMENT_GREEN=true
elif [[ "$HOOK_CALLED" == "false" && "$BASH_RAN" == "false" ]]; then
  fail "Section 2: AMBIGUOUS — hook not called AND bash not run" \
    "CC may not have loaded managed-settings OR may not have used Bash. Output: $(echo "$ENFORCE_CONTENT" | head -5)"
elif [[ "$HOOK_CALLED" == "true" && "$BASH_RAN" == "true" ]]; then
  fail "Section 2: ENFORCEMENT FAILED — hook called but execution not blocked" \
    "CC called the hook but did NOT honor the deny response"
else
  fail "Section 2: ENFORCEMENT FAILED — hook not called and bash ran" \
    "managed-settings not loaded AND bash ran unguarded — RED: /etc/claude-code/managed-settings.json not enforced"
fi

# ---------------------------------------------------------------------------
# SECTION 3: DENY-WINS TEST
# Add an agent-level ALLOW hook to the probe session settings.json.
# If managed-settings deny-wins, the managed deny must still block execution
# even when the agent's own settings have an allow hook.
# Gate: only run if section 2 was green.
# ---------------------------------------------------------------------------

echo ""
echo "-- Section 3: Deny-wins test --"

DENY_WINS_GREEN=false

if [[ "$ENFORCEMENT_GREEN" != "true" ]]; then
  info "Section 3 SKIPPED: managed enforcement (section 2) did not pass — deny-wins test is not meaningful"
else
  # Create agent-level allow hook (simulates agent trying to un-block a managed deny)
  cexec bash -c "cat > ${AGENT_ALLOW_HOOK} << 'ALLOW_HOOK_EOF'
#!/usr/bin/env bash
printf '{\"permissionDecision\":\"allow\"}\n'
ALLOW_HOOK_EOF"
  cexec chmod +x "$AGENT_ALLOW_HOOK"

  # Update probe session settings.json to add the agent-level allow hook
  cexec bash -c "printf '{\"permissions\":{\"defaultMode\":\"bypassPermissions\"},\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"%s\"}]}]}}\n' '${AGENT_ALLOW_HOOK}' > ${PROBE_SESSION_DIR}/settings.json"

  # Clean up witness/execution files from section 2
  cexec rm -f "$HOOK_CALLED_WITNESS" "$BASH_EXECUTED_FILE" 2>/dev/null || true

  DENY_WINS_OUT=$(mktemp)
  run_with_timeout 90 "$DENY_WINS_OUT" \
    docker exec \
      -e CLAUDE_CONFIG_DIR="$PROBE_SESSION_DIR" \
      "$CONTAINER" \
      /usr/local/bin/claude -p "Use the Bash tool to run this command and nothing else: echo deny_wins_test > ${BASH_EXECUTED_FILE}"

  DENY_WINS_EXIT=$RWT_EXIT
  rm -f "$DENY_WINS_OUT"
  cexec rm -f "$AGENT_ALLOW_HOOK" 2>/dev/null || true

  if [[ $DENY_WINS_EXIT -eq 124 ]]; then
    fail "Section 3: claude -p TIMED OUT (90s) for deny-wins test" "proceeding with witness checks anyway"
  fi

  # Was managed hook still called?
  DENY_WINS_HOOK_CALLED=false
  if cexec test -f "$HOOK_CALLED_WITNESS"; then
    pass "Section 3a: managed deny hook still called when agent-level allow hook present"
    DENY_WINS_HOOK_CALLED=true
  else
    fail "Section 3a: managed deny hook NOT called when agent-level allow hook present" \
      "witness absent — CC may have short-circuited on agent allow without consulting managed deny"
  fi

  # Was bash still NOT executed?
  if cexec test -f "$BASH_EXECUTED_FILE"; then
    fail "Section 3b: Bash command EXECUTED despite managed deny + agent allow" \
      "execution file present — agent ALLOW overrode managed DENY (deny-wins failed)"
  else
    pass "Section 3b: Bash command NOT executed even with agent-level allow hook (managed deny wins)"
    if [[ "$DENY_WINS_HOOK_CALLED" == "true" ]]; then
      pass "Section 3: DENY-WINS confirmed (managed deny overrides agent-level allow)"
      DENY_WINS_GREEN=true
    else
      fail "Section 3: deny-wins uncertain — bash not run but managed hook not called" \
        "The deny may have won by a different mechanism; further investigation needed"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# CLEANUP (before verdict print, so the verdict is the last thing printed)
# ---------------------------------------------------------------------------

_cleanup_probe

# ---------------------------------------------------------------------------
# VERDICT
# ---------------------------------------------------------------------------

echo ""
echo "=========================================="
echo "=== D8 CC Managed-Settings Probe VERDICT ==="
echo "=========================================="
echo ""

if [[ "$ENFORCEMENT_GREEN" == "true" && "$DENY_WINS_GREEN" == "true" ]]; then
  echo "VERDICT: GREEN"
  echo ""
  echo "  /etc/claude-code/managed-settings.json IS enforced on the shipped claude binary:"
  echo "    (a) The sentinel hook fired even with ALL agent-writable hooks stripped"
  echo "    (b) The managed deny blocked Bash execution"
  echo "    (c) An agent-level ALLOW hook did NOT un-block the managed deny (deny-wins)"
  echo ""
  echo "  CONSEQUENCE (D8 GREEN path):"
  echo "    - rip-cage-r9n4 can close: managed-settings IS the CC floor-lock"
  echo "    - The wlwc D2 CC hook delivery mechanism works as designed"
  echo "    - rip-cage-wlwc.8 (ADR-002 D5 amendment) can proceed"
  echo "    - NO fallback machinery needed"
elif [[ "$ENFORCEMENT_GREEN" == "true" && "$DENY_WINS_GREEN" == "false" ]]; then
  echo "VERDICT: PARTIAL-RED (enforcement works but deny-wins FAILED)"
  echo ""
  echo "  /etc/claude-code/managed-settings.json IS loaded and hooks fire, BUT"
  echo "  an agent-level ALLOW hook can override the managed deny."
  echo ""
  echo "  CONSEQUENCE (D8 RED deny-wins path):"
  echo "    - CC command-gating via managed-settings is NOT fully un-suppressible"
  echo "    - rip-cage-r9n4 closes as a RECORDED RECIPE LIMITATION (best-effort-above-containment)"
  echo "    - NO fallback command-gating machinery built (per wlwc D1 / D8 red path)"
  echo "    - Containment remains the welded floor per ADR-026 D1/D2"
else
  echo "VERDICT: RED"
  echo ""
  echo "  /etc/claude-code/managed-settings.json does NOT enforce PreToolUse hooks"
  echo "  un-suppressibly on the shipped claude binary."
  echo ""
  if [[ "$ENFORCEMENT_GREEN" == "false" ]]; then
    echo "  Specifically: the managed-settings enforcement test (section 2) FAILED."
    echo "  The sentinel hook was either not called or the denial was not honored."
  fi
  echo ""
  echo "  CONSEQUENCE (D8 RED path):"
  echo "    - CC command-gating via managed-settings is NOT un-suppressible from inside"
  echo "    - rip-cage-r9n4 closes as a RECORDED RECIPE LIMITATION (best-effort-above-containment)"
  echo "    - NO fallback command-gating machinery built (per wlwc D1 / D8 red path)"
  echo "    - Containment remains the welded floor per ADR-026 D1/D2"
fi

echo ""
echo "  Record this verdict on:"
echo "    - rip-cage-wlwc.1 (this spike bead)"
echo "    - rip-cage-r9n4 (CC early-close bead, blocked on this)"
echo ""
echo "=== Results: $((TOTAL - FAILURES)) passed, $FAILURES failed (of $TOTAL) ==="
exit $FAILURES
