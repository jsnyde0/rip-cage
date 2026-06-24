#!/usr/bin/env bash
# test-egress-firewall.sh — in-cage egress checks (rip-cage-ta1o.1: pure destination router).
#
# Adapted for the pure SNI destination router:
#   - No TLS decryption, no CA, no per-host leaf cert.
#   - Destination denial = TCP reset / connection refused (not HTTP 403 body).
#   - Cert-absence assertion: no rip-cage CA in system trust store.
#   - Anthropic API: real upstream cert presented (not intercepted by MITM).
#   - IOC-floor denial: connection-level, not HTTP-level.
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

echo "=== Egress Firewall Checks (pure destination router) ==="
echo ""

# Check egress-off state (positive assertions when firewall is disabled).
# Design doc specifies: no iptables rules, no router, direct HTTPS works.
if [[ ! -f /etc/rip-cage/firewall-env ]]; then
  echo "-- Firewall is disabled (RIP_CAGE_EGRESS=off) --"
  echo ""

  # Egress-off check A: no router process running
  if pgrep -u rip-proxy -f rip_cage_router >/dev/null 2>/dev/null; then
    check "No router process (egress-off)" "fail" "rip_cage_router running unexpectedly"
  else
    check "No router process (egress-off)" "pass"
  fi

  # Egress-off check B: no REDIRECT rule in nat OUTPUT chain
  if sudo iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q REDIRECT; then
    check "No iptables REDIRECT rule (egress-off)" "fail" "REDIRECT rule present unexpectedly"
  else
    check "No iptables REDIRECT rule (egress-off)" "pass"
  fi

  # Egress-off check C: direct HTTPS to Anthropic API works (no router)
  direct_code=$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time 10 \
    https://api.anthropic.com/v1/models 2>/dev/null || true)
  if [[ "$direct_code" == "401" ]] || [[ "$direct_code" == "200" ]] || [[ "$direct_code" == "403" ]]; then
    check "Direct HTTPS works without router (egress-off)" "pass" "HTTP $direct_code"
  else
    check "Direct HTTPS works without router (egress-off)" "fail" "HTTP $direct_code (expected 401/200/403)"
  fi

  echo ""
  echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
  exit "$(( FAIL > 0 ? 1 : 0 ))"
fi

echo "-- Router Process --"

# Check 1: Router process running as rip-proxy user
if pgrep -u rip-proxy -f rip_cage_router >/dev/null 2>/dev/null; then
  check "SNI router process running (rip-proxy user)" "pass"
else
  check "SNI router process running (rip-proxy user)" "fail" "no rip_cage_router process for rip-proxy"
fi

# Check 2: Router listening on :8080
# Check the socket is in LISTEN state via /proc/net/tcp.
# 0100007F = 127.0.0.1, 1F90 = 8080, 0A = LISTEN.
if grep -qE '^\s*[0-9]+:\s+0100007F:1F90\s+[0-9A-F]+:[0-9A-F]+\s+0A' /proc/net/tcp; then
  check "Router listening on 127.0.0.1:8080" "pass"
else
  check "Router listening on 127.0.0.1:8080" "fail" "no LISTEN socket on 127.0.0.1:8080"
fi

echo ""
echo "-- Cert Absence (no MITM CA) --"

# Check 3: NO rip-cage CA cert in system trust store (pure router has no CA)
# Acceptance #2: assert cert ABSENCE — proves MITM is actually gone.
if [[ -f /usr/local/share/ca-certificates/rip-cage-proxy.crt ]]; then
  check "No rip-cage CA cert in system trust store (MITM absent)" "fail" \
    "rip-cage-proxy.crt found — CA still present, MITM not fully removed"
else
  check "No rip-cage CA cert in system trust store (MITM absent)" "pass"
fi

# Check 4: /etc/rip-cage/ca directory should not exist or be empty (no CA keypair)
if [[ -d /etc/rip-cage/ca ]] && ls /etc/rip-cage/ca/rip-cage-proxy-ca.* 2>/dev/null | grep -q .; then
  check "No CA keypair present (/etc/rip-cage/ca empty)" "fail" \
    "CA keypair files found in /etc/rip-cage/ca — MITM CA still present"
else
  check "No CA keypair present (/etc/rip-cage/ca empty)" "pass"
fi

# Check 5: NO mitmproxy confdir
if [[ -d /etc/rip-cage/mitmproxy ]]; then
  check "No mitmproxy confdir (pure router)" "fail" \
    "/etc/rip-cage/mitmproxy exists — mitmproxy remnant"
else
  check "No mitmproxy confdir (pure router)" "pass"
fi

echo ""
echo "-- Destination Routing (allowed host transparency) --"

# Check 6: Allowed host — real upstream cert presented (not intercepted).
# In block mode the Anthropic API must be in allowed_hosts; in legacy mode it passes freely.
# The pure router passes TLS bytes unchanged, so the upstream cert is real.
# We check curl can complete TLS using the SYSTEM CA bundle (not a custom CA).
# 401 = auth required (valid HTTP response, real TLS succeeded); 200/403 also fine.
_egress_mode=$(grep -m1 '^mode:' /etc/rip-cage/egress-rules.yaml 2>/dev/null | awk '{print $2}' || true)
anthropic_code=$(curl -s -o /dev/null -w '%{http_code}' \
  --max-time 10 \
  https://api.anthropic.com/v1/models 2>/dev/null || true)
if [[ "$anthropic_code" == "401" ]] || [[ "$anthropic_code" == "200" ]] || [[ "$anthropic_code" == "403" ]]; then
  check "Anthropic API reachable via router (real cert, no MITM)" "pass" "HTTP $anthropic_code"
else
  check "Anthropic API reachable via router (real cert, no MITM)" "fail" \
    "HTTP $anthropic_code (expected 401/200/403; 000 = connection refused by router or network)"
fi

echo ""
echo "-- Denylist Enforcement (destination-level) --"

# Check 7: Known-denied IOC host — connection refused/reset (not HTTP 403)
# Pure router: destination denial = TCP RST, curl exits non-zero with exit code
# 7 (CURLE_COULDNT_CONNECT) or similar — not 403.
denied_exit=0
curl -s -o /dev/null -w '%{http_code}' \
  --max-time 10 \
  https://webhook.site/test-rip-cage-probe 2>/dev/null || denied_exit=$?
if [[ "$denied_exit" -ne 0 ]]; then
  check "Known-denied host refused at destination level (webhook.site)" "pass" "curl exit=$denied_exit"
else
  check "Known-denied host refused at destination level (webhook.site)" "fail" \
    "curl exit=0 — destination not denied (expected non-zero exit)"
fi

# Check 8: Known-allowed GET succeeds
# 403 is also accepted: server-side auth failure, not router denial.
allowed_code=$(curl -s -o /dev/null -w '%{http_code}' \
  --max-time 10 \
  https://api.github.com/ 2>/dev/null || true)
if [[ "$allowed_code" =~ ^(200|301|302|304|403)$ ]]; then
  check "Known-allowed GET succeeds (api.github.com)" "pass" "HTTP $allowed_code"
else
  check "Known-allowed GET succeeds (api.github.com)" "fail" "HTTP $allowed_code (expected 200/30x/403)"
fi

# Check 9: Method symmetry — POST to allowed host is not blocked (no write-gate)
# Pure router: POST = GET for destination purposes. POST to an allowed host must succeed.
post_exit=0
post_code=$(curl -s -o /dev/null -w '%{http_code}' \
  --max-time 10 \
  -X POST \
  https://api.github.com/ 2>/dev/null) || post_exit=$?
if [[ "$post_code" =~ ^(200|201|301|302|403|404|405|422)$ ]]; then
  check "Method symmetry: POST to allowed host succeeds (no write-gate)" "pass" "HTTP $post_code"
else
  check "Method symmetry: POST to allowed host succeeds (no write-gate)" "fail" \
    "HTTP $post_code exit=$post_exit (expected non-connection-refused response)"
fi

echo ""
echo "-- iptables Rules --"

# Check 10: REDIRECT rule present in nat OUTPUT chain
if sudo iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q REDIRECT; then
  check "iptables REDIRECT rule present" "pass"
else
  check "iptables REDIRECT rule present" "fail" "no REDIRECT in nat OUTPUT"
fi

# Check 11: UDP DROP rule present for port 443 (HTTP/3 block)
if sudo iptables -L OUTPUT -n 2>/dev/null | grep -q "udp.*dpt:443"; then
  check "iptables UDP DROP rule for port 443 present" "pass"
else
  check "iptables UDP DROP rule for port 443 present" "fail" "no UDP DROP for dpt:443"
fi

# Check 12: Agent cannot modify iptables rules without sudo (ADR-002 D12)
if iptables -t nat -F OUTPUT 2>/dev/null; then
  check "Agent cannot flush iptables rules (D12)" "fail" "iptables -F succeeded as agent — REDIRECT rule is now gone"
else
  check "Agent cannot flush iptables rules (D12)" "pass" "iptables -F denied as expected"
fi

echo ""
echo "-- Audit Log --"

# Check 13: JSONL log entry written for the denied connection from Check 7
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
echo "-- Perimeter (IPv6, QUIC) --"

# Check 14: IPv6 egress blocked (active probe)
if ! command -v curl >/dev/null 2>&1; then
  check "IPv6 egress blocked (active probe)" "fail" "curl unavailable"
else
  ipv6_exit=0
  curl -6 --max-time 5 -s -o /dev/null https://ipv6.google.com > /dev/null 2>&1 || ipv6_exit=$?
  if [[ "$ipv6_exit" -ne 0 ]]; then
    check "IPv6 egress blocked (active probe)" "pass" "curl -6 exited $ipv6_exit"
  else
    check "IPv6 egress blocked (active probe)" "fail" \
      "curl -6 exited 0 — IPv6 path is open"
  fi
fi

# Check 15: Non-HTTP TCP ports not DROP'd (D4 policy)
filter_rules=$(sudo iptables -L OUTPUT -n 2>/dev/null || true)
if [[ "$_egress_mode" == "block" ]]; then
  if echo "$filter_rules" | grep -qE 'DROP.*tcp.*dpt:(25|587|993|2375|5432|6379)'; then
    bad_rule=$(echo "$filter_rules" | grep -E 'DROP.*tcp.*dpt:(25|587|993|2375|5432|6379)' | head -1)
    check "Non-HTTP TCP ports not DROP'd (D4, excl TCP-22 in block mode)" "fail" "unexpected DROP rule: $bad_rule"
  else
    check "Non-HTTP TCP ports not DROP'd (D4, excl TCP-22 in block mode)" "pass"
  fi
else
  if echo "$filter_rules" | grep -qE 'DROP.*tcp.*dpt:(22|25|53|587|993|2375|5432|6379)'; then
    bad_rule=$(echo "$filter_rules" | grep -E 'DROP.*tcp.*dpt:(22|25|53|587|993|2375|5432|6379)' | head -1)
    check "Non-HTTP TCP ports not DROP'd (D4=allowed)" "fail" "unexpected DROP rule: $bad_rule"
  else
    check "Non-HTTP TCP ports not DROP'd (D4=allowed)" "pass"
  fi
fi

# Check 15b: TCP-22 IP allowlist in block mode (ADR-012 D8 evolved).
if [[ "$_egress_mode" == "block" ]]; then
  if echo "$filter_rules" | grep -qE 'DROP.*tcp.*dpt:22'; then
    check "TCP-22 DROP rule present (block mode, ADR-012 D8 evolved)" "pass"
  else
    check "TCP-22 DROP rule present (block mode, ADR-012 D8 evolved)" "fail" "no TCP-22 DROP rule in block mode"
  fi
fi

# Check 16: DoH denial — dns.google denied in block mode (default-deny since not in allowed_hosts)
# In legacy mode: checked via IOC rule (nextdns-doh host_suffix; dns.google/cloudflare removed from floor).
# In block mode: dns.google is not in allowed_hosts → destination denied by default-deny.
# In either case, expect connection refused (TCP RST), not HTTP.
if [[ "$_egress_mode" == "block" ]]; then
  doh_exit=0
  curl -s -o /dev/null -w '%{http_code}' \
    --max-time 10 \
    "https://dns.google/dns-query?name=example.com&type=A" 2>/dev/null || doh_exit=$?
  if [[ "$doh_exit" -ne 0 ]]; then
    check "DoH to dns.google denied (block mode, default-deny)" "pass" "curl exit=$doh_exit"
  else
    check "DoH to dns.google denied (block mode, default-deny)" "fail" \
      "curl exit=0 — dns.google not denied (expected connection refused)"
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
[[ "$FAIL" -eq 0 ]]
