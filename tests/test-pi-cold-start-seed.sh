#!/usr/bin/env bash
# Host-side unit tests for pi auth cold-start seeding (rip-cage-wo9).
#
# Coverage:
#   (a) cold — no ~/.pi/agent/auth.json → after seeding, dir exists and auth.json contains {}
#   (b) idempotent — existing auth.json with real content is NOT overwritten
#   (c) symlink — a dangling symlink at the path is NOT clobbered/seeded
#
# Uses a temp HOME override so no host state is touched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_TMPDIR=""

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

setup_home() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-pi-cold-seed-XXXXXX")
}

teardown_home() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
}

# ---------------------------------------------------------------------------
# Source the helper from rc so the test drives the exact same function.
# _ensure_pi_auth_seed is defined in rc; we source only the function
# by loading rc in a subshell with the right HOME.
# ---------------------------------------------------------------------------
_run_ensure_pi_auth_seed() {
  local test_home="$1"
  # Source rc then call the helper; capture stderr for assertion.
  HOME="$test_home" bash -c '
    set -uo pipefail
    source "'"$RC"'" 2>/dev/null || true
    _ensure_pi_auth_seed 2>&1
  '
}

# ---------------------------------------------------------------------------
# (a) Cold — no ~/.pi/agent/auth.json → dir + file created, content = {}
# ---------------------------------------------------------------------------
test_a_cold_seed() {
  setup_home
  local test_home="$TEST_TMPDIR/home"
  mkdir -p "$test_home"
  # Deliberately do NOT create ~/.pi/agent

  local seed_output
  seed_output=$(_run_ensure_pi_auth_seed "$test_home")

  local auth_path="${test_home}/.pi/agent/auth.json"

  if [[ ! -f "$auth_path" ]]; then
    fail "(a) cold seed: auth.json not created at $auth_path (output='$seed_output')"
    teardown_home
    return
  fi

  local content
  content=$(cat "$auth_path")
  if [[ "$content" == "{}" ]]; then
    pass "(a) cold seed: auth.json created with content {}"
  else
    fail "(a) cold seed: auth.json content unexpected (got '$content', expected '{}')"
  fi

  # Log line must mention seeding
  if printf '%s' "$seed_output" | grep -qi "seeded"; then
    pass "(a) cold seed: seeding log line emitted"
  else
    fail "(a) cold seed: no seeding log line in output (got '$seed_output')"
  fi

  teardown_home
}

# ---------------------------------------------------------------------------
# (a2) Empty-dir — ~/.pi/agent exists but auth.json absent (AC2 state) → seeded {}
# ---------------------------------------------------------------------------
test_a2_empty_dir_seed() {
  setup_home
  local test_home="$TEST_TMPDIR/home"
  mkdir -p "${test_home}/.pi/agent"   # dir exists, but no auth.json

  local seed_output
  seed_output=$(_run_ensure_pi_auth_seed "$test_home")

  local auth_path="${test_home}/.pi/agent/auth.json"
  if [[ -f "$auth_path" && "$(cat "$auth_path")" == "{}" ]]; then
    pass "(a2) empty-dir seed: auth.json created with content {} when dir pre-exists"
  else
    fail "(a2) empty-dir seed: auth.json not seeded correctly (got '$(cat "$auth_path" 2>/dev/null)', output='$seed_output')"
  fi

  teardown_home
}

# ---------------------------------------------------------------------------
# (b) Idempotent — existing auth.json with real content is NOT overwritten
# ---------------------------------------------------------------------------
test_b_idempotent() {
  setup_home
  local test_home="$TEST_TMPDIR/home"
  mkdir -p "${test_home}/.pi/agent"
  local auth_path="${test_home}/.pi/agent/auth.json"
  local real_content='{"provider":"openai","token":"tok-abc123"}'
  printf '%s' "$real_content" > "$auth_path"

  local seed_output
  seed_output=$(_run_ensure_pi_auth_seed "$test_home")

  local content
  content=$(cat "$auth_path")
  if [[ "$content" == "$real_content" ]]; then
    pass "(b) idempotent: existing auth.json content preserved"
  else
    fail "(b) idempotent: auth.json was overwritten (got '$content', expected '$real_content')"
  fi

  # No seed log line (was not cold)
  if printf '%s' "$seed_output" | grep -qi "seeded"; then
    fail "(b) idempotent: spurious seeding log line emitted on second run (output='$seed_output')"
  else
    pass "(b) idempotent: no seeding log line on idempotent run"
  fi

  teardown_home
}

# ---------------------------------------------------------------------------
# (c) Symlink — a dangling symlink at the path is NOT clobbered
# ---------------------------------------------------------------------------
test_c_symlink_not_clobbered() {
  setup_home
  local test_home="$TEST_TMPDIR/home"
  mkdir -p "${test_home}/.pi/agent"
  local auth_path="${test_home}/.pi/agent/auth.json"
  # Create a dangling symlink pointing to a non-existent target
  ln -s "/nonexistent/path/auth.json" "$auth_path"

  local seed_output
  seed_output=$(_run_ensure_pi_auth_seed "$test_home")

  # The symlink must still be a symlink (not replaced by a regular file)
  if [[ -L "$auth_path" ]]; then
    pass "(c) symlink: dangling symlink not clobbered (still a symlink)"
  else
    fail "(c) symlink: symlink was replaced or removed (path is no longer a symlink)"
  fi

  # The symlink target must still point to the original dangling path
  local link_target
  link_target=$(readlink "$auth_path" 2>/dev/null || true)
  if [[ "$link_target" == "/nonexistent/path/auth.json" ]]; then
    pass "(c) symlink: symlink target preserved (still points to /nonexistent/path/auth.json)"
  else
    fail "(c) symlink: symlink target changed (got '$link_target', expected '/nonexistent/path/auth.json')"
  fi

  teardown_home
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-pi-cold-start-seed.sh — pi auth cold-start seeding (rip-cage-wo9) ==="

test_a_cold_seed
test_a2_empty_dir_seed
test_b_idempotent
test_c_symlink_not_clobbered

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
