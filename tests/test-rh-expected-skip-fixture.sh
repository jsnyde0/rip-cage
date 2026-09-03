#!/usr/bin/env bash
# tests/test-rh-expected-skip-fixture.sh -- rip-cage-pow0 fixture.
#
# PURPOSE: this file exists ONLY to prove run-host.sh's two new ledger
# behaviors against a deterministic, host-only, near-instant probe (no
# docker/msb/live-cage dependency, unlike the real regression probe --
# test-cc-dcg-managed-settings.sh -- that motivated this bead):
#
#   1. A test that exits 0 having printed the repo's "SKIP:" stdout
#      sentinel and NO "PASS"-prefixed line ledgers SKIP, never PASS
#      (rip-cage-pow0 acceptance #1/#4).
#   2. A probe declared EXPECTED-TO-RUN in a given configuration
#      (`--expect-no-skip` / RC_TEST_EXPECT_NO_SKIP) that self-skips
#      instead is itself a FAIL, not a SKIP (rip-cage-pow0's "the part
#      that actually protects coverage" -- a SKIP column alone is
#      cosmetic without this).
#
# This fixture deliberately ALWAYS self-skips -- it has no precondition to
# gate on, unlike a real probe. It is safe to leave wired into the default
# suite: it never touches a container, never mutates anything, and its
# SKIP contributes to TOTALS the same way test-msb-boot-smoke.sh's
# environment-gated self-skip already does today.
#
# Proof commands (see the rip-cage-pow0 ship-record for full evidence):
#   bash tests/run-host.sh --only 'test-rh-expected-skip-fixture.sh' --ledger L
#     -> ledgers SKIP, exit 0
#   bash tests/run-host.sh --only 'test-rh-expected-skip-fixture.sh' \
#       --expect-no-skip 'test-rh-expected-skip-fixture.sh' --ledger L
#     -> ledgers FAIL (reason=expected-no-skip), exit 1

set -uo pipefail

echo "=== test-rh-expected-skip-fixture.sh ==="
echo "SKIP: this fixture has no precondition to satisfy -- it always self-skips (rip-cage-pow0)"
exit 0
