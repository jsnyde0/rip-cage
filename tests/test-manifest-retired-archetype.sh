#!/usr/bin/env bash
# Host-side unit test: a manifest declaring a RETIRED archetype (MEDIATOR)
# must be rejected with an ACTIONABLE message, not fall into the generic
# "unknown archetype" arm (cli/lib/manifest_checks.sh, the `*)` case at the
# end of the archetype validation switch).
#
# Fable rider on the hard-fail-stands ruling: the retired-archetype
# rejection must name (a) the retired archetype, (b) the offending file +
# tools[idx] ('name') entry, (c) that it was retired in the msb migration
# (ADR-029 D2/D3), (d) the exact fix (delete the entry).
#
# MEDIATOR is the only retired ARCHETYPE token confirmed against
# docs/decisions/ADR-029-msb-migration.md D2 (in-cage security engine
# deletion, "the MEDIATOR archetype's launch machinery" named explicitly)
# and git history (cae1811 "S4 -- engine deletion sweep
# (router/firewall/mediator retired)"). ssh was never an ARCHETYPE value --
# only a config field (network.ssh.allowed_hosts etc, retired by ADR-029 D3,
# cfa2a33), so no ssh-archetype case arm is added here.
#
# Coverage:
#   R1  MEDIATOR archetype entry aborts non-zero
#   R2  error names the archetype ('MEDIATOR')
#   R3  error names the offending file + tools[idx] ('name') entry
#   R4  error says "retired in the msb migration" and cites ADR-029 D2/D3
#   R5  error gives the exact fix: delete this entry from <file>
#   R6  error does NOT fall into the generic "unknown 'archetype' value" arm
#
# No docker/msb required -- pure host-side manifest validation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

setup_manifest_sandbox() {
  local fixture="$1"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-retired-archetype-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_load in the sandbox. stdout discarded; stderr to $1.
run_manifest_load() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_load" 2>"$stderr_file"
}

setup_manifest_sandbox "manifest-hostile-retired-mediator-archetype.yaml"
manifest_file="${TEST_HOME}/.config/rip-cage/tools.yaml"

stderr_file=$(mktemp)
exit_code=0
run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
stderr_content=$(cat "$stderr_file")

# R1: aborts non-zero
if [[ "$exit_code" -ne 0 ]]; then
  pass "R1 MEDIATOR archetype entry aborts non-zero (exit=$exit_code)"
else
  fail "R1 expected non-zero exit for retired MEDIATOR archetype, got exit=$exit_code"
fi

# R2: names the archetype
if grep -q "MEDIATOR" "$stderr_file"; then
  pass "R2 error names the retired archetype 'MEDIATOR'"
else
  fail "R2 error does not name 'MEDIATOR': $stderr_content"
fi

# R3: names the offending file + tools[idx] ('name') entry
if grep -q "$manifest_file" "$stderr_file" && grep -q "legacy-mediator" "$stderr_file"; then
  pass "R3 error names the offending file + tools[idx] ('legacy-mediator') entry"
else
  fail "R3 error does not name file+entry: $stderr_content"
fi

# R4: says "retired in the msb migration" and cites ADR-029 D2/D3
if grep -qi "retired in the msb migration" "$stderr_file" && grep -q "ADR-029" "$stderr_file"; then
  pass "R4 error says 'retired in the msb migration' and cites ADR-029"
else
  fail "R4 error missing msb-migration retirement framing or ADR-029 citation: $stderr_content"
fi

# R5: gives the exact fix -- delete this entry from <file>
if grep -qi "delete this entry from" "$stderr_file" && grep -q "$manifest_file" "$stderr_file"; then
  pass "R5 error gives the exact fix: delete this entry from <file>"
else
  fail "R5 error does not give the 'delete this entry from <file>' fix: $stderr_content"
fi

# R6: does NOT fall into the generic "unknown 'archetype' value" arm
if grep -q "unknown 'archetype' value" "$stderr_file"; then
  fail "R6 retired MEDIATOR archetype fell into the generic 'unknown archetype' arm: $stderr_content"
else
  pass "R6 retired MEDIATOR archetype did not fall into the generic 'unknown archetype' arm"
fi

rm -f "$stderr_file"
teardown_manifest_sandbox

echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES test(s)"
  exit 1
fi
echo "All tests passed."
