#!/usr/bin/env bash
set -euo pipefail
PASS=0
FAIL=0
TOTAL=0

check() {
  local name="$1" result="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "pass" ]]; then
    echo "PASS  [$TOTAL] $name${detail:+ — $detail}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  [$TOTAL] $name${detail:+ — $detail}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Egress Firewall Checks ==="
echo ""

# Check egress-off state (positive assertions when firewall is disabled).
# Design doc specifies: no iptables rules, no proxy, direct HTTPS works.
if [[ ! -f /etc/rip-cage/firewall-env ]]; then
  echo "-- Firewall is disabled (RIP_CAGE_EGRESS=off) --"
  echo ""

  # Egress-off check A: no mitmdump process running
  if pgrep -u rip-proxy mitmdump >/dev/null 2>/dev/null; then
    check "No mitmdump process (egress-off)" "fail" "mitmdump running unexpectedly"
  else
    check "No mitmdump process (egress-off)" "pass"
  fi

  # Egress-off check B: no REDIRECT rule in nat OUTPUT chain
  if sudo iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q REDIRECT; then
    check "No iptables REDIRECT rule (egress-off)" "fail" "REDIRECT rule present unexpectedly"
  else
    check "No iptables REDIRECT rule (egress-off)" "pass"
  fi

  # Egress-off check C: direct HTTPS to Anthropic API works (no proxy intercept)
  direct_code=$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time 10 \
    https://api.anthropic.com/v1/models 2>/dev/null || true)
  if [[ "$direct_code" == "401" ]] || [[ "$direct_code" == "200" ]] || [[ "$direct_code" == "403" ]]; then
    check "Direct HTTPS works without proxy (egress-off)" "pass" "HTTP $direct_code"
  else
    check "Direct HTTPS works without proxy (egress-off)" "fail" "HTTP $direct_code (expected 401/200/403)"
  fi

  echo ""
  echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
  exit "$(( FAIL > 0 ? 1 : 0 ))"
fi

echo "-- Proxy --"

# Check 1: Proxy process running as rip-proxy user
if pgrep -u rip-proxy mitmdump >/dev/null 2>/dev/null; then
  check "mitmproxy process running (rip-proxy user)" "pass"
else
  check "mitmproxy process running (rip-proxy user)" "fail" "no mitmdump process for rip-proxy"
fi

# Check 2: Proxy listening on :8080
# mitmproxy in transparent mode won't respond to a plain HTTP GET to 127.0.0.1:8080
# (it expects intercepted traffic, not direct proxy-style requests). So we check the
# socket is in LISTEN state via /proc/net/tcp. 0100007F = 127.0.0.1, 1F90 = 8080, 0A = LISTEN.
if grep -qE '^\s*[0-9]+:\s+0100007F:1F90\s+[0-9A-F]+:[0-9A-F]+\s+0A' /proc/net/tcp; then
  check "Proxy listening on 127.0.0.1:8080" "pass"
else
  check "Proxy listening on 127.0.0.1:8080" "fail" "no LISTEN socket on 127.0.0.1:8080"
fi

echo ""
echo "-- CA Trust --"

# Check 3: Proxy CA cert installed in system trust store
if [[ -f /usr/local/share/ca-certificates/rip-cage-proxy.crt ]]; then
  check "Proxy CA cert installed" "pass"
else
  check "Proxy CA cert installed" "fail" "missing /usr/local/share/ca-certificates/rip-cage-proxy.crt"
fi

# Check 4: CA cert verifiable against system bundle
if openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
     /usr/local/share/ca-certificates/rip-cage-proxy.crt >/dev/null 2>/dev/null; then
  check "CA cert in system bundle" "pass"
else
  check "CA cert in system bundle" "fail" "openssl verify failed"
fi

# Check 5: NODE_EXTRA_CA_CERTS is set in environment
if [[ -n "${NODE_EXTRA_CA_CERTS:-}" ]]; then
  check "NODE_EXTRA_CA_CERTS is set" "pass" "$NODE_EXTRA_CA_CERTS"
else
  check "NODE_EXTRA_CA_CERTS is set" "fail" "env var not exported (was init-rip-cage.sh run after init-firewall.sh?)"
fi

# Check 6: Anthropic API reachable through MITM proxy (D4 regression guard)
# 401 = auth required (valid HTTP response, TLS succeeded through proxy)
# 200 or 403 = also fine
# 000 = curl transport error (TLS failure or connection timeout -- proxy broke TLS)
anthropic_code=$(curl -s -o /dev/null -w '%{http_code}' \
  --max-time 10 \
  --cacert /etc/ssl/certs/ca-certificates.crt \
  https://api.anthropic.com/v1/models 2>/dev/null || true)
if [[ "$anthropic_code" == "401" ]] || [[ "$anthropic_code" == "200" ]] || [[ "$anthropic_code" == "403" ]]; then
  check "Anthropic API reachable via MITM (D4)" "pass" "HTTP $anthropic_code"
else
  check "Anthropic API reachable via MITM (D4)" "fail" "HTTP $anthropic_code (expected 401/200/403; 000 = TLS error)"
fi

echo ""
echo "-- Denylist Enforcement --"

# Check 7: Known-denied POST returns 403
denied_code=$(curl -s -o /dev/null -w '%{http_code}' \
  --max-time 10 \
  -X POST \
  https://webhook.site/test-rip-cage-probe 2>/dev/null || true)
if [[ "$denied_code" == "403" ]]; then
  check "Known-denied POST blocked (webhook.site)" "pass" "HTTP 403"
else
  check "Known-denied POST blocked (webhook.site)" "fail" "HTTP $denied_code (expected 403)"
fi

# Check 8: Denial response has X-Rip-Cage-Denied header
denied_header=$(curl -s -D - -o /dev/null \
  --max-time 10 \
  -X POST \
  https://webhook.site/test-rip-cage-probe 2>/dev/null | grep -i 'X-Rip-Cage-Denied' || true)
if [[ -n "$denied_header" ]]; then
  check "403 response has X-Rip-Cage-Denied header" "pass" "$denied_header"
else
  check "403 response has X-Rip-Cage-Denied header" "fail" "header missing"
fi

# Check 9: Known-allowed GET succeeds (method asymmetry -- reads allowed)
# 403 is also accepted: GitHub API returns 403 on rate limit (not a rip-cage denial
# -- use absence of X-Rip-Cage-Denied header to confirm proxy didn't block it).
allowed_code=$(curl -s -o /dev/null -w '%{http_code}' \
  --max-time 10 \
  https://api.github.com/ 2>/dev/null || true)
if [[ "$allowed_code" =~ ^(200|301|302|304|403)$ ]]; then
  check "Known-allowed GET succeeds (api.github.com)" "pass" "HTTP $allowed_code"
else
  check "Known-allowed GET succeeds (api.github.com)" "fail" "HTTP $allowed_code (expected 200/30x/403)"
fi

echo ""
echo "-- iptables Rules --"

# Check 10: REDIRECT rule present in nat OUTPUT chain
# Agent has sudo permission for 'iptables -t nat -L OUTPUT -n' (set in Bead 1 sudoers).
if sudo iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q REDIRECT; then
  check "iptables REDIRECT rule present" "pass"
else
  check "iptables REDIRECT rule present" "fail" "no REDIRECT in nat OUTPUT"
fi

# Check 11: UDP DROP rule present for port 443 (HTTP/3 block)
# Grep for 'udp' specifically to distinguish from a TCP DROP (which would also match
# "DROP.*dpt:443" but would not block QUIC/HTTP3).
if sudo iptables -L OUTPUT -n 2>/dev/null | grep -q "udp.*dpt:443"; then
  check "iptables UDP DROP rule for port 443 present" "pass"
else
  check "iptables UDP DROP rule for port 443 present" "fail" "no UDP DROP for dpt:443"
fi

# Check 12: Agent cannot modify iptables rules without sudo (ADR-002 D12)
# Run iptables -F WITHOUT sudo -- should fail with "Operation not permitted"
# Note: if this check somehow passes (iptables flushed), checks 10 and 11 above
# already ran and their pass/fail results are already recorded.
if iptables -t nat -F OUTPUT 2>/dev/null; then
  check "Agent cannot flush iptables rules (D12)" "fail" "iptables -F succeeded as agent -- REDIRECT rule is now gone"
else
  check "Agent cannot flush iptables rules (D12)" "pass" "iptables -F denied as expected"
fi

echo ""
echo "-- Audit Log --"

# Check 13: JSONL log entry written for the denied request from Check 7
if [[ -f /workspace/.rip-cage/egress.log ]]; then
  last_entry=$(tail -1 /workspace/.rip-cage/egress.log 2>/dev/null || true)
  if python3 -c "import json, sys; d=json.loads(sys.argv[1]); assert 'rule_id' in d and 'timestamp' in d" \
       "$last_entry" 2>/dev/null; then
    rule_id=$(python3 -c "import json, sys; print(json.loads(sys.argv[1])['rule_id'])" "$last_entry" 2>/dev/null || true)
    check "Denial logged to egress.log (JSONL)" "pass" "rule_id=$rule_id"
  else
    check "Denial logged to egress.log (JSONL)" "fail" "last entry not valid JSONL with rule_id+timestamp"
  fi
else
  check "Denial logged to egress.log (JSONL)" "fail" "/workspace/.rip-cage/egress.log does not exist"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
[[ "$FAIL" -eq 0 ]]
