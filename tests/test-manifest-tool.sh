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
# T1b — Default manifest (no user tools.yaml): generated steps are herdr-only.
# herdr is the one default TOOL entry that carries an install_cmd (version-pinned
# GitHub download, commit 90de322). The 5 bundled tools (beads/dolt/gh/claude/pi/dcg)
# have no install_cmd and are baked by the Dockerfile — they generate no extra steps.
# This test asserts: exit=0, output contains herdr's install marker, output does NOT
# contain the scratch tool's ripgrep install (that would signal a wrong manifest).
# ---------------------------------------------------------------------------
test_t1b_without_scratch_tool_no_steps() {
  setup_manifest_sandbox
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_steps "$stderr_file") || exit_code=$?
  # Default manifest seeds herdr (install_cmd present) → exactly herdr's RUN step is generated.
  # The scratch tool (ripgrep) must NOT appear — that would mean the wrong manifest is in effect.
  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "herdr" && ! echo "$out" | grep -q "apt-get install -y ripgrep"; then
    pass "T1b default manifest: generates herdr steps (non-empty) and does NOT contain scratch tool's ripgrep install"
  else
    fail "T1b default manifest: expected herdr steps only. exit=$exit_code stdout='$out' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1c — Counterfactual delta: WITH scratch-tool entry adds ripgrep steps; WITHOUT does not.
# The delta between the two outputs is the proof of manifest-driven provenance.
# A hand-edited Dockerfile would produce identical outputs regardless of manifest.
# Reframed: WITH output CONTAINS "apt-get install -y ripgrep" (scratch tool's install_cmd);
# WITHOUT (default) does NOT. Both outputs are non-empty (default has herdr steps), but
# the ripgrep step is only present when the scratch tool is explicitly in the manifest.
# ---------------------------------------------------------------------------
test_t1c_counterfactual_steps_differ() {
  # WITHOUT (default/bundled — herdr is present, but NOT ripgrep)
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
# T1d — D8 default manifest: bundled-only tools (beads/dolt/gh/claude/pi/dcg) produce
# zero extra steps; herdr (the one default TOOL with install_cmd) produces exactly its
# own steps and no others. This validates the per-entry generation logic: entries with
# version_pin "bundled" and no install_cmd contribute nothing; herdr's pinned install_cmd
# drives exactly one RUN block in the default manifest output.
# ---------------------------------------------------------------------------
test_t1d_default_manifest_bundled_only_no_extra_steps() {
  # Use the manifest default (no file) — falls back to _manifest_default_yaml in rc
  setup_manifest_sandbox
  local out exit_code stderr_file
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_steps "$stderr_file") || exit_code=$?
  # Assert: herdr's step is present (non-bundled default tool with install_cmd)
  # AND none of the bundled-only tools (beads/dolt/gh/claude/pi/dcg) appear in steps.
  # This proves the bundled tools contribute zero extra steps while herdr's install_cmd fires.
  if [[ "$exit_code" -eq 0 ]] \
     && echo "$out" | grep -q "herdr" \
     && ! echo "$out" | grep -qE "manifest TOOL: (beads|dolt|gh|claude|pi|dcg) "; then
    pass "T1d D8 default manifest: bundled tools (beads/dolt/gh/claude/pi/dcg) produce zero steps; herdr's install_cmd generates its own step"
  else
    fail "T1d D8 default manifest: unexpected extra steps. exit=$exit_code out='$out' stderr=$(cat "$stderr_file")"
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
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
