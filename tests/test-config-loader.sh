#!/usr/bin/env bash
# Host-side unit tests for the .rip-cage.yaml loader (ADR-021, rip-cage-o4z).
#
# Coverage matrix:
#   D2 (per-field-type merge):
#     T1  additive list union (global + project both contribute, dedup)
#     T2  selection list — project replaces global when present
#     T3  selection list — project absent ⇒ inherit global
#     T4  selection list — explicit zero-out (project: [])
#     T5  scalar — project replaces global
#   D3 (schema versioning):
#     T6  missing version field ⇒ warn + assume version 1
#     T7  future version + selection-list field ⇒ ABORT (Option B)
#     T8  future version + additive-only ⇒ warn + skip file
#     T9  per-file version independence (global v1 ok, project v99 additive-only)
#   D4 (rc config show):
#     T10 YAML output contains provenance comments
#     T11 --json output has parallel .config + .provenance objects
#     T12 sha256 is stable across equivalent reorderings (canonical-form hash)
#   D5 (regression contract):
#     T13 both files absent ⇒ defaults emitted, no errors
#     T14 only global present ⇒ project absent, layers.project = null
#     T15 only project present ⇒ global absent, layers.global = null
#   yq dependency:
#     T16 yq missing on PATH ⇒ rc config show fails loud per ADR-001
#   D3 abort propagation through the substrate validation step:
#     T17 _config_validate_or_abort exits non-zero on selection-list+future-version
#         (covers ADR-021:177 invalidation check; the rc up / rc init contract)
#     T18 _config_validate_or_abort returns 0 silently when neither file exists
#         (D5 regression contract — substrate must not abort in the both-absent case)
#     T19 _config_validate_or_abort exits non-zero when a config file exists but
#         yq is missing (ADR-021 implementation notes: no silent degradation)
#
# Tests do NOT require docker — pure host-side loader logic only.
# Container label / first-run hint behavior is covered by e2e tests.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Build a sandbox HOME with optional global config + a workspace dir with
# optional project config. Sets globals: TEST_HOME, TEST_WS.
# Args: $1 = global fixture name (or "" to omit), $2 = project fixture name (or "" to omit)
setup_sandbox() {
  local global_fixture="$1" project_fixture="$2"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-config-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
  if [[ -n "$global_fixture" ]]; then
    cp "${FIXTURES}/${global_fixture}" "${TEST_HOME}/.config/rip-cage/config.yaml"
  fi
  if [[ -n "$project_fixture" ]]; then
    cp "${FIXTURES}/${project_fixture}" "${TEST_WS}/.rip-cage.yaml"
  fi
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
  TEST_WS=""
}

# Run rc config show in the sandbox (with sandbox HOME / XDG_CONFIG_HOME).
# Echoes stdout; stderr captured separately via $2 (file path) when given.
run_rc_config() {
  local args="$1" stderr_file="${2:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "cd '$TEST_WS' && '$RC' config $args" 2>"$stderr_file"
}

# ---------------------------------------------------------------------------
# D2 — per-field-type merge rules
# ---------------------------------------------------------------------------

test_t1_additive_union() {
  setup_sandbox "config-global-basic.yaml" "config-project-basic.yaml"
  local out hosts
  out=$(run_rc_config "show --json")
  hosts=$(jq -c '.config.ssh.allowed_hosts' <<<"$out")
  if [[ "$hosts" == '["github.com","switch.berlin"]' ]]; then
    pass "T1 additive list union (global ∪ project, order-preserving)"
  else
    fail "T1 expected [github.com, switch.berlin], got: $hosts"
  fi
  local prov
  prov=$(jq -c '.provenance["ssh.allowed_hosts"]' <<<"$out")
  if [[ "$prov" == '["global","project"]' ]]; then
    pass "T1b additive list provenance is union(global, project)"
  else
    fail "T1b expected [global,project], got: $prov"
  fi
  teardown_sandbox
}

test_t2_selection_replaces() {
  setup_sandbox "config-global-basic.yaml" "config-project-basic.yaml"
  local out keys prov
  out=$(run_rc_config "show --json")
  keys=$(jq -c '.config.ssh.allowed_keys' <<<"$out")
  prov=$(jq -r '.provenance["ssh.allowed_keys"]' <<<"$out")
  if [[ "$keys" == '["id_ed25519_personal"]' && "$prov" == "project" ]]; then
    pass "T2 selection list — project replaces global"
  else
    fail "T2 expected keys=[id_ed25519_personal] prov=project, got keys=$keys prov=$prov"
  fi
  teardown_sandbox
}

test_t3_selection_inherit_global() {
  setup_sandbox "config-global-basic.yaml" "config-project-only-additive.yaml"
  local out keys prov
  out=$(run_rc_config "show --json")
  keys=$(jq -c '.config.ssh.allowed_keys' <<<"$out")
  prov=$(jq -r '.provenance["ssh.allowed_keys"]' <<<"$out")
  if [[ "$keys" == '["id_ed25519_personal","id_ed25519_work"]' && "$prov" == "global" ]]; then
    pass "T3 selection list — project absent ⇒ inherit global"
  else
    fail "T3 expected keys=both prov=global, got keys=$keys prov=$prov"
  fi
  teardown_sandbox
}

test_t4_selection_zero_out() {
  setup_sandbox "config-global-basic.yaml" "config-project-zero-out-keys.yaml"
  local out keys prov
  out=$(run_rc_config "show --json")
  keys=$(jq -c '.config.ssh.allowed_keys' <<<"$out")
  prov=$(jq -r '.provenance["ssh.allowed_keys"]' <<<"$out")
  if [[ "$keys" == '[]' && "$prov" == "project" ]]; then
    pass "T4 selection list — explicit zero-out ([]) honored"
  else
    fail "T4 expected keys=[] prov=project, got keys=$keys prov=$prov"
  fi
  teardown_sandbox
}

test_t5_scalar_replaces() {
  setup_sandbox "config-global-basic.yaml" "config-project-basic.yaml"
  local out version prov
  out=$(run_rc_config "show --json")
  version=$(jq -r '.config.version' <<<"$out")
  prov=$(jq -r '.provenance.version' <<<"$out")
  # Both files declare version: 1 → scalar rule says project replaces.
  if [[ "$version" == "1" && "$prov" == "project" ]]; then
    pass "T5 scalar — project replaces global"
  else
    fail "T5 expected version=1 prov=project, got version=$version prov=$prov"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# D3 — schema versioning
# ---------------------------------------------------------------------------

test_t6_missing_version_warns() {
  setup_sandbox "" "config-project-missing-version.yaml"
  local stderr_file
  stderr_file=$(mktemp)
  run_rc_config "show --json" "$stderr_file" >/dev/null
  if grep -q "has no 'version:' field" "$stderr_file"; then
    pass "T6 missing version field warns loud"
  else
    fail "T6 expected warning about missing version, got: $(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

test_t7_future_version_with_selection_aborts() {
  setup_sandbox "" "config-project-future-version-with-selection.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  out=$(run_rc_config "show --json" "$stderr_file") || exit_code=$?
  exit_code="${exit_code:-0}"
  if [[ "$exit_code" -ne 0 ]] && grep -q "selection-list field(s) \[ssh.allowed_keys\]" "$stderr_file"; then
    pass "T7 future version + selection-list field ⇒ abort with field-named error"
  else
    fail "T7 expected non-zero exit + selection-list error, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

test_t8_future_version_additive_only_skips() {
  setup_sandbox "" "config-project-future-version-additive-only.yaml"
  local stderr_file out exit_code hosts
  stderr_file=$(mktemp)
  out=$(run_rc_config "show --json" "$stderr_file") || exit_code=$?
  exit_code="${exit_code:-0}"
  hosts=$(jq -c '.config.ssh.allowed_hosts' <<<"$out")
  if [[ "$exit_code" -eq 0 ]] \
     && grep -q "Skipping this file" "$stderr_file" \
     && [[ "$hosts" == '[]' ]]; then
    pass "T8 future version + additive-only ⇒ warn+skip; effective omits file's contents"
  else
    fail "T8 expected exit=0 + skip warning + empty hosts, exit=$exit_code stderr=$(cat "$stderr_file") hosts=$hosts"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

test_t9_per_file_version_independence() {
  # Global v1 (loads), project v99 additive-only (skipped).
  setup_sandbox "config-global-basic.yaml" "config-project-future-version-additive-only.yaml"
  local out hosts keys
  out=$(run_rc_config "show --json" /dev/null)
  hosts=$(jq -c '.config.ssh.allowed_hosts' <<<"$out")
  keys=$(jq -c '.config.ssh.allowed_keys' <<<"$out")
  # Global contributes; project is skipped (not merged).
  if [[ "$hosts" == '["github.com"]' && "$keys" == '["id_ed25519_personal","id_ed25519_work"]' ]]; then
    pass "T9 per-file version independence — global loads, project v99 skipped"
  else
    fail "T9 expected hosts=[github.com] keys=both, got hosts=$hosts keys=$keys"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# D4 — rc config show
# ---------------------------------------------------------------------------

test_t10_yaml_provenance_comments() {
  setup_sandbox "config-global-basic.yaml" "config-project-basic.yaml"
  local out
  out=$(run_rc_config "show")
  if echo "$out" | grep -q "from project" \
     && echo "$out" | grep -q "union(global, project)" \
     && echo "$out" | grep -q "# global" \
     && echo "$out" | grep -q "# project"; then
    pass "T10 YAML output includes field-level + per-element provenance comments"
  else
    fail "T10 missing one or more provenance markers; output:
$out"
  fi
  teardown_sandbox
}

test_t11_json_parallel_structure() {
  setup_sandbox "config-global-basic.yaml" "config-project-basic.yaml"
  local out
  out=$(run_rc_config "show --json")
  local has_config has_prov has_layers has_sha
  has_config=$(jq 'has("config")' <<<"$out")
  has_prov=$(jq 'has("provenance")' <<<"$out")
  has_layers=$(jq 'has("layers")' <<<"$out")
  has_sha=$(jq 'has("sha256")' <<<"$out")
  if [[ "$has_config" == "true" && "$has_prov" == "true" \
        && "$has_layers" == "true" && "$has_sha" == "true" ]]; then
    pass "T11 --json has .config / .provenance / .layers / .sha256"
  else
    fail "T11 missing top-level keys; got: $(jq -c 'keys' <<<"$out")"
  fi
  teardown_sandbox
}

test_t12_sha256_canonical() {
  setup_sandbox "config-global-basic.yaml" "config-project-basic.yaml"
  local sha1
  sha1=$(run_rc_config "show --json" | jq -r '.sha256')
  # Reorder the project file (semantically equivalent).
  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
ssh:
  allowed_hosts:
    - switch.berlin
  allowed_keys:
    - id_ed25519_personal
version: 1
YAML
  local sha2
  sha2=$(run_rc_config "show --json" | jq -r '.sha256')
  if [[ "$sha1" == "$sha2" && -n "$sha1" ]]; then
    pass "T12 sha256 stable across key reordering (canonical-form hash)"
  else
    fail "T12 sha256 changed on reorder: $sha1 vs $sha2"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# D5 — regression contract
# ---------------------------------------------------------------------------

test_t13_both_absent_defaults() {
  setup_sandbox "" ""
  local out exit_code
  exit_code=0
  out=$(run_rc_config "show --json") || exit_code=$?
  local g_layer p_layer
  g_layer=$(jq -r '.layers.global' <<<"$out")
  p_layer=$(jq -r '.layers.project' <<<"$out")
  if [[ "$exit_code" -eq 0 && "$g_layer" == "null" && "$p_layer" == "null" ]]; then
    pass "T13 both files absent ⇒ defaults emitted, no errors"
  else
    fail "T13 expected exit=0 + null layers, exit=$exit_code g=$g_layer p=$p_layer"
  fi
  teardown_sandbox
}

test_t14_only_global() {
  setup_sandbox "config-global-basic.yaml" ""
  local out g_layer p_layer keys
  out=$(run_rc_config "show --json")
  g_layer=$(jq -r '.layers.global' <<<"$out")
  p_layer=$(jq -r '.layers.project' <<<"$out")
  keys=$(jq -c '.config.ssh.allowed_keys' <<<"$out")
  if [[ "$g_layer" != "null" && "$p_layer" == "null" \
        && "$keys" == '["id_ed25519_personal","id_ed25519_work"]' ]]; then
    pass "T14 only global present ⇒ project null, global values applied"
  else
    fail "T14 unexpected: g=$g_layer p=$p_layer keys=$keys"
  fi
  teardown_sandbox
}

test_t15_only_project() {
  setup_sandbox "" "config-project-basic.yaml"
  local out g_layer p_layer hosts
  out=$(run_rc_config "show --json")
  g_layer=$(jq -r '.layers.global' <<<"$out")
  p_layer=$(jq -r '.layers.project' <<<"$out")
  hosts=$(jq -c '.config.ssh.allowed_hosts' <<<"$out")
  if [[ "$g_layer" == "null" && "$p_layer" != "null" \
        && "$hosts" == '["switch.berlin"]' ]]; then
    pass "T15 only project present ⇒ global null, project values applied"
  else
    fail "T15 unexpected: g=$g_layer p=$p_layer hosts=$hosts"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# yq dependency (ADR-001 fail-loud)
# ---------------------------------------------------------------------------

test_t16_yq_missing_fails_loud() {
  setup_sandbox "" "config-project-basic.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  # Run with PATH that excludes yq.
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    PATH="/usr/bin:/bin" \
    bash -c "cd '$TEST_WS' && '$RC' config show" 2>"$stderr_file" >/dev/null \
    || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -q "yq not found on PATH" "$stderr_file"; then
    pass "T16 yq missing ⇒ fail-loud per ADR-001 (no silent degradation)"
  else
    fail "T16 expected non-zero + 'yq not found' error, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# D3 abort propagation through the substrate validation step
# (ADR-021:177 invalidation check; the rc up / rc init contract)
# ---------------------------------------------------------------------------
#
# Direct tests of _config_validate_or_abort — the central gate that cmd_up
# and cmd_init both call. We source rc to pick up the function, then
# invoke it in subshells so abort=exit doesn't take down the test harness.

# Source rc functions in a way that doesn't trigger top-level dispatch.
_source_rc_for_validate_tests() {
  # rc has a sourced-vs-invoked guard: BASH_SOURCE != 0 short-circuits.
  # shellcheck disable=SC1090
  source "$RC"
}

test_t17_validate_aborts_on_selection_list_future_version() {
  setup_sandbox "" "config-project-future-version-with-selection.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '$RC'; _config_validate_or_abort '$TEST_WS'" 2>"$stderr_file" \
    || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] \
     && grep -q "selection-list field(s) \[ssh.allowed_keys\]" "$stderr_file"; then
    pass "T17 _config_validate_or_abort exits non-zero on selection-list+future-version"
  else
    fail "T17 expected non-zero exit + selection-list error, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

test_t18_validate_silent_no_config() {
  setup_sandbox "" ""
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '$RC'; _config_validate_or_abort '$TEST_WS'" 2>"$stderr_file" \
    || exit_code=$?
  local stderr_content
  stderr_content=$(cat "$stderr_file")
  if [[ "$exit_code" -eq 0 && -z "$stderr_content" ]]; then
    pass "T18 _config_validate_or_abort silent when neither file exists (D5 regression)"
  else
    fail "T18 expected exit=0 + empty stderr, exit=$exit_code stderr=$stderr_content"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

test_t19_validate_yq_missing_with_config_aborts() {
  setup_sandbox "" "config-project-basic.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    PATH="/usr/bin:/bin" \
    bash -c "source '$RC'; _config_validate_or_abort '$TEST_WS'" 2>"$stderr_file" \
    || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -q "yq not found on PATH" "$stderr_file"; then
    pass "T19 _config_validate_or_abort fails loud when yq missing + config present"
  else
    fail "T19 expected non-zero + yq error, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# mounts.symlinks.* config group (acceptance 13, 14, 15 — bead rip-cage-c1p.2)
# T20: default emission with mounts.symlinks default config (follow/file/rw)
# T21: mounts.symlinks.on_dangling=invalid aborts loud per ADR-021 D3
# T22: mounts.symlinks.mode=invalid aborts loud per ADR-021 D3
# T23: future-version YAML with mounts.symlinks.* selection-list field aborts
# ---------------------------------------------------------------------------

test_t20_mounts_symlinks_default_emission() {
  # T16 (bead): mounts.symlinks.* defaults: follow/file/rw emitted with no config
  setup_sandbox "" ""
  local out on_dangling scope mode
  out=$(run_rc_config "show --json")
  on_dangling=$(jq -r '.config.mounts.symlinks.on_dangling // "MISSING"' <<<"$out")
  scope=$(jq -r '.config.mounts.symlinks.scope // "MISSING"' <<<"$out")
  mode=$(jq -r '.config.mounts.symlinks.mode // "MISSING"' <<<"$out")
  if [[ "$on_dangling" == "follow" && "$scope" == "file" && "$mode" == "rw" ]]; then
    pass "T20 mounts.symlinks.* defaults: on_dangling=follow scope=file mode=rw"
  else
    fail "T20 expected follow/file/rw defaults, got on_dangling=$on_dangling scope=$scope mode=$mode"
  fi
  teardown_sandbox
}

test_t21_mounts_symlinks_on_dangling_invalid_aborts() {
  # T17 (bead): mounts.symlinks.on_dangling=invalid aborts loud per ADR-021 D3
  setup_sandbox "" "config-project-mounts-symlinks-unknown-enum.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_rc_config "show --json" "$stderr_file") || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    pass "T21 mounts.symlinks.on_dangling=invalid aborts loud per ADR-021 D3"
  else
    fail "T21 expected non-zero exit for invalid on_dangling, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

test_t22_mounts_symlinks_mode_invalid_aborts() {
  # T18 (bead): mounts.symlinks.mode=invalid aborts loud per ADR-021 D3
  setup_sandbox "" ""
  # Create inline config with invalid mode value
  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 1
mounts:
  symlinks:
    on_dangling: follow
    scope: file
    mode: invalid_mode
YAML
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_rc_config "show --json" "$stderr_file") || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    pass "T22 mounts.symlinks.mode=invalid aborts loud per ADR-021 D3"
  else
    fail "T22 expected non-zero exit for invalid mode, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  # Don't call teardown_sandbox here — setup_sandbox wasn't called
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
  TEST_WS=""
}

test_t23_mounts_symlinks_with_project_default_fixture() {
  # T15 variant: mounts.symlinks fixture loads and produces nested config
  setup_sandbox "" "config-project-mounts-symlinks-default.yaml"
  local out on_dangling scope mode prov
  out=$(run_rc_config "show --json")
  on_dangling=$(jq -r '.config.mounts.symlinks.on_dangling // "MISSING"' <<<"$out")
  scope=$(jq -r '.config.mounts.symlinks.scope // "MISSING"' <<<"$out")
  mode=$(jq -r '.config.mounts.symlinks.mode // "MISSING"' <<<"$out")
  prov=$(jq -r '.provenance["mounts.symlinks.on_dangling"] // "MISSING"' <<<"$out")
  if [[ "$on_dangling" == "follow" && "$scope" == "file" && "$mode" == "rw" && "$prov" == "project" ]]; then
    pass "T23 mounts.symlinks default fixture: follow/file/rw from project"
  else
    fail "T23 expected follow/file/rw prov=project, got on_dangling=$on_dangling scope=$scope mode=$mode prov=$prov"
  fi
  teardown_sandbox
}

test_t24_mounts_symlinks_ro_fixture() {
  # mounts.symlinks.mode=ro fixture loads correctly
  setup_sandbox "" "config-project-mounts-symlinks-ro.yaml"
  local out mode prov
  out=$(run_rc_config "show --json")
  mode=$(jq -r '.config.mounts.symlinks.mode // "MISSING"' <<<"$out")
  prov=$(jq -r '.provenance["mounts.symlinks.mode"] // "MISSING"' <<<"$out")
  if [[ "$mode" == "ro" && "$prov" == "project" ]]; then
    pass "T24 mounts.symlinks.mode=ro fixture: mode=ro from project"
  else
    fail "T24 expected mode=ro prov=project, got mode=$mode prov=$prov"
  fi
  teardown_sandbox
}

test_t25_mounts_symlinks_parent_fixture() {
  # mounts.symlinks.scope=parent fixture loads correctly
  setup_sandbox "" "config-project-mounts-symlinks-parent.yaml"
  local out scope
  out=$(run_rc_config "show --json")
  scope=$(jq -r '.config.mounts.symlinks.scope // "MISSING"' <<<"$out")
  if [[ "$scope" == "parent" ]]; then
    pass "T25 mounts.symlinks.scope=parent fixture: scope=parent from project"
  else
    fail "T25 expected scope=parent, got scope=$scope"
  fi
  teardown_sandbox
}

test_t26_config_show_mounts_symlinks_nested_yaml() {
  # acc 2: rc config show renders mounts.symlinks.* as nested YAML group
  setup_sandbox "" "config-project-mounts-symlinks-default.yaml"
  local out
  out=$(run_rc_config "show")
  if echo "$out" | grep -q "^mounts:" \
     && echo "$out" | grep -q "  symlinks:" \
     && echo "$out" | grep -q "    on_dangling:"; then
    pass "T26 rc config show renders mounts.symlinks.* as nested YAML group"
  else
    fail "T26 expected nested YAML group, got:
$out"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "=== test-config-loader.sh — ADR-021 layered config loader ==="
test_t1_additive_union
test_t2_selection_replaces
test_t3_selection_inherit_global
test_t4_selection_zero_out
test_t5_scalar_replaces
test_t6_missing_version_warns
test_t7_future_version_with_selection_aborts
test_t8_future_version_additive_only_skips
test_t9_per_file_version_independence
test_t10_yaml_provenance_comments
test_t11_json_parallel_structure
test_t12_sha256_canonical
test_t13_both_absent_defaults
test_t14_only_global
test_t15_only_project
test_t16_yq_missing_fails_loud
test_t17_validate_aborts_on_selection_list_future_version
test_t18_validate_silent_no_config
test_t19_validate_yq_missing_with_config_aborts
test_t20_mounts_symlinks_default_emission
test_t21_mounts_symlinks_on_dangling_invalid_aborts
test_t22_mounts_symlinks_mode_invalid_aborts
test_t23_mounts_symlinks_with_project_default_fixture
test_t24_mounts_symlinks_ro_fixture
test_t25_mounts_symlinks_parent_fixture
test_t26_config_show_mounts_symlinks_nested_yaml

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
