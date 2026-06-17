# clawpatrol — Alternative Appliance (Not a MEDIATOR Provider)

[clawpatrol](https://github.com/denoland/clawpatrol) (by the Deno team) is a
vertically-integrated WireGuard-tunnel L3-router appliance. This note explains
its architectural relationship to rip-cage and when each approach applies.

---

## Why clawpatrol cannot plug into rip-cage's MEDIATOR seam

rip-cage's composition seam (`network.http.forward_to`) works by having the in-cage
SNI router send allowed HTTP/HTTPS traffic to a co-located mediator's listen port via
**HTTP CONNECT** — the mediator must accept transparent-proxy intake on a plain TCP port.

clawpatrol's gateway has **no such plain-TCP or transparent-proxy ingress**. Off-host
traffic enters the clawpatrol gateway only through its own WireGuard netstack from an
enrolled, operator-approved device. The loopback `:8443` listener is the dashboard and
join surface — not the injection path. Credential injection is scoped to the WireGuard
peer identity; there is no mechanism to receive forwarded traffic from an external
chokepoint and inject credentials for it.

In other words: clawpatrol is the "let the mediator own capture too" architecture.
This is the approach [ADR-026 D3](../docs/decisions/ADR-026-containment-mediation-identity.md)
already rejects as insufficient — a host-process tunnel admits that "if the agent
bypasses the tunnel it gets the open internet," and only the container (which owns
its network namespace) can force-capture. You **cannot** run clawpatrol downstream of
rip-cage's chokepoint; it is an appliance you run *instead of* rip-cage's chokepoint.

**Classification:** clawpatrol = **alternative appliance** (WG-only ingress, run
instead-of), not a MEDIATOR provider (transparent-proxy intake, run downstream-of).

---

## The actual composition path: mitmproxy + iron-proxy

If you want rip-cage's force-capture guarantee (chokepoint) **combined with** L7 content
policy and credential non-possession, use a MEDIATOR provider that plugs into the
`network.http.forward_to` seam:

| Provider | Role | Recipe |
|---|---|---|
| **iron-proxy** | **Recommended-adopt** — GA, Apache-2.0, single binary, OOTB default-deny + built-in secret injection (no addon to write) | [compose-rc-with-iron-proxy.md](compose-rc-with-iron-proxy.md) |
| **mitmproxy** | Reference / proof provider — validated the seam end-to-end (in-cage E4: placeholder→real-secret injection proven via httpbin.org/headers) | [compose-rc-with-mitmproxy.md](compose-rc-with-mitmproxy.md) |

Both plug through the same MEDIATOR archetype with zero rip-cage edits. For new
deployments, start with the **iron-proxy recipe**.

---

## When clawpatrol applies

clawpatrol is a coherent, proven alternative if you prefer a WireGuard-tunnel
architecture and are willing to accept that:

- The agent-side WireGuard client must join the clawpatrol gateway's tunnel;
  the agent can potentially route around it (by not starting the client) unless
  you add your own routing enforcement.
- You are replacing rip-cage's chokepoint, not composing with it — you get
  clawpatrol's L7 policy and credential injection in exchange for giving up
  rip-cage's force-capture guarantee.
- The Linux cage path for clawpatrol requires a Go userspace-WireGuard client
  inside the container (no kernel WireGuard module required) — this works in
  unprivileged Linux containers.

This is a valid architecture for settings where an external WG gateway is already
operated and force-capture is less critical than gateway-managed policy.

---

## See Also

- [composition-seam.md](../docs/reference/composition-seam.md) — MEDIATOR provider model, seam contract, GUARANTEES/SUPPLIES
- [ADR-026](../docs/decisions/ADR-026-containment-mediation-identity.md) — containment-vs-mediation identity (clawpatrol reclassification rationale in D5)
- [ADR-005 D12](../docs/decisions/ADR-005-ecosystem-tools.md) — rip-cage as composable seam, not bundler
- [compose-rc-with-iron-proxy.md](compose-rc-with-iron-proxy.md) — recommended MEDIATOR recipe
- [compose-rc-with-mitmproxy.md](compose-rc-with-mitmproxy.md) — reference/proof MEDIATOR recipe
- [github.com/denoland/clawpatrol](https://github.com/denoland/clawpatrol) — clawpatrol upstream
