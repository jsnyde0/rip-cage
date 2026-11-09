#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2012,SC2016  # A&&B||C pass/fail idiom; ls names in diagnostics; planted bodies and literals are deliberately single-quoted
set -uo pipefail

# tests/test-host-tool-recipe.sh -- host-side proof for rip-cage-jdl2.5
# (ADR-032 D1/D4): the examples/host-tool recipe, end to end through the REAL
# pieces. Nothing here is a cage: the proof cannot run in-cage (the answer
# writer would be the agent approving itself).
#
#   R1  the README's install step, replayed: bin/ copied to a temp
#       XDG_DATA_HOME, the shipped declaration rendered with that path, loaded
#       through the real loader (cli/lib/host_tools.sh) against a mount list
#       holding the temp workspace (passes) and against one holding the
#       install dir (refused: the README's reason for installing outside every
#       mount).
#   R2  the REAL gatekeeper (cli/lib/host-tool-gatekeeper.py) started on that
#       rendered declaration, driven by the SHIPPED client
#       (cage/substrate/host-tool) with HOST_TOOL_SOCKET injecting AF_UNIX:
#       echo (text, --count, a URL, bounds), env (variable set equal to
#       {PATH, HOME, LANG}; HOME and cwd the same fresh per-call directory
#       under calls/).
#   R3  notify, the ask-then-run wrapper behind the gatekeeper, with the asker
#       a no-op and the answer file written by this test into the temp inbox:
#       allow, allow+newline (run); deny, extra content, trailing space, empty,
#       wrong case, no answer within the budget, missing asker, failing asker
#       (exit 3, nothing ran); nothing left in the inbox or the call dir.
#   R4  distinct request ids for identical calls; the request file is valid
#       JSON even for a quote and a backslash; asker stdout never reaches the
#       reply.
#   R5  decoy config: the wrapper run with HOME, XDG_CONFIG_HOME and
#       XDG_STATE_HOME on empty dirs and again on dirs holding decoys at every
#       path a naive wrapper might read behaves identically and touches no
#       decoy; its source derives no path from anything but argv.
#   R6  ask-nudge: never answers; stderr path when no notifier; the two
#       platform notifiers receive the request path.
#
# Fixtures are generic (asker stubs, an inbox under a temp dir); rc names no
# tool and this test names only the recipe's own scripts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RECIPE="${REPO_ROOT}/examples/host-tool"
GK="${REPO_ROOT}/cli/lib/host-tool-gatekeeper.py"
CLIENT="${REPO_ROOT}/cage/substrate/host-tool"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
[ -x /usr/bin/python3 ] || { echo "SKIP: /usr/bin/python3 (the client shebang) not present"; exit 0; }
PY="$(command -v python3 || true)"
[[ -n "$PY" ]] || { echo "SKIP: python3 not on PATH"; exit 0; }
PY="$(cd "$(dirname "$PY")" && pwd -P)/$(basename "$PY")"

T=$(mktemp -d /tmp/rc-ht-recipe-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
GK_PIDS=""
stop_all() {
  local p
  for p in $GK_PIDS; do kill -TERM "$p" 2>/dev/null; done
  sleep 0.3
  for p in $GK_PIDS; do kill -KILL "$p" 2>/dev/null; done
  GK_PIDS=""
}
cleanup() { stop_all; chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

for f in bin/echo-tool bin/env-tool bin/ask-then-run bin/ask-nudge example.tools.yaml README.md; do
  [[ -f "${RECIPE}/${f}" ]] && pass "recipe file present: examples/host-tool/${f}" || fail "recipe file present: examples/host-tool/${f}"
done

# --- R1: the README's install step, replayed ----------------------------------
mkdir -p "$T/ws" "$T/elsewhere" "$T/other-home" "$T/askers" "$T/askers/seen"
export XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/xstate" XDG_CONFIG_HOME="$T/cfg"
DEST="${XDG_DATA_HOME}/host-tool-examples"
STATE_ROOT="${XDG_STATE_HOME}/host-tool-examples"
INBOX="${STATE_ROOT}/inbox"
# Replay the README's step-1 block as written (nothing pre-created: the block
# makes its own directories), with <cage> set to "scratch". Twice: it must be
# safe to re-run.
DECL="${XDG_CONFIG_HOME}/rip-cage/projects/scratch.tools.yaml"
sed -n '/<!-- step1:begin/,/<!-- step1:end/p' "${RECIPE}/README.md" | sed -e '/^<!--/d' -e '/^```/d' -e 's/<cage>/scratch/g' > "$T/step1.sh"
if [[ -s "$T/step1.sh" ]]; then pass "R1 the README carries a step-1 block between markers"; else fail "R1 no step-1 block in the README"; fi
if ( cd "$REPO_ROOT" && bash "$T/step1.sh" ) > "$T/step1.out" 2>&1 && ( cd "$REPO_ROOT" && bash "$T/step1.sh" ) >> "$T/step1.out" 2>&1; then
  pass "R1 README step 1 runs as written on a bare config dir, twice"
else
  fail "R1 README step 1 failed: $(cat "$T/step1.out")"
fi
if [[ -x "$DEST/bin/ask-then-run" && -x "$DEST/bin/ask-nudge" && -x "$DEST/bin/echo-tool" && -x "$DEST/bin/env-tool" && -d "$INBOX" ]]; then
  pass "R1 step 1 installed the four scripts (executable) and the inbox"
else
  fail "R1 step 1 left the install incomplete"
fi
if grep -q 'ABSOLUTE' "$DECL"; then fail "R1 render left a placeholder behind"; else pass "R1 render fills both placeholders"; fi
printf '%s\n' "$T/ws" > "$T/mounts"
printf '%s\n' "$DEST" > "$T/mounts-install"
# shellcheck source=cli/lib/protected_paths.sh
source "${REPO_ROOT}/cli/lib/protected_paths.sh"
# shellcheck source=cli/lib/msb_runtime.sh
source "${REPO_ROOT}/cli/lib/msb_runtime.sh"
# shellcheck source=cli/lib/host_tools.sh
source "${REPO_ROOT}/cli/lib/host_tools.sh"
if _host_tools_load "$DECL" "$T/mounts" > "$T/shipped.json" 2> "$T/load.err"; then
  pass "R1 the real loader accepts the rendered declaration (mount list: the workspace)"
else
  fail "R1 the real loader refused the rendered declaration: $(cat "$T/load.err")"
fi
if _host_tools_load "$DECL" "$T/mounts-install" > /dev/null 2> "$T/refuse.err"; then
  fail "R1 the loader accepted a declaration whose commands sit inside a mount"
elif grep -q 'inside mount source' "$T/refuse.err"; then
  pass "R1 the loader refuses it when the install dir is a mount ($(head -c 160 "$T/refuse.err" | tr '\n' ' '))"
else
  fail "R1 refusal did not name the mount: $(cat "$T/refuse.err")"
fi
if [[ "$(wc -l < "$T/refuse.err" | tr -d ' ')" == 1 ]]; then pass "R1 the refusal is one Error: line"; else fail "R1 refusal is not one line"; fi

# --- gatekeeper helpers ------------------------------------------------------
# serve LABEL DECL: load through the real loader, start the real gatekeeper on
# it. Sets STATE and SOCK. The gatekeeper starts with canary secrets and a
# different HOME on purpose: the env verb must show none of them.
serve() {
  local lab="$1" decl="$2"
  STATE="$T/st-${lab}"; SOCK="$STATE/host-tool.sock"
  mkdir -p "$STATE"
  if ! _host_tools_load "$decl" "$T/mounts" > "$STATE/tools.json" 2> "$STATE/load.err"; then
    fail "serve ${lab}: loader refused: $(cat "$STATE/load.err")"; return 1
  fi
  ( cd "$T/elsewhere" && env -i CCTOK=canary GITHUB_TOKEN=canary MSB_X=canary XDG_CONFIG_HOME=/canary \
      HOME="$T/other-home" PATH="$PATH" LANG=de_DE.UTF-8 "$PY" -I "$GK" --socket "$SOCK" --decl "$STATE/tools.json" \
      --log "$STATE/gatekeeper.log" --pid "$STATE/gatekeeper.pid" --cwd "$STATE" >/dev/null 2>&1 & )
  for _ in $(seq 1 50); do
    if [[ -s "$STATE/gatekeeper.pid" && -S "$SOCK" ]]; then
      GK_PIDS="$GK_PIDS $(cat "$STATE/gatekeeper.pid")"; return 0
    fi
    sleep 0.1
  done
  fail "serve ${lab}: gatekeeper did not come up"; return 1
}
# call ARGS...: the shipped client over the injected AF_UNIX transport.
call() {
  HOST_TOOL_SOCKET="$SOCK" "$CLIENT" "$@" >"$T/out" 2>"$T/err"
  RC=$?
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
# variant NAME ASKER BUDGET: the rendered declaration with the asker and the
# budget swapped (the lines are asserted to have changed, so a variant cannot
# silently be the original).
variant() {
  local name="$1" asker="$2" budget="$3"
  sed -e "s|\"${DEST}/bin/ask-nudge\"|\"${asker}\"|" -e "s|\"--budget\", \"90\"|\"--budget\", \"${budget}\"|" "$DECL" > "$T/${name}.tools.yaml"
  grep -q "\"${asker}\"" "$T/${name}.tools.yaml" && grep -q "\"--budget\", \"${budget}\"" "$T/${name}.tools.yaml" \
    || fail "variant ${name}: the sed did not change the asker and budget lines"
}
clean_after() { # LABEL: inbox and call dir empty
  if [[ -z "$(ls -A "$INBOX")" && -z "$(ls -A "$STATE/calls")" ]]; then
    pass "$1: no file left in the inbox or the call dir"
  else
    fail "$1: left behind: inbox=[$(ls -A "$INBOX" | tr '\n' ' ')] calls=[$(ls -A "$STATE/calls" | tr '\n' ' ')]"
  fi
}

# --- R2: echo and env through the real gatekeeper and the shipped client ----
serve plain "$DECL" || { echo "FAILED: ${FAILURES}"; exit 1; }
call example echo --text hello
[[ $RC -eq 0 && "$OUT" == "hello" ]] && pass "R2 echo prints the text" || fail "R2 echo: rc=$RC out=[$OUT] err=[$ERR]"
call example echo --text hello --count 3
[[ $RC -eq 0 && "$OUT" == $'hello\nhello\nhello' ]] && pass "R2 echo --count 3 repeats three times" || fail "R2 echo --count 3: rc=$RC out=[$OUT]"
call example echo --text https://example.com/a/b?x=1 --count 2
[[ $RC -eq 0 && "$OUT" == $'https://example.com/a/b?x=1\nhttps://example.com/a/b?x=1' ]] && pass "R2 echo carries a URL (allow_slash)" || fail "R2 echo URL: rc=$RC out=[$OUT] err=[$ERR]"
call example echo --text 'a b;$(id)'
[[ $RC -eq 0 && "$OUT" == 'a b;$(id)' ]] && pass "R2 echo hands shell metacharacters through as one literal" || fail "R2 echo metachar: rc=$RC out=[$OUT]"
call example echo --text hi --count 6
[[ $RC -eq 2 && "$ERR" == *"bad-argument: slot count"* ]] && pass "R2 echo --count 6 is refused (exit 2, slot count)" || fail "R2 echo --count 6: rc=$RC err=[$ERR]"
call example echo --text hi --count 0
[[ $RC -eq 2 ]] && pass "R2 echo --count 0 is refused (exit 2)" || fail "R2 echo --count 0: rc=$RC"
call example echo --text -rf
[[ $RC -eq 2 && "$ERR" == *"slot text"* ]] && pass "R2 echo refuses a leading-dash text (allow_dash false)" || fail "R2 echo -rf: rc=$RC err=[$ERR]"

call example env
KEYS="$(printf '%s\n' "$OUT" | grep -E '^[A-Z_][A-Z0-9_]*=' | cut -d= -f1 | sort | tr '\n' ' ')"
ENV_HOME="$(printf '%s\n' "$OUT" | sed -n 's/^HOME=//p')"
ENV_CWD="$(printf '%s\n' "$OUT" | sed -n 's/^cwd=//p')"
[[ $RC -eq 0 && "$KEYS" == "HOME LANG PATH " ]] && pass "R2 env: variable set is exactly {HOME, LANG, PATH}" || fail "R2 env keys: rc=$RC keys=[$KEYS] out=[$OUT]"
[[ "$OUT" == *$'\nLANG=de_DE.UTF-8'* || "$OUT" == "LANG=de_DE.UTF-8"* ]] && pass "R2 env: LANG is the gatekeeper's launch value" || fail "R2 env LANG: out=[$OUT]"
[[ "$OUT" == *"PATH=/usr/bin:/bin"* ]] && pass "R2 env: PATH is the platform constant" || fail "R2 env PATH: out=[$OUT]"
if [[ -n "$ENV_CWD" && "$ENV_HOME" == "$ENV_CWD" && "$ENV_CWD" =~ ^${STATE}/calls/c[^/]+$ ]]; then
  pass "R2 env: HOME equals cwd, a per-call directory under the state dir's calls/"
else
  fail "R2 env: HOME=[$ENV_HOME] cwd=[$ENV_CWD] (want one dir under ${STATE}/calls/)"
fi
[[ ! -e "$ENV_CWD" ]] && pass "R2 env: the call directory is gone after the call" || fail "R2 env: ${ENV_CWD} outlived the call"
FIRST_CWD="$ENV_CWD"
call example env
ENV_CWD="$(printf '%s\n' "$OUT" | sed -n 's/^cwd=//p')"
[[ -n "$ENV_CWD" && "$ENV_CWD" != "$FIRST_CWD" ]] && pass "R2 env: a second call gets a different directory" || fail "R2 env: two calls shared a directory ($FIRST_CWD, $ENV_CWD)"
call --list
[[ $RC -eq 0 && "$OUT" == *"notify"* && "$OUT" == *"echo"* && "$OUT" == *"env"* && "$OUT" != *"/ask-"* ]] \
  && pass "R2 --list names the three verbs and no host path" || fail "R2 --list: rc=$RC out=[$OUT]"
stop_all

# --- R3: notify behind the wrapper ------------------------------------------
# noop asker: records the request it was handed, prints noise on stdout (which
# must never reach the reply), answers nothing. It is the stand-in for
# whatever nudges a human; THIS TEST is the human.
cat > "$T/askers/noop" <<EOS
#!/bin/sh
echo "\$1" >> "$T/asker.log"
cp "\$1" "$T/askers/seen/\$(basename "\$1")"
echo ASKER-STDOUT-NOISE
exit 0
EOS
printf '#!/bin/sh\nexit 1\n' > "$T/askers/fail"
chmod 755 "$T/askers/noop" "$T/askers/fail"

# ask_call BUDGET-VARIANT-IS-ALREADY-SERVED FORMAT [TEXT]: run notify in the
# background; when the request file appears in the inbox, write the answer
# (FORMAT, printf %b) atomically; FORMAT "-" writes none.
ask_call() {
  local fmt="$1" text="${2:-hi}" cpid id req
  HOST_TOOL_SOCKET="$SOCK" "$CLIENT" example notify --text "$text" >"$T/out" 2>"$T/err" &
  cpid=$!
  if [[ "$fmt" != "-" ]]; then
    req=""
    for _ in $(seq 1 100); do
      req="$(ls "$INBOX"/*.json 2>/dev/null | head -1)"
      [[ -n "$req" ]] && break
      kill -0 "$cpid" 2>/dev/null || break   # the call ended without ever asking
      sleep 0.1
    done
    if [[ -n "$req" ]]; then
      id="$(basename "$req" .json)"
      printf '%b' "$fmt" > "$T/answer.tmp"
      mv "$T/answer.tmp" "$INBOX/${id}.answer"
    fi
  fi
  wait "$cpid"; RC=$?
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}

variant v-noop "$T/askers/noop" 90
serve noop "$T/v-noop.tools.yaml" || { echo "FAILED: ${FAILURES}"; exit 1; }
want_run() { # LABEL FORMAT
  : > "$T/asker.log"
  ask_call "$2"
  if [[ $RC -eq 0 && "$OUT" == "hi" ]]; then pass "R3 $1 -> the command ran (reply is its stdout alone)"; else fail "R3 $1: rc=$RC out=[$OUT] err=[$ERR]"; fi
  clean_after "R3 $1"
}
want_deny() { # LABEL FORMAT
  ask_call "$2"
  if [[ $RC -eq 3 && "$OUT" == "" && "$ERR" == *"tool-failed"* ]]; then pass "R3 $1 -> denied (exit 3, tool-failed, nothing printed)"; else fail "R3 $1: rc=$RC out=[$OUT] err=[$ERR]"; fi
  clean_after "R3 $1"
}
want_run "answer allow" 'allow'
want_run "answer allow + one newline" 'allow\n'
want_deny "answer deny" 'deny\n'
want_deny "answer allow + extra content" 'allow\nextra'
want_deny "answer allow + two newlines" 'allow\n\n'
want_deny "answer allow + trailing space" 'allow '
want_deny "answer allow + NUL" 'allow\0'
want_deny "answer empty" ''
want_deny "answer ALLOW (case)" 'ALLOW\n'
stop_all

variant v-short "$T/askers/noop" 2
serve short "$T/v-short.tools.yaml" || { echo "FAILED: ${FAILURES}"; exit 1; }
T0=$(date +%s)
ask_call "-"
T1=$(date +%s)
if [[ $RC -eq 3 && "$OUT" == "" && "$ERR" == *"tool-failed"* ]] && [[ $((T1 - T0)) -ge 1 ]]; then
  pass "R3 no answer within the budget -> denied after waiting (exit 3, $((T1 - T0)) s)"
else
  fail "R3 no answer: rc=$RC out=[$OUT] err=[$ERR] waited=$((T1 - T0))s"
fi
clean_after "R3 no answer"
stop_all

variant v-missing "$T/askers/does-not-exist" 30
serve missing "$T/v-missing.tools.yaml" || { echo "FAILED: ${FAILURES}"; exit 1; }
T0=$(date +%s)
ask_call 'allow\n'
T1=$(date +%s)
if [[ $RC -eq 3 && "$OUT" == "" ]] && [[ $((T1 - T0)) -lt 10 ]]; then
  pass "R3 missing asker -> denied at once, not after the budget (exit 3, $((T1 - T0)) s of a 30 s budget)"
else
  fail "R3 missing asker: rc=$RC out=[$OUT] err=[$ERR] took=$((T1 - T0))s"
fi
clean_after "R3 missing asker"
stop_all

variant v-failing "$T/askers/fail" 30
serve failing "$T/v-failing.tools.yaml" || { echo "FAILED: ${FAILURES}"; exit 1; }
T0=$(date +%s)
ask_call 'allow\n'
T1=$(date +%s)
if [[ $RC -eq 3 && "$OUT" == "" ]] && [[ $((T1 - T0)) -lt 10 ]]; then
  pass "R3 failing asker -> denied at once (exit 3, $((T1 - T0)) s of a 30 s budget)"
else
  fail "R3 failing asker: rc=$RC out=[$OUT] err=[$ERR] took=$((T1 - T0))s"
fi
clean_after "R3 failing asker"
stop_all

# --- R4: distinct ids, valid JSON requests ----------------------------------
variant v-ids "$T/askers/noop" 1
serve ids "$T/v-ids.tools.yaml" || { echo "FAILED: ${FAILURES}"; exit 1; }
: > "$T/asker.log"; rm -f "$T/askers/seen"/*
ask_call "-" 'say "hi" \o'
ask_call "-" 'say "hi" \o'
N="$(wc -l < "$T/asker.log" | tr -d ' ')"
IDS="$(sed 's|.*/||; s|\.json$||' "$T/asker.log" | sort -u | wc -l | tr -d ' ')"
if [[ "$N" == 2 && "$IDS" == 2 ]]; then pass "R4 two calls with identical arguments produce different request ids"; else fail "R4 ids: $N requests, $IDS distinct"; fi
BAD=0
while IFS= read -r line; do
  case "$line" in "$INBOX"/*.json) : ;; *) BAD=1 ;; esac
  [[ "$(basename "$line")" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$ ]] || BAD=1
done < "$T/asker.log"
[[ $BAD -eq 0 ]] && pass "R4 each request file is <inbox>/<uuid>.json" || fail "R4 request file names: $(cat "$T/asker.log")"
GOODJSON=1
for f in "$T/askers/seen"/*.json; do
  jq -e --arg t 'say "hi" \o' '(.id | type == "string") and (.argv | index($t) != null)' "$f" >/dev/null 2>&1 || GOODJSON=0
done
[[ $GOODJSON -eq 1 ]] && pass "R4 the request is valid JSON carrying id and argv, a quote and a backslash intact" || fail "R4 request JSON: $(cat "$T/askers/seen"/* 2>/dev/null | head -3)"
stop_all

# --- R3b: a blocking asker is bounded by the budget ------------------------
# The asker sleeps 3 s, then writes allow and a marker. With --budget 1 the
# call is refused in about 1 s, and the asker is killed before it can answer.
cat > "$T/askers/block" <<EOS
#!/bin/sh
sleep 3
printf 'allow\n' > "\$(dirname "\$1")/\$(basename "\$1" .json).answer"
touch "$T/block.marker"
EOS
chmod 755 "$T/askers/block"
variant v-block "$T/askers/block" 1
serve block "$T/v-block.tools.yaml" || { echo "FAILED: ${FAILURES}"; exit 1; }
T0=$(date +%s)
ask_call "-"
T1=$(date +%s)
if [[ $RC -eq 3 && "$OUT" == "" && $((T1 - T0)) -le 2 ]]; then
  pass "R3b blocking asker + budget 1 -> denied in $((T1 - T0)) s (exit 3), not after the asker's 3 s"
else
  fail "R3b blocking asker: rc=$RC out=[$OUT] took=$((T1 - T0))s"
fi
sleep 3.5
if [[ ! -e "$T/block.marker" && -z "$(ls -A "$INBOX")" ]]; then
  pass "R3b the blocked asker was killed: no marker, no late answer in the inbox"
else
  fail "R3b the asker outlived the deadline (inbox=[$(ls -A "$INBOX")])"
fi
stop_all

# --- R3d: an asker that ignores TERM is KILLed after the grace --------------
cat > "$T/askers/ignore" <<EOS
#!/bin/sh
trap '' TERM
echo \$\$ > "$T/ignore.pid"
while :; do sleep 1; done
EOS
chmod 755 "$T/askers/ignore"
variant v-ignore "$T/askers/ignore" 1
serve ignore "$T/v-ignore.tools.yaml" || { echo "FAILED: ${FAILURES}"; exit 1; }
T0=$(date +%s)
ask_call "-"
T1=$(date +%s)
IGN="$(cat "$T/ignore.pid" 2>/dev/null)"
if [[ $RC -eq 3 && "$OUT" == "" && $((T1 - T0)) -le 3 ]]; then
  pass "R3d TERM-ignoring asker + budget 1 -> denied in $((T1 - T0)) s (budget plus the 1 s grace)"
else
  fail "R3d TERM-ignoring asker: rc=$RC out=[$OUT] took=$((T1 - T0))s"
fi
if [[ -n "$IGN" ]] && ! kill -0 "$IGN" 2>/dev/null; then
  pass "R3d the TERM-ignoring asker (pid $IGN) is gone: KILLed by the wrapper"
else
  fail "R3d the asker (pid '$IGN') is still alive"
  [[ -n "$IGN" ]] && kill -KILL "$IGN" 2>/dev/null
fi
clean_after "R3d TERM-ignoring asker"
stop_all
# Direct, with no gatekeeper group kill behind it: the wrapper alone must end
# the asker (TERM, 1 s grace, KILL).
rm -f "$T/ignore.pid"
T0=$(date +%s)
( cd "$T/elsewhere" && env -i PATH=/usr/bin:/bin "$DEST/bin/ask-then-run" --asker "$T/askers/ignore" --inbox "$INBOX" --budget 1 -- "$DEST/bin/echo-tool" hi 1 ) >"$T/d.out" 2>"$T/d.err"
DRC=$?
T1=$(date +%s)
IGN="$(cat "$T/ignore.pid" 2>/dev/null)"
if [[ $DRC -eq 2 && $((T1 - T0)) -le 3 ]]; then
  pass "R3d direct: wrapper exits 2 in $((T1 - T0)) s with a TERM-ignoring asker"
else
  fail "R3d direct: rc=$DRC took=$((T1 - T0))s err=[$(cat "$T/d.err")]"
fi
if [[ -n "$IGN" ]] && ! kill -0 "$IGN" 2>/dev/null && [[ -z "$(ls -A "$INBOX")" ]]; then
  pass "R3d direct: the asker (pid $IGN) is gone and the inbox is empty"
else
  fail "R3d direct: asker pid '$IGN' alive or inbox not empty [$(ls -A "$INBOX")]"
  [[ -n "$IGN" ]] && kill -KILL "$IGN" 2>/dev/null
fi

# --- R3c: --budget parsing --------------------------------------------------
for b in 090 0 00 -5 1.5 abc 1234567 12345678901234567890 ""; do
  ( cd "$T/elsewhere" && env -i PATH=/usr/bin:/bin "$DEST/bin/ask-then-run" --asker "$T/askers/noop" --inbox "$INBOX" --budget "$b" -- "$DEST/bin/echo-tool" hi 1 ) >"$T/b.out" 2>"$T/b.err"
  brc=$?
  if [[ $brc -eq 2 && -z "$(cat "$T/b.out")" && "$(cat "$T/b.err")" == *"--budget must be whole seconds"* && -z "$(ls -A "$INBOX")" ]]; then
    pass "R3c budget [$b] -> exit 2 with the budget message, nothing written"
  else
    fail "R3c budget [$b]: rc=$brc err=[$(cat "$T/b.err")]"
  fi
done

# --- R5: decoy config is never consulted -----------------------------------
# The wrapper runs directly (the gatekeeper's own environment is fixed; here
# the point is the wrapper's inputs). Run A: HOME, XDG_CONFIG_HOME,
# XDG_STATE_HOME and the cwd are empty dirs. Run B: the same variables point
# at dirs holding decoys at every path a naive wrapper might read, written to
# change the outcome if read (an auto-allow, another asker, a zero budget, a
# standing answer). The two must behave identically.
WRAP="${DEST}/bin/ask-then-run"
mk_world() { # DIR [decoys]
  local w="$1"
  mkdir -p "$w/home/.config/host-tool-examples" "$w/xcfg/host-tool-examples" "$w/xstate/host-tool-examples/inbox" "$w/cwd" "$w/inbox"
  if [[ "${2:-}" == decoys ]]; then
    local d
    for d in "$w/home/.config/host-tool-examples/config" "$w/home/.config/ask-then-run" "$w/home/.config/ask-then-run.conf" \
             "$w/xcfg/host-tool-examples/config" "$w/xcfg/ask-then-run.conf" "$w/xcfg/host-tool-examples/asker" \
             "$w/xstate/host-tool-examples/ask-then-run.conf" "$w/cwd/ask-then-run.conf" "$w/cwd/.ask-then-run" \
             "$w/home/.ask-then-run" "$w/home/ask-then-run.conf"; do
      printf 'asker=%s\nbudget=0\nauto=allow\n' "$T/askers/fail" > "$d"
    done
    printf 'allow\n' > "$w/xstate/host-tool-examples/inbox/standing.answer"
    printf 'allow\n' > "$w/cwd/standing.answer"
  fi
}
run_world() { # DIR FORMAT: runs the wrapper, answer per FORMAT ("-" none); sets WRC, WOUT
  local w="$1" fmt="$2" cpid req id
  ( cd "$w/cwd" && env -i HOME="$w/home" XDG_CONFIG_HOME="$w/xcfg" XDG_STATE_HOME="$w/xstate" PATH=/usr/bin:/bin \
      "$WRAP" --asker "$T/askers/noop" --inbox "$w/inbox" --budget 2 -- "$DEST/bin/echo-tool" hi 1 >"$w/out" 2>"$w/err"; echo $? > "$w/rc" ) &
  cpid=$!
  if [[ "$fmt" != "-" ]]; then
    for _ in $(seq 1 100); do
      req="$(ls "$w/inbox"/*.json 2>/dev/null | head -1)"
      [[ -n "$req" ]] && break
      kill -0 "$cpid" 2>/dev/null || break
      sleep 0.1
    done
    if [[ -n "$req" ]]; then
      id="$(basename "$req" .json)"
      printf '%b' "$fmt" > "$w/answer.tmp"; mv "$w/answer.tmp" "$w/inbox/${id}.answer"
    fi
  fi
  wait "$cpid"
  WRC="$(cat "$w/rc")"; WOUT="$(cat "$w/out")"
}
mk_world "$T/wA"; mk_world "$T/wB" decoys
decoy_sums() { ( cd "$T/wB" && find home xcfg xstate cwd -type f -print0 | sort -z | xargs -0 cksum ); }
decoy_sums > "$T/decoys.before"
run_world "$T/wA" -;        A1="$WRC|$WOUT"
run_world "$T/wB" -;        B1="$WRC|$WOUT"
[[ "$A1" == "$B1" && "$A1" == "2|"* ]] && pass "R5 no answer: identical on empty dirs and on decoys (exit 2, nothing printed)" || fail "R5 no answer: empty=[$A1] decoy=[$B1]"
run_world "$T/wA" 'allow\n'; A2="$WRC|$WOUT"
run_world "$T/wB" 'allow\n'; B2="$WRC|$WOUT"
[[ "$A2" == "$B2" && "$A2" == "0|hi" ]] && pass "R5 allow: identical on empty dirs and on decoys (exit 0, hi)" || fail "R5 allow: empty=[$A2] decoy=[$B2]"
run_world "$T/wA" 'deny\n';  A3="$WRC|$WOUT"
run_world "$T/wB" 'deny\n';  B3="$WRC|$WOUT"
[[ "$A3" == "$B3" && "$A3" == "2|"* ]] && pass "R5 deny: identical on empty dirs and on decoys" || fail "R5 deny: empty=[$A3] decoy=[$B3]"
decoy_sums > "$T/decoys.after"
if diff "$T/decoys.before" "$T/decoys.after" >/dev/null; then
  pass "R5 every decoy file is byte-identical after the runs, and no file was added beside them"
else
  fail "R5 a decoy changed or a file appeared: $(diff "$T/decoys.before" "$T/decoys.after" | head -4)"
fi
if [[ -z "$(ls -A "$T/wA/cwd")$(ls -A "$T/wA/inbox")$(ls -A "$T/wB/inbox")" ]]; then
  pass "R5 the wrapper left nothing in its cwd or its inbox"
else
  fail "R5 leftovers: cwd=[$(ls -A "$T/wA/cwd" | tr '\n' ' ')] inboxes=[$(ls -A "$T/wA/inbox")$(ls -A "$T/wB/inbox")]"
fi
# Static: the wrapper's only path inputs are argv. Comment lines are skipped.
STATIC_RE='HOME|XDG_|~|\.config|/etc/|\.conf|\$0|BASH_SOURCE|dirname|^[[:space:]]*(\.|source)[[:space:]]'
ABS_RE='(^|[^A-Za-z0-9_.}$"\\-])/[A-Za-z][A-Za-z0-9_./-]*'
abs_hits() { grep -oE "$ABS_RE" | grep -vE '^[^/]*/dev/null$' || true; }
# positive controls: a naive wrapper would trip both
NAIVE='cfg="$HOME/.config/ask/c"; . /etc/ask.conf; d=$(dirname "$0"); x=/var/lib/ask'
if printf '%s\n' "$NAIVE" | grep -qE "$STATIC_RE" && [[ -n "$(printf '%s\n' "$NAIVE" | abs_hits)" ]]; then
  pass "R5 control: both static checks fire on a naive wrapper's lines"
else
  fail "R5 control: a static check is blind to a naive wrapper"
fi
CODE="$(grep -v '^[[:space:]]*#' "$WRAP")"
if printf '%s\n' "$CODE" | grep -nE "$STATIC_RE" > "$T/static.hits"; then
  fail "R5 the wrapper source reads a path not derived from argv: $(head -3 "$T/static.hits")"
else
  pass "R5 the wrapper source names no HOME, XDG_*, ~, .config, /etc, .conf, \$0 or sourced file"
fi
ABS="$(printf '%s\n' "$CODE" | abs_hits)"
if [[ -z "$ABS" ]]; then pass "R5 the wrapper source holds no absolute path but /dev/null"; else fail "R5 absolute path literal in the wrapper: $(printf '%s' "$ABS" | head -3)"; fi

# --- R6: ask-nudge ----------------------------------------------------------
NUDGE="${DEST}/bin/ask-nudge"
mk_stubs() { # DIR UNAME
  rm -rf "$1"; mkdir -p "$1"
  printf '#!/bin/sh\necho %s\n' "$2" > "$1/uname"
  ln -s "$(command -v id)" "$1/id"
  chmod 755 "$1/uname"
}
REQ="$INBOX/00000000-0000-4000-8000-000000000000.json"
mk_stubs "$T/stubs-none" Linux
PATH="$T/stubs-none" "$NUDGE" "$REQ" >"$T/n.out" 2>"$T/n.err"; NRC=$?
if [[ $NRC -eq 0 && "$(cat "$T/n.err")" == *"$REQ"* && ! -e "${REQ%.json}.answer" ]]; then
  pass "R6 no notifier: exits 0, request path on stderr, no answer written"
else
  fail "R6 no notifier: rc=$NRC err=[$(cat "$T/n.err")]"
fi
mk_stubs "$T/stubs-linux" Linux
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/notify.args"\nprintf "%%s\\n" "${DBUS_SESSION_BUS_ADDRESS:-unset}" > "%s/notify.dbus"\n' "$T" "$T" > "$T/stubs-linux/notify-send"
chmod 755 "$T/stubs-linux/notify-send"
PATH="$T/stubs-linux" "$NUDGE" "$REQ" >"$T/n.out" 2>"$T/n.err"; NRC=$?
WANT_DBUS="unset"; [[ -S "/run/user/$(id -u)/bus" ]] && WANT_DBUS="unix:path=/run/user/$(id -u)/bus"
if [[ $NRC -eq 0 && "$(cat "$T/notify.args")" == *"$REQ"* && ! -e "${REQ%.json}.answer" ]]; then
  pass "R6 Linux: notify-send receives the request path; no answer written"
else
  fail "R6 Linux: rc=$NRC args=[$(cat "$T/notify.args" 2>/dev/null)]"
fi
[[ "$(cat "$T/notify.dbus")" == "$WANT_DBUS" ]] && pass "R6 Linux: DBUS_SESSION_BUS_ADDRESS is set from /run/user/<uid>/bus exactly when that socket exists ($WANT_DBUS)" || fail "R6 Linux dbus: [$(cat "$T/notify.dbus")] want [$WANT_DBUS]"
printf '#!/bin/sh\nexit 1\n' > "$T/stubs-linux/notify-send"
PATH="$T/stubs-linux" "$NUDGE" "$REQ" >"$T/n.out" 2>"$T/n.err"; NRC=$?
[[ $NRC -eq 0 && "$(cat "$T/n.err")" == *"$REQ"* ]] && pass "R6 Linux: a failing notify-send falls back to the stderr path, exit 0" || fail "R6 failing notifier: rc=$NRC err=[$(cat "$T/n.err")]"
mk_stubs "$T/stubs-mac" Darwin
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/osa.args"\n' "$T" > "$T/stubs-mac/osascript"
chmod 755 "$T/stubs-mac/osascript"
PATH="$T/stubs-mac" "$NUDGE" "$REQ" >"$T/n.out" 2>"$T/n.err"; NRC=$?
if [[ $NRC -eq 0 && "$(cat "$T/osa.args")" == *"display notification"* && "$(cat "$T/osa.args")" == *"$REQ"* ]]; then
  pass "R6 macOS: osascript display notification receives the request path"
else
  fail "R6 macOS: rc=$NRC args=[$(cat "$T/osa.args" 2>/dev/null)]"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED: ${FAILURES}"
exit 1
