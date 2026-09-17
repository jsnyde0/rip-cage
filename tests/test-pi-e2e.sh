#!/usr/bin/env bash
# test-pi-e2e.sh - end-to-end pi -p smoke test inside rip-cage
# Requires: real ~/.pi/agent/auth.json on host with valid credentials
# Skips gracefully when pi auth is absent (safe in CI with no pi creds)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TEST_WS=""
CREATED_CAGES=()

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; FAILURES=$((FAILURES + 1)); }

# shellcheck source=tests/_cage-lookup-lib.sh
source "${SCRIPT_DIR}/_cage-lookup-lib.sh"

_track() { CREATED_CAGES+=("$1"); }

_resolve_container() { cage_name_for_source "$TEST_WS"; }

cleanup() {
  local c _d_out _d_rc
  for c in "${CREATED_CAGES[@]:-}"; do
    if [[ -n "$c" ]]; then
      _d_out=$("$RC" destroy "$c" 2>&1)
      _d_rc=$?
      if [[ "$_d_rc" -ne 0 ]]; then
        echo "WARNING: failed to destroy '$c' (exit ${_d_rc}): ${_d_out}" >&2
      fi
    fi
  done
  if [[ -n "$TEST_WS" ]]; then
    rm -rf "$TEST_WS"
  fi
}
trap cleanup EXIT

# Step 1: Skip if rip-cage image not built
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest not built — run ./rc build first"
  exit 0
fi

# Step 1b: Skip if no host auth.json at all (cheap pre-check before the
# more expensive credential-usability probe below).
if [[ ! -f "${HOME}/.pi/agent/auth.json" ]]; then
  echo "SKIP: no pi auth on host (${HOME}/.pi/agent/auth.json absent); run 'pi /login' first"
  exit 0
fi

# Step 1c (rip-cage-sw6s, Defect A): file-existence is NOT the same
# precondition as "the provider pi -p will actually use has a usable
# credential" -- auth.json can exist and structurally contain a top-level
# key for a provider while that provider's OAuth token is expired/invalid,
# which surfaces at runtime as "No API key for provider: <name>" instead of
# a clean skip. `pi -p` here is invoked with no --provider/--model, so it
# resolves whatever its own implicit default is; the only concrete evidence
# of that default on this host is the observed failure naming "anthropic"
# (baseline.log:772). Preflight THAT provider's usability with `pi auth
# check`, which performs the same refresh attempt pi -p does internally, so
# a token that is present-but-invalid is caught here instead of surfacing as
# an unexplained smoke-test FAIL. --json (no --credentials) reports only
# status, never the credential value. If the host has no `pi` binary to run
# this preflight with, fall through to the old file-existence-only signal
# rather than skipping on an unverifiable precondition.
if command -v pi >/dev/null 2>&1; then
  _e2e_auth_check_json=$(pi auth check --provider anthropic --json 2>&1)
  _e2e_auth_check_rc=$?
  if [[ $_e2e_auth_check_rc -ne 0 ]]; then
    echo "SKIP: pi auth check --provider anthropic reports not usable (${_e2e_auth_check_json}); run 'pi /login' to refresh"
    exit 0
  fi
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
_track "$CONTAINER"

# Step 3: Run pi -p with 30s timeout
_output=$(msb exec "$CONTAINER" -- timeout 30 pi -p \
  'Reply with the literal string PI_E2E_OK and nothing else' \
  2>&1 || true)

# Step 4: Assert output contains PI_E2E_OK
if echo "$_output" | grep -q 'PI_E2E_OK'; then
  pass "pi -p smoke test: PI_E2E_OK received"
else
  fail "pi -p smoke test: PI_E2E_OK not in output" "$_output"
fi

exit $FAILURES
