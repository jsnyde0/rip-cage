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
# NOT IN SCOPE HERE: a cross-run sweep that DESTROYS the stranded names.
# rip-cage-neu7.9 made every runner cleanup path read-only after a real
# incident (a degenerate glob destroyed the human's own `code-personal` cage
# and its volumes), and relaxing its "names it created THIS run" rule to "any
# run of this harness" is a decision above this file. Raised on rip-cage-sygz.2.
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
if grep -qF "rc destroy --force T-tmp.aaaa" "$LOG2"; then
  pass "T2b: destroy was called by EXACT name (no enumeration, no glob)"
else
  fail "T2b: expected 'rc destroy --force T-tmp.aaaa' in the call log" "$(cat "$LOG2")"
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

FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/docker" <<'FAKEEOF'
#!/usr/bin/env bash
echo "docker $*" >> "$RC_STUB_LOG"
echo "pi 1.2.3"
exit 0
FAKEEOF
chmod +x "${FAKE_BIN}/docker"

# The stub rc for the pi legs: `ls --output json` reports ONE running cage
# named by $RC_STUB_RUNNING; `exec` answers agent:agent; anything else exits 0.
cat > "${PI_ROOT}/rc" <<'STUBEOF'
#!/usr/bin/env bash
echo "rc $*" >> "$RC_STUB_LOG"
if [[ "${1:-}" == "ls" ]]; then
  printf '[{"name":"%s","status":"running"}]\n' "$RC_STUB_RUNNING"
  exit 0
fi
if [[ "${1:-}" == "exec" ]]; then
  echo "agent:agent"
  exit 0
fi
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
if grep -qF "rc exec T-tmp.ours" "$LOG6"; then
  pass "T6b: Tests 3/4 really executed against the registered cage"
else
  fail "T6b: expected 'rc exec T-tmp.ours' in the call log" "$(cat "$LOG6")"
fi
if [[ "$t6_rc" -eq 0 ]]; then
  pass "T6c: the file still exits 0 on the happy path"
else
  fail "T6c: expected exit 0, got $t6_rc" "$t6_out"
fi

echo ""
echo "=== Summary: $FAILURES/$TOTAL failed ==="
echo "TOTALS: PASS=$((TOTAL - FAILURES)) FAIL=${FAILURES}"
[[ "$FAILURES" -eq 0 ]] || exit 1
exit 0
