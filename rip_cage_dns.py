"""
rip_cage_dns.py — DNS resolver sidecar for rip-cage egress enforcement.

Implements ADR-012 D9: transparent DNS exfil inspection layer.

Architecture mirror of rip_cage_egress.py:
  - Pure decision function dns_decide() (no dnspython dependency) — unit-testable.
  - Network server loop (requires dnspython) — wraps dns_decide().
  - Fail-closed: if rules can't be loaded or sidecar can't start, DNS fails.
  - Mode-aware: block / observe / legacy (mode absent/null = no DNS inspection).
  - Shared rules file and JSONL log format as the HTTP egress proxy.

DNS exfil heuristics (applied to NON-whitelisted apexes only):
  1. Long-label heuristic: any subdomain label exceeding DNS_LABEL_LENGTH_THRESHOLD
     characters is flagged as encoding-shaped. Threshold is an implementation detail
     per ADR-012 D9 — documented as a module constant so it can be tuned.
  2. Cardinality heuristic: more than DNS_CARDINALITY_THRESHOLD queries against a
     single apex within DNS_CARDINALITY_WINDOW_SECS seconds is flagged as a burst
     (C2/exfil fan-out pattern).

Whitelisted apex behavior:
  If the query's apex (or the FQDN itself) matches an allowed_hosts entry (exact or
  subdomain match, same semantics as the HTTP egress proxy), the query passes
  unconditionally — no heuristic is applied.

Clean non-whitelisted queries:
  A clean (short labels, low cardinality) query to a non-whitelisted apex is
  FORWARDED upstream. DNS resolution itself is not blocked by the whitelist —
  only exfil-SHAPED queries are refused. The HTTP/TCP egress layer handles
  connection-level whitelist enforcement.

Apex derivation:
  The apex is computed from the last two DNS labels of the FQDN (e.g.
  "foo.bar.attacker.com" → apex "attacker.com"). This is a deliberate simplification:
  it's correct for the vast majority of domains (ccTLDs like .co.uk would need more
  labels, but are uncommon in exfil contexts) and avoids a full Public Suffix List
  dependency. The simplification is noted as an implementation detail per ADR-012 D9.

Structured denial fields (epic D11 contract — same as HTTP egress proxy):
  pattern      — what heuristic triggered (label-length or cardinality)
  target       — the queried FQDN
  why          — human-readable explanation
  fix_command  — agent-actionable command to unblock the host
  config_file  — config file to edit (always .rip-cage.yaml)
  config_path  — YAML path within config_file (always network.allowed_hosts)
"""

import json
import os
import socket
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

import yaml

RULES_PATH = "/etc/rip-cage/egress-rules.yaml"
LOG_PATH = "/workspace/.rip-cage/egress-dns.log"

# ---------------------------------------------------------------------------
# Heuristic thresholds — implementation detail per ADR-012 D9.
# These are conservative defaults: tunable by changing these constants.
# ---------------------------------------------------------------------------

# A subdomain label longer than this is considered encoding-shaped.
# Rationale: base32-encoded data labels are typically 40–60 chars (8 bytes/label at
# base32 = 16 chars; DNS exfil tools pack more). 30 chars is conservative — it
# allows labels like "files.pythonhosted.org" style paths (typically <20 chars)
# while catching typical base32/base64 encoded payloads.
DNS_LABEL_LENGTH_THRESHOLD: int = 30

# Number of queries to a single apex within the window before triggering cardinality block.
# Rationale: legitimate dev tools rarely fan out >20 subdomains in 1 second to a single
# apex. DNS exfil tools often send 100+ queries/second. 20 is intentionally generous.
DNS_CARDINALITY_THRESHOLD: int = 20

# Time window (in seconds) for cardinality counting.
DNS_CARDINALITY_WINDOW_SECS: float = 1.0

# The six structured fields that every denial/would-block must carry.
# These names are the contract (same as rip_cage_egress.py STRUCTURED_FIELD_NAMES).
STRUCTURED_FIELD_NAMES = [
    "pattern",
    "target",
    "why",
    "fix_command",
    "config_file",
    "config_path",
]


@dataclass
class DNSDecisionResult:
    """Result of dns_decide().

    action: "allow" | "deny" | "would-block"
    heuristic: which heuristic triggered ("label-length" | "cardinality" | "")
    apex: the derived apex domain for this query
    pattern: structured field — what heuristic/criterion triggered
    target: structured field — queried FQDN
    why: structured field — human-readable explanation
    fix_command: structured field — agent-actionable command
    config_file: structured field — config file name
    config_path: structured field — YAML path to edit
    """
    action: str
    heuristic: str = ""
    apex: str = ""
    pattern: Optional[str] = None
    target: Optional[str] = None
    why: Optional[str] = None
    fix_command: Optional[str] = None
    config_file: Optional[str] = None
    config_path: Optional[str] = None


def _derive_apex(qname: str) -> str:
    """Derive the apex (registrable domain) from an FQDN.

    Implementation: use the last two DNS labels. This is correct for the
    vast majority of domains (.com, .net, .org, .io, etc.). ccTLDs with two
    levels (.co.uk, .com.au) would need three labels, but are uncommon in
    DNS exfil contexts and are an accepted limitation documented in the module
    docstring (ADR-012 D9: implementation detail).

    Returns the apex in lowercase. Trailing dot (FQDN) is stripped.
    """
    # Strip trailing dot (FQDN form: "foo.com." -> "foo.com")
    name = qname.rstrip(".").lower()
    labels = name.split(".")
    if len(labels) < 2:
        return name  # single label or empty — just return as-is
    return ".".join(labels[-2:])


def _host_matches_allowed(host: str, allowed_entry: str) -> bool:
    """Return True if `host` is covered by `allowed_entry`.

    Mirrors rip_cage_egress._host_matches_allowed exactly:
      - Exact match: host == allowed_entry  (case-insensitive)
      - Subdomain match: host ends with "." + allowed_entry  (case-insensitive)
    """
    host_lower = host.lower().rstrip(".")
    entry_lower = allowed_entry.lower().rstrip(".")
    return host_lower == entry_lower or host_lower.endswith("." + entry_lower)


def _is_whitelisted(qname: str, allowed_hosts: List[str]) -> bool:
    """Return True if the query's FQDN (or its apex) is covered by allowed_hosts."""
    # Check if the exact qname matches any allowed_hosts entry (covers apex-only queries too)
    # and also check if any label/subdomain hierarchy is covered.
    return any(_host_matches_allowed(qname, entry) for entry in allowed_hosts)


def _make_allow() -> DNSDecisionResult:
    return DNSDecisionResult(action="allow")


def _make_block_or_observe(
    action: str,
    heuristic: str,
    qname: str,
    apex: str,
    why_text: str,
    pattern_text: str,
) -> DNSDecisionResult:
    """Build a deny or would-block DNS result with all six structured fields populated."""
    fix_command = f"rc allowlist add {apex} --cage=<cage-name>"
    return DNSDecisionResult(
        action=action,
        heuristic=heuristic,
        apex=apex,
        pattern=pattern_text,
        target=qname,
        why=why_text,
        fix_command=fix_command,
        config_file=".rip-cage.yaml",
        config_path="network.allowed_hosts",
    )


def dns_decide(
    qname: str,
    rules_doc: Optional[Dict],
    recent_query_state: Dict,
) -> DNSDecisionResult:
    """
    Pure DNS decision function: given a queried name, a parsed rules document,
    and recent-query state (for cardinality tracking), return a DNSDecisionResult.

    This function has NO dnspython/socket dependency and is fully unit-testable.

    The recent_query_state dict maps apex -> list[float] (unix timestamps of recent
    queries for that apex). Callers update the state after a decision (the function
    does NOT mutate it — pure function).

    Rules doc formats supported:
      Version 2 (block/observe):
        version: 2
        mode: "block" | "observe"
        allowed_hosts: [...]
        ...

      Legacy (no mode or mode=null):
        => no DNS inspection; forward everything (pure passthrough)

    Decision flow for block/observe mode:
      1. Whitelist check: if qname (or its apex) is in allowed_hosts → allow (unconditional)
      2. Long-label check: any label > DNS_LABEL_LENGTH_THRESHOLD → deny/would-block
      3. Cardinality check: recent apex count > DNS_CARDINALITY_THRESHOLD → deny/would-block
      4. Clean query → allow (forward upstream)

    Fail-closed: None rules_doc → deny.
    """
    if rules_doc is None:
        return _make_block_or_observe(
            action="deny",
            heuristic="no-rules-doc",
            qname=qname or "",
            apex="",
            why_text="No rules document available (fail-closed)",
            pattern_text="no-rules-doc",
        )

    qname = (qname or "").strip()

    # Determine mode: "block", "observe", or None (legacy)
    mode = rules_doc.get("mode")

    # Normalize non-None mode values defensively.
    if mode is not None:
        mode_norm = str(mode).strip().lower()
        if mode_norm == "observe":
            mode = "observe"
        elif mode_norm == "block":
            mode = "block"
        else:
            print(
                f"rip-cage dns: unrecognized mode value {mode!r} — failing closed to 'block'",
                file=sys.stderr,
            )
            mode = "block"

    # --- LEGACY MODE (mode absent or null): no DNS inspection, pure passthrough ---
    if mode is None:
        return _make_allow()

    # --- BLOCK / OBSERVE MODE ---
    allowed_hosts = rules_doc.get("allowed_hosts") or []

    # Step 1: Whitelist check — whitelisted apexes pass unconditionally
    if _is_whitelisted(qname, allowed_hosts):
        return _make_allow()

    # Derive apex for heuristic checks (only applied to non-whitelisted queries)
    apex = _derive_apex(qname)

    # Also check if the derived apex itself is whitelisted (handles long subdomains
    # under whitelisted parents that the full-name check already catches, but
    # explicit apex check is clearer)
    # Note: _is_whitelisted already handles subdomain matching, so this is redundant
    # but harmless. Keeping for clarity.

    effective_action = "would-block" if mode == "observe" else "deny"

    # Step 2: Long-label heuristic — check each label in the FQDN
    name_stripped = qname.rstrip(".")
    labels = name_stripped.split(".")
    for label in labels:
        if len(label) > DNS_LABEL_LENGTH_THRESHOLD:
            return _make_block_or_observe(
                action=effective_action,
                heuristic="label-length",
                qname=qname,
                apex=apex,
                why_text=(
                    f"DNS query {qname!r}: subdomain label {label!r} exceeds length threshold "
                    f"({len(label)} > {DNS_LABEL_LENGTH_THRESHOLD}) — exfil-encoding shape detected"
                ),
                pattern_text=f"label-length:{DNS_LABEL_LENGTH_THRESHOLD}",
            )

    # Step 3: Cardinality heuristic — count recent queries for this apex in window
    now = time.time()
    window_start = now - DNS_CARDINALITY_WINDOW_SECS
    recent_for_apex = recent_query_state.get(apex, [])
    count_in_window = sum(1 for ts in recent_for_apex if ts >= window_start)
    if count_in_window > DNS_CARDINALITY_THRESHOLD:
        return _make_block_or_observe(
            action=effective_action,
            heuristic="cardinality",
            qname=qname,
            apex=apex,
            why_text=(
                f"DNS query {qname!r}: cardinality burst for apex {apex!r} — "
                f"{count_in_window} queries in {DNS_CARDINALITY_WINDOW_SECS}s "
                f"(threshold: {DNS_CARDINALITY_THRESHOLD})"
            ),
            pattern_text=f"cardinality:{DNS_CARDINALITY_THRESHOLD}",
        )

    # Step 4: Clean query — forward upstream
    return _make_allow()


# ---------------------------------------------------------------------------
# Rules loading
# ---------------------------------------------------------------------------

def _load_rules(rules_path: str = RULES_PATH) -> Dict:
    """Load and validate rules from YAML. Raise on any error (fail-closed)."""
    data = yaml.safe_load(Path(rules_path).read_text())
    if not isinstance(data, dict):
        raise ValueError(f"Rule file {rules_path}: expected a YAML mapping")
    # DNS sidecar only needs mode and allowed_hosts; rules/IOC floor is HTTP-layer concern.
    # We accept a dict with any keys but do NOT require 'rules' (unlike the HTTP addon).
    return data


# ---------------------------------------------------------------------------
# DNS network server — only loaded when dnspython is available
# ---------------------------------------------------------------------------
try:
    import threading

    import dns.message
    import dns.name
    import dns.opcode
    import dns.query
    import dns.rdatatype
    import dns.resolver

    # Default upstream DNS resolver (system-configured)
    _UPSTREAM_DNS = "8.8.8.8"
    _UPSTREAM_PORT = 53

    _LISTEN_HOST = "127.0.0.1"
    _LISTEN_PORT = 5300

    # Shared recent-query state (protected by lock)
    _state_lock = threading.Lock()
    _recent_query_state: Dict = {}

    def _update_state(apex: str) -> None:
        """Record a query for apex in _recent_query_state (thread-safe)."""
        now = time.time()
        window_start = now - DNS_CARDINALITY_WINDOW_SECS
        with _state_lock:
            existing = _recent_query_state.get(apex, [])
            # Prune stale entries
            fresh = [ts for ts in existing if ts >= window_start]
            fresh.append(now)
            _recent_query_state[apex] = fresh

    def _get_state_snapshot() -> Dict:
        """Return a shallow snapshot of the current recent-query state (thread-safe)."""
        with _state_lock:
            return {k: list(v) for k, v in _recent_query_state.items()}

    def _log_dns_event(event: str, result: DNSDecisionResult) -> None:
        """Append a JSONL record to LOG_PATH. Silent on ALL exceptions."""
        try:
            log_path = Path(LOG_PATH)
            log_path.parent.mkdir(parents=True, exist_ok=True)
            record = {
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "event": event,
                "layer": "dns",
                "qname": result.target or "",
                "apex": result.apex or "",
                "heuristic": result.heuristic or "",
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
            pass  # Never let logging failure affect DNS operation

    def _forward_query(request: "dns.message.Message") -> "dns.message.Message":
        """Forward a DNS query to the upstream resolver and return the response."""
        response = dns.query.udp(request, _UPSTREAM_DNS, port=_UPSTREAM_PORT, timeout=5)
        return response

    def _make_refused_response(request: "dns.message.Message") -> bytes:
        """Build a REFUSED response for a blocked DNS query."""
        response = dns.message.make_response(request)
        response.set_rcode(dns.rcode.REFUSED)
        return response.to_wire()

    def _handle_dns_query(data: bytes, rules_doc: Dict) -> bytes:
        """Process a raw DNS query datagram. Returns the raw response bytes."""
        try:
            request = dns.message.from_wire(data)
        except Exception:
            return b""  # Malformed query — drop

        # Only handle standard queries
        if request.opcode() != dns.opcode.QUERY:
            try:
                return _forward_query(request).to_wire()
            except Exception:
                return _make_refused_response(request)

        # Extract first question name
        if not request.question:
            return _make_refused_response(request)

        qname = str(request.question[0].name).rstrip(".")

        # Get cardinality snapshot
        state_snapshot = _get_state_snapshot()
        result = dns_decide(qname, rules_doc, state_snapshot)

        # Update cardinality state for this apex (regardless of decision)
        apex = _derive_apex(qname)
        _update_state(apex)

        if result.action == "deny":
            _log_dns_event("deny", result)
            return _make_refused_response(request)
        elif result.action == "would-block":
            _log_dns_event("would-block", result)
            # Observe mode: fall through and forward the query
        # allow or would-block: forward upstream
        try:
            upstream_response = _forward_query(request)
            return upstream_response.to_wire()
        except Exception as exc:
            # Fail-closed on upstream errors: return REFUSED
            err_result = DNSDecisionResult(
                action="deny",
                heuristic="upstream-error",
                apex=apex,
                pattern="upstream-error",
                target=qname,
                why=f"Upstream DNS error: {exc}",
                fix_command=f"rc allowlist add {apex} --cage=<cage-name>",
                config_file=".rip-cage.yaml",
                config_path="network.allowed_hosts",
            )
            _log_dns_event("upstream-error", err_result)
            return _make_refused_response(request)

    def run_dns_server(rules_path: str = RULES_PATH) -> None:
        """
        Start the DNS resolver sidecar.

        Fail-closed: if rules cannot be loaded, raise immediately so the caller
        (restart loop) knows not to silently continue in an unprotected state.
        """
        rules_doc = _load_rules(rules_path)

        import socket as _socket
        sock = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
        sock.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
        sock.bind((_LISTEN_HOST, _LISTEN_PORT))
        print(
            f"rip-cage dns sidecar listening on {_LISTEN_HOST}:{_LISTEN_PORT}",
            flush=True,
        )

        while True:
            try:
                data, addr = sock.recvfrom(512)
                response = _handle_dns_query(data, rules_doc)
                if response:
                    sock.sendto(response, addr)
            except Exception as exc:
                print(f"rip-cage dns: error handling query: {exc}", file=sys.stderr)
                continue

    if __name__ == "__main__":
        # Entry point when invoked directly by rip-dns-start.sh
        import signal

        def _shutdown(sig, frame):
            print("rip-cage dns sidecar shutting down", flush=True)
            sys.exit(0)

        signal.signal(signal.SIGTERM, _shutdown)
        signal.signal(signal.SIGINT, _shutdown)

        rules_path_env = os.environ.get("RIP_CAGE_RULES_PATH", RULES_PATH)
        run_dns_server(rules_path_env)

except ModuleNotFoundError:
    # dnspython not installed — pure-function mode (unit tests, host-side tools).
    pass
