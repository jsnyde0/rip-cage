#!/usr/bin/env bash
# Unit tests for _rc_ls_mode_from_source_path helper (rip-cage FIX1).
#
# Verifies that cmd_ls derives 'mode' from the source path's .rip-cage.yaml
# (the live source of truth post-promote) rather than the immutable container
# label. Tests run host-side, no Docker required.
#
# Coverage:
#   M1  block mode read from .rip-cage.yaml
#   M2  observe mode read from .rip-cage.yaml
#   M3  absent .rip-cage.yaml → returns "legacy"
#   M4  .rip-cage.yaml present but network.mode is null/absent → returns "legacy"
#   M5  Source path does not exist → returns "legacy"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

# Source the REAL helper function from rc.
# rc has a sourcing guard (BASH_SOURCE[0] != $0) at the bottom that prevents
# dispatch from running when sourced, but the early initialization code still
# executes. To avoid that, we extract just the _rc_ls_mode_from_source_path
# function body from rc using awk and eval it in this shell.
eval "$(awk '
  /^_rc_ls_mode_from_source_path\(\)/ { found=1 }
  found { print }
  found && /^\}$/ { exit }
' "$RC")"

TMPDIR_TEST=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# --- M1: block mode ---
M1_DIR="${TMPDIR_TEST}/m1"
mkdir -p "$M1_DIR"
cat > "${M1_DIR}/.rip-cage.yaml" <<'YAML'
version: 1
network:
  mode: block
  allowed_hosts:
    - api.anthropic.com
YAML

m1_result=$(_rc_ls_mode_from_source_path "$M1_DIR")
if [[ "$m1_result" == "block" ]]; then
  pass "M1 block mode from .rip-cage.yaml"
else
  fail "M1 block mode from .rip-cage.yaml" "got: $m1_result"
fi

# --- M2: observe mode ---
M2_DIR="${TMPDIR_TEST}/m2"
mkdir -p "$M2_DIR"
cat > "${M2_DIR}/.rip-cage.yaml" <<'YAML'
version: 1
network:
  mode: observe
  allowed_hosts:
    - example.com
YAML

m2_result=$(_rc_ls_mode_from_source_path "$M2_DIR")
if [[ "$m2_result" == "observe" ]]; then
  pass "M2 observe mode from .rip-cage.yaml"
else
  fail "M2 observe mode from .rip-cage.yaml" "got: $m2_result"
fi

# --- M3: no .rip-cage.yaml → legacy ---
M3_DIR="${TMPDIR_TEST}/m3"
mkdir -p "$M3_DIR"

m3_result=$(_rc_ls_mode_from_source_path "$M3_DIR")
if [[ "$m3_result" == "legacy" ]]; then
  pass "M3 absent .rip-cage.yaml → legacy"
else
  fail "M3 absent .rip-cage.yaml → legacy" "got: $m3_result"
fi

# --- M4: .rip-cage.yaml present but no network.mode → legacy ---
M4_DIR="${TMPDIR_TEST}/m4"
mkdir -p "$M4_DIR"
cat > "${M4_DIR}/.rip-cage.yaml" <<'YAML'
version: 1
network:
  allowed_hosts:
    - api.anthropic.com
YAML

m4_result=$(_rc_ls_mode_from_source_path "$M4_DIR")
if [[ "$m4_result" == "legacy" ]]; then
  pass "M4 .rip-cage.yaml without network.mode → legacy"
else
  fail "M4 .rip-cage.yaml without network.mode → legacy" "got: $m4_result"
fi

# --- M5: source path does not exist → legacy ---
M5_DIR="${TMPDIR_TEST}/m5-does-not-exist"

m5_result=$(_rc_ls_mode_from_source_path "$M5_DIR")
if [[ "$m5_result" == "legacy" ]]; then
  pass "M5 nonexistent source path → legacy"
else
  fail "M5 nonexistent source path → legacy" "got: $m5_result"
fi

echo ""
echo "=== ls-mode-source unit tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
