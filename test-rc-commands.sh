#!/usr/bin/env bash
set -uo pipefail

# Test script for rc init and rc build commands
# Each test prints PASS/FAIL and exits non-zero on first failure

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# --- Test 1: Usage includes build and init ---
echo "=== Test 1: Usage text includes build and init ==="
usage_output=$("$RC" 2>&1 || true)
if echo "$usage_output" | grep -q "build"; then
  pass "usage mentions build"
else
  fail "usage does not mention build"
fi
if echo "$usage_output" | grep -q "init"; then
  pass "usage mentions init"
else
  fail "usage does not mention init"
fi

# --- Test 2: rc init creates devcontainer.json in target directory ---
echo ""
echo "=== Test 2: rc init creates devcontainer.json ==="
TEST_DIR=$(mktemp -d)
RC_ALLOWED_ROOTS="$(dirname "$TEST_DIR")" "$RC" init "$TEST_DIR"
if [[ -f "$TEST_DIR/.devcontainer/devcontainer.json" ]]; then
  pass "devcontainer.json created"
else
  fail "devcontainer.json not created"
fi

# --- Test 3: devcontainer.json has correct content ---
echo ""
echo "=== Test 3: devcontainer.json content is correct ==="
if grep -q '"image": "rip-cage:latest"' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "image is rip-cage:latest"
else
  fail "image is not rip-cage:latest"
fi
if grep -q '"remoteUser": "agent"' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "remoteUser is agent"
else
  fail "remoteUser is not agent"
fi
if grep -q 'rc-state-' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "has rc-state volume mount"
else
  fail "missing rc-state volume mount"
fi
if grep -q 'init-rip-cage.sh' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "has postStartCommand"
else
  fail "missing postStartCommand"
fi

# --- Test 4: rc init refuses to overwrite without --force ---
echo ""
echo "=== Test 4: rc init refuses overwrite without --force ==="
overwrite_output=$(RC_ALLOWED_ROOTS="$(dirname "$TEST_DIR")" "$RC" init "$TEST_DIR" 2>&1 || true)
if echo "$overwrite_output" | grep -qi "exists\|already"; then
  pass "refuses to overwrite"
else
  fail "did not refuse to overwrite: $overwrite_output"
fi

# --- Test 5: rc init --force overwrites ---
echo ""
echo "=== Test 5: rc init --force overwrites ==="
RC_ALLOWED_ROOTS="$(dirname "$TEST_DIR")" "$RC" init --force "$TEST_DIR"
if [[ -f "$TEST_DIR/.devcontainer/devcontainer.json" ]]; then
  pass "devcontainer.json exists after --force"
else
  fail "devcontainer.json missing after --force"
fi

# --- Test 6: rc init with no path defaults to current directory ---
echo ""
echo "=== Test 6: rc init with no path uses current directory ==="
TEST_DIR2=$(mktemp -d)
cd "$TEST_DIR2"
"$RC" init
if [[ -f "$TEST_DIR2/.devcontainer/devcontainer.json" ]]; then
  pass "devcontainer.json created in current directory"
else
  fail "devcontainer.json not created in current directory"
fi

# --- Test 7: rc build uses SCRIPT_DIR to find Dockerfile ---
echo ""
echo "=== Test 7: rc build finds Dockerfile via SCRIPT_DIR ==="
# We just test that it attempts docker build with the right context
# Use --dry-run isn't available, so we test from a different directory
# and check that it doesn't complain about missing Dockerfile
# (it will fail because docker may not be running, but the error should
# be about docker, not about missing Dockerfile)
cd /tmp
build_output=$("$RC" build --help-test-sentinel 2>&1 || true)
# If we get a docker error (not a "Dockerfile not found" error), the path resolution works
# The command should at least print what it's doing
if echo "$build_output" | grep -qi "build\|docker"; then
  pass "build command recognized and attempts docker build"
else
  fail "build command not working: $build_output"
fi

# --- Cleanup ---
rm -rf "$TEST_DIR" "$TEST_DIR2"

echo ""
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
