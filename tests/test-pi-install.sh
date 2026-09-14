#!/usr/bin/env bash
set -uo pipefail

# Test that pi-coding-agent is installed in the rip-cage:latest image
# and that a RUNNING cage has /home/agent/.pi/agent pre-created with
# agent:agent ownership (ADR-019 D1 evolved: container-local cage-owned dir,
# rip-cage-hhh.12).
#
# pi was un-baked from the base image into a composable TOOL recipe
# (commits 9b67bb6, b6095b2): the bare image intentionally does NOT contain
# /home/agent/.pi/agent — it is created at cage-up time. So Tests 3/4 assert
# the up-time (running-cage) shape, not the bare-image shape. Mirrors
# test-pi-auth-mount.sh Tests 7/9, which assert the same shape against a
# running cage.

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
# Resolve a running rip-cage container for Tests 3/4 (up-time shape).
#
# SCOPING (rip-cage-sygz.2). This used to take the FIRST running cage `rc ls`
# reported — any cage on the host, including one the suite never created. Two
# ways that goes wrong, both observed 2026-09-14: a suite run killed by the OS
# low-memory reaper strands a scratch cage whose workspace is already deleted,
# and every later run of this file asserts against that corpse and fails; and
# a human's own working cage gets probed for a shape this suite never set up.
# Neither red says anything about pi.
#
# So the cage must be one we can vouch for:
#   1. RC_TEST_CONTAINER  — the operator named it explicitly.
#   2. the harness's created-cage registry (tests/_scratch-cage-lib.sh),
#      intersected with what `rc ls` reports running.
#   3. otherwise SKIP.
# A foreign running cage is never selected — it cannot reach step 2, because
# only scratch_cage_register writes that file.
# -----------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"

CONTAINER="${RC_TEST_CONTAINER:-}"
if [[ -z "$CONTAINER" ]]; then
  _registry=$(_scratch_cage_registry_path)
  if [[ -f "$_registry" ]]; then
    _running=$("$RC" ls --output json 2>/dev/null | jq -r '.[] | select(.status=="running") | .name')
    while IFS= read -r _candidate; do
      [[ -z "$_candidate" ]] && continue
      if echo "$_running" | grep -qxF "$_candidate"; then
        CONTAINER="$_candidate"
        break
      fi
    done < "$_registry"
  fi
fi

# -----------------------------------------------
# Test 3: /home/agent/.pi/agent is owned by agent:agent in a RUNNING cage
# (container-local dir, created at cage-up time — not baked into the image)
# -----------------------------------------------
echo ""
echo "=== Test 3: /home/agent/.pi/agent owned by agent:agent (running cage) ==="

if [[ -z "$CONTAINER" ]]; then
  echo "SKIP: no harness-created running cage; pass RC_TEST_CONTAINER=<name> (a foreign running cage is deliberately not used — rip-cage-sygz.2)"
else
  ownership=$("$RC" exec "$CONTAINER" -- stat -c '%U:%G' /home/agent/.pi/agent 2>&1 || true)
  if [[ "$ownership" == "agent:agent" ]]; then
    pass "/home/agent/.pi/agent ownership is agent:agent"
  else
    fail "/home/agent/.pi/agent should be owned by agent:agent" "$ownership"
  fi
fi

# -----------------------------------------------
# Test 4: /home/agent/.pi/agent/extensions dir exists in a RUNNING cage
# (agent-owned extension space; not auto-scanned post-olen)
# -----------------------------------------------
echo ""
echo "=== Test 4: /home/agent/.pi/agent/extensions exists (running cage) ==="

if [[ -z "$CONTAINER" ]]; then
  echo "SKIP: no harness-created running cage; pass RC_TEST_CONTAINER=<name> (a foreign running cage is deliberately not used — rip-cage-sygz.2)"
else
  ext_stat=$("$RC" exec "$CONTAINER" -- stat -c '%U:%G' /home/agent/.pi/agent/extensions 2>&1 || true)
  if [[ "$ext_stat" == "agent:agent" ]]; then
    pass "/home/agent/.pi/agent/extensions exists and is agent:agent"
  else
    fail "/home/agent/.pi/agent/extensions should exist and be agent:agent" "$ext_stat"
  fi
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
