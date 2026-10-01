#!/usr/bin/env bash
# Host-tier test of init's daemon block restart policy (rip-cage-vpxk).
#
# The boot descriptor's daemons[] entries take an optional `restart` field:
# `always` or `never` (the default, today's behaviour). Under `always`, init
# launches the daemon from a small supervising subshell that re-runs `start`
# after each exit, with a fixed backoff and a WARNING line naming the exit
# code. The loop is armed only after the first start passes its health check,
# so a misconfigured daemon never spins.
#
# _rc_start_daemons lives above init-rip-cage.sh's RC_INIT_LIB_ONLY guard, so
# this test sources only the function definitions and drives the real block
# against a fake descriptor, with pidfiles and logs under RC_DAEMON_RUN_DIR.
#
# Coverage:
#   D1  restart: always respawns a daemon that exits after 1s: >= 2 starts
#       within 15s, and a WARNING line naming the daemon and exit code
#   D2  no restart key: exactly 1 start (today's behaviour)
#   D3  restart: never: exactly 1 start
#   D4  restart: always whose FIRST health check fails: exactly 1 start (the
#       loop is armed only after a healthy first start)
#   D5  the block returns promptly and holds no pipe open (the supervisor
#       never keeps init's output stream alive)
#   D9  a second init run in the same boot replaces the supervisor instead of
#       leaving two respawning the same daemon
#   D6  stopping the supervisor (its pidfile) stops the respawns
#   D7  an unknown restart value fails the boot loud, naming the field
#   D10 a supervisor that exits on its own (disarmed) removes its own pidfile,
#       so a later init run cannot TERM a reused pid
#   D8  rc-boot-merge carries the restart field through untouched
#   T1-T4 optional health_timeout (rip-cage-tun0): bounded vs default, invalid
#       values fail loud, merge carries it

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SCRIPT="${SCRIPT_DIR}/../cage/init/init-rip-cage.sh"
BOOT_MERGE="${SCRIPT_DIR}/../cage/boot/rc-boot-merge"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

echo "=== daemon restart policy (rip-cage-vpxk) ==="

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi

W=$(mktemp -d "${TMPDIR:-/tmp}/rc-vpxk.XXXXXX")
RUN="${W}/run"
mkdir -p "$RUN" "${W}/bin"

cleanup() {
  local _f
  for _f in "$RUN"/*.supervisor.pid "$RUN"/*.pid; do
    [ -f "$_f" ] && kill "$(cat "$_f")" 2>/dev/null
  done
  rm -rf "$W"
}
trap cleanup EXIT

# macOS hosts have no coreutils timeout; init's health loop calls it.
if ! command -v timeout >/dev/null 2>&1; then
  printf '#!/bin/sh\nshift\nexec "$@"\n' > "${W}/bin/timeout"
  chmod +x "${W}/bin/timeout"
fi

# A fake daemon: records one line per start, lives $2 seconds (default 1), exits 3.
cat > "${W}/bin/fake-daemon" <<'EOF'
#!/bin/sh
echo start >> "$1"
sleep "${2:-1}"
exit 3
EOF
chmod +x "${W}/bin/fake-daemon"

# Five daemons in one descriptor so their clocks run in parallel.
# health checks the count file: once written, the daemon counts as healthy.
jq -n --arg d "${W}/bin/fake-daemon" --arg w "$W" '{
  daemons: [
    { name: "always",  restart: "always", start: "exec \($d) \($w)/always.count",  health: "test -f \($w)/always.count" },
    { name: "default",                    start: "exec \($d) \($w)/default.count", health: "test -f \($w)/default.count" },
    { name: "never",   restart: "never",  start: "exec \($d) \($w)/never.count",   health: "test -f \($w)/never.count" },
    { name: "unhealthy", restart: "always", start: "exec \($d) \($w)/unhealthy.count", health: "false" },
    { name: "long",    restart: "always", start: "exec \($d) \($w)/long.count 60", health: "test -f \($w)/long.count" }
  ]
}' > "${W}/boot.json"

count() { if [ -f "${W}/$1.count" ]; then wc -l < "${W}/$1.count" | tr -d ' '; else echo 0; fi; }

# Run the block in its own bash, piped through cat: if a supervisor held the
# pipe open, cat would never see EOF. perl's alarm bounds the whole pipeline,
# killing its process group (no timeout binary on macOS hosts).
# shellcheck disable=SC2016 # the perl program and inner script are single-quoted on purpose
perl -e '$t = shift; $p = fork; if (!$p) { setpgrp(0, 0); exec @ARGV; exit 127 }
         $SIG{ALRM} = sub { kill "KILL", -$p; exit 142 }; alarm $t;
         waitpid($p, 0); exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' \
  25 bash -c '
  set -euo pipefail
  export PATH="$1/bin:$PATH" RC_DAEMON_RUN_DIR="$2"
  RC_INIT_LIB_ONLY=1 source "$3"
  _rc_boot_descriptor="$4"
  _rc_start_daemons "$4" 2>&1 | cat > "$1/init.log"
' _ "$W" "$RUN" "$INIT_SCRIPT" "${W}/boot.json"
block_rc=$?
block_end=$(date +%s)

if [ "$block_rc" -eq 0 ]; then
  pass "D5 the daemon block returned 0 and released its output pipe"
else
  fail "D5 the daemon block returned 0 and released its output pipe" "rc=${block_rc} (142 = alarm: something held the pipe); log: $(tail -5 "${W}/init.log")"
fi

# Wait up to 15s from the block's return for a second start of 'always'.
while [ "$(count always)" -lt 2 ] && [ $(( $(date +%s) - block_end )) -lt 15 ]; do
  sleep 1
done
if [ "$(count always)" -ge 2 ]; then
  pass "D1 restart: always respawned the daemon ($(count always) starts)"
else
  fail "D1 restart: always respawned the daemon" "starts=$(count always); init log: $(tail -5 "${W}/init.log")"
fi
if grep -q "WARNING: daemon 'always' exited (code 3); restarting (restart: always)" "${RUN}/rip-cage-daemon-always.log" 2>/dev/null; then
  pass "D1 the respawn logged a WARNING naming the daemon and its exit code"
else
  fail "D1 the respawn logged a WARNING naming the daemon and its exit code" "log: $(cat "${RUN}/rip-cage-daemon-always.log" 2>/dev/null)"
fi

# D9: re-run the block for 'long' alone (it lives 60s, so it is serving) while
# its first supervisor lives.
rerun() {
  # shellcheck disable=SC2016
  bash -c '
    export PATH="$1/bin:$PATH" RC_DAEMON_RUN_DIR="$2"
    RC_INIT_LIB_ONLY=1 source "$3"
    _rc_boot_descriptor="$4"
    _rc_start_daemons "$4"
  ' _ "$W" "$RUN" "$INIT_SCRIPT" "$1" >"${W}/init2.log" 2>&1
}
sup() { cat "${RUN}/rip-cage-daemon-long.supervisor.pid" 2>/dev/null || echo ""; }
# D9a: health passes, so init skips and the supervisor stays.
old_sup=$(sup)
jq '{daemons: [.daemons[4]]}' "${W}/boot.json" > "${W}/long-only.json"
rerun "${W}/long-only.json"
if [ -n "$old_sup" ] && [ "$(sup)" = "$old_sup" ] && kill -0 "$old_sup" 2>/dev/null; then
  pass "D9 a second init with the daemon healthy kept the supervisor (${old_sup})"
else
  fail "D9 a second init with the daemon healthy kept the supervisor" "old=${old_sup:-none} now=$(sup); init: $(tail -3 "${W}/init2.log")"
fi
# D9b: health fails, so init restarts: the old supervisor must go, not double up.
jq '.daemons[0].health = "false"' "${W}/long-only.json" > "${W}/long-sick.json"
rerun "${W}/long-sick.json"
new_sup=$(sup)
if [ -n "$new_sup" ] && [ "$new_sup" != "$old_sup" ] && ! kill -0 "$old_sup" 2>/dev/null; then
  pass "D9 a second init with the daemon unhealthy replaced the supervisor (${old_sup} -> ${new_sup})"
else
  fail "D9 a second init with the daemon unhealthy replaced the supervisor" "old=${old_sup:-none} new=${new_sup:-none}; init: $(tail -3 "${W}/init2.log")"
fi
# Give the non-restarting daemons more than one backoff window to misbehave.
sleep 7
[ "$(count default)" -eq 1 ] && pass "D2 no restart key: exactly 1 start" \
  || fail "D2 no restart key: exactly 1 start" "starts=$(count default)"
[ "$(count never)" -eq 1 ] && pass "D3 restart: never: exactly 1 start" \
  || fail "D3 restart: never: exactly 1 start" "starts=$(count never)"
[ "$(count unhealthy)" -eq 1 ] && pass "D4 restart: always with a failed first health check: exactly 1 start" \
  || fail "D4 restart: always with a failed first health check: exactly 1 start" "starts=$(count unhealthy)"

# D10: 'unhealthy' was disarmed; its supervisor exited and took its pidfile.
if [ ! -f "${RUN}/rip-cage-daemon-unhealthy.supervisor.pid" ]; then
  pass "D10 a disarmed supervisor removed its own pidfile"
else
  fail "D10 a disarmed supervisor removed its own pidfile" "still there: $(cat "${RUN}/rip-cage-daemon-unhealthy.supervisor.pid")"
fi

# D6: stop the supervisor; the respawns stop.
sup_pid=$(cat "${RUN}/rip-cage-daemon-always.supervisor.pid" 2>/dev/null || echo "")
if [ -n "$sup_pid" ] && kill "$sup_pid" 2>/dev/null; then
  sleep 1
  stopped_at=$(count always)
  sleep 7
  if [ "$(count always)" -eq "$stopped_at" ] && ! kill -0 "$sup_pid" 2>/dev/null; then
    pass "D6 killing the supervisor stopped the respawns (held at ${stopped_at} starts)"
  else
    fail "D6 killing the supervisor stopped the respawns" "starts ${stopped_at} -> $(count always)"
  fi
else
  fail "D6 killing the supervisor stopped the respawns" "no live supervisor pidfile at ${RUN}/rip-cage-daemon-always.supervisor.pid"
fi

# D7: an unknown value is a composition error.
jq -n '{daemons: [{name: "typo", restart: "sometimes", start: "true", health: "true"}]}' > "${W}/bad.json"
# shellcheck disable=SC2016
# Under set -u, with no global _rc_boot_descriptor: the message must name $1.
bad_out=$(bash -c '
  set -u
  export PATH="$1/bin:$PATH" RC_DAEMON_RUN_DIR="$2"
  RC_INIT_LIB_ONLY=1 source "$3"
  _rc_start_daemons "$4"
' _ "$W" "$RUN" "$INIT_SCRIPT" "${W}/bad.json" 2>&1); bad_rc=$?
if [ "$bad_rc" -ne 0 ] && grep -qF "${W}/bad.json: daemons[0] field 'restart'" <<<"$bad_out"; then
  pass "D7 an unknown restart value fails the boot naming daemons[0] and the field"
else
  fail "D7 an unknown restart value fails the boot naming daemons[0] and the field" "rc=${bad_rc} out=${bad_out}"
fi

# D8: rc-boot-merge passes the field through.
printf '{"daemons":[],"multiplexers":[],"tools":[]}\n' > "${W}/base.json"
if RC_BOOT_DESCRIPTOR="${W}/base.json" sh "$BOOT_MERGE" "${W}/boot.json" >/dev/null 2>&1 \
   && jq -e '.daemons[0].restart == "always" and .daemons[2].restart == "never" and (.daemons[1] | has("restart") | not)' "${W}/base.json" >/dev/null; then
  pass "D8 rc-boot-merge carries restart through untouched"
else
  fail "D8 rc-boot-merge carries restart through untouched" "$(jq -c '.daemons' "${W}/base.json" 2>/dev/null)"
fi

# T1/T2 (rip-cage-tun0): optional health_timeout bounds the health phase. One
# init run, two daemons whose hook turns healthy ~8s after start (past the
# default 3-attempt loop, which gives up at ~3s on a fast-failing hook).
# 'bounded' declares health_timeout: 20 and must pass; 'unbounded' declares
# nothing and must WARN. Clock: ~8s + ~3s.
cat > "${W}/bin/slow-start" <<'EOF'
#!/bin/sh
sleep 8
touch "$1"
exec sleep 60
EOF
chmod +x "${W}/bin/slow-start"
jq -n --arg s "${W}/bin/slow-start" --arg w "$W" '{
  daemons: [
    { name: "bounded",   health_timeout: 20, start: "exec \($s) \($w)/bounded.ready",   health: "test -f \($w)/bounded.ready" },
    { name: "unbounded",                     start: "exec \($s) \($w)/unbounded.ready", health: "test -f \($w)/unbounded.ready" }
  ]
}' > "${W}/slow.json"
# shellcheck disable=SC2016
slow_out=$(bash -c '
  export PATH="$1/bin:$PATH" RC_DAEMON_RUN_DIR="$2"
  RC_INIT_LIB_ONLY=1 source "$3"
  _rc_start_daemons "$4"
' _ "$W" "$RUN" "$INIT_SCRIPT" "${W}/slow.json" 2>&1)
if grep -q "daemon 'bounded' health OK" <<<"$slow_out"; then
  pass "T1 a slow-healthy daemon with health_timeout: 20 passes health"
else
  fail "T1 a slow-healthy daemon with health_timeout: 20 passes health" "$slow_out"
fi
if grep -q "WARNING: daemon 'unbounded' health check FAILED" <<<"$slow_out"; then
  pass "T2 the same daemon with no health_timeout still WARNs (default envelope unchanged)"
else
  fail "T2 the same daemon with no health_timeout still WARNs (default envelope unchanged)" "$slow_out"
fi

# T3: an invalid health_timeout fails the boot loud, naming the field.
for _bad in '"soon"' 0 -5 1.5; do
  jq -n --argjson v "$_bad" '{daemons: [{name: "t", health_timeout: $v, start: "true", health: "true"}]}' > "${W}/badt.json"
  # shellcheck disable=SC2016
  t3_out=$(bash -c '
    set -u
    export PATH="$1/bin:$PATH" RC_DAEMON_RUN_DIR="$2"
    RC_INIT_LIB_ONLY=1 source "$3"
    _rc_start_daemons "$4"
  ' _ "$W" "$RUN" "$INIT_SCRIPT" "${W}/badt.json" 2>&1); t3_rc=$?
  if [ "$t3_rc" -ne 0 ] && grep -qF "${W}/badt.json: daemons[0] field 'health_timeout'" <<<"$t3_out"; then
    pass "T3 health_timeout ${_bad} fails the boot naming daemons[0] and the field"
  else
    fail "T3 health_timeout ${_bad} fails the boot naming daemons[0] and the field" "rc=${t3_rc} out=${t3_out}"
  fi
done

# T4: rc-boot-merge carries health_timeout through.
printf '{"daemons":[],"multiplexers":[],"tools":[]}\n' > "${W}/base2.json"
if RC_BOOT_DESCRIPTOR="${W}/base2.json" sh "$BOOT_MERGE" "${W}/slow.json" >/dev/null 2>&1 \
   && jq -e '.daemons[0].health_timeout == 20 and (.daemons[1] | has("health_timeout") | not)' "${W}/base2.json" >/dev/null; then
  pass "T4 rc-boot-merge carries health_timeout through untouched"
else
  fail "T4 rc-boot-merge carries health_timeout through untouched" "$(jq -c '.daemons' "${W}/base2.json" 2>/dev/null)"
fi

echo ""
echo "${TOTAL} checks, ${FAILURES} failed"
[ "$FAILURES" -eq 0 ]
