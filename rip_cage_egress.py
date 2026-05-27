"""
rip_cage_egress.py — mitmproxy addon for rip-cage egress enforcement.

Enforcement modes (read from /etc/rip-cage/egress-rules.yaml):
  - block  : default-deny whitelist + IOC floor; denies with 403 + structured JSON body.
  - observe: same logic but lets traffic through; logs would-have-blocked events.
  - legacy : (no 'mode' key, or mode=null) original denylist-only behavior preserved
             exactly — iterate rules, deny on deny:true match, allow everything else.

Structured denial fields (epic D11 contract):
  pattern      — what rule/criterion triggered the denial
  target       — the request target (host + path)
  why          — human-readable explanation
  fix_command  — agent-actionable command to unblock the host
  config_file  — config file to edit (always .rip-cage.yaml)
  config_path  — YAML path within config_file (always network.allowed_hosts)

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

# The six structured fields that every denial/would-block must carry.
# These names are the contract for the integration harness and host-agent repair cycle.
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
    target: structured field — request target (host[:path])
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

    # Path prefix match
    if "path_prefix" in rule_match:
        if not path_str.startswith(rule_match["path_prefix"]):
            return False

    # Path regex match
    if "path_regex" in rule_match:
        if not re.search(rule_match["path_regex"], path_str):
            return False

    # Method membership match
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
    target = f"{host}{path}" if path and path != "/" else host
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


def _make_write_gate_denial(
    action: str,
    host: str,
    path: str,
    method: str,
) -> DecisionResult:
    """Build a deny or would-block result for a write-gate violation.

    Used when a write method (POST/PUT/DELETE/PATCH) targets a host that is in
    allowed_hosts but NOT in writable_hosts (and writable_hosts is non-empty).
    """
    target = f"{host}{path}" if path and path != "/" else host
    fix_command = (
        f"Add {host!r} to network.writable_hosts in .rip-cage.yaml to allow write methods"
    )
    return DecisionResult(
        action=action,
        rule_id="write-method-not-writable",
        in_allowed_hosts=True,
        pattern="writable_hosts",
        target=target,
        why=(
            f"Write method {method!r} is not allowed to {host!r}: "
            f"host is in allowed_hosts but not in writable_hosts"
        ),
        fix_command=fix_command,
        config_file=".rip-cage.yaml",
        config_path="network.writable_hosts",
    )


# Write methods that are gated by writable_hosts.
_WRITE_METHODS = frozenset({"POST", "PUT", "DELETE", "PATCH"})


def decide(
    host: str,
    method: str,
    path: str,
    rules_doc: Optional[Dict],
) -> DecisionResult:
    """
    Pure decision function: given request fields and a parsed rules document,
    return a DecisionResult indicating allow, deny, or would-block.

    This function has no mitmproxy dependency and is fully unit-testable.

    Rules doc formats supported:
      Version 2 (block/observe):
        version: 2
        mode: "block" | "observe"
        allowed_hosts: [...]
        rules: [...]   # IOC floor

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

    # Phase 2: Whitelist check
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

    # Phase 3: Write-method gate (only when writable_hosts is non-empty)
    # If writable_hosts is empty (the default), no write gating is applied —
    # preserving the autonomy default (all methods flow freely to allowed hosts).
    writable_hosts = rules_doc.get("writable_hosts") or []
    if writable_hosts and method in _WRITE_METHODS:
        in_writable = any(_host_matches_allowed(host, entry) for entry in writable_hosts)
        if not in_writable:
            effective_action = "would-block" if mode == "observe" else "deny"
            return _make_write_gate_denial(
                action=effective_action,
                host=host,
                path=path,
                method=method,
            )

    return _make_allow(host, in_allowed_hosts=True)


# ---------------------------------------------------------------------------
# mitmproxy addon — only loaded when mitmproxy is available (inside the proxy)
# ---------------------------------------------------------------------------
try:
    from mitmproxy import http as _http

    class EgressFirewall:
        def __init__(self):
            # FAIL-CLOSED: if _load_rules raises, mitmproxy startup fails.
            # iptables REDIRECT then causes connection refused for all traffic --
            # no silent bypass.
            self.rules_doc = self._load_rules()

        def _load_rules(self) -> Dict:
            """Load and validate rules from YAML. Raise on any error (fail-closed)."""
            data = yaml.safe_load(Path(RULES_PATH).read_text())
            if not isinstance(data, dict):
                raise ValueError(f"Rule file {RULES_PATH}: expected a YAML mapping")
            if "rules" not in data:
                raise ValueError(f"Rule file {RULES_PATH}: missing 'rules' key")
            if not isinstance(data["rules"], list):
                raise ValueError(f"Rule file {RULES_PATH}: 'rules' must be a list")
            return data

        def request(self, flow: _http.HTTPFlow) -> None:
            """
            Evaluate egress rules pre-upstream (before connecting to the real server).
            Wrapped entirely in try/except: any unexpected error denies the request
            (fail-closed) rather than crashing the proxy or allowing traffic through.
            """
            try:
                method = flow.request.method or ""
                host = flow.request.pretty_host or flow.request.host or ""
                path = flow.request.path or ""

                result = decide(host, method, path, self.rules_doc)

                if result.action == "deny":
                    self._deny(flow, result)
                elif result.action == "would-block":
                    # Observe mode: let through but log
                    self._log_observe(result, method, host, path)
                # allow: no action needed

            except Exception as exc:
                # Fail-closed: deny rather than crash or allow
                err_result = _make_block_or_observe(
                    action="deny",
                    rule_id="internal-error",
                    host=getattr(flow.request, "pretty_host", "") or "",
                    path=getattr(flow.request, "path", "") or "",
                    why_text=f"Rule evaluation error: {type(exc).__name__}: {exc}",
                    pattern_text="internal-error",
                    in_allowed_hosts=False,
                )
                self._deny(flow, err_result)

        def _build_denial_body(self, result: DecisionResult) -> bytes:
            """Build the 403 response body: JSON + human-readable fallback."""
            structured = {
                "blocked_by": "rip-cage egress firewall",
                "rule_id": result.rule_id,
                "pattern": result.pattern,
                "target": result.target,
                "why": result.why,
                "fix_command": result.fix_command,
                "config_file": result.config_file,
                "config_path": result.config_path,
            }
            json_part = json.dumps(structured, indent=2)
            human_part = (
                f"\n\n---\n"
                f"Blocked by rip-cage egress firewall.\n"
                f"Rule: {result.rule_id}\n"
                f"Why: {result.why}\n"
                f"Fix: {result.fix_command}\n"
                f"Config: {result.config_file} @ {result.config_path}\n"
                f"Docs: https://github.com/jsnyde0/rip-cage/blob/main/docs/reference/egress-firewall.md\n"
            )
            return (json_part + human_part).encode()

        def _deny(self, flow: _http.HTTPFlow, result: DecisionResult) -> None:
            body = self._build_denial_body(result)
            flow.response = _http.Response.make(
                403,
                body,
                {
                    "Content-Type": "application/json",
                    "X-Rip-Cage-Denied": result.rule_id,
                },
            )
            self._log_denial(result, flow.request.method or "", flow.request.path or "")

        def _log_denial(
            self,
            result: DecisionResult,
            method: str,
            path: str,
        ) -> None:
            """Append a JSONL denial record to LOG_PATH. Silent on ALL exceptions."""
            try:
                log_path = Path(LOG_PATH)
                log_path.parent.mkdir(parents=True, exist_ok=True)
                record = {
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "event": "deny",
                    "rule_id": result.rule_id,
                    "method": method,
                    "host": result.target or "",
                    "path": path[:500],
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
                pass  # Never let logging failure affect proxy operation

        def _log_observe(
            self,
            result: DecisionResult,
            method: str,
            host: str,
            path: str,
        ) -> None:
            """Log a would-have-blocked event (observe mode). Silent on ALL exceptions."""
            try:
                log_path = Path(LOG_PATH)
                log_path.parent.mkdir(parents=True, exist_ok=True)
                record = {
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "event": "would-block",
                    "rule_id": result.rule_id,
                    "method": method,
                    "host": host,
                    "path": path[:500],
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
                pass  # Never let logging failure affect proxy operation

    addons = [EgressFirewall()]

except ModuleNotFoundError:
    # mitmproxy not installed — pure-function mode (unit tests, host-side tools).
    # addons list is intentionally absent: this module is only partially loaded.
    pass
