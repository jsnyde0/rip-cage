#!/usr/bin/env bash
# Unit/integration tests for tests/run-host.sh's batch-selection + ledger +
# aggregator support (rip-cage-7atw.13).
#
# These tests invoke run-host.sh as a real subprocess (never source it — it
# has top-level side effects). They stay fast/host-only by using --list
# (enumeration only, no test execution) and --dry-run (selection + ledger
# plumbing without executing test bodies) wherever the assertion doesn't
# specifically need a real PASS/FAIL row; a small number of cases DO invoke a
# real, fast, host-only test file (test-doctor-version-skew.sh) to prove the
# ledger captures genuine PASS/FAIL/duration data end-to-end.
#
# Coverage:
#   L1  --list enumerates the driver's full ordered test set (no dupes, count
#       matches an independent grep of run_test/run_pytest call lines)
#   L2  --list is stable across repeated invocations (determinism)
#   B1  --batch K/N over --list partitions deterministically: union of all N
#       slices == the unfiltered --list output, slices pairwise disjoint
#   B2  --batch is stable across repeated invocations of the same slice
#   O1  --only <glob> selects exactly the matching basenames from --list
#   D1  --dry-run + --ledger writes one SKIP(dry-run) row per selected file,
#       no test bodies executed (near-instant)
#   R1  a real --only run against a fast host-only test writes a genuine PASS
#       ledger row with a numeric duration
#   H1  --ledger writes a run-header line stamping commit/image_digest/rc_e2e
#   A1  --ledger-summary unions multiple ledger files against the driver's own
#       enumeration and reports zero PASS/FAIL/SKIP counts with zero never-run
#       files when the batch ledgers are complete
#   A2  RED CONTROL: deleting one file's rows from the ledger union makes
#       --ledger-summary flag that file as NEVER-RUN and exit non-zero
#   F1  run_test's FAIL branch (same awk-extraction idiom as
#       test-doctor-version-skew.sh/test-ls-mode-source.sh): extracts the
#       REAL run_test/_rh_is_selected/_rh_ledger_row/_is_needs_container
#       function bodies and calls run_test against a genuine throwaway
#       always-exits-1 fixture script -- proves the FAIL row + FAILED_TESTS
#       bookkeeping without needing a real suite test to fail on demand.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_HOST="${SCRIPT_DIR}/run-host.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- L1: --list enumerates the full ordered set; count matches an
# independent grep of the top-level run_test/run_pytest call lines in
# run-host.sh (independent source of truth -- not the same code path). ---
list_out="$(bash "$RUN_HOST" --list 2>/tmp/rh_l1_err.txt)"
list_rc=$?
expected_count="$(grep -cE '^[[:space:]]*run_test |^[[:space:]]*run_pytest ' "$RUN_HOST")"
actual_count="$(printf '%s\n' "$list_out" | grep -c .)"
dup_count="$(printf '%s\n' "$list_out" | sort | uniq -d | grep -c . || true)"
if [[ "$list_rc" -eq 0 && "$actual_count" == "$expected_count" && "$dup_count" -eq 0 ]]; then
  pass "L1 --list enumerates the full ordered set ($actual_count entries, matches independent grep count, no dupes)"
else
  fail "L1 --list enumerates the full ordered set" "rc=$list_rc actual=$actual_count expected=$expected_count dupes=$dup_count stderr=$(cat /tmp/rh_l1_err.txt)"
fi

# --- L2: --list is deterministic across repeated invocations ---
list_out2="$(bash "$RUN_HOST" --list 2>/dev/null)"
if [[ "$list_out" == "$list_out2" ]]; then
  pass "L2 --list is stable/deterministic across repeated invocations"
else
  fail "L2 --list is stable/deterministic across repeated invocations" "two invocations produced different output"
fi

# --- B1: --batch K/N partitions the full enumeration completely and
# disjointly. Uses N=5 (does not evenly divide 111) to exercise the
# remainder case. ---
: > "$WORKDIR/union.txt"
disjoint_ok=true
for k in 1 2 3 4 5; do
  slice="$(bash "$RUN_HOST" --batch "${k}/5" --list 2>/dev/null)"
  printf '%s\n' "$slice" >> "$WORKDIR/union.txt"
  printf '%s\n' "$slice" > "$WORKDIR/slice_${k}.txt"
done
sort "$WORKDIR/union.txt" | grep . > "$WORKDIR/union_sorted.txt"
printf '%s\n' "$list_out" | sort > "$WORKDIR/full_sorted.txt"
if diff -q "$WORKDIR/union_sorted.txt" "$WORKDIR/full_sorted.txt" >/dev/null 2>&1; then
  pass "B1 union of --batch 1/5..5/5 == unfiltered --list (completeness)"
else
  fail "B1 union of --batch 1/5..5/5 == unfiltered --list (completeness)" "$(diff "$WORKDIR/union_sorted.txt" "$WORKDIR/full_sorted.txt" | head -5)"
fi
for a in 1 2 3 4 5; do
  for b in 1 2 3 4 5; do
    [[ "$a" -ge "$b" ]] && continue
    overlap="$(comm -12 <(sort "$WORKDIR/slice_${a}.txt") <(sort "$WORKDIR/slice_${b}.txt") | grep -c . || true)"
    if [[ "$overlap" -ne 0 ]]; then
      disjoint_ok=false
    fi
  done
done
if $disjoint_ok; then
  pass "B1b --batch slices are pairwise disjoint"
else
  fail "B1b --batch slices are pairwise disjoint" "found overlapping basenames between slices"
fi

# --- B2: same K/N is stable across repeated invocations ---
slice_1_again="$(bash "$RUN_HOST" --batch 2/5 --list 2>/dev/null)"
if [[ "$slice_1_again" == "$(cat "$WORKDIR/slice_2.txt")" ]]; then
  pass "B2 --batch 2/5 is stable/deterministic across repeated invocations"
else
  fail "B2 --batch 2/5 is stable/deterministic across repeated invocations" "slice changed between invocations"
fi

# --- O1: --only <glob> selects exactly the matching basenames ---
only_out="$(bash "$RUN_HOST" --only 'test-ssh-*.sh' --list 2>/dev/null)"
expected_only="$(printf '%s\n' "$list_out" | grep -E '^test-ssh-.*\.sh$' | sort)"
actual_only="$(printf '%s\n' "$only_out" | sort)"
if [[ "$actual_only" == "$expected_only" && -n "$actual_only" ]]; then
  pass "O1 --only 'test-ssh-*.sh' selects exactly the matching basenames"
else
  fail "O1 --only 'test-ssh-*.sh' selects exactly the matching basenames" "expected=[$expected_only] actual=[$actual_only]"
fi

# --- D1: --dry-run + --ledger writes one SKIP(dry-run) row per selected
# file, near-instant (no test body executed). Uses --batch 1/20 to keep the
# selected subset small. ---
dry_ledger="$WORKDIR/dry.ledger"
dry_selected="$(bash "$RUN_HOST" --batch 1/20 --list 2>/dev/null)"
bash "$RUN_HOST" --batch 1/20 --dry-run --ledger "$dry_ledger" >/dev/null 2>&1
dry_rc=$?
dry_rows="$(grep -vc '^#' "$dry_ledger" 2>/dev/null || echo 0)"
expected_dry_rows="$(printf '%s\n' "$dry_selected" | grep -c .)"
dry_all_skip="$(awk -F'|' '!/^#/ && $2 != "SKIP" {c++} END{print c+0}' "$dry_ledger")"
dry_all_reason="$(awk -F'|' '!/^#/ && $4 != "dry-run" {c++} END{print c+0}' "$dry_ledger")"
if [[ "$dry_rc" -eq 0 && "$dry_rows" == "$expected_dry_rows" && "$dry_all_skip" -eq 0 && "$dry_all_reason" -eq 0 ]]; then
  pass "D1 --dry-run --ledger writes one SKIP(dry-run) row per selected file ($dry_rows rows)"
else
  fail "D1 --dry-run --ledger writes one SKIP(dry-run) row per selected file" "rc=$dry_rc rows=$dry_rows expected=$expected_dry_rows non-skip=$dry_all_skip bad-reason=$dry_all_reason"
fi

# --- H1: --ledger writes a run-header line stamping commit/image_digest/rc_e2e ---
header_line="$(grep '^#RUN' "$dry_ledger" | head -1)"
current_commit="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
if [[ "$header_line" == *"commit=${current_commit}"* && "$header_line" == *"image_digest="* && "$header_line" == *"rc_e2e="* && "$header_line" == *"timestamp="* ]]; then
  pass "H1 ledger run-header stamps commit/image_digest/rc_e2e/timestamp"
else
  fail "H1 ledger run-header stamps commit/image_digest/rc_e2e/timestamp" "header=[$header_line]"
fi

# --- P2: REGRESSION. With RC_TEST_STAMP_COMMIT/RC_TEST_STAMP_IMAGE_DIGEST
# unset, header stamping must be byte-identical to today's auto-derivation:
# commit == real `git rev-parse HEAD`, image_digest == real `docker image
# inspect`. `env -u` guards against the pin vars leaking in from this
# harness's own environment. ---
independent_commit="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
independent_digest=""
if command -v docker >/dev/null 2>&1; then
  independent_digest="$(docker image inspect --format '{{.Id}}' rip-cage:latest 2>/dev/null || true)"
fi
[[ -z "$independent_digest" ]] && independent_digest="unavailable"
env -u RC_TEST_STAMP_COMMIT -u RC_TEST_STAMP_IMAGE_DIGEST \
  bash "$RUN_HOST" --only 'test-doctor-version-skew.sh' --dry-run --ledger "$WORKDIR/p2_ledger" >/dev/null 2>&1
p2_header="$(grep '^#RUN' "$WORKDIR/p2_ledger")"
if [[ "$p2_header" == *"commit=${independent_commit}"* && "$p2_header" == *"image_digest=${independent_digest}"* ]]; then
  pass "P2 REGRESSION: pin env vars unset -> header stamping unchanged (auto-derived commit + image_digest)"
else
  fail "P2 REGRESSION: pin env vars unset -> header stamping unchanged (auto-derived commit + image_digest)" "header=[$p2_header] expected_commit=$independent_commit expected_digest=$independent_digest"
fi

# --- P1: RC_TEST_STAMP_COMMIT / RC_TEST_STAMP_IMAGE_DIGEST pin the header
# stamps VERBATIM, bypassing per-invocation auto-derivation entirely. This
# is what lets the .14 multi-hour batched baseline capture stay coherent
# even though a concurrent session commits to main mid-run (moving the
# auto-derived commit) and rip-cage:latest may be rebuilt (moving the
# auto-derived image_digest) between batches. Simulated here via an
# obviously-fake pinned value that can never coincide with the real
# auto-derived commit (independently captured first, for contrast) --
# stronger evidence than mutating real git HEAD, and it does not touch the
# shared repo's history (a concurrent session is actively committing here). ---
real_commit_for_contrast="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
pinned_commit="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
pinned_digest="sha256:pinnedpinnedpinnedpinnedpinnedpinnedpinnedpinnedpinnedpinnedpin0"
if [[ "$pinned_commit" == "$real_commit_for_contrast" ]]; then
  fail "P1 fixture sanity" "pinned_commit fixture collided with the real HEAD -- pick a different fake sha"
else
  : > "$WORKDIR/p1_l1"
  : > "$WORKDIR/p1_l2"
  RC_TEST_STAMP_COMMIT="$pinned_commit" RC_TEST_STAMP_IMAGE_DIGEST="$pinned_digest" \
    bash "$RUN_HOST" --batch 1/2 --dry-run --ledger "$WORKDIR/p1_l1" >/dev/null 2>&1
  RC_TEST_STAMP_COMMIT="$pinned_commit" RC_TEST_STAMP_IMAGE_DIGEST="$pinned_digest" \
    bash "$RUN_HOST" --batch 2/2 --dry-run --ledger "$WORKDIR/p1_l2" >/dev/null 2>&1
  p1_h1="$(grep '^#RUN' "$WORKDIR/p1_l1")"
  p1_h2="$(grep '^#RUN' "$WORKDIR/p1_l2")"
  p1_out="$(bash "$RUN_HOST" --ledger-summary "$WORKDIR/p1_l1" "$WORKDIR/p1_l2" 2>&1)"
  p1_rc=$?
  if [[ "$p1_h1" == *"commit=${pinned_commit}"* && "$p1_h1" == *"image_digest=${pinned_digest}"* \
     && "$p1_h2" == *"commit=${pinned_commit}"* && "$p1_h2" == *"image_digest=${pinned_digest}"* \
     && "$p1_rc" -eq 0 ]] \
     && ! printf '%s\n' "$p1_out" | grep -qi 'incoherent'; then
    pass "P1 pinned stamps: every header carries the exact pinned values; union coherent despite would-be-differing auto-derivation"
  else
    fail "P1 pinned stamps: every header carries the exact pinned values; union coherent despite would-be-differing auto-derivation" "h1=[$p1_h1] h2=[$p1_h2] rc=$p1_rc out=$p1_out"
  fi
fi

# --- R1: a real (non-dry) run against a fast host-only test writes a
# genuine PASS row with a numeric duration. test-doctor-version-skew.sh is a
# pure _doctor_bd_version_compare unit test (no docker needed), confirmed
# PASS in isolation as part of this same change. ---
real_ledger="$WORKDIR/real.ledger"
bash "$RUN_HOST" --only 'test-doctor-version-skew.sh' --ledger "$real_ledger" >/tmp/rh_r1_out.txt 2>&1
real_rc=$?
real_row="$(grep -v '^#' "$real_ledger" | grep '^test-doctor-version-skew.sh|')"
if [[ "$real_rc" -eq 0 && "$real_row" == test-doctor-version-skew.sh\|PASS\|*  ]]; then
  dur_field="$(printf '%s' "$real_row" | awk -F'|' '{print $3}')"
  if [[ "$dur_field" =~ ^[0-9]+$ ]]; then
    pass "R1 real run writes a genuine PASS row with numeric duration (row=$real_row)"
  else
    fail "R1 real run writes a genuine PASS row with numeric duration" "duration field not numeric: [$dur_field] row=[$real_row]"
  fi
else
  fail "R1 real run writes a genuine PASS row with numeric duration" "rc=$real_rc row=[$real_row] driver_output=$(cat /tmp/rh_r1_out.txt)"
fi

# --- A1: --ledger-summary unions batch ledgers against the driver's own
# full enumeration; zero PASS/FAIL/SKIP counts with zero never-run files
# when the batch union is complete. Built via 4 --dry-run batch slices
# (sanctioned fast route -- no need to execute the whole suite for real to
# prove union-completeness/zero-row detection). ---
# Derived, not hardcoded: the total enumeration count comes from --list
# itself (already independently cross-checked against a grep of run_test/
# run_pytest call lines by L1 above). Asserting against a literal here would
# break every time a test file is added/removed elsewhere in the suite (as
# happened: a concurrent bead wired 2 more files in, 111 -> 113) and would
# train maintainers to just bump the magic number -- exactly how a real
# never-run regression later goes unnoticed. ---
total_enum="$(printf '%s\n' "$list_out" | grep -c .)"

: > "$WORKDIR/a1_l1"
: > "$WORKDIR/a1_l2"
bash "$RUN_HOST" --batch 1/4 --dry-run --ledger "$WORKDIR/a1_l1" >/dev/null 2>&1
bash "$RUN_HOST" --batch 2/4 --dry-run --ledger "$WORKDIR/a1_l1" >/dev/null 2>&1
bash "$RUN_HOST" --batch 3/4 --dry-run --ledger "$WORKDIR/a1_l2" >/dev/null 2>&1
bash "$RUN_HOST" --batch 4/4 --dry-run --ledger "$WORKDIR/a1_l2" >/dev/null 2>&1
summary_out="$(bash "$RUN_HOST" --ledger-summary "$WORKDIR/a1_l1" "$WORKDIR/a1_l2" 2>&1)"
summary_rc=$?
if [[ "$summary_rc" -eq 0 ]] && printf '%s\n' "$summary_out" | grep -qE "^TOTALS: PASS=0 FAIL=0 SKIP=${total_enum} ZERO=0 MALFORMED=0 ENUMERATED=${total_enum}\$"; then
  pass "A1 --ledger-summary over a complete 4-way batch union: ZERO=0, all ${total_enum} accounted for"
else
  fail "A1 --ledger-summary over a complete 4-way batch union: ZERO=0, all ${total_enum} accounted for" "rc=$summary_rc totals_line=$(printf '%s\n' "$summary_out" | grep '^TOTALS')"
fi

# --- A2: RED CONTROL. Delete one file's rows from the ledger union (a
# genuinely batched real ledger, not a synthetic fixture) -- the aggregator
# must flag that file as NEVER-RUN and exit non-zero. This is the
# completeness harness the bead's design calls out explicitly. ---
victim="$(grep -v '^#' "$WORKDIR/a1_l2" | head -1 | awk -F'|' '{print $1}')" # a file actually present in a1_l2's rows
grep -v "^${victim}|" "$WORKDIR/a1_l2" > "$WORKDIR/a1_l2_redacted"
red_summary_out="$(bash "$RUN_HOST" --ledger-summary "$WORKDIR/a1_l1" "$WORKDIR/a1_l2_redacted" 2>&1)"
red_summary_rc=$?
skip_after_removal=$((total_enum - 1))
if [[ "$red_summary_rc" -ne 0 ]] \
   && printf '%s\n' "$red_summary_out" | grep -qF "ZERO-ROW: ${victim}" \
   && printf '%s\n' "$red_summary_out" | grep -qE "^TOTALS: PASS=0 FAIL=0 SKIP=${skip_after_removal} ZERO=1 MALFORMED=0 ENUMERATED=${total_enum}\$"; then
  pass "A2 RED CONTROL: deleting ${victim}'s rows makes --ledger-summary flag it NEVER-RUN and exit non-zero"
else
  fail "A2 RED CONTROL: deleting ${victim}'s rows makes --ledger-summary flag it NEVER-RUN and exit non-zero" "rc=$red_summary_rc victim=$victim output=$red_summary_out"
fi

# --- A3: RED CONTROL. A batched real-world run can land its slices at
# DIFFERENT commits/images/RC_E2E postures (a multi-hour kill-resumable run
# -- exactly rip-cage-7atw.14's baseline capture shape). A union that is
# file-complete (ZERO=0) but stamped from incoherent runs is NOT a valid
# single-revision baseline and must not silently report success. Mutate one
# ledger's real run-header commit to a different (fake) value and confirm
# the aggregator detects and reports the divergence, exiting non-zero even
# though every file has a row. ---
: > "$WORKDIR/a3_l1"
: > "$WORKDIR/a3_l2"
bash "$RUN_HOST" --batch 1/2 --dry-run --ledger "$WORKDIR/a3_l1" >/dev/null 2>&1
bash "$RUN_HOST" --batch 2/2 --dry-run --ledger "$WORKDIR/a3_l2" >/dev/null 2>&1
sed -i.bak 's/^#RUN commit=[^ ]*/#RUN commit=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "$WORKDIR/a3_l2"
a3_out="$(bash "$RUN_HOST" --ledger-summary "$WORKDIR/a3_l1" "$WORKDIR/a3_l2" 2>&1)"
a3_rc=$?
# The incoherence warning must not swallow the rest of the report -- the
# per-file completeness table + TOTALS line still need to print alongside
# it, so an operator sees BOTH "which files ran" and "why this isn't a
# valid single-revision baseline" in one report.
if [[ "$a3_rc" -ne 0 ]] \
   && printf '%s\n' "$a3_out" | grep -qi 'incoherent' \
   && printf '%s\n' "$a3_out" | grep -q 'commit' \
   && printf '%s\n' "$a3_out" | grep -q 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' \
   && printf '%s\n' "$a3_out" | grep -q '^TOTALS: '; then
  pass "A3 RED CONTROL: divergent commit stamps across a file-complete union -> flagged incoherent + non-zero exit, table still shown"
else
  fail "A3 RED CONTROL: divergent commit stamps across a file-complete union -> flagged incoherent + non-zero exit, table still shown" "rc=$a3_rc output=$a3_out"
fi

# --- A4: sanity companion to A3 -- SAME commit/image/rc_e2e stamps (the
# normal case, e.g. A1's batches) must NOT be flagged incoherent. Guards
# against A3's fix being overzealous (e.g. flagging on any multi-line
# header rather than on genuine value divergence). ---
a4_out="$(bash "$RUN_HOST" --ledger-summary "$WORKDIR/a1_l1" "$WORKDIR/a1_l2" 2>&1)"
if ! printf '%s\n' "$a4_out" | grep -qi 'incoherent'; then
  pass "A4 coherent (same-commit) union is NOT flagged incoherent"
else
  fail "A4 coherent (same-commit) union is NOT flagged incoherent" "output=$a4_out"
fi

# --- I1: RED CONTROL for the ACTUAL mac-mini kill failure mode (not just
# "file missing"). Append-resume after a mid-write SIGTERM can tear the
# FINAL row of a ledger file: the row's content lands but its trailing
# newline doesn't (no fsync boundary between them), so the NEXT invocation's
# "#RUN ..." header concatenates directly onto the same line. Reproduce
# this exactly: two REAL single-row ledgers, then splice header #2 onto the
# end of row #1's line (no separating newline) -- the shape a torn write
# actually leaves on disk. The aggregator must DETECT this as malformed
# (not silently accept the glued line as a normal SKIP row via a merely
# NF>=4 check, and not silently vanish it either). ---
bash "$RUN_HOST" --only 'test-doctor-version-skew.sh' --dry-run --ledger "$WORKDIR/i1_l1" >/dev/null 2>&1
bash "$RUN_HOST" --only 'test-doctor-version-skew.sh' --dry-run --ledger "$WORKDIR/i1_l2" >/dev/null 2>&1
row1="$(grep -v '^#' "$WORKDIR/i1_l1")"      # command substitution strips the trailing newline
header2="$(grep '^#RUN' "$WORKDIR/i1_l2")"
row2="$(grep -v '^#' "$WORKDIR/i1_l2")"
{
  grep '^#RUN' "$WORKDIR/i1_l1"           # header #1, intact
  printf '%s%s\n' "$row1" "$header2"      # TORN: row1 + header2 glued onto ONE line
  printf '%s\n' "$row2"                   # row2 resumes normally on its own line
} > "$WORKDIR/i1_torn"
i1_out="$(bash "$RUN_HOST" --ledger-summary "$WORKDIR/i1_torn" 2>&1)"
i1_rc=$?
if [[ "$i1_rc" -ne 0 ]] \
   && printf '%s\n' "$i1_out" | grep -qi 'malformed' \
   && printf '%s\n' "$i1_out" | grep -q 'test-doctor-version-skew.sh'; then
  pass "I1 RED CONTROL: a torn (no-newline, header-glued) row is detected as malformed, not silently accepted or vanished"
else
  fail "I1 RED CONTROL: a torn (no-newline, header-glued) row is detected as malformed, not silently accepted or vanished" "rc=$i1_rc output=$i1_out"
fi

# --- G1: basename-collision guard. If the SAME basename appears more than
# once across the unioned ledgers (e.g. two overlapping/misconfigured
# batches both ran it), the aggregator must count it exactly ONCE in
# TOTALS -- using the LATEST row deterministically -- not double-count it
# or silently average/concatenate conflicting statuses. (The complementary
# guard against a duplicate basename in the driver's OWN enumeration is L1's
# no-dupes check on --list output above.) ---
: > "$WORKDIR/coll_ledger"
bash "$RUN_HOST" --only 'test-doctor-version-skew.sh' --dry-run --ledger "$WORKDIR/coll_ledger" >/dev/null 2>&1
printf 'test-doctor-version-skew.sh|FAIL|7||2026-01-01T00:00:00Z\n' >> "$WORKDIR/coll_ledger"
coll_out="$(bash "$RUN_HOST" --ledger-summary "$WORKDIR/coll_ledger" 2>&1)"
if printf '%s\n' "$coll_out" | grep -q '^test-doctor-version-skew.sh: FAIL' \
   && printf '%s\n' "$coll_out" | grep -qE '^TOTALS: PASS=0 FAIL=1 '; then
  pass "G1 basename collision: same file appearing twice is counted once, latest row wins"
else
  fail "G1 basename collision: same file appearing twice is counted once, latest row wins" "output=$coll_out"
fi

# --- F1: run_test's FAIL branch, exercised via the REAL extracted function
# bodies (same idiom as test-doctor-version-skew.sh) against a genuine
# throwaway always-fails fixture. Proves the FAIL row + FAILED_TESTS
# bookkeeping without relying on some real suite test happening to fail. ---
_extract_fn() {
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { found=1 }
    found { print }
    found && /^}$/ { exit }
  ' "$RUN_HOST"
}
# shellcheck disable=SC1090  # dynamically extracted from run-host.sh, not a static path
eval "$(_extract_fn _is_needs_container)"
# shellcheck disable=SC1090
eval "$(_extract_fn _rh_matches_only)"
# shellcheck disable=SC1090
eval "$(_extract_fn _rh_is_selected)"
# shellcheck disable=SC1090
eval "$(_extract_fn _rh_ledger_row)"
# shellcheck disable=SC1090
eval "$(_extract_fn run_test)"

if ! declare -F run_test >/dev/null 2>&1; then
  fail "F1 run_test FAIL branch writes a FAIL row + records FAILED_TESTS" "run_test not found after extraction -- awk pattern drifted from run-host.sh"
else
  # shellcheck disable=SC2034  # read by the dynamically eval'd run_test/_rh_* bodies above, invisible to static analysis
  FAILED_TESTS=()
  # shellcheck disable=SC2034
  NEEDS_CONTAINER=()
  # shellcheck disable=SC2034
  HOST_ONLY_MODE=false
  # shellcheck disable=SC2034
  RH_DRY_RUN=false
  # shellcheck disable=SC2034
  RH_BATCH_N=""
  # shellcheck disable=SC2034
  RH_ONLY_FILTER=""
  # shellcheck disable=SC2034
  RH_LEDGER_PATH="$WORKDIR/fail.ledger"
  _RH_MODE="run"
  _RH_CALL_INDEX=0
  printf '#!/usr/bin/env bash\nexit 1\n' > "$WORKDIR/always-fail.sh"
  chmod +x "$WORKDIR/always-fail.sh"
  run_test "$WORKDIR/always-fail.sh"
  fail_row="$(grep -v '^#' "$WORKDIR/fail.ledger" | grep '^always-fail.sh|')"
  recorded="${FAILED_TESTS[*]:-}"
  if [[ "$fail_row" == always-fail.sh\|FAIL\|*  && "$recorded" == *"always-fail.sh"* ]]; then
    pass "F1 run_test FAIL branch writes a FAIL row + records FAILED_TESTS (row=$fail_row)"
  else
    fail "F1 run_test FAIL branch writes a FAIL row + records FAILED_TESTS" "row=[$fail_row] FAILED_TESTS=[$recorded]"
  fi
fi

echo ""
echo "=== run-host-driver tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
