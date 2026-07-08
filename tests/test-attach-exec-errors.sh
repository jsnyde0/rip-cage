#!/usr/bin/env bash
# tests/test-attach-exec-errors.sh — rip-cage-9oyh §4 gap-fill: attach/exec
# error-path matrix. EXTENDS the existing attach/exec coverage (2 driver
# refs each per the coverage-gap inventory in
# docs/2026-07-08-rc-decomposition-map.md: test-rc-commands.sh's usage/
# schema/--output-json-allowlist assertions, test-multiplexer-lifecycle.sh's
# live-cage attach path) with the host-side, container-free error matrix. A
# subset is also golden-mastered byte-for-byte in
# tests/golden-master/cases.sh (attach_not_running, exec_missing_separator,
# exec_no_command_after_separator, exec_extra_arg_before_separator,
# exec_not_running_human/json); this file adds the remaining argv-parsing
# edge cases and cross-checks exit codes explicitly (not just byte-diff).
#
# Wired into tests/run-host.sh (host-only tier).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GM_LIB="${SCRIPT_DIR}/golden-master/lib"
# shellcheck source=golden-master/lib/sandbox.sh
source "${GM_LIB}/sandbox.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

gm_sandbox_reset

# --- exec argv-parsing matrix ----------------------------------------------

# A1: no args at all.
gm_capture exec
if [[ "$GM_EXIT" -ne 0 ]] && echo "$GM_ERR" | grep -qi "requires a '--' separator\|Usage: rc exec"; then
  pass "A1: 'rc exec' with no args -- fails loud naming the separator/usage"
else
  fail "A1" "expected non-zero + separator/usage message; got exit=$GM_EXIT stderr=$GM_ERR"
fi

# A2: cage name only, no -- at all.
gm_capture exec some-cage
if [[ "$GM_EXIT" -ne 0 ]] && echo "$GM_ERR" | grep -qi "requires a '--' separator"; then
  pass "A2: 'rc exec <cage>' with no '--' -- fails loud"
else
  fail "A2" "expected non-zero + separator message; got exit=$GM_EXIT stderr=$GM_ERR"
fi

# A3: two positional args before '--' (only one cage-name slot allowed).
gm_capture exec cage-a cage-b -- echo hi
if [[ "$GM_EXIT" -ne 0 ]] && echo "$GM_ERR" | grep -qF "unexpected argument 'cage-b'"; then
  pass "A3: 'rc exec <a> <b> -- cmd' -- names the unexpected second argument"
else
  fail "A3" "expected non-zero + 'unexpected argument' naming cage-b; got exit=$GM_EXIT stderr=$GM_ERR"
fi

# A4: '--' as the very first arg (no cage name at all) -- name_arg empty,
# resolve_name("") falls into auto-select / no-container-found territory.
GM_DOCKER_STATE=absent gm_capture exec -- echo hi
if [[ "$GM_EXIT" -ne 0 ]]; then
  pass "A4: 'rc exec -- cmd' with no cage name -- fails loud (no cage to resolve)"
else
  fail "A4" "expected non-zero exit; got 0. stdout=$GM_OUT stderr=$GM_ERR"
fi

# A5: --output json + missing '--' separator -- the argv-parse error fires
# BEFORE any JSON-mode branching (still a plain stderr message, not JSON --
# proves the separator check runs first, ahead of output-format handling).
gm_capture --output json exec some-cage
if [[ "$GM_EXIT" -ne 0 ]] && echo "$GM_ERR" | grep -qi "requires a '--' separator" && ! echo "$GM_OUT" | grep -q '"code"'; then
  pass "A5: --output json exec with no '--' -- plain stderr usage error, no JSON envelope (argv-parse precedes output-format branching)"
else
  fail "A5" "expected plain-text usage error with no JSON stdout; got exit=$GM_EXIT stdout=$GM_OUT stderr=$GM_ERR"
fi

# --- attach argv-parsing / state matrix -------------------------------------

# A6: attach to a cage in a non-running state (e.g. exited) -- same
# "not running" error as absent (attach doesn't provision).
GM_DOCKER_STATE=exited GM_DOCKER_LABEL_SOURCE_PATH="$(gm_ws_realpath)" gm_capture attach some-cage
if [[ "$GM_EXIT" -ne 0 ]] && echo "$GM_ERR" | grep -qi "not running"; then
  pass "A6: attach to an EXITED (not running) cage -- fails loud, same as absent"
else
  fail "A6" "expected non-zero + 'not running'; got exit=$GM_EXIT stderr=$GM_ERR"
fi

# A7: attach --output json is REJECTED by the global allowlist (attach is
# not in the --output json allowlist) -- this fires before any docker call.
gm_capture --output json attach some-cage
if [[ "$GM_EXIT" -ne 0 ]] && echo "$GM_ERR" | grep -qi "not supported for 'attach'"; then
  pass "A7: --output json attach -- rejected by the global allowlist before dispatch"
else
  fail "A7" "expected the allowlist rejection message; got exit=$GM_EXIT stderr=$GM_ERR"
fi

# --- exec: running cage -> real command execution path is reached ----------

# A8: exec against a RUNNING cage reaches `docker exec` (shim returns 0 for
# `exec`, per lib/fake-bin/docker's catch-all) -- proves the "not running"
# guard is the only thing stopping execution in A2-A6, not some earlier gate.
GM_DOCKER_STATE=running GM_DOCKER_LABEL_SOURCE_PATH="$(gm_ws_realpath)" \
  gm_capture --output json exec some-cage -- echo hi
if [[ "$GM_EXIT" -eq 0 ]] && echo "$GM_OUT" | jq -e '.status == "success"' >/dev/null 2>&1; then
  pass "A8: exec against a RUNNING cage reaches docker exec and reports success"
else
  fail "A8" "expected exit 0 + JSON status=success; got exit=$GM_EXIT stdout=$GM_OUT stderr=$GM_ERR"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
