#!/usr/bin/env bash
# tests/test-cleanup-failsafe.sh — rip-cage-neu7.9 committed repro test.
#
# INCIDENT CONTEXT (rip-cage-neu7.8, 2026-07-28): a register-array-style
# CLEANUP EXIT trap fired via SIGTERM while mktemp staging vars were still
# EMPTY, and a fragile match degenerated into destroying a live off-limits
# cage. This test locks in the fail-safe SHAPE directly: firing a
# register-array-style CLEANUP with an EMPTY registry (and no staging done
# yet) must destroy NOTHING — not "nothing visibly broke", a hard assertion
# of ZERO destroy-command invocations via a stubbed destroy command.
#
# Exercises tests/_scratch-cage-lib.sh's REAL production `_scratch_cage_cleanup`
# (the exemplar register-array helper, already fail-safe by construction —
# see rip-cage-neu7.9 audit comment on the bead) rather than a copy, so this
# is a genuine regression guard on shipped code, not a description of it.
#
# Stubs the destroy command (a fake `rc` binary that only appends its argv to
# a log file) instead of merely observing "no cage was destroyed" — a stub
# that DID get invoked would still be caught here even if it happened to be a
# no-op in practice, because invocation count is asserted directly.
#
# Pure bash logic, no docker/msb dependency — always runs, no self-skip.
#
# Exit: $FAILURES (silent-red guard per rip-cage-test-fail-prose-without-exit-silent-red).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_LIB="${SCRIPT_DIR}/_scratch-cage-lib.sh"

FAILURES=0
PASS_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== test-cleanup-failsafe.sh ==="

# ----------------------------------------------------------------------------
# Case: firing _scratch_cage_cleanup with an EMPTY registry (no
# scratch_cage_register call ever made — the registry array and the trap
# staging stay at their just-sourced initial state) invokes the destroy
# command ZERO times.
# ----------------------------------------------------------------------------
STUB_DIR=$(mktemp -d)
# _scratch_cage_cleanup destroys via "${SCRIPT_DIR}/../rc destroy --force
# <name>". Point the inner SCRIPT_DIR at a nested dir so that path resolves
# to STUB_DIR/rc — our logging stub, never the real rc.
mkdir -p "${STUB_DIR}/nested"
DESTROY_LOG="${STUB_DIR}/destroy-calls.log"

cat > "${STUB_DIR}/rc" <<STUBEOF
#!/usr/bin/env bash
echo "\$@" >> "${DESTROY_LOG}"
STUBEOF
chmod +x "${STUB_DIR}/rc"

# Fire the CLEANUP function directly with NO scratch_cage_register call --
# _SCRATCH_CAGE_NAMES stays the empty array it's initialized to at source
# time. Run under `set -u` to match the real-world caller (test files source
# this lib under `set -uo pipefail`) — the exact condition under which the
# rip-cage-neu7.8 incident's sibling bug (unbound-variable abort on empty
# array expansion) could otherwise matter. Either a clean empty-loop skip or
# an abort both count as "destroys nothing" -- this asserts the destroy
# command is invoked zero times either way.
bash -c "
  set -u
  SCRIPT_DIR='${STUB_DIR}/nested'
  source '${REAL_LIB}'
  _scratch_cage_cleanup
" >/dev/null 2>&1

if [[ ! -s "$DESTROY_LOG" ]]; then
  pass "empty-registry CLEANUP invokes the destroy command ZERO times"
else
  fail "empty-registry CLEANUP invoked destroy $(wc -l < "$DESTROY_LOG" | tr -d ' ') time(s): $(cat "$DESTROY_LOG")"
fi

rm -rf "$STUB_DIR"

echo ""
echo "=== test-cleanup-failsafe.sh: PASS=$PASS_COUNT FAIL=$FAILURES ==="

exit "$FAILURES"
