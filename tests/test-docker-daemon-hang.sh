#!/usr/bin/env bash
set -uo pipefail

# rip-cage-3t1 — verify rc fails loud (not hangs) when the Docker daemon is
# wedged, and that `rc doctor --host` reports daemon liveness.
#
# Strategy: build a fake `docker` on PATH that hangs forever for `docker info`,
# simulating a wedged daemon (OrbStack VM stuck in Starting state — socket
# present but never replies). Lower RC_DOCKER_PREFLIGHT_TIMEOUT so each case
# runs in ~1s.
#
# rip-cage-tsf2.1: the msb-preflight verbs moved from check_docker to
# check_msb (ADR-029 D1 hard cutover). Tests 1/2 below exercise a fake `msb`
# that hangs on `--version` (check_msb's own preflight call) instead of a fake
# `docker` — otherwise identical wedge-detection shape, msb-side error code
# (MSB_UNREACHABLE, not DOCKER_DAEMON_UNREACHABLE). Their subjects were
# `rc ls` and `rc down`, which retired with the six-verb thinning
# (rip-cage-ely4.10); `rc destroy` and `rc test` are what is left behind that
# preflight arm, so the two cases move onto them. Tests 3-6 (`rc doctor
# --host`) are UNCHANGED: that verb's job is specifically to diagnose the
# DOCKER daemon (ADR-029 D1's docker-build path is still real docker), so
# it stays fake-docker-driven.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

# Sandboxes
HANG_BIN=$(mktemp -d)
DEAD_BIN=$(mktemp -d)
MSB_HANG_BIN=$(mktemp -d)
cleanup() {
  rm -rf "$HANG_BIN" "$DEAD_BIN" "$MSB_HANG_BIN"
  # Reap any orphan `sleep` processes our fake docker/msb may have left behind.
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

# Fake msb that hangs on `--version` (check_msb's own preflight call --
# simulates a wedged msb runtime, the msb-side counterpart to the docker
# HANG_BIN above).
cat > "$MSB_HANG_BIN/msb" <<'MSBHANGEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  exec sleep 60
fi
exit 0
MSBHANGEOF
chmod +x "$MSB_HANG_BIN/msb"

# 1s timeout keeps the suite fast. We don't time the calls strictly, but they
# must complete in well under the suite-level test timeout.
export RC_DOCKER_PREFLIGHT_TIMEOUT=1
export RC_MSB_PREFLIGHT_TIMEOUT=1

# -----------------------------------------------
# Test 1: rc destroy against a wedged msb runtime → MSB_UNREACHABLE, JSON
# -----------------------------------------------
echo ""
echo "=== Test 1: rc destroy --output json against wedged msb ==="
start=$(date +%s)
output=$(PATH="$MSB_HANG_BIN:$PATH" "$RC" --output json destroy 2>&1 || true)
elapsed=$(( $(date +%s) - start ))

if echo "$output" | grep -q '"code":"MSB_UNREACHABLE"'; then
  pass "wedged msb: JSON error code is MSB_UNREACHABLE"
else
  fail "wedged msb: expected MSB_UNREACHABLE in JSON" "$output"
fi
if echo "$output" | grep -qi "unresponsive\|wedged"; then
  pass "wedged msb: human message names the failure mode"
else
  fail "wedged msb: message should explain wedge/unresponsive" "$output"
fi
if (( elapsed <= 4 )); then
  pass "wedged msb: rc destroy returns in <=4s (was ${elapsed}s)"
else
  fail "wedged msb: rc destroy should not hang (was ${elapsed}s)" ""
fi

# -----------------------------------------------
# Test 2: rc test against a wedged msb runtime — same fail-loud
# -----------------------------------------------
echo ""
echo "=== Test 2: rc test --output json against wedged msb ==="
output=$(PATH="$MSB_HANG_BIN:$PATH" "$RC" --output json test 2>&1 || true)
if echo "$output" | grep -q '"code":"MSB_UNREACHABLE"'; then
  pass "wedged msb (test): JSON error code is MSB_UNREACHABLE"
else
  fail "wedged msb (test): expected MSB_UNREACHABLE" "$output"
fi

# -----------------------------------------------
# Test 3: rc doctor --host against wedged daemon — structured output
# -----------------------------------------------
echo ""
echo "=== Test 3: rc doctor --host (human) against wedged daemon ==="
output=$(PATH="$HANG_BIN:$PATH" "$RC" doctor --host 2>&1 || true)
# Pin the exact lines cli/doctor.sh prints for a wedged daemon. The "Scope:"
# line (doctor.sh:126) mentions "daemon" unconditionally, so a bare word grep
# passes even when no daemon check ran.
# RC_DOCKER_PREFLIGHT_TIMEOUT=1 above -> ${_t} is 1.
daemon_line=$(echo "$output" | grep '^Daemon:' || true)
if [[ "$daemon_line" == "Daemon:       FAIL — daemon unresponsive (no reply within 1s; likely wedged)" ]]; then
  pass "doctor --host: Daemon line is 'FAIL — daemon unresponsive (no reply within 1s; likely wedged)' (cli/doctor.sh:38,128)"
else
  fail "doctor --host: Daemon line should be the wedged-daemon FAIL status" "$daemon_line"
fi
if echo "$output" | grep -qxF "Remedy: 'orb restart' (OrbStack) or restart Docker Desktop, then retry."; then
  pass "doctor --host: includes the docker-daemon Remedy line (cli/doctor.sh:137)"
else
  fail "doctor --host: should include the docker-daemon Remedy line" "$output"
fi

# -----------------------------------------------
# Test 4: rc doctor --host --output json — parseable shape
# -----------------------------------------------
echo ""
echo "=== Test 4: rc doctor --host JSON against wedged daemon ==="
output=$(PATH="$HANG_BIN:$PATH" "$RC" --output json doctor --host 2>&1 || true)
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
output=$(PATH="$DEAD_BIN:$PATH" "$RC" --output json doctor --host 2>&1 || true)
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
output=$(PATH="$HANG_BIN:$PATH" "$RC" doctor --host 2>&1 || true)
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
