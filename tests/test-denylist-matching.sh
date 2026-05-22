#!/usr/bin/env bash
# Host-side unit tests for _check_secret_path_denylist (ADR-023, rip-cage-3gu.1).
#
# Coverage matrix:
#   M1  positive: dotfile-directory component match (.aws in path)
#   M2  positive: bareword filename component match (credentials as basename)
#   M3  negative: no denylist component in path
#   M4  critical negative: ~/code/my-credentials-manager/app.env does NOT match
#       "credentials" — component-equals discipline (ADR-023 D4 anti-substring)
#   M5  mounts.allow_risky bypass: matching path allowed when in allow_risky list
#   M6  RC_ALLOW_RISKY_MOUNT bypass: matching path allowed when in-process array
#   M7  positive: bareword pattern matches intermediate path component (not just basename)
#   M8  negative: empty denylist allows all paths
#
# Tests source rc to access _check_secret_path_denylist directly.
# No docker required — pure function tests.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TEST_HOME=""
TEST_WS=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

setup_sandbox() {
  local global_fixture="$1" project_fixture="$2"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-denylist-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
  if [[ -n "$global_fixture" ]]; then
    # Write inline YAML to global config
    printf '%s' "$global_fixture" > "${TEST_HOME}/.config/rip-cage/config.yaml"
  fi
  if [[ -n "$project_fixture" ]]; then
    # Write inline YAML to project config
    printf '%s' "$project_fixture" > "${TEST_WS}/.rip-cage.yaml"
  fi
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
  TEST_WS=""
}

# Run _check_secret_path_denylist in a subshell with a given HOME/workspace.
# Returns the exit code of the function.
# Args: $1 = path to check, $2 = global config YAML content (or ""), $3 = project YAML (or "")
# Optional: $4 = space-separated RC_ALLOW_RISKY_MOUNT entries
run_denylist_check() {
  local path="$1"
  local global_yaml="$2"
  local project_yaml="$3"
  local allow_risky_mounts="${4:-}"

  setup_sandbox "$global_yaml" "$project_yaml"

  local exit_code=0
  if [[ -n "$allow_risky_mounts" ]]; then
    # Pass RC_ALLOW_RISKY_MOUNT as array entries
    HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
      bash -c "
        source '$RC'
        RC_ALLOW_RISKY_MOUNT=($allow_risky_mounts)
        _check_secret_path_denylist '$path' '$TEST_WS'
      " 2>/dev/null || exit_code=$?
  else
    HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
      bash -c "
        source '$RC'
        _check_secret_path_denylist '$path' '$TEST_WS'
      " 2>/dev/null || exit_code=$?
  fi

  teardown_sandbox
  return "$exit_code"
}

# ---------------------------------------------------------------------------
# M1: positive — dotfile-directory component match (.aws in path)
# ---------------------------------------------------------------------------
test_m1_dotfile_dir_component_match() {
  local global_yaml
  global_yaml='version: 1
mounts:
  denylist:
    - .aws
'
  local path="/home/u/.aws/credentials"
  local exit_code=0
  run_denylist_check "$path" "$global_yaml" "" || exit_code=$?
  # 0 = deny (match found)
  if [[ "$exit_code" -eq 0 ]]; then
    pass "M1 .aws component in /home/u/.aws/credentials → denied (exit 0)"
  else
    fail "M1 expected exit 0 (deny) for .aws component, got: $exit_code"
  fi
}

# ---------------------------------------------------------------------------
# M2: positive — bareword filename component match (credentials as basename)
# ---------------------------------------------------------------------------
test_m2_bareword_filename_match() {
  local global_yaml
  global_yaml='version: 1
mounts:
  denylist:
    - credentials
'
  local path="/home/u/.aws/credentials"
  local exit_code=0
  run_denylist_check "$path" "$global_yaml" "" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "M2 credentials component in /home/u/.aws/credentials → denied (exit 0)"
  else
    fail "M2 expected exit 0 (deny) for credentials component, got: $exit_code"
  fi
}

# ---------------------------------------------------------------------------
# M3: negative — no denylist component in path
# ---------------------------------------------------------------------------
test_m3_no_match_allowed() {
  local global_yaml
  global_yaml='version: 1
mounts:
  denylist:
    - .aws
    - credentials
'
  local path="/home/u/code/foo"
  local exit_code=0
  run_denylist_check "$path" "$global_yaml" "" || exit_code=$?
  # 1 = allow (no match)
  if [[ "$exit_code" -eq 1 ]]; then
    pass "M3 /home/u/code/foo has no denylist component → allowed (exit 1)"
  else
    fail "M3 expected exit 1 (allow) for /home/u/code/foo, got: $exit_code"
  fi
}

# ---------------------------------------------------------------------------
# M4: critical negative — component-equals discipline (ADR-023 D4)
# ~/code/my-credentials-manager/app.env does NOT match "credentials"
# ---------------------------------------------------------------------------
test_m4_no_substring_match() {
  local global_yaml
  global_yaml='version: 1
mounts:
  denylist:
    - credentials
'
  local path="/home/u/code/my-credentials-manager/app.env"
  local exit_code=0
  run_denylist_check "$path" "$global_yaml" "" || exit_code=$?
  # "my-credentials-manager" is NOT equal to "credentials" → should allow (exit 1)
  if [[ "$exit_code" -eq 1 ]]; then
    pass "M4 my-credentials-manager does NOT match credentials (component-equals, not substring)"
  else
    fail "M4 expected exit 1 (allow) — component-equals discipline violated (substring match fired)"
  fi
}

# ---------------------------------------------------------------------------
# M5: mounts.allow_risky bypass — path in allow_risky list is allowed even when
#     it would otherwise match the denylist
# ---------------------------------------------------------------------------
test_m5_allow_risky_config_bypass() {
  local global_yaml
  global_yaml='version: 1
mounts:
  denylist:
    - .aws
'
  local project_yaml
  project_yaml='version: 1
mounts:
  allow_risky:
    - /home/u/.aws/credentials
'
  local path="/home/u/.aws/credentials"
  local exit_code=0
  run_denylist_check "$path" "$global_yaml" "$project_yaml" || exit_code=$?
  # allow_risky overrides denylist → should allow (exit 1)
  if [[ "$exit_code" -eq 1 ]]; then
    pass "M5 mounts.allow_risky bypass: /home/u/.aws/credentials in allow_risky → allowed"
  else
    fail "M5 expected exit 1 (allow) via mounts.allow_risky bypass, got: $exit_code"
  fi
}

# ---------------------------------------------------------------------------
# M6: RC_ALLOW_RISKY_MOUNT bypass — path in in-process array is allowed
# ---------------------------------------------------------------------------
test_m6_rc_allow_risky_mount_bypass() {
  local global_yaml
  global_yaml='version: 1
mounts:
  denylist:
    - .aws
'
  local path="/home/u/.aws/credentials"
  local exit_code=0
  run_denylist_check "$path" "$global_yaml" "" '"/home/u/.aws/credentials"' || exit_code=$?
  # RC_ALLOW_RISKY_MOUNT overrides denylist → should allow (exit 1)
  if [[ "$exit_code" -eq 1 ]]; then
    pass "M6 RC_ALLOW_RISKY_MOUNT bypass: /home/u/.aws/credentials in array → allowed"
  else
    fail "M6 expected exit 1 (allow) via RC_ALLOW_RISKY_MOUNT bypass, got: $exit_code"
  fi
}

# ---------------------------------------------------------------------------
# M7: positive — bareword pattern matches intermediate component (not just basename)
# /home/u/credentials/subdir/file — "credentials" is an intermediate component
# ---------------------------------------------------------------------------
test_m7_intermediate_component_match() {
  local global_yaml
  global_yaml='version: 1
mounts:
  denylist:
    - credentials
'
  local path="/home/u/credentials/subdir/file"
  local exit_code=0
  run_denylist_check "$path" "$global_yaml" "" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "M7 credentials as intermediate component → denied (exit 0)"
  else
    fail "M7 expected exit 0 (deny) for credentials as intermediate component, got: $exit_code"
  fi
}

# ---------------------------------------------------------------------------
# M8: negative — empty denylist allows all paths
# ---------------------------------------------------------------------------
test_m8_empty_denylist_allows_all() {
  local global_yaml
  global_yaml='version: 1
mounts:
  denylist: []
'
  local path="/home/u/.aws/credentials"
  local exit_code=0
  run_denylist_check "$path" "$global_yaml" "" || exit_code=$?
  if [[ "$exit_code" -eq 1 ]]; then
    pass "M8 empty denylist allows all paths (even .aws/credentials)"
  else
    fail "M8 expected exit 1 (allow) with empty denylist, got: $exit_code"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "=== test-denylist-matching.sh — ADR-023 _check_secret_path_denylist ==="
test_m1_dotfile_dir_component_match
test_m2_bareword_filename_match
test_m3_no_match_allowed
test_m4_no_substring_match
test_m5_allow_risky_config_bypass
test_m6_rc_allow_risky_mount_bypass
test_m7_intermediate_component_match
test_m8_empty_denylist_allows_all

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
