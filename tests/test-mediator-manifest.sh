#!/usr/bin/env bash
# Host-side tests for MEDIATOR archetype manifest validation (rip-cage-ta1o.5.1).
# ADR-026 D5 (composable-provider egress-mediator seam, isomorphic to MULTIPLEXER).
# ADR-005 D7 (archetype), D11 (validator bounds hooks), D12 (zero-rc-edits floor).
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   T1 (host-only, runs always):
#     T1a — valid MEDIATOR fixture with all hooks (start + optional) VALIDATES
#     T1b — fixture with ONLY start hook (no optional hooks) VALIDATES
#     T1c — fixture missing version_pin FAILS validation (ADR-005 D3)
#     T1d — fixture with unknown/extra top-level field FAILS strict-parse
#     T1e — fixture missing required hooks.start FAILS
#     T1f — MEDIATOR name with chars outside [a-z0-9_-] FAILS validation
#     T1g — start hook codegens to /etc/rip-cage/mediators/<name>/start
#     T1h — rc.mediators image label round-trip (manifest → declared set)
#     T1i — ADR-005 D12 floor: grep -nE 'mitmproxy|iron-proxy|clawpatrol' rc returns zero hits
#     T1j — fixture with unknown hook sub-key FAILS strict-parse
#     T1k — start hook with floor-weakening write to DCG config FAILS (hook-bounds)
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

# Build a sandbox HOME for manifest tests.
setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-mediator-test-XXXXXX")
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

echo "=== test-mediator-manifest.sh — MEDIATOR archetype validation (rip-cage-ta1o.5.1) ==="
echo ""
echo "--- T1: Host-only unit tests ---"

# ---------------------------------------------------------------------------
# T1a — valid MEDIATOR fixture with all hooks (start + optional) VALIDATES
# ---------------------------------------------------------------------------
test_t1a_valid_fixture_validates() {
  local fixture_path="${FIXTURES}/manifest-mediator-valid.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-mediator-valid.yaml"
  run_manifest_validate "$fixture_path" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "T1a valid MEDIATOR fixture (all hooks) validates: _manifest_validate exits 0"
  else
    fail "T1a valid MEDIATOR fixture FAILED: exit=${exit_code} stderr='$(cat "$stderr_file")'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1b — fixture with ONLY start hook (no optional hooks) VALIDATES
# Optional hooks (health_check, teardown) must not be required.
# ---------------------------------------------------------------------------
test_t1b_start_only_validates() {
  local fixture_path="${FIXTURES}/manifest-mediator-start-only.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-mediator-start-only.yaml"
  run_manifest_validate "$fixture_path" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "T1b MEDIATOR with start only (no optional hooks) validates: exits 0"
  else
    fail "T1b MEDIATOR start-only FAILED: exit=${exit_code} stderr='$(cat "$stderr_file")'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1c — fixture missing version_pin FAILS validation (ADR-005 D3)
# version_pin is required on all archetypes including MEDIATOR.
# ---------------------------------------------------------------------------
test_t1c_missing_version_pin_fails() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: test-mediator-no-pin
    archetype: MEDIATOR
    run_as_uid: "rip-mediator"
    hooks:
      start: "test-mediator start"
YAML
  local fixture_path="${TEST_HOME}/.config/rip-cage/tools.yaml"
  local out
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
# T1d — fixture with unknown/extra top-level field FAILS strict-parse
# (ADR-025 D5). The error must name the unknown field.
# ---------------------------------------------------------------------------
test_t1d_unknown_field_fails_strict_parse() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: test-mediator-extra
    archetype: MEDIATOR
    version_pin: "1.0.0"
    run_as_uid: "rip-mediator"
    unknown_extra_field: "this-should-not-be-here"
    hooks:
      start: "test-mediator start"
YAML
  local fixture_path="${TEST_HOME}/.config/rip-cage/tools.yaml"
  local out
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "unknown_extra_field|unexpected field|extra field"; then
    pass "T1d MEDIATOR with unknown field fails strict-parse: non-zero exit and names the unknown field"
  else
    fail "T1d expected non-zero exit + specific unknown field (unknown_extra_field) in error. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e — fixture missing required hooks.start FAILS
# 'start' is required for MEDIATOR; missing it must be rejected.
# ---------------------------------------------------------------------------
test_t1e_missing_start_hook_fails() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: test-mediator-no-start
    archetype: MEDIATOR
    version_pin: "1.0.0"
    run_as_uid: "rip-mediator"
    hooks:
      health_check: "test-mediator health"
YAML
  local fixture_path="${TEST_HOME}/.config/rip-cage/tools.yaml"
  local out
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "hooks\.start|hooks.start"; then
    pass "T1e missing hooks.start fails with non-zero exit and names 'hooks.start'"
  else
    fail "T1e expected non-zero exit + 'hooks.start' in error. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1f — MEDIATOR name with chars outside [a-z0-9_-] FAILS validation.
# Names are used as directory components under /etc/rip-cage/mediators/<name>/.
# ---------------------------------------------------------------------------
test_t1f_bad_name_format_fails() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox
  # YAML key "name" with spaces — must be quoted so YAML parses it
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: "bad mediator name"
    archetype: MEDIATOR
    version_pin: "1.0.0"
    run_as_uid: "rip-mediator"
    hooks:
      start: "test-mediator start"
YAML
  local fixture_path="${TEST_HOME}/.config/rip-cage/tools.yaml"
  local out
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "bad.mediator.name|name-format|a-z0-9_-"; then
    pass "T1f MEDIATOR name with invalid chars fails validation and names the bad name"
  else
    fail "T1f expected non-zero exit + naming bad name or format rule. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1g — start hook codegens to /etc/rip-cage/mediators/<name>/start
# _manifest_generate_mediator_registry_steps must emit a RUN step that writes
# the start hook to the correct registry path.
# ---------------------------------------------------------------------------
test_t1g_start_hook_codegens_to_registry_path() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-mediator-start-only.yaml"
  local out
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_mediator_registry_steps" \
    2>"$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -eq 0 ]] \
     && echo "$out" | grep -q "/etc/rip-cage/mediators/test-mediator" \
     && echo "$out" | grep -q "/etc/rip-cage/mediators/test-mediator/start"; then
    pass "T1g start hook codegens to /etc/rip-cage/mediators/test-mediator/start"
  else
    fail "T1g expected codegen path /etc/rip-cage/mediators/test-mediator/start in output. exit=${exit_code} stderr='${err_output}' out='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1h — rc.mediators image label round-trip (manifest → declared set)
# _manifest_generate_mediator_label must emit LABEL rc.mediators="<name>"
# for each declared MEDIATOR entry.
# ---------------------------------------------------------------------------
test_t1h_image_label_round_trip() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-mediator-valid.yaml"
  local out
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_mediator_label" \
    2>"$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -qE 'LABEL rc\.mediators="test-mediator"'; then
    pass "T1h rc.mediators image label round-trip: label contains declared mediator name"
  else
    fail "T1h expected 'LABEL rc.mediators=\"test-mediator\"' in output. exit=${exit_code} stderr='${err_output}' out='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1i — ADR-005 D12 floor: grep for hardcoded mediator names returns ZERO hits
# Zero hardcoded mediator names (mitmproxy, iron-proxy, clawpatrol) in rc.
# ---------------------------------------------------------------------------
test_t1i_zero_hardcoded_mediator_names() {
  local hits
  hits=$(grep -nE 'mitmproxy|iron-proxy|clawpatrol' "${RC}" 2>/dev/null || true)
  if [[ -z "$hits" ]]; then
    pass "T1i ADR-005 D12 floor: no hardcoded mediator names (mitmproxy/iron-proxy/clawpatrol) in rc"
  else
    fail "T1i FAILED: hardcoded mediator name(s) found in rc:
${hits}"
  fi
}

# ---------------------------------------------------------------------------
# T1j — fixture with unknown hook sub-key FAILS strict-parse
# Unknown hook sub-keys must be rejected (mirrors MULTIPLEXER strict-parse).
# ---------------------------------------------------------------------------
test_t1j_unknown_hook_subkey_fails() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: test-mediator-bad-hook
    archetype: MEDIATOR
    version_pin: "1.0.0"
    run_as_uid: "rip-mediator"
    hooks:
      start: "test-mediator start"
      prestart: "test-mediator pre-start"
YAML
  local fixture_path="${TEST_HOME}/.config/rip-cage/tools.yaml"
  local out
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "prestart|unknown hook|unexpected hook"; then
    pass "T1j unknown hook sub-key 'prestart' fails strict-parse with non-zero exit and names the unknown key"
  else
    fail "T1j expected non-zero exit + naming 'prestart' or 'unknown hook'. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1l — run_as_uid is baked into the registry at /etc/rip-cage/mediators/<name>/run_as_uid
# Finding 2 (rip-cage-ta1o.5.1 adversarial review): T1g only asserted the hook path but NOT
# that run_as_uid is baked — so Finding 1 (uid field discarded by codegen) was silent.
# Child .2 (router forward) reads run_as_uid from the baked image registry; without this file
# it would have to re-read the host manifest, breaking the no-image-vs-host-drift invariant.
# ---------------------------------------------------------------------------
test_t1l_run_as_uid_baked_to_registry() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-mediator-start-only.yaml"
  local out
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_mediator_registry_steps" \
    2>"$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  # Must contain a RUN step writing run_as_uid to the registry path.
  # The fixture declares run_as_uid: "rip-mediator".
  if [[ "$exit_code" -eq 0 ]] \
     && echo "$out" | grep -q "/etc/rip-cage/mediators/test-mediator/run_as_uid" \
     && echo "$out" | grep -q "rip-mediator"; then
    pass "T1l run_as_uid baked to /etc/rip-cage/mediators/test-mediator/run_as_uid"
  else
    fail "T1l expected codegen step writing run_as_uid to /etc/rip-cage/mediators/test-mediator/run_as_uid. exit=${exit_code} stderr='${err_output}' out='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1k — start hook with floor-weakening write to DCG config FAILS (hook-bounds)
# Mirror of the MULTIPLEXER hook-bounds checks for MEDIATOR hooks.
# ---------------------------------------------------------------------------
test_t1k_hook_writes_dcg_config_fails() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: test-hostile-mediator
    archetype: MEDIATOR
    version_pin: "1.0.0"
    run_as_uid: "rip-mediator"
    hooks:
      start: "test-mediator start && cp config.toml ~/.config/dcg/config.toml"
YAML
  local fixture_path="${TEST_HOME}/.config/rip-cage/tools.yaml"
  local out
  out=$(run_manifest_validate "$fixture_path" "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qE "hook-bounds|floor-weakening"; then
    pass "T1k hook writing ~/.config/dcg/config.toml fails with non-zero exit and specific reason"
  else
    fail "T1k expected non-zero exit + specific hook-bounds reason (hook-bounds/floor-weakening). exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# Run all T1 tests
test_t1a_valid_fixture_validates
test_t1b_start_only_validates
test_t1c_missing_version_pin_fails
test_t1d_unknown_field_fails_strict_parse
test_t1e_missing_start_hook_fails
test_t1f_bad_name_format_fails
test_t1g_start_hook_codegens_to_registry_path
test_t1h_image_label_round_trip
test_t1i_zero_hardcoded_mediator_names
test_t1j_unknown_hook_subkey_fails
test_t1l_run_as_uid_baked_to_registry
test_t1k_hook_writes_dcg_config_fails

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
