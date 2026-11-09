#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2001,SC2013  # A&&B||C pass/fail idiom; planted tool bodies and the metachar literal are deliberately single-quoted
set -uo pipefail

# tests/test-host-tool-gatekeeper.sh -- host-tier proof for rip-cage-jdl2.2
# (ADR-032 D3/D6): cli/lib/host-tool-gatekeeper.py, the host-side validator and
# argv executor, driven over a real AF_UNIX socket. No cage, no msb, no vsock.
#
# The declaration goes through the REAL loader (cli/lib/host_tools.sh), so the
# JSON shape .1 produces is the shape the gatekeeper is proven against. Tool
# scripts are planted under $T/tools (outside the mount list, as declared argv
# must be). The gatekeeper is launched with canary secrets in its environment,
# another HOME, and from another cwd, on purpose.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GK="${REPO_ROOT}/cli/lib/host-tool-gatekeeper.py"
CLIENT="${SCRIPT_DIR}/fixtures/host-tool-gatekeeper/client.py"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
PY="$(command -v python3 || true)"
[[ -n "$PY" ]] || { echo "SKIP: python3 not on PATH"; exit 0; }
PY="$(cd "$(dirname "$PY")" && pwd -P)/$(basename "$PY")"

T=$(mktemp -d /tmp/rc-gk-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
GK_PIDS=""
cleanup() {
  local p q
  for p in $GK_PIDS; do kill -TERM "$p" 2>/dev/null; done
  sleep 0.3
  for p in $GK_PIDS; do kill -KILL "$p" 2>/dev/null; done
  for p in "$T"/pids/*; do
    [[ -f "$p" ]] || continue
    while read -r q; do [[ -n "$q" ]] && kill -KILL "$q" 2>/dev/null; done < "$p"
  done
  chmod -R u+rwx "$T" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$T/ws" "$T/tools" "$T/state" "$T/state2" "$T/elsewhere" "$T/other-home" "$T/pids" "$T/bin"
SOCK="$T/state/host-tool.sock"
: > "$T/errors.log"; : > "$T/values.log"

# --- plant the tools ------------------------------------------------------
plant_tool() { printf '#!/bin/sh\n%s\n' "$2" > "$T/tools/$1"; chmod 755 "$T/tools/$1"; }
plant_tool argv-echo 'printf "%s\n" "$#"; for a in "$@"; do printf "%s\n" "$a"; done'
plant_tool canary "touch '$T/canary-marker'"
plant_tool plant 'echo planted > "$HOME/.gitconfig"; echo planted > "$HOME/planted"; mkdir -p "$HOME/sub"; echo x > "$HOME/sub/f"; chmod 500 "$HOME/sub"'
plant_tool ls-home 'ls -A "$HOME"'
plant_tool homecwd 'printf "%s\n%s\n" "$HOME" "$(pwd -P)"'
plant_tool sleep-fork "sleep 60 & echo \$! >> '$T/pids/sleepfork'; echo \$\$ >> '$T/pids/sleepfork'; sleep 60"
plant_tool sleeper "echo \$\$ >> '$T/pids/sleeper'; sleep 20 & echo \$! >> '$T/pids/sleeper'; wait"
plant_tool stream "sleep 30 & echo \$! >> '$T/pids/stream'; exec yes yyyyyyyyyyyyyyyy"
plant_tool big "sleep 30 & echo \$! >> '$T/pids/big'; head -c 20000 /dev/zero | tr '\\0' '\"'"
plant_tool fail7 'echo "SECRETSTDERR-token" >&2; echo "partial stdout"; exit 7'
plant_tool pidinfo 'echo "$$ $(ps -o sid= -p $$ | tr -d " ")"'
plant_tool git-shaped 'if [ -e "$HOME/.gitconfig" ]; then echo present; else echo absent; fi'
plant_tool gone-tool 'echo should-not-run'
plant_tool ppid-env 'tr "\0" "\n" < "/proc/$PPID/environ"'
plant_tool hold 'sleep 4; echo held'
plant_tool late "echo \$\$ >> '$T/pids/late'; sleep 30"
printf '#!/bin/sh\necho ok\n' > "$T/bin/tool"; chmod 755 "$T/bin/tool"

cat > "$T/decl.yaml" <<YAML
tools:
  t:
    verbs:
      echo:
        argv: ["$T/tools/argv-echo", "{v}"]
        slots:
          v: {type: string, allow_dash: true, allow_slash: true}
        timeout: 10s
      lit:
        argv: ["$T/tools/argv-echo", "fixed", "{s}"]
        slots:
          s: {type: string, max: 5}
        timeout: 10s
      rx:
        argv: ["$T/tools/argv-echo", "{w}"]
        slots:
          w: {type: string, regex: "^[a-z]+\$"}
        timeout: 10s
      dflt:
        argv: ["$T/tools/argv-echo", "{n}", "{m}", "{d}"]
        slots:
          n: {type: int, default: 7}
          m: {type: enum, values: [a, b], default: b}
          d: {type: string, default: hi}
        timeout: 10s
      can:
        argv: ["$T/tools/canary", "{s}", "{i}", "{e}"]
        slots:
          s: {type: string, max: 5}
          i: {type: int, min: 1, max: 10}
          e: {type: enum, values: [a, b]}
        timeout: 10s
      envp:
        argv: ["/usr/bin/env"]
        timeout: 10s
      homecwd:
        argv: ["$T/tools/homecwd"]
        timeout: 10s
      plant:
        argv: ["$T/tools/plant"]
        timeout: 10s
      lshome:
        argv: ["$T/tools/ls-home"]
        timeout: 10s
      gitshaped:
        argv: ["$T/tools/git-shaped"]
        timeout: 10s
      sleepfork:
        argv: ["$T/tools/sleep-fork"]
        timeout: 1s
      sleeper:
        argv: ["$T/tools/sleeper"]
        timeout: 30s
      stream:
        argv: ["$T/tools/stream"]
        timeout: 30s
      big:
        argv: ["$T/tools/big"]
        timeout: 30s
      fail7:
        argv: ["$T/tools/fail7"]
        timeout: 10s
      pidinfo:
        argv: ["$T/tools/pidinfo"]
        timeout: 10s
      ppidenv:
        argv: ["$T/tools/ppid-env"]
        timeout: 10s
      hold:
        argv: ["$T/tools/hold"]
        timeout: 20s
      late:
        argv: ["$T/tools/late"]
        timeout: 40s
      gone:
        argv: ["$T/tools/gone-tool"]
        timeout: 10s
YAML
printf '%s\n' "$T/ws" > "$T/mounts"

# --- load through the real loader ------------------------------------------
# shellcheck source=cli/lib/protected_paths.sh
source "${REPO_ROOT}/cli/lib/protected_paths.sh"
# shellcheck source=cli/lib/msb_runtime.sh
source "${REPO_ROOT}/cli/lib/msb_runtime.sh"
# shellcheck source=cli/lib/host_tools.sh
source "${REPO_ROOT}/cli/lib/host_tools.sh"
if _host_tools_load "$T/decl.yaml" "$T/mounts" > "$T/state/tools.json" 2> "$T/load.err"; then
  pass "real loader accepts the test declaration"
else
  fail "real loader refused the declaration: $(cat "$T/load.err")"; echo "failures: $FAILURES"; exit 1
fi
sed "s|@T@|${T}|g" "${SCRIPT_DIR}/fixtures/host-tools/valid.tools.yaml" > "$T/valid.yaml"
if _host_tools_load "$T/valid.yaml" "$T/mounts" > "$T/state2/tools.json" 2> "$T/load2.err"; then
  pass "real loader accepts .1's valid fixture"
else
  fail "real loader refused valid fixture: $(cat "$T/load2.err")"
fi

# --- gatekeeper launch helpers ---------------------------------------------
start_gk() { # state-dir [extra args...]; sets LAST_GK_PID. GK_LANG (if set) is the launch LANG.
  local st="$1"; shift
  ( cd "$T/elsewhere" && env -i CCTOK=canary GITHUB_TOKEN=canary MSB_X=canary XDG_CONFIG_HOME=/canary \
      HOME="$T/other-home" PATH="$PATH" ${GK_LANG:+"LANG=$GK_LANG"} "$PY" -I "$GK" --socket "$st/host-tool.sock" --decl "$st/tools.json" \
      --log "$st/gatekeeper.log" --pid "$st/gatekeeper.pid" --cwd "$st" "$@" >/dev/null 2>&1 & )
  local i
  for i in $(seq 1 50); do
    if [[ -s "$st/gatekeeper.pid" && -S "$st/host-tool.sock" ]]; then
      LAST_GK_PID="$(cat "$st/gatekeeper.pid")"; GK_PIDS="$GK_PIDS $LAST_GK_PID"; return 0
    fi
    sleep 0.1
  done
  return 1
}
note_err() { case "$1" in *'"ok":false'*) printf '%s\n' "$1" >> "$T/errors.log" ;; esac; }
# rpc SOCK [client opts]: stdin request -> reply line. EVERY reply the suite receives passes
# through here (error replies collected), and every string in the request's args (>= 4 chars,
# shorter ones cannot be grepped meaningfully) is recorded for the hygiene sweep.
rpc() {
  local sock="$1" f r; shift
  f="$(mktemp "$T/req.XXXXXX")"; cat > "$f"
  jq -r '(.args? // empty) | .. | strings' "$f" 2>/dev/null | while IFS= read -r l; do
    [[ ${#l} -ge 4 ]] && printf '%s\n' "$l" >> "$T/values.log"
  done
  r="$("$PY" -I "$CLIENT" "$sock" "$@" < "$f")"
  rm -f "$f"
  note_err "$r"
  printf '%s\n' "$r"
}
call() { # verb argsjson -> reply on stdout (also logged for hygiene)
  local a="${2-}" r
  [[ -n "$a" ]] || a='{}'
  r="$(jq -nc --arg verb "$1" --argjson args "$a" '{v:1,tool:"t",verb:$verb,args:$args}' | rpc "$SOCK")"
  printf '%s\n' "$r"
}
raw() { printf '%s\n' "$1" | rpc "$SOCK"; }
kind() { jq -r '.error.kind // "ok"' <<<"$1" 2>/dev/null || echo unparseable; }
sent() { printf '%s\n' "$1" >> "$T/values.log"; }
refused() { # name reply want-kind
  local k; k="$(kind "$2")"
  if [[ "$k" == "$3" && ! -e "$T/canary-marker" ]]; then
    pass "$1 -> $3, nothing ran"
  else
    fail "$1: want $3, got $k ($(printf '%.200s' "$2")); canary: $([[ -e $T/canary-marker ]] && echo PRESENT || echo absent)"
  fi
}
calls_empty() { [[ -z "$(ls -A "$T/state/calls" 2>/dev/null)" ]]; }
any_alive() { # pid-file -> 0 when any listed pid is still alive
  local q
  while read -r q; do [[ -n "$q" ]] && kill -0 "$q" 2>/dev/null && return 0; done < "$1"
  return 1
}

if start_gk "$T/state"; then
  pass "gatekeeper started (pid file and socket within 5 s)"
else
  fail "gatekeeper did not come up: $(cat "$T/state/gatekeeper.log" 2>/dev/null)"; echo "failures: $FAILURES"; exit 1
fi
GK_PID="$LAST_GK_PID"
mode="$(stat -c %a "$SOCK" 2>/dev/null || stat -f %Lp "$SOCK")"
[[ "$mode" == 600 ]] && pass "socket mode 0600" || fail "socket mode is $mode"

# --- ok call, one-element argv ---------------------------------------------
sent "plainvalue"
r="$(call echo '{"v":"plainvalue"}')"
[[ "$(jq -r .result <<<"$r")" == "$(printf '1\nplainvalue')" ]] && pass "well-formed call returns stdout (argc 1 + the value)" || fail "ok call: $r"

META='; touch canary $(id) | cat'
r="$(call echo "$(jq -nc --arg v "$META" '{v:$v}')")"
[[ "$(jq -r .result <<<"$r")" == "$(printf '1\n%s' "$META")" ]] && pass "metacharacter value arrives as exactly one literal argv element" || fail "metachar: $r"
[[ ! -e "$T/canary-marker" && ! -e "$T/state/canary" ]] && pass "no canary file after the metacharacter call" || fail "canary file appeared"

# --- defaults ----------------------------------------------------------------
r="$(call dflt '{}')"
[[ "$(jq -r .result <<<"$r")" == "$(printf '3\n7\nb\nhi')" ]] && pass "omitted slots filled from defaults" || fail "defaults: $r"
r="$(call dflt '{"n":9,"m":"a","d":"zzzz"}')"
[[ "$(jq -r .result <<<"$r")" == "$(printf '3\n9\na\nzzzz')" ]] && pass "supplied slots override defaults" || fail "override: $r"

# --- refusals: canary verb ---------------------------------------------------
rm -f "$T/canary-marker"
refused "unknown tool" "$(raw '{"v":1,"tool":"canary","verb":"can","args":{}}')" no-such-tool
refused "unknown verb" "$(raw '{"v":1,"tool":"t","verb":"canary","args":{}}')" no-such-verb
refused "unknown tool named canary, verb canary" "$(raw '{"v":1,"tool":"canary","verb":"canary","args":{}}')" no-such-tool
refused "unknown top-level field" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","i":5,"e":"a"},"extra":1}')" bad-argument
refused "unknown top-level field on list" "$(raw '{"v":1,"list":true,"extra":1}')" bad-argument
refused "wrong v" "$(raw '{"v":2,"tool":"t","verb":"can","args":{"s":"abc","i":5,"e":"a"}}')" bad-argument
refused "v is true" "$(raw '{"v":true,"tool":"t","verb":"can","args":{"s":"abc","i":5,"e":"a"}}')" bad-argument
refused "tool of the wrong type" "$(raw '{"v":1,"tool":5,"verb":"can","args":{}}')" bad-argument
refused "verb of the wrong type" "$(raw '{"v":1,"tool":"t","verb":["can"],"args":{}}')" bad-argument
refused "tool missing" "$(raw '{"v":1,"verb":"can","args":{}}')" bad-argument
refused "verb missing" "$(raw '{"v":1,"tool":"t","args":{}}')" bad-argument
refused "v missing" "$(raw '{"tool":"t","verb":"can","args":{"s":"abc","i":5,"e":"a"}}')" bad-argument
refused "not JSON" "$(raw 'not json at all')" bad-argument
refused "unknown arg" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","i":5,"e":"a","zz":1}}')" bad-argument
refused "missing required slot" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","e":"a"}}')" bad-argument
refused "string with newline (123\\n)" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"123\n","i":5,"e":"a"}}')" bad-argument
refused "NUL in string" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"a\u0000b","i":5,"e":"a"}}')" bad-argument
refused "control char (tab)" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"a\tb","i":5,"e":"a"}}')" bad-argument
refused "bool for int" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","i":true,"e":"a"}}')" bad-argument
refused "numeric string for int" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","i":"5","e":"a"}}')" bad-argument
refused "float for int" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","i":5.0,"e":"a"}}')" bad-argument
refused "int below min" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","i":0,"e":"a"}}')" bad-argument
refused "int above max" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","i":11,"e":"a"}}')" bad-argument
sent zzenum
refused "enum miss" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","i":5,"e":"zzenum"}}')" bad-argument
sent toolongvalue
refused "string over max" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"toolongvalue","i":5,"e":"a"}}')" bad-argument
refused "leading dash without allow_dash" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"-rf","i":5,"e":"a"}}')" bad-argument
refused "slash without allow_slash" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"a/b","i":5,"e":"a"}}')" bad-argument
refused ".. without allow_slash" "$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"..","i":5,"e":"a"}}')" bad-argument
refused "args not an object" "$(raw '{"v":1,"tool":"t","verb":"can","args":[1]}')" bad-argument
r="$(call rx '{"w":"abc1"}')"; [[ "$(kind "$r")" == bad-argument ]] && pass "regex miss -> bad-argument" || fail "regex miss: $r"
r="$(call rx '{"w":"abc"}')"; [[ "$(kind "$r")" == ok ]] && pass "regex full match accepted" || fail "regex ok: $r"
r="$(call echo '{"v":"a\nb"}')"; [[ "$(kind "$r")" == bad-argument ]] && pass "newline refused even on a permissive slot" || fail "permissive newline: $r"
r="$(call echo '{"v":"../x"}')"; [[ "$(kind "$r")" == ok ]] && pass "allow_slash slot admits .. and /" || fail "allow_slash: $r"
r="$(call echo '{"v":"a\u2028bcd"}')"; [[ "$(kind "$r")" == bad-argument ]] && pass "U+2028 (Zl) refused in a string value" || fail "U+2028: $r"
r="$(call echo '{"v":"a\u2029bcd"}')"; [[ "$(kind "$r")" == bad-argument ]] && pass "U+2029 (Zp) refused in a string value" || fail "U+2029: $r"
r="$(printf '%s' '{"v":1,"tool":"t","verb":"echo","args":{"v":"halfclosed"}}' | rpc "$SOCK" --halfclose)"
[[ "$(jq -r .result <<<"$r")" == "$(printf '1\nhalfclosed')" ]] && pass "request with no trailing newline + half-close is processed" || fail "half-close: $r"
r="$(call echo '{"v":"-x"}')"; [[ "$(kind "$r")" == ok ]] && pass "allow_dash slot admits a leading dash" || fail "allow_dash: $r"
r="$(call lit '{"s":"a..b"}')"; [[ "$(kind "$r")" == ok ]] && pass "a..b passes on a plain slot (only the segment .. is refused)" || fail "a..b: $r"
r="$(call lit '{"s":"..."}')"; [[ "$(kind "$r")" == ok ]] && pass "... is not a .. segment" || fail "...: $r"
r="$(call lit '{"s":"abcdé"}')"; [[ "$(kind "$r")" == bad-argument ]] && pass "string max counts bytes (5 chars, 6 bytes)" || fail "byte max: $r"

# --- request cap ---------------------------------------------------------------
big40="$(head -c 40000 /dev/zero | tr '\0' 'a')"
sent "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
refused "request over 32 KiB" "$(raw "{\"v\":1,\"tool\":\"t\",\"verb\":\"can\",\"args\":{\"s\":\"$big40\",\"i\":5,\"e\":\"a\"}}")" request-too-large
refused "oversized line with no newline (40 KiB)" "$(printf '%s' "$big40" | rpc "$SOCK" --halfclose)" request-too-large
r="$(raw '{"v":1,"tool":"t","verb":"can","args":{"s":"abc","i":5,"e":"a"}}')"
[[ "$(kind "$r")" == ok && -e "$T/canary-marker" ]] && pass "canary harness is live (a valid call does run it)" || fail "canary harness dead: $r"
rm -f "$T/canary-marker"

# --- reply cap / output bound --------------------------------------------------
: > "$T/pids/big"; : > "$T/pids/stream"
r="$(call big '{}')"
[[ "$(kind "$r")" == reply-too-large ]] && pass "20000 raw bytes that encode over 32 KiB -> reply-too-large" || fail "big: $(printf '%.200s' "$r")"
[[ "$r" != *'\"\"\"'* ]] && pass "reply-too-large returns nothing partial" || fail "big leaked output"
sleep 0.4
any_alive "$T/pids/big" && fail "big: group process still alive" || pass "big: no process left in the group"
r="$(call stream '{}')"
[[ "$(kind "$r")" == reply-too-large ]] && pass "never-ending stream cut at the bound -> reply-too-large" || fail "stream: $(printf '%.200s' "$r")"
sleep 0.4
any_alive "$T/pids/stream" && fail "stream: group process still alive" || pass "stream: no process left in the group"
calls_empty && pass "no call directory survives big/stream" || fail "calls/ not empty: $(ls "$T/state/calls")"

# --- timeout with a forking command -----------------------------------------
: > "$T/pids/sleepfork"
t0=$SECONDS
r="$(call sleepfork '{}')"
[[ "$(kind "$r")" == timeout ]] && pass "forking command past its timeout -> timeout" || fail "sleepfork: $r"
[[ $((SECONDS - t0)) -le 4 ]] && pass "timeout reply arrives promptly" || fail "timeout took $((SECONDS - t0)) s"
sleep 0.3
any_alive "$T/pids/sleepfork" && fail "timeout: group process still alive" || pass "timeout: no process left in the group (grandchild included)"

# --- environment, cwd, per-call HOME ----------------------------------------
r="$(call envp '{}')"
envtxt="$(jq -r .result <<<"$r")"
keys="$(sed 's/=.*//' <<<"$envtxt" | sort | tr '\n' ' ')"
[[ "$keys" == "HOME LANG PATH " ]] && pass "environment key set EQUALS {HOME, LANG, PATH}" || fail "env keys: '$keys'"
[[ "$(sed -n 's/^PATH=//p' <<<"$envtxt")" == "/usr/bin:/bin" ]] && pass "PATH is the platform constant /usr/bin:/bin" || fail "PATH: $envtxt"
case "$envtxt" in
  *canary*|*"$T/other-home"*) fail "launch-environment canary leaked into a tool" ;;
  *) pass "no launch canary (CCTOK/GITHUB_TOKEN/MSB_X/XDG/HOME) reached the tool" ;;
esac
gkenv="$(tr '\0' '\n' < "/proc/$GK_PID/environ" | sort)"
[[ "$(sed 's/=.*//' <<<"$gkenv" | tr '\n' ' ')" == "HOME LANG PATH " ]] && pass "/proc/<gatekeeper>/environ holds exactly {HOME, LANG, PATH}" || fail "gatekeeper environ: $(tr '\n' ' ' <<<"$gkenv")"
[[ "$gkenv" == "$(printf 'HOME=%s\nLANG=C.UTF-8\nPATH=/usr/bin:/bin' "$T/state")" ]] && pass "/proc/<gatekeeper>/environ values are HOME=<state>, LANG=C.UTF-8, PATH=constant" || fail "gatekeeper environ values: $(tr '\n' ' ' <<<"$gkenv")"
r="$(call ppidenv '{}')"; penv="$(jq -r .result <<<"$r")"
[[ "$(sed 's/=.*//' <<<"$penv" | sort | tr '\n' ' ')" == "HOME LANG PATH " ]] && pass "a tool reading /proc/\$PPID/environ sees exactly {HOME, LANG, PATH}" || fail "ppid environ: $(printf '%.200s' "$r")"
case "$penv" in *canary*) fail "launch canary readable through /proc/\$PPID/environ" ;; *) pass "no canary value readable through the parent's environ" ;; esac
hv="$(sed -n 's/^HOME=//p' <<<"$envtxt")"
[[ "$hv" == "$T/state/calls/"* ]] && pass "HOME is a path under <state>/calls/" || fail "HOME: $hv"
r="$(call homecwd '{}')"; h="$(jq -r .result <<<"$r" | sed -n 1p)"; c="$(jq -r .result <<<"$r" | sed -n 2p)"
[[ -n "$h" && "$h" == "$c" && "$c" == "$T/state/calls/"* ]] && pass "cwd equals HOME (gatekeeper launched from a different cwd)" || fail "cwd/HOME: '$h' '$c'"
calls_empty && pass "call directory gone after the call" || fail "calls/ not empty"
call plant '{}' >/dev/null
r="$(call lshome '{}')"
[[ "$(jq -r .result <<<"$r")" == "" && "$(kind "$r")" == ok ]] && pass "plant then ls: the next call's HOME is empty" || fail "ls-home: $r"
calls_empty && pass "calls/ empty after plant (incl. a read-only subdirectory)" || fail "calls/ not empty after plant: $(ls -A "$T/state/calls")"
r="$(call gitshaped '{}')"; [[ "$(jq -r .result <<<"$r")" == absent ]] && pass "git-shaped command finds no .gitconfig" || fail "git-shaped: $r"
[[ ! -e "$T/state/.gitconfig" && ! -e "$T/state/planted" && -s "$T/state/gatekeeper.pid" && -s "$T/state/tools.json" ]] && pass "state dir untouched by a tool's HOME writes" || fail "state dir polluted"

# --- tool-failed and stderr -----------------------------------------------------
r="$(call fail7 '{}')"
[[ "$(kind "$r")" == tool-failed && "$(jq -r .error.message <<<"$r")" == *7* ]] && pass "non-zero exit -> tool-failed carrying exit 7" || fail "fail7: $r"
case "$r" in *SECRETSTDERR*|*partial*) fail "stderr/partial stdout in a reply" ;; *) pass "stderr text and partial stdout never appear in the reply" ;; esac
grep -q SECRETSTDERR-token "$T/state/gatekeeper.log" && pass "tool stderr landed in the host log" || fail "stderr not in the log"
if grep -qF -e "plainvalue" -e "$META" "$T/state/gatekeeper.log"; then fail "gatekeeper log carries an argument value"; else pass "gatekeeper log lines carry no argument values"; fi

# --- sessions -------------------------------------------------------------------
gsid="$(ps -o sid= -p "$GK_PID" | tr -d ' ')"; mysid="$(ps -o sid= -p $$ | tr -d ' ')"
[[ -n "$gsid" && "$gsid" != "$mysid" ]] && pass "gatekeeper session id differs from its parent's" || fail "sid: gk=$gsid parent=$mysid"
r="$(call pidinfo '{}')"; tsid="$(jq -r .result <<<"$r" | awk '{print $2}')"
[[ -n "$tsid" && "$tsid" != "$gsid" ]] && pass "a command runs in its own session" || fail "tool sid $tsid vs gk $gsid"

# --- removed command ------------------------------------------------------------
rm -f "$T/tools/gone-tool"
r="$(call gone '{}')"; [[ "$(kind "$r")" == unavailable ]] && pass "removed declared command -> unavailable" || fail "gone: $r"

# --- list --------------------------------------------------------------------------
r="$(raw '{"v":1,"list":true}')"
[[ "$(jq -r '.ok' <<<"$r")" == true && "$r" != *'/'* ]] && pass "list succeeds and contains no /" || fail "list: $(printf '%.200s' "$r")"
jq -e '.result.tools.t.dflt == {"timeout":10,"slots":{"n":"int","m":"enum","d":"string"}} and (.result.tools.t.envp.slots == {})' <<<"$r" >/dev/null \
  && pass "list shape: tool>verb>{timeout,slots{name:type}}" || fail "list shape: $(printf '%.300s' "$r")"

# --- idle connections (all 4 slots, so a leaked slot turns the follow-up red) ---------
for i in 1 2 3 4; do "$PY" -I "$CLIENT" "$SOCK" --idle > "$T/idle.$i" & done
wait
okidle=1
for i in 1 2 3 4; do el="$(cat "$T/idle.$i")"; awk -v e="$el" 'BEGIN{exit !(e >= 10 && e < 13)}' || okidle=0; done
[[ $okidle -eq 1 ]] && pass "4 idle connections (the bound) each closed after ~10 s" || fail "idle close times: $(cat "$T"/idle.*)"
r="$(call echo '{"v":"after-idle"}')"; [[ "$(kind "$r")" == ok ]] && pass "a call after the idle closes is not busy (no slot leaked)" || fail "after idle: $r"

# --- a burst at the bound: exactly 4 served, the rest busy, none refused at connect ------
for i in $(seq 1 40); do ( call hold '{}' > "$T/burst.$i" ) & done
wait
nok=0; nbusy=0; nother=0
for i in $(seq 1 40); do
  case "$(kind "$(cat "$T/burst.$i")")" in ok) nok=$((nok + 1)) ;; busy) nbusy=$((nbusy + 1)) ;; *) nother=$((nother + 1)) ;; esac
done
[[ $nok -eq 4 && $nbusy -eq 36 && $nother -eq 0 ]] && pass "40 concurrent connections at bound 4: exactly 4 ok, 36 busy, none refused" || fail "burst: ok=$nok busy=$nbusy other=$nother"

# --- concurrency bound -----------------------------------------------------------
: > "$T/pids/sleeper"
for i in 1 2 3 4; do ( call sleeper '{}' > "$T/sleeper.$i.out" ) & done
for i in $(seq 1 50); do [[ "$(grep -c . "$T/pids/sleeper")" -ge 8 ]] && break; sleep 0.1; done
r="$(call echo '{"v":"fifth"}')"; [[ "$(kind "$r")" == busy ]] && pass "fifth connection (call) at bound 4 -> busy" || fail "fifth call: $r"
r="$(raw '{"v":1,"list":true}')"; [[ "$(kind "$r")" == busy ]] && pass "fifth connection (list) at bound 4 -> busy" || fail "fifth list: $r"
first="$(sed -n 1p "$T/pids/sleeper")"; kill -TERM "$first" 2>/dev/null
ok=0; r=""
for i in $(seq 1 30); do r="$(raw '{"v":1,"list":true}')"; [[ "$(kind "$r")" == ok ]] && { ok=1; break; }; sleep 0.1; done
[[ $ok -eq 1 ]] && pass "list succeeds the moment one slot frees" || fail "list after free: $r"
for q in $(sed -n '1~2p' "$T/pids/sleeper"); do kill -TERM "$q" 2>/dev/null; done
wait
calls_empty && pass "calls/ empty after the sleepers" || fail "calls/ not empty after sleepers"

# --- the same burst through the SHIPPED client (list, then call): 4 ok, 36 busy, no exit 5 ---
SHIPPED="${REPO_ROOT}/cage/substrate/host-tool"
for i in $(seq 1 40); do
  ( HOST_TOOL_SOCKET="$SOCK" "$PY" -I "$SHIPPED" t hold >/dev/null 2>&1; echo $? > "$T/sburst.$i" ) &
done
wait
s0=0; s4=0; sother=""
for i in $(seq 1 40); do
  c="$(cat "$T/sburst.$i")"
  case "$c" in 0) s0=$((s0 + 1)) ;; 4) s4=$((s4 + 1)) ;; *) sother="$sother $c" ;; esac
done
[[ $s0 -eq 4 && $s4 -eq 36 && -z "$sother" ]] && pass "shipped client, 40 concurrent at bound 4: exactly 4 exit 0, 36 exit 4, zero exit 5" || fail "shipped burst: exit0=$s0 exit4=$s4 other:$sother"

# --- launch locale: PEP 538 coercion must not make the gatekeeper refuse -------------------
lang_case() { # label launch-LANG(or "-" for none) expected-LANG
  local st="$T/stL$1" gp
  mkdir -p "$st"; cp "$T/state/tools.json" "$st/tools.json"
  if [[ "$2" == "-" ]]; then GK_LANG=""; else GK_LANG="$2"; fi
  if start_gk "$st"; then
    gp="$LAST_GK_PID"
    local blk r penv
    blk="$(tr '\0' '\n' < "/proc/$gp/environ" | sort | tr '\n' ' ')"
    r="$(jq -nc '{v:1,tool:"t",verb:"ppidenv",args:{}}' | rpc "$st/host-tool.sock")"; penv="$(jq -r .result <<<"$r" | grep . | sort | tr '\n' ' ')"
    local want="HOME=$st LANG=$3 PATH=/usr/bin:/bin "
    [[ "$blk" == "$want" && "$penv" == "$want" ]] && pass "launch LANG=${2}: starts; /proc environ and a tool's view are exactly {HOME, LANG=$3, PATH}" || fail "launch LANG=$2: blk='$blk' tool='$penv'"
    kill -TERM "$gp"; for i in $(seq 1 30); do kill -0 "$gp" 2>/dev/null || break; sleep 0.1; done
  else
    fail "launch LANG=$2: gatekeeper did not start: $(cat "$st/gatekeeper.log" 2>/dev/null)"
  fi
  GK_LANG=""
}
lang_case 1 C C
lang_case 2 POSIX POSIX
lang_case 3 xx_XX.UTF-8 xx_XX.UTF-8
lang_case 4 - C.UTF-8
GK_LANG=""

# --- uid 0 -------------------------------------------------------------------------
if unshare -r true 2>/dev/null; then
  unshare -r "$PY" -I "$GK" --socket "$T/u0.sock" --decl "$T/state/tools.json" --log "$T/u0.log" --pid "$T/u0.pid" --cwd "$T/state2" >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 && ! -e "$T/u0.sock" && ! -e "$T/u0.pid" ]] && pass "uid 0 refused (exit $rc) before binding" || fail "uid 0: rc=$rc"
else
  echo "SKIP: uid-0 case (unshare -r unavailable on this host)"
fi

# --- start refusals ---------------------------------------------------------------
: > "$T/exist.sock"
"$PY" -I "$GK" --socket "$T/exist.sock" --decl "$T/state/tools.json" --log "$T/exist.log" --pid "$T/exist.pid" --cwd "$T/state2" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && ! -e "$T/exist.pid" ]] && pass "refuses to start when the socket path exists" || fail "existing socket: rc=$rc"
cat > "$T/badrx.json" <<'JSON'
{"v":1,"tools":{"t":{"verbs":{"v":{"argv":["/bin/true","{a}"],"slots":{"a":{"type":"string","max":9,"allow_dash":false,"allow_slash":false,"regex":"(?<x"}},"timeout":5,"returns_secret":false}}}}}
JSON
"$PY" -I "$GK" --socket "$T/badrx.sock" --decl "$T/badrx.json" --log "$T/badrx.log" --pid "$T/badrx.pid" --cwd "$T/state2" >/dev/null 2>&1; rc=$?
nl="$(grep -c . "$T/badrx.log" 2>/dev/null)"
[[ $rc -ne 0 && ! -e "$T/badrx.sock" && ! -e "$T/badrx.pid" && "$nl" -eq 1 ]] && pass "regex Python re cannot compile -> non-zero exit, no socket, one log line" || fail "bad regex: rc=$rc lines=$nl"

# --- a default goes through the same validation (fill, then validate) -------
mkdir -p "$T/state3"
cat > "$T/state3/tools.json" <<JSON
{"v":1,"tools":{"t":{"verbs":{"d":{"argv":["$T/tools/argv-echo","{a}"],"slots":{"a":{"type":"string","max":9,"allow_dash":false,"allow_slash":false,"default":"-bad"}},"timeout":5,"returns_secret":false}}}}}
JSON
if start_gk "$T/state3"; then
  r="$(jq -nc '{v:1,tool:"t",verb:"d",args:{}}' | rpc "$T/state3/host-tool.sock")"
  [[ "$(kind "$r")" == bad-argument ]] && pass "omitted slot's default is filled then validated (bad default refused)" || fail "bad default: $r"
  r="$(jq -nc '{v:1,tool:"t",verb:"d",args:{a:"good"}}' | rpc "$T/state3/host-tool.sock")"
  [[ "$(kind "$r")" == ok ]] && pass "supplying the slot bypasses the bad default" || fail "supplied over bad default: $r"
  kill -TERM "$LAST_GK_PID"; for i in $(seq 1 30); do kill -0 "$LAST_GK_PID" 2>/dev/null || break; sleep 0.1; done
else
  fail "third gatekeeper (default case) did not start"
fi

# --- .1's fixture, second gatekeeper ------------------------------------------------
if start_gk "$T/state2"; then
  r="$(jq -nc '{v:1,list:true}' | rpc "$T/state2/host-tool.sock")"
  jq -e '.ok == true and (.result.tools.demo.send == {"timeout":30,"slots":{"chat":"string","limit":"int"}}) and (.result.tools.demo.all == {"timeout":120,"slots":{"mode":"enum","name":"string","n":"int"}}) and ((.result.tools | keys) == ["demo"])' <<<"$r" >/dev/null \
    && pass ".1 fixture loads and lists in the fixed shape" || fail "fixture list: $(printf '%.300s' "$r")"
  r="$(jq -nc '{v:1,tool:"demo",verb:"send",args:{chat:"-100123"}}' | rpc "$T/state2/host-tool.sock")"
  [[ "$(jq -r .result <<<"$r")" == ok ]] && pass ".1 fixture verb runs with its default and a dashed chat id" || fail "fixture call: $r"
  kill -TERM "$LAST_GK_PID"; for i in $(seq 1 30); do kill -0 "$LAST_GK_PID" 2>/dev/null || break; sleep 0.1; done
else
  fail "second gatekeeper (fixture) did not start: $(cat "$T/state2/gatekeeper.log" 2>/dev/null)"
fi

# --- python compiles -----------------------------------------------------------------
mkdir -p "$T/pyc"
if "$PY" -I -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$GK" "$T/pyc/gk.pyc"; then pass "py_compile clean"; else fail "py_compile failed"; fi

# --- SIGTERM teardown (and the race: a request read AFTER SIGTERM must not spawn) -------
: > "$T/pids/sleeper"; : > "$T/pids/late"
( call sleeper '{}' > "$T/term.out" ) &
for i in $(seq 1 50); do [[ "$(grep -c . "$T/pids/sleeper")" -ge 2 ]] && break; sleep 0.1; done
# a second connection, accepted before SIGTERM, whose request arrives 1.5 s later
printf '%s\n' '{"v":1,"tool":"t","verb":"late","args":{}}' | rpc "$SOCK" --delay 1.5 > "$T/late.out" &
sleep 0.3
t0=$SECONDS
kill -TERM "$GK_PID"
for i in $(seq 1 100); do kill -0 "$GK_PID" 2>/dev/null || break; sleep 0.1; done
el=$((SECONDS - t0))
if kill -0 "$GK_PID" 2>/dev/null; then fail "gatekeeper still alive ${el}s after SIGTERM"; else pass "gatekeeper exited after SIGTERM (${el}s)"; fi
if any_alive "$T/pids/sleeper" || [[ $el -gt 8 ]]; then fail "SIGTERM: group alive or slow (elapsed=$el)"; else pass "SIGTERM: in-flight group killed within the 5 s grace"; fi
wait
lk="$(kind "$(cat "$T/late.out")")"
{ [[ "$lk" == unavailable ]] || grep -q NOREPLY "$T/late.out"; } && pass "request read after SIGTERM is refused (unavailable or closed): $lk" || fail "late request: $(cat "$T/late.out")"
[[ ! -s "$T/pids/late" ]] && pass "request read after SIGTERM ran nothing" || fail "late command started: $(cat "$T/pids/late")"
any_alive "$T/pids/late" && fail "late command survives the gatekeeper" || pass "no late command survives the gatekeeper"
if pgrep -s "$GK_PID" >/dev/null 2>&1; then fail "a process remains in the gatekeeper's session"; else pass "no process remains in the gatekeeper's session"; fi
[[ ! -e "$SOCK" && ! -e "$T/state/gatekeeper.pid" ]] && pass "SIGTERM leaves no socket and no pid file" || fail "socket/pid left behind"
calls_empty && pass "SIGTERM leaves nothing under calls/" || fail "calls/ not empty after SIGTERM"

# --- message hygiene over everything collected ---------------------------------
n="$(grep -c . "$T/errors.log")"
bad=0
[[ "$n" -gt 20 ]] || { fail "hygiene: only $n error replies collected"; bad=1; }
if jq -r '.error.message' "$T/errors.log" | grep -q '/'; then fail "hygiene: an error message contains /"; bad=1; fi
if grep -qE 'Traceback|Error|Exception' "$T/errors.log"; then fail "hygiene: Traceback/Error text in a reply"; bad=1; fi
while IFS= read -r v; do
  if [[ -n "$v" ]] && grep -qF -- "$v" "$T/errors.log"; then fail "hygiene: argument value '$v' appears in a reply"; bad=1; fi
done < "$T/values.log"
if grep -qF -- "$META" "$T/errors.log"; then fail "hygiene: metacharacter value in a reply"; bad=1; fi
[[ $bad -eq 0 ]] && pass "message hygiene over $n error replies: no /, no argument value, no Traceback/Error"

echo "failures: $FAILURES"
[[ "$FAILURES" -eq 0 ]]
