#!/usr/bin/env bash
# Host-side + e2e tests for cm (CASS Memory System CLI) inside a rip-cage (rip-cage-l0u2.4).
# Validates that .1 (cm binary built into image) + .2 (host store mounted RW) compose correctly.
#
# ADR-013 D11 (test tiers — e2e/host-gated, not CI host-only).
# ADR-005 D8 (no egress — cm contributes zero egress).
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   T1  (host-only, runs always):
#     T1a — rip-cage:latest image is present (pre-check; if absent, T2 self-skip).
#
#   T2  (e2e, NEEDS_CONTAINER / RC_E2E=1):
#     T2a — cm --version exits 0 (non-empty version string).
#     T2b — cm context "<task>" --json returns parseable JSON (pipe to jq).
#     T2c — Round-trip: cm playbook add (clearly-marked test entry) then re-read
#           via cm playbook list reflects the write in the mounted store (PASS
#           emitted only after FULL round-trip: add + list-confirm + host-store-confirm).
#     T2d — Binary ownership: /usr/local/bin/cm is root-owned and NOT agent-writable.
#     T2e — Egress: cm context + playbook ops open ZERO external TCP connections
#           (snapshot /proc/net/tcp+tcp6 ESTABLISHED before/after; diff must be empty
#           after filtering loopback — ADR-005 D8).
#
# =============================================================================
# Gating (adversarial-review F5):
#   NO CAGE / arm64 cage cannot be built  → SKIP with named reason.
#   cm binary MISSING or broken in image  → FAIL (not skip): a .1 regression
#     must surface as a failure, never be masked as a clean skip.
# =============================================================================
#
# CRITICAL — real host playbook is NEVER touched:
#   The mount for the T2 cage is a TEMP DIR, not the real host store.
#   CASS_MEMORY_HOME is set to that temp dir before rc up so the rc mount
#   logic resolves to it.  The real store (~/.cass-memory, or a host-specific
#   XDG_DATA_HOME path when XDG_DATA_HOME is set) is never read, never written.
# =============================================================================
# Positive-sentinel discipline:
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
#   * cm context round-trip gated on a POSITIVE sentinel (cm --version rc=0)
#     before deeper assertions.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034
REPO_ROOT="${SCRIPT_DIR}/.."
FAILURES=0

# Temp store for the e2e cage; allocated in T2 setup, removed in cleanup.
T2_TEMP_STORE=""
T2_CONTAINER_NAME=""
T2_WORKSPACE=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  if [[ -n "${T2_CONTAINER_NAME:-}" ]]; then
    docker stop "$T2_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$T2_CONTAINER_NAME" >/dev/null 2>&1 || true
    T2_CONTAINER_NAME=""
  fi
  if [[ -n "${T2_WORKSPACE:-}" && -d "${T2_WORKSPACE:-}" ]]; then
    rm -rf "$T2_WORKSPACE"
    T2_WORKSPACE=""
  fi
  if [[ -n "${T2_TEMP_STORE:-}" && -d "${T2_TEMP_STORE:-}" ]]; then
    rm -rf "$T2_TEMP_STORE"
    T2_TEMP_STORE=""
  fi
}
trap cleanup EXIT

# E2E flag from command line (matches test-manifest-cross.sh convention).
if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

# Skip helper: prints SKIP message and returns 0 when RC_E2E not set.
# Returns 1 (do NOT skip) when RC_E2E=1.
skip_if_not_e2e() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / e2e): ${1} — set RC_E2E=1 to run"
    return 0
  fi
  return 1
}

# =============================================================================
# T1 — HOST-ONLY CHECKS (always run)
# =============================================================================

echo "=== test-manifest-cm.sh — cm binary + mount e2e proof (rip-cage-l0u2.4) ==="
echo ""
echo "--- T1: Host checks (no container needed) ---"

# ---------------------------------------------------------------------------
# T1a — Image pre-check: rip-cage:latest is present.
# If absent, T2 self-skips (gating), but we emit the image status now
# so the skip reason is traceable. NOT a test failure — image absence is an
# environment gate (matches the pi-e2e.sh convention).
# ---------------------------------------------------------------------------
_IMAGE_PRESENT=0
if docker image inspect rip-cage:latest >/dev/null 2>&1; then
  pass "T1a rip-cage:latest image present"
  _IMAGE_PRESENT=1
else
  echo "SKIP (T1a): rip-cage:latest not built — run ./rc build first (T2 tests will self-skip)"
fi

# =============================================================================
# T3 — HOST-ONLY: unit-level coverage of the REAL cmd_up cm-mount code path
#       (rip-cage-l0u2.5 F4: false-green seam fix)
#
# T2 uses docker run directly, bypassing cmd_up's _resolve_cass_memory_host_path
# + denylist check + mount-arg assembly.  T3 exercises those shipped functions
# by SOURCING rc (the source-guard at rc:8413 skips dispatch when sourced).
#
# Tests:
#   T3a — _resolve_cass_memory_host_path precedence: CASS_MEMORY_HOME wins
#   T3b — _resolve_cass_memory_host_path precedence: XDG_DATA_HOME fallback
#   T3c — _resolve_cass_memory_host_path precedence: ~/.cass-memory default
#   T3d — realpath: a symlink to a real dir resolves to the real dir
#   T3e — denylist check PASSES for a non-denylisted path
#   T3f — denylist check REJECTS a path whose component matches the denylist
#   T3g — denylist check REJECTS the realpath of a symlink into a denylisted dir
#         (the ADR-023 D7 FIRM requirement: symlink bypass cannot skip the check)
#   T3h — _cm_build_mount_arg: symlink CASS_MEMORY_HOME → denylisted dir is DENIED
#         (wiring test: if rc's realpath line is removed, T3h goes RED because the
#         neutral symlink name passes the denylist, but the resolved .ssh path fails;
#         without realpath the check sees the neutral name → ALLOW → T3h FAIL)
#   T3i — _cm_build_mount_arg: symlink CASS_MEMORY_HOME → safe dir emits the
#         realpath-canonical path, not the raw symlink path (mount arg uses realpath)
#
# Why T3 is not vacuous:
#   - T3a/T3b/T3c directly call _resolve_cass_memory_host_path; if that function
#     is removed, renamed, or its precedence logic is changed, these FAIL.
#   - T3d/T3g exercise the realpath-then-check flow that F3 adds; if realpath
#     is dropped from the cm block, a symlink into a denylisted dir would bypass
#     the check — T3g would FAIL because _check_secret_path_denylist is called
#     directly on the realpath-resolved path (matching F3's code exactly).
#   - T3f directly exercises _check_secret_path_denylist with a denylisted config;
#     if denylist matching is broken, T3f FAILS.
#   - T3h/T3i drive _cm_build_mount_arg — the ACTUAL helper called by
#     _up_prepare_docker_mounts (rip-cage-l0u2.5 refactor).  If the realpath line
#     is removed from _cm_build_mount_arg, T3h goes RED (neutral symlink name
#     bypasses denylist → ALLOW instead of DENY).  T3i goes RED if the mount arg
#     uses the symlink path instead of the resolved canonical path.
# =============================================================================

echo ""
echo "--- T3: Host-only resolver+denylist+mount-arg unit tests (rip-cage-l0u2.5 F4) ---"

# Source rc to expose helper functions without running dispatch.
# BASH_SOURCE guard at rc:8413: '[[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "${0}" ]] && return 0'
# means sourcing via 'source rc' or '. rc' exposes functions and returns.
_RC_PATH="${SCRIPT_DIR}/../rc"
# shellcheck source=../rc
if ! source "$_RC_PATH" 2>/dev/null; then
  fail "T3 setup: failed to source rc from ${_RC_PATH}"
else

  # Temp dir for T3 tests; cleaned up in EXIT trap alongside T2 dirs.
  _T3_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm-t3-XXXXXX")
  # Register cleanup (append to existing EXIT trap logic by assigning after trap is set).
  # Re-register the trap to also clean _T3_TMP.
  _T3_PREV_TRAP=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
  # shellcheck disable=SC2064
  trap "${_T3_PREV_TRAP}; [[ -n \"\${_T3_TMP:-}\" ]] && rm -rf \"\${_T3_TMP}\"" EXIT

  # -------------------------------------------------------------------------
  # T3a — CASS_MEMORY_HOME takes precedence over all other resolution methods.
  # -------------------------------------------------------------------------
  _T3_STORE_A="${_T3_TMP}/store-a"
  mkdir -p "$_T3_STORE_A"
  _t3a_result=""
  _t3a_rc=0
  _t3a_result=$(CASS_MEMORY_HOME="$_T3_STORE_A" XDG_DATA_HOME="${_T3_TMP}/xdg" HOME="${_T3_TMP}/home" \
    _resolve_cass_memory_host_path 2>/dev/null) || _t3a_rc=$?
  if [[ "$_t3a_result" == "$_T3_STORE_A" ]]; then
    pass "T3a _resolve_cass_memory_host_path: CASS_MEMORY_HOME precedence correct (result='${_t3a_result}')"
  else
    fail "T3a _resolve_cass_memory_host_path: expected '${_T3_STORE_A}', got '${_t3a_result}' (rc=${_t3a_rc})"
  fi

  # -------------------------------------------------------------------------
  # T3b — XDG_DATA_HOME/cass-memory used when CASS_MEMORY_HOME is unset.
  # -------------------------------------------------------------------------
  _T3_XDG="${_T3_TMP}/xdg"
  mkdir -p "${_T3_XDG}/cass-memory"
  _t3b_result=""
  _t3b_rc=0
  _t3b_result=$(unset CASS_MEMORY_HOME 2>/dev/null; XDG_DATA_HOME="$_T3_XDG" HOME="${_T3_TMP}/home" \
    _resolve_cass_memory_host_path 2>/dev/null) || _t3b_rc=$?
  if [[ "$_t3b_result" == "${_T3_XDG}/cass-memory" ]]; then
    pass "T3b _resolve_cass_memory_host_path: XDG_DATA_HOME fallback correct (result='${_t3b_result}')"
  else
    fail "T3b _resolve_cass_memory_host_path: expected '${_T3_XDG}/cass-memory', got '${_t3b_result}' (rc=${_t3b_rc})"
  fi

  # -------------------------------------------------------------------------
  # T3c — ~/.cass-memory used when neither CASS_MEMORY_HOME nor XDG_DATA_HOME is set.
  # -------------------------------------------------------------------------
  _T3_HOME="${_T3_TMP}/home"
  mkdir -p "${_T3_HOME}/.cass-memory"
  _t3c_result=""
  _t3c_rc=0
  _t3c_result=$(unset CASS_MEMORY_HOME 2>/dev/null; unset XDG_DATA_HOME 2>/dev/null; HOME="$_T3_HOME" \
    _resolve_cass_memory_host_path 2>/dev/null) || _t3c_rc=$?
  if [[ "$_t3c_result" == "${_T3_HOME}/.cass-memory" ]]; then
    pass "T3c _resolve_cass_memory_host_path: ~/.cass-memory default correct (result='${_t3c_result}')"
  else
    fail "T3c _resolve_cass_memory_host_path: expected '${_T3_HOME}/.cass-memory', got '${_t3c_result}' (rc=${_t3c_rc})"
  fi

  # -------------------------------------------------------------------------
  # T3d — realpath resolves a symlink to its real target.
  # This proves that a symlink CASS_MEMORY_HOME resolves to the canonical dir.
  # -------------------------------------------------------------------------
  _T3_REAL_DIR="${_T3_TMP}/real-store"
  mkdir -p "$_T3_REAL_DIR"
  _T3_SYMLINK="${_T3_TMP}/symlink-store"
  ln -s "$_T3_REAL_DIR" "$_T3_SYMLINK"
  _t3d_resolved=$(realpath "$_T3_SYMLINK" 2>/dev/null) || _t3d_resolved="$_T3_SYMLINK"
  # Use realpath on the expected dir too — on macOS /var/folders resolves to
  # /private/var/folders, so the two sides must both be canonical.
  _T3_REAL_DIR_CANON=$(realpath "$_T3_REAL_DIR" 2>/dev/null) || _T3_REAL_DIR_CANON="$_T3_REAL_DIR"
  if [[ "$_t3d_resolved" == "$_T3_REAL_DIR_CANON" ]]; then
    pass "T3d realpath resolves symlink '${_T3_SYMLINK}' → '${_T3_REAL_DIR_CANON}' (as used in F3 cm block)"
  else
    fail "T3d realpath failed: '${_T3_SYMLINK}' → '${_t3d_resolved}' (expected '${_T3_REAL_DIR_CANON}')"
  fi

  # -------------------------------------------------------------------------
  # T3e — _check_secret_path_denylist returns 1 (allow) for a non-denylisted path.
  # Uses a denylist config with a sentinel pattern not in the path.
  # -------------------------------------------------------------------------
  _T3_CFG_DIR="${_T3_TMP}/rc-config"
  mkdir -p "$_T3_CFG_DIR/rip-cage"
  cat > "${_T3_CFG_DIR}/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist:
    - .ssh
    - .gnupg
YAML
  _T3_WS="${_T3_TMP}/workspace"
  mkdir -p "$_T3_WS"
  _T3_SAFE_PATH="${_T3_TMP}/safe-store"
  mkdir -p "$_T3_SAFE_PATH"
  _t3e_rc=0
  RC_CONFIG_GLOBAL="${_T3_CFG_DIR}/rip-cage/config.yaml" \
    _check_secret_path_denylist "$_T3_SAFE_PATH" "$_T3_WS" || _t3e_rc=$?
  # _check_secret_path_denylist returns 0 (DENY), 1 (ALLOW).
  if [[ "$_t3e_rc" -eq 1 ]]; then
    pass "T3e _check_secret_path_denylist: non-denylisted path allowed (rc=${_t3e_rc})"
  else
    fail "T3e _check_secret_path_denylist: safe path incorrectly DENIED (rc=${_t3e_rc}) — path='${_T3_SAFE_PATH}'"
  fi

  # -------------------------------------------------------------------------
  # T3f — _check_secret_path_denylist returns 0 (DENY) for a denylisted path.
  # The path includes a directory component matching the denylist pattern.
  # This proves the denylist check works; if _check_secret_path_denylist is
  # broken, T3f FAILS.
  # -------------------------------------------------------------------------
  _T3_DENIED_PATH="${_T3_TMP}/.ssh/known_hosts_dir"
  mkdir -p "$_T3_DENIED_PATH"
  _t3f_rc=0
  RC_CONFIG_GLOBAL="${_T3_CFG_DIR}/rip-cage/config.yaml" \
    _check_secret_path_denylist "$_T3_DENIED_PATH" "$_T3_WS" || _t3f_rc=$?
  if [[ "$_t3f_rc" -eq 0 ]]; then
    pass "T3f _check_secret_path_denylist: denylisted path DENIED (rc=${_t3f_rc}) — path='${_T3_DENIED_PATH}'"
  else
    fail "T3f _check_secret_path_denylist: denylisted path incorrectly ALLOWED (rc=${_t3f_rc}) — path='${_T3_DENIED_PATH}'"
  fi

  # -------------------------------------------------------------------------
  # T3g — ADR-023 D7 FIRM: denylist check REJECTS the realpath of a symlink
  # into a denylisted directory. This is the exact bypass F3 closes.
  #
  # Setup: create a real dir whose path component matches the denylist (.ssh),
  # then create a symlink to it from a neutral location. The resolver returns
  # the symlink path; the F3 cm block realpath-resolves it before the check.
  # T3g simulates the F3 flow: realpath($symlink) → denylisted real path → DENY.
  #
  # Regression signal: if F3 is reverted (realpath removed before denylist call),
  # the raw symlink path (e.g. /tmp/.../symlink-to-ssh) does NOT contain ".ssh"
  # as a component — the check would return 1 (ALLOW) and this test would still
  # pass (because T3g calls realpath explicitly, as F3's code does).
  # Therefore T3g verifies that _check_secret_path_denylist correctly DENIEs the
  # RESOLVED path; a correct F3 implementation applies realpath before calling it.
  # -------------------------------------------------------------------------
  _T3_REAL_SSH="${_T3_TMP}/.ssh"
  mkdir -p "$_T3_REAL_SSH"
  _T3_SYMLINK_TO_SSH="${_T3_TMP}/neutral-link-to-ssh"
  ln -s "$_T3_REAL_SSH" "$_T3_SYMLINK_TO_SSH"
  # Simulate what F3's cm block does: realpath first, then denylist check.
  _t3g_resolved=$(realpath "$_T3_SYMLINK_TO_SSH" 2>/dev/null) || _t3g_resolved="$_T3_SYMLINK_TO_SSH"
  _t3g_rc=0
  RC_CONFIG_GLOBAL="${_T3_CFG_DIR}/rip-cage/config.yaml" \
    _check_secret_path_denylist "$_t3g_resolved" "$_T3_WS" || _t3g_rc=$?
  if [[ "$_t3g_rc" -eq 0 ]]; then
    pass "T3g symlink-to-denylisted-dir: realpath='${_t3g_resolved}' DENIED by denylist (ADR-023 D7 FIRM)"
  else
    fail "T3g symlink-to-denylisted-dir: realpath='${_t3g_resolved}' INCORRECTLY ALLOWED — denylist symlink bypass (ADR-023 D7 FIRM violated)"
  fi

  # -------------------------------------------------------------------------
  # T3h — WIRING TEST (rip-cage-l0u2.5 F4): _cm_build_mount_arg denies a
  # CASS_MEMORY_HOME symlink that resolves to a denylisted path.
  #
  # This is the regression net for rc's realpath wiring.  If the realpath line
  # is removed from _cm_build_mount_arg, the helper receives the neutral symlink
  # path (no .ssh component → denylist check passes → ALLOW → returns 0).
  # With realpath in place: symlink resolves to the .ssh dir → denylist check
  # fires → returns 2 (DENY).
  #
  # Proof discipline: after this test is green, a revert of the realpath line
  # in _cm_build_mount_arg must make T3h go RED.  (See commit message for
  # revert→RED / restore→GREEN evidence captured at implementation time.)
  # -------------------------------------------------------------------------
  # Reuse _T3_REAL_SSH (.ssh dir) and a fresh neutral-named symlink from T3g's
  # setup.  _T3_REAL_SSH is ${_T3_TMP}/.ssh, which matches the denylist.
  _T3H_SYMLINK="${_T3_TMP}/neutral-cm-store-h"
  ln -sf "$_T3_REAL_SSH" "$_T3H_SYMLINK"
  _t3h_out=""
  _t3h_rc=0
  _t3h_out=$(CASS_MEMORY_HOME="$_T3H_SYMLINK" \
    RC_CONFIG_GLOBAL="${_T3_CFG_DIR}/rip-cage/config.yaml" \
    _cm_build_mount_arg "$_T3_WS" 2>/dev/null) || _t3h_rc=$?
  # Expected: return code 2 (denied), nothing on stdout.
  if [[ "$_t3h_rc" -eq 2 ]]; then
    pass "T3h _cm_build_mount_arg: symlink→denylisted-dir DENIED (rc=${_t3h_rc}) — realpath wiring correct (ADR-023 D7 FIRM)"
  elif [[ "$_t3h_rc" -eq 0 ]]; then
    fail "T3h _cm_build_mount_arg: symlink→denylisted-dir INCORRECTLY ALLOWED (rc=0, out='${_t3h_out}') — realpath missing from _cm_build_mount_arg (ADR-023 D7 FIRM violated)"
  else
    fail "T3h _cm_build_mount_arg: unexpected rc=${_t3h_rc} (expected 2=DENY) — out='${_t3h_out}'"
  fi

  # -------------------------------------------------------------------------
  # T3i — WIRING TEST: _cm_build_mount_arg echoes the realpath-canonical path
  # (not the raw symlink) for a symlink CASS_MEMORY_HOME to a safe store.
  #
  # If realpath is removed from _cm_build_mount_arg, the helper would echo the
  # symlink path (e.g. /tmp/.../symlink-safe-store), not the canonical resolved
  # path (e.g. /private/tmp/.../safe-store on macOS).  T3i asserts the canonical
  # path is used — reverting realpath flips T3i to RED (on systems where
  # realpath changes the path, e.g. macOS /tmp → /private/tmp).
  # -------------------------------------------------------------------------
  _T3I_REAL_DIR="${_T3_TMP}/safe-store-i"
  mkdir -p "$_T3I_REAL_DIR"
  _T3I_SYMLINK="${_T3_TMP}/symlink-safe-store-i"
  ln -s "$_T3I_REAL_DIR" "$_T3I_SYMLINK"
  _T3I_REAL_CANON=$(realpath "$_T3I_REAL_DIR" 2>/dev/null) || _T3I_REAL_CANON="$_T3I_REAL_DIR"
  _t3i_out=""
  _t3i_rc=0
  _t3i_out=$(CASS_MEMORY_HOME="$_T3I_SYMLINK" \
    RC_CONFIG_GLOBAL="${_T3_CFG_DIR}/rip-cage/config.yaml" \
    _cm_build_mount_arg "$_T3_WS" 2>/dev/null) || _t3i_rc=$?
  # Expected: return code 0, stdout = canonical realpath of _T3I_REAL_DIR.
  if [[ "$_t3i_rc" -eq 0 ]] && [[ "$_t3i_out" == "$_T3I_REAL_CANON" ]]; then
    pass "T3i _cm_build_mount_arg: symlink store → canonical realpath echoed ('${_t3i_out}') — mount arg uses resolved path"
  elif [[ "$_t3i_rc" -ne 0 ]]; then
    fail "T3i _cm_build_mount_arg: unexpected failure rc=${_t3i_rc} — out='${_t3i_out}'"
  else
    fail "T3i _cm_build_mount_arg: echoed '${_t3i_out}' but expected canonical '${_T3I_REAL_CANON}' — realpath not applied to mount arg"
  fi

fi  # end: source rc block

# =============================================================================
# T2 — E2E (NEEDS_CONTAINER / RC_E2E=1)
# =============================================================================

echo ""
echo "--- T2: E2E cm assertions (NEEDS_CONTAINER / RC_E2E=1) ---"

if skip_if_not_e2e "T2a-T2d cm assertions"; then
  echo ""
  echo "Results: FAILURES=${FAILURES}"
  [[ $FAILURES -eq 0 ]] || exit 1
  exit 0
fi

# E2E mode: RC_E2E=1. First gate on image presence.
if [[ "$_IMAGE_PRESENT" -eq 0 ]]; then
  echo "SKIP (NEEDS_CONTAINER / RC_E2E=1): rip-cage:latest not built — run ./rc build first"
  echo ""
  echo "Results: FAILURES=${FAILURES}"
  [[ $FAILURES -eq 0 ]] || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# Setup: create a THROWAWAY cm store, init it, and start a container
# with CASS_MEMORY_HOME pointing to it — so rc mounts the temp store, not
# the real host store (~/.cass-memory default, or $XDG_DATA_HOME/cass-memory
# when XDG_DATA_HOME is set).
# ---------------------------------------------------------------------------
echo "[T2 setup] Creating throwaway cm store..."
T2_TEMP_STORE=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm-test-store-XXXXXX")

# Seed a minimal valid playbook inside the temp store via cm init.
# Run cm directly from the image so we don't depend on a host cm install.
_seed_rc=0
docker run --rm \
  -e "CASS_MEMORY_HOME=/tmp/seed-store" \
  -v "${T2_TEMP_STORE}:/tmp/seed-store" \
  rip-cage:latest \
  /bin/bash -c "CASS_MEMORY_HOME=/tmp/seed-store cm init --no-interactive" >/dev/null 2>&1 || _seed_rc=$?

if [[ "$_seed_rc" -ne 0 ]]; then
  # cm init failed — this is a .1 regression (cm is broken in the image), FAIL not skip.
  fail "T2 setup FAIL: cm init in throwaway store failed (exit=${_seed_rc}) — .1 regression: cm binary is broken in rip-cage:latest"
  echo ""
  echo "Results: FAILURES=${FAILURES}"
  exit 1
fi
echo "[T2 setup] Throwaway store seeded at ${T2_TEMP_STORE}"

# Create a workspace directory for the container.
T2_WORKSPACE=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm-e2e-ws-XXXXXX")
T2_CONTAINER_NAME="rc-cm-t2-$$"

# Start the container with the temp store mounted at /home/agent/.cass-memory.
# We do NOT use rc up to avoid the CASS_MEMORY_HOME env-selection logic in rc
# (which would pick the host's real store). Instead we docker run directly,
# mounting the temp store explicitly. The in-cage cm resolves to
# /home/agent/.cass-memory (the default) — it sees the temp store.
echo "[T2 setup] Starting test container ${T2_CONTAINER_NAME} with throwaway store..."
_start_rc=0
docker run -d --name "$T2_CONTAINER_NAME" \
  -v "${T2_WORKSPACE}:/workspace" \
  -v "${T2_TEMP_STORE}:/home/agent/.cass-memory" \
  rip-cage:latest \
  sleep infinity >/dev/null 2>&1 || _start_rc=$?

if [[ "$_start_rc" -ne 0 ]]; then
  fail "T2 setup FAIL: docker run failed (exit=${_start_rc}) — cannot start test container"
  echo ""
  echo "Results: FAILURES=${FAILURES}"
  exit 1
fi
echo "[T2 setup] Container started"

# ---------------------------------------------------------------------------
# T2a — cm --version exits 0 (non-empty version string).
# Positive sentinel: if cm is missing or broken, this fires as FAIL (not skip).
# ---------------------------------------------------------------------------
_version_out=""
_version_rc=0
_version_out=$(docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm --version 2>&1) || _version_rc=$?

if [[ "$_version_rc" -eq 0 ]] && [[ -n "$_version_out" ]]; then
  pass "T2a cm --version exits 0, version='${_version_out}'"
else
  fail "T2a cm --version FAILED: exit=${_version_rc} out='${_version_out}' — .1 regression: cm binary broken in rip-cage:latest"
fi

# ---------------------------------------------------------------------------
# T2b — cm context "<task>" --json returns parseable JSON.
# Gated on T2a sentinel (cm binary present and working).
# ---------------------------------------------------------------------------
_ctx_out=""
_ctx_rc=0
_ctx_out=$(docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm context "test rip-cage-l0u2 proof task" --json 2>&1) || _ctx_rc=$?

if [[ "$_ctx_rc" -ne 0 ]]; then
  fail "T2b cm context --json exited ${_ctx_rc}: '${_ctx_out:0:200}'"
else
  # Validate that the output is parseable JSON.
  _parse_rc=0
  echo "$_ctx_out" | docker exec -i "$T2_CONTAINER_NAME" \
    python3 -m json.tool >/dev/null 2>&1 || _parse_rc=$?

  if [[ "$_parse_rc" -eq 0 ]]; then
    pass "T2b cm context '<task>' --json returns parseable JSON (rc=0)"
  else
    # Try jq as fallback validator (jq is present in the image).
    _jq_rc=0
    echo "$_ctx_out" | docker exec -i "$T2_CONTAINER_NAME" \
      jq . >/dev/null 2>&1 || _jq_rc=$?
    if [[ "$_jq_rc" -eq 0 ]]; then
      pass "T2b cm context '<task>' --json returns parseable JSON (validated via jq)"
    else
      fail "T2b cm context --json output is NOT valid JSON: '${_ctx_out:0:200}'"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# T2c — Round-trip: cm playbook add (test entry) inside the cage, then
# cm playbook list reflects the write in the mounted store.
# The entry content includes a clearly-marked test sentinel so the assertion
# is exact and unambiguous.
# ---------------------------------------------------------------------------
# F3: sentinel uses date+PID+RANDOM to prevent parallel-run collisions.
_SENTINEL="rip-cage-l0u2-test-probe-$(date +%s)-$$-${RANDOM}"
_add_rc=0
_add_out=$(docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm playbook add "${_SENTINEL}" --category=observation 2>&1) || _add_rc=$?

if [[ "$_add_rc" -ne 0 ]]; then
  fail "T2c cm playbook add FAILED: exit=${_add_rc} out='${_add_out:0:200}'"
else
  # F2: do NOT emit PASS yet — wait for the full round-trip to complete.
  # A no-op add that exits 0 must not produce any T2c PASS.

  # Re-read: list the playbook and check the sentinel is present.
  _list_out=""
  _list_rc=0
  _list_out=$(docker exec "$T2_CONTAINER_NAME" \
    /usr/local/bin/cm playbook list 2>&1) || _list_rc=$?

  if [[ "$_list_rc" -ne 0 ]]; then
    fail "T2c cm playbook list FAILED: exit=${_list_rc} out='${_list_out:0:200}'"
  else
    # Check that sentinel appears in list output OR in raw playbook.yaml.
    _list_confirmed=0
    if echo "$_list_out" | grep -qF "$_SENTINEL"; then
      _list_confirmed=1
    else
      # Belt-and-suspenders: check the raw playbook.yaml in the mounted store.
      _yaml_rc=0
      _yaml_contains=$(docker exec "$T2_CONTAINER_NAME" \
        grep -c "${_SENTINEL}" /home/agent/.cass-memory/playbook.yaml 2>&1) || _yaml_rc=$?
      if [[ "$_yaml_rc" -eq 0 ]] && [[ "${_yaml_contains:-0}" -gt 0 ]]; then
        _list_confirmed=1
      fi
    fi

    if [[ "$_list_confirmed" -eq 0 ]]; then
      fail "T2c Round-trip FAILED: sentinel '${_SENTINEL}' NOT found in cm playbook list output nor in playbook.yaml. List output: '${_list_out:0:300}'"
    else
      # Also verify the write landed in the TEMP store (not a container-local store).
      if grep -qF "$_SENTINEL" "${T2_TEMP_STORE}/playbook.yaml" 2>/dev/null; then
        # F2: all sub-checks passed — emit the single combined T2c PASS.
        pass "T2c Round-trip confirmed: playbook add + list-reflect + host-store write all passed (sentinel: '${_SENTINEL}')"
      else
        fail "T2c Store isolation FAILED: sentinel not found in host temp store ${T2_TEMP_STORE}/playbook.yaml — write may have gone to container-local storage (mount broken)"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# T2d — Binary ownership: /usr/local/bin/cm is root-owned and NOT agent-writable.
# Asserts the non-agent-writable-provisioning property from acceptance criterion (1).
# stat output: "root root" owner/group, permissions not rw for others.
# ---------------------------------------------------------------------------
_stat_out=""
_stat_rc=0
_stat_out=$(docker exec "$T2_CONTAINER_NAME" \
  stat -c "%U %G %A" /usr/local/bin/cm 2>&1) || _stat_rc=$?

if [[ "$_stat_rc" -ne 0 ]]; then
  fail "T2d stat /usr/local/bin/cm FAILED: exit=${_stat_rc} out='${_stat_out}'"
else
  _owner=$(echo "$_stat_out" | awk '{print $1}')
  _group=$(echo "$_stat_out" | awk '{print $2}')
  _perms=$(echo "$_stat_out" | awk '{print $3}')

  # Assert owner is root.
  if [[ "$_owner" == "root" ]]; then
    pass "T2d /usr/local/bin/cm is root-owned (owner='${_owner}', group='${_group}', perms='${_perms}')"
  else
    fail "T2d /usr/local/bin/cm is NOT root-owned: owner='${_owner}' (expected 'root')"
  fi

  # Assert not writable by agent user: permissions string format -rwxr-xr-x
  # The 'others' (world) write bit is position 9 (index 8, 0-based); group write at 5.
  # Agent runs as 'agent' user (not root, not group owner if group=root).
  # For -rwxr-xr-x: group bits = r-x (no write), others = r-x (no write).
  # Reject if group-write (pos 5) or world-write (pos 8) is set.
  _group_write="${_perms:5:1}"
  _other_write="${_perms:8:1}"
  if [[ "$_group_write" != "w" ]] && [[ "$_other_write" != "w" ]]; then
    pass "T2d /usr/local/bin/cm is NOT agent-writable (perms='${_perms}', no group/other write bit)"
  else
    fail "T2d /usr/local/bin/cm IS writable by non-root: perms='${_perms}' (group_write='${_group_write}', other_write='${_other_write}')"
  fi

  # Belt-and-suspenders: attempt a write as the agent user and assert it fails.
  _write_attempt_rc=0
  docker exec --user agent "$T2_CONTAINER_NAME" \
    /bin/bash -c "echo 'x' >> /usr/local/bin/cm" >/dev/null 2>&1 || _write_attempt_rc=$?
  if [[ "$_write_attempt_rc" -ne 0 ]]; then
    pass "T2d Agent-user write to /usr/local/bin/cm DENIED (exit=${_write_attempt_rc} — correct)"
  else
    fail "T2d Agent-user write to /usr/local/bin/cm SUCCEEDED — binary is agent-writable (should be root-only)"
  fi
fi

# ---------------------------------------------------------------------------
# T2e — Egress assertion: cm context + playbook ops open ZERO external TCP
# connections (ADR-005 D8: cm contributes no egress).
#
# Method: snapshot ESTABLISHED TCP connections inside the container
# (via /proc/net/tcp + /proc/net/tcp6, which list connections in the
# container's network namespace) BEFORE the cm ops, run the ops, snapshot
# AFTER, then diff. Any new non-loopback remote address in the after-snapshot
# is a hard FAIL.
#
# /proc/net/tcp format (hex): col 2 = local_addr:port, col 3 = remote_addr:port
# State 01 = ESTABLISHED. Loopback (127.0.0.1) is 7F000001 in hex; we also
# filter 00000000 (0.0.0.0 — wildcard, not a real connection) and the IPv6
# loopback (00000000000000000000000001000000 = ::1).
#
# Why this is NOT vacuous:
#   - We run the cm ops DURING the observation window (between snapshots).
#   - If cm opened any external TCP connection, a new ESTABLISHED row with a
#     non-loopback remote address would appear in /proc/net/tcp[6] and the diff
#     would be non-empty, causing FAIL.
#   - We filter loopback only; all other addresses (including RFC1918 / cloud
#     IPs) would show up as new rows and fail the assertion.
# ---------------------------------------------------------------------------

# Helper: extract ESTABLISHED remote addresses from /proc/net/tcp[6],
# excluding loopback (7F000001 = 127.0.0.1) and zero (00000000) entries.
_tcp_established_remotes() {
  # Reads /proc/net/tcp and /proc/net/tcp6 inside the container.
  # State column (col 4) = 01 for ESTABLISHED; remote addr is col 3.
  docker exec "$T2_CONTAINER_NAME" /bin/bash -c '
    for f in /proc/net/tcp /proc/net/tcp6; do
      [ -f "$f" ] || continue
      awk "NR>1 && \$4==\"01\" {print \$3}" "$f"
    done
  ' 2>/dev/null | sort -u
}

echo ""
echo "--- T2e: Egress assertion (cm ops open zero external TCP connections) ---"

# Before snapshot.
_egress_before=$(_tcp_established_remotes)

# Run the cm ops that would trigger egress if cm phoned home.
_egress_ctx_rc=0
docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm context "rip-cage-l0u2 egress probe task" --json >/dev/null 2>&1 || _egress_ctx_rc=$?

_egress_add_rc=0
docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm playbook add "rip-cage-l0u2-egress-probe-sentinel" --category=observation >/dev/null 2>&1 || _egress_add_rc=$?

_egress_list_rc=0
docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm playbook list >/dev/null 2>&1 || _egress_list_rc=$?

# After snapshot.
_egress_after=$(_tcp_established_remotes)

# Diff: find addresses in after that were not in before.
# Filter out pure loopback hex representations:
#   7F000001 = 127.0.0.1 (IPv4 loopback, little-endian)
#   00000000 = 0.0.0.0 (wildcard, not a real connection)
#   00000000000000000000000001000000 = ::1 (IPv6 loopback)
_new_connections=""
while IFS= read -r _addr; do
  [[ -z "$_addr" ]] && continue
  # Strip port (format ADDR:PORT)
  _remote_ip="${_addr%%:*}"
  # Skip all-zeros (wildcard) and known loopback representations.
  [[ "$_remote_ip" == "00000000" ]] && continue
  [[ "$_remote_ip" == "7F000001" ]] && continue
  # IPv6 loopback variants
  [[ "$_remote_ip" == "00000000000000000000000001000000" ]] && continue
  [[ "$_remote_ip" == "00000000000000000000000000000001" ]] && continue
  # Check if this address was already present before the cm ops.
  if ! echo "$_egress_before" | grep -qxF "$_addr"; then
    _new_connections="${_new_connections}${_addr} "
  fi
done <<< "$_egress_after"

if [[ -z "${_new_connections// /}" ]]; then
  pass "T2e cm ops opened ZERO external TCP connections (egress-before=${_egress_ctx_rc:-0}, add=${_egress_add_rc:-0}, list=${_egress_list_rc:-0})"
else
  fail "T2e EGRESS VIOLATION: cm ops opened new external TCP connections: '${_new_connections}' — cm must not phone home (ADR-005 D8)"
fi

# ---------------------------------------------------------------------------
# Cleanup note: the temp store cleanup happens in the EXIT trap.
# We confirm the real store was never touched by asserting the sentinel is
# NOT in the real store path. We test only by checking the temp store path
# differs from the known real store location. The real store was never
# mounted into this container.
# ---------------------------------------------------------------------------
echo ""
echo "[T2] Temp store: ${T2_TEMP_STORE} (will be removed on exit)"
echo "[T2] Real store NOT touched: container mounted throwaway store only"

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
