#!/usr/bin/env bash
# Host-side + e2e tests for the from-source builder stage (rip-cage-buuo.2).
# ADR-005 D6 (from-source generalization), D11 (mechanism 1), ADR-002 (multi-stage build).
#
# This bead owns: from-source manifest SCHEMA and its validator acceptance.
# The validator (_manifest_validate) must:
#   1. ACCEPT a well-formed from-source entry (builder_image + build_script + output_path, no install_cmd).
#   2. REJECT a from-source entry that is missing builder_image, build_script, or output_path.
#
# The codegen (_manifest_generate_extra_dockerfile_steps via _manifest_build_dockerfile_path) must:
#   - Emit a FROM <builder_image> AS rc-builder-<name> isolated stage (before the runtime stage).
#   - Run the declared build script in that stage.
#   - COPY only the output_path into the runtime stage.
#   - NOT put build toolchain into the runtime layer.
#
# Test tiers:
#
#   S1 (host-only) — Validator: well-formed from-source entry validates clean.
#   S2 (host-only) — Validator: malformed from-source entry (missing builder_image) is rejected.
#   S3 (host-only) — Validator: malformed from-source entry (missing build_script) is rejected.
#   S4 (host-only) — Validator: malformed from-source entry (missing output_path) is rejected.
#   S5 (host-only) — Codegen: generated Dockerfile fragment contains FROM <builder_image> AS rc-builder-<name>.
#   S6 (host-only) — Codegen: generated Dockerfile fragment runs the declared build script in builder stage.
#   S7 (host-only) — Codegen: generated full Dockerfile contains COPY --from=rc-builder-<name> <output_path> into runtime.
#   S8 (host-only) — Codegen: runtime stage does NOT contain the builder image name (toolchain not leaked).
#   S9 (host-only) — Codegen: from-source entry with NO install_cmd generates builder stage (not skipped).
#   S10 (host-only) — Validator: from-source entry with install_cmd is rejected (contradictory).
#   S11 (host-only) — Validator: bundled entry with build_source is rejected (schema gap F1).
#   S12 (host-only) — Validator: newline in build_source.builder_image is rejected (newline-injection, ADR-024/F2).
#
#   SE1 (e2e, NEEDS_CONTAINER + RC_E2E=1) — Real docker build: binary present in runtime, toolchain absent.
#
# The RC_E2E tier is intentionally deferred; host-side codegen tests (S1-S10) run always.
# Explicit SKIP lines for SE1 appear in the output when RC_E2E is not set.

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
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-source-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_validate in the sandbox. Returns exit code.
run_manifest_validate() {
  local manifest_file="$1"
  local stderr_file="${2:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${manifest_file}'" 2>"$stderr_file"
}

# Run _manifest_generate_extra_dockerfile_steps in the sandbox.
# Outputs the generated runtime-stage Dockerfile fragment to stdout.
run_manifest_generate_steps() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_extra_dockerfile_steps" 2>"$stderr_file"
}

# Run _manifest_generate_source_builder_stages in the sandbox.
# Outputs the generated builder-stage Dockerfile fragment to stdout.
run_manifest_generate_builder_stages() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_source_builder_stages" 2>"$stderr_file"
}

# Run _manifest_build_dockerfile_path in the sandbox.
# Outputs the path to the temp Dockerfile on stdout.
run_manifest_build_dockerfile_path() {
  local stderr_file="${1:-/dev/null}"
  local orig_dockerfile="${2:-${REPO_ROOT}/Dockerfile}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_build_dockerfile_path '${orig_dockerfile}'" 2>"$stderr_file"
}

# ---------------------------------------------------------------------------
# S1 — Well-formed from-source entry validates clean
# A TOOL entry with build_source.{builder_image, build_script, output_path}
# and no install_cmd must pass _manifest_validate without error.
# ---------------------------------------------------------------------------
test_s1_well_formed_from_source_validates_clean() {
  setup_manifest_sandbox "manifest-with-from-source-tool.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "S1 well-formed from-source entry validates clean (exit=0, no error)"
  else
    fail "S1 well-formed from-source entry rejected (should validate clean). exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S2 — Missing builder_image is rejected fail-loud
# ---------------------------------------------------------------------------
test_s2_missing_builder_image_rejected() {
  setup_manifest_sandbox "manifest-hostile-source-missing-builder-image.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "builder_image" "$stderr_file"; then
    pass "S2 missing builder_image rejected non-zero + names 'builder_image'"
  else
    fail "S2 expected non-zero exit + 'builder_image' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S3 — Missing build_script is rejected fail-loud
# ---------------------------------------------------------------------------
test_s3_missing_build_script_rejected() {
  setup_manifest_sandbox "manifest-hostile-source-missing-build-script.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "build_script" "$stderr_file"; then
    pass "S3 missing build_script rejected non-zero + names 'build_script'"
  else
    fail "S3 expected non-zero exit + 'build_script' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S4 — Missing output_path is rejected fail-loud
# ---------------------------------------------------------------------------
test_s4_missing_output_path_rejected() {
  setup_manifest_sandbox "manifest-hostile-source-missing-output-path.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "output_path" "$stderr_file"; then
    pass "S4 missing output_path rejected non-zero + names 'output_path'"
  else
    fail "S4 expected non-zero exit + 'output_path' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S5 — Generated builder stages contain FROM <builder_image> AS rc-builder-<name>
# The codegen must emit an isolated builder stage for a from-source entry.
# The builder stage is emitted by _manifest_generate_source_builder_stages (separate
# from the runtime COPY --from steps in _manifest_generate_extra_dockerfile_steps).
# ---------------------------------------------------------------------------
test_s5_codegen_contains_builder_stage() {
  setup_manifest_sandbox "manifest-with-from-source-tool.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_builder_stages "$stderr_file") || exit_code=$?
  # The generated builder stages must contain a FROM ... AS rc-builder-... line.
  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -qE "^FROM .+ AS rc-builder-.+"; then
    pass "S5 builder stages contain FROM <builder_image> AS rc-builder-<name> isolated stage"
  else
    fail "S5 expected FROM ... AS rc-builder-... in builder stages. exit=$exit_code stdout='$out' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S6 — Generated builder stages run the declared build script
# The builder stage must COPY the build script in and execute it (RUN sh ...).
# ---------------------------------------------------------------------------
test_s6_codegen_runs_build_script_in_builder() {
  setup_manifest_sandbox "manifest-with-from-source-tool.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_builder_stages "$stderr_file") || exit_code=$?
  # The generated builder stage must include COPY of the build script and a RUN for it.
  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "COPY" && echo "$out" | grep -qE "^RUN sh /rc-build/build\.sh"; then
    pass "S6 builder stages: COPY build script + RUN sh /rc-build/build.sh present"
  else
    fail "S6 expected COPY + RUN sh /rc-build/build.sh in builder stages. exit=$exit_code stdout='$out' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S7 — Full generated Dockerfile contains COPY --from=rc-builder-<name> <output_path>
# The runtime stage must receive only the artifact, not the build toolchain.
# ---------------------------------------------------------------------------
test_s7_codegen_copies_output_into_runtime() {
  setup_manifest_sandbox "manifest-with-from-source-tool.yaml"
  local stderr_file dockerfile_path exit_code
  stderr_file=$(mktemp)
  exit_code=0
  dockerfile_path=$(run_manifest_build_dockerfile_path "$stderr_file") || exit_code=$?
  if [[ "$exit_code" -ne 0 || -z "$dockerfile_path" || ! -f "$dockerfile_path" ]]; then
    fail "S7 _manifest_build_dockerfile_path failed or returned empty path. exit=$exit_code path='$dockerfile_path' stderr=$(cat "$stderr_file")"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi
  local df_content
  df_content=$(< "$dockerfile_path")
  rm -f "$dockerfile_path"
  # Must contain COPY --from=rc-builder-<name>
  if echo "$df_content" | grep -qE "COPY --from=rc-builder-.+ .+ .+"; then
    pass "S7 generated Dockerfile contains COPY --from=rc-builder-<name> <output_path> <runtime_path>"
  else
    fail "S7 expected COPY --from=rc-builder-... in generated Dockerfile. Content (tail)=$(echo "$df_content" | tail -20)"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S8 — Runtime stage does NOT contain the builder image name (toolchain not leaked)
# The builder image and its toolchain must be isolated to the builder stage.
# Specifically, the runtime FROM line must not reference the builder_image.
# ---------------------------------------------------------------------------
test_s8_runtime_stage_toolchain_absent() {
  setup_manifest_sandbox "manifest-with-from-source-tool.yaml"
  local stderr_file dockerfile_path exit_code
  stderr_file=$(mktemp)
  exit_code=0
  dockerfile_path=$(run_manifest_build_dockerfile_path "$stderr_file") || exit_code=$?
  if [[ "$exit_code" -ne 0 || -z "$dockerfile_path" || ! -f "$dockerfile_path" ]]; then
    fail "S8 _manifest_build_dockerfile_path failed or returned empty path. exit=$exit_code path='$dockerfile_path' stderr=$(cat "$stderr_file")"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi
  local df_content
  df_content=$(< "$dockerfile_path")
  rm -f "$dockerfile_path"

  # The builder_image in the fixture is "alpine:3.19" — it must NOT appear in a FROM
  # line for the runtime stage. The runtime stage FROM is "FROM debian:trixie".
  # Check: no second FROM after the runtime FROM that uses the builder image.
  # More precisely: after the first occurrence of "FROM debian:trixie", no line
  # should be "FROM alpine:3.19" (the fixture builder image).
  local runtime_from_line builder_image_in_runtime
  runtime_from_line=$(echo "$df_content" | grep -n "^FROM debian:trixie$" | head -1 | cut -d: -f1)
  if [[ -z "$runtime_from_line" ]]; then
    fail "S8 could not find 'FROM debian:trixie' runtime stage in generated Dockerfile"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi
  # After the runtime FROM line, check that "FROM alpine:3.19" does not appear
  builder_image_in_runtime=$(echo "$df_content" | tail -n "+${runtime_from_line}" | grep -c "^FROM alpine:3.19" || true)
  if [[ "${builder_image_in_runtime:-0}" -eq 0 ]]; then
    pass "S8 builder image (alpine:3.19) is NOT in the runtime stage (toolchain isolated)"
  else
    fail "S8 builder image appears inside the runtime stage — toolchain leaked!"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S9 — From-source entry with NO install_cmd generates builder stage (not skipped)
# The codegen must NOT skip from-source entries just because install_cmd is absent.
# Checks BOTH the builder stages function and the runtime COPY --from function.
# ---------------------------------------------------------------------------
test_s9_from_source_without_install_cmd_not_skipped() {
  setup_manifest_sandbox "manifest-with-from-source-tool.yaml"
  local stderr_file out_stages out_steps exit_code_stages exit_code_steps
  stderr_file=$(mktemp)
  exit_code_stages=0
  exit_code_steps=0
  out_stages=$(run_manifest_generate_builder_stages "$stderr_file") || exit_code_stages=$?
  out_steps=$(run_manifest_generate_steps "$stderr_file") || exit_code_steps=$?
  # The fixture has NO install_cmd; both builder stages and runtime COPY must be produced.
  if [[ "$exit_code_stages" -eq 0 && -n "$out_stages" && "$exit_code_steps" -eq 0 && -n "$out_steps" ]]; then
    pass "S9 from-source entry (no install_cmd) is NOT skipped — builder stages and runtime COPY steps both produced"
  else
    fail "S9 from-source entry (no install_cmd) produced empty codegen — incorrectly skipped. stages_exit=$exit_code_stages steps_exit=$exit_code_steps stages='$out_stages' steps='$out_steps' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S10 — From-source entry WITH install_cmd is rejected (contradictory)
# A from-source entry that also declares install_cmd is contradictory and must
# be rejected fail-loud naming the contradiction.
# ---------------------------------------------------------------------------
test_s10_from_source_with_install_cmd_rejected() {
  setup_manifest_sandbox "manifest-hostile-source-with-install-cmd.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "mutually exclusive\|install_cmd.*build_source\|build_source.*install_cmd" "$stderr_file"; then
    pass "S10 from-source entry with install_cmd rejected non-zero + error names the contradiction"
  else
    fail "S10 expected non-zero exit + error naming contradiction. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S11 — Bundled entry WITH build_source is rejected (contradictory)
# A bundled entry (version_pin: "bundled") must NOT have a build_source block;
# they are contradictory (bundled = baked by Dockerfile, no external builder needed).
# The validator must reject fail-loud naming "build_source".
# ---------------------------------------------------------------------------
test_s11_bundled_with_build_source_rejected() {
  setup_manifest_sandbox "manifest-hostile-bundled-with-build-source.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "build_source" "$stderr_file"; then
    pass "S11 bundled+build_source rejected non-zero + error names 'build_source'"
  else
    fail "S11 expected non-zero exit + 'build_source' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S12 — Newline in build_source.builder_image is rejected (newline-injection guard)
# A YAML value with \n in builder_image would inject arbitrary Dockerfile directives
# into the generated builder stage (ADR-024 prompt-injection threat model).
# The validator must reject fail-loud naming the offending field.
# ---------------------------------------------------------------------------
test_s12_newline_in_builder_image_rejected() {
  setup_manifest_sandbox "manifest-hostile-source-newline-in-builder-image.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "builder_image" "$stderr_file"; then
    pass "S12 newline in build_source.builder_image rejected non-zero + error names 'builder_image'"
  else
    fail "S12 expected non-zero exit + 'builder_image' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S13 — Absolute build_script is rejected fail-loud (path-scope check — rip-cage-buuo.6 F2)
# An absolute build_script (/absolute/path/build.sh) is outside the build context
# (SCRIPT_DIR). Docker would reject it with an opaque "forbidden path" error;
# the validator must catch it FIRST with a named, fail-closed error (ADR-001).
# ---------------------------------------------------------------------------
test_s13_absolute_build_script_rejected() {
  setup_manifest_sandbox "manifest-hostile-source-absolute-build-script.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "build_script\|build context\|outside.*context\|absolute" "$stderr_file"; then
    pass "S13 absolute build_script rejected non-zero + names the path-scope violation"
  else
    fail "S13 expected non-zero exit + path-scope error for absolute build_script. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S14 — ../ escaping build_script is rejected fail-loud (path-scope check — rip-cage-buuo.6 F2)
# A build_script starting with ../ resolves outside the build context (repo root).
# Docker would reject it with an opaque "forbidden path" error;
# the validator must catch it FIRST with a named, fail-closed error (ADR-001).
# ---------------------------------------------------------------------------
test_s14_escape_build_script_rejected() {
  setup_manifest_sandbox "manifest-hostile-source-escape-build-script.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "build_script\|build context\|outside.*context\|escape\|\.\./" "$stderr_file"; then
    pass "S14 ../-escaping build_script rejected non-zero + names the path-scope violation"
  else
    fail "S14 expected non-zero exit + path-scope error for ../ build_script. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# S15 — Bare ".." build_script is rejected fail-loud (path-scope check — rip-cage-buuo.6 minor fix)
# A build_script of exactly ".." (no slashes) escapes the build context just like
# "../..." but slips a guard that only matches "../"*, *"/../"*, *"/.."  The
# validator must also catch the bare ".." case and reject fail-loud (ADR-001).
# ---------------------------------------------------------------------------
test_s15_bare_dotdot_build_script_rejected() {
  setup_manifest_sandbox "manifest-hostile-source-bare-dotdot-build-script.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_validate "${TEST_HOME}/.config/rip-cage/tools.yaml" "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "build_script\|build context\|outside.*context\|escape\|\.\." "$stderr_file"; then
    pass "S15 bare '..' build_script rejected non-zero + names the path-scope violation"
  else
    fail "S15 expected non-zero exit + path-scope error for bare '..' build_script. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# SE1 — E2E: Real docker build proves binary present in runtime, toolchain absent
# (RC_E2E=1 only; intentionally deferred to consolidated RC_E2E gate after sibling .3)
# ---------------------------------------------------------------------------
test_se1_real_build_binary_present_toolchain_absent() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (RC_E2E gated): SE1 real docker build — set RC_E2E=1 to run (deferred to consolidated RC_E2E gate after sibling .3)"
    return 0
  fi

  echo "SE1 RC_E2E=1: running real docker build with manifest-with-from-source-tool.yaml ..."

  # Fixture: manifest declaring a from-source tool (alpine:3.19 builder, build-hello-from-source.sh,
  # output at /usr/local/bin/hello-from-source). The fixture has NO install_cmd.
  local se1_fixture="${FIXTURES}/manifest-with-from-source-tool.yaml"
  local se1_image="rip-cage:se1-test"

  # Save the current rip-cage:latest so we can restore it after the build.
  local se1_saved_tag="rip-cage:se1-saved-$(date +%s)"
  local se1_had_latest=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "$se1_saved_tag" 2>/dev/null && se1_had_latest=1
  fi

  # Cleanup on any exit path: remove test image, remove our temp tag, restore latest.
  # shellcheck disable=SC2329
  _se1_cleanup() {
    docker image rm "$se1_image" 2>/dev/null || true
    if [[ "$se1_had_latest" -eq 1 ]]; then
      docker tag "$se1_saved_tag" rip-cage:latest 2>/dev/null || true
    else
      docker image rm rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "$se1_saved_tag" 2>/dev/null || true
  }
  trap _se1_cleanup RETURN

  # Run rc build with the from-source fixture.
  local build_out build_rc=0
  build_out=$(RC_MANIFEST_GLOBAL="$se1_fixture" \
    "${RC}" build 2>&1) || build_rc=$?

  if [[ "$build_rc" -ne 0 ]]; then
    fail "SE1 rc build failed (exit=${build_rc}): ${build_out:0:400}"
    return
  fi

  # Tag the built image as se1_image for assertions (and to distinguish it from
  # any subsequent build that may overwrite rip-cage:latest).
  docker tag rip-cage:latest "$se1_image" 2>/dev/null || true

  # (a) Binary PRESENT at runtime path and RUNS.
  local runtime_path="/usr/local/bin/hello-from-source"
  local run_out run_rc=0
  run_out=$(docker run --rm "$se1_image" "$runtime_path" 2>&1) || run_rc=$?
  if [[ "$run_rc" -eq 0 ]] && echo "$run_out" | grep -q "hello from source"; then
    pass "SE1(a) from-source binary present at ${runtime_path} and runs: '${run_out}'"
  else
    fail "SE1(a) from-source binary absent or did not run correctly at ${runtime_path}. exit=${run_rc} out='${run_out}'"
  fi

  # (b) Build TOOLCHAIN (alpine:3.19 builder) is ABSENT from the runtime layer.
  # The runtime base is debian:trixie — apk (alpine's package manager) must NOT exist.
  # Also: the builder stage's /usr/local/bin/hello-from-source should be the ONLY artifact
  # — alpine-specific files (/etc/apk, /lib/apk) must not be present.
  local apk_out apk_rc=0
  apk_out=$(docker run --rm "$se1_image" sh -c 'which apk 2>/dev/null || echo absent' 2>&1) || apk_rc=$?
  if echo "$apk_out" | grep -q "absent"; then
    pass "SE1(b) alpine toolchain (apk) is ABSENT from runtime layer — multi-stage isolation confirmed"
  else
    fail "SE1(b) alpine toolchain found in runtime layer: '${apk_out}' — builder stage leaked into runtime"
  fi

  # (c) Binary is correctly arch'd Linux (native to build host).
  # The build script produces a shell script (not an ELF binary), so arch verification
  # is done by checking that the container arch matches the host arch.
  # Normalize: macOS says 'arm64', Linux says 'aarch64' — both are the same arch.
  local uname_out
  uname_out=$(docker run --rm "$se1_image" uname -m 2>/dev/null) || uname_out="unknown"
  local host_arch
  host_arch=$(uname -m 2>/dev/null) || host_arch="unknown"
  # Normalize arm64 ↔ aarch64 (same arch, different OS naming conventions).
  local uname_norm host_norm
  uname_norm="${uname_out/aarch64/arm64}"
  host_norm="${host_arch/aarch64/arm64}"
  if [[ "$uname_norm" == "$host_norm" ]]; then
    pass "SE1(c) runtime arch '${uname_out}' matches host arch '${host_arch}' (normalized: ${uname_norm}) — no cross-compile target forced"
  else
    fail "SE1(c) runtime arch '${uname_out}' does not match host arch '${host_arch}' — arch mismatch detected (${uname_norm} vs ${host_norm})"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

# E2E flag from command line
if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

echo "=== test-manifest-source.sh — from-source builder stage schema + codegen (rip-cage-buuo.2) ==="
echo ""
echo "--- S1-S4: Validator schema tests ---"
test_s1_well_formed_from_source_validates_clean
test_s2_missing_builder_image_rejected
test_s3_missing_build_script_rejected
test_s4_missing_output_path_rejected

echo ""
echo "--- S5-S9: Codegen tests ---"
test_s5_codegen_contains_builder_stage
test_s6_codegen_runs_build_script_in_builder
test_s7_codegen_copies_output_into_runtime
test_s8_runtime_stage_toolchain_absent
test_s9_from_source_without_install_cmd_not_skipped

echo ""
echo "--- S10: Contradictory fields rejected ---"
test_s10_from_source_with_install_cmd_rejected

echo ""
echo "--- S11: Bundled+build_source rejected (schema gap F1) ---"
test_s11_bundled_with_build_source_rejected

echo ""
echo "--- S12: Newline-injection guard on build_source sub-fields (F2/ADR-024) ---"
test_s12_newline_in_builder_image_rejected

echo ""
echo "--- S13-S15: Path-scope guard on build_script (F2/rip-cage-buuo.6 — must be within build context) ---"
test_s13_absolute_build_script_rejected
test_s14_escape_build_script_rejected
test_s15_bare_dotdot_build_script_rejected

echo ""
echo "--- SE1: E2E real-build (RC_E2E gated) ---"
test_se1_real_build_binary_present_toolchain_absent

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
