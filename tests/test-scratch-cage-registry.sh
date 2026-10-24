#!/usr/bin/env bash
# tests/test-scratch-cage-registry.sh — rip-cage-sygz.2's verification target.
#
# THE BUG. tests/_scratch-cage-lib.sh held its created-cage names in a shell
# array and destroyed them from an EXIT/INT/TERM trap. A SIGKILL runs no trap
# (the OS low-memory reaper killed tests/run-host.sh twice on 2026-09-14), so
# the cage survived the run that made it, with its workspace directory already
# deleted. tests/test-pi-install.sh then auto-detected that corpse — it took
# the FIRST running cage `rc ls` reported, with no notion of whose it was —
# and went RED twice on a cage nobody was testing. Suite debris failing a
# later test in the same run.
#
# THE FIX, in two halves:
#   (a) _scratch-cage-lib.sh ALSO records each created name, one per line, in a
#       file that outlives the process (_scratch_cage_registry_path). A
#       successful destroy drops the line; a FAILED destroy keeps it, because
#       the cage is still out there.
#   (b) test-pi-install.sh picks its cage from RC_TEST_CONTAINER or from that
#       registry, never from "whatever is running". A foreign cage is
#       structurally unreachable: only scratch_cage_register writes the file.
#
#   (c) the cross-run SWEEP: run-host.sh destroys, at run start, the cages a
#       killed run stranded. rip-cage-neu7.9 made every runner cleanup path
#       read-only after a real incident (a degenerate glob destroyed the
#       human's own `code-personal` cage and its volumes), so the sweep was
#       raised rather than written. The granter ruled it in on 2026-09-14 with
#       a structural guard: names come ONLY from the registry file this
#       harness wrote (no enumeration, no glob, no computed names), AND a name
#       that does not carry a harness scratch prefix is refused even if it is
#       sitting in the registry. neu7.9's property survives; only its temporal
#       qualifier relaxes from "this run" to "a run of this harness".
#
# Host-only. No live cage, no live docker: `rc` is faked by running a SYMLINK
# to the real test-pi-install.sh out of a scratch tree whose `../rc` is a stub,
# and `docker` is faked on PATH. The file under test is the live one — the
# symlink cannot go stale against a copy.
#
# Coverage:
#   T1  scratch_cage_register writes the exact name to the registry file
#   T2  a SUCCESSFUL destroy drops that line
#   T3  a FAILED destroy KEEPS the line (the cage still exists)
#   T4  registry line-matching is whole-line exact, never a prefix
#   T5  test-pi-install.sh with a FOREIGN cage running and an empty registry ->
#       SKIPs 3/4, exits 0, and never runs `rc exec` against the foreign name
#   T6  NEGATIVE CONTROL for T5: the same running cage listed in the registry
#       IS selected, and 3/4 really execute against it
#   T7  the sweep destroys a stranded harness cage by EXACT name and drops it
#   T8  NEGATIVE CONTROL 1: a foreign name planted in the registry is REFUSED,
#       logged, and its line kept — no destroy call ever names it
#   T9  NEGATIVE CONTROL 2: a registry entry whose cage is gone is dropped
#       SILENTLY — no destroy call, no warning
#   T10 one mixed registry, one pass: both prefixes, both controls together
#   T11 the prefix guard matches a PREFIX, not a substring
#   T12 the sweep never enumerates — `msb list` is never called
#   T13 a failed destroy is loud, keeps its line, and never aborts the
#       `set -e` caller (run-host.sh) over a cleanup miss
#   T14 run-host.sh really calls the sweep, and calls it BEFORE the warn
#   T15 destroy-then-deregister, then exit: no warning, no second destroy
#   T16 NEGATIVE CONTROL for T15: a stranded (never-deregistered) name still
#       warns loudly, and only it
#   T17 INT/TERM under `set -e`: exit 130/143, one destroy, no reg.* leak
#   T18 EXIT under `set -e`: every cage destroyed, exit status kept, prior
#       EXIT body runs and sees it
#   T19 deregistering the last name under `set -e` keeps the caller alive
#   T20 a prior INT/TERM trap body is captured and still runs
#   T21 leftover rip-cage-x-* images are listed on one line, never removed
#   T22 NEGATIVE CONTROL for T21: silent with no scratch image or no msb;
#       run-host.sh prints the image line right after the cage warning

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rc-sygz2-XXXXXX")

# ---------------------------------------------------------------------------
# T1-T4: the registry itself, driven through the real lib.
# ---------------------------------------------------------------------------
REG="${WORK}/created-cages"

echo "=== T1: scratch_cage_register writes the exact name to the registry file ==="
t1_out=$(
  RC_TEST_CAGE_REGISTRY="$REG" \
  bash -c '
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_cage_register "T-tmp.LImsTGdjwx"
    # Disarm the composed trap: this case is about the registry WRITE, and a
    # cleanup pass here would immediately try to destroy the fixture name.
    trap - EXIT INT TERM
  ' 2>&1
)
if [[ -f "$REG" ]] && grep -qxF "T-tmp.LImsTGdjwx" "$REG"; then
  pass "T1: registry file holds the registered name verbatim"
else
  fail "T1: expected 'T-tmp.LImsTGdjwx' as a whole line in $REG" "$(cat "$REG" 2>&1); lib said: ${t1_out}"
fi

echo ""
echo "=== T2: a SUCCESSFUL destroy drops the line ==="
# A stub `rc` at ${SCRIPT_DIR}/../rc is what the lib calls, so the whole
# exercise runs in a scratch tree with its own tests/ dir + sibling rc.
STUB_ROOT="${WORK}/t2"
mkdir -p "${STUB_ROOT}/tests"
ln -sf "${REPO_ROOT}/tests/_scratch-cage-lib.sh" "${STUB_ROOT}/tests/_scratch-cage-lib.sh"
cat > "${STUB_ROOT}/rc" <<'STUBEOF'
#!/usr/bin/env bash
echo "rc $*" >> "$RC_STUB_LOG"
exit "${RC_STUB_EXIT:-0}"
STUBEOF
chmod +x "${STUB_ROOT}/rc"

REG2="${WORK}/reg2"
printf 'T-tmp.aaaa\nT-tmp.bbbb\n' > "$REG2"
LOG2="${WORK}/log2"
: > "$LOG2"
RC_TEST_CAGE_REGISTRY="$REG2" RC_STUB_LOG="$LOG2" RC_STUB_EXIT=0 \
bash -c '
  SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
  source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
  _SCRATCH_CAGE_NAMES=("T-tmp.aaaa")
  _scratch_cage_cleanup
' >/dev/null 2>&1
if grep -qxF "T-tmp.aaaa" "$REG2"; then
  fail "T2: destroyed cage's line should be gone" "$(cat "$REG2")"
elif grep -qxF "T-tmp.bbbb" "$REG2"; then
  pass "T2: the destroyed name is dropped, the other name survives"
else
  fail "T2: the untouched name T-tmp.bbbb was dropped too" "$(cat "$REG2")"
fi
if grep -qF "rc destroy T-tmp.aaaa" "$LOG2"; then
  pass "T2b: destroy was called by EXACT name (no enumeration, no glob)"
else
  fail "T2b: expected 'rc destroy T-tmp.aaaa' in the call log" "$(cat "$LOG2")"
fi

echo ""
echo "=== T3: a FAILED destroy KEEPS the line (the cage still exists) ==="
REG3="${WORK}/reg3"
printf 'T-tmp.cccc\n' > "$REG3"
LOG3="${WORK}/log3"
: > "$LOG3"
RC_TEST_CAGE_REGISTRY="$REG3" RC_STUB_LOG="$LOG3" RC_STUB_EXIT=1 \
bash -c '
  SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
  source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
  _SCRATCH_CAGE_NAMES=("T-tmp.cccc")
  _scratch_cage_cleanup
' >/dev/null 2>&1
if grep -qxF "T-tmp.cccc" "$REG3"; then
  pass "T3: a cage that failed to destroy keeps its registry line"
else
  fail "T3: expected T-tmp.cccc to survive a failed destroy" "$(cat "$REG3")"
fi

echo ""
echo "=== T4: registry removal is whole-line exact, never a prefix ==="
REG4="${WORK}/reg4"
printf 'T-tmp.dddd\nT-tmp.dddd-extra\n' > "$REG4"
LOG4="${WORK}/log4"
: > "$LOG4"
RC_TEST_CAGE_REGISTRY="$REG4" RC_STUB_LOG="$LOG4" RC_STUB_EXIT=0 \
bash -c '
  SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
  source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
  _SCRATCH_CAGE_NAMES=("T-tmp.dddd")
  _scratch_cage_cleanup
' >/dev/null 2>&1
if grep -qxF "T-tmp.dddd-extra" "$REG4" && ! grep -qxF "T-tmp.dddd" "$REG4"; then
  pass "T4: only the exact name went; the prefix-sharing neighbour stayed"
else
  fail "T4: expected T-tmp.dddd gone and T-tmp.dddd-extra kept" "$(cat "$REG4")"
fi

# ---------------------------------------------------------------------------
# T5/T6: the real tests/test-pi-install.sh, run out of a scratch tree.
#
# `rc` is the stub above; `docker` is faked on PATH so Tests 1/2 of that file
# (docker run --rm rip-cage:latest pi --version) never touch a real daemon.
# ---------------------------------------------------------------------------
PI_ROOT="${WORK}/pi"
mkdir -p "${PI_ROOT}/tests"
ln -sf "${REPO_ROOT}/tests/test-pi-install.sh" "${PI_ROOT}/tests/test-pi-install.sh"
ln -sf "${REPO_ROOT}/tests/_scratch-cage-lib.sh" "${PI_ROOT}/tests/_scratch-cage-lib.sh"
# Every lib test-pi-install.sh sources has to be linked in, or it dies on a
# missing source and this suite reads that as "the cage was skipped" —
# T6's failure mode exactly. _cage-lookup-lib.sh arrived with rip-cage-ely4.7.3,
# when cage discovery moved off the retired `rc ls`.
ln -sf "${REPO_ROOT}/tests/_cage-lookup-lib.sh" "${PI_ROOT}/tests/_cage-lookup-lib.sh"

FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/docker" <<'FAKEEOF'
#!/usr/bin/env bash
echo "docker $*" >> "$RC_STUB_LOG"
echo "pi 1.2.3"
exit 0
FAKEEOF
chmod +x "${FAKE_BIN}/docker"

# The stub msb for the pi legs (rip-cage-ely4.7.3): cage discovery and in-cage
# exec moved off `rc ls` / `rc exec` onto msb when those verbs retired
# (ADR-031 D3), so the stub that answers them has to move too, or T6b asserts
# on a call nothing makes any more.
#
# `list --format json` reports ONE running cage named by $RC_STUB_RUNNING.
# Note the CAPITALIZED status: that is msb's own vocabulary, and stubbing it
# lowercase would let a discovery bug that only matches "running" pass here
# while failing against a real msb.
cat > "${FAKE_BIN}/msb" <<'MSBSTUBEOF'
#!/usr/bin/env bash
echo "msb $*" >> "$RC_STUB_LOG"
case "${1:-}" in
  list)
    printf '[{"name":"%s","status":"Running"}]\n' "$RC_STUB_RUNNING"
    exit 0 ;;
  exec)
    echo "agent:agent"
    exit 0 ;;
esac
exit 0
MSBSTUBEOF
chmod +x "${FAKE_BIN}/msb"

# The stub rc for the pi legs: everything the suite still routes through rc.
cat > "${PI_ROOT}/rc" <<'STUBEOF'
#!/usr/bin/env bash
echo "rc $*" >> "$RC_STUB_LOG"
exit 0
STUBEOF
chmod +x "${PI_ROOT}/rc"

echo ""
echo "=== T5: foreign cage running + EMPTY registry -> SKIP, and the foreign cage is never exec'd ==="
REG5="${WORK}/reg5"
: > "$REG5"
LOG5="${WORK}/log5"
: > "$LOG5"
t5_rc=0
t5_out=$(
  PATH="${FAKE_BIN}:$PATH" \
  RC_TEST_CAGE_REGISTRY="$REG5" \
  RC_STUB_LOG="$LOG5" \
  RC_STUB_RUNNING="code-personal" \
  bash "${PI_ROOT}/tests/test-pi-install.sh" 2>&1
) || t5_rc=$?

if echo "$t5_out" | grep -q "SKIP: no harness-created running cage"; then
  pass "T5: Tests 3/4 SKIP rather than assert against a cage the suite did not create"
else
  fail "T5: expected the scoped SKIP line" "$t5_out"
fi
if grep -qF "rc exec code-personal" "$LOG5"; then
  fail "T5b: the foreign cage was exec'd — scoping is not load-bearing" "$(cat "$LOG5")"
else
  pass "T5b: no 'rc exec' ever named the foreign cage"
fi
if grep -qF "destroy" "$LOG5"; then
  fail "T5c: something tried to destroy a cage from this read-only test file" "$(cat "$LOG5")"
else
  pass "T5c: the foreign cage was left completely untouched (no destroy call at all)"
fi
if [[ "$t5_rc" -eq 0 ]]; then
  pass "T5d: the file exits 0 — a foreign running cage is no longer a suite failure"
else
  fail "T5d: expected exit 0, got $t5_rc" "$t5_out"
fi

echo ""
echo "=== T6 (NEGATIVE CONTROL for T5): the SAME cage, listed in the registry, IS selected ==="
REG6="${WORK}/reg6"
echo "T-tmp.ours" > "$REG6"
LOG6="${WORK}/log6"
: > "$LOG6"
t6_rc=0
t6_out=$(
  PATH="${FAKE_BIN}:$PATH" \
  RC_TEST_CAGE_REGISTRY="$REG6" \
  RC_STUB_LOG="$LOG6" \
  RC_STUB_RUNNING="T-tmp.ours" \
  bash "${PI_ROOT}/tests/test-pi-install.sh" 2>&1
) || t6_rc=$?

if echo "$t6_out" | grep -q "SKIP: no harness-created running cage"; then
  fail "T6: a registered running cage must NOT be skipped — T5 would be vacuous" "$t6_out"
else
  pass "T6: a registered running cage is selected (so T5's SKIP is a real discrimination)"
fi
if grep -qF "msb exec T-tmp.ours" "$LOG6"; then
  pass "T6b: Tests 3/4 really executed against the registered cage"
else
  fail "T6b: expected 'msb exec T-tmp.ours' in the call log" "$(cat "$LOG6")"
fi
if [[ "$t6_rc" -eq 0 ]]; then
  pass "T6c: the file still exits 0 on the happy path"
else
  fail "T6c: expected exit 0, got $t6_rc" "$t6_out"
fi

# ---------------------------------------------------------------------------
# T7-T12: the cross-run DESTROY sweep (scratch_cage_sweep_registry).
#
# Host-only, and deliberately so: the human's own `code-personal` cage is live
# on this machine while these run. Nothing here may reach a real cage, so `rc`
# is the stub below and `msb` is faked on PATH — the fake decides which names
# "exist" via $MSB_FAKE_EXISTING and logs every call it is given, which is how
# T12 proves the sweep never enumerated.
# ---------------------------------------------------------------------------
SWEEP_ROOT="${WORK}/sweep"
mkdir -p "${SWEEP_ROOT}/tests"
ln -sf "${REPO_ROOT}/tests/_scratch-cage-lib.sh" "${SWEEP_ROOT}/tests/_scratch-cage-lib.sh"
cat > "${SWEEP_ROOT}/rc" <<'STUBEOF'
#!/usr/bin/env bash
echo "rc $*" >> "$RC_STUB_LOG"
exit "${RC_STUB_EXIT:-0}"
STUBEOF
chmod +x "${SWEEP_ROOT}/rc"

SWEEP_BIN="${WORK}/sweepbin"
mkdir -p "$SWEEP_BIN"
cat > "${SWEEP_BIN}/msb" <<'FAKEEOF'
#!/usr/bin/env bash
echo "msb $*" >> "$RC_STUB_LOG"
if [[ "${1:-}" == "inspect" ]]; then
  for _n in ${MSB_FAKE_EXISTING:-}; do
    [[ "$_n" == "${2:-}" ]] && exit 0
  done
  exit 1
fi
exit 0
FAKEEOF
chmod +x "${SWEEP_BIN}/msb"

# run_registry_sweep <registry-file> <call-log> <space-separated names that "exist">
# Echoes the sweep's combined stdout+stderr.
run_registry_sweep() {
  PATH="${SWEEP_BIN}:$PATH" \
  RC_TEST_CAGE_REGISTRY="$1" \
  RC_STUB_LOG="$2" \
  MSB_FAKE_EXISTING="$3" \
  bash -c '
    SCRIPT_DIR="'"${SWEEP_ROOT}/tests"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_cage_sweep_registry
  ' 2>&1
}

echo ""
echo "=== T7: a stranded harness cage is destroyed by EXACT name and dropped ==="
REG7="${WORK}/reg7"
echo "T-tmp.stranded" > "$REG7"
LOG7="${WORK}/log7"
: > "$LOG7"
t7_out=$(run_registry_sweep "$REG7" "$LOG7" "T-tmp.stranded")
if grep -qF "rc destroy T-tmp.stranded" "$LOG7"; then
  pass "T7: the sweep called destroy by exact name"
else
  fail "T7: expected 'rc destroy T-tmp.stranded' in the call log" "$(cat "$LOG7"); sweep said: ${t7_out}"
fi
if grep -qxF "T-tmp.stranded" "$REG7"; then
  fail "T7b: a destroyed cage must not keep its registry line" "$(cat "$REG7")"
else
  pass "T7b: the destroyed name is gone from the registry"
fi
if echo "$t7_out" | grep -q "T-tmp.stranded"; then
  pass "T7c: the sweep names what it destroyed"
else
  fail "T7c: the sweep destroyed a cage without saying so" "$t7_out"
fi

echo ""
echo "=== T8 (NEGATIVE CONTROL 1): a foreign name in the registry is REFUSED ==="
REG8="${WORK}/reg8"
echo "code-personal" > "$REG8"
LOG8="${WORK}/log8"
: > "$LOG8"
t8_out=$(run_registry_sweep "$REG8" "$LOG8" "code-personal")
if grep -qF "destroy" "$LOG8"; then
  fail "T8: a destroy call was made against a foreign name — the guard is not load-bearing" "$(cat "$LOG8")"
else
  pass "T8: no destroy call of any kind was made"
fi
if echo "$t8_out" | grep -qi "refus" && echo "$t8_out" | grep -q "code-personal"; then
  pass "T8b: the refusal is logged and names the offending entry"
else
  fail "T8b: expected a logged refusal naming code-personal" "$t8_out"
fi
if grep -qxF "code-personal" "$REG8"; then
  pass "T8c: the refused line is KEPT, so a tampered registry stays visible"
else
  fail "T8c: the refused line was silently dropped — the tampering evidence is gone" "$(cat "$REG8")"
fi

echo ""
echo "=== T9 (NEGATIVE CONTROL 2): an entry whose cage is gone is dropped SILENTLY ==="
REG9="${WORK}/reg9"
echo "T-tmp.gone" > "$REG9"
LOG9="${WORK}/log9"
: > "$LOG9"
t9_out=$(run_registry_sweep "$REG9" "$LOG9" "")
if grep -qF "destroy" "$LOG9"; then
  fail "T9: a cage that does not exist must not be destroyed" "$(cat "$LOG9")"
else
  pass "T9: no destroy call for a cage that is already gone"
fi
if [[ -s "$REG9" ]]; then
  fail "T9b: the stale entry should have been dropped" "$(cat "$REG9")"
else
  pass "T9b: the stale entry is dropped"
fi
if echo "$t9_out" | grep -q "T-tmp.gone"; then
  fail "T9c: dropping a stale entry must be SILENT — every run would cry wolf" "$t9_out"
else
  pass "T9c: the drop is silent"
fi

echo ""
echo "=== T10: one mixed registry, one pass — both prefixes, both controls ==="
REG10="${WORK}/reg10"
printf 'rc-t-t.AbCdEf\ncode-personal\nT-tmp.gone\nT-tmp.live\n' > "$REG10"
LOG10="${WORK}/log10"
: > "$LOG10"
t10_out=$(run_registry_sweep "$REG10" "$LOG10" "rc-t-t.AbCdEf code-personal T-tmp.live")
# Counts `rc destroy ` lines, not `rc destroy --force` (rip-cage-ely4.10: the
# flag retired with the confirmation prompt, ADR-031 D3). The old spelling made
# this counter read 0 and T10 go red -- worth noting that it failed LOUD rather
# than passing vacuously, because the expected count is an exact 2, not a
# lower bound. The trailing space keeps `rc destroyx` out of the count.
t10_destroys=$(grep -cF "rc destroy " "$LOG10" 2>/dev/null || true)
t10_destroys="${t10_destroys:-0}"
if [[ "$t10_destroys" -eq 2 ]] \
  && grep -qF "rc destroy rc-t-t.AbCdEf" "$LOG10" \
  && grep -qF "rc destroy T-tmp.live" "$LOG10"; then
  pass "T10: exactly the two harness-prefixed live cages were destroyed (rc-t- and T-tmp. both)"
else
  fail "T10: expected exactly 2 destroys, for rc-t-t.AbCdEf and T-tmp.live" "count=${t10_destroys}; log: $(cat "$LOG10")"
fi
if [[ "$(cat "$REG10")" == "code-personal" ]]; then
  pass "T10b: the registry is left holding exactly the refused foreign name"
else
  fail "T10b: expected the registry to hold only 'code-personal'" "$(cat "$REG10")"
fi
# The pass that DID destroy two cages must still have said no to the third.
# This is what makes T8 a control rather than a coincidence: same code path,
# same run, one name destroyed and one refused.
if echo "$t10_out" | grep -qi "refus" && echo "$t10_out" | grep -q "code-personal"; then
  pass "T10c: the same pass that destroyed two cages refused the foreign one out loud"
else
  fail "T10c: expected a refusal naming code-personal in the mixed pass" "$t10_out"
fi

echo ""
echo "=== T11: the prefix guard matches a PREFIX, not a substring ==="
REG11="${WORK}/reg11"
printf 'evil-T-tmp.x\nnot-rc-t-y\n' > "$REG11"
LOG11="${WORK}/log11"
: > "$LOG11"
t11_out=$(run_registry_sweep "$REG11" "$LOG11" "evil-T-tmp.x not-rc-t-y")
if grep -qF "destroy" "$LOG11"; then
  fail "T11: a name that merely CONTAINS the prefix was swept" "$(cat "$LOG11")"
else
  pass "T11: names that only contain the prefix are refused, not swept"
fi
if [[ "$(cat "$REG11")" == "$(printf 'evil-T-tmp.x\nnot-rc-t-y')" ]]; then
  pass "T11b: both refused lines are kept"
else
  fail "T11b: expected both lines kept verbatim" "$(cat "$REG11")"
fi
# T11a/T11b above are "nothing happened" assertions, which a missing sweep
# would also satisfy. This one is not: it requires the sweep to have run and
# to have said NO to each name by name.
if echo "$t11_out" | grep -q "evil-T-tmp.x" && echo "$t11_out" | grep -q "not-rc-t-y"; then
  pass "T11c: the sweep actually ran and refused each name out loud"
else
  fail "T11c: expected a refusal naming each entry" "$t11_out"
fi

echo ""
echo "=== T12: the sweep never enumerates ==="
if grep -qF "msb list" "$LOG10"; then
  fail "T12: the sweep enumerated sandboxes — neu7.9's banned shape" "$(cat "$LOG10")"
else
  pass "T12: no 'msb list' call; every name came from the registry file"
fi

echo ""
echo "=== T13: a failed destroy is loud, keeps its line, and does NOT kill a set -e caller ==="
# run-host.sh runs under `set -euo pipefail`. A sweep that aborted its caller
# on a failed destroy would turn a cleanup miss into a dead suite, so this runs
# the sweep in a shell with the same strict mode the real caller uses.
REG13="${WORK}/reg13"
echo "T-tmp.wontdie" > "$REG13"
LOG13="${WORK}/log13"
: > "$LOG13"
t13_rc=0
t13_out=$(
  PATH="${SWEEP_BIN}:$PATH" \
  RC_TEST_CAGE_REGISTRY="$REG13" \
  RC_STUB_LOG="$LOG13" \
  RC_STUB_EXIT=7 \
  MSB_FAKE_EXISTING="T-tmp.wontdie" \
  bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"${SWEEP_ROOT}/tests"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_cage_sweep_registry
    echo "CALLER-SURVIVED"
  ' 2>&1
) || t13_rc=$?
if echo "$t13_out" | grep -q "CALLER-SURVIVED" && [[ "$t13_rc" -eq 0 ]]; then
  pass "T13: a failed destroy never aborts the strict-mode caller"
else
  fail "T13: the set -e caller died on a failed destroy (exit ${t13_rc})" "$t13_out"
fi
if echo "$t13_out" | grep -q "T-tmp.wontdie"; then
  pass "T13b: the failure is named out loud"
else
  fail "T13b: a cage leaked without a word on stderr" "$t13_out"
fi
if grep -qxF "T-tmp.wontdie" "$REG13"; then
  pass "T13c: the line is KEPT — the cage is still out there, so the record must be too"
else
  fail "T13c: a cage that survived its destroy lost its registry line" "$(cat "$REG13")"
fi

echo ""
echo "=== T14: run-host.sh actually calls the sweep, before the read-only warn ==="
# The driver's path is assembled from parts rather than written as one
# literal, exactly as test-rc-decomposition-structure.sh case (j) assembles its
# own. That case flags any file the driver runs which names the driver's path
# in a path position, because such a file is usually about to INVOKE it and a
# nested run contaminates the shared msb daemon. This file only READS the
# driver, and it must keep running in the suite, so the manual-only-probe
# exemption would be a false claim.
_rh_driver="run-host"
RH="${REPO_ROOT}/tests/${_rh_driver}.sh"
rh_sweep_line=$(grep -n '^scratch_cage_sweep_registry$' "$RH" | head -1 | cut -d: -f1)
rh_warn_line=$(grep -n '^_warn_leftover_scratch_cages$' "$RH" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016  # the single quotes are the point: this is a
# literal grep pattern for the source line as it appears in the driver, not an
# expansion.
if [[ -n "$rh_sweep_line" ]] && grep -q '^source "\${SCRIPT_DIR}/_scratch-cage-lib.sh"$' "$RH"; then
  pass "T14: run-host.sh sources the lib and calls scratch_cage_sweep_registry"
else
  fail "T14: the sweep is written but never wired into the runner" "sweep_line='${rh_sweep_line}'"
fi
if [[ -n "$rh_sweep_line" && -n "$rh_warn_line" && "$rh_sweep_line" -lt "$rh_warn_line" ]]; then
  pass "T14b: the sweep runs BEFORE the warn, so the warning names only what is really left"
else
  fail "T14b: expected sweep before warn" "sweep=${rh_sweep_line} warn=${rh_warn_line}"
fi

echo ""
echo "=== T15: destroy-then-deregister, then exit -> no leak warning (rip-cage-sygz.7) ==="
# The stub rc FAILS, as a real destroy of an already-gone cage does: that
# doomed second destroy is what used to print the false 'will leak' warning.
# The trap fires on a real exit, not a direct _scratch_cage_cleanup call.
REG15="${WORK}/reg15"
: > "$REG15"
LOG15="${WORK}/log15"
: > "$LOG15"
t15_err=$(
  RC_TEST_CAGE_REGISTRY="$REG15" RC_STUB_LOG="$LOG15" RC_STUB_EXIT=1 \
  bash -c '
    SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_cage_register "T-tmp.ffff"
    scratch_cage_deregister "T-tmp.ffff"
    exit 0
  ' 2>&1 >/dev/null
)
if [[ -z "$t15_err" && ! -s "$LOG15" ]] && ! grep -qxF "T-tmp.ffff" "$REG15"; then
  pass "T15: a deregistered cage gets no exit-trap destroy, no warning, and no registry line"
else
  fail "T15: expected silence, no destroy call, no line" "stderr='${t15_err}' calls='$(cat "$LOG15")' reg='$(cat "$REG15")'"
fi

echo ""
echo "=== T16: NEGATIVE CONTROL for T15: a stranded name still warns loudly ==="
REG16="${WORK}/reg16"
: > "$REG16"
LOG16="${WORK}/log16"
: > "$LOG16"
t16_err=$(
  RC_TEST_CAGE_REGISTRY="$REG16" RC_STUB_LOG="$LOG16" RC_STUB_EXIT=1 \
  bash -c '
    SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_cage_register "T-tmp.gggg"
    scratch_cage_register "T-tmp.hhhh"
    scratch_cage_deregister "T-tmp.gggg"
    exit 0
  ' 2>&1 >/dev/null
)
if grep -q "failed to destroy scratch cage 'T-tmp.hhhh'" <<<"$t16_err" \
   && grep -q "will leak" <<<"$t16_err" \
   && ! grep -qF "T-tmp.gggg" <<<"$t16_err" \
   && [[ "$(cat "$LOG16")" == "rc destroy T-tmp.hhhh" ]]; then
  pass "T16: the stranded name is destroyed and warned about; its deregistered sibling is not"
else
  fail "T16: expected one loud warning naming T-tmp.hhhh only" "stderr='${t16_err}' calls='$(cat "$LOG16")'"
fi

echo ""
echo "=== T17: an INT/TERM under set -e ends the test 130/143, one destroy, no reg.* leak (rip-cage-b8kd.64) ==="
# Several live suites turn `set -e` on AFTER registering their cage. The trap
# then runs under errexit, and the registry-remove grep exits 1 once it empties
# the file: before the fix the trap aborted there, so the shell exited 1, the
# EXIT trap destroyed the cage a second time, and reg.<pid> was left behind.
for _t17_sig in INT TERM; do
  case "$_t17_sig" in INT) _t17_want=130 ;; TERM) _t17_want=143 ;; esac
  REG17="${WORK}/reg17-${_t17_sig}"
  : > "$REG17"
  LOG17="${WORK}/log17-${_t17_sig}"
  : > "$LOG17"
  t17_rc=0
  RC_TEST_CAGE_REGISTRY="$REG17" RC_STUB_LOG="$LOG17" RC_STUB_EXIT=0 \
  bash -c '
    SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_cage_register "T-tmp.sig17"
    set -e
    kill -'"$_t17_sig"' $$
    sleep 2
    echo RESUMED-AFTER-SIGNAL
  ' >/dev/null 2>&1 || t17_rc=$?
  _t17_leak=$(find "$WORK" -maxdepth 1 -name "reg17-${_t17_sig}.*" | wc -l | tr -d ' ')
  if [[ "$t17_rc" -eq "$_t17_want" && "$(cat "$LOG17")" == "rc destroy T-tmp.sig17" \
        && ! -s "$REG17" && "$_t17_leak" -eq 0 ]]; then
    pass "T17 (${_t17_sig}): exit ${_t17_want}, exactly one destroy, registry emptied, no reg.* temp file"
  else
    fail "T17 (${_t17_sig}): expected exit ${_t17_want}, one destroy, empty registry, no temp file" \
         "exit=${t17_rc} calls='$(tr '\n' ';' < "$LOG17")' reg='$(cat "$REG17")' temp_files=${_t17_leak}"
  fi
done

echo ""
echo "=== T18: the EXIT trap under set -e destroys EVERY cage, keeps the exit status, runs the prior body ==="
# Same errexit hazard on the EXIT path: it stopped after the cage whose removal
# emptied the registry, and a non-zero test status (returned by the cleanup to
# preserve \$?) aborted the trap before the prior EXIT body could run.
REG18="${WORK}/reg18"
: > "$REG18"
LOG18="${WORK}/log18"
: > "$LOG18"
t18_rc=0
RC_TEST_CAGE_REGISTRY="$REG18" RC_STUB_LOG="$LOG18" RC_STUB_EXIT=0 \
bash -c '
  SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
  trap '"'"'echo "prior-exit-body saw $?" >> "$RC_STUB_LOG"'"'"' EXIT
  source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
  scratch_cage_register "T-tmp.ex18a"
  scratch_cage_register "T-tmp.ex18b"
  set -e
  exit 3
' >/dev/null 2>&1 || t18_rc=$?
t18_want=$'rc destroy T-tmp.ex18a\nrc destroy T-tmp.ex18b\nprior-exit-body saw 3'
if [[ "$t18_rc" -eq 3 && "$(cat "$LOG18")" == "$t18_want" && ! -s "$REG18" ]]; then
  pass "T18: both cages destroyed once, the prior EXIT body ran and saw \$?=3, the test's exit 3 survives"
else
  fail "T18: expected two destroys then the prior body seeing 3, exit 3, empty registry" \
       "exit=${t18_rc} calls='$(tr '\n' ';' < "$LOG18")' reg='$(cat "$REG18")'"
fi

echo ""
echo "=== T19: deregistering the LAST name under set -e does not kill the caller ==="
REG19="${WORK}/reg19"
: > "$REG19"
LOG19="${WORK}/log19"
: > "$LOG19"
t19_out=$(
  RC_TEST_CAGE_REGISTRY="$REG19" RC_STUB_LOG="$LOG19" RC_STUB_EXIT=0 \
  bash -c '
    SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_cage_register "T-tmp.dr19"
    set -e
    scratch_cage_deregister "T-tmp.dr19"
    echo CALLER-SURVIVED
  ' 2>&1
)
if grep -q CALLER-SURVIVED <<<"$t19_out" && [[ ! -s "$REG19" && ! -s "$LOG19" ]]; then
  pass "T19: the caller survives, the registry is empty, and the trap destroys nothing"
else
  fail "T19: deregister of the last name aborted a set -e caller" \
       "out='${t19_out}' reg='$(cat "$REG19")' calls='$(tr '\n' ';' < "$LOG19")'"
fi

echo ""
echo "=== T20: a PRIOR INT/TERM trap body is captured and still runs (rip-cage-b8kd.64 minor a) ==="
# `trap -p INT` prints the signal as SIGINT, so a pattern anchored on ' INT$'
# never captured the prior body; it was silently replaced.
for _t20_sig in INT TERM; do
  REG20="${WORK}/reg20-${_t20_sig}"
  : > "$REG20"
  LOG20="${WORK}/log20-${_t20_sig}"
  : > "$LOG20"
  RC_TEST_CAGE_REGISTRY="$REG20" RC_STUB_LOG="$LOG20" RC_STUB_EXIT=0 \
  bash -c '
    SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
    trap '"'"'echo "prior-'"$_t20_sig"'-body" >> "$RC_STUB_LOG"'"'"' '"$_t20_sig"'
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_cage_register "T-tmp.pr20"
    kill -'"$_t20_sig"' $$
    sleep 2
  ' >/dev/null 2>&1
  if [[ "$(cat "$LOG20")" == "rc destroy T-tmp.pr20"$'\n'"prior-${_t20_sig}-body" ]]; then
    pass "T20 (${_t20_sig}): the cage is destroyed first, then the prior ${_t20_sig} body runs"
  else
    fail "T20 (${_t20_sig}): expected the destroy then the prior body" "calls='$(tr '\n' ';' < "$LOG20")'"
  fi
done

echo ""
echo "=== T21: leftover rip-cage-x-* scratch images are LISTED, never removed (rip-cage-sygz.7.7) ==="
# A killed run strands its scratch image tags as well as its cages. The image
# line is read-only: it names them, and an operator decides. A fake msb on
# PATH answers `image ls -q` and logs every call, so a removal would show.
IMG_BIN="${WORK}/img-bin"
mkdir -p "$IMG_BIN"
cat > "${IMG_BIN}/msb" <<'MSBIMGEOF'
#!/usr/bin/env bash
echo "msb $*" >> "$RC_STUB_LOG"
if [[ "$1 $2" == "image ls" || "$1 $2" == "image list" ]]; then
  printf '%s\n' ${MSB_FAKE_IMAGES:-}
fi
exit 0
MSBIMGEOF
chmod +x "${IMG_BIN}/msb"
LOG21="${WORK}/log21"
: > "$LOG21"
t21_rc=0
t21_err=$(
  PATH="${IMG_BIN}:$PATH" RC_STUB_LOG="$LOG21" \
  MSB_FAKE_IMAGES="rip-cage:latest alpine rip-cage-x-floor-asroot:1 localhost/rip-cage-x-bootdesc:1 rip-cage-xyz:1" \
  bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_image_list_leftovers
    echo CALLER-SURVIVED >&2
  ' 2>&1 >/dev/null
) || t21_rc=$?
if [[ "$t21_rc" -eq 0 ]] && grep -q CALLER-SURVIVED <<<"$t21_err" \
   && grep -qF "rip-cage-x-floor-asroot:1" <<<"$t21_err" \
   && grep -qF "localhost/rip-cage-x-bootdesc:1" <<<"$t21_err"; then
  pass "T21: both rip-cage-x-* images are named, under the caller's set -e"
else
  fail "T21: expected both rip-cage-x-* refs named and the caller alive" "exit=${t21_rc} stderr='${t21_err}'"
fi
if ! grep -qE "rip-cage:latest|alpine|rip-cage-xyz" <<<"$t21_err"; then
  pass "T21b: rip-cage:latest, alpine and rip-cage-xyz (no 'x-' prefix) are not named"
else
  fail "T21b: a non-scratch image was named" "$t21_err"
fi
if [[ "$(cat "$LOG21")" == "msb image ls -q" ]]; then
  pass "T21c: the one msb call is the listing -- nothing is removed"
else
  fail "T21c: expected exactly 'msb image ls -q'" "calls='$(tr '\n' ';' < "$LOG21")'"
fi

echo ""
echo "=== T22: NEGATIVE CONTROL for T21: no scratch image, or no msb, prints nothing ==="
: > "$LOG21"
t22_err=$(
  PATH="${IMG_BIN}:$PATH" RC_STUB_LOG="$LOG21" MSB_FAKE_IMAGES="rip-cage:latest alpine" \
  bash -c '
    SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_image_list_leftovers
  ' 2>&1
)
t22_nomsb=$(
  PATH="/usr/bin:/bin" bash -c '
    SCRIPT_DIR="'"${STUB_ROOT}/tests"'"
    source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
    scratch_image_list_leftovers
    echo "rc=$?"
  ' 2>&1
)
if [[ -z "$t22_err" && "$t22_nomsb" == "rc=0" ]]; then
  pass "T22: silent with no scratch image, and silent (exit 0) with no msb on PATH"
else
  fail "T22: expected silence in both" "no-scratch='${t22_err}' no-msb='${t22_nomsb}'"
fi
_rh_driver2="run-host"
RH2="${REPO_ROOT}/tests/${_rh_driver2}.sh"
rh_img_line=$(grep -n '^scratch_image_list_leftovers$' "$RH2" | head -1 | cut -d: -f1)
rh_warn_line2=$(grep -n '^_warn_leftover_scratch_cages$' "$RH2" | head -1 | cut -d: -f1)
if [[ -n "$rh_img_line" && -n "$rh_warn_line2" && "$rh_img_line" -eq $((rh_warn_line2 + 1)) ]]; then
  pass "T22b: run-host.sh prints the image line right after the leftover-cage warning"
else
  fail "T22b: the image line is not wired next to the cage warning in run-host.sh" "img=${rh_img_line} warn=${rh_warn_line2}"
fi

echo ""
echo "=== Summary: $FAILURES/$TOTAL failed ==="
echo "TOTALS: PASS=$((TOTAL - FAILURES)) FAIL=${FAILURES}"
[[ "$FAILURES" -eq 0 ]] || exit 1
exit 0
