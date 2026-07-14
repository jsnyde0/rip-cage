#!/usr/bin/env bash
# Unit tests for _rc_ls_mode_from_source_path helper.
#
# Post schema-v2 (rip-cage-tsf2.10.3 / ADR-021 D9): the egress "mode"
# (observe/block/off) is vestigial. network.mode was dropped from the schema
# (it now loud-rejects as a retired field, ADR-029 — egress is msb default-deny
# at the VM boundary) so the helper no longer reads any config: it returns the
# inert "legacy" sentinel unconditionally. The `mode` column/JSON key on `rc ls`
# is retained (stable contract) but is always "legacy".
#
# Coverage:
#   M1  .rip-cage.yaml present (any content)          -> "legacy"
#   M2  absent .rip-cage.yaml                          -> "legacy"
#   M3  nonexistent source path                        -> "legacy"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

# Source the REAL helper function.
# rc has a sourcing guard (BASH_SOURCE[0] != $0) at the bottom that prevents
# dispatch from running when sourced, but the early initialization code still
# executes. To avoid that, we extract just the _rc_ls_mode_from_source_path
# function body using awk and eval it in this shell. Post-decomposition
# (rip-cage-gto1) the function lives in cli/ls.sh, not the rc shim.
eval "$(awk '
  /^_rc_ls_mode_from_source_path\(\)/ { found=1 }
  found { print }
  found && /^\}$/ { exit }
' "${SCRIPT_DIR}/../cli/ls.sh")"

TMPDIR_TEST=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# --- M1: .rip-cage.yaml present (any content) -> legacy ---
M1_DIR="${TMPDIR_TEST}/m1"
mkdir -p "$M1_DIR"
cat > "${M1_DIR}/.rip-cage.yaml" <<'YAML'
version: 2
network:
  allowed_hosts:
    - api.anthropic.com
YAML

m1_result=$(_rc_ls_mode_from_source_path "$M1_DIR")
if [[ "$m1_result" == "legacy" ]]; then
  pass "M1 present .rip-cage.yaml -> legacy (mode retired)"
else
  fail "M1 present .rip-cage.yaml -> legacy" "got: $m1_result"
fi

# --- M2: no .rip-cage.yaml -> legacy ---
M2_DIR="${TMPDIR_TEST}/m2"
mkdir -p "$M2_DIR"

m2_result=$(_rc_ls_mode_from_source_path "$M2_DIR")
if [[ "$m2_result" == "legacy" ]]; then
  pass "M2 absent .rip-cage.yaml -> legacy"
else
  fail "M2 absent .rip-cage.yaml -> legacy" "got: $m2_result"
fi

# --- M3: source path does not exist -> legacy ---
M3_DIR="${TMPDIR_TEST}/m3-does-not-exist"

m3_result=$(_rc_ls_mode_from_source_path "$M3_DIR")
if [[ "$m3_result" == "legacy" ]]; then
  pass "M3 nonexistent source path -> legacy"
else
  fail "M3 nonexistent source path -> legacy" "got: $m3_result"
fi

echo ""
echo "=== ls-mode-source unit tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
