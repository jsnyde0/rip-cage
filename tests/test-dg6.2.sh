#!/usr/bin/env bash
if ! command -v docker > /dev/null 2>&1; then
  echo "SKIP: Docker not available -- skipping $(basename "$0")"
  exit 0
fi
set -uo pipefail

# Tests for bead dg6.2: --dry-run, input hardening, agent context
# These tests validate behavior WITHOUT requiring Docker containers.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# --- Test 1: rc script is valid bash ---
echo "=== Test 1: rc script is valid bash ==="
if bash -n "$RC" 2>&1; then
  pass "rc is valid bash"
else
  fail "rc has syntax errors"
fi

# =============================================
# Part B: Input hardening (validate_path)
# =============================================

# --- Tests 2, 3, 4: RETIRED with the allowed-roots guard (rip-cage-ely4.9) ---
# They asserted that `rc up` warns when RC_ALLOWED_ROOTS is unset, rejects a
# path outside the roots, and rejects a /code-evil prefix attack against
# /code. ADR-031 D2 deletes the guard: every mount is an explicit line in the
# project's own config now, authored host-side, so there is no surrounding
# root for a path argument to be outside OF and no prefix to attack.
#
# What replaced it is not a narrower version of the same check — it is a
# different one on a better surface. The protected-paths rule reads the cage
# config's whole mount list and refuses a credential store outright, which is
# the accident these three were really aimed at. Its coverage lives in
# tests/test-rc-commands.sh Test 60 (60b in particular), where the assertion
# is "no msb subcommand ran", not merely a non-zero exit.
#
# Tests 5-7 below survive unchanged: validate_path still rejects a
# non-existent path, a non-directory, and control characters. Those are shape
# checks on the argument itself and never depended on the roots.

# --- Test 5: validate_path rejects non-existent path ---
echo ""
echo "=== Test 5: rc up rejects non-existent path ==="
nonexist_err=$(RC_ALLOWED_ROOTS=/tmp "$RC" up /tmp/does-not-exist-xyz123 2>&1) || true
if echo "$nonexist_err" | grep -q "does not exist"; then
  pass "rc up rejects non-existent path"
else
  fail "rc up did not reject non-existent path. Got: $nonexist_err"
fi

# --- Test 6: validate_path rejects non-directory (file) ---
echo ""
echo "=== Test 6: rc up rejects non-directory path ==="
temp_file=$(mktemp)
file_err=$(RC_ALLOWED_ROOTS=/tmp "$RC" up "$temp_file" 2>&1) || true
if echo "$file_err" | grep -q "not a directory"; then
  pass "rc up rejects non-directory path"
else
  fail "rc up did not reject non-directory path. Got: $file_err"
fi
rm -f "$temp_file"

# --- Test 7: validate_path rejects control characters ---
echo ""
echo "=== Test 7: rc up rejects control characters in path ==="
# Use printf to embed a control char in the argument
ctrl_err=$(RC_ALLOWED_ROOTS=/tmp "$RC" up $'/tmp/bad\x01dir' 2>&1) || true
if echo "$ctrl_err" | grep -q "control characters"; then
  pass "rc up rejects control characters"
else
  fail "rc up did not reject control characters. Got: $ctrl_err"
fi

# --- Test 8: validate_path accepts a valid path ---
echo ""
echo "=== Test 8: rc up accepts a valid path (dry-run, no Docker side-effects) ==="
# $test_dir used to be created by Test 2, which retired with the allowed-roots
# guard (rip-cage-ely4.9). Created here instead, where it is actually used --
# a fixture that outlives the case that made it is how a retirement leaves an
# unbound variable behind.
test_dir=$(mktemp -d)
# --dry-run: validation passes, no docker pull/build/create; image-agnostic.
valid_err=$(RC_CAGE_CONF="$(cage_conf_for "$test_dir")" "$RC" --dry-run up "$test_dir" 2>&1) || true
# Should NOT contain path validation errors
if echo "$valid_err" | grep -q "does not exist\|not a directory\|control characters"; then
  fail "rc up rejected valid path. Got: $valid_err"
else
  pass "rc up accepted valid path (dry-run previews action without Docker)"
fi

# --- Test 9: validate_path JSON error output ---
echo ""
echo "=== Test 9: rc up --output json produces JSON error for invalid path ==="
# json_error writes to stdout; human errors go to stderr. Capture both.
# The subject is validate_path's OWN rejection, so the path must be invalid on
# its own terms. /tmp used to qualify only because it sat outside the allowed
# roots, which is no longer a thing a path can be. A regular FILE is the
# shape-invalid case that still maps to PATH_INVALID (a non-existent path
# returns PATH_NOT_FOUND, a different code with its own case above).
_t9_file=$(mktemp)
json_err=$("$RC" --output json up "$_t9_file" 2>/dev/null) || true
rm -f "$_t9_file"
if echo "$json_err" | jq -e '.code == "PATH_INVALID"' >/dev/null 2>&1; then
  pass "--output json produces PATH_INVALID error code"
else
  fail "--output json did not produce PATH_INVALID. Got: $json_err"
fi

# =============================================
# Part A: --dry-run
# =============================================

# --- Test 10: rc up --dry-run does not create container ---
echo ""
echo "=== Test 10: rc up --dry-run prints what would happen ==="
dryrun_dir=$(mktemp -d)
dryrun_out=$(RC_CAGE_CONF="$(cage_conf_for "$dryrun_dir")" "$RC" --dry-run up "$dryrun_dir" 2>&1) || true
if echo "$dryrun_out" | grep -q "Would create\|would_create\|Would build"; then
  pass "--dry-run reports what would happen"
else
  fail "--dry-run did not report action. Got: $dryrun_out"
fi
rmdir "$dryrun_dir" 2>/dev/null || true

# --- Test 11: rc up --dry-run --output json produces dry_run JSON ---
echo ""
echo "=== Test 11: rc up --dry-run --output json produces JSON ==="
dryrun_dir2=$(mktemp -d)
dryrun_json=$(RC_CAGE_CONF="$(cage_conf_for "$dryrun_dir2")" "$RC" --dry-run --output json up "$dryrun_dir2" 2>/dev/null) || true
# Accept any would_*_create action: would_create (image present), would_build_and_create
# (no registry, builds locally), or would_pull_and_create (registry configured + image
# absent — the CI default). The original assertion omitted would_pull_and_create, which
# only surfaced once Test 2 stopped building an image as a side effect.
if echo "$dryrun_json" | jq -e '.dry_run == true and (.action | startswith("would_"))' >/dev/null 2>&1; then
  pass "--dry-run --output json produces correct JSON"
else
  fail "--dry-run --output json incorrect. Got: $dryrun_json"
fi
rmdir "$dryrun_dir2" 2>/dev/null || true

# --- Test 12: rc destroy --dry-run with non-existent container fails ---
echo ""
echo "=== Test 12: rc destroy --dry-run with non-existent container errors ==="
destroy_err=$(RC_ALLOWED_ROOTS=/tmp "$RC" --dry-run destroy nonexistent-container-xyz 2>&1) || true
if echo "$destroy_err" | grep -qi "not found\|error"; then
  pass "--dry-run destroy errors on non-existent container"
else
  fail "--dry-run destroy did not error on non-existent. Got: $destroy_err"
fi

# =============================================
# Part C: Agent context in AGENTS.md
# =============================================

# --- Test 13: AGENTS.md contains agent rules section ---
echo ""
echo "=== Test 13: AGENTS.md contains rc invocation rules ==="
if grep -qi "Rules for AI agents calling rc" "${REPO_ROOT}/AGENTS.md"; then
  pass "AGENTS.md has agent rules section"
else
  fail "AGENTS.md missing agent rules section"
fi

# --- Test 14: AGENTS.md mentions --output json ---
echo ""
echo "=== Test 14: AGENTS.md mentions --output json ==="
if grep -q "\-\-output json" "${REPO_ROOT}/AGENTS.md"; then
  pass "AGENTS.md mentions --output json"
else
  fail "AGENTS.md does not mention --output json"
fi

# --- Test 15: RETIRED (rip-cage-ely4.14) ---
# Asserted that AGENTS.md told a calling agent to set RC_ALLOWED_ROOTS before
# rc up. The allowed-roots guard is deleted (ADR-031 D2: there is nothing left
# to guard once every mount is an explicit line in the cage config), so the
# variable is read by nothing. The assertion had inverted into a control that
# would only stay green while the agent docs kept teaching a dead variable.

# --- Test 16: rc init is removed — verify it returns unknown-command (rip-cage-kt25) ---
echo ""
echo "=== Test 16: rc init returns unknown-command (removed in rip-cage-kt25) ==="
init_err=$("$RC" init /tmp 2>&1) || true
if echo "$init_err" | grep -q "build"; then
  pass "rc init falls through to usage (unknown command)"
else
  fail "rc init did not produce usage output: $init_err"
fi

# --- Test 17: RETIRED with the allowed-roots warning (rip-cage-ely4.9) ---
# It asserted that an unset RC_ALLOWED_ROOTS produces a stderr warning naming
# the variable. The variable is inert and the warning is gone (ADR-031 D2):
# there is no implicit root grant left to warn about, because there are no
# implicit mounts left to grant.

# --- Test 18: --output json --env-file outside workspace does not fail with 'outside allowed roots' ---
echo ""
echo "=== Test 18: rc up with --env-file outside workspace succeeds path validation ==="
env_ws_dir=$(mktemp -d)
env_file_dir=$(mktemp -d)
env_file_path="${env_file_dir}/test.env"
printf "TEST_VAR=hello\n" > "$env_file_path"
env_file_err=$(RC_CONFIG=/dev/null env -u RC_ALLOWED_ROOTS "$RC" --output json up "$env_ws_dir" --env-file "$env_file_path" 2>&1) || true
if echo "$env_file_err" | grep -q "outside allowed roots"; then
  fail "rc up --env-file got 'outside allowed roots' error. Got: $env_file_err"
else
  pass "rc up --env-file outside workspace did not fail with 'outside allowed roots'"
fi
rm -f "$env_file_path"
rmdir "$env_file_dir" 2>/dev/null || true
rmdir "$env_ws_dir" 2>/dev/null || true

# --- Cleanup ---
rmdir "$test_dir" 2>/dev/null || true

echo ""
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
