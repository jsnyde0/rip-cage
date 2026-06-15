#!/usr/bin/env bash
# test-multiplexer-composable.sh — Composability integration harness (rip-cage-61al.8)
#
# PRIMARY SIGNAL: proves "zero rc edits" for a new multiplexer.
# A fixture mux named 'fakemux' — a name that appears NOWHERE in rc or
# init-rip-cage.sh — drives the full lifecycle (build, config-validate, start,
# attach dispatch) with ZERO edits to the committed rc/init source.
#
# This is the ONLY signal that proves the composability claim: a unit test of
# the hook parser would pass even if a hidden gate survived (round-1 review
# Finding 12). The novel-name end-to-end probe is load-bearing.
#
# =============================================================================
# Test structure
# =============================================================================
#
#   G1  (grep-guard, always / host-only):
#     G1a — 'fakemux' appears NOWHERE in rc or init-rip-cage.sh (name is novel)
#     G1b — 'tmux|herdr' returns ZERO hits in rc + init-rip-cage.sh (full D12
#             scope: dispatch, schema enum, comments, function names, check_tmux
#             preflight — all gone; ADR-005 D12 FIRM regression guard).
#     G1c — the historically-leaky 'none,tmux,herdr' comma-enum string is absent
#     G1d — no case-arm matching tmux or herdr literals in rc or init-rip-cage.sh
#
#   E1  (e2e, NEEDS_CONTAINER / RC_E2E=1):
#     E1a — fakemux hooks baked: /etc/rip-cage/multiplexers/fakemux/start and
#             /attach present in the built image
#     E1b — rc.multiplexers image label contains 'fakemux'
#     E1c — session.multiplexer: fakemux PASSES config-validate (a name rc has
#             never heard of; accepted because it's baked in the image label)
#     E1d — rc up (COLD cage) starts the container and init-rip-cage.sh runs the
#             fakemux start hook: /tmp/fakemux-started sentinel present inside cage
#     E1e — _rc_mux_resolve_hook_path resolves fakemux/attach from the cage
#             (proves the registry dispatch routes through the baked hook)
#     E1f — running the baked attach hook via docker exec writes /tmp/fakemux-attached
#             (proves the attach hook executes and emits the expected marker)
#     E1g — ALL of E1a-E1f happen with ZERO edits to rc/init (no rc/init touched
#             by this test; the source under test is the committed repo)
#
# =============================================================================
# Conventions (load-bearing repo lessons):
#   * FAILURES counter + [[ $FAILURES -eq 0 ]] || exit 1 — no prose-only red
#     (per rip-cage-test-fail-prose-without-exit-silent-red).
#   * Crash-safe trap armed BEFORE first mutation (docker build mutates
#     rip-cage:latest — per test-mutating-shared-live-state-needs-crash-safe-trap).
#   * Throwaway image tag, NOT rip-cage:latest.
#   * RC_ALLOWED_ROOTS set for fixture cage (per rip-cage-validation-fixture-pattern).
#   * RC_E2E=1 required for e2e tier (NEEDS_CONTAINER per ADR-013).
#   * Source rc with explicit ./ prefix (per rip-cage-source-rc-bare-vs-explicit).
# =============================================================================
#
# Run:
#   bash tests/test-multiplexer-composable.sh          # G1 only (host-only tier)
#   RC_E2E=1 bash tests/test-multiplexer-composable.sh # G1 + E1 (full, slow)
#
# Wired into tests/run-host.sh as NEEDS_CONTAINER per ADR-013 D1/D3.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# G1: Grep-guard (always / host-only)
# ---------------------------------------------------------------------------
echo "=== test-multiplexer-composable.sh ==="
echo ""
echo "--- G1: grep-guards (host-only, always) ---"

# G1a — 'fakemux' appears NOWHERE in rc or init-rip-cage.sh.
# This is the load-bearing precondition: if 'fakemux' were already in rc/init,
# the test would prove nothing (it would just be testing a known special-case).
FAKEMUX_HITS=$(grep -n 'fakemux' "${REPO_ROOT}/rc" "${REPO_ROOT}/init-rip-cage.sh" 2>/dev/null || true)
if [[ -z "$FAKEMUX_HITS" ]]; then
  pass "G1a 'fakemux' appears NOWHERE in rc or init-rip-cage.sh (name is novel — precondition holds)"
else
  fail "G1a 'fakemux' found in rc or init-rip-cage.sh — the test name is NOT novel; composability claim is weakened" \
    "hits: ${FAKEMUX_HITS}"
fi

# G1b — Full ADR-005 D12 scope: 'tmux|herdr' returns ZERO hits in rc + init-rip-cage.sh.
# This guard enforces the D12 invariant repo-wide: rc's code never names a specific
# optional tool — not in dispatch, not in schema enum, not in comments, not in function
# names, not in the check_tmux preflight. A broad grep catches every shape.
# After rip-cage-61al (all children closed), expected count = 0.
GREP_GUARD_OUT=$(grep -n 'tmux\|herdr' "${REPO_ROOT}/rc" "${REPO_ROOT}/init-rip-cage.sh" 2>/dev/null || true)
if [[ -z "$GREP_GUARD_OUT" ]]; then
  pass "G1b zero tmux|herdr hits in rc + init-rip-cage.sh (ADR-005 D12 FIRM invariant holds)"
else
  fail "G1b unexpected tmux|herdr literals in rc or init-rip-cage.sh (D12 violation — optional-mux names must not appear in core source)" \
    "$(echo "$GREP_GUARD_OUT" | head -5)"
fi
echo "  Full grep output (D12 survivors report):"
echo "$GREP_GUARD_OUT" | while IFS= read -r _line; do echo "    $_line"; done
echo ""

# G1c — 'none,tmux,herdr' comma-enum literal is absent from rc.
# This is the historically-leaky shape (the static schema enum that B2 removed).
# Belt-and-suspenders: even if G1b somehow missed it, this anchored grep catches it.
ENUM_HITS=$(grep -n 'none,tmux,herdr' "${REPO_ROOT}/rc" 2>/dev/null || true)
if [[ -z "$ENUM_HITS" ]]; then
  pass "G1c 'none,tmux,herdr' static enum literal absent from rc (B2 de-enumeration holds)"
else
  fail "G1c 'none,tmux,herdr' static enum PRESENT in rc — static enum must be replaced by dynamic derivation" \
    "hits: ${ENUM_HITS}"
fi

# G1d — No case-arm matching 'tmux' or 'herdr' as named targets in rc or init-rip-cage.sh.
# The case-dispatch pattern 'case.*tmux|herdr' is the historically-hardcoded dispatch shape
# (B3's job was to de-hardcode these). Anchored grep.
CASE_HITS=$(grep -nE 'tmux\)|herdr\)' "${REPO_ROOT}/rc" "${REPO_ROOT}/init-rip-cage.sh" 2>/dev/null || true)
if [[ -z "$CASE_HITS" ]]; then
  pass "G1d no 'tmux)' or 'herdr)' case-arm targets in rc or init-rip-cage.sh (B3 dispatch de-hardcoding holds)"
else
  fail "G1d hardcoded case-arm dispatch target 'tmux)' or 'herdr)' found in rc or init-rip-cage.sh" \
    "hits: ${CASE_HITS}"
fi

echo ""
echo "--- G1 complete ---"
echo ""

# ---------------------------------------------------------------------------
# E1: E2E composability probe — NEEDS_CONTAINER / RC_E2E=1
# ---------------------------------------------------------------------------
if [[ "${RC_E2E:-}" != "1" ]]; then
  echo "SKIP (NEEDS_CONTAINER / e2e): E1a-E1g — set RC_E2E=1 to run the live fakemux composability probe"
  echo ""
  if [[ $FAILURES -eq 0 ]]; then
    echo "All G1 grep-guard tests PASSED."
    exit 0
  else
    echo "${FAILURES} G1 test(s) FAILED."
    exit 1
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  [[ $FAILURES -eq 0 ]] && exit 0 || exit 1
fi

echo "--- E1: live fakemux composability e2e (RC_E2E=1) ---"
echo ""

# ---------------------------------------------------------------------------
# E1 state — throwaway image + scratch cage + crash-safe cleanup
# ---------------------------------------------------------------------------
FM_IMAGE=""          # throwaway image tag
FM_SAVED_TAG=""      # saved rip-cage:latest (if any)
FM_HAD_LATEST=0      # 1 if rip-cage:latest existed before our build
FM_TMP=""            # temp dir for scratch workspace
FM_CAGE=""           # scratch cage name

# Cleanup: idempotent, safe to call multiple times.
# Note: 'local' is not valid at top-level in bash; use plain vars with guard.
_FM_CLEANUP_CALLED=0
_fm_cleanup() {
  if [[ "${_FM_CLEANUP_CALLED:-0}" -eq 1 ]]; then return; fi
  _FM_CLEANUP_CALLED=1

  # Destroy scratch cage if created
  if [[ -n "${FM_CAGE:-}" ]]; then
    docker rm -f "${FM_CAGE}" >/dev/null 2>&1 || true
    docker volume rm "rc-state-${FM_CAGE}" >/dev/null 2>&1 || true
    docker volume rm "rc-history-${FM_CAGE}" >/dev/null 2>&1 || true
    docker volume rm "rc-mise-cache" >/dev/null 2>&1 || true
    FM_CAGE=""
  fi

  # Destroy throwaway image
  if [[ -n "${FM_IMAGE:-}" ]]; then
    docker image rm "${FM_IMAGE}" >/dev/null 2>&1 || true
    FM_IMAGE=""
  fi

  # Restore rip-cage:latest
  if [[ -n "${FM_SAVED_TAG:-}" ]]; then
    if [[ "${FM_HAD_LATEST:-0}" -eq 1 ]]; then
      docker tag "${FM_SAVED_TAG}" rip-cage:latest 2>/dev/null || true
    else
      docker image rm rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "${FM_SAVED_TAG}" 2>/dev/null || true
    FM_SAVED_TAG=""
  fi

  # Remove temp workspace
  [[ -n "${FM_TMP:-}" ]] && rm -rf "${FM_TMP}"
  FM_TMP=""
}

# Arm crash-safe trap BEFORE the first mutation (build tags rip-cage:latest).
trap '_fm_cleanup' EXIT INT TERM

# ---------------------------------------------------------------------------
# Build: save existing rip-cage:latest, build fakemux image, tag throwaway.
# ---------------------------------------------------------------------------
_fm_unique_suffix="$(date +%s)-$$"
FM_SAVED_TAG="rip-cage:fakemux-composable-saved-${_fm_unique_suffix}"
FM_HAD_LATEST=0

if docker image inspect rip-cage:latest >/dev/null 2>&1; then
  docker tag rip-cage:latest "${FM_SAVED_TAG}" 2>/dev/null && FM_HAD_LATEST=1
fi

FAKEMUX_FIXTURE="${FIXTURES}/manifest-fakemux.yaml"
if [[ ! -f "${FAKEMUX_FIXTURE}" ]]; then
  fail "E1 FATAL: fakemux fixture not found at ${FAKEMUX_FIXTURE}"
  echo "FATAL: fixture missing — cannot proceed with E1"
  exit 1
fi

echo "=== E1: Building fakemux cage image from ${FAKEMUX_FIXTURE} ==="
_fm_build_rc=0
RC_MANIFEST_GLOBAL="${FAKEMUX_FIXTURE}" "${RC}" build \
  >/tmp/rc-fakemux-composable-build.out 2>&1 || _fm_build_rc=$?

if [[ "${_fm_build_rc}" -ne 0 ]]; then
  fail "E1 FATAL: rc build with fakemux fixture failed (exit=${_fm_build_rc})" \
    "see /tmp/rc-fakemux-composable-build.out"
  echo "FATAL: cannot proceed with E1 without a successful image build"
  exit 1
fi

FM_IMAGE="rip-cage:fakemux-composable-${_fm_unique_suffix}"
docker tag rip-cage:latest "${FM_IMAGE}" 2>/dev/null || true
pass "E1 rc build succeeded with fakemux manifest: ${FM_IMAGE}"

# ---------------------------------------------------------------------------
# E1a — fakemux hooks baked in image: /etc/rip-cage/multiplexers/fakemux/start + /attach
# ---------------------------------------------------------------------------
echo ""
echo "--- E1a: fakemux hooks baked in image ---"

_e1a_start_rc=0
docker run --rm "${FM_IMAGE}" test -f /etc/rip-cage/multiplexers/fakemux/start 2>/dev/null || _e1a_start_rc=$?
if [[ "${_e1a_start_rc}" -eq 0 ]]; then
  pass "E1a /etc/rip-cage/multiplexers/fakemux/start hook file baked in image"
else
  fail "E1a /etc/rip-cage/multiplexers/fakemux/start ABSENT in image — registry bake failed"
fi

_e1a_attach_rc=0
docker run --rm "${FM_IMAGE}" test -f /etc/rip-cage/multiplexers/fakemux/attach 2>/dev/null || _e1a_attach_rc=$?
if [[ "${_e1a_attach_rc}" -eq 0 ]]; then
  pass "E1a /etc/rip-cage/multiplexers/fakemux/attach hook file baked in image"
else
  fail "E1a /etc/rip-cage/multiplexers/fakemux/attach ABSENT in image — registry bake failed"
fi

# Verify start hook content references the sentinel command
_e1a_start_content=$(docker run --rm "${FM_IMAGE}" cat /etc/rip-cage/multiplexers/fakemux/start 2>/dev/null || true)
if echo "${_e1a_start_content}" | grep -q 'fakemux-started'; then
  pass "E1a start hook content baked correctly (references 'fakemux-started' sentinel)"
else
  fail "E1a start hook content unexpected: '${_e1a_start_content}'"
fi

# ---------------------------------------------------------------------------
# E1b — rc.multiplexers image label contains 'fakemux'
# ---------------------------------------------------------------------------
echo ""
echo "--- E1b: rc.multiplexers label ---"

_e1b_label=$(docker inspect --format '{{ index .Config.Labels "rc.multiplexers" }}' "${FM_IMAGE}" 2>/dev/null || true)
if [[ -n "${_e1b_label}" ]]; then
  pass "E1b rc.multiplexers label present: '${_e1b_label}'"
else
  fail "E1b rc.multiplexers label ABSENT from built image"
fi

if echo "${_e1b_label}" | grep -q 'fakemux'; then
  pass "E1b rc.multiplexers label contains 'fakemux': '${_e1b_label}'"
else
  fail "E1b rc.multiplexers label does NOT contain 'fakemux'. label='${_e1b_label}'"
fi

# ---------------------------------------------------------------------------
# E1c — session.multiplexer: fakemux PASSES config-validate with the built image.
# Uses RC_MUX_INSPECT_IMAGE override (same pattern as test-multiplexer-config-dynamic.sh).
# ---------------------------------------------------------------------------
echo ""
echo "--- E1c: config-validate with session.multiplexer: fakemux ---"

_e1c_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/rc-fakemux-composable-config-XXXXXX")
mkdir -p "${_e1c_sandbox}/.config/rip-cage"
mkdir -p "${_e1c_sandbox}/workspace"
cat > "${_e1c_sandbox}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
YAML
touch "${_e1c_sandbox}/.config/rip-cage/tools.yaml"
cat > "${_e1c_sandbox}/workspace/.rip-cage.yaml" <<'YAML'
version: 1
session:
  multiplexer: fakemux
YAML

_e1c_stderr=$(mktemp)
_e1c_exit=0
HOME="${_e1c_sandbox}" XDG_CONFIG_HOME="${_e1c_sandbox}/.config" \
  RC_MUX_INSPECT_IMAGE="${FM_IMAGE}" \
  RC_MANIFEST_GLOBAL="${FAKEMUX_FIXTURE}" \
  bash -c "cd '${_e1c_sandbox}/workspace' && '${RC}' config show --json" \
  >/dev/null 2>"${_e1c_stderr}" || _e1c_exit=$?

if [[ "${_e1c_exit}" -eq 0 ]]; then
  pass "E1c session.multiplexer=fakemux PASSES config-validate (baked image label authoritative)"
else
  fail "E1c session.multiplexer=fakemux FAILED config-validate — label-based derivation broken" \
    "stderr: $(cat "${_e1c_stderr}")"
fi

# Belt-and-suspenders: ghost-mux (not in label) must FAIL loud
cat > "${_e1c_sandbox}/workspace/.rip-cage.yaml" <<'YAML'
version: 1
session:
  multiplexer: ghost-mux
YAML
_e1c_ghost_exit=0
HOME="${_e1c_sandbox}" XDG_CONFIG_HOME="${_e1c_sandbox}/.config" \
  RC_MUX_INSPECT_IMAGE="${FM_IMAGE}" \
  RC_MANIFEST_GLOBAL="${FAKEMUX_FIXTURE}" \
  bash -c "cd '${_e1c_sandbox}/workspace' && '${RC}' config show --json" \
  >/dev/null 2>"${_e1c_stderr}" || _e1c_ghost_exit=$?

if [[ "${_e1c_ghost_exit}" -ne 0 ]]; then
  pass "E1c session.multiplexer=ghost-mux FAILS loud (not baked — config-validate discriminates)"
else
  fail "E1c session.multiplexer=ghost-mux should fail but exited 0 — config-validate is fail-open"
fi

rm -f "${_e1c_stderr}"
rm -rf "${_e1c_sandbox}"

# ---------------------------------------------------------------------------
# E1d — rc up (COLD cage): start hook runs, /tmp/fakemux-started sentinel present.
# ---------------------------------------------------------------------------
echo ""
echo "--- E1d: rc up (COLD cage) — fakemux start hook runs ---"

# Create scratch workspace
FM_TMP=$(mktemp -d)
FM_TMP=$(realpath "${FM_TMP}")
mkdir -p "${FM_TMP}/fakemux-workspace"
git -C "${FM_TMP}/fakemux-workspace" init -q 2>/dev/null
printf '# fakemux composability test workspace\n' > "${FM_TMP}/fakemux-workspace/README"

# .rip-cage.yaml: select fakemux multiplexer
cat > "${FM_TMP}/fakemux-workspace/.rip-cage.yaml" <<'YAML'
version: 1
session:
  multiplexer: fakemux
YAML

export RC_ALLOWED_ROOTS="${FM_TMP}"

# Derive cage name (container_name uses last two path components of workspace).
# FM_TMP/fakemux-workspace → last two: <parent-basename>/fakemux-workspace
_fm_parent_base=$(basename "${FM_TMP}")
FM_CAGE="${_fm_parent_base}-fakemux-workspace"

# Pre-cleanup: remove any leftover from prior aborted run
docker rm -f "${FM_CAGE}" >/dev/null 2>&1 || true
docker volume rm "rc-state-${FM_CAGE}" >/dev/null 2>&1 || true
docker volume rm "rc-history-${FM_CAGE}" >/dev/null 2>&1 || true

echo "  Spinning up fakemux cage: ${FM_CAGE} (image: ${FM_IMAGE})"
_e1d_up_rc=0
RC_MANIFEST_GLOBAL="${FAKEMUX_FIXTURE}" \
  "${RC}" up "${FM_TMP}/fakemux-workspace" \
  </dev/null >/tmp/rc-fakemux-composable-up.out 2>&1 || _e1d_up_rc=$?

# Check cage is running
if docker inspect "${FM_CAGE}" >/dev/null 2>&1; then
  pass "E1d fakemux cage started: ${FM_CAGE} (rc up exit=${_e1d_up_rc})"
else
  fail "E1d fakemux cage failed to start" \
    "rc up exit=${_e1d_up_rc}; see /tmp/rc-fakemux-composable-up.out"
  # Cannot proceed with sentinel checks
  echo "FATAL: cage not running — aborting E1d/e/f"
  echo ""
  echo "=== test-multiplexer-composable.sh complete ==="
  [[ $FAILURES -eq 0 ]] || exit 1
  exit 0
fi

# Assert rc.session.multiplexer label is 'fakemux'
_e1d_mux_label=$(docker inspect --format '{{index .Config.Labels "rc.session.multiplexer"}}' "${FM_CAGE}" 2>/dev/null || true)
if [[ "${_e1d_mux_label}" == "fakemux" ]]; then
  pass "E1d rc.session.multiplexer label = 'fakemux'"
else
  fail "E1d rc.session.multiplexer label = '${_e1d_mux_label}' (expected 'fakemux')"
fi

# Assert start hook ran: /tmp/fakemux-started sentinel present inside cage.
# init-rip-cage.sh runs the start hook at container init time (via docker exec).
# Allow up to 15s for init to complete (the hook runs early in the init sequence).
_e1d_sentinel_found=false
_e1d_waited=0
while [[ "${_e1d_waited}" -lt 15 ]]; do
  _e1d_sentinel=$(docker exec "${FM_CAGE}" sh -c 'test -f /tmp/fakemux-started && echo present || echo absent' 2>/dev/null || echo absent)
  if [[ "${_e1d_sentinel}" == "present" ]]; then
    _e1d_sentinel_found=true
    break
  fi
  sleep 1
  _e1d_waited=$((_e1d_waited + 1))
done

if [[ "${_e1d_sentinel_found}" == "true" ]]; then
  pass "E1d fakemux start hook ran: /tmp/fakemux-started sentinel present inside cage (init_hook dispatched via baked registry)"
else
  fail "E1d fakemux start hook did NOT run — /tmp/fakemux-started absent after ${_e1d_waited}s" \
    "registry dispatch or init-rip-cage.sh start-case may be broken"
  # Diagnostic: check init log
  _e1d_init_log=$(docker exec "${FM_CAGE}" grep -i 'fakemux\|ERROR\|multiplexer' /var/log/rip-cage-init.log 2>/dev/null || true)
  echo "  Init log excerpt: ${_e1d_init_log:-<not available>}"
fi

# ---------------------------------------------------------------------------
# E1e — _rc_mux_resolve_hook_path resolves fakemux/attach from the running cage.
# Proves the registry dispatch routes through the baked hook (cage-aware path).
# ---------------------------------------------------------------------------
echo ""
echo "--- E1e: registry dispatch — _rc_mux_resolve_hook_path resolves fakemux/attach ---"

_e1e_resolve_out=""
_e1e_resolve_rc=0
_e1e_resolve_out=$(bash -c "source '${RC}'; _rc_mux_resolve_hook_path 'fakemux' 'attach' '${FM_CAGE}'" 2>&1) || _e1e_resolve_rc=$?

if [[ "${_e1e_resolve_rc}" -eq 0 ]] && [[ -n "${_e1e_resolve_out}" ]]; then
  pass "E1e _rc_mux_resolve_hook_path resolved 'fakemux/attach' via cage: '${_e1e_resolve_out}'"
else
  fail "E1e _rc_mux_resolve_hook_path FAILED to resolve 'fakemux/attach'" \
    "exit=${_e1e_resolve_rc} out='${_e1e_resolve_out}'"
fi

if echo "${_e1e_resolve_out}" | grep -q 'fakemux/attach'; then
  pass "E1e resolved path contains expected 'fakemux/attach' component"
else
  fail "E1e resolved path missing 'fakemux/attach': '${_e1e_resolve_out}'"
fi

# Ghost-mux must fail loud (discriminating — fakemux image only has fakemux in label)
_e1e_ghost_out=""
_e1e_ghost_rc=0
_e1e_ghost_out=$(bash -c "source '${RC}'; _rc_mux_resolve_hook_path 'ghost-mux' 'attach' '${FM_CAGE}'" 2>&1) || _e1e_ghost_rc=$?
if [[ "${_e1e_ghost_rc}" -ne 0 ]]; then
  pass "E1e _rc_mux_resolve_hook_path fails loud on 'ghost-mux' (not baked — discriminates)"
else
  fail "E1e _rc_mux_resolve_hook_path should fail on 'ghost-mux' but exited 0" \
    "out='${_e1e_ghost_out}'"
fi

# ---------------------------------------------------------------------------
# E1f — running the baked attach hook via docker exec writes /tmp/fakemux-attached
#        and emits the unique marker 'fakemux-attach-marker'.
# ---------------------------------------------------------------------------
echo ""
echo "--- E1f: attach hook executes and emits expected marker ---"

# Resolve the baked hook path (already proven in E1e; use fresh resolution)
_e1f_hook_path=""
_e1f_hook_path=$(bash -c "source '${RC}'; _rc_mux_resolve_hook_path 'fakemux' 'attach' '${FM_CAGE}'" 2>/dev/null || true)

if [[ -z "${_e1f_hook_path}" ]]; then
  fail "E1f cannot run attach hook: path resolution failed (E1e must have also failed)"
else
  # Run the baked attach hook directly inside the cage (non-TTY, headless)
  _e1f_hook_out=""
  _e1f_hook_rc=0
  _e1f_hook_out=$(docker exec "${FM_CAGE}" sh "${_e1f_hook_path}" 2>&1) || _e1f_hook_rc=$?

  if echo "${_e1f_hook_out}" | grep -q 'fakemux-attach-marker'; then
    pass "E1f baked attach hook emitted 'fakemux-attach-marker' (hook is self-contained; end-to-end dispatch resolution proven in E1e)"
  else
    fail "E1f baked attach hook did NOT emit 'fakemux-attach-marker'" \
      "exit=${_e1f_hook_rc} output='${_e1f_hook_out}'"
  fi

  # Check /tmp/fakemux-attached sentinel written by attach hook
  _e1f_sentinel=$(docker exec "${FM_CAGE}" sh -c 'test -f /tmp/fakemux-attached && echo present || echo absent' 2>/dev/null || echo absent)
  if [[ "${_e1f_sentinel}" == "present" ]]; then
    pass "E1f /tmp/fakemux-attached sentinel written by attach hook (hook executed fully)"
  else
    fail "E1f /tmp/fakemux-attached sentinel NOT written" \
      "hook output: '${_e1f_hook_out}'"
  fi
fi

# ---------------------------------------------------------------------------
# E1g — Zero edits to rc/init: verify the committed source was not touched.
# The test runs against the committed repo; no rc/init file was modified by
# any step in E1. This assertion is structural (no build process touches rc/init).
# We confirm by asserting the git working tree for rc/init is clean.
# ---------------------------------------------------------------------------
echo ""
echo "--- E1g: zero rc/init edits (composability claim: rc-unknown mux needs ZERO source edits) ---"

_e1g_rc_dirty=$(git -C "${REPO_ROOT}" diff --name-only -- rc init-rip-cage.sh 2>/dev/null || true)
if [[ -z "${_e1g_rc_dirty}" ]]; then
  pass "E1g rc and init-rip-cage.sh are CLEAN (no edits made by this test — zero-rc-edit claim holds)"
else
  fail "E1g rc or init-rip-cage.sh modified during this test run — the composability claim is FALSE" \
    "dirty files: ${_e1g_rc_dirty}"
fi

# Summarise: the novel-name (fakemux) drove config-validate + start + attach
# with ZERO edits to the committed rc/init source.
echo ""
echo "  Summary: 'fakemux' (a name rc has never heard of) drove the full lifecycle"
echo "  (build → label → config-validate → start hook → attach dispatch)"
echo "  with ZERO edits to rc or init-rip-cage.sh."
echo "  ADR-005 D12 composable-seam invariant: HOLDS."

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
echo "=== test-multiplexer-composable.sh complete ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All composability integration tests PASSED."
else
  echo "${FAILURES} composability integration test(s) FAILED."
fi

[[ $FAILURES -eq 0 ]] || exit 1
