#!/usr/bin/env bash
set -uo pipefail

# rip-cage-3t1 — verify rc fails loud (not hangs) when the Docker daemon is
# wedged, and that `rc doctor --host` reports daemon liveness.
#
# Strategy: build a fake `docker` on PATH that hangs forever for `docker info`,
# simulating a wedged daemon (OrbStack VM stuck in Starting state — socket
# present but never replies). Lower RC_DOCKER_PREFLIGHT_TIMEOUT so each case
# runs in ~1s.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

# Sandboxes
HANG_BIN=$(mktemp -d)
DEAD_BIN=$(mktemp -d)
cleanup() {
  rm -rf "$HANG_BIN" "$DEAD_BIN"
  # Reap any orphan `sleep` processes our fake docker may have left behind.
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT

# Fake docker that hangs on `info` (simulates wedged daemon).
cat > "$HANG_BIN/docker" <<'HANGEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
  exec sleep 60
fi
exit 0
HANGEOF
chmod +x "$HANG_BIN/docker"

# Fake docker that exits non-zero on `info` (simulates daemon down / refused).
cat > "$DEAD_BIN/docker" <<'DEADEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
  echo "Cannot connect to the Docker daemon" >&2
  exit 1
fi
exit 0
DEADEOF
chmod +x "$DEAD_BIN/docker"

# 1s timeout keeps the suite fast. We don't time the calls strictly, but they
# must complete in well under the suite-level test timeout.
export RC_DOCKER_PREFLIGHT_TIMEOUT=1

# -----------------------------------------------
# Test 1: rc ls against a wedged daemon → DOCKER_DAEMON_UNREACHABLE, JSON
# -----------------------------------------------
echo ""
echo "=== Test 1: rc ls --output json against wedged daemon ==="
start=$(date +%s)
output=$(PATH="$HANG_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" --output json ls 2>&1 || true)
elapsed=$(( $(date +%s) - start ))

if echo "$output" | grep -q '"code":"DOCKER_DAEMON_UNREACHABLE"'; then
  pass "wedged daemon: JSON error code is DOCKER_DAEMON_UNREACHABLE"
else
  fail "wedged daemon: expected DOCKER_DAEMON_UNREACHABLE in JSON" "$output"
fi
if echo "$output" | grep -qi "unresponsive\|wedged"; then
  pass "wedged daemon: human message names the failure mode"
else
  fail "wedged daemon: message should explain wedge/unresponsive" "$output"
fi
if (( elapsed <= 4 )); then
  pass "wedged daemon: rc ls returns in <=4s (was ${elapsed}s)"
else
  fail "wedged daemon: rc ls should not hang (was ${elapsed}s)" ""
fi

# -----------------------------------------------
# Test 2: rc down against a wedged daemon — same fail-loud
# -----------------------------------------------
echo ""
echo "=== Test 2: rc down --output json against wedged daemon ==="
output=$(PATH="$HANG_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" --output json down 2>&1 || true)
if echo "$output" | grep -q '"code":"DOCKER_DAEMON_UNREACHABLE"'; then
  pass "wedged daemon (down): JSON error code is DOCKER_DAEMON_UNREACHABLE"
else
  fail "wedged daemon (down): expected DOCKER_DAEMON_UNREACHABLE" "$output"
fi

# -----------------------------------------------
# Test 3: rc doctor --host against wedged daemon — structured output
# -----------------------------------------------
echo ""
echo "=== Test 3: rc doctor --host (human) against wedged daemon ==="
output=$(PATH="$HANG_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" doctor --host 2>&1 || true)
if echo "$output" | grep -qi "daemon"; then
  pass "doctor --host: output mentions 'daemon'"
else
  fail "doctor --host: should mention 'daemon'" "$output"
fi
if echo "$output" | grep -qi "FAIL"; then
  pass "doctor --host: explicitly marks FAIL"
else
  fail "doctor --host: should mark FAIL on wedge" "$output"
fi
if echo "$output" | grep -qi "remedy"; then
  pass "doctor --host: includes actionable Remedy line"
else
  fail "doctor --host: should include Remedy line" "$output"
fi

# -----------------------------------------------
# Test 4: rc doctor --host --output json — parseable shape
# -----------------------------------------------
echo ""
echo "=== Test 4: rc doctor --host JSON against wedged daemon ==="
output=$(PATH="$HANG_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" --output json doctor --host 2>&1 || true)
if echo "$output" | jq -e '.scope == "host"' >/dev/null 2>&1; then
  pass "doctor --host JSON: scope=host"
else
  fail "doctor --host JSON: missing scope=host" "$output"
fi
if echo "$output" | jq -e '.docker_info_rc == 124' >/dev/null 2>&1; then
  pass "doctor --host JSON: docker_info_rc=124 (timeout convention)"
else
  fail "doctor --host JSON: docker_info_rc should be 124" "$output"
fi
if echo "$output" | jq -e '.daemon | test("FAIL")' >/dev/null 2>&1; then
  pass "doctor --host JSON: daemon field starts with FAIL"
else
  fail "doctor --host JSON: daemon should be FAIL" "$output"
fi

# -----------------------------------------------
# Test 5: rc doctor --host against a working-but-rejecting daemon
#         (exits 1, NOT timeout) — should report rc=1, still FAIL
# -----------------------------------------------
echo ""
echo "=== Test 5: rc doctor --host against rejecting daemon (rc=1, not 124) ==="
output=$(PATH="$DEAD_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" --output json doctor --host 2>&1 || true)
if echo "$output" | jq -e '.docker_info_rc == 1' >/dev/null 2>&1; then
  pass "doctor --host: rejected daemon reports rc=1 (distinct from wedge)"
else
  fail "doctor --host: rejecting daemon should report rc=1" "$output"
fi

# -----------------------------------------------
# Test 6: rc doctor --host bypasses preflight (still emits diagnostic even
#         when daemon is fully down). Preflight running first would have
#         exited before _doctor_host could print anything.
# -----------------------------------------------
echo ""
echo "=== Test 6: rc doctor --host emits diagnostic (not preflight error) ==="
output=$(PATH="$HANG_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" doctor --host 2>&1 || true)
if echo "$output" | grep -q "Scope:"; then
  pass "doctor --host: bypasses preflight, prints Scope: line"
else
  fail "doctor --host: should bypass preflight" "$output"
fi

# -----------------------------------------------
# Summary
# -----------------------------------------------
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All daemon-hang tests passed."
else
  echo "$FAILURES test(s) FAILED."
  exit 1
fi
