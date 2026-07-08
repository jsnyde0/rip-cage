"""
rip_cage_egress.py — decision engine for rip-cage egress enforcement.

Pure destination router (rip-cage-ta1o.1): reads SNI / host from the
connection, allow/denies the DESTINATION. No TLS decryption, no CA, no
per-host cert, no method/path inspection.

Enforcement modes (read from /etc/rip-cage/egress-rules.yaml):
  - block  : default-deny whitelist + IOC floor; denies at the destination level.
  - observe: same logic but lets traffic through; logs would-have-blocked events.
  - legacy : (no 'mode' key, or mode=null) original denylist-only behavior preserved
             exactly — iterate rules, deny on deny:true match, allow everything else.

Destination denial (pure-router contract):
  The router surfaces a connection-refused / TCP-reset at the destination level.
  No structured HTTP 403 body is emitted (the router never decrypts the TLS
  stream). Structured fields (pattern, target, why, fix_command, config_file,
  config_path) are logged to the JSONL audit log for agent-actionable feedback.

Fail-closed: load/parse errors deny all traffic.

Allowed-hosts subdomain semantics: an entry "example.com" in allowed_hosts matches
the exact host "example.com" AND any subdomain "*.example.com". This mirrors the
host_suffix match semantics used in IOC rules. Rationale: baseline lists apex domains
(e.g. "github.com") which must cover their subdomains (e.g. "api.github.com").
"""

import json
import re
import socket
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml

RULES_PATH = "/etc/rip-cage/egress-rules.yaml"
LOG_PATH = "/workspace/.rip-cage/egress.log"

# ---------------------------------------------------------------------------
# Self-test endpoint constants (rip-cage-fft / rip-cage-ta1o.1).
#
# SELFTEST_HOSTNAME is the reserved hostname used by the startup guard in
# init-firewall.sh to verify the router is ON-PATH.  The guard curls this
# host pinned to a guaranteed-unroutable RFC5737 address (192.0.2.1), so
# only an on-path router can return a response.
#
# For the pure-router (HTTP-only, port 80): the router intercepts the
# plain-HTTP request and returns the marker locally without forwarding.
# Port 443 (HTTPS): the router sees the TLS ClientHello, reads the SNI,
# detects the selftest hostname, and sends SELFTEST_TLS_MARKER (a short
# distinctive plaintext byte sequence) before closing the connection.
# This is NOT a TLS handshake — the router cannot generate one — but it
# is enough for the startup selftest probe to detect router on-path presence
# on port 443 by reading the marker bytes (see init-firewall.sh F5 probe).
#
# The startup self-test uses BOTH port 80 (marker response) and port 443
# (SELFTEST_TLS_MARKER) to prove the router is on-path for both redirect rules.
#
# The endpoint is handled BEFORE any allow/deny/mode evaluation (invariant I3):
# it does not depend on egress-rules.yaml content and behaves identically in
# block, legacy, and observe modes.
# ---------------------------------------------------------------------------
SELFTEST_HOSTNAME = "selftest.rip-cage.internal"
SELFTEST_MARKER_HEADER = "X-Rip-Cage-Selftest"
SELFTEST_MARKER_VALUE = "on-path"

# TLS selftest distinctive marker (sent before RST on port 443 for selftest SNI).
# A pure router cannot complete a TLS handshake, so port-443 on-path verification
# uses a short plaintext marker pushed before the connection is closed.
# The startup selftest reads this marker to distinguish "router intercepted and
# responded" (ENFORCED) from "connection went to unroutable 192.0.2.1" (BYPASSED).
# The byte sequence is a comment that is not valid TLS — deliberately not a TLS
# record so the probe can detect it without a TLS library.
SELFTEST_TLS_MARKER = b"rip-cage-selftest:443:on-path\r\n"


@dataclass
class SelftestResponse:
    """Minimal response object returned by handle_selftest_request().

    Attributes:
        status_code: HTTP status code (always 200).
        headers: dict of response headers (always includes the marker header).
    """
    status_code: int
    headers: Dict[str, str]


def handle_selftest_request(hostname: str) -> Optional["SelftestResponse"]:
    """Return a locally-generated marker response for the self-test hostname.

    Returns a SelftestResponse if hostname matches SELFTEST_HOSTNAME, or
    None if the hostname is not the self-test host.

    This function has NO proxy dependency and is fully unit-testable.

    Invariants:
      - (I1) Response is generated locally, no upstream round-trip.
      - (I3) Does not depend on egress-rules.yaml; takes no rules_doc argument.
      - Mode-independent: called before any allow/deny/mode evaluation.
    """
    if not hostname or hostname.lower() != SELFTEST_HOSTNAME.lower():
        return None
    return SelftestResponse(
        status_code=200,
        headers={SELFTEST_MARKER_HEADER: SELFTEST_MARKER_VALUE},
    )


# The six structured fields carried in logged denial records.
# These names are the contract for the agent-actionable repair cycle.
# Note: the pure router cannot return an HTTP 403 body (no TLS decryption),
# but structured fields are written to the JSONL audit log.
STRUCTURED_FIELD_NAMES = [
    "pattern",
    "target",
    "why",
    "fix_command",
    "config_file",
    "config_path",
]


@dataclass
class DecisionResult:
    """Result of decide().

    action: "allow" | "deny" | "would-block"
    rule_id: which rule matched (or synthetic id for whitelist denials)
    in_allowed_hosts: whether the host appeared in allowed_hosts
    pattern: structured field — what rule/criterion triggered
    target: structured field — request target (host)
    why: structured field — human-readable explanation
    fix_command: structured field — agent-actionable command
    config_file: structured field — config file name
    config_path: structured field — YAML path to edit
    """
    action: str
    rule_id: str = ""
    in_allowed_hosts: bool = False
    pattern: Optional[str] = None
    target: Optional[str] = None
    why: Optional[str] = None
    fix_command: Optional[str] = None
    config_file: Optional[str] = None
    config_path: Optional[str] = None


def _host_matches_allowed(host: str, allowed_entry: str) -> bool:
    """Return True if `host` is covered by `allowed_entry`.

    Matching semantics (mirrors host_suffix in _ioc_matches):
      - Exact match: host == allowed_entry  (case-insensitive)
      - Subdomain match: host ends with "." + allowed_entry  (case-insensitive)

    Examples:
      "github.com" matches "github.com"         (exact)
      "api.github.com" matches "github.com"     (subdomain)
      "evil-github.com" does NOT match "github.com"  (not a subdomain)
    """
    host_lower = host.lower()
    entry_lower = allowed_entry.lower()
    return host_lower == entry_lower or host_lower.endswith("." + entry_lower)


def _ioc_matches(rule_match: Any, method: str, host: str, path: str) -> bool:
    """Return True when ALL present match-keys in rule_match pass.

    This is the same logic as the original _matches() method, preserved
    exactly for legacy and IOC-floor matching.

    Note: for a pure destination router, only host-based match-keys are
    meaningful at enforcement time. method_in and path_prefix/path_regex
    keys in existing rules are evaluated here but the router does not
    inspect live traffic at method/path level — these keys in egress-rules.yaml
    have been removed (IOC-floor audit, rip-cage-ta1o.1).
    """
    if not isinstance(rule_match, dict):
        return False
    host_lower = (host or "").lower()
    path_str = path or ""
    method_upper = (method or "").upper()

    # Host exact match
    if "host" in rule_match:
        if host_lower != rule_match["host"].lower():
            return False

    # Host suffix match (e.g. ".ngrok.io" matches "foo.ngrok.io")
    # Also matches the root domain (strip leading dot).
    if "host_suffix" in rule_match:
        suffix_lower = rule_match["host_suffix"].lower()
        if not host_lower.endswith(suffix_lower) and host_lower != suffix_lower.lstrip("."):
            return False

    # Host membership match
    if "host_in" in rule_match:
        if host_lower not in [h.lower() for h in rule_match["host_in"]]:
            return False

    # Path prefix match (evaluated but not applicable in pure-router enforcement)
    if "path_prefix" in rule_match:
        if not path_str.startswith(rule_match["path_prefix"]):
            return False

    # Path regex match (evaluated but not applicable in pure-router enforcement)
    if "path_regex" in rule_match:
        if not re.search(rule_match["path_regex"], path_str):
            return False

    # Method membership match (evaluated but not applicable in pure-router enforcement)
    if "method_in" in rule_match:
        allowed = [m.upper() for m in rule_match["method_in"]]
        if method_upper not in allowed:
            return False

    return True


def _make_allow(host: str, in_allowed_hosts: bool = True) -> DecisionResult:
    return DecisionResult(
        action="allow",
        rule_id="",
        in_allowed_hosts=in_allowed_hosts,
    )


def _make_block_or_observe(
    action: str,
    rule_id: str,
    host: str,
    path: str,
    why_text: str,
    pattern_text: str,
    in_allowed_hosts: bool,
) -> DecisionResult:
    """Build a deny or would-block result with all six structured fields populated."""
    target = host  # Pure router: destination is the host, no path visibility
    fix_command = f"rc allowlist add {host} --cage=<cage-name>"
    return DecisionResult(
        action=action,
        rule_id=rule_id,
        in_allowed_hosts=in_allowed_hosts,
        pattern=pattern_text,
        target=target,
        why=why_text,
        fix_command=fix_command,
        config_file=".rip-cage.yaml",
        config_path="network.allowed_hosts",
    )


def decide(
    host: str,
    method: str,
    path: str,
    rules_doc: Optional[Dict],
) -> DecisionResult:
    """
    Pure decision function: given a destination host and a parsed rules document,
    return a DecisionResult indicating allow, deny, or would-block.

    Pure destination router (rip-cage-ta1o.1):
      - Only the destination host is evaluated (allow/deny by host).
      - method and path parameters are accepted for API compatibility and
        legacy/IOC rule evaluation, but are NOT used for write-gating.
      - Method-asymmetry (writable_hosts write-gate) is REMOVED.
      - POST to an allowlisted host is identical to GET.

    This function has no proxy dependency and is fully unit-testable.

    Rules doc formats supported:
      Version 2 (block/observe):
        version: 2
        mode: "block" | "observe"
        allowed_hosts: [...]
        rules: [...]   # IOC floor (host-based rules only after ta1o.1)

      Legacy (no mode or mode=null):
        version: 1 (or 2 with mode absent/null)
        rules: [...]   # denylist only

    Precedence for block/observe mode:
      1. IOC floor (deny:true rules) — highest priority, non-overridable
      2. allowed_hosts whitelist — determines default-deny vs allow
    """
    if rules_doc is None:
        # Fail-closed: no doc -> deny
        return _make_block_or_observe(
            action="deny",
            rule_id="internal-error",
            host=host or "",
            path=path or "",
            why_text="No rules document available (fail-closed)",
            pattern_text="no-rules-doc",
            in_allowed_hosts=False,
        )

    host = (host or "").strip()
    method = (method or "").upper()
    path = (path or "")

    # Determine mode: "block", "observe", or None (legacy)
    mode = rules_doc.get("mode")  # None if key absent or value is null

    # Normalize non-None mode values defensively.
    # Only exact lowercase "observe" and "block" are recognized.
    # Any other non-None value fails-closed to "block" (stricter than legacy).
    if mode is not None:
        mode_norm = str(mode).strip().lower()
        if mode_norm == "observe":
            mode = "observe"
        elif mode_norm == "block":
            mode = "block"
        else:
            print(
                f"rip-cage egress: unrecognized mode value {mode!r} — failing closed to 'block'",
                file=sys.stderr,
            )
            mode = "block"

    # --- LEGACY MODE ---
    # mode absent or null: iterate rules denylist, allow everything else
    if mode is None:
        rules = rules_doc.get("rules", []) or []
        for rule in rules:
            if not rule.get("deny", False):
                continue
            match = rule.get("match", {})
            if _ioc_matches(match, method, host, path):
                reason = rule.get("reason", "")
                rule_id = rule.get("id", "unknown")
                return _make_block_or_observe(
                    action="deny",
                    rule_id=rule_id,
                    host=host,
                    path=path,
                    why_text=f"Rule {rule_id!r}: {reason}" if reason else f"Matched deny rule {rule_id!r}",
                    pattern_text=str(rule.get("match", {})),
                    in_allowed_hosts=False,
                )
        return _make_allow(host, in_allowed_hosts=False)

    # --- BLOCK / OBSERVE MODE ---
    # Phase 1: Check IOC floor (deny:true rules — non-overridable)
    ioc_rules = rules_doc.get("rules", []) or []
    for rule in ioc_rules:
        if not rule.get("deny", False):
            continue
        match = rule.get("match", {})
        if _ioc_matches(match, method, host, path):
            reason = rule.get("reason", "")
            rule_id = rule.get("id", "unknown")
            # IOC floor: host may be in allowed_hosts — still denied
            in_allowed = any(
                _host_matches_allowed(host, entry)
                for entry in (rules_doc.get("allowed_hosts") or [])
            )
            effective_action = "would-block" if mode == "observe" else "deny"
            return _make_block_or_observe(
                action=effective_action,
                rule_id=rule_id,
                host=host,
                path=path,
                why_text=(
                    f"IOC floor rule {rule_id!r}: {reason}"
                    if reason
                    else f"Matched IOC deny rule {rule_id!r}"
                ),
                pattern_text=str(rule.get("match", {})),
                in_allowed_hosts=in_allowed,
            )

    # Phase 2: Whitelist check (destination-only)
    allowed_hosts = rules_doc.get("allowed_hosts") or []
    in_allowed = any(_host_matches_allowed(host, entry) for entry in allowed_hosts)

    if not in_allowed:
        # Not whitelisted — default-deny
        effective_action = "would-block" if mode == "observe" else "deny"
        return _make_block_or_observe(
            action=effective_action,
            rule_id="not-whitelisted",
            host=host,
            path=path,
            why_text=f"Host {host!r} is not in the allowed_hosts whitelist",
            pattern_text="allowed_hosts",
            in_allowed_hosts=False,
        )

    # Phase 3: Allowed — no write-gate (method-asymmetry removed in rip-cage-ta1o.1)
    return _make_allow(host, in_allowed_hosts=True)


def _log_denial(
    host: str,
    result: DecisionResult,
    method: str = "",
    path: str = "",
) -> None:
    """Append a JSONL denial record to LOG_PATH. Silent on ALL exceptions."""
    try:
        log_path = Path(LOG_PATH)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        record = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "event": "deny",
            "rule_id": result.rule_id,
            "host": host,
            "container_hostname": socket.gethostname(),
            "pattern": result.pattern,
            "target": result.target,
            "why": result.why,
            "fix_command": result.fix_command,
            "config_file": result.config_file,
            "config_path": result.config_path,
        }
        with log_path.open("a") as f:
            f.write(json.dumps(record) + "\n")
    except Exception:
        pass  # Never let logging failure affect router operation


def _log_observe(
    host: str,
    result: DecisionResult,
    method: str = "",
    path: str = "",
) -> None:
    """Log a would-have-blocked event (observe mode). Silent on ALL exceptions."""
    try:
        log_path = Path(LOG_PATH)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        record = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "event": "would-block",
            "rule_id": result.rule_id,
            "host": host,
            "in_allowed_hosts": result.in_allowed_hosts,
            "container_hostname": socket.gethostname(),
            "pattern": result.pattern,
            "target": result.target,
            "why": result.why,
            "fix_command": result.fix_command,
            "config_file": result.config_file,
            "config_path": result.config_path,
        }
        with log_path.open("a") as f:
            f.write(json.dumps(record) + "\n")
    except Exception:
        pass  # Never let logging failure affect router operation
