#!/usr/bin/env bash
# Tier 1 (host-unit, no docker) tests for _bd_host_preflight helper.
# Invokes the internal 'bd-preflight-test' entry point in rc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"

pass=0; fail=0

check() {
  local desc="$1" expected_exit="$2" expected_out="$3" beads_dir="$4" dolt_mode="$5"
  local actual_out actual_exit=0
  actual_out=$("$RC" __bd-preflight-test "$beads_dir" "$dolt_mode" 2>/dev/null) || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]] && [[ "$actual_out" == *"$expected_out"* ]]; then
    echo "PASS: $desc"
    pass=$(( pass + 1 ))
  else
    echo "FAIL: $desc"
    echo "  expected exit $expected_exit, got $actual_exit"
    echo "  expected out to contain: $expected_out"
    echo "  actual out: $actual_out"
    fail=$(( fail + 1 ))
  fi
}

TMPDIR_FIXTURE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# State 1: embedded mode — skip check entirely
mkdir -p "$TMPDIR_FIXTURE/embedded/.beads"
check "embedded mode skips check" 0 "not applicable (embedded mode)" \
  "$TMPDIR_FIXTURE/embedded/.beads" "embedded"

# State 2: unset dolt_mode — also skip check
mkdir -p "$TMPDIR_FIXTURE/unset/.beads"
check "unset dolt_mode skips check" 0 "not applicable (embedded mode)" \
  "$TMPDIR_FIXTURE/unset/.beads" ""

# State 3: server-mode, port file missing (case A)
mkdir -p "$TMPDIR_FIXTURE/missing/.beads"
check "port file missing (case A)" 1 "port file missing" \
  "$TMPDIR_FIXTURE/missing/.beads" "server"

# State 4: server-mode, port file stale (case B) — pick a port, verify nothing answers first
STALE_PORT=59998
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import socket; s=socket.socket(); s.settimeout(0.2); s.connect(('127.0.0.1',$STALE_PORT))" 2>/dev/null; then
    echo "SKIP: stale-port test (port $STALE_PORT is unexpectedly in use)"
  else
    mkdir -p "$TMPDIR_FIXTURE/stale/.beads"
    printf '%d\n' "$STALE_PORT" > "$TMPDIR_FIXTURE/stale/.beads/dolt-server.port"
    check "stale port (case B)" 1 "stale port ${STALE_PORT}" \
      "$TMPDIR_FIXTURE/stale/.beads" "server"
  fi
else
  mkdir -p "$TMPDIR_FIXTURE/stale/.beads"
  printf '%d\n' "$STALE_PORT" > "$TMPDIR_FIXTURE/stale/.beads/dolt-server.port"
  check "stale port (case B)" 1 "stale port ${STALE_PORT}" \
    "$TMPDIR_FIXTURE/stale/.beads" "server"
fi

# State 5: server-mode, port file corrupt (case C) — non-numeric content
mkdir -p "$TMPDIR_FIXTURE/corrupt/.beads"
printf 'not-a-number\n' > "$TMPDIR_FIXTURE/corrupt/.beads/dolt-server.port"
check "corrupt port file (case C)" 1 "corrupt port file" \
  "$TMPDIR_FIXTURE/corrupt/.beads" "server"

# State 5b: empty port file — also case C (corrupt)
mkdir -p "$TMPDIR_FIXTURE/empty/.beads"
printf '' > "$TMPDIR_FIXTURE/empty/.beads/dolt-server.port"
check "empty port file (case C, empty)" 1 "corrupt port file" \
  "$TMPDIR_FIXTURE/empty/.beads" "server"

# State 5c: zero port — also case C
mkdir -p "$TMPDIR_FIXTURE/zero/.beads"
printf '0\n' > "$TMPDIR_FIXTURE/zero/.beads/dolt-server.port"
check "zero port (case C, out-of-range)" 1 "corrupt port file" \
  "$TMPDIR_FIXTURE/zero/.beads" "server"

# State 5d: out-of-range port — also case C
mkdir -p "$TMPDIR_FIXTURE/outrange/.beads"
printf '65536\n' > "$TMPDIR_FIXTURE/outrange/.beads/dolt-server.port"
check "out-of-range port (case C, >65535)" 1 "corrupt port file" \
  "$TMPDIR_FIXTURE/outrange/.beads" "server"

# State 6 (optional): server-mode, port file healthy — bind to port 0 and read back assigned port
LISTENER_PID=""
if command -v python3 >/dev/null 2>&1; then
  # Use a temp file to communicate the assigned port from the listener process
  PORT_FILE=$(mktemp)
  python3 -c "
import socket, time, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0))
s.listen(1)
port = s.getsockname()[1]
with open(sys.argv[1], 'w') as f:
    f.write(str(port))
time.sleep(10)
" "$PORT_FILE" &
  LISTENER_PID=$!
  # Wait for the port file to be written (up to 2 seconds)
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$PORT_FILE" ]] && break
    sleep 0.1
  done
  HEALTHY_PORT=$(cat "$PORT_FILE" 2>/dev/null || true)
  rm -f "$PORT_FILE"
  if [[ -n "$HEALTHY_PORT" ]] && [[ "$HEALTHY_PORT" =~ ^[0-9]+$ ]]; then
    mkdir -p "$TMPDIR_FIXTURE/healthy/.beads"
    printf '%d\n' "$HEALTHY_PORT" > "$TMPDIR_FIXTURE/healthy/.beads/dolt-server.port"
    check "healthy server (case healthy)" 0 "dolt reachable on 127.0.0.1:${HEALTHY_PORT}" \
      "$TMPDIR_FIXTURE/healthy/.beads" "server"
  else
    echo "SKIP: healthy-state test (could not read assigned port from listener)"
  fi
  kill "$LISTENER_PID" 2>/dev/null || true
  LISTENER_PID=""
else
  echo "SKIP: healthy-state test (python3 not available)"
fi

echo "---"
echo "=== dolt-server.port env-injection validation (rip-cage-a0h item (a), ADR-007 D8 rescope) ==="
echo "==="

# _bd_dolt_port_inject_arg — validates .beads/dolt-server.port content BEFORE
# it is used to build the BEADS_DOLT_SERVER_PORT env-injection arg (rc:~1891
# residual). Mirrors the validation predicate in _bd_host_preflight (rc:4372).
# On invalid content: warns (naming the file) to stderr, emits NOTHING on
# stdout (skip injection), and returns 0 (warn-not-fail — ADR-007 D8; bd is
# optional and must never block the container). Exercised via the hidden
# `__bd-port-inject-test` CLI entry point (sibling of __bd-preflight-test).
check_inject() {
  local desc="$1" port_file="$2" expect_stdout="$3" expect_stderr_contains="$4"
  local actual_stdout actual_stderr actual_exit=0
  actual_stdout=$("$RC" __bd-port-inject-test "$port_file" 2>/tmp/rc-inject-test-stderr.$$) || actual_exit=$?
  actual_stderr=$(cat "/tmp/rc-inject-test-stderr.$$" 2>/dev/null)
  rm -f "/tmp/rc-inject-test-stderr.$$"

  local ok=true
  [[ "$actual_exit" -eq 0 ]] || ok=false
  [[ "$actual_stdout" == "$expect_stdout" ]] || ok=false
  if [[ -n "$expect_stderr_contains" ]]; then
    [[ "$actual_stderr" == *"$expect_stderr_contains"* ]] || ok=false
  else
    [[ -z "$actual_stderr" ]] || ok=false
  fi

  if $ok; then
    echo "PASS: $desc"
    pass=$(( pass + 1 ))
  else
    echo "FAIL: $desc"
    echo "  expected exit 0, got $actual_exit"
    echo "  expected stdout: '$expect_stdout' — actual: '$actual_stdout'"
    echo "  expected stderr to contain: '$expect_stderr_contains' — actual: '$actual_stderr'"
    fail=$(( fail + 1 ))
  fi
}

TMPDIR_INJECT=$(mktemp -d)

# Missing file: no injection, no warning, exit 0 (existing behavior preserved).
check_inject "missing port file: no injection, no warning" \
  "${TMPDIR_INJECT}/nonexistent/dolt-server.port" "" ""

# Valid port: injected verbatim, no warning.
mkdir -p "${TMPDIR_INJECT}/valid"
printf '5000\n' > "${TMPDIR_INJECT}/valid/dolt-server.port"
check_inject "valid port: injected as BEADS_DOLT_SERVER_PORT" \
  "${TMPDIR_INJECT}/valid/dolt-server.port" "BEADS_DOLT_SERVER_PORT=5000" ""

# Invalid (non-integer) content: NOT injected, warns naming the file, exit 0.
mkdir -p "${TMPDIR_INJECT}/corrupt"
printf 'not-a-number\n' > "${TMPDIR_INJECT}/corrupt/dolt-server.port"
check_inject "corrupt (non-integer) port: not injected, warns naming the file, exit 0" \
  "${TMPDIR_INJECT}/corrupt/dolt-server.port" "" "${TMPDIR_INJECT}/corrupt/dolt-server.port"

# Out-of-range content: NOT injected, warns, exit 0.
mkdir -p "${TMPDIR_INJECT}/outrange"
printf '65536\n' > "${TMPDIR_INJECT}/outrange/dolt-server.port"
check_inject "out-of-range port: not injected, warns, exit 0" \
  "${TMPDIR_INJECT}/outrange/dolt-server.port" "" "expected an integer port 1-65535"

# Zero: NOT injected, warns, exit 0.
mkdir -p "${TMPDIR_INJECT}/zero"
printf '0\n' > "${TMPDIR_INJECT}/zero/dolt-server.port"
check_inject "zero port: not injected, warns, exit 0" \
  "${TMPDIR_INJECT}/zero/dolt-server.port" "" "expected an integer port 1-65535"

rm -rf "$TMPDIR_INJECT"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
