#!/usr/bin/env bash
# Unit tests for _rc_probe_host_bridge / _rc_host_bridge_resolves
# (rip-cage-woox).
#
# cage/init/init-rip-cage.sh's host-bridge preflight probe (ADR-016 D2) used
# to (a) probe only Docker/OrbStack bridge names, never the msb bridge name,
# and (b) overwrite a pre-set $CAGE_HOST_ADDR (the correct value rc up
# already computed at cli/up.sh:963) with whatever it probed. Both functions
# now live at the top of init-rip-cage.sh, guarded by RC_INIT_LIB_ONLY so a
# host-side test can source ONLY the function definitions (no bind-mount
# chowns, mise install, or Claude Code bootstrap) and stub the resolver.
#
# NOTE (ADR-029 D6 + the 2026-07-09 spike): host.microsandbox.internal
# RESOLVES in the guest -- resolvability is not reachability. The spike
# measured a fake-accepted TCP connect to it on msb <0.6.10 under macOS/HVF;
# that mechanic is gone on 0.6.18 (rip-cage-6v34.9) and guest->host
# reachability has not been re-measured since. Either way these tests only
# assert "resolves"/"is chosen", never "is reachable".
#
# _run_probe (below) calls _rc_probe_host_bridge as a plain (non-substituted)
# command, redirecting its stdout/stderr to temp files. Capturing via
# $(_rc_probe_host_bridge) instead would fork a subshell for the command
# substitution, and the function's _RC_HOST_BRIDGE_STATUS side-channel
# write would be lost when that subshell exits -- this avoids that trap.
#
# Coverage:
#   B1  preset honored: CAGE_HOST_ADDR set, resolver stubbed to resolve
#       NOTHING -> result is the preset value, status=preset, no WARNING
#   B2  msb name probed first: CAGE_HOST_ADDR unset, resolver resolves ALL
#       THREE candidate names -> result is host.microsandbox.internal
#       (proves ordering, not just membership)
#   B3  docker name still works: resolver resolves ONLY
#       host.docker.internal -> result is host.docker.internal, status=resolved
#   B4  genuinely unresolvable: resolver resolves nothing, CAGE_HOST_ADDR
#       unset -> status=fallback-literal AND the WARNING line IS emitted
#   B5  NEGATIVE CONTROL: preset must be honored, not overwritten. Reverting
#       the preset branch in init-rip-cage.sh (making the function probe
#       unconditionally) makes exactly this case fail -- see the driver
#       report for the RED/GREEN demonstration transcript.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SCRIPT="${SCRIPT_DIR}/../cage/init/init-rip-cage.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

echo "=== cage-host-bridge-probe unit tests ==="

# Source ONLY the function definitions -- RC_INIT_LIB_ONLY makes
# init-rip-cage.sh return right after defining _rc_host_bridge_resolves /
# _rc_probe_host_bridge, before any of its imperative init work runs.
RC_INIT_LIB_ONLY=1 source "$INIT_SCRIPT"

if ! declare -F _rc_probe_host_bridge >/dev/null 2>&1; then
  fail "_rc_probe_host_bridge exists after sourcing" "function not found"
  echo ""
  echo "=== cage-host-bridge-probe unit tests: 0/$TOTAL passed, $FAILURES failed ==="
  exit 1
fi

# Plain (non-subshelled) invocation so _RC_HOST_BRIDGE_STATUS side effects
# survive into the calling shell. Sets PROBE_RESULT / PROBE_STDERR /
# PROBE_STATUS.
_run_probe() {
  local out err
  out="$(mktemp)"
  err="$(mktemp)"
  _rc_probe_host_bridge >"$out" 2>"$err"
  PROBE_RESULT="$(cat "$out")"
  PROBE_STDERR="$(cat "$err")"
  PROBE_STATUS="$_RC_HOST_BRIDGE_STATUS"
  rm -f "$out" "$err"
}

# --- B1: preset honored, no probing, no WARNING ---
_rc_host_bridge_resolves() { return 1; }  # stub: resolves NOTHING
unset _RC_HOST_BRIDGE_STATUS
CAGE_HOST_ADDR="some.preset.host" _run_probe
if [[ "$PROBE_RESULT" == "some.preset.host" && "$PROBE_STATUS" == "preset" ]]; then
  pass "B1 preset value honored, status=preset"
else
  fail "B1 preset value honored, status=preset" "got result='$PROBE_RESULT' status='$PROBE_STATUS'"
fi
if [[ "$PROBE_STDERR" != *WARNING* ]]; then
  pass "B1 no WARNING emitted when preset is honored"
else
  fail "B1 no WARNING emitted when preset is honored" "stderr: $PROBE_STDERR"
fi

# --- B2: msb name probed first (ordering, not just membership) ---
_rc_host_bridge_resolves() { return 0; }  # stub: resolves ALL THREE
unset _RC_HOST_BRIDGE_STATUS
unset CAGE_HOST_ADDR
_run_probe
if [[ "$PROBE_RESULT" == "host.microsandbox.internal" && "$PROBE_STATUS" == "resolved" ]]; then
  pass "B2 msb bridge name probed and chosen first when all three resolve"
else
  fail "B2 msb bridge name probed and chosen first when all three resolve" "got result='$PROBE_RESULT' status='$PROBE_STATUS'"
fi

# --- B3: docker name still works when only it resolves ---
_rc_host_bridge_resolves() {
  [[ "$1" == "host.docker.internal" ]]
}
unset _RC_HOST_BRIDGE_STATUS
unset CAGE_HOST_ADDR
_run_probe
if [[ "$PROBE_RESULT" == "host.docker.internal" && "$PROBE_STATUS" == "resolved" ]]; then
  pass "B3 docker bridge name chosen when it's the only one that resolves"
else
  fail "B3 docker bridge name chosen when it's the only one that resolves" "got result='$PROBE_RESULT' status='$PROBE_STATUS'"
fi

# --- B4: genuinely unresolvable -> fallback-literal + WARNING ---
_rc_host_bridge_resolves() { return 1; }  # stub: resolves NOTHING
unset _RC_HOST_BRIDGE_STATUS
unset CAGE_HOST_ADDR
_run_probe
if [[ "$PROBE_RESULT" == "host.microsandbox.internal" && "$PROBE_STATUS" == "fallback-literal" ]]; then
  pass "B4 fallback-literal result+status when nothing resolves"
else
  fail "B4 fallback-literal result+status when nothing resolves" "got result='$PROBE_RESULT' status='$PROBE_STATUS'"
fi
if [[ "$PROBE_STDERR" == *"WARNING: no host bridge resolvable"* ]]; then
  pass "B4 WARNING emitted for the genuinely-unresolvable case"
else
  fail "B4 WARNING emitted for the genuinely-unresolvable case" "stderr: $PROBE_STDERR"
fi

# --- B5: NEGATIVE CONTROL -- preset must win over probing.
# If the preset branch is reverted (function probes unconditionally even
# with CAGE_HOST_ADDR set), this case goes RED: the stub below resolves
# host.docker.internal but NOT the preset value or the msb name, so an
# unconditional probe would return "host.docker.internal" instead of the
# preset "some.preset.host".
_rc_host_bridge_resolves() {
  [[ "$1" == "host.docker.internal" ]]
}
unset _RC_HOST_BRIDGE_STATUS
CAGE_HOST_ADDR="some.preset.host" _run_probe
if [[ "$PROBE_RESULT" == "some.preset.host" && "$PROBE_STATUS" == "preset" ]]; then
  pass "B5 NEGATIVE CONTROL: preset wins even when a probe candidate also resolves"
else
  fail "B5 NEGATIVE CONTROL: preset wins even when a probe candidate also resolves" "got result='$PROBE_RESULT' status='$PROBE_STATUS'"
fi

echo ""
echo "=== cage-host-bridge-probe unit tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
