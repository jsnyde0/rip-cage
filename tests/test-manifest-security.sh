#!/usr/bin/env bash
# Host-side + e2e tests for manifest binary-root-owned and build-isolation assertions (rip-cage-buuo.3).
# ADR-005 D9 (binary-ownership safety floor), D11 (mechanism 2 FIRM enforcement arm),
# ADR-001 (fail-loud), ADR-024 (agent-authoring threat model).
#
# Two assertions added to the build path:
#
#   Assertion 1 (binary-root-owned): A provisioned from-source tool binary, at its
#   runtime path in the built image, must be owned by root and NOT writable by
#   the agent user. Check fires AFTER docker build using docker run stat.
#
#   Assertion 2 (build-isolation): The generated builder stages must NOT bind-mount
#   host paths (RUN --mount=type=bind,src=<absolute> or VOLUME in an rc-builder-* stage).
#   Check fires BEFORE docker build — static analysis of the generated Dockerfile.
#
# Test tiers:
#
#   B1a (host-only) — Unit: _manifest_check_binary_root_owned function accepts
#        a mock stat output of "root 755" (root-owned, not agent-writable). [PASS]
#
#   B1b (host-only) — Unit: _manifest_check_binary_root_owned function rejects
#        a mock stat output of "agent 777" (agent-owned, world-writable). [FAIL-LOUD]
#
#   B1c (host-only) — Unit: _manifest_check_binary_root_owned function rejects
#        mode "755" that is root-owned but then is overridden by agent ownership. [FAIL-LOUD]
#
#   B1d (host-only) — Unit: _manifest_check_binary_root_owned function rejects
#        mode "775" (group-writable even if root-owned). [FAIL-LOUD]
#
#   BI1a (host-only) — Unit: _manifest_check_build_isolation accepts a clean
#        generated Dockerfile with rc-builder-* stage using only COPY + RUN. [PASS]
#
#   BI1b (host-only) — Unit: _manifest_check_build_isolation rejects a Dockerfile
#        with RUN --mount=type=bind,src=/host/path in an rc-builder-* stage. [FAIL-LOUD]
#
#   BI1c (host-only) — Unit: _manifest_check_build_isolation rejects a Dockerfile
#        with a VOLUME directive in an rc-builder-* stage. [FAIL-LOUD]
#
#   BI1d (host-only) — Unit: _manifest_check_build_isolation accepts a Dockerfile
#        with RUN --mount=type=bind,src=/host/path OUTSIDE an rc-builder-* stage
#        (runtime stage, not a builder stage). [PASS — only builder stages are checked]
#
#   BI1e (host-only) — Unit: _manifest_check_build_isolation is a no-op for the
#        original (non-generated) Dockerfile (no rc-builder-* stages). [PASS]
#
#   BE1 (e2e, RC_E2E=1) — Real build: a well-formed from-source tool
#        (build-hello-from-source.sh — chmod 755) passes the binary-root-owned
#        assertion. [GREEN at RC_E2E — DEFERRED]
#
#   BE2 (e2e, RC_E2E=1) — Crafted-bad: a from-source tool that chmods output 777
#        (build-hello-agent-writable.sh) causes the binary-root-owned assertion
#        to REJECT with a fail-loud error. Reverting the assertion turns it GREEN,
#        proving the assertion is load-bearing. [RC_E2E-DEFERRED — the falsifiable
#        real-build proof. Runs with RC_E2E=1 only.]
#
# EXPLICIT SKIP: BE1 and BE2 require a real docker build. They are gated behind
# RC_E2E=1. The host-side unit tests (B1a-B1d, BI1a-BI1h) cover the assertion LOGIC;
# BE2 is the falsifiable real-build crafted-bad→RED proof and is intentionally
# deferred to the consolidated RC_E2E gate (as stated in the bead's ADDENDUM).
# Do NOT claim BE2 green from host-side tests alone — that is the gated-RC_E2E
# false-green tripwire (rip-cage-test-fail-prose-without-exit-silent-red).
#
# Positive-sentinel discipline: every failure increments FAILURES.
# Script ends with exit-propagation shape: [[ $FAILURES -eq 0 ]] || exit 1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# _manifest_check_binary_root_owned lives in cli/lib/manifest_checks.sh post
# rc-decomposition (it is no longer inlined in the rc shim, which now just
# globs+sources cli/lib/*.sh and cli/*.sh) -- "assertion-active in production"
# checks below grep this file, not $RC.
MANIFEST_CHECKS_LIB="${REPO_ROOT}/cli/lib/manifest_checks.sh"
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
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-security-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_check_binary_root_owned in the sandbox with a mock docker.
# The mock docker command intercepts "docker run --rm <image> stat -c '%U %a' <path>"
# and outputs $MOCK_STAT_OUTPUT instead.
run_check_binary_root_owned_with_mock() {
  local fixture="$1"
  local mock_stat_output="$2"
  local stderr_file="${3:-/dev/null}"

  setup_manifest_sandbox "$fixture"

  # Create a mock docker that outputs the desired stat result.
  local mock_bin_dir
  mock_bin_dir="${TEST_HOME}/mock-bin"
  mkdir -p "$mock_bin_dir"
  # Write the mock docker script using a heredoc.
  # MOCK_OUTPUT is expanded; the rest of the script body is literal (single-quoted heredoc).
  local mock_docker_script
  mock_docker_script="${mock_bin_dir}/docker"
  # shellcheck disable=SC2016  # $1 and $@ are intentional literal text in the generated script
  cat > "$mock_docker_script" <<MOCK_SCRIPT
#!/bin/sh
# Mock docker for binary-root-owned unit tests (rip-cage-buuo.3)
if [ "\$1" = "run" ]; then
  echo "${mock_stat_output}"
  exit 0
fi
exec /usr/bin/docker "\$@"
MOCK_SCRIPT
  chmod +x "$mock_docker_script"

  local exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" PATH="${mock_bin_dir}:$PATH" \
    bash -c "source '${RC}'; _manifest_check_binary_root_owned 'rip-cage:test'" 2>"$stderr_file" || exit_code=$?

  teardown_manifest_sandbox
  return "$exit_code"
}

# Run _manifest_check_build_isolation with a crafted Dockerfile string.
run_check_build_isolation_with_dockerfile() {
  local dockerfile_content="$1"
  local stderr_file="${2:-/dev/null}"
  local tmp_df
  tmp_df=$(mktemp "${TMPDIR:-/tmp}/rc-test-isolation-XXXXXX")
  printf '%s\n' "$dockerfile_content" > "$tmp_df"
  local exit_code=0
  bash -c "source '${RC}'; _manifest_check_build_isolation '${tmp_df}'" 2>"$stderr_file" || exit_code=$?
  rm -f "$tmp_df"
  return "$exit_code"
}

# ---------------------------------------------------------------------------
# B1a — Mock stat "root 755": root-owned, not agent-writable → PASS
# ---------------------------------------------------------------------------
test_b1a_root_755_accepted() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_check_binary_root_owned_with_mock "manifest-with-from-source-tool.yaml" "root 755" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "B1a mock stat 'root 755' accepted (root-owned, not agent-writable)"
  else
    fail "B1a mock stat 'root 755' should pass. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# B1b — Mock stat "agent 777": agent-owned, world-writable → REJECT
# ---------------------------------------------------------------------------
test_b1b_agent_777_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_check_binary_root_owned_with_mock "manifest-with-from-source-tool.yaml" "agent 777" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "ADR-005 D9\|binary-root-owned\|agent-writable\|not root\|owned by" "$stderr_file"; then
    pass "B1b mock stat 'agent 777' rejected non-zero + error names the invariant"
  else
    fail "B1b mock stat 'agent 777' should be rejected with ADR-005 D9 error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# B1c — Mock stat "agent 755": agent-owned (even if mode is fine) → REJECT
# An agent-owned binary can be overwritten via sudo or direct write. Fail-loud.
# ---------------------------------------------------------------------------
test_b1c_agent_owned_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_check_binary_root_owned_with_mock "manifest-with-from-source-tool.yaml" "agent 755" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "ADR-005 D9\|binary-root-owned\|agent-writable\|not root\|owned by" "$stderr_file"; then
    pass "B1c mock stat 'agent 755' rejected non-zero + error names the invariant (owner check)"
  else
    fail "B1c mock stat 'agent 755' should be rejected (agent ownership violates invariant). exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# B1d — Mock stat "root 775": root-owned but group-writable → REJECT
# group-write bit set means the agent (member of agent group) could overwrite.
# ---------------------------------------------------------------------------
test_b1d_root_775_group_writable_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_check_binary_root_owned_with_mock "manifest-with-from-source-tool.yaml" "root 775" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "ADR-005 D9\|binary-root-owned\|agent-writable\|group.*writable\|mode" "$stderr_file"; then
    pass "B1d mock stat 'root 775' rejected non-zero + error names the invariant (group-writable)"
  else
    fail "B1d mock stat 'root 775' should be rejected (group-write bit). exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BI1a — Clean builder Dockerfile with only COPY + RUN → PASS
# ---------------------------------------------------------------------------
test_bi1a_clean_builder_stage_accepted() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  local clean_dockerfile
  clean_dockerfile=$(cat <<'DOCKERFILE'
# Stage 1: go-builder
FROM golang:1.25-trixie AS go-builder
RUN echo "building"

# manifest from-source builder stage: hello-from-source (rip-cage-buuo.2)
FROM alpine:3.19 AS rc-builder-hello-from-source
COPY tests/fixtures/build-hello-from-source.sh /rc-build/build.sh
RUN sh /rc-build/build.sh

# Stage 4: Runtime
FROM debian:trixie
COPY --from=rc-builder-hello-from-source /usr/local/bin/hello-from-source /usr/local/bin/hello-from-source
RUN useradd -m -u 1000 -g agent agent
DOCKERFILE
)
  run_check_build_isolation_with_dockerfile "$clean_dockerfile" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "BI1a clean builder stage (COPY+RUN only) accepted — build-isolation clean"
  else
    fail "BI1a clean builder stage should pass isolation check. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BI1b — Builder stage with RUN --mount=type=bind,src=/absolute/host/path → REJECT
# ---------------------------------------------------------------------------
test_bi1b_bind_mount_host_path_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  local hostile_dockerfile
  hostile_dockerfile=$(cat <<'DOCKERFILE'
# manifest from-source builder stage: evil-tool
FROM alpine:3.19 AS rc-builder-evil-tool
COPY tests/fixtures/build-hello-from-source.sh /rc-build/build.sh
RUN --mount=type=bind,src=/etc/passwd,dst=/etc/passwd-host sh /rc-build/build.sh

# Stage 4: Runtime
FROM debian:trixie
COPY --from=rc-builder-evil-tool /usr/local/bin/hello-from-source /usr/local/bin/hello-from-source
DOCKERFILE
)
  run_check_build_isolation_with_dockerfile "$hostile_dockerfile" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "build-isolation\|bind.*mount\|host path\|ADR-005 D9\|ADR-024" "$stderr_file"; then
    pass "BI1b RUN --mount=type=bind,src=/absolute/path in builder stage rejected + names invariant"
  else
    fail "BI1b hostile bind-mount should be rejected. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BI1c — Builder stage with VOLUME directive → REJECT
# ---------------------------------------------------------------------------
test_bi1c_volume_in_builder_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  local hostile_dockerfile
  hostile_dockerfile=$(cat <<'DOCKERFILE'
# manifest from-source builder stage: evil-tool
FROM alpine:3.19 AS rc-builder-evil-tool
COPY tests/fixtures/build-hello-from-source.sh /rc-build/build.sh
VOLUME /host-secret
RUN sh /rc-build/build.sh

# Stage 4: Runtime
FROM debian:trixie
COPY --from=rc-builder-evil-tool /usr/local/bin/hello-from-source /usr/local/bin/hello-from-source
DOCKERFILE
)
  run_check_build_isolation_with_dockerfile "$hostile_dockerfile" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "build-isolation\|VOLUME\|ADR-005 D9\|ADR-024" "$stderr_file"; then
    pass "BI1c VOLUME in builder stage rejected + names invariant"
  else
    fail "BI1c VOLUME in builder stage should be rejected. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BI1d — RUN --mount=type=bind,src=/absolute/path OUTSIDE builder stage → PASS
# The runtime stage can use bind mounts (e.g. for SSH keys); only builder
# stages are scoped for build-isolation.
# ---------------------------------------------------------------------------
test_bi1d_bind_mount_outside_builder_accepted() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  local runtime_bind_dockerfile
  runtime_bind_dockerfile=$(cat <<'DOCKERFILE'
# manifest from-source builder stage: hello-from-source (clean)
FROM alpine:3.19 AS rc-builder-hello-from-source
COPY tests/fixtures/build-hello-from-source.sh /rc-build/build.sh
RUN sh /rc-build/build.sh

# Stage 4: Runtime — bind mount here is fine (not a builder stage)
FROM debian:trixie
COPY --from=rc-builder-hello-from-source /usr/local/bin/hello-from-source /usr/local/bin/hello-from-source
RUN --mount=type=bind,src=/etc/hosts,dst=/etc/hosts-copy cat /etc/hosts-copy
DOCKERFILE
)
  run_check_build_isolation_with_dockerfile "$runtime_bind_dockerfile" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "BI1d RUN --mount=type=bind outside builder stage (in runtime) is accepted"
  else
    fail "BI1d bind mount in runtime stage should NOT be flagged. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BI1e — Original Dockerfile (no rc-builder-* stages) → no-op PASS
# _manifest_check_build_isolation is called with the original Dockerfile path
# (not a generated temp file); the function must pass cleanly (no builder stages).
# ---------------------------------------------------------------------------
test_bi1e_original_dockerfile_noop() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  # The original Dockerfile has no rc-builder-* stages.
  bash -c "source '${RC}'; _manifest_check_build_isolation '${REPO_ROOT}/cage/Dockerfile'" 2>"$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "BI1e original Dockerfile (no rc-builder-* stages) passes isolation check (no-op)"
  else
    fail "BI1e original Dockerfile should pass isolation check cleanly. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BI1f — Empty/absent Dockerfile path → no-op PASS
# When all tools are bundled, _manifest_build_dockerfile_path returns the
# original path. If called with an empty string, the function should no-op.
# Defensive guard test: cmd_build never triggers _manifest_check_build_isolation
# with an empty arg (it gates on non-empty tmp Dockerfile), but the guard is
# still exercised here for belt-and-suspenders coverage.
# ---------------------------------------------------------------------------
test_bi1f_empty_path_noop() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  bash -c "source '${RC}'; _manifest_check_build_isolation ''" 2>"$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "BI1f empty dockerfile path is a no-op (no builder stages to check)"
  else
    fail "BI1f empty dockerfile path should be no-op. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BI1g — Builder stage with RUN --mount=type=ssh → REJECT
# --mount=type=ssh injects the host SSH agent socket into the build step,
# giving the builder stage direct access to the host SSH agent (host-resource
# access vector). Must be rejected fail-loud naming the vector.
# ---------------------------------------------------------------------------
test_bi1g_ssh_mount_in_builder_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  local hostile_dockerfile
  hostile_dockerfile=$(cat <<'DOCKERFILE'
# manifest from-source builder stage: evil-tool
FROM alpine:3.19 AS rc-builder-evil-tool
COPY tests/fixtures/build-hello-from-source.sh /rc-build/build.sh
RUN --mount=type=ssh sh /rc-build/build.sh

# Stage: Runtime
FROM debian:trixie
COPY --from=rc-builder-evil-tool /usr/local/bin/hello-from-source /usr/local/bin/hello-from-source
DOCKERFILE
)
  run_check_build_isolation_with_dockerfile "$hostile_dockerfile" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "build-isolation\|ssh\|ADR-005 D9\|ADR-024" "$stderr_file"; then
    pass "BI1g RUN --mount=type=ssh in builder stage rejected + names invariant"
  else
    fail "BI1g RUN --mount=type=ssh in builder stage should be rejected. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BI1h — Builder stage with RUN --mount=type=secret → REJECT
# --mount=type=secret exposes host build secrets (e.g. API keys, credentials)
# into the build step, giving the builder stage access to host secrets
# (host-resource access vector). Must be rejected fail-loud naming the vector.
# ---------------------------------------------------------------------------
test_bi1h_secret_mount_in_builder_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  local hostile_dockerfile
  hostile_dockerfile=$(cat <<'DOCKERFILE'
# manifest from-source builder stage: evil-tool
FROM alpine:3.19 AS rc-builder-evil-tool
COPY tests/fixtures/build-hello-from-source.sh /rc-build/build.sh
RUN --mount=type=secret,id=mytoken sh /rc-build/build.sh

# Stage: Runtime
FROM debian:trixie
COPY --from=rc-builder-evil-tool /usr/local/bin/hello-from-source /usr/local/bin/hello-from-source
DOCKERFILE
)
  run_check_build_isolation_with_dockerfile "$hostile_dockerfile" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "build-isolation\|secret\|ADR-005 D9\|ADR-024" "$stderr_file"; then
    pass "BI1h RUN --mount=type=secret in builder stage rejected + names invariant"
  else
    fail "BI1h RUN --mount=type=secret in builder stage should be rejected. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BE1 — E2E: Real build with compliant from-source tool passes binary-root-owned
# (RC_E2E=1 only — intentionally deferred to consolidated RC_E2E gate)
# ---------------------------------------------------------------------------
test_be1_real_build_compliant_tool_passes() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (RC_E2E gated): BE1 real docker build compliant tool — set RC_E2E=1 to run"
    echo "  [RC_E2E-deferred] BE1 would build with manifest-with-from-source-tool.yaml (chmod 755 output)"
    echo "  and assert _manifest_check_binary_root_owned passes (root-owned, 755 → not agent-writable)."
    return 0
  fi

  echo "BE1 RC_E2E=1: real build with manifest-with-from-source-tool.yaml (chmod 755) — expect PASS ..."

  local be1_fixture="${FIXTURES}/manifest-with-from-source-tool.yaml"
  local be1_image="rip-cage:be1-test"

  # Save rip-cage:latest for restore.
  local be1_saved_tag
  be1_saved_tag="rip-cage:be1-saved-$(date +%s)"
  local be1_had_latest=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "$be1_saved_tag" 2>/dev/null && be1_had_latest=1
  fi

  # shellcheck disable=SC2329
  _be1_cleanup() {
    docker image rm "$be1_image" 2>/dev/null || true
    if [[ "$be1_had_latest" -eq 1 ]]; then
      docker tag "$be1_saved_tag" rip-cage:latest 2>/dev/null || true
    else
      docker image rm rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "$be1_saved_tag" 2>/dev/null || true
  }
  trap _be1_cleanup RETURN

  # rc build with the compliant fixture (chmod 755 output).
  local build_out build_rc=0
  build_out=$(RC_MANIFEST_GLOBAL="$be1_fixture" \
    "${RC}" build 2>&1) || build_rc=$?

  if [[ "$build_rc" -ne 0 ]]; then
    fail "BE1 rc build with compliant fixture failed (exit=${build_rc}): ${build_out:0:400}"
    return
  fi

  # Tag for assertions.
  docker tag rip-cage:latest "$be1_image" 2>/dev/null || true

  # Effect assertion: stat the binary inside the built image — must be root-owned, mode 755.
  local runtime_path="/usr/local/bin/hello-from-source"
  local stat_out stat_rc=0
  stat_out=$(docker run --rm "$be1_image" stat -c '%U %a' "$runtime_path" 2>&1) || stat_rc=$?

  if [[ "$stat_rc" -ne 0 ]]; then
    fail "BE1 could not stat binary '${runtime_path}' in built image. stat_rc=${stat_rc} out='${stat_out}'"
    return
  fi

  local stat_owner stat_mode
  stat_owner=$(awk '{print $1}' <<<"$stat_out")
  stat_mode=$(awk '{print $2}' <<<"$stat_out")

  if [[ "$stat_owner" == "root" && "$stat_mode" == "755" ]]; then
    pass "BE1 compliant build PASSES binary-root-owned check: owner=${stat_owner} mode=${stat_mode} (root-owned, not agent-writable)"
  else
    fail "BE1 expected root 755 on binary, got owner='${stat_owner}' mode='${stat_mode}' — binary-root-owned check would reject this"
  fi
}

# ---------------------------------------------------------------------------
# BE2 — E2E: Crafted-bad fixture (agent-writable binary) causes binary-root-owned
# assertion to REJECT with fail-loud error. Reverting the assertion turns it GREEN.
#
# EXPLICIT SKIP: This is the RC_E2E-gated falsifiable proof. The host-side unit
# tests (B1b, B1d) prove the assertion LOGIC using mock stat; BE2 proves the
# assertion fires against a REAL built image. They are different altitudes.
# "host-side B1b GREEN" does NOT claim "BE2 GREEN" — gated-RC_E2E false-green tripwire.
# ---------------------------------------------------------------------------
test_be2_crafted_bad_agent_writable_rejected() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (RC_E2E gated): BE2 crafted-bad agent-writable binary → must be RED on real build"
    echo "  [RC_E2E-deferred] To verify: set RC_E2E=1, then:"
    echo "    1. Install manifest-hostile-agent-writable-binary.yaml as the global tools.yaml"
    echo "    2. rc build — must FAIL with ADR-005 D9 binary-root-owned error"
    echo "    3. Revert _manifest_check_binary_root_owned from rc and rc build — must PASS"
    echo "    4. That RED→GREEN transition proves the assertion is load-bearing."
    echo "  Fixture: tests/fixtures/manifest-hostile-agent-writable-binary.yaml"
    echo "  Build script: tests/fixtures/build-hello-agent-writable.sh (chmod 777 output)"
    return 0
  fi

  echo "BE2 RC_E2E=1: crafted-bad agent-writable binary (chmod 777) — must REJECT with ADR-005 D9 error ..."

  local be2_fixture="${FIXTURES}/manifest-hostile-agent-writable-binary.yaml"
  local be2_image="rip-cage:be2-test"

  # Save rip-cage:latest for restore.
  local be2_saved_tag
  be2_saved_tag="rip-cage:be2-saved-$(date +%s)"
  local be2_had_latest=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "$be2_saved_tag" 2>/dev/null && be2_had_latest=1
  fi

  # shellcheck disable=SC2329
  _be2_cleanup() {
    # Ensure no violating image is left tagged as rip-cage:latest.
    docker image rm rip-cage:latest 2>/dev/null || true
    if [[ "$be2_had_latest" -eq 1 ]]; then
      docker tag "$be2_saved_tag" rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "$be2_saved_tag" 2>/dev/null || true
    docker image rm "$be2_image" 2>/dev/null || true
  }
  trap _be2_cleanup RETURN

  # -----------------------------------------------------------------------
  # Step 1: rc build with hostile fixture — must FAIL (binary-root-owned check fires)
  # -----------------------------------------------------------------------
  local be2_step1_out be2_step1_rc=0
  be2_step1_out=$(RC_MANIFEST_GLOBAL="$be2_fixture" \
    "${RC}" build 2>&1) || be2_step1_rc=$?

  # The build must fail with the ADR-005 D9 binary-root-owned error.
  local be2_error_signal
  be2_error_signal=$(grep -iE "ADR-005 D9|binary-root-owned|agent-writable|owned by.*not root|not root" <<<"$be2_step1_out" | head -1)

  if [[ "$be2_step1_rc" -ne 0 ]] && [[ -n "$be2_error_signal" ]]; then
    pass "BE2 step1: hostile build REJECTED with ADR-005 D9 binary-root-owned error (exit=${be2_step1_rc}): '${be2_error_signal}'"
  elif [[ "$be2_step1_rc" -eq 0 ]]; then
    fail "BE2 step1: hostile build SUCCEEDED (exit=0) — binary-root-owned assertion did NOT fire. Build allowed an agent-writable binary. out='${be2_step1_out:0:300}'"
    return
  else
    fail "BE2 step1: build failed (exit=${be2_step1_rc}) but error message missing ADR-005 D9 signal. out='${be2_step1_out:0:400}'"
    return
  fi

  # -----------------------------------------------------------------------
  # F1 fix: After step 1 failure, rip-cage:latest must NOT be tagged to the
  # violating image. cmd_build calls `docker image rm "$IMAGE"` on violation.
  # -----------------------------------------------------------------------
  if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
    pass "BE2 F1: after binary-root-owned rejection, rip-cage:latest is NOT tagged to the violating image"
  else
    # It might have been restored by a previous test; check if it's the violating build.
    # The violating image should have been untagged — if latest exists, it must be our saved one.
    local latest_id saved_id
    latest_id=$(docker image inspect rip-cage:latest --format '{{.Id}}' 2>/dev/null)
    saved_id=$(docker image inspect "$be2_saved_tag" --format '{{.Id}}' 2>/dev/null)
    if [[ -n "$be2_saved_tag" ]] && [[ "$latest_id" == "$saved_id" ]]; then
      pass "BE2 F1: rip-cage:latest after rejection is the pre-test saved image (not the violating build)"
    else
      fail "BE2 F1: rip-cage:latest still tagged after binary-root-owned rejection (violating image not untagged)"
    fi
  fi

  # -----------------------------------------------------------------------
  # Step 2: FALSIFIABILITY PROOF — disable the assertion, same build must PASS.
  # We override _manifest_check_binary_root_owned by sourcing rc in a subshell
  # and redefining the function to always return 0. This tests without modifying
  # any production file.
  # -----------------------------------------------------------------------
  echo "BE2 falsifiability: disabling _manifest_check_binary_root_owned (override in subshell) — same hostile build must PASS ..."

  local be2_repo_root
  be2_repo_root="$(cd "$(dirname "${RC}")" && pwd)"

  local be2_step2_out be2_step2_rc=0
  be2_step2_out=$(
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export RC_MANIFEST_GLOBAL="$be2_fixture"
    # Source rc. When rc is sourced (not executed), $0 is the shell name, so
    # _resolve_script_dir returns the wrong dir. Override SCRIPT_DIR explicitly.
    # shellcheck disable=SC1090
    source "${RC}"
    SCRIPT_DIR="$be2_repo_root"
    # Override the binary-root-owned check to always succeed (disabled).
    # This proves the check is the load-bearing discriminator.
    # shellcheck disable=SC2329  # invoked indirectly by cmd_build in this subshell
    _manifest_check_binary_root_owned() { return 0; }
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export OUTPUT_FORMAT=""
    cmd_build
  ) || be2_step2_rc=$?

  if [[ "$be2_step2_rc" -eq 0 ]]; then
    pass "BE2 falsifiability: with _manifest_check_binary_root_owned DISABLED, hostile build PASSES — assertion is load-bearing (RED→GREEN proven)"
  else
    fail "BE2 falsifiability: expected build to pass with assertion disabled, but exit=${be2_step2_rc}. out='${be2_step2_out:0:300}'"
  fi

  # Verify the production assertion is still in place (assertion active on
  # disk, defined in cli/lib/manifest_checks.sh post-decomposition).
  if grep -q "_manifest_check_binary_root_owned" "${MANIFEST_CHECKS_LIB}"; then
    pass "BE2 assertion-active: _manifest_check_binary_root_owned is PRESENT in cli/lib/manifest_checks.sh (production assertion active)"
  else
    fail "BE2 assertion-active: _manifest_check_binary_root_owned NOT FOUND in cli/lib/manifest_checks.sh — production assertion removed!"
  fi
}

# ---------------------------------------------------------------------------
# BE3 — E2E: _pull_or_build auto-build path (rc up without prior rc build) enforces
# D11 validators. A crafted-bad from-source tool (agent-writable binary) provisioned
# via _pull_or_build (RIP_CAGE_IMAGE_REGISTRY unset → local build) must be REJECTED
# with the ADR-005 D9 fail-loud error and leave NO tainted rip-cage:latest.
#
# This tests the F1 fix from rip-cage-buuo.6: _pull_or_build previously called
# docker build WITHOUT the D11 validators. After the fix, both build branches in
# _pull_or_build wire _manifest_check_build_isolation (pre-build) and
# _manifest_check_binary_root_owned (post-build) with the same semantics as cmd_build.
#
# RC_E2E=1 required (real docker build).
# ---------------------------------------------------------------------------
test_be3_pull_or_build_auto_build_path_rejects_hostile() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (RC_E2E gated): BE3 _pull_or_build auto-build path D11 enforcement — set RC_E2E=1 to run"
    echo "  [RC_E2E-deferred] BE3 would invoke _pull_or_build with RIP_CAGE_IMAGE_REGISTRY='' and"
    echo "  manifest-hostile-agent-writable-binary.yaml — expect REJECTION with ADR-005 D9 error,"
    echo "  no tainted rip-cage:latest. The F1 fix wires both D11 validators into _pull_or_build."
    echo "  Fixture: tests/fixtures/manifest-hostile-agent-writable-binary.yaml"
    return 0
  fi

  echo "BE3 RC_E2E=1: _pull_or_build auto-build path with hostile fixture — must REJECT with D11 error ..."

  local be3_fixture="${FIXTURES}/manifest-hostile-agent-writable-binary.yaml"

  # Save rip-cage:latest for restore.
  local be3_saved_tag
  be3_saved_tag="rip-cage:be3-saved-$(date +%s)"
  local be3_had_latest=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "$be3_saved_tag" 2>/dev/null && be3_had_latest=1
  fi

  # shellcheck disable=SC2329
  _be3_cleanup() {
    docker image rm rip-cage:latest 2>/dev/null || true
    if [[ "$be3_had_latest" -eq 1 ]]; then
      docker tag "$be3_saved_tag" rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "$be3_saved_tag" 2>/dev/null || true
  }
  trap _be3_cleanup RETURN

  # Remove rip-cage:latest so _pull_or_build must build (not skip).
  docker image rm rip-cage:latest 2>/dev/null || true

  # Invoke _pull_or_build directly in a subshell with RIP_CAGE_IMAGE_REGISTRY=''
  # (forces the local-build branch, bypassing pull). Use RC_MANIFEST_GLOBAL to inject
  # the hostile fixture.
  local be3_repo_root
  be3_repo_root="$(cd "$(dirname "${RC}")" && pwd)"

  # Invoke _pull_or_build in an isolated subprocess, capturing all output to a file.
  # docker BuildKit writes progress to stderr; the D11 error from _manifest_check_binary_root_owned
  # also goes to stderr. We capture everything to a temp file and scan it for the D11 signal.
  local be3_out_file be3_rc=0
  be3_out_file=$(mktemp)
  (
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export RC_MANIFEST_GLOBAL="$be3_fixture"
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export RIP_CAGE_IMAGE_REGISTRY=""
    # Source rc in subshell; override SCRIPT_DIR for sourced-context correctness.
    # shellcheck disable=SC1090
    source "${RC}"
    SCRIPT_DIR="$be3_repo_root"
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export OUTPUT_FORMAT=""
    _pull_or_build
  ) >"$be3_out_file" 2>&1 || be3_rc=$?
  local be3_combined
  be3_combined=$(cat "$be3_out_file")
  rm -f "$be3_out_file"

  # The call must FAIL (non-zero) with the ADR-005 D9 binary-root-owned error.
  local be3_error_signal
  be3_error_signal=$(grep -iE "ADR-005 D9|binary-root-owned|agent-writable|owned by.*not root|not root" <<<"$be3_combined" | head -1)

  if [[ "$be3_rc" -ne 0 ]] && [[ -n "$be3_error_signal" ]]; then
    pass "BE3 step1: _pull_or_build auto-build REJECTED with ADR-005 D9 error (exit=${be3_rc}): '${be3_error_signal}'"
  elif [[ "$be3_rc" -eq 0 ]]; then
    fail "BE3 step1: _pull_or_build auto-build SUCCEEDED (exit=0) — D11 validators NOT wired (F1 bypass still present). out='${be3_combined:0:300}'"
    return
  else
    fail "BE3 step1: _pull_or_build failed (exit=${be3_rc}) but missing ADR-005 D9 signal. combined='${be3_combined: -500}'"
    return
  fi

  # After rejection, rip-cage:latest must NOT be tagged to the violating image.
  if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
    pass "BE3 F1: after D11 rejection, rip-cage:latest is NOT tagged to the violating image"
  else
    local be3_latest_id be3_saved_id
    be3_latest_id=$(docker image inspect rip-cage:latest --format '{{.Id}}' 2>/dev/null)
    be3_saved_id=$(docker image inspect "$be3_saved_tag" --format '{{.Id}}' 2>/dev/null)
    if [[ -n "$be3_saved_tag" ]] && [[ "$be3_latest_id" == "$be3_saved_id" ]]; then
      pass "BE3 F1: rip-cage:latest after rejection is the pre-test saved image (not the violating build)"
    else
      fail "BE3 F1: rip-cage:latest still tagged after D11 rejection (violating image not untagged)"
    fi
  fi

  # -----------------------------------------------------------------------
  # Falsifiability: also verify _pull_or_build passes with a COMPLIANT fixture.
  # -----------------------------------------------------------------------
  local be3_good_fixture="${FIXTURES}/manifest-with-from-source-tool.yaml"
  docker image rm rip-cage:latest 2>/dev/null || true

  local be3_good_out_file be3_good_rc=0
  be3_good_out_file=$(mktemp)
  (
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export RC_MANIFEST_GLOBAL="$be3_good_fixture"
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export RIP_CAGE_IMAGE_REGISTRY=""
    # shellcheck disable=SC1090
    source "${RC}"
    SCRIPT_DIR="$be3_repo_root"
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export OUTPUT_FORMAT=""
    _pull_or_build
  ) >"$be3_good_out_file" 2>&1 || be3_good_rc=$?
  local be3_good_out
  be3_good_out=$(cat "$be3_good_out_file")
  rm -f "$be3_good_out_file"

  if [[ "$be3_good_rc" -eq 0 ]]; then
    pass "BE3 compliant: _pull_or_build auto-build PASSES with compliant fixture (root-owned, 755)"
  else
    fail "BE3 compliant: _pull_or_build with compliant fixture failed (exit=${be3_good_rc}). out='${be3_good_out:0:300}'"
  fi
}

# ---------------------------------------------------------------------------
# B2a — Mock stat "root 755" for prebuilt entry WITH binary_path: PASS
# A prebuilt install_cmd TOOL entry that declares binary_path and the binary
# is root-owned 755 must pass.
# ---------------------------------------------------------------------------
test_b2a_prebuilt_root_755_accepted() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_check_binary_root_owned_with_mock "manifest-prebuilt-with-binary-path.yaml" "root 755" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "B2a prebuilt mock stat 'root 755' accepted (root-owned, not agent-writable)"
  else
    fail "B2a prebuilt mock stat 'root 755' should pass. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# B2b — Mock stat "agent 777" for prebuilt entry WITH binary_path: REJECT
# ---------------------------------------------------------------------------
test_b2b_prebuilt_agent_777_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_check_binary_root_owned_with_mock "manifest-prebuilt-with-binary-path.yaml" "agent 777" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "ADR-005 D9\|binary-root-owned\|agent-writable\|not root\|owned by" "$stderr_file"; then
    pass "B2b prebuilt mock stat 'agent 777' rejected non-zero + error names the invariant"
  else
    fail "B2b prebuilt mock stat 'agent 777' should be rejected with ADR-005 D9 error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# B2c — Mock stat "agent 755" for prebuilt entry WITH binary_path: REJECT (bad owner)
# ---------------------------------------------------------------------------
test_b2c_prebuilt_agent_owned_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_check_binary_root_owned_with_mock "manifest-prebuilt-with-binary-path.yaml" "agent 755" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "ADR-005 D9\|binary-root-owned\|agent-writable\|not root\|owned by" "$stderr_file"; then
    pass "B2c prebuilt mock stat 'agent 755' rejected non-zero + error names the invariant (owner check)"
  else
    fail "B2c prebuilt mock stat 'agent 755' should be rejected (agent ownership). exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# B2d — Mock stat "root 775" for prebuilt entry WITH binary_path: REJECT (group-writable)
# ---------------------------------------------------------------------------
test_b2d_prebuilt_root_775_group_writable_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_check_binary_root_owned_with_mock "manifest-prebuilt-with-binary-path.yaml" "root 775" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "ADR-005 D9\|binary-root-owned\|agent-writable\|group.*writable\|mode" "$stderr_file"; then
    pass "B2d prebuilt mock stat 'root 775' rejected non-zero + error names the invariant (group-writable)"
  else
    fail "B2d prebuilt mock stat 'root 775' should be rejected (group-write bit). exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# B2e — Prebuilt entry WITHOUT binary_path is NOT checked (skipped, builds clean)
# A prebuilt install_cmd TOOL entry with no binary_path declared must be skipped
# entirely — the validator must not fire for it (no docker stat call, exit 0).
# ---------------------------------------------------------------------------
test_b2e_prebuilt_no_binary_path_skipped() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  # Use a fixture with a prebuilt install_cmd but NO binary_path.
  # We use a mock docker that always returns "agent 777" — if the validator fires
  # for this entry, it would fail. If it's correctly skipped, it passes.
  run_check_binary_root_owned_with_mock "manifest-valid-non-bundled-with-install-cmd.yaml" "agent 777" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "B2e prebuilt entry WITHOUT binary_path is skipped (not checked by binary-root-owned)"
  else
    fail "B2e prebuilt without binary_path should be skipped (not trigger binary check). exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# B2f — Prebuilt entry with binary_path as a LIST: all paths are checked.
# When binary_path is a list, each declared path must be checked.
# Mock returns "root 755" — should PASS for all paths.
# ---------------------------------------------------------------------------
test_b2f_prebuilt_binary_path_list_accepted() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_check_binary_root_owned_with_mock "manifest-prebuilt-with-binary-path-list.yaml" "root 755" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "B2f prebuilt binary_path as list, mock 'root 755' accepted for all paths"
  else
    fail "B2f prebuilt binary_path list with 'root 755' should pass. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# Schema validation tests for binary_path field (rip-cage-ryn6)
#
# BS1a — binary_path as string accepted
# BS1b — binary_path as list of strings accepted
# BS1c — binary_path as empty string rejected
# BS1d — binary_path as multiline string rejected
# BS1e — binary_path as relative path (no leading /) rejected
# ---------------------------------------------------------------------------

# Helper: run _manifest_validate on inline YAML content and return exit code.
run_schema_validate_inline() {
  local yaml_content="$1"
  local stderr_file="${2:-/dev/null}"
  local tmp_yaml
  tmp_yaml=$(mktemp "${TMPDIR:-/tmp}/rc-test-manifest-XXXXXX.yaml")
  printf '%s\n' "$yaml_content" > "$tmp_yaml"

  local exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_MANIFEST_GLOBAL="$tmp_yaml" \
    bash -c "source '${RC}'; _manifest_validate '${tmp_yaml}'" 2>"$stderr_file" || exit_code=$?

  rm -f "$tmp_yaml"
  return "$exit_code"
}

# BS1a — binary_path as single-line absolute string accepted
test_bs1a_binary_path_string_accepted() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox ""

  local yaml_content
  yaml_content=$(cat <<'YAML'
version: 1
tools:
  - name: test-prebuilt
    archetype: TOOL
    version_pin: "1.0.0"
    install_cmd: "curl -fsSL https://example.com/tool -o /usr/local/bin/mytool && chmod 755 /usr/local/bin/mytool"
    binary_path: "/usr/local/bin/mytool"
    egress: []
    mounts: []
YAML
)

  run_schema_validate_inline "$yaml_content" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "BS1a binary_path as absolute string accepted by schema validator"
  else
    fail "BS1a binary_path as absolute string should be accepted. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  teardown_manifest_sandbox
  rm -f "$stderr_file"
}

# BS1b — binary_path as list of absolute strings accepted
test_bs1b_binary_path_list_accepted() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox ""

  local yaml_content
  yaml_content=$(cat <<'YAML'
version: 1
tools:
  - name: test-prebuilt-multi
    archetype: TOOL
    version_pin: "1.0.0"
    install_cmd: "install -m 755 /tmp/tool1 /usr/local/bin/tool1 && install -m 755 /tmp/tool2 /usr/local/bin/tool2"
    binary_path:
      - "/usr/local/bin/tool1"
      - "/usr/local/bin/tool2"
    egress: []
    mounts: []
YAML
)

  run_schema_validate_inline "$yaml_content" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "BS1b binary_path as list of absolute strings accepted by schema validator"
  else
    fail "BS1b binary_path as list of absolute strings should be accepted. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  teardown_manifest_sandbox
  rm -f "$stderr_file"
}

# BS1c — binary_path as empty string rejected
test_bs1c_binary_path_empty_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox ""

  local yaml_content
  yaml_content=$(cat <<'YAML'
version: 1
tools:
  - name: test-prebuilt-empty
    archetype: TOOL
    version_pin: "1.0.0"
    install_cmd: "curl -fsSL https://example.com/tool -o /usr/local/bin/mytool && chmod 755 /usr/local/bin/mytool"
    binary_path: ""
    egress: []
    mounts: []
YAML
)

  run_schema_validate_inline "$yaml_content" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "binary_path\|empty\|non-empty" "$stderr_file"; then
    pass "BS1c binary_path as empty string rejected with error naming binary_path"
  else
    fail "BS1c binary_path empty string should be rejected. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  teardown_manifest_sandbox
  rm -f "$stderr_file"
}

# BS1d — binary_path with embedded newline rejected (multiline)
test_bs1d_binary_path_multiline_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox ""

  # Use printf to embed a real newline in the YAML value.
  local tmp_yaml
  tmp_yaml=$(mktemp "${TMPDIR:-/tmp}/rc-test-schema-XXXXXX.yaml")
  printf 'version: 1\ntools:\n  - name: test-prebuilt-newline\n    archetype: TOOL\n    version_pin: "1.0.0"\n    install_cmd: "apt-get install -y jq"\n    binary_path: "/usr/local/bin/tool1\\n/usr/local/bin/tool2"\n    egress: []\n    mounts: []\n' > "$tmp_yaml"

  local exit_code2=0
  bash -c "source '${RC}'; _manifest_validate '${tmp_yaml}'" 2>"$stderr_file" || exit_code2=$?
  rm -f "$tmp_yaml"

  if [[ "$exit_code2" -ne 0 ]] && grep -qi "binary_path\|single.line\|newline" "$stderr_file"; then
    pass "BS1d binary_path with embedded newline rejected with error naming binary_path"
  else
    fail "BS1d binary_path multiline should be rejected. exit=$exit_code2 stderr=$(cat "$stderr_file")"
  fi
  teardown_manifest_sandbox
  rm -f "$stderr_file"
}

# BS1e — binary_path as relative path (no leading slash) rejected
test_bs1e_binary_path_relative_rejected() {
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox ""

  local yaml_content
  yaml_content=$(cat <<'YAML'
version: 1
tools:
  - name: test-prebuilt-relpath
    archetype: TOOL
    version_pin: "1.0.0"
    install_cmd: "apt-get install -y jq"
    binary_path: "usr/local/bin/jq"
    egress: []
    mounts: []
YAML
)

  run_schema_validate_inline "$yaml_content" "$stderr_file" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "binary_path\|absolute\|leading slash\|must start" "$stderr_file"; then
    pass "BS1e binary_path relative path rejected with error naming binary_path"
  else
    fail "BS1e binary_path relative path should be rejected. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  teardown_manifest_sandbox
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# BE4 — E2E: Real build with compliant PREBUILT fixture (install_cmd + binary_path)
# passes binary-root-owned assertion. (RC_E2E=1 only)
# ---------------------------------------------------------------------------
test_be4_real_build_compliant_prebuilt_passes() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (RC_E2E gated): BE4 real docker build compliant PREBUILT tool — set RC_E2E=1 to run"
    echo "  [RC_E2E-deferred] BE4 would build with manifest-prebuilt-compliant.yaml (install_cmd"
    echo "  that installs root-owned 755 binary + declares binary_path) and assert"
    echo "  _manifest_check_binary_root_owned passes."
    return 0
  fi

  echo "BE4 RC_E2E=1: real build with manifest-prebuilt-compliant.yaml (root-owned 755) — expect PASS ..."

  local be4_fixture="${FIXTURES}/manifest-prebuilt-compliant.yaml"
  local be4_image="rip-cage:be4-test"

  local be4_saved_tag
  be4_saved_tag="rip-cage:be4-saved-$(date +%s)"
  local be4_had_latest=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "$be4_saved_tag" 2>/dev/null && be4_had_latest=1
  fi

  # shellcheck disable=SC2329
  _be4_cleanup() {
    docker image rm "$be4_image" 2>/dev/null || true
    if [[ "$be4_had_latest" -eq 1 ]]; then
      docker tag "$be4_saved_tag" rip-cage:latest 2>/dev/null || true
    else
      docker image rm rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "$be4_saved_tag" 2>/dev/null || true
  }
  trap _be4_cleanup RETURN

  local build_out build_rc=0
  build_out=$(RC_MANIFEST_GLOBAL="$be4_fixture" \
    "${RC}" build 2>&1) || build_rc=$?

  if [[ "$build_rc" -ne 0 ]]; then
    fail "BE4 rc build with compliant prebuilt fixture failed (exit=${build_rc}): ${build_out:0:400}"
    return
  fi

  docker tag rip-cage:latest "$be4_image" 2>/dev/null || true

  # Effect assertion: stat the binary inside the built image — must be root-owned, mode 755.
  local runtime_path="/usr/local/bin/hello-prebuilt"
  local stat_out stat_rc=0
  stat_out=$(docker run --rm "$be4_image" stat -c '%U %a' "$runtime_path" 2>&1) || stat_rc=$?

  if [[ "$stat_rc" -ne 0 ]]; then
    fail "BE4 could not stat binary '${runtime_path}' in built image. stat_rc=${stat_rc} out='${stat_out}'"
    return
  fi

  local stat_owner stat_mode
  stat_owner=$(awk '{print $1}' <<<"$stat_out")
  stat_mode=$(awk '{print $2}' <<<"$stat_out")

  if [[ "$stat_owner" == "root" && "$stat_mode" == "755" ]]; then
    pass "BE4 compliant PREBUILT build PASSES binary-root-owned check: owner=${stat_owner} mode=${stat_mode}"
  else
    fail "BE4 expected root 755 on prebuilt binary, got owner='${stat_owner}' mode='${stat_mode}'"
  fi
}

# ---------------------------------------------------------------------------
# BE5 — E2E: Crafted-bad PREBUILT fixture (install_cmd with chmod 777 + binary_path)
# causes binary-root-owned assertion to REJECT with fail-loud error.
# Falsifiability: reverting the prebuilt coverage turns it GREEN, proving load-bearing.
# (RC_E2E=1 only)
# ---------------------------------------------------------------------------
test_be5_crafted_bad_prebuilt_rejected() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (RC_E2E gated): BE5 crafted-bad PREBUILT agent-writable binary → must be RED on real build"
    echo "  [RC_E2E-deferred] BE5 would build with manifest-prebuilt-hostile.yaml (install_cmd"
    echo "  that chmods the binary 777 + declares binary_path) and assert REJECTION."
    echo "  Reverting the prebuilt coverage in _manifest_check_binary_root_owned turns it GREEN."
    echo "  Fixture: tests/fixtures/manifest-prebuilt-hostile.yaml"
    return 0
  fi

  echo "BE5 RC_E2E=1: crafted-bad PREBUILT (chmod 777 on declared binary) — must REJECT with ADR-005 D9 error ..."

  local be5_fixture="${FIXTURES}/manifest-prebuilt-hostile.yaml"

  local be5_saved_tag
  be5_saved_tag="rip-cage:be5-saved-$(date +%s)"
  local be5_had_latest=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "$be5_saved_tag" 2>/dev/null && be5_had_latest=1
  fi

  # shellcheck disable=SC2329
  _be5_cleanup() {
    docker image rm rip-cage:latest 2>/dev/null || true
    if [[ "$be5_had_latest" -eq 1 ]]; then
      docker tag "$be5_saved_tag" rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "$be5_saved_tag" 2>/dev/null || true
  }
  trap _be5_cleanup RETURN

  # -----------------------------------------------------------------------
  # Step 1: rc build with hostile prebuilt fixture — must FAIL
  # -----------------------------------------------------------------------
  local be5_step1_out be5_step1_rc=0
  be5_step1_out=$(RC_MANIFEST_GLOBAL="$be5_fixture" \
    "${RC}" build 2>&1) || be5_step1_rc=$?

  local be5_error_signal
  be5_error_signal=$(grep -iE "ADR-005 D9|binary-root-owned|agent-writable|owned by.*not root|not root" <<<"$be5_step1_out" | head -1)

  if [[ "$be5_step1_rc" -ne 0 ]] && [[ -n "$be5_error_signal" ]]; then
    pass "BE5 step1: hostile PREBUILT build REJECTED with ADR-005 D9 binary-root-owned error (exit=${be5_step1_rc}): '${be5_error_signal}'"
  elif [[ "$be5_step1_rc" -eq 0 ]]; then
    fail "BE5 step1: hostile PREBUILT build SUCCEEDED (exit=0) — prebuilt binary-root-owned coverage NOT wired. out='${be5_step1_out:0:300}'"
    return
  else
    fail "BE5 step1: build failed (exit=${be5_step1_rc}) but error message missing ADR-005 D9 signal. out='${be5_step1_out:0:400}'"
    return
  fi

  # -----------------------------------------------------------------------
  # F1 fix: After step 1 failure, rip-cage:latest must NOT be tagged to violating image.
  # -----------------------------------------------------------------------
  if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
    pass "BE5 F1: after binary-root-owned rejection, rip-cage:latest is NOT tagged to the violating image"
  else
    local be5_latest_id be5_saved_id
    be5_latest_id=$(docker image inspect rip-cage:latest --format '{{.Id}}' 2>/dev/null)
    be5_saved_id=$(docker image inspect "$be5_saved_tag" --format '{{.Id}}' 2>/dev/null)
    if [[ -n "$be5_saved_tag" ]] && [[ "$be5_latest_id" == "$be5_saved_id" ]]; then
      pass "BE5 F1: rip-cage:latest after rejection is the pre-test saved image (not the violating build)"
    else
      fail "BE5 F1: rip-cage:latest still tagged after binary-root-owned rejection (violating image not untagged)"
    fi
  fi

  # -----------------------------------------------------------------------
  # Step 2: FALSIFIABILITY PROOF — disable the prebuilt branch of assertion,
  # same build must PASS (RED→GREEN).
  # We override _manifest_check_binary_root_owned by redefining it in a subshell.
  # -----------------------------------------------------------------------
  echo "BE5 falsifiability: disabling _manifest_check_binary_root_owned — hostile PREBUILT build must PASS ..."

  local be5_repo_root
  be5_repo_root="$(cd "$(dirname "${RC}")" && pwd)"

  local be5_step2_out be5_step2_rc=0
  be5_step2_out=$(
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export RC_MANIFEST_GLOBAL="$be5_fixture"
    # shellcheck disable=SC1090
    source "${RC}"
    SCRIPT_DIR="$be5_repo_root"
    # shellcheck disable=SC2329
    _manifest_check_binary_root_owned() { return 0; }
    # shellcheck disable=SC2030,SC2031  # intentional: per-case env override scoped to subshell
    export OUTPUT_FORMAT=""
    cmd_build
  ) || be5_step2_rc=$?

  if [[ "$be5_step2_rc" -eq 0 ]]; then
    pass "BE5 falsifiability: with _manifest_check_binary_root_owned DISABLED, hostile PREBUILT build PASSES — assertion is load-bearing (RED→GREEN proven)"
  else
    fail "BE5 falsifiability: expected build to pass with assertion disabled, but exit=${be5_step2_rc}. out='${be5_step2_out:0:300}'"
  fi

  if grep -q "_manifest_check_binary_root_owned" "${MANIFEST_CHECKS_LIB}"; then
    pass "BE5 assertion-active: _manifest_check_binary_root_owned is PRESENT in cli/lib/manifest_checks.sh (production assertion active)"
  else
    fail "BE5 assertion-active: _manifest_check_binary_root_owned NOT FOUND in cli/lib/manifest_checks.sh — production assertion removed!"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

echo "=== test-manifest-security.sh — binary-root-owned + build-isolation assertions (rip-cage-buuo.3) ==="
echo ""
echo "--- B1a-B1d: Unit tests for _manifest_check_binary_root_owned (mock stat, from-source) ---"
test_b1a_root_755_accepted
test_b1b_agent_777_rejected
test_b1c_agent_owned_rejected
test_b1d_root_775_group_writable_rejected

echo ""
echo "--- B2a-B2f: Unit tests for _manifest_check_binary_root_owned (mock stat, prebuilt binary_path; rip-cage-ryn6) ---"
test_b2a_prebuilt_root_755_accepted
test_b2b_prebuilt_agent_777_rejected
test_b2c_prebuilt_agent_owned_rejected
test_b2d_prebuilt_root_775_group_writable_rejected
test_b2e_prebuilt_no_binary_path_skipped
test_b2f_prebuilt_binary_path_list_accepted

echo ""
echo "--- BS1a-BS1e: Schema validation unit tests for binary_path field (rip-cage-ryn6) ---"
test_bs1a_binary_path_string_accepted
test_bs1b_binary_path_list_accepted
test_bs1c_binary_path_empty_rejected
test_bs1d_binary_path_multiline_rejected
test_bs1e_binary_path_relative_rejected

echo ""
echo "--- BI1a-BI1h: Unit tests for _manifest_check_build_isolation (crafted Dockerfiles) ---"
test_bi1a_clean_builder_stage_accepted
test_bi1b_bind_mount_host_path_rejected
test_bi1c_volume_in_builder_rejected
test_bi1d_bind_mount_outside_builder_accepted
test_bi1e_original_dockerfile_noop
test_bi1f_empty_path_noop
test_bi1g_ssh_mount_in_builder_rejected
test_bi1h_secret_mount_in_builder_rejected

echo ""
echo "--- BE1-BE2: E2E (RC_E2E gated — real-build falsifiable proof via cmd_build, from-source) ---"
test_be1_real_build_compliant_tool_passes
test_be2_crafted_bad_agent_writable_rejected

echo ""
echo "--- BE3: E2E (RC_E2E gated — D11 enforcement on _pull_or_build auto-build path; rip-cage-buuo.6 F1) ---"
test_be3_pull_or_build_auto_build_path_rejects_hostile

echo ""
echo "--- BE4-BE5: E2E (RC_E2E gated — prebuilt binary_path coverage; rip-cage-ryn6) ---"
test_be4_real_build_compliant_prebuilt_passes
test_be5_crafted_bad_prebuilt_rejected

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
