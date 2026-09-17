#!/usr/bin/env bash
# tests/test-run-host-image-identity-gate.sh -- rip-cage-ely4.7.9's guard.
#
# THE RULE: a suite run must leave the operator's production image exactly as
# it found it, in BOTH stores, and must FAIL the run when it does not.
#
# WHY A SECOND FILE, AND WHY THIS SHAPE. run-host.sh already had a tag-move
# check, and it was advisory: it printed a CAVEAT and the run still exited 0.
# On 2026-09-17 it fired for real on a `--host-only` run. The line scrolled
# past in a thousand-line log, the run reported success, and rip-cage:latest
# was left pointing at a months-old release with no floor probe in it -- so
# every later probe would have measured the wrong image while the suite said
# everything was fine. Advisory was the defect.
#
# Its verification target already had a probe -- test-run-host-image-tag-move-
# caveat.sh -- but that one is MANUAL-ONLY, because proving the check by
# actually repointing rip-cage:latest is precisely the act nothing automated
# may do. This file proves the same property WITHOUT touching either store: it
# lifts the comparison out of run-host.sh and drives it with synthetic values.
# No docker, no msb, no cage, no image. That is what lets it run every time.
#
# Coverage:
#   G1  identical start/end -> silent, returns 0
#   G2  unreadable at either end -> NOT reported as a move (docker or msb
#       being down mid-run is a different problem, and crying clobber for it
#       would train everyone to ignore the line -- which is how the real one
#       got ignored)
#   R1  RED CASE: genuinely different values -> returns 1 and says MOVED,
#       naming which store. This is the case that must be able to fail.
#   S1  run-host.sh reads BOTH stores: docker's image id and msb's cache
#       digest, each captured at start and compared at end. Watching only
#       docker is what let the msb half go unnoticed.
#   S2  a move actually reaches the exit status -- the whole point.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# RC_TEST_RUN_HOST points this probe at a SCRATCH COPY of run-host.sh, which
# is how the red case is demonstrated on demand: mutate the copy (drop the
# exit, neuter the verdict, delete the msb resolver) and re-run to watch the
# matching case go red. Unset in every normal run, so the subject is the real
# file. Reading only -- this probe never executes run-host.sh.
RUN_HOST="${RC_TEST_RUN_HOST:-${SCRIPT_DIR}/run-host.sh}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ -- $2}"; FAIL=$((FAIL + 1)); }

if [[ ! -f "$RUN_HOST" ]]; then
  echo "FAIL: run-host.sh not found at ${RUN_HOST}"
  exit 1
fi

# Lift the verdict function out of run-host.sh and eval it here. Extracting
# the REAL text -- rather than restating the comparison -- is what makes this
# a test of run-host.sh and not of a copy that can drift away from it.
_verdict_src=$(awk '/^_rh_image_identity_verdict\(\) \{/,/^\}/' "$RUN_HOST")
if [[ -z "$_verdict_src" ]]; then
  fail "could not extract _rh_image_identity_verdict from run-host.sh" \
    "the gate may have been renamed or removed"
  echo ""
  echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
  exit 1
fi
eval "$_verdict_src"

echo "=== G1: identical identities are silent and pass ==="
_g1_out=$(_rh_image_identity_verdict "docker image id" "sha256:aaa" "sha256:aaa"); _g1_rc=$?
if [[ "$_g1_rc" -eq 0 && -z "$_g1_out" ]]; then
  pass "G1: an unchanged image reports nothing and returns 0"
else
  fail "G1: expected silence and rc=0" "rc=${_g1_rc} out='${_g1_out}'"
fi

echo ""
echo "=== G2: an unreadable store is not a clobber ==="
_g2_fails=0
for _pair in "unavailable|sha256:bbb" "sha256:aaa|unavailable" "|sha256:bbb" "sha256:aaa|"; do
  _s="${_pair%%|*}"; _e="${_pair##*|}"
  _out=$(_rh_image_identity_verdict "docker image id" "$_s" "$_e"); _rc=$?
  if [[ "$_rc" -ne 0 || -n "$_out" ]]; then
    _g2_fails=1
    fail "G2: start='${_s}' end='${_e}' was reported as a move" "rc=${_rc} out='${_out}'"
  fi
done
[[ "$_g2_fails" -eq 0 ]] && pass "G2: an unreadable identity at either end is not reported as a move"

echo ""
echo "=== R1 (RED CASE): a genuine move returns non-zero and names the store ==="
_r1_out=$(_rh_image_identity_verdict "msb cache config digest" "sha256:aaa" "sha256:bbb"); _r1_rc=$?
if [[ "$_r1_rc" -ne 0 ]]; then
  pass "R1a: a differing identity returns non-zero (the gate can fail)"
else
  fail "R1a: a differing identity returned 0 -- the gate cannot fail, so every green is vacuous"
fi
if [[ "$_r1_out" == *"MOVED"* && "$_r1_out" == *"msb cache config digest"* \
   && "$_r1_out" == *"sha256:aaa"* && "$_r1_out" == *"sha256:bbb"* ]]; then
  pass "R1b: the report names the store and both identities"
else
  fail "R1b: the report is not actionable" "out='${_r1_out}'"
fi

echo ""
echo "=== S1: both stores are captured at start and compared at end ==="
for _needle in \
  "_rh_resolve_image_digest" \
  "_rh_resolve_msb_image_digest" \
  "RH_START_IMAGE_DIGEST" \
  "RH_START_MSB_IMAGE_DIGEST"; do
  if grep -q "$_needle" "$RUN_HOST"; then
    pass "S1: run-host.sh still carries ${_needle}"
  else
    fail "S1: ${_needle} is gone from run-host.sh" "one of the two stores is no longer watched"
  fi
done
if grep -q 'msb image inspect rip-cage:latest' "$RUN_HOST"; then
  pass "S1: the msb resolver reads msb's own cache entry for the production tag"
else
  fail "S1: nothing in run-host.sh reads msb's cache entry" "the msb half is not wired"
fi

echo ""
echo "=== S2: a move reaches the exit status (not just the log) ==="
if grep -q 'RH_IMAGE_MOVED=1' "$RUN_HOST" && grep -qE 'RH_IMAGE_MOVED.*-eq 1' "$RUN_HOST"; then
  pass "S2a: run-host.sh sets and then reads RH_IMAGE_MOVED"
else
  fail "S2a: RH_IMAGE_MOVED is not both set and read" "a move would be advisory again"
fi
# The read must sit in a block that exits non-zero, or it changes nothing.
_s2_block=$(awk '/if \[\[ "\$RH_IMAGE_MOVED" -eq 1 \]\]; then/,/^fi/' "$RUN_HOST")
if grep -q 'exit 1' <<<"$_s2_block"; then
  pass "S2b: the RH_IMAGE_MOVED branch exits non-zero"
else
  fail "S2b: the RH_IMAGE_MOVED branch does not exit non-zero" "block: ${_s2_block}"
fi
# And the old advisory framing must be gone, or a reader will trust the wrong
# contract even while the code is right.
if grep -q 'advisory-only, never touches exit status' "$RUN_HOST"; then
  fail "S2c: run-host.sh still describes the check as advisory-only" \
    "the comment contradicts the gate directly above it"
else
  pass "S2c: the stale advisory-only framing is gone"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
