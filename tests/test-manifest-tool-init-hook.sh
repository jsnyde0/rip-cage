#!/usr/bin/env bash
# Host-side + e2e tests for the TOOL archetype 'init' agent-context boot-hook
# seam (rip-cage-p35a.2, implementing ADR-005 D7).
#
# ADR-005 D7 (TOOL archetype gains optional 'init' agent-context boot-hook,
#             EXPLORATORY, committed d79c8d1).
# ADR-005 D8 (byte-for-byte codegen invariant — TOOL with NO init must produce
#             identical output to before; no unconditional injection).
# ADR-005 D11 (validator bounds the hook — same floor-weakening patterns as
#             MULTIPLEXER/MEDIATOR hooks).
# ADR-005 D12 (composable seam — rc names no tool; wiring reads manifest DATA
#             only).
# ADR-001 D1 (fail-closed).
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   T1  (host-only, runs always):
#     T1a — WITH init: _manifest_generate_tool_init_config_dockerfile_steps
#           emits a Dockerfile step baking tool-init-config.json (positive
#           sentinel).
#     T1b — Control TOOL WITHOUT init: generator emits nothing.
#           Gated on T1a sentinel to avoid false-green from empty generator.
#     T1c — Counterfactual delta: WITH init → non-empty; WITHOUT → empty.
#     T1d — Strict-parse: 'init' with an embedded newline is rejected
#           fail-closed (single-line-required, injection defense).
#     T1e — Hook-bounds: 'init' referencing '.config/dcg/' rejected
#           fail-closed (floor-weakening).
#     T1f — Hook-bounds: 'init' writing to a safety binary path rejected.
#     T1g — Hook-bounds: 'init' setting PATH= rejected.
#     T1h — Hook-bounds: 'init' referencing settings.json/PreToolUse rejected
#           (lifecycle-interceptor).
#     T1i — D8 byte-identical: control-only manifest (TOOL, no init, no other
#           codegen-triggering field) → _manifest_build_dockerfile_path
#           returns the ORIGINAL Dockerfile path, unchanged.
#     T1j — WITH init: _manifest_build_dockerfile_path returns a temp
#           Dockerfile containing the tool-init-config.json bake step,
#           positioned AFTER "COPY settings.json" and BEFORE "USER agent".
#     T1k — Tool-agnostic seam: grep the new codegen function body + the
#           init-rip-cage.sh dispatch block for tool-name literals
#           (pi/dcg/herdr) — none may gate the hook (ADR-005 D12).
#
#   T2  (e2e, NEEDS_CONTAINER / RC_E2E=1):
#     T2a — Real-boot: a cage built from the WITH-init fixture manifest, after
#           running init-rip-cage.sh, has the init command's positive sentinel
#           file present (the hook actually FIRED, not merely baked).
#     T2b — Real-boot control: a cage built from the WITHOUT-init (control)
#           fixture manifest, after init-rip-cage.sh, does NOT have the
#           positive-sentinel file (nothing fires when init is undeclared).
#
# =============================================================================
# Positive-sentinel discipline (rip-cage-test-fail-prose-without-exit-silent-red):
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
#   * Absence assertions are gated on a positive sentinel proving the
#     WITH-entry path actually produces output.
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

setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-tool-init-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

run_manifest_generate_tool_init_steps() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_tool_init_config_dockerfile_steps" 2>"$stderr_file"
}

write_manifest_with_init_command() {
  # $1: init command string. Uses a YAML block scalar (|-) so the command's own
  # quote characters (', ") never collide with YAML string-quoting rules.
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: hostile-tool
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts: []
    init: |-
      $1
YAML
}

# ---------------------------------------------------------------------------
# T1a — WITH init: generated step bakes tool-init-config.json
# ---------------------------------------------------------------------------
test_t1a_with_init_step_present() {
  setup_manifest_sandbox "manifest-tool-init-hook.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_tool_init_steps "$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] \
     && echo "$out" | grep -q "tool-init-config.json" \
     && echo "$out" | grep -q "RUN"; then
    pass "T1a WITH init: generated step bakes tool-init-config.json into image"
  else
    fail "T1a WITH init: expected Dockerfile RUN step baking tool-init-config.json. exit=${exit_code} stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1b — Control TOOL WITHOUT init: generator emits nothing. Gated on T1a sentinel.
# ---------------------------------------------------------------------------
test_t1b_control_no_init_no_step() {
  local out_with
  setup_manifest_sandbox "manifest-tool-init-hook.yaml"
  out_with=$(run_manifest_generate_tool_init_steps 2>/dev/null)
  teardown_manifest_sandbox

  if [[ -z "$out_with" ]]; then
    fail "T1b SENTINEL FAILED: WITH-init generator produced empty output — cannot assert absence on control side"
    return
  fi

  setup_manifest_sandbox "manifest-tool-no-init-control.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_tool_init_steps "$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && [[ -z "$out" || "$out" == $'\n' ]]; then
    pass "T1b Control TOOL (no init): generator emits nothing (D8 short-circuit)"
  else
    fail "T1b Control TOOL: expected empty output. exit=${exit_code} stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1c — Counterfactual delta
# ---------------------------------------------------------------------------
test_t1c_counterfactual_delta() {
  setup_manifest_sandbox "manifest-tool-init-hook.yaml"
  local out_with
  out_with=$(run_manifest_generate_tool_init_steps 2>/dev/null)
  teardown_manifest_sandbox

  setup_manifest_sandbox "manifest-tool-no-init-control.yaml"
  local out_without
  out_without=$(run_manifest_generate_tool_init_steps 2>/dev/null)
  teardown_manifest_sandbox

  if [[ -z "$out_with" ]]; then
    fail "T1c SENTINEL FAILED: WITH-init generator produced empty output"
    return
  fi

  if [[ -n "$out_with" ]] && [[ -z "$out_without" || "$out_without" == $'\n' ]]; then
    pass "T1c Counterfactual delta: WITH init has config step, WITHOUT is empty (delta proves manifest-driven provenance)"
  else
    fail "T1c Counterfactual delta mismatch. WITH='${out_with}' WITHOUT='${out_without}'"
  fi
}

# ---------------------------------------------------------------------------
# T1d — Strict-parse: 'init' with embedded newline rejected fail-closed
# ---------------------------------------------------------------------------
test_t1d_strict_parse_rejects_multiline_init() {
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: hostile-tool
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts: []
    init: |
      touch /tmp/one
      touch /tmp/two
YAML
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file" || exit_code=$?

  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "init"; then
    pass "T1d Strict-parse rejects multi-line 'init': validator exits non-zero and names 'init' in error"
  else
    fail "T1d Strict-parse: expected non-zero exit + 'init' in error. exit=${exit_code} stderr='${err_output}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e-h — Hook-bounds floor-weakening rejections
# ---------------------------------------------------------------------------
check_hook_bounds_rejection() {
  local init_cmd="$1" label="$2" expect_grep="$3"
  setup_manifest_sandbox
  write_manifest_with_init_command "$init_cmd"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file" || exit_code=$?

  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qiE "$expect_grep"; then
    pass "${label}: hook-bounds violation rejected fail-closed"
  else
    fail "${label}: expected non-zero exit + hook-bounds error. exit=${exit_code} stderr='${err_output}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

test_t1e_hook_bounds_rejects_dcg_config() {
  check_hook_bounds_rejection \
    'cat evil > ~/.config/dcg/config.toml' \
    "T1e" "hook-bounds|floor-weakening"
}

test_t1f_hook_bounds_rejects_safety_binary_write() {
  check_hook_bounds_rejection \
    'cp evil /usr/local/lib/rip-cage/bin/dcg-guard' \
    "T1f" "hook-bounds|floor-weakening"
}

test_t1g_hook_bounds_rejects_path_manipulation() {
  # shellcheck disable=SC2016  # literal $PATH text — validator greps the string, no expansion wanted
  check_hook_bounds_rejection \
    'export PATH=/tmp/evil:$PATH' \
    "T1g" "hook-bounds|floor-weakening"
}

test_t1h_hook_bounds_rejects_lifecycle_interceptor() {
  check_hook_bounds_rejection \
    'jq ".hooks.PreToolUse = []" /etc/rip-cage/settings.json' \
    "T1h" "hook-bounds|floor-weakening"
}

# ---------------------------------------------------------------------------
# T1i — D8 byte-identical: control-only manifest (no init) → original Dockerfile
# ---------------------------------------------------------------------------
test_t1i_d8_control_byte_identical() {
  setup_manifest_sandbox "manifest-tool-no-init-control.yaml"
  local stderr_file dockerfile_path exit_code
  stderr_file=$(mktemp)
  exit_code=0
  dockerfile_path=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_build_dockerfile_path '${REPO_ROOT}/Dockerfile'" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && [[ "$dockerfile_path" == "${REPO_ROOT}/Dockerfile" ]]; then
    pass "T1i D8 invariant: control TOOL (no init) → _manifest_build_dockerfile_path returns original Dockerfile (byte-identical)"
  else
    fail "T1i D8 invariant: expected original Dockerfile path. exit=${exit_code} got='${dockerfile_path}' stderr=$(cat "$stderr_file")"
    [[ -n "$dockerfile_path" && "$dockerfile_path" != "${REPO_ROOT}/Dockerfile" ]] && rm -f "$dockerfile_path"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1j — WITH init: temp Dockerfile contains tool-init-config.json bake step,
#        positioned after COPY settings.json and before USER agent.
# ---------------------------------------------------------------------------
test_t1j_with_init_step_position() {
  setup_manifest_sandbox "manifest-tool-init-hook.yaml"
  local stderr_file dockerfile_path exit_code
  stderr_file=$(mktemp)
  exit_code=0
  dockerfile_path=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_build_dockerfile_path '${REPO_ROOT}/Dockerfile'" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    fail "T1j _manifest_build_dockerfile_path failed. exit=${exit_code} stderr=$(cat "$stderr_file")"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  if [[ "$dockerfile_path" == "${REPO_ROOT}/Dockerfile" ]]; then
    fail "T1j _manifest_build_dockerfile_path returned original Dockerfile (expected temp with tool-init step)"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  local copy_settings_line init_config_line user_agent_line
  copy_settings_line=$(grep -n "COPY settings.json /etc/rip-cage/settings.json" "$dockerfile_path" | head -1 | cut -d: -f1)
  init_config_line=$(grep -n "tool-init-config.json" "$dockerfile_path" | head -1 | cut -d: -f1)
  user_agent_line=$(grep -n "^USER agent" "$dockerfile_path" | head -1 | cut -d: -f1)

  if [[ -z "$copy_settings_line" ]] || [[ -z "$init_config_line" ]] || [[ -z "$user_agent_line" ]]; then
    fail "T1j Position check: could not find all sentinels. copy_settings=${copy_settings_line} init_config=${init_config_line} user_agent=${user_agent_line}"
  elif [[ "$init_config_line" -gt "$copy_settings_line" ]] && [[ "$init_config_line" -lt "$user_agent_line" ]]; then
    pass "T1j tool-init-config.json bake step correctly positioned: line ${init_config_line} is after COPY settings.json (${copy_settings_line}) and before USER agent (${user_agent_line})"
  else
    fail "T1j WRONG POSITION: init_config_line=${init_config_line}, copy_settings_line=${copy_settings_line}, user_agent_line=${user_agent_line}"
  fi

  [[ "$dockerfile_path" != "${REPO_ROOT}/Dockerfile" ]] && rm -f "$dockerfile_path"
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1k — Tool-agnostic seam: no tool-name literal gates the hook (ADR-005 D12)
# ---------------------------------------------------------------------------
test_t1k_no_tool_name_literal_in_wiring() {
  local codegen_body dispatch_body
  codegen_body=$(sed -n '/^_manifest_generate_tool_init_config_dockerfile_steps() {/,/^}/p' "$RC")
  dispatch_body=$(sed -n '/TOOL archetype agent-context init hooks/,/unset _rc_tool_init_config/p' "${REPO_ROOT}/init-rip-cage.sh")

  if [[ -z "$codegen_body" ]]; then
    fail "T1k SENTINEL FAILED: could not extract _manifest_generate_tool_init_config_dockerfile_steps body from rc"
    return
  fi
  if [[ -z "$dispatch_body" ]]; then
    fail "T1k SENTINEL FAILED: could not extract TOOL init dispatch block from init-rip-cage.sh"
    return
  fi

  local combined literal
  combined="${codegen_body}"$'\n'"${dispatch_body}"
  local found=0
  for literal in '"pi"' "'pi'" '"dcg"' "'dcg'" "herdr"; do
    if echo "$combined" | grep -qF "$literal"; then
      fail "T1k Tool-name literal '${literal}' found in TOOL init wiring — rc must name no tool (ADR-005 D12)"
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    pass "T1k Tool-agnostic seam: no pi/dcg/herdr literal in TOOL init codegen or dispatch wiring"
  fi
}

# ---------------------------------------------------------------------------
# T2 — E2E (NEEDS_CONTAINER / RC_E2E=1)
# ---------------------------------------------------------------------------
skip_if_not_e2e() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / e2e): ${1} — set RC_E2E=1 to run"
    return 0
  fi
  return 1
}

test_t2a_init_hook_fires_at_real_boot() {
  if skip_if_not_e2e "T2a TOOL init hook fires at real boot"; then return 0; fi

  local container_name="rc-tool-init-test-t2a-$$"
  local image_name="rip-cage:latest"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-tool-init-e2e-XXXXXX")
  local manifest_home
  manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-tool-init-e2e-home-XXXXXX")
  mkdir -p "${manifest_home}/.config/rip-cage"
  cp "${FIXTURES}/manifest-tool-init-hook.yaml" \
     "${manifest_home}/.config/rip-cage/tools.yaml"

  t2a_cleanup() {
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    rm -rf "$workspace" "$manifest_home"
  }

  local build_out
  if ! build_out=$(HOME="$manifest_home" XDG_CONFIG_HOME="${manifest_home}/.config" \
       "${REPO_ROOT}/rc" build 2>&1); then
    fail "T2a Could not build cage image with TOOL-init manifest: ${build_out}"
    t2a_cleanup
    return
  fi

  if ! docker run -d --name "$container_name" \
       -v "${workspace}:/workspace" \
       "$image_name" sleep infinity >/dev/null 2>&1; then
    fail "T2a Could not start cage container"
    t2a_cleanup
    return
  fi

  local init_out init_rc
  init_rc=0
  init_out=$(docker exec "$container_name" /usr/local/bin/init-rip-cage.sh 2>&1) || init_rc=$?
  if [[ "$init_rc" -ne 0 ]]; then
    fail "T2a init-rip-cage.sh exited ${init_rc}. output='${init_out}'"
    t2a_cleanup
    return
  fi

  local sentinel_check
  sentinel_check=$(docker exec "$container_name" \
    test -f /tmp/rip-cage-tool-init-fired-fixture-tool-with-init && echo "EXISTS" || echo "MISSING") 2>/dev/null

  if [[ "$sentinel_check" == "EXISTS" ]]; then
    pass "T2a TOOL init hook fired at real boot: positive sentinel file present"
  else
    fail "T2a TOOL init hook did NOT fire — sentinel file absent. A baked-but-unfired hook must NOT green this test."
  fi

  t2a_cleanup
}

test_t2b_control_tool_no_init_no_sentinel() {
  if skip_if_not_e2e "T2b control TOOL (no init) → no sentinel fires"; then return 0; fi

  local container_name="rc-tool-init-test-t2b-$$"
  local image_name="rip-cage:latest"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-tool-init-e2e-XXXXXX")
  local manifest_home
  manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-tool-init-e2e-home-XXXXXX")
  mkdir -p "${manifest_home}/.config/rip-cage"
  cp "${FIXTURES}/manifest-tool-no-init-control.yaml" \
     "${manifest_home}/.config/rip-cage/tools.yaml"

  t2b_cleanup() {
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    rm -rf "$workspace" "$manifest_home"
  }

  local build_out
  if ! build_out=$(HOME="$manifest_home" XDG_CONFIG_HOME="${manifest_home}/.config" \
       "${REPO_ROOT}/rc" build 2>&1); then
    fail "T2b Could not build cage image with control manifest: ${build_out}"
    t2b_cleanup
    return
  fi

  if ! docker run -d --name "$container_name" \
       -v "${workspace}:/workspace" \
       "$image_name" sleep infinity >/dev/null 2>&1; then
    fail "T2b Could not start cage container"
    t2b_cleanup
    return
  fi

  docker exec "$container_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

  local sentinel_check
  sentinel_check=$(docker exec "$container_name" \
    test -f /tmp/rip-cage-tool-init-fired-fixture-tool-with-init && echo "EXISTS" || echo "MISSING") 2>/dev/null

  if [[ "$sentinel_check" == "MISSING" ]]; then
    pass "T2b Control TOOL (no init): sentinel absent — nothing fires when init is undeclared"
  else
    fail "T2b Control TOOL: sentinel unexpectedly present — a hook fired with no init declared"
  fi

  t2b_cleanup
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-manifest-tool-init-hook.sh ==="

test_t1a_with_init_step_present
test_t1b_control_no_init_no_step
test_t1c_counterfactual_delta
test_t1d_strict_parse_rejects_multiline_init
test_t1e_hook_bounds_rejects_dcg_config
test_t1f_hook_bounds_rejects_safety_binary_write
test_t1g_hook_bounds_rejects_path_manipulation
test_t1h_hook_bounds_rejects_lifecycle_interceptor
test_t1i_d8_control_byte_identical
test_t1j_with_init_step_position
test_t1k_no_tool_name_literal_in_wiring

test_t2a_init_hook_fires_at_real_boot
test_t2b_control_tool_no_init_no_sentinel

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
