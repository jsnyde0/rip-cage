#!/usr/bin/env bash
set -uo pipefail

# Tests for bead dg6.2: --dry-run, input hardening, agent context
# These tests validate behavior WITHOUT requiring Docker containers.

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

# =============================================
# Part B: Input hardening (validate_path)
# =============================================

# --- Test 2: validate_path rejects when RC_ALLOWED_ROOTS is unset ---
echo ""
echo "=== Test 2: rc up fails when RC_ALLOWED_ROOTS is unset ==="
test_dir=$(mktemp -d)
unset RC_ALLOWED_ROOTS 2>/dev/null || true
up_err=$(env -u RC_ALLOWED_ROOTS "$RC" up "$test_dir" 2>&1) || true
if echo "$up_err" | grep -q "RC_ALLOWED_ROOTS"; then
  pass "rc up fails with RC_ALLOWED_ROOTS error when unset"
else
  fail "rc up did not mention RC_ALLOWED_ROOTS. Got: $up_err"
fi

# --- Test 3: validate_path rejects path outside allowed roots ---
echo ""
echo "=== Test 3: rc up rejects path outside allowed roots ==="
outside_err=$(RC_ALLOWED_ROOTS="$test_dir" "$RC" up /tmp 2>&1) || true
if echo "$outside_err" | grep -q "outside allowed roots"; then
  pass "rc up rejects path outside allowed roots"
else
  fail "rc up did not reject outside path. Got: $outside_err"
fi

# --- Test 4: validate_path rejects path prefix attack ---
echo ""
echo "=== Test 4: rc up rejects path prefix attack ==="
# Create /tmp/code and /tmp/code-evil to test prefix matching
code_dir=$(mktemp -d -t code)
evil_dir="${code_dir}-evil"
mkdir -p "$evil_dir"
prefix_err=$(RC_ALLOWED_ROOTS="$code_dir" "$RC" up "$evil_dir" 2>&1) || true
if echo "$prefix_err" | grep -q "outside allowed roots"; then
  pass "rc up rejects prefix attack (code-evil vs code)"
else
  fail "rc up did not reject prefix attack. Got: $prefix_err"
fi
rmdir "$evil_dir" 2>/dev/null || true
rmdir "$code_dir" 2>/dev/null || true

# --- Test 5: validate_path rejects non-existent path ---
echo ""
echo "=== Test 5: rc up rejects non-existent path ==="
nonexist_err=$(RC_ALLOWED_ROOTS=/tmp "$RC" up /tmp/does-not-exist-xyz123 2>&1) || true
if echo "$nonexist_err" | grep -q "does not exist"; then
  pass "rc up rejects non-existent path"
else
  fail "rc up did not reject non-existent path. Got: $nonexist_err"
fi

# --- Test 6: validate_path rejects non-directory (file) ---
echo ""
echo "=== Test 6: rc up rejects non-directory path ==="
temp_file=$(mktemp)
file_err=$(RC_ALLOWED_ROOTS=/tmp "$RC" up "$temp_file" 2>&1) || true
if echo "$file_err" | grep -q "not a directory"; then
  pass "rc up rejects non-directory path"
else
  fail "rc up did not reject non-directory path. Got: $file_err"
fi
rm -f "$temp_file"

# --- Test 7: validate_path rejects control characters ---
echo ""
echo "=== Test 7: rc up rejects control characters in path ==="
# Use printf to embed a control char in the argument
ctrl_err=$(RC_ALLOWED_ROOTS=/tmp "$RC" up $'/tmp/bad\x01dir' 2>&1) || true
if echo "$ctrl_err" | grep -q "control characters"; then
  pass "rc up rejects control characters"
else
  fail "rc up did not reject control characters. Got: $ctrl_err"
fi

# --- Test 8: validate_path accepts valid path under allowed root ---
echo ""
echo "=== Test 8: rc up accepts valid path under allowed root (fails later at Docker) ==="
# This should pass validation and fail at Docker check
valid_err=$(RC_ALLOWED_ROOTS="$(dirname "$test_dir")" "$RC" up "$test_dir" 2>&1) || true
# Should NOT contain path validation errors
if echo "$valid_err" | grep -q "outside allowed roots\|RC_ALLOWED_ROOTS not set\|does not exist\|not a directory\|control characters"; then
  fail "rc up rejected valid path. Got: $valid_err"
else
  pass "rc up accepted valid path (failed at Docker check as expected)"
fi

# --- Test 9: validate_path JSON error output ---
echo ""
echo "=== Test 9: rc up --output json produces JSON error for invalid path ==="
# json_error writes to stdout; human errors go to stderr. Capture both.
json_err=$(RC_ALLOWED_ROOTS="$test_dir" "$RC" --output json up /tmp 2>/dev/null) || true
if echo "$json_err" | jq -e '.code == "PATH_INVALID"' >/dev/null 2>&1; then
  pass "--output json produces PATH_INVALID error code"
else
  fail "--output json did not produce PATH_INVALID. Got: $json_err"
fi

# =============================================
# Part A: --dry-run
# =============================================

# --- Test 10: rc up --dry-run does not create container ---
echo ""
echo "=== Test 10: rc up --dry-run prints what would happen ==="
dryrun_dir=$(mktemp -d)
dryrun_out=$(RC_ALLOWED_ROOTS="$(dirname "$dryrun_dir")" "$RC" --dry-run up "$dryrun_dir" 2>&1) || true
if echo "$dryrun_out" | grep -q "Would create\|would_create"; then
  pass "--dry-run reports what would happen"
else
  fail "--dry-run did not report action. Got: $dryrun_out"
fi
rmdir "$dryrun_dir" 2>/dev/null || true

# --- Test 11: rc up --dry-run --output json produces dry_run JSON ---
echo ""
echo "=== Test 11: rc up --dry-run --output json produces JSON ==="
dryrun_dir2=$(mktemp -d)
dryrun_json=$(RC_ALLOWED_ROOTS="$(dirname "$dryrun_dir2")" "$RC" --dry-run --output json up "$dryrun_dir2" 2>/dev/null) || true
if echo "$dryrun_json" | jq -e '.dry_run == true and .action == "would_create"' >/dev/null 2>&1; then
  pass "--dry-run --output json produces correct JSON"
else
  fail "--dry-run --output json incorrect. Got: $dryrun_json"
fi
rmdir "$dryrun_dir2" 2>/dev/null || true

# --- Test 12: rc destroy --dry-run with non-existent container fails ---
echo ""
echo "=== Test 12: rc destroy --dry-run with non-existent container errors ==="
destroy_err=$(RC_ALLOWED_ROOTS=/tmp "$RC" --dry-run destroy nonexistent-container-xyz 2>&1) || true
if echo "$destroy_err" | grep -qi "not found\|error"; then
  pass "--dry-run destroy errors on non-existent container"
else
  fail "--dry-run destroy did not error on non-existent. Got: $destroy_err"
fi

# =============================================
# Part C: Agent context in AGENTS.md
# =============================================

# --- Test 13: AGENTS.md contains agent rules section ---
echo ""
echo "=== Test 13: AGENTS.md contains rc invocation rules ==="
if grep -q "Rules for AI agents calling rc" "${SCRIPT_DIR}/AGENTS.md"; then
  pass "AGENTS.md has agent rules section"
else
  fail "AGENTS.md missing agent rules section"
fi

# --- Test 14: AGENTS.md mentions --output json ---
echo ""
echo "=== Test 14: AGENTS.md mentions --output json ==="
if grep -q "\-\-output json" "${SCRIPT_DIR}/AGENTS.md"; then
  pass "AGENTS.md mentions --output json"
else
  fail "AGENTS.md does not mention --output json"
fi

# --- Test 15: AGENTS.md mentions RC_ALLOWED_ROOTS ---
echo ""
echo "=== Test 15: AGENTS.md mentions RC_ALLOWED_ROOTS ==="
if grep -q "RC_ALLOWED_ROOTS" "${SCRIPT_DIR}/AGENTS.md"; then
  pass "AGENTS.md mentions RC_ALLOWED_ROOTS"
else
  fail "AGENTS.md does not mention RC_ALLOWED_ROOTS"
fi

# --- Test 16: cmd_init validates explicit paths ---
echo ""
echo "=== Test 16: rc init validates explicit path ==="
init_err=$(RC_ALLOWED_ROOTS="$test_dir" "$RC" init /tmp 2>&1) || true
if echo "$init_err" | grep -q "outside allowed roots"; then
  pass "rc init validates explicit path"
else
  fail "rc init did not validate path. Got: $init_err"
fi

# --- Cleanup ---
rmdir "$test_dir" 2>/dev/null || true

echo ""
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
