# Compose rip-cage with clawpatrol (Reference Recipe)

This recipe shows how to attach [clawpatrol](https://github.com/denoland/clawpatrol) (by the Deno team) as an external mediator that sits in front of rip-cage's egress chokepoint. The combination yields:

- **rip-cage provides:** forced capture of all HTTP/HTTPS and DNS egress (the agent cannot bypass); destination-level allow/deny (SNI router); DNS exfil heuristic.
- **clawpatrol provides:** TLS-MITM gateway; CEL/HCL L7 content policy; credential non-possession (the agent holds a placeholder token; the gateway injects the real secret on the wire); human-in-the-loop (HITL) approval.

**Threat tier achieved:** exfil-grade — credential non-possession closes the credential-exfil axis that standalone rip-cage leaves open (see [composition-seam.md](../docs/reference/composition-seam.md) and [ADR-026 D6](../docs/decisions/ADR-026-containment-mediation-identity.md)).

**Important notes:**

- This recipe describes the **Linux-cage production path** (the supported path). A macOS-host path requires a signed system-extension app and GUI approval — agent-hostile, so macOS-host composition is dev-only; the Linux container is the production path per [ADR-026 D5](../docs/decisions/ADR-026-containment-mediation-identity.md) (its open-validation note: the spike's routing-attach ran on a macOS host as proof-of-mechanism; Linux-cage validation is bead `rip-cage-ta1o.4`).
- The gateway-setup and credential-injection steps have been validated headlessly end-to-end (a spike confirmed: agent sent no auth header; httpbin.org/headers echoed back the real injected token). The **container-side routing attach** on Linux is proof-of-mechanism (spike ran on macOS); end-to-end Linux-cage validation is tracked in bead `rip-cage-ta1o.4`.
- If exact flags differ from what's shown here, consult the upstream source at [github.com/denoland/clawpatrol](https://github.com/denoland/clawpatrol) and note any discrepancy as `<!-- verify against upstream -->`.
- This file lives under `examples/` per [ADR-005 D12](../docs/decisions/ADR-005-ecosystem-tools.md) — rip-cage bundles nothing; this is a copyable recipe, not a baked integration.

---

## Prerequisites

- A running rip-cage container (`rc up /path/to/workspace`).
- Access to a host (or separate VM) where the clawpatrol gateway will run. The gateway does NOT run inside the cage — it is the external mediator the cage forwards to.
- `CLAWPATROL_SECRET_<NAME>` environment variable(s) on the gateway host, holding the real credential(s) the agent should not possess directly (e.g. `CLAWPATROL_SECRET_ANTHROPIC_API_KEY=sk-ant-...`).
- The agent inside the cage will have a corresponding **placeholder token** in its env (e.g. `ANTHROPIC_API_KEY=proxy-injected`); clawpatrol injects the real value on the wire at the gateway.

---

## Steps

### Step 1: Set up the clawpatrol gateway

On the gateway host (not inside the cage):

**1a. Write a minimal gateway config.**

```hcl
# clawpatrol-gateway.hcl  (example — verify flags against upstream)
gateway {
  listen = ":8443"   # TLS-MITM proxy port the cage will route to
}

credentials {
  bearer_token "anthropic" {
    # Header to inject; real value comes from CLAWPATROL_SECRET_ANTHROPIC_API_KEY env
    header = "Authorization"
    value  = env("ANTHROPIC_API_KEY")   # placeholder the agent sent
    inject = env("CLAWPATROL_SECRET_ANTHROPIC_API_KEY")  # real secret
  }
}
```

The injection mechanism is implemented in `internal/config/plugins/credentials/bearer_token.go` in the clawpatrol source. The `env()` references match `CLAWPATROL_SECRET_*` env vars; verify the exact config syntax against the upstream. <!-- verify against upstream -->

**1b. Export the real credential(s) and start the gateway.**

```bash
export CLAWPATROL_SECRET_ANTHROPIC_API_KEY="sk-ant-<your-real-key>"
clawpatrol gateway --config clawpatrol-gateway.hcl   # <!-- verify against upstream: exact flag name -->
```

The gateway starts and listens for incoming TLS connections from the cage.

**1c. Fetch the gateway CA certificate.**

```bash
# From the gateway host, or from any machine that can reach the gateway
curl http://<gateway-host>:8080/ca.crt -o clawpatrol-ca.crt
```

The CA endpoint is `GET /ca.crt` on the gateway's plain-HTTP management port. <!-- verify against upstream: exact port -->

This CA certificate must be trusted inside the cage so the agent accepts the gateway's MITM certificate when the gateway intercepts HTTPS traffic.

---

### Step 2: Configure the cage to trust the gateway CA

Inside the cage (via `rc exec <cage-name>` or a mounted file):

```bash
# Copy the CA cert into the cage's trusted CA store
sudo cp /workspace/.clawpatrol-ca.crt /usr/local/share/ca-certificates/clawpatrol-ca.crt
sudo update-ca-certificates

# Export for Node.js (Claude Code runs on Node)
export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/clawpatrol-ca.crt
```

Alternatively, mount the CA cert file from the host at `rc up` time using a `mounts:` entry in `.rip-cage.yaml`, so it is available at `/workspace/.clawpatrol-ca.crt` from the start.

---

### Step 3: Attach the container-side routing

The cage must route all of its egress through the clawpatrol gateway. Two approaches — choose based on your Linux cage environment:

**Option A — userspace-WireGuard client (preferred, no kernel module required).**

clawpatrol uses a WireGuard/Tailscale tunnel for the network path. A Go-based userspace-WireGuard client (`gvisor-go/wireguard-go` or the one embedded in clawpatrol's client component) can run inside an unprivileged Linux container without a kernel WireGuard module.

```bash
# Inside the cage — run the clawpatrol client / join the tunnel
# This routes all cage egress through the gateway tunnel
clawpatrol run --gateway <gateway-host>:8443 --token <join-token>
# <!-- verify against upstream: exact subcommand and flags for the client/join step -->
```

The `cmd/clawpatrol/dnsvip/dnsvip.go` source shows that clawpatrol's DNS path is routing-only (gives each SSH-able hostname a unique VIP; passes non-VIP names through the normal resolver). rip-cage's own DNS force-through continues to apply — the cage captures all port-53 traffic at the iptables level regardless.

**Option B — socat-relay over unix socket (fallback).**

If userspace-WireGuard proves incompatible with your Linux cage configuration (e.g. unprivileged userns restrictions), use a socat relay. This is the approach Anthropic's `sandbox-runtime` (`anthropic-experimental/sandbox-runtime`) uses for its forced-egress model:

```bash
# On the gateway host: start a SOCKS5/HTTP proxy and expose it over a shared unix socket
# (or over a TCP port the cage can reach via CAGE_HOST_ADDR)

# Inside the cage: relay cage egress to the host-side proxy
# Example — HTTP_PROXY pointing at the gateway via socat
socat TCP-LISTEN:3128,fork,reuseaddr TCP:<gateway-host>:<proxy-port> &
export HTTP_PROXY=http://127.0.0.1:3128
export HTTPS_PROXY=http://127.0.0.1:3128
```

The `CAGE_HOST_ADDR` environment variable (set by rip-cage's preflight probe, [ADR-016](../docs/decisions/ADR-016-cage-host-network-awareness.md)) can be used to address the host from inside the cage.

---

### Step 4: Configure credential injection

In the agent's environment inside the cage, set the placeholder token(s). The agent sends the placeholder; the gateway intercepts and injects the real value:

```bash
# Inside the cage — set placeholder(s) the agent will use
export ANTHROPIC_API_KEY="proxy-injected"

# (Or set via .rip-cage.yaml env block or rc up --env)
```

The spike validated this end-to-end: the agent sent no `Authorization` header; `httpbin.org/headers` echoed back `Authorization: Bearer <real-token>`. The gateway injects the real secret at the wire level using the bearer_token plugin (`internal/config/plugins/credentials/bearer_token.go`).

---

### Step 5: Verify the composition is working

From inside the cage:

```bash
# Confirm force-through is still on-path (rip-cage guarantee)
curl -v https://httpbin.org/headers   # should succeed via the gateway

# Confirm the agent's env has only the placeholder
echo $ANTHROPIC_API_KEY   # should print: proxy-injected

# Confirm no rip-cage CA in the trust store (rip-cage does not MITM)
ls /usr/local/share/ca-certificates/ | grep rip-cage   # should return nothing

# Confirm a non-allowlisted host is still blocked at destination level
curl https://evil.example.com 2>&1   # should get connection refused/reset
```

End-to-end Linux-cage validation (including the credential-injection proof) is covered by bead `rip-cage-ta1o.4`.

---

## What the gateway config should NOT do

- **Do not** try to weaken rip-cage's iptables rules from inside the cage — `RIP_CAGE_EGRESS` is a host-side kill switch only; inside the cage you cannot disable the egress capture.
- **Do not** add the gateway CA to the rip-cage IOC floor exceptions — rip-cage's IOC floor (known exfil sinks) is non-overridable; the gateway CA is a separate trust-store concern.
- **Do not** set `CLAWPATROL_SECRET_*` env vars inside the cage — they belong on the gateway host only. The non-possession property is that these secrets are never in the cage's process environment.

---

## Standalone Tiering Reminder

If you are running this recipe you have opted into the **exfil-grade** tier. If you only need accident-containment (blocking accidental egress to non-allowlisted hosts), standalone rip-cage is sufficient and this recipe is optional.

| | Standalone rip-cage | rip-cage + clawpatrol |
|---|---|---|
| Force-through (HTTP + DNS) | Yes | Yes |
| Destination allow/deny (SNI) | Yes | Yes |
| Credential non-possession | No — agent holds real creds | Yes — agent holds placeholder only |
| L7 content policy | No | Yes (CEL/HCL rules in gateway config) |
| HITL approval | No | Yes (configurable in gateway) |
| Real upstream cert (no MITM) | Yes | No — gateway terminates TLS (that is how injection works) |

rip-cage alone is "at least put your Claude in a cage." rip-cage + a mediator is "your Claude can't exfiltrate secrets it was never given."

---

## See Also

- [composition-seam.md](../docs/reference/composition-seam.md) — tool-agnostic seam description and the GUARANTEES/SUPPLIES contract
- [ADR-026](../docs/decisions/ADR-026-containment-mediation-identity.md) — the containment-vs-mediation identity (FIRM)
- [ADR-005 D12](../docs/decisions/ADR-005-ecosystem-tools.md) — rip-cage is a composable seam, not a bundler
- [egress.md](../docs/reference/egress.md) — standalone egress: observe → promote → block workflow
- [github.com/denoland/clawpatrol](https://github.com/denoland/clawpatrol) — clawpatrol upstream (authoritative for config syntax and CLI flags)
