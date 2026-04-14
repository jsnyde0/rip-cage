#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="$SCRIPT_DIR/rc"

# Create isolated temp project directory
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/test-project"
echo "test" > "$TEST_DIR/test-project/README.md"
export RC_ALLOWED_ROOTS="$TEST_DIR"

# Track container name for cleanup
CONTAINER_NAME=""

cleanup() {
  if [[ -n "$CONTAINER_NAME" ]]; then
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker volume rm "rc-state-$CONTAINER_NAME" "rc-history-$CONTAINER_NAME" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

check() {
  local desc="$1" result="$2" expected="$3"
  echo -n "Test: $desc... "
  if echo "$result" | grep -qE "$expected"; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL (expected: $expected)"; echo "  Got: $result"; FAIL=$((FAIL + 1))
  fi
}

check_exit() {
  local desc="$1" exit_code="$2" expected_code="$3"
  echo -n "Test: $desc... "
  if [[ "$exit_code" -eq "$expected_code" ]]; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL (expected exit $expected_code, got $exit_code)"; FAIL=$((FAIL + 1))
  fi
}

echo "=== Agent-Friendly CLI Integration Tests ==="
echo "Test dir: $TEST_DIR"
echo ""

# --- JSON Output Tests ---

echo "-- JSON output --"

# Test 1: rc --output json ls returns valid JSON array
# Note: global flags (--output, --dry-run) must precede the subcommand
RESULT=$($RC --output json ls 2>/dev/null)
TYPE=$(echo "$RESULT" | jq -r type 2>/dev/null || echo "invalid")
check "rc ls --output json returns array" "$TYPE" "array"

# Test 2: rc ls without flag returns table (not JSON)
RESULT=$($RC ls 2>/dev/null || true)
if echo "$RESULT" | jq . >/dev/null 2>&1; then
  echo "Test: rc ls without flag is NOT json... FAIL (output was valid JSON)"
  FAIL=$((FAIL + 1))
else
  echo "Test: rc ls without flag is NOT json... PASS"
  PASS=$((PASS + 1))
fi

# Test 3: rc --output json build
RESULT=$($RC --output json build 2>/dev/null)
STATUS=$(echo "$RESULT" | jq -r .status 2>/dev/null || echo "invalid")
check "rc build --output json has status=success" "$STATUS" "success"

# --- Dry-Run Tests ---

echo ""
echo "-- Dry-run --"

# Test 4: rc up --dry-run (human)
# Note: global flags (--dry-run) must precede the subcommand
RESULT=$($RC --dry-run up "$TEST_DIR/test-project" 2>&1)
check "rc up --dry-run shows Would" "$RESULT" "Would"

# Test 5: rc up --dry-run --output json
RESULT=$($RC --dry-run --output json up "$TEST_DIR/test-project" 2>/dev/null)
DRY=$(echo "$RESULT" | jq -r .dry_run 2>/dev/null || echo "missing")
check "rc up --dry-run --output json has dry_run=true" "$DRY" "true"

ACTION=$(echo "$RESULT" | jq -r .action 2>/dev/null || echo "missing")
check "rc up --dry-run action starts with would_" "$ACTION" "would_"

# --- Input Hardening Tests ---

echo ""
echo "-- Input hardening --"

# Test 6: Blocked path
set +e
RESULT=$($RC --output json up /etc 2>&1)
EXIT_CODE=$?
set -e
check "blocked path returns PATH_INVALID" "$RESULT" "PATH_INVALID"
check_exit "blocked path exits non-zero" "$EXIT_CODE" 1

# Test 7: Missing RC_ALLOWED_ROOTS (non-TTY: warns and continues)
set +e
RESULT=$(RC_CONFIG=/dev/null env -u RC_ALLOWED_ROOTS $RC up "$TEST_DIR/test-project" 2>&1)
EXIT_CODE=$?
set -e
check "missing RC_ALLOWED_ROOTS mentions env var" "$RESULT" "RC_ALLOWED_ROOTS"

# --- Full Lifecycle Test ---

echo ""
echo "-- Full container lifecycle --"

# Test 8: rc up --output json (create)
RESULT=$($RC --output json up "$TEST_DIR/test-project" 2>/dev/null)
CONTAINER_NAME=$(echo "$RESULT" | jq -r .name 2>/dev/null || echo "")
ACTION=$(echo "$RESULT" | jq -r .action 2>/dev/null || echo "")
check "rc up creates container (action=created)" "$ACTION" "created"

if [[ -n "$CONTAINER_NAME" ]]; then
  # Test 9: rc --output json ls shows the container
  RESULT=$($RC --output json ls 2>/dev/null)
  FOUND=$(echo "$RESULT" | jq -r ".[].name" 2>/dev/null | grep -c "$CONTAINER_NAME" || echo "0")
  check "rc ls shows created container" "$FOUND" "1"

  # Test 10: rc --output json test
  RESULT=$($RC --output json test "$CONTAINER_NAME" 2>/dev/null)
  OVERALL=$(echo "$RESULT" | jq -r .overall 2>/dev/null || echo "missing")
  check "rc test --output json returns overall field" "$OVERALL" "^(pass|fail)$"

  # Test 11: rc --output json down
  RESULT=$($RC --output json down "$CONTAINER_NAME" 2>/dev/null)
  ACTION=$(echo "$RESULT" | jq -r .action 2>/dev/null || echo "")
  check "rc down stops container (action=stopped)" "$ACTION" "stopped"

  # Test 12: rc --output json --dry-run destroy (container is stopped but still exists)
  RESULT=$($RC --output json --dry-run destroy "$CONTAINER_NAME" 2>/dev/null)
  DRY=$(echo "$RESULT" | jq -r .dry_run 2>/dev/null || echo "missing")
  check "rc destroy --dry-run has dry_run=true" "$DRY" "true"

  # Verify container still exists after dry-run (dry-run must not remove anything)
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "Test: container still exists after destroy --dry-run... PASS"; PASS=$((PASS + 1))
  else
    echo "Test: container still exists after destroy --dry-run... FAIL (container was removed!)"; FAIL=$((FAIL + 1))
  fi

  # Test 13: rc destroy --output json (actual destroy)
  # Save the name before clearing CONTAINER_NAME for cleanup safety
  DESTROYED_NAME="$CONTAINER_NAME"
  RESULT=$($RC --output json destroy "$CONTAINER_NAME" 2>/dev/null)
  ACTION=$(echo "$RESULT" | jq -r .action 2>/dev/null || echo "")
  check "rc destroy removes container (action=destroyed)" "$ACTION" "destroyed"
  CONTAINER_NAME=""  # Clear so cleanup trap doesn't try again

  # Test 14: rc --output json ls no longer shows the destroyed container
  RESULT=$($RC --output json ls 2>/dev/null)
  FOUND=$(echo "$RESULT" | jq -r ".[].name" 2>/dev/null | grep -c "$DESTROYED_NAME" || echo "0")
  check "destroyed container no longer in rc ls" "$FOUND" "^0$"
else
  echo "SKIPPING lifecycle tests: rc up did not return a container name"
  FAIL=$((FAIL + 7))
fi

# --- Agent Context Test ---

echo ""
echo "-- Agent context --"

# Test 15: AGENTS.md has rc invocation rules
if grep -q "Rules for AI agents calling rc" "$SCRIPT_DIR/AGENTS.md"; then
  echo "Test: AGENTS.md has agent rules section... PASS"; PASS=$((PASS + 1))
else
  echo "Test: AGENTS.md has agent rules section... FAIL"; FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
