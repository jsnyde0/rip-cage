import json
import re
import socket
import time
from pathlib import Path

import yaml
from mitmproxy import http

RULES_PATH = "/etc/rip-cage/egress-rules.yaml"
LOG_PATH = "/workspace/.rip-cage/egress.log"


class EgressFirewall:
    def __init__(self):
        # FAIL-CLOSED: if _load_rules raises, mitmproxy startup fails.
        # iptables REDIRECT then causes connection refused for all traffic --
        # no silent bypass.
        self.rules = self._load_rules()

    def _load_rules(self):
        """Load and validate rules from YAML. Raise on any error (fail-closed)."""
        data = yaml.safe_load(Path(RULES_PATH).read_text())
        if not isinstance(data, dict):
            raise ValueError(f"Rule file {RULES_PATH}: expected a YAML mapping")
        if "rules" not in data:
            raise ValueError(f"Rule file {RULES_PATH}: missing 'rules' key")
        if not isinstance(data["rules"], list):
            raise ValueError(f"Rule file {RULES_PATH}: 'rules' must be a list")
        return data["rules"]

    def _matches(self, rule_match, method, host, path):
        """
        Return True only when ALL present match-keys in rule_match pass.
        Missing match-key = wildcard (matches any value for that dimension).
        Comparisons: host is case-insensitive; path is case-sensitive.

        Edge cases handled:
          - Empty/None host: treated as empty string (never matches host rules).
          - Empty/None path: treated as empty string (never matches path rules).
          - Empty/None method: treated as empty string (never matches method_in).
          - Non-dict rule_match: treated as no match (returns False).
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

        # Host suffix match (e.g. ".ngrok.io" matches "foo.ngrok.io").
        # Also match the root domain itself (e.g. ".ngrok.io" matches "ngrok.io")
        # by comparing host to the suffix with the leading dot stripped.
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

    def request(self, flow: http.HTTPFlow) -> None:
        """
        Evaluate denylist rules pre-upstream (before connecting to the real server).
        Wrapped entirely in try/except: any unexpected error denies the request
        (fail-closed) rather than crashing the proxy or allowing traffic through.
        """
        try:
            # Safely extract request fields -- each may be None/empty on malformed
            # requests (e.g. missing Host header, binary body, raw IP target).
            method = flow.request.method or ""
            # pretty_host decodes IDNA; fall back to raw host if unavailable.
            host = flow.request.pretty_host or flow.request.host or ""
            path = flow.request.path or ""

            for rule in self.rules:
                if not rule.get("deny", False):
                    continue
                match = rule.get("match", {})
                if self._matches(match, method, host, path):
                    self._deny(
                        flow,
                        rule.get("id", "unknown"),
                        rule.get("reason", ""),
                        method,
                        host,
                        path,
                    )
                    return
        except Exception as exc:
            # Fail-closed: deny rather than crash or allow
            self._deny(
                flow,
                "internal-error",
                f"Rule evaluation error: {type(exc).__name__}",
                getattr(flow.request, "method", "") or "",
                getattr(flow.request, "pretty_host", "") or "",
                getattr(flow.request, "path", "") or "",
            )

    def _deny(
        self,
        flow: http.HTTPFlow,
        rule_id: str,
        reason: str,
        method: str,
        host: str,
        path: str,
    ) -> None:
        body = (
            f"Blocked by rip-cage egress firewall.\n"
            f"Rule: {rule_id}\n"
            f"Reason: {reason}\n"
            f"Override: set RIP_CAGE_EGRESS=off and restart the container.\n"
            f"Docs: https://github.com/jsnyde0/rip-cage/blob/main/docs/reference/egress-firewall.md\n"
        )
        flow.response = http.Response.make(
            403,
            body,
            {
                "Content-Type": "text/plain",
                "X-Rip-Cage-Denied": rule_id,
            },
        )
        self._log_denial(rule_id, method, host, path)

    def _log_denial(self, rule_id: str, method: str, host: str, path: str) -> None:
        """
        Append a JSONL denial record to LOG_PATH.
        Silent on ALL exceptions -- log failure must never affect proxy operation.
        path is truncated to 500 chars to prevent unbounded log growth from
        crafted long URLs.
        """
        try:
            log_path = Path(LOG_PATH)
            log_path.parent.mkdir(parents=True, exist_ok=True)
            record = {
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "rule_id": rule_id,
                "method": method,
                "host": host,
                "path": path[:500],
                "container_hostname": socket.gethostname(),
            }
            with log_path.open("a") as f:
                f.write(json.dumps(record) + "\n")
        except Exception:
            pass  # Never let logging failure affect proxy operation


addons = [EgressFirewall()]
