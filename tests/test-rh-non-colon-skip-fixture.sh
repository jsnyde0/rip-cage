#!/usr/bin/env bash
# tests/test-rh-non-colon-skip-fixture.sh -- rip-cage-pow0 round-2 fixture.
#
# PURPOSE: round 1 of rip-cage-pow0 detected a self-skip only via the exact
# "^SKIP:" stdout sentinel. That missed every other self-skip spelling
# actually in use in tests/ -- "SKIP (NEEDS_CONTAINER / RC_E2E): ...",
# "SKIP (reserved-scratch): ...", "SKIP C6: ...", etc (round 2's
# blast-radius measurement found 21 affected files, e.g.
# test-mount-mode-e2e.sh). Round 2 widened run-host.sh's match to
# '^SKIP[[:space:]:(]' so it also catches these.
#
# This fixture is deterministic, host-only, near-instant (no docker/msb/
# live-cage dependency) proof that the WIDENED match -- not just the
# original "SKIP:" one -- classifies a whole-file self-skip as SKIP, never
# PASS. It deliberately uses the "SKIP (...)" parenthesised spelling (no
# colon directly after "SKIP") and prints zero "PASS"-prefixed lines.
#
# This fixture deliberately ALWAYS self-skips -- it has no precondition to
# gate on. It is safe to leave wired into the default suite: it never
# touches a container, never mutates anything.
#
# Proof command (see the rip-cage-pow0 round-2 ship-record for full
# before/after evidence against the widened match):
#   bash tests/run-host.sh --only 'test-rh-non-colon-skip-fixture.sh' --ledger L
#     -> ledgers SKIP, exit 0 (would have ledgered PASS under round 1's
#        '^SKIP:'-only match, since this line has no colon right after SKIP)

set -uo pipefail

echo "=== test-rh-non-colon-skip-fixture.sh ==="
echo "SKIP (NEEDS_CONTAINER / RC_E2E): this fixture always self-skips via a non-colon sentinel spelling (rip-cage-pow0 round 2)"
exit 0
