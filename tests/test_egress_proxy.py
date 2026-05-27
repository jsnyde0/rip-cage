#!/usr/bin/env python3
"""
Unit tests for rip_cage_egress.py — proxy enforcement rewrite (rip-cage-hhh.3).

Tests are structured around the pure `decide()` function which is testable
without mitmproxy imports. Each test covers one acceptance criterion from the bead.

Run with: uv run python -m pytest tests/test_egress_proxy.py -v
       or: uv run python tests/test_egress_proxy.py

Acceptance criteria covered:
  (a) block mode denies non-whitelisted host
  (b) block mode allows whitelisted host
  (c) IOC-floor host denied even if in allowed_hosts
  (d) observe mode lets a would-be-denied request THROUGH but logs would-have-blocked
  (e) legacy (no mode) reproduces denylist-only behavior unchanged
  (f) denial carries all six structured fields with correct names:
      pattern, target, why, fix_command, config_file, config_path
"""
import sys
import unittest
from pathlib import Path

# Import the module under test. Because it imports mitmproxy at the top level,
# we rely on the decide() pure function being importable without a live proxy.
# If mitmproxy is unavailable (unit test environment), we import with a mock.
try:
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from rip_cage_egress import decide, DecisionResult, STRUCTURED_FIELD_NAMES
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
        "writable_hosts": [],
        "rules": ioc_rules or [],
    }


def _observe_doc(allowed_hosts, ioc_rules=None):
    """Build a rules doc with mode=observe."""
    return {
        "version": 2,
        "mode": "observe",
        "allowed_hosts": allowed_hosts,
        "writable_hosts": [],
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
