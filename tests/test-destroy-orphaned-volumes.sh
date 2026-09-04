#!/usr/bin/env bash
# tests/test-destroy-orphaned-volumes.sh -- rip-cage-o5ie repro + regression guard.
#
# cli/down_destroy.sh's cmd_destroy used to `exit 1` at the _msb_exists check
# BEFORE reaching the rc-state-<name>/rc-history-<name> volume-removal loop,
# so a cage whose sandbox was already removed (e.g. by a prior `msb remove`,
# or a test's own EXIT-trap teardown racing a host-side destroy) leaked its
# two named volumes forever -- `msb remove` alone never deletes them (see
# cli/down_destroy.sh's own header comment). Fix: derive the two volume
# names from the resolved cage name and remove them whether or not the
# sandbox still exists.
#
# SAFETY: this test creates its fixture volumes DIRECTLY via `msb volume
# create` -- never a wildcard/enumerate-and-destroy pass -- and its own EXIT
# trap removes ONLY the exact volume names it created, by literal name, with
# a run-id suffix that can never collide with a real cage or a parallel
# suite run in flight. tests/test-cleanup-failsafe.sh is the incident repro
# for the class of mistake this guards against; the negative-control decoy
# volume below proves this test would catch a wildcard/prefix-match "fix"
# too, not just the original bug (see rip-cage-o5ie ship-record for the RED
# demonstration against a deliberately-wildcard variant).
#
# Only needs the real `msb volume` primitive (create/inspect/remove) -- no
# sandbox boot, no image, no docker. Self-skips (SKIP:, exit 0) if `msb`
# isn't on PATH -- never fakes a PASS.
#
# Exit: $FAILURES (silent-red guard per rip-cage-test-fail-prose-without-exit-silent-red).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
PASS_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== test-destroy-orphaned-volumes.sh ==="

if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb --version >/dev/null 2>&1; then
  echo "SKIP: msb not responsive -- skipping $(basename "$0")"
  exit 0
fi

# Unique run-id suffix -- can never collide with a real cage name or with a
# parallel suite run currently in flight on this machine.
RUN_ID="o5ie-$$-${RANDOM}"
CAGE_NAME="rc-destroy-orphan-${RUN_ID}"
DECOY_NAME="${CAGE_NAME}-decoy-sibling" # shares CAGE_NAME as a PREFIX but is a DIFFERENT cage name

VOL_STATE="rc-state-${CAGE_NAME}"
VOL_HISTORY="rc-history-${CAGE_NAME}"
DECOY_VOL_STATE="rc-state-${DECOY_NAME}"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  # Exact literal names only -- never a glob/prefix sweep.
  msb volume remove "$VOL_STATE" >/dev/null 2>&1 || true
  msb volume remove "$VOL_HISTORY" >/dev/null 2>&1 || true
  msb volume remove "$DECOY_VOL_STATE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

volume_exists() {
  msb volume inspect "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Setup: create the two named volumes DIRECTLY (msb volume create), plus a
# negative-control decoy volume under a similar-but-different name. No
# sandbox is ever created for CAGE_NAME -- this is the "sandbox already
# removed" state the bug leaves behind.
# ---------------------------------------------------------------------------
if ! msb volume create "$VOL_STATE" >/dev/null 2>&1; then
  fail "setup: msb volume create $VOL_STATE failed"
fi
if ! msb volume create "$VOL_HISTORY" >/dev/null 2>&1; then
  fail "setup: msb volume create $VOL_HISTORY failed"
fi
if ! msb volume create "$DECOY_VOL_STATE" >/dev/null 2>&1; then
  fail "setup: msb volume create $DECOY_VOL_STATE failed"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo ""
  echo "=== test-destroy-orphaned-volumes.sh: PASS=$PASS_COUNT FAIL=$FAILURES (setup aborted) ==="
  exit "$FAILURES"
fi

if volume_exists "$VOL_STATE" && volume_exists "$VOL_HISTORY" && volume_exists "$DECOY_VOL_STATE"; then
  pass "setup: fixture + decoy volumes genuinely exist pre-destroy"
else
  fail "setup: expected all three fixture volumes to exist pre-destroy"
fi

if msb inspect "$CAGE_NAME" --format json >/dev/null 2>&1; then
  fail "setup: unexpectedly found a real sandbox named $CAGE_NAME (fixture must NOT create one)"
else
  pass "setup: no sandbox exists for $CAGE_NAME (simulates an already-removed sandbox)"
fi

# ---------------------------------------------------------------------------
# Case: rc destroy --force against a name whose sandbox is absent but whose
# volumes still exist.
# ---------------------------------------------------------------------------
# swallow-ok(rip-cage-54q3.6.6): status IS read (DESTROY_RC=$? on the next line) and reported -- via fail() at line 118, which increments FAILURES and echoes "FAIL: ..." (this file's own pass/fail test-report convention, not a raw stderr echo) -- so the detector's stderr-anchored shape-(b) heuristic doesn't recognize it even though nothing is silently swallowed.
DESTROY_OUT=$("$RC" destroy --force "$CAGE_NAME" 2>&1)
DESTROY_RC=$?

if [[ "$DESTROY_RC" -eq 0 ]]; then
  pass "rc destroy --force exits 0 against an already-sandbox-absent cage with leftover volumes"
else
  fail "rc destroy --force did not exit 0 (rc=$DESTROY_RC out=$DESTROY_OUT)"
fi

if ! volume_exists "$VOL_STATE"; then
  pass "$VOL_STATE is gone after rc destroy --force"
else
  fail "$VOL_STATE still exists after rc destroy --force"
fi

if ! volume_exists "$VOL_HISTORY"; then
  pass "$VOL_HISTORY is gone after rc destroy --force"
else
  fail "$VOL_HISTORY still exists after rc destroy --force"
fi

# ---------------------------------------------------------------------------
# Negative control: the decoy volume (a DIFFERENT cage name that merely
# shares CAGE_NAME as a prefix) must be UNTOUCHED. A prefix/wildcard "fix"
# (enumerate rc-state-${CAGE_NAME}* and remove matches) would destroy this
# too -- see rip-cage-o5ie's ship-record for the RED demonstration proving
# this assertion has teeth.
# ---------------------------------------------------------------------------
if volume_exists "$DECOY_VOL_STATE"; then
  pass "negative control: $DECOY_VOL_STATE (similar-but-different name) survives rc destroy --force"
else
  fail "negative control: $DECOY_VOL_STATE was destroyed -- destroy is not deriving volume names exactly"
fi

echo ""
echo "=== test-destroy-orphaned-volumes.sh: PASS=$PASS_COUNT FAIL=$FAILURES ==="
exit "$FAILURES"
