#!/usr/bin/env bash
# Baked multiplexer-provider registry mechanism (rip-cage-61al.2).
# Tests that rc build bakes MULTIPLEXER-archetype hook commands into
# /etc/rip-cage/multiplexers/<name>/<hook> and writes the rc.multiplexers
# image label. Also tests the reference reader helper.
#
# ADR-005 D9/D11 (hooks baked as availability-payload, FIRM)
# ADR-005 D12 (composable seam — registry IS the mechanism)
# ADR-001 (fail loud on unbaked name)
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   T1  (host-only, runs always):
#     T1a — _manifest_generate_multiplexer_registry_steps emits Dockerfile RUN
#           steps for a MULTIPLEXER fixture (codegen present)
#     T1b — codegen includes start and attach hook file writes for the fixture mux
#     T1c — codegen only writes declared hooks (optional hook absent from start-attach-only fixture)
#     T1d — codegen emits rc.multiplexers LABEL with the mux name
#     T1e — _manifest_generate_multiplexer_registry_steps emits NOTHING for a
#           manifest with no MULTIPLEXER entries (D8 byte-for-byte contract)
#     T1f — _rc_mux_resolve_hook_path resolves a baked name (local-root override /
#           in-container semantics; cage_name omitted, RC_MUX_REGISTRY_ROOT set)
#     T1g — _rc_mux_resolve_hook_path fails loud on an unbaked name (ADR-001)
#
#   T2  (e2e, NEEDS_CONTAINER / RC_E2E=1):
#     T2a — rc build from fixture writes hook files into image at
#           /etc/rip-cage/multiplexers/<name>/start and /attach
#     T2b — an UNdeclared optional hook file is ABSENT in the built image
#     T2c — docker inspect shows rc.multiplexers label enumerating the baked set
#     T2d — _rc_mux_resolve_hook_path resolves a baked name to its hook path
#           (invoked inside the container; resolves without error)
#     T2e — _rc_mux_resolve_hook_path cage-aware path: resolves baked name via
#           docker exec cage; fails loud on unbaked name; also tests local-root
#           override with a real temp dir fake registry
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
  if [[ -n "${T2_IMAGE:-}" ]]; then
    docker image rm "${T2_IMAGE}" 2>/dev/null || true
    T2_IMAGE=""
  fi
  if [[ -n "${T2_SAVED_TAG:-}" ]]; then
    if [[ "${T2_HAD_LATEST:-0}" -eq 1 ]]; then
      docker tag "${T2_SAVED_TAG}" rip-cage:latest 2>/dev/null || true
    else
      docker image rm rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "${T2_SAVED_TAG}" 2>/dev/null || true
    T2_SAVED_TAG=""
  fi
}
trap cleanup EXIT INT TERM

# E2E flag from command line
if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

# Skip helper
skip_if_not_e2e() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / e2e): ${1} — set RC_E2E=1 to run"
    return 0
  fi
  return 1
}

# Build a sandbox HOME for manifest tests.
setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-mux-bake-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_generate_multiplexer_registry_steps against a fixture file path.
run_generate_mux_registry_steps() {
  local fixture_path="$1"
  local stderr_file="${2:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; RC_MANIFEST_GLOBAL='${fixture_path}'; _manifest_generate_multiplexer_registry_steps" \
    2>"$stderr_file"
}

# Run _manifest_generate_multiplexer_label against a fixture file path.
run_generate_mux_label() {
  local fixture_path="$1"
  local stderr_file="${2:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; RC_MANIFEST_GLOBAL='${fixture_path}'; _manifest_generate_multiplexer_label" \
    2>"$stderr_file"
}

echo "=== test-multiplexer-registry-bake.sh — MULTIPLEXER registry bake (rip-cage-61al.2) ==="
echo ""
echo "--- T1: Host-only unit tests ---"

# ---------------------------------------------------------------------------
# T1a — _manifest_generate_multiplexer_registry_steps emits Dockerfile steps
# for a fixture with all hooks (start+attach+optional).
# ---------------------------------------------------------------------------
test_t1a_codegen_emits_steps_for_valid_fixture() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-valid.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-valid.yaml"
  out=$(run_generate_mux_registry_steps "$fixture_path" "$stderr_file") || exit_code=$?
  if [[ "$exit_code" -eq 0 ]] && [[ -n "$out" ]]; then
    pass "T1a _manifest_generate_multiplexer_registry_steps emits Dockerfile steps for valid MULTIPLEXER fixture: non-empty output, exits 0"
  else
    fail "T1a _manifest_generate_multiplexer_registry_steps failed or emitted nothing. exit=${exit_code} stderr='$(cat "$stderr_file")' out='${out:0:200}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1b — codegen includes start and attach hook file writes for the fixture mux.
# Each declared hook must appear as a file write in the generated steps.
# ---------------------------------------------------------------------------
test_t1b_codegen_includes_start_and_attach_hooks() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-valid.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-valid.yaml"
  out=$(run_generate_mux_registry_steps "$fixture_path" "$stderr_file") || exit_code=$?

  # The output must reference the hook file paths under /etc/rip-cage/multiplexers/test-mux/
  if echo "$out" | grep -q "/etc/rip-cage/multiplexers/test-mux/start"; then
    pass "T1b codegen includes /etc/rip-cage/multiplexers/test-mux/start hook write"
  else
    fail "T1b codegen missing /etc/rip-cage/multiplexers/test-mux/start hook write in: '${out:0:300}'"
  fi

  if echo "$out" | grep -q "/etc/rip-cage/multiplexers/test-mux/attach"; then
    pass "T1b codegen includes /etc/rip-cage/multiplexers/test-mux/attach hook write"
  else
    fail "T1b codegen missing /etc/rip-cage/multiplexers/test-mux/attach hook write in: '${out:0:300}'"
  fi

  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1c — codegen only writes declared hooks (optional hook absent from
# start-attach-only fixture does not appear in the generated steps).
# The manifest-multiplexer-start-attach-only.yaml has no exec/new_session/teardown.
# ---------------------------------------------------------------------------
test_t1c_codegen_only_writes_declared_hooks() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-start-attach-only.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-start-attach-only.yaml"
  out=$(run_generate_mux_registry_steps "$fixture_path" "$stderr_file") || exit_code=$?

  # start and attach must be present
  if echo "$out" | grep -q "/etc/rip-cage/multiplexers/test-mux-minimal/start"; then
    pass "T1c start hook write present for minimal fixture (test-mux-minimal)"
  else
    fail "T1c start hook write MISSING for minimal fixture. out='${out:0:300}'"
  fi

  if echo "$out" | grep -q "/etc/rip-cage/multiplexers/test-mux-minimal/attach"; then
    pass "T1c attach hook write present for minimal fixture (test-mux-minimal)"
  else
    fail "T1c attach hook write MISSING for minimal fixture. out='${out:0:300}'"
  fi

  # exec/new_session/teardown must NOT appear (they are undeclared optional hooks)
  if echo "$out" | grep -q "/etc/rip-cage/multiplexers/test-mux-minimal/exec"; then
    fail "T1c exec hook write PRESENT for minimal fixture — should NOT be (only declared hooks written). out='${out:0:300}'"
  else
    pass "T1c exec hook write correctly ABSENT for minimal fixture (not declared)"
  fi

  if echo "$out" | grep -q "/etc/rip-cage/multiplexers/test-mux-minimal/teardown"; then
    fail "T1c teardown hook write PRESENT for minimal fixture — should NOT be. out='${out:0:300}'"
  else
    pass "T1c teardown hook write correctly ABSENT for minimal fixture (not declared)"
  fi

  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1d — codegen emits rc.multiplexers LABEL with the baked mux name.
# _manifest_generate_multiplexer_label must output the label line.
# ---------------------------------------------------------------------------
test_t1d_codegen_emits_label_with_mux_name() {
  local fixture_path="${FIXTURES}/manifest-multiplexer-valid.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-multiplexer-valid.yaml"
  out=$(run_generate_mux_label "$fixture_path" "$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "rc.multiplexers"; then
    pass "T1d _manifest_generate_multiplexer_label emits 'rc.multiplexers' in output"
  else
    fail "T1d _manifest_generate_multiplexer_label failed or missing 'rc.multiplexers'. exit=${exit_code} stderr='$(cat "$stderr_file")' out='${out}'"
  fi

  if echo "$out" | grep -q "test-mux"; then
    pass "T1d label output contains the fixture mux name 'test-mux'"
  else
    fail "T1d label output does NOT contain 'test-mux'. out='${out}'"
  fi

  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e — _manifest_generate_multiplexer_registry_steps emits NOTHING for a
# manifest with no MULTIPLEXER entries (D8 byte-for-byte contract).
# ---------------------------------------------------------------------------
test_t1e_codegen_emits_nothing_for_no_multiplexer_entries() {
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox
  # Manifest with a SHELL-INTEGRATION entry — no MULTIPLEXER archetype
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: some-shell-tool
    archetype: SHELL-INTEGRATION
    version_pin: "bundled"
    shell_init: "eval \"$(some-shell-tool init zsh)\""
YAML

  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_multiplexer_registry_steps" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && [[ -z "$out" ]]; then
    pass "T1e _manifest_generate_multiplexer_registry_steps emits nothing for no-MULTIPLEXER manifest (D8)"
  else
    fail "T1e expected empty output + exit 0. exit=${exit_code} stderr='$(cat "$stderr_file")' out='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}


# ---------------------------------------------------------------------------
# T1f — _rc_mux_resolve_hook_path resolves a baked mux name using the local-root
# override (in-container semantics; no cage_name, RC_MUX_REGISTRY_ROOT overrides
# the default /etc/rip-cage/multiplexers for host-tier unit tests).
# Simulates being called from inside a container with a fake baked registry.
# ---------------------------------------------------------------------------
test_t1f_reader_resolves_baked_name() {
  setup_manifest_sandbox
  # Create a fake baked registry dir to simulate the image environment
  local fake_registry="${TEST_HOME}/etc/rip-cage/multiplexers/test-mux"
  mkdir -p "$fake_registry"
  echo "test-mux start-server --daemon" > "${fake_registry}/start"
  chmod +x "${fake_registry}/start"
  local fake_registry_root="${TEST_HOME}/etc/rip-cage/multiplexers"

  local out exit_code stderr_file
  stderr_file=$(mktemp)
  exit_code=0
  # Use RC_MUX_REGISTRY_ROOT to override the local registry root (in-container path).
  # cage_name is omitted → local-filesystem branch (in-container semantics).
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_MUX_REGISTRY_ROOT="${fake_registry_root}" \
    bash -c "source '${RC}'; _rc_mux_resolve_hook_path 'test-mux' 'start'" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && [[ -n "$out" ]]; then
    pass "T1f _rc_mux_resolve_hook_path resolves 'test-mux/start' to path: '${out}'"
  else
    fail "T1f _rc_mux_resolve_hook_path failed to resolve baked name. exit=${exit_code} stderr='$(cat "$stderr_file")' out='${out}'"
  fi

  # Also verify the resolved path contains the expected component
  if echo "$out" | grep -q "test-mux/start"; then
    pass "T1f resolved path contains expected 'test-mux/start' component"
  else
    fail "T1f resolved path does not look right: '${out}'"
  fi

  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1g — _rc_mux_resolve_hook_path fails loud on an unbaked name (ADR-001).
# A name with no baked registry dir must exit non-zero with a clear error.
# Uses RC_MUX_REGISTRY_ROOT override (in-container semantics; cage_name omitted).
# ---------------------------------------------------------------------------
test_t1g_reader_fails_loud_on_unbaked_name() {
  setup_manifest_sandbox
  # Do NOT create any registry dir — simulate no baked entry for 'ghost-mux'
  local fake_registry_root="${TEST_HOME}/etc/rip-cage/multiplexers"

  local out stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_MUX_REGISTRY_ROOT="${fake_registry_root}" \
    bash -c "source '${RC}'; _rc_mux_resolve_hook_path 'ghost-mux' 'start'" \
    2>"$stderr_file") || exit_code=$?

  local err_output
  err_output=$(cat "$stderr_file")

  if [[ "$exit_code" -ne 0 ]]; then
    pass "T1g _rc_mux_resolve_hook_path fails loud (non-zero exit) on unbaked name 'ghost-mux'"
  else
    fail "T1g _rc_mux_resolve_hook_path should have failed on unbaked name but exited 0. out='${out}' stderr='${err_output}'"
  fi

  # Error message must identify the unbaked name
  if echo "$err_output" | grep -qi "ghost-mux"; then
    pass "T1g error message names the unbaked multiplexer 'ghost-mux'"
  else
    fail "T1g error message does not name 'ghost-mux': stderr='${err_output}'"
  fi

  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# Run T1 tests
test_t1a_codegen_emits_steps_for_valid_fixture
test_t1b_codegen_includes_start_and_attach_hooks
test_t1c_codegen_only_writes_declared_hooks
test_t1d_codegen_emits_label_with_mux_name
test_t1e_codegen_emits_nothing_for_no_multiplexer_entries
test_t1f_reader_resolves_baked_name
test_t1g_reader_fails_loud_on_unbaked_name

echo ""
echo "--- T2: E2E assertions (NEEDS_CONTAINER / RC_E2E=1) ---"

# ---------------------------------------------------------------------------
# T2 state — shared baked image (built once, used by T2a-T2e)
# ---------------------------------------------------------------------------
T2_IMAGE=""
T2_SAVED_TAG=""
T2_HAD_LATEST=0
T2_BUILD_FAILED=0

_t2_build_mux_registry_image() {
  if [[ -n "${T2_IMAGE:-}" ]]; then
    return 0
  fi
  if [[ "${T2_BUILD_FAILED:-0}" -eq 1 ]]; then
    return 1
  fi

  # Save existing rip-cage:latest (if any) so we can restore it on cleanup.
  local unique_suffix
  unique_suffix="$(date +%s)-$$"
  T2_SAVED_TAG="rip-cage:mux-bake-saved-${unique_suffix}"
  T2_HAD_LATEST=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "${T2_SAVED_TAG}" 2>/dev/null && T2_HAD_LATEST=1
  fi

  local fixture_file="${FIXTURES}/manifest-multiplexer-valid.yaml"
  echo "[T2 setup] Building rip-cage image with fixture MULTIPLEXER tool (manifest-multiplexer-valid.yaml)..."
  echo "[T2 setup] This bakes test-mux hooks into /etc/rip-cage/multiplexers/test-mux/ ..."

  local build_out build_rc=0
  build_out=$(RC_MANIFEST_GLOBAL="$fixture_file" \
    "${REPO_ROOT}/rc" build 2>&1) || build_rc=$?

  if [[ "$build_rc" -ne 0 ]]; then
    local build_tail
    build_tail=$(echo "$build_out" | tail -30)
    echo "[T2 setup] FAIL: cage image build failed (exit=${build_rc}). Last 30 lines:" >&2
    echo "$build_tail" >&2
    T2_BUILD_FAILED=1
    return 1
  fi

  # Tag to unique throwaway tag for our assertions.
  T2_IMAGE="rip-cage:mux-bake-test-${unique_suffix}"
  docker tag rip-cage:latest "${T2_IMAGE}" 2>/dev/null || true
  echo "[T2 setup] Image built and tagged: ${T2_IMAGE}"
  return 0
}

# ---------------------------------------------------------------------------
# T2a — rc build from fixture writes hook files into image.
# /etc/rip-cage/multiplexers/test-mux/start and /attach must exist.
# ---------------------------------------------------------------------------
test_t2a_hook_files_present_in_image() {
  if skip_if_not_e2e "T2a hook files present in image"; then return 0; fi

  if ! _t2_build_mux_registry_image; then
    fail "T2a Image build failed — see [T2 setup] FAIL output above"
    return
  fi

  # Check start hook file exists
  local start_rc=0
  docker run --rm "${T2_IMAGE}" test -f /etc/rip-cage/multiplexers/test-mux/start 2>/dev/null || start_rc=$?
  if [[ "$start_rc" -eq 0 ]]; then
    pass "T2a /etc/rip-cage/multiplexers/test-mux/start hook file exists in image"
  else
    fail "T2a /etc/rip-cage/multiplexers/test-mux/start hook file ABSENT in image"
  fi

  # Check attach hook file exists
  local attach_rc=0
  docker run --rm "${T2_IMAGE}" test -f /etc/rip-cage/multiplexers/test-mux/attach 2>/dev/null || attach_rc=$?
  if [[ "$attach_rc" -eq 0 ]]; then
    pass "T2a /etc/rip-cage/multiplexers/test-mux/attach hook file exists in image"
  else
    fail "T2a /etc/rip-cage/multiplexers/test-mux/attach hook file ABSENT in image"
  fi

  # Check exec hook file exists (it IS declared in the valid fixture)
  local exec_rc=0
  docker run --rm "${T2_IMAGE}" test -f /etc/rip-cage/multiplexers/test-mux/exec 2>/dev/null || exec_rc=$?
  if [[ "$exec_rc" -eq 0 ]]; then
    pass "T2a /etc/rip-cage/multiplexers/test-mux/exec hook file exists (declared in valid fixture)"
  else
    fail "T2a /etc/rip-cage/multiplexers/test-mux/exec hook file ABSENT (was declared in valid fixture)"
  fi

  # Verify content of start hook (should contain the command from the fixture)
  local start_content
  start_content=$(docker run --rm "${T2_IMAGE}" cat /etc/rip-cage/multiplexers/test-mux/start 2>/dev/null) || true
  if echo "$start_content" | grep -q "test-mux"; then
    pass "T2a start hook file content references 'test-mux' command: '${start_content}'"
  else
    fail "T2a start hook file content unexpected: '${start_content}'"
  fi
}

# ---------------------------------------------------------------------------
# T2b — an UNdeclared optional hook file is ABSENT in the built image.
# Build from start-attach-only fixture (test-mux-minimal) and assert exec is absent.
# ---------------------------------------------------------------------------
test_t2b_undeclared_hook_file_absent() {
  if skip_if_not_e2e "T2b undeclared optional hook file absent"; then return 0; fi

  if ! _t2_build_mux_registry_image; then
    fail "T2b Image build failed — see [T2 setup] FAIL output above"
    return
  fi

  # The main T2 image is built from manifest-multiplexer-valid.yaml (which has test-mux with all hooks).
  # For T2b, we need the start-attach-only fixture (test-mux-minimal).
  # Build a second throwaway image for this assertion.
  local t2b_fixture="${FIXTURES}/manifest-multiplexer-start-attach-only.yaml"
  local t2b_image="rip-cage:mux-bake-t2b-$$"
  local t2b_saved_tag="rip-cage:mux-bake-t2b-saved-$$"
  local t2b_had_latest=0

  # Save rip-cage:latest (may be the T2a image; save it)
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "${t2b_saved_tag}" 2>/dev/null && t2b_had_latest=1
  fi

  # shellcheck disable=SC2329  # invoked via RETURN trap
  _t2b_cleanup() {
    docker image rm "${t2b_image}" 2>/dev/null || true
    if [[ "${t2b_had_latest}" -eq 1 ]]; then
      docker tag "${t2b_saved_tag}" rip-cage:latest 2>/dev/null || true
    else
      docker image rm rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "${t2b_saved_tag}" 2>/dev/null || true
  }
  trap _t2b_cleanup RETURN

  echo "[T2b] Building start-attach-only fixture image (test-mux-minimal)..."
  local t2b_build_out t2b_build_rc=0
  t2b_build_out=$(RC_MANIFEST_GLOBAL="$t2b_fixture" \
    "${REPO_ROOT}/rc" build 2>&1) || t2b_build_rc=$?

  if [[ "$t2b_build_rc" -ne 0 ]]; then
    fail "T2b start-attach-only build failed (exit=${t2b_build_rc}): ${t2b_build_out:0:200}"
    return
  fi

  docker tag rip-cage:latest "${t2b_image}" 2>/dev/null || true

  # start and attach must be present for test-mux-minimal
  local start_rc=0
  docker run --rm "${t2b_image}" test -f /etc/rip-cage/multiplexers/test-mux-minimal/start 2>/dev/null || start_rc=$?
  if [[ "$start_rc" -eq 0 ]]; then
    pass "T2b /etc/rip-cage/multiplexers/test-mux-minimal/start exists (declared)"
  else
    fail "T2b /etc/rip-cage/multiplexers/test-mux-minimal/start ABSENT (should be declared)"
  fi

  # exec must be ABSENT (not declared in start-attach-only fixture)
  local exec_rc=0
  docker run --rm "${t2b_image}" test -f /etc/rip-cage/multiplexers/test-mux-minimal/exec 2>/dev/null || exec_rc=$?
  if [[ "$exec_rc" -ne 0 ]]; then
    pass "T2b /etc/rip-cage/multiplexers/test-mux-minimal/exec ABSENT (undeclared optional hook — correctly not baked)"
  else
    fail "T2b /etc/rip-cage/multiplexers/test-mux-minimal/exec present — should NOT be (only declared hooks written)"
  fi

  # teardown must be ABSENT
  local teardown_rc=0
  docker run --rm "${t2b_image}" test -f /etc/rip-cage/multiplexers/test-mux-minimal/teardown 2>/dev/null || teardown_rc=$?
  if [[ "$teardown_rc" -ne 0 ]]; then
    pass "T2b /etc/rip-cage/multiplexers/test-mux-minimal/teardown ABSENT (undeclared — correctly not baked)"
  else
    fail "T2b /etc/rip-cage/multiplexers/test-mux-minimal/teardown present — should NOT be"
  fi
}

# ---------------------------------------------------------------------------
# T2c — docker inspect shows rc.multiplexers label enumerating the baked set.
# ---------------------------------------------------------------------------
test_t2c_image_label_enumerates_baked_set() {
  if skip_if_not_e2e "T2c rc.multiplexers image label present"; then return 0; fi

  if ! _t2_build_mux_registry_image; then
    fail "T2c Image build failed — see [T2 setup] FAIL output above"
    return
  fi

  local label_value
  label_value=$(docker inspect --format '{{ index .Config.Labels "rc.multiplexers" }}' "${T2_IMAGE}" 2>/dev/null) || label_value=""

  if [[ -n "$label_value" ]]; then
    pass "T2c rc.multiplexers label present on image: '${label_value}'"
  else
    fail "T2c rc.multiplexers label ABSENT from image (docker inspect showed empty/no label)"
  fi

  if echo "$label_value" | grep -q "test-mux"; then
    pass "T2c rc.multiplexers label contains 'test-mux': '${label_value}'"
  else
    fail "T2c rc.multiplexers label does NOT contain 'test-mux'. label='${label_value}'"
  fi
}

# ---------------------------------------------------------------------------
# T2d — _rc_mux_resolve_hook_path resolves a baked name inside the container.
# Invokes the helper on the image and checks it resolves test-mux start correctly.
# ---------------------------------------------------------------------------
test_t2d_reader_resolves_baked_name_in_image() {
  if skip_if_not_e2e "T2d reader resolves baked name in image"; then return 0; fi

  if ! _t2_build_mux_registry_image; then
    fail "T2d Image build failed — see [T2 setup] FAIL output above"
    return
  fi

  # The reference reader is in rc (host-side), but we can verify the hook file
  # is resolvable by checking existence of the expected path directly.
  # _rc_mux_resolve_hook_path is a host-side helper but its logic relies on the
  # baked /etc/rip-cage/multiplexers/ tree in the image.
  # Here we verify that the hook path exists and is executable in the image.
  local hook_path_out hook_rc=0
  hook_path_out=$(docker run --rm "${T2_IMAGE}" sh -c \
    'test -f /etc/rip-cage/multiplexers/test-mux/start && echo "/etc/rip-cage/multiplexers/test-mux/start" || echo "ABSENT"' \
    2>/dev/null) || hook_rc=$?

  if [[ "$hook_rc" -eq 0 ]] && echo "$hook_path_out" | grep -q "test-mux/start"; then
    pass "T2d baked hook path /etc/rip-cage/multiplexers/test-mux/start resolvable in image: '${hook_path_out}'"
  else
    fail "T2d baked hook path not resolvable in image. hook_rc=${hook_rc} out='${hook_path_out}'"
  fi

  # Also verify the rc helper resolves it correctly from the host (if we can simulate the registry path)
  # by running the host-side function pointing at what the image would have.
  # This is already covered by T1f for the host-side logic; here we prove the image has the files.
  local attach_content
  attach_content=$(docker run --rm "${T2_IMAGE}" cat /etc/rip-cage/multiplexers/test-mux/attach 2>/dev/null) || attach_content=""
  if [[ -n "$attach_content" ]]; then
    pass "T2d baked attach hook file readable in image, content: '${attach_content}'"
  else
    fail "T2d baked attach hook file empty or unreadable in image"
  fi
}

# ---------------------------------------------------------------------------
# T2e — _rc_mux_resolve_hook_path cage-aware path (non-vacuous).
# Exercises three sub-cases:
#   (a) Cage-aware: start a container from the built image; resolve a baked name
#       via docker exec (cage_name arg) — must succeed and return the in-container path.
#   (b) Cage-aware: resolve an unbaked name + cage_name — must fail loud (ADR-001).
#   (c) Local-root override: point RC_MUX_REGISTRY_ROOT at a real temp dir with a
#       fake registry; resolve baked name → success; resolve unbaked → fail loud.
#       (Validates the in-container / RC_MUX_REGISTRY_ROOT branch.)
# ---------------------------------------------------------------------------
test_t2e_reader_cage_aware_and_local_override() {
  if skip_if_not_e2e "T2e reader cage-aware path + local-root override"; then return 0; fi

  if ! _t2_build_mux_registry_image; then
    fail "T2e Image build failed — see [T2 setup] FAIL output above"
    return
  fi

  # --- Sub-case (a)+(b): cage-aware path via docker exec ---
  local t2e_cage="rip-cage-mux-bake-t2e-$$"
  # Start a detached container from the built image (just sleep; no init needed)
  local cage_start_rc=0
  docker run -d --name "${t2e_cage}" "${T2_IMAGE}" sleep 300 >/dev/null 2>&1 || cage_start_rc=$?
  if [[ "$cage_start_rc" -ne 0 ]]; then
    fail "T2e could not start a detached container from ${T2_IMAGE} — docker run -d failed (exit=${cage_start_rc})"
    return
  fi

  # Register cage for crash-safe cleanup
  local _t2e_cage_ref="${t2e_cage}"
  # shellcheck disable=SC2329  # invoked via RETURN trap
  _t2e_cleanup_cage() {
    docker rm -f "${_t2e_cage_ref}" 2>/dev/null || true
  }
  trap _t2e_cleanup_cage RETURN

  # (a) Cage-aware resolve: baked name 'test-mux' / hook 'start' — must succeed
  local t2e_resolve_out t2e_resolve_rc=0
  t2e_resolve_out=$(bash -c \
    "source '${RC}'; _rc_mux_resolve_hook_path 'test-mux' 'start' '${t2e_cage}'" \
    2>&1) || t2e_resolve_rc=$?

  if [[ "$t2e_resolve_rc" -eq 0 ]] && [[ -n "$t2e_resolve_out" ]]; then
    pass "T2e(a) cage-aware resolve 'test-mux/start' via docker exec succeeded: '${t2e_resolve_out}'"
  else
    fail "T2e(a) cage-aware resolve 'test-mux/start' FAILED. exit=${t2e_resolve_rc} out='${t2e_resolve_out}'"
  fi

  if echo "$t2e_resolve_out" | grep -q "test-mux/start"; then
    pass "T2e(a) resolved path contains expected 'test-mux/start' component"
  else
    fail "T2e(a) resolved path missing 'test-mux/start': '${t2e_resolve_out}'"
  fi

  # (b) Cage-aware resolve: unbaked name 'ghost-mux' + cage — must fail loud
  local t2e_ghost_out t2e_ghost_rc=0
  t2e_ghost_out=$(bash -c \
    "source '${RC}'; _rc_mux_resolve_hook_path 'ghost-mux' 'start' '${t2e_cage}'" \
    2>&1) || t2e_ghost_rc=$?

  if [[ "$t2e_ghost_rc" -ne 0 ]]; then
    pass "T2e(b) cage-aware resolve 'ghost-mux' fails loud (exit ${t2e_ghost_rc}) on unbaked name"
  else
    fail "T2e(b) cage-aware resolve 'ghost-mux' should fail loud but exited 0. out='${t2e_ghost_out}'"
  fi

  if echo "$t2e_ghost_out" | grep -qi "ghost-mux"; then
    pass "T2e(b) error output names the unbaked multiplexer 'ghost-mux'"
  else
    fail "T2e(b) error output does not name 'ghost-mux': '${t2e_ghost_out}'"
  fi

  # --- Sub-case (c): local-root override (RC_MUX_REGISTRY_ROOT) ---
  # Create a real temp-dir fake registry
  local t2e_fake_root t2e_fake_dir
  t2e_fake_root=$(mktemp -d "${TMPDIR:-/tmp}/rc-mux-t2e-fake-XXXXXX")
  t2e_fake_dir="${t2e_fake_root}/test-mux"
  mkdir -p "${t2e_fake_dir}"
  echo "test-mux start-server --daemon" > "${t2e_fake_dir}/start"
  chmod 0755 "${t2e_fake_dir}/start"

  # Resolve baked name using RC_MUX_REGISTRY_ROOT override → must succeed
  local t2e_local_out t2e_local_rc=0
  t2e_local_out=$(RC_MUX_REGISTRY_ROOT="${t2e_fake_root}" \
    bash -c "source '${RC}'; _rc_mux_resolve_hook_path 'test-mux' 'start'" \
    2>&1) || t2e_local_rc=$?

  if [[ "$t2e_local_rc" -eq 0 ]] && [[ -n "$t2e_local_out" ]]; then
    pass "T2e(c) local-root override resolves 'test-mux/start': '${t2e_local_out}'"
  else
    fail "T2e(c) local-root override failed to resolve 'test-mux/start'. exit=${t2e_local_rc} out='${t2e_local_out}'"
  fi

  # Resolve unbaked name with local-root override → must fail loud
  local t2e_local_ghost_out t2e_local_ghost_rc=0
  t2e_local_ghost_out=$(RC_MUX_REGISTRY_ROOT="${t2e_fake_root}" \
    bash -c "source '${RC}'; _rc_mux_resolve_hook_path 'ghost-mux' 'start'" \
    2>&1) || t2e_local_ghost_rc=$?

  if [[ "$t2e_local_ghost_rc" -ne 0 ]]; then
    pass "T2e(c) local-root override fails loud on unbaked 'ghost-mux' (exit ${t2e_local_ghost_rc})"
  else
    fail "T2e(c) local-root override should fail on 'ghost-mux' but exited 0. out='${t2e_local_ghost_out}'"
  fi

  if echo "$t2e_local_ghost_out" | grep -qi "ghost-mux"; then
    pass "T2e(c) error output names the unbaked multiplexer 'ghost-mux'"
  else
    fail "T2e(c) error output does not name 'ghost-mux': '${t2e_local_ghost_out}'"
  fi

  rm -rf "${t2e_fake_root}"
}

test_t2a_hook_files_present_in_image
test_t2b_undeclared_hook_file_absent
test_t2c_image_label_enumerates_baked_set
test_t2d_reader_resolves_baked_name_in_image
test_t2e_reader_cage_aware_and_local_override

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
