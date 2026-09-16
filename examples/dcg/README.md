# dcg recipe — destructive-command guard

Builds the DCG (Destructive Command Guard) binary from source and wires it in
front of every Bash tool call, so a destructive command (a recursive delete
targeting root or home, a raw-disk `dd`, a format op, and more) gets refused
instead of executed.

DCG is **NOT floor** (ADR-025 D2, ADR-026 D2). It is a composable recipe.
Without it, containment still holds via the other layers (the msb microVM
boundary, default-deny egress) — there is simply no command-level guard.
Nothing in `rc` names it; this directory is a recipe you compose.

## What is in here

| file | what it is |
|---|---|
| `Dockerfile.snippet` | the lines to paste into your own Dockerfile — a builder stage plus a wiring block |
| `boot-fragment.json` | the `tools[].launch` declaration that loads the guard into pi's launch, merged at build time |
| `build-dcg-from-source.sh` | the from-source build script, run inside the isolated builder stage |
| `dcg-guard` | the wrapper engine — pins config, strips override variables, execs the binary |
| `config.toml` | the cage-owned DCG config |
| `ripcage-testsentinel-rule.yaml` | a sentinel fixture used by the recipe's own smoke test |
| `dcg-gate.ts` | the pi-agent guard extension — a TypeScript pi extension that shells out to `dcg-guard` |
| `smoke.sh` | the recipe's behavioral test, run by `rc test` |

## Use it

1. Write your own Dockerfile outside every directory your cage config mounts —
   `rc build` refuses one inside a cage mount, fail-closed, no opt-out
   (ADR-031 D5(a)). `~/.config/rip-cage/images/` is a good home.

   Paste the builder stage from `Dockerfile.snippet` **before** your own
   `FROM ghcr.io/jsnyde0/rip-cage:latest` line, and the wiring block **between**
   that line and `USER agent`:

   ```dockerfile
   FROM rust:1-slim-trixie AS dcg-builder
   # ...paste the builder-stage lines here...

   FROM ghcr.io/jsnyde0/rip-cage:latest
   USER root
   # ...paste the wiring-block lines here...
   USER agent
   ```

   Copy every other file in this directory next to your Dockerfile — the
   `COPY` lines read from the build context, which is that Dockerfile's own
   directory.

2. Build and point your cage config's `image:` key at the result:

   ```bash
   RC_IMAGE=my-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
   ```

3. `rc up`. Every pi invocation now routes through the guard.

## Adding a rule

Edit `config.toml` (the cage-owned DCG config) or add a custom rule file
alongside `ripcage-testsentinel-rule.yaml`, then re-`rc build`. The `core` pack
is force-enabled by DCG regardless of this file — its sole job is to parse
successfully, which suppresses the agent-writable user-layer
`~/.config/dcg/config.toml` DCG would otherwise also read (config.rs:2417 —
the user layer loads only when the cage's own config path is unset). **Do not
delete `config.toml`** — a missing or malformed cage config silently re-opens
that hole.

## How DCG works

`dcg-guard` (the wrapper, root-owned so the agent cannot replace or weaken it):

1. `cd`s to a root-owned, `.git`-free directory so DCG's own project-config
   discovery never walks up to `/workspace` and finds an agent-written
   `/workspace/.dcg.toml`.
2. Pins the config path to `config.toml` above.
3. Strips `DCG_*` overrides that could weaken policy.
4. `exec`s the pinned `dcg` binary with stdin passed through.

**Never invoke `/usr/local/bin/dcg` directly from a hook** — always go through
`dcg-guard`. Without this recipe composed, a hook that calls `dcg-guard`
directly finds no binary and fails open (non-blocking) — see
[`examples/claude/README.md`](../claude/README.md) for that coupling on the
Claude Code side.

## pi wiring: OPEN by default, LOCKED opt-in (ADR-027 D1/D4)

`boot-fragment.json` declares:

```json
{ "tools": [{ "name": "pi", "launch": "/usr/local/lib/rip-cage/bin/pi-real -e /etc/rip-cage/pi/dcg-gate.ts" }] }
```

This is the **OPEN default** (ADR-027 D1, FIRM 2026-07-02): the guard extension
always loads, but pi's own extension auto-discovery paths
(`/workspace/.pi/extensions/`, `~/.pi/agent/extensions/`) stay live.
**Accepted residual ("vector-b")**: a prompt-injected pi agent could write its
own extension into an auto-discovery path and have it auto-load — there is no
guard against that in the open default. This trade favors agent autonomy (the
point of the cage) over closing that residual.

To close vector-b at the cost of pi extension autonomy, edit your own copy of
`boot-fragment.json` to add `--no-extensions` ahead of the `-e` flag:

```json
{ "tools": [{ "name": "pi", "launch": "/usr/local/lib/rip-cage/bin/pi-real --no-extensions -e /etc/rip-cage/pi/dcg-gate.ts" }] }
```

`--no-extensions` disables pi's auto-discovery paths entirely — only
extensions explicitly listed via `-e` load. This is a real autonomy cost: the
agent can no longer drop its own pi extensions into
`~/.pi/agent/extensions/` and have them pick up automatically. Most cages
should stay on the open default; reach for the locked variant only when that
tradeoff is acceptable for your threat model.

## Claude Code wiring

Claude Code reaches the guard through a different mechanism — a root-owned
`managed-settings.json` `PreToolUse` hook, not `tools[].launch`. Compose
[`examples/claude/`](../claude/) for that; its recipe calls `dcg-guard`
unconditionally, so composing DCG alongside it is what makes the hook actually
block instead of failing open.

## Composing with another pi launch extension (e.g. herdr)

`rc-boot-merge` replaces a `tools[]` entry **by name**, wholesale — it does not
combine two fragments' `launch` values for the same tool. If you also want
herdr's semantic-status pi extension loaded, read
[`examples/herdr-pi/README.md`](../herdr-pi/README.md): it is the worked
example of hand-combining two `-e` contributions into one `launch` string.
