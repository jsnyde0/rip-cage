# clawpatrol — Alternative Appliance (Not a Composed Mediator)

[clawpatrol](https://github.com/denoland/clawpatrol) (by the Deno team) is a
vertically-integrated WireGuard-tunnel L3-router appliance. This note explains
its architectural relationship to rip-cage and when each approach applies.

> **Historical note:** this page originally explained why clawpatrol couldn't plug into
> rip-cage's **MEDIATOR** manifest archetype (`network.http.forward_to` HTTP-CONNECT
> handoff to a co-located proxy). **That archetype is deleted, not just undocumented**
> ([ADR-029](../docs/decisions/ADR-029-msb-migration.md) D2/D5) — there is no `rc`-side
> mediator seam left for *any* appliance to plug into, clawpatrol included. The
> `compose-rc-with-iron-proxy.md`/`compose-rc-with-mitmproxy.md` recipes this page used
> to point at are removed (see [examples/README.md](README.md#mediator-recipes--dropped)).
> The architectural point below (clawpatrol's WG-only ingress vs. a transparent-proxy
> chokepoint) still holds as a general appliance-classification argument even though the
> specific rip-cage seam it was contrasted against no longer exists.

---

## Why clawpatrol was never a transparent-proxy target

clawpatrol's gateway has **no plain-TCP or transparent-proxy ingress**. Off-host
traffic enters the clawpatrol gateway only through its own WireGuard netstack from an
enrolled, operator-approved device. The loopback `:8443` listener is the dashboard and
join surface — not an injection path. Credential injection is scoped to the WireGuard
peer identity; there is no mechanism to receive forwarded traffic from an external
chokepoint and inject credentials for it.

In other words: clawpatrol is the "let the mediator own capture too" architecture.
This is the approach [ADR-026 D3](../docs/decisions/ADR-026-containment-mediation-identity.md)
already rejects as insufficient — a host-process tunnel admits that "if the agent
bypasses the tunnel it gets the open internet," and only the isolation boundary itself
(the container's network namespace pre-cutover; the msb microVM boundary post-cutover)
can force-capture. You **cannot** run clawpatrol downstream of rip-cage's chokepoint; it
is an appliance you run *instead of* rip-cage's egress control.

**Classification:** clawpatrol = **alternative appliance** (WG-only ingress, run
instead-of rip-cage's own default-deny egress).

---

## Today's composition path: `auth.credentials` + msb `--secret`

Post-cutover, the credential non-possession property clawpatrol/iron-proxy/mitmproxy
used to provide via a composed mediator is a **default platform property**: declare
`auth.credentials: [{source_env, hosts}]` in `.rip-cage.yaml` and msb injects the real
secret on the wire toward the bound host(s) only ([ADR-029](../docs/decisions/ADR-029-msb-migration.md)
D5, [egress.md](../docs/reference/egress.md)). If you need L7 content policy beyond a
per-host secret binding, that remains fully operator-composed and unwired — run
something yourself, outside `rc`'s declared composition surface.

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
- clawpatrol requires a Go userspace-WireGuard client inside the guest (no kernel
  WireGuard module required) — this note pre-dates the msb migration and was
  written against the Linux-container path; it has not been re-verified inside an
  msb guest.

This is a valid architecture for settings where an external WG gateway is already
operated and force-capture is less critical than gateway-managed policy.

---

## See Also

- [composition-seam.md](../docs/reference/composition-seam.md) — what replaced the retired MEDIATOR seam, and the historical record of how it worked
- [ADR-029](../docs/decisions/ADR-029-msb-migration.md) D2/D5 — the msb-runtime egress/credential model that retired the MEDIATOR archetype
- [ADR-026](../docs/decisions/ADR-026-containment-mediation-identity.md) — containment-vs-mediation identity (clawpatrol reclassification rationale in D5, pre-cutover)
- [ADR-005 D12](../docs/decisions/ADR-005-ecosystem-tools.md) — rip-cage as composable seam, not bundler
- [egress.md](../docs/reference/egress.md) — `auth.credentials`/`--secret` non-possession, the current default
- [github.com/denoland/clawpatrol](https://github.com/denoland/clawpatrol) — clawpatrol upstream
