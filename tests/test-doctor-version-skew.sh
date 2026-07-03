#!/usr/bin/env bash
# Unit tests for _doctor_bd_version_compare (rip-cage-2cks).
#
# rc doctor's version-skew check (D3) compares host bd --version against
# in-cage bd --version. A bare version mismatch is a WARN, never a FAIL — the
# invariant "the store parses" is owned by the workspace-resolution check
# (rip-cage-aq70's honest symptom), not this one. This function is pure
# string logic, so it's tested host-only with stubbed version strings — no
# docker required (the live "correct cage: host==cage -> ok" path is also
# exercised end-to-end by test-doctor-runnability.sh; a genuine live
# skew-but-parses fixture needs a second baked bd release image, which is
# impractical to keep around — see that test file's header for the judgment
# call).
#
# Coverage:
#   V1  identical versions -> ok
#   V2  different versions -> warn (never fail)
#   V3  build-tag differs but numeric version matches -> ok (ignores "(dev)"
#       vs "(Homebrew)" suffix -- see rc comment for rationale)
#   V4  host version string unparseable -> skip
#   V5  cage version string unparseable -> skip

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

# Source the REAL helper function from rc (same awk-extraction idiom as
# test-ls-mode-source.sh — rc's sourcing guard prevents dispatch from running
# when sourced, but we only need this one function body).
eval "$(awk '
  /^_doctor_bd_version_compare\(\)/ { found=1 }
  found { print }
  found && /^\}$/ { exit }
' "$RC")"

if ! declare -F _doctor_bd_version_compare >/dev/null 2>&1; then
  fail "_doctor_bd_version_compare exists in rc" "function not found after extraction"
  echo ""
  echo "=== doctor-version-skew unit tests: 0/$TOTAL passed, $FAILURES failed ==="
  exit 1
fi

# --- V1: identical versions -> ok ---
v1_result=$(_doctor_bd_version_compare "bd version 1.0.5 (Homebrew)" "bd version 1.0.5 (dev)")
if [[ "$v1_result" == ok\ 1.0.5\ 1.0.5 ]]; then
  pass "V1 identical numeric versions -> ok"
else
  fail "V1 identical numeric versions -> ok" "got: $v1_result"
fi

# --- V2: different versions -> warn ---
v2_result=$(_doctor_bd_version_compare "bd version 1.0.5 (Homebrew)" "bd version 1.0.2 (dev)")
if [[ "$v2_result" == warn\ 1.0.5\ 1.0.2 ]]; then
  pass "V2 differing versions -> warn"
else
  fail "V2 differing versions -> warn" "got: $v2_result"
fi

# --- V3: build-tag differs, numeric matches -> ok (not a false-warn on provenance) ---
v3_result=$(_doctor_bd_version_compare "bd version 1.0.5 (Homebrew)" "bd version 1.0.5 (dev)")
if [[ "$v3_result" == ok\ 1.0.5\ 1.0.5 ]]; then
  pass "V3 build-tag-only difference -> ok (ignores provenance suffix)"
else
  fail "V3 build-tag-only difference -> ok (ignores provenance suffix)" "got: $v3_result"
fi

# --- V4: host version unparseable -> skip ---
v4_result=$(_doctor_bd_version_compare "command not found" "bd version 1.0.5 (dev)")
if [[ "$v4_result" == skip* ]]; then
  pass "V4 unparseable host version -> skip"
else
  fail "V4 unparseable host version -> skip" "got: $v4_result"
fi

# --- V5: cage version unparseable -> skip ---
v5_result=$(_doctor_bd_version_compare "bd version 1.0.5 (Homebrew)" "bd: command not found")
if [[ "$v5_result" == skip* ]]; then
  pass "V5 unparseable cage version -> skip"
else
  fail "V5 unparseable cage version -> skip" "got: $v5_result"
fi

echo ""
echo "=== doctor-version-skew unit tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
