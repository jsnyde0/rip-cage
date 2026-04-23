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

# ---- Test 4: no host agent → label=off, sentinel=no_host_agent ----
# Regression guard for the "label lies about wiring" issue (review fix list
# 2026-04-23). When the host has no agent to forward, we must NOT write
# rc.forward-ssh=on (a subsequent resume would then re-attempt a doomed
# mount). Exercised only on Linux — on macOS, the OrbStack/Docker-Desktop
# magic path always resolves, so this case cannot arise.
if [[ "$(uname)" != "Darwin" ]]; then
  echo "=== Test 4: no host agent produces label=off, sentinel=no_host_agent ==="
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off SSH_AUTH_SOCK="" "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
  CONTAINER=$(_resolve_container)
  label=$(docker inspect --format '{{ index .Config.Labels "rc.forward-ssh" }}' "$CONTAINER" 2>/dev/null)
  if [[ "$label" == "off" ]]; then
    pass "rc.forward-ssh label = off (no host agent)"
  else
    fail "rc.forward-ssh label = '$label' (expected 'off')"
  fi
  status=$(docker exec "$CONTAINER" cat /etc/rip-cage/ssh-agent-status 2>/dev/null)
  if [[ "$status" == "no_host_agent" ]]; then
    pass "sentinel = no_host_agent"
  else
    fail "sentinel = '$status' (expected 'no_host_agent')"
  fi
else
  echo "=== Test 4: skipped (macOS always has a host-services magic path) ==="
fi

echo
echo "=== Results: $FAILURES failure(s) ==="
exit "$FAILURES"
