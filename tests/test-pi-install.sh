#!/usr/bin/env bash
set -uo pipefail

# Test that pi-coding-agent is installed in the rip-cage:latest image
# and that /pi-agent mount point is pre-created with agent:agent ownership.

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

IMAGE="rip-cage:latest"

# -----------------------------------------------
# Test 1: pi binary is installed and --version exits 0
# -----------------------------------------------
echo ""
echo "=== Test 1: pi --version exits 0 ==="

if output=$(docker run --rm "$IMAGE" pi --version 2>&1); then
  pass "pi --version exits 0"
else
  fail "pi --version should exit 0" "$output"
fi

# -----------------------------------------------
# Test 2: pi --version output contains a semver
# -----------------------------------------------
echo ""
echo "=== Test 2: pi --version output contains semver ==="

output=$(docker run --rm "$IMAGE" pi --version 2>&1 || true)
if echo "$output" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
  pass "pi --version output contains semver: $output"
else
  fail "pi --version output should contain semver matching [0-9]+.[0-9]+.[0-9]+" "$output"
fi

# -----------------------------------------------
# Test 3: /pi-agent is owned by agent:agent
# -----------------------------------------------
echo ""
echo "=== Test 3: /pi-agent owned by agent:agent ==="

ownership=$(docker run --rm "$IMAGE" stat -c '%U:%G' /pi-agent 2>&1 || true)
if [[ "$ownership" == "agent:agent" ]]; then
  pass "/pi-agent ownership is agent:agent"
else
  fail "/pi-agent should be owned by agent:agent" "$ownership"
fi

# -----------------------------------------------
# Summary
# -----------------------------------------------
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All pi-install tests passed."
else
  echo "$FAILURES test(s) FAILED."
  exit 1
fi
