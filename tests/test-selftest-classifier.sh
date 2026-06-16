#!/usr/bin/env bash
# Unit tests for _classify_selftest_probe() pure function (rip-cage-fft).
#
# Tests run host-side with no live firewall — all inputs are fixture values.
# Coverage:
#   C1  marker header present (curl_exit=0, http_code=200, marker=present) => ENFORCED
#   C2  200 response without marker header => BYPASSED
#   C3  403 from non-proxy (no marker) => BYPASSED
#   C4  curl exit 28 (timeout) against unroutable target => BYPASSED
#   C5  curl exit 7 (conn-refused) against unroutable target => BYPASSED
#   C6  curl exit 6 (DNS fail / name-not-resolved) => INCONCLUSIVE
#   C7  http_code=000, curl_exit=0 (edge case, genuine ambiguity) => INCONCLUSIVE
#   C8  curl TLS/cert-handshake exit codes (35, 51, 58, 59, 60, 77, 83) => BYPASSED
#       Post rip-cage-ta1o.1 (pure SNI router): there is NO rip-cage CA and the
#       selftest probe is plain HTTP on port 80 — so a TLS-handshake failure can
#       no longer be the benign "CA failed to install" case. With no CA excuse,
#       a TLS error is anomalous and maps to BYPASSED defensively (fail-closed:
#       refuse to start rather than warn-and-proceed).
#
# INCONCLUSIVE is near-empty by construction (per design invariants I1+I2).
# C6 and C7 represent the residual cases that cannot be confidently classified.
#
# Usage: bash tests/test-selftest-classifier.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREWALL_SCRIPT="${SCRIPT_DIR}/../init-firewall.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

# Source the helper functions from init-firewall.sh (the sourcing guard prevents
# execution when the script is sourced, so only functions are loaded).
# shellcheck source=../init-firewall.sh
# shellcheck disable=SC1091
source "$FIREWALL_SCRIPT"

# -------------------------------------------------------------------
# C1: marker present => ENFORCED
# -------------------------------------------------------------------
result=$(_classify_selftest_probe 0 200 "on-path")
if [[ "$result" == "ENFORCED" ]]; then
  pass "C1: marker present (exit=0, 200, on-path) => ENFORCED"
else
  fail "C1: marker present (exit=0, 200, on-path) => ENFORCED" "got: $result"
fi

# C1b: marker present with any http code => ENFORCED (marker wins)
result=$(_classify_selftest_probe 0 403 "on-path")
if [[ "$result" == "ENFORCED" ]]; then
  pass "C1b: marker present with 403 response => ENFORCED (marker wins)"
else
  fail "C1b: marker present with 403 response => ENFORCED (marker wins)" "got: $result"
fi

# -------------------------------------------------------------------
# C2: 200 response without marker => BYPASSED
# -------------------------------------------------------------------
result=$(_classify_selftest_probe 0 200 "")
if [[ "$result" == "BYPASSED" ]]; then
  pass "C2: 200 without marker (exit=0, 200, no-marker) => BYPASSED"
else
  fail "C2: 200 without marker (exit=0, 200, no-marker) => BYPASSED" "got: $result"
fi

# -------------------------------------------------------------------
# C3: 403 from non-proxy (no marker) => BYPASSED
# -------------------------------------------------------------------
result=$(_classify_selftest_probe 0 403 "")
if [[ "$result" == "BYPASSED" ]]; then
  pass "C3: 403 without marker (exit=0, 403, no-marker) => BYPASSED"
else
  fail "C3: 403 without marker (exit=0, 403, no-marker) => BYPASSED" "got: $result"
fi

# -------------------------------------------------------------------
# C4: timeout against unroutable target (exit 28) => BYPASSED
# -------------------------------------------------------------------
result=$(_classify_selftest_probe 28 000 "")
if [[ "$result" == "BYPASSED" ]]; then
  pass "C4: timeout (exit=28, 000, no-marker) => BYPASSED"
else
  fail "C4: timeout (exit=28, 000, no-marker) => BYPASSED" "got: $result"
fi

# -------------------------------------------------------------------
# C5: connection refused (exit 7) against unroutable target => BYPASSED
# -------------------------------------------------------------------
result=$(_classify_selftest_probe 7 000 "")
if [[ "$result" == "BYPASSED" ]]; then
  pass "C5: conn-refused (exit=7, 000, no-marker) => BYPASSED"
else
  fail "C5: conn-refused (exit=7, 000, no-marker) => BYPASSED" "got: $result"
fi

# -------------------------------------------------------------------
# C6: DNS fail (exit 6) => INCONCLUSIVE (ambiguous: DNS sidecar might be absent)
# -------------------------------------------------------------------
result=$(_classify_selftest_probe 6 000 "")
if [[ "$result" == "INCONCLUSIVE" ]]; then
  pass "C6: DNS-fail (exit=6, 000, no-marker) => INCONCLUSIVE"
else
  fail "C6: DNS-fail (exit=6, 000, no-marker) => INCONCLUSIVE" "got: $result"
fi

# -------------------------------------------------------------------
# C7: http_code=000 with curl exit=0 (curl connected but got nothing) => INCONCLUSIVE
# -------------------------------------------------------------------
result=$(_classify_selftest_probe 0 000 "")
if [[ "$result" == "INCONCLUSIVE" ]]; then
  pass "C7: http_code=000 with exit=0 => INCONCLUSIVE"
else
  fail "C7: http_code=000 with exit=0 => INCONCLUSIVE" "got: $result"
fi

# -------------------------------------------------------------------
# C8: TLS/cert-handshake curl exit codes => BYPASSED
#
# Post rip-cage-ta1o.1 (pure SNI router): no rip-cage CA, no TLS termination, and
# the selftest probe is plain HTTP on port 80. A TLS-handshake failure can no longer
# be the benign "CA failed to install" case — with no CA excuse it is anomalous, so
# it maps to BYPASSED defensively (fail-closed: refuse to start). Matches
# init-firewall.sh _classify_selftest_probe (35|51|58|59|60|77|83 => BYPASSED).
#
#   35  SSL connect error (generic TLS handshake failure)
#   51  peer certificate/fingerprint mismatch
#   58  local client certificate problem
#   59  couldn't use specified SSL cipher
#   60  SSL peer certificate or SSH remote key was not OK
#   77  problem with CA cert / cert bundle
#   83  issuer check failed (TLS certificate chain validation)
# -------------------------------------------------------------------
for tls_code in 35 51 58 59 60 77 83; do
  result=$(_classify_selftest_probe "$tls_code" 000 "")
  if [[ "$result" == "BYPASSED" ]]; then
    pass "C8-exit${tls_code}: TLS-handshake failure (exit=${tls_code}, 000, no-marker) => BYPASSED"
  else
    fail "C8-exit${tls_code}: TLS-handshake failure (exit=${tls_code}, 000, no-marker) => BYPASSED" "got: $result"
  fi
done

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "=== selftest classifier unit tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
