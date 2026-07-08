# Examples — Recipe Index

Every directory and standalone file here is a **recipe**: a concrete, legible fragment an agent reads to learn how to compose a particular seam. Recipes are **inspiration**, not validated machinery — rip-cage does not auto-scan or auto-install them. The agent reads a recipe, copies the relevant `tools[]` entries into `~/.config/rip-cage/tools.yaml`, and runs `rc build`.

See [docs/reference/README.md](../docs/reference/README.md) for the seam catalog (what each archetype is for and the manifest field shape). See [docs/reference/adding-a-tool.md](../docs/reference/adding-a-tool.md) for a generic TOOL-add walkthrough.

---

## Guard recipes

These recipes compose on top of the containment floor to block classes of dangerous commands via Claude Code's `PreToolUse` hook system. Omitting a guard means no command-guard for that class; containment still holds. ([ADR-025](../docs/decisions/ADR-025-host-adoptable-dcg-policy.md), [ADR-026 D2](../docs/decisions/ADR-026-containment-mediation-identity.md))

| Recipe | Seam | What it provides |
|---|---|---|
| [examples/dcg/](dcg/) | Guard (TOOL) | DCG (Destructive Command Guard) — builds the `dcg` binary from source (Rust) and bakes the guard wrapper engine + cage config + pi DCG extension (`dcg-gate.ts`). Blocks `rm -rf`, `dd`, format ops, and more. See [dcg/README.md](dcg/README.md). |
| [examples/ssh-bypass/](ssh-bypass/) | Guard (TOOL) | `block-ssh-bypass.sh` — Perl PreToolUse hook that blocks `ssh`/`scp`/`sftp` invocations carrying host-key-override flags (`-o StrictHostKeyChecking=no`, etc.). See [ssh-bypass/README.md](ssh-bypass/README.md). |

---

## Multiplexer recipes

Multiplexers provide the terminal session layer (persistence, attach/detach) above the containment floor. Selected via `session.multiplexer` in `.rip-cage.yaml`. Each provider needs a TOOL entry (binary install) + a MULTIPLEXER entry (start/attach hooks). ([ADR-021 D6](../docs/decisions/ADR-021-layered-rip-cage-config.md))

| Recipe | Seam | What it provides |
|---|---|---|
| [examples/herdr/](herdr/) | Multiplexer (TOOL + MULTIPLEXER) | herdr agent-supervisor: unix-socket headless supervisor with a TUI client. Hooks: `herdr server` (start), `herdr` (attach). Installs herdr integrations for pi and claude at boot. See [manifest-fragment.yaml](herdr/manifest-fragment.yaml) and [compose-rc-with-herdr.md](compose-rc-with-herdr.md). |
| [examples/tmux/](tmux/) | Multiplexer (TOOL + MULTIPLEXER) | tmux session persistence: creates a background `rip-cage` session, attaches on `rc up`/`rc attach`. Installs via apt. See [manifest-fragment.yaml](tmux/manifest-fragment.yaml). |

---

## Mediator recipes

Mediators compose onto rip-cage's egress chokepoint for L7 traffic inspection, credential injection, or content-level policy. The mediator receives all allowed HTTPS traffic via HTTP CONNECT (`network.http.forward_to`). Each provider needs a TOOL entry (binary + uid setup) + a MEDIATOR entry (start hook, `run_as_uid`, optional `ca_cert_path`). ([ADR-026 D5](../docs/decisions/ADR-026-containment-mediation-identity.md), [composition-seam.md](../docs/reference/composition-seam.md))

| Recipe | Seam | What it provides |
|---|---|---|
| [examples/iron-proxy/](iron-proxy/) | Mediator (TOOL + MEDIATOR) | iron-proxy (Apache-2.0, single Go binary) — recommended-adopt provider. OOTB default-deny + built-in placeholder→real-secret injection, no addon to write. See [manifest-fragment.yaml](iron-proxy/manifest-fragment.yaml) and [compose-rc-with-iron-proxy.md](compose-rc-with-iron-proxy.md). |
| [examples/mitmproxy/](mitmproxy/) | Mediator (TOOL + MEDIATOR) | mitmproxy — reference/proof provider. Validates the seam end-to-end; a Python addon handles credential injection. Read this recipe first to understand the seam mechanics before adopting iron-proxy. See [manifest-fragment.yaml](mitmproxy/manifest-fragment.yaml) and [compose-rc-with-mitmproxy.md](compose-rc-with-mitmproxy.md). |

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
