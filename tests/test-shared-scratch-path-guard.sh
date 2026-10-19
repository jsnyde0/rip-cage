#!/usr/bin/env bash
# tests/test-shared-scratch-path-guard.sh -- recurrence guard for
# rip-cage-k13u (golden-master self-check.sh S5 flake).
#
# ROOT CAUSE this guards against: a scratch/backup-file path that is FIXED
# and NON-UNIQUE across concurrent invocations of the same script. Every
# overlapping process writes, reads, and removes the SAME literal path, so
# whoever finishes first deletes it out from under the others -- an
# intermittent race that reproduces on some runs and not others, which is
# worse than a permanent red because the natural response is to re-run
# until green (rip-cage-k13u DESIGN). rip-cage-k13u's audit (comment
# "SHARED-PATH AUDIT, located") found exactly two such sites:
#
#   1. tests/golden-master/self-check.sh -- the under-scrub diff file was
#      the hardcoded literal /tmp/rc-gm-selfcheck-underscrub.diff, written,
#      cat'd and rm -f'd by every concurrent invocation. This is the S5
#      flake (tests/test-golden-master-sandbox-isolation.sh).
#   2. tests/test-rc-commands.sh -- BACKUP_VERSION_FILE was assigned the
#      fixed repo-root literal "${REPO_ROOT}/VERSION.t20bak", colliding the
#      same way when two test-rc-commands.sh runs overlap.
#
# HOST-ONLY: pure static text analysis of the two named files. No docker,
# no msb, no live cage, no network -- passes on a machine with nothing
# installed.
#
# THE RULE (per rip-cage-k13u's audit; this is a NAMED-SITE guard, not a
# general scan, because the audit found and cleared every OTHER fixed path
# under tests/golden-master/ -- self-check.sh:31/32/97's mktemp -d
# templates and :103's ${CANARY_FILE}.bak are already per-invocation):
#
#   (a) tests/golden-master/self-check.sh must not contain the literal
#       fixed path /tmp/rc-gm-selfcheck-underscrub.diff anywhere. The fix
#       is a per-invocation mktemp path (matching the file's own idiom at
#       lines 31/32/97), which never produces this literal string.
#   (b) tests/test-rc-commands.sh's BACKUP_VERSION_FILE assignment line
#       must carry a per-process uniqueness token ($$) rather than a bare
#       fixed literal -- the assignment line is found structurally
#       (`grep 'BACKUP_VERSION_FILE='`, which only matches the one real
#       assignment; every other reference is a read, `"$BACKUP_VERSION_FILE"`,
#       with no `=` immediately after the name).
#
# A MISSING SUBJECT IS A FAILURE, NOT A PASS (rip-cage-b8kd.8.3). Both checks
# above read "clean" when there is nothing to read, so a moved or deleted
# subject file, or a renamed BACKUP_VERSION_FILE, used to pass silently. Case 2
# now requires each named file to exist and (b)'s assignment line to be found
# before it trusts the clean result.
#
# NEGATIVE CONTROL (Case 1 below): a guard with no proof it can fail is
# worthless. Case 1 writes throwaway fixtures with the OFFENDING and FIXED
# shapes into a temp dir and asserts the detector reds on the offending one
# and stays green on the fixed one, before Case 2 runs the real scan.
#
# Exit: $FAILURES (silent-red guard per
# rip-cage-test-fail-prose-without-exit-silent-red).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILURES=0
PASS_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

echo "=== test-shared-scratch-path-guard.sh ==="

# check_selfcheck_underscrub_path <file> -- returns 0 (clean) if <file> does
# NOT contain the fixed literal underscrub-diff path, 1 (offending) if it does.
check_selfcheck_underscrub_path() {
  local f="$1"
  ! grep -qF '/tmp/rc-gm-selfcheck-underscrub.diff' "$f" 2>/dev/null
}

# check_backup_version_file_unique <file> -- returns 0 (clean) if <file>'s
# BACKUP_VERSION_FILE assignment line (if any) carries a per-process
# uniqueness token ($$), 1 (offending) if an assignment exists without one.
# A file with no assignment at all (nothing to check) is also clean.
check_backup_version_file_unique() {
  local f="$1"
  local assign_line
  assign_line=$(grep -n 'BACKUP_VERSION_FILE=' "$f" 2>/dev/null | head -1)
  [[ -z "$assign_line" ]] && return 0
  echo "$assign_line" | grep -qF '$$'
}

# require_subject <file> -- returns 0 if the named subject file exists, 1 if
# it is gone (a moved or deleted subject must never scan as clean).
require_subject() {
  [[ -f "$1" ]]
}

# require_backup_version_assignment <file> -- returns 0 if <file> still holds
# a BACKUP_VERSION_FILE= assignment, 1 if none is found (renamed or removed:
# check (b) would otherwise have nothing to check and read clean).
require_backup_version_assignment() {
  grep -q 'BACKUP_VERSION_FILE=' "$1" 2>/dev/null
}

# ============================================================================
# Case 1: negative control -- the detector must be able to fail.
# ============================================================================
echo ""
echo "--- Case 1: detector self-test (negative control + clean fixtures) ---"

FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-sharedpath-guard-selftest-XXXXXX")
cleanup_fixture() { rm -rf "$FIXTURE_DIR"; }
trap cleanup_fixture EXIT

cat > "${FIXTURE_DIR}/offending-selfcheck.sh" <<'FIXEOF'
#!/usr/bin/env bash
diff -rq "$A" "$B" >/tmp/rc-gm-selfcheck-underscrub.diff 2>&1
cat /tmp/rc-gm-selfcheck-underscrub.diff
rm -f /tmp/rc-gm-selfcheck-underscrub.diff
FIXEOF

cat > "${FIXTURE_DIR}/clean-selfcheck.sh" <<'FIXEOF'
#!/usr/bin/env bash
UNDERSCRUB_DIFF=$(mktemp "${TMPDIR:-/tmp}/rc-gm-selfcheck-underscrub-diff-XXXXXX")
diff -rq "$A" "$B" >"$UNDERSCRUB_DIFF" 2>&1
cat "$UNDERSCRUB_DIFF"
rm -f "$UNDERSCRUB_DIFF"
FIXEOF

cat > "${FIXTURE_DIR}/offending-rc-commands.sh" <<'FIXEOF'
REPO_VERSION_FILE="${REPO_ROOT}/VERSION"
BACKUP_VERSION_FILE="${REPO_ROOT}/VERSION.t20bak"
mv "$REPO_VERSION_FILE" "$BACKUP_VERSION_FILE"
FIXEOF

cat > "${FIXTURE_DIR}/clean-rc-commands.sh" <<'FIXEOF'
REPO_VERSION_FILE="${REPO_ROOT}/VERSION"
BACKUP_VERSION_FILE="${REPO_ROOT}/VERSION.t20bak.$$"
mv "$REPO_VERSION_FILE" "$BACKUP_VERSION_FILE"
FIXEOF

_offending_a_flagged=1
_clean_a_flagged=0
_offending_b_flagged=1
_clean_b_flagged=0

check_selfcheck_underscrub_path "${FIXTURE_DIR}/offending-selfcheck.sh" && _offending_a_flagged=0
check_selfcheck_underscrub_path "${FIXTURE_DIR}/clean-selfcheck.sh" || _clean_a_flagged=1
check_backup_version_file_unique "${FIXTURE_DIR}/offending-rc-commands.sh" && _offending_b_flagged=0
check_backup_version_file_unique "${FIXTURE_DIR}/clean-rc-commands.sh" || _clean_b_flagged=1

if [[ "$_offending_a_flagged" -eq 1 && "$_clean_a_flagged" -eq 0 ]]; then
  pass "negative control: fixed-path detector REDS on the offending fixture and stays clean on the mktemp'd fixture (proves it can fail)"
else
  fail "negative control: fixed-path detector" "offending fixture flagged=$_offending_a_flagged (want 1) clean fixture flagged=$_clean_a_flagged (want 0)"
fi

if [[ "$_offending_b_flagged" -eq 1 && "$_clean_b_flagged" -eq 0 ]]; then
  pass "negative control: BACKUP_VERSION_FILE detector REDS on the fixed-literal fixture and stays clean on the \$\$-suffixed fixture (proves it can fail)"
else
  fail "negative control: BACKUP_VERSION_FILE detector" "offending fixture flagged=$_offending_b_flagged (want 1) clean fixture flagged=$_clean_b_flagged (want 0)"
fi

cat > "${FIXTURE_DIR}/renamed-rc-commands.sh" <<'FIXEOF'
BACKUP_FILE="${REPO_ROOT}/VERSION.t20bak"
FIXEOF

if ! require_subject "${FIXTURE_DIR}/no-such-subject.sh" && require_subject "${FIXTURE_DIR}/clean-selfcheck.sh"; then
  pass "negative control: a missing subject file is caught (it no longer reads as clean)"
else
  fail "negative control: missing-subject check" "a nonexistent path must fail require_subject and an existing one must pass"
fi

if ! require_backup_version_assignment "${FIXTURE_DIR}/renamed-rc-commands.sh" && require_backup_version_assignment "${FIXTURE_DIR}/clean-rc-commands.sh"; then
  pass "negative control: a renamed BACKUP_VERSION_FILE assignment is caught (it no longer reads as clean)"
else
  fail "negative control: missing-assignment check" "a file without BACKUP_VERSION_FILE= must fail and one with it must pass"
fi

rm -rf "$FIXTURE_DIR"
trap - EXIT

# ============================================================================
# Case 2: real scan of the two named sites in the actual repo tree.
# ============================================================================
echo ""
echo "--- Case 2: live scan of the two rip-cage-k13u sites ---"

# RC_SCRATCH_GUARD_SELF_CHECK / RC_SCRATCH_GUARD_RC_COMMANDS repoint the two
# subjects -- the positive control for this guard itself: aimed at a
# nonexistent path, the whole test must exit non-zero naming it.
SELF_CHECK_SH="${RC_SCRATCH_GUARD_SELF_CHECK:-${SCRIPT_DIR}/golden-master/self-check.sh}"
RC_COMMANDS_SH="${RC_SCRATCH_GUARD_RC_COMMANDS:-${SCRIPT_DIR}/test-rc-commands.sh}"

for _subject in "$SELF_CHECK_SH" "$RC_COMMANDS_SH"; do
  if require_subject "$_subject"; then
    pass "subject present: ${_subject}"
  else
    fail "subject missing: ${_subject}" "this guard names that file as a rip-cage-k13u site; a moved or deleted subject cannot be scanned, so it fails rather than reading clean. Re-point the guard at the file's new home, or re-decide the site."
  fi
done

if [[ -f "$RC_COMMANDS_SH" ]] && ! require_backup_version_assignment "$RC_COMMANDS_SH"; then
  fail "no BACKUP_VERSION_FILE= assignment in ${RC_COMMANDS_SH}" "check (b) has nothing to check: the variable was renamed or removed. Re-point the guard at the new name, or re-decide the site."
fi

if check_selfcheck_underscrub_path "$SELF_CHECK_SH"; then
  pass "tests/golden-master/self-check.sh does not contain the fixed shared path /tmp/rc-gm-selfcheck-underscrub.diff"
else
  fail "tests/golden-master/self-check.sh shared-path" "found the fixed literal /tmp/rc-gm-selfcheck-underscrub.diff -- every concurrent invocation writes/reads/rm's the SAME file, so whoever finishes first deletes it out from under the others (rip-cage-k13u S5 flake). Fix: mktemp a per-invocation path, matching this file's own idiom at lines 31/32/97."
fi

# No assignment (or no subject) already FAILed above; check_backup_version_file_unique
# reads that case as clean, so it must not print a PASS (rip-cage-b8kd.44).
if ! require_backup_version_assignment "$RC_COMMANDS_SH"; then
  :
elif check_backup_version_file_unique "$RC_COMMANDS_SH"; then
  pass "${RC_COMMANDS_SH}'s BACKUP_VERSION_FILE carries a per-process uniqueness token"
else
  fail "${RC_COMMANDS_SH} BACKUP_VERSION_FILE" "the assignment is a fixed literal name in the repo root -- two overlapping test-rc-commands.sh runs collide on it (rip-cage-k13u DESIGN: the rsync 'VERSION.t20bak: No such file or directory' symptom). Fix: append a per-process token (e.g. \$\$) to the name."
fi

echo ""
echo "=== test-shared-scratch-path-guard.sh: PASS=$PASS_COUNT FAIL=$FAILURES ==="

exit "$FAILURES"
