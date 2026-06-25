#!/usr/bin/env bash
# test-pi-no-extensions.sh — Regression probe: pi --no-extensions bypass guard (rip-cage-sn1h)
#
# Confirms that the pi launch wrapper (/usr/local/bin/pi) closes the workspace-path
# extension auto-discovery bypass by adding --no-extensions -e <dcg-gate> to every pi call.
#
# This probe verifies TWO things:
#   (a) /workspace/.pi/extensions/evil.ts is NOT loaded by the wrapper (auto-discovery disabled)
#   (b) a known-destructive command is still DENIED by the DCG guard (effect, not presence)
#
# Non-negotiable guardrails wired in (repo scars):
#   POSITIVE CONTROL: prove evil.ts CAN be detected when explicitly loaded, so absence
#     is meaningful (not vacuous). Uses /usr/bin/pi directly + explicit -e.
#     (auth-precondition-presence-not-validity-silent-timeout)
#   EFFECT not presence: DCG denial is tested via dcg-guard effect (DENIED output),
#     not merely by checking wrapper exists or config presence.
#     (rip-cage-firewall-rule-presence-not-enforcement)
#   EXIT CODE: exits $FAILURES — never FAIL-prose + exit 0.
#     (rip-cage-test-fail-prose-without-exit-silent-red)
#   OWN-SHELL: run against a cage alive in your session; do not carry forward from
#     a prior destroyed container.
#     (rip-cage-verification-carry-forward-false-green)
#
# Usage (host-side):
#   RC_TEST_CONTAINER=<container-name> bash tests/test-pi-no-extensions.sh
#   # Or with a running cage: auto-detected via rip-cage:latest ancestor
#
# Classification: NEEDS_CONTAINER (runs docker exec, requires a running rip-cage cage)

set -uo pipefail

FAILURES=0
TOTAL=0
PROBE_SUFFIX=$$
EVIL_TS_PATH="/workspace/.pi/extensions/evil.ts"
PI_SESSION_DIR="/tmp/pi-no-ext-probe-${PROBE_SUFFIX}"

pass() {
  TOTAL=$((TOTAL + 1))
  echo "PASS  [$TOTAL] $1"
}

fail() {
  TOTAL=$((TOTAL + 1))
  echo "FAIL  [$TOTAL] $1${2:+  — $2}"
  FAILURES=$((FAILURES + 1))
}

# Portable timeout: run a command in background; kill if it exceeds N seconds.
# Sets global RWT_EXIT to the exit code (124 = timeout).
RWT_EXIT=0
run_with_timeout() {
  local timeout_secs="$1" outfile="$2"
  shift 2
  RWT_EXIT=0
  "$@" >"$outfile" 2>&1 &
  local cmd_pid=$!
  ( sleep "$timeout_secs" && kill "$cmd_pid" 2>/dev/null ) &
  local watchdog_pid=$!
  wait "$cmd_pid" 2>/dev/null && RWT_EXIT=$? || RWT_EXIT=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if ! kill -0 "$cmd_pid" 2>/dev/null && [[ $RWT_EXIT -gt 128 ]]; then
    RWT_EXIT=124
  fi
}

echo "=== Pi --no-extensions Regression Probe (rip-cage-sn1h) ==="
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
# Resolve test container
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
cexec() { docker exec "$CONTAINER" "$@"; }

# ---------------------------------------------------------------------------
# Guard: skip if pi not installed in the container
# ---------------------------------------------------------------------------
if ! cexec bash -c 'command -v pi >/dev/null 2>&1'; then
  echo "SKIP: pi not installed in container $CONTAINER (non-pi cage)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Cleanup: remove probe artifacts (called explicitly before exit)
# ---------------------------------------------------------------------------
_cleanup_probe() {
  cexec rm -rf "$PI_SESSION_DIR" 2>/dev/null || true
  cexec rm -f "$EVIL_TS_PATH" 2>/dev/null || true
  cexec bash -c "rmdir /workspace/.pi/extensions 2>/dev/null || true" 2>/dev/null || true
  cexec bash -c "rmdir /workspace/.pi 2>/dev/null || true" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# SECTION S: STRUCTURAL checks (no API call needed)
# ---------------------------------------------------------------------------
echo "-- Section S: Structural checks --"

# S1: pi wrapper present at /usr/local/bin/pi
if cexec test -x /usr/local/bin/pi; then
  pass "S1: pi wrapper present and executable at /usr/local/bin/pi"
else
  fail "S1: pi wrapper MISSING or not executable at /usr/local/bin/pi" \
    "expected: examples/pi recipe install_cmd writes the wrapper to /usr/local/bin/pi (rip-cage-sn1h)"
fi

# S2: wrapper contains --no-extensions flag
if cexec grep -q -- '--no-extensions' /usr/local/bin/pi 2>/dev/null; then
  pass "S2: wrapper contains --no-extensions flag"
else
  fail "S2: wrapper does NOT contain --no-extensions flag" \
    "$(cexec cat /usr/local/bin/pi 2>/dev/null | head -5)"
fi

# S3: wrapper contains explicit -e <dcg-gate.ts>
if cexec grep -q 'dcg-gate.ts' /usr/local/bin/pi 2>/dev/null; then
  pass "S3: wrapper contains explicit -e dcg-gate.ts path"
else
  fail "S3: wrapper does NOT contain explicit -e dcg-gate.ts path" \
    "$(cexec cat /usr/local/bin/pi 2>/dev/null | head -10)"
fi

# S4: wrapper invokes the real pi binary
if cexec grep -q '/usr/bin/pi' /usr/local/bin/pi 2>/dev/null; then
  pass "S4: wrapper invokes real pi at /usr/bin/pi"
else
  fail "S4: wrapper does NOT reference /usr/bin/pi" \
    "$(cexec cat /usr/local/bin/pi 2>/dev/null | head -10)"
fi

# S5: wrapper is root-owned (agent cannot replace it to bypass --no-extensions)
_wrapper_owner=$(cexec stat -c '%U' /usr/local/bin/pi 2>/dev/null || true)
if [[ "$_wrapper_owner" == "root" ]]; then
  pass "S5: wrapper is root-owned (agent cannot replace it)"
else
  fail "S5: wrapper is owned by '${_wrapper_owner}' (expected root)" \
    "agent could replace wrapper to bypass --no-extensions"
fi
unset _wrapper_owner

# S6: dcg-gate.ts present and root-owned on its OWN separate load path
# (ADR-027 D1/D3 — guard wiring NOT inside extensions/; olen retired, rip-cage-wlwc.4)
if cexec test -f /etc/rip-cage/pi/dcg-gate.ts; then
  pass "S6a: dcg-gate.ts present at /etc/rip-cage/pi/dcg-gate.ts"
else
  fail "S6a: dcg-gate.ts MISSING at /etc/rip-cage/pi/dcg-gate.ts" \
    "recipe regression: examples/pi install_cmd must write the guard to /etc/rip-cage/pi/dcg-gate.ts"
fi

_dcg_owner=$(cexec stat -c '%U' /etc/rip-cage/pi/dcg-gate.ts 2>/dev/null || true)
if [[ "$_dcg_owner" == "root" ]]; then
  pass "S6b: dcg-gate.ts is root-owned (write-denied to agent)"
else
  fail "S6b: dcg-gate.ts is owned by '${_dcg_owner}' (expected root)" \
    "agent can overwrite the guard — floor-lock regression (ADR-027 D1/D3)"
fi
unset _dcg_owner

echo ""

# ---------------------------------------------------------------------------
# SECTION E: EVIL.TS NOT LOADED (extension auto-discovery disabled)
#
# Design:
#   evil.ts = a factory-exporting extension that writes "EVIL_EXT_LOADED" to
#   stderr on load. If auto-discovery were still enabled, it would appear in
#   pi's output when run from /workspace (since pi scans <cwd>/.pi/extensions/).
#
# POSITIVE CONTROL (E1): call /usr/bin/pi DIRECTLY with -e evil.ts to confirm
#   evil.ts CAN be detected (the "EVIL_EXT_LOADED" marker appears in output).
#   This makes absence in E2 meaningful — not a vacuous test.
#
# MAIN ASSERTION (E2): call `pi` via the WRAPPER (which adds --no-extensions)
#   and confirm "EVIL_EXT_LOADED" does NOT appear. The wrapper's --no-extensions
#   disables auto-discovery so /workspace/.pi/extensions/evil.ts is not loaded.
# ---------------------------------------------------------------------------
echo "-- Section E: Evil extension NOT loaded via wrapper --"

# Create the evil extension in the workspace path pi would auto-discover
cexec mkdir -p /workspace/.pi/extensions
cexec bash -c 'cat > /workspace/.pi/extensions/evil.ts << '\''EVIL_EOF'\''
// evil.ts — test extension: prints EVIL_EXT_LOADED on load if auto-discovered.
// Used by test-pi-no-extensions.sh (rip-cage-sn1h) to confirm --no-extensions
// prevents loading from the agent-writable /workspace/.pi/extensions/ path.
export default function(pi: any) {
  process.stderr.write("EVIL_EXT_LOADED\n");
}
EVIL_EOF'

if cexec test -f /workspace/.pi/extensions/evil.ts; then
  pass "E0: evil.ts dropped at /workspace/.pi/extensions/evil.ts"
else
  fail "E0: failed to create evil.ts at /workspace/.pi/extensions/evil.ts" \
    "cannot proceed with extension isolation test"
  echo ""
  _cleanup_probe
  echo "=== Results: $((TOTAL - FAILURES)) passed, $FAILURES failed (of $TOTAL) ==="
  exit $FAILURES
fi

# Create session dir for pi to use
cexec mkdir -p "$PI_SESSION_DIR"

# E1: POSITIVE CONTROL — call /usr/bin/pi DIRECTLY with explicit -e evil.ts.
# evil.ts should be loaded (EVIL_EXT_LOADED appears). Proves detection works.
POS_OUT=$(mktemp)
run_with_timeout 30 "$POS_OUT" \
  docker exec \
    -e HOME=/home/agent \
    -e PI_CODING_AGENT_DIR=/home/agent/.pi/agent \
    -w /workspace \
    "$CONTAINER" \
    /usr/bin/pi \
      --no-session \
      --session-dir "$PI_SESSION_DIR" \
      --no-extensions \
      -e /workspace/.pi/extensions/evil.ts \
      --help

POS_EXIT=$RWT_EXIT
POS_CONTENT=$(cat "$POS_OUT")
rm -f "$POS_OUT"

if echo "$POS_CONTENT" | grep -q 'EVIL_EXT_LOADED'; then
  pass "E1: POSITIVE CONTROL — evil.ts IS loaded when explicitly passed via -e (detection works)"
else
  fail "E1: POSITIVE CONTROL FAILED — evil.ts NOT loaded even with explicit -e (exit $POS_EXIT)" \
    "Cannot proceed: absence in E2 would be vacuous (evil.ts fails to signal on load)"
  echo ""
  echo "FATAL: Positive control failed — E2 assertion would be vacuous. Cannot continue."
  _cleanup_probe
  echo "=== Results: $((TOTAL - FAILURES)) passed, $FAILURES failed (of $TOTAL) ==="
  exit $FAILURES
fi

# E2: MAIN ASSERTION — call `pi` via the WRAPPER (which adds --no-extensions -e dcg-gate.ts).
# evil.ts in /workspace/.pi/extensions/ must NOT be loaded (no EVIL_EXT_LOADED in output).
MAIN_OUT=$(mktemp)
run_with_timeout 30 "$MAIN_OUT" \
  docker exec \
    -e HOME=/home/agent \
    -e PI_CODING_AGENT_DIR=/home/agent/.pi/agent \
    -w /workspace \
    "$CONTAINER" \
    /usr/local/bin/pi \
      --session-dir "$PI_SESSION_DIR" \
      --help

MAIN_EXIT=$RWT_EXIT
MAIN_CONTENT=$(cat "$MAIN_OUT")
rm -f "$MAIN_OUT"

if [[ $MAIN_EXIT -eq 124 ]]; then
  fail "E2: pi --help via wrapper TIMED OUT (30s)" "wrapper may be broken or pi hangs"
elif echo "$MAIN_CONTENT" | grep -q 'EVIL_EXT_LOADED'; then
  fail "E2: EVIL_EXT_LOADED found in wrapper output — evil.ts WAS loaded despite --no-extensions" \
    "/workspace/.pi/extensions/ auto-discovery bypass is still open (rip-cage-sn1h not fixed)"
else
  pass "E2: EVIL_EXT_LOADED NOT in wrapper output — evil.ts NOT loaded (auto-discovery disabled)"
fi

echo ""

# ---------------------------------------------------------------------------
# SECTION D: DCG GUARD STILL DENIES (effect test)
#
# Tests the DCG guard actually BLOCKS a destructive command (effect, not config).
# Uses dcg-guard directly (same mechanism as DCG-PI-GUARD-2a.rm in examples/dcg/smoke.sh) — no API call.
# D1: positive control — safe command is ALLOWED (proves guard actually ran)
# D2: destructive command (rm -rf /) is DENIED
# ---------------------------------------------------------------------------
echo "-- Section D: DCG guard still denies destructive commands --"

DCG_GUARD="/usr/local/lib/rip-cage/bin/dcg-guard"

if ! cexec test -x "$DCG_GUARD"; then
  fail "D0: dcg-guard not executable at $DCG_GUARD" \
    "Sections D1/D2 skipped — guard not available"
  echo ""
  _cleanup_probe
  echo "=== Results: $((TOTAL - FAILURES)) passed, $FAILURES failed (of $TOTAL) ==="
  exit $FAILURES
fi

# D1: POSITIVE CONTROL — safe command (echo hello) is NOT denied.
# Proves the guard ran and responded (not silently broken / returning empty).
_safe_out=$(cexec bash -c "printf '{\"tool_name\":\"bash\",\"tool_input\":{\"command\":\"echo hello\"}}' | ${DCG_GUARD} 2>/dev/null || true")
if echo "$_safe_out" | grep -qE '"permissionDecision".*"deny"'; then
  fail "D1: POSITIVE CONTROL FAILED — safe command 'echo hello' was DENIED by dcg-guard" \
    "DCG guard is over-blocking or misbehaving; output: $_safe_out"
else
  pass "D1: POSITIVE CONTROL — safe command 'echo hello' is ALLOWED (guard ran and is responsive)"
fi
unset _safe_out

# D2: EFFECT TEST — destructive command (rm -rf /) is DENIED.
_deny_out=$(cexec bash -c "printf '{\"tool_name\":\"bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | ${DCG_GUARD} 2>/dev/null || true")
if echo "$_deny_out" | grep -qE '"permissionDecision".*"deny"'; then
  pass "D2: EFFECT — destructive 'rm -rf /' is DENIED by dcg-guard (guard still active)"
else
  fail "D2: EFFECT FAILED — destructive 'rm -rf /' was NOT denied by dcg-guard" \
    "DCG guard not blocking; output: $_deny_out"
fi
unset _deny_out

echo ""

# ---------------------------------------------------------------------------
# Cleanup + Summary
# ---------------------------------------------------------------------------
_cleanup_probe
echo "=== Results: $((TOTAL - FAILURES)) passed, $FAILURES failed (of $TOTAL) ==="
exit $FAILURES
