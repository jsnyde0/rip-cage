#!/usr/bin/env bash
# tests/test-reload-exit-trap-seam.sh — rip-cage-9oyh §3(vi): the reload
# EXIT-trap side effect (rc:5988 `trap "rmdir '$lock_dir' ..." EXIT` in
# cmd_reload) is a FILESYSTEM effect the stdout/stderr/exit golden master
# cannot see. A split that drops or rescopes the trap leaks $lock_dir, and
# the NEXT `rc reload` hits the lock guard (rc:5981-5984) -> exit 3.
#
# Two rev.2 construction requirements this test honors:
#   (1) The trap is reachable only AFTER the reload docker gates (container
#       exists, verify_rc_container, state==running, workspace label
#       non-empty + dir exists) -- so the shim presents a RUNNING container
#       with a valid rc.source.path label pointing at a REAL directory, not
#       a bare stub.
#   (2) The EXIT trap fires at SHELL exit, not function return -- so the
#       two-run case runs each `cmd_reload` in a SEPARATE bash process (a
#       fresh `bash -c` subshell each time). Two in-process calls would
#       leave run-1's $lock_dir (trap unfired within the same process) and
#       spuriously fail run-2.
#
# `cmd_reload` naturally terminates (via `exit`, not `return`) once it hits
# `_config_read_applied`'s "container predates rc reload support" branch
# (no applied-config snapshot in our fixture) -- AFTER the trap is set
# (rc:5988), which is exactly what this test needs: it doesn't require a
# full successful reload, only that execution passes the trap-set line.
#
# Wired into tests/run-host.sh (host-only tier).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
GM_FAKEBIN="${SCRIPT_DIR}/golden-master/lib/fake-bin"
FAILURES=0
TEST_HOME=""
TEST_WS=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

unset RC_CONFIG_GLOBAL

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  return 0
}
trap cleanup EXIT

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-reload-trap-XXXXXX")
mkdir -p "${TEST_HOME}/.config/rip-cage"
cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
touch "${TEST_HOME}/.config/rip-cage/tools.yaml"
TEST_WS="${TEST_HOME}/workspace"
mkdir -p "$TEST_WS"
TEST_WS_REAL="$(cd "$TEST_WS" && pwd -P)"

NAME="reload-trap-test-cage"
LOCK_DIR="${TEST_HOME}/.cache/rip-cage/${NAME}/.reload.lock.d"

# run_cmd_reload — a FRESH bash process each call (requirement 2 above).
run_cmd_reload() {
  PATH="${GM_FAKEBIN}:${PATH}" \
    HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    GM_DOCKER_STATE=running GM_DOCKER_LABEL_SOURCE_PATH="$TEST_WS_REAL" \
    GM_DOCKER_LABEL_EGRESS=on \
    bash -c "
      source '$RC' 2>/dev/null
      cmd_reload '$NAME'
    "
  echo "$?"
}

# ---------------------------------------------------------------------------
# Run 1: cmd_reload reaches the trap-set line (rc:5988) and then exits
# (naturally, via the "predates rc reload support" no-applied-snapshot
# branch) -- assert $lock_dir is ABSENT afterward.
# ---------------------------------------------------------------------------
RUN1_EXIT=$(run_cmd_reload)

if [[ "$RUN1_EXIT" -ne 3 ]]; then
  pass "run 1: cmd_reload does not hit the lock-contention guard (exit=$RUN1_EXIT, not 3 -- lock was never held by a stale prior run)"
else
  fail "run 1 exit code" "expected non-3 (no pre-existing lock), got exit 3"
fi

if [[ ! -d "$LOCK_DIR" ]]; then
  pass "run 1: \$lock_dir is ABSENT after cmd_reload exits (EXIT trap fired)"
else
  fail "run 1 lock_dir cleanup" "\$lock_dir ($LOCK_DIR) still exists after cmd_reload exited -- EXIT trap did not fire/fired in the wrong scope"
fi

# ---------------------------------------------------------------------------
# Run 2 (SEPARATE process): must NOT hit the lock guard (exit 3). If run 1
# leaked the lock (trap dropped by a future refactor), run 2's `mkdir
# "$lock_dir"` fails and cmd_reload exits 3 here.
# ---------------------------------------------------------------------------
RUN2_EXIT=$(run_cmd_reload)

if [[ "$RUN2_EXIT" -ne 3 ]]; then
  pass "run 2 (separate process): does not hit exit 3 -- run 1's lock did not leak across the two-run boundary"
else
  fail "run 2 exit code" "got exit 3 (lock contention) -- run 1 leaked \$lock_dir, meaning the EXIT trap (rc:5988) did not fire or was dropped"
fi

if [[ ! -d "$LOCK_DIR" ]]; then
  pass "run 2: \$lock_dir is ABSENT after cmd_reload exits (EXIT trap fired again, independently)"
else
  fail "run 2 lock_dir cleanup" "\$lock_dir still exists after run 2"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
