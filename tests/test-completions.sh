#!/usr/bin/env bash
# test-completions.sh — Host-side tests for rc completions and rc setup
# Run from repo root: bash tests/test-completions.sh
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Syntax validation ---

if zsh --no-rcs -c "source '${SCRIPT_DIR}/../completions/_rc'" 2>/dev/null; then
  pass "completions/_rc zsh syntax valid"
else
  fail "completions/_rc zsh syntax invalid"
fi

if bash -c "source '${SCRIPT_DIR}/../completions/rc.bash'" 2>/dev/null; then
  pass "completions/rc.bash bash syntax valid"
else
  fail "completions/rc.bash bash syntax invalid"
fi

# --- rc completions output ---

if "$RC" completions zsh 2>/dev/null | grep -q "#compdef rc"; then
  pass "rc completions zsh outputs zsh completion script"
else
  fail "rc completions zsh did not output expected content"
fi

if "$RC" completions bash 2>/dev/null | grep -q "_rc_complete"; then
  pass "rc completions bash outputs bash completion script"
else
  fail "rc completions bash did not output expected content"
fi

# --- rc completions error paths (must be stderr-only) ---

stdout=$("$RC" completions 2>/dev/null || true)
if [[ -z "$stdout" ]]; then
  pass "rc completions (no arg) emits nothing to stdout"
else
  fail "rc completions (no arg) leaked to stdout: $stdout"
fi

stdout=$("$RC" completions fish 2>/dev/null || true)
if [[ -z "$stdout" ]]; then
  pass "rc completions fish emits nothing to stdout"
else
  fail "rc completions fish leaked to stdout: $stdout"
fi

# --- Subcommand sync: zsh completions must list all commands in schema ---
# Parse schema JSON via rc schema to get canonical command list

schema_cmds=$("$RC" schema 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for cmd in sorted(d['commands'].keys()):
    print(cmd)
")

missing=0
while IFS= read -r cmd; do
  if ! "$RC" completions zsh 2>/dev/null | grep -q "'${cmd}:"; then
    fail "subcommand sync: '$cmd' in schema but missing from zsh completions"
    missing=$((missing + 1))
  fi
done <<< "$schema_cmds"
if [[ $missing -eq 0 ]]; then
  pass "subcommand sync: all schema commands present in zsh completions"
fi

# --- rc setup idempotency (non-interactive) ---

tmpdir=$(mktemp -d)
echo 'eval "$(rc completions zsh)"' > "${tmpdir}/.zshrc"

if SHELL=/bin/zsh HOME="$tmpdir" "$RC" setup 2>&1 | grep -q "already configured"; then
  pass "rc setup idempotency: skips when eval line present"
else
  fail "rc setup idempotency: did not detect existing eval line"
fi
rm -rf "$tmpdir"

# --- rc setup default-no: empty input should not modify config ---

tmpdir=$(mktemp -d)
touch "${tmpdir}/.zshrc"
SHELL=/bin/zsh HOME="$tmpdir" "$RC" setup < /dev/null 2>&1 || true
if grep -q "rc completions" "${tmpdir}/.zshrc" 2>/dev/null; then
  fail "rc setup default-N: appended to config on empty input"
else
  pass "rc setup default-N: config unchanged on empty input"
fi
rm -rf "$tmpdir"

# --- rc setup echo-y: 'y' should append eval line ---

tmpdir=$(mktemp -d)
touch "${tmpdir}/.zshrc"
echo y | SHELL=/bin/zsh HOME="$tmpdir" "$RC" setup 2>&1 || true
if grep -q "rc completions" "${tmpdir}/.zshrc" 2>/dev/null; then
  pass "rc setup echo-y: appended eval line to config"
else
  fail "rc setup echo-y: did not append eval line"
fi
rm -rf "$tmpdir"

# --- rc schema includes setup ---

if "$RC" schema 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'setup' in d['commands']"; then
  pass "rc schema includes setup"
else
  fail "rc schema missing setup"
fi

# --- Summary ---

echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"
[[ $FAIL -eq 0 ]]
