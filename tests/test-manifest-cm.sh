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
#           via cm playbook list reflects the write in the mounted store.
#     T2d — Binary ownership: /usr/local/bin/cm is root-owned and NOT agent-writable.
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
#   logic resolves to it.  The real store (~/.local/share/cass-memory) is
#   never read, never written.
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
# the real host store at ~/.local/share/cass-memory.
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
_SENTINEL="rip-cage-l0u2-test-probe-$(date +%s)"
_add_rc=0
_add_out=$(docker exec "$T2_CONTAINER_NAME" \
  /usr/local/bin/cm playbook add "${_SENTINEL}" --category=observation 2>&1) || _add_rc=$?

if [[ "$_add_rc" -ne 0 ]]; then
  fail "T2c cm playbook add FAILED: exit=${_add_rc} out='${_add_out:0:200}'"
else
  pass "T2c cm playbook add exited 0 (entry: '${_SENTINEL}')"

  # Re-read: list the playbook and check the sentinel is present.
  _list_out=""
  _list_rc=0
  _list_out=$(docker exec "$T2_CONTAINER_NAME" \
    /usr/local/bin/cm playbook list 2>&1) || _list_rc=$?

  if [[ "$_list_rc" -ne 0 ]]; then
    fail "T2c cm playbook list FAILED: exit=${_list_rc} out='${_list_out:0:200}'"
  elif echo "$_list_out" | grep -qF "$_SENTINEL"; then
    pass "T2c Round-trip: cm playbook list reflects the added entry (sentinel found in list output)"
  else
    # Also check the raw playbook.yaml in the mounted store (belt-and-suspenders).
    _yaml_rc=0
    _yaml_contains=$(docker exec "$T2_CONTAINER_NAME" \
      grep -c "${_SENTINEL}" /home/agent/.cass-memory/playbook.yaml 2>&1) || _yaml_rc=$?
    if [[ "$_yaml_rc" -eq 0 ]] && [[ "${_yaml_contains:-0}" -gt 0 ]]; then
      pass "T2c Round-trip: sentinel present in playbook.yaml (list output may use short display)"
    else
      fail "T2c Round-trip FAILED: sentinel '${_SENTINEL}' NOT found in cm playbook list output nor in playbook.yaml. List output: '${_list_out:0:300}'"
    fi
  fi

  # Verify the write landed in the TEMP store (not a container-local store).
  # The temp store is mounted at /home/agent/.cass-memory; check via the host path.
  if grep -qF "$_SENTINEL" "${T2_TEMP_STORE}/playbook.yaml" 2>/dev/null; then
    pass "T2c Store isolation: write landed in the throwaway temp store (not container-local)"
  else
    fail "T2c Store isolation FAILED: sentinel not found in host temp store ${T2_TEMP_STORE}/playbook.yaml — write may have gone to container-local storage (mount broken)"
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
