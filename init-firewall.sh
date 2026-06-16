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
# Pure classifier for the startup egress self-test (rip-cage-fft / rip-cage-ta1o.1).
# Inputs:
#   CURL_EXIT     — curl exit code
#   HTTP_CODE     — HTTP status code (string, e.g. "200", "403", "000")
#   MARKER_PRESENT — marker header value if present, empty string if absent
# Output (stdout): ENFORCED | BYPASSED | INCONCLUSIVE
#
# Classification logic (pure-router version):
#   Marker present (non-empty MARKER_PRESENT)          => ENFORCED
#     The router generated the marker locally (I1); this is the confident on-path signal.
#   Any definite response (non-000 http_code, no marker) => BYPASSED
#     The direct path produced a real response — not our router, bypass confirmed.
#   Exit 28 (timeout) or 7 (conn-refused), 000 http_code => BYPASSED
#     The probe dead-ended at the unroutable IP (I2); a working router would have
#     returned the marker (I1), so this is a confident bypass, not ambiguity.
#   Exit 6 (DNS resolution failed)                      => INCONCLUSIVE
#     --resolve should make DNS irrelevant, but DNS sidecar absence or curl
#     version quirk could cause exit 6 without a true bypass; warn-and-proceed.
#   Exit 0 with 000 http_code (curl connected, got nothing) => INCONCLUSIVE
#     Genuinely ambiguous: something is on the path but produced no response.
#     Warn-and-proceed (never-false-alarm requirement).
#
# Note: TLS error exit codes (35/51/58/59/60/77/83) are no longer expected
# since the pure router does NOT terminate TLS — the probe uses plain HTTP (port 80).
# They remain mapped to BYPASSED (a real bypass would give a TLS error from the
# remote host), but should not occur in practice.
_classify_selftest_probe() {
  local curl_exit="$1"
  local http_code="$2"
  local marker_present="$3"

  # Marker present => router is on-path (confident positive signal, I1)
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
      # a working router would have intercepted the connection and returned the marker.
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
      # TLS/cert-handshake failure codes: these should not occur with plain HTTP
      # selftest probe, but map to BYPASSED defensively (a real bypass to 192.0.2.1
      # would not produce a TLS response).
      printf 'BYPASSED\n'
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
# Runs the startup EFFECT self-test guard (rip-cage-fft / rip-cage-ta1o.1).
#
# Pure-router version:
#   The probe uses plain HTTP (port 80), NOT HTTPS. The pure router intercepts
#   plain-HTTP requests and returns the marker locally for the selftest hostname,
#   without any TLS handshake or CA involvement.
#
# Mode-awareness:
#   - observe mode: skip (logs "skipped: observe mode", exits 0)
#   - RIP_CAGE_EGRESS=off: skip (logs "skipped: egress off", exits 0)
#   - block mode or legacy mode: run probe; BYPASSED => exit non-zero (refuse to start)
#
# Probe mechanism:
#   Curls the reserved self-test hostname over plain HTTP (port 80), pinned to the
#   RFC 5737 reserved (guaranteed-unroutable) address 192.0.2.1 via --resolve
#   (no DNS/sidecar involved; --resolve pre-pins the IP before TCP connect).
#   Uses HTTP (not HTTPS) since the pure router cannot decrypt TLS.
#
#   WHY 192.0.2.1 works (invariant I2 preserved):
#   The router intercepts plain-HTTP connections and responds to the selftest
#   hostname locally, before attempting any upstream connect. So the marker is
#   returned locally (I1).  When the REDIRECT is absent, curl's TCP connection
#   to this IP goes nowhere (RFC 5737 IP is unroutable by design) and times out
#   (curl exit 28). A working router can NEVER produce this outcome — it would
#   return the marker locally — so a timeout here is a CONFIDENT bypass signal
#   (I2 holds).
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
  # The router intercepts the plain-HTTP request and responds locally (I1).
  # When the REDIRECT is absent, curl's TCP connection to this IP times out (I2).
  local probe_ip="192.0.2.1"
  # Plain HTTP (port 80) — the pure router handles HTTP natively.
  # No TLS, no CA, no cert needed.
  local probe_url="http://${selftest_host}/"
  local marker_header="x-rip-cage-selftest"
  local probe_timeout=5  # seconds; router answers locally (<1ms), so 5s is generous

  # Real probe: curl with --resolve to pin IP, --max-time for the unroutable case.
  # Capture http_code via -w '%{http_code}' and write headers to a temp file
  # so we can check for the marker without messing up output parsing.
  local classification
  local tmpfile
  tmpfile=$(mktemp)
  local curl_exit=0
  local http_code
  http_code=$(curl -s \
    --resolve "${selftest_host}:80:${probe_ip}" \
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
      echo "rip-cage selftest: port 80 ENFORCED — router is on-path for HTTP"
      ;;
    BYPASSED)
      echo "ERROR: rip-cage selftest: port 80 BYPASSED — egress router is NOT on-path (silent fail-open detected)" >&2
      echo "ERROR: The iptables REDIRECT rule (port 80) may have silently no-op'd." >&2
      echo "ERROR: Likely cause: legacy x_tables interface absent on this kernel (6.18+) or iptables backend no-op." >&2
      echo "ERROR: Refusing to start cage in blocking posture with unenforceable firewall." >&2
      return 1
      ;;
    INCONCLUSIVE)
      echo "WARNING: rip-cage selftest: port 80 INCONCLUSIVE — probe result ambiguous; warn-and-proceed (cage starts)" >&2
      echo "WARNING: This may indicate a curl/sidecar anomaly. Monitor egress.log for unexpected traffic." >&2
      # Don't return here — also run the port-443 probe for completeness.
      ;;
    *)
      echo "WARNING: rip-cage selftest: port 80 unrecognized classification '$classification'; warn-and-proceed" >&2
      ;;
  esac

  # --- Port-443 on-path proof (F5 — rip-cage-ta1o.1 adversarial review) ---
  # Port 443 (HTTPS/TLS) is the dominant exfil path. A broken iptables REDIRECT
  # that drops the port-443 half while keeping port-80 would pass the port-80 probe.
  # Verify the router is also on-path for port 443 by sending a TLS-shaped connection
  # (with SNI=selftest.rip-cage.internal) and checking for the distinctive marker bytes
  # the router sends before closing (SELFTEST_TLS_MARKER from rip_cage_egress.py).
  #
  # Probe uses bash /dev/tcp or nc (both available in the image) pinned to probe_ip
  # via an iptables REDIRECT (which is what we're testing). The router sees the SNI,
  # recognises the selftest hostname, sends SELFTEST_TLS_MARKER, then closes.
  #
  # On bypass (REDIRECT missing): the connection to 192.0.2.1:443 goes to the
  # unroutable IP and times out — the marker is never received (BYPASSED).
  #
  # We use bash /dev/tcp for the probe (no dependency on nc). But /dev/tcp cannot
  # set a timeout; we use a subshell with `read -t`.
  local tls_probe_marker="rip-cage-selftest:443:on-path"
  local tls_probe_result=""
  local tls_classification

  # Attempt: open TCP to probe_ip:443 (REDIRECT will rewrite to 127.0.0.1:8080),
  # send a minimal TLS ClientHello-shaped payload with the selftest SNI, and read
  # the first line the router sends back.
  # We build a minimal TLS ClientHello bytes as a Python one-liner (python3 is in image).
  # The ClientHello includes SNI=selftest.rip-cage.internal so the router can extract it.
  local tls443_out tls443_exit
  tls443_out=""
  tls443_exit=0
  tls443_out=$(python3 -c "
import socket, struct, sys, time

HOST = '${probe_ip}'
PORT = 443
TIMEOUT = ${probe_timeout}
SNI = b'${selftest_host}'

# Build minimal TLS 1.0 ClientHello with SNI extension
# SNI extension
sni_name = SNI
sni_ext = (
    b'\\x00\\x00'  # extension type: SNI (0x0000)
    + struct.pack('!H', len(sni_name) + 5)  # extension data length
    + struct.pack('!H', len(sni_name) + 3)  # SNI list length
    + b'\\x00'  # name type: host_name
    + struct.pack('!H', len(sni_name))
    + sni_name
)
# Random (32 bytes)
random_bytes = b'\\x00' * 32
# ClientHello body
ch_body = (
    b'\\x03\\x03'  # TLS version 1.2
    + random_bytes
    + b'\\x00'  # session id length 0
    + b'\\x00\\x02'  # cipher suite length 2
    + b'\\xc0\\x2b'  # TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    + b'\\x01\\x00'  # compression methods: 1, null
    + struct.pack('!H', len(sni_ext) + 4)  # extensions total length
    + sni_ext
)
# Handshake header: type=ClientHello(1) + length(3)
hs = b'\\x01' + struct.pack('!I', len(ch_body))[1:] + ch_body
# TLS record: ContentType=Handshake(0x16) + TLS1.0(0x0301) + length
record = b'\\x16\\x03\\x01' + struct.pack('!H', len(hs)) + hs

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    s.connect((HOST, PORT))
    s.sendall(record)
    # Read first bytes the router sends back
    data = s.recv(256)
    s.close()
    sys.stdout.buffer.write(data)
except Exception as e:
    sys.stderr.write(str(e) + '\\n')
    sys.exit(1)
" 2>/dev/null) || tls443_exit=$?

  if echo "$tls443_out" | grep -q "$tls_probe_marker"; then
    tls_classification="ENFORCED"
  elif [[ $tls443_exit -ne 0 ]]; then
    # Connection failed (timeout / refused): could be bypass or transient error.
    # Classify as BYPASSED — a working router would have sent the marker.
    tls_classification="BYPASSED"
  elif [[ -z "$tls443_out" ]]; then
    # Connected but no bytes received — router may be in RST mode. Treat as INCONCLUSIVE.
    tls_classification="INCONCLUSIVE"
  else
    # Got bytes but not the marker — something else on path. BYPASSED.
    tls_classification="BYPASSED"
  fi

  case "$tls_classification" in
    ENFORCED)
      echo "rip-cage selftest: port 443 ENFORCED — router is on-path for HTTPS/TLS"
      ;;
    BYPASSED)
      echo "ERROR: rip-cage selftest: port 443 BYPASSED — egress router is NOT on-path for HTTPS (silent fail-open detected)" >&2
      echo "ERROR: The iptables REDIRECT rule (port 443) may have silently no-op'd." >&2
      echo "ERROR: Refusing to start cage in blocking posture with unenforceable firewall." >&2
      return 1
      ;;
    INCONCLUSIVE)
      echo "WARNING: rip-cage selftest: port 443 INCONCLUSIVE — probe result ambiguous; warn-and-proceed" >&2
      ;;
    *)
      echo "WARNING: rip-cage selftest: port 443 unrecognized classification '$tls_classification'; warn-and-proceed" >&2
      ;;
  esac

  # Both probes passed (or were inconclusive — never-false-alarm requirement).
  if [[ "$classification" == "ENFORCED" && "$tls_classification" == "ENFORCED" ]]; then
    echo "rip-cage selftest: ENFORCED — router is on-path for both port 80 and port 443"
  elif [[ "$classification" != "ENFORCED" || "$tls_classification" != "ENFORCED" ]]; then
    echo "WARNING: rip-cage selftest: one or both probes inconclusive; cage starts (warn-and-proceed)" >&2
  fi
  return 0
}

# When sourced (e.g., by tests), skip execution -- expose functions only.
[[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

set -euo pipefail

# Step 1: Apply iptables rules (idempotent -- check with -C before -A).
# REDIRECT: intercept TCP 80+443 from non-rip-proxy UIDs to :8080.
# rip-proxy's own re-originated traffic is excluded to prevent an infinite loop.
RIP_PROXY_UID=$(id -u rip-proxy)
if ! iptables -t nat -C OUTPUT -p tcp -m multiport --dports 443,80 \
     -m owner ! --uid-owner "$RIP_PROXY_UID" -j REDIRECT --to-port 8080 2>/dev/null; then
  iptables -t nat -A OUTPUT -p tcp -m multiport --dports 443,80 \
    -m owner ! --uid-owner "$RIP_PROXY_UID" -j REDIRECT --to-port 8080
fi

# Step 1a: Loop-prevention uid-exemptions for co-located mediators (ADR-026 D5).
# Each baked mediator has a dedicated uid stored at:
#   /etc/rip-cage/mediators/<name>/run_as_uid
# The mediator's already-allowed re-originated egress must not be re-REDIRECTed
# back into the router (infinite loop). We add an iptables OUTPUT RETURN rule
# per mediator uid — the same mechanism applied above to rip-proxy's own uid,
# but expressed as an ACCEPT/RETURN before the REDIRECT chain fires.
# The floor was enforced at the router before forwarding; this exemption does NOT
# widen the destination floor — it only stops looping on already-allowed traffic.
_MEDIATOR_REGISTRY_DIR=/etc/rip-cage/mediators
if [[ -d "$_MEDIATOR_REGISTRY_DIR" ]]; then
  for _med_uid_file in "${_MEDIATOR_REGISTRY_DIR}"/*/run_as_uid; do
    [[ -f "$_med_uid_file" ]] || continue
    _med_uid_name=$(cat "$_med_uid_file" 2>/dev/null || true)
    [[ -z "$_med_uid_name" ]] && continue
    # Resolve uid name to numeric uid. Skip silently if the user doesn't exist yet.
    _med_numeric_uid=$(id -u "$_med_uid_name" 2>/dev/null || true)
    [[ -z "$_med_numeric_uid" ]] && continue
    # Add RETURN rule for the mediator's uid before the REDIRECT rule fires.
    # This exempts the mediator's TCP 80+443 egress from being re-intercepted.
    # Flush-before-rebuild (mirrors TCP-22 idempotency discipline): delete any
    # existing RETURN rules for this uid first, then re-insert at position 1.
    # A plain -C check is NOT sufficient — it matches anywhere in the chain, so
    # on reload a REDIRECT could be appended between runs, leaving the RETURN
    # after the REDIRECT and silently re-enabling the loop.
    while iptables -t nat -D OUTPUT -p tcp -m multiport --dports 443,80 \
          -m owner --uid-owner "$_med_numeric_uid" -j RETURN 2>/dev/null; do :; done
    iptables -t nat -I OUTPUT 1 -p tcp -m multiport --dports 443,80 \
      -m owner --uid-owner "$_med_numeric_uid" -j RETURN
  done
fi
# DROP: block UDP port 443 (HTTP/3/QUIC) to force HTTP/2 fallback.
# Applies to all UIDs including rip-proxy. HTTP clients fall back to TCP automatically.
if ! iptables -C OUTPUT -p udp --dport 443 -j DROP 2>/dev/null; then
  iptables -A OUTPUT -p udp --dport 443 -j DROP
fi

# Step 1b: REDIRECT DNS (UDP+TCP port 53) to DNS resolver sidecar on :5300.
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

# Step 1c: TCP-22 IP allowlist (ADR-012 D8 evolved).
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

# Step 2: Start the SNI destination router as rip-proxy user.
# || true is REQUIRED on this line: pkill returns exit 1 when no process found
# (normal on first run). set -e would abort without it.
pkill -u rip-proxy python3 2>/dev/null || true

# Pre-create the router log so rip-proxy can write to it.
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

# Step 3: Wait for router to be ready (up to 10s).
# The SNI router accepts connections on :8080. Check the socket is in LISTEN state.
count=0
while [[ $count -lt 20 ]]; do
  # Check if :8080 is listening (0100007F = 127.0.0.1, 1F90 = 8080, 0A = LISTEN)
  if grep -qE '^\s*[0-9]+:\s+0100007F:1F90\s+[0-9A-F]+:[0-9A-F]+\s+0A' /proc/net/tcp 2>/dev/null; then
    break
  fi
  sleep 0.5
  count=$((count + 1))
done
if [[ $count -ge 20 ]]; then
  echo "ERROR: rip-cage SNI router did not start within 10s" >&2
  exit 1
fi

# Step 4: EFFECT-based startup self-test (rip-cage-fft / rip-cage-ta1o.1).
# Verifies the router is actually ON-PATH by curling the reserved self-test
# endpoint over plain HTTP, pinned to 192.0.2.1 (RFC 5737 guaranteed-unroutable).
# The router handles the HTTP request locally (no upstream contact with 192.0.2.1).
# Must run AFTER the router-readiness gate (Step 3).
# Skips in observe mode and when egress is off.
# Refuses to start (exit 1) if router is not on-path in a blocking posture.
_run_startup_selftest /etc/rip-cage/egress-rules.yaml

# Step 5: Write firewall-env (no CA vars needed — pure router has no CA).
# The env file signals that egress is active (checked by test-egress-firewall.sh).
# CA-related env vars (NODE_EXTRA_CA_CERTS, SSL_CERT_FILE, etc.) are NOT set:
# the pure router does not intercept TLS, so no custom CA is needed or present.
cat > /etc/rip-cage/firewall-env <<'ENVEOF'
# rip-cage egress router active (pure destination router, no TLS MITM)
# No CA vars needed: TLS traffic passes through unmodified.
ENVEOF

# Step 6: Print mode-aware startup banner.
RULE_COUNT=$(/opt/rip-cage-proxy/bin/python -c "import yaml; d=yaml.safe_load(open('/etc/rip-cage/egress-rules.yaml')); print(len(d['rules']))")
_BANNER_MODE=$(_read_egress_mode /etc/rip-cage/egress-rules.yaml)
case "$_BANNER_MODE" in
  block)   echo "egress firewall active ($RULE_COUNT rules, block mode, pure destination router)" ;;
  observe) echo "egress firewall active ($RULE_COUNT rules, observe mode, pure destination router)" ;;
  *)       echo "egress firewall active ($RULE_COUNT rules, legacy (deny-list) mode, pure destination router)" ;;
esac
