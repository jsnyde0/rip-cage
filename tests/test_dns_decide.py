#!/usr/bin/env python3
"""
Unit tests for rip_cage_dns.py — DNS resolver sidecar (rip-cage-hhh.8).

Tests are structured around the pure `dns_decide()` function which is testable
without dnspython/socket imports. Each test covers one acceptance criterion from
the bead.

Run with: uv run --with pytest --with dnspython python -m pytest tests/test_dns_decide.py -v

Acceptance criteria covered:
  (a) whitelisted-apex query passes even with a long subdomain label
  (b) non-whitelisted apex with a long-encoded subdomain label => deny (block) / would-block (observe)
  (c) cardinality burst against one non-whitelisted apex => deny/would-block
  (d) clean short non-whitelisted query => allow (forward)
  (e) legacy mode => no inspection (all allow)
  (f) denial carries the six structured fields with correct names:
      pattern, target, why, fix_command, config_file, config_path
  (g) unrecognized mode fails closed to block
"""
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "cage" / "egress"))
from rip_cage_dns import (
    dns_decide,
    DNSDecisionResult,
    DNS_LABEL_LENGTH_THRESHOLD,
    DNS_CARDINALITY_WINDOW_SECS,
    DNS_CARDINALITY_THRESHOLD,
    STRUCTURED_FIELD_NAMES,
)


# ---------------------------------------------------------------------------
# Helpers: build minimal rules-doc dicts for each posture
# ---------------------------------------------------------------------------

def _block_doc(allowed_hosts):
    """Build a rules doc with mode=block."""
    return {
        "version": 2,
        "mode": "block",
        "allowed_hosts": allowed_hosts,
        "rules": [],
    }


def _observe_doc(allowed_hosts):
    """Build a rules doc with mode=observe."""
    return {
        "version": 2,
        "mode": "observe",
        "allowed_hosts": allowed_hosts,
        "rules": [],
    }


def _legacy_doc():
    """Build a legacy rules doc (no mode key)."""
    return {
        "version": 1,
        "rules": [],
    }


def _fresh_state():
    """Return a fresh (empty) recent-query state dict."""
    return {}


# ---------------------------------------------------------------------------
# (a) whitelisted-apex query passes even with a long subdomain label
# ---------------------------------------------------------------------------
class TestWhitelistedApexPassesUnconditionally(unittest.TestCase):
    def test_whitelisted_apex_with_long_label_passes(self):
        """A whitelisted apex query with a very long subdomain label must pass."""
        # label 40 chars (> threshold) under a whitelisted apex
        long_label = "a" * 40
        qname = f"{long_label}.github.com"
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "allow",
                         f"Whitelisted apex must pass regardless of subdomain length, got: {result.action}")

    def test_whitelisted_apex_exact_match_passes(self):
        """An exact whitelisted apex passes unconditionally."""
        doc = _block_doc(allowed_hosts=["api.anthropic.com"])
        result = dns_decide("api.anthropic.com", doc, _fresh_state())
        self.assertEqual(result.action, "allow")

    def test_whitelisted_apex_subdomain_passes(self):
        """A subdomain of a whitelisted apex passes unconditionally."""
        doc = _block_doc(allowed_hosts=["anthropic.com"])
        result = dns_decide("api.anthropic.com", doc, _fresh_state())
        self.assertEqual(result.action, "allow")


# ---------------------------------------------------------------------------
# (b) non-whitelisted apex + long-encoded subdomain label => deny/would-block
# ---------------------------------------------------------------------------
class TestLongLabelHeuristic(unittest.TestCase):
    def test_long_label_non_whitelisted_blocked(self):
        """Block mode: long subdomain label on non-whitelisted apex must be denied."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "deny",
                         f"Block mode: long label on non-whitelisted apex must be denied, got: {result.action}")

    def test_long_label_observe_mode_would_block(self):
        """Observe mode: long subdomain label on non-whitelisted apex must be would-block."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = _observe_doc(allowed_hosts=["github.com"])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "would-block",
                         f"Observe mode: long label must be would-block, got: {result.action}")

    def test_label_at_threshold_not_blocked(self):
        """A label exactly at the threshold must NOT be blocked (threshold is exclusive)."""
        label_at_threshold = "a" * DNS_LABEL_LENGTH_THRESHOLD
        qname = f"{label_at_threshold}.attacker.com"
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "allow",
                         f"Label at threshold should pass (threshold exclusive), got: {result.action}")

    def test_short_label_not_blocked(self):
        """A short, clean non-whitelisted subdomain query must pass through."""
        qname = "api.attacker.com"
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "allow",
                         "Short label on non-whitelisted apex must be allowed (forward)")


# ---------------------------------------------------------------------------
# (c) cardinality burst against a single non-whitelisted apex => deny/would-block
# ---------------------------------------------------------------------------
class TestCardinalityHeuristic(unittest.TestCase):
    def _make_burst_state(self, apex, count):
        """Build a recent-query-state that looks like `count` queries for `apex` just now."""
        now = time.time()
        return {apex: [now] * count}

    def test_cardinality_burst_blocked(self):
        """Block mode: cardinality burst for non-whitelisted apex must be denied."""
        apex = "attacker.com"
        state = self._make_burst_state(apex, DNS_CARDINALITY_THRESHOLD + 1)
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide(f"sub.{apex}", doc, state)
        self.assertEqual(result.action, "deny",
                         f"Cardinality burst must be denied in block mode, got: {result.action}")

    def test_cardinality_burst_observe_would_block(self):
        """Observe mode: cardinality burst for non-whitelisted apex must be would-block."""
        apex = "attacker.com"
        state = self._make_burst_state(apex, DNS_CARDINALITY_THRESHOLD + 1)
        doc = _observe_doc(allowed_hosts=["github.com"])
        result = dns_decide(f"sub.{apex}", doc, state)
        self.assertEqual(result.action, "would-block",
                         f"Cardinality burst must be would-block in observe mode, got: {result.action}")

    def test_cardinality_at_threshold_not_blocked(self):
        """Exactly at the cardinality threshold must NOT be blocked (threshold is exclusive)."""
        apex = "attacker.com"
        state = self._make_burst_state(apex, DNS_CARDINALITY_THRESHOLD)
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide(f"sub.{apex}", doc, state)
        self.assertEqual(result.action, "allow",
                         "At threshold must pass (threshold exclusive)")

    def test_stale_cardinality_not_counted(self):
        """Cardinality counts older than the window are ignored."""
        apex = "attacker.com"
        old_time = time.time() - DNS_CARDINALITY_WINDOW_SECS - 1
        state = {apex: [old_time] * (DNS_CARDINALITY_THRESHOLD + 5)}  # all stale
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide(f"sub.{apex}", doc, state)
        self.assertEqual(result.action, "allow",
                         "Stale cardinality counts must not trigger block")

    def test_cardinality_burst_whitelisted_apex_still_passes(self):
        """Cardinality burst against a whitelisted apex must still pass (whitelisted = unconditional)."""
        apex = "github.com"
        state = self._make_burst_state(apex, DNS_CARDINALITY_THRESHOLD + 100)
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide(f"sub.{apex}", doc, state)
        self.assertEqual(result.action, "allow",
                         "Whitelisted apex must pass even under cardinality burst")


# ---------------------------------------------------------------------------
# (d) clean short non-whitelisted query => allow (forward)
# ---------------------------------------------------------------------------
class TestCleanQueryForwarded(unittest.TestCase):
    def test_clean_non_whitelisted_forwarded_in_block_mode(self):
        """Block mode: clean, short query to non-whitelisted apex must be allowed (forwarded)."""
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide("api.example.com", doc, _fresh_state())
        self.assertEqual(result.action, "allow",
                         "DNS whitelist does not block clean queries — HTTP layer handles connection enforcement")

    def test_apex_only_query_allowed(self):
        """Apex-only query (no subdomain) to non-whitelisted apex must be allowed."""
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide("example.com", doc, _fresh_state())
        self.assertEqual(result.action, "allow",
                         "Apex-only non-whitelisted query must be allowed")


# ---------------------------------------------------------------------------
# (e) legacy mode => no inspection, all allow
# ---------------------------------------------------------------------------
class TestLegacyMode(unittest.TestCase):
    def test_legacy_mode_long_label_passes(self):
        """Legacy mode: long label query must pass (no DNS inspection in legacy)."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 5)
        qname = f"{long_label}.attacker.com"
        doc = _legacy_doc()
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "allow",
                         "Legacy mode must not inspect DNS queries")

    def test_legacy_mode_cardinality_burst_passes(self):
        """Legacy mode: cardinality burst must pass (no DNS inspection in legacy)."""
        apex = "attacker.com"
        now = time.time()
        state = {apex: [now] * (DNS_CARDINALITY_THRESHOLD + 100)}
        doc = _legacy_doc()
        result = dns_decide(f"sub.{apex}", doc, state)
        self.assertEqual(result.action, "allow",
                         "Legacy mode must not apply cardinality heuristic")

    def test_legacy_mode_null_mode_key_also_passes(self):
        """mode=null triggers legacy behavior (no DNS inspection)."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 5)
        qname = f"{long_label}.attacker.com"
        doc = {"version": 2, "mode": None, "allowed_hosts": [], "rules": []}
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "allow",
                         "mode=null must trigger legacy (no inspection)")


# ---------------------------------------------------------------------------
# (f) denial carries six structured fields with correct names
# ---------------------------------------------------------------------------
class TestStructuredFields(unittest.TestCase):
    REQUIRED_FIELDS = {"pattern", "target", "why", "fix_command", "config_file", "config_path"}

    def test_structured_field_names_exported(self):
        """The module must export STRUCTURED_FIELD_NAMES with the exact required set."""
        self.assertEqual(set(STRUCTURED_FIELD_NAMES), self.REQUIRED_FIELDS,
                         f"STRUCTURED_FIELD_NAMES mismatch: {STRUCTURED_FIELD_NAMES}")

    def test_long_label_denial_has_all_structured_fields(self):
        """Long-label denial must carry all six structured fields."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = _block_doc(allowed_hosts=[])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "deny")
        for field in self.REQUIRED_FIELDS:
            self.assertTrue(hasattr(result, field),
                            f"DNSDecisionResult missing structured field: {field}")
            self.assertIsNotNone(getattr(result, field),
                                 f"Structured field {field!r} must not be None on denial")

    def test_cardinality_denial_has_all_structured_fields(self):
        """Cardinality denial must carry all six structured fields."""
        apex = "attacker.com"
        now = time.time()
        state = {apex: [now] * (DNS_CARDINALITY_THRESHOLD + 1)}
        doc = _block_doc(allowed_hosts=[])
        result = dns_decide(f"sub.{apex}", doc, state)
        self.assertEqual(result.action, "deny")
        for field in self.REQUIRED_FIELDS:
            self.assertTrue(hasattr(result, field),
                            f"Cardinality denial missing structured field: {field}")
            self.assertIsNotNone(getattr(result, field),
                                 f"Structured field {field!r} must not be None on cardinality denial")

    def test_target_field_contains_qname(self):
        """target field must reference the queried name."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = _block_doc(allowed_hosts=[])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertIn("attacker.com", result.target,
                      f"target must contain the queried domain, got: {result.target!r}")

    def test_fix_command_references_rc_allowlist(self):
        """fix_command must include 'rc allowlist' — the agent-actionable command."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = _block_doc(allowed_hosts=[])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertIn("rc allowlist", result.fix_command,
                      f"fix_command must reference 'rc allowlist', got: {result.fix_command!r}")

    def test_config_file_references_rip_cage_yaml(self):
        """config_file must name .rip-cage.yaml."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = _block_doc(allowed_hosts=[])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertIn(".rip-cage.yaml", result.config_file)

    def test_config_path_references_allowed_hosts(self):
        """config_path must point to network.allowed_hosts in the config."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = _block_doc(allowed_hosts=[])
        result = dns_decide(qname, doc, _fresh_state())
        self.assertIn("network.allowed_hosts", result.config_path)

    def test_allow_result_does_not_need_structured_fields(self):
        """Allow results don't require structured fields."""
        doc = _block_doc(allowed_hosts=["github.com"])
        result = dns_decide("api.github.com", doc, _fresh_state())
        self.assertEqual(result.action, "allow")
        # structured fields may be None/empty for allows — no assertion required


# ---------------------------------------------------------------------------
# (g) unrecognized mode fails closed to block
# ---------------------------------------------------------------------------
class TestUnrecognizedModeFailsClosed(unittest.TestCase):
    def test_bogus_mode_fails_to_block(self):
        """mode='bogus' (unrecognized) must fail-closed to block mode (deny, not would-block)."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = {
            "version": 2,
            "mode": "bogus",
            "allowed_hosts": [],
            "rules": [],
        }
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "deny",
                         "mode='bogus' must fail-closed to block/deny, not return would-block")

    def test_uppercase_observe_normalizes(self):
        """mode='OBSERVE' must normalize to observe (not fail closed)."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = {
            "version": 2,
            "mode": "OBSERVE",
            "allowed_hosts": [],
            "rules": [],
        }
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "would-block",
                         "mode='OBSERVE' must normalize to observe and return would-block")

    def test_uppercase_block_normalizes(self):
        """mode='BLOCK' must normalize to block mode."""
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        qname = f"{long_label}.attacker.com"
        doc = {
            "version": 2,
            "mode": "BLOCK",
            "allowed_hosts": [],
            "rules": [],
        }
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "deny",
                         "mode='BLOCK' must normalize to block and return deny")


# ---------------------------------------------------------------------------
# Apex derivation edge cases
# ---------------------------------------------------------------------------
class TestApexDerivation(unittest.TestCase):
    def test_deeply_nested_subdomain_apex_derived_correctly(self):
        """Apex of deeply nested subdomain must be derived as last two labels."""
        # attacker.com is the apex; github.com is whitelisted
        doc = _block_doc(allowed_hosts=["github.com"])
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        # deeply nested: long.long.long.attacker.com — apex is attacker.com
        qname = f"{long_label}.nested.deeply.attacker.com"
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "deny",
                         "Deeply nested non-whitelisted domain with long label must be denied")

    def test_whitelisted_parent_label_attack_denied(self):
        """github.com.attacker.com must not match whitelisted github.com."""
        doc = _block_doc(allowed_hosts=["github.com"])
        long_label = "a" * (DNS_LABEL_LENGTH_THRESHOLD + 1)
        # attacker puts github.com as a subdomain of their own domain
        qname = f"{long_label}.github.com.attacker.com"
        result = dns_decide(qname, doc, _fresh_state())
        self.assertEqual(result.action, "deny",
                         "Whitelist bypass via parent-label attack must not work")


if __name__ == "__main__":
    unittest.main(verbosity=2)
