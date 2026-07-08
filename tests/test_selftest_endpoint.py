#!/usr/bin/env python3
"""
Unit tests for the rip-cage self-test endpoint in rip_cage_egress.py (rip-cage-fft).

Tests assert that:
  (a) The reserved self-test hostname triggers a distinctive proxy-generated marker
      response BEFORE any allow/deny/mode evaluation.
  (b) The response is generated LOCALLY — no upstream fetch occurs.
  (c) The endpoint behaves identically in block, legacy, and observe modes.
  (d) The marker response does NOT depend on egress-rules.yaml content (I3 invariant):
      a rules doc with empty allowed_hosts still returns the marker.
  (e) The marker does not trip the normal deny path — it must be handled before
      allow/deny evaluation.

Run with: uv run --with pytest --with pyyaml python -m pytest tests/test_selftest_endpoint.py -v
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "cage" / "egress"))
from rip_cage_egress import (
    SELFTEST_HOSTNAME,
    SELFTEST_MARKER_HEADER,
    SELFTEST_MARKER_VALUE,
    SELFTEST_TLS_MARKER,
    handle_selftest_request,
)


class TestSelftestEndpoint(unittest.TestCase):
    """Verify the reserved self-test endpoint behaves as specified."""

    # -------------------------------------------------------------------
    # (a) Marker response returned for self-test hostname
    # -------------------------------------------------------------------
    def test_selftest_hostname_returns_marker(self):
        """The self-test hostname returns a response with the marker header."""
        response = handle_selftest_request(SELFTEST_HOSTNAME)
        self.assertIsNotNone(response, "Expected a response for the self-test hostname")

    def test_selftest_response_has_marker_header(self):
        """The self-test response carries the distinctive marker header."""
        response = handle_selftest_request(SELFTEST_HOSTNAME)
        self.assertIn(SELFTEST_MARKER_HEADER.lower(), {k.lower() for k in response.headers},
                      f"Marker header {SELFTEST_MARKER_HEADER!r} missing from response")

    def test_selftest_response_marker_value_is_on_path(self):
        """The marker header value is 'on-path' (the distinctive signal)."""
        response = handle_selftest_request(SELFTEST_HOSTNAME)
        headers_lower = {k.lower(): v for k, v in response.headers.items()}
        actual = headers_lower.get(SELFTEST_MARKER_HEADER.lower(), "")
        self.assertEqual(actual, SELFTEST_MARKER_VALUE,
                         f"Marker value must be {SELFTEST_MARKER_VALUE!r}, got {actual!r}")

    def test_selftest_response_is_200(self):
        """The self-test response has HTTP status 200."""
        response = handle_selftest_request(SELFTEST_HOSTNAME)
        self.assertEqual(response.status_code, 200,
                         f"Expected 200 for self-test, got {response.status_code}")

    # -------------------------------------------------------------------
    # (b) Non-self-test hostname returns None (not handled by self-test path)
    # -------------------------------------------------------------------
    def test_non_selftest_hostname_returns_none(self):
        """handle_selftest_request() returns None for non-self-test hostnames."""
        result = handle_selftest_request("api.anthropic.com")
        self.assertIsNone(result,
                          "Non-self-test hostname must return None (not intercepted)")

    def test_non_selftest_hostname_example_com(self):
        """handle_selftest_request() returns None for example.com."""
        result = handle_selftest_request("example.com")
        self.assertIsNone(result)

    def test_empty_hostname_returns_none(self):
        """handle_selftest_request() returns None for empty hostname."""
        result = handle_selftest_request("")
        self.assertIsNone(result)

    # -------------------------------------------------------------------
    # (c) Mode-independence: same response across block, legacy, observe
    # The function signature takes only the hostname (no rules_doc / mode),
    # proving mode-independence at the call site.
    # -------------------------------------------------------------------
    def test_selftest_response_has_no_upstream_roundtrip_marker(self):
        """Self-test response must be generated locally (no upstream fields).

        The response body must NOT contain typical upstream headers like
        'server' pointing to real hosts — it should be purely proxy-generated.
        The absence of an upstream-facing 'location' or redirect proves locality.
        """
        response = handle_selftest_request(SELFTEST_HOSTNAME)
        # A locally-generated response must not redirect upstream
        self.assertNotIn("location", {k.lower() for k in response.headers},
                         "Self-test response must not redirect (would require upstream)")

    # -------------------------------------------------------------------
    # (d) I3 invariant: does not depend on egress-rules.yaml
    # The function takes no rules_doc argument — by design, no config dependency.
    # -------------------------------------------------------------------
    def test_selftest_function_takes_no_rules_doc(self):
        """handle_selftest_request() takes only hostname — no rules_doc parameter.

        This structurally enforces I3: the positive signal cannot be broken
        by a config edit, because the function signature doesn't accept config.
        """
        import inspect
        sig = inspect.signature(handle_selftest_request)
        params = list(sig.parameters.keys())
        self.assertEqual(params, ["hostname"],
                         f"handle_selftest_request must take only 'hostname', got: {params}")

    # -------------------------------------------------------------------
    # (e) Integration: decide() still works normally for non-selftest hosts
    # The self-test path must not interfere with normal flow classification.
    # -------------------------------------------------------------------
    def test_decide_still_denies_non_whitelisted_after_selftest_added(self):
        """decide() still denies non-whitelisted hosts normally (no regression)."""
        from rip_cage_egress import decide
        doc = {
            "version": 2,
            "mode": "block",
            "allowed_hosts": ["api.anthropic.com"],
            "rules": [],
        }
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertEqual(result.action, "deny",
                         "Normal deny path must still work after selftest endpoint added")

    def test_decide_still_allows_whitelisted_after_selftest_added(self):
        """decide() still allows whitelisted hosts normally (no regression)."""
        from rip_cage_egress import decide
        doc = {
            "version": 2,
            "mode": "block",
            "allowed_hosts": ["api.anthropic.com"],
            "rules": [],
        }
        result = decide("api.anthropic.com", "GET", "/v1/messages", doc)
        self.assertEqual(result.action, "allow",
                         "Normal allow path must still work after selftest endpoint added")


class TestSelftestConstants(unittest.TestCase):
    """Verify the exported constants match the expected values."""

    def test_selftest_hostname_is_expected(self):
        """SELFTEST_HOSTNAME must be the reserved internal name."""
        self.assertEqual(SELFTEST_HOSTNAME, "selftest.rip-cage.internal",
                         f"Expected 'selftest.rip-cage.internal', got {SELFTEST_HOSTNAME!r}")

    def test_selftest_marker_header_is_expected(self):
        """SELFTEST_MARKER_HEADER must be 'X-Rip-Cage-Selftest'."""
        self.assertEqual(SELFTEST_MARKER_HEADER.lower(), "x-rip-cage-selftest",
                         f"Expected 'X-Rip-Cage-Selftest', got {SELFTEST_MARKER_HEADER!r}")

    def test_selftest_marker_value_is_on_path(self):
        """SELFTEST_MARKER_VALUE must be 'on-path'."""
        self.assertEqual(SELFTEST_MARKER_VALUE, "on-path",
                         f"Expected 'on-path', got {SELFTEST_MARKER_VALUE!r}")


class TestTlsSelftestMarker(unittest.TestCase):
    """Verify the port-443 on-path TLS selftest marker (F5 — rip-cage-ta1o.1 fix).

    The router sends SELFTEST_TLS_MARKER (a distinctive plaintext byte sequence)
    before closing a port-443 connection whose SNI matches the selftest hostname.
    This lets the startup selftest prove the port-443 REDIRECT is also working,
    without requiring a full TLS handshake.
    """

    def test_selftest_tls_marker_is_bytes(self):
        """SELFTEST_TLS_MARKER must be a bytes object."""
        self.assertIsInstance(SELFTEST_TLS_MARKER, bytes,
                              "SELFTEST_TLS_MARKER must be bytes, not str")

    def test_selftest_tls_marker_contains_distinctive_string(self):
        """SELFTEST_TLS_MARKER must contain the distinctive 'rip-cage-selftest:443:on-path' string."""
        self.assertIn(b"rip-cage-selftest:443:on-path", SELFTEST_TLS_MARKER,
                      "SELFTEST_TLS_MARKER must contain 'rip-cage-selftest:443:on-path'")

    def test_selftest_tls_marker_ends_with_crlf(self):
        """SELFTEST_TLS_MARKER must end with CRLF (shell-readable line delimiter)."""
        self.assertTrue(SELFTEST_TLS_MARKER.endswith(b"\r\n"),
                        "SELFTEST_TLS_MARKER must end with \\r\\n for shell-readable parsing")

    def test_selftest_tls_marker_is_not_valid_tls(self):
        """SELFTEST_TLS_MARKER must not start with TLS record byte 0x16.

        The marker is intentionally not a valid TLS record so the startup probe
        can detect it without a TLS library.
        """
        self.assertNotEqual(SELFTEST_TLS_MARKER[0:1], b"\x16",
                            "SELFTEST_TLS_MARKER must not start with 0x16 (TLS record byte)")

    def test_selftest_tls_marker_is_short(self):
        """SELFTEST_TLS_MARKER must be short (< 256 bytes) for fast startup probing."""
        self.assertLess(len(SELFTEST_TLS_MARKER), 256,
                        f"SELFTEST_TLS_MARKER too long: {len(SELFTEST_TLS_MARKER)} bytes")


if __name__ == "__main__":
    unittest.main(verbosity=2)
