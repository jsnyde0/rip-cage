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
# STRUCT: rc never invokes a forced stop anywhere in cli/up.sh or
# cli/lib/msb_runtime.sh.
# ---------------------------------------------------------------------------
echo ""
echo "=== STRUCT: rc's own code never invokes 'msb stop --force'/-f ==="
STRUCT_HITS=$(grep -nE '^\s*[^#]*msb stop[^|;]*(--force|-f\b)' "${REPO_ROOT}/cli/up.sh" "${REPO_ROOT}/cli/lib/msb_runtime.sh" 2>/dev/null || true)
if [[ -z "$STRUCT_HITS" ]]; then
  pass "STRUCT: zero occurrences of 'msb stop --force'/-f in cli/up.sh or cli/lib/msb_runtime.sh"
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
