# Examples — Recipe Index

Every directory and standalone file here is a **recipe**: a concrete, legible
`Dockerfile.snippet` (plus a `boot-fragment.json` when it starts something)
that you paste into your own Dockerfile. Recipes are **inspiration**, not
validated machinery — rip-cage does not auto-scan or auto-install them. You
(or the agent acting for you) read a recipe, paste its `Dockerfile.snippet`
into a Dockerfile that extends the published base image, copy the other files
it asks for next to it, and run `rc build --file <path>`.

See [docs/reference/README.md](../docs/reference/README.md) for the composable-seam
catalog and [examples/base/](base/) for the smallest complete starting point.

---

## Guard recipes

These recipes compose on top of the containment floor to block classes of
dangerous commands. Omitting a guard means no command-guard for that class;
containment still holds. ([ADR-025](../docs/decisions/ADR-025-host-adoptable-dcg-policy.md),
[ADR-026 D2](../docs/decisions/ADR-026-containment-mediation-identity.md))

| Recipe | What it provides |
|---|---|
| [examples/dcg/](dcg/) | DCG (Destructive Command Guard) — builds the `dcg` binary from source (Rust builder stage) and bakes the guard wrapper engine + cage config + pi guard extension (`dcg-gate.ts`). See [dcg/README.md](dcg/README.md). |

`examples/ssh-bypass/` (the ssh host-key-override guard) is **deleted, not
just undocumented** — it retired wholesale with the ssh cluster
([ADR-029](../docs/decisions/ADR-029-msb-migration.md) D3). Git now
authenticates over HTTPS + msb `--secret`; there is no ssh host-key-override
surface left to guard.

---

## Multiplexer recipes

Multiplexers provide the terminal session layer (persistence, attach/detach)
above the containment floor. Selected at launch with `RC_MULTIPLEXER=<name>`,
not a config file field. Each provider needs a `multiplexers[]` boot-descriptor
entry (`start`/`attach`, plus optional `exec`/`new_session`/`teardown`).

| Recipe | What it provides |
|---|---|
| [examples/herdr/](herdr/) | herdr agent-supervisor: unix-socket headless supervisor with a TUI client. Installs herdr integrations for pi and claude at boot. See [herdr/README.md](herdr/README.md). |
| [examples/tmux/](tmux/) | tmux session persistence: creates a background `rip-cage` session, attaches on `rc up`. See [tmux/README.md](tmux/README.md). |

---

## Daemon recipes

Long-running localhost services in-cage agents talk to. Each is a `daemons[]`
boot-descriptor entry: `start`, `health`, optional `state_dir`.

| Recipe | What it provides |
|---|---|
| [examples/postgres-pgvector/](postgres-pgvector/) | Postgres 17 + pgvector as a plain unprivileged process, so a caged agent can run a DB-backed test suite with no docker in the cage and no containment-floor change. See [postgres-pgvector/README.md](postgres-pgvector/README.md). |

---

## Mediator recipes — DROPPED

> **There is no manifest-declared MEDIATOR archetype, and no `rc`-side mediator
> launch, selection, or HTTP-CONNECT handoff surface left to recipe against**
> ([ADR-029](../docs/decisions/ADR-029-msb-migration.md) D2/D5,
> [ADR-031](../docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2/D4).
> `examples/iron-proxy/`, `examples/mitmproxy/`, `compose-rc-with-iron-proxy.md`,
> and `compose-rc-with-mitmproxy.md` — which documented a co-located proxy
> `rc` launched and wired — are removed from this tree.
>
> Credential non-possession for the dominant secret (Claude's own auth, and any
> git host token) is a **default platform property** via msb `--secret`: a
> `secrets:` entry in the project's own cage config, `value:` deliberately
> omitted (msb resolves the real value from a same-named host variable at boot;
> the guest only ever sees a placeholder) — see the 2026-09-15 amendment in
> [ADR-031](../docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md)
> D2 and [ADR-029](../docs/decisions/ADR-029-msb-migration.md) D5. If you need
> L7 content policy (method/path rules, request rewriting) beyond a per-host
> secret binding, that is fully **operator-composed and unwired** today — run
> a proxy yourself, outside `rc`'s declared composition surface.

**Alternative appliance (not a mediator):**

| File | What it covers |
|---|---|
| [compose-rc-with-clawpatrol.md](compose-rc-with-clawpatrol.md) | clawpatrol (Deno WireGuard appliance) — note on when this architecture applies; clawpatrol cannot plug into any `rc`-side mediator seam (none exists) and is an alternative appliance you run *instead of* rip-cage's own egress control, not a downstream mediator. |

---

## Agent recipes

Recipes that harden how an agent binary itself launches — session isolation,
a floor-lock hook registration, a cage-topology doc. Each declares a
`tools[].launch` and/or `tools[].init` boot-descriptor entry for an agent the
base image already installs (`claude`, `pi`).

| Recipe | What it provides |
|---|---|
| [examples/claude/](claude/) | Claude Code session-isolation wrapper + DCG floor-lock via root-owned `managed-settings.json`. See [claude/README.md](claude/README.md). |
| [examples/pi/](pi/) | pi cage-topology doc + the extensions-dir boot hook herdr's integration install needs. Running pi with no guard and no launch wrapping needs nothing composed at all — see [pi/README.md](pi/README.md). |

---

## Launch-composition recipes

A recipe that shows **combining** multiple fragments — guard + multiplexer +
agent — into one `tools[].launch` value, since `rc-boot-merge` replaces a
`tools[]` entry by name and cannot combine two fragments' `launch` strings for
the same tool automatically.

| Recipe | What it provides |
|---|---|
| [examples/herdr-pi/](herdr-pi/) | The canonical composition worked example: herdr's pi semantic-status extension loaded alongside the DCG guard in one combined `launch` string, plus the herdr multiplexer. See [herdr-pi/README.md](herdr-pi/README.md). |

---

## Whole-cage composition recipes

Recipes that compose a full cage shape spanning multiple recipes at once —
read fresh each time rather than copied from a pre-built manifest, since there
is no manifest file for a delta to drift out of sync with.

| Recipe | What it provides |
|---|---|
| [compose-walk-away-cage.md](compose-walk-away-cage.md) | Walk-away/headless multi-agent delta: herdr (supervisor multiplexer) + herdr-pi (status extension) recipes, and the pi provider/model pin (closes the headless-throttle footgun). Credential non-possession is a cage-config `secrets:` declaration, not a composed mediator. |
| [examples/dotpi-3bi/](dotpi-3bi/) | Factory socket-API drive delta on top of `examples/herdr/`: how a host-side orchestrator drives a cage's herdr pane via `pane run`/`pane read` (not interactive attach) — session-scoped socket path + explicit pane sizing, the two headless-herdr gotchas. See [dotpi-3bi/README.md](dotpi-3bi/README.md). |
