#!/usr/bin/env python3
"""
Unit tests for rip_cage_egress.py — pure destination router (rip-cage-ta1o.1).

Tests are structured around the pure `decide()` function which is testable
without proxy imports. Each test covers one acceptance criterion from the bead.

Run with: uv run --with pytest,pyyaml python -m pytest tests/test_egress_proxy.py -v
       or: uv run --with pyyaml python tests/test_egress_proxy.py

Acceptance criteria covered:
  (a) block mode denies non-whitelisted host
  (b) block mode allows whitelisted host
  (c) IOC-floor host denied even if in allowed_hosts
  (d) observe mode lets a would-be-denied request THROUGH but logs would-have-blocked
  (e) legacy (no mode) reproduces denylist-only behavior unchanged
  (f) denial carries all six structured fields with correct names:
      pattern, target, why, fix_command, config_file, config_path
  (g) method symmetry — POST to allowed host is identical to GET (no write-gate axis)

Removed from this file (rip-cage-ta1o.1):
  - TestWritableHostsGating: method-asymmetry / writable_hosts write-gate is DELETED.
    POST to an allowlisted host behaves identically to GET. See TestMethodSymmetry.
"""
import socket
import struct
import sys
import threading
import time
import unittest
import unittest.mock
from pathlib import Path

# Import the module under test. The pure decide() function is importable
# without a live proxy. pyyaml must be installed (uv run --with pyyaml).
try:
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from rip_cage_egress import decide, DecisionResult, STRUCTURED_FIELD_NAMES
    import rip_cage_router
    from rip_cage_router import (
        _extract_http_host,
        _resolve_upstream,
        _handle_connection,
        _connect_via_mediator,
    )
except ImportError as e:
    # Provide a helpful message if the import fails for a different reason
    print(f"Import error: {e}", file=sys.stderr)
    raise


# ---------------------------------------------------------------------------
# Helpers: build minimal rules-doc dicts for each posture
# ---------------------------------------------------------------------------

def _block_doc(allowed_hosts, ioc_rules=None):
    """Build a rules doc with mode=block."""
    return {
        "version": 2,
        "mode": "block",
        "allowed_hosts": allowed_hosts,
        "rules": ioc_rules or [],
    }


def _observe_doc(allowed_hosts, ioc_rules=None):
    """Build a rules doc with mode=observe."""
    return {
        "version": 2,
        "mode": "observe",
        "allowed_hosts": allowed_hosts,
        "rules": ioc_rules or [],
    }


def _legacy_doc(deny_rules):
    """Build a legacy rules doc (no mode key — denylist-only behavior)."""
    return {
        "version": 1,
        "rules": deny_rules,
    }


# A minimal IOC rule that denies webhook.site
IOC_WEBHOOK_SITE = {
    "id": "webhook-site",
    "deny": True,
    "match": {"host": "webhook.site"},
    "reason": "webhook.site is an OAST/exfiltration service",
}


# ---------------------------------------------------------------------------
# (a) block mode denies non-whitelisted host
# ---------------------------------------------------------------------------
class TestBlockModeDefaultDeny(unittest.TestCase):
    def test_unlisted_host_is_denied(self):
        """Block mode: a host NOT in allowed_hosts must be denied."""
        doc = _block_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertEqual(result.action, "deny",
                         f"Expected deny for unlisted host, got: {result.action}")

    def test_empty_allowed_list_denies_all(self):
        """Block mode with empty allowed_hosts: every host is denied."""
        doc = _block_doc(allowed_hosts=[])
        result = decide("api.github.com", "GET", "/", doc)
        self.assertEqual(result.action, "deny")

    def test_denial_reason_is_not_whitelisted(self):
        """Block mode denial reason should indicate host not in whitelist."""
        doc = _block_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertEqual(result.action, "deny")
        # why field should convey that the host isn't whitelisted
        self.assertIn("evil.example.com", result.why)


# ---------------------------------------------------------------------------
# (b) block mode allows whitelisted host
# ---------------------------------------------------------------------------
class TestBlockModeAllowsWhitelisted(unittest.TestCase):
    def test_exact_host_is_allowed(self):
        """Block mode: exact host in allowed_hosts must be allowed."""
        doc = _block_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("api.anthropic.com", "GET", "/v1/messages", doc)
        self.assertEqual(result.action, "allow",
                         f"Expected allow for whitelisted host, got: {result.action}")

    def test_subdomain_of_allowed_host_is_also_allowed(self):
        """Block mode: subdomains of an allowed host must also be allowed.

        Decision: allowed_hosts entries match the exact host AND its subdomains,
        mirroring host_suffix semantics. Baseline lists apex domains like
        'pypi.org' which needs to include 'files.pythonhosted.org' — but more
        importantly 'github.com' needs to cover 'api.github.com'. The design
        intent: adding 'github.com' to allowed_hosts covers all github.com subdomains.
        """
        doc = _block_doc(allowed_hosts=["github.com"])
        result = decide("api.github.com", "GET", "/", doc)
        self.assertEqual(result.action, "allow",
                         "Subdomain of allowed host should be allowed")

    def test_unrelated_host_with_similar_name_is_denied(self):
        """Block mode: a host that contains an allowed hostname as substring is denied."""
        doc = _block_doc(allowed_hosts=["github.com"])
        # 'evil-github.com' should NOT match 'github.com' — suffix-only, not substring
        result = decide("evil-github.com", "GET", "/", doc)
        self.assertEqual(result.action, "deny",
                         "Host containing allowed host as substring must still be denied")


# ---------------------------------------------------------------------------
# (c) IOC floor is non-overridable
# ---------------------------------------------------------------------------
class TestIocFloorNonOverridable(unittest.TestCase):
    def test_ioc_host_in_allowed_hosts_still_denied(self):
        """IOC denylist wins even when the host appears in allowed_hosts."""
        doc = _block_doc(
            allowed_hosts=["webhook.site", "api.anthropic.com"],
            ioc_rules=[IOC_WEBHOOK_SITE],
        )
        result = decide("webhook.site", "GET", "/", doc)
        self.assertEqual(result.action, "deny",
                         "IOC-listed host must be denied even if in allowed_hosts")

    def test_ioc_rule_id_in_denial(self):
        """IOC denial should reference the IOC rule id."""
        doc = _block_doc(
            allowed_hosts=["webhook.site"],
            ioc_rules=[IOC_WEBHOOK_SITE],
        )
        result = decide("webhook.site", "POST", "/path", doc)
        self.assertEqual(result.action, "deny")
        self.assertEqual(result.rule_id, "webhook-site")

    def test_non_ioc_host_in_allowed_is_still_allowed(self):
        """IOC denylist does not affect hosts that are only in allowed_hosts."""
        doc = _block_doc(
            allowed_hosts=["api.anthropic.com"],
            ioc_rules=[IOC_WEBHOOK_SITE],  # IOC rule only denies webhook.site
        )
        result = decide("api.anthropic.com", "GET", "/v1/messages", doc)
        self.assertEqual(result.action, "allow")

    def test_ioc_subdomain_also_denied(self):
        """IOC rule using host_suffix denies matching subdomains."""
        ioc_suffix_rule = {
            "id": "ngrok",
            "deny": True,
            "match": {"host_suffix": ".ngrok.io"},
            "reason": "ngrok tunnels",
        }
        doc = _block_doc(
            allowed_hosts=["foo.ngrok.io"],
            ioc_rules=[ioc_suffix_rule],
        )
        result = decide("foo.ngrok.io", "GET", "/", doc)
        self.assertEqual(result.action, "deny",
                         "IOC suffix rule must deny even host-in-allowed")


# ---------------------------------------------------------------------------
# (d) observe mode: logs would-have-blocked but lets request through
# ---------------------------------------------------------------------------
class TestObserveMode(unittest.TestCase):
    def test_observe_non_whitelisted_returns_would_block(self):
        """Observe mode: unlisted host returns action=would-block (not block)."""
        doc = _observe_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertEqual(result.action, "would-block",
                         f"Observe mode must return would-block not deny, got: {result.action}")

    def test_observe_whitelisted_returns_allow(self):
        """Observe mode: whitelisted host is allowed."""
        doc = _observe_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("api.anthropic.com", "GET", "/v1/messages", doc)
        self.assertEqual(result.action, "allow")

    def test_observe_ioc_host_returns_would_block(self):
        """Observe mode: IOC host is would-block (not full deny)."""
        doc = _observe_doc(
            allowed_hosts=["webhook.site"],
            ioc_rules=[IOC_WEBHOOK_SITE],
        )
        result = decide("webhook.site", "GET", "/", doc)
        self.assertEqual(result.action, "would-block",
                         "Observe mode on IOC host must return would-block")

    def test_observe_result_has_in_baseline_classification(self):
        """Observe mode result distinguishes in-baseline vs not-whitelisted."""
        # Whitelisted host should have in_allowed=True
        doc = _observe_doc(allowed_hosts=["api.anthropic.com"])
        result_allowed = decide("api.anthropic.com", "GET", "/", doc)
        self.assertTrue(result_allowed.in_allowed_hosts,
                        "Whitelisted host must have in_allowed_hosts=True")

        result_denied = decide("evil.example.com", "GET", "/", doc)
        self.assertFalse(result_denied.in_allowed_hosts,
                         "Non-whitelisted host must have in_allowed_hosts=False")


# ---------------------------------------------------------------------------
# (e) legacy mode (no mode key): denylist-only behavior unchanged
# ---------------------------------------------------------------------------
class TestLegacyMode(unittest.TestCase):
    def test_legacy_denies_ioc_host(self):
        """Legacy: IOC rule fires and denies matching host."""
        doc = _legacy_doc(deny_rules=[IOC_WEBHOOK_SITE])
        result = decide("webhook.site", "GET", "/", doc)
        self.assertEqual(result.action, "deny",
                         "Legacy mode must deny host matching a deny rule")

    def test_legacy_allows_non_ioc_host(self):
        """Legacy: host not in any deny rule is allowed (default-allow behavior)."""
        doc = _legacy_doc(deny_rules=[IOC_WEBHOOK_SITE])
        result = decide("api.github.com", "GET", "/", doc)
        self.assertEqual(result.action, "allow",
                         "Legacy mode must allow host not in any deny rule")

    def test_legacy_mode_detected_by_absent_mode_key(self):
        """Legacy: rules doc without 'mode' key triggers legacy behavior."""
        doc = {"version": 1, "rules": [IOC_WEBHOOK_SITE]}
        self.assertNotIn("mode", doc)  # sanity — no mode key
        result_denied = decide("webhook.site", "POST", "/", doc)
        result_allowed = decide("api.github.com", "GET", "/", doc)
        self.assertEqual(result_denied.action, "deny")
        self.assertEqual(result_allowed.action, "allow")

    def test_legacy_mode_null_mode_key_also_triggers_legacy(self):
        """Legacy: rules doc with mode=null also triggers legacy behavior."""
        doc = {"version": 2, "mode": None, "rules": [IOC_WEBHOOK_SITE], "allowed_hosts": []}
        result = decide("webhook.site", "GET", "/", doc)
        self.assertEqual(result.action, "deny",
                         "mode=null must trigger legacy denylist-only behavior")

    def test_legacy_does_not_default_deny(self):
        """Legacy: arbitrary host not in deny rules must be allowed (not default-denied)."""
        doc = _legacy_doc(deny_rules=[IOC_WEBHOOK_SITE])
        result = decide("completely.unknown.host.example", "GET", "/", doc)
        self.assertEqual(result.action, "allow",
                         "Legacy mode is default-allow, not default-deny")


# ---------------------------------------------------------------------------
# (f) structured fields on denial — all six must be present with correct names
# ---------------------------------------------------------------------------
class TestStructuredFields(unittest.TestCase):
    REQUIRED_FIELDS = {"pattern", "target", "why", "fix_command", "config_file", "config_path"}

    def test_structured_field_names_exported(self):
        """The module must export STRUCTURED_FIELD_NAMES with the exact required set."""
        self.assertEqual(set(STRUCTURED_FIELD_NAMES), self.REQUIRED_FIELDS,
                         f"STRUCTURED_FIELD_NAMES mismatch: {STRUCTURED_FIELD_NAMES}")

    def test_block_mode_denial_has_all_structured_fields(self):
        """Block mode denial: DecisionResult must have all six structured fields."""
        doc = _block_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertEqual(result.action, "deny")
        for field in self.REQUIRED_FIELDS:
            self.assertTrue(hasattr(result, field),
                            f"DecisionResult missing structured field: {field}")
            self.assertIsNotNone(getattr(result, field),
                                 f"Structured field {field!r} must not be None on denial")

    def test_ioc_denial_has_all_structured_fields(self):
        """IOC floor denial: DecisionResult must have all six structured fields."""
        doc = _block_doc(
            allowed_hosts=["webhook.site"],
            ioc_rules=[IOC_WEBHOOK_SITE],
        )
        result = decide("webhook.site", "POST", "/", doc)
        self.assertEqual(result.action, "deny")
        for field in self.REQUIRED_FIELDS:
            self.assertTrue(hasattr(result, field),
                            f"IOC denial missing structured field: {field}")

    def test_pattern_field_is_descriptive(self):
        """pattern field must convey what rule triggered the denial."""
        doc = _block_doc(allowed_hosts=[])
        result = decide("evil.example.com", "GET", "/", doc)
        # pattern should name the rule or match criterion
        self.assertIsInstance(result.pattern, str)
        self.assertGreater(len(result.pattern), 0)

    def test_target_field_contains_host(self):
        """target field must reference the request target (host)."""
        doc = _block_doc(allowed_hosts=[])
        result = decide("evil.example.com", "GET", "/path", doc)
        self.assertIn("evil.example.com", result.target)

    def test_fix_command_references_rc_allowlist(self):
        """fix_command must include 'rc allowlist' — the agent-actionable command."""
        doc = _block_doc(allowed_hosts=[])
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertIn("rc allowlist", result.fix_command,
                      f"fix_command must reference 'rc allowlist', got: {result.fix_command!r}")

    def test_config_file_references_rip_cage_yaml(self):
        """config_file must name .rip-cage.yaml."""
        doc = _block_doc(allowed_hosts=[])
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertIn(".rip-cage.yaml", result.config_file)

    def test_config_path_references_allowed_hosts(self):
        """config_path must point to network.allowed_hosts in the config."""
        doc = _block_doc(allowed_hosts=[])
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertIn("network.allowed_hosts", result.config_path)

    def test_observe_mode_would_block_also_has_structured_fields(self):
        """Observe mode would-block also has all six structured fields."""
        doc = _observe_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertEqual(result.action, "would-block")
        for field in self.REQUIRED_FIELDS:
            self.assertTrue(hasattr(result, field),
                            f"would-block result missing structured field: {field}")
            self.assertIsNotNone(getattr(result, field),
                                 f"Structured field {field!r} must not be None on would-block")

    def test_allow_result_does_not_need_structured_fields(self):
        """Allow results don't require structured fields (no error to report)."""
        doc = _block_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("api.anthropic.com", "GET", "/", doc)
        self.assertEqual(result.action, "allow")
        # Structured fields may be None/empty for allows — no assertion required


# ---------------------------------------------------------------------------
# Fail-closed: on load/parse error, behavior should remain deny
# (tested at integration level; the unit function itself requires a valid doc)
# We test that invalid docs produce deny outcomes safely.
# ---------------------------------------------------------------------------
class TestFailClosed(unittest.TestCase):
    def test_none_rules_doc_treated_as_error_or_deny(self):
        """decide() with None doc must not allow (fail-closed contract)."""
        # The function should either raise or return deny — never allow
        try:
            result = decide("api.anthropic.com", "GET", "/", None)
            self.assertNotEqual(result.action, "allow",
                                "Fail-closed: None rules doc must not return allow")
        except Exception:
            pass  # Raising is also acceptable (caller handles it)

    def test_empty_dict_doc_falls_back_to_legacy_deny_or_error(self):
        """decide() with empty doc (no rules) should not crash the proxy."""
        # Empty doc = no mode, no rules -> legacy with no deny rules -> allow all
        # This is consistent with legacy behavior (empty denylist allows all)
        doc = {}
        result = decide("api.github.com", "GET", "/", doc)
        # With no rules and no mode, legacy behavior allows everything
        self.assertIn(result.action, ("allow", "deny"),
                      f"Empty doc must return allow or deny, not: {result.action}")


# ---------------------------------------------------------------------------
# Fix 2 — suffix-bypass: github.com.attacker.com must not match "github.com"
# ---------------------------------------------------------------------------
class TestSuffixBypassDenied(unittest.TestCase):
    def test_allowed_apex_as_parent_label_is_denied(self):
        """Block mode: github.com.attacker.com must be DENIED when allowed_hosts=["github.com"].

        The attacker puts the allowed apex as a parent label in their domain.
        'github.com.attacker.com' does NOT end with '.github.com', so it must not match.
        """
        doc = _block_doc(allowed_hosts=["github.com"])
        result = decide("github.com.attacker.com", "GET", "/", doc)
        self.assertEqual(
            result.action, "deny",
            "github.com.attacker.com must be denied — allowed apex must not match as parent label",
        )


# ---------------------------------------------------------------------------
# Fix 3 — case-insensitive matching
# ---------------------------------------------------------------------------
class TestCaseInsensitiveMatching(unittest.TestCase):
    def test_uppercase_host_matches_allowed_hosts(self):
        """Block mode: GITHUB.COM must be ALLOWED when allowed_hosts=["github.com"]."""
        doc = _block_doc(allowed_hosts=["github.com"])
        result = decide("GITHUB.COM", "GET", "/", doc)
        self.assertEqual(
            result.action, "allow",
            "GITHUB.COM should be allowed when github.com is in allowed_hosts",
        )

    def test_uppercase_subdomain_matches_allowed_hosts(self):
        """Block mode: API.GITHUB.COM must be ALLOWED when allowed_hosts=["github.com"]."""
        doc = _block_doc(allowed_hosts=["github.com"])
        result = decide("API.GITHUB.COM", "GET", "/", doc)
        self.assertEqual(
            result.action, "allow",
            "API.GITHUB.COM should be allowed when github.com is in allowed_hosts",
        )

    def test_uppercase_ioc_host_still_denied(self):
        """IOC floor: WEBHOOK.SITE must still be DENIED even in uppercase."""
        doc = _block_doc(
            allowed_hosts=[],
            ioc_rules=[IOC_WEBHOOK_SITE],
        )
        result = decide("WEBHOOK.SITE", "GET", "/", doc)
        self.assertEqual(
            result.action, "deny",
            "WEBHOOK.SITE must be denied by IOC floor regardless of case",
        )


# ---------------------------------------------------------------------------
# Fix 1 — mode-value normalization
# ---------------------------------------------------------------------------
class TestModeNormalization(unittest.TestCase):
    def test_observe_uppercase_normalizes_to_observe(self):
        """mode='OBSERVE' (uppercase) must behave as observe mode (returns would-block)."""
        doc = {
            "version": 2,
            "mode": "OBSERVE",
            "allowed_hosts": ["api.anthropic.com"],
            "rules": [],
        }
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertEqual(
            result.action, "would-block",
            "mode='OBSERVE' must normalize to observe and return would-block",
        )

    def test_bogus_mode_falls_to_block_deny(self):
        """mode='bogus' (unrecognized) must fail-closed to block mode (deny, not would-block).

        Fail-closed means unknown mode normalizes to 'block', not 'observe'.
        A non-whitelisted host must receive 'deny', not the 'would-block' that
        observe mode would return.
        """
        doc = {
            "version": 2,
            "mode": "bogus",
            "allowed_hosts": ["api.anthropic.com"],  # unlisted host → must be denied
            "rules": [],
        }
        result = decide("evil.example.com", "GET", "/", doc)
        self.assertEqual(
            result.action, "deny",
            "mode='bogus' must fail-closed to block/deny, not return would-block",
        )


# ---------------------------------------------------------------------------
# (g) Method symmetry — method-asymmetry DELETED (rip-cage-ta1o.1)
#
# The write-gate (writable_hosts) is REMOVED from the pure destination router.
# POST to an allowlisted host must behave identically to GET — both allowed.
# There is no method inspection; only the destination matters.
# ---------------------------------------------------------------------------
class TestMethodSymmetry(unittest.TestCase):
    """Verify that POST/PUT/DELETE/PATCH to an allowed host = GET (no write-gate)."""

    def test_post_to_allowed_host_is_allowed(self):
        """Pure router: POST to a whitelisted host must be ALLOWED (no write-gate)."""
        doc = _block_doc(allowed_hosts=["api.github.com"])
        result = decide("api.github.com", "POST", "/repos", doc)
        self.assertEqual(
            result.action, "allow",
            "POST to an allowed host must be ALLOWED — method-asymmetry deleted",
        )

    def test_put_to_allowed_host_is_allowed(self):
        """Pure router: PUT to a whitelisted host must be ALLOWED."""
        doc = _block_doc(allowed_hosts=["api.github.com"])
        result = decide("api.github.com", "PUT", "/repos/file", doc)
        self.assertEqual(result.action, "allow",
                         "PUT to allowed host must be ALLOWED")

    def test_delete_to_allowed_host_is_allowed(self):
        """Pure router: DELETE to a whitelisted host must be ALLOWED."""
        doc = _block_doc(allowed_hosts=["api.github.com"])
        result = decide("api.github.com", "DELETE", "/repos/thing", doc)
        self.assertEqual(result.action, "allow",
                         "DELETE to allowed host must be ALLOWED")

    def test_patch_to_allowed_host_is_allowed(self):
        """Pure router: PATCH to a whitelisted host must be ALLOWED."""
        doc = _block_doc(allowed_hosts=["api.github.com"])
        result = decide("api.github.com", "PATCH", "/repos/thing", doc)
        self.assertEqual(result.action, "allow",
                         "PATCH to allowed host must be ALLOWED")

    def test_post_to_unlisted_host_is_still_denied(self):
        """POST to a non-whitelisted host is denied — destination policy applies."""
        doc = _block_doc(allowed_hosts=["api.github.com"])
        result = decide("evil.example.com", "POST", "/exfil", doc)
        self.assertEqual(result.action, "deny",
                         "POST to unlisted host must still be denied")

    def test_no_writable_hosts_field_in_decide_signature(self):
        """decide() ignores any writable_hosts field in the rules doc."""
        doc = {
            "version": 2,
            "mode": "block",
            "allowed_hosts": ["api.github.com"],
            "writable_hosts": [],  # present but ignored
            "rules": [],
        }
        result = decide("api.github.com", "POST", "/repos", doc)
        self.assertEqual(
            result.action, "allow",
            "writable_hosts in rules doc must be ignored — only destination matters",
        )

    def test_method_symmetry_in_observe_mode(self):
        """Observe mode: POST to allowed host is also allowed (no write-gate)."""
        doc = _observe_doc(allowed_hosts=["api.github.com"])
        result = decide("api.github.com", "POST", "/repos", doc)
        self.assertEqual(result.action, "allow",
                         "POST to allowed host in observe mode must be ALLOWED")


# ---------------------------------------------------------------------------
# F9 — IPv6 literal Host header handling (rip-cage-ta1o.1 adversarial review)
#
# _extract_http_host must correctly strip the port from IPv6 bracketed literals.
# "[::1]:80" must return "[::1]", not "[::1]:80".
# ---------------------------------------------------------------------------
class TestExtractHttpHostIpv6(unittest.TestCase):
    """Verify _extract_http_host correctly handles IPv6 literal Host headers."""

    def _make_request(self, host_value: str) -> bytes:
        """Build a minimal HTTP/1.1 request with the given Host header value."""
        return f"GET / HTTP/1.1\r\nHost: {host_value}\r\nConnection: close\r\n\r\n".encode()

    def test_ipv6_literal_no_port(self):
        """[::1] (no port) must return '[::1]'."""
        result = _extract_http_host(self._make_request("[::1]"))
        self.assertEqual(result, "[::1]",
                         "IPv6 literal without port must return '[::1]'")

    def test_ipv6_literal_with_port(self):
        """[::1]:80 must return '[::1]' (port stripped). F9 fix."""
        result = _extract_http_host(self._make_request("[::1]:80"))
        self.assertEqual(result, "[::1]",
                         "IPv6 literal with port must strip port: '[::1]:80' → '[::1]'")

    def test_ipv6_full_with_port(self):
        """[2001:db8::1]:443 must return '[2001:db8::1]' (port stripped)."""
        result = _extract_http_host(self._make_request("[2001:db8::1]:443"))
        self.assertEqual(result, "[2001:db8::1]",
                         "Full IPv6 literal with port must strip port")

    def test_ipv4_with_port(self):
        """1.2.3.4:80 must return '1.2.3.4' (port stripped, unchanged behavior)."""
        result = _extract_http_host(self._make_request("1.2.3.4:80"))
        self.assertEqual(result, "1.2.3.4",
                         "IPv4 with port must strip port")

    def test_hostname_with_port(self):
        """example.com:8080 must return 'example.com' (port stripped)."""
        result = _extract_http_host(self._make_request("example.com:8080"))
        self.assertEqual(result, "example.com",
                         "Hostname with port must strip port")

    def test_hostname_no_port(self):
        """example.com (no port) must return 'example.com' (unchanged)."""
        result = _extract_http_host(self._make_request("example.com"))
        self.assertEqual(result, "example.com",
                         "Hostname without port must be returned as-is")


# ---------------------------------------------------------------------------
# F1 — no-SNI / IP-literal handling (rip-cage-ta1o.1 adversarial review)
#
# A pure SNI router cannot recover a hostname from a SNI-less or ECH-encrypted
# TLS connection. The router falls back to the raw IP string as the "host" value.
#
# Block/observe mode: the raw IP is not in allowed_hosts → FAIL-CLOSED (deny /
# would-block). This is the correct posture.
#
# Legacy mode: IP string matches no host-based IOC rule → ALLOW. This is the
# known gap documented in ADR-012 D3 / D4. We verify it here so it is tested
# and visible, not silently absent.
# ---------------------------------------------------------------------------
class TestNoSniIpLiteralHandling(unittest.TestCase):
    """Verify fail-closed behavior for no-SNI / IP-literal fallback."""

    def test_block_mode_ip_literal_is_denied(self):
        """Block mode: raw IPv4 literal (no SNI fallback) must be DENIED.

        The router falls back to orig_dst IP when SNI is absent. The IP string
        '1.2.3.4' is not in allowed_hosts → deny. This is the correct
        fail-closed posture for SNI-less TLS connections.
        """
        doc = _block_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("1.2.3.4", "GET", "/", doc)
        self.assertEqual(
            result.action, "deny",
            "Block mode: IP literal not in allowed_hosts must be DENIED (fail-closed)"
        )

    def test_observe_mode_ip_literal_is_would_block(self):
        """Observe mode: raw IPv4 literal (no SNI fallback) must be WOULD-BLOCK.

        Same fail-closed logic as block mode — IP literal is not in allowed_hosts.
        In observe mode the connection is allowed through but logged as would-block.
        """
        doc = _observe_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("1.2.3.4", "GET", "/", doc)
        self.assertEqual(
            result.action, "would-block",
            "Observe mode: IP literal not in allowed_hosts must be WOULD-BLOCK"
        )

    def test_block_mode_empty_host_is_denied(self):
        """Block mode: empty host (no SNI, no fallback IP) must be DENIED.

        decide() with an empty host falls through to the not-whitelisted branch
        in block mode — fail-closed.
        """
        doc = _block_doc(allowed_hosts=["api.anthropic.com"])
        result = decide("", "GET", "/", doc)
        self.assertEqual(
            result.action, "deny",
            "Block mode: empty host must be DENIED (fail-closed)"
        )

    def test_legacy_mode_ip_literal_is_allowed(self):
        """Legacy mode: raw IPv4 literal passes through (known gap).

        In legacy (denylist-only) mode the IP '1.2.3.4' matches no host-based
        IOC deny rule → allowed. This is the DOCUMENTED gap for SNI-less TLS in
        legacy mode per ADR-012 D3/D4. This test exists to make the gap visible
        and to prevent a future change from silently breaking the documented behavior.
        """
        doc = _legacy_doc(deny_rules=[IOC_WEBHOOK_SITE])
        result = decide("1.2.3.4", "GET", "/", doc)
        self.assertEqual(
            result.action, "allow",
            "Legacy mode: IP literal not in any deny rule must be ALLOWED (documented gap)"
        )

    def test_block_mode_ip_literal_with_ioc_still_denied(self):
        """Block mode: IP literal is denied by default-deny (not-whitelisted), not IOC."""
        doc = _block_doc(allowed_hosts=[], ioc_rules=[IOC_WEBHOOK_SITE])
        result = decide("192.168.1.100", "GET", "/", doc)
        self.assertEqual(result.action, "deny")
        # rule_id should be 'not-whitelisted' (not an IOC rule), because the IP
        # doesn't match any IOC rule — the IP just isn't in allowed_hosts.
        self.assertEqual(result.rule_id, "not-whitelisted",
                         "IP literal denial should come from not-whitelisted, not an IOC rule")


# ---------------------------------------------------------------------------
# rip-cage-ta1o.5.2 — HTTP CONNECT forward seam
#
# Tests for:
#   (a) _resolve_upstream() reads http_forward_to from rules doc
#   (b) CONNECT-speaking echo mediator integration probe
#   (c) Floor-before-forward: denied dst never reaches mediator (count=0)
#   (d) null http_forward_to = origin-splice (no mediator)
#   (e) Startup/observe parity: covered by existing tests
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Unit tests: _resolve_upstream()
# ---------------------------------------------------------------------------
class TestResolveUpstream(unittest.TestCase):
    """Unit tests for _resolve_upstream() — reads http_forward_to from rules doc."""

    def test_null_doc_returns_none(self):
        """_resolve_upstream(None) returns None (origin-splice, no mediator)."""
        result = _resolve_upstream(None)
        self.assertIsNone(result, "_resolve_upstream(None) must return None")

    def test_missing_http_forward_to_returns_none(self):
        """Rules doc without http_forward_to returns None."""
        doc = {"version": 2, "mode": "block", "allowed_hosts": [], "rules": []}
        result = _resolve_upstream(doc)
        self.assertIsNone(result)

    def test_host_only_returns_tuple_with_default_port(self):
        """http_forward_to='127.0.0.1' returns ('127.0.0.1', 8888) with default port."""
        doc = {"version": 2, "rules": [], "http_forward_to": "127.0.0.1"}
        host, port = _resolve_upstream(doc)
        self.assertEqual(host, "127.0.0.1")
        self.assertIsInstance(port, int)
        self.assertGreater(port, 0)

    def test_host_colon_port_returns_parsed_tuple(self):
        """http_forward_to='127.0.0.1:9000' returns ('127.0.0.1', 9000)."""
        doc = {"version": 2, "rules": [], "http_forward_to": "127.0.0.1:9000"}
        host, port = _resolve_upstream(doc)
        self.assertEqual(host, "127.0.0.1")
        self.assertEqual(port, 9000)

    def test_empty_string_returns_none(self):
        """http_forward_to='' returns None."""
        doc = {"version": 2, "rules": [], "http_forward_to": ""}
        result = _resolve_upstream(doc)
        self.assertIsNone(result)

    def test_explicit_null_returns_none(self):
        """http_forward_to=None in doc returns None."""
        doc = {"version": 2, "rules": [], "http_forward_to": None}
        result = _resolve_upstream(doc)
        self.assertIsNone(result)


# ---------------------------------------------------------------------------
# Integration probe: CONNECT-speaking echo mediator
#
# This class stands up a minimal TCP server that:
#   - Receives an HTTP CONNECT request and records the target
#   - Replies 200 Connection established
#   - Then echoes all subsequent bytes back (echo mediator)
#   - Counts total connections received
#
# We then build a router-like CONNECT handoff path and verify:
#   (a) The CONNECT target matches the original destination
#   (b) The first_chunk (ClientHello) is replayed AFTER the 200
#   (c) The deny path never reaches the mediator (count=0)
#   (d) Null http_forward_to → no mediator contact at all
# ---------------------------------------------------------------------------

def _start_echo_mediator(port: int, stop_event: threading.Event):
    """Minimal CONNECT-speaking echo server for testing.

    Listens on 127.0.0.1:<port>. For each connection:
      - Reads the CONNECT request line
      - Records the target in the global list
      - Sends 200
      - Echoes all subsequent data
    """
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(5)
    srv.settimeout(0.5)

    while not stop_event.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        try:
            # Read CONNECT request (read until \r\n\r\n)
            buf = b""
            conn.settimeout(2.0)
            while b"\r\n\r\n" not in buf:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
            # Parse target from "CONNECT host:port HTTP/1.1\r\n..."
            first_line = buf.split(b"\r\n")[0].decode("latin-1", errors="replace")
            parts = first_line.split()
            if len(parts) >= 2 and parts[0].upper() == "CONNECT":
                _MEDIATOR_CONNECT_TARGETS.append(parts[1])
            # Reply 200
            conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            # Echo all remaining data back
            conn.settimeout(0.5)
            while not stop_event.is_set():
                try:
                    data = conn.recv(4096)
                    if not data:
                        break
                    conn.sendall(data)
                except socket.timeout:
                    break
                except OSError:
                    break
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    srv.close()


# Global mutable state for the echo mediator integration test
_MEDIATOR_CONNECT_TARGETS = []
_MEDIATOR_CONNECTION_COUNT = 0


def _start_counting_echo_mediator(port: int, stop_event: threading.Event):
    """Like _start_echo_mediator, but also counts every inbound connection."""
    global _MEDIATOR_CONNECTION_COUNT
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(5)
    srv.settimeout(0.5)

    while not stop_event.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        _MEDIATOR_CONNECTION_COUNT += 1
        try:
            conn.close()
        except OSError:
            pass

    srv.close()


def _do_connect_handoff(mediator_host: str, mediator_port: int,
                        orig_host: str, orig_port: int,
                        first_chunk: bytes) -> socket.socket:
    """Perform the HTTP CONNECT handoff to a mediator.

    Opens a TCP connection to the mediator, sends CONNECT <orig_host>:<orig_port>,
    awaits 200, replays first_chunk, and returns the connected socket.

    Raises OSError or AssertionError on failure.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(3.0)
    sock.connect((mediator_host, mediator_port))

    # Send CONNECT request
    connect_req = f"CONNECT {orig_host}:{orig_port} HTTP/1.1\r\nHost: {orig_host}:{orig_port}\r\n\r\n"
    sock.sendall(connect_req.encode())

    # Read 200 response
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            raise OSError("Mediator closed connection before 200")
        resp += chunk

    assert b"200" in resp, f"Expected 200 from mediator, got: {resp[:200]!r}"

    # Replay first_chunk (simulates the router replaying the buffered ClientHello)
    if first_chunk:
        sock.sendall(first_chunk)

    return sock


def _run_handle_connection_via_socketpair(
    rules_doc: dict,
    fake_orig_dst,  # (host, port) that _get_original_dst should return
    first_chunk: bytes,
) -> socket.socket:
    """Drive _handle_connection through the real routing code using a socketpair.

    Creates a socketpair, writes first_chunk to the client end, patches
    _get_original_dst to return fake_orig_dst, then runs _handle_connection
    in a thread.  Returns the client-end socket so the caller can read any
    response (e.g. RST/close detection) and assert on mediator state.

    The caller is responsible for closing the returned socket.
    """
    client_sock, router_sock = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    # Write the first chunk so the router can recv it
    client_sock.sendall(first_chunk)

    def run():
        with unittest.mock.patch.object(
            rip_cage_router, "_get_original_dst", return_value=fake_orig_dst
        ):
            _handle_connection(router_sock, ("127.0.0.1", 99999), rules_doc)

    t = threading.Thread(target=run, daemon=True)
    t.start()
    return client_sock, t


class TestHttpConnectForwardSeam(unittest.TestCase):
    """Integration probe: HTTP CONNECT forward seam (rip-cage-ta1o.5.2).

    All tests that exercise the floor-before-forward invariant or the
    _connect_via_mediator path drive the REAL _handle_connection via
    _run_handle_connection_via_socketpair.  The _do_connect_handoff
    test-local reimplementation is REMOVED from the allow path so the
    tests cannot pass without the production routing code running.
    """

    def setUp(self):
        global _MEDIATOR_CONNECT_TARGETS, _MEDIATOR_CONNECTION_COUNT
        _MEDIATOR_CONNECT_TARGETS = []
        _MEDIATOR_CONNECTION_COUNT = 0
        self._stop = threading.Event()

    def tearDown(self):
        self._stop.set()
        time.sleep(0.15)

    def _find_free_port(self) -> int:
        """Bind to port 0 and return the OS-assigned port."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    # (a) ALLOWED connection → real _handle_connection → real _connect_via_mediator
    #     CONNECT target == real original destination; first_chunk replayed through mediator.
    def test_allowed_connection_reaches_mediator_with_correct_connect_target(self):
        """(a) On ALLOW, real _handle_connection → _connect_via_mediator; CONNECT target correct.

        Drives the PRODUCTION _handle_connection (with _get_original_dst patched)
        and the PRODUCTION _connect_via_mediator.  The test-local _do_connect_handoff
        is NOT used here — if the production routing code is bypassed this test fails.

        Uses plain HTTP (port 80) so _extract_http_host("api.github.com") drives the
        decision and CONNECT target.  The router reads Host: api.github.com, ALLOWS it,
        opens CONNECT to the echo mediator, replays first_chunk, and splices both ways.
        """
        med_port = self._find_free_port()
        t = threading.Thread(target=_start_echo_mediator,
                             args=(med_port, self._stop), daemon=True)
        t.start()
        time.sleep(0.05)  # let mediator start

        orig_host = "api.github.com"
        orig_port = 80
        # Plain HTTP request so _extract_http_host extracts the correct host.
        first_chunk = f"GET /repos HTTP/1.1\r\nHost: {orig_host}\r\nConnection: keep-alive\r\n\r\n".encode()

        # Rules doc: api.github.com ALLOWED; mediator at med_port.
        rules_doc = _block_doc(allowed_hosts=[orig_host])
        rules_doc["http_forward_to"] = f"127.0.0.1:{med_port}"

        # Drive the REAL router via _handle_connection.
        # fake_orig_dst port 80 → plain-HTTP path; IP is the orig destination.
        client_sock, handler_thread = _run_handle_connection_via_socketpair(
            rules_doc,
            fake_orig_dst=("10.0.0.1", orig_port),
            first_chunk=first_chunk,
        )
        try:
            # The router splices first_chunk to the mediator, which echoes it back.
            client_sock.settimeout(3.0)
            echoed = b""
            try:
                while len(echoed) < len(first_chunk):
                    chunk = client_sock.recv(4096)
                    if not chunk:
                        break
                    echoed += chunk
            except socket.timeout:
                pass
        finally:
            client_sock.close()

        handler_thread.join(timeout=3.0)

        # The CONNECT target must match the SNI/Host extracted by the router.
        # _extract_http_host returns "api.github.com" from the Host header.
        # The router uses this as the CONNECT target host.
        self.assertEqual(len(_MEDIATOR_CONNECT_TARGETS), 1,
                         f"Expected 1 CONNECT via _handle_connection, got: {_MEDIATOR_CONNECT_TARGETS}")
        connect_target = _MEDIATOR_CONNECT_TARGETS[0]
        self.assertEqual(connect_target, f"{orig_host}:{orig_port}",
                         f"CONNECT target mismatch: {connect_target!r}")
        # first_chunk was spliced through the mediator and echoed back.
        self.assertEqual(echoed, first_chunk,
                         "first_chunk must be replayed through _connect_via_mediator and echoed back")

    # (b) Floor-before-forward: denied dst → real _handle_connection RSTs before
    #     reaching mediator.  Positive control: allowed dst DOES reach mediator (count ≥ 1).
    #     Without the positive control the count==0 assertion is vacuous (dead mediator).
    def test_denied_destination_never_reaches_mediator(self):
        """(b) DENIED destination: real _handle_connection RSTs; mediator count stays 0.

        Drives the REAL _handle_connection (not just decide()).  Includes a POSITIVE
        CONTROL: an allowed connection through the same _handle_connection path DOES
        increment the mediator's connection count, proving the counter is wired and the
        count==0 on deny is real evidence, not an artefact of a dead mediator.

        Uses plain HTTP (port 80) for both allow and deny paths so _extract_http_host
        correctly extracts the Host header and drives decide() with the right hostname.
        The _start_counting_echo_mediator just accepts + closes; _connect_via_mediator
        will fail (no 200) but the TCP connection is established — incrementing the count.
        """
        med_port = self._find_free_port()
        t = threading.Thread(target=_start_counting_echo_mediator,
                             args=(med_port, self._stop), daemon=True)
        t.start()
        time.sleep(0.05)

        allowed_host = "api.github.com"

        # --- POSITIVE CONTROL: allowed connection DOES reach the mediator ---
        # Plain HTTP request so _extract_http_host returns "api.github.com" → ALLOW.
        # The router calls _connect_via_mediator; the counting mediator accepts + closes.
        # _connect_via_mediator raises OSError (no 200); the router catches it and returns.
        # Crucially, the TCP connection IS established → count increments to ≥ 1.
        allowed_http = f"GET / HTTP/1.1\r\nHost: {allowed_host}\r\nConnection: close\r\n\r\n".encode()
        allowed_rules = _block_doc(allowed_hosts=[allowed_host])
        allowed_rules["http_forward_to"] = f"127.0.0.1:{med_port}"

        positive_client, positive_thread = _run_handle_connection_via_socketpair(
            allowed_rules,
            fake_orig_dst=("10.0.0.1", 80),
            first_chunk=allowed_http,
        )
        positive_client.close()
        positive_thread.join(timeout=3.0)

        # After the allowed path, the mediator must have seen ≥ 1 connection.
        time.sleep(0.05)
        count_after_allow = _MEDIATOR_CONNECTION_COUNT
        self.assertGreaterEqual(count_after_allow, 1,
                                "POSITIVE CONTROL: allowed connection must reach the mediator "
                                f"(count={count_after_allow} — if 0 the mediator is not wired)")

        # --- DENY PATH: denied connection must NOT add to the count ---
        # Plain HTTP with Host: evil.example.com → _extract_http_host → DENY.
        # The router RSTs the connection before calling _connect_via_mediator.
        deny_http = b"GET / HTTP/1.1\r\nHost: evil.example.com\r\nConnection: close\r\n\r\n"
        deny_rules = _block_doc(allowed_hosts=[allowed_host])
        deny_rules["http_forward_to"] = f"127.0.0.1:{med_port}"

        deny_client, deny_thread = _run_handle_connection_via_socketpair(
            deny_rules,
            fake_orig_dst=("10.0.0.1", 80),
            first_chunk=deny_http,
        )
        # Wait for the router to close/RST the deny client socket.
        deny_client.settimeout(3.0)
        try:
            data = deny_client.recv(4096)
        except (socket.timeout, OSError):
            data = b""
        deny_client.close()
        deny_thread.join(timeout=3.0)

        time.sleep(0.05)
        count_after_deny = _MEDIATOR_CONNECTION_COUNT
        self.assertEqual(count_after_deny, count_after_allow,
                         f"Mediator count must not increase after a DENIED connection "
                         f"(before={count_after_allow}, after={count_after_deny})")

    # (c) http_forward_to null → _resolve_upstream returns None (origin-splice)
    def test_null_forward_to_uses_origin_splice(self):
        """(c) With http_forward_to null, _resolve_upstream returns None (origin-splice)."""
        doc = _block_doc(allowed_hosts=["api.github.com"])
        # No http_forward_to key = None
        result = _resolve_upstream(doc)
        self.assertIsNone(result,
                          "Null http_forward_to must return None (origin-splice behavior)")

    # (d) With http_forward_to set: _resolve_upstream returns a valid (host, port)
    def test_configured_forward_to_returns_mediator_address(self):
        """(d) With http_forward_to set, _resolve_upstream returns (host, port)."""
        doc = _block_doc(allowed_hosts=["api.github.com"])
        doc["http_forward_to"] = "127.0.0.1:9999"
        result = _resolve_upstream(doc)
        self.assertIsNotNone(result, "http_forward_to set must return a (host, port) tuple")
        host, port = result
        self.assertEqual(host, "127.0.0.1")
        self.assertEqual(port, 9999)

    # (e) _resolve_upstream handles host-only (no port) using a default port
    def test_host_only_forward_to_uses_default_port(self):
        """(e) http_forward_to='127.0.0.1' (no port) uses a sensible default port."""
        doc = _block_doc(allowed_hosts=[])
        doc["http_forward_to"] = "127.0.0.1"
        result = _resolve_upstream(doc)
        self.assertIsNotNone(result)
        host, port = result
        self.assertEqual(host, "127.0.0.1")
        self.assertIsInstance(port, int)
        self.assertGreater(port, 0)

    # (f) _connect_via_mediator: non-200 CONNECT response → fail-closed (OSError)
    def test_connect_via_mediator_non_200_response_fails_closed(self):
        """(f) _connect_via_mediator with non-200 response fails closed (raises OSError).

        Exercises the 200-status check at rip_cage_router._connect_via_mediator ~line 199.
        A mediator that rejects CONNECT with 407/502/etc must cause an OSError, not a
        silently open tunnel.  Also tests partial/short response (no \\r\\n\\r\\n) and
        empty response (mediator closes immediately).
        """
        def _find_free_port():
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.bind(("127.0.0.1", 0))
            p = s.getsockname()[1]
            s.close()
            return p

        # --- sub-case 1: mediator sends 407 Proxy Auth Required ---
        stop407 = threading.Event()
        port407 = _find_free_port()

        def _mediator_407(port, stop):
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", port))
            srv.listen(5)
            srv.settimeout(1.0)
            while not stop.is_set():
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    conn.recv(4096)  # drain CONNECT request
                    conn.sendall(b"HTTP/1.1 407 Proxy Auth Required\r\n\r\n")
                    conn.close()
                except OSError:
                    pass
            srv.close()

        t407 = threading.Thread(target=_mediator_407, args=(port407, stop407), daemon=True)
        t407.start()
        time.sleep(0.05)

        with self.assertRaises(OSError,
                               msg="_connect_via_mediator must raise OSError on 407 response"):
            _connect_via_mediator("127.0.0.1", port407, "api.github.com", 443)
        stop407.set()

        # --- sub-case 2: mediator sends oversized response (> 8192 bytes before \\r\\n\\r\\n) ---
        stop_big = threading.Event()
        port_big = _find_free_port()

        def _mediator_oversized(port, stop):
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", port))
            srv.listen(5)
            srv.settimeout(1.0)
            while not stop.is_set():
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    conn.recv(4096)
                    # Send >8192 bytes WITHOUT \r\n\r\n to trigger the size bail-out
                    conn.sendall(b"X" * 8193)
                    conn.close()
                except OSError:
                    pass
            srv.close()

        t_big = threading.Thread(target=_mediator_oversized, args=(port_big, stop_big), daemon=True)
        t_big.start()
        time.sleep(0.05)

        with self.assertRaises(OSError,
                               msg="_connect_via_mediator must raise OSError on oversized response"):
            _connect_via_mediator("127.0.0.1", port_big, "api.github.com", 443)
        stop_big.set()

        # --- sub-case 3: mediator closes connection immediately (no response) ---
        stop_close = threading.Event()
        port_close = _find_free_port()

        def _mediator_close_immediately(port, stop):
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", port))
            srv.listen(5)
            srv.settimeout(1.0)
            while not stop.is_set():
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    conn.close()  # close immediately without sending anything
                except OSError:
                    pass
            srv.close()

        t_close = threading.Thread(target=_mediator_close_immediately,
                                   args=(port_close, stop_close), daemon=True)
        t_close.start()
        time.sleep(0.05)

        with self.assertRaises(OSError,
                               msg="_connect_via_mediator must raise OSError when mediator closes immediately"):
            _connect_via_mediator("127.0.0.1", port_close, "api.github.com", 443)
        stop_close.set()


if __name__ == "__main__":
    unittest.main(verbosity=2)
