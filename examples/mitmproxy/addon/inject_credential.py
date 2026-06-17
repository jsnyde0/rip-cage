"""
inject_credential.py — mitmproxy addon for placeholder→real-secret credential injection.

Reads the real secret from RIPCAGE_MEDIATOR_BEARER_SECRET (env, set on the mitmproxy
process). When a request carries the placeholder value in its Authorization header
(or has no Authorization header), replaces it with "Bearer <real-secret>".

Usage:
    mitmdump ... -s inject_credential.py

Required env vars (set on the mitmproxy process, NOT in the agent env):
    RIPCAGE_MEDIATOR_BEARER_SECRET   — the real bearer token to inject
    RIPCAGE_MEDIATOR_PLACEHOLDER     — (optional) the placeholder the agent sends;
                                        when absent, injection fires unconditionally

The agent env holds only the placeholder value (e.g. ANTHROPIC_API_KEY=ripcage-placeholder).
The real secret is never in the agent's process environment — non-possession property.

ADR-026 D5 / rip-cage-ta1o.5.4.
"""

import os


def request(flow):
    real_secret = os.environ.get("RIPCAGE_MEDIATOR_BEARER_SECRET", "")
    if not real_secret:
        # No secret configured — pass through unchanged.
        return
    placeholder = os.environ.get("RIPCAGE_MEDIATOR_PLACEHOLDER", "")
    auth_header = flow.request.headers.get("authorization", "")
    if placeholder:
        # Targeted: only replace when the agent sent the known placeholder.
        if auth_header != f"Bearer {placeholder}":
            return
    # Inject the real secret.
    flow.request.headers["authorization"] = f"Bearer {real_secret}"
