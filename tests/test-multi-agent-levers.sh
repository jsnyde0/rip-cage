#!/usr/bin/env bash
# test-multi-agent-levers.sh — NEEDS_CONTAINER e2e test
#
# Verifies the Tier 1a mechanical session levers (rip-cage-tlm):
#   1. Verbatim pass-through — rc agent runs command with exact word boundaries
#   2. Enumerate by membership — rc sessions --json contains both handles (membership, not count)
#   3. Selective kill — rc sessions --kill a removes a while b survives
#   4. Duplicate-name refusal — second rc agent --name=b exits non-zero with surfaced error
#   5. Two-pi concurrency proof — two pi agents both show pi-ready marker via tmux capture-pane
#
# Pi-ready marker: "escape interrupt" — from pi's startup banner
#   (captured from a live in-cage pi probe: init-rip-cage container, pi startup).
#   Not a bare shell, not a crashed/respawned-to-shell pi — only present when pi
#   is running interactively.
#
# Pre-conditions: docker available; rip-cage:latest built; a running cage exists
# (container name passed as RC_TEST_CONTAINER or auto-detected via docker ps).
#
# NEEDS_CONTAINER: self-skips when no running cage.
# Wired into tests/run-host.sh NEEDS_CONTAINER array per ADR-013.
#
# Hard rules (repo lessons):
#   - FAILURES counter + exit $FAILURES at end; no "fail via prose + exit 0"
#   - Every absence assertion is gated on a positive sentinel first
#   - Membership assertions (.[].name contains X) not exclusive list/count
#   - Default rip-cage session is always present — never assert an exact session count

set -uo pipefail

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

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
echo "=== test-multi-agent-levers.sh ==="
echo "Container: $CONTAINER"

RC="${RC:-$(dirname "$0")/../rc}"
PI_READY_MARKER="escape interrupt"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
cexec() { docker exec "$CONTAINER" "$@"; }

# ---------------------------------------------------------------------------
# Pre-step: clean up any stale test sessions from prior runs
# ---------------------------------------------------------------------------
cexec tmux kill-session -t tlm-a 2>/dev/null || true
cexec tmux kill-session -t tlm-b 2>/dev/null || true
cexec tmux kill-session -t tlm-pi1 2>/dev/null || true
cexec tmux kill-session -t tlm-pi2 2>/dev/null || true
cexec rm -f /workspace/tlm-sentinel.txt 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 1: Verbatim pass-through
# rc agent --name=a -- <cmd with spaces AND special chars> that writes a sentinel
# Asserts: sentinel content proves the command ran exactly as given
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 1: Verbatim pass-through ==="

SENTINEL_CONTENT='hello world  extra   spaces  & special!chars'
SENTINEL_PATH="/workspace/tlm-sentinel.txt"

# The command writes the exact expected content to the sentinel file.
# Uses a shell -c invocation so we can embed the string as one quoted arg.
# The key test: the multi-word string with spaces reaches the command intact.
"$RC" agent "$CONTAINER" --name=tlm-a -- sh -c "printf '%s' 'hello world  extra   spaces  & special!chars' > $SENTINEL_PATH"
EXIT_AGENT_A=$?

if [[ $EXIT_AGENT_A -eq 0 ]]; then
  pass "Step 1: rc agent --name=tlm-a exited 0"
else
  fail "Step 1: rc agent --name=tlm-a exited $EXIT_AGENT_A" ""
fi

# Wait for the session to run the command (short-lived sh -c exits quickly)
_waited=0
while [[ $_waited -lt 10 ]]; do
  if cexec test -f "$SENTINEL_PATH" 2>/dev/null; then
    break
  fi
  sleep 1
  _waited=$((_waited + 1))
done

# Gate: only check content if the file exists
if ! cexec test -f "$SENTINEL_PATH" 2>/dev/null; then
  fail "Step 1: sentinel file $SENTINEL_PATH not created within 10s" ""
else
  ACTUAL=$(cexec cat "$SENTINEL_PATH")
  if [[ "$ACTUAL" == "$SENTINEL_CONTENT" ]]; then
    pass "Step 1: sentinel content matches exactly (verbatim pass-through confirmed)"
  else
    fail "Step 1: sentinel content mismatch" "expected='$SENTINEL_CONTENT' actual='$ACTUAL'"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: Enumerate by membership
# rc agent --name=b -- <cheap long-lived cmd>
# Asserts: rc sessions --json returns non-empty array containing both a and b
# (membership — default rip-cage session is also present; never exclusive count)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Enumerate by membership ==="

"$RC" agent "$CONTAINER" --name=tlm-b -- sleep 300
EXIT_AGENT_B=$?

if [[ $EXIT_AGENT_B -eq 0 ]]; then
  pass "Step 2: rc agent --name=tlm-b exited 0"
else
  fail "Step 2: rc agent --name=tlm-b exited $EXIT_AGENT_B" ""
fi

# Short wait for tmux session list to stabilize
sleep 1

SESSION_JSON=$("$RC" sessions "$CONTAINER" --json 2>&1)
SESSION_JSON_EXIT=$?

if [[ $SESSION_JSON_EXIT -ne 0 ]]; then
  fail "Step 2: rc sessions --json exited $SESSION_JSON_EXIT" "$SESSION_JSON"
else
  # Positive sentinel: JSON must be a non-empty array
  if echo "$SESSION_JSON" | grep -q '^\[\]$'; then
    fail "Step 2: rc sessions --json returned empty array — no sessions" ""
  elif ! echo "$SESSION_JSON" | grep -q '^\['; then
    fail "Step 2: rc sessions --json output is not JSON array" "$SESSION_JSON"
  else
    pass "Step 2: rc sessions --json returned a non-empty array (positive sentinel)"

    # Check membership for tlm-a (either still listed or already exited — short-lived)
    # Note: tlm-a ran a short sh -c; it may have exited (respawn-pane resurrects it as shell,
    # and it will still be listed). Check that tlm-b is present (long-lived sleep).
    if echo "$SESSION_JSON" | grep -q '"name":"tlm-b"'; then
      pass "Step 2: tlm-b present in rc sessions --json (membership confirmed)"
    else
      fail "Step 2: tlm-b NOT found in rc sessions --json" "$SESSION_JSON"
    fi

    # Also verify tlm-a is present (either still running command or respawned shell)
    if echo "$SESSION_JSON" | grep -q '"name":"tlm-a"'; then
      pass "Step 2: tlm-a present in rc sessions --json (membership confirmed)"
    else
      fail "Step 2: tlm-a NOT found in rc sessions --json" "$SESSION_JSON"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: Selective kill
# rc sessions --kill tlm-a; assert tlm-a absent and tlm-b present (membership)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Selective kill ==="

# Gate: only run kill test if we got a valid session list
if [[ $SESSION_JSON_EXIT -eq 0 ]] && ! echo "$SESSION_JSON" | grep -q '^\[\]$'; then
  "$RC" sessions "$CONTAINER" --kill tlm-a
  KILL_EXIT=$?

  if [[ $KILL_EXIT -eq 0 ]]; then
    pass "Step 3: rc sessions --kill tlm-a exited 0"
  else
    fail "Step 3: rc sessions --kill tlm-a exited $KILL_EXIT" ""
  fi

  sleep 1

  # Verify b is still present (positive sentinel before absence check)
  SESSION_JSON_AFTER=$("$RC" sessions "$CONTAINER" --json 2>&1)
  AFTER_EXIT=$?

  if [[ $AFTER_EXIT -ne 0 ]]; then
    fail "Step 3: rc sessions --json after kill exited $AFTER_EXIT" "$SESSION_JSON_AFTER"
  elif echo "$SESSION_JSON_AFTER" | grep -q '^\[\]$'; then
    fail "Step 3: rc sessions --json after kill returned empty array — source empty/unreachable, cannot assert tlm-a absent" "$SESSION_JSON_AFTER"
  elif ! echo "$SESSION_JSON_AFTER" | grep -q '^\['; then
    fail "Step 3: rc sessions --json after kill output is not a JSON array — source unreachable, cannot assert tlm-a absent" "$SESSION_JSON_AFTER"
  elif ! echo "$SESSION_JSON_AFTER" | grep -q '"name":"tlm-b"'; then
    fail "Step 3: tlm-b absent after killing tlm-a — expected it to survive" "$SESSION_JSON_AFTER"
  else
    pass "Step 3: SESSION_JSON_AFTER is a live non-empty array (positive sentinel)"
    pass "Step 3: tlm-b still present after killing tlm-a (b-presence confirmed)"
    # Now check a is absent
    if echo "$SESSION_JSON_AFTER" | grep -q '"name":"tlm-a"'; then
      fail "Step 3: tlm-a still present after kill — kill did not work" "$SESSION_JSON_AFTER"
    else
      pass "Step 3: tlm-a absent from rc sessions --json after kill (selective kill confirmed)"
    fi
  fi
else
  fail "Step 3: skipping kill test — positive sentinel from Step 2 not established" ""
fi

# ---------------------------------------------------------------------------
# Step 4: Duplicate-name refusal
# Second rc agent --name=tlm-b exits non-zero with surfaced error
# First tlm-b must be undisturbed (b still listed after failed duplicate attempt)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 4: Duplicate-name refusal ==="

DUP_OUT=$("$RC" agent "$CONTAINER" --name=tlm-b -- sleep 1 2>&1)
DUP_EXIT=$?

if [[ $DUP_EXIT -ne 0 ]]; then
  pass "Step 4: duplicate rc agent --name=tlm-b exited non-zero ($DUP_EXIT)"
else
  fail "Step 4: duplicate rc agent --name=tlm-b exited 0 — should have failed" ""
fi

# Check error was surfaced (tmux emits "duplicate session: <name>")
if echo "$DUP_OUT" | grep -qi "duplicate"; then
  pass "Step 4: duplicate error message surfaced: '$DUP_OUT'"
else
  fail "Step 4: duplicate error not surfaced in output" "got: '$DUP_OUT'"
fi

# Confirm original tlm-b is still present (undisturbed)
SESSION_JSON_DUP=$("$RC" sessions "$CONTAINER" --json 2>&1)
if echo "$SESSION_JSON_DUP" | grep -q '"name":"tlm-b"'; then
  pass "Step 4: original tlm-b session still present after failed duplicate attempt"
else
  fail "Step 4: tlm-b session gone after duplicate attempt — original was disturbed!" "$SESSION_JSON_DUP"
fi

# ---------------------------------------------------------------------------
# Step 5: Two-pi concurrency proof
# Two pi agents via rc agent, then tmux capture-pane EACH session.
# Assert pi-ready marker appears in BOTH panes.
# Session presence alone is insufficient (respawn-pane resurrects crashed pi as shell).
# Marker: "escape interrupt" from pi's startup banner.
# Startup-only — NO pi -p, zero API spend.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Two-pi concurrency proof ==="

# Clean up any prior pi sessions
cexec tmux kill-session -t tlm-pi1 2>/dev/null || true
cexec tmux kill-session -t tlm-pi2 2>/dev/null || true

"$RC" agent "$CONTAINER" --name=tlm-pi1 -- pi
EXIT_PI1=$?

"$RC" agent "$CONTAINER" --name=tlm-pi2 -- pi
EXIT_PI2=$?

if [[ $EXIT_PI1 -eq 0 ]]; then
  pass "Step 5: rc agent --name=tlm-pi1 -- pi exited 0"
else
  fail "Step 5: rc agent --name=tlm-pi1 -- pi exited $EXIT_PI1" ""
fi

if [[ $EXIT_PI2 -eq 0 ]]; then
  pass "Step 5: rc agent --name=tlm-pi2 -- pi exited 0"
else
  fail "Step 5: rc agent --name=tlm-pi2 -- pi exited $EXIT_PI2" ""
fi

# Wait for both pi instances to reach interactive-ready
# Poll up to 60s; capture-pane check for marker
_PI_TIMEOUT=60
_pi1_ready=false
_pi2_ready=false
_waited=0

while [[ $_waited -lt $_PI_TIMEOUT ]]; do
  sleep 2
  _waited=$((_waited + 2))

  PANE1=$(cexec tmux capture-pane -p -t tlm-pi1 -S -100 2>/dev/null || true)
  PANE2=$(cexec tmux capture-pane -p -t tlm-pi2 -S -100 2>/dev/null || true)

  if echo "$PANE1" | grep -q "$PI_READY_MARKER"; then
    _pi1_ready=true
  fi
  if echo "$PANE2" | grep -q "$PI_READY_MARKER"; then
    _pi2_ready=true
  fi

  if [[ "$_pi1_ready" == "true" && "$_pi2_ready" == "true" ]]; then
    break
  fi
done

echo "  tlm-pi1 pane (last 5 lines):"
cexec tmux capture-pane -p -t tlm-pi1 -S -5 2>/dev/null | sed 's/^/    /' || true
echo "  tlm-pi2 pane (last 5 lines):"
cexec tmux capture-pane -p -t tlm-pi2 -S -5 2>/dev/null | sed 's/^/    /' || true

if [[ "$_pi1_ready" == "true" ]]; then
  pass "Step 5: pi-ready marker found in tlm-pi1 pane (pi is interactive-ready)"
else
  fail "Step 5: pi-ready marker NOT found in tlm-pi1 pane within ${_PI_TIMEOUT}s" \
    "marker='$PI_READY_MARKER'"
fi

if [[ "$_pi2_ready" == "true" ]]; then
  pass "Step 5: pi-ready marker found in tlm-pi2 pane (pi is interactive-ready)"
else
  fail "Step 5: pi-ready marker NOT found in tlm-pi2 pane within ${_PI_TIMEOUT}s" \
    "marker='$PI_READY_MARKER'"
fi

if [[ "$_pi1_ready" == "true" && "$_pi2_ready" == "true" ]]; then
  pass "Step 5: TWO concurrent pi agents confirmed interactive-ready in one cage"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cexec tmux kill-session -t tlm-a 2>/dev/null || true
cexec tmux kill-session -t tlm-b 2>/dev/null || true
cexec tmux kill-session -t tlm-pi1 2>/dev/null || true
cexec tmux kill-session -t tlm-pi2 2>/dev/null || true
cexec rm -f "$SENTINEL_PATH" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== test-multi-agent-levers.sh complete ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All multi-agent lever tests PASSED."
else
  echo "$FAILURES multi-agent lever test(s) FAILED."
fi

exit $FAILURES
