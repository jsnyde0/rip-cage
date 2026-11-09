#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&B||C pass/fail idiom; fake bodies and python snippets are deliberately single-quoted
set -uo pipefail

# tests/test-host-tool-lifecycle.sh -- host-tier proof for rip-cage-jdl2.3.3
# (ADR-032 D6, child C of the rc up wiring): the gatekeeper's lifecycle under
# rc. The REAL rc and the REAL gatekeeper (cli/lib/host-tool-gatekeeper.py)
# run behind the fake msb (tests/_fake-runtime-lib.sh): a fake that never
# listened would stay green when the real launch is given wrong arguments.
# Every lifecycle fact is observed from the host: /proc (environ, cwd, fd
# list, session id, command line), the socket (a list request over it shows
# which contents are served), the pid file, the state directory, and the
# fake's call log. Linux branches only; the macOS branches (mkdir lock, ps
# liveness) are asserted by rip-cage-jdl2.8.
#
# Needs python3, yq, jq and /proc; SKIPs with the reason otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
PY="$(command -v python3 || true)"
[[ -n "$PY" ]] || { echo "SKIP: python3 not on PATH (the gatekeeper needs it)"; exit 0; }
[[ -d /proc/self ]] || { echo "SKIP: no /proc (the process facts are read from it)"; exit 0; }
PY="$(readlink -f "$PY")"

# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"
# The loader, to compute what tools.json must equal.
# shellcheck source=cli/lib/protected_paths.sh
source "${REPO_ROOT}/cli/lib/protected_paths.sh"
# shellcheck source=cli/lib/host_tools.sh
source "${REPO_ROOT}/cli/lib/host_tools.sh"

T=$(mktemp -d /tmp/rc-life-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
LOG="${T}/calls.log"
: > "$LOG"
FAKE_BIN=$(fake_runtime_bin "$LOG")

# gk_pids [DIR] -- pids of every gatekeeper whose command line carries DIR
# (default: this test's whole temp tree), read from /proc in-shell.
gk_pids() {
  local _p _c _dir="${1:-$T}"
  for _p in /proc/[0-9]*; do
    _c=$({ tr '\0' ' ' < "${_p}/cmdline"; } 2>/dev/null) || continue
    [[ "$_c" == *host-tool-gatekeeper.py* && "$_c" == *"${_dir}"* ]] && echo "${_p#/proc/}"
  done
  return 0
}
cleanup() {
  local _p _f
  for _f in "$T"/*/*/gatekeeper.pid "$T"/home/.local/state/rip-cage/*/gatekeeper.pid; do
    [[ -f "$_f" ]] || continue
    _p=$(cat "$_f" 2>/dev/null); [[ "$_p" =~ ^[0-9]+$ ]] && kill -KILL "$_p" 2>/dev/null
  done
  # The gatekeepers lead their own sessions, so a session sweep cannot reach them: killed by pid file above and by command line here.
  for _p in $(gk_pids "$T"); do kill -KILL "$_p" 2>/dev/null; done
  for _p in $(sleepers_pids); do kill -KILL "$_p" 2>/dev/null; done
  rm -rf "$T" "$FAKE_BIN"
}
sleepers_pids() { # the planted TERM-ignoring stand-ins carry T in their cmdline
  local _p _c
  for _p in /proc/[0-9]*; do
    _c=$({ tr '\0' ' ' < "${_p}/cmdline"; } 2>/dev/null) || continue
    [[ "$_c" == *"${T}/standin"* ]] && echo "${_p#/proc/}"
  done
  return 0
}
trap cleanup EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_STATE_HOME="${T}/home/.local/state"
export PATH="${FAKE_BIN}:${PATH}"
unset RC_STATE_DIR RC_PYTHON3 RC_CAGE_CONF FAKE_MSB_INSPECT_FILE
STATE_ROOT="${XDG_STATE_HOME}/rip-cage"

mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$HOME/.claude/commands" \
  "$T/ws/.git/hooks" "$T/ws/.git/info" "$T/bin" "$T/conf" "$T/cwd" "$T/alt"
: > "$T/ws/.git/config"
: > "$T/ws/.env"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tool"; chmod 0755 "$T/bin/tool"

cage_name() {
  local _p="$1"
  printf '%s-%s' "$(basename "$(dirname "$_p")")" "$(basename "$_p")" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^[.-]*//' | sed 's/-$//'
}
NAME=$(cage_name "$T/ws")
STATE="${STATE_ROOT}/${NAME}"
SOCK="${STATE}/host-tool.sock"
PIDF="${STATE}/gatekeeper.pid"

mk_conf() { # FILE PROJECT
  {
    printf 'image: rip-cage:latest\nworkdir: /workspace\nmounts:\n  - "%s:/workspace"\n' "$2"
    printf "  - \"%s/.claude/projects:/home/agent/.claude/projects\"\n  - \"%s/.claude/sessions:/home/agent/.claude/sessions\"\n" "$HOME" "$HOME"
    printf 'network:\n  policy: none\n  strict: false\n  allow:\n    - "api.anthropic.com:tcp:443"\n'
  } > "$1"
}
mk_decl() { # FILE [EXTRA_VERB]
  {
    printf 'tools:\n  demo:\n    verbs:\n      go:\n        argv: ["%s/bin/tool"]\n        timeout: 30s\n' "$T"
    [[ -n "${2:-}" ]] && printf '      %s:\n        argv: ["%s/bin/tool", "x"]\n        timeout: 30s\n' "$2" "$T"
  } > "$1"
}
CONF="$T/conf/a.yaml"; DECL="$T/conf/a.tools.yaml"
mk_conf "$CONF" "$T/ws"

sha_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
printf '[{"reference":"rip-cage:latest","digest":"%s"}]\n' "$DIGEST" > "$T/images.json"
export FAKE_MSB_IMAGE_LIST_FILE="$T/images.json"
# mk_inspect STATUS HOST_TOOLS_LABEL(present|absent) [STATE_DIR_LABEL] -> $T/inspect.json
mk_inspect() {
  local _status="$1" _ht="$2" _sd="${3:-$STATE}"
  jq -n --arg st "$_status" --arg ht "$_ht" --arg dg "$DIGEST" --arg path "$T/ws" --arg sha "$(sha_of "$CONF")" --arg sd "$_sd" '
    {status: $st, config: {manifest_digest: $dg, labels: ({"rc.source.path": $path, "rc.cage-conf-sha": $sha, "rc.session.multiplexer": "none", "rc.host-tools": $ht}
        + (if $ht == "present" then {"rc.state-dir": $sd} else {} end)), mounts: []}}' > "$T/inspect.json"
}

OUT=''; EX=0
run_up() { # [VAR=val ...] -- ARGS...  -> OUT, EX; the call log holds this run only
  local -a _envs=()
  while [[ "$1" != -- ]]; do _envs+=("$1"); shift; done
  shift
  : > "$LOG"
  rm -f "${T}/inspect.json.removed"
  OUT=$(cd "$T/cwd" && env ${_envs[@]+"${_envs[@]}"} "$RC" "$@" 2>&1 </dev/null)
  EX=$?
}
# run_up_tty [VAR=val ...] -- ARGS... -- as run_up, with rc on a pty (the
# attach branch runs only with a terminal); the pty child is its own session.
run_up_tty() {
  local -a _envs=()
  while [[ "$1" != -- ]]; do _envs+=("$1"); shift; done
  shift
  : > "$LOG"
  rm -f "${T}/inspect.json.removed"
  OUT=$(cd "$T/cwd" && env ${_envs[@]+"${_envs[@]}"} "$PY" -I -c 'import os, pty, sys
sys.exit(pty.spawn(sys.argv[1:]) >> 8)' "$RC" "$@" 2>&1 </dev/null)
  EX=$?
}
calls() { grep '^msb ' "$LOG" | grep -v '^msb --version$' || true; }
has_call() { grep -q "^msb $1" "$LOG"; }
count_calls() { grep -c "^msb $1" "$LOG" || true; }

gk_pid() { cat "$PIDF" 2>/dev/null; }
fd_targets() { local _f; for _f in /proc/"$1"/fd/*; do readlink "$_f"; done 2>/dev/null; }
alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }
stat_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
# listed -- the verbs the gatekeeper at SOCK serves (a list request over it).
listed() {
  printf '{"v":1,"list":true}\n' | "$PY" -I "${SCRIPT_DIR}/fixtures/host-tool-gatekeeper/client.py" "${1:-$SOCK}" --halfclose 2>&1
}
stop_all() { # leave the test with no gatekeeper and a clean state root
  local _p
  for _p in $(gk_pids "$T"); do kill -TERM "$_p" 2>/dev/null; done
  sleep 0.5
  for _p in $(gk_pids "$T"); do kill -KILL "$_p" 2>/dev/null; done
  rm -rf "$STATE_ROOT" "$T/alt"/*
}
wait_dead() { local _i=0; while alive "$1" && [[ $_i -lt 60 ]]; do sleep 0.1; _i=$((_i + 1)); done; ! alive "$1"; }
LOADED=''
load_decl() { # -> LOADED, the loader's normalized JSON for DECL
  local _m; _m=$(mktemp "$T/mounts.XXXXXX"); printf '%s\n' "$T/ws" > "$_m"
  LOADED=$(_host_tools_load "$DECL" "$_m"); rm -f "$_m"
}

# ============================================================================
echo "=== A: create path (fake create + init, real gatekeeper, attach exit 3) ==="
mk_decl "$DECL"
load_decl
rm -f "$T/inspect.json" "$T/inspect.json.removed"; export FAKE_MSB_INSPECT_FILE="$T/inspect.json"
run_up_tty "FAKE_MSB_ATTACH_EXIT=3" -- up --conf "$CONF" "$T/ws"
GK=$(gk_pid)
if has_call create && has_call 'exec .*init-rip-cage.sh'; then pass "A1: the fake create and the init exec were recorded"; else fail "A1: calls: $(calls)"; fi
if alive "$GK" && [[ -S "$SOCK" ]] && [[ "$(listed)" == *'"demo"'* && "$(listed)" == *'"go"'* ]]; then pass "A2: a gatekeeper (pid ${GK}) listens on <state>/host-tool.sock and answers a list over it"; else fail "A2: pid=${GK} sock: $(ls -la "$STATE" 2>&1) list: $(listed)"; fi
KEYS=$(tr '\0' '\n' < "/proc/${GK}/environ" | cut -d= -f1 | sort | paste -sd' ' -)
ENV_HOME=$(tr '\0' '\n' < "/proc/${GK}/environ" | grep '^HOME=' | cut -d= -f2-)
ENV_PATH=$(tr '\0' '\n' < "/proc/${GK}/environ" | grep '^PATH=' | cut -d= -f2-)
if [[ "$KEYS" == "HOME LANG PATH" && "$ENV_HOME" == "$STATE" && "$ENV_PATH" == "/usr/bin:/bin" ]]; then pass "A3: /proc/<pid>/environ keys are exactly {PATH, HOME, LANG}; HOME=<state>, PATH=/usr/bin:/bin"; else fail "A3: keys='${KEYS}' HOME='${ENV_HOME}' PATH='${ENV_PATH}'"; fi
if [[ "$(readlink "/proc/${GK}/cwd")" == "$STATE" ]]; then pass "A4: its cwd (/proc/<pid>/cwd) is the state directory"; else fail "A4: cwd=$(readlink "/proc/${GK}/cwd")"; fi
SID=$(awk '{print $6}' "/proc/${GK}/stat")
if [[ "$SID" == "$GK" && "$SID" != "$(awk '{print $6}' /proc/$$/stat)" ]]; then pass "A5: it leads its own session (sid ${SID} = its pid, not this test's)"; else fail "A5: sid=${SID} pid=${GK}"; fi
HOLDS=$(for _f in /proc/"${GK}"/fd/*; do readlink "$_f"; done 2>/dev/null | grep -cx "${STATE}/lock" || true)
if [[ -e "$STATE/lock" && "$HOLDS" == 0 ]]; then pass "A6: /proc/<pid>/fd holds no descriptor on <state>/lock (lock file exists, none inherited)"; else fail "A6: holds=${HOLDS}"; fi
CMD=$(tr '\0' '\n' < "/proc/${GK}/cmdline")
if [[ "$(printf '%s\n' "$CMD" | sed -n 1p)" == "$PY" && "$(printf '%s\n' "$CMD" | sed -n 2p)" == "-I" ]]; then pass "A7: its command line is the absolute python3 (${PY}) then -I"; else fail "A7: $(printf '%s\n' "$CMD" | head -3 | paste -sd' ' -)"; fi
if [[ "$(stat_mode "$STATE")" == 700 ]]; then pass "A8: the state directory is 0700"; else fail "A8: mode $(stat_mode "$STATE")"; fi
if [[ "$(cat "$STATE/tools.json")" == "$LOADED" && -n "$LOADED" ]]; then pass "A9: tools.json equals the loader's output"; else fail "A9: tools.json=$(cat "$STATE/tools.json") loaded=${LOADED}"; fi
if [[ "$EX" -eq 3 ]] && alive "$GK" && [[ -S "$SOCK" ]]; then pass "A10: a non-zero attach exit (fake exec returning 3; rc exit ${EX}) leaves the gatekeeper running"; else fail "A10: ex=${EX} alive=$(alive "$GK" && echo y || echo n)"; fi

# ============================================================================
echo "=== B: a second rc up during an attach does not wait on the lock ==="
stop_all; : > "$T/started"
rm -f "$T/inspect.json" "$T/inspect.json.removed"
( cd "$T/cwd" && FAKE_MSB_ATTACH_SLEEP=8 FAKE_MSB_ATTACH_STARTED_FILE="$T/started" "$PY" -I -c 'import os, pty, sys
sys.exit(pty.spawn(sys.argv[1:]) >> 8)' "$RC" up --conf "$CONF" "$T/ws" >"$T/first.out" 2>&1 </dev/null ) &
FIRST=$!
_i=0; while [[ ! -s "$T/started" && $_i -lt 150 ]]; do sleep 0.1; _i=$((_i + 1)); done
RCPID=$(cat "$T/started" 2>/dev/null); GK=$(gk_pid)
if [[ -n "$RCPID" ]] && alive "$RCPID" && alive "$GK"; then pass "B0: the first rc up is inside its attach (rc pid ${RCPID}) with the gatekeeper up (${GK})"; else fail "B0: rc=${RCPID} gk=${GK}"; fi
if [[ "$(awk '{print $6}' "/proc/${RCPID}/stat")" != "$(awk '{print $6}' "/proc/${GK}/stat")" ]]; then pass "B1: its session id differs from rc's (rc sid $(awk '{print $6}' "/proc/${RCPID}/stat"), gatekeeper sid $(awk '{print $6}' "/proc/${GK}/stat"))"; else fail "B1: same session"; fi
if command -v flock >/dev/null 2>&1; then
  if ( exec 8>"$STATE/lock"; flock -n 8 ); then pass "B2: the lock is free during the attach (flock -n succeeds)"; else fail "B2: the lock is held during the attach"; fi
else
  echo "SKIP: B2: no flock command here"
fi
mk_inspect Running present
T0=$(date +%s)
run_up -- up --conf "$CONF" "$T/ws"
T1=$(date +%s)
if [[ "$EX" -eq 0 && $((T1 - T0)) -lt 5 ]] && alive "$RCPID" && alive "$GK" && [[ "$(gk_pid)" == "$GK" ]]; then pass "B3: a second rc up returned (exit ${EX}, $((T1 - T0)) s) while the first was inside its attach; same gatekeeper pid"; else fail "B3: ex=${EX} t=$((T1 - T0))s out=${OUT}"; fi
wait "$FIRST" 2>/dev/null
if alive "$GK"; then pass "B4: the first rc up's attach ended; the gatekeeper still runs"; else fail "B4: gatekeeper died with the attach"; fi
stop_all

# ============================================================================
echo "=== C: stopped cage, edited contents: a NEW pid serves them, no recreate ==="
rm -f "$T/inspect.json.removed"
mk_decl "$DECL"; mk_inspect Stopped present
run_up -- up --conf "$CONF" "$T/ws"        # resume once: starts the gatekeeper on contents A
OLD=$(gk_pid)
if [[ "$EX" -eq 0 ]] && alive "$OLD" && has_call start; then pass "C0: a plain resume started a gatekeeper (pid ${OLD}) with the fake start"; else fail "C0: ex=${EX} out=${OUT}"; fi
mk_decl "$DECL" newverb
mk_inspect Stopped present
run_up -- up --conf "$CONF" "$T/ws"
NEW=$(gk_pid)
if [[ "$EX" -eq 0 && -n "$NEW" && "$NEW" != "$OLD" ]] && alive "$NEW" && ! alive "$OLD"; then pass "C1: after the edit, plain rc up left a NEW pid (${OLD} -> ${NEW}) and the old one is gone, though it was alive"; else fail "C1: ex=${EX} old=${OLD} new=${NEW} oldalive=$(alive "$OLD" && echo y || echo n) out=${OUT}"; fi
if [[ "$(listed)" == *'"newverb"'* ]]; then pass "C2: a list over the socket shows the new verb"; else fail "C2: $(listed)"; fi
if has_call start && ! has_call remove && ! has_call create; then pass "C3: no recreate (fake start recorded; no remove, no create)"; else fail "C3: $(calls)"; fi
# the dead-gatekeeper variant of the same rule
kill -KILL "$NEW" 2>/dev/null; wait_dead "$NEW" >/dev/null
mk_decl "$DECL"
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 ]] && alive "$(gk_pid)" && [[ "$(listed)" != *newverb* ]]; then pass "C4: a dead gatekeeper (stale socket and pid file) is replaced on resume, serving the current file"; else fail "C4: ex=${EX} ${OUT}"; fi

# ============================================================================
echo "=== D: failures after a fresh start leave no gatekeeper ==="
stop_all
mk_inspect Stopped present
run_up "FAKE_MSB_START_EXIT=1" -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -ne 0 ]] && has_call start && [[ -z "$(gk_pids "$STATE")" && ! -e "$SOCK" && ! -e "$PIDF" ]]; then pass "D1: a fake msb start failure after the fresh start leaves no gatekeeper (exit ${EX})"; else fail "D1: ex=${EX} procs=$(gk_pids "$STATE") ${OUT}"; fi
if [[ "$OUT" == *"msb start failed"* ]]; then pass "D1b: the failure is named"; else fail "D1b: ${OUT}"; fi
stop_all
rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up "FAKE_MSB_INIT_EXIT=1" -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -ne 0 ]] && has_call 'exec .*init-rip-cage.sh' && [[ -z "$(gk_pids "$STATE")" && ! -e "$SOCK" && ! -e "$PIDF" ]]; then pass "D2: a fake init failure leaves no gatekeeper (exit ${EX})"; else fail "D2: ex=${EX} procs=$(gk_pids "$STATE") ${OUT}"; fi
stop_all
run_up "FAKE_MSB_CREATE_EXIT=1" -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -ne 0 ]] && has_call create && [[ -z "$(gk_pids "$T")" && ! -e "$STATE" ]]; then pass "D3: a failed create starts nothing and creates no state directory"; else fail "D3: ex=${EX} procs=$(gk_pids "$T") state=$(ls "$STATE" 2>&1) ${OUT}"; fi

# ============================================================================
echo "=== E: running cage rules ==="
stop_all
mk_decl "$DECL"; mk_inspect Running present
run_up -- up --conf "$CONF" "$T/ws"        # label present, nothing running: starts it
G1=$(gk_pid)
if [[ "$EX" -eq 0 ]] && alive "$G1" && ! has_call start && ! has_call create && ! has_call remove; then pass "E0: running cage, label present, gatekeeper dead: restarted (pid ${G1}), no msb start/create/remove"; else fail "E0: ex=${EX} ${OUT}"; fi
mk_decl "$DECL" newverb
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" == *'host-tool declaration changed; takes effect on `rc up --replace`'* && "$(gk_pid)" == "$G1" ]] && alive "$G1" && [[ "$(listed)" != *newverb* ]]; then pass "E1: a changed file prints the --replace line and keeps the live pid (${G1})"; else fail "E1: ex=${EX} pid=$(gk_pid) ${OUT}"; fi
mk_decl "$DECL"
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$OUT" != *"takes effect"* ]]; then pass "E1b: an unchanged file prints nothing"; else fail "E1b: ${OUT}"; fi
# presence drift: added
mk_inspect Running absent
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" == *'host-tool declaration added; takes effect on `rc up --replace`'* && "$(gk_pid)" == "$G1" ]]; then pass "E2: presence drift (declaration added) prints the added line; the live pid is untouched"; else fail "E2: ex=${EX} ${OUT}"; fi
stop_all
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" == *"host-tool declaration added"* && -z "$(gk_pids "$T")" && ! -e "$STATE" ]]; then pass "E2b: presence drift starts nothing (no process, no state directory)"; else fail "E2b: procs=$(gk_pids "$T") ${OUT}"; fi
# presence drift: removed
mk_inspect Running present
mv "$DECL" "$T/conf/a.tools.yaml.off"
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" == *'host-tool declaration removed; takes effect on `rc up --replace`'* && -z "$(gk_pids "$T")" ]]; then pass "E3: presence drift (declaration removed) prints the removed line and starts nothing"; else fail "E3: ex=${EX} ${OUT}"; fi
mv "$T/conf/a.tools.yaml.off" "$DECL"
# dead gatekeeper after a kill -9: stale socket + stale pid file, restart
stop_all
run_up -- up --conf "$CONF" "$T/ws"; G2=$(gk_pid)
kill -KILL "$G2"; wait_dead "$G2" >/dev/null
run_up -- up --conf "$CONF" "$T/ws"; G3=$(gk_pid)
if [[ "$EX" -eq 0 && -n "$G3" && "$G3" != "$G2" ]] && alive "$G3" && [[ "$(listed)" == *'"go"'* ]]; then pass "E4: a gatekeeper killed -9 (stale socket and pid) is restarted on a running cage (${G2} -> ${G3})"; else fail "E4: ex=${EX} ${OUT}"; fi
# defective file with a dead gatekeeper: site 3 first, nothing started, no exec
kill -KILL "$G3"; wait_dead "$G3" >/dev/null
printf 'tools:\n  demo:\n    verbs:\n      go:\n        argv: ["/nonexistent/tool"]\n        timeout: 30s\n' > "$DECL"
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -ne 0 && "$OUT" == *"Error:"* ]] && ! has_call exec && [[ -z "$(gk_pids "$T")" ]]; then pass "E5: a defective file with a dead gatekeeper exits non-zero, records no exec, starts nothing"; else fail "E5: ex=${EX} calls=$(calls) procs=$(gk_pids "$T") ${OUT}"; fi
# control: the same dead-gatekeeper restart with a good file DOES record an exec
# (a pty attach, so the fake records its interactive exec)
mk_decl "$DECL"
run_up_tty -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 ]] && has_call exec && alive "$(gk_pid)"; then pass "E5b: control: with a good file the same dead-gatekeeper state restarts and DOES record an exec (attach)"; else fail "E5b: ex=${EX} calls=$(calls) ${OUT}"; fi
# a socket file with no pid file and nothing listening
stop_all; mkdir -p "$STATE"; chmod 0700 "$STATE"
"$PY" -I -c 'import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.close()' "$SOCK"
if [[ -S "$SOCK" && ! -e "$PIDF" ]]; then pass "E6a: setup: a socket file, no pid file, nothing listening"; else fail "E6a: setup"; fi
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 ]] && alive "$(gk_pid)" && [[ "$(listed)" == *'"go"'* ]]; then pass "E6: that socket is unlinked and the start succeeds"; else fail "E6: ex=${EX} ${OUT} $(tail -3 "$STATE/gatekeeper.log" 2>&1)"; fi

# ============================================================================
echo "=== F: --replace ==="
mk_inspect Running present
OLDF=$(gk_pid)
run_up "FAKE_MSB_REMOVE_PROBE_PIDFILE=$PIDF" -- up --replace --conf "$CONF" "$T/ws"
P_LINE=$(grep -n '^probe: gatekeeper.pid' "$LOG" | head -1 | cut -d: -f1); R_LINE=$(grep -n '^msb remove' "$LOG" | head -1 | cut -d: -f1)
if [[ -n "$R_LINE" && "$(sed -n "${P_LINE}p" "$LOG")" == "probe: gatekeeper.pid absent" && "$P_LINE" -gt "$R_LINE" ]] && ! alive "$OLDF"; then pass "F1: rc up --replace stopped the gatekeeper before the fake remove (pid file absent when remove ran; old pid ${OLDF} gone)"; else fail "F1: ex=${EX} remove@${R_LINE} probe@${P_LINE}: $(grep '^probe' "$LOG") ${OUT}"; fi
NEWF=$(gk_pid)
if has_call create && alive "$NEWF" && [[ "$NEWF" != "$OLDF" ]]; then pass "F2: the recreate then started a fresh gatekeeper (${NEWF})"; else fail "F2: new=${NEWF} calls=$(calls)"; fi

# ============================================================================
echo "=== G: rc destroy ==="
mk_inspect Running present
run_up -- destroy "$NAME"
if [[ "$EX" -eq 0 && -z "$(gk_pids "$T")" && ! -e "$SOCK" && ! -e "$PIDF" && ! -e "$STATE" ]]; then pass "G1: rc destroy leaves no process, socket, pid file or state directory"; else fail "G1: ex=${EX} procs=$(gk_pids "$T") state=$(ls "$STATE" 2>&1) ${OUT}"; fi
# a state directory found through the label under a different RC_STATE_DIR
ALT="$T/alt"; ALTSTATE="${ALT}/${NAME}"
rm -f "$T/inspect.json"; rm -f "$T/inspect.json.removed"
run_up "RC_STATE_DIR=$ALT" -- up --conf "$CONF" "$T/ws"
ALTPID=$(cat "$ALTSTATE/gatekeeper.pid" 2>/dev/null)
mk_inspect Running present "$ALTSTATE"
run_up -- destroy "$NAME"
if alive "$ALTPID" || [[ -e "$ALTSTATE" ]]; then fail "G2: destroy did not clean ${ALTSTATE} (pid ${ALTPID}): ${OUT}"; else [[ -n "$ALTPID" && "$EX" -eq 0 ]] && pass "G2: destroy found the state directory through rc.state-dir under a different RC_STATE_DIR (gatekeeper ${ALTPID} stopped, ${ALTSTATE} removed)" || fail "G2: setup pid=${ALTPID} ex=${EX}"; fi
# a gone cage: inspect absent, no volumes, an orphan gatekeeper under the default dir
rm -f "$T/inspect.json"
run_up -- up --conf "$CONF" "$T/ws"        # creates the orphan's state through the normal path
ORPH=$(gk_pid)
rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up "FAKE_MSB_NO_VOLUMES=1" -- destroy "$NAME"
if [[ "$EX" -eq 2 && -n "$ORPH" && ! -e "$STATE" && -z "$(gk_pids "$T")" && "$OUT" == *"orphaned host-tool gatekeeper"* ]]; then pass "G3: on a gone cage (no inspect, no volumes) destroy still stops the orphan and removes the directory, says so, and exits 2 as before"; else fail "G3: ex=${EX} orphan=${ORPH} procs=$(gk_pids "$T") ${OUT}"; fi
# a state directory the label points elsewhere, named wrongly, is never removed
mkdir -p "$T/precious/other"; : > "$T/precious/other/keep"
mk_inspect Running present "$T/precious/other"
run_up -- destroy "$NAME"
if [[ "$EX" -ne 0 && -e "$T/precious/other/keep" && "$OUT" == *"not touching it"* ]]; then pass "G4: a label naming a directory not named after the cage is refused (non-zero), not removed"; else fail "G4: ${OUT}"; fi

# ============================================================================
echo "=== H: dry-run and no declaration ==="
stop_all; rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up -- up --dry-run --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 && ! -e "$STATE_ROOT" && -z "$(gk_pids "$T")" ]]; then pass "H1: --dry-run creates no state directory and starts nothing"; else fail "H1: ex=${EX} ${OUT}"; fi
mk_inspect Stopped present
run_up -- up --dry-run --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 && ! -e "$STATE_ROOT" && -z "$(gk_pids "$T")" ]]; then pass "H1b: --dry-run on a stopped cage creates no state directory either"; else fail "H1b: ex=${EX} ${OUT}"; fi
rm -f "$T/inspect.json" "$T/inspect.json.removed"; mv "$DECL" "$T/conf/a.tools.yaml.off"
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 && -z "$(gk_pids "$T")" && ! -e "$STATE_ROOT" ]] && has_call create; then pass "H2: with no declaration, rc up starts no process and creates no state directory"; else fail "H2: ex=${EX} state=$(ls "$STATE_ROOT" 2>&1) ${OUT}"; fi
mv "$T/conf/a.tools.yaml.off" "$DECL"

# ============================================================================
echo "=== I: start failure, and the stop escalation ==="
printf '#!/bin/sh\ncase "$*" in *host-tool-gatekeeper.py*) exit 1 ;; esac\nexec "%s" "$@"\n' "$PY" > "$T/bin/badpy"; chmod 0755 "$T/bin/badpy"
rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up "RC_PYTHON3=$T/bin/badpy" -- up --conf "$CONF" "$T/ws"
NERR=$(printf '%s\n' "$OUT" | grep -c '^Error:' || true)
if [[ "$EX" -ne 0 && "$NERR" == 1 && "$OUT" == *"${STATE}/gatekeeper.log"* ]] && has_call create && ! has_call exec && [[ -z "$(gk_pids "$T")" ]]; then pass "I1: a gatekeeper that does not come up: one Error: line naming the log, non-zero, the cage left as created (create recorded, no init)"; else fail "I1: ex=${EX} errors=${NERR} calls=$(calls) ${OUT}"; fi
stop_all
# stop: a stand-in that ignores SIGTERM, named like the gatekeeper, is killed after the wait
mkdir -p "$STATE"
bash -c 'trap "" TERM; while :; do sleep 0.2; done' "host-tool-gatekeeper.py" "${T}/standin" --socket "${SOCK}" &
STAND=$!
echo "$STAND" > "$PIDF"; : > "$SOCK"
T0=$(date +%s)
_host_tools_gatekeeper_stop "$NAME" "$STATE"
T1=$(date +%s)
if ! alive "$STAND" && [[ ! -e "$PIDF" && ! -e "$SOCK" && $((T1 - T0)) -ge 9 && $((T1 - T0)) -le 13 ]]; then pass "I2: stop: SIGTERM ignored -> SIGKILL after the 10 s wait ($((T1 - T0)) s), socket and pid file removed"; else fail "I2: alive=$(alive "$STAND" && echo y || echo n) t=$((T1 - T0))"; fi
{ wait "$STAND"; } 2>/dev/null
# stop: a recycled pid (a live process that is not the gatekeeper) is not signalled
sleep 30 &
OTHER=$!
echo "$OTHER" > "$PIDF"; : > "$SOCK"
_host_tools_gatekeeper_stop "$NAME" "$STATE"
if alive "$OTHER" && [[ ! -e "$PIDF" ]]; then pass "I3: stop never signals a live pid whose command line is not the gatekeeper's; the stale pid file is removed"; else fail "I3"; fi
kill "$OTHER" 2>/dev/null; { wait "$OTHER"; } 2>/dev/null

# ============================================================================
echo "=== J: create-path gatekeeper failure stops the cage; the next rc up retries ==="
stop_all
rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up "RC_PYTHON3=$T/bin/badpy" -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -ne 0 ]] && has_call create && has_call stop && ! has_call exec; then pass "J1: gatekeeper failure on create: the cage is stopped (fake stop recorded), init never ran (no exec), exit ${EX}"; else fail "J1: ex=${EX} calls=$(calls) ${OUT}"; fi
if ! has_call remove; then pass "J1b: the cage is not removed (stays as created, stopped)"; else fail "J1b: remove recorded"; fi
mk_inspect Stopped present
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 ]] && has_call start && has_call 'exec .*init-rip-cage.sh' && alive "$(gk_pid)"; then pass "J2: the next rc up (fake Stopped) takes the stopped path: fresh gatekeeper, start, init exec recorded"; else fail "J2: ex=${EX} calls=$(calls) ${OUT}"; fi
stop_all
rm -f "$T/inspect.json" "$T/inspect.json.removed"; : > "$LOG"
JOUT=$(cd "$T/cwd" && env RC_PYTHON3="$T/bin/badpy" "$RC" --output json up --conf "$CONF" "$T/ws" 2>/dev/null </dev/null); JEX=$?
if [[ "$JEX" -ne 0 && "$(jq -r '.status' <<<"$JOUT" 2>/dev/null)" == stopped && "$(jq -r '.init' <<<"$JOUT" 2>/dev/null)" == not-run \
      && "$(jq -r '.host_tools.status' <<<"$JOUT" 2>/dev/null)" == gatekeeper-failed && "$(jq -r '.host_tools.log' <<<"$JOUT" 2>/dev/null)" == "${STATE}/gatekeeper.log" ]] && has_call stop; then
  pass "J3: --output json: status stopped, init not-run, host_tools gatekeeper-failed with the log path"
else fail "J3: ex=${JEX} ${JOUT}"; fi

# ============================================================================
echo "=== K: an unreadable pid file is an unknown owner ==="
stop_all
rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up -- up --conf "$CONF" "$T/ws"
KG=$(gk_pid)
if [[ "$(id -u)" == 0 ]]; then
  echo "SKIP: K: running as root, chmod 000 does not hide the file"
elif ! alive "$KG"; then
  fail "K0: setup: no gatekeeper (${OUT})"
else
  chmod 000 "$PIDF"
  mk_inspect Running present
  run_up -- destroy "$NAME"
  if [[ "$EX" -ne 0 && "$OUT" == *"${PIDF}"* && "$OUT" == *"cannot be read"* ]] && alive "$KG" && [[ -S "$SOCK" && -e "$STATE/tools.json" ]] && ! has_call remove; then pass "K1: pid file chmod 000: destroy exits non-zero naming the file, gatekeeper alive, socket and state directory intact, no remove"; else fail "K1: ex=${EX} alive=$(alive "$KG" && echo y || echo n) ${OUT}"; fi
  kill -KILL "$KG" 2>/dev/null; wait_dead "$KG" >/dev/null
  run_up -- up --conf "$CONF" "$T/ws"
  if [[ "$EX" -ne 0 && "$OUT" == *"cannot be read"* && "$OUT" != *"by hand"* && -e "$PIDF" ]]; then pass "K2: the running-branch restart refuses on the unreadable pid file, never suggests removing by hand, deletes nothing"; else fail "K2: ex=${EX} ${OUT}"; fi
  chmod 600 "$PIDF"
  run_up -- destroy "$NAME"
  if [[ "$EX" -eq 0 && ! -e "$STATE" && -z "$(gk_pids "$T")" ]]; then pass "K3: after chmod back, destroy succeeds and leaves nothing"; else fail "K3: ex=${EX} ${OUT}"; fi
fi

# ============================================================================
echo "=== L: symlinks never steer an act ==="
stop_all
mkdir -p "$STATE"; chmod 0700 "$STATE"
printf 'keep\n' > "$T/victim"
ln -s "$T/victim" "$STATE/lock"
mk_inspect Stopped present
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -ne 0 && "$OUT" == *"lock is a symlink"* && "$(cat "$T/victim")" == keep && -z "$(gk_pids "$T")" ]] && ! has_call start; then pass "L1: lock symlinked to a file: refused, the target untouched, nothing started"; else fail "L1: ex=${EX} victim=$(cat "$T/victim") ${OUT}"; fi
rm -f "$STATE/lock"; ln -s "$T/nothere" "$STATE/lock"
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -ne 0 && ! -e "$T/nothere" && ! -L "$T/nothere" && -z "$(gk_pids "$T")" ]]; then pass "L2: dangling lock symlink: refused, nothing created at its target"; else fail "L2: ex=${EX} ${OUT}"; fi
stop_all
# a label naming a directory whose parent is a symlink
rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up "RC_STATE_DIR=$T/alt" -- up --conf "$CONF" "$T/ws"      # real gatekeeper under alt/<cage>
LG=$(cat "$T/alt/$NAME/gatekeeper.pid" 2>/dev/null)
ln -s "$T/alt" "$T/linkparent"
mk_inspect Running present "$T/linkparent/$NAME"
run_up -- destroy "$NAME"
if [[ "$EX" -ne 0 && "$OUT" == *"symlink"* && -e "$T/alt/$NAME/tools.json" ]] && alive "$LG" && ! has_call remove; then pass "L3: label with a symlinked parent: destroy refused (non-zero), gatekeeper and directory untouched"; else fail "L3: ex=${EX} alive=$(alive "$LG" && echo y || echo n) ${OUT}"; fi
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -ne 0 && "$OUT" == *"symlink"* ]] && alive "$LG"; then pass "L4: the same label on rc up: refused, the live gatekeeper untouched"; else fail "L4: ex=${EX} ${OUT}"; fi
rm -f "$T/linkparent"
stop_all

# ============================================================================
echo "=== M: two rc up serialize ==="
printf '#!/bin/sh\ncase "$*" in *host-tool-gatekeeper.py*) date +%%s%%N >> "%s"; sleep 1 ;; esac\nexec "%s" "$@"\n' "$T/marks" "$PY" > "$T/bin/slowpy"; chmod 0755 "$T/bin/slowpy"
M_OK=1; M_DETAIL=''
for _round in 1 2 3; do
  stop_all; : > "$T/marks"; rm -f "$T/inspect.json.removed"
  mk_inspect Stopped present
  ( cd "$T/cwd" && RC_PYTHON3="$T/bin/slowpy" "$RC" up --conf "$CONF" "$T/ws" >"$T/m1.out" 2>&1 </dev/null ) & P1=$!
  sleep 0.03
  ( cd "$T/cwd" && RC_PYTHON3="$T/bin/slowpy" "$RC" up --conf "$CONF" "$T/ws" >"$T/m2.out" 2>&1 </dev/null ) & P2=$!
  wait "$P1"; E1=$?; wait "$P2"; E2=$?
  NG=$(gk_pids "$STATE" | wc -l | tr -d ' ')
  M1=$(sed -n 1p "$T/marks"); M2=$(sed -n 2p "$T/marks")
  if [[ "$E1" -ne 0 || "$E2" -ne 0 || "$NG" != 1 || -z "$M1" || -z "$M2" || $((M2 - M1)) -lt 1000000000 ]]; then
    M_OK=0; M_DETAIL="round ${_round}: exits ${E1}/${E2} gatekeepers=${NG} launches ${M1:-none} ${M2:-none}: $(cat "$T/m1.out" "$T/m2.out" | head -4)"
  fi
done
if [[ "$M_OK" == 1 ]]; then pass "M1: two rc up 30 ms apart on a stopped cage, 3 rounds: both exit 0, exactly one gatekeeper, the second launch began >= 1 s after the first (it waited on the lock)"; else fail "M1: ${M_DETAIL}"; fi
stop_all

# ============================================================================
echo "=== N: readiness failure, descriptors, destroy names ==="
printf '#!/bin/sh\ncase "$*" in *host-tool-gatekeeper.py*) trap "" TERM; while :; do sleep 0.2; done ;; esac\nexec "%s" "$@"\n' "$PY" > "$T/bin/hangpy"; chmod 0755 "$T/bin/hangpy"
rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up "RC_PYTHON3=$T/bin/hangpy" -- up --conf "$CONF" "$T/ws"
sleep 0.5
if [[ "$EX" -ne 0 && "$OUT" == *"did not become ready"* && -z "$(gk_pids "$T")" && ! -e "$PIDF" && "$OUT" != *"left as created"* ]]; then pass "N1: a TERM-ignoring start that never listens: killed, pid file gone, no process remains"; else fail "N1: ex=${EX} procs=$(gk_pids "$T") ${OUT}"; fi
mk_inspect Stopped present
run_up -- up --conf "$CONF" "$T/ws"
if [[ "$EX" -eq 0 ]] && alive "$(gk_pid)" && [[ "$(listed)" == *'"go"'* ]]; then pass "N2: the next rc up does not mistake the dead start for a live gatekeeper: a fresh one serves"; else fail "N2: ex=${EX} ${OUT}"; fi
stop_all
sleep 2 5>"$T/fd5" & CTRL=$!
if fd_targets "$CTRL" | grep -qx "$T/fd5"; then pass "N3a: control: a caller's fd 5 is visible in an inheriting child's /proc fd list"; else fail "N3a: control"; fi
kill "$CTRL" 2>/dev/null; { wait "$CTRL"; } 2>/dev/null
: > "$LOG"; rm -f "$T/inspect.json" "$T/inspect.json.removed"
OUT=$(cd "$T/cwd" && "$RC" up --conf "$CONF" "$T/ws" 5>"$T/fd5" 2>&1 </dev/null); EX=$?
FG=$(gk_pid)
if [[ "$EX" -eq 0 ]] && alive "$FG" && ! fd_targets "$FG" | grep -qx "$T/fd5"; then pass "N3: a descriptor the caller left open (fd 5) is absent from the gatekeeper's /proc fd list"; else fail "N3: ex=${EX} $(fd_targets "$FG" | paste -sd';' -)"; fi
stop_all
mkdir -p "$XDG_STATE_HOME/x"; : > "$XDG_STATE_HOME/x/keep"
for BAD in .. ../x; do
  run_up -- destroy "$BAD"
  if [[ "$EX" -ne 0 && "$OUT" == *"is not a cage name"* && -z "$(calls)" && -e "$XDG_STATE_HOME/x/keep" && -d "$XDG_STATE_HOME" ]]; then pass "N4: rc destroy ${BAD} refuses before touching anything (no msb call, nothing removed)"; else fail "N4 ${BAD}: ex=${EX} calls=$(calls) ${OUT}"; fi
done
# a gone cage whose default state directory is a symlink: refused, never reported removed
mkdir -p "$T/elsewhere"; : > "$T/elsewhere/keep"; mkdir -p "$STATE_ROOT"
ln -s "$T/elsewhere" "$STATE"
rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up "FAKE_MSB_NO_VOLUMES=1" -- destroy "$NAME"
if [[ "$EX" -ne 0 && "$OUT" != *"removed its state directory"* && "$OUT" == *"NOT removed"* && -e "$T/elsewhere/keep" ]]; then pass "N5: orphan path: a symlinked state directory is refused; 'removed its state directory' is not printed; exit non-zero"; else fail "N5: ex=${EX} ${OUT}"; fi
rm -f "$STATE"

# ============================================================================
echo "=== O: a long command line, and refusals before the cage is touched ==="
stop_all
rm -f "$T/inspect.json" "$T/inspect.json.removed"
run_up -- up --conf "$CONF" "$T/ws"
OG=$(gk_pid)
mk_inspect Running present
run_up COLUMNS=80 -- up --conf "$CONF" "$T/ws"
NG=$(gk_pids "$T" | wc -l | tr -d ' ')
if [[ "$EX" -eq 0 && "$(gk_pid)" == "$OG" && "$NG" == 1 ]] && alive "$OG"; then pass "O1: COLUMNS=80 rc up on a running cage with a live gatekeeper: same pid (${OG}), exactly one gatekeeper"; else fail "O1: ex=${EX} pid=$(gk_pid) want ${OG} n=${NG} ${OUT}"; fi
run_up COLUMNS=80 -- destroy "$NAME"
if [[ "$EX" -eq 0 && -z "$(gk_pids "$T")" && ! -e "$STATE" ]] && ! alive "$OG"; then pass "O2: COLUMNS=80 rc destroy leaves no gatekeeper and no state directory"; else fail "O2: ex=${EX} procs=$(gk_pids "$T") ${OUT}"; fi
stop_all
if [[ "$(id -u)" == 0 ]]; then
  echo "SKIP: O3: running as root, chmod 000 does not hide the file"
else
  rm -f "$T/inspect.json" "$T/inspect.json.removed"
  run_up -- up --conf "$CONF" "$T/ws"
  OG=$(gk_pid); chmod 000 "$PIDF"
  mk_inspect Running present
  run_up -- up --replace --conf "$CONF" "$T/ws"
  if [[ "$EX" -eq 1 && "$OUT" == *"cannot be read"* ]] && ! has_call stop && ! has_call remove && alive "$OG"; then pass "O3: pid file 000 + rc up --replace on a running cage: exit 1, no msb stop, no remove, gatekeeper alive"; else fail "O3: ex=${EX} calls=$(calls) ${OUT}"; fi
  chmod 600 "$PIDF"
  mk_decl "$DECL"; mk_inspect Running present "$T/linkparent/$NAME"
  ln -s "$T/alt" "$T/linkparent"
  run_up -- up --replace --conf "$CONF" "$T/ws"
  if [[ "$EX" -eq 1 && "$OUT" == *"To recover: stop the gatekeeper by hand"* ]] && ! has_call stop; then pass "O4: a symlinked label dir on --replace: refused before msb stop, with the recovery step"; else fail "O4: ex=${EX} calls=$(calls) ${OUT}"; fi
  rm -f "$T/linkparent"
  chmod 000 "$PIDF"; mk_inspect Running present
  run_up -- destroy "$NAME"
  if [[ "$EX" -ne 0 && "$OUT" == *"To recover: stop the gatekeeper by hand"* ]]; then pass "O5: destroy's refusal names the recovery step"; else fail "O5: ${OUT}"; fi
  chmod 600 "$PIDF"
fi
stop_all

echo ""
if [[ "$FAILURES" -eq 0 ]]; then echo "All host-tool lifecycle checks passed"; exit 0; fi
echo "${FAILURES} host-tool lifecycle check(s) FAILED"
exit 1
