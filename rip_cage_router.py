#!/usr/bin/env python3
"""
rip_cage_router.py — pure destination router for rip-cage egress enforcement.

Replaces mitmproxy transparent proxy (rip-cage-ta1o.1).

Architecture:
  - Reads SNI from TLS ClientHello (in the clear) OR Host header from plain HTTP.
  - Recovers original destination via SO_ORIGINAL_DST (iptables REDIRECT sets this).
  - Calls decide() from rip_cage_egress to allow/deny the DESTINATION.
  - ALLOW: splices the raw TCP stream unchanged (no TLS decryption, no modification).
  - DENY:  resets the TCP connection (RST) and logs to JSONL audit log.
  - Selftest: HTTP GET to selftest.rip-cage.internal returns the marker response
    (plain-text HTTP on port 80 only; HTTPS connections get RST after marker check).

Security properties:
  - No TLS decryption — upstream cert is never seen; privacy preserved.
  - No CA — no rip-cage CA keypair, no per-host leaf cert.
  - No method/path inspection — only the destination host matters.
  - Fail-closed: if rules load fails, all connections are reset.

Design note (ADR-005 D12 / rip-cage-ta1o.1):
  The router is FLOOR (safety infrastructure), not an optional tool.
  A concrete Python implementation baked into the image is correct per ADR-005 D12
  which governs optional/blessed tools, NOT the safety floor. The router does not
  appear in the tool manifest.

Run as: python3 /usr/local/lib/rip-cage/rip_cage_router.py
Listens: 127.0.0.1:8080 (iptables REDIRECTs TCP 80+443 here).
User: rip-proxy (avoids REDIRECT loop — rip-proxy traffic is excluded from REDIRECT).
"""

import errno
import json
import logging
import os
import select
import socket
import struct
import sys
import threading
import time
from pathlib import Path
from typing import Optional, Tuple

import yaml

# ---------------------------------------------------------------------------
# Path setup — allow running from either the image path or the repo root.
# ---------------------------------------------------------------------------
_THIS_DIR = Path(__file__).parent
sys.path.insert(0, str(_THIS_DIR))

from rip_cage_egress import (
    RULES_PATH,
    LOG_PATH,
    SELFTEST_HOSTNAME,
    SELFTEST_MARKER_HEADER,
    SELFTEST_MARKER_VALUE,
    SELFTEST_TLS_MARKER,
    DecisionResult,
    decide,
    _log_denial,
    _log_observe,
    handle_selftest_request,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8080
BUFFER_SIZE = 65536
CONNECT_TIMEOUT = 10   # seconds to connect to upstream
SPLICE_TIMEOUT = 300   # seconds of inactivity before closing a proxied connection

# SO_ORIGINAL_DST: recovers the pre-REDIRECT destination from the kernel.
# Linux-only: netfilter sets this on REDIRECT'd connections.
SO_ORIGINAL_DST = 80
SOL_IP = 0


# ---------------------------------------------------------------------------
# Rules loading (fail-closed)
# ---------------------------------------------------------------------------
def _load_rules() -> dict:
    """Load and parse egress-rules.yaml. Returns empty dict on error (fail-closed)."""
    try:
        data = yaml.safe_load(Path(RULES_PATH).read_text())
        if not isinstance(data, dict):
            logging.error("rip-cage router: rules file is not a YAML mapping — fail-closed")
            return None
        if "rules" not in data:
            logging.error("rip-cage router: rules file missing 'rules' key — fail-closed")
            return None
        return data
    except Exception as exc:
        logging.error("rip-cage router: failed to load rules: %s — fail-closed", exc)
        return None


# ---------------------------------------------------------------------------
# SO_ORIGINAL_DST: recover iptables-REDIRECT'd destination
# ---------------------------------------------------------------------------
def _get_original_dst(conn: socket.socket) -> Optional[Tuple[str, int]]:
    """Return (ip, port) of the original destination before iptables REDIRECT.

    Uses getsockopt(SOL_IP, SO_ORIGINAL_DST) which Linux netfilter sets on
    REDIRECT'd connections. Returns None if not available (non-Linux, or
    connection not REDIRECT'd).
    """
    try:
        # struct sockaddr_in: sin_family(2) + sin_port(2) + sin_addr(4) + pad(8)
        dst = conn.getsockopt(SOL_IP, SO_ORIGINAL_DST, 16)
        port = struct.unpack("!H", dst[2:4])[0]
        ip = socket.inet_ntoa(dst[4:8])
        return (ip, port)
    except (OSError, struct.error):
        return None


# ---------------------------------------------------------------------------
# SNI extraction from TLS ClientHello
# ---------------------------------------------------------------------------
def _extract_sni(data: bytes) -> Optional[str]:
    """Extract the SNI hostname from a TLS ClientHello record.

    Returns the SNI hostname string if found, or None.
    Does NOT decrypt or modify the data — reads the SNI extension only.
    """
    try:
        # TLS record: ContentType(1) + Version(2) + Length(2) + Handshake...
        if len(data) < 5:
            return None
        if data[0] != 0x16:  # ContentType 22 = Handshake
            return None
        record_len = struct.unpack("!H", data[3:5])[0]
        if len(data) < 5 + record_len:
            return None

        # Handshake header: HandshakeType(1) + Length(3)
        hs = data[5:]
        if len(hs) < 4:
            return None
        if hs[0] != 0x01:  # HandshakeType 1 = ClientHello
            return None

        # ClientHello: Version(2) + Random(32) + SessionIDLen(1) + ...
        pos = 4  # skip handshake header
        if pos + 34 > len(hs):
            return None
        pos += 34  # Version + Random

        # SessionID
        if pos >= len(hs):
            return None
        sid_len = hs[pos]
        pos += 1 + sid_len

        # CipherSuites
        if pos + 2 > len(hs):
            return None
        cs_len = struct.unpack("!H", hs[pos:pos+2])[0]
        pos += 2 + cs_len

        # CompressionMethods
        if pos >= len(hs):
            return None
        cm_len = hs[pos]
        pos += 1 + cm_len

        # Extensions
        if pos + 2 > len(hs):
            return None
        ext_total = struct.unpack("!H", hs[pos:pos+2])[0]
        pos += 2
        ext_end = pos + ext_total

        while pos + 4 <= ext_end and pos + 4 <= len(hs):
            ext_type = struct.unpack("!H", hs[pos:pos+2])[0]
            ext_len = struct.unpack("!H", hs[pos+2:pos+4])[0]
            pos += 4
            if ext_type == 0x0000:  # SNI extension
                # SNI: ListLen(2) + NameType(1) + NameLen(2) + HostName
                if pos + 5 <= len(hs):
                    name_type = hs[pos + 2]
                    if name_type == 0:  # host_name
                        name_len = struct.unpack("!H", hs[pos+3:pos+5])[0]
                        name_end = pos + 5 + name_len
                        if name_end <= len(hs):
                            return hs[pos+5:name_end].decode("ascii", errors="replace")
                return None
            pos += ext_len

        return None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Host header extraction from plain HTTP
# ---------------------------------------------------------------------------
def _extract_http_host(data: bytes) -> Optional[str]:
    """Extract the Host header value from a plain-HTTP request.

    Handles three forms:
      - "example.com"       → "example.com"
      - "example.com:80"    → "example.com"
      - "[::1]"             → "[::1]"   (IPv6 literal, no port)
      - "[::1]:80"          → "[::1]"   (IPv6 literal with port — strip port)
    """
    try:
        text = data.decode("latin-1", errors="replace")
        for line in text.split("\r\n")[1:]:
            if line.lower().startswith("host:"):
                host = line[5:].strip()
                if host.startswith("["):
                    # IPv6 literal: "[addr]" or "[addr]:port"
                    # Strip the port after the closing bracket.
                    bracket_end = host.find("]")
                    if bracket_end != -1:
                        host = host[:bracket_end + 1]  # keep "[addr]", drop ":port"
                elif ":" in host:
                    # IPv4 or hostname with port: strip the trailing ":port"
                    host = host.rsplit(":", 1)[0]
                return host
        return None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# TCP splice (bidirectional raw stream forward)
# ---------------------------------------------------------------------------
def _splice(client: socket.socket, upstream: socket.socket, first_chunk: bytes) -> None:
    """Bidirectionally splice raw TCP bytes between client and upstream.

    Sends `first_chunk` to upstream first (the already-read ClientHello or
    HTTP request), then runs a select() loop until either side closes.
    """
    try:
        # Send the buffered first chunk upstream
        upstream.sendall(first_chunk)
    except OSError:
        return

    socks = [client, upstream]
    while True:
        try:
            readable, _, exceptional = select.select(socks, [], socks, SPLICE_TIMEOUT)
        except (OSError, ValueError):
            break
        if exceptional:
            break
        if not readable:
            break  # timeout
        for s in readable:
            other = upstream if s is client else client
            try:
                data = s.recv(BUFFER_SIZE)
                if not data:
                    return
                other.sendall(data)
            except OSError:
                return


# ---------------------------------------------------------------------------
# Selftest HTTP response builder
# ---------------------------------------------------------------------------
_SELFTEST_BODY = b"rip-cage selftest: router is on-path"


def _send_selftest_response(conn: socket.socket) -> None:
    """Send a minimal HTTP/1.1 200 response with the selftest marker header."""
    headers = (
        f"HTTP/1.1 200 OK\r\n"
        f"Content-Length: {len(_SELFTEST_BODY)}\r\n"
        f"{SELFTEST_MARKER_HEADER}: {SELFTEST_MARKER_VALUE}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    )
    try:
        conn.sendall(headers.encode() + _SELFTEST_BODY)
    except OSError:
        pass


def _send_tls_selftest_marker(conn: socket.socket) -> None:
    """Send a distinctive plaintext marker for port-443 on-path verification.

    A pure SNI router cannot complete a TLS handshake, so the port-443 selftest
    probe reads this raw byte sequence instead of an HTTP response. The marker
    is not valid TLS; it is a short plaintext string that the startup selftest
    can detect with `nc` (netcat) or similar without a TLS library.

    The startup selftest (init-firewall.sh _run_startup_selftest) connects to
    port 443 via nc/bash, reads the first bytes, and checks for SELFTEST_TLS_MARKER.
    On bypass (no REDIRECT), the connection goes to 192.0.2.1 (unroutable) and
    times out — the marker is never received, confirming BYPASSED.
    """
    try:
        conn.sendall(SELFTEST_TLS_MARKER)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Connection handler
# ---------------------------------------------------------------------------
def _handle_connection(conn: socket.socket, addr: Tuple, rules_doc: Optional[dict]) -> None:
    """Handle one incoming (REDIRECT'd) TCP connection."""
    try:
        # Recover original destination
        orig_dst = _get_original_dst(conn)
        orig_port = orig_dst[1] if orig_dst else 0

        # Peek at the first bytes to determine protocol and extract host
        conn.settimeout(5.0)
        try:
            first_chunk = conn.recv(BUFFER_SIZE)
        except (socket.timeout, OSError):
            return
        if not first_chunk:
            return

        conn.settimeout(None)

        # Determine if TLS (port 443) or plain HTTP (port 80)
        is_tls = (orig_port == 443) or (first_chunk[0:1] == b"\x16")

        if is_tls:
            host = _extract_sni(first_chunk)
        else:
            host = _extract_http_host(first_chunk)

        # Fallback: use original destination IP as host (no SNI / no Host header)
        if not host and orig_dst:
            host = orig_dst[0]

        # Selftest: detect on-path for both port 80 (HTTP) and port 443 (TLS).
        if host and host.lower() == SELFTEST_HOSTNAME.lower():
            if not is_tls:
                # Port 80: return full HTTP marker response (readable by curl).
                _send_selftest_response(conn)
            else:
                # Port 443: cannot complete a TLS handshake. Send a distinctive
                # plaintext marker before closing so the startup selftest probe
                # can confirm the router is on-path for port 443 as well (F5).
                _send_tls_selftest_marker(conn)
            return

        # Decide: allow or deny
        result = decide(host or "", "", "", rules_doc)

        if result.action == "deny":
            _log_denial(host or "", result)
            # TCP RST — drop the connection
            try:
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                struct.pack("ii", 1, 0))
            except OSError:
                pass
            return

        if result.action == "would-block":
            _log_observe(host or "", result)
            # Observe mode: fall through to forward

        # Allow: connect to original destination and splice
        if not orig_dst:
            # No original destination available — cannot forward
            logging.warning("rip-cage router: no SO_ORIGINAL_DST for %s", addr)
            return

        upstream_ip, upstream_port = orig_dst
        try:
            upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            upstream.settimeout(CONNECT_TIMEOUT)
            upstream.connect((upstream_ip, upstream_port))
            upstream.settimeout(None)
        except OSError as exc:
            logging.debug("rip-cage router: upstream connect failed %s:%d: %s",
                         upstream_ip, upstream_port, exc)
            return

        try:
            _splice(conn, upstream, first_chunk)
        finally:
            try:
                upstream.close()
            except OSError:
                pass

    except Exception as exc:
        logging.debug("rip-cage router: handler error: %s", exc)
    finally:
        try:
            conn.close()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Main server loop
# ---------------------------------------------------------------------------
def _main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s rip-cage-router %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    # Load rules (fail-closed: if None, all connections will be denied)
    rules_doc = _load_rules()
    if rules_doc is None:
        logging.error("rip-cage router: rules load failed — all connections will be denied")

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(128)

    logging.info("rip-cage router listening on %s:%d", LISTEN_HOST, LISTEN_PORT)

    while True:
        try:
            conn, addr = server.accept()
        except OSError as exc:
            logging.error("rip-cage router: accept error: %s", exc)
            time.sleep(0.1)
            continue

        t = threading.Thread(
            target=_handle_connection,
            args=(conn, addr, rules_doc),
            daemon=True,
        )
        t.start()


if __name__ == "__main__":
    _main()
