# Composition Seam — Attaching an External Mediator to rip-cage's Egress Chokepoint

rip-cage guarantees that all HTTP and DNS egress from the cage hits a chosen chokepoint. What happens at that chokepoint is pluggable — by default, a built-in destination allow/deny router and DNS heuristic; optionally, any external mediator that accepts a proxy-forward or a DNS forward.

This document describes the chokepoint's upstream interface: the contract a mediator attaches to.

---

## The Contract

### rip-cage GUARANTEES

1. **Force-through of all HTTP/HTTPS egress.** iptables REDIRECTs port-80/443 traffic to the in-container SNI destination router (`rip_cage_router.py`). There is no non-redirected route for port-80/443 traffic — the container owns its network namespace and the agent cannot bypass the capture. A startup self-test proves the router is genuinely on-path before the agent session begins.

2. **Force-through of all DNS egress.** iptables REDIRECTs UDP and TCP port-53 traffic to the in-container DNS resolver sidecar (`rip_cage_dns.py`), regardless of the resolver the caller names. `dig @8.8.8.8`, `nslookup`, `ping`, and `host` are all captured. There is no DNS bypass path.

3. **SNI-level destination allow/deny for HTTP/HTTPS.** The router reads the SNI label from each TLS ClientHello (in the clear), allows or denies the destination, and forwards the still-sealed TLS bytes unchanged. No TLS termination; no MITM; no rip-cage CA in the trust store. The agent sees the real upstream certificate. Denied hosts receive a connection reset/refuse.

4. **`network.dns.forward_to` seam.** Clean DNS queries (those the built-in heuristic passes) are forwarded to a configurable upstream resolver specified as `network.dns.forward_to` in `.rip-cage.yaml` (format: `host` or `host:port`). When set, this routes the clean-query stream to an external DNS specialist — a DNS-aware mediator, a resolving firewall, or a local forwarder. The built-in exfil heuristic still runs first, regardless.

### The Mediator SUPPLIES

An attached mediator can add any layer that requires seeing into the traffic rip-cage's pure router passes sealed:

- **L7 content policy** — method/path/body rules, per-request allow/deny, structured refusals with explainable denials.
- **Credential injection / non-possession** — the agent holds a placeholder token in its env; the mediator intercepts the sealed stream and injects the real credential on the wire. The real secret never enters the cage.
- **Human-in-the-loop (HITL) approval** — escalate specific request patterns to a human reviewer before forwarding.
- **Protocol parsing and audit logging** — full request/response capture beyond rip-cage's destination-level logs.

### What the seam does NOT provide standalone

Standalone rip-cage (no mediator attached) is the **accident-containment** tier: it limits where traffic can go (destination control) and stops accidental exfil to known-bad sinks (IOC floor + DNS exfil heuristic). It does **not** close the credential-exfil axis ([ADR-026 D4](../decisions/ADR-026-containment-mediation-identity.md)) — a prompt-injected agent can read its own env or `.credentials.json` and send the real token to any allowed destination. Exfil-grade security (credential non-possession + content-exfil defense) requires composing a mediator. See [Tiering](#tiering-standalone-vs-composed) below.

---

## Attach Points

There are two concrete seams a mediator plugs into:

### HTTP/HTTPS: upstream proxy target

The in-container SNI router (`rip_cage_router.py`) allows/denies at the destination level and forwards sealed bytes. To attach an external mediator for L7 content inspection or credential injection:

**Option A — userspace-WireGuard tunnel (clawpatrol / NanoClaw pattern).** Run a userspace-WireGuard client inside the cage (no kernel WireGuard module required — a Go userspace client has no kernel dependencies). All egress from the container is routed through the WireGuard tunnel to the gateway, which acts as the TLS-terminating mediator. The gateway returns a CA certificate (`GET /ca.crt`) that the cage trusts; the WireGuard tunnel carries the traffic; the mediator injects credentials and applies L7 policy before forwarding to the real upstream.

**Option B — socat-relay over unix socket (Anthropic sandbox-runtime pattern).** A host-side proxy (HTTP + SOCKS5) listens on a unix socket. The cage's egress is relayed to it via `socat` or a similar unix-to-TCP bridge. This is the approach Anthropic's open-source `sandbox-runtime` (`anthropic-experimental/sandbox-runtime`) uses for its bubblewrap + forced-egress model — a proven-shipping fallback if userspace-WireGuard proves hostile in a given Linux cage configuration.

Both attach options are **additive** — neither requires changes to `rc` or the Dockerfile; the mediator and routing are set up by the agent (or its bootstrap recipe) inside the running cage.

### DNS: `network.dns.forward_to`

Set `network.dns.forward_to` in `.rip-cage.yaml` to point the cage's DNS resolver sidecar at the mediator's resolver port. The sidecar applies its built-in exfil heuristic first; clean queries are forwarded to the configured upstream. Compatible with any resolver that accepts standard DNS-over-UDP/TCP queries (NextDNS, Cisco Umbrella, dnsdist, Zeek, or a custom resolver). No product name is hardcoded in rip-cage.

```yaml
network:
  mode: block
  allowed_hosts:
    - api.anthropic.com
  dns:
    forward_to: "127.0.0.1:5353"   # or "192.0.2.1" for a remote resolver
```

---

## Tiering: Standalone vs. Composed

| Tier | What you get | What remains open |
|---|---|---|
| **Standalone rip-cage** | Force-through chokepoint, destination-level allow/deny (SNI), DNS exfil heuristic, IOC floor, ssh-bypass guard | Credential-exfil axis open (agent holds real creds; can exfil to allowed destinations); no content-level policy; no per-request structured refusals |
| **rip-cage + composed mediator** | All standalone guarantees PLUS: credential non-possession (placeholder in cage, real secret injected at mediator), L7 content policy, HITL approval, full request audit | Runnability depends on mediator setup (see reference recipe) |

**Standalone rip-cage is honestly the accident-containment tier.** It is the right answer to "at least put your Claude in a cage." It is NOT a claim of exfil-grade security.

**Exfil-grade security requires composing a mediator.** If an agent holds real credentials, a sophisticated enough prompt injection can exfiltrate them. The only architectural fix is credential non-possession — the agent never holds the real secret — and that is a mediation property, not a containment property ([ADR-026 D6](../decisions/ADR-026-containment-mediation-identity.md)).

If you are running agents against production systems or sensitive credentials, compose a mediator. rip-cage's chokepoint guarantee is what makes that composition sound — without it, the mediator's tunnel can be bypassed; with it, every byte leaves through the chosen chokepoint.

---

## Alternative Mediator Shapes

The seam targets a **class** of mediators, not a single product. The reference recipe (below) uses clawpatrol as a concrete worked example, but the same attach points work with:

- **[clawpatrol](https://github.com/denoland/clawpatrol)** (Deno team) — WireGuard/Tailscale tunnel → TLS-MITM gateway → CEL/HCL content policy → credential injection → HITL approval.
- **Cloudflare Sandbox** — `outboundByHost` + `interceptHttps` = an L7 TLS-introspecting egress proxy with sentinel credential injection (container receives a `proxy-injected` placeholder; the Worker swaps in the real header) and forced DNS through Cloudflare resolvers. Cloud-only; designed for batch-task sandboxes rather than interactive sessions.
- **Coder "Agent Boundaries"** — give the agent code and tools, withhold credentials and network access at the workspace layer. Philosophically the same non-possession principle; credential scoping via the Coder platform rather than per-request injection. Enterprise self-hosted.

All three converge on the same pattern: sentinel-placeholder-in-agent + real-secret-injected-at-L7-proxy. The seam rip-cage exposes is the force-through chokepoint each of them sits in front of.

---

## See Also

- [ADR-026](../decisions/ADR-026-containment-mediation-identity.md) — the containment-vs-mediation identity decision (FIRM)
- [ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md) — rip-cage is a composable seam, not a bundler (FIRM)
- [egress.md](egress.md) — the observe → promote → block workflow for standalone use
- [config.md → `network.*`](config.md#network----egress-firewall) — the config schema including `network.dns.forward_to`
- [examples/compose-rc-with-clawpatrol.md](../../examples/compose-rc-with-clawpatrol.md) — step-by-step reference recipe for attaching clawpatrol as the mediator
