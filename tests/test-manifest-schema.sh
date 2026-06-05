#!/usr/bin/env bash
# Host-side unit tests for the tool manifest schema loader + validator.
# (rip-cage-4c5.1 — ADR-005 D7/D8, ADR-021 D1, ADR-024 D1)
#
# Coverage matrix:
#   VALID — one-per-archetype manifest parses and exposes entries
#     M1  TOOL archetype entry parses: name/archetype/egress/mounts/version_pin
#     M2  SHELL-INTEGRATION archetype entry parses: name/archetype/shell_init/version_pin
#     M3  IN-CAGE-DAEMON archetype entry parses: name/archetype/start/health/state_dir/version_pin
#   HOSTILE — strict-parse, fail-closed (ADR-001 / validate-config-by-parsing)
#     M4  unknown archetype aborts non-zero + names the 'archetype' field
#     M5  missing required field (name) aborts non-zero + names 'name'
#     M6  malformed egress (non-list) aborts non-zero + names 'egress'
#     M7  missing required TOOL field (no egress) aborts non-zero + names 'egress'
#   ABSENT/EMPTY
#     M8  absent manifest yields the default stack (D8 regression contract)
#     M9  empty manifest (zero-byte) yields the default stack
#   HOSTILE (continued)
#     M11 missing version_pin aborts non-zero + names 'version_pin' (all archetypes)
#   HOST-ONLY
#     M10  loader path resolves to host config dir (XDG_CONFIG_HOME / ~/.config)
#     M10b loader path does not reference /workspace (path-derivation assertion)
#     M10c XDG_CONFIG_HOME redirect is honored — proves the override mechanism
#          (host-side-only: env not forwarded into cage, ADR-005 D7 FIRM / ADR-024 D1)
#
# Tests do NOT require docker — pure host-side loader logic only.
#
# Positive-sentinel discipline: tests assert on SPECIFIC expected output, not
# merely absence of error. (rip-cage-test-fail-prose-without-exit-silent-red)

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

# Build a sandbox HOME with optional manifest.
# Args: $1 = fixture name (or "" to omit the manifest file)
setup_manifest_sandbox() {
  local fixture="$1"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_load in the sandbox. Outputs JSON on stdout; stderr to $1 if given.
run_manifest_load() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_load" 2>"$stderr_file"
}

# ---------------------------------------------------------------------------
# M1 — TOOL archetype parses
# ---------------------------------------------------------------------------
test_m1_tool_archetype_parses() {
  setup_manifest_sandbox "manifest-valid-all-archetypes.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_load "$stderr_file") || exit_code=$?
  local name archetype version_pin egress
  name=$(jq -r '.tools[] | select(.archetype == "TOOL") | .name' <<<"$out" 2>/dev/null | head -1)
  archetype=$(jq -r '.tools[] | select(.archetype == "TOOL") | .archetype' <<<"$out" 2>/dev/null | head -1)
  version_pin=$(jq -r '.tools[] | select(.archetype == "TOOL") | .version_pin' <<<"$out" 2>/dev/null | head -1)
  egress=$(jq -c '.tools[] | select(.archetype == "TOOL") | .egress' <<<"$out" 2>/dev/null | head -1)
  if [[ "$exit_code" -eq 0 \
        && -n "$name" \
        && "$archetype" == "TOOL" \
        && -n "$version_pin" \
        && -n "$egress" ]]; then
    pass "M1 TOOL archetype parses: name=$name archetype=$archetype version_pin=$version_pin egress=$egress"
  else
    fail "M1 TOOL archetype parse failed: exit=$exit_code name=$name archetype=$archetype version_pin=$version_pin egress=$egress stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M2 — SHELL-INTEGRATION archetype parses
# ---------------------------------------------------------------------------
test_m2_shell_integration_archetype_parses() {
  setup_manifest_sandbox "manifest-valid-all-archetypes.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_load "$stderr_file") || exit_code=$?
  local name archetype version_pin shell_init
  name=$(jq -r '.tools[] | select(.archetype == "SHELL-INTEGRATION") | .name' <<<"$out" 2>/dev/null | head -1)
  archetype=$(jq -r '.tools[] | select(.archetype == "SHELL-INTEGRATION") | .archetype' <<<"$out" 2>/dev/null | head -1)
  version_pin=$(jq -r '.tools[] | select(.archetype == "SHELL-INTEGRATION") | .version_pin' <<<"$out" 2>/dev/null | head -1)
  shell_init=$(jq -r '.tools[] | select(.archetype == "SHELL-INTEGRATION") | .shell_init' <<<"$out" 2>/dev/null | head -1)
  if [[ "$exit_code" -eq 0 \
        && -n "$name" \
        && "$archetype" == "SHELL-INTEGRATION" \
        && -n "$version_pin" \
        && -n "$shell_init" ]]; then
    pass "M2 SHELL-INTEGRATION archetype parses: name=$name version_pin=$version_pin shell_init present"
  else
    fail "M2 SHELL-INTEGRATION archetype parse failed: exit=$exit_code name=$name archetype=$archetype version_pin=$version_pin shell_init=$shell_init stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M3 — IN-CAGE-DAEMON archetype parses
# ---------------------------------------------------------------------------
test_m3_daemon_archetype_parses() {
  setup_manifest_sandbox "manifest-valid-all-archetypes.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_load "$stderr_file") || exit_code=$?
  local name archetype version_pin start health state_dir
  name=$(jq -r '.tools[] | select(.archetype == "IN-CAGE-DAEMON") | .name' <<<"$out" 2>/dev/null | head -1)
  archetype=$(jq -r '.tools[] | select(.archetype == "IN-CAGE-DAEMON") | .archetype' <<<"$out" 2>/dev/null | head -1)
  version_pin=$(jq -r '.tools[] | select(.archetype == "IN-CAGE-DAEMON") | .version_pin' <<<"$out" 2>/dev/null | head -1)
  start=$(jq -r '.tools[] | select(.archetype == "IN-CAGE-DAEMON") | .start' <<<"$out" 2>/dev/null | head -1)
  health=$(jq -r '.tools[] | select(.archetype == "IN-CAGE-DAEMON") | .health' <<<"$out" 2>/dev/null | head -1)
  state_dir=$(jq -r '.tools[] | select(.archetype == "IN-CAGE-DAEMON") | .state_dir' <<<"$out" 2>/dev/null | head -1)
  if [[ "$exit_code" -eq 0 \
        && -n "$name" \
        && "$archetype" == "IN-CAGE-DAEMON" \
        && -n "$version_pin" \
        && -n "$start" \
        && -n "$health" \
        && -n "$state_dir" ]]; then
    pass "M3 IN-CAGE-DAEMON archetype parses: name=$name version_pin=$version_pin start/health/state_dir present"
  else
    fail "M3 IN-CAGE-DAEMON archetype parse failed: exit=$exit_code name=$name archetype=$archetype version_pin=$version_pin start=$start health=$health state_dir=$state_dir stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M4 — unknown archetype aborts non-zero + names 'archetype' field
# ---------------------------------------------------------------------------
test_m4_unknown_archetype_aborts() {
  setup_manifest_sandbox "manifest-hostile-unknown-archetype.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "archetype" "$stderr_file"; then
    pass "M4 unknown archetype aborts non-zero + names 'archetype' field"
  else
    fail "M4 expected non-zero exit + 'archetype' in error, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M5 — missing required field (name) aborts non-zero + names 'name'
# ---------------------------------------------------------------------------
test_m5_missing_name_aborts() {
  setup_manifest_sandbox "manifest-hostile-missing-name.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "name" "$stderr_file"; then
    pass "M5 missing 'name' field aborts non-zero + names 'name'"
  else
    fail "M5 expected non-zero exit + 'name' in error, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M6 — malformed egress (non-list) aborts non-zero + names 'egress'
# ---------------------------------------------------------------------------
test_m6_malformed_egress_aborts() {
  setup_manifest_sandbox "manifest-hostile-malformed-egress.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "egress" "$stderr_file"; then
    pass "M6 malformed egress (non-list) aborts non-zero + names 'egress'"
  else
    fail "M6 expected non-zero exit + 'egress' in error, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M7 — TOOL archetype missing required egress field aborts + names 'egress'
# ---------------------------------------------------------------------------
test_m7_tool_missing_egress_aborts() {
  setup_manifest_sandbox "manifest-hostile-tool-missing-egress.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "egress" "$stderr_file"; then
    pass "M7 TOOL missing required 'egress' field aborts + names 'egress'"
  else
    fail "M7 expected non-zero exit + 'egress' in error, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M8 — absent manifest yields the default stack (D8 regression contract)
# ---------------------------------------------------------------------------
test_m8_absent_manifest_yields_defaults() {
  setup_manifest_sandbox ""
  local stderr_file out exit_code tool_count
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_load "$stderr_file") || exit_code=$?
  # Default stack should contain at least: beads, dolt, gh, claude
  # (the current bundled tools — ADR-005 D8)
  local names
  names=$(jq -r '[.tools[].name] | sort | join(",")' <<<"$out" 2>/dev/null)
  tool_count=$(jq '.tools | length' <<<"$out" 2>/dev/null)
  # Must exit 0, must have tools, must include some of the known bundled stack
  if [[ "$exit_code" -eq 0 \
        && "${tool_count:-0}" -gt 0 \
        && "$names" == *"beads"* ]]; then
    pass "M8 absent manifest yields default stack ($tool_count tools, includes beads)"
  else
    fail "M8 expected default stack with beads, exit=$exit_code tool_count=${tool_count:-?} names=$names stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M9 — empty manifest (zero-byte) yields the default stack
# ---------------------------------------------------------------------------
test_m9_empty_manifest_yields_defaults() {
  setup_manifest_sandbox ""
  # Create an empty (zero-byte) manifest
  touch "${TEST_HOME}/.config/rip-cage/tools.yaml"
  local stderr_file out exit_code tool_count
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_load "$stderr_file") || exit_code=$?
  local names
  names=$(jq -r '[.tools[].name] | sort | join(",")' <<<"$out" 2>/dev/null)
  tool_count=$(jq '.tools | length' <<<"$out" 2>/dev/null)
  if [[ "$exit_code" -eq 0 \
        && "${tool_count:-0}" -gt 0 \
        && "$names" == *"beads"* ]]; then
    pass "M9 empty (zero-byte) manifest yields default stack ($tool_count tools, includes beads)"
  else
    fail "M9 expected default stack with beads, exit=$exit_code tool_count=${tool_count:-?} names=$names stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M10 — loader reads host path ONLY; assert the path resolves to the host
# config dir (XDG_CONFIG_HOME / ~/.config) never a /workspace path.
# The host-only FIRM property (ADR-005 D7) rests on rc running host-side
# (not copied into the image, env not forwarded into the cage), NOT on the
# path being unconditionally fixed.  These tests exercise the path-derivation
# logic in the host process.
# ---------------------------------------------------------------------------
test_m10_loader_reads_host_path_only() {
  setup_manifest_sandbox ""
  local manifest_path
  manifest_path=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_global_path")
  # Must resolve to the sandbox host config dir
  local expected_path="${TEST_HOME}/.config/rip-cage/tools.yaml"
  if [[ "$manifest_path" == "$expected_path" ]]; then
    pass "M10 loader path resolves to host config dir (${manifest_path})"
  else
    fail "M10 expected path=${expected_path}, got=${manifest_path}"
  fi
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M10b — loader path does not reference /workspace
# Asserts the path returned by _manifest_global_path does not reference
# /workspace.  This is a path-derivation assertion — it does not by itself
# prove agent-inaccessibility; that property rests on rc running host-side
# (not copied into the image, env not forwarded into the cage).
# ---------------------------------------------------------------------------
test_m10b_loader_path_not_workspace() {
  setup_manifest_sandbox ""
  local manifest_path
  manifest_path=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_global_path")
  if [[ "$manifest_path" != */workspace/* ]]; then
    pass "M10b loader path does not reference /workspace"
  else
    fail "M10b loader path references /workspace — violates host-only path expectation"
  fi
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# M10c — XDG_CONFIG_HOME redirect is honored (host-side operator override)
# Proves that the loader follows XDG_CONFIG_HOME when set — this is a
# legitimate host-side test/operator override mechanism.  Agent-inaccessibility
# is preserved because RC_MANIFEST_GLOBAL and XDG_CONFIG_HOME are host-side
# env vars: rc runs on the host and neither env var is forwarded into the
# container (ADR-005 D7 FIRM property).
# ---------------------------------------------------------------------------
test_m10c_xdg_config_home_redirect_honored() {
  local alt_config_dir
  alt_config_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-xdg-test-XXXXXX")
  mkdir -p "${alt_config_dir}/rip-cage"
  local expected_path="${alt_config_dir}/rip-cage/tools.yaml"
  local manifest_path
  # Override XDG_CONFIG_HOME to a different directory; HOME is unrelated
  manifest_path=$(HOME="/tmp" XDG_CONFIG_HOME="${alt_config_dir}" \
    bash -c "source '${RC}'; _manifest_global_path")
  if [[ "$manifest_path" == "$expected_path" ]]; then
    pass "M10c XDG_CONFIG_HOME redirect followed: path=${manifest_path}"
  else
    fail "M10c expected XDG redirect path=${expected_path}, got=${manifest_path}"
  fi
  rm -rf "$alt_config_dir"
}

# ---------------------------------------------------------------------------
# M11 — missing version_pin aborts non-zero + names 'version_pin' field
# version_pin is documented-required for all three archetypes (see comment
# block ~rc:6089-6091).  A TOOL/SHELL-INTEGRATION/IN-CAGE-DAEMON entry with
# no version_pin must be rejected by the validator (fail-closed contract).
# ---------------------------------------------------------------------------
test_m11_missing_version_pin_aborts() {
  setup_manifest_sandbox "manifest-hostile-missing-version-pin.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "version_pin" "$stderr_file"; then
    pass "M11 missing 'version_pin' field aborts non-zero + names 'version_pin'"
  else
    fail "M11 expected non-zero exit + 'version_pin' in error, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "=== test-manifest-schema.sh — tool manifest schema/loader (rip-cage-4c5.1) ==="
test_m1_tool_archetype_parses
test_m2_shell_integration_archetype_parses
test_m3_daemon_archetype_parses
test_m4_unknown_archetype_aborts
test_m5_missing_name_aborts
test_m6_malformed_egress_aborts
test_m7_tool_missing_egress_aborts
test_m8_absent_manifest_yields_defaults
test_m9_empty_manifest_yields_defaults
test_m10_loader_reads_host_path_only
test_m10b_loader_path_not_workspace
test_m10c_xdg_config_home_redirect_honored
test_m11_missing_version_pin_aborts

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
