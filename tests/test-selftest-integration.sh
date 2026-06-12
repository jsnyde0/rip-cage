#!/usr/bin/env bash
# Container integration test for the startup self-test guard (rip-cage-fft).
#
# Tests the full end-to-end path: init-firewall.sh → real curl → real iptables
# REDIRECT → real proxy, inside a throwaway container.
#
# Tests:
#   IT1 (positive): a normally-started cage runs the guard and STARTS (probe => ENFORCED).
#   IT2 (negative): flush the nat REDIRECT rule so the proxy is off-path, run
#       _run_startup_selftest, assert BYPASSED + non-zero exit + fail-loud message.
#
# Requirements:
#   - Docker must be available and rip-cage:latest image must exist.
#   - The test mounts the current init-firewall.sh (from the repo) into the container
#     at the canonical path so the latest code is tested without requiring a full image
#     rebuild.  Production validation requires `./rc build` first (see harness.md).
#
# Usage:
#   bash tests/test-selftest-integration.sh
#
# Exit: 0 if all tests pass, 1 on any failure.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
echo "=== Selftest Container Integration Tests ==="
echo ""

# Check Docker is available.
if ! docker info > /dev/null 2>/dev/null; then
  echo "SKIP: Docker not available — skipping container integration tests"
  exit 0
fi

# Check the image exists.
if ! docker image inspect rip-cage:latest > /dev/null 2>/dev/null; then
  echo "SKIP: rip-cage:latest image not found — run ./rc build first"
  exit 0
fi

INIT_FIREWALL="${REPO_ROOT}/init-firewall.sh"
if [[ ! -f "$INIT_FIREWALL" ]]; then
  echo "FAIL: init-firewall.sh not found at ${INIT_FIREWALL}"
  exit 1
fi

RIP_CAGE_EGRESS_PY="${REPO_ROOT}/rip_cage_egress.py"
if [[ ! -f "$RIP_CAGE_EGRESS_PY" ]]; then
  echo "FAIL: rip_cage_egress.py not found at ${RIP_CAGE_EGRESS_PY}"
  exit 1
fi

RIP_PROXY_START="${REPO_ROOT}/rip-proxy-start.sh"
if [[ ! -f "$RIP_PROXY_START" ]]; then
  echo "FAIL: rip-proxy-start.sh not found at ${RIP_PROXY_START}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Container lifecycle helpers
# ---------------------------------------------------------------------------
IT1_CONTAINER="rc-selftest-it1-$$"
IT2_CONTAINER="rc-selftest-it2-$$"
IT1_WS=""
IT2_WS=""

# shellcheck disable=SC2329
cleanup() {
  docker rm -f "$IT1_CONTAINER" > /dev/null 2>/dev/null || true
  docker rm -f "$IT2_CONTAINER" > /dev/null 2>/dev/null || true
  [[ -n "$IT1_WS" ]] && rm -rf "$IT1_WS" || true
  [[ -n "$IT2_WS" ]] && rm -rf "$IT2_WS" || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# IT1: Positive path — a normally-started cage runs the guard and STARTS.
#
# The cage starts with the egress firewall active (block mode).  The selftest
# guard runs after the mitmproxy-readiness gate; the REDIRECT rule is in place;
# the proxy intercepts the probe and returns the ENFORCED marker.  The cage must
# start successfully (init-firewall.sh exits 0, guard emits ENFORCED).
# ---------------------------------------------------------------------------
echo "-- IT1: positive path (normal start => ENFORCED) --"

IT1_WS=$(mktemp -d)
mkdir -p "${IT1_WS}/.rip-cage"

# Start a throwaway container with:
# - the updated init-firewall.sh mounted (tests latest code without full rebuild)
# - the updated rip_cage_egress.py mounted (proxy addon with selftest endpoint)
# - the updated rip-proxy-start.sh mounted (must have connection_strategy=lazy so
#   the probe to the unroutable 192.0.2.1 is intercepted before upstream contact)
# - NET_ADMIN capability (required for iptables)
# The container runs sleep infinity; we exec init-firewall.sh as root to
# simulate the production startup path.
docker run -d --name "$IT1_CONTAINER" \
  --cap-add NET_ADMIN \
  -v "${INIT_FIREWALL}:/usr/local/lib/rip-cage/init-firewall.sh:ro" \
  -v "${RIP_CAGE_EGRESS_PY}:/usr/local/lib/rip-cage/rip_cage_egress.py:ro" \
  -v "${RIP_PROXY_START}:/usr/local/lib/rip-cage/rip-proxy-start.sh:ro" \
  -v "${IT1_WS}:/workspace:delegated" \
  rip-cage:latest sleep infinity > /dev/null 2>/dev/null

# Run init-firewall.sh as root (same as production path).
# Capture the output to assert on the ENFORCED log line.
# Use 'bash' to invoke so the bind-mount's host file permissions don't matter
# (the baked image has +x; the bind-mount may not inherit it on all platforms).
it1_output=""
it1_exit=0
it1_output=$(docker exec -u root "$IT1_CONTAINER" \
  bash /usr/local/lib/rip-cage/init-firewall.sh 2>&1) || it1_exit=$?

if [[ $it1_exit -eq 0 ]]; then
  pass "IT1a: init-firewall.sh exits 0 (cage started successfully)"
else
  fail "IT1a: init-firewall.sh exits 0 (cage started successfully)" \
       "exit $it1_exit; output: ${it1_output:0:500}"
fi

if echo "$it1_output" | grep -q "selftest: ENFORCED"; then
  pass "IT1b: guard emits ENFORCED log line (proxy on-path)"
else
  fail "IT1b: guard emits ENFORCED log line (proxy on-path)" \
       "output did not contain 'selftest: ENFORCED'; output: ${it1_output:0:500}"
fi

# ---------------------------------------------------------------------------
# IT2: Negative path — flush the REDIRECT rule, run guard, assert BYPASSED.
#
# After init-firewall.sh has run (REDIRECT rule present), flush the nat OUTPUT
# chain to remove the REDIRECT.  Then re-run _run_startup_selftest (sourced from
# the updated init-firewall.sh) inside the container.  The probe must dead-end at
# the unroutable IP (proxy off-path), classify BYPASSED, exit non-zero, and print
# the fail-loud message.  This exercises the real curl → classify path end-to-end.
# ---------------------------------------------------------------------------
echo ""
echo "-- IT2: negative path (REDIRECT flushed => BYPASSED, refuse to start) --"

IT2_WS=$(mktemp -d)
mkdir -p "${IT2_WS}/.rip-cage"

# Reuse a fresh container (same image, same mounts including rip-proxy-start.sh).
docker run -d --name "$IT2_CONTAINER" \
  --cap-add NET_ADMIN \
  -v "${INIT_FIREWALL}:/usr/local/lib/rip-cage/init-firewall.sh:ro" \
  -v "${RIP_CAGE_EGRESS_PY}:/usr/local/lib/rip-cage/rip_cage_egress.py:ro" \
  -v "${RIP_PROXY_START}:/usr/local/lib/rip-cage/rip-proxy-start.sh:ro" \
  -v "${IT2_WS}:/workspace:delegated" \
  rip-cage:latest sleep infinity > /dev/null 2>/dev/null

# First, run the full init-firewall.sh to set up the proxy, CA certs, and REDIRECT rule.
docker exec -u root "$IT2_CONTAINER" \
  /usr/local/lib/rip-cage/init-firewall.sh > /dev/null 2>/dev/null || true

# Now flush the nat OUTPUT chain (removes the REDIRECT rule).
# The proxy is still running but no longer on-path — exactly the failure class
# we must detect (x_tables absent / backend flip).
docker exec -u root "$IT2_CONTAINER" \
  iptables -t nat -F OUTPUT > /dev/null 2>/dev/null

# Verify the REDIRECT rule is gone before testing.
it2_redirect=""
it2_redirect=$(docker exec -u root "$IT2_CONTAINER" \
  iptables -t nat -L OUTPUT -n 2>/dev/null | grep REDIRECT || true)
if [[ -z "$it2_redirect" ]]; then
  pass "IT2-prereq: REDIRECT rule flushed (proxy off-path)"
else
  fail "IT2-prereq: REDIRECT rule flushed (proxy off-path)" \
       "REDIRECT still present: $it2_redirect"
fi

# Source init-firewall.sh and call _run_startup_selftest.
# The probe must classify BYPASSED and exit non-zero.
# The proxy is still running (lazy mode) but the REDIRECT is gone — the probe
# to 192.0.2.1:443 reaches the unroutable IP directly (no interception) and
# times out.  The real _run_startup_selftest uses 5s max-time; the test inherits it.
it2_output=""
it2_exit=0
it2_output=$(docker exec -u root "$IT2_CONTAINER" bash -c '
  source /usr/local/lib/rip-cage/init-firewall.sh
  _run_startup_selftest /etc/rip-cage/egress-rules.yaml
' 2>&1) || it2_exit=$?

if [[ $it2_exit -ne 0 ]]; then
  pass "IT2a: guard exits non-zero when REDIRECT flushed (refuses to start)"
else
  fail "IT2a: guard exits non-zero when REDIRECT flushed (refuses to start)" \
       "exit was 0; output: ${it2_output:0:500}"
fi

if echo "$it2_output" | grep -qiE "BYPASSED|fail.open|silent|x_tables"; then
  pass "IT2b: guard emits fail-loud message (BYPASSED / silent fail-open)"
else
  fail "IT2b: guard emits fail-loud message (BYPASSED / silent fail-open)" \
       "output: ${it2_output:0:500}"
fi

# The fail-loud message must mention the likely cause.
if echo "$it2_output" | grep -qiE "x_tables|iptables|REDIRECT|backend"; then
  pass "IT2c: fail-loud message names likely cause (iptables/REDIRECT/backend)"
else
  fail "IT2c: fail-loud message names likely cause (iptables/REDIRECT/backend)" \
       "output: ${it2_output:0:500}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== selftest integration tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
