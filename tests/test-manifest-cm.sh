#!/usr/bin/env bash
# Host-side + e2e tests for cm (CASS Memory System CLI) as a manifest worked example.
# Updated for rip-cage-buuo.5: cm is demoted from a baked default to an opt-in
# manifest entry. The default image must NOT contain cm; cm is provisioned via the
# generic from-source manifest mechanism (ADR-005 D2/D6/D11).
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
#     T1b — default rip-cage:latest image does NOT contain cm binary.
#           (ADR-005 D8 invariant: default build is cm-free)
#
#   T3  (host-only, cm manifest example static checks):
#     T3a — cm manifest example fixture exists at tests/fixtures/manifest-cm-example.yaml.
#     T3b — cm manifest build script exists at tests/fixtures/build-cm-from-source.sh.
#     T3c — cm manifest example is valid YAML (parseable by rc _manifest_validate).
#     T3d — cm manifest example contains a from-source entry for 'cm' with
#           build_source.builder_image, build_source.build_script, build_source.output_path.
#     T3e — build script does NOT hardcode a --target arch flag (arch-adaptive requirement,
#           subsuming rip-cage-ywek: bun build auto-detects target arch without --target).
#     T3f — cm manifest example has a mounts entry pointing to ~/.cass-memory.
#
#   T2  (e2e, NEEDS_CONTAINER / RC_E2E=1):
#     T2a — cm provisioned via manifest: cm --version exits 0 (non-empty version string).
#     T2b — cm context "<task>" --json returns parseable JSON (pipe to jq).
#     T2c — Round-trip: cm playbook add (clearly-marked test entry) then re-read
#           via cm playbook list reflects the write in the mounted store (PASS
#           emitted only after FULL round-trip: add + list-confirm + host-store-confirm).
#     T2d — Binary ownership: /usr/local/bin/cm is root-owned and NOT agent-writable
#           (buuo.3 assertion passes for manifest-provisioned cm).
#     T2e — Egress: cm context + playbook ops open ZERO external TCP connections
#           (snapshot /proc/net/tcp+tcp6 ESTABLISHED before/after; diff must be empty
#           after filtering loopback — ADR-005 D8).
#
# =============================================================================
# Gating:
#   NO CAGE  → self-skip with named reason.
#   T2: build must be triggered with RC_MANIFEST_GLOBAL pointing to the cm example
#       manifest so the built image contains cm (opt-in, not default).
# =============================================================================
#
# CRITICAL — real host playbook is NEVER touched:
#   T2 creates a throwaway HOME with .cass-memory inside it. HOME is set to this
#   throwaway dir when calling rc up, so ~/  expands to the throwaway, and the
#   manifest consumer mounts the throwaway store — never the real host store.
#   The mount goes through the real manifest consumer (_manifest_build_mount_args
#   + _manifest_expand_mount_host), not a direct "docker run -v" bypass.
# =============================================================================
# Positive-sentinel discipline:
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034
REPO_ROOT="${SCRIPT_DIR}/.."
FAILURES=0

# T2 state — allocated in T2 setup, removed in cleanup.
# T2_HOME: temp HOME directory containing .cass-memory (the throwaway store).
#   The cm manifest declares host: "~/.cass-memory"; rc up expands ~ to T2_HOME,
#   so the mount goes through the real manifest consumer (not a direct -v).
T2_HOME=""
T2_CONTAINER_NAME=""
T2_WORKSPACE_BASE=""  # parent of workspace (for RC_ALLOWED_ROOTS)
T2_WORKSPACE=""       # the actual workspace dir passed to rc up
T2_WS_RESOLVED=""     # realpath of T2_WORKSPACE_BASE for RC_ALLOWED_ROOTS

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  if [[ -n "${T2_CONTAINER_NAME:-}" ]]; then
    docker stop "$T2_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$T2_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker volume rm "rc-state-${T2_CONTAINER_NAME}" >/dev/null 2>&1 || true
    T2_CONTAINER_NAME=""
  fi
  if [[ -n "${T2_WORKSPACE_BASE:-}" && -d "${T2_WORKSPACE_BASE:-}" ]]; then
    rm -rf "$T2_WORKSPACE_BASE"
    T2_WORKSPACE_BASE=""
  fi
  if [[ -n "${T2_HOME:-}" && -d "${T2_HOME:-}" ]]; then
    rm -rf "$T2_HOME"
    T2_HOME=""
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

echo "=== test-manifest-cm.sh — cm as manifest worked example (rip-cage-buuo.5) ==="
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

# ---------------------------------------------------------------------------
# T1b — Default image must NOT contain cm binary (ADR-005 D8 invariant).
# A default build (no manifest) is byte-equivalent to pre-cm; cm is opt-in.
# This is a FAIL if the image exists but contains cm.
# ---------------------------------------------------------------------------
if [[ "$_IMAGE_PRESENT" -eq 1 ]]; then
  _cm_absent_rc=0
  docker run --rm rip-cage:latest bash -c 'command -v cm' >/dev/null 2>&1 || _cm_absent_rc=$?
  if [[ "$_cm_absent_rc" -ne 0 ]]; then
    pass "T1b default rip-cage:latest image has NO cm binary (opt-in via manifest, not baked — ADR-005 D8)"
  else
    fail "T1b default rip-cage:latest image CONTAINS cm binary — cm must be opt-in via manifest, not baked (ADR-005 D8 violated)"
  fi
fi

# =============================================================================
# T3 — HOST-ONLY: static checks for the cm manifest example + build script
# =============================================================================

echo ""
echo "--- T3: cm manifest example static checks (host-only) ---"

_CM_MANIFEST="${SCRIPT_DIR}/../tests/fixtures/manifest-cm-example.yaml"
_CM_BUILD_SCRIPT="${SCRIPT_DIR}/../tests/fixtures/build-cm-from-source.sh"

# ---------------------------------------------------------------------------
# T3a — cm manifest example exists.
# ---------------------------------------------------------------------------
if [[ -f "$_CM_MANIFEST" ]]; then
  pass "T3a cm manifest example exists at tests/fixtures/manifest-cm-example.yaml"
else
  fail "T3a cm manifest example MISSING: tests/fixtures/manifest-cm-example.yaml not found"
fi

# ---------------------------------------------------------------------------
# T3b — cm build script exists.
# ---------------------------------------------------------------------------
if [[ -f "$_CM_BUILD_SCRIPT" ]]; then
  pass "T3b cm build script exists at tests/fixtures/build-cm-from-source.sh"
else
  fail "T3b cm build script MISSING: tests/fixtures/build-cm-from-source.sh not found"
fi

# ---------------------------------------------------------------------------
# T3c — cm manifest example is valid YAML (parseable) and passes rc _manifest_validate.
# Source rc to expose validator function.
# ---------------------------------------------------------------------------
_RC_PATH="${SCRIPT_DIR}/../rc"
_T3_SOURCE_OK=0
# shellcheck source=../rc
if ! source "$_RC_PATH" 2>/dev/null; then
  fail "T3c setup: failed to source rc from ${_RC_PATH}"
  _T3_SOURCE_OK=0
else
  _T3_SOURCE_OK=1
fi

if [[ "$_T3_SOURCE_OK" -eq 1 ]] && [[ -f "$_CM_MANIFEST" ]]; then
  _t3c_rc=0
  _t3c_out=$(_manifest_validate "$_CM_MANIFEST" 2>&1) || _t3c_rc=$?
  if [[ "$_t3c_rc" -eq 0 ]]; then
    pass "T3c cm manifest example passes _manifest_validate (valid schema)"
  else
    fail "T3c cm manifest example FAILS _manifest_validate: ${_t3c_out}"
  fi
elif [[ "$_T3_SOURCE_OK" -eq 1 ]]; then
  fail "T3c cm manifest example missing — cannot validate (T3a already failed)"
fi

# ---------------------------------------------------------------------------
# T3d — cm manifest entry has required from-source fields.
# ---------------------------------------------------------------------------
if [[ -f "$_CM_MANIFEST" ]]; then
  _t3d_ok=1
  _t3d_entry=""
  _t3d_entry=$(yq -o=json '.tools[] | select(.name == "cm")' "$_CM_MANIFEST" 2>/dev/null) || _t3d_ok=0

  if [[ "$_t3d_ok" -eq 0 ]] || [[ -z "$_t3d_entry" ]]; then
    fail "T3d cm manifest: no 'cm' tool entry found in manifest-cm-example.yaml"
  else
    _t3d_bi=$(jq -r '.build_source.builder_image // "MISSING"' <<<"$_t3d_entry" 2>/dev/null)
    _t3d_bs=$(jq -r '.build_source.build_script // "MISSING"' <<<"$_t3d_entry" 2>/dev/null)
    _t3d_op=$(jq -r '.build_source.output_path // "MISSING"' <<<"$_t3d_entry" 2>/dev/null)

    if [[ "$_t3d_bi" != "MISSING" ]] && [[ -n "$_t3d_bi" ]] \
      && [[ "$_t3d_bs" != "MISSING" ]] && [[ -n "$_t3d_bs" ]] \
      && [[ "$_t3d_op" != "MISSING" ]] && [[ -n "$_t3d_op" ]]; then
      pass "T3d cm manifest has from-source fields (builder_image='${_t3d_bi}', build_script='${_t3d_bs}', output_path='${_t3d_op}')"
    else
      fail "T3d cm manifest missing from-source field(s): builder_image='${_t3d_bi}', build_script='${_t3d_bs}', output_path='${_t3d_op}'"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# T3e — Build script does NOT hardcode --target arch flag (arch-adaptive).
# The Dockerfile cm-builder stage hardcoded --target=bun-linux-arm64 (rip-cage-ywek).
# The manifest build script must be arch-adaptive — it detects arch at build time.
# Assert: no '--target=bun-linux-' literal in the build script.
# ---------------------------------------------------------------------------
if [[ -f "$_CM_BUILD_SCRIPT" ]]; then
  if grep -qF -- '--target=bun-linux-' "$_CM_BUILD_SCRIPT" 2>/dev/null; then
    fail "T3e cm build script contains hardcoded --target=bun-linux-<arch> flag — must be arch-adaptive (rip-cage-ywek)"
  else
    pass "T3e cm build script has no hardcoded --target arch flag — arch-adaptive (rip-cage-ywek subsumed)"
  fi
fi

# ---------------------------------------------------------------------------
# T3f — cm manifest has a mounts entry for ~/.cass-memory → /home/agent/.cass-memory.
# This provides the RW store mount via the generic mechanism (buuo.1).
# ---------------------------------------------------------------------------
if [[ -f "$_CM_MANIFEST" ]]; then
  _t3f_host=$(yq -o=json '.tools[] | select(.name == "cm") | .mounts[] | select(.dest == "/home/agent/.cass-memory") | .host' "$_CM_MANIFEST" 2>/dev/null | tr -d '"')
  if [[ -n "$_t3f_host" ]]; then
    pass "T3f cm manifest has mount: host='${_t3f_host}' → dest='/home/agent/.cass-memory' (RW store mount via generic mechanism)"
  else
    fail "T3f cm manifest missing mounts entry for /home/agent/.cass-memory — cm store mount not declared"
  fi
fi

# =============================================================================
# T2 — E2E (NEEDS_CONTAINER / RC_E2E=1)
# These tests require a REAL rc build with RC_MANIFEST_GLOBAL pointing to the
# cm manifest example, then verify cm is functional inside the cage.
# =============================================================================

echo ""
echo "--- T2: E2E cm assertions (NEEDS_CONTAINER / RC_E2E=1) ---"

if skip_if_not_e2e "T2a-T2e cm via manifest assertions"; then
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
# Setup: build a cm-enabled image, create a THROWAWAY HOME with .cass-memory,
# then start the container through rc up with RC_MANIFEST_GLOBAL pointing to
# the cm manifest example.
#
# This exercises the REAL manifest consumer (_manifest_build_mount_args +
# _manifest_expand_mount_host). The cm manifest declares:
#   mounts: [{host: "~/.cass-memory", dest: "/home/agent/.cass-memory"}]
# rc up expands ~ → T2_HOME, so the mount comes from the manifest consumer —
# NOT from a direct "docker run -v" bypass (rip-cage-buuo.5 false-green fix).
#
# NOTE: rc build hardcodes IMAGE="rip-cage:latest" — this overwrites the default
# image. A clean rebuild (./rc build) after this test restores the default.
# ---------------------------------------------------------------------------

# Build a cm-enabled image via rc build with RC_MANIFEST_GLOBAL.
echo "[T2 setup] Building cm-enabled rip-cage:latest via rc build + cm manifest..."
_build_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm-t2-build-home-XXXXXX")
mkdir -p "${_build_home}/.config/rip-cage"
_build_rc=0
_build_out=$(HOME="$_build_home" XDG_CONFIG_HOME="${_build_home}/.config" \
  RC_MANIFEST_GLOBAL="${REPO_ROOT}/tests/fixtures/manifest-cm-example.yaml" \
  "${REPO_ROOT}/rc" build 2>&1) || _build_rc=$?
rm -rf "$_build_home"

if [[ "$_build_rc" -ne 0 ]]; then
  fail "T2 setup FAIL: rc build with cm manifest failed (exit=${_build_rc}). Last 10 lines: $(echo "$_build_out" | tail -10)"
  echo ""
  echo "Results: FAILURES=${FAILURES}"
  exit 1
fi
echo "[T2 setup] cm-enabled image built"

# Verify cm is in the newly built image (early gate before proceeding).
_cm_check_rc=0
docker run --rm rip-cage:latest /bin/bash -c 'command -v cm' >/dev/null 2>&1 || _cm_check_rc=$?
if [[ "$_cm_check_rc" -ne 0 ]]; then
  fail "T2 setup FAIL: cm NOT found in rip-cage:latest after build with cm manifest — image build did not include cm"
  echo ""
  echo "Results: FAILURES=${FAILURES}"
  exit 1
fi
echo "[T2 setup] cm binary verified in rip-cage:latest"

# Create a throwaway HOME with .cass-memory store inside.
# ~ expands to T2_HOME at rc-up time, so ~/.cass-memory = T2_HOME/.cass-memory.
echo "[T2 setup] Creating throwaway HOME with .cass-memory store..."
T2_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm-t2-home-XXXXXX")
mkdir -p "${T2_HOME}/.cass-memory"
mkdir -p "${T2_HOME}/.config/rip-cage"

# Seed a minimal valid playbook inside the temp store via cm init.
_seed_rc=0
docker run --rm \
  -v "${T2_HOME}/.cass-memory:/tmp/seed-store" \
  rip-cage:latest \
  /bin/bash -c "CASS_MEMORY_HOME=/tmp/seed-store cm init --no-interactive" >/dev/null 2>&1 || _seed_rc=$?

if [[ "$_seed_rc" -ne 0 ]]; then
  fail "T2 setup FAIL: cm init in throwaway store failed (exit=${_seed_rc})"
  echo ""
  echo "Results: FAILURES=${FAILURES}"
  exit 1
fi
echo "[T2 setup] Throwaway store seeded at ${T2_HOME}/.cass-memory"

# Build a workspace for rc up. Container name = parent-base of workspace path.
# We put it at T2_WORKSPACE_BASE/rc/cm-t2 so name derives to "rc-cm-t2".
T2_WORKSPACE_BASE=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm-t2-ws-XXXXXX")
mkdir -p "${T2_WORKSPACE_BASE}/rc"
T2_WORKSPACE="${T2_WORKSPACE_BASE}/rc/cm-t2"
mkdir -p "$T2_WORKSPACE"
T2_CONTAINER_NAME="rc-cm-t2"

# Compute the RC_ALLOWED_ROOTS base (the parent of "rc").
T2_WS_RESOLVED=$(realpath "$T2_WORKSPACE_BASE" 2>/dev/null) || T2_WS_RESOLVED="$T2_WORKSPACE_BASE"

# Start the container through rc up with:
#   HOME=T2_HOME        — so ~/  expands to T2_HOME (containing .cass-memory)
#   RC_MANIFEST_GLOBAL  — the cm example manifest declaring ~/.cass-memory mount
# rc up is non-TTY; it exits non-zero from the tmux-attach step even when the
# container starts successfully. We capture output, ignore the exit code, and
# check container state directly (ME1 pattern from test-manifest-mounts.sh).
echo "[T2 setup] Starting container ${T2_CONTAINER_NAME} via rc up (manifest consumer path)..."
HOME="$T2_HOME" XDG_CONFIG_HOME="${T2_HOME}/.config" \
  RC_MANIFEST_GLOBAL="${REPO_ROOT}/tests/fixtures/manifest-cm-example.yaml" \
  RC_ALLOWED_ROOTS="$T2_WS_RESOLVED" \
  "${REPO_ROOT}/rc" up "$T2_WORKSPACE" >"${T2_WORKSPACE_BASE}/rc-up.log" 2>&1 || true
_up_out=$(cat "${T2_WORKSPACE_BASE}/rc-up.log" 2>/dev/null || true)

# Confirm the container is actually running.
_container_state=$(docker inspect "$T2_CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || true)
if [[ "$_container_state" != "running" ]]; then
  fail "T2 setup FAIL: container '${T2_CONTAINER_NAME}' is not running after rc up (state='${_container_state}'). rc up output: ${_up_out:0:500}"
  echo ""
  echo "Results: FAILURES=${FAILURES}"
  exit 1
fi
echo "[T2 setup] Container ${T2_CONTAINER_NAME} running (via rc up / manifest consumer)"

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
  fail "T2a cm --version FAILED: exit=${_version_rc} out='${_version_out}' — cm binary broken or missing in rip-cage:latest (was image built with the cm manifest?)"
fi

# ---------------------------------------------------------------------------
# T2b — cm context "<task>" --json returns parseable JSON.
# Gated on T2a sentinel (cm binary present and working).
# ---------------------------------------------------------------------------
_ctx_out=""
_ctx_rc=0
_ctx_out=$(docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm context "test rip-cage-buuo.5 proof task" --json 2>&1) || _ctx_rc=$?

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
# ---------------------------------------------------------------------------
_SENTINEL="rip-cage-buuo5-test-probe-$(date +%s)-$$-${RANDOM}"
_add_rc=0
_add_out=$(docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm playbook add "${_SENTINEL}" --category=observation 2>&1) || _add_rc=$?

if [[ "$_add_rc" -ne 0 ]]; then
  fail "T2c cm playbook add FAILED: exit=${_add_rc} out='${_add_out:0:200}'"
else
  # Re-read: list the playbook and check the sentinel is present.
  _list_out=""
  _list_rc=0
  _list_out=$(docker exec "$T2_CONTAINER_NAME" \
    /usr/local/bin/cm playbook list 2>&1) || _list_rc=$?

  if [[ "$_list_rc" -ne 0 ]]; then
    fail "T2c cm playbook list FAILED: exit=${_list_rc} out='${_list_out:0:200}'"
  else
    _list_confirmed=0
    if echo "$_list_out" | grep -qF "$_SENTINEL"; then
      _list_confirmed=1
    else
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
      # Host-store confirm: the sentinel must appear in the host-side store
      # (the throwaway .cass-memory dir inside T2_HOME). This proves the write
      # went through the manifest-consumer mount, NOT container-local storage.
      _host_store_yaml="${T2_HOME}/.cass-memory/playbook.yaml"
      if grep -qF "$_SENTINEL" "$_host_store_yaml" 2>/dev/null; then
        pass "T2c Round-trip confirmed: playbook add + list-reflect + host-store write all passed (sentinel: '${_SENTINEL}'; mount via manifest consumer)"
      else
        fail "T2c Store isolation FAILED: sentinel not found in host temp store ${_host_store_yaml} — write may have gone to container-local storage (manifest mount broken or bypassed)"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# T2d — Binary ownership: /usr/local/bin/cm is root-owned and NOT agent-writable.
# The buuo.3 root-owned assertion must pass for manifest-provisioned cm.
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

  if [[ "$_owner" == "root" ]]; then
    pass "T2d /usr/local/bin/cm is root-owned (owner='${_owner}', group='${_group}', perms='${_perms}')"
  else
    fail "T2d /usr/local/bin/cm is NOT root-owned: owner='${_owner}' (expected 'root')"
  fi

  _group_write="${_perms:5:1}"
  _other_write="${_perms:8:1}"
  if [[ "$_group_write" != "w" ]] && [[ "$_other_write" != "w" ]]; then
    pass "T2d /usr/local/bin/cm is NOT agent-writable (perms='${_perms}', no group/other write bit)"
  else
    fail "T2d /usr/local/bin/cm IS writable by non-root: perms='${_perms}' (group_write='${_group_write}', other_write='${_other_write}')"
  fi

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
# ---------------------------------------------------------------------------

_tcp_established_remotes() {
  docker exec "$T2_CONTAINER_NAME" /bin/bash -c '
    for f in /proc/net/tcp /proc/net/tcp6; do
      [ -f "$f" ] || continue
      awk "NR>1 && \$4==\"01\" {print \$3}" "$f"
    done
  ' 2>/dev/null | sort -u
}

echo ""
echo "--- T2e: Egress assertion (cm ops open zero external TCP connections) ---"

_egress_before=$(_tcp_established_remotes)

_egress_ctx_rc=0
docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm context "rip-cage-buuo5 egress probe task" --json >/dev/null 2>&1 || _egress_ctx_rc=$?

_egress_add_rc=0
docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm playbook add "rip-cage-buuo5-egress-probe-sentinel" --category=observation >/dev/null 2>&1 || _egress_add_rc=$?

_egress_list_rc=0
docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm playbook list >/dev/null 2>&1 || _egress_list_rc=$?

_egress_after=$(_tcp_established_remotes)

_new_connections=""
while IFS= read -r _addr; do
  [[ -z "$_addr" ]] && continue
  _remote_ip="${_addr%%:*}"
  [[ "$_remote_ip" == "00000000" ]] && continue
  [[ "$_remote_ip" == "7F000001" ]] && continue
  [[ "$_remote_ip" == "00000000000000000000000001000000" ]] && continue
  [[ "$_remote_ip" == "00000000000000000000000000000001" ]] && continue
  if ! echo "$_egress_before" | grep -qxF "$_addr"; then
    _new_connections="${_new_connections}${_addr} "
  fi
done <<< "$_egress_after"

if [[ -z "${_new_connections// /}" ]]; then
  pass "T2e cm ops opened ZERO external TCP connections (egress-before=${_egress_ctx_rc:-0}, add=${_egress_add_rc:-0}, list=${_egress_list_rc:-0})"
else
  fail "T2e EGRESS VIOLATION: cm ops opened new external TCP connections: '${_new_connections}' — cm must not phone home (ADR-005 D8)"
fi

echo ""
echo "[T2] Throwaway HOME: ${T2_HOME} (will be removed on exit)"
echo "[T2] Store: ${T2_HOME}/.cass-memory (will be removed on exit)"
echo "[T2] Real store NOT touched: container mounted throwaway store via manifest consumer"

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
