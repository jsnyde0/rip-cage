#!/usr/bin/env bash
# Host-side tests for MULTIPLEXER archetype manifest validation (rip-cage-61al.1).
# ADR-005 D11 (validator bounds the hooks, FIRM — M7 is its mechanism).
# ADR-005 D10 (fail-closed build / safety asymmetry).
# ADR-005 D9  (hooks = availability-payload, FIRM).
# ADR-005 D3  (version_pin required on every archetype).
# ADR-024 D11 (entrypoint-completeness — check inside _manifest_validate).
# ADR-025 D5  (strict-parse / fail-closed manifest contract).
# ADR-001     (fail loud on a floor-weakening hook).
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   T1 (host-only, runs always):
#     T1a — valid MULTIPLEXER fixture with all hooks (start+attach+optional) VALIDATES
#     T1b — fixture with ONLY start+attach (no optional hooks) VALIDATES
#     T1c — fixture missing version_pin FAILS validation (ADR-005 D3)
#     T1d — fixture with unknown/extra field: asserting actual validator posture.
#           NOTE: the current validator does NOT strict-reject unknown/extra fields
#           for any archetype — this test asserts the ACTUAL posture (lax for unknown
#           top-level fields) and documents the gap. For MULTIPLEXER, unknown top-level
#           fields ARE rejected (strict-parse per ADR-025 D5 implemented for this archetype).
#     T1e — fixture whose start hook writes ~/.config/dcg/config.toml FAILS (floor-weakening)
#     T1f — fixture whose start hook writes workspace .dcg.toml FAILS (floor-weakening)
#     T1g — fixture whose hook PATH-shadows a safety binary FAILS (floor-weakening)
#     T1h — fixture missing required hooks.start FAILS
#     T1i — fixture missing required hooks.attach FAILS
#
# =============================================================================
# Positive-sentinel discipline:
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# E2E flag from command line
if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

# Build a sandbox HOME for manifest tests.
setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-mux-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_validate against a given fixture file path.
# Outputs stdout to stdout; stderr to $2 if given.
run_manifest_validate() {
  local fixture_path="$1"
  local stderr_file="${2:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${fixture_path}'" \
    2>"$stderr_file"
}

echo "=== test-manifest-multiplexer-validate.sh — MULTIPLEXER archetype validation (rip-cage-61al.1) ==="
echo ""
echo "--- T1: Host-only unit tests ---"

# ---------------------------------------------------------------------------
# T1a — valid MULTIPLEXER fixture with all hooks (start+attach+optional) VALIDATES
# ---------------------------------------------------------------------------
test_t1a_valid_fixture_validates() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-valid.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-valid.yaml"
  run_manifest_validate "$fixture_path" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "T1a valid MULTIPLEXER fixture (all hooks) validates: _manifest_validate exits 0"
  else
    fail "T1a valid MULTIPLEXER fixture FAILED: exit=${exit_code} stderr='$(cat "$stderr_file")'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1b — fixture with ONLY start+attach (no optional hooks) VALIDATES
# Optional hooks (exec, new_session, teardown) must not be required.
# ---------------------------------------------------------------------------
test_t1b_start_attach_only_validates() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-start-attach-only.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-start-attach-only.yaml"
  run_manifest_validate "$fixture_path" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "T1b MULTIPLEXER with start+attach only (no optional hooks) validates: exits 0"
  else
    fail "T1b MULTIPLEXER start+attach only FAILED: exit=${exit_code} stderr='$(cat "$stderr_file")'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1c — fixture missing version_pin FAILS validation (ADR-005 D3)
# version_pin is required on all archetypes including MULTIPLEXER.
# ---------------------------------------------------------------------------
test_t1c_missing_version_pin_fails() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-missing-version-pin.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-missing-version-pin.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "version_pin"; then
    pass "T1c missing version_pin fails with non-zero exit and names 'version_pin'"
  else
    fail "T1c expected non-zero exit + 'version_pin' in error. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1d — fixture with unknown/extra field FAILS strict-parse for MULTIPLEXER
# (ADR-025 D5). For MULTIPLEXER, strict-parse IS enforced (unlike TOOL/
# SHELL-INTEGRATION/IN-CAGE-DAEMON which currently allow extra fields — that
# gap is noted but not fixed here; MULTIPLEXER implements the full contract).
# The error must name the unknown field.
# ---------------------------------------------------------------------------
test_t1d_unknown_field_fails_strict_parse() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-unknown-field.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-unknown-field.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  # The error must name the specific unknown field (unknown_extra_field) — not just say
  # "unknown archetype" (which would be a false-positive match on "unknown").
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "unknown_extra_field|unexpected field|extra field"; then
    pass "T1d MULTIPLEXER with unknown field fails strict-parse: non-zero exit and names the unknown field"
  else
    fail "T1d expected non-zero exit + specific unknown field (unknown_extra_field) in error. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e — fixture whose start hook writes ~/.config/dcg/config.toml FAILS
# Hook-bounds check: writing DCG global config weakens the safety floor.
# Must fail with a specific reason naming the floor-weakening pattern.
# ---------------------------------------------------------------------------
test_t1e_hook_writes_dcg_global_config_fails() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-hostile-dcg-global.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-hostile-dcg-global.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  # Must fail AND mention hook-bounds specific terms.
  # Note: the err_output fixture path contains "dcg" — we require more specific terms
  # that only the hook-bounds check itself would produce: "hook-bounds", "floor-weakening",
  # or "config.toml" (naming the specific file being guarded).
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qE "hook-bounds|floor-weakening"; then
    pass "T1e hook writing ~/.config/dcg/config.toml fails with non-zero exit and specific reason"
  else
    fail "T1e expected non-zero exit + specific hook-bounds reason (hook-bounds/floor-weakening). exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1f — fixture whose start hook writes workspace .dcg.toml FAILS
# Hook-bounds check: writing workspace DCG config weakens the safety floor.
# ---------------------------------------------------------------------------
test_t1f_hook_writes_dcg_workspace_toml_fails() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-hostile-dcg-workspace.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-hostile-dcg-workspace.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qE "hook-bounds|floor-weakening"; then
    pass "T1f hook writing workspace .dcg.toml fails with non-zero exit and specific reason"
  else
    fail "T1f expected non-zero exit + specific hook-bounds reason (hook-bounds/floor-weakening). exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1g — fixture whose hook PATH-shadows a safety binary FAILS
# Hook-bounds check: PATH manipulation to shadow dcg/dcg-policy/block-ssh-bypass
# weakens the safety floor. Must fail with a specific reason.
# ---------------------------------------------------------------------------
test_t1g_hook_path_shadows_safety_binary_fails() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-hostile-path-shadow.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-hostile-path-shadow.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  # The error must name hook-bounds specifically — NOT just "unknown archetype".
  # "hook-bounds" is produced only by the hook-bounds check, not by the archetype rejection.
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qE "hook-bounds|floor-weakening"; then
    pass "T1g hook PATH-shadowing safety binary fails with non-zero exit and specific reason"
  else
    fail "T1g expected non-zero exit + specific hook-bounds reason (hook-bounds/floor-weakening). exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1h — fixture missing required hooks.start FAILS
# 'start' is required for MULTIPLEXER; missing it must be rejected.
# ---------------------------------------------------------------------------
test_t1h_missing_start_hook_fails() {
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: test-mux-no-start
    archetype: MULTIPLEXER
    version_pin: "1.0.0"
    hooks:
      attach: "test-mux attach"
YAML
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  # The error must name 'hooks.start' specifically (not just "unknown archetype" where start doesn't appear)
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "hooks\.start|hooks.start"; then
    pass "T1h missing hooks.start fails with non-zero exit and names 'hooks.start'"
  else
    fail "T1h expected non-zero exit + 'hooks.start' in error. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1i — fixture missing required hooks.attach FAILS
# 'attach' is required for MULTIPLEXER; missing it must be rejected.
# ---------------------------------------------------------------------------
test_t1i_missing_attach_hook_fails() {
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: test-mux-no-attach
    archetype: MULTIPLEXER
    version_pin: "1.0.0"
    hooks:
      start: "test-mux start-server"
YAML
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  # The error must name 'hooks.attach' specifically
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "hooks\.attach|hooks.attach"; then
    pass "T1i missing hooks.attach fails with non-zero exit and names 'hooks.attach'"
  else
    fail "T1i expected non-zero exit + 'hooks.attach' in error. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1j — Finding 1a: exec hook writes /usr/local/lib/rip-cage/bin/dcg-guard FAILS
# The DCG guard WRAPPER is the policy-enforcing binary; overwriting it weakens
# the safety floor. Current pattern 3b misses this path — regression test.
# ---------------------------------------------------------------------------
test_t1j_hook_writes_dcg_guard_fails() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-hostile-dcg-guard-exec.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-hostile-dcg-guard-exec.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qE "hook-bounds|floor-weakening"; then
    pass "T1j exec hook writing /usr/local/lib/rip-cage/bin/dcg-guard fails with non-zero exit and specific reason"
  else
    fail "T1j expected non-zero exit + hook-bounds/floor-weakening reason. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1k — Finding 1b: attach hook writes /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh FAILS
# The ssh-bypass blocker lives at the lib path, not /usr/local/bin — the
# current pattern misses it. Regression test.
# ---------------------------------------------------------------------------
test_t1k_hook_writes_ssh_blocker_fails() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-hostile-ssh-blocker-attach.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-hostile-ssh-blocker-attach.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qE "hook-bounds|floor-weakening"; then
    pass "T1k attach hook writing /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh fails with non-zero exit and specific reason"
  else
    fail "T1k expected non-zero exit + hook-bounds/floor-weakening reason. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1l — Finding 2: start hook patches /etc/rip-cage/settings.json to add PreToolUse FAILS
# Lifecycle-interceptor check (M7 requirement): a hook must NOT register
# PreToolUse/PostToolUse hooks or modify the settings.json lifecycle config.
# ---------------------------------------------------------------------------
test_t1l_hook_lifecycle_interceptor_fails() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-hostile-lifecycle-interceptor.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-hostile-lifecycle-interceptor.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qE "hook-bounds|floor-weakening|lifecycle"; then
    pass "T1l start hook patching /etc/rip-cage/settings.json (PreToolUse) fails with non-zero exit and specific reason"
  else
    fail "T1l expected non-zero exit + hook-bounds/floor-weakening/lifecycle reason. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1m — Finding 3: unknown hook sub-key (prestart) inside hooks: object FAILS
# Strict-parse must cover keys INSIDE the hooks object, not just top-level.
# An unrecognized hook sub-key escapes both the known-hooks iterator and bounds
# checks; it must be explicitly rejected.
# ---------------------------------------------------------------------------
test_t1m_unknown_hook_subkey_fails() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-unknown-hook-key.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-unknown-hook-key.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "prestart|unknown hook|unexpected hook"; then
    pass "T1m unknown hook sub-key 'prestart' fails strict-parse with non-zero exit and names the unknown key"
  else
    fail "T1m expected non-zero exit + naming 'prestart' or 'unknown hook'. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1n — MULTIPLEXER name with chars outside [a-z0-9_-] FAILS validation.
# A name like "bad'name" (quote) or "bad name" (space) must be rejected with
# a clear error naming the bad name — not silently accepted and then failing
# docker build with an opaque Dockerfile syntax error (ADR-001 fail-loud).
# ---------------------------------------------------------------------------
test_t1n_bad_name_format_fails() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-bad-name.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-bad-name.yaml"
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  # Must fail AND name the offending name in the error
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "bad.name|name-format|a-z0-9_-"; then
    pass "T1n MULTIPLEXER name with invalid chars fails validation and names the bad name"
  else
    fail "T1n expected non-zero exit + naming bad name or format rule. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# Run T1 tests
test_t1a_valid_fixture_validates
test_t1b_start_attach_only_validates
test_t1c_missing_version_pin_fails
test_t1d_unknown_field_fails_strict_parse
test_t1e_hook_writes_dcg_global_config_fails
test_t1f_hook_writes_dcg_workspace_toml_fails
test_t1g_hook_path_shadows_safety_binary_fails
test_t1h_missing_start_hook_fails
test_t1i_missing_attach_hook_fails
test_t1j_hook_writes_dcg_guard_fails
test_t1k_hook_writes_ssh_blocker_fails
test_t1l_hook_lifecycle_interceptor_fails
test_t1m_unknown_hook_subkey_fails
test_t1n_bad_name_format_fails

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
