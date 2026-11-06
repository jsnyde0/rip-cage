#!/usr/bin/env bash
set -uo pipefail

# tests/test-host-tool-client.sh -- hermetic proof for rip-cage-jdl2.4 (ADR-032 D6).
#
# Drives the REAL client cage/substrate/host-tool against a FAKE gatekeeper
# (tests/fixtures/host-tool-fake-gatekeeper.py) over AF_UNIX: the client's own
# transport injection, HOST_TOOL_SOCKET. No vsock is ever dialled. Every case
# asserts the exit code and the output; wire cases assert the captured raw
# request line byte for byte.
#
#   argument parsing + typed encoding from list, the wire bytes, the exit-code
#   map for every error kind, both exit-5 cases (connect-stage failure or bad
#   list reply: the three-cause message; failure after the call request was
#   sent: the "command may have run" message), the reply-timeout derivation,
#   --list never carrying a slash, and static checks on the Dockerfile and floor-probe lines.
#
# Fake vocabulary is deliberately generic: tool kh, verb send, slots chat/limit.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
CLIENT="${REPO_ROOT}/cage/substrate/host-tool"
FAKE="${SCRIPT_DIR}/fixtures/host-tool-fake-gatekeeper.py"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# The client runs under its shebang interpreter, so that is what the guard checks.
[ -x /usr/bin/python3 ] || { echo "SKIP: /usr/bin/python3 (the client shebang) not present"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not on PATH (fake gatekeeper)"; exit 0; }

T=$(mktemp -d /tmp/rc-host-tool-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
FAKE_PID=""
stop_fake() {
  if [ -n "$FAKE_PID" ]; then kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=""; fi
}
trap 'stop_fake; rm -rf "$T"' EXIT

SOCK="${T}/gk.sock"
CAP="${T}/capture"
OUT="${T}/out"
ERR="${T}/err"
STOP_MSG='host-tool line stopped answering after the request was sent; the command may have run. Operator: run rc doctor on this cage.'
EXIT_MSG='host-tool line did not answer. Causes: no <cage>.tools.yaml declared for this cage; declaration added but the cage not recreated yet; or the gatekeeper is down. Operator: run rc doctor on this cage.'

LIST_OK='{"ok":true,"result":{"tools":{"kh":{"send":{"timeout":1,"slots":{"chat":"string","limit":"int"}},"slow":{"timeout":1,"slots":{}}}}}}'
OK_REPLY='{"ok":true,"result":"sent 20"}'

# err_reply <kind>  ->  a typed error reply line
err_reply() { printf '{"ok":false,"error":{"kind":"%s","message":"fixed text for %s"}}' "$1" "$1"; }

# start_fake <list-raw> <call-raw> [delay-seconds-for-kh-slow] ; FAKE_DROP=1 closes call connections unanswered
start_fake() {
  stop_fake
  : > "$CAP"
  python3 -I -c '
import json, sys
path, list_raw, call_raw, slow_delay = sys.argv[1:5]
drop = len(sys.argv) > 5
json.dump({"list": {"raw": list_raw},
           "calls": {"*": {"raw": call_raw, "drop": drop},
                     "kh slow": {"raw": call_raw, "delay": float(slow_delay)}}},
          open(path, "w"))
' "$T/table.json" "$1" "$2" "${3:-0}" ${FAKE_DROP:+drop}
  rm -f "$SOCK"
  python3 -I "$FAKE" "$SOCK" "$T/table.json" "$CAP" &
  FAKE_PID=$!
  local _n
  for _n in $(seq 1 50); do [ -S "$SOCK" ] && return 0; sleep 0.1; done
  fail "fake gatekeeper did not come up"
  return 1
}

# run_client <args...>  ->  sets RC; stdout in $OUT, stderr in $ERR
run_client() {
  HOST_TOOL_SOCKET="$SOCK" "$CLIENT" "$@" >"$OUT" 2>"$ERR"
  RC=$?
}

expect() { # <name> <want-rc>
  if [ "$RC" -eq "$2" ]; then pass "$1: exit $2"; else fail "$1: exit $RC, want $2 (stderr: $(cat "$ERR"))"; fi
}
expect_out() { # <name> <fixed-string> (in stdout)
  if grep -qF -- "$2" "$OUT"; then pass "$1: stdout has '$2'"; else fail "$1: stdout lacks '$2': $(cat "$OUT")"; fi
}
expect_err_exact() { # <name> <exact stderr text>
  if [ "$(cat "$ERR")" = "$2" ]; then pass "$1: stderr exact"; else fail "$1: stderr is '$(cat "$ERR")'"; fi
}
# expect_capture <name> <line>...  -- whole capture file equals the lines, each newline-terminated
expect_capture() {
  local name="$1"; shift
  printf '%s\n' "$@" > "$T/expected"
  if cmp -s "$CAP" "$T/expected"; then pass "$name: captured request bytes exact"; else fail "$name: capture differs: $(od -c "$CAP" | head -5)"; fi
}
# expect_stdout_bytes <name> <printf-format>
expect_stdout_bytes() {
  # shellcheck disable=SC2059
  printf "$2" > "$T/expected"
  if cmp -s "$OUT" "$T/expected"; then pass "$1: stdout bytes exact"; else fail "$1: stdout is $(od -c "$OUT" | head -3)"; fi
}
last_request() { tail -n 1 "$CAP"; }

[ -x "$CLIENT" ] || { fail "client $CLIENT missing or not executable"; echo "FAILED: $FAILURES"; exit 1; }

# --- list -------------------------------------------------------------------
start_fake "$LIST_OK" "$OK_REPLY"
run_client --list
expect "list" 0
expect_out "list" "kh"
expect_out "list" "send"
expect_out "list" "chat:string"
expect_out "list" "limit:int"
if grep -q '/' "$OUT"; then fail "list output contains a slash: $(cat "$OUT")"; else pass "list output contains no slash"; fi
expect_capture "list" '{"v":1,"list":true}' 
run_client --json --list
expect "list --json" 0
if [ "$(cat "$OUT")" = "$LIST_OK" ]; then pass "list --json prints the raw reply"; else fail "list --json printed '$(cat "$OUT")'"; fi

# --- ok call, wire bytes ------------------------------------------------------
start_fake "$LIST_OK" "$OK_REPLY"
run_client kh send --chat -100123 --limit 20
expect "ok call" 0
expect_out "ok call" "sent 20"
WANT='{"v":1,"tool":"kh","verb":"send","args":{"chat":"-100123","limit":20}}'
expect_capture "wire: dash value is a string, int slot is an integer" '{"v":1,"list":true}' "$WANT"
expect_stdout_bytes "ok call (result without newline gets one)" 'sent 20\n' 

: > "$CAP"
run_client kh send --chat=hi --limit=20
expect "--slot=value" 0
expect_capture "wire: --limit=20 is integer 20" '{"v":1,"list":true}' '{"v":1,"tool":"kh","verb":"send","args":{"chat":"hi","limit":20}}'
: > "$CAP"
run_client kh send --limit -5
expect_capture "wire: negative int is an integer" '{"v":1,"list":true}' '{"v":1,"tool":"kh","verb":"send","args":{"limit":-5}}'
: > "$CAP"
run_client kh send --limit $'20\n'
expect "int slot with trailing newline" 0
expect_capture "wire: 20 plus newline is the string, not integer 20" '{"v":1,"list":true}' '{"v":1,"tool":"kh","verb":"send","args":{"limit":"20\n"}}'

# stdout newline rule, exact bytes
start_fake "$LIST_OK" '{"ok":true,"result":"line\n"}'
run_client kh send
expect_stdout_bytes "result already ending in newline" 'line\n'
start_fake "$LIST_OK" '{"ok":true,"result":""}'
run_client kh send
expect_stdout_bytes "empty result" '\n'

start_fake "$LIST_OK" "$(err_reply bad-argument)"
run_client kh send --limit 2x
expect "--limit 2x" 2
expect_capture "wire: non-integer for an int slot goes as a string" '{"v":1,"list":true}' '{"v":1,"tool":"kh","verb":"send","args":{"limit":"2x"}}' 
expect_err_exact "error line" "error: bad-argument: fixed text for bad-argument"

run_client --json kh send --limit 2x
expect "--json keeps the exit code" 2
if [ "$(cat "$OUT")" = "$(err_reply bad-argument)" ]; then pass "--json prints the raw error reply"; else fail "--json printed '$(cat "$OUT")'"; fi

# --- every error kind -> exit code --------------------------------------------
for kv in no-such-tool:2 no-such-verb:2 bad-argument:2 request-too-large:2 \
          tool-failed:3 reply-too-large:3 timeout:4 busy:4 unavailable:4; do
  kind="${kv%%:*}"; want="${kv##*:}"
  start_fake "$LIST_OK" "$(err_reply "$kind")"
  run_client kh send --chat x
  expect "kind $kind" "$want"
  expect_err_exact "kind $kind" "error: ${kind}: fixed text for ${kind}"
done

# unknown kind and non-JSON call reply -> 5 (the line gave no typed answer)
start_fake "$LIST_OK" "$(err_reply martian)"
run_client kh send --chat x
expect "unknown error kind" 5
expect_err_exact "unknown error kind (post-send)" "$STOP_MSG"
start_fake "$LIST_OK" "this is not json"
run_client kh send --chat x
expect "non-JSON call reply" 5
expect_err_exact "non-JSON call reply (post-send)" "$STOP_MSG"
start_fake "$LIST_OK" '{"ok":true,"result":5}'
run_client kh send --chat x
expect "non-string result" 5
expect_err_exact "non-string result (post-send)" "$STOP_MSG"
run_client --json kh send --chat x
expect "non-string result, --json (same exit code)" 5
expect_err_exact "non-string result, --json" "$STOP_MSG"
if [ ! -s "$OUT" ]; then pass "non-string result, --json: nothing on stdout"; else fail "--json printed '$(cat "$OUT")'"; fi
FAKE_DROP=1 start_fake "$LIST_OK" "$OK_REPLY"
run_client kh send --chat x
expect "connection closed mid-call" 5
expect_err_exact "connection closed mid-call (post-send)" "$STOP_MSG"
start_fake "$LIST_OK" '{"ok":false,"error":{"kind":"tool-failed","message":"a\nb\u0007c"}}'
run_client kh send --chat x
expect "error message with control characters" 3
expect_err_exact "error message with control characters" 'error: tool-failed: a\nb\x07c'
if [ "$(wc -l < "$ERR")" -eq 1 ]; then pass "control-character error is one stderr line"; else fail "stderr lines $(wc -l < "$ERR")"; fi

# unusable timeouts in the list reply: a bad list reply, exit 5, three-cause message, no traceback
for bad in -10 '"x"' 0 null true 1e999 -1e999; do
  start_fake '{"ok":true,"result":{"tools":{"kh":{"send":{"timeout":'"$bad"',"slots":{}}}}}}' "$OK_REPLY"
  run_client kh send
  expect "list timeout $bad" 5
  expect_err_exact "list timeout $bad" "$EXIT_MSG"
done
# No ceiling on a listed timeout (a loader may accept 120m = 7200; 1e308 is finite).
for big in 7200 1e308; do
  start_fake '{"ok":true,"result":{"tools":{"kh":{"send":{"timeout":'"$big"',"slots":{"limit":"int"}}}}}}' "$OK_REPLY"
  run_client kh send --limit 3
  expect "list timeout $big" 0
  expect_out "list timeout $big" "sent 20"
  expect_capture "list timeout $big: request on the wire" '{"v":1,"list":true}' '{"v":1,"tool":"kh","verb":"send","args":{"limit":3}}'
done

# --- busy reply to list is an answer: 4 ----------------------------------------
start_fake "$(err_reply busy)" "$OK_REPLY"
run_client --list
expect "busy list (--list)" 4
run_client kh send --chat x
expect "busy list (call)" 4
if [ "$(grep -c . "$CAP")" -eq 2 ]; then pass "busy list stops the call from being sent"; else fail "requests after busy list: $(grep -c . "$CAP")"; fi

# --- exit 5 ----------------------------------------------------------------------
stop_fake
rm -f "$SOCK"
run_client --list
expect "dial, nothing at the path" 5
expect_err_exact "dial, nothing at the path" "$EXIT_MSG"

start_fake "$LIST_OK" "$OK_REPLY"
stop_fake   # leaves a stale socket file nobody listens on: connection refused
run_client kh send --chat x
expect "dial, stale socket (refused)" 5
expect_err_exact "dial, stale socket (refused)" "$EXIT_MSG"

start_fake "not json at all" "$OK_REPLY"
run_client --list
expect "non-JSON list reply" 5
expect_err_exact "non-JSON list reply" "$EXIT_MSG"
start_fake "[1,2]" "$OK_REPLY"
run_client --list
expect "list reply that is JSON but not an object" 5

# Connect timeout: a listening AF_UNIX socket with backlog 0 whose one pending
# slot is already taken. Honest limit: Python's timed connect() on AF_UNIX fails
# EAGAIN at once instead of waiting out the timer, so this shape exercises the
# "connect cannot complete -> exit 5 with the one message" branch, not the 2 s
# wait itself (that wait is the vsock leg, bounded by the CONNECT_TIMEOUT
# constant asserted below and proven live by rip-cage-jdl2.6).
stop_fake
rm -f "$SOCK"
python3 -I -c '
import os, socket, subprocess, sys, time
path, client = sys.argv[1:3]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(0)
filler = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
filler.connect(path)
t0 = time.time()
p = subprocess.run([client, "--list"], env=dict(os.environ, HOST_TOOL_SOCKET=path),
                   capture_output=True, text=True, timeout=30)
print("%d %.1f" % (p.returncode, time.time() - t0))
sys.stderr.write(p.stderr)
' "$SOCK" "$CLIENT" >"$OUT" 2>"$ERR"
read -r CT_RC CT_SECS < "$OUT"
if [ "${CT_RC:-}" = "5" ]; then pass "full-backlog connect: exit 5"; else fail "full-backlog connect: exit '${CT_RC:-}'"; fi
if [ "${CT_SECS%.*}" -le 4 ] 2>/dev/null; then pass "connect failure: bounded (${CT_SECS}s)"; else fail "connect timeout took '${CT_SECS:-}'"; fi
expect_err_exact "full-backlog connect" "$EXIT_MSG"
rm -f "$SOCK"
if grep -Eq '^CONNECT_TIMEOUT *= *2$' "$CLIENT" && grep -q 's.settimeout(CONNECT_TIMEOUT)' "$CLIENT"; then pass "connect timeout constant: 2 s, applied before connect"; else fail "connect timeout constant not found"; fi

# --- reply-timeout derivation: listed timeout + 5 s -----------------------------
# The fake lists timeout 1 for kh slow and delays its reply 2 s: a client whose
# deadline was the bare listed timeout (1 s) would give up; the derived 6 s
# deadline receives it. The 8 s case below proves the upper side (gives up near
# 6 s); the constant grep pins the expression "listed timeout + 5".
start_fake "$LIST_OK" "$OK_REPLY" 2
run_client kh slow
expect "slow reply within listed timeout + 5 s" 0
expect_out "slow reply" "sent 20"
# Upper bound: reply delayed 8 s against a 6 s deadline -> exit 5, post-send, 5..8 s.
start_fake "$LIST_OK" "$OK_REPLY" 8
T0=$(python3 -I -c 'import time; print(time.time())')
run_client kh slow
T1=$(python3 -I -c 'import time; print(time.time())')
expect "reply later than listed timeout + 5 s" 5
expect_err_exact "reply later than listed timeout + 5 s" "$STOP_MSG"
if python3 -I -c 'import sys; d = float(sys.argv[2]) - float(sys.argv[1]); sys.exit(0 if 5 <= d < 8 else 1)' "$T0" "$T1"; then pass "client gave up inside [5, 8) s (deadline 6 s)"; else fail "elapsed outside [5, 8): $T0 -> $T1"; fi
if grep -Eq 'timeout *\+ *REPLY_GRACE' "$CLIENT" && grep -Eq '^REPLY_GRACE *= *5$' "$CLIENT"; then pass "derivation constant: listed timeout + REPLY_GRACE (5)"; else fail "reply-timeout derivation not found in client"; fi

# --- usage errors -> 2, one stderr line ---------------------------------------------
start_fake "$LIST_OK" "$OK_REPLY"
for args in "" "kh" "kh send stray" "kh send --chat" "--bogus kh send" "kh send --chat a --chat b"; do
  # shellcheck disable=SC2086
  run_client $args
  expect "usage error '${args}'" 2
  if [ "$(wc -l < "$ERR")" -eq 1 ]; then pass "usage error '${args}': one stderr line"; else fail "usage error '${args}': stderr lines $(wc -l < "$ERR")"; fi
done
if [ ! -s "$CAP" ]; then pass "usage errors send nothing"; else fail "usage errors reached the wire: $(cat "$CAP")"; fi

# --- static: image + floor probe + purity -------------------------------------------
if grep -qE '^  /usr/local/bin/host-tool$' "${REPO_ROOT}/cage/floor/floor-probe.sh"; then pass "floor probe: host-tool in _rc_floor_guard_paths"; else fail "floor probe lacks host-tool guard path"; fi
if grep -q 'path-resolution host-tool' "${REPO_ROOT}/cage/floor/floor-probe.sh"; then pass "floor probe: host-tool PATH-shadow check"; else fail "floor probe lacks the host-tool shadow check"; fi
if grep -q '^COPY cage/substrate/host-tool /usr/local/bin/host-tool$' "${REPO_ROOT}/cage/Dockerfile"; then pass "Dockerfile COPY line"; else fail "Dockerfile COPY line missing"; fi
if grep -q 'chown root:root /usr/local/bin/host-tool' "${REPO_ROOT}/cage/Dockerfile" && grep -q 'chmod 0555 /usr/local/bin/host-tool' "${REPO_ROOT}/cage/Dockerfile"; then pass "Dockerfile chown/chmod 0555 lines"; else fail "Dockerfile chown/chmod lines missing"; fi
if [ "$(head -n 1 "$CLIENT")" = '#!/usr/bin/python3 -I' ]; then pass "client shebang is python3 -I"; else fail "client shebang: $(head -n 1 "$CLIENT")"; fi
RESERVED='appro''val|ho''ok|ca''rd|pol''icy'   # split so this file does not match itself
grep -qwiE "$RESERVED" "$CLIENT" "$0" "$FAKE" 2>/dev/null
case $? in
  1) pass "no reserved vocabulary in client, test, fake" ;;
  0) fail "client/test/fake name a reserved word" ;;
  *) fail "reserved-word grep could not read a file" ;;
esac

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL PASSED"; exit 0; else echo "FAILED: $FAILURES"; exit 1; fi
