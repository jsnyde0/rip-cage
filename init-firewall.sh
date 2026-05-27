#!/usr/bin/env bash

# ---------------------------------------------------------------------------
# Helper functions (always defined -- used by both exec and source/test paths).
# ---------------------------------------------------------------------------

# _get_tcp22_allowed_ips RULES_FILE
# Reads the egress-rules.yaml at RULES_FILE, checks the mode field.
# If mode=block: resolves each entry in allowed_hosts to IPv4 addresses and writes
# one IP per line to stdout. If mode is absent (legacy) or observe, writes nothing.
# Used at firewall-setup time to build the TCP-22 per-destination allowlist.
# IP churn is accepted and documented: resolution happens at firewall-setup time
# (rc up / rc reload); a host's IP changing requires rc reload to re-resolve.
_get_tcp22_allowed_ips() {
  local rules_file="${1:-/etc/rip-cage/egress-rules.yaml}"
  [[ ! -f "$rules_file" ]] && return 0

  # Read mode from the YAML file. Use grep/awk for portability (no yq/python needed).
  local mode
  mode=$(grep -m1 '^mode:' "$rules_file" 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'")

  # TCP-22 scoping only engages in block mode. Legacy (null/absent) and observe
  # leave TCP-22 as-is (ADR-012 D8 non-regression contract / ADR-021 D5).
  [[ "$mode" != "block" ]] && return 0

  # Read allowed_hosts from the YAML (simple YAML list parser: lines starting with "  - ")
  local hosts_section=0
  local host _ips
  while IFS= read -r line; do
    if [[ "$line" =~ ^allowed_hosts: ]]; then
      hosts_section=1
      continue
    fi
    # Stop reading at the next top-level key (unindented non-empty non-comment line)
    if [[ $hosts_section -eq 1 && "$line" =~ ^[a-zA-Z] ]]; then
      hosts_section=0
      break
    fi
    if [[ $hosts_section -eq 1 && "$line" =~ ^[[:space:]]*-[[:space:]]*(.*) ]]; then
      host="${BASH_REMATCH[1]}"
      # Resolve hostname to IPs. Try getent first (Debian containers), then host(1),
      # then python3 socket. Silently skip if all fail. Each resolver may fail with
      # exit 0 but empty output (e.g. getent on macOS); check output not exit code.
      _ips=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
      if [[ -z "$_ips" ]]; then
        _ips=$(host -t A "$host" 2>/dev/null | awk '/has address/{print $NF}' | sort -u)
      fi
      if [[ -z "$_ips" ]]; then
        _ips=$(python3 -c "
import socket, sys
try:
  for a in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET):
    print(a[4][0])
except Exception:
  pass
" "$host" 2>/dev/null | sort -u)
      fi
      [[ -n "$_ips" ]] && printf '%s\n' "$_ips"
    fi
  done < "$rules_file"
}

# _read_egress_mode RULES_FILE
# Reads the mode field from an egress-rules.yaml file.
# Prints "block", "observe", or "legacy" to stdout.
_read_egress_mode() {
  local rules_file="${1:-/etc/rip-cage/egress-rules.yaml}"
  [[ ! -f "$rules_file" ]] && { printf 'legacy\n'; return 0; }

  local mode
  mode=$(grep -m1 '^mode:' "$rules_file" 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'")

  case "${mode:-}" in
    block|observe) printf '%s\n' "$mode" ;;
    *) printf 'legacy\n' ;;
  esac
}

# When sourced (e.g., by tests), skip execution -- expose functions only.
[[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

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

# Step 1b: Populate mitmproxy confdir with our CA keypair so mitmproxy uses it
# instead of auto-generating its own (which clients don't trust).
# mitmproxy-ca.pem = private key + cert concatenated (mitmproxy's expected format).
# mitmproxy-ca-cert.pem = cert only (for distribution / trust anchoring).
mkdir -p /etc/rip-cage/mitmproxy
cat /etc/rip-cage/ca/rip-cage-proxy-ca.key \
    /etc/rip-cage/ca/rip-cage-proxy-ca.pem \
    > /etc/rip-cage/mitmproxy/mitmproxy-ca.pem
cp /etc/rip-cage/ca/rip-cage-proxy-ca.pem \
   /etc/rip-cage/mitmproxy/mitmproxy-ca-cert.pem
chmod 600 /etc/rip-cage/mitmproxy/mitmproxy-ca.pem
chmod 644 /etc/rip-cage/mitmproxy/mitmproxy-ca-cert.pem
chown -R rip-proxy:rip-proxy /etc/rip-cage/mitmproxy

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
export CLAUDE_CODE_CERT_STORE=/etc/ssl/certs/ca-certificates.crt
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

# Step 4b: REDIRECT DNS (UDP+TCP port 53) to DNS resolver sidecar on :5300.
# ADR-012 D9: transparent port-53 REDIRECT so dig @8.8.8.8 / nslookup / ping / host
# are all captured regardless of the upstream resolver the caller names.
# rip-proxy UID is excluded to avoid a loop when the sidecar makes its own upstream queries.
if ! iptables -t nat -C OUTPUT -p udp --dport 53 \
     -m owner ! --uid-owner "$RIP_PROXY_UID" -j REDIRECT --to-port 5300 2>/dev/null; then
  iptables -t nat -A OUTPUT -p udp --dport 53 \
    -m owner ! --uid-owner "$RIP_PROXY_UID" -j REDIRECT --to-port 5300
fi
if ! iptables -t nat -C OUTPUT -p tcp --dport 53 \
     -m owner ! --uid-owner "$RIP_PROXY_UID" -j REDIRECT --to-port 5300 2>/dev/null; then
  iptables -t nat -A OUTPUT -p tcp --dport 53 \
    -m owner ! --uid-owner "$RIP_PROXY_UID" -j REDIRECT --to-port 5300
fi

# Step 4c: TCP-22 IP allowlist (ADR-012 D8 evolved).
# When mode=block: resolve network.allowed_hosts to IPs; ACCEPT TCP-22 to those IPs;
# DROP TCP-22 to all other destinations. Fires BEFORE ssh-agent forwarding is
# consulted (network-layer block), closing the git-push exfil channel.
# When mode is legacy/null or observe: leave TCP-22 as-is (non-regression contract
# per ADR-021 D5 -- existing/unconfigured cages keep working).
# Resolution happens here (in-container, as root) via _get_tcp22_allowed_ips.
# IP churn is accepted: a host's IP changing requires rc reload to re-resolve.
_EGRESS_RULES=/etc/rip-cage/egress-rules.yaml
_TCP22_MODE=$(_read_egress_mode "$_EGRESS_RULES")
if [[ "$_TCP22_MODE" == "block" ]]; then
  # Remove any existing TCP-22 DROP/ACCEPT rules from prior runs (idempotent reload).
  # iptables -D returns non-zero if rule not found; iterate until all cleared.
  while iptables -D OUTPUT -p tcp --dport 22 -j DROP 2>/dev/null; do :; done
  while iptables -D OUTPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; do :; done

  # Add per-IP ACCEPT rules for whitelisted hosts (ACCEPT rules must come before DROP).
  while IFS= read -r _tcp22_ip; do
    [[ -z "$_tcp22_ip" ]] && continue
    if ! iptables -C OUTPUT -p tcp --dport 22 -d "$_tcp22_ip" -j ACCEPT 2>/dev/null; then
      iptables -A OUTPUT -p tcp --dport 22 -d "$_tcp22_ip" -j ACCEPT
    fi
  done < <(_get_tcp22_allowed_ips "$_EGRESS_RULES")

  # DROP all other TCP-22 (non-whitelisted destinations).
  if ! iptables -C OUTPUT -p tcp --dport 22 -j DROP 2>/dev/null; then
    iptables -A OUTPUT -p tcp --dport 22 -j DROP
  fi
fi

# Step 5: Start mitmproxy as rip-proxy user.
# || true is REQUIRED on this line: pkill returns exit 1 when no process found
# (normal on first run). set -e would abort without it.
pkill -u rip-proxy mitmdump 2>/dev/null || true

# Pre-create the proxy log so rip-proxy can write to it.
# (The file is root-owned by default; rip-proxy cannot create it otherwise.)
touch /var/log/rip-cage-proxy.log
chown rip-proxy:rip-proxy /var/log/rip-cage-proxy.log

# Pre-create the DNS sidecar log so rip-proxy can write to it.
touch /var/log/rip-cage-dns.log
chown rip-proxy:rip-proxy /var/log/rip-cage-dns.log

# Pre-create the audit log directory on the workspace bind mount.
# rip-proxy writes JSONL denial records here; /workspace is owned by agent:agent.
mkdir -p /workspace/.rip-cage
chmod 777 /workspace/.rip-cage

# Use the wrapper scripts baked into the image at build time (root-owned, 755).
# Do NOT write to /tmp -- it is world-writable and replaceable by the agent user.
su -s /bin/sh rip-proxy -c 'nohup /usr/local/lib/rip-cage/rip-proxy-start.sh >/dev/null 2>&1 &'
su -s /bin/sh rip-proxy -c 'nohup /usr/local/lib/rip-cage/rip-dns-start.sh >/dev/null 2>&1 &'

# Step 6: Wait for proxy to be ready (up to 10s).
# mitmproxy transparent mode responds to direct HTTP with a proxy error page (4xx/5xx)
# rather than 200. Check curl exit code, not HTTP status:
#   exit 7 = connection refused (proxy not up yet -- keep waiting)
#   any other exit = port is accepting connections (even 4xx/5xx means 'up')
count=0
while [[ $count -lt 20 ]]; do
  curl_exit=0
  curl -s --max-time 1 http://127.0.0.1:8080/ >/dev/null 2>&1 || curl_exit=$?
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

# Step 7: Print mode-aware startup banner.
# Read mode from the generated egress-rules.yaml (set by rc up / rc reload).
# mode=block   -> "block mode"    (whitelist enforced, TCP-22 scoped)
# mode=observe -> "observe mode"  (traffic logged, nothing blocked)
# absent       -> "legacy (deny-list) mode" (pre-evolution posture)
RULE_COUNT=$(/opt/rip-cage-proxy/bin/python -c "import yaml; d=yaml.safe_load(open('/etc/rip-cage/egress-rules.yaml')); print(len(d['rules']))")
_BANNER_MODE=$(_read_egress_mode /etc/rip-cage/egress-rules.yaml)
case "$_BANNER_MODE" in
  block)   echo "egress firewall active ($RULE_COUNT rules, block mode)" ;;
  observe) echo "egress firewall active ($RULE_COUNT rules, observe mode)" ;;
  *)       echo "egress firewall active ($RULE_COUNT rules, legacy (deny-list) mode)" ;;
esac
