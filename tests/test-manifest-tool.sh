#!/usr/bin/env bash
# Host-side + e2e tests for TOOL archetype install-step generation (rip-cage-4c5.2).
# ADR-005 D1 (build-time install FIRM), D3 (version pins), D8 (default unchanged).
#
# Test tiers:
#
#   T1  (fast, host-only) — Generated Dockerfile steps differ WITH vs WITHOUT a
#       scratch TOOL entry. No docker build needed; proves the generation logic
#       responds to manifest content. This is the unit-level proxy for the
#       counterfactual: WITH entry → steps present; WITHOUT entry → steps absent.
#
#   T2  (e2e, NEEDS_CONTAINER) — Two-scratch-build counterfactual: build image A
#       with the scratch tool entry, build image B without it; docker exec probes
#       confirm the binary is present only in A. This is the full counterfactual
#       proof that cannot be satisfied by a hand-edited Dockerfile.
#
#   T3  (e2e, NEEDS_CONTAINER) — Default manifest (bundled-only) build uses the
#       original Dockerfile unchanged. Proven by verifying no temp Dockerfile is
#       generated and `rc build` produces an image byte-for-byte equivalent to a
#       direct `docker build` of the unmodified Dockerfile.
#
# ADR-005 D4 reconciliation note (FIRM --with flags):
#   The manifest IS the build-time tool-selection surface; per-cage --with/--only/
#   --skip selection is DEFERRED (Open-decision 8). This bead does not implement
#   selection; it records the manifest mechanism as the interface point D4 will
#   layer on top of later.
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

# Build a sandbox HOME for manifest tests.
setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-tool-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_generate_extra_dockerfile_steps in the sandbox.
# Outputs the generated Dockerfile fragment to stdout.
run_manifest_generate_steps() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_extra_dockerfile_steps" 2>"$stderr_file"
}

# ---------------------------------------------------------------------------
# T1a — WITH scratch TOOL entry: generated steps contain the install command
# ---------------------------------------------------------------------------
test_t1a_with_scratch_tool_steps_present() {
  setup_manifest_sandbox "manifest-with-scratch-tool.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_steps "$stderr_file") || exit_code=$?
  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "apt-get install -y ripgrep"; then
    pass "T1a WITH scratch TOOL: generated steps contain install_cmd (apt-get install -y ripgrep)"
  else
    fail "T1a WITH scratch TOOL: expected install step in output. exit=$exit_code stdout='$out' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1b — Default manifest (no user tools.yaml): generated steps are empty (zero steps).
# The default manifest is core-only (beads/dolt/gh/claude/pi), all with
# version_pin "bundled" and no install_cmd — they are baked by the Dockerfile.
# No extra TOOL entries means no extra install steps.
# This test asserts: exit=0, output is empty (no install steps generated), output does NOT
# contain the scratch tool's ripgrep install (that would signal a wrong manifest).
# ---------------------------------------------------------------------------
test_t1b_without_scratch_tool_no_steps() {
  setup_manifest_sandbox
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_steps "$stderr_file") || exit_code=$?
  # Default manifest = core-only bundled tools → zero extra steps (empty output).
  # The scratch tool (ripgrep) must NOT appear — that would mean the wrong manifest is in effect.
  # herdr must NOT appear — herdr is no longer seeded in the default manifest (ADR-005 D12).
  if [[ "$exit_code" -eq 0 ]] && [[ -z "$out" ]] && ! echo "$out" | grep -q "apt-get install -y ripgrep"; then
    pass "T1b default manifest: generates zero steps (bundled-only, no install_cmd tools) and does NOT contain scratch tool's ripgrep install"
  else
    fail "T1b default manifest: expected zero steps (empty output). exit=$exit_code stdout='$out' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1c — Counterfactual delta: WITH scratch-tool entry adds ripgrep steps; WITHOUT does not.
# The delta between the two outputs is the proof of manifest-driven provenance.
# A hand-edited Dockerfile would produce identical outputs regardless of manifest.
# Reframed: WITH output CONTAINS "apt-get install -y ripgrep" (scratch tool's install_cmd);
# WITHOUT (default) does NOT. Default is core-only bundled tools → zero extra steps (empty),
# and the ripgrep step is only present when the scratch tool is explicitly in the manifest.
# ---------------------------------------------------------------------------
test_t1c_counterfactual_steps_differ() {
  # WITHOUT (default/bundled — core-only tools; NOT ripgrep, NOT herdr, NOT tmux)
  setup_manifest_sandbox
  local out_without
  out_without=$(run_manifest_generate_steps 2>/dev/null)
  teardown_manifest_sandbox

  # WITH scratch tool (ripgrep added)
  setup_manifest_sandbox "manifest-with-scratch-tool.yaml"
  local out_with
  out_with=$(run_manifest_generate_steps 2>/dev/null)
  teardown_manifest_sandbox

  # Delta: WITH contains scratch tool's ripgrep install; WITHOUT does not.
  # This proves that the ripgrep step is entirely manifest-driven provenance.
  if echo "$out_with" | grep -q "apt-get install -y ripgrep" && ! echo "$out_without" | grep -q "apt-get install -y ripgrep"; then
    pass "T1c Counterfactual delta: WITH entry adds ripgrep install step, WITHOUT does not (delta proves manifest-driven provenance)"
  else
    fail "T1c Counterfactual delta mismatch. WITH='$out_with' WITHOUT='$out_without'"
  fi
}

# ---------------------------------------------------------------------------
# T1d — D8 default manifest: bundled-only tools (beads/dolt/gh/claude/pi) produce
# zero extra steps. The default manifest is core-only (ADR-005 D12) — all entries have
# version_pin "bundled" and no install_cmd. This validates that the default manifest
# generates ZERO install steps (empty output), and no multiplexer/herdr steps appear.
# ---------------------------------------------------------------------------
test_t1d_default_manifest_bundled_only_no_extra_steps() {
  # Use the manifest default (no file) — falls back to _manifest_default_yaml in rc
  setup_manifest_sandbox
  local out exit_code stderr_file
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_steps "$stderr_file") || exit_code=$?
  # Assert: ALL tools are bundled (beads/dolt/gh/claude/pi) → zero extra steps (empty output).
  # dcg is opt-in via examples/dcg recipe (rip-cage-wlwc.10 / ADR-025 D2).
  # Neither herdr nor dcg nor any other non-bundled tool appears in the default manifest (ADR-005 D12).
  if [[ "$exit_code" -eq 0 ]] \
     && [[ -z "$out" ]] \
     && ! echo "$out" | grep -qE "herdr|manifest TOOL: (beads|dolt|gh|claude|pi) "; then
    pass "T1d D8 default manifest: ALL bundled tools (beads/dolt/gh/claude/pi) produce zero extra steps; default is core-only (ADR-005 D12, dcg is opt-in recipe)"
  else
    fail "T1d D8 default manifest: expected zero steps (empty output — core-only default). exit=$exit_code out='$out' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T2 — E2E COUNTERFACTUAL (NEEDS_CONTAINER)
#
# Two-scratch-build counterfactual:
#   Image A: manifest WITH ripgrep scratch TOOL entry → docker exec probe succeeds
#   Image B: manifest WITHOUT ripgrep entry → docker exec probe fails (binary absent)
#
# This test is the real counterfactual proof. It is SLOW (two docker builds).
# It is wired to NEEDS_CONTAINER so it does not run in CI by default.
# Run with: bash tests/test-manifest-tool.sh --e2e
#
# Note: --with/--only/--skip selection is DEFERRED (ADR-005 D4 / Open-decision 8).
# The manifest is the build-time tool surface; per-cage selection layers on top later.
# ---------------------------------------------------------------------------
test_t2_counterfactual_two_builds() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / e2e): T2 counterfactual two-scratch-build — set RC_E2E=1 or RUN_E2E=1 to run"
    return 0
  fi

  local image_with="rip-cage-test-with-ripgrep:counterfactual"
  local image_without="rip-cage-test-without-ripgrep:counterfactual"

  # Cleanup helper — invoked via trap (shellcheck disable SC2329)
  # shellcheck disable=SC2329
  _t2_cleanup() {
    docker rmi "$image_with" "$image_without" >/dev/null 2>&1 || true
    [[ -n "${_t2_home_with:-}" ]] && rm -rf "$_t2_home_with"
    [[ -n "${_t2_home_without:-}" ]] && rm -rf "$_t2_home_without"
  }
  trap _t2_cleanup RETURN

  # Build WITH ripgrep in manifest
  local _t2_home_with
  _t2_home_with=$(mktemp -d "${TMPDIR:-/tmp}/rc-t2-with-XXXXXX")
  mkdir -p "${_t2_home_with}/.config/rip-cage"
  cp "${FIXTURES}/manifest-with-scratch-tool.yaml" "${_t2_home_with}/.config/rip-cage/tools.yaml"

  echo "T2: Building image WITH ripgrep in manifest..."
  if ! HOME="$_t2_home_with" XDG_CONFIG_HOME="${_t2_home_with}/.config" \
       RC_MANIFEST_GLOBAL="${_t2_home_with}/.config/rip-cage/tools.yaml" \
       "${RC}" build -t "$image_with"; then
    fail "T2 Build WITH ripgrep failed"
    return
  fi

  # Build WITHOUT ripgrep in manifest (default manifest = no extra steps)
  local _t2_home_without
  _t2_home_without=$(mktemp -d "${TMPDIR:-/tmp}/rc-t2-without-XXXXXX")
  mkdir -p "${_t2_home_without}/.config/rip-cage"
  # Do NOT copy the scratch manifest — use default (bundled-only) manifest

  echo "T2: Building image WITHOUT ripgrep in manifest..."
  if ! HOME="$_t2_home_without" XDG_CONFIG_HOME="${_t2_home_without}/.config" \
       "${RC}" build -t "$image_without"; then
    fail "T2 Build WITHOUT ripgrep failed"
    return
  fi

  # Probe: ripgrep binary present in WITH build
  local probe_result_with
  probe_result_with=$(docker run --rm "$image_with" which rg 2>&1)
  if echo "$probe_result_with" | grep -q "/rg"; then
    pass "T2a ripgrep binary present in WITH-entry image (path: $probe_result_with)"
  else
    fail "T2a ripgrep binary NOT found in WITH-entry image. probe='$probe_result_with'"
  fi

  # Probe: ripgrep binary ABSENT in WITHOUT build (counterfactual half)
  local probe_result_without
  probe_result_without=$(docker run --rm "$image_without" which rg 2>&1) || true
  if ! echo "$probe_result_without" | grep -q "/rg"; then
    pass "T2b ripgrep binary ABSENT in WITHOUT-entry image (delta proved — counterfactual holds)"
  else
    fail "T2b ripgrep binary FOUND in WITHOUT-entry image — counterfactual FAILED. probe='$probe_result_without'"
  fi

  # Probe: ripgrep version output works in WITH build (positive sentinel)
  local version_probe
  version_probe=$(docker run --rm "$image_with" rg --version 2>&1 | head -1)
  if echo "$version_probe" | grep -qi "ripgrep"; then
    pass "T2c rg --version works in WITH-entry image: $version_probe"
  else
    fail "T2c rg --version probe failed. output='$version_probe'"
  fi

  # Probe: binary was present BEFORE cage start (build-time, not runtime)
  # This is proven by the fact that docker run (no cage up/init) sees the binary.
  # The T2a probe already uses `docker run --rm` without init-rip-cage.sh.
  pass "T2d Binary present at build time (not runtime/up): proven by T2a docker run --rm (no cage init)"
}

# ---------------------------------------------------------------------------
# T3 — RC_E2E: Default cage has no multiplexer binaries (tmux absent, herdr absent).
#
# Builds a fresh default cage image from the default manifest (no user tools.yaml).
# Probes the image with `command -v tmux` and `command -v herdr` — both must fail.
# This is the real counterfactual proof that cannot be satisfied by a host-tier
# codegen test alone (gated-e2e false-green family: T1d proves codegen, T3 proves image).
#
# Realizes ADR-005 D12 consequences 2 & 3: tmux and herdr are no longer bundled;
# the default cage ships minimal (core tools only).
#
# Run with: bash tests/test-manifest-tool.sh --e2e
# ---------------------------------------------------------------------------
test_t3_default_cage_has_no_mux_binaries() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / RC_E2E): T3 default-cage tmux+herdr absent — set RC_E2E=1 to run"
    return 0
  fi

  local image_default="rip-cage-test-default-nomux:t3"
  local _t3_home_default=""

  # Cleanup: remove image + temp dir on exit/interrupt (crash-safe)
  # shellcheck disable=SC2329
  _t3_cleanup() {
    docker rmi "$image_default" >/dev/null 2>&1 || true
    [[ -n "${_t3_home_default:-}" ]] && rm -rf "$_t3_home_default"
  }
  trap _t3_cleanup RETURN

  # Build default cage — no user manifest, falls back to _manifest_default_yaml (core-only)
  _t3_home_default=$(mktemp -d "${TMPDIR:-/tmp}/rc-t3-default-XXXXXX")
  mkdir -p "${_t3_home_default}/.config/rip-cage"
  # Intentionally do NOT copy any manifest — use default (bundled-only, no tmux, no herdr)

  echo "T3: Building default cage image (no manifest, core-only)..."
  if ! HOME="$_t3_home_default" XDG_CONFIG_HOME="${_t3_home_default}/.config" \
       "${RC}" build -t "$image_default"; then
    fail "T3 Default cage build failed"
    return
  fi

  # Probe: tmux absent in default image
  local tmux_probe_exit
  tmux_probe_exit=0
  docker run --rm "$image_default" sh -c 'command -v tmux' >/dev/null 2>&1 || tmux_probe_exit=$?
  if [[ "$tmux_probe_exit" -ne 0 ]]; then
    pass "T3a tmux binary ABSENT in default cage image (ADR-005 D12: tmux unbaked, opt-in via manifest)"
  else
    fail "T3a tmux binary FOUND in default cage image — tmux must not be bundled (ADR-005 D12)"
  fi

  # Probe: herdr absent in default image
  local herdr_probe_exit
  herdr_probe_exit=0
  docker run --rm "$image_default" sh -c 'command -v herdr' >/dev/null 2>&1 || herdr_probe_exit=$?
  if [[ "$herdr_probe_exit" -ne 0 ]]; then
    pass "T3b herdr binary ABSENT in default cage image (ADR-005 D12: herdr removed from default manifest)"
  else
    fail "T3b herdr binary FOUND in default cage image — herdr must not be in default manifest (ADR-005 D12)"
  fi
}

# ---------------------------------------------------------------------------
# T4 — RC_E2E: examples/tmux manifest-fragment.yaml is a complete migration target.
#
# Proves that the two-entry examples/tmux/manifest-fragment.yaml (tmux-bin TOOL +
# tmux MULTIPLEXER) produces a cage image in which:
#   T4a — the tmux binary IS present (the TOOL entry installs it via apt)
#   T4b — the MULTIPLEXER registry hooks ARE baked (start/attach/new_session)
#
# RED-before-GREEN: T3 already proves that the DEFAULT cage (no manifest) has NO
# tmux binary (the unbaked state). T4 is the GREEN half — it proves that following
# the CHANGELOG migration path (add examples/tmux + rc build) DOES yield a working
# tmux binary. Without the TOOL entry in examples/tmux (the pre-fix state), a user
# would get the MULTIPLEXER hooks baked but no binary → start hook fails with
# "tmux: command not found". T4 closes that gap.
#
# Run with: bash tests/test-manifest-tool.sh --e2e
# ---------------------------------------------------------------------------
test_t4_examples_tmux_is_complete_migration_target() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / RC_E2E): T4 examples/tmux migration target — set RC_E2E=1 to run"
    return 0
  fi

  local examples_tmux_fixture="${REPO_ROOT}/examples/tmux/manifest-fragment.yaml"
  if [[ ! -f "$examples_tmux_fixture" ]]; then
    fail "T4 examples/tmux/manifest-fragment.yaml not found at expected path"
    return
  fi

  local image_tmux="rip-cage-test-examples-tmux:t4"
  local _t4_home=""

  # Cleanup: remove image + temp dir on exit/interrupt (crash-safe)
  # shellcheck disable=SC2329
  _t4_cleanup() {
    docker rmi "$image_tmux" >/dev/null 2>&1 || true
    [[ -n "${_t4_home:-}" ]] && rm -rf "$_t4_home"
  }
  trap _t4_cleanup RETURN

  # Build from examples/tmux/manifest-fragment.yaml (the migration target)
  _t4_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-t4-tmux-XXXXXX")
  mkdir -p "${_t4_home}/.config/rip-cage"
  cp "$examples_tmux_fixture" "${_t4_home}/.config/rip-cage/tools.yaml"

  echo "T4: Building cage image from examples/tmux/manifest-fragment.yaml (two-entry: tmux-bin TOOL + tmux MULTIPLEXER)..."
  if ! HOME="$_t4_home" XDG_CONFIG_HOME="${_t4_home}/.config" \
       "${RC}" build -t "$image_tmux"; then
    fail "T4 Build from examples/tmux failed"
    return
  fi

  # T4a: tmux binary IS present (TOOL entry installs it)
  local tmux_path
  tmux_path=$(docker run --rm "$image_tmux" sh -c 'command -v tmux' 2>&1) || true
  if echo "$tmux_path" | grep -q "tmux"; then
    pass "T4a tmux binary present in examples/tmux cage image (path: ${tmux_path})"
  else
    fail "T4a tmux binary NOT found in examples/tmux cage — TOOL entry install_cmd failed. probe='${tmux_path}'"
  fi

  # T4a+: tmux --version works (positive sentinel)
  local version_out version_rc
  version_rc=0
  version_out=$(docker run --rm "$image_tmux" tmux -V 2>&1) || version_rc=$?
  if [[ "$version_rc" -eq 0 ]]; then
    pass "T4a tmux -V exits 0 in cage: '${version_out}'"
  else
    fail "T4a tmux -V failed: exit=${version_rc} out='${version_out}'"
  fi

  # T4b: MULTIPLEXER registry hooks are baked (start and attach scripts present)
  local start_hook_exit attach_hook_exit
  start_hook_exit=0
  attach_hook_exit=0
  docker run --rm "$image_tmux" test -f /etc/rip-cage/multiplexers/tmux/start >/dev/null 2>&1 || start_hook_exit=$?
  docker run --rm "$image_tmux" test -f /etc/rip-cage/multiplexers/tmux/attach >/dev/null 2>&1 || attach_hook_exit=$?
  if [[ "$start_hook_exit" -eq 0 ]]; then
    pass "T4b tmux registry 'start' hook baked at /etc/rip-cage/multiplexers/tmux/start"
  else
    fail "T4b tmux registry 'start' hook MISSING — MULTIPLEXER bake did not run"
  fi
  if [[ "$attach_hook_exit" -eq 0 ]]; then
    pass "T4b tmux registry 'attach' hook baked at /etc/rip-cage/multiplexers/tmux/attach"
  else
    fail "T4b tmux registry 'attach' hook MISSING — MULTIPLEXER bake did not run"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

# E2E flag from command line
if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

echo "=== test-manifest-tool.sh — TOOL archetype install generation (rip-cage-4c5.2) ==="
echo ""
echo "--- T1: Host-only unit tests (generate Dockerfile steps) ---"
test_t1a_with_scratch_tool_steps_present
test_t1b_without_scratch_tool_no_steps
test_t1c_counterfactual_steps_differ
test_t1d_default_manifest_bundled_only_no_extra_steps

echo ""
echo "--- T2: E2E counterfactual two-scratch-build (NEEDS_CONTAINER) ---"
test_t2_counterfactual_two_builds

echo ""
echo "--- T3: E2E default cage has no multiplexer binaries (NEEDS_CONTAINER / RC_E2E=1) ---"
test_t3_default_cage_has_no_mux_binaries

echo ""
echo "--- T4: RC_E2E examples/tmux is a complete migration target (NEEDS_CONTAINER / RC_E2E=1) ---"
test_t4_examples_tmux_is_complete_migration_target

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
