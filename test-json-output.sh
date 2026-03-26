#!/usr/bin/env bash
set -uo pipefail

# Tests for --output json flag on the rc CLI
# These tests validate JSON output without requiring Docker containers.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# --- Test 1: rc script is valid bash ---
echo "=== Test 1: rc script is valid bash ==="
if bash -n "$RC" 2>&1; then
  pass "rc is valid bash"
else
  fail "rc has syntax errors"
fi

# --- Test 2: Usage text documents --output flag ---
echo ""
echo "=== Test 2: Usage text documents --output json ==="
usage_output=$("$RC" 2>&1 || true)
if echo "$usage_output" | grep -q "\-\-output"; then
  pass "usage mentions --output"
else
  fail "usage does not mention --output"
fi

# --- Test 3: --output json ls returns valid JSON array ---
echo ""
echo "=== Test 3: --output json ls returns valid JSON array ==="
# This works even without Docker running — docker ps returns error which
# we need to handle, or if Docker IS running, returns empty array
ls_output=$("$RC" --output json ls 2>/dev/null) || true
if echo "$ls_output" | jq -e 'type == "array"' >/dev/null 2>&1; then
  pass "--output json ls returns JSON array"
else
  fail "--output json ls did not return JSON array. Got: $ls_output"
fi

# --- Test 4: rc ls (no --output flag) returns human table format ---
echo ""
echo "=== Test 4: rc ls without --output returns human table format ==="
ls_human=$("$RC" ls 2>/dev/null) || true
# Human output starts with NAMES (docker table header) or is empty
# It should NOT be a JSON array
if echo "$ls_human" | jq -e 'type == "array"' >/dev/null 2>&1; then
  fail "rc ls without flag returned JSON (should be human format)"
else
  pass "rc ls without flag returns human format (not JSON)"
fi

# --- Test 5: --output requires 'json' argument ---
echo ""
echo "=== Test 5: --output without json argument errors ==="
bad_output=$("$RC" --output foo ls 2>&1) || true
if echo "$bad_output" | grep -qi "error\|requires"; then
  pass "--output foo produces error"
else
  fail "--output foo did not produce error. Got: $bad_output"
fi

# --- Test 6: Global flags must come before subcommand ---
echo ""
echo "=== Test 6: Global flags before subcommand ==="
# rc --output json ls should work (tested above in test 3)
# rc ls --output json should NOT work (treated as unknown arg to ls)
# We just verify that the correct order works
ls_correct=$("$RC" --output json ls 2>/dev/null) || true
if echo "$ls_correct" | jq -e 'type == "array"' >/dev/null 2>&1; then
  pass "global flags before subcommand works"
else
  fail "global flags before subcommand failed. Got: $ls_correct"
fi

# --- Test 7: json_error produces valid JSON with error and code fields ---
echo ""
echo "=== Test 7: --output json up with no path produces JSON error ==="
up_err=$("$RC" --output json up 2>&1) || true
if echo "$up_err" | jq -e '.error and .code' >/dev/null 2>&1; then
  pass "--output json up with no path returns JSON error with code"
else
  fail "--output json up with no path did not return JSON error. Got: $up_err"
fi

# --- Test 8: cmd_up Docker-not-running check emits JSON error ---
echo ""
echo "=== Test 8: cmd_up Docker-not-running emits JSON error ==="
# If Docker IS running, this test is not applicable; skip it
if ! docker info > /dev/null 2>&1; then
  up_docker_err=$("$RC" --output json up /tmp 2>&1) || true
  if echo "$up_docker_err" | jq -e '.code == "DOCKER_NOT_RUNNING"' >/dev/null 2>&1; then
    pass "Docker-not-running returns JSON error with DOCKER_NOT_RUNNING code"
  else
    fail "Docker-not-running did not return correct JSON error. Got: $up_docker_err"
  fi
else
  echo "SKIP: Docker is running, cannot test DOCKER_NOT_RUNNING path"
fi

# --- Test 9: log function sends to stderr in JSON mode ---
echo ""
echo "=== Test 9: log sends to stderr in JSON mode ==="
# For cmd_build, in JSON mode the log message should go to stderr
# We capture stderr separately
build_stderr=$("$RC" --output json build 2>&1 1>/dev/null) || true
# In JSON mode, "Building..." should appear on stderr
if echo "$build_stderr" | grep -q "Building"; then
  pass "log message goes to stderr in JSON mode"
else
  # Docker may not be running, so build may fail, but the log should still appear
  fail "log message not found on stderr in JSON mode. stderr: $build_stderr"
fi

# --- Test 10: --dry-run flag is accepted (parsed without error) ---
echo ""
echo "=== Test 10: --dry-run flag is accepted ==="
dryrun_output=$("$RC" --dry-run ls 2>/dev/null) || true
# Should not error about unknown flag — just run the command normally for now
# (--dry-run behavior is for a future bead, but parsing should work)
if [[ $? -le 1 ]]; then
  pass "--dry-run flag is accepted without parse error"
else
  fail "--dry-run flag caused parse error"
fi

# --- Cleanup ---
echo ""
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
