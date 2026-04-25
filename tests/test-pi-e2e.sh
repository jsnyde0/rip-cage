#!/usr/bin/env bash
# test-pi-e2e.sh - end-to-end pi -p smoke test inside rip-cage
# Requires: real ~/.pi/agent/auth.json on host with valid credentials
# Skips gracefully when pi auth is absent (safe in CI with no pi creds)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TEST_WS=""
CONTAINER=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; FAILURES=$((FAILURES + 1)); }

_resolve_container() {
  docker ps -a \
    --filter "label=rc.source.path=$(realpath "$TEST_WS")" \
    --format '{{.Names}}' | head -1
}

cleanup() {
  if [[ -n "$CONTAINER" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "rc-state-${CONTAINER}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEST_WS" ]]; then
    rm -rf "$TEST_WS"
  fi
}
trap cleanup EXIT

# Step 1: Skip if rip-cage image not built
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "[skip] rip-cage:latest not built — run ./rc build first"
  exit 0
fi

# Step 1b: Skip if no host auth.json
if [[ ! -f "${HOME}/.pi/agent/auth.json" ]]; then
  echo "[skip] no pi auth on host; run 'pi /login' first"
  exit 0
fi

# Step 2: Create temp project and start container
TEST_WS=$(mktemp -d)
echo "# pi e2e test" > "$TEST_WS/README"
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" \
  </dev/null >/dev/null 2>&1 || true
CONTAINER=$(_resolve_container)
if [[ -z "$CONTAINER" ]]; then
  fail "container did not come up"
  exit $FAILURES
fi

# Step 3: Run pi -p with 30s timeout
_output=$(docker exec "$CONTAINER" timeout 30 pi -p \
  'Reply with the literal string PI_E2E_OK and nothing else' \
  2>&1 || true)

# Step 4: Assert output contains PI_E2E_OK
if echo "$_output" | grep -q 'PI_E2E_OK'; then
  pass "pi -p smoke test: PI_E2E_OK received"
else
  fail "pi -p smoke test: PI_E2E_OK not in output" "$_output"
fi

exit $FAILURES
