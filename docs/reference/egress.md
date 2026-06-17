# Network egress firewall

Rip cage watches every outbound connection the agent makes and decides what's allowed to leave. This is a **network-layer** control — distinct from the command-level guard (DCG) that gates what the agent runs in the shell. It's enabled by default on `rc up`; `RIP_CAGE_EGRESS=off` disables it entirely. Under the hood: a **pure SNI destination router** intercepts HTTP/HTTPS — it reads the TLS SNI (or the HTTP Host header) in the clear, allow/denies the **destination host**, and splices the still-encrypted bytes through unchanged (no TLS termination, no CA, no content inspection); a DNS resolver sidecar inspects port-53 queries; and iptables refuses TCP-22 to hosts that aren't on the allowlist. Content-layer enforcement (method/path, credential injection) is **not** rip-cage's job — it composes onto an external mediator (see [composition-seam.md](composition-seam.md)). See [ADR-012](../decisions/ADR-012-egress-firewall.md) and [ADR-026](../decisions/ADR-026-containment-mediation-identity.md) for the full rationale.

---

## The observe → promote → block workflow

New cages start in **observe mode**: nothing is blocked, but every outbound destination the agent talks to is logged. You let the agent work, see what it actually needed, promote that set into an allowlist, and flip the cage to **block mode**. This is the centerpiece — audit first, then lock down. Default-block on day one produces the "just turn it off" exit; observe-mode makes the friction opt-in.

**1. Let the agent run in observe mode** (the default for new cages). Traffic is logged to the workspace JSONL logs, nothing is blocked.

**2. See what it talked to:**

```bash
$ rc allowlist show --observed --cage my-cage
Observed blocked/would-block hosts:
  api.deepseek.com
  files.example-cdn.net
  telemetry.vendor.io
```

**3. Promote the observed hosts and flip to block mode:**

```bash
$ rc allowlist promote --from-observed --cage my-cage
=== rc allowlist promote: .rip-cage.yaml mutation diff ===
  network.allowed_hosts: adding 3 host(s):
    + api.deepseek.com
    + files.example-cdn.net
    + telemetry.vendor.io
  network.mode: observe -> block
=== end diff ===
Running rc reload my-cage to apply...
```

`promote` merges the observed hosts into `network.allowed_hosts` in `.rip-cage.yaml`, sets `network.mode: block`, and — when `--cage` is given — runs `rc reload` so the change applies live without recreating the container. Review the diff first; everything the agent reached in observe mode gets promoted, so prune anything you don't want in `.rip-cage.yaml` afterward.

From here the cage enforces the allowlist: anything not in `network.allowed_hosts` (or the baseline) is refused at the connection level (the destination host isn't allowed), and the denial is logged to `.rip-cage/egress.log` (host + reason) for the agent or host to read and self-correct against. (A pure router can't return a per-request structured 403 body — it never decrypts the request; per-request structured feedback returns when a mediator is composed, per [ADR-026](../decisions/ADR-026-containment-mediation-identity.md) D4.)

> The agent inside the cage **cannot** promote or self-grant. `rc allowlist add`/`promote` are host-only (they mutate effective config via `rc reload`, which is not on the cage PATH). The human running the command on the host is the approval step.

---

## Modes

| Mode | Behavior | Set on |
|---|---|---|
| `observe` | Log every outbound destination to the JSONL logs; block nothing. | Default for **new** cages. |
| `block` | Enforce the allowlist — non-allowed HTTP/HTTPS, DNS-exfil shapes, and TCP-22 destinations are refused. | After `rc allowlist promote --from-observed`. |
| legacy | No `network.mode` is set; old denylist behavior. Non-regression for cages created before egress shipped. | Cages predating the egress firewall. |

`network.mode` is a scalar (`observe` | `block`). Legacy is the *absence* of the field, not a value you set.

---

## `rc allowlist` command reference

All three are **host-side only** — run them on the host, not inside the cage.

| Command | Effect |
|---|---|
| `rc allowlist add <host> [--cage=<name>]` | Append `<host>` to `network.allowed_hosts` in `.rip-cage.yaml` (idempotent — skips if already present). With `--cage`, runs `rc reload <name>` to apply live. Supports `--output json`. |
| `rc allowlist show [--effective] [--observed]` | Default: list configured `network.allowed_hosts`. `--effective`: merged allowlist with provenance (ADR-021 D4). `--observed`: read the egress logs and list blocked / would-block hosts. |
| `rc allowlist promote --from-observed [--cage=<name>]` | Merge observed blocked hosts into `network.allowed_hosts`, flip `network.mode` to `block`, emit a diff, and run `rc reload` when `--cage` is given. Requires `--from-observed`. |

```bash
# Add one host and apply it live
rc allowlist add api.deepseek.com --cage my-cage

# Inspect configured vs. effective (baseline + user) allowlist
rc allowlist show
rc allowlist show --effective

# See what's being blocked / would be blocked
rc allowlist show --observed --cage my-cage
```

`--cage` resolves the workspace (and its log paths) from the container; without it, the commands operate on `.rip-cage.yaml` and `.rip-cage/` under the current directory.

---

## Config fields

The allowlist lives in `.rip-cage.yaml` under `network.*`:

| Field | Meaning |
|---|---|
| `network.mode` | `observe` or `block`. Absent = legacy. |
| `network.allowed_hosts` | Additive list of domains allowed for HTTP/HTTPS (and reachable on TCP-22). |
| `network.egress.mediator` | Name of a manifest-declared MEDIATOR provider to run co-located (e.g. `iron-proxy`, `mitmproxy`). Default: unset (standalone mode). Validated against the `rc.mediators` image label — unknown names abort loud. See [composition-seam.md](composition-seam.md). |
| `network.http.forward_to` | Address (`host:port`) the SNI router sends allowed HTTP/HTTPS traffic to via HTTP CONNECT, instead of splicing directly to origin. Typically `"127.0.0.1:8888"` for a co-located MEDIATOR. Requires the destination check and IOC floor to pass first (push-side uncrossable floor). See [composition-seam.md](composition-seam.md). |

`rc allowlist add` and `promote` edit the `network.mode` and `network.allowed_hosts` fields for you. For the full schema (types, defaults, merge semantics), see [config.md → `network.*`](config.md#network----egress-firewall).

---

## DNS exfil detection

A small Python DNS resolver sidecar runs inside the cage alongside the HTTP router. iptables transparently REDIRECTs UDP **and** TCP port 53 to it, so `dig @8.8.8.8 evil.com`, `nslookup`, `ping`, and `host` are all captured regardless of the resolver the caller names — there's no `dig @8.8.8.8` bypass. Clean queries forward to a default upstream (8.8.8.8) or, when `network.dns.forward_to` is set, to a DNS-exfil specialist of your choice (see [config.md](config.md)).

The resolver applies an exfil-shape heuristic (long encoded subdomain labels, high per-apex query cardinality) **only to non-whitelisted apex domains**. Queries to apexes in `network.allowed_hosts` pass unconditionally. It honors the cage mode like every other layer: in `observe` it logs a would-block record and resolves; in `block` it refuses. DNS denials land in `.rip-cage/egress-dns.log`. The resolver is fail-closed — if it can't start, DNS fails loudly rather than routing around the control.

---

## Baseline allowlist and the IOC floor

Two things are true out of the box, before you configure anything:

- **Baseline allowlist** — new cages pre-load a curated set of common destinations so observe→promote doesn't churn on the obvious ones: LLM provider APIs (`api.anthropic.com`, `api.openai.com`, …), code hosting (`github.com`, `gitlab.com`, `codeberg.org`, …), top package registries (`registry.npmjs.org`, `pypi.org`, `crates.io`, `proxy.golang.org`, Docker, Maven, …), and common docs/CDN hosts. The effective allowlist is `baseline ∪ network.allowed_hosts`.
- **IOC floor** — a curated denylist of known exfil sinks (paste services, webhook relays, tunnel endpoints) is always enforced and **cannot be overridden** by your allowlist. The project allowlist can broaden, but never shrink below this floor.

---

## Logs

JSONL audit logs live inside the workspace (visible from the host without entering the container):

| Log | Path | Contents |
|---|---|---|
| HTTP/HTTPS | `.rip-cage/egress.log` | Denied / would-block HTTP requests. |
| DNS | `.rip-cage/egress-dns.log` | Denied / would-block DNS queries. |

`rc allowlist show --observed` reads both. Only denials (and observe-mode would-blocks) are logged — allowed traffic is not, to keep the signal dense.

---

## Disabling and diagnosing

- **Kill switch:** `RIP_CAGE_EGRESS=off rc up <path>` starts the cage with the proxy and iptables rules disabled entirely. One name to grep for; no per-rule knobs.
- **Diagnose:** `rc doctor <name>` reports the egress label, live mode, and whether the egress router process (`rip_cage_router.py`) is actually running.

---

## See also

- [ADR-012](../decisions/ADR-012-egress-firewall.md) — full design rationale (modes, pure SNI router, DNS sidecar, IOC floor, threat model)
- [config.md → `network.*`](config.md#network----egress-firewall) — the config schema
- [CLI reference → `rc allowlist`](cli-reference.md#rc-allowlist----egress-allowlist) — command summary
- [composition-seam.md](composition-seam.md) — how to attach an external MEDIATOR (mitmproxy, iron-proxy) for credential non-possession and L7 content policy; `network.egress.mediator` + `network.http.forward_to` seam
