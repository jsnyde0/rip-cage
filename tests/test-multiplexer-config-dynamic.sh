#!/usr/bin/env bash
# test-multiplexer-config-dynamic.sh — Dynamic session.multiplexer config-validation
# (rip-cage-61al.4)
#
# Verifies that session.multiplexer's allowed set derives dynamically from
# the baked registry (rc.multiplexers image label) rather than a static enum.
# Also verifies the pre-build manifest-enumeration fallback and ADR-001
# fail-loud for unbaked names.
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   T1  (host-only, runs always):
#     T1a — grep confirms no 'none,tmux,herdr' literal in rc (static enum gone)
#     T1b — session.multiplexer: none passes config-validate (none always allowed)
#     T1c — session.multiplexer: unbaked-name fails loud with fix-naming message
#           (non-zero exit + message names 'rc build')
#     T1d — pre-build manifest-enumeration fallback: manifest declares MULTIPLEXER
#           'test-mux', no image built yet → 'test-mux' passes config-validate
#     T1e — pre-build fallback is discriminating: manifest without test-mux,
#           session.multiplexer: test-mux → still fails loud (not a silent pass)
#
#   T2  (e2e, NEEDS_CONTAINER / RC_E2E=1):
#     T2a — rc build with MULTIPLEXER fixture → rc.multiplexers label written
#     T2b — session.multiplexer: test-mux passes config-validate for built image
#           with rc.multiplexers=test-mux (label-based derivation)
#     T2c — session.multiplexer: ghost-mux fails loud for built image that only
#           has rc.multiplexers=test-mux (ghost-mux not in baked set)
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
TEST_WS=""

# Unset any driver-level RC_CONFIG_GLOBAL so per-call XDG sandboxes work.
unset RC_CONFIG_GLOBAL

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
cleanup_on_exit() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "${TEST_HOME}"
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
trap cleanup_on_exit EXIT INT TERM

T2_IMAGE=""
T2_SAVED_TAG=""
T2_HAD_LATEST=0
T2_BUILD_FAILED=0

# ---------------------------------------------------------------------------
# Sandbox helpers
# ---------------------------------------------------------------------------
setup_sandbox() {
  local global_fixture="${1:-}" project_fixture="${2:-}" manifest_fixture="${3:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-mux-config-dynamic-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "${TEST_WS}"
  # Default minimal global config (avoids mounts.denylist warnings)
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist: []
YAML
  if [[ -n "${global_fixture}" ]]; then
    cp "${FIXTURES}/${global_fixture}" "${TEST_HOME}/.config/rip-cage/config.yaml"
  fi
  if [[ -n "${project_fixture}" ]]; then
    cp "${FIXTURES}/${project_fixture}" "${TEST_WS}/.rip-cage.yaml"
  fi
  if [[ -n "${manifest_fixture}" ]]; then
    cp "${FIXTURES}/${manifest_fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  else
    # Empty tools.yaml: no manifest entries (default bundled stack, D8)
    touch "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "${TEST_HOME}"
  TEST_HOME=""
  TEST_WS=""
}

# Run rc config show in the sandbox.
# Args: stderr_file [rc_image_tag [manifest_path]]
#
# Env vars are exported by the function (not as a prefix to 'cd' inside bash -c),
# because assignments preceding bash builtins are not visible to subsequent
# commands in the same shell session.
run_rc_config_show() {
  local stderr_file="${1:-/dev/null}"
  local rc_image="${2:-}"
  local manifest_path="${3:-}"

  local RC_MUX_INSPECT_IMAGE_VAL="${rc_image}"
  local RC_MANIFEST_GLOBAL_VAL="${manifest_path}"

  HOME="${TEST_HOME}" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MUX_INSPECT_IMAGE="${RC_MUX_INSPECT_IMAGE_VAL}" \
    RC_MANIFEST_GLOBAL="${RC_MANIFEST_GLOBAL_VAL}" \
    bash -c "cd '${TEST_WS}' && '${RC}' config show --json" 2>"${stderr_file}"
}

echo "=== test-multiplexer-config-dynamic.sh — dynamic session.multiplexer schema (rip-cage-61al.4) ==="
echo ""
echo "--- T1: Host-only unit tests ---"

# ---------------------------------------------------------------------------
# T1a — Static enum literal 'none,tmux,herdr' is GONE from rc.
# ---------------------------------------------------------------------------
test_t1a_static_enum_gone() {
  local count
  count=$(grep -c 'none,tmux,herdr' "${RC}" 2>/dev/null || true)
  if [[ "$count" -eq 0 ]]; then
    pass "T1a 'none,tmux,herdr' static enum literal is absent from rc"
  else
    fail "T1a 'none,tmux,herdr' still present in rc (${count} occurrences) — static enum must be removed"
  fi
}

# ---------------------------------------------------------------------------
# T1b — session.multiplexer: none passes config-validate.
# 'none' is always in the allowed set regardless of baked registry.
# ---------------------------------------------------------------------------
test_t1b_none_passes() {
  # Use empty manifest (no MULTIPLEXER entries), no image needed
  setup_sandbox "" "" ""

  # Write project config with session.multiplexer: none
  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
session:
  multiplexer: none
YAML

  local exit_code=0
  local stderr_file
  stderr_file=$(mktemp)
  # Force non-existent image so label path fails → manifest fallback used
  run_rc_config_show "$stderr_file" "rip-cage:nonexistent-test-image-t1b" >/dev/null || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "T1b session.multiplexer=none passes config-validate"
  else
    fail "T1b session.multiplexer=none should pass but exited ${exit_code}. stderr='$(cat "$stderr_file")'"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# T1c — session.multiplexer: unbaked-name fails loud with fix-naming message.
# An unknown name (not in manifest, no image) must exit non-zero and name the fix.
# ---------------------------------------------------------------------------
test_t1c_unbaked_fails_loud() {
  # Empty manifest (no MULTIPLEXER entries), no real image
  setup_sandbox "" "" ""

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
session:
  multiplexer: ghost-mux
YAML

  local exit_code=0
  local stderr_file
  stderr_file=$(mktemp)
  run_rc_config_show "$stderr_file" "rip-cage:nonexistent-test-image-t1c" >/dev/null || exit_code=$?
  local err_out
  err_out=$(cat "$stderr_file")

  if [[ "$exit_code" -ne 0 ]]; then
    pass "T1c session.multiplexer=ghost-mux fails loud (non-zero exit) when not in manifest/registry"
  else
    fail "T1c session.multiplexer=ghost-mux should fail but exited 0. stderr='${err_out}'"
  fi

  # Error message must name the fix: 'rc build'
  if echo "$err_out" | grep -q "rc build"; then
    pass "T1c error message names the fix ('rc build')"
  else
    fail "T1c error message does not name 'rc build'. stderr='${err_out}'"
  fi

  rm -f "$stderr_file"
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# T1d — Pre-build manifest-enumeration fallback: manifest declares MULTIPLEXER
# 'test-mux', no real image → 'test-mux' passes config-validate.
# ---------------------------------------------------------------------------
test_t1d_manifest_fallback_passes() {
  # Use the valid multiplexer fixture (has 'test-mux' MULTIPLEXER entry)
  setup_sandbox "" "" "manifest-multiplexer-valid.yaml"

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
session:
  multiplexer: test-mux
YAML

  local exit_code=0
  local stderr_file
  stderr_file=$(mktemp)
  # Use non-existent image → force manifest fallback; explicit manifest path
  run_rc_config_show "$stderr_file" \
    "rip-cage:nonexistent-test-image-t1d" \
    "${FIXTURES}/manifest-multiplexer-valid.yaml" >/dev/null || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "T1d session.multiplexer=test-mux passes config-validate via manifest-enumeration fallback (pre-build)"
  else
    fail "T1d session.multiplexer=test-mux should pass via manifest fallback but exited ${exit_code}. stderr='$(cat "$stderr_file")'"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# T1e — Pre-build fallback is discriminating: manifest WITHOUT test-mux, yet
# session.multiplexer: test-mux → still fails loud (not a silent pass).
# ---------------------------------------------------------------------------
test_t1e_manifest_fallback_rejects_absent_name() {
  # Empty manifest (no MULTIPLEXER entries)
  setup_sandbox "" "" ""

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
session:
  multiplexer: test-mux
YAML

  local exit_code=0
  local stderr_file
  stderr_file=$(mktemp)
  # Non-existent image → manifest fallback, but manifest has no 'test-mux'
  run_rc_config_show "$stderr_file" "rip-cage:nonexistent-test-image-t1e" >/dev/null || exit_code=$?
  local err_out
  err_out=$(cat "$stderr_file")

  if [[ "$exit_code" -ne 0 ]]; then
    pass "T1e session.multiplexer=test-mux (not in manifest, no image) fails loud — fallback is not fail-open"
  else
    fail "T1e session.multiplexer=test-mux should fail when not in manifest/registry but exited 0. stderr='${err_out}'"
  fi

  # Should still name the fix
  if echo "$err_out" | grep -q "rc build"; then
    pass "T1e error message names the fix ('rc build') for manifest-fallback rejection"
  else
    fail "T1e error message does not name 'rc build'. stderr='${err_out}'"
  fi

  rm -f "$stderr_file"
  teardown_sandbox
}

# Run T1 tests
test_t1a_static_enum_gone
test_t1b_none_passes
test_t1c_unbaked_fails_loud
test_t1d_manifest_fallback_passes
test_t1e_manifest_fallback_rejects_absent_name

echo ""
echo "--- T2: E2E assertions (NEEDS_CONTAINER / RC_E2E=1) ---"

# ---------------------------------------------------------------------------
# E2E guard
# ---------------------------------------------------------------------------
if [[ "${RC_E2E:-}" != "1" ]]; then
  echo "SKIP (NEEDS_CONTAINER / e2e): T2a-T2c — set RC_E2E=1 to run"
  echo ""
  if [[ "$FAILURES" -eq 0 ]]; then
    echo "All T1 tests passed."
    exit 0
  else
    echo "$FAILURES T1 test(s) failed."
    exit 1
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  if [[ "$FAILURES" -eq 0 ]]; then exit 0; else exit 1; fi
fi

# ---------------------------------------------------------------------------
# T2 image setup — build once, use for T2a-T2c.
# Saves + restores existing rip-cage:latest; uses a throwaway tag.
# ---------------------------------------------------------------------------
_t2_build_test_image() {
  if [[ -n "${T2_IMAGE:-}" ]]; then
    return 0
  fi
  if [[ "${T2_BUILD_FAILED:-0}" -eq 1 ]]; then
    return 1
  fi

  local unique_suffix
  unique_suffix="$(date +%s)-$$"
  T2_SAVED_TAG="rip-cage:mux-config-dyn-saved-${unique_suffix}"
  T2_HAD_LATEST=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "${T2_SAVED_TAG}" 2>/dev/null && T2_HAD_LATEST=1
  fi

  local fixture_file="${FIXTURES}/manifest-multiplexer-valid.yaml"
  echo "[T2 setup] Building rip-cage image with manifest-multiplexer-valid.yaml (test-mux)..."

  local build_rc=0
  RC_MANIFEST_GLOBAL="${fixture_file}" "${REPO_ROOT}/rc" build >/tmp/rc-mux-config-dyn-build.out 2>&1 || build_rc=$?

  if [[ "$build_rc" -ne 0 ]]; then
    echo "[T2 setup] FAIL: rc build failed (exit=${build_rc}). See /tmp/rc-mux-config-dyn-build.out" >&2
    T2_BUILD_FAILED=1
    return 1
  fi

  T2_IMAGE="rip-cage:mux-config-dyn-test-${unique_suffix}"
  docker tag rip-cage:latest "${T2_IMAGE}" 2>/dev/null || true
  echo "[T2 setup] Image built and tagged: ${T2_IMAGE}"
  return 0
}

# ---------------------------------------------------------------------------
# T2a — Built image has rc.multiplexers=test-mux label.
# ---------------------------------------------------------------------------
test_t2a_image_has_mux_label() {
  if ! _t2_build_test_image; then
    fail "T2a Image build failed"
    return
  fi

  local label
  label=$(docker inspect --format '{{ index .Config.Labels "rc.multiplexers" }}' "${T2_IMAGE}" 2>/dev/null || echo "")
  if echo "$label" | grep -q "test-mux"; then
    pass "T2a rc.multiplexers label contains 'test-mux': '${label}'"
  else
    fail "T2a rc.multiplexers label missing 'test-mux'. Got: '${label}'"
  fi
}

# ---------------------------------------------------------------------------
# T2b — session.multiplexer: test-mux passes config-validate for built image.
# The label rc.multiplexers=test-mux is the authoritative source at runtime.
# ---------------------------------------------------------------------------
test_t2b_baked_mux_passes() {
  if ! _t2_build_test_image; then
    fail "T2b Image build failed"
    return
  fi

  setup_sandbox "" "" "manifest-multiplexer-valid.yaml"

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
session:
  multiplexer: test-mux
YAML

  local exit_code=0
  local stderr_file
  stderr_file=$(mktemp)
  # Pass the throwaway image tag → label-based derivation reads test-mux
  run_rc_config_show "$stderr_file" \
    "${T2_IMAGE}" \
    "${FIXTURES}/manifest-multiplexer-valid.yaml" >/dev/null || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "T2b session.multiplexer=test-mux passes config-validate for image with rc.multiplexers=test-mux"
  else
    fail "T2b session.multiplexer=test-mux should pass for baked image but exited ${exit_code}. stderr='$(cat "$stderr_file")'"
  fi
  rm -f "$stderr_file"
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# T2c — session.multiplexer: ghost-mux fails loud for built image that only
# has rc.multiplexers=test-mux (ghost-mux not in baked set).
# ---------------------------------------------------------------------------
test_t2c_unbaked_fails_loud_with_image() {
  if ! _t2_build_test_image; then
    fail "T2c Image build failed"
    return
  fi

  setup_sandbox "" "" "manifest-multiplexer-valid.yaml"

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
session:
  multiplexer: ghost-mux
YAML

  local exit_code=0
  local stderr_file
  stderr_file=$(mktemp)
  run_rc_config_show "$stderr_file" \
    "${T2_IMAGE}" \
    "${FIXTURES}/manifest-multiplexer-valid.yaml" >/dev/null || exit_code=$?
  local err_out
  err_out=$(cat "$stderr_file")

  if [[ "$exit_code" -ne 0 ]]; then
    pass "T2c session.multiplexer=ghost-mux fails loud for image with rc.multiplexers=test-mux (ghost-mux not baked)"
  else
    fail "T2c session.multiplexer=ghost-mux should fail for baked image but exited 0. stderr='${err_out}'"
  fi

  # Error message must name the fix
  if echo "$err_out" | grep -q "rc build"; then
    pass "T2c error message names the fix ('rc build') for label-based rejection"
  else
    fail "T2c error message does not name 'rc build'. stderr='${err_out}'"
  fi

  rm -f "$stderr_file"
  teardown_sandbox
}

test_t2a_image_has_mux_label
test_t2b_baked_mux_passes
test_t2c_unbaked_fails_loud_with_image

# ---------------------------------------------------------------------------
# T2d — Image present but NO rc.multiplexers label → label is authoritative
# (allowed = "none" only); manifest fallback must NOT be consulted.
#
# Setup: build a throwaway image without any rc.multiplexers label (simulates
# a pre-label image or one built before the mux feature). The manifest declares
# test-mux as a MULTIPLEXER, so under the old (buggy) code the manifest fallback
# would incorrectly accept test-mux. Under the correct code, image-present +
# empty label = no muxes baked = "none" only → test-mux must fail loud naming
# 'rc build'.
#
# This is the discriminating test for Finding 1: it proves the image-present
# label path is authoritative and the manifest fallback is NOT consulted when
# the image exists.
# ---------------------------------------------------------------------------
T2D_IMAGE=""
test_t2d_image_present_unlabeled_label_authoritative() {
  # Build a minimal image with no rc.multiplexers label (label-less image).
  local unique_suffix
  unique_suffix="$(date +%s)-$$-t2d"
  T2D_IMAGE="rip-cage:mux-config-dyn-unlabeled-${unique_suffix}"
  local build_rc=0
  # Build from existing debian:trixie base — no LABEL rc.multiplexers, so the
  # image exists but carries an empty (absent) rc.multiplexers value.
  docker build -t "${T2D_IMAGE}" -f - "${REPO_ROOT}" <<'DOCKERFILE' >/tmp/rc-mux-t2d-build.out 2>&1 || build_rc=$?
FROM debian:trixie
LABEL maintainer="rip-cage-test"
DOCKERFILE
  if [[ "$build_rc" -ne 0 ]]; then
    fail "T2d throwaway image build failed (exit=${build_rc}). See /tmp/rc-mux-t2d-build.out"
    return
  fi

  # Confirm: image exists, label is absent/empty
  local label
  label=$(docker inspect --format '{{ index .Config.Labels "rc.multiplexers" }}' "${T2D_IMAGE}" 2>/dev/null || echo "")
  if [[ -n "$label" ]]; then
    fail "T2d test setup error: throwaway image unexpectedly has rc.multiplexers='${label}'"
    docker image rm "${T2D_IMAGE}" 2>/dev/null || true
    T2D_IMAGE=""
    return
  fi

  # Sandbox: manifest declares test-mux as MULTIPLEXER; project config sets test-mux.
  setup_sandbox "" "" "manifest-multiplexer-valid.yaml"
  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
session:
  multiplexer: test-mux
YAML

  local exit_code=0
  local stderr_file
  stderr_file=$(mktemp)
  # Point RC_MUX_INSPECT_IMAGE at the unlabeled image.
  # Image exists → label authoritative (empty = no muxes baked = "none" only).
  # Manifest has test-mux but must NOT be consulted.
  run_rc_config_show "$stderr_file" \
    "${T2D_IMAGE}" \
    "${FIXTURES}/manifest-multiplexer-valid.yaml" >/dev/null || exit_code=$?
  local err_out
  err_out=$(cat "$stderr_file")

  if [[ "$exit_code" -ne 0 ]]; then
    pass "T2d image-present+unlabeled: test-mux fails loud (label authoritative; manifest fallback NOT consulted)"
  else
    fail "T2d image-present+unlabeled: test-mux should fail loud (label authoritative) but exited 0. stderr='${err_out}'"
  fi

  if echo "$err_out" | grep -q "rc build"; then
    pass "T2d error message names the fix ('rc build') for unlabeled-image rejection"
  else
    fail "T2d error message does not name 'rc build'. stderr='${err_out}'"
  fi

  rm -f "$stderr_file"
  teardown_sandbox
  docker image rm "${T2D_IMAGE}" 2>/dev/null || true
  T2D_IMAGE=""
}

test_t2d_image_present_unlabeled_label_authoritative

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
