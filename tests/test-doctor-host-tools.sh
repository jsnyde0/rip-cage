#!/usr/bin/env bash
set -uo pipefail

# tests/test-doctor-host-tools.sh -- host-tier proof for rip-cage-jdl2.6
# (ADR-032 D7): rc doctor's "Host tools" section (human and JSON arms), the
# not-found orphan line, and the host-side half of rc test's generic route
# checks (the arm keyed on the rc.host-tools label, the --list comparison
# against tools.json, nothing on the host stopped). Runs the REAL rc behind
# the fake runtime (tests/_fake-runtime-lib.sh) plus a thin msb wrapper that
# answers `host-tool --list --json` from a fixture; no cage, no docker, no msb.
# The in-guest half (tests/test-host-tool.sh) and the live route sample are the
# driver's: they need a built image.
#
# Cases (names are the PASS/FAIL labels):
#   D1  declared, gatekeeper alive, no drift  D1b possession-mode verb
#   D2  none declared (label-less and label=absent, no file): no drift
#   D3  dead gatekeeper                       D4  alive on a stopped cage
#   D5  presence drift: file added (label absent, and label MISSING)
#   D6  presence drift: file removed          D7  contents drift
#   D8  not-found with a running gatekeeper (human and JSON), and without
#   T1-T7  rc test: arm selection, list vs tools.json (never the file), busy,
#          drift line, nothing stopped, JSON arm
#   S1  Dockerfile / suite-list static checks

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not on PATH (the gatekeeper stand-in)"; exit 0; }

# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"

T=$(mktemp -d /tmp/rc-dht-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
LOG="${T}/calls.log"
: > "$LOG"
FAKE_BIN=$(fake_runtime_bin "$LOG")
SLEEPERS=()
cleanup() {
  local _p
  for _p in ${SLEEPERS[@]+"${SLEEPERS[@]}"}; do kill -KILL "$_p" 2>/dev/null; done
  rm -rf "$T" "$FAKE_BIN"
}
trap cleanup EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_STATE_HOME="${T}/home/.local/state"
export RC_STATE_DIR="${T}/st"
unset RC_PYTHON3 RC_CAGE_CONF
mkdir -p "$HOME/.claude/projects" "$T/ws" "$T/bin" "$T/conf" "$T/wrap" "$T/st"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tool"; chmod 0755 "$T/bin/tool"

# The msb wrapper: answers the client's --list from $FAKE_LIST_FILE (exit
# $FAKE_LIST_EXIT), everything else goes to the shared fake.
cat > "$T/wrap/msb" <<WRAP
#!/usr/bin/env bash
if [[ "\${1:-}" == "exec" && "\$*" == *"/usr/local/bin/host-tool --list --json"* ]]; then
  echo "msb \$*" >> "$LOG"
  [[ -f "\${FAKE_LIST_FILE:-}" ]] && cat "\${FAKE_LIST_FILE}"
  exit "\${FAKE_LIST_EXIT:-0}"
fi
exec "$FAKE_BIN/msb" "\$@"
WRAP
chmod +x "$T/wrap/msb"
export PATH="${T}/wrap:${FAKE_BIN}:${PATH}"

NAME=cagea
CONF="$T/conf/c.yaml"
DECL="$T/conf/c.tools.yaml"
SD="$RC_STATE_DIR/$NAME"
INSPECT="$T/inspect.json"
export FAKE_MSB_INSPECT_FILE="$INSPECT"
: > "$CONF"

mk_decl() { # FILE [TIMEOUT] [SECRET]
  {
    printf 'tools:\n  demo:\n    verbs:\n      go:\n        argv: ["%s/bin/tool"]\n        timeout: %s\n' "$T" "${2:-30s}"
    printf '      peek:\n        argv: ["%s/bin/tool", "x"]\n        timeout: 5s\n        returns_secret: %s\n' "$T" "${3:-false}"
  } > "$1"
}

# mk_inspect STATUS HOSTLABEL  -- HOSTLABEL: present|absent|missing
mk_inspect() {
  local _status="$1" _hl="$2"
  jq -n --arg st "$_status" --arg ws "$T/ws" --arg conf "$CONF" --arg sd "$SD" --arg hl "$_hl" \
    '{status: $st, updated_at: "2026-01-01T00:00:00Z",
      config: {labels: ({"rc.source.path": $ws, "rc.cage-conf": $conf}
                        + (if $hl == "missing" then {} else {"rc.host-tools": $hl} end)
                        + (if $hl == "present" then {"rc.state-dir": $sd} else {} end)),
               mounts: [{host: $ws}]}}' > "$INSPECT"
  rm -f "$INSPECT.removed"
}

# The normalized declaration the way rc up writes tools.json.
write_tools_json() { # DIR
  mkdir -p "$1"
  local _m="$T/mounts"
  printf '%s\n' "$T/ws" > "$_m"
  # shellcheck disable=SC1090  # sourcing rc exposes its functions only (no dispatch)
  ( source "$RC" && _host_tools_load "$DECL" "$_m" ) > "$1/tools.json"
}

# Stand-ins for a gatekeeper: a live process whose command line names the
# gatekeeper script and this socket path (what _host_tools_pid_is_gatekeeper
# reads), and a pid that is gone.
LIVE_PID=''
start_gk() { # DIR
  mkdir -p "$1"
  python3 -c 'import time; time.sleep(300)' host-tool-gatekeeper.py "$1/host-tool.sock" </dev/null >/dev/null 2>&1 &
  LIVE_PID=$!
  SLEEPERS+=("$LIVE_PID")
  printf '%s\n' "$LIVE_PID" > "$1/gatekeeper.pid"
  sleep 0.2
}
DEAD_PID=''
dead_pid() {
  sleep 0 & DEAD_PID=$!
  wait "$DEAD_PID" 2>/dev/null
}

OUT=''; EX=0
run_rc() { # ARGS...  -> OUT (stdout+stderr), EX
  : > "$LOG"
  OUT=$(cd "$T" && "$RC" "$@" 2>&1)
  EX=$?
}
doctor_h() { run_rc doctor "${1:-$NAME}"; }
doctor_j() { run_rc --output json doctor "${1:-$NAME}"; }

reset_state() {
  rm -rf "$SD" "$RC_STATE_DIR/ghost"
  rm -f "$DECL"
  mkdir -p "$T/st"
}

has() { if [[ "$OUT" == *"$2"* ]]; then pass "$1"; else fail "$1"; echo "  missing: $2"; echo "  output: $OUT"; fi; }
lacks() { if [[ "$OUT" != *"$2"* ]]; then pass "$1"; else fail "$1"; echo "  unexpected: $2"; echo "  output: $OUT"; fi; }
jeq() { # LABEL JQ-EXPR WANT   (against $OUT as JSON)
  local _got
  _got=$(printf '%s\n' "$OUT" | jq -c "$2" 2>&1)
  if [[ "$_got" == "$3" ]]; then pass "$1"; else fail "$1"; echo "  got: $_got  want: $3"; fi
}

SENTENCE="A host tool reaches whatever its command reaches on the host; network.allow does not see it; rc checked the files its argv names, not the code they load."

# ============================================================================
echo "=== D1: declared, alive, running, no drift ==="
reset_state; mk_decl "$DECL"; mk_inspect Running present; write_tools_json "$SD"; start_gk "$SD"
doctor_h
has "D1 human: section header" "Host tools:"
has "D1 human: tool listed" "demo"
has "D1 human: verb with timeout" "go"
has "D1 human: timeout shown" "timeout 30s"
has "D1 human: the fixed sentence" "$SENTENCE"
has "D1 human: gatekeeper alive with pid" "alive (pid ${LIVE_PID})"
lacks "D1 human: no drift line" "declaration added"
lacks "D1 human: no contents drift" "declaration changed"
lacks "D1 human: not marked possession-mode" "possession-mode"
doctor_j
jeq "D1 json: declared" '.host_tools.declared' 'true'
jeq "D1 json: tool and verbs" '[.host_tools.tools[] | {name, v: [.verbs[].name]}]' '[{"name":"demo","v":["go","peek"]}]'
jeq "D1 json: timeout" '[.host_tools.tools[0].verbs[] | select(.name=="go") | .timeout]' '[30]'
jeq "D1 json: gatekeeper" '.host_tools.gatekeeper | {state, pid}' "{\"state\":\"alive\",\"pid\":${LIVE_PID}}"
jeq "D1 json: no presence drift" '.host_tools.presence_drift' 'null'
jeq "D1 json: no contents drift" '.host_tools.contents_drift' 'false'
jeq "D1 json: the sentence" '.host_tools.sentence' "\"${SENTENCE}\""
jeq "D1 json: rest of doctor JSON intact" '.name' "\"${NAME}\""

echo "=== D1b: possession-mode verb ==="
reset_state; mk_decl "$DECL" 30s true; mk_inspect Running present; write_tools_json "$SD"; start_gk "$SD"
doctor_h
has "D1b human: possession-mode marked" "possession-mode"
doctor_j
jeq "D1b json: possession flag" '[.host_tools.tools[0].verbs[] | select(.name=="peek") | .possession_mode]' '[true]'
jeq "D1b json: other verb not possession" '[.host_tools.tools[0].verbs[] | select(.name=="go") | .possession_mode]' '[false]'

# ============================================================================
echo "=== D2: none declared ==="
reset_state; mk_inspect Running missing
doctor_h
has "D2 human (label-less cage, no file): none declared" "Host tools: none declared"
lacks "D2 human: label-less cage shows no drift (added)" "declaration added"
lacks "D2 human: label-less cage shows no drift (removed)" "declaration removed"
lacks "D2 human: no sentence" "reaches whatever its command reaches"
doctor_j
jeq "D2 json: declared false" '.host_tools.declared' 'false'
jeq "D2 json: state_dir is a string" '.host_tools.state_dir | type' '"string"'
jeq "D2 json: no presence drift" '.host_tools.presence_drift' 'null'
jeq "D2 json: no contents drift" '.host_tools.contents_drift' 'false'
reset_state; mk_inspect Running absent
doctor_h
has "D2 human (label=absent, no file): none declared" "Host tools: none declared"

# ============================================================================
echo "=== D3: dead gatekeeper ==="
reset_state; mk_decl "$DECL"; mk_inspect Running present; write_tools_json "$SD"; dead_pid
printf '%s\n' "$DEAD_PID" > "$SD/gatekeeper.pid"
doctor_h
has "D3 human: dead gatekeeper named" "dead (pid ${DEAD_PID})"
doctor_j
jeq "D3 json: gatekeeper dead" '.host_tools.gatekeeper | {state, pid}' "{\"state\":\"dead\",\"pid\":${DEAD_PID}}"

# ============================================================================
echo "=== D4: gatekeeper alive for a stopped cage ==="
reset_state; mk_decl "$DECL"; mk_inspect Stopped present; write_tools_json "$SD"; start_gk "$SD"
doctor_h
has "D4 human: informational restart note" "restarts on rc up"
has "D4 human: still alive with pid" "alive (pid ${LIVE_PID})"
doctor_j
jeq "D4 json: alive and cage stopped" '.host_tools.gatekeeper | {state, cage_stopped}' '{"state":"alive","cage_stopped":true}'
reset_state; mk_decl "$DECL"; mk_inspect Running present; write_tools_json "$SD"; start_gk "$SD"
doctor_h
lacks "D4 control: running cage prints no restart note" "restarts on rc up"

# ============================================================================
echo "=== D5: presence drift, file added ==="
reset_state; mk_decl "$DECL"; mk_inspect Running absent
doctor_h
has "D5 human (label=absent): declaration added" "declaration added"
has "D5 human: recreate advice" "rc up on the stopped cage, or rc up --replace, recreates"
doctor_j
jeq "D5 json (label=absent): presence_drift added" '.host_tools.presence_drift' '"added"'
reset_state; mk_decl "$DECL"; mk_inspect Running missing
doctor_h
has "D5 human (label MISSING reads absent): declaration added" "declaration added"
doctor_j
jeq "D5 json (label MISSING reads absent): presence_drift added" '.host_tools.presence_drift' '"added"'
jeq "D5 json: declared by the file" '.host_tools.declared' 'true'

echo "=== D6: presence drift, file removed ==="
reset_state; mk_inspect Running present
# tools.json written from a declaration that is now gone
mk_decl "$DECL"; write_tools_json "$SD"; rm -f "$DECL"
start_gk "$SD"
doctor_h
has "D6 human: declaration removed" "declaration removed"
has "D6 human: recreate advice" "rc up on the stopped cage, or rc up --replace, recreates"
doctor_j
jeq "D6 json: presence_drift removed" '.host_tools.presence_drift' '"removed"'
jeq "D6 json: still declared (the cage has the route)" '.host_tools.declared' 'true'

# ============================================================================
echo "=== D7: contents drift ==="
reset_state; mk_decl "$DECL"; mk_inspect Running present; write_tools_json "$SD"; start_gk "$SD"
mk_decl "$DECL" 31s
doctor_h
has "D7 human: declaration changed" "declaration changed; rc up --replace applies it (rc up, if the cage is stopped)"
lacks "D7 human: not presence drift" "declaration added"
doctor_j
jeq "D7 json: contents_drift true" '.host_tools.contents_drift' 'true'
jeq "D7 json: presence_drift null" '.host_tools.presence_drift' 'null'

# ============================================================================
echo "=== D9: a declaration that does not load is contents drift, with or without tools.json ==="
reset_state; mk_decl "$DECL"; mk_inspect Running present; write_tools_json "$SD"; start_gk "$SD"
printf 'tools: [not, a, map\n' > "$DECL"
doctor_h
has "D9 human (tools.json present): drift line" "declaration changed; rc up --replace applies it"
doctor_j
jeq "D9 json (tools.json present): contents_drift true" '.host_tools.contents_drift' 'true'
jeq "D9 json: load_error set" '.host_tools.load_error | type' '"string"'
rm -f "$SD/tools.json"
doctor_j
jeq "D9 json (no tools.json): contents_drift true" '.host_tools.contents_drift' 'true'
doctor_h
has "D9 human (no tools.json): drift line" "declaration changed; rc up --replace applies it"

# ============================================================================
echo "=== D8: cage gone, gatekeeper still running ==="
reset_state; rm -f "$INSPECT"
mkdir -p "$RC_STATE_DIR/ghost"; start_gk "$RC_STATE_DIR/ghost"
doctor_h ghost
STILL="host-tool gatekeeper still running for this name (pid ${LIVE_PID}); rc destroy ghost stops it"
has "D8 human: still-running line" "$STILL"
has "D8 human: not-found exit follows" "container ghost not found"
if [[ "$EX" -ne 0 ]]; then pass "D8 human: exit non-zero"; else fail "D8 human: exit was 0"; fi
if [[ "${OUT%%container ghost not found*}" == *"$STILL"* ]]; then pass "D8 human: the line comes BEFORE the not-found error"; else fail "D8 human: line not before the not-found error"; echo "  output: $OUT"; fi
doctor_j ghost
has "D8 json: still-running text in the error" "$STILL"
jeq "D8 json: CONTAINER_NOT_FOUND code" '.code' '"CONTAINER_NOT_FOUND"'
rm -rf "$RC_STATE_DIR/ghost"; mkdir -p "$RC_STATE_DIR/ghost"
dead_pid; printf '%s\n' "$DEAD_PID" > "$RC_STATE_DIR/ghost/gatekeeper.pid"
doctor_h ghost
lacks "D8 control: a dead pid prints no still-running line" "still running"
rm -rf "$RC_STATE_DIR/ghost"
doctor_h ghost
lacks "D8 control: no state dir prints no still-running line" "still running"

# ============================================================================
# rc test: the host-side half. The fake msb answers every in-guest suite with
# nothing and exit 0; the list fixture is what the (fake) client returned.
echo "=== T: rc test host-side checks ==="
LIST_OK='{"ok":true,"result":{"tools":{"demo":{"go":{"timeout":30,"slots":{}},"peek":{"timeout":5,"slots":{}}}}}}'
export FAKE_LIST_FILE="$T/list.json"
printf '%s\n' "$LIST_OK" > "$FAKE_LIST_FILE"
unset FAKE_LIST_EXIT

reset_state; mk_decl "$DECL"; mk_inspect Running present; write_tools_json "$SD"; start_gk "$SD"
GK="$LIVE_PID"
run_rc test "$NAME"
T1_OUT="$OUT"
has "T1 declared: list matches the running gatekeeper's declaration" "PASS  [0] host-tools: list matches"
if [[ "$EX" -eq 0 ]]; then pass "T1 declared: rc test exits 0 (host half green, fake suites silent)"; else fail "T1 exit $EX"; echo "$OUT"; fi
CALLS=$(cat "$LOG")
if [[ "$CALLS" == *"/usr/local/bin/host-tool --list --json"* ]]; then pass "T1 the list is taken at the absolute client path"; else fail "T1 no absolute-path list call"; fi
if [[ "$CALLS" == *"test-host-tool.sh"* && "$CALLS" == *"RC_HOST_TOOLS_DECLARED=present"* && "$CALLS" == *"RC_HOST_TOOL_PORT=7700"* ]]; then
  pass "T1 the in-guest script gets arm=present and the port from rc's constant"
else
  fail "T1 env on the baked script"; echo "$CALLS"
fi
if grep -Eq '^msb (stop|kill|remove|destroy)' "$LOG"; then fail "T1 rc test issued a stop/kill/remove: $(grep -E '^msb (stop|kill|remove|destroy)' "$LOG")"; else pass "T1 rc test issued no stop/kill/remove"; fi
if kill -0 "$GK" 2>/dev/null && [[ "$(cat "$SD/gatekeeper.pid")" == "$GK" ]]; then pass "T1 the gatekeeper pid is alive and unchanged after rc test"; else fail "T1 gatekeeper pid changed or died"; fi
if [[ "$T1_OUT" != *demo* && "$T1_OUT" != *peek* ]]; then pass "T1 rc's own lines name no tool or verb"; else fail "T1 a tool or verb name leaked into rc's lines"; fi

# T2: the running gatekeeper loaded something other than the cage lists. The
# FAIL line is count-only: no declared name reaches rc's output or the JSON.
printf '%s\n' '{"ok":true,"result":{"tools":{"demo":{"go":{"timeout":30,"slots":{}},"extra":{"timeout":5,"slots":{}}}}}}' > "$FAKE_LIST_FILE"
run_rc test "$NAME"
has "T2 list differs from tools.json: FAIL, count-only" "FAIL  [0] host-tools: list does not match the running gatekeeper's declaration — list has 1 tool(s)/2 verb(s), loaded has 1 tool(s)/2 verb(s) (names withheld"
if [[ "$EX" -ne 0 ]]; then pass "T2 exit non-zero"; else fail "T2 exit was 0"; fi
if printf '%s\n' "$OUT" | grep -Eqw 'demo|go|peek|extra'; then fail "T2 a declared name leaked into rc test's output"; echo "$OUT"; else pass "T2 no declared name in rc test's output"; fi
run_rc --output json test "$NAME"
if printf '%s\n' "$OUT" | grep -Eqw 'demo|go|peek|extra'; then fail "T2 a declared name leaked into rc test's JSON"; else pass "T2 no declared name in rc test's JSON"; fi
jeq "T2 json: the comparison is a failing parsed check" '[.checks[] | select(.name | startswith("host-tools: list does not match")) | .status]' '["fail"]'
printf '%s\n' "$LIST_OK" > "$FAKE_LIST_FILE"

# T2b: a busy override that is not an integer warns on stderr and falls back
printf '%s\n' '{"ok":false,"error":{"kind":"busy","message":"x"}}' > "$FAKE_LIST_FILE"
FAKE_LIST_EXIT=4 RC_TEST_LIST_BUSY_SECS=abc run_rc test "$NAME" &
T2B=$!; sleep 4
if kill -0 "$T2B" 2>/dev/null; then pass "T2b bad RC_TEST_LIST_BUSY_SECS falls back to the 30 s window (still retrying after 4 s)"; else fail "T2b bad override ended the retry early"; fi
kill "$T2B" 2>/dev/null; wait "$T2B" 2>/dev/null
printf '%s\n' "$LIST_OK" > "$FAKE_LIST_FILE"

# T3: the FILE on disk changed (contents drift) but the gatekeeper's tools.json
# still equals the list: test passes - drift is doctor's finding.
mk_decl "$DECL" 77s
printf '      extra:\n        argv: ["%s/bin/tool", "y"]\n        timeout: 5s\n' "$T" >> "$DECL"
run_rc test "$NAME"
has "T3 contents drift on disk does not fail the list check" "PASS  [0] host-tools: list matches"
lacks "T3 and no FAIL" "FAIL"

# T4: a saturated line
printf '%s\n' '{"ok":false,"error":{"kind":"busy","message":"line saturated"}}' > "$FAKE_LIST_FILE"
FAKE_LIST_EXIT=4 RC_TEST_LIST_BUSY_SECS=2 run_rc test "$NAME"
has "T4 busy for the whole window: FAIL naming a saturated line" "saturated line"
if [[ "$EX" -ne 0 ]]; then pass "T4 exit non-zero"; else fail "T4 exit was 0"; fi
printf '%s\n' "$LIST_OK" > "$FAKE_LIST_FILE"

# T5: label=absent, file absent: the undeclared arm, no list call
reset_state; mk_inspect Running absent
run_rc test "$NAME"
CALLS=$(cat "$LOG")
if [[ "$CALLS" == *"RC_HOST_TOOLS_DECLARED=absent"* ]]; then pass "T5 undeclared arm: env arm=absent"; else fail "T5 arm env"; echo "$CALLS"; fi
if [[ "$CALLS" != *"host-tool --list"* ]]; then pass "T5 undeclared arm: no host-side list call"; else fail "T5 list call on an undeclared cage"; fi
lacks "T5 no drift line" "declaration added"

# T6: presence drift, file added after a label-absent create: drift line, arm from the LABEL
reset_state; mk_decl "$DECL"; mk_inspect Running absent
run_rc test "$NAME"
has "T6a drift line printed" "declaration added"
if [[ "$(cat "$LOG")" == *"RC_HOST_TOOLS_DECLARED=absent"* ]]; then pass "T6a arm follows the label (absent), not the file"; else fail "T6a arm"; fi
# ... and file removed under a label=present cage
reset_state; mk_decl "$DECL"; mk_inspect Running present; write_tools_json "$SD"; start_gk "$SD"; rm -f "$DECL"
run_rc test "$NAME"
has "T6b drift line printed" "declaration removed"
if [[ "$(cat "$LOG")" == *"RC_HOST_TOOLS_DECLARED=present"* ]]; then pass "T6b arm follows the label (present), not the file"; else fail "T6b arm"; fi
has "T6b the declared arm still ran its list check" "host-tools: list matches"
# label MISSING + file: reads absent
reset_state; mk_decl "$DECL"; mk_inspect Running missing
run_rc test "$NAME"
if [[ "$(cat "$LOG")" == *"RC_HOST_TOOLS_DECLARED=absent"* ]]; then pass "T6c missing label selects the absent arm"; else fail "T6c arm"; fi

# T7: JSON arm carries the host-side check as a parsed check
reset_state; mk_decl "$DECL"; mk_inspect Running present; write_tools_json "$SD"; start_gk "$SD"
run_rc --output json test "$NAME"
jeq "T7 json: the list check is a passing parsed check" '[.checks[] | select(.name | startswith("host-tools: list matches")) | .status]' '["pass"]'

# T8: rule 6 of the beads redirect refusal sees the cage's --conf directory
# (from the rc.cage-conf label), as rc up does: a redirect INTO that directory
# is refused. The target is a valid .beads dir that IS the config's directory,
# outside every other leg, so only the label-derived _UP_CONF_DIR refuses it.
SAVE_CONF="$CONF"
mkdir -p "$T/bd/.beads"; printf '{}\n' > "$T/bd/.beads/metadata.json"; : > "$T/bd/.beads/c.yaml"
CONF="$T/bd/.beads/c.yaml"
reset_state; mk_inspect Running absent
mkdir -p "$T/ws/.beads"; printf '../bd/.beads\n' > "$T/ws/.beads/redirect"
run_rc test "$NAME"
has "T8 beads redirect to the config's own directory is refused (rule 6)" "ADR-032 D2"
rm -rf "$T/ws/.beads"; CONF="$SAVE_CONF"

# ============================================================================
echo "=== S1: static checks ==="
if grep -q '^COPY tests/test-host-tool.sh /usr/local/lib/rip-cage/test-host-tool.sh' "${REPO_ROOT}/cage/Dockerfile" \
   && grep -A3 'COPY tests/test-host-tool.sh' "${REPO_ROOT}/cage/Dockerfile" | grep -q 'chown root:root /usr/local/lib/rip-cage/test-host-tool.sh' \
   && grep -A3 'COPY tests/test-host-tool.sh' "${REPO_ROOT}/cage/Dockerfile" | grep -q 'chmod 0555 /usr/local/lib/rip-cage/test-host-tool.sh'; then
  pass "S1 cage/Dockerfile copies tests/test-host-tool.sh root:root 0555"
else
  fail "S1 cage/Dockerfile copy/chown/chmod lines for test-host-tool.sh"
fi
if grep -q 'test-host-tool.sh' "${REPO_ROOT}/cli/test.sh" && [[ -f "${REPO_ROOT}/tests/test-host-tool.sh" ]]; then pass "S1 cli/test.sh lists the baked script and it exists"; else fail "S1 cli/test.sh suite list"; fi
if ! grep -E 'RC_HOST_TOOL_PORT[^ ]*[:=-]+[0-9]+' "${REPO_ROOT}/tests/test-host-tool.sh" >/dev/null 2>&1; then pass "S1 the baked script holds no copy of the port number"; else fail "S1 the baked script hardcodes a port default"; fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then echo "All doctor host-tools tests passed"; exit 0; fi
echo "${FAILURES} failure(s)"
exit 1
