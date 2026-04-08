#!/usr/bin/env bash
# Host-side unit tests for bd-wrapper.sh
# Run: bash test-bd-wrapper.sh
set -euo pipefail

PASS=0
FAIL=0
WRAPPER="/Users/jonat/code/personal/rip-cage/bd-wrapper.sh"

check() {
  local name="$1" result="$2" detail="${3:-}"
  if [[ "$result" == "pass" ]]; then
    echo "PASS  $name${detail:+ — $detail}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name${detail:+ — $detail}"
    FAIL=$((FAIL + 1))
  fi
}

# 1. Syntax check
if bash -n "$WRAPPER" 2>/dev/null; then
  check "syntax check" "pass"
else
  check "syntax check" "fail"
fi

# 2. bd dolt start is blocked when BEADS_DOLT_SERVER_MODE=1
output=$(BEADS_DOLT_SERVER_MODE=1 bash "$WRAPPER" dolt start 2>&1 || true)
# Use a subshell approach
if BEADS_DOLT_SERVER_MODE=1 bash "$WRAPPER" dolt start 2>/dev/null; then
  check "dolt start blocked (BEADS_DOLT_SERVER_MODE=1)" "fail" "expected exit 1"
else
  if echo "$output" | grep -q "BLOCKED"; then
    check "dolt start blocked (BEADS_DOLT_SERVER_MODE=1)" "pass" "exited non-zero with BLOCKED message"
  else
    check "dolt start blocked (BEADS_DOLT_SERVER_MODE=1)" "fail" "exited non-zero but no BLOCKED in output: $output"
  fi
fi

# 3. --verbose flag bypass prevented
output2=$(BEADS_DOLT_SERVER_MODE=1 bash "$WRAPPER" --verbose dolt start 2>&1 || true)
if BEADS_DOLT_SERVER_MODE=1 bash "$WRAPPER" --verbose dolt start 2>/dev/null; then
  check "--verbose dolt start blocked" "fail" "expected exit 1"
else
  if echo "$output2" | grep -q "BLOCKED"; then
    check "--verbose dolt start blocked" "pass"
  else
    check "--verbose dolt start blocked" "fail" "no BLOCKED in output: $output2"
  fi
fi

# 4. dolt stop is NOT blocked (even with BEADS_DOLT_SERVER_MODE=1)
# Since bd-real doesn't exist on host, it will fail with "not found" — but it
# must NOT fail with "BLOCKED". We check that the exit is NOT due to BLOCKED.
output3=$(BEADS_DOLT_SERVER_MODE=1 bash "$WRAPPER" dolt stop 2>&1 || true)
if echo "$output3" | grep -q "BLOCKED"; then
  check "dolt stop NOT blocked" "fail" "got BLOCKED: $output3"
else
  check "dolt stop NOT blocked" "pass" "passed through (no BLOCKED)"
fi

# 5. Without BEADS_DOLT_SERVER_MODE, dolt start passes through
output4=$(bash "$WRAPPER" dolt start 2>&1 || true)
if echo "$output4" | grep -q "BLOCKED"; then
  check "dolt start not blocked without env var" "fail" "got BLOCKED unexpectedly"
else
  check "dolt start not blocked without env var" "pass" "passed through (no BLOCKED)"
fi

# 6. Port re-read uses correct env var name BEADS_DOLT_SERVER_PORT (not BEADS_DOLT_PORT)
if grep -q 'BEADS_DOLT_SERVER_PORT' "$WRAPPER" && ! grep -qE 'BEADS_DOLT_PORT[^_]' "$WRAPPER"; then
  check "port re-read uses correct env var BEADS_DOLT_SERVER_PORT" "pass"
else
  check "port re-read uses correct env var BEADS_DOLT_SERVER_PORT" "fail" "wrapper exports wrong env var name (should be BEADS_DOLT_SERVER_PORT, not BEADS_DOLT_PORT)"
fi

echo ""
echo "Results: $PASS passed, $((PASS + FAIL)) total"
[[ "$FAIL" -eq 0 ]] || exit 1
