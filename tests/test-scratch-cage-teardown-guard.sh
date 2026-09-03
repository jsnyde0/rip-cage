#!/usr/bin/env bash
# shellcheck disable=SC2016
# (file-wide: every `tr -d '${}'` below intentionally uses single quotes to
# delete literal $ { } characters from an already-extracted var reference --
# there is nothing to expand.)
#
# tests/test-scratch-cage-teardown-guard.sh -- recurrence guard for
# rip-cage-4cuh / rip-cage-22hn / rip-cage-qg25.
#
# ROOT CAUSE this guards against (rip-cage-4cuh NOTES, 2026-09-03 audit):
# ~18 test files tear their cage down with a bare `msb remove --force` and
# NEVER call `msb volume remove` or route through `rc destroy` -- the cage
# disappears but its two named volumes (rc-state-<name>, rc-history-<name>)
# survive forever. `rc destroy --force` against a still-live cage DOES reap
# both volumes (cli/down_destroy.sh's volume-deletion loop), so the fix is
# pure ADOPTION of tests/_scratch-cage-lib.sh (or an explicit paired
# `msb volume remove`) across the leaking files -- this test is the
# recurrence guard that makes that adoption stick.
#
# HOST-ONLY: pure static text analysis of tests/*.sh. No docker, no msb, no
# live cage, no network -- passes on a machine with nothing installed.
#
# THE RULE (enforced per `msb remove` call-site found in a file, never a
# file allowlist -- rip-cage-4cuh explicitly forbids re-creating an
# exception list here): a line that invokes `msb remove` on a cage name is
# a LEAK unless the SAME FILE also, for that same call:
#   (a) registers the cage via `scratch_cage_register <name>`
#       (tests/_scratch-cage-lib.sh -- its EXIT/INT/TERM trap runs
#       `rc destroy --force`, which DOES reap both named volumes), or
#   (b) tears the SAME variable down via `<rc-wrapper> destroy --force VAR`
#       instead of/in addition to `msb remove` (rc destroy's own
#       volume-deletion loop reaps it), or
#   (c) pairs the SAME variable's volumes explicitly: an
#       `msb volume remove "rc-state-$VAR" ...` / "rc-history-$VAR" call
#       appears anywhere in the file, or
#   (d) has its OWN working EXIT-trap volume-reap safety net: the file
#       both registers an EXIT/INT/TERM trap AND contains at least one
#       bespoke `msb volume remove` call somewhere. This is the one
#       file-scoped (not name-matched) fallback, deliberately kept because
#       some bespoke fixtures reap by a volume label the test invented
#       itself (e.g. a disk-kind volume for nested-Docker storage), not by
#       the cage's own name -- rejecting those as "unpaired" would be a
#       false positive on already-correct teardown (rip-cage-4cuh names
#       these "ALREADY CLEAN (bespoke but correctly paired)"). It still
#       requires a REAL teardown mechanism (a live trap) plus REAL evidence
#       of a volume reap somewhere in the same file -- not merely "the word
#       msb appears" -- so it can't be satisfied by prose or an unrelated
#       comment.
#
# FAIL-SAFE CONSTRAINT (tests/test-cleanup-failsafe.sh is the committed
# repro of the incident this rule exists for): this guard is read-only
# static analysis -- it destroys nothing itself -- and its failure message
# below NEVER recommends a wildcard/pattern sweep over rc-state-*/
# rc-history-*. The only two fixes it ever names are "register the cage via
# scratch_cage_register" or "pair the msb remove with an explicit
# msb volume remove by name" -- exactly the two real remedies rip-cage-4cuh
# and rip-cage-qg25 apply.
#
# SCOPE DECISION (tests/spike-uuh9-port443.sh, not wired into run-host.sh):
# it IS included in this scan. The rule targets any `tests/*.sh` file
# carrying the leak pattern, not just files run.host.sh currently executes
# -- excluding it would need a name-based carve-out, which is exactly the
# allowlist shape this guard exists to avoid. A dev running the spike
# manually leaks the same two volumes; the guard should say so.
#
# Exit: $FAILURES (silent-red guard per rip-cage-test-fail-prose-without-exit-silent-red).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILURES=0
PASS_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== test-scratch-cage-teardown-guard.sh ==="

# Real invocation of `msb remove` (any spelling): bare, -f, or --force. Must
# be anchored at a real command-start boundary (line start, or after
# ; & | ( { ` with optional whitespace) so a PROSE mention inside a string
# literal or a comment (e.g. a fail() reason describing the behavior, or a
# doc comment naming `_msb_volume_remove` / `msb remove`) is never mistaken
# for an actual invocation. `msb volume remove` never matches this pattern
# (the word "remove" there is preceded by "volume ", not the boundary set).
MSB_REMOVE_RE='(^[[:space:]]*|[;&|({`][[:space:]]*)msb[[:space:]]+remove([[:space:]]|$)'

# scan_dir_for_leaks <dir> -- populates the LEAK_LINES array (global) with
# one "relpath:line: trimmed-text" entry per offending msb-remove call found
# in <dir>/*.sh. Never touches anything outside plain text reads.
scan_dir_for_leaks() {
  local dir="$1"
  LEAK_LINES=()
  local f
  for f in "$dir"/*.sh; do
    [[ -f "$f" ]] || continue
    _scan_one_file "$f"
  done
}

_scan_one_file() {
  local f="$1"
  local base
  base=$(basename "$f")

  # --- Build this file's tier-1 "reaped variable" registry. ---------------
  local -A reaped=()
  local var

  # (a) scratch_cage_register <var>
  while IFS= read -r var; do
    [[ -n "$var" ]] && reaped["$var"]=1
  done < <(grep -oE 'scratch_cage_register[[:space:]]+.?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' "$f" 2>/dev/null \
             | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | tr -d '${}')

  # (c) msb volume remove "rc-state-$VAR" / "rc-history-${VAR}"
  while IFS= read -r var; do
    [[ -n "$var" ]] && reaped["$var"]=1
  done < <(grep -oE 'rc-(state|history)-\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' "$f" 2>/dev/null \
             | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | tr -d '${}')

  # (b) <wrapper> destroy [--force] "$VAR" (rc / run_rc / $RC destroy) --
  # ORDER-SENSITIVE (rip-cage-4cuh's own hypothesized-but-secondary
  # mechanism, confirmed live in test-rc-reload.sh / test-up-converge.sh
  # while building this guard): `rc destroy` only reaps volumes when the
  # msb sandbox is STILL PRESENT (cli/down_destroy.sh's volume-deletion
  # loop runs after a presence check; CONTAINER_NOT_FOUND exits loud
  # BEFORE it). A `destroy --force $VAR` call AFTER a bare `msb remove
  # $VAR` already ran is a no-op for volumes -- the cage is already gone.
  # So this only counts as pairing for an `msb remove` occurrence at line
  # L if a destroy call for the SAME var exists at a line strictly BEFORE
  # L (destroy reaped a still-live cage; the later bare remove is
  # redundant cleanup of an already-volumeless situation, not a leak).
  # `msb volume remove` (tier (c) above) has no such hazard -- it acts on
  # the volume directly, independent of cage presence.
  local -A destroy_first_line=()
  while IFS=: read -r _dline _dtext; do
    var=$(echo "$_dtext" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | head -1 | tr -d '${}')
    [[ -z "$var" ]] && continue
    if [[ -z "${destroy_first_line[$var]:-}" || "$_dline" -lt "${destroy_first_line[$var]}" ]]; then
      destroy_first_line["$var"]="$_dline"
    fi
  done < <(grep -nE 'destroy([[:space:]]+--force)?[[:space:]]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?' "$f" 2>/dev/null)

  # --- (d) file-scoped fallback precondition: a live EXIT/INT/TERM trap ---
  # AND at least one real (non-comment, non-prose) msb-volume-remove call
  # somewhere in the file.
  local has_trap=0 has_vol_remove=0
  grep -qE '(^[[:space:]]*|[;&|({`][[:space:]]*)trap[[:space:]].*\b(EXIT|INT|TERM)\b' "$f" 2>/dev/null && has_trap=1
  while IFS= read -r _line; do
    local _trimmed="${_line#"${_line%%[![:space:]]*}"}"
    [[ "$_trimmed" == \#* ]] && continue
    echo "$_line" | grep -qE '(^[[:space:]]*|[;&|({`][[:space:]]*)msb[[:space:]]+volume[[:space:]]+remove([[:space:]]|$)' && has_vol_remove=1 && break
  done < <(grep -nE 'volume[[:space:]]+remove' "$f" 2>/dev/null | cut -d: -f2-)
  local file_has_reap_net=0
  [[ "$has_trap" -eq 1 && "$has_vol_remove" -eq 1 ]] && file_has_reap_net=1

  # --- VOLUME-ATTACHMENT GATE (mechanism, not filename) --------------------
  # cli/up.sh's cmd_up is the ONLY place that attaches the
  # `rc-state-<name>`/`rc-history-<name>` named volumes to a cage (as -v
  # flags built by _up_prepare_mounts). A cage stood up via a DIRECT
  # `msb create`/`msb run --name/-n <var>` (bypassing `rc up` entirely)
  # never gets those volumes attached at all -- so a bare `msb remove` on
  # such a cage orphans NOTHING, and flagging it would be a false positive
  # (the exact failure mode this gate exists to close).
  #
  # Structural, per-variable signal (not a filename list): this codebase's
  # own idiom is the discriminator. A cage created via `rc up` always has
  # its SERVER-ASSIGNED name read back via `... | jq -r '.name'` (the test
  # doesn't choose the name, msb up wraps container_name() resolution and
  # reports it back in JSON); a cage created via direct `msb create`/`run`
  # always has its name chosen by the TEST ITSELF beforehand and passed as
  # a literal `-n`/`--name` argument. These two idioms are mutually
  # exclusive per call site in every file surveyed for rip-cage-4cuh.
  #
  #   created_via_rc_up(VAR)  -- VAR=... | jq -r '.name' appears anywhere
  #   created_via_direct(VAR) -- msb create/run ... (-n|--name) VAR appears
  #
  # A variable matching NEITHER (ambiguous provenance -- e.g. a name swept
  # from `msb list` rather than assigned directly, or computed
  # independently) is resolved by the FILE's own dominant idiom rather than
  # a blind default: if this file shows NO evidence anywhere of ever
  # creating a cage the rc-up-sourced way (no `jq -r '.name'` extraction at
  # all), an ambiguous var is presumed to belong to the file's
  # direct-msb-only pattern (e.g. tests/spike-uuh9-port443.sh's leftover
  # sweep of ITS OWN prior-run cages, all created via direct `msb
  # create`/`run` earlier in that same file) and is NOT flagged. If the
  # file DOES show rc-up evidence elsewhere (it creates at least one cage
  # the rc-up way), an ambiguous var is presumed volume-bearing and IS
  # flagged -- e.g. test-msb-lifecycle-create-resume.sh's PF_CAGE_NAME,
  # a preflight-cleanup name computed to match what THAT SAME file's own
  # `rc up` call would assign. See this test's OPEN/ship-record note for
  # the one file this second branch currently reaches.
  local file_has_any_rc_up_evidence=0
  grep -qE "jq[[:space:]]+-r[[:space:]]+.?\\.name" "$f" 2>/dev/null && file_has_any_rc_up_evidence=1
  _created_via_rc_up() {
    local v="$1"
    grep -qE "^[[:space:]]*${v}=.*jq[[:space:]]+-r[[:space:]]+.?\\.name" "$f" 2>/dev/null
  }
  _created_via_direct_msb() {
    local v="$1"
    grep -qE "msb[[:space:]]+(create|run)\\b.*(-n|--name)[[:space:]]+\"?\\\$\\{?${v}\\}?\"?" "$f" 2>/dev/null
  }

  # --- Walk candidate `msb remove` lines and classify each. ---------------
  local lineno line trimmed
  while IFS=: read -r lineno line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue

    echo "$line" | grep -qE "$MSB_REMOVE_RE" || continue

    var=$(echo "$line" | sed -E 's/.*msb[[:space:]]+remove[[:space:]]+//' \
            | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | head -1 | tr -d '${}')

    if [[ -n "$var" && -n "${reaped[$var]:-}" ]]; then
      continue
    fi
    if [[ -n "$var" && -n "${destroy_first_line[$var]:-}" && "${destroy_first_line[$var]}" -lt "$lineno" ]]; then
      continue  # a `destroy --force` for this var already reaped a still-live cage before this line
    fi
    if [[ "$file_has_reap_net" -eq 1 ]]; then
      continue
    fi
    if [[ -n "$var" ]] && ! _created_via_rc_up "$var"; then
      if _created_via_direct_msb "$var"; then
        continue  # volumes were never attached -- nothing to leak
      fi
      if [[ "$file_has_any_rc_up_evidence" -eq 0 ]]; then
        continue  # ambiguous provenance, but this file never uses the rc-up idiom at all
      fi
    fi
    LEAK_LINES+=("${base}:${lineno}: ${trimmed}")
  done < <(grep -nE 'msb[[:space:]]+remove' "$f" 2>/dev/null)
}

# ============================================================================
# Case 1: NEGATIVE CONTROL + POSITIVE (clean) fixtures.
#
# A guard with no proof it can fail is worthless. This case writes a
# throwaway LEAKING fixture and a set of throwaway CLEAN fixtures (one per
# tier-1/tier-2 recognition path) into a temp dir, scans ONLY that temp dir,
# and asserts the detector reds on the leaking one and stays green on every
# clean one.
# ============================================================================
echo ""
echo "--- Case 1: detector self-test (negative control + clean fixtures) ---"

FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-teardown-guard-selftest-XXXXXX")
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# 1a. LEAKING fixture: a REAL rc-up-shaped cage (name read back from the
# creation call's JSON via `jq -r '.name'` -- the volume-bearing idiom, per
# cli/up.sh's cmd_up) torn down with a bare `msb remove --force` and no
# pairing of any kind.
cat > "${FIXTURE_DIR}/test-fixture-leaking.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
UP_OUT=$(run_rc up "$WS" 2>&1)
CAGE_NAME=$(echo "$UP_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
cleanup() {
  msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
echo "pretend test body"
FIXEOF

# 1b. CLEAN fixture via scratch_cage_register (tier-1a).
cat > "${FIXTURE_DIR}/test-fixture-clean-registered.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
CAGE_NAME="fake-clean-registered-cage-$$"
scratch_cage_register "$CAGE_NAME"
msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
FIXEOF

# 1c. CLEAN fixture via an explicit paired volume remove (tier-1c).
cat > "${FIXTURE_DIR}/test-fixture-clean-paired.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
CAGE_NAME="fake-clean-paired-cage-$$"
cleanup() {
  msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
  msb volume remove "rc-state-${CAGE_NAME}" "rc-history-${CAGE_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
FIXEOF

# 1d. CLEAN fixture via `rc destroy --force` on the same variable (tier-1b).
cat > "${FIXTURE_DIR}/test-fixture-clean-destroy.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
CAGE_NAME="fake-clean-destroy-cage-$$"
run_rc destroy --force "$CAGE_NAME" >/dev/null 2>&1 || true
msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
FIXEOF

# 1e. CLEAN fixture via a bespoke EXIT-trap reap net with a differently
# named volume (tier-2d -- mirrors tests/test-dind-compose-disk-kind-live.sh,
# which reaps a disk-kind volume that is not named after the cage at all).
cat > "${FIXTURE_DIR}/test-fixture-clean-bespoke-net.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
CAGE_C1="fake-bespoke-cage-$$"
VOL_DISK="fake-bespoke-vol-$$"
cleanup() {
  msb remove -f "$CAGE_C1" >/dev/null 2>&1 || true
  msb volume remove "$VOL_DISK" >/dev/null 2>&1 || true
}
trap cleanup EXIT
# A mid-script, non-locally-paired removal that relies on the same trap's
# eventual volume reap at real process exit -- exactly the shape this tier
# exists to recognize as fine, not an accident.
msb remove -f "$CAGE_C1" >/dev/null 2>&1 || true
FIXEOF

# 1f. Prose/comment control: text that MENTIONS "msb remove" inside a
# string literal and a comment must never be mistaken for an invocation.
cat > "${FIXTURE_DIR}/test-fixture-prose-only.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
# doc note: cli/lib/msb_runtime.sh wraps `msb remove` in _msb_volume_remove
reason="the recreate path must not run: msb remove WAS reached unexpectedly"
echo "$reason"
FIXEOF

# 1g. CLEAN fixture via the VOLUME-ATTACHMENT GATE: a cage stood up by a
# DIRECT `msb create --name` (never `rc up`) never gets rc-state-/
# rc-history- volumes attached in the first place (cli/up.sh's cmd_up is
# the only thing that attaches them) -- a bare, entirely-unpaired
# `msb remove` on it orphans NOTHING. This is the coordinator-flagged
# false-positive class (rip-cage-4cuh correction, 2026-09-03): tests that
# drive `msb create`/`msb run` directly, bypassing `rc up`.
cat > "${FIXTURE_DIR}/test-fixture-clean-direct-msb.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
CAGE_C1="fake-direct-msb-cage-$$"
if msb create --name "$CAGE_C1" alpine >/dev/null 2>&1; then
  echo "boot ok"
fi
msb remove --force "$CAGE_C1" >/dev/null 2>&1 || true
FIXEOF

# 1h. LEAKING fixture: `msb remove` runs BEFORE a `destroy --force` call on
# the same rc-up-sourced variable (mirrors the real bug found live in
# tests/test-rc-reload.sh / tests/test-up-converge.sh while building this
# guard). The later destroy is a no-op -- cli/down_destroy.sh's
# volume-deletion loop only runs when the sandbox is still present, and the
# bare remove already killed it. A destroy call ANYWHERE in the file is not
# enough; it must run on a still-live cage (i.e. before this remove) to
# count as pairing.
cat > "${FIXTURE_DIR}/test-fixture-leaking-destroy-too-late.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
UP_OUT=$(run_rc up "$WS" 2>&1)
RCL_CAGE=$(echo "$UP_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
msb remove --force "$RCL_CAGE" >/dev/null 2>&1
[[ -n "$RCL_CAGE" ]] && "$RC" destroy --force "$RCL_CAGE" >/dev/null 2>&1
FIXEOF

# 1i. CLEAN fixture: an AMBIGUOUS-provenance var (name swept from `msb
# list`, not directly assigned) in a file that shows NO rc-up evidence
# anywhere -- mirrors tests/spike-uuh9-port443.sh's leftover-cage sweep,
# which only ever removes cages the SAME file created via direct `msb
# create`/`run` earlier. No jq -r '.name' extraction anywhere in this
# fixture, so the ambiguous var is presumed to share the file's
# direct-msb-only pattern and is NOT flagged.
cat > "${FIXTURE_DIR}/test-fixture-clean-ambiguous-no-rc-up-evidence.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
CAGE_C1="fake-direct-sweep-cage-$$"
msb create --name "$CAGE_C1" alpine >/dev/null 2>&1
while IFS= read -r _leftover; do
  [[ -z "$_leftover" ]] && continue
  msb remove -f "$_leftover" >/dev/null 2>&1 || true
done < <(msb list --format json 2>/dev/null | jq -r '.[].name' 2>/dev/null | grep '^fake-direct-sweep-')
FIXEOF

# 1j. LEAKING fixture: the SAME ambiguous-provenance shape as 1i, but in a
# file that DOES show rc-up evidence elsewhere (a real `jq -r '.name'`
# extraction for a DIFFERENT cage) -- mirrors
# tests/test-msb-lifecycle-create-resume.sh's PF_CAGE_NAME preflight-cleanup
# var, computed to match what THAT SAME file's own `rc up` call would
# assign. Ambiguous + file-uses-rc-up defaults to FLAGGED.
cat > "${FIXTURE_DIR}/test-fixture-leaking-ambiguous-with-rc-up-evidence.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
UP_OUT=$(run_rc up "$WS" 2>&1)
CAGE_NAME=$(echo "$UP_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
scratch_cage_register "$CAGE_NAME"
PF_CAGE_NAME=$(basename "$(dirname "$WS")")-$(basename "$WS")
if ! msb inspect "$PF_CAGE_NAME" --format json >/dev/null 2>&1; then
  echo "no stale sandbox"
else
  msb remove --force "$PF_CAGE_NAME" >/dev/null 2>&1 || true
fi
FIXEOF

scan_dir_for_leaks "$FIXTURE_DIR"

_leaking_flagged=0
_destroy_order_flagged=0
_ambiguous_clean_flagged=1
_ambiguous_leak_flagged=0
_clean_flagged=""
for _entry in "${LEAK_LINES[@]+"${LEAK_LINES[@]}"}"; do
  case "$_entry" in
    test-fixture-leaking.sh:*) _leaking_flagged=1 ;;
    test-fixture-leaking-destroy-too-late.sh:*) _destroy_order_flagged=1 ;;
    test-fixture-clean-ambiguous-no-rc-up-evidence.sh:*) _ambiguous_clean_flagged=0 ;;
    test-fixture-leaking-ambiguous-with-rc-up-evidence.sh:*) _ambiguous_leak_flagged=1 ;;
    test-fixture-clean-*|test-fixture-prose-only.sh:*) _clean_flagged="${_clean_flagged}${_entry}; " ;;
  esac
done

if [[ "$_leaking_flagged" -eq 1 ]]; then
  pass "negative control: the detector REDS on a synthetic bare-msb-remove leak (proves it can fail)"
else
  fail "negative control: the detector did NOT flag the synthetic leaking fixture -- detector is not red-capable"
fi

if [[ "$_ambiguous_clean_flagged" -eq 1 && "$_ambiguous_leak_flagged" -eq 1 ]]; then
  pass "negative control: ambiguous-provenance var resolved by the file's OWN rc-up-evidence (sweep var in a direct-msb-only file stays clean; a preflight var in an rc-up-using file is flagged)"
else
  fail "negative control: ambiguous-provenance resolution is wrong" "clean-case-cleared=$([[ "$_ambiguous_clean_flagged" -eq 1 ]] && echo yes || echo no) leak-case-flagged=$([[ "$_ambiguous_leak_flagged" -eq 1 ]] && echo yes || echo no)"
fi

if [[ "$_destroy_order_flagged" -eq 1 ]]; then
  pass "negative control: a destroy call AFTER the msb remove (too late to reap) is still flagged, not falsely cleared"
else
  fail "negative control: an order-insensitive destroy match let a real leak (remove-before-destroy) through uncaught"
fi

if [[ -z "$_clean_flagged" ]]; then
  pass "positive controls: registered / paired / rc-destroy / bespoke-net / prose-only fixtures are all correctly left clean"
else
  fail "positive controls: detector false-positived on a correctly-paired or prose-only fixture" "$_clean_flagged"
fi

rm -rf "$FIXTURE_DIR"
trap - EXIT

# ============================================================================
# Case 2: REAL SCAN of tests/*.sh -- the actual recurrence guard.
#
# This is expected to be RED until the sibling adoption work (rip-cage-qg25)
# lands every file named in the rip-cage-4cuh inventory onto
# tests/_scratch-cage-lib.sh or an explicit paired volume remove. Each
# offending line is printed below so a reader can diff it against that
# inventory.
# ============================================================================
echo ""
echo "--- Case 2: live scan of tests/*.sh for unpaired msb-remove teardown ---"

scan_dir_for_leaks "$SCRIPT_DIR"

# This guard's own fixtures above are the only files it is allowed to invent
# leaks for; strip nothing else out -- no allowlist here by design.
if [[ "${#LEAK_LINES[@]}" -eq 0 ]]; then
  pass "live scan: zero unpaired msb-remove teardown calls under tests/*.sh"
else
  fail "live scan: ${#LEAK_LINES[@]} unpaired msb-remove call(s) found -- each leaks rc-state-<cage> and rc-history-<cage> forever" \
       "fix: either scratch_cage_register the cage in tests/_scratch-cage-lib.sh, or pair the msb remove with an explicit msb volume remove by name (never a rc-state-*/rc-history-* wildcard sweep)"
  for _entry in "${LEAK_LINES[@]}"; do
    echo "  LEAK: ${_entry}"
  done
fi

echo ""
echo "=== test-scratch-cage-teardown-guard.sh: PASS=$PASS_COUNT FAIL=$FAILURES ==="

exit "$FAILURES"
