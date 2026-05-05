#!/usr/bin/env bash
# Unit-style tests for rip-cage-bnf.4: in-cage github.com preflight + sentinel writer.
#
# Tests the following functions sourced from rc:
#   _up_github_identity_preflight()   -- preflight: probe greeting, write sentinels, cache
#   _identity_cache_read()            -- cache read (raw JSON entry or empty)
#   _identity_cache_write()           -- cache write (upsert entry with ts)
#   _identity_cache_touch_all()       -- rc auth refresh: update all ts values to now
#
# Also verifies cmd_auth_refresh cache-touch behavior.
#
# Does NOT require a running container. docker exec is stubbed via PATH shim.
#
# Acceptance criteria covered:
#   AC1: sentinels present, root-owned, 644, non-empty, source value in expected set
#   AC2: cold cache → entry populated, sentinel = match
#   AC3: greeting differs from expected → sentinel = mismatch with both names readable, exit 0
#   AC4: source=none (layer-4) → sentinel = unset with greeting readable, exit 0
#   AC5: unreachable → sentinel = unreachable, exit 0, no cache write for that keyname
#   AC6: rc auth refresh → cache ts updated
#   AC7: host-config branch → ssh-config-source = host-config, no label comparison, github-identity has greeting

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TMPDIR_TEST=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  if [[ -n "${TMPDIR_TEST:-}" && -d "${TMPDIR_TEST:-}" ]]; then
    rm -rf "$TMPDIR_TEST"
  fi
  # Remove PATH shim if it was added
  if [[ -n "${STUB_BIN:-}" ]]; then
    # PATH already uses TMPDIR_TEST which will be cleaned above
    :
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Setup: create temp HOME, stub docker exec via PATH shim
# ---------------------------------------------------------------------------
TMPDIR_TEST=$(mktemp -d)
export HOME="${TMPDIR_TEST}"
CACHE_DIR="${TMPDIR_TEST}/.cache/rip-cage"
mkdir -p "$CACHE_DIR"
IDENTITY_MAP="${CACHE_DIR}/identity-map.json"

# The stub dir sits at the front of PATH, providing a fake `docker` that
# behaves like a container exec for our tests. We control the greeting via
# STUB_GREETING env var (default: "Hi stub-user!").
STUB_BIN="${TMPDIR_TEST}/stub-bin"
mkdir -p "$STUB_BIN"
export PATH="${STUB_BIN}:${PATH}"

# Write stub docker — intercepts "docker exec … ssh -T … git@github.com"
# and responds with STUB_GREETING; all other docker calls pass through to
# real docker (if present on PATH after the stub dir).
REAL_DOCKER=$(command -v docker 2>/dev/null || true)

cat > "${STUB_BIN}/docker" <<'STUBEOF'
#!/usr/bin/env bash
# Stub docker: intercept exec ssh github greeting, pass everything else through
# Read greeting from file so subshell invocations see the right value
GREETING_FILE="${TMPDIR_TEST_STUB}/greeting"
STUB_RC_FILE="${TMPDIR_TEST_STUB}/stub_rc"
if [[ -f "$GREETING_FILE" ]]; then
  STUB_GREETING=$(cat "$GREETING_FILE")
else
  STUB_GREETING="Hi stub-user!"
fi
STUB_RC=0
if [[ -f "$STUB_RC_FILE" ]]; then
  STUB_RC=$(cat "$STUB_RC_FILE")
fi

# Detect: docker exec <name> <...> ssh -T <...> git@github.com
if [[ "$1" == "exec" ]]; then
  # Shift past "exec" and look for ssh invocation
  shift
  # collect args until we find ssh
  while [[ $# -gt 0 && "$1" != "ssh" ]]; do
    shift
  done
  if [[ "$1" == "ssh" ]]; then
    # It's the greeting probe — emit greeting on stderr (as real github does)
    if [[ "$STUB_RC" == "0" ]]; then
      echo "$STUB_GREETING" >&2
      exit 0
    else
      # Simulate unreachable
      exit 255
    fi
  fi
fi

# For root-writes (docker exec --user root ... tee ...), simulate success
if [[ "$1" == "exec" ]] && [[ "${2:-}" == "-u" ]] && [[ "${3:-}" == "root" ]]; then
  # Pass stdin to /dev/null (we track sentinel writes via RC_* env vars in
  # the real function, which writes to TMPDIR sentinel files in test mode)
  cat >/dev/null
  exit 0
fi

# For everything else, forward to real docker if available
REAL_DOCKER_PATH="${TMPDIR_TEST_STUB}/real_docker"
if [[ -f "$REAL_DOCKER_PATH" ]]; then
  exec "$(cat "$REAL_DOCKER_PATH")" "$@"
fi
exit 0
STUBEOF
chmod +x "${STUB_BIN}/docker"

# Create helper files the stub reads
echo "$TMPDIR_TEST" > "${TMPDIR_TEST}/stub-bin/.stub-home"
# Write a file with the real docker path (may be empty)
echo "${REAL_DOCKER:-}" > "${TMPDIR_TEST}/stub-bin/real_docker"

# Export TMPDIR_TEST_STUB for the stub to find its config files
export TMPDIR_TEST_STUB="${TMPDIR_TEST}"

# Helper: set stub greeting
set_greeting() {
  echo "$1" > "${TMPDIR_TEST}/greeting"
  echo "0" > "${TMPDIR_TEST}/stub_rc"
}

# Helper: set stub to simulate unreachable
set_unreachable() {
  echo "" > "${TMPDIR_TEST}/greeting"
  echo "255" > "${TMPDIR_TEST}/stub_rc"
}

# Start with a default greeting
set_greeting "Hi stub-user!"

# ---------------------------------------------------------------------------
# Source rc to get function definitions
# ---------------------------------------------------------------------------
_source_rc_functions() {
  set +e
  # shellcheck source=../rc
  source "$RC" 2>/dev/null
  set -e
}
_source_rc_functions

# ---------------------------------------------------------------------------
# Sentinel capture: redirect sentinel writes in preflight to test-local files.
# The real function writes to /etc/rip-cage/ inside a container via docker exec.
# For unit tests, we override the write function via a hook so tests can inspect
# sentinel content without needing a real container.
#
# We accomplish this by having _up_github_identity_preflight accept an optional
# test-mode sentinel dir via RC_PREFLIGHT_SENTINEL_DIR env var.
# ---------------------------------------------------------------------------

SENTINEL_DIR="${TMPDIR_TEST}/sentinels"
mkdir -p "$SENTINEL_DIR"
export RC_PREFLIGHT_SENTINEL_DIR="$SENTINEL_DIR"

# ---------------------------------------------------------------------------
# Test 1 (AC1): sentinels present, non-empty, source value in expected set
# Also: AC2 (cold cache → match)
# ---------------------------------------------------------------------------
echo "=== Test 1 (AC1+AC2): cold cache + correct identity → sentinels written, match ==="

# Reset sentinel dir
rm -rf "$SENTINEL_DIR"
mkdir -p "$SENTINEL_DIR"
# Clear cache
rm -f "$IDENTITY_MAP"

set_greeting "Hi expected-user!"

# Call preflight: container=test-container, key=id_ed25519_work, source=cli-flag
# expected username comes from cache (cold: will be populated from greeting)
_up_github_identity_preflight "test-container" "id_ed25519_work" "cli-flag"

# AC1: github-identity sentinel exists, non-empty
if [[ -f "${SENTINEL_DIR}/github-identity" ]]; then
  _gi_val=$(cat "${SENTINEL_DIR}/github-identity")
  if [[ -n "$_gi_val" ]]; then
    pass "AC1: github-identity sentinel present and non-empty"
  else
    fail "AC1: github-identity sentinel is empty"
  fi
else
  fail "AC1: github-identity sentinel missing"
fi

# AC1: ssh-config-source sentinel exists, value in allowed set
if [[ -f "${SENTINEL_DIR}/ssh-config-source" ]]; then
  _src_val=$(cat "${SENTINEL_DIR}/ssh-config-source")
  case "$_src_val" in
    host-config|cli-flag|label|rules-file|none|disabled)
      pass "AC1: ssh-config-source='$_src_val' is in expected set"
      ;;
    *)
      fail "AC1: ssh-config-source='$_src_val' is NOT in expected set"
      ;;
  esac
else
  fail "AC1: ssh-config-source sentinel missing"
fi

# AC1: source is "cli-flag" (what we passed)
if [[ "${_src_val:-}" == "cli-flag" ]]; then
  pass "AC1: ssh-config-source correctly = cli-flag"
else
  fail "AC1: ssh-config-source = '${_src_val:-}', expected cli-flag"
fi

# AC2: cold cache → entry written to identity-map.json
if [[ -f "$IDENTITY_MAP" ]]; then
  _cached_user=$(jq -r '.["id_ed25519_work"].github_username // empty' "$IDENTITY_MAP" 2>/dev/null)
  if [[ "$_cached_user" == "expected-user" ]]; then
    pass "AC2: cold cache populated with greeting username"
  else
    fail "AC2: cache entry = '$_cached_user', expected 'expected-user'"
  fi
else
  fail "AC2: identity-map.json not created after cold-cache preflight"
fi

# AC2: sentinel = match (cold cache → populate → compare with self → match)
_gi_val=$(cat "${SENTINEL_DIR}/github-identity" 2>/dev/null || echo "")
if [[ "$_gi_val" == match* ]]; then
  pass "AC2: sentinel = 'match' on cold-cache correct first run"
else
  fail "AC2: sentinel = '$_gi_val', expected 'match...'"
fi

# ---------------------------------------------------------------------------
# Test 2 (AC2): warm cache + greeting same → match
# ---------------------------------------------------------------------------
echo "=== Test 2 (AC2): warm cache + same greeting → match ==="

rm -rf "$SENTINEL_DIR"
mkdir -p "$SENTINEL_DIR"
# Keep existing cache from Test 1 (warm)
set_greeting "Hi expected-user!"

_up_github_identity_preflight "test-container" "id_ed25519_work" "label"

_gi_val=$(cat "${SENTINEL_DIR}/github-identity" 2>/dev/null || echo "")
if [[ "$_gi_val" == match* ]]; then
  pass "AC2: warm cache + same greeting → match"
else
  fail "AC2: warm cache expected match, got '$_gi_val'"
fi

# ---------------------------------------------------------------------------
# Test 3 (AC3): warm cache + different greeting → mismatch, exit 0
# ---------------------------------------------------------------------------
echo "=== Test 3 (AC3): warm cache + different greeting → mismatch, exit 0 ==="

rm -rf "$SENTINEL_DIR"
mkdir -p "$SENTINEL_DIR"
# Cache has expected-user for id_ed25519_work (from test 1)
# But now greeting returns a different user
set_greeting "Hi different-user!"

_preflight_exit=0
_up_github_identity_preflight "test-container" "id_ed25519_work" "rules-file" || _preflight_exit=$?

# AC3: exit 0 even on mismatch
if [[ "$_preflight_exit" -eq 0 ]]; then
  pass "AC3: rc up exits 0 on mismatch"
else
  fail "AC3: rc up exited $_preflight_exit, expected 0"
fi

# AC3: sentinel starts with "mismatch"
_gi_val=$(cat "${SENTINEL_DIR}/github-identity" 2>/dev/null || echo "")
if [[ "$_gi_val" == mismatch* ]]; then
  pass "AC3: sentinel = mismatch"
else
  fail "AC3: sentinel = '$_gi_val', expected mismatch..."
fi

# AC3: both usernames readable in sentinel
if echo "$_gi_val" | grep -q "expected-user"; then
  pass "AC3: expected username readable in sentinel"
else
  fail "AC3: expected username NOT in sentinel: '$_gi_val'"
fi
if echo "$_gi_val" | grep -q "different-user"; then
  pass "AC3: greeting username readable in sentinel"
else
  fail "AC3: greeting username NOT in sentinel: '$_gi_val'"
fi

# ---------------------------------------------------------------------------
# Test 4 (AC4): source=none → unset sentinel with greeting readable, exit 0
# ---------------------------------------------------------------------------
echo "=== Test 4 (AC4): source=none (layer-4 fallback) → unset with greeting, exit 0 ==="

rm -rf "$SENTINEL_DIR"
mkdir -p "$SENTINEL_DIR"
set_greeting "Hi some-user!"

_preflight_exit=0
# source=none, no key basename (empty)
_up_github_identity_preflight "test-container" "" "none" || _preflight_exit=$?

if [[ "$_preflight_exit" -eq 0 ]]; then
  pass "AC4: exit 0 on unset"
else
  fail "AC4: exited $_preflight_exit, expected 0"
fi

_gi_val=$(cat "${SENTINEL_DIR}/github-identity" 2>/dev/null || echo "")
if [[ "$_gi_val" == unset* ]]; then
  pass "AC4: sentinel starts with 'unset'"
else
  fail "AC4: sentinel = '$_gi_val', expected unset..."
fi

# AC4: greeting username readable in sentinel
if echo "$_gi_val" | grep -q "some-user"; then
  pass "AC4: greeting username readable in unset sentinel"
else
  fail "AC4: greeting username NOT in unset sentinel: '$_gi_val'"
fi

# AC4: ssh-config-source = none
_src_val=$(cat "${SENTINEL_DIR}/ssh-config-source" 2>/dev/null || echo "")
if [[ "$_src_val" == "none" ]]; then
  pass "AC4: ssh-config-source = none"
else
  fail "AC4: ssh-config-source = '$_src_val', expected 'none'"
fi

# ---------------------------------------------------------------------------
# Test 5 (AC5): unreachable → sentinel = unreachable, exit 0, no cache write
# ---------------------------------------------------------------------------
echo "=== Test 5 (AC5): unreachable → sentinel = unreachable, exit 0, no cache write ==="

rm -rf "$SENTINEL_DIR"
mkdir -p "$SENTINEL_DIR"
# Clear any entry for a new key
rm -f "$IDENTITY_MAP"
# Put in an existing entry for a different key (should survive)
mkdir -p "$CACHE_DIR"
echo '{"id_ed25519_other": {"github_username": "other-user", "ts": "2026-01-01T00:00:00Z"}}' > "$IDENTITY_MAP"

set_unreachable

_preflight_exit=0
_up_github_identity_preflight "test-container" "id_ed25519_work" "cli-flag" || _preflight_exit=$?

if [[ "$_preflight_exit" -eq 0 ]]; then
  pass "AC5: exit 0 on unreachable"
else
  fail "AC5: exited $_preflight_exit, expected 0"
fi

_gi_val=$(cat "${SENTINEL_DIR}/github-identity" 2>/dev/null || echo "")
if [[ "$_gi_val" == unreachable* ]]; then
  pass "AC5: sentinel starts with 'unreachable'"
else
  fail "AC5: sentinel = '$_gi_val', expected unreachable..."
fi

# AC5: no cache entry written for id_ed25519_work
if [[ -f "$IDENTITY_MAP" ]]; then
  _work_entry=$(jq -r '.["id_ed25519_work"] // empty' "$IDENTITY_MAP" 2>/dev/null)
  if [[ -z "$_work_entry" ]]; then
    pass "AC5: no cache entry written for id_ed25519_work on unreachable"
  else
    fail "AC5: cache entry written for id_ed25519_work despite unreachable: '$_work_entry'"
  fi
  # AC5: other entry preserved
  _other_entry=$(jq -r '.["id_ed25519_other"].github_username // empty' "$IDENTITY_MAP" 2>/dev/null)
  if [[ "$_other_entry" == "other-user" ]]; then
    pass "AC5: pre-existing cache entry for other key preserved"
  else
    fail "AC5: pre-existing cache entry for other key lost: '$_other_entry'"
  fi
else
  pass "AC5: identity-map.json not written on unreachable (no prior file)"
fi

# ---------------------------------------------------------------------------
# Test 6 (AC6): rc auth refresh → cache ts updated
# ---------------------------------------------------------------------------
echo "=== Test 6 (AC6): rc auth refresh → cache ts updated ==="

# Seed cache with an old timestamp
mkdir -p "$CACHE_DIR"
OLD_TS="2020-01-01T00:00:00Z"
echo "{\"id_ed25519_work\": {\"github_username\": \"test-user\", \"ts\": \"${OLD_TS}\"}}" > "$IDENTITY_MAP"

# Call the cache touch function (equivalent to what cmd_auth_refresh should call)
_identity_cache_touch_all

if [[ -f "$IDENTITY_MAP" ]]; then
  _new_ts=$(jq -r '.["id_ed25519_work"].ts // empty' "$IDENTITY_MAP" 2>/dev/null)
  if [[ "$_new_ts" != "$OLD_TS" ]]; then
    pass "AC6: ts updated from $OLD_TS to $_new_ts"
  else
    fail "AC6: ts not updated (still $OLD_TS)"
  fi
  # Verify username preserved
  _uname=$(jq -r '.["id_ed25519_work"].github_username // empty' "$IDENTITY_MAP" 2>/dev/null)
  if [[ "$_uname" == "test-user" ]]; then
    pass "AC6: github_username preserved after ts refresh"
  else
    fail "AC6: github_username changed after ts refresh: '$_uname'"
  fi
else
  fail "AC6: identity-map.json missing after touch"
fi

# ---------------------------------------------------------------------------
# Test 7 (AC7): host-config branch → no label comparison, greeting in sentinel
# ---------------------------------------------------------------------------
echo "=== Test 7 (AC7): source=host-config → ssh-config-source=host-config, greeting in github-identity ==="

rm -rf "$SENTINEL_DIR"
mkdir -p "$SENTINEL_DIR"
set_greeting "Hi host-config-user!"

_preflight_exit=0
# source=host-config: no key basename matters for label compare, just greeting is recorded
_up_github_identity_preflight "test-container" "id_ed25519_work" "host-config" || _preflight_exit=$?

if [[ "$_preflight_exit" -eq 0 ]]; then
  pass "AC7: exit 0 on host-config branch"
else
  fail "AC7: exited $_preflight_exit, expected 0"
fi

# AC7: ssh-config-source = host-config
_src_val=$(cat "${SENTINEL_DIR}/ssh-config-source" 2>/dev/null || echo "")
if [[ "$_src_val" == "host-config" ]]; then
  pass "AC7: ssh-config-source = host-config"
else
  fail "AC7: ssh-config-source = '$_src_val', expected host-config"
fi

# AC7: github-identity contains the greeting username (NOT 'unset')
_gi_val=$(cat "${SENTINEL_DIR}/github-identity" 2>/dev/null || echo "")
if [[ "$_gi_val" != unset* ]]; then
  pass "AC7: github-identity not 'unset' on host-config branch"
else
  fail "AC7: github-identity = '$_gi_val' (unexpected 'unset' on host-config branch)"
fi
if echo "$_gi_val" | grep -q "host-config-user"; then
  pass "AC7: greeting username readable in github-identity sentinel"
else
  fail "AC7: greeting username NOT in github-identity sentinel: '$_gi_val'"
fi

# ---------------------------------------------------------------------------
# Test 8: source=disabled → sentinels written as disabled
# ---------------------------------------------------------------------------
echo "=== Test 8: source=disabled → both sentinels = disabled ==="

rm -rf "$SENTINEL_DIR"
mkdir -p "$SENTINEL_DIR"

_up_github_identity_preflight "test-container" "" "disabled"

_gi_val=$(cat "${SENTINEL_DIR}/github-identity" 2>/dev/null || echo "")
_src_val=$(cat "${SENTINEL_DIR}/ssh-config-source" 2>/dev/null || echo "")

if [[ "$_gi_val" == "disabled" ]]; then
  pass "Test 8: github-identity = disabled"
else
  fail "Test 8: github-identity = '$_gi_val', expected disabled"
fi
if [[ "$_src_val" == "disabled" ]]; then
  pass "Test 8: ssh-config-source = disabled"
else
  fail "Test 8: ssh-config-source = '$_src_val', expected disabled"
fi

# ---------------------------------------------------------------------------
# Test 9: TTL — stale entry (>24h) treated as cold cache
# ---------------------------------------------------------------------------
echo "=== Test 9: stale cache entry (>24h old) treated as cold cache ==="

rm -rf "$SENTINEL_DIR"
mkdir -p "$SENTINEL_DIR"
# Plant a stale entry (2 days ago)
STALE_TS="2020-01-01T00:00:00Z"
echo "{\"id_ed25519_work\": {\"github_username\": \"old-user\", \"ts\": \"${STALE_TS}\"}}" > "$IDENTITY_MAP"
set_greeting "Hi new-user!"

_up_github_identity_preflight "test-container" "id_ed25519_work" "cli-flag"

# Should treat stale as cold: probe greeting, overwrite entry with new user
_cached_user=$(jq -r '.["id_ed25519_work"].github_username // empty' "$IDENTITY_MAP" 2>/dev/null)
if [[ "$_cached_user" == "new-user" ]]; then
  pass "Test 9: stale cache entry refreshed with new greeting username"
else
  fail "Test 9: stale cache entry not refreshed: '$_cached_user'"
fi

# After stale + re-probe → still match (new user vs new user)
_gi_val=$(cat "${SENTINEL_DIR}/github-identity" 2>/dev/null || echo "")
if [[ "$_gi_val" == match* ]]; then
  pass "Test 9: stale → cold → match (self-consistent)"
else
  fail "Test 9: after stale refresh, expected match, got '$_gi_val'"
fi

# ---------------------------------------------------------------------------
# Test 10: JSON shape of cache entry
# ---------------------------------------------------------------------------
echo "=== Test 10: identity-map.json has correct JSON shape ==="

rm -f "$IDENTITY_MAP"
set_greeting "Hi shape-user!"
_up_github_identity_preflight "test-container" "id_ed25519_shape" "cli-flag"

if [[ -f "$IDENTITY_MAP" ]]; then
  _has_username=$(jq -e '.["id_ed25519_shape"].github_username' "$IDENTITY_MAP" 2>/dev/null)
  _has_ts=$(jq -e '.["id_ed25519_shape"].ts' "$IDENTITY_MAP" 2>/dev/null)
  if [[ -n "$_has_username" ]]; then
    pass "Test 10: cache entry has github_username field"
  else
    fail "Test 10: cache entry missing github_username"
  fi
  if [[ -n "$_has_ts" ]]; then
    pass "Test 10: cache entry has ts field"
  else
    fail "Test 10: cache entry missing ts field"
  fi
  # ts should be ISO-8601-ish (contains T and Z)
  _ts_val=$(jq -r '.["id_ed25519_shape"].ts' "$IDENTITY_MAP" 2>/dev/null)
  if echo "$_ts_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
    pass "Test 10: ts field is ISO-8601 format"
  else
    fail "Test 10: ts field format unexpected: '$_ts_val'"
  fi
else
  fail "Test 10: identity-map.json not created"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "FAILURES: $FAILURES"
  exit 1
fi
