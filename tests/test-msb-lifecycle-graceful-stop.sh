#!/usr/bin/env bash
# tests/test-msb-lifecycle-graceful-stop.sh -- proof for bead rip-cage-rj68
# (S6) criterion 2: "A graceful stop provably PERSISTS a completed guest
# write (real read-back after restart); a --force stop is refused/avoided
# on state-bearing cages (regression guard for the silent-loss footgun)."
#
# Two parts:
#   STRUCT (structural regression guard) -- rc's OWN code (cli/up.sh,
#     cli/lib/msb_runtime.sh) never invokes `msb stop --force` / `-f`
#     anywhere in the create/resume/init-rollback lifecycle. This is the
#     right verification SHAPE for an absence claim ("rc never does X") --
#     msb_runtime.sh deliberately exposes only `_msb_stop_graceful` (no
#     forced-stop sibling at all, see its own module comment) so there is
#     no accidental one-flag-away footgun to grep for; this test confirms
#     that design holds in the actual shipped code, not just in the
#     module's stated intent.
#   PERSIST (real effect) -- a real guest write, made via `rc up`'s own
#     init-established cage, survives graceful stop (_msb_stop_graceful,
#     the function rc's own resume-rollback path uses) + msb start,
#     read back independently via msb exec after restart. The CONTRASTING
#     force-kill data-loss mechanism itself (ADR-029 D4's "--force
#     hard-kill silently discards guest writes") is already
#     adversarially proven upstream (spike rip-cage-9iab Q3/Q4, cited
#     directly in ADR-029 D4) -- this bead's job is wiring rc onto the
#     graceful-only discipline, not re-deriving msb's force-kill mechanics
#     from scratch.
#
# NEEDS_MSB + a pre-built rip-cage:latest image already `msb load`-ed.
# STRUCT self-runs unconditionally (pure grep, no live dependency).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# STRUCT: rc never invokes a forced stop anywhere in cli/*.sh or
# cli/lib/*.sh.
#
# rip-cage-syzk (R9): widened from "cli/up.sh cli/lib/msb_runtime.sh" to the
# full cli/*.sh + cli/lib/*.sh file set -- the original two-file scope
# predates cli/reload.sh owning its OWN _msb_stop_graceful/_msb_remove call
# (this bead's changed seam: image-drift-as-recreate-trigger reuses that
# same cold-recreate call pair), so a forced-stop regression introduced in
# cli/reload.sh (or any other module) was invisible to this guard until now.
# ---------------------------------------------------------------------------
echo ""
echo "=== STRUCT: rc's own code never invokes 'msb stop --force'/-f (all of cli/*.sh + cli/lib/*.sh) ==="
STRUCT_HITS=$(grep -nE '^\s*[^#]*msb stop[^|;]*(--force|-f\b)' "${REPO_ROOT}"/cli/*.sh "${REPO_ROOT}"/cli/lib/*.sh 2>/dev/null || true)
if [[ -z "$STRUCT_HITS" ]]; then
  pass "STRUCT: zero occurrences of 'msb stop --force'/-f across cli/*.sh + cli/lib/*.sh"
else
  fail "STRUCT: found a forced-stop invocation" "$STRUCT_HITS"
fi

STRUCT_FN_COUNT=$(grep -c '^_msb_stop' "${REPO_ROOT}/cli/lib/msb_runtime.sh" 2>/dev/null || echo 0)
STRUCT_GRACEFUL_ONLY=$(grep -c '^_msb_stop_graceful()' "${REPO_ROOT}/cli/lib/msb_runtime.sh" 2>/dev/null || echo 0)
if [[ "$STRUCT_FN_COUNT" -eq 1 && "$STRUCT_GRACEFUL_ONLY" -eq 1 ]]; then
  pass "STRUCT: msb_runtime.sh exposes exactly ONE stop primitive, and it is the graceful one (no forced-stop sibling to misuse)"
else
  fail "STRUCT: expected exactly one _msb_stop* function (the graceful one)" "count=${STRUCT_FN_COUNT}"
fi

# ---------------------------------------------------------------------------
# R12 (rip-cage-syzk) -- invariant 2's proof over the changed seam: in
# cli/reload.sh, every _msb_remove call is immediately preceded by an
# unconditional _msb_stop_graceful on the same code path -- no intervening
# conditional, no early-return between them. R9 above (STRUCT) catches a
# *forced* stop; this catches an *absent* stop before a forced *remove* --
# the hazard a future "skip the stop when already stopped" optimisation
# would introduce (rejected in review, rip-cage-syzk design). With that
# optimisation rejected, the two calls are adjacent non-comment lines, so
# this assertion is a cheap adjacency check.
#
# Adversarial-review finding F2 (fresh-context review of rip-cage-syzk): the
# original version only grepped the previous line for the SUBSTRING
# '_msb_stop_graceful ' -- a one-liner-guarded mutation like
# `[[ "$image_drift" -ne 1 ]] && _msb_stop_graceful "$name"` (literally the
# rejected "skip the stop when already stopped" shape) STILL contains that
# substring, so it passed. Fixed: the previous line must be an UNCONDITIONAL
# call -- after stripping leading whitespace it must START with
# `_msb_stop_graceful` (nothing else -- no `[[`, no `if`, no `&&`/`||`
# guard token -- ahead of the call on that line).
# ---------------------------------------------------------------------------
echo ""
echo "=== R12: cli/reload.sh -- every _msb_remove call is immediately preceded by an unconditional _msb_stop_graceful ==="
_R12_RELOAD_CODE_LINES=$(grep -v '^\s*#' "${REPO_ROOT}/cli/reload.sh" | grep -v '^\s*$')
_R12_REMOVE_LINE_COUNT=$(echo "$_R12_RELOAD_CODE_LINES" | grep -c '_msb_remove ')
if [[ "$_R12_REMOVE_LINE_COUNT" -eq 0 ]]; then
  fail "R12: expected at least one _msb_remove call in cli/reload.sh (did the cold-recreate call site move/get removed?)" "(none found)"
else
  _r12_ok=true
  _r12_bad_lines=""
  while IFS= read -r _r12_lineno; do
    [[ -z "$_r12_lineno" ]] && continue
    _r12_prev_lineno=$((_r12_lineno - 1))
    _r12_prev_line=$(echo "$_R12_RELOAD_CODE_LINES" | sed -n "${_r12_prev_lineno}p")
    if ! echo "$_r12_prev_line" | grep -qE '^[[:space:]]*_msb_stop_graceful([[:space:]]|$)'; then
      _r12_ok=false
      _r12_bad_lines="${_r12_bad_lines} line${_r12_lineno}(prev='${_r12_prev_line}')"
    fi
  done < <(echo "$_R12_RELOAD_CODE_LINES" | grep -n '_msb_remove ' | cut -d: -f1)
  if [[ "$_r12_ok" == "true" ]]; then
    pass "R12: every _msb_remove call in cli/reload.sh is immediately preceded (same code path, no intervening conditional/early-return) by _msb_stop_graceful"
  else
    fail "R12: an _msb_remove call in cli/reload.sh is NOT immediately preceded by _msb_stop_graceful" "${_r12_bad_lines}"
  fi
fi

if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping the PERSIST (live) part of $(basename "$0")"
  echo ""
  echo "=== test-msb-lifecycle-graceful-stop.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  [[ "$FAILURES" -eq 0 ]]
  exit $?
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping the PERSIST (live) part of $(basename "$0")"
  echo ""
  echo "=== test-msb-lifecycle-graceful-stop.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  [[ "$FAILURES" -eq 0 ]]
  exit $?
fi

# ---------------------------------------------------------------------------
# PERSIST: a real guest write survives _msb_stop_graceful + msb start.
# ---------------------------------------------------------------------------
echo ""
echo "=== PERSIST: a completed guest write survives graceful stop + restart ==="
NAME="gs-probe-$$"
cleanup() { msb remove --force "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! msb create "$IMAGE" --name "$NAME" >/dev/null 2>&1; then
  fail "PERSIST setup: msb create failed"
  echo ""
  echo "=== test-msb-lifecycle-graceful-stop.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi

# A real completed write, individually reported successful (exit 0) BEFORE
# the stop is issued -- exactly the class of write the D4 corollary is
# about ("writes that already reported success").
msb exec "$NAME" -- sh -c 'echo graceful-stop-marker-value > /home/agent/gs-marker.txt && sync'
WRITE_RC=$?
if [[ "$WRITE_RC" -eq 0 ]]; then
  pass "PERSIST: guest write reported success before stop (exit 0)"
else
  fail "PERSIST: guest write did not report success" "rc=$WRITE_RC"
fi

# shellcheck source=/dev/null
source "${REPO_ROOT}/rc" 2>/dev/null
_msb_stop_graceful "$NAME" >/dev/null 2>&1
STOPPED_STATE=$(_msb_sandbox_state "$NAME")
if [[ "$STOPPED_STATE" == "exited" ]]; then
  pass "PERSIST: sandbox genuinely stopped via the graceful primitive"
else
  fail "PERSIST: expected exited after graceful stop" "got '${STOPPED_STATE}'"
fi

_msb_start "$NAME" >/dev/null 2>&1
RESTARTED_STATE=$(_msb_sandbox_state "$NAME")
if [[ "$RESTARTED_STATE" == "running" ]]; then
  pass "PERSIST: sandbox running again after restart"
else
  fail "PERSIST: expected running after restart" "got '${RESTARTED_STATE}'"
fi

READBACK=$(msb exec "$NAME" -- cat /home/agent/gs-marker.txt 2>/dev/null)
if [[ "$READBACK" == "graceful-stop-marker-value" ]]; then
  pass "PERSIST: independent post-restart read-back confirms the write survived graceful stop: '${READBACK}'"
else
  fail "PERSIST: write did not survive graceful stop + restart" "got '${READBACK}'"
fi

echo ""
echo "=== test-msb-lifecycle-graceful-stop.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
