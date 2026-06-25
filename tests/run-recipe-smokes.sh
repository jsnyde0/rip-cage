#!/usr/bin/env bash
# run-recipe-smokes.sh — Generic name-free in-cage recipe-test runner.
#
# Globs /usr/local/lib/rip-cage/recipe-tests/*.sh and runs EVERY *.sh present.
# Accumulates failures — does NOT abort at first failure (no set -e here),
# no subshell/pipe that loses child exit, no || true swallowing.
# Exits non-zero if any smoke test failed.
# Empty/absent recipe-tests dir = clean exit 0 (minimal cage is fine).
#
# The recipe-tests dir MUST be root:root (ADR-027 D1 dir-ownership-is-the-write-gate):
# only root-installed smoke tests run. The runner itself is baked floor — name-free,
# no guard or recipe names appear in this script.
#
# Mirror discipline: mirrors run-host.sh accumulate-don't-abort pattern.

set -uo pipefail

RECIPE_TESTS_DIR="/usr/local/lib/rip-cage/recipe-tests"
RUNNER_FAILURES=0
RUNNER_TOTAL=0

if [[ ! -d "$RECIPE_TESTS_DIR" ]]; then
  echo "INFO: $RECIPE_TESTS_DIR absent — no recipe smoke tests installed (minimal cage)"
  exit 0
fi

# Collect all *.sh in the recipe-tests dir.
# Use find to avoid glob-expansion issues when no files match.
mapfile -t _SMOKE_TESTS < <(find "$RECIPE_TESTS_DIR" -maxdepth 1 -name '*.sh' -type f | sort)

if [[ "${#_SMOKE_TESTS[@]}" -eq 0 ]]; then
  echo "INFO: $RECIPE_TESTS_DIR is empty — no recipe smoke tests to run (minimal cage)"
  exit 0
fi

echo "=== Recipe Smoke Tests (run-recipe-smokes.sh) ==="
echo "Found ${#_SMOKE_TESTS[@]} smoke test(s) in $RECIPE_TESTS_DIR"
echo ""

for _smoke in "${_SMOKE_TESTS[@]}"; do
  RUNNER_TOTAL=$((RUNNER_TOTAL + 1))
  echo "--- Running: $_smoke ---"
  _smoke_rc=0
  # Run WITHOUT subshell pipe (would lose exit code). Capture exit directly.
  bash "$_smoke"
  _smoke_rc=$?
  if [[ "$_smoke_rc" -ne 0 ]]; then
    echo "SMOKE-FAIL [$RUNNER_TOTAL] $(basename "$_smoke") exited $_smoke_rc"
    RUNNER_FAILURES=$((RUNNER_FAILURES + 1))
  else
    echo "SMOKE-PASS [$RUNNER_TOTAL] $(basename "$_smoke")"
  fi
  echo ""
done

echo "=== Recipe Smoke Summary: ${RUNNER_TOTAL} test(s) run, ${RUNNER_FAILURES} failed ==="

if [[ "$RUNNER_FAILURES" -gt 0 ]]; then
  exit 1
fi
exit 0
