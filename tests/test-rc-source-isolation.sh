#!/usr/bin/env bash
# Host-side tests for rc source-isolation (rip-cage-k2d5).
#
# Coverage:
#   (a) Source-isolation: sourcing rc does NOT force set -e onto the caller shell.
#   (b) Executed-strict: rc run directly exits non-zero on a bad command.
#       (b1) — set -euo pipefail line present in rc (static check).
#       (b2) — direct execution still errors on an unknown subcommand
#              (sanity check: executed path not broken by the guard).
#              Does NOT claim to prove strict mode is active — that proof
#              is (b1) + the predicate-sync check (d) + the full regression suite.
#   (c) Piped-exec: bash -s -- < rc (BASH_SOURCE empty) treated as INVOKED.
#       Discriminating oracle: if piped-exec were WRONGLY classified as sourced,
#       rc:9494's `return 0` would fire at the top level of a non-sourced script
#       and bash would emit "return: can only `return' from a function or sourced
#       script" to stderr. The ABSENCE of that error on stderr is the load-bearing
#       proof that piped-exec is correctly classified as INVOKED, not sourced.
#   (d) Predicate-sync: the guard predicate at rc:5 is textually identical to the
#       dispatch-skip predicate at rc:9494. Drift between the two is the regression
#       this fix must not introduce (acceptance criterion 4).
#
# All assertions are discriminating positive controls — none is vacuous.
# Mirrors test-dcg-policy.sh / test-egress-rules-gen.sh structure.
#
# Note: -e intentionally omitted so individual test failures don't abort the suite.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

echo "=== test-rc-source-isolation.sh — rc source isolation ==="
echo ""

# ---------------------------------------------------------------------------
# (a) Source-isolation: sourcing rc must NOT force -e onto the caller.
#
# Runs in a fresh subshell so the test's own options are not affected.
# We explicitly disable -e before sourcing, then check that it stays off.
# ---------------------------------------------------------------------------
echo "=== (a) Source-isolation: set -e must not leak when sourcing rc ==="

source_isolation_result=$(bash -c '
  set +e
  # shellcheck disable=SC1090
  source "'"$RC"'" 2>/dev/null
  # Check whether the e option is present in the current shell options.
  if [[ "$-" == *e* ]]; then
    echo "LEAKED"
  else
    echo "CLEAN"
  fi
')

if [[ "$source_isolation_result" == "CLEAN" ]]; then
  pass "(a)" "sourcing rc does not force set -e onto caller"
else
  fail "(a)" "sourcing rc forces set -e onto caller" "got: ${source_isolation_result}"
fi

echo ""

# ---------------------------------------------------------------------------
# (b) Executed-strict: rc run directly (executed, not sourced) aborts on error.
#
# (b1) Static check: the guarded set -euo pipefail line is present in rc.
# (b2) Sanity check: direct execution still errors on an unknown subcommand,
#      confirming the guard didn't disable the executed path entirely.
#      NOTE: non-zero exit here is consistent with strict mode being active,
#      but is also what rc's own dispatch exit-1 would produce without it.
#      The genuine "executed path retains strict mode" evidence is (b1) +
#      the predicate-sync check (d) + the full regression suite.
# ---------------------------------------------------------------------------
echo "=== (b) Executed-strict: direct execution and static checks ==="

# (b1) Verify the guarded set -euo pipefail line is present in rc.
if grep -q 'set -euo pipefail' "$RC"; then
  pass "(b1)" "set -euo pipefail line present in rc"
else
  fail "(b1)" "set -euo pipefail line missing from rc" "check rc header"
fi

# (b2) Invoke rc with an unknown subcommand — must exit non-zero.
# Sanity check: executed path not broken by the guard (does NOT prove strict mode active).
exec_exit=0
bash "$RC" __no_such_command_k2d5__ 2>/dev/null
exec_exit=$?
if [[ $exec_exit -ne 0 ]]; then
  pass "(b2)" "direct execution of rc exits non-zero on invalid command (executed path functional)"
else
  fail "(b2)" "direct execution of rc exited 0 on invalid command (executed path broken)" "exit=$exec_exit"
fi

echo ""

# ---------------------------------------------------------------------------
# (c) Piped-exec: bash -s -- < rc (BASH_SOURCE empty) treated as INVOKED.
#
# Discriminating oracle: if the piped-exec path were WRONGLY classified as
# sourced, then rc:9494's `return 0` would execute at the top level of a
# non-sourced (piped) script. Bash emits the error:
#   "bash: line N: return: can only `return' from a function or sourced script"
# to stderr in that case. The ABSENCE of "can only" / "return" on stderr is
# the load-bearing proof that piped-exec is correctly classified as INVOKED.
#
# We also keep the non-zero-exit check as a secondary sanity check.
# ---------------------------------------------------------------------------
echo "=== (c) Piped-exec: bash -s -- < rc treats BASH_SOURCE-empty as INVOKED ==="

# Capture stderr to check for the "return from non-sourced" error.
piped_stderr=$(bash -s -- __no_such_command_k2d5__ < "$RC" 2>&1 >/dev/null)
piped_exit=$?

# Primary discriminating oracle: stderr must NOT contain the "can only `return'"
# error that bash emits when `return` is called at the top level of a non-sourced script.
if echo "$piped_stderr" | grep -q "can only"; then
  fail "(c1)" "piped-exec stderr contains 'can only' — piped-exec wrongly classified as sourced (return fired at top level)" "stderr: ${piped_stderr}"
else
  pass "(c1)" "piped-exec stderr does not contain 'can only' — piped-exec correctly classified as INVOKED (not sourced)"
fi

# Secondary check: should still exit non-zero (bad command).
if [[ $piped_exit -ne 0 ]]; then
  pass "(c2)" "piped-exec (BASH_SOURCE empty) exits non-zero — dispatch reached and errors on unknown command"
else
  fail "(c2)" "piped-exec (BASH_SOURCE empty) exited 0 — dispatch may have been skipped" "exit=$piped_exit"
fi

echo ""

# ---------------------------------------------------------------------------
# (d) Predicate-sync: the guard predicate at rc:2 (header) must be textually
#     identical to the dispatch-skip predicate at rc:9494. If they drift apart,
#     the sourced-vs-invoked classification could diverge between the two sites.
#
#     We extract the common substring from each line and assert both are present.
#     The canonical substring is: [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "${0}" ]]
# ---------------------------------------------------------------------------
echo "=== (d) Predicate-sync: rc:2 guard identical to rc:9494 dispatch-skip ==="

# shellcheck disable=SC2016  # single quotes intentional: we want the literal string for grep -F
PREDICATE='[[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "${0}" ]]'

# Count occurrences of the canonical predicate substring in rc.
predicate_count=$(grep -cF "$PREDICATE" "$RC")

if [[ "$predicate_count" -ge 2 ]]; then
  pass "(d)" "canonical predicate appears in both the rc:2 guard and rc:9494 dispatch-skip (count=${predicate_count})"
else
  fail "(d)" "canonical predicate does not appear in both guard sites (count=${predicate_count})" \
    "expected >=2 occurrences of: ${PREDICATE}"
fi

echo ""

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit "$FAILURES"
fi
