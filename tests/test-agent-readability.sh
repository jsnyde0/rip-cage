#!/usr/bin/env bash
# test-agent-readability.sh — host-side fixture tests for agent *.md readability
# classification (rip-cage-7wc).
#
# Coverage:
#   A1  readable.md (symlink → existing file) → classified "readable"
#   A2  hostonly.md (broken symlink → target OUTSIDE cage roots) → classified "hostonly"
#   A3  corrupt.md  (broken symlink → target INSIDE cage roots)  → classified "corrupt"
#   A4  _normalize_path — pure-bash BSD/GNU-safe path normalization
#
#   B1  All-host-only scenario (no readable, no corrupt) → 0 failures overall
#   B2  One-corrupt scenario → 1 failure, host-only not counted as failure
#   B3  Mixed scenario (readable + hostonly + corrupt) → failures == corrupt count only
#   B4  All-readable scenario → 0 failures
#
#   C1  _report_agents_classification: all-host-only dir → 0 reported fails
#   C2  _report_agents_classification: one-corrupt, 0 readable, 0 hostonly
#         → fail count == 1, NO phantom PASS line emitted
#   C3  _report_agents_classification: mixed (readable + hostonly + corrupt)
#         → fail count == corrupt count, exactly one summary PASS emitted
#   C4  _report_agents_classification: empty dir → exactly 1 reported fail
#         (the "0 .md files" sentinel is preserved)
#
# Uses RC_AGENTS_DIR + RC_CAGE_ROOTS env var overrides so no container is needed.
#
# Usage: bash tests/test-agent-readability.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the classification helpers
# shellcheck source=./_agent-readability.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_agent-readability.sh"

FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 — $2"; }

# ---------------------------------------------------------------------------
# Fixture management
# ---------------------------------------------------------------------------

FIXTURE_DIR=""

setup_fixture() {
  FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-agent-readability-XXXXXX")
}

teardown_fixture() {
  if [[ -n "${FIXTURE_DIR:-}" && -d "$FIXTURE_DIR" ]]; then
    find "$FIXTURE_DIR" -mindepth 1 -delete 2>/dev/null
    rmdir "$FIXTURE_DIR" 2>/dev/null
  fi
  FIXTURE_DIR=""
}

# ---------------------------------------------------------------------------
# A1: readable.md → "readable"
# ---------------------------------------------------------------------------
echo "=== Unit: _classify_agent_file ==="
test_a1_readable() {
  setup_fixture
  # Real file lives outside the agents dir so it doesn't appear in find results
  local backing_dir="${FIXTURE_DIR}/backing"
  mkdir -p "$backing_dir"
  local real_file="${backing_dir}/real-content.md"
  printf "# hello\n" > "$real_file"
  ln -sf "$real_file" "${FIXTURE_DIR}/readable.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  local result
  result=$(_classify_agent_file "${FIXTURE_DIR}/readable.md" "$cage_roots")
  if [[ "$result" == "readable" ]]; then
    pass "A1: readable.md (symlink → existing file) classified as 'readable'"
  else
    fail "A1: readable.md classification" "expected 'readable', got '${result}'"
  fi
  teardown_fixture
}

# ---------------------------------------------------------------------------
# A2: hostonly.md → "hostonly"
# The target is absolute and OUTSIDE the cage roots.
# ---------------------------------------------------------------------------
test_a2_hostonly() {
  setup_fixture
  # Target does not exist AND is outside the fixture cage root
  ln -sf "/nonexistent-host/dotpi/code-reviewer.md" "${FIXTURE_DIR}/hostonly.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  local result
  result=$(_classify_agent_file "${FIXTURE_DIR}/hostonly.md" "$cage_roots")
  if [[ "$result" == "hostonly" ]]; then
    pass "A2: hostonly.md (broken symlink outside cage roots) classified as 'hostonly'"
  else
    fail "A2: hostonly.md classification" "expected 'hostonly', got '${result}'"
  fi
  teardown_fixture
}

# ---------------------------------------------------------------------------
# A3: corrupt.md → "corrupt"
# The target is absolute and INSIDE the cage roots (should exist but doesn't).
# ---------------------------------------------------------------------------
test_a3_corrupt() {
  setup_fixture
  # Target is inside the fixture cage root but the file is missing
  ln -sf "${FIXTURE_DIR}/missing-target.md" "${FIXTURE_DIR}/corrupt.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  local result
  result=$(_classify_agent_file "${FIXTURE_DIR}/corrupt.md" "$cage_roots")
  if [[ "$result" == "corrupt" ]]; then
    pass "A3: corrupt.md (broken symlink inside cage roots) classified as 'corrupt'"
  else
    fail "A3: corrupt.md classification" "expected 'corrupt', got '${result}'"
  fi
  teardown_fixture
}

test_a1_readable
test_a2_hostonly
test_a3_corrupt

# ---------------------------------------------------------------------------
# A4: _normalize_path — BSD/GNU safe path normalization
# ---------------------------------------------------------------------------
echo ""
echo "=== Unit: _normalize_path ==="

test_a4_normalize_path() {
  local result

  # Absolute path with no normalization needed
  result=$(_normalize_path "/workspace/project/file.md" "")
  if [[ "$result" == "/workspace/project/file.md" ]]; then
    pass "A4a: _normalize_path: absolute path passes through unchanged"
  else
    fail "A4a: _normalize_path absolute" "expected '/workspace/project/file.md', got '${result}'"
  fi

  # Path with /./
  result=$(_normalize_path "/workspace/./project/file.md" "")
  if [[ "$result" == "/workspace/project/file.md" ]]; then
    pass "A4b: _normalize_path: collapses /./ in path"
  else
    fail "A4b: _normalize_path collapse /./'" "expected '/workspace/project/file.md', got '${result}'"
  fi

  # Path with /../
  result=$(_normalize_path "/workspace/other/../project/file.md" "")
  if [[ "$result" == "/workspace/project/file.md" ]]; then
    pass "A4c: _normalize_path: collapses /../ in path"
  else
    fail "A4c: _normalize_path collapse /../" "expected '/workspace/project/file.md', got '${result}'"
  fi

  # Relative path with base dir
  result=$(_normalize_path "../../dotpi/code-reviewer.md" "/home/agent/.rc-context/agents")
  if [[ "$result" == "/home/agent/dotpi/code-reviewer.md" ]]; then
    pass "A4d: _normalize_path: relative path resolved relative to base dir"
  else
    fail "A4d: _normalize_path relative" "expected '/home/agent/dotpi/code-reviewer.md', got '${result}'"
  fi
}

test_a4_normalize_path

# ---------------------------------------------------------------------------
# Scenario tests: use _classify_agents_dir directly (avoids subshell for vars)
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario tests: _classify_agents_dir ==="

# ---------------------------------------------------------------------------
# B1: All-host-only scenario → 0 failures
# ---------------------------------------------------------------------------
test_b1_all_hostonly_zero_failures() {
  setup_fixture
  # Create two host-only broken symlinks (targets outside cage roots)
  ln -sf "/nonexistent-host/dotpi/code-reviewer.md" "${FIXTURE_DIR}/code-reviewer.md"
  ln -sf "/nonexistent-host/dotpi/devops.md" "${FIXTURE_DIR}/devops.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  _classify_agents_dir "$FIXTURE_DIR" "$cage_roots"
  # _CAD_READABLE, _CAD_HOSTONLY, _CAD_CORRUPT set by _classify_agents_dir

  if [[ "$_CAD_CORRUPT" -eq 0 ]]; then
    pass "B1: all-host-only scenario → 0 failures (host-only symlinks SKIPped, readable=${_CAD_READABLE} hostonly=${_CAD_HOSTONLY})"
  else
    fail "B1: all-host-only scenario" "expected corrupt=0, got corrupt=${_CAD_CORRUPT} (readable=${_CAD_READABLE} hostonly=${_CAD_HOSTONLY})"
  fi
  if [[ "$_CAD_HOSTONLY" -eq 2 ]]; then
    pass "B1b: all-host-only → hostonly count is 2"
  else
    fail "B1b: all-host-only hostonly count" "expected 2, got ${_CAD_HOSTONLY}"
  fi
  teardown_fixture
}

# ---------------------------------------------------------------------------
# B2: One corrupt entry → exactly 1 failure, host-only not counted
# ---------------------------------------------------------------------------
test_b2_one_corrupt_one_failure() {
  setup_fixture
  # One host-only (skip) + one corrupt (fail)
  ln -sf "/nonexistent-host/dotpi/code-reviewer.md" "${FIXTURE_DIR}/code-reviewer.md"
  ln -sf "${FIXTURE_DIR}/missing-target.md" "${FIXTURE_DIR}/corrupt.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  _classify_agents_dir "$FIXTURE_DIR" "$cage_roots"

  if [[ "$_CAD_CORRUPT" -eq 1 ]]; then
    pass "B2: one-corrupt scenario → corrupt count=1"
  else
    fail "B2: one-corrupt scenario" "expected corrupt=1, got corrupt=${_CAD_CORRUPT}"
  fi
  if [[ "$_CAD_HOSTONLY" -eq 1 ]]; then
    pass "B2b: host-only count=1 (no bleed between categories)"
  else
    fail "B2b: category counts" "expected hostonly=1, got hostonly=${_CAD_HOSTONLY}"
  fi
  teardown_fixture
}

# ---------------------------------------------------------------------------
# B3: Mixed scenario (readable + hostonly + corrupt) → failures == corrupt count
# ---------------------------------------------------------------------------
test_b3_mixed_failures_match_corrupt_count() {
  setup_fixture
  # Readable entry: real file lives outside the agents dir, symlink inside
  local backing_dir="${FIXTURE_DIR}/backing"
  mkdir -p "$backing_dir"
  local real_file="${backing_dir}/real-content.md"
  printf "# hello\n" > "$real_file"
  ln -sf "$real_file" "${FIXTURE_DIR}/readable.md"

  # Host-only (skip)
  ln -sf "/nonexistent-host/dotpi/code-reviewer.md" "${FIXTURE_DIR}/code-reviewer.md"

  # Two corrupt entries (inside cage root, target missing)
  ln -sf "${FIXTURE_DIR}/missing1.md" "${FIXTURE_DIR}/corrupt1.md"
  ln -sf "${FIXTURE_DIR}/missing2.md" "${FIXTURE_DIR}/corrupt2.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  _classify_agents_dir "$FIXTURE_DIR" "$cage_roots"

  if [[ "$_CAD_CORRUPT" -eq 2 && "$_CAD_READABLE" -eq 1 && "$_CAD_HOSTONLY" -eq 1 ]]; then
    pass "B3: mixed scenario → readable=1 hostonly=1 corrupt=2 (failures == corrupt count)"
  else
    fail "B3: mixed scenario" "expected readable=1 hostonly=1 corrupt=2, got readable=${_CAD_READABLE} hostonly=${_CAD_HOSTONLY} corrupt=${_CAD_CORRUPT}"
  fi
  teardown_fixture
}

# ---------------------------------------------------------------------------
# B4: Pure-readable scenario → 0 failures
# ---------------------------------------------------------------------------
test_b4_all_readable_zero_failures() {
  setup_fixture
  # Real file lives outside the agents dir; the symlink inside is what we classify
  local backing_dir="${FIXTURE_DIR}/backing"
  mkdir -p "$backing_dir"
  local real_file="${backing_dir}/real-content.md"
  printf "# hello\n" > "$real_file"
  ln -sf "$real_file" "${FIXTURE_DIR}/agent1.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  _classify_agents_dir "$FIXTURE_DIR" "$cage_roots"

  if [[ "$_CAD_CORRUPT" -eq 0 && "$_CAD_READABLE" -eq 1 ]]; then
    pass "B4: all-readable scenario → 0 failures, readable=1"
  else
    fail "B4: all-readable scenario" "expected readable=1 corrupt=0, got readable=${_CAD_READABLE} corrupt=${_CAD_CORRUPT}"
  fi
  teardown_fixture
}

# ---------------------------------------------------------------------------
# Run all B scenarios
# ---------------------------------------------------------------------------
test_b1_all_hostonly_zero_failures
test_b2_one_corrupt_one_failure
test_b3_mixed_failures_match_corrupt_count
test_b4_all_readable_zero_failures

# ---------------------------------------------------------------------------
# C-series: end-to-end reporting layer tests using _report_agents_classification
# A local check() shim counts pass/fail calls so we can assert the reported
# outcome without running the full test-skills.sh suite.
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario tests: _report_agents_classification (reporting layer) ==="

# Helper: run _report_agents_classification with a shim check() and return
# counts via output variables _SHIM_PASS and _SHIM_FAIL.
_run_with_shim() {
  local agents_dir="$1"
  local cage_roots="$2"

  _SHIM_PASS=0
  _SHIM_FAIL=0

  # Define a local check() shim that tallies pass/fail calls.
  # shellcheck disable=SC2317,SC2329
  check() {
    local _result="$2"
    if [[ "$_result" == "pass" ]]; then
      _SHIM_PASS=$((_SHIM_PASS + 1))
    else
      _SHIM_FAIL=$((_SHIM_FAIL + 1))
    fi
  }

  _report_agents_classification "$agents_dir" "$cage_roots"

  # Remove the shim so it doesn't bleed into the outer harness.
  unset -f check
}

# ---------------------------------------------------------------------------
# C1: All-host-only dir → 0 reported fails, ≥1 reported passes
# ---------------------------------------------------------------------------
test_c1_all_hostonly_reporting() {
  setup_fixture
  ln -sf "/nonexistent-host/dotpi/code-reviewer.md" "${FIXTURE_DIR}/code-reviewer.md"
  ln -sf "/nonexistent-host/dotpi/devops.md" "${FIXTURE_DIR}/devops.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  _run_with_shim "$FIXTURE_DIR" "$cage_roots"

  if [[ "$_SHIM_FAIL" -eq 0 ]]; then
    pass "C1: all-host-only dir → 0 reported fails (got pass=${_SHIM_PASS} fail=${_SHIM_FAIL})"
  else
    fail "C1: all-host-only reporting" "expected fail=0, got fail=${_SHIM_FAIL} pass=${_SHIM_PASS}"
  fi
  teardown_fixture
}

# ---------------------------------------------------------------------------
# C2: One-corrupt, 0 readable, 0 hostonly → fail==1, pass==0 (no phantom PASS)
# ---------------------------------------------------------------------------
test_c2_one_corrupt_no_phantom_pass() {
  setup_fixture
  ln -sf "${FIXTURE_DIR}/missing-target.md" "${FIXTURE_DIR}/corrupt.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  _run_with_shim "$FIXTURE_DIR" "$cage_roots"

  local ok=true
  if [[ "$_SHIM_FAIL" -ne 1 ]]; then
    fail "C2a: one-corrupt no phantom pass — fail count" "expected fail=1, got fail=${_SHIM_FAIL}"
    ok=false
  fi
  if [[ "$_SHIM_PASS" -ne 0 ]]; then
    fail "C2b: one-corrupt no phantom pass — phantom PASS emitted" "expected pass=0, got pass=${_SHIM_PASS}"
    ok=false
  fi
  if [[ "$ok" == true ]]; then
    pass "C2: one-corrupt, 0 readable, 0 hostonly → fail=1 pass=0 (no phantom PASS)"
  fi
  teardown_fixture
}

# ---------------------------------------------------------------------------
# C3: Mixed (readable + hostonly + 2 corrupt) → fail==2, pass==1 (one summary PASS)
# ---------------------------------------------------------------------------
test_c3_mixed_reporting() {
  setup_fixture
  local backing_dir="${FIXTURE_DIR}/backing"
  mkdir -p "$backing_dir"
  local real_file="${backing_dir}/real-content.md"
  printf "# hello\n" > "$real_file"
  ln -sf "$real_file" "${FIXTURE_DIR}/readable.md"
  ln -sf "/nonexistent-host/dotpi/code-reviewer.md" "${FIXTURE_DIR}/code-reviewer.md"
  ln -sf "${FIXTURE_DIR}/missing1.md" "${FIXTURE_DIR}/corrupt1.md"
  ln -sf "${FIXTURE_DIR}/missing2.md" "${FIXTURE_DIR}/corrupt2.md"

  local cage_roots="${FIXTURE_DIR}:/workspace"
  _run_with_shim "$FIXTURE_DIR" "$cage_roots"

  local ok=true
  if [[ "$_SHIM_FAIL" -ne 2 ]]; then
    fail "C3a: mixed reporting — fail count" "expected fail=2 (corrupt count), got fail=${_SHIM_FAIL}"
    ok=false
  fi
  if [[ "$_SHIM_PASS" -ne 1 ]]; then
    fail "C3b: mixed reporting — pass count" "expected exactly 1 summary PASS, got pass=${_SHIM_PASS}"
    ok=false
  fi
  if [[ "$ok" == true ]]; then
    pass "C3: mixed (readable=1 hostonly=1 corrupt=2) → fail=2 pass=1"
  fi
  teardown_fixture
}

# ---------------------------------------------------------------------------
# C4: Empty dir → exactly 1 reported fail ("0 .md files" sentinel preserved)
# ---------------------------------------------------------------------------
test_c4_empty_dir_reporting() {
  setup_fixture
  # No *.md files created — empty agents dir

  local cage_roots="${FIXTURE_DIR}:/workspace"
  _run_with_shim "$FIXTURE_DIR" "$cage_roots"

  local ok=true
  if [[ "$_SHIM_FAIL" -ne 1 ]]; then
    fail "C4a: empty dir reporting — fail count" "expected fail=1, got fail=${_SHIM_FAIL}"
    ok=false
  fi
  if [[ "$_SHIM_PASS" -ne 0 ]]; then
    fail "C4b: empty dir reporting — spurious PASS" "expected pass=0, got pass=${_SHIM_PASS}"
    ok=false
  fi
  if [[ "$ok" == true ]]; then
    pass "C4: empty dir → exactly 1 fail (\"0 .md files\" sentinel), 0 passes"
  fi
  teardown_fixture
}

test_c1_all_hostonly_reporting
test_c2_one_corrupt_no_phantom_pass
test_c3_mixed_reporting
test_c4_empty_dir_reporting

echo ""
echo "=== Results: $((TOTAL - FAILURES)) passed, ${FAILURES} failed (of ${TOTAL}) ==="
[[ "$FAILURES" -eq 0 ]] || exit 1
