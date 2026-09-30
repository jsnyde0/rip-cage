#!/usr/bin/env bash
# test-scratch-cage-registry-guard.sh — rip-cage-znws. Host-tier, no msb/VM.
#
# scratch_cage_register must refuse to PERSIST a name the sweep would later
# refuse (fail at the source, naming the calling test), and must refuse an
# empty / "null" name outright. The registry is pointed at a temp file via
# RC_TEST_CAGE_REGISTRY; the real ~/.cache/rc-t/created-cages is never touched.
#
#   G1  non-conforming name  -> loud stderr naming the caller, registry empty,
#                               still tracked in-process (trap can destroy it)
#   G2  empty name           -> loud, return 1, registry empty
#   G3  literal "null"       -> loud, return 1, registry empty
#   G4  conforming names     -> persisted verbatim, no complaint
#   G5  <hint>.XXXXXX-<subdir>, hint dir under the scratch root -> persisted
#   G6  same shape, no such hint dir -> refused
#   G7  the sweep guard itself: hint-dir shape ours, foreign names not
#   G8  the dash-template shape (<hint>-XXXXXX-<subdir>) ours only with its dir
#   G9  HOME re-pointed after _host-sandbox-lib.sh: source-time root still used

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0; TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rc-znws-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# An empty scratch root, so G1-G4 never depend on what ~/.cache/rc-t holds.
export RC_TEST_TMPDIR="${WORK}/emptyroot"; mkdir -p "$RC_TEST_TMPDIR"

# reg_call <registry> <name> — run register in a child that is itself a named
# script (so the message can name a caller); prints "RC=<n>" then the stderr.
reg_call() {
  local _reg="$1" _name="$2" _drv="${WORK}/fake-caller-test.sh"
  cat > "$_drv" <<DRV
SCRIPT_DIR="${SCRIPT_DIR}"
source "\${SCRIPT_DIR}/_scratch-cage-lib.sh"
scratch_cage_register "\$1"; _r=\$?
echo "RC=\$_r"
echo "TRACKED=\${#_SCRATCH_CAGE_NAMES[@]}"
trap - EXIT INT TERM
DRV
  RC_TEST_CAGE_REGISTRY="$_reg" bash "$_drv" "$_name" 2>&1
}

R1="${WORK}/r1"
out=$(reg_call "$R1" "tmp.abc123-stock-proj")
if [[ ! -s "$R1" ]]; then pass "G1: non-conforming name not written to registry"; else fail "G1: registry written" "$(cat "$R1")"; fi
if grep -q "fake-caller-test.sh" <<<"$out" && grep -q "tmp.abc123-stock-proj" <<<"$out"; then
  pass "G1: refusal is loud and names the calling test + the name"
else fail "G1: message" "$out"; fi
if grep -q "TRACKED=1" <<<"$out"; then pass "G1: name still tracked in-process for trap cleanup"; else fail "G1: tracking" "$out"; fi

R2="${WORK}/r2"
out=$(reg_call "$R2" "")
if [[ ! -s "$R2" ]] && grep -q "RC=1" <<<"$out" && grep -q "TRACKED=0" <<<"$out" && grep -q "fake-caller-test.sh" <<<"$out"; then
  pass "G2: empty name refused loud (rc=1), nothing written or tracked"
else fail "G2" "$out"; fi

R3="${WORK}/r3"
out=$(reg_call "$R3" "null")
if [[ ! -s "$R3" ]] && grep -q "RC=1" <<<"$out" && grep -q "TRACKED=0" <<<"$out" && grep -q "fake-caller-test.sh" <<<"$out"; then
  pass "G3: literal null refused loud (rc=1), nothing written or tracked"
else fail "G3" "$out"; fi

R4="${WORK}/r4"
out=$(reg_call "$R4" "rc-t-hint.AbCdEf-proj"; reg_call "$R4" "T-tmp.AbCdEf")
if [[ "$(cat "$R4" 2>/dev/null)" == $'rc-t-hint.AbCdEf-proj\nT-tmp.AbCdEf' ]] && ! grep -qi "refus" <<<"$out"; then
  pass "G4: conforming names persisted verbatim, no complaint"
else fail "G4" "$(cat "$R4" 2>&1); $out"; fi

# G5-G7: a workspace that is a SUBDIRECTORY of a _host_scratch_mktemp_d dir
# yields "<hint>.XXXXXX-<subdir>" (container_name = parent-basename +
# basename). Accepted only when <hint>.XXXXXX is a real dir under the scratch
# root (RC_TEST_TMPDIR here), so the shape alone never reaches a foreign cage.
ROOT="${WORK}/root"; mkdir -p "${ROOT}/floor.AbC123" "${ROOT}/live-probe.XyZ789"
R5="${WORK}/r5"
out=$(RC_TEST_TMPDIR="$ROOT" reg_call "$R5" "floor.AbC123-stock-proj"; RC_TEST_TMPDIR="$ROOT" reg_call "$R5" "live-probe.XyZ789-workspace")
if [[ "$(cat "$R5" 2>/dev/null)" == $'floor.AbC123-stock-proj\nlive-probe.XyZ789-workspace' ]] && ! grep -q "ERROR" <<<"$out"; then
  pass "G5: <hint>.XXXXXX-<subdir> names whose hint dir is under the scratch root are persisted, no complaint"
else fail "G5" "$(cat "$R5" 2>&1); $out"; fi

R6="${WORK}/r6"
out=$(RC_TEST_TMPDIR="$ROOT" reg_call "$R6" "gone.QqQ111-workspace")
if [[ ! -s "$R6" ]] && grep -q "ERROR" <<<"$out"; then
  pass "G6: the same shape with no such dir under the scratch root is refused"
else fail "G6" "$(cat "$R6" 2>&1); $out"; fi

R7="${WORK}/r7"
RC_TEST_CAGE_REGISTRY="$R7" RC_TEST_TMPDIR="$ROOT" bash -c "SCRIPT_DIR='${SCRIPT_DIR}'; source '${SCRIPT_DIR}/_scratch-cage-lib.sh'; trap - EXIT INT TERM
  _scratch_cage_name_is_ours floor.AbC123-stock-proj && echo OURS1
  _scratch_cage_name_is_ours code-personal || echo FOREIGN1
  _scratch_cage_name_is_ours ../floor.AbC123-x || echo FOREIGN2" > "${WORK}/g7.out" 2>&1
if grep -q OURS1 "${WORK}/g7.out" && grep -q FOREIGN1 "${WORK}/g7.out" && grep -q FOREIGN2 "${WORK}/g7.out"; then
  pass "G7: the sweep's guard accepts the hint-dir shape and still rejects foreign names"
else fail "G7" "$(cat "${WORK}/g7.out")"; fi

mkdir -p "${ROOT}/rc-lifecycle-cr-Ab12Cd"
RC_TEST_CAGE_REGISTRY="${WORK}/r8" RC_TEST_TMPDIR="$ROOT" bash -c "SCRIPT_DIR='${SCRIPT_DIR}'; source '${SCRIPT_DIR}/_scratch-cage-lib.sh'; trap - EXIT INT TERM
  _scratch_cage_name_is_ours rc-lifecycle-cr-Ab12Cd-workspace && echo OURS2
  _scratch_cage_name_is_ours rc-lifecycle-cr-Ab12Cd || echo FOREIGN3
  _scratch_cage_name_is_ours rc-lifecycle-cr-Zz99Zz-workspace || echo FOREIGN4" > "${WORK}/g8.out" 2>&1
if grep -q OURS2 "${WORK}/g8.out" && grep -q FOREIGN3 "${WORK}/g8.out" && grep -q FOREIGN4 "${WORK}/g8.out"; then
  pass "G8: a \$TMPDIR/<hint>-XXXXXX dash-template dir's subdir is ours; the bare dir name and a missing dir are not"
else fail "G8" "$(cat "${WORK}/g8.out")"; fi

# G9: a live test sources _host-sandbox-lib.sh, then re-points HOME at a fake
# home before it registers. The registry and the guard must still use the
# scratch root resolved at source time, not the fake HOME's.
mkdir -p "${WORK}/realhome" "${WORK}/fakehome"
env -u RC_TEST_TMPDIR -u RC_TEST_CAGE_REGISTRY HOME="${WORK}/realhome" bash -c "SCRIPT_DIR='${SCRIPT_DIR}'
  source '${SCRIPT_DIR}/_host-sandbox-lib.sh'
  T=\$(_host_scratch_mktemp_d g9); export HOME='${WORK}/fakehome'
  source '${SCRIPT_DIR}/_scratch-cage-lib.sh'; trap - EXIT INT TERM
  scratch_cage_register \"\$(basename \"\$T\")-ws\"" > "${WORK}/g9.out" 2>&1
_g9_reg=$(cd "${WORK}/realhome/.cache/rc-t" 2>/dev/null && pwd -P)/created-cages
if grep -qE '^g9\.[A-Za-z0-9]{6}-ws$' "$_g9_reg" 2>/dev/null && [[ ! -e "${WORK}/fakehome/.cache/rc-t/created-cages" ]] && ! grep -q ERROR "${WORK}/g9.out"; then
  pass "G9: after HOME is re-pointed, a <hint>.XXXXXX-ws name persists to the source-time scratch root's registry"
else fail "G9" "$(cat "${WORK}/g9.out"; cat "$_g9_reg" 2>&1)"; fi

echo ""
echo "=== Summary: $FAILURES/$TOTAL failed ==="
echo "TOTALS: PASS=$((TOTAL - FAILURES)) FAIL=${FAILURES}"
[[ "$FAILURES" -eq 0 ]] || exit 1
