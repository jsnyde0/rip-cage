#!/usr/bin/env python3
"""
Unit/integration tests for the DNS forward-to-specialist seam (rip-cage-ta1o.2).

Tests the configurable upstream resolver: when network.dns.forward_to is set
in the rules doc, clean queries forward to that address rather than the
hardcoded 8.8.8.8.

Run with:
  uv run --with "pytest,pyyaml,dnspython" pytest tests/test_dns_seam.py -q

Acceptance criteria covered:
  (a) Default behavior (no forward_to in rules doc): clean query resolves using
      the default upstream (_UPSTREAM_DNS = 8.8.8.8). Confirmed by checking
      that no forward_to override is applied.
  (b) When forward_to is set (host-only format, e.g. "192.0.2.1"), clean
      queries are sent to that address, NOT to 8.8.8.8.
  (c) When forward_to is set with a port (host:port format, e.g. "192.0.2.1:5353"),
      queries are sent to the configured host:port.
  (d) Built-in heuristic still fires BEFORE forwarding: a query that triggers
      the long-label heuristic is denied even when forward_to is set.
  (e) No hardcoded specialist-product names in the module: forward_to is a
      bare address, not a named product.
"""
import socket
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent.parent))
from rip_cage_dns import (
    DNS_LABEL_LENGTH_THRESHOLD,
    dns_decide,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _block_doc(allowed_hosts, forward_to=None):
    """Build a rules doc with mode=block, optionally with dns_forward_to."""
    doc = {
        "version": 2,
        "mode": "block",
        "allowed_hosts": allowed_hosts,
        "rules": [],
    }
    if forward_to is not None:
        doc["dns_forward_to"] = forward_to
    return doc


def _fresh_state():
    return {}


# ---------------------------------------------------------------------------
# Import the network-server section (only available when dnspython is installed)
# ---------------------------------------------------------------------------
try:
    import dns.message
    import dns.name
    import dns.rdatatype
    import dns.rcode
    import rip_cage_dns as _dns_module

    _HAS_DNSPYTHON = True
except ImportError:
    _HAS_DNSPYTHON = False


# ---------------------------------------------------------------------------
# (a) Pure-function: dns_decide() is unaffected by dns_forward_to presence
# ---------------------------------------------------------------------------
class TestDnsDecideUnchanged(unittest.TestCase):
    """The built-in heuristic (dns_decide) is unaffected by dns_forward_to."""

    def test_clean_query_still_allow_with_forward_to(self):
        """Clean query returns allow even when rules doc has dns_forward_to set."""
        doc = _block_doc(["github.com"], forward_to="192.0.2.1")
        result = dns_decide("api.example.com", doc, _fresh_state())
        self.assertEqual(result.action, "allow",
                         "Clean query must still be allowed when forward_to is set")

    def test_long_label_still_denied_with_forward_to(self):
        """Long-label heuristic still denies even when dns_forward_to is configured."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = _block_doc([], forward_to="192.0.2.1")
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "deny",
                         "Long-label heuristic must still fire regardless of forward_to")

    def test_whitelisted_apex_passes_with_forward_to(self):
        """Whitelisted apex passes even with forward_to configured."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.github.com"
        doc = _block_doc(["github.com"], forward_to="192.0.2.1")
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "allow",
                         "Whitelisted apex must pass unconditionally with forward_to")

    def test_no_hardcoded_product_names_in_module(self):
        """
        ADR-005 D12: the module must not reference named DNS specialist products
        (NextDNS, Umbrella, dnsdist, Zeek) as defaults or special-cased values.
        The seam is a bare address, not a blessed product name.
        """
        module_path = Path(__file__).parent.parent / "rip_cage_dns.py"
        source = module_path.read_text()
        # These are the specialist product names that must NOT be hardcoded
        forbidden = ["nextdns", "umbrella", "dnsdist", "zeek", "cisco", "opendns"]
        found = [p for p in forbidden if p.lower() in source.lower()]
        self.assertEqual(found, [],
                         f"ADR-005 D12: specialist product name(s) found in source: {found}")


# ---------------------------------------------------------------------------
# (b/c) Network-layer: forward_to is used as the upstream resolver address
# ---------------------------------------------------------------------------
@unittest.skipUnless(_HAS_DNSPYTHON, "dnspython not installed")
class TestForwardToSeam(unittest.TestCase):
    """
    Verify that _forward_query routes to the configured dns_forward_to address
    rather than the hardcoded 8.8.8.8 when the rules doc has dns_forward_to set.

    We use a mock local UDP listener as the "specialist" upstream to avoid
    any external network dependency.
    """

    def _make_a_query(self, qname="api.example.com"):
        """Build a minimal DNS A query datagram for qname."""
        msg = dns.message.make_query(qname, dns.rdatatype.A)
        return msg.to_wire()

    def _make_noerror_response(self, request_wire):
        """Build a minimal NOERROR response to the given request wire."""
        request = dns.message.from_wire(request_wire)
        response = dns.message.make_response(request)
        response.set_rcode(dns.rcode.NOERROR)
        return response.to_wire()

    def setUp(self):
        """Start a local UDP listener that records queries and returns NOERROR."""
        self.received_queries = []
        self._stop_event = threading.Event()
        self._server_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server_sock.bind(("127.0.0.1", 0))  # OS-assigned port
        self._server_addr, self._server_port = self._server_sock.getsockname()
        self._server_sock.settimeout(0.5)

        def _serve():
            while not self._stop_event.is_set():
                try:
                    data, addr = self._server_sock.recvfrom(512)
                    self.received_queries.append(data)
                    resp = self._make_noerror_response(data)
                    self._server_sock.sendto(resp, addr)
                except socket.timeout:
                    continue
                except Exception:
                    break

        self._thread = threading.Thread(target=_serve, daemon=True)
        self._thread.start()

    def tearDown(self):
        self._stop_event.set()
        self._server_sock.close()
        self._thread.join(timeout=2)

    def test_forward_to_host_only_routes_to_configured_address(self):
        """
        When dns_forward_to is a bare host (e.g. "127.0.0.1"), clean queries
        must be forwarded to that host on the default port 53.

        We verify by patching _UPSTREAM_DNS/_UPSTREAM_PORT in the module and
        checking that _handle_dns_query calls dns.query.udp with the configured
        address.
        """
        query_wire = self._make_a_query("api.example.com")
        rules_doc = _block_doc(["github.com"], forward_to=self._server_addr)

        # Patch the _forward_query function to verify which upstream was called
        forwarded_to = []

        original_forward = _dns_module._forward_query

        def _recording_forward(request, upstream_host, upstream_port):
            forwarded_to.append((upstream_host, upstream_port))
            return original_forward(request, upstream_host, upstream_port)

        with mock.patch.object(_dns_module, "_forward_query",
                                side_effect=_recording_forward):
            # Use a real clean query and a rules doc with forward_to set
            _dns_module._handle_dns_query(query_wire, rules_doc)

        self.assertEqual(len(forwarded_to), 1,
                         "Expected exactly one forward call")
        host, port = forwarded_to[0]
        self.assertEqual(host, self._server_addr,
                         f"Expected forward to {self._server_addr}, got: {host}")
        self.assertEqual(port, 53,
                         "Default port must be 53 when forward_to has no port component")

    def test_forward_to_host_port_routes_to_configured_address_and_port(self):
        """
        When dns_forward_to is host:port (e.g. "127.0.0.1:5353"), clean queries
        must be forwarded to that exact host:port.
        """
        forward_to_str = f"{self._server_addr}:{self._server_port}"
        query_wire = self._make_a_query("api.example.com")
        rules_doc = _block_doc(["github.com"], forward_to=forward_to_str)

        forwarded_to = []
        original_forward = _dns_module._forward_query

        def _recording_forward(request, upstream_host, upstream_port):
            forwarded_to.append((upstream_host, upstream_port))
            return original_forward(request, upstream_host, upstream_port)

        with mock.patch.object(_dns_module, "_forward_query",
                                side_effect=_recording_forward):
            _dns_module._handle_dns_query(query_wire, rules_doc)

        self.assertEqual(len(forwarded_to), 1,
                         "Expected exactly one forward call")
        host, port = forwarded_to[0]
        self.assertEqual(host, self._server_addr,
                         f"Expected forward to {self._server_addr}, got: {host}")
        self.assertEqual(port, self._server_port,
                         f"Expected port {self._server_port}, got: {port}")

    def test_no_forward_to_uses_default_upstream(self):
        """
        When dns_forward_to is absent from the rules doc, _handle_dns_query
        forwards to the module-default upstream (_UPSTREAM_DNS / _UPSTREAM_PORT).
        """
        query_wire = self._make_a_query("api.example.com")
        rules_doc = _block_doc(["github.com"])  # No forward_to

        forwarded_to = []
        original_forward = _dns_module._forward_query

        def _recording_forward(request, upstream_host, upstream_port):
            forwarded_to.append((upstream_host, upstream_port))
            # Don't actually call the real Google DNS — just record and return
            # a NOERROR response
            response = dns.message.make_response(request)
            response.set_rcode(dns.rcode.NOERROR)
            return response

        with mock.patch.object(_dns_module, "_forward_query",
                                side_effect=_recording_forward):
            _dns_module._handle_dns_query(query_wire, rules_doc)

        self.assertEqual(len(forwarded_to), 1)
        host, port = forwarded_to[0]
        self.assertEqual(host, _dns_module._UPSTREAM_DNS,
                         f"No forward_to: expected default {_dns_module._UPSTREAM_DNS}, got {host}")
        self.assertEqual(port, _dns_module._UPSTREAM_PORT,
                         f"No forward_to: expected default port {_dns_module._UPSTREAM_PORT}, got {port}")

    def test_heuristic_fires_before_forward_no_forward_called_on_deny(self):
        """
        When the heuristic denies a query (long label), _forward_query must NOT
        be called — the query is refused before any forwarding happens.
        """
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        query_wire = self._make_a_query(f"{long_label}.attacker.com")
        rules_doc = _block_doc([], forward_to="127.0.0.1")

        forwarded_to = []

        def _recording_forward(request, upstream_host, upstream_port):
            forwarded_to.append((upstream_host, upstream_port))
            response = dns.message.make_response(request)
            response.set_rcode(dns.rcode.NOERROR)
            return response

        with mock.patch.object(_dns_module, "_forward_query",
                                side_effect=_recording_forward):
            resp_wire = _dns_module._handle_dns_query(query_wire, rules_doc)

        self.assertEqual(forwarded_to, [],
                         "Forward must not be called when heuristic denies the query")
        # Verify the response is REFUSED
        resp = dns.message.from_wire(resp_wire)
        self.assertEqual(resp.rcode(), dns.rcode.REFUSED,
                         "Denied query must return REFUSED, not NOERROR")


# ---------------------------------------------------------------------------
# (e) rc schema: dns_forward_to emitted in rules YAML when set
# ---------------------------------------------------------------------------
class TestSidecarReadsDnsForwardTo(unittest.TestCase):
    """
    Verify the sidecar reads dns_forward_to from the rules doc (the value the
    generator emits) and uses it as the forward upstream.

    The rc -> egress-rules.yaml *generation* path — that _generate_egress_rules_file
    emits `dns_forward_to:` iff network.dns.forward_to is set — is covered by the
    shell test test-egress-rules-gen.sh G13a/G13b (rc is bash; tested there, not here).
    """

    def test_dns_forward_to_field_read_from_rules_doc(self):
        """
        The sidecar reads dns_forward_to from the rules doc correctly.
        A rules doc with dns_forward_to set must expose it for _handle_dns_query.
        """
        if not _HAS_DNSPYTHON:
            self.skipTest("dnspython not installed")

        # When forward_to is set and clean query arrives, the module must use it.
        # We verify by patching _forward_query — the test is that it's called
        # with the configured address (127.0.0.1) not the hardcoded default.
        query_wire = dns.message.make_query(
            "api.example.com", dns.rdatatype.A
        ).to_wire()
        rules_doc = _block_doc(["github.com"], forward_to="127.0.0.1:15353")

        forwarded_to = []
        original_forward = _dns_module._forward_query

        def _recording_forward(request, upstream_host, upstream_port):
            forwarded_to.append((upstream_host, upstream_port))
            response = dns.message.make_response(request)
            response.set_rcode(dns.rcode.NOERROR)
            return response

        with mock.patch.object(_dns_module, "_forward_query",
                                side_effect=_recording_forward):
            _dns_module._handle_dns_query(query_wire, rules_doc)

        self.assertEqual(len(forwarded_to), 1)
        host, port = forwarded_to[0]
        self.assertEqual(host, "127.0.0.1")
        self.assertEqual(port, 15353)


if __name__ == "__main__":
    unittest.main(verbosity=2)
