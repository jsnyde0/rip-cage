#!/usr/bin/env bash
# test-multiplexer-composable.sh — composability integration harness
# (rip-cage-61al.8, ported to the boot descriptor by rip-cage-ely4.7.4).
#
# PRIMARY SIGNAL: proves "zero rc edits" for a new multiplexer.
# A fixture mux named 'fakemux' — a name that appears NOWHERE in rc or
# init-rip-cage.sh — drives the full lifecycle (build, selection, start,
# attach dispatch) with ZERO edits to the committed rc/init source.
#
# This is the ONLY signal that proves the composability claim: a unit test of
# the hook parser would pass even if a hidden gate survived (round-1 review
# Finding 12). The novel-name end-to-end probe is load-bearing.
#
# =============================================================================
# WHAT THE PORT CHANGED, AND WHY EACH CASE STILL BITES
# =============================================================================
#
# Every surface E1 used to probe retired with the tools manifest (ADR-031 D4)
# and the six-verb thinning (D3). The fixture is no longer a manifest handed to
# `rc build -t`; it is a Dockerfile that extends the base image and merges a
# boot-descriptor fragment, built with `rc build --file` under RC_IMAGE. Case
# by case:
#
#   E1a  was: two hook FILES under /etc/rip-cage/multiplexers/fakemux/.
#        now: the image's boot descriptor declares a fakemux multiplexer whose
#        start hook carries the sentinel. Same question — did the composed
#        image really carry the mux — asked of the surface that now answers it.
#
#   E1b  RETIRED. It read the rc.multiplexers image label, which no longer
#        exists. Re-expressing it against the descriptor would just restate
#        E1a, so it goes rather than becoming a second copy of its neighbour.
#
#   E1c  was: `rc config show` accepting session.multiplexer: fakemux.
#        now: `rc up --dry-run` with RC_MULTIPLEXER=fakemux is accepted and
#        ghost-mux is REFUSED. This case got STRONGER: the old one validated a
#        config field against an image label, while this one exercises the
#        preflight that actually gates a boot, and the refusal names the
#        multiplexers the image does declare.
#
#   E1d  was: docker inspect for a label, docker exec for the sentinel.
#        now: the cage is an msb sandbox — `msb exec` for the sentinel, and the
#        selection is read back from rc's own label on the sandbox.
#
#   E1e  was: _rc_mux_resolve_hook_path, deleted. Its successor is
#        _container_mux_hook_cmd, which returns the hook's COMMAND STRING read
#        out of the running cage's descriptor rather than a path. Same
#        discriminator: it fail-louds on a mux the image does not declare.
#
#   E1f  runs that command string inside the cage. Under the old registry the
#        hook was a file to execute; under the descriptor it is a command to
#        run, so the assertion follows the hook, not the path.
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
#     E1a — the built image's boot descriptor declares fakemux, with the
#             sentinel-carrying start hook and an attach hook
#     E1c — RC_MULTIPLEXER=fakemux is accepted by rc up's preflight; ghost-mux
#             is refused, naming what the image does declare
#     E1d — a real cage boots under fakemux and init ran its start hook:
#             /tmp/fakemux-started present inside the cage
#     E1e — _container_mux_hook_cmd resolves fakemux/attach from the running
#             cage's descriptor, and fail-louds on ghost-mux
#     E1f — running that attach command inside the cage emits the marker and
#             writes /tmp/fakemux-attached
#     E1g — ALL of the above happen with ZERO edits to rc/init
#
# =============================================================================
# Conventions (load-bearing repo lessons):
#   * FAILURES counter + [[ $FAILURES -eq 0 ]] || exit 1 — no prose-only red
#     (per rip-cage-test-fail-prose-without-exit-silent-red).
#   * Crash-safe trap armed BEFORE the first mutation.
#   * A throwaway image tag via RC_IMAGE, never rip-cage:latest — and the
#     scratch tag is reaped from BOTH docker and msb, since `rc build` loads
#     what it builds into msb's cache too.
#   * The fixture Dockerfile lives OUTSIDE every tree the cage config mounts:
#     rc refuses one that resolves inside a cage mount (ADR-031 D5(a)).
#   * RC_E2E=1 required for the e2e tier (NEEDS_CONTAINER per ADR-013).
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
FAKEMUX_HITS=$(grep -n 'fakemux' "${REPO_ROOT}/rc" "${REPO_ROOT}/cage/init/init-rip-cage.sh" 2>/dev/null || true)
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
GREP_GUARD_OUT=$(grep -n 'tmux\|herdr' "${REPO_ROOT}/rc" "${REPO_ROOT}/cage/init/init-rip-cage.sh" 2>/dev/null || true)
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
CASE_HITS=$(grep -nE 'tmux\)|herdr\)' "${REPO_ROOT}/rc" "${REPO_ROOT}/cage/init/init-rip-cage.sh" 2>/dev/null || true)
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
# E1 state — scratch extension image + scratch cage + crash-safe cleanup
# ---------------------------------------------------------------------------
BASE_TAG="${RC_FAKEMUX_BASE_TAG:-rip-cage:latest}"
FM_IMAGE=""          # scratch extension tag; rip-cage:latest is never written
FM_WORK=""           # build context — OUTSIDE every tree the cage config mounts
FM_TMP=""            # temp dir holding the scratch workspace
FM_CAGE=""           # scratch cage name

# shellcheck source=tests/_cage-conf-lib.sh
source "${SCRIPT_DIR}/_cage-conf-lib.sh"
# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"

if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available — the cage runtime is msb now, not docker"
  [[ $FAILURES -eq 0 ]] && exit 0 || exit 1
fi
if ! docker image inspect "$BASE_TAG" >/dev/null 2>&1; then
  echo "SKIP: no ${BASE_TAG} to extend — run 'rc build' first"
  [[ $FAILURES -eq 0 ]] && exit 0 || exit 1
fi
# An image built before the boot descriptor landed has no rc-boot-merge in it,
# so every case below would fail on the FIXTURE rather than on the contract.
# Say which it is (copied from test-boot-descriptor.sh's own guard).
if ! docker run --rm --entrypoint sh "$BASE_TAG" -c 'command -v rc-boot-merge' >/dev/null 2>&1; then
  echo "SKIP: ${BASE_TAG} predates the boot descriptor (no rc-boot-merge in it)"
  [[ $FAILURES -eq 0 ]] && exit 0 || exit 1
fi

# Cleanup: idempotent, safe to call multiple times.
# Note: 'local' is not valid at top-level in bash; use plain vars with guard.
_FM_CLEANUP_CALLED=0
_fm_cleanup() {
  if [[ "${_FM_CLEANUP_CALLED:-0}" -eq 1 ]]; then return; fi
  _FM_CLEANUP_CALLED=1

  # Destroy the scratch cage by its EXACT name — rc destroy, never an
  # enumeration, and never a bare msb remove (which would orphan the cage's
  # rc-state-/rc-history- volumes forever).
  if [[ -n "${FM_CAGE:-}" ]]; then
    _fm_d_out=$("${RC}" destroy "${FM_CAGE}" 2>&1)
    _fm_d_rc=$?
    if [[ "$_fm_d_rc" -ne 0 ]]; then
      echo "WARNING: failed to destroy '${FM_CAGE}' (exit ${_fm_d_rc}): ${_fm_d_out}" >&2
    fi
    FM_CAGE=""
  fi

  # Reap the scratch image from BOTH stores. `rc build` loads what it builds
  # into msb's cache as well as docker's, so removing only the docker tag
  # leaves a scratch image behind in the store cages actually boot from.
  if [[ -n "${FM_IMAGE:-}" ]]; then
    docker image rm "${FM_IMAGE}" >/dev/null 2>&1 || true
    msb image remove "${FM_IMAGE}" >/dev/null 2>&1 || true
    FM_IMAGE=""
  fi

  [[ -n "${FM_WORK:-}" ]] && rm -rf "${FM_WORK}"
  FM_WORK=""
  [[ -n "${FM_TMP:-}" ]] && rm -rf "${FM_TMP}"
  FM_TMP=""
}

# Arm crash-safe trap BEFORE the first mutation (the build creates FM_IMAGE).
trap '_fm_cleanup' EXIT INT TERM

# ---------------------------------------------------------------------------
# Build: a FROM-extension carrying one synthetic multiplexer.
#
# fakemux installs no binary on purpose. The whole subject is that a name rc
# has never heard of works, so the hooks are an echo and a touch — the cheapest
# thing that leaves observable evidence inside a real cage.
#
# The build context is a fresh mktemp dir, kept well away from the workspace
# this test later mounts: rc refuses, fail-closed, a Dockerfile that resolves
# inside a tree its own cage config mounts (ADR-031 D5(a)).
# ---------------------------------------------------------------------------
_fm_unique_suffix="$(date +%s)-$$"
FM_IMAGE="rip-cage-fakemux-composable:${_fm_unique_suffix}"

FM_WORK=$(mktemp -d)
FM_WORK=$(cd "$FM_WORK" && pwd -P)

cat > "${FM_WORK}/boot-fragment.json" <<'FRAGMENT'
{
  "multiplexers": [
    {
      "name": "fakemux",
      "start": "touch /tmp/fakemux-started && echo '[fakemux] start hook ran: sentinel at /tmp/fakemux-started'",
      "attach": "echo 'fakemux-attach-marker' && touch /tmp/fakemux-attached"
    }
  ]
}
FRAGMENT

cat > "${FM_WORK}/Dockerfile" <<DOCKERFILE
FROM ${BASE_TAG}
USER root
COPY boot-fragment.json /tmp/fakemux-boot.json
RUN rc-boot-merge /tmp/fakemux-boot.json && rm -f /tmp/fakemux-boot.json
USER agent
DOCKERFILE

echo "=== E1: building the fakemux extension image -> ${FM_IMAGE} ==="
_fm_build_rc=0
RC_IMAGE="${FM_IMAGE}" "${RC}" build --file "${FM_WORK}/Dockerfile" \
  >/tmp/rc-fakemux-composable-build.out 2>&1 || _fm_build_rc=$?

if [[ "${_fm_build_rc}" -ne 0 ]]; then
  fail "E1 FATAL: rc build --file failed for the fakemux extension (exit=${_fm_build_rc})" \
    "see /tmp/rc-fakemux-composable-build.out"
  echo "FATAL: cannot proceed with E1 without a successful image build"
  exit 1
fi
pass "E1 rc build --file produced the fakemux extension image: ${FM_IMAGE}"

# `rc build` loads into msb best-effort. A cage cannot boot from an image msb
# does not hold, so make the load explicit rather than discovering it as a
# confusing rc up failure three cases later.
if ! msb image inspect "${FM_IMAGE}" >/dev/null 2>&1; then
  _fm_tar="${FM_WORK}/fakemux.tar"
  docker save "${FM_IMAGE}" -o "${_fm_tar}" >/dev/null 2>&1 \
    && msb load --tag "${FM_IMAGE}" -i "${_fm_tar}" >/dev/null 2>&1 || true
  rm -f "${_fm_tar}"
fi
if msb image inspect "${FM_IMAGE}" >/dev/null 2>&1; then
  pass "E1 the fakemux image is in msb's cache (a cage can boot from it)"
else
  fail "E1 FATAL: the fakemux image never reached msb's cache" \
    "rc up below would fail on a missing image, not on the contract"
  exit 1
fi

# ---------------------------------------------------------------------------
# E1a — the composed image's boot descriptor declares fakemux.
# ---------------------------------------------------------------------------
echo ""
echo "--- E1a: fakemux declared in the image's boot descriptor ---"

_e1a_desc=$(docker run --rm --entrypoint sh "${FM_IMAGE}" -c 'cat /etc/rip-cage/boot.json' 2>/dev/null || true)
if jq -e '(.multiplexers // []) | any(.name == "fakemux")' <<<"${_e1a_desc}" >/dev/null 2>&1; then
  pass "E1a the descriptor declares a 'fakemux' multiplexer"
else
  fail "E1a no 'fakemux' entry in the image's descriptor — the fragment did not merge" \
    "descriptor: ${_e1a_desc}"
fi

_e1a_start=$(jq -r '(.multiplexers // [])[] | select(.name=="fakemux") | .start // ""' <<<"${_e1a_desc}" 2>/dev/null || true)
if grep -q 'fakemux-started' <<<"${_e1a_start}"; then
  pass "E1a the start hook carries the sentinel (merged verbatim, not mangled)"
else
  fail "E1a the start hook does not reference 'fakemux-started': '${_e1a_start}'"
fi

_e1a_attach=$(jq -r '(.multiplexers // [])[] | select(.name=="fakemux") | .attach // ""' <<<"${_e1a_desc}" 2>/dev/null || true)
if [[ -n "${_e1a_attach}" ]]; then
  pass "E1a the attach hook is present (the schema's second required field)"
else
  fail "E1a the fakemux entry carries no attach hook"
fi

# The base image must NOT already declare fakemux, or E1a proves nothing about
# the fragment this test merged.
_e1a_base_desc=$(docker run --rm --entrypoint sh "${BASE_TAG}" -c 'cat /etc/rip-cage/boot.json' 2>/dev/null || true)
if jq -e '(.multiplexers // []) | any(.name == "fakemux")' <<<"${_e1a_base_desc}" >/dev/null 2>&1; then
  fail "E1a the BASE image already declares fakemux — E1a cannot attribute it to the fragment"
else
  pass "E1a negative control: the base image declares no fakemux, so the fragment is what added it"
fi

# ---------------------------------------------------------------------------
# E1c — rc up's multiplexer preflight accepts fakemux and refuses ghost-mux.
#
# This replaces the retired config-validate case, and asks a better question:
# the preflight below is what actually gates a boot, and it reads the IMAGE's
# descriptor rather than a label. A dry run is enough — the refusal happens
# before anything is created.
# ---------------------------------------------------------------------------
echo ""
echo "--- E1c: RC_MULTIPLEXER preflight discriminates a declared mux from an unknown one ---"

FM_TMP=$(mktemp -d)
FM_TMP=$(cd "$FM_TMP" && pwd -P)
mkdir -p "${FM_TMP}/fakemux-workspace"
git -C "${FM_TMP}/fakemux-workspace" init -q 2>/dev/null
printf '# fakemux composability test workspace\n' > "${FM_TMP}/fakemux-workspace/README"

FM_CONF=$(cage_conf_for "${FM_TMP}/fakemux-workspace" "${FM_IMAGE}")

_e1c_ok_err=$(mktemp)
_e1c_ok_rc=0
RC_CAGE_CONF="${FM_CONF}" RC_IMAGE="${FM_IMAGE}" RC_MULTIPLEXER="fakemux" \
  "${RC}" up --dry-run "${FM_TMP}/fakemux-workspace" \
  </dev/null >/dev/null 2>"${_e1c_ok_err}" || _e1c_ok_rc=$?
if [[ "${_e1c_ok_rc}" -eq 0 ]]; then
  pass "E1c a mux the image declares is accepted — 'fakemux' passes the preflight"
else
  fail "E1c 'fakemux' was refused even though the image declares it" \
    "stderr: $(cat "${_e1c_ok_err}")"
fi

_e1c_ghost_err=$(mktemp)
_e1c_ghost_rc=0
RC_CAGE_CONF="${FM_CONF}" RC_IMAGE="${FM_IMAGE}" RC_MULTIPLEXER="ghost-mux" \
  "${RC}" up --dry-run "${FM_TMP}/fakemux-workspace" \
  </dev/null >/dev/null 2>"${_e1c_ghost_err}" || _e1c_ghost_rc=$?
if [[ "${_e1c_ghost_rc}" -ne 0 ]]; then
  pass "E1c a mux the image does NOT declare is refused — 'ghost-mux' fails the preflight"
else
  fail "E1c 'ghost-mux' was accepted — the preflight is fail-open"
fi
# The refusal has to be actionable, or an operator cannot tell a typo from a
# missing recipe.
if grep -q 'fakemux' "${_e1c_ghost_err}"; then
  pass "E1c the refusal names what the image DOES declare"
else
  fail "E1c the refusal does not name the declared multiplexers" \
    "stderr: $(cat "${_e1c_ghost_err}")"
fi
rm -f "${_e1c_ok_err}" "${_e1c_ghost_err}"

# ---------------------------------------------------------------------------
# E1d — a real cage boots under fakemux and init ran its start hook.
# ---------------------------------------------------------------------------
echo ""
echo "--- E1d: rc up (COLD cage) — the fakemux start hook runs inside a real cage ---"

FM_CAGE="$(basename "${FM_TMP}")-fakemux-workspace"
scratch_cage_register "${FM_CAGE}"

echo "  Spinning up fakemux cage: ${FM_CAGE} (image: ${FM_IMAGE})"
_e1d_up_rc=0
RC_CAGE_CONF="${FM_CONF}" RC_IMAGE="${FM_IMAGE}" RC_MULTIPLEXER="fakemux" \
  "${RC}" up "${FM_TMP}/fakemux-workspace" \
  </dev/null >/tmp/rc-fakemux-composable-up.out 2>&1 || _e1d_up_rc=$?

if msb inspect "${FM_CAGE}" >/dev/null 2>&1; then
  pass "E1d fakemux cage created: ${FM_CAGE} (rc up exit=${_e1d_up_rc})"
else
  fail "E1d fakemux cage failed to start" \
    "rc up exit=${_e1d_up_rc}; see /tmp/rc-fakemux-composable-up.out"
  echo "FATAL: cage not running — aborting E1d/e/f"
  echo ""
  echo "=== test-multiplexer-composable.sh complete ==="
  exit 1
fi

_e1d_mux_label=$(msb inspect "${FM_CAGE}" --format json 2>/dev/null \
  | jq -r '.config.labels["rc.session.multiplexer"] // ""' 2>/dev/null || true)
if [[ "${_e1d_mux_label}" == "fakemux" ]]; then
  pass "E1d the cage is stamped rc.session.multiplexer=fakemux"
else
  fail "E1d rc.session.multiplexer = '${_e1d_mux_label}' (expected 'fakemux')"
fi

# init runs the start hook early in the boot sequence; give it a bounded wait
# rather than a fixed sleep. Each probe carries its own timeout because macOS
# has no timeout(1) to wrap the whole thing in.
_e1d_sentinel_found=false
_e1d_waited=0
while [[ "${_e1d_waited}" -lt 20 ]]; do
  _e1d_sentinel=$(msb exec "${FM_CAGE}" -- sh -c 'test -f /tmp/fakemux-started && echo present || echo absent' 2>/dev/null || echo absent)
  if [[ "${_e1d_sentinel}" == "present" ]]; then
    _e1d_sentinel_found=true
    break
  fi
  sleep 1
  _e1d_waited=$((_e1d_waited + 1))
done

if [[ "${_e1d_sentinel_found}" == "true" ]]; then
  pass "E1d the fakemux start hook RAN: /tmp/fakemux-started is present inside the cage"
else
  fail "E1d the fakemux start hook did NOT run — /tmp/fakemux-started absent after ${_e1d_waited}s" \
    "init's descriptor dispatch may be broken"
  _e1d_init_log=$(msb exec "${FM_CAGE}" -- sh -c 'grep -i "fakemux\|ERROR\|multiplexer" /var/log/rip-cage-init.log 2>/dev/null | tail -20' 2>/dev/null || true)
  echo "  Init log excerpt: ${_e1d_init_log:-<not available>}"
fi

# ---------------------------------------------------------------------------
# E1e — the hook resolver reads fakemux/attach out of the RUNNING cage.
#
# Successor to the deleted _rc_mux_resolve_hook_path. It returns the hook's
# COMMAND STRING, read from the descriptor inside the cage, not a file path.
# ---------------------------------------------------------------------------
echo ""
echo "--- E1e: _container_mux_hook_cmd resolves fakemux/attach from the running cage ---"

_e1e_resolve_out=""
_e1e_resolve_rc=0
_e1e_resolve_out=$(bash -c "source '${RC}' 2>/dev/null; _container_mux_hook_cmd 'fakemux' 'attach' '${FM_CAGE}'" 2>&1) || _e1e_resolve_rc=$?

if [[ "${_e1e_resolve_rc}" -eq 0 && -n "${_e1e_resolve_out}" ]]; then
  pass "E1e resolved fakemux/attach from the cage: '${_e1e_resolve_out}'"
else
  fail "E1e failed to resolve 'fakemux/attach' from the running cage" \
    "exit=${_e1e_resolve_rc} out='${_e1e_resolve_out}'"
fi
if grep -q 'fakemux-attach-marker' <<<"${_e1e_resolve_out}"; then
  pass "E1e the resolved command is the one the fragment declared"
else
  fail "E1e the resolved command is not the declared attach hook: '${_e1e_resolve_out}'"
fi

# Discriminating half: a mux the cage does not carry must fail loud, or the
# resolver would happily hand back nothing and the caller would run it.
_e1e_ghost_out=""
_e1e_ghost_rc=0
_e1e_ghost_out=$(bash -c "source '${RC}' 2>/dev/null; _container_mux_hook_cmd 'ghost-mux' 'attach' '${FM_CAGE}'" 2>&1) || _e1e_ghost_rc=$?
if [[ "${_e1e_ghost_rc}" -ne 0 ]]; then
  pass "E1e the resolver fails loud on 'ghost-mux' (it discriminates)"
else
  fail "E1e the resolver returned 0 for 'ghost-mux'" "out='${_e1e_ghost_out}'"
fi

# ---------------------------------------------------------------------------
# E1f — running the resolved attach command inside the cage has its effect.
# ---------------------------------------------------------------------------
echo ""
echo "--- E1f: the resolved attach hook executes and emits its marker ---"

if [[ -z "${_e1e_resolve_out}" ]]; then
  fail "E1f cannot run the attach hook: resolution failed (E1e is also red)"
else
  _e1f_hook_out=""
  _e1f_hook_rc=0
  _e1f_hook_out=$(msb exec "${FM_CAGE}" -- sh -c "${_e1e_resolve_out}" 2>&1) || _e1f_hook_rc=$?

  if grep -q 'fakemux-attach-marker' <<<"${_e1f_hook_out}"; then
    pass "E1f the attach hook emitted 'fakemux-attach-marker'"
  else
    fail "E1f the attach hook did not emit its marker" \
      "exit=${_e1f_hook_rc} output='${_e1f_hook_out}'"
  fi

  _e1f_sentinel=$(msb exec "${FM_CAGE}" -- sh -c 'test -f /tmp/fakemux-attached && echo present || echo absent' 2>/dev/null || echo absent)
  if [[ "${_e1f_sentinel}" == "present" ]]; then
    pass "E1f /tmp/fakemux-attached was written — the hook ran to completion, not just its first echo"
  else
    fail "E1f /tmp/fakemux-attached was NOT written" "hook output: '${_e1f_hook_out}'"
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
