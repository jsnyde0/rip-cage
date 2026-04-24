#!/usr/bin/env bash
# Tests for ADR-017 ssh-agent forwarding. Host-side: spawns real containers
# via `rc up` and verifies the socket is mounted, the label is set, the
# sentinel is written, and `--no-forward-ssh` produces the opposite state.
#
# Requires docker + the rip-cage image already built (./rc build).
# Does NOT require a working host ssh-agent — the preflight will report
# "empty" or "unreachable" depending on the host, and the test only asserts
# that the preflight surfaces *some* terminal status, not which one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_WS=""
CONTAINER=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Resolve the container name from the workspace label — robust against
# rc's collision-hash fallback and tr/sed name normalization.
_resolve_container() {
  docker ps -a --filter "label=rc.source.path=$(realpath "$TEST_WS" 2>/dev/null || echo "$TEST_WS")" \
    --format '{{.Names}}' | head -1
}

cleanup() {
  local _c
  _c=$(_resolve_container 2>/dev/null || true)
  [[ -n "$_c" ]] && docker rm -f "$_c" >/dev/null 2>&1 || true
  if [[ -n "$TEST_WS" && -d "$TEST_WS" ]]; then
    rm -rf "$TEST_WS"
  fi
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest image not built — run ./rc build first"
  exit 0
fi

TEST_WS=$(mktemp -d)

# ---- Test 1: default rc up wires forwarding ----
echo "=== Test 1: default rc up mounts socket and sets label=on ==="
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true

CONTAINER=$(_resolve_container)
if [[ -z "$CONTAINER" ]]; then
  fail "container did not come up"
  exit 1
fi

label=$(docker inspect --format '{{ index .Config.Labels "rc.forward-ssh" }}' "$CONTAINER" 2>/dev/null)
if [[ "$label" == "on" ]]; then
  pass "rc.forward-ssh label = on"
else
  fail "rc.forward-ssh label = '$label' (expected 'on')"
fi

if docker exec "$CONTAINER" test -S /ssh-agent.sock; then
  pass "/ssh-agent.sock is a socket inside container"
else
  fail "/ssh-agent.sock missing or not a socket"
fi

env_sock=$(docker exec "$CONTAINER" sh -c 'echo $SSH_AUTH_SOCK')
if [[ "$env_sock" == "/ssh-agent.sock" ]]; then
  pass "SSH_AUTH_SOCK=/ssh-agent.sock inside container"
else
  fail "SSH_AUTH_SOCK='$env_sock' (expected /ssh-agent.sock)"
fi

# Preflight sentinel: must be written with a recognized value.
status=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-status 2>/dev/null)
case "$status" in
  ok:*|empty|unreachable)
    pass "preflight sentinel = '$status' (recognized)"
    ;;
  *)
    fail "preflight sentinel = '$status' (expected ok:N|empty|unreachable)"
    ;;
esac

# Agent user must be able to talk to the socket (or get 'empty'), not hit
# permission-denied. ssh-add exits 2 for "cannot contact agent", which
# covers both the real-unreachable case and the permission-denied case
# caused by a missing init-rip-cage.sh chown step.
if docker exec -u agent "$CONTAINER" ssh-add -l >/dev/null 2>&1; then
  pass "agent user can reach forwarded socket (keys loaded)"
else
  ec=$?
  if [[ $ec -eq 1 ]]; then
    pass "agent user can reach forwarded socket (empty agent)"
  else
    # Only call this a failure if the status sentinel claims reachability —
    # otherwise the 'unreachable' case is already flagged above.
    if [[ "$status" != "unreachable" ]]; then
      fail "agent user hit exit=$ec talking to socket (likely chown missing)"
    fi
  fi
fi

# Banner: fresh shell should print the ssh-agent line.
banner=$(docker exec -u agent "$CONTAINER" zsh -i -c 'true' 2>&1 | head -1)
if echo "$banner" | grep -q '\[rip-cage\] ssh-agent:'; then
  pass "zshrc banner prints ssh-agent line on new shell"
else
  fail "zshrc banner missing ssh-agent line (got: '$banner')"
fi

# rc ls column (tab-separated; STATUS column contains spaces like "Up 2 seconds")
ls_out=$("$RC" ls 2>/dev/null | awk -F'\t' -v c="$CONTAINER" '$1 == c { print }')
fwd_col=$(printf '%s\n' "$ls_out" | awk -F'\t' '{ print $4 }')
if [[ "$fwd_col" == "on" ]]; then
  pass "rc ls FWD-SSH column shows 'on'"
else
  fail "rc ls FWD-SSH column = '$fwd_col' (expected 'on'), row: $ls_out"
fi

# ---- Test 2: --no-forward-ssh produces opposite state ----
echo "=== Test 2: --no-forward-ssh disables forwarding ==="
docker rm -f "$CONTAINER" >/dev/null 2>&1

RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up --no-forward-ssh "$TEST_WS" </dev/null >/dev/null 2>&1 || true
CONTAINER=$(_resolve_container)

label=$(docker inspect --format '{{ index .Config.Labels "rc.forward-ssh" }}' "$CONTAINER" 2>/dev/null)
if [[ "$label" == "off" ]]; then
  pass "rc.forward-ssh label = off"
else
  fail "rc.forward-ssh label = '$label' (expected 'off')"
fi

if docker exec "$CONTAINER" test -e /ssh-agent.sock 2>/dev/null; then
  fail "/ssh-agent.sock present despite --no-forward-ssh"
else
  pass "/ssh-agent.sock absent (expected)"
fi

env_sock=$(docker exec "$CONTAINER" sh -c 'echo $SSH_AUTH_SOCK')
if [[ -z "$env_sock" ]]; then
  pass "SSH_AUTH_SOCK unset inside container"
else
  fail "SSH_AUTH_SOCK='$env_sock' (expected unset)"
fi

status=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-status 2>/dev/null)
if [[ "$status" == "disabled" ]]; then
  pass "preflight sentinel = disabled"
else
  fail "preflight sentinel = '$status' (expected 'disabled')"
fi

# ---- Test 3: resume preserves label (no silent upgrade) ----
echo "=== Test 3: resume preserves --no-forward-ssh choice ==="
docker stop "$CONTAINER" >/dev/null 2>&1
# Resume WITHOUT --no-forward-ssh; label must still be off.
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
label=$(docker inspect --format '{{ index .Config.Labels "rc.forward-ssh" }}' "$CONTAINER" 2>/dev/null)
if [[ "$label" == "off" ]]; then
  pass "resume preserved rc.forward-ssh=off"
else
  fail "resume changed rc.forward-ssh to '$label' (expected 'off')"
fi

status=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-status 2>/dev/null)
if [[ "$status" == "disabled" ]]; then
  pass "resume sentinel still = disabled"
else
  fail "resume sentinel = '$status' (expected 'disabled')"
fi

# ---- Test 4: no host agent (SSH_AUTH_SOCK="") ----
# On Linux: both SSH_AUTH_SOCK="" and no convention socket → no_host_agent, label=off.
# On macOS: SSH_AUTH_SOCK="" means candidate #1 is skipped; candidate #2
# (/run/host-services/ssh-auth.sock) may or may not be reachable.
# - If reachable (OrbStack/Docker Desktop proxy present): label=on, ssh-agent-socket non-empty.
# - If unreachable: label=off, sentinel=no_host_agent.
echo "=== Test 4: no host agent (SSH_AUTH_SOCK unset) ==="
docker rm -f "$CONTAINER" >/dev/null 2>&1
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off SSH_AUTH_SOCK="" "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
CONTAINER=$(_resolve_container)
if [[ "$(uname)" != "Darwin" ]]; then
  label=$(docker inspect --format '{{ index .Config.Labels "rc.forward-ssh" }}' "$CONTAINER" 2>/dev/null)
  if [[ "$label" == "off" ]]; then
    pass "Test 4 (Linux): rc.forward-ssh label = off (no host agent)"
  else
    fail "Test 4 (Linux): rc.forward-ssh label = '$label' (expected 'off')"
  fi
  status=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-status 2>/dev/null)
  if [[ "$status" == "no_host_agent" ]]; then
    pass "Test 4 (Linux): sentinel = no_host_agent"
  else
    fail "Test 4 (Linux): sentinel = '$status' (expected 'no_host_agent')"
  fi
else
  # macOS: probe picks candidate #2 or falls through to no_host_agent
  label=$(docker inspect --format '{{ index .Config.Labels "rc.forward-ssh" }}' "$CONTAINER" 2>/dev/null)
  case "$label" in
    on)
      sock_sentinel=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-socket 2>/dev/null)
      if [[ -n "$sock_sentinel" ]]; then
        pass "Test 4 (macOS): candidate #2 wired, label=on, ssh-agent-socket='$sock_sentinel'"
      else
        fail "Test 4 (macOS): label=on but ssh-agent-socket sentinel is empty"
      fi
      ;;
    off)
      status=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-status 2>/dev/null)
      pass "Test 4 (macOS): no reachable candidate, label=off, sentinel='$status'"
      ;;
    *)
      fail "Test 4 (macOS): label='$label' (expected 'on' or 'off')"
      ;;
  esac
fi

# ---- Test 5: session-agent probe forwards the key the user actually loaded ----
echo "=== Test 5: session-agent probe forwards the key the user actually loaded ==="
docker rm -f "$(_resolve_container)" >/dev/null 2>&1
SSH_AGENT_SOCK=/tmp/rc-probe-test.sock
rm -f "$SSH_AGENT_SOCK"
eval "$(ssh-agent -a "$SSH_AGENT_SOCK")" >/dev/null 2>&1
ssh-keygen -t ed25519 -N "" -f /tmp/rc-test-key -C "rc-test" >/dev/null 2>&1
SSH_AUTH_SOCK="$SSH_AGENT_SOCK" ssh-add /tmp/rc-test-key >/dev/null 2>&1
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off SSH_AUTH_SOCK="$SSH_AGENT_SOCK" "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
CONTAINER=$(_resolve_container)
# Key visible inside cage
if docker exec "$CONTAINER" ssh-add -l 2>/dev/null | grep -q "rc-test"; then
  pass "Test 5: session-agent key visible inside cage"
else
  fail "Test 5: session-agent key not visible inside cage"
fi
# Companion sentinel contains the host socket path
sock_sentinel=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-socket 2>/dev/null)
if [[ "$sock_sentinel" == "$SSH_AGENT_SOCK" ]]; then
  pass "Test 5: ssh-agent-socket sentinel = $SSH_AGENT_SOCK"
else
  fail "Test 5: ssh-agent-socket sentinel = '$sock_sentinel' (expected '$SSH_AGENT_SOCK')"
fi
# Cleanup mock agent and temp key; eval ensures SSH_AUTH_SOCK/SSH_AGENT_PID
# are unset in this process so they don't bleed into later tests.
eval "$(SSH_AUTH_SOCK="$SSH_AGENT_SOCK" ssh-agent -k 2>/dev/null)" >/dev/null 2>&1 || true
unset SSH_AUTH_SOCK SSH_AGENT_PID
rm -f /tmp/rc-test-key /tmp/rc-test-key.pub /tmp/rc-probe-test.sock

# ---- Test 6: empty-agent — sentinel names the socket, banner includes path ----
echo "=== Test 6: empty-agent — sentinel names the socket, banner includes path ==="
docker rm -f "$(_resolve_container)" >/dev/null 2>&1
SSH_AGENT_SOCK=/tmp/rc-empty-test.sock
rm -f "$SSH_AGENT_SOCK"
eval "$(ssh-agent -a "$SSH_AGENT_SOCK")" >/dev/null 2>&1
# Do NOT add any keys — agent is empty
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off SSH_AUTH_SOCK="$SSH_AGENT_SOCK" "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
CONTAINER=$(_resolve_container)
status=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-status 2>/dev/null)
if [[ "$status" == "empty" ]]; then
  pass "Test 6: sentinel=empty for empty agent"
else
  fail "Test 6: sentinel='$status' (expected 'empty')"
fi
sock_sentinel=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-socket 2>/dev/null)
if [[ -n "$sock_sentinel" ]]; then
  pass "Test 6: ssh-agent-socket sentinel non-empty ('$sock_sentinel')"
else
  fail "Test 6: ssh-agent-socket sentinel is empty (should name the candidate)"
fi
banner=$(docker exec -u agent "$CONTAINER" zsh -i -c 'true' 2>&1)
if echo "$banner" | grep -q "$SSH_AGENT_SOCK"; then
  pass "Test 6: banner includes socket path"
else
  fail "Test 6: banner does not include socket path (got: $(echo "$banner" | grep rip-cage | head -3))"
fi
eval "$(SSH_AUTH_SOCK="$SSH_AGENT_SOCK" ssh-agent -k 2>/dev/null)" >/dev/null 2>&1 || true
unset SSH_AUTH_SOCK SSH_AGENT_PID
rm -f /tmp/rc-empty-test.sock

# ---- Test 7: unreachable SSH_AUTH_SOCK falls through gracefully ----
echo "=== Test 7: unreachable SSH_AUTH_SOCK falls through gracefully ==="
docker rm -f "$(_resolve_container)" >/dev/null 2>&1
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off SSH_AUTH_SOCK="/tmp/rc-nonexistent-sock-$$" "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
CONTAINER=$(_resolve_container)
if [[ -z "$CONTAINER" ]]; then
  fail "Test 7: container did not come up (docker run failed)"
else
  pass "Test 7: docker run succeeded despite unreachable SSH_AUTH_SOCK"
  status=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-status 2>/dev/null)
  case "$status" in
    ok:*|empty|unreachable|no_host_agent)
      pass "Test 7: sentinel='$status' (valid state after unreachable candidate)"
      ;;
    *)
      fail "Test 7: sentinel='$status' (unexpected)"
      ;;
  esac
fi

# ---- Test 8: Docker Desktop bind-mount guard skips /var/folders path ----
# Uses a real Unix socket so Gate 1 ([[ -S ]]) passes and Gate 2 (the
# /var/folders bind-mount guard) is actually exercised. A regular file from
# mktemp would be rejected by Gate 1 before Gate 2 is ever reached.
echo "=== Test 8: Docker Desktop bind-mount guard skips /var/folders path ==="
_backend=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo "unknown")
if [[ "$_backend" == *".docker/run/docker.sock"* ]] || [[ "$_backend" == "desktop-linux" ]]; then
  if [[ -d /var/folders ]]; then
    _fake_sock_dir=$(mktemp -d /var/folders/rc-test-XXXXXX 2>/dev/null)
    _fake_sock="${_fake_sock_dir}/agent.sock"
    if [[ -n "$_fake_sock_dir" ]]; then
      # Create a real Unix socket using python3 so Gate 1 (-S check) passes.
      python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); import time; time.sleep(30)" "$_fake_sock" &
      _fake_sock_pid=$!
      # Give the socket a moment to bind
      sleep 0.2
      if [[ -S "$_fake_sock" ]]; then
        docker rm -f "$(_resolve_container)" >/dev/null 2>&1
        # Also set up candidate #2 (/run/host-services/ssh-auth.sock) as a reachable
        # fallback so we can assert the /var/folders path was NOT chosen.
        RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off SSH_AUTH_SOCK="$_fake_sock" "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
        CONTAINER=$(_resolve_container)
        if [[ -z "$CONTAINER" ]]; then
          fail "Test 8: container did not come up (docker run failed — guard should have skipped, not crashed)"
        else
          pass "Test 8: container came up despite /var/folders SSH_AUTH_SOCK (guard skipped it)"
          # Verify the /var/folders socket was NOT mounted (the guard rejected it).
          mount_src=$(docker inspect \
            --format '{{ range .Mounts }}{{ if eq .Destination "/ssh-agent.sock" }}{{ .Source }}{{ end }}{{ end }}' \
            "$CONTAINER" 2>/dev/null || true)
          if [[ "$mount_src" == "$_fake_sock" ]]; then
            fail "Test 8: /var/folders socket was mounted despite Docker Desktop guard"
          else
            pass "Test 8: /var/folders socket was NOT mounted (guard correctly rejected it)"
          fi
        fi
      else
        echo "=== Test 8: skipped (could not create Unix socket in /var/folders) ==="
      fi
      kill "$_fake_sock_pid" 2>/dev/null
      wait "$_fake_sock_pid" 2>/dev/null
      rm -rf "$_fake_sock_dir"
    else
      echo "=== Test 8: skipped (could not create temp dir in /var/folders) ==="
    fi
  else
    echo "=== Test 8: skipped (no /var/folders directory) ==="
  fi
else
  echo "=== Test 8: skipped (not Docker Desktop backend: $_backend) ==="
fi

# ---- Test 9: --no-forward-ssh short-circuits probe (no latency added) ----
echo "=== Test 9: --no-forward-ssh short-circuits probe (no latency added) ==="
docker rm -f "$(_resolve_container)" >/dev/null 2>&1
_t0=$SECONDS
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off RIP_CAGE_FORWARD_SSH=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
_t_disabled=$(( SECONDS - _t0 ))
docker rm -f "$(_resolve_container)" >/dev/null 2>&1
_t0=$SECONDS
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off SSH_AUTH_SOCK="/tmp/rc-nonexistent-$$" "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
_t_probing=$(( SECONDS - _t0 ))
# disabled run should not be significantly slower than the probing run
# (it should be faster or comparable; a single 5s probe firing would push past 2s excess)
if [[ $(( _t_disabled - _t_probing )) -lt 2 ]]; then
  pass "Test 9: disabled run (${_t_disabled}s) not significantly slower than probing run (${_t_probing}s)"
else
  fail "Test 9: disabled run took ${_t_disabled}s vs probing run ${_t_probing}s — probe may be firing on disabled path"
fi
docker rm -f "$(_resolve_container)" >/dev/null 2>&1

# ---- Test 10: Linux — companion sentinel written alongside status sentinel ----
if [[ "$(uname)" != "Darwin" ]]; then
  echo "=== Test 10: Linux — companion sentinel written alongside status sentinel ==="
  if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    docker rm -f "$(_resolve_container)" >/dev/null 2>&1
    RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
    CONTAINER=$(_resolve_container)
    sock_sentinel=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-socket 2>/dev/null)
    if [[ -n "$sock_sentinel" ]]; then
      pass "Test 10: ssh-agent-socket sentinel written on Linux ('$sock_sentinel')"
    else
      fail "Test 10: ssh-agent-socket sentinel empty on Linux (should contain SSH_AUTH_SOCK path)"
    fi
  else
    echo "=== Test 10: skipped (SSH_AUTH_SOCK unset on Linux — run in a shell with ssh-agent) ==="
  fi
else
  echo "=== Test 10: skipped (macOS) ==="
fi

echo
echo "=== Results: $FAILURES failure(s) ==="
exit "$FAILURES"
