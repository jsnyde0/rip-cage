# Examples — Recipe Index

Every directory and standalone file here is a **recipe**: a concrete, legible fragment an agent reads to learn how to compose a particular seam. Recipes are **inspiration**, not validated machinery — rip-cage does not auto-scan or auto-install them. The agent reads a recipe, copies the relevant `tools[]` entries into `~/.config/rip-cage/tools.yaml`, and runs `rc build`.

See [docs/reference/README.md](../docs/reference/README.md) for the seam catalog (what each archetype is for and the manifest field shape). See [docs/reference/adding-a-tool.md](../docs/reference/adding-a-tool.md) for a generic TOOL-add walkthrough.

---

## Guard recipes

These recipes compose on top of the containment floor to block classes of dangerous commands via Claude Code's `PreToolUse` hook system. Omitting a guard means no command-guard for that class; containment still holds. ([ADR-025](../docs/decisions/ADR-025-host-adoptable-dcg-policy.md), [ADR-026 D2](../docs/decisions/ADR-026-containment-mediation-identity.md))

| Recipe | Seam | What it provides |
|---|---|---|
| [examples/dcg/](dcg/) | Guard (TOOL) | DCG (Destructive Command Guard) — builds the `dcg` binary from source (Rust) and bakes the guard wrapper engine + cage config + pi DCG extension (`dcg-gate.ts`). Blocks `rm -rf`, `dd`, format ops, and more. See [dcg/README.md](dcg/README.md). |

`examples/ssh-bypass/` (the ssh host-key-override PreToolUse guard) is **deleted, not just undocumented** — it retired wholesale with the ssh cluster ([ADR-029](../docs/decisions/ADR-029-msb-migration.md) D3). Git now authenticates over HTTPS + msb `--secret`; there is no ssh host-key-override surface left to guard.

---

## Multiplexer recipes

Multiplexers provide the terminal session layer (persistence, attach/detach) above the containment floor. Selected via `session.multiplexer` in `.rip-cage.yaml`. Each provider needs a TOOL entry (binary install) + a MULTIPLEXER entry (start/attach hooks). ([ADR-021 D6](../docs/decisions/ADR-021-layered-rip-cage-config.md))

| Recipe | Seam | What it provides |
|---|---|---|
| [examples/herdr/](herdr/) | Multiplexer (TOOL + MULTIPLEXER) | herdr agent-supervisor: unix-socket headless supervisor with a TUI client. Hooks: `herdr server` (start), `herdr` (attach). Installs herdr integrations for pi and claude at boot. See [manifest-fragment.yaml](herdr/manifest-fragment.yaml) and [compose-rc-with-herdr.md](compose-rc-with-herdr.md). |
| [examples/tmux/](tmux/) | Multiplexer (TOOL + MULTIPLEXER) | tmux session persistence: creates a background `rip-cage` session, attaches on `rc up`/`rc attach`. Installs via apt. See [manifest-fragment.yaml](tmux/manifest-fragment.yaml). |

---

## Mediator recipes — DROPPED

> **The manifest-declared MEDIATOR archetype and its launch machinery are deleted, not merely undocumented** ([ADR-029](../docs/decisions/ADR-029-msb-migration.md) D2/D5). `examples/iron-proxy/`, `examples/mitmproxy/`, `compose-rc-with-iron-proxy.md`, and `compose-rc-with-mitmproxy.md` — which documented `network.egress.mediator` + `network.http.forward_to` + a `docker exec -u root`-launched, uid-exempted co-located proxy — are removed from this tree. There is no `rc`-side mediator launch, selection, or HTTP-CONNECT handoff surface left to recipe against; `network.egress.mediator`/`network.http.forward_to` are gone from the config schema (retained only as inert legacy fields, see [config.md](../docs/reference/config.md)).
>
> Credential non-possession for the dominant secret (Claude's own auth, and any git host token) is now a **default platform property** via msb `--secret` (`auth.credentials` in `.rip-cage.yaml` — see [egress.md](../docs/reference/egress.md)), not something that required composing a mediator. If you need L7 content policy (method/path rules, request rewriting) or credential injection beyond `--secret`'s per-host binding, that is fully **operator-composed and unwired** today — rip-cage provides no manifest archetype, launch hook, or forward-to seam for it; you'd run a proxy yourself and point your own tooling at it, outside `rc`'s declared composition surface.

**Alternative appliance (not a mediator):**

| File | What it covers |
|---|---|
| [compose-rc-with-clawpatrol.md](compose-rc-with-clawpatrol.md) | clawpatrol (Deno WireGuard appliance) — note on when this architecture applies; clawpatrol cannot plug into the MEDIATOR seam (no transparent-proxy ingress) and is an alternative appliance, not a downstream mediator. |

---

## TOOL recipes

Plain tool installation recipes — binary-on-PATH tools or in-cage substrates that compose via the TOOL manifest archetype without needing multiplexer or mediator-specific fields.

| Recipe | Seam | What it provides |
|---|---|---|
| [examples/claude/](claude/) | TOOL | Claude Code session-isolation wrapper + DCG floor-lock via root-owned `managed-settings.json`. Bakes `/usr/local/bin/claude` (wrapper) and `/etc/claude-code/managed-settings.json` (un-suppressible hook registration). See [claude/README.md](claude/README.md). |
| [examples/pi/](pi/) | TOOL | pi coding-agent launch-hardening wrapper + cage-topology doc. Bakes `/etc/rip-cage/cage-pi.md`. DCG guard wiring is contributed by the DCG fragment via `launch_args` (compose separately). See [pi/README.md](pi/README.md) and [pi/manifest-fragment-no-guard.yaml](pi/manifest-fragment-no-guard.yaml) for the no-guard path. |

---

## Launch-composition recipes

Recipes that demonstrate **combining** multiple fragments — guard + multiplexer + tool — using the `launch_args` mechanism ([ADR-027 D4](../docs/decisions/ADR-027-agent-substrate-projection.md)). Each fragment declares its own `launch_args` contribution; `rc build` assembles them in fragment order into a generic launch shim. No runtime contribution directory.

| Recipe | Seam | What it provides |
|---|---|---|
| [examples/herdr-pi/](herdr-pi/) | Launch composition (TOOL with `launch_args`) | The canonical launch-composition example: herdr's pi semantic-status extension composed alongside DCG. Shows how `launch_args` from DCG (`-e <dcg-gate>`, OPEN by default — ADR-027 D1) and herdr-pi (`-e <herdr-ext>`) assemble in fragment order. With-DCG, without-DCG, and LOCKED-opt-in (`--no-extensions`) paths. See [herdr-pi/README.md](herdr-pi/README.md). |

---

## Whole-cage delta composition recipes

Recipes that compose a full cage shape as a **delta on top of `manifest/default-tools.yaml`** (the
published image's reference manifest), spanning multiple archetypes at once. No pre-composed
manifest ships alongside these — read the fragments they point at fresh, per the same judgment
the `configure-cage` skill applies.

| Recipe | What it provides |
|---|---|
| [compose-walk-away-cage.md](compose-walk-away-cage.md) | Walk-away/headless multi-agent delta: `dist` + herdr (supervisor multiplexer) + herdr-pi (status extension) fragments, the pi provider/model pin (closes the headless-throttle footgun), and the egress mediator framed as situational/optional (ADR-026), not part of the base delta. |
| [examples/dotpi-3bi/](dotpi-3bi/) | Factory socket-API drive delta on top of `examples/herdr/`: how a host-side orchestrator drives a cage's herdr pane via `pane run`/`pane read` (not interactive attach) — session-scoped socket path + explicit pane sizing, the two headless-herdr gotchas. See [dotpi-3bi/README.md](dotpi-3bi/README.md). |
