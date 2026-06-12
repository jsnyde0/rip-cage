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

# _classify_selftest_probe CURL_EXIT HTTP_CODE MARKER_PRESENT
# Pure classifier for the startup egress self-test (rip-cage-fft).
# Inputs:
#   CURL_EXIT     — curl exit code
#   HTTP_CODE     — HTTP status code (string, e.g. "200", "403", "000")
#   MARKER_PRESENT — marker header value if present, empty string if absent
# Output (stdout): ENFORCED | BYPASSED | INCONCLUSIVE
#
# Classification logic:
#   Marker present (non-empty MARKER_PRESENT)          => ENFORCED
#     The proxy generated the marker locally (I1); this is the confident on-path signal.
#   Any definite response (non-000 http_code, no marker) => BYPASSED
#     The direct path produced a real response — not our proxy, bypass confirmed.
#   Exit 28 (timeout) or 7 (conn-refused), 000 http_code => BYPASSED
#     The probe dead-ended at the unroutable IP (I2); a working proxy would have
#     returned the marker (I1), so this is a confident bypass, not ambiguity.
#   Exit 6 (DNS resolution failed)                      => INCONCLUSIVE
#     --resolve should make DNS irrelevant, but DNS sidecar absence or curl
#     version quirk could cause exit 6 without a true bypass; warn-and-proceed.
#   Exit 0 with 000 http_code (curl connected, got nothing) => INCONCLUSIVE
#     Genuinely ambiguous: something is on the path but produced no response.
#     Warn-and-proceed (never-false-alarm requirement).
#
# INCONCLUSIVE is near-empty by construction (I1+I2 invariants): the ENFORCED
# path cannot time out (answered locally by the already-up proxy, no round-trip),
# so residual INCONCLUSIVE covers only edge-case curl/env anomalies.
_classify_selftest_probe() {
  local curl_exit="$1"
  local http_code="$2"
  local marker_present="$3"

  # Marker present => proxy is on-path (confident positive signal, I1)
  if [[ -n "$marker_present" ]]; then
    printf 'ENFORCED\n'
    return 0
  fi

  # Definite non-000 HTTP response without the marker => something else answered
  if [[ "$http_code" != "000" ]]; then
    printf 'BYPASSED\n'
    return 0
  fi

  # HTTP code is 000 — check curl exit code
  case "$curl_exit" in
    28|7)
      # Timeout (28) or connection refused (7) against the unroutable target:
      # a working proxy would have intercepted the connection and returned the marker.
      # No intercept => BYPASSED (confident, per I2: unroutable target dead-ends).
      printf 'BYPASSED\n'
      ;;
    6)
      # DNS resolution failed. With --resolve this shouldn't happen, but if it does
      # we cannot confidently attribute it to bypass (could be curl/sidecar quirk).
      printf 'INCONCLUSIVE\n'
      ;;
    0)
      # curl exited 0 but got no HTTP response (000) — ambiguous; warn-and-proceed.
      printf 'INCONCLUSIVE\n'
      ;;
    35|51|58|59|60|77|83)
      # TLS/cert-handshake failure codes: curl could not establish a trusted TLS
      # session with the proxy. This is AMBIGUOUS — the rip-cage CA may have failed
      # to install (e.g. update-ca-certificates not yet run, or a timing issue),
      # not necessarily a bypass. A working proxy with a missing CA would produce
      # exactly this outcome, so mapping to BYPASSED would false-alarm a healthy-but-
      # degraded cage. Never-false-alarm contract wins: INCONCLUSIVE (warn-and-proceed).
      #   35  SSL connect error (generic TLS handshake failure)
      #   51  peer certificate / fingerprint mismatch
      #   58  local client certificate problem
      #   59  couldn't use specified SSL cipher
      #   60  SSL peer certificate or SSH remote key was not OK (CA verify failed)
      #   77  problem with CA cert / cert bundle
      #   83  issuer check failed (TLS certificate chain validation)
      printf 'INCONCLUSIVE\n'
      ;;
    *)
      # Any other curl error against the unroutable target: the direct path failed
      # in an unrecognised way. Default-to-safe: treat as BYPASSED so a novel
      # definite-failure code does not silently allow a misconfigured cage to start.
      printf 'BYPASSED\n'
      ;;
  esac
}

# _run_startup_selftest RULES_FILE
# Runs the startup EFFECT self-test guard (rip-cage-fft).
#
# Mode-awareness:
#   - observe mode: skip (logs "skipped: observe mode", exits 0)
#   - RIP_CAGE_EGRESS=off: skip (logs "skipped: egress off", exits 0)
#   - block mode or legacy mode: run probe; BYPASSED => exit non-zero (refuse to start)
#
# Probe mechanism:
#   Curls the reserved self-test hostname over HTTPS, pinned to the RFC 5737
#   reserved (guaranteed-unroutable) address 192.0.2.1 via --resolve (no DNS/sidecar
#   involved; --resolve pre-pins the IP before TLS/TCP).
#   Uses HTTPS (port 443) to exercise the same interception path real traffic uses.
#   The system CA bundle (updated by update-ca-certificates in Step 2) trusts the
#   MITM cert, so no special --cacert flag is needed.
#
#   WHY 192.0.2.1 works (invariant I2 preserved):
#   mitmproxy is started with --set connection_strategy=lazy (rip-proxy-start.sh),
#   which defers the upstream TCP connect until AFTER the request() hook runs.
#   In lazy mode the proxy completes the client-side TLS handshake (minting a cert
#   for the SNI from the rip-cage CA) without contacting 192.0.2.1 at all; the
#   request() hook fires, sees the self-test hostname, returns the marker locally,
#   and mitmproxy never attempts an upstream connect. Sub-ms, zero internet round-trip.
#
#   If the REDIRECT is absent (proxy bypassed), curl's connection to 192.0.2.1:443
#   goes nowhere (RFC 5737 IP is unroutable by design) and times out (curl exit 28).
#   A working proxy can NEVER produce this outcome — it would return the marker
#   locally — so a timeout here is a CONFIDENT bypass signal (I2 holds).
#
#   This restores invariant I2 (no external-host dependency): the probe dead-ends
#   at the guaranteed-unroutable IP when bypassed, not at a real host that might
#   be temporarily unreachable (which would false-alarm against a healthy cage).
#
# NO production test hook: testability is achieved via a curl PATH-shim (a fake
# curl on PATH returning canned output) and by controlling the rules file / mode.
# See tests/test-selftest-mode-gating.sh.
_run_startup_selftest() {
  local rules_file="${1:-/etc/rip-cage/egress-rules.yaml}"

  # Skip when egress is explicitly off
  if [[ "${RIP_CAGE_EGRESS:-}" == "off" ]]; then
    echo "rip-cage selftest: skipped: egress off"
    return 0
  fi

  # Read mode from rules file
  local mode
  mode=$(_read_egress_mode "$rules_file")

  # Skip in observe mode (intentionally logs-but-allows; not a blocking posture)
  if [[ "$mode" == "observe" ]]; then
    echo "rip-cage selftest: skipped: observe mode"
    return 0
  fi

  # block or legacy: run the probe
  local selftest_host="selftest.rip-cage.internal"
  # RFC 5737 reserved address — guaranteed unroutable by IANA assignment.
  # With connection_strategy=lazy in rip-proxy-start.sh, the proxy completes the
  # client-side TLS handshake and fires the request() hook WITHOUT first contacting
  # this IP, so the marker is returned locally (I1).  When the REDIRECT is absent,
  # curl's TCP connection to this IP goes nowhere and times out (I2: confident bypass).
  # No external-host dependency: false-alarm on "real host temporarily down" is
  # structurally impossible (the host is unroutable, not just down).
  local probe_ip="192.0.2.1"
  local probe_url="https://${selftest_host}/"
  local marker_header="x-rip-cage-selftest"
  local probe_timeout=5  # seconds; proxy answers locally (<1ms), so 5s is generous

  # Real probe: curl with --resolve to pin IP, --max-time for the unroutable case.
  # Capture http_code via -w '%{http_code}' and write headers to a temp file
  # so we can check for the marker without messing up output parsing.
  local classification
  local tmpfile
  tmpfile=$(mktemp)
  local curl_exit=0
  local http_code
  http_code=$(curl -s \
    --resolve "${selftest_host}:443:${probe_ip}" \
    --max-time "${probe_timeout}" \
    -D "${tmpfile}" \
    -o /dev/null \
    -w '%{http_code}' \
    "${probe_url}" 2>/dev/null) || curl_exit=$?

  # Check for marker header in the captured response headers
  local marker_value=""
  if [[ -f "$tmpfile" ]]; then
    marker_value=$(grep -i "^${marker_header}:" "$tmpfile" 2>/dev/null | awk -F': ' '{print $2}' | tr -d '[:space:]') || true
    rm -f "$tmpfile"
  fi

  classification=$(_classify_selftest_probe "$curl_exit" "${http_code:-000}" "$marker_value")

  case "$classification" in
    ENFORCED)
      echo "rip-cage selftest: ENFORCED — proxy is on-path, egress firewall active"
      return 0
      ;;
    BYPASSED)
      echo "ERROR: rip-cage selftest: BYPASSED — egress proxy is NOT on-path (silent fail-open detected)" >&2
      echo "ERROR: The iptables REDIRECT rule may have silently no-op'd." >&2
      echo "ERROR: Likely cause: legacy x_tables interface absent on this kernel (6.18+) or iptables backend no-op." >&2
      echo "ERROR: Refusing to start cage in blocking posture with unenforceable firewall." >&2
      return 1
      ;;
    INCONCLUSIVE)
      echo "WARNING: rip-cage selftest: INCONCLUSIVE — probe result ambiguous; warn-and-proceed (cage starts)" >&2
      echo "WARNING: This may indicate a curl/sidecar anomaly. Monitor egress.log for unexpected traffic." >&2
      return 0
      ;;
    *)
      echo "WARNING: rip-cage selftest: unrecognized classification '$classification'; warn-and-proceed" >&2
      return 0
      ;;
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
# `sh /script` rather than `/script` directly: bind-mounted scripts may lack the
# execute (+x) bit on the host filesystem, which would cause a "Permission denied"
# error; invoking via `sh` bypasses the execute-bit requirement entirely.
su -s /bin/sh rip-proxy -c 'nohup sh /usr/local/lib/rip-cage/rip-proxy-start.sh >/dev/null 2>&1 &'
su -s /bin/sh rip-proxy -c 'nohup sh /usr/local/lib/rip-cage/rip-dns-start.sh >/dev/null 2>&1 &'

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

# Step 7: EFFECT-based startup self-test (rip-cage-fft).
# Verifies the proxy is actually ON-PATH by curling the reserved self-test endpoint
# pinned to 192.0.2.1 (RFC 5737 guaranteed-unroutable; see _run_startup_selftest).
# The proxy is started with connection_strategy=lazy (rip-proxy-start.sh), so the
# request() hook fires locally before any upstream contact with 192.0.2.1.
# Must run AFTER the CA-install (Step 2) and mitmproxy-readiness gate (Step 6).
# Skips in observe mode and when egress is off.
# Refuses to start (exit 1) if proxy is not on-path in a blocking posture.
_run_startup_selftest /etc/rip-cage/egress-rules.yaml

# Step 8: Print mode-aware startup banner.
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
