#!/usr/bin/env bash
# Host-side + e2e tests for herdr TOOL manifest fixture (rip-cage-1f59.5).
# herdr: github.com/ogulcancelik/herdr — agent-aware terminal multiplexer.
# Distribution: prebuilt release binaries (herdr-linux-x86_64, herdr-linux-aarch64).
# Archetype: TOOL (binary on PATH; server start dispatched via the baked MULTIPLEXER registry).
#
# ADR-005 D7 (TOOL archetype: binary install + egress declaration).
# ADR-021 D6 (session.multiplexer: tmux drops as hard dep; herdr is opt-in via manifest).
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   T1  (host-only, runs always):
#     T1a — Fixture parses + validates against manifest schema (strict-parse,
#           fail-closed per ADR-001 / ADR-025 D5).
#     T1b — install_cmd downloads a prebuilt release binary (contains
#           'releases/download' — no cargo build, no install.sh).
#     T1c — install_cmd is arch-adaptive (references uname -m, not hardcoded arch).
#     T1d — install_cmd uses 'install -m 755' or chown root to place binary root-owned.
#     T1e — Strict-parse rejects a TOOL entry missing install_cmd (missing-field guard).
#     T1f — Default seed manifest does NOT contain a herdr entry (regression guard, ADR-005 D12).
#     T1g — Formula/rip-cage.rb does NOT contain 'depends_on "tmux"' (ADR-021 D6).
#
#   T2  (e2e, NEEDS_CONTAINER / RC_E2E=1):
#     T2a — rc build with herdr manifest installs herdr binary in cage.
#     T2b — herdr binary is root-owned and NOT agent-writable (ADR-005 D9).
#     T2c — init-rip-cage.sh starts the herdr server process via the baked
#           MULTIPLEXER registry when RC_MULTIPLEXER=herdr; pgrep shows herdr running.
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
FIXTURE_FILE="${FIXTURES}/manifest-herdr.yaml"
# T2 build fixture: two-entry fixture (herdr-bin TOOL + herdr MULTIPLEXER).
# The TOOL-only fixture (manifest-herdr.yaml) does not bake the MULTIPLEXER registry,
# so init-rip-cage.sh registry dispatch would exit 1 — T2c/T2d must use this fixture.
T2_FIXTURE_FILE="${FIXTURES}/manifest-herdr-multiplexer.yaml"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  if [[ -n "${T2_BUILD_MANIFEST_HOME:-}" ]]; then
    rm -rf "$T2_BUILD_MANIFEST_HOME"
    T2_BUILD_MANIFEST_HOME=""
  fi
}
trap cleanup EXIT

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
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-herdr-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

echo "=== test-manifest-herdr.sh — herdr TOOL manifest fixture (rip-cage-1f59.5) ==="
echo ""
echo "--- T1: Host-only unit tests ---"

# ---------------------------------------------------------------------------
# T1a — Fixture parses + validates against manifest schema (strict-parse).
# ---------------------------------------------------------------------------
test_t1a_fixture_validates_strict_parse() {
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  setup_manifest_sandbox "manifest-herdr.yaml"
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${FIXTURE_FILE}'" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "T1a herdr fixture strict-parse validates: _manifest_validate exits 0"
  else
    fail "T1a herdr fixture strict-parse FAILED: exit=${exit_code} stderr='$(cat "$stderr_file")' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1b — install_cmd downloads a prebuilt release binary (not cargo build).
# ---------------------------------------------------------------------------
test_t1b_install_cmd_is_prebuilt_download() {
  if [[ ! -f "$FIXTURE_FILE" ]]; then
    fail "T1b Fixture missing — cannot check install_cmd"
    return
  fi

  local install_cmd
  install_cmd=$(yq -o=json '.tools[] | select(.name == "herdr") | .install_cmd' "$FIXTURE_FILE" 2>/dev/null | tr -d '"')

  if [[ -z "$install_cmd" ]]; then
    fail "T1b Could not extract install_cmd from fixture (herdr entry not found or install_cmd empty)"
    return
  fi

  if echo "$install_cmd" | grep -q "releases/download"; then
    pass "T1b install_cmd references prebuilt release download (releases/download)"
  else
    fail "T1b install_cmd does NOT reference releases/download. Got: '${install_cmd:0:100}'"
  fi

  if echo "$install_cmd" | grep -q "cargo build"; then
    fail "T1b install_cmd uses cargo build — NOT viable for prebuilt-only distribution"
  else
    pass "T1b install_cmd does NOT use cargo build (correct: prebuilt download)"
  fi

  if echo "$install_cmd" | grep -qE "install\.sh|herdr\.dev/install"; then
    fail "T1b install_cmd calls install.sh — NOT allowed (install.sh may have side effects unfit for headless Dockerfile build)"
  else
    pass "T1b install_cmd does NOT call install.sh (correct: direct asset download)"
  fi
}

# ---------------------------------------------------------------------------
# T1c — install_cmd is arch-adaptive (uses uname -m, not hardcoded arch).
# ---------------------------------------------------------------------------
test_t1c_install_cmd_arch_adaptive() {
  if [[ ! -f "$FIXTURE_FILE" ]]; then
    fail "T1c Fixture missing — cannot check arch-adaptivity"
    return
  fi

  local install_cmd
  install_cmd=$(yq -o=json '.tools[] | select(.name == "herdr") | .install_cmd' "$FIXTURE_FILE" 2>/dev/null | tr -d '"')

  if [[ -z "$install_cmd" ]]; then
    fail "T1c Could not extract install_cmd"
    return
  fi

  if echo "$install_cmd" | grep -q "uname -m\|uname.*m\|\$(uname"; then
    pass "T1c install_cmd is arch-adaptive (uses uname -m for arch detection)"
  else
    fail "T1c install_cmd does NOT use uname -m for arch detection — may be hardcoded arch. Got: '${install_cmd:0:120}'"
  fi
}

# ---------------------------------------------------------------------------
# T1d — install_cmd places the binary root-owned (uses 'install -m 755').
# Root-owned binary is required by ADR-005 D9.
# ---------------------------------------------------------------------------
test_t1d_install_cmd_root_owned_binary() {
  if [[ ! -f "$FIXTURE_FILE" ]]; then
    fail "T1d Fixture missing — cannot check root-owned binary installation"
    return
  fi

  local install_cmd
  install_cmd=$(yq -o=json '.tools[] | select(.name == "herdr") | .install_cmd' "$FIXTURE_FILE" 2>/dev/null | tr -d '"')

  if [[ -z "$install_cmd" ]]; then
    fail "T1d Could not extract install_cmd"
    return
  fi

  # 'install -m 755 <binary> /usr/local/bin/' places binary as root-owned (Dockerfile RUN stage = root)
  if echo "$install_cmd" | grep -qE "install -m [0-9]+ .*(/usr/local/bin|/usr/bin)"; then
    pass "T1d install_cmd uses 'install -m <mode>' to /usr/local/bin (binary placed root-owned by Dockerfile RUN root)"
  else
    fail "T1d install_cmd does not use 'install -m <mode> ... /usr/local/bin' — cannot confirm root-owned placement. Got: '${install_cmd:0:120}'"
  fi
}

# ---------------------------------------------------------------------------
# T1e — Strict-parse rejects a TOOL entry with no install_cmd and non-bundled
# version_pin. _manifest_validate exits non-zero and names the missing field.
# ---------------------------------------------------------------------------
test_t1e_strict_parse_rejects_missing_install_cmd() {
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: herdr-no-install-cmd
    archetype: TOOL
    version_pin: "0.6.10"
    egress:
      - github.com
    mounts: []
YAML

  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file") || exit_code=$?

  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "install_cmd"; then
    pass "T1e Strict-parse rejects TOOL with missing install_cmd: exits non-zero and names 'install_cmd'"
  else
    fail "T1e Strict-parse: expected non-zero exit + 'install_cmd' in error. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1f — Default seed manifest does NOT contain a herdr entry (regression guard).
# herdr was removed from _manifest_default_yaml (ADR-005 D12: composable seam,
# default ships minimal/core-only). This is the inverse of the previous assertion —
# it guards the regression direction: herdr must not silently re-enter the default.
# Users who want herdr add it via their own manifest entry (see examples/herdr/).
# ---------------------------------------------------------------------------
test_t1f_default_seed_does_not_contain_herdr() {
  local seed_out
  seed_out=$(bash -c "source '${RC}'; _manifest_default_yaml" 2>/dev/null)

  if ! echo "$seed_out" | grep -q "name: herdr"; then
    pass "T1f _manifest_default_yaml seed does NOT contain 'name: herdr' (ADR-005 D12: default is core-only)"
  else
    fail "T1f _manifest_default_yaml seed CONTAINS 'name: herdr' — herdr must NOT be in the seeded default manifest (ADR-005 D12 regression)"
  fi

  # Also verify the default seed itself still validates (core-only is valid)
  local seed_file seed_validate_rc
  seed_file=$(mktemp)
  bash -c "source '${RC}'; _manifest_default_yaml" > "$seed_file" 2>/dev/null
  seed_validate_rc=0
  bash -c "source '${RC}'; _manifest_validate '${seed_file}'" 2>/dev/null || seed_validate_rc=$?
  rm -f "$seed_file"

  if [[ "$seed_validate_rc" -eq 0 ]]; then
    pass "T1f Default seed manifest (core-only, no herdr) passes _manifest_validate"
  else
    fail "T1f Default seed manifest FAILS _manifest_validate (core-only seed is invalid)"
  fi
}

# ---------------------------------------------------------------------------
# T1g — Formula/rip-cage.rb does NOT contain 'depends_on "tmux"' (ADR-021 D6).
# tmux becomes optional/manifest-installed, not a hard Homebrew dependency.
# ---------------------------------------------------------------------------
test_t1g_formula_no_tmux_dep() {
  local formula_file="${REPO_ROOT}/packaging/Formula/rip-cage.rb"
  if [[ ! -f "$formula_file" ]]; then
    fail "T1g Formula/rip-cage.rb not found at expected path"
    return
  fi

  local tmux_dep_count
  tmux_dep_count=$(grep -c 'depends_on "tmux"' "$formula_file" 2>/dev/null || true)

  if [[ "${tmux_dep_count}" -eq 0 ]]; then
    pass "T1g Formula/rip-cage.rb has no 'depends_on \"tmux\"' (tmux is optional — ADR-021 D6)"
  else
    fail "T1g Formula/rip-cage.rb still has 'depends_on \"tmux\"' (${tmux_dep_count} occurrence(s)) — must be removed (ADR-021 D6)"
  fi
}

# Run T1 tests
test_t1a_fixture_validates_strict_parse
test_t1b_install_cmd_is_prebuilt_download
test_t1c_install_cmd_arch_adaptive
test_t1d_install_cmd_root_owned_binary
test_t1e_strict_parse_rejects_missing_install_cmd
test_t1f_default_seed_does_not_contain_herdr
test_t1g_formula_no_tmux_dep

echo ""
echo "--- T2: E2E assertions (NEEDS_CONTAINER / RC_E2E=1) ---"

# ---------------------------------------------------------------------------
# T2 state
# ---------------------------------------------------------------------------
T2_BUILD_MANIFEST_HOME=""
T2_BUILD_FAILED=0

_t2_build_herdr_image() {
  if [[ -n "${T2_BUILD_MANIFEST_HOME:-}" ]]; then
    return 0
  fi
  if [[ "${T2_BUILD_FAILED:-0}" -eq 1 ]]; then
    return 1
  fi

  T2_BUILD_MANIFEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-herdr-e2e-home-XXXXXX")
  mkdir -p "${T2_BUILD_MANIFEST_HOME}/.config/rip-cage"
  # Use the two-entry fixture: herdr-bin TOOL (installs binary) + herdr MULTIPLEXER
  # (bakes start/attach hooks into /etc/rip-cage/multiplexers/herdr/).
  # The TOOL-only fixture (manifest-herdr.yaml) does not bake the registry, so
  # init-rip-cage.sh registry dispatch (ADR-005 D12) would exit 1 at T2c/T2d.
  cp "${T2_FIXTURE_FILE}" "${T2_BUILD_MANIFEST_HOME}/.config/rip-cage/tools.yaml"

  local build_out build_rc
  build_rc=0
  echo "[T2 setup] Building cage image with herdr two-entry manifest (TOOL+MULTIPLEXER, downloads prebuilt binary — may take ~1min)..."
  build_out=$(HOME="$T2_BUILD_MANIFEST_HOME" \
    XDG_CONFIG_HOME="${T2_BUILD_MANIFEST_HOME}/.config" \
    "${REPO_ROOT}/rc" build 2>&1) || build_rc=$?

  if [[ "$build_rc" -ne 0 ]]; then
    local build_tail
    build_tail=$(echo "$build_out" | tail -30)
    echo "[T2 setup] FAIL: cage image build failed (exit=${build_rc}). Last 30 lines:" >&2
    echo "$build_tail" >&2
    rm -rf "$T2_BUILD_MANIFEST_HOME"
    T2_BUILD_MANIFEST_HOME=""
    T2_BUILD_FAILED=1
    return 1
  fi

  echo "[T2 setup] Image built: rip-cage:latest"
  return 0
}

# ---------------------------------------------------------------------------
# T2a — rc build with herdr manifest installs herdr binary in cage.
# ---------------------------------------------------------------------------
test_t2a_herdr_binary_installed() {
  if skip_if_not_e2e "T2a herdr binary installed via manifest"; then return 0; fi

  if ! _t2_build_herdr_image; then
    fail "T2a Image build failed — see [T2 setup] FAIL output above"
    return
  fi

  local herdr_path
  herdr_path=$(docker run --rm rip-cage:latest which herdr 2>&1)
  if echo "$herdr_path" | grep -q "/herdr"; then
    pass "T2a herdr binary present in cage image at: ${herdr_path}"
  else
    fail "T2a herdr binary NOT found in cage image. 'which herdr' output: '${herdr_path}'"
  fi

  # Version check
  local version_out version_rc
  version_rc=0
  version_out=$(docker run --rm rip-cage:latest herdr --version 2>&1) || version_rc=$?
  if [[ "$version_rc" -eq 0 ]]; then
    pass "T2a herdr --version exits 0 in cage: '${version_out:0:60}'"
  else
    fail "T2a herdr --version failed: exit=${version_rc} out='${version_out:0:100}'"
  fi
}

# ---------------------------------------------------------------------------
# T2b — herdr binary is root-owned and NOT agent-writable (ADR-005 D9).
# ---------------------------------------------------------------------------
test_t2b_herdr_binary_root_owned() {
  if skip_if_not_e2e "T2b herdr binary root-owned (ADR-005 D9)"; then return 0; fi

  if ! _t2_build_herdr_image; then
    fail "T2b Image build failed — see [T2 setup] FAIL output above"
    return
  fi

  local stat_out stat_rc
  stat_rc=0
  stat_out=$(docker run --rm rip-cage:latest stat -c "%U %G %a" /usr/local/bin/herdr 2>&1) || stat_rc=$?

  if [[ "$stat_rc" -ne 0 ]]; then
    fail "T2b stat /usr/local/bin/herdr FAILED: exit=${stat_rc} out='${stat_out}'"
    return
  fi

  local owner mode
  owner=$(echo "$stat_out" | awk '{print $1}')
  mode=$(echo "$stat_out" | awk '{print $3}')

  if [[ "$owner" == "root" ]]; then
    pass "T2b /usr/local/bin/herdr is root-owned (owner='${owner}', mode='${mode}')"
  else
    fail "T2b /usr/local/bin/herdr is NOT root-owned: owner='${owner}' (ADR-005 D9 binary-root-owned)"
  fi

  # Check no group-write or other-write bit
  # mode is 3-digit octal like "755": group digit at position 1, other at position 2
  local group_write other_write
  group_write="${mode:1:1}"
  other_write="${mode:2:1}"
  local gw_bit ow_bit
  gw_bit=$(( (0$group_write >> 1) & 1 ))
  ow_bit=$(( (0$other_write >> 1) & 1 ))

  if [[ "$gw_bit" -eq 0 ]] && [[ "$ow_bit" -eq 0 ]]; then
    pass "T2b /usr/local/bin/herdr has no group/other write bit (mode='${mode}' — agent cannot overwrite)"
  else
    fail "T2b /usr/local/bin/herdr has group/other write bit set (mode='${mode}') — agent-writable! (ADR-005 D9 violation)"
  fi
}

# ---------------------------------------------------------------------------
# T2c — init-rip-cage.sh starts the herdr server via the baked MULTIPLEXER
# registry when RC_MULTIPLEXER=herdr. pgrep inside the container shows herdr running.
# This is the critical RC_E2E proof that herdr actually starts (not just installed).
# ---------------------------------------------------------------------------
test_t2c_herdr_server_starts_with_multiplexer() {
  if skip_if_not_e2e "T2c herdr server starts when RC_MULTIPLEXER=herdr"; then return 0; fi

  if ! _t2_build_herdr_image; then
    fail "T2c Image build failed — see [T2 setup] FAIL output above"
    return
  fi

  local container_name="rc-herdr-t2c-$$"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-herdr-e2e-XXXXXX")

  # Start container with RC_MULTIPLEXER=herdr
  docker run -d --name "$container_name" \
    -e RC_MULTIPLEXER=herdr \
    -v "${workspace}:/workspace" \
    rip-cage:latest sleep infinity >/dev/null 2>&1 || true

  # Run init to trigger the herdr server start
  docker exec "$container_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

  # Wait for herdr server to start (up to 10s)
  local herdr_running=0
  local _i
  for _i in 1 2 3 4 5; do
    sleep 2
    if docker exec "$container_name" pgrep -x herdr >/dev/null 2>&1; then
      herdr_running=1
      break
    fi
  done
  unset _i

  if [[ "$herdr_running" -eq 1 ]]; then
    local herdr_pid
    herdr_pid=$(docker exec "$container_name" pgrep -x herdr 2>/dev/null | head -1)
    pass "T2c herdr server is running in cage (PID=${herdr_pid}) after init with RC_MULTIPLEXER=herdr"
  else
    local init_log
    init_log=$(docker exec "$container_name" \
      cat /tmp/rip-cage-mux-herdr.log 2>/dev/null | head -20 || true)
    fail "T2c herdr server NOT running after init with RC_MULTIPLEXER=herdr. herdr log: '${init_log}'"
  fi

  # Also verify the socket was created (herdr server creates ~/.config/herdr/herdr.sock)
  local socket_check
  socket_check=$(docker exec "$container_name" \
    test -S /home/agent/.config/herdr/herdr.sock && echo "exists" || echo "missing" 2>/dev/null) || socket_check="missing"
  if [[ "$socket_check" == "exists" ]]; then
    pass "T2c herdr socket present at /home/agent/.config/herdr/herdr.sock"
  else
    echo "INFO: T2c herdr socket check returned '${socket_check}' (server may use different socket path)"
  fi

  docker stop "$container_name" >/dev/null 2>&1 || true
  docker rm "$container_name" >/dev/null 2>&1 || true
  rm -rf "$workspace"
}

# ---------------------------------------------------------------------------
# T2d — ADR-006 D8: init-rip-cage.sh auto-installs bundled agent integrations
# via herdr's public CLI after starting the herdr server (rip-cage-zshp).
#
# Verification: start a cage with RC_MULTIPLEXER=herdr, run init, then confirm
# 'herdr integration status' shows pi AND claude as installed — WITHOUT any
# manual 'herdr integration install' call. This proves D8's auto-install fires
# from init-rip-cage.sh for every bundled agent present on PATH.
#
# Boundary: we do NOT call 'herdr integration install' ourselves — the cage init
# must do it. If it does not, status shows "not installed" and the test FAILs.
# ---------------------------------------------------------------------------
test_t2d_herdr_integrations_auto_installed_by_init() {
  if skip_if_not_e2e "T2d herdr integrations auto-installed by init (ADR-006 D8)"; then return 0; fi

  if ! _t2_build_herdr_image; then
    fail "T2d Image build failed — see [T2 setup] FAIL output above"
    return
  fi

  local container_name="rc-herdr-t2d-$$"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-herdr-e2e-XXXXXX")

  # Start container with RC_MULTIPLEXER=herdr — NO manual integration install
  docker run -d --name "$container_name" \
    -e RC_MULTIPLEXER=herdr \
    -v "${workspace}:/workspace" \
    rip-cage:latest sleep infinity >/dev/null 2>&1 || true

  # Run init — this is the ONLY thing that should install the integrations
  docker exec "$container_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

  # Wait for herdr server to be ready (it backgrounds; give it a moment to accept connections)
  local _w
  for _w in 1 2 3 4 5; do
    sleep 1
    if docker exec "$container_name" test -S /home/agent/.config/herdr/herdr.sock 2>/dev/null; then
      break
    fi
  done
  unset _w

  # Check integration status — NO manual 'herdr integration install' was called
  local status_out
  status_out=$(docker exec -u agent "$container_name" herdr integration status 2>&1 || true)
  echo "  herdr integration status:"
  echo "$status_out" | while IFS= read -r line; do echo "    $line"; done

  # pi is a composable TOOL recipe (rip-cage-fwp3) — the pi binary, and hence
  # herdr's auto-install of the pi integration, is only present when a manifest
  # actually composes pi. T2_FIXTURE_FILE (herdr TOOL+MULTIPLEXER only) does not
  # compose pi, so assert pi-integration presence ONLY when pi is on PATH in
  # this container; otherwise this assertion does not apply (INFO, not FAIL).
  if docker exec "$container_name" bash -c 'command -v pi >/dev/null 2>&1'; then
    if echo "$status_out" | grep -qE '^pi: *(current|outdated|installed)'; then
      pass "T2d (ADR-006 D8) pi integration auto-installed by init (no manual install)"
    else
      fail "T2d (ADR-006 D8) pi integration NOT auto-installed — init-rip-cage.sh missing 'herdr integration install pi'"
    fi
  else
    echo "INFO: T2d pi not installed in this container (pi is a composable TOOL recipe, rip-cage-fwp3, not composed by ${T2_FIXTURE_FILE}) — pi-integration assertion does not apply"
  fi

  # claude must show as installed (not "not installed")
  if echo "$status_out" | grep -qE '^claude: *(current|outdated|installed)'; then
    pass "T2d (ADR-006 D8) claude integration auto-installed by init (no manual install)"
  else
    fail "T2d (ADR-006 D8) claude integration NOT auto-installed — init-rip-cage.sh missing 'herdr integration install claude'"
  fi

  docker stop "$container_name" >/dev/null 2>&1 || true
  docker rm "$container_name" >/dev/null 2>&1 || true
  rm -rf "$workspace"
}

test_t2a_herdr_binary_installed
test_t2b_herdr_binary_root_owned
test_t2c_herdr_server_starts_with_multiplexer
test_t2d_herdr_integrations_auto_installed_by_init

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
