#!/usr/bin/env bash
set -uo pipefail

# Tests for code review fixes (C1, C2, I1, I2, I3, I4)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/rc"
FAILURES=0
PASSES=0

pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== Code Review Fix Tests ==="

# --- C1: json_error uses jq --arg (no string interpolation) ---
echo ""
echo "=== C1: json_error uses jq --arg ==="
# Verify json_error implementation uses jq --arg, not string interpolation
if grep -A2 'json_error()' "$RC" | grep -q 'jq -nc --arg'; then
  pass "json_error uses jq --arg for safe JSON construction"
else
  fail "json_error does not use jq --arg"
fi

# --- C2: json_out eliminated — verify no json_out calls with interpolation ---
echo ""
echo "=== C2: No unsafe json_out with interpolated variables ==="
# Count json_out calls that contain $ (variable interpolation) in rc, excluding the function definition
unsafe_count=$(grep 'json_out' "$RC" | grep -v 'json_out()' | grep '\$' | wc -l | tr -d ' ')
if [[ "$unsafe_count" -eq 0 ]]; then
  pass "No json_out calls with variable interpolation"
else
  fail "Found $unsafe_count json_out calls with variable interpolation"
fi

# --- I1: cmd_ls no phantom null entry ---
echo ""
echo "=== I1: cmd_ls no phantom null when empty ==="
# When docker ps returns nothing, should get empty array not [{name:null}]
ls_output=$("$RC" --output json ls 2>/dev/null) || true
null_check=$(echo "$ls_output" | jq '[.[] | select(.name == null)] | length' 2>/dev/null || echo "unknown")
if [[ "$null_check" == "0" ]]; then
  pass "cmd_ls has no null entries"
else
  fail "cmd_ls has null entries. Got: $ls_output"
fi

# --- I2: Empty volumes_removed check ---
# This requires a running container to test fully, but we verify the code pattern
echo ""
echo "=== I2: volumes_removed empty array handling ==="
# Verify the code uses select(length > 0) pattern
if grep -q 'select(length > 0)' "$RC"; then
  pass "volumes_removed uses select(length > 0) filter"
else
  fail "volumes_removed missing select(length > 0) filter"
fi

# --- I3: No duplicate --dry-run/--output in cmd_up ---
echo ""
echo "=== I3: No duplicate --dry-run/--output in cmd_up ==="
# Extract the cmd_up function and check its local case statement
# The cmd_up while loop should not contain --dry-run or --output cases
in_cmd_up=false
dup_found=false
while IFS= read -r line; do
  if [[ "$line" =~ ^cmd_up\(\) ]]; then
    in_cmd_up=true
  elif [[ "$in_cmd_up" == true ]] && [[ "$line" =~ ^cmd_ ]] && [[ ! "$line" =~ ^cmd_up ]]; then
    break
  elif [[ "$in_cmd_up" == true ]]; then
    if [[ "$line" =~ "--dry-run)" ]] || [[ "$line" =~ "--output)" ]]; then
      dup_found=true
    fi
  fi
done < "$RC"
if [[ "$dup_found" == false ]]; then
  pass "cmd_up does not have duplicate --dry-run/--output parsing"
else
  fail "cmd_up still has duplicate --dry-run or --output parsing"
fi

# --- I4: cmd_down distinguishes not-found from already-stopped ---
echo ""
echo "=== I4: cmd_down distinguishes not-found vs not-running ==="
# Test with a container name that definitely doesn't exist
down_err=$("$RC" --output json down nonexistent-container-xyz123 2>/dev/null) || true
if echo "$down_err" | jq -e '.code == "CONTAINER_NOT_FOUND"' >/dev/null 2>&1; then
  pass "cmd_down returns CONTAINER_NOT_FOUND for missing container"
else
  fail "cmd_down did not return CONTAINER_NOT_FOUND. Got: $down_err"
fi

# --- Syntax check ---
echo ""
echo "=== Syntax check ==="
if bash -n "$RC" 2>&1; then
  pass "rc is valid bash"
else
  fail "rc has syntax errors"
fi

echo ""
echo "=== Results: $PASSES passed, $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]] || exit 1
