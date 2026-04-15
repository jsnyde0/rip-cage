#!/usr/bin/env bash
set -uo pipefail

# Integration tests for `rc auth refresh`
# Covers: Linux no-op path, JSON mode, macOS failure mock, helper extraction

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Helper: run rc with the /.dockerenv guard bypassed (for testing inside containers)
run_rc() {
  local rc_script
  rc_script=$(sed 's|if \[\[ -f /\.dockerenv \]\]|if false|' "$RC")
  echo "$rc_script" | bash -s -- "$@"
}

# --- Test 1: usage includes auth refresh ---
echo "=== Test 1: usage includes auth refresh ==="
usage_output=$(run_rc 2>&1 || true)
if echo "$usage_output" | grep -q "auth refresh"; then
  pass "usage mentions auth refresh"
else
  fail "usage does not mention auth refresh"
fi

# --- Test 2: rc auth refresh exits 0 on Linux (no-op path) ---
echo ""
echo "=== Test 2: rc auth refresh exits 0 on Linux ==="
if [[ "$(uname)" != "Darwin" ]]; then
  auth_output=$(run_rc auth refresh 2>&1)
  auth_exit=$?
  if [[ $auth_exit -eq 0 ]]; then
    pass "rc auth refresh exits 0 on Linux"
  else
    fail "rc auth refresh exited $auth_exit on Linux (expected 0)"
  fi
  # Verify the output message
  if echo "$auth_output" | grep -q "On Linux"; then
    pass "rc auth refresh prints Linux no-op message"
  else
    fail "rc auth refresh did not print Linux no-op message: $auth_output"
  fi
else
  echo "SKIP: not on Linux"
fi

# --- Test 3: rc auth refresh --output json on Linux emits correct JSON ---
echo ""
echo "=== Test 3: rc auth refresh --output json on Linux ==="
if [[ "$(uname)" != "Darwin" ]]; then
  json_output=$(run_rc --output json auth refresh 2>/dev/null)
  json_exit=$?
  if [[ $json_exit -eq 0 ]]; then
    pass "rc auth refresh --output json exits 0 on Linux"
  else
    fail "rc auth refresh --output json exited $json_exit on Linux (expected 0)"
  fi
  # Validate JSON structure
  if echo "$json_output" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    pass "JSON output has status ok"
  else
    fail "JSON output missing status ok: $json_output"
  fi
  if echo "$json_output" | jq -e '.action == "no_op"' >/dev/null 2>&1; then
    pass "JSON output has action no_op"
  else
    fail "JSON output missing action no_op: $json_output"
  fi
  if echo "$json_output" | jq -e '.message' >/dev/null 2>&1; then
    pass "JSON output has message field"
  else
    fail "JSON output missing message field: $json_output"
  fi
else
  echo "SKIP: not on Linux"
fi

# --- Test 4: _extract_credentials returns 0 on Linux (no-op) ---
echo ""
echo "=== Test 4: _extract_credentials returns 0 on Linux ==="
if [[ "$(uname)" != "Darwin" ]]; then
  # Source the helper and call it directly
  extract_exit=0
  bash -c '
    # Source just the function from rc (bypass the dockerenv guard and main dispatch)
    eval "$(sed -n "/_extract_credentials()/,/^}/p" "'"$RC"'")"
    _extract_credentials
  ' 2>/dev/null
  extract_exit=$?
  if [[ $extract_exit -eq 0 ]]; then
    pass "_extract_credentials returns 0 on Linux"
  else
    fail "_extract_credentials returned $extract_exit on Linux (expected 0)"
  fi
else
  echo "SKIP: not on Linux"
fi

# --- Test 5: macOS failure path with mocked security command ---
echo ""
echo "=== Test 5: macOS failure path (mocked security command) ==="
# Simulate macOS by overriding uname and providing a failing security command
MOCK_DIR=$(mktemp -d)
cat > "$MOCK_DIR/uname" <<'MOCK'
#!/usr/bin/env bash
echo "Darwin"
MOCK
chmod +x "$MOCK_DIR/uname"
cat > "$MOCK_DIR/security" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$MOCK_DIR/security"

# Create a temp HOME so we don't clobber real credentials
MOCK_HOME=$(mktemp -d)
mkdir -p "$MOCK_HOME/.claude"

# Run _extract_credentials with mocked commands
extract_mac_exit=0
PATH="$MOCK_DIR:$PATH" HOME="$MOCK_HOME" bash -c '
  eval "$(sed -n "/_extract_credentials()/,/^}/p" "'"$RC"'")"
  _extract_credentials
' 2>/dev/null
extract_mac_exit=$?
if [[ $extract_mac_exit -ne 0 ]]; then
  pass "_extract_credentials returns non-zero on macOS keychain failure"
else
  fail "_extract_credentials returned 0 on macOS keychain failure (expected non-zero)"
fi

# --- Test 6: macOS JSON failure path emits correct error ---
echo ""
echo "=== Test 6: macOS JSON failure path (mocked) ==="
# Build a minimal script that simulates the cmd_auth_refresh JSON failure path
json_fail_output=$(PATH="$MOCK_DIR:$PATH" HOME="$MOCK_HOME" bash -c '
  OUTPUT_FORMAT="json"
  json_error() {
    local msg="$1" code="$2"
    jq -nc --arg error "$msg" --arg code "$code" "{error: \$error, code: \$code}"
    exit 1
  }
  log() {
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo "$@" >&2
    else
      echo "$@"
    fi
  }
  eval "$(sed -n "/_extract_credentials()/,/^}/p" "'"$RC"'")"
  eval "$(sed -n "/^cmd_auth_refresh()/,/^}/p" "'"$RC"'")"
  cmd_auth_refresh
' 2>/dev/null) || true

if echo "$json_fail_output" | jq -e '.code == "KEYCHAIN_EXTRACTION_FAILED"' >/dev/null 2>&1; then
  pass "macOS JSON failure emits KEYCHAIN_EXTRACTION_FAILED code"
else
  fail "macOS JSON failure did not emit correct error code: $json_fail_output"
fi
if echo "$json_fail_output" | jq -e '.error' >/dev/null 2>&1; then
  pass "macOS JSON failure has error message"
else
  fail "macOS JSON failure missing error message: $json_fail_output"
fi

# --- Test 7: macOS success path with mocked security command ---
echo ""
echo "=== Test 7: macOS success path (mocked security command) ==="
MOCK_SUCCESS_DIR=$(mktemp -d)
cat > "$MOCK_SUCCESS_DIR/uname" <<'MOCK'
#!/usr/bin/env bash
echo "Darwin"
MOCK
chmod +x "$MOCK_SUCCESS_DIR/uname"
cat > "$MOCK_SUCCESS_DIR/security" <<'MOCK'
#!/usr/bin/env bash
# Simulate keychain returning a JSON credential blob
echo '{"access_token":"mock-token","expires_at":"2099-01-01T00:00:00Z"}'
MOCK
chmod +x "$MOCK_SUCCESS_DIR/security"

MOCK_HOME2=$(mktemp -d)
mkdir -p "$MOCK_HOME2/.claude"

extract_success_exit=0
PATH="$MOCK_SUCCESS_DIR:$PATH" HOME="$MOCK_HOME2" bash -c '
  eval "$(sed -n "/_extract_credentials()/,/^}/p" "'"$RC"'")"
  _extract_credentials
' 2>/dev/null
extract_success_exit=$?
if [[ $extract_success_exit -eq 0 ]]; then
  pass "_extract_credentials returns 0 on macOS keychain success"
else
  fail "_extract_credentials returned $extract_success_exit on macOS keychain success (expected 0)"
fi
# Verify the credentials file was written
if [[ -f "$MOCK_HOME2/.claude/.credentials.json" ]]; then
  pass "credentials file written on macOS success"
else
  fail "credentials file not written on macOS success"
fi

# --- Test 8: macOS JSON success path ---
echo ""
echo "=== Test 8: macOS JSON success path (mocked) ==="
MOCK_HOME3=$(mktemp -d)
mkdir -p "$MOCK_HOME3/.claude"

json_success_output=$(PATH="$MOCK_SUCCESS_DIR:$PATH" HOME="$MOCK_HOME3" bash -c '
  OUTPUT_FORMAT="json"
  json_error() {
    local msg="$1" code="$2"
    jq -nc --arg error "$msg" --arg code "$code" "{error: \$error, code: \$code}"
    exit 1
  }
  log() {
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo "$@" >&2
    else
      echo "$@"
    fi
  }
  eval "$(sed -n "/_extract_credentials()/,/^}/p" "'"$RC"'")"
  eval "$(sed -n "/^cmd_auth_refresh()/,/^}/p" "'"$RC"'")"
  cmd_auth_refresh
' 2>/dev/null) || true

if echo "$json_success_output" | jq -e '.status == "ok"' >/dev/null 2>&1; then
  pass "macOS JSON success has status ok"
else
  fail "macOS JSON success missing status ok: $json_success_output"
fi
if echo "$json_success_output" | jq -e '.action == "credentials_refreshed"' >/dev/null 2>&1; then
  pass "macOS JSON success has action credentials_refreshed"
else
  fail "macOS JSON success missing action credentials_refreshed: $json_success_output"
fi
if echo "$json_success_output" | jq -e '.credentials_updated == true' >/dev/null 2>&1; then
  pass "macOS JSON success has credentials_updated true"
else
  fail "macOS JSON success missing credentials_updated: $json_success_output"
fi

# --- Test 9: auth dispatch is in main case statement ---
echo ""
echo "=== Test 9: auth dispatch exists in rc script ==="
if grep -q 'auth).*cmd_auth ' "$RC"; then
  pass "auth dispatch found in rc"
else
  fail "auth dispatch not found in rc"
fi

# --- Test 10: _up_prepare_docker_mounts calls _extract_credentials ---
echo ""
echo "=== Test 10: _up_prepare_docker_mounts calls _extract_credentials ==="
if grep -q '_extract_credentials' "$RC"; then
  # Verify it's called inside _up_prepare_docker_mounts (check between function start and next function)
  if sed -n '/_up_prepare_docker_mounts()/,/^[a-z_]*().*{/p' "$RC" | grep -q '_extract_credentials'; then
    pass "_up_prepare_docker_mounts calls _extract_credentials"
  else
    fail "_up_prepare_docker_mounts does not call _extract_credentials"
  fi
else
  fail "_extract_credentials not found in rc at all"
fi

# --- Test 11: auth does not require Docker ---
echo ""
echo "=== Test 11: auth does not require Docker ==="
# The docker check list should NOT include auth
docker_check_line=$(grep 'check_docker' "$RC" | grep 'case')
if echo "$docker_check_line" | grep -q 'auth'; then
  fail "auth is in the Docker prerequisite check (should not require Docker)"
else
  pass "auth does not require Docker"
fi

# --- Cleanup ---
rm -rf "$MOCK_DIR" "$MOCK_HOME" "$MOCK_SUCCESS_DIR" "$MOCK_HOME2" "$MOCK_HOME3"

echo ""
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
