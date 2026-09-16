# pi recipe — cage-topology doc + extensions-dir hook

Gives the pi coding agent a topology doc (network/filesystem orientation
inside the cage) and makes sure `~/.pi/agent/extensions/` exists before
anything tries to write into it. The pi binary itself ships in the base image
(`npm install`) — this recipe adds a small amount of glue on top of it.

Not floor, never on by default (ADR-005 D12 FIRM). This directory is a recipe
you compose; nothing in `rc` knows it exists.

## What is in here

| file | what it is |
|---|---|
| `Dockerfile.snippet` | the lines to paste into your own Dockerfile |
| `boot-fragment.json` | the `tools[].init` declaration, merged into the image's boot descriptor at build time |
| `cage-pi.md` | the cage-topology doc, read directly by pi at its known path |

## Use it

1. Write your own Dockerfile outside every directory your cage config mounts —
   `rc build` refuses one inside a cage mount, fail-closed, no opt-out
   (ADR-031 D5(a)). `~/.config/rip-cage/images/` is a good home.

   ```dockerfile
   FROM ghcr.io/jsnyde0/rip-cage:latest
   # ...paste Dockerfile.snippet here...
   ```

   Copy `cage-pi.md` and `boot-fragment.json` next to it.

2. Build and point your cage config's `image:` key at the result:

   ```bash
   RC_IMAGE=my-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
   ```

3. `rc up`. pi runs with no launch wrapping at all by default — see below.

## Running pi with no guard needs nothing composed

The base image's generic per-tool launch wrapper execs the real `pi` binary
directly whenever the boot descriptor's `tools[]` entry for `pi` declares no
`launch` command — which is exactly what this recipe alone ships (only `init`,
no `launch`). pi auto-discovers its own extensions from `/workspace/.pi/extensions/`
and `~/.pi/agent/extensions/` normally. There is no separate "no-guard" fragment
to compose — it is the out-of-the-box shape once you compose nothing more.

## The `init` hook

```json
{"name": "pi", "init": "..."}
```

`tools[].init` is a one-shot, agent-context boot hook (no sudo, fail-warn — a
broken hook logs a warning and never bricks the cage). This one creates
`~/.pi/agent/extensions/` if absent. It exists because herdr's
`herdr integration install pi` (run by the herdr multiplexer's `start` hook,
[`examples/herdr/`](../herdr/)) writes into that directory but does not create
it — without this hook, a fresh cage with no prior extensions dir makes that
install fail with "extension directory not found" (`rip-cage-fwp3`). It must
run as the agent, not root: creating the dir as root at build time reintroduces
the exact permission-denied bug this hook fixes.

## Adding the DCG guard

Compose [`examples/dcg/`](../dcg/) alongside this recipe. Its own
`boot-fragment.json` declares `tools[].launch` for `pi` (pointing at the real
binary plus `-e <dcg-gate.ts>`) — merge DCG's fragment **after** this one so its
`launch` value is what survives (`rc-boot-merge` replaces a `tools[]` entry by
name; the last fragment merged for a given tool name wins wholesale, it does
not combine fields). This recipe's `init` hook still applies underneath: tools[]
replace-by-name replaces the merged JSON object for `pi`, so if you want both
`init` (this recipe) and `launch` (DCG) on the same `pi` entry, either merge
DCG's fragment second in the same Dockerfile (DCG's own fragment also declares
`init` — read [`examples/dcg/boot-fragment.json`](../dcg/boot-fragment.json))
or write one fragment yourself carrying both fields. See
[`examples/dcg/README.md`](../dcg/README.md) for the OPEN/LOCKED posture choice.

## Adding herdr's semantic-status extension

Compose [`examples/herdr-pi/`](../herdr-pi/) — it is the worked example of
combining **two** recipes that both want to extend pi's launch line (DCG's
guard `-e` and herdr's status `-e`) into one `tools[].launch` value, since
`rc-boot-merge` cannot combine two fragments' contributions to the same field
automatically. Read it once; the same hand-composition move applies to any
third `-e` extension you add later (including a pi extension your own project
keeps on the host and mounts in via the cage config's own `mounts:` list,
analogous to the old subagent-extension pattern this recipe used to ship as a
separate fragment).

## Pinning pi's provider/model (headless throttle)

A fresh headless pi invocation defaults to resolving the Claude subscription
entitlement, which Anthropic throttles for third-party apps (400 "Third-party
apps now draw from your extra usage"). This only bites once pi runs unattended
long enough to hit it — interactively-driven pi with working subscription auth
never does. If you hit it, pin a static-key provider by adding `--model
<provider/model>` to whichever `tools[].launch` value you author for `pi` (a
plain `sh -c` command string — append the flag before `"$@"`'s implicit pass-
through). There is no shipped default value here: pick the provider/model that
matches your own auth.

## Two things worth knowing before you change this

**Resolution is by absolute path.** The base image moves the real `pi` binary
to `/usr/local/lib/rip-cage/bin/pi-real` and puts its own generic launch
wrapper at the original PATH name (ADR-031 D4). Any `launch` command you
declare should invoke `pi-real` at that absolute path, not `pi` — invoking `pi`
would recurse back into the wrapper.

**`tools[]` merges replace-by-name, they do not combine fields.** This is the
single most common mistake composing multiple pi recipes: two Dockerfile
snippets that each merge their own `{"name": "pi", "launch": "..."}` fragment
leave only the SECOND one's `launch` value in the descriptor — the first is
silently dropped, not appended to. `examples/herdr-pi/` is the worked example
of composing around this deliberately (ADR-005 D12: composition is the
composing agent's judgment, not something `rc` automates for you).
