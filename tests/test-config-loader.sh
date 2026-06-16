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
#     T39 _config_validate_or_abort: global config present + yq absent ⇒ non-zero
#         exit AND stderr names "rip-cage config dependency" (rip-cage-j86 review)
#
# Tests do NOT require docker — pure host-side loader logic only.
# Container label / first-run hint behavior is covered by e2e tests.

set -uo pipefail

# tests/run-host.sh exports RC_CONFIG_GLOBAL pointing to an empty-denylist fixture
# for the whole suite. RC_CONFIG_GLOBAL takes precedence over XDG_CONFIG_HOME in
# _config_global_path (rc:6207-6208), so per-call XDG sandboxes get silently
# shadowed — tests that build their own global config see the fixture's empty config
# instead, causing 16/39 failures. Unset here so per-call XDG sandboxes resolve
# correctly.
# Mirror of the fix in tests/test-secret-path-denylist.sh (see run-host.sh:102-109).
unset RC_CONFIG_GLOBAL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

_NO_YQ_BINDIR=""

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  [[ -n "${_NO_YQ_BINDIR:-}" && -d "${_NO_YQ_BINDIR:-}" ]] && rm -rf "$_NO_YQ_BINDIR"
}
trap cleanup EXIT

# _make_no_yq_path: return a PATH string that includes essential tools but NOT yq.
# Creates a temp bindir (once; cached in _NO_YQ_BINDIR) with symlinks to needed tools
# from their real locations, deliberately omitting yq — so `command -v yq` fails
# regardless of where the system installed yq (e.g. /usr/bin/yq on ubuntu-latest).
_make_no_yq_path() {
  if [[ -z "${_NO_YQ_BINDIR:-}" ]]; then
    _NO_YQ_BINDIR=$(mktemp -d)
    local tool loc
    # Symlink all tools rc may call from within config commands (except yq).
    for tool in bash sh env cat grep sed awk sort uniq cut tr wc head tail find \
                xargs mktemp realpath readlink rm mkdir cp mv chmod touch printf tee \
                date id uname pwd ls jq python3 dirname basename stat file \
                docker git curl wget; do
      loc=$(command -v "$tool" 2>/dev/null) || continue
      ln -sf "$loc" "${_NO_YQ_BINDIR}/${tool}" 2>/dev/null || true
    done
    # Deliberately do NOT symlink yq — that's the whole point.
  fi
  echo "$_NO_YQ_BINDIR"
}

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
  local stderr_file exit_code no_yq_path
  stderr_file=$(mktemp)
  exit_code=0
  # Run with a sanitized PATH that has the tools rc needs but NOT yq,
  # so `command -v yq` fails regardless of where the system installed yq
  # (e.g. /usr/bin/yq on ubuntu-latest, /usr/local/bin/yq on macOS).
  no_yq_path=$(_make_no_yq_path)
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    PATH="$no_yq_path" \
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
  local stderr_file exit_code no_yq_path
  stderr_file=$(mktemp)
  exit_code=0
  no_yq_path=$(_make_no_yq_path)
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    PATH="$no_yq_path" \
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
# mounts.denylist + mounts.allow_risky schema fields (ADR-023, rip-cage-3gu.1)
# T27: mounts.denylist parses from global config layer
# T28: mounts.denylist parses from project config layer
# T29: mounts.denylist merges additively across layers (global + project = union)
# T30: mounts.allow_risky parses (selection_list semantics)
# ---------------------------------------------------------------------------

test_t27_mounts_denylist_from_global() {
  # mounts.denylist (additive_list) parses from global config layer
  setup_sandbox "config-global-with-denylist.yaml" ""
  local out denylist prov
  out=$(run_rc_config "show --json")
  denylist=$(jq -c '.config.mounts.denylist' <<<"$out")
  prov=$(jq -r '.provenance["mounts.denylist"]' <<<"$out")
  if [[ "$denylist" == '[".aws",".ssh"]' && "$prov" == "global" ]]; then
    pass "T27 mounts.denylist parses from global config layer"
  else
    fail "T27 expected denylist=[.aws,.ssh] prov=global, got denylist=$denylist prov=$prov"
  fi
  teardown_sandbox
}

test_t28_mounts_denylist_from_project() {
  # mounts.denylist (additive_list) parses from project config layer
  setup_sandbox "" "config-project-with-denylist.yaml"
  local out denylist prov
  out=$(run_rc_config "show --json")
  denylist=$(jq -c '.config.mounts.denylist' <<<"$out")
  prov=$(jq -r '.provenance["mounts.denylist"]' <<<"$out")
  if [[ "$denylist" == '[".env"]' && "$prov" == "project" ]]; then
    pass "T28 mounts.denylist parses from project config layer"
  else
    fail "T28 expected denylist=[.env] prov=project, got denylist=$denylist prov=$prov"
  fi
  teardown_sandbox
}

test_t29_mounts_denylist_additive_merge() {
  # mounts.denylist merges additively across layers
  # global: [.aws, .ssh], project: [.env] → effective: [.aws, .ssh, .env]
  setup_sandbox "config-global-with-denylist.yaml" "config-project-with-denylist.yaml"
  local out denylist prov
  out=$(run_rc_config "show --json")
  denylist=$(jq -c '.config.mounts.denylist' <<<"$out")
  prov=$(jq -c '.provenance["mounts.denylist"]' <<<"$out")
  if [[ "$denylist" == '[".aws",".ssh",".env"]' ]]; then
    pass "T29 mounts.denylist additive merge: global [.aws,.ssh] + project [.env] = [.aws,.ssh,.env]"
  else
    fail "T29 expected [.aws,.ssh,.env], got: $denylist (prov=$prov)"
  fi
  teardown_sandbox
}

test_t30_mounts_allow_risky_selection_list() {
  # mounts.allow_risky (selection_list) parses; project replaces global when present
  setup_sandbox "" "config-project-with-allow-risky.yaml"
  local out allow_risky prov
  out=$(run_rc_config "show --json")
  allow_risky=$(jq -c '.config.mounts.allow_risky' <<<"$out")
  prov=$(jq -r '.provenance["mounts.allow_risky"]' <<<"$out")
  if [[ "$allow_risky" == '["/home/user/.aws/credentials"]' && "$prov" == "project" ]]; then
    pass "T30 mounts.allow_risky selection_list parses from project"
  else
    fail "T30 expected allow_risky=[/home/user/.aws/credentials] prov=project, got allow_risky=$allow_risky prov=$prov"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# network.* config fields (ADR-021, rip-cage-hhh.1)
# T31: network.allowed_hosts parses from global config layer (additive_list)
# T32: network.allowed_hosts merges additively across layers (global + project = union)
# T33: v1 config with no network.* fields parses unchanged with empty defaults
# T34: network.mode selection_list parses (observe/block); project replaces global
# T35: absent network.mode resolves to null/default (not a third mode value string)
# T36: network.writable_hosts in config file is silently ignored (field removed in rip-cage-ta1o.1)
# T37: network.writable_hosts absent from effective config (field removed in rip-cage-ta1o.1)
# T38: network.mode invalid value aborts loud per ADR-021 D3
# ---------------------------------------------------------------------------

test_t31_network_allowed_hosts_from_global() {
  setup_sandbox "config-global-with-network.yaml" ""
  local out hosts prov
  out=$(run_rc_config "show --json")
  hosts=$(jq -c '.config.network.allowed_hosts' <<<"$out")
  prov=$(jq -r '.provenance["network.allowed_hosts"]' <<<"$out")
  if [[ "$hosts" == '["api.github.com","pypi.org"]' && "$prov" == "global" ]]; then
    pass "T31 network.allowed_hosts parses from global config layer"
  else
    fail "T31 expected hosts=[api.github.com,pypi.org] prov=global, got hosts=$hosts prov=$prov"
  fi
  teardown_sandbox
}

test_t32_network_allowed_hosts_additive_merge() {
  # global: [api.github.com, pypi.org], project: [registry.npmjs.org]
  # effective: [api.github.com, pypi.org, registry.npmjs.org]
  setup_sandbox "config-global-with-network.yaml" "config-project-with-network.yaml"
  local out hosts prov
  out=$(run_rc_config "show --json")
  hosts=$(jq -c '.config.network.allowed_hosts' <<<"$out")
  prov=$(jq -c '.provenance["network.allowed_hosts"]' <<<"$out")
  if [[ "$hosts" == '["api.github.com","pypi.org","registry.npmjs.org"]' ]]; then
    pass "T32 network.allowed_hosts additive merge: global + project = union"
  else
    fail "T32 expected [api.github.com,pypi.org,registry.npmjs.org], got: $hosts (prov=$prov)"
  fi
  teardown_sandbox
}

test_t33_v1_config_no_network_parses_unchanged() {
  # Existing v1 config with no network.* → empty defaults, no error.
  # Note: writable_hosts removed from schema in rip-cage-ta1o.1 (write-gate deleted).
  # The field is no longer in the effective config output.
  setup_sandbox "config-global-basic.yaml" "config-project-basic.yaml"
  local out hosts mode
  out=$(run_rc_config "show --json")
  hosts=$(jq -c '.config.network.allowed_hosts' <<<"$out")
  mode=$(jq -r '.config.network.mode' <<<"$out")
  # ssh fields still present
  local ssh_hosts
  ssh_hosts=$(jq -c '.config.ssh.allowed_hosts' <<<"$out")
  if [[ "$hosts" == '[]' && "$mode" == "null" \
        && "$ssh_hosts" == '["github.com","switch.berlin"]' ]]; then
    pass "T33 v1 config with no network.* parses unchanged, empty defaults"
  else
    fail "T33 expected empty network defaults (allowed_hosts=[], mode=null) + ssh unchanged, got hosts=$hosts mode=$mode ssh_hosts=$ssh_hosts"
  fi
  teardown_sandbox
}

test_t34_network_mode_selection_list() {
  # network.mode from global (block); check it parses and provenance is global
  setup_sandbox "config-global-with-network.yaml" ""
  local out mode prov
  out=$(run_rc_config "show --json")
  mode=$(jq -r '.config.network.mode' <<<"$out")
  prov=$(jq -r '.provenance["network.mode"]' <<<"$out")
  if [[ "$mode" == "block" && "$prov" == "global" ]]; then
    pass "T34 network.mode=block parses from global, prov=global"
  else
    fail "T34 expected mode=block prov=global, got mode=$mode prov=$prov"
  fi
  teardown_sandbox
}

test_t35_absent_network_mode_is_null_not_enum() {
  # network.mode absent from all configs → null (not "legacy" or any string value)
  setup_sandbox "" ""
  local out mode prov
  out=$(run_rc_config "show --json")
  mode=$(jq -r '.config.network.mode' <<<"$out")
  prov=$(jq -r '.provenance["network.mode"]' <<<"$out")
  # mode must be null (JSON null), not any string like "legacy", "off", etc.
  if [[ "$mode" == "null" && "$prov" == "default" ]]; then
    pass "T35 absent network.mode resolves to null (default), not a third mode string"
  else
    fail "T35 expected mode=null prov=default, got mode=$mode prov=$prov"
  fi
  teardown_sandbox
}

test_t36_network_writable_hosts_unknown_field_ignored() {
  # rip-cage-ta1o.1: network.writable_hosts removed from schema (write-gate deleted).
  # A config file that still has network.writable_hosts should be silently accepted
  # (unknown fields in YAML files are not an error — the loader only reads schema keys).
  # The old test asserted abort-loud; that constraint is gone.
  setup_sandbox "" "config-project-network-writable-violation.yaml"
  local out exit_code
  exit_code=0
  out=$(run_rc_config "show --json") || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "T36 config with writable_hosts (removed field) is accepted silently (write-gate deleted, rip-cage-ta1o.1)"
  else
    fail "T36 expected exit 0 (writable_hosts is now an unknown/ignored field), got exit=$exit_code"
  fi
  teardown_sandbox
}

test_t37_network_writable_hosts_removed_from_schema() {
  # rip-cage-ta1o.1: network.writable_hosts removed from schema (write-gate deleted).
  # The effective config no longer contains network.writable_hosts at all.
  # This test verifies the field is absent from the effective config output,
  # replacing the old T37 which tested additive merge of a now-removed field.
  setup_sandbox "config-global-with-network.yaml" "config-project-with-network.yaml"
  local out
  out=$(run_rc_config "show --json")
  # The field must not appear in the effective config
  if ! echo "$out" | jq -e '.config.network | has("writable_hosts")' >/dev/null 2>&1; then
    pass "T37 network.writable_hosts absent from effective config (removed in rip-cage-ta1o.1)"
  else
    local writable
    writable=$(jq -c '.config.network.writable_hosts' <<<"$out")
    fail "T37 network.writable_hosts unexpectedly present in effective config: $writable"
  fi
  teardown_sandbox
}

test_t38_network_mode_invalid_aborts() {
  # network.mode with invalid value aborts loud
  setup_sandbox "" ""
  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 1
network:
  mode: turbo_firewall
YAML
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_rc_config "show --json" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    pass "T38 network.mode=invalid aborts loud per ADR-021 D3"
  else
    fail "T38 expected non-zero exit for invalid network.mode, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
  TEST_WS=""
}

# ---------------------------------------------------------------------------
# T39: yq absent + GLOBAL config present ⇒ fail-loud with dependency message
# (rip-cage-j86 review: acceptance bullet "yq absent + config present → accurate
# message naming yq as a rip-cage config dependency")
# ---------------------------------------------------------------------------

test_t39_validate_yq_missing_with_global_config_emits_dependency_message() {
  setup_sandbox "config-global-basic.yaml" ""
  local stderr_file exit_code no_yq_path
  stderr_file=$(mktemp)
  exit_code=0
  no_yq_path=$(_make_no_yq_path)
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    PATH="$no_yq_path" \
    bash -c "source '$RC'; _config_validate_or_abort '$TEST_WS'" 2>"$stderr_file" \
    || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -q "rip-cage config dependency" "$stderr_file"; then
    pass "T39 yq absent + global config present ⇒ non-zero exit + 'rip-cage config dependency' in stderr"
  else
    fail "T39 expected non-zero exit + 'rip-cage config dependency' message, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# session.multiplexer config field (ADR-021 D6, rip-cage-1f59.1)
# T40: session.multiplexer absent ⇒ default "none"
# T41: session.multiplexer: tmux ⇒ parses as tmux, prov=project
# T42: session.multiplexer: invalid value ⇒ aborts loud per ADR-001
# ---------------------------------------------------------------------------

test_t40_session_multiplexer_default_none() {
  # When session.multiplexer is absent, it defaults to "none"
  setup_sandbox "" ""
  local out mux
  out=$(run_rc_config "show --json")
  mux=$(jq -r '.config.session.multiplexer // "MISSING"' <<<"$out")
  if [[ "$mux" == "none" ]]; then
    pass "T40 session.multiplexer absent ⇒ default 'none'"
  else
    fail "T40 expected 'none' default, got: $mux"
  fi
  teardown_sandbox
}

test_t41_session_multiplexer_tmux_parses() {
  # session.multiplexer: tmux parses correctly with project provenance.
  # rip-cage-61al.4: tmux is now dynamic (manifest/registry-derived), not static.
  # Must declare tmux as a MULTIPLEXER in the manifest for config-validate to accept it.
  #
  # RC_MUX_INSPECT_IMAGE is pinned to a nonexistent tag so _config_mux_derive_allowed_set
  # deterministically takes the image-absent path → manifest-enumeration fallback.
  # Without this pin, the test would read the host's rip-cage:latest label, making
  # the result host-state-dependent (rip-cage-61al.4 review, Finding 2).
  setup_sandbox "" "config-project-multiplexer-tmux.yaml"
  # Seed a tools.yaml with tmux as a MULTIPLEXER so the manifest-enumeration
  # fallback accepts it (pre-build path; no real image needed for this test).
  cp "${FIXTURES}/manifest-tmux-provider.yaml" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  local out mux prov
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MUX_INSPECT_IMAGE="rip-cage:nonexistent-isolation-t41" \
    bash -c "cd '$TEST_WS' && '$RC' config show --json")
  mux=$(jq -r '.config.session.multiplexer' <<<"$out")
  prov=$(jq -r '.provenance["session.multiplexer"]' <<<"$out")
  if [[ "$mux" == "tmux" && "$prov" == "project" ]]; then
    pass "T41 session.multiplexer=tmux parses from project, prov=project (tmux declared in manifest)"
  else
    fail "T41 expected mux=tmux prov=project, got mux=$mux prov=$prov"
  fi
  teardown_sandbox
}

test_t42_session_multiplexer_invalid_aborts() {
  # session.multiplexer: zellij (invalid) ⇒ aborts loud per ADR-001 / ADR-021 D3
  setup_sandbox "" "config-project-multiplexer-invalid.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_rc_config "show --json" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    pass "T42 session.multiplexer=invalid aborts loud per ADR-021 D3"
  else
    fail "T42 expected non-zero exit for invalid session.multiplexer, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# network.egress.mediator config field (ADR-026 D5, rip-cage-ta1o.5.1)
# T43: network.egress.mediator absent ⇒ default "none"
# T44: network.egress.mediator: my-proxy ⇒ parses as my-proxy, prov=project
#      (manifest declares "my-proxy" as MEDIATOR; image-absent path → manifest fallback)
# T45: network.egress.mediator: unknown-mediator ⇒ aborts loud per ADR-001
# ---------------------------------------------------------------------------

test_t43_network_egress_mediator_default_none() {
  # When network.egress.mediator is absent, it defaults to "none"
  setup_sandbox "" ""
  local out mediator
  out=$(run_rc_config "show --json")
  mediator=$(jq -r '.config.network.egress.mediator // "MISSING"' <<<"$out")
  if [[ "$mediator" == "none" ]]; then
    pass "T43 network.egress.mediator absent ⇒ default 'none'"
  else
    fail "T43 expected 'none' default, got: $mediator"
  fi
  teardown_sandbox
}

test_t44_network_egress_mediator_declared_parses() {
  # network.egress.mediator: my-proxy parses correctly with project provenance.
  # Isomorphic to T41 (session.multiplexer=tmux).
  # RC_MEDIATOR_INSPECT_IMAGE is pinned to a nonexistent tag so
  # _config_mediator_derive_allowed_set deterministically takes the image-absent
  # path → manifest-enumeration fallback.
  setup_sandbox "" "config-project-mediator-myproxy.yaml"
  # Seed a tools.yaml with my-proxy as a MEDIATOR so the manifest-enumeration
  # fallback accepts it (pre-build path; no real image needed for this test).
  cp "${FIXTURES}/manifest-mediator-provider.yaml" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  local out mediator prov
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MEDIATOR_INSPECT_IMAGE="rip-cage:nonexistent-isolation-t44" \
    bash -c "cd '$TEST_WS' && '$RC' config show --json")
  mediator=$(jq -r '.config.network.egress.mediator' <<<"$out")
  prov=$(jq -r '.provenance["network.egress.mediator"]' <<<"$out")
  if [[ "$mediator" == "my-proxy" && "$prov" == "project" ]]; then
    pass "T44 network.egress.mediator=my-proxy parses from project, prov=project (my-proxy declared in manifest)"
  else
    fail "T44 expected mediator=my-proxy prov=project, got mediator=$mediator prov=$prov"
  fi
  teardown_sandbox
}

test_t45_network_egress_mediator_invalid_aborts() {
  # network.egress.mediator: unknown-mediator-not-in-manifest ⇒ aborts loud per ADR-001
  setup_sandbox "" "config-project-mediator-invalid.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_rc_config "show --json" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    pass "T45 network.egress.mediator=unknown aborts loud per ADR-021 D3"
  else
    fail "T45 expected non-zero exit for invalid network.egress.mediator, exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
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
test_t27_mounts_denylist_from_global
test_t28_mounts_denylist_from_project
test_t29_mounts_denylist_additive_merge
test_t30_mounts_allow_risky_selection_list
test_t31_network_allowed_hosts_from_global
test_t32_network_allowed_hosts_additive_merge
test_t33_v1_config_no_network_parses_unchanged
test_t34_network_mode_selection_list
test_t35_absent_network_mode_is_null_not_enum
test_t36_network_writable_not_subset_aborts
test_t37_network_writable_hosts_removed_from_schema
test_t38_network_mode_invalid_aborts
test_t39_validate_yq_missing_with_global_config_emits_dependency_message
test_t40_session_multiplexer_default_none
test_t41_session_multiplexer_tmux_parses
test_t42_session_multiplexer_invalid_aborts
test_t43_network_egress_mediator_default_none
test_t44_network_egress_mediator_declared_parses
test_t45_network_egress_mediator_invalid_aborts

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
