# Composition Seam — Attaching an External Mediator to rip-cage's Egress Chokepoint

rip-cage guarantees that all HTTP and DNS egress from the cage hits a chosen chokepoint. What happens at that chokepoint is pluggable — by default, a built-in destination allow/deny router and DNS heuristic; optionally, any external mediator that the router forwards allowed traffic to.

This document describes the chokepoint's upstream interface: the contract a mediator attaches to, how a mediator is declared and launched, and how to select one.

---

## The Contract

### rip-cage GUARANTEES

1. **Force-through of all HTTP/HTTPS egress.** iptables REDIRECTs port-80/443 traffic to the in-container SNI destination router (`rip_cage_router.py`). There is no non-redirected route for port-80/443 traffic — the container owns its network namespace and the agent cannot bypass the capture. A startup self-test proves the router is genuinely on-path before the agent session begins.

2. **Force-through of all DNS egress.** iptables REDIRECTs UDP and TCP port-53 traffic to the in-container DNS resolver sidecar (`rip_cage_dns.py`), regardless of the resolver the caller names. `dig @8.8.8.8`, `nslookup`, `ping`, and `host` are all captured. There is no DNS bypass path.

3. **SNI-level destination allow/deny for HTTP/HTTPS.** The router reads the SNI label from each TLS ClientHello (in the clear), allows or denies the destination, and forwards the still-sealed TLS bytes unchanged — or, when `network.http.forward_to` is configured, forwards via HTTP CONNECT to the mediator. No TLS termination by rip-cage itself; no rip-cage CA in the trust store in standalone mode. Denied hosts receive a connection reset/refuse.

4. **IOC floor before forward.** Destination allow/deny and the IOC floor (known exfil sinks) run **before** any forward to a mediator. A mediator can add restriction; it cannot subtract — it never receives traffic rip-cage already denied.

5. **`network.dns.forward_to` seam.** Clean DNS queries (those the built-in heuristic passes) are forwarded to a configurable upstream resolver specified as `network.dns.forward_to` in `.rip-cage.yaml` (format: `host` or `host:port`). When set, this routes the clean-query stream to an external DNS specialist — a DNS-aware mediator, a resolving firewall, or a local forwarder. The built-in exfil heuristic still runs first, regardless.

### The Mediator SUPPLIES

An attached mediator can add any layer that requires seeing into the traffic rip-cage's pure router passes sealed:

- **L7 content policy** — method/path/body rules, per-request allow/deny, structured refusals with explainable denials.
- **Credential injection / non-possession** — the agent holds a placeholder token in its env; the mediator intercepts the stream and injects the real credential on the wire. The real secret never enters the cage.
- **Human-in-the-loop (HITL) approval** — escalate specific request patterns to a human reviewer before forwarding.
- **Protocol parsing and audit logging** — full request/response capture beyond rip-cage's destination-level logs.

### What the seam does NOT provide standalone

Standalone rip-cage (no mediator attached) is the **accident-containment** tier: it limits where traffic can go (destination control) and stops accidental exfil to known-bad sinks (IOC floor + DNS exfil heuristic). It does **not** close the credential-exfil axis ([ADR-026 D4](../decisions/ADR-026-containment-mediation-identity.md)) — a prompt-injected agent can read its own env or `.credentials.json` and send the real token to any allowed destination. Exfil-grade security (credential non-possession + content-exfil defense) requires composing a mediator. See [Tiering](#tiering-standalone-vs-composed) below.

---

## The HTTP Mediator Seam: `network.http.forward_to`

When `network.http.forward_to` is set in `.rip-cage.yaml`, the router uses HTTP CONNECT to forward allowed HTTP/HTTPS traffic to the mediator's listen address, instead of splicing the sealed bytes directly to the upstream.

```
Agent (inside cage)
  │  TCP/443 or TCP/80
  ▼
rip-cage router (rip_cage_router.py)
  │  Destination check: allowed? → yes
  │  IOC floor: not denied? → yes
  │  network.http.forward_to = "127.0.0.1:8888"
  │  HTTP CONNECT <orig-dst>:<port> → mediator on :8888
  ▼
Mediator (dedicated uid, 127.0.0.1:8888)
  │  TLS-MITM: sees plaintext request
  │  Applies L7 policy / credential injection
  │  Re-originates TLS to actual upstream
  │  (mediator uid is uid-exempted from REDIRECT — no loop)
  ▼
Real upstream
```

The mediator runs co-located inside the cage, under a **dedicated non-root uid** (the `run_as_uid` declared in its manifest entry). The firewall's uid-exemption for that uid prevents the mediator's own re-originated egress from being re-captured by the REDIRECT rules (loop prevention). The mediator is network-containment substrate — it sits in the traffic path and is coupled to the firewall's uid-exemption; it is NOT a session/UX component.

```yaml
# .rip-cage.yaml
network:
  mode: block
  allowed_hosts:
    - api.anthropic.com
  egress:
    mediator: mitmproxy       # matches a manifest-declared MEDIATOR provider
  http:
    forward_to: "127.0.0.1:8888"   # router sends allowed traffic here via HTTP CONNECT
  dns:
    forward_to: "127.0.0.1:5353"   # optional: DNS specialist
```

`network.http.forward_to` and `network.egress.mediator` are independent settings but are used together: `forward_to` is the router address; `mediator` selects which manifest-declared MEDIATOR lifecycle to run.

---

## The MEDIATOR Provider Model

A mediator is declared as an entry in the tool manifest (`~/.config/rip-cage/tools.yaml` or a project `tools.yaml`) with `archetype: MEDIATOR`. Adding a mediator is a **manifest entry with zero rip-cage source edits** — rip-cage never hardcodes any mediator name ([ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)).

### MEDIATOR manifest archetype

```yaml
version: 1
tools:
  - name: my-mediator
    archetype: MEDIATOR
    version_pin: "1.2.3"
    run_as_uid: "rip-my-mediator"    # dedicated non-root uid
    ca_cert_path: "/etc/my-mediator/ca.crt"   # optional: auto-installed by init-mediator.sh
    hooks:
      start: "/path/to/start-my-mediator ..."
      teardown: "pkill -u rip-my-mediator my-mediator || true"   # optional
```

`rc build` bakes the hook strings into `/etc/rip-cage/mediators/<name>/` in the image and stamps an `rc.mediators` label listing the declared mediator names. The config validator uses that label to verify that `network.egress.mediator: <name>` references a built-in provider — unknown names abort loud (fail-closed, [ADR-005 D11](../decisions/ADR-005-ecosystem-tools.md)).

### Selecting a mediator

```yaml
# .rip-cage.yaml
network:
  egress:
    mediator: iron-proxy   # must match a name in the rc.mediators image label
```

Default is `none` (no mediator — standalone mode). The allowed set is derived from the `rc.mediators` image label, not a fixed enum in rc source.

### Mediator launch: host-driven root phase (sibling to the firewall)

The mediator's launch is **network-containment substrate** — it is analogous to the firewall, not to the session multiplexer. Like `init-firewall.sh`, it runs as a host-driven `docker exec -u root` step from `rc up`, **before the agent-context init** (`init-rip-cage.sh`).

Launch order at `rc up`:
1. Container starts (`sleep infinity`).
2. `init-firewall.sh` runs as `docker exec -u root`:
   - Installs iptables REDIRECT rules.
   - Reads the mediator's `run_as_uid` from the registry and adds a uid-exemption OUTPUT RETURN rule (loop prevention).
3. `init-mediator.sh` runs as `docker exec -u root` (after the firewall, before the agent init):
   - Reads the mediator registry from `/etc/rip-cage/mediators/<name>/`.
   - Validates `run_as_uid` (fail-closed: empty/0/root → refuse).
   - Drops to the mediator uid and backgrounds the `start` hook via `nohup su ...`.
   - Installs the `ca_cert_path` CA into the cage trust store (if declared).
   - The real secret arrives via `rc up --mediator-env` into the mediator's process env only — never into `/proc/1/environ`.
4. `init-rip-cage.sh` runs as `docker exec` (agent-context init — auth, hooks, git identity).

The mediator process survives the exec returning (backgrounded via `nohup`). It dies with the container — the same lifecycle as the firewall rules. There is no EXIT-trap teardown in the container; the teardown hook, if declared, is available for external callers.

This runs on both **create and resume** paths (`rc up` after `rc down` re-launches the mediator, because the secret intentionally does not persist).

**Why not the session multiplexer tier?** The session multiplexer (tmux/herdr) runs as the agent user, in the session/UX layer — no privilege needed. The egress mediator is coupled to the firewall's uid-exemption and must run under a dedicated non-root uid; it requires root privilege at launch to drop correctly. These are two distinct substrate tiers; conflating them was the source of the broken auto-launch leg in earlier designs.

### Real secret delivery: `--mediator-env`

```bash
rc up /path/to/workspace \
  --mediator-env RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-real-key-here
# or from a file not in version control:
rc up /path/to/workspace --mediator-env-file /path/to/.cage-secrets
```

`--mediator-env` delivers vars only to `init-mediator.sh`'s `docker exec -e` channel — they reach the mediator's process env and never appear in the container's `/proc/1/environ`. **Must be re-supplied on every `rc up`** (including resume after `rc down`) — the secret intentionally does not persist.

---

## Reference Providers (examples/ only — never baked)

Two reference MEDIATOR providers ship as examples. Neither is baked into rip-cage (per [ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)): adding either is a manifest entry.

| Provider | Role | Recipe |
|---|---|---|
| **mitmproxy** | Reference / proof provider — validated the seam end-to-end (in-cage E4: placeholder→real-secret injection proven via httpbin.org/headers) | [examples/compose-rc-with-mitmproxy.md](../../examples/compose-rc-with-mitmproxy.md) |
| **iron-proxy** | **Recommended-adopt** — GA, Apache-2.0, single binary, OOTB default-deny + built-in secret injection (no addon to write); proves the seam is tool-agnostic (second differently-shaped provider, zero rc edits) | [examples/compose-rc-with-iron-proxy.md](../../examples/compose-rc-with-iron-proxy.md) |

For new deployments, start with the iron-proxy recipe. For the seam mechanics, read the mitmproxy recipe first — it annotates each step against the composition model described above.

---

## DNS: `network.dns.forward_to`

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

If you are running agents against production systems or sensitive credentials, compose a mediator. rip-cage's chokepoint guarantee is what makes that composition sound — without it, the mediator can be bypassed; with it, every byte leaves through the chosen chokepoint.

---

## Alternative Appliances

[**clawpatrol**](https://github.com/denoland/clawpatrol) (Deno team) is a vertically-integrated WireGuard-tunnel L3-router appliance. It has **no transparent-proxy ingress** — off-host traffic enters only through its own WireGuard netstack from an enrolled device. It cannot receive forwarded traffic from rip-cage's `network.http.forward_to` chokepoint and cannot plug into the MEDIATOR seam. It is an **alternative appliance** (run instead of rip-cage's chokepoint), not a downstream mediator. See [examples/compose-rc-with-clawpatrol.md](../../examples/compose-rc-with-clawpatrol.md) for notes on when this architecture applies.

---

## See Also

- [ADR-026](../decisions/ADR-026-containment-mediation-identity.md) — the containment-vs-mediation identity decision
- [ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md) — rip-cage is a composable seam, not a bundler (FIRM)
- [egress.md](egress.md) — the observe → promote → block workflow for standalone use
- [config.md → `network.*`](config.md#network----egress-firewall) — the config schema including `network.egress.mediator`, `network.http.forward_to`, and `network.dns.forward_to`
- [examples/compose-rc-with-mitmproxy.md](../../examples/compose-rc-with-mitmproxy.md) — step-by-step reference recipe (mitmproxy — proof provider)
- [examples/compose-rc-with-iron-proxy.md](../../examples/compose-rc-with-iron-proxy.md) — step-by-step recipe (iron-proxy — recommended adopt)
