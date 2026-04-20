#!/usr/bin/env bash
set -euo pipefail

# Step 1: Generate CA keypair if not present (idempotent -- skip if cert exists).
if [[ ! -f /etc/rip-cage/ca/rip-cage-proxy-ca.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout /etc/rip-cage/ca/rip-cage-proxy-ca.key \
    -out /etc/rip-cage/ca/rip-cage-proxy-ca.pem \
    -subj "/CN=rip-cage-proxy-CA/O=rip-cage" \
    2>/dev/null
  chmod 600 /etc/rip-cage/ca/rip-cage-proxy-ca.key
fi

# Step 2: Install CA cert into system trust store (idempotent -- cp overwrites).
cp /etc/rip-cage/ca/rip-cage-proxy-ca.pem \
   /usr/local/share/ca-certificates/rip-cage-proxy.crt
update-ca-certificates --fresh 2>/dev/null

# Step 3: Write env file for CA trust vars (idempotent -- overwrite on every run).
#
# CRITICAL distinction from design doc "CA cert trust" section:
#   NODE_EXTRA_CA_CERTS points to the proxy CA cert ONLY.
#     Node APPENDS this to its built-in store. Correct -- do not point to the
#     combined bundle (that would load system CAs twice, wrong semantics).
#   SSL_CERT_FILE, REQUESTS_CA_BUNDLE, CURL_CA_BUNDLE point to the COMBINED
#     system bundle (/etc/ssl/certs/ca-certificates.crt).
#     These vars REPLACE the default trust store, so they MUST include all system
#     CAs. Pointing them to the proxy CA cert alone breaks all Python/curl HTTPS
#     because Let's Encrypt, DigiCert etc. would not be trusted.
cat > /etc/rip-cage/firewall-env <<'ENVEOF'
export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/rip-cage-proxy.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENVEOF

# Step 4: Apply iptables rules (idempotent -- check with -C before -A).
# REDIRECT: intercept TCP 80+443 from non-rip-proxy UIDs to :8080.
# rip-proxy's own re-originated traffic is excluded to prevent an infinite loop.
RIP_PROXY_UID=$(id -u rip-proxy)
if ! iptables -t nat -C OUTPUT -p tcp -m multiport --dports 443,80 \
     -m owner ! --uid-owner "$RIP_PROXY_UID" -j REDIRECT --to-port 8080 2>/dev/null; then
  iptables -t nat -A OUTPUT -p tcp -m multiport --dports 443,80 \
    -m owner ! --uid-owner "$RIP_PROXY_UID" -j REDIRECT --to-port 8080
fi
# DROP: block UDP port 443 (HTTP/3/QUIC) to force HTTP/2 fallback.
# Applies to all UIDs including rip-proxy. HTTP clients fall back to TCP automatically.
if ! iptables -C OUTPUT -p udp --dport 443 -j DROP 2>/dev/null; then
  iptables -A OUTPUT -p udp --dport 443 -j DROP
fi

# Step 5: Start mitmproxy as rip-proxy user.
# || true is REQUIRED on this line: pkill returns exit 1 when no process found
# (normal on first run). set -e would abort without it.
pkill -u rip-proxy mitmdump 2>/dev/null || true

# Write restart-wrapper to disk to avoid fragile nested shell quoting.
# This file is written at runtime; it is not COPYd in the Dockerfile.
cat > /tmp/rip-proxy-start.sh <<'PROXYEOF'
#!/bin/sh
while true; do
  mitmdump --mode transparent --listen-host 127.0.0.1 --listen-port 8080 \
    --set confdir=/etc/rip-cage/mitmproxy \
    -s /usr/local/lib/rip-cage/rip_cage_egress.py \
    2>>/var/log/rip-cage-proxy.log
  sleep 1
done
PROXYEOF
chmod +x /tmp/rip-proxy-start.sh
su -s /bin/sh rip-proxy -c 'nohup /tmp/rip-proxy-start.sh >/dev/null 2>&1 &'

# Step 6: Wait for proxy to be ready (up to 10s).
# mitmproxy transparent mode responds to direct HTTP with a proxy error page (4xx/5xx)
# rather than 200. Check curl exit code, not HTTP status:
#   exit 7 = connection refused (proxy not up yet -- keep waiting)
#   any other exit = port is accepting connections (even 4xx/5xx means 'up')
count=0
while [[ $count -lt 20 ]]; do
  curl -s --max-time 1 http://127.0.0.1:8080/ >/dev/null 2>&1
  curl_exit=$?
  if [[ $curl_exit -ne 7 ]]; then
    break
  fi
  sleep 0.5
  count=$((count + 1))
done
if [[ $count -ge 20 ]]; then
  echo "ERROR: mitmproxy did not start within 10s" >&2
  exit 1
fi

RULE_COUNT=$(/opt/rip-cage-proxy/bin/python -c "import yaml; d=yaml.safe_load(open('/etc/rip-cage/egress-rules.yaml')); print(len(d['rules']))")
echo "egress firewall active ($RULE_COUNT rules, deny-list mode)"
