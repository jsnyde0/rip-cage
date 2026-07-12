# Composition Seam — Egress and Credential Non-Possession (post-cutover)

> **Most of this page's pre-cutover content is retired, not merely undocumented** ([ADR-029](../decisions/ADR-029-msb-migration.md) D2/D5). rip-cage used to run an in-cage engine (`rip_cage_router.py`, `rip_cage_dns.py`, `init-firewall.sh`, `init-mediator.sh`) with a manifest `MEDIATOR` provider archetype that `rc up` launched as a co-located, uid-exempted proxy, reachable via `network.http.forward_to`'s HTTP CONNECT handoff. **All of that is deleted.** This page now describes what replaced it, and keeps a condensed historical record at the bottom for context.

## What replaced it

Cages run on microsandbox (msb, libkrun microVMs). Egress and credential injection are **msb host-side runtime primitives** rip-cage *declares against* via `.rip-cage.yaml` — not an in-cage process it launches or a mediator you compose:

- **Destination control:** `network.allowed_hosts` → one `--net-rule allow@<host>` per entry, default-deny otherwise. See [egress.md](egress.md).
- **Credential non-possession:** `auth.credentials: [{source_env, hosts}]` → one `--secret <SYNTH>@<host>` per (credential, host) pair. The guest env/disk/proc hold only a synthesized placeholder; msb injects the real value on the wire toward the bound host(s) only, with a block-and-log violation guard for any other destination ([ADR-029](../decisions/ADR-029-msb-migration.md) D5). This is now a **default platform property** for the dominant secrets (Claude's own auth, git host tokens) — not something that required composing anything.

```yaml
# <project>/.rip-cage.yaml
version: 1
network:
  allowed_hosts:
    - github.com
auth:
  credentials:
    - source_env: GH_TOKEN
      hosts: [github.com]
```

See [egress.md](egress.md) for the full worked example and the deny→fix→reload repair loop.

## What is NOT provided anymore

Standalone rip-cage — which is now the *only* mode, there is no composed-mediator mode wired into `rc` — gives you: the msb host/VM boundary, default-deny destination control, DNS default-deny, the IOC floor, and `--secret` non-possession for declared credential bindings. It does **not** give you:

- **L7 content policy** (method/path/body rules, structured per-request refusals) — msb's netstack allow/denies by destination host only.
- **Credential injection for anything beyond a per-host `--secret` binding** — e.g. a shared credential that needs different treatment per request path.
- **Human-in-the-loop approval** or **full request/response audit logging** beyond msb's own trace-level denial log.

If you need any of those, that is **fully operator-composed and unwired** today — there is no manifest archetype, launch hook, or forward-to seam to attach to. You would run something yourself (e.g. as your own process, however you choose) and it would not be part of rip-cage's declared composition surface. See [examples/README.md](../../examples/README.md#mediator-recipes--dropped) — the mitmproxy/iron-proxy reference recipes that used to document this seam are deleted, not demoted, because there is no `rc`-side mechanism left to recipe against.

## Alternative appliances

[**clawpatrol**](https://github.com/denoland/clawpatrol) (Deno team) is a vertically-integrated WireGuard-tunnel L3-router appliance with no transparent-proxy ingress — it never plugged into the pre-cutover MEDIATOR seam either (off-host traffic only enters through its own WireGuard netstack from an enrolled device). It remains an **alternative appliance** (run instead of rip-cage's containment), not a downstream composition target. See [examples/compose-rc-with-clawpatrol.md](../../examples/compose-rc-with-clawpatrol.md).

---

## See also

- [ADR-029](../decisions/ADR-029-msb-migration.md) D2/D3/D5 — the msb-runtime egress + credential-non-possession design and what it replaced
- [ADR-026](../decisions/ADR-026-containment-mediation-identity.md) — the pre-cutover containment-vs-mediation identity decision (evolved in place; the delegate is now msb itself, D1)
- [egress.md](egress.md) — the deny→fix→reload repair loop and the `network.allowed_hosts`/`auth.credentials` worked example
- [config.md → `network.*`](config.md#network----msb-egress-allowlist) — the config schema

---

<details>
<summary>Historical record of the pre-cutover MEDIATOR seam (click to expand — not current behavior)</summary>

rip-cage used to guarantee that all HTTP and DNS egress from the cage hit a chosen chokepoint (a force-through iptables REDIRECT to an in-container SNI destination router and DNS resolver sidecar). What happened at that chokepoint was pluggable: by default, a built-in destination allow/deny router and DNS heuristic; optionally, any external mediator the router forwarded allowed traffic to via HTTP CONNECT (`network.http.forward_to`).

A mediator was declared as an entry in the global tool manifest with `archetype: MEDIATOR` (`run_as_uid`, optional `ca_cert_path`, `hooks.start`/`hooks.teardown`). `rc build` baked the hook strings into the image and stamped an `rc.mediators` label; `network.egress.mediator: <name>` selected one, validated fail-closed against that label. Launch was a host-driven `docker exec -u root` step (`init-mediator.sh`), after the firewall's iptables setup and before agent-context init — the mediator dropped to its dedicated non-root uid, which was uid-exempted from the REDIRECT rules to prevent a loop. The real secret reached the mediator's process env only via `rc up --mediator-env`/`--mediator-env-file`, never `/proc/1/environ`.

Two reference providers shipped as examples (neither baked): **mitmproxy** (proof provider, Python addon for credential injection) and **iron-proxy** (recommended-adopt, Apache-2.0 single Go binary, OOTB default-deny + built-in injection). Both recipes, and the manifest MEDIATOR archetype they targeted, are deleted at the msb cutover ([ADR-029](../decisions/ADR-029-msb-migration.md) D2/D5) — msb absorbed the credential-non-possession property as a runtime primitive (`--secret`), and no replacement L7-content-policy seam was built.

</details>
