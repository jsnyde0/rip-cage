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

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0; TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rc-znws-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

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

echo ""
echo "=== Summary: $FAILURES/$TOTAL failed ==="
echo "TOTALS: PASS=$((TOTAL - FAILURES)) FAIL=${FAILURES}"
[[ "$FAILURES" -eq 0 ]] || exit 1
