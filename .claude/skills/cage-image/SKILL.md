---
name: cage-image
description: "Extend the rip-cage base image with your own Dockerfile and boot-descriptor fragment. Use when a cage needs a tool, language runtime, database, multiplexer (tmux, herdr), or command guard that the base image does not have; when `rc build` fails or refuses; or when the human says 'add <tool> to the cage', 'the cage needs <X>', 'build a custom cage image'. Do NOT use for the per-project config file of mounts, secrets and egress (that is cage-config) or for running a cage (that is cage-ops)."
---

# cage-image

Invoke this when what a cage needs is *inside the image*: a binary on PATH, a
server that starts at boot, a multiplexer that survives a detach, a command
guard. The artifact you produce is **one Dockerfile** (plus the files it copies)
that a human can read before `rc build` runs. You do not run `rc build` on a
shared host without saying so first — it moves the image tag every cage boots
from.

## The whole model in four lines

1. Your Dockerfile starts `FROM ghcr.io/jsnyde0/rip-cage:latest`.
2. Anything that must be installed as root goes between `USER root` and
   `USER agent`.
3. Anything that must **start** at boot also ships a small JSON fragment,
   merged into the cage's boot descriptor at build time with `rc-boot-merge`.
4. `rc build --file <your Dockerfile>` builds it. One input, fixed argv.

There is no manifest, no tool registry, and no schema to satisfy. The
Dockerfile IS the composition ([ADR-031](../../../docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D4).

**Start from [`examples/base/Dockerfile.snippet`](../../../examples/base/Dockerfile.snippet)** —
it is a complete working Dockerfile that adds nothing, with the two rules that
bite spelled out in its own comments. Read it before writing anything.

## Two rules that fail silently if you break them

Both are stated in `examples/base/`, and both were measured, not guessed:

- **End on `USER agent`.** An extension whose last `USER` is root boots a root
  shell with every mount stranded under `/home/agent` — silently, no error.
- **Never prepend to `PATH` to shadow a base-image tool.** The prepend survives
  into the interactive shell, but the base image's own wrappers resolve by
  absolute path and will not see it. You get half of each.

## Assert the tool is there, in the Dockerfile

```dockerfile
RUN which ripgrep
```

A `RUN` that fails the build is a stronger claim than a line saying a tool
should be present, because it is checked against the artifact. The retired
manifest had a "declared capability" field for this; a build-time assertion
replaces it and cannot drift from what actually shipped.

*Done when:* every tool your Dockerfile claims to add has a line that fails the
build if it is absent.

## When you also need a boot fragment

A tool you just want on PATH needs nothing but a `RUN`. A tool that **starts
something** needs to declare it:

```dockerfile
COPY boot-fragment.json /tmp/f.json
RUN rc-boot-merge /tmp/f.json && rm -f /tmp/f.json
```

Three kinds of declaration, and the schema for each:

| Array | For | Required fields |
|---|---|---|
| `daemons[]` | a server that runs for the cage's life | `name`, `start`, `health` |
| `multiplexers[]` | a session surface `rc up` attaches to | `name`, `start`, `attach` |
| `tools[]` | how an agent binary launches, plus a one-shot boot hook | `name` |

The authoritative schema is the `_readme` key inside the descriptor itself:
[`cage/boot/boot.json`](../../../cage/boot/boot.json). Read it there — it is
the file, so it cannot be out of date. It also carries the **daemon gotcha**
(prefix the real server with `exec`, and `health` is the liveness authority,
never the pid), which is the single most common way a fragment looks right and
is wrong.

`rc-boot-merge`'s own header states the merge rule and why merging is
mechanical rather than auto-wiring: [`cage/boot/rc-boot-merge`](../../../cage/boot/rc-boot-merge).

## Where the Dockerfile must live

**Outside every path your cage config mounts.** `rc build` refuses a Dockerfile
inside a cage mount, fail-closed, with no opt-out — a cage that can edit its own
next image is not contained ([ADR-031](../../../docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5).

`~/.config/rip-cage/images/` is a good home.

## What `rc build` will and will not take

```bash
rc build --file <path-to-Dockerfile>
```

That is the whole surface. `rc` hands docker a fixed argv — the file, a version
build-arg, a tag, and the file's own directory as context. **Anything else is
rejected before any docker call.** Express the rest in the Dockerfile, which is
yours to write. Set `RC_IMAGE` to build under a different tag.

Bare `rc build` builds rip-cage's own base image.

*Done when:* `docker image inspect <tag>` succeeds and reports the version
label you expect.

## Recipes

Each of these is a real, maintained directory under `examples/`. **Read the
recipe and paste its snippet; do not copy the snippet into this skill** — a
copy diverges from the thing it copied, which is exactly how the skill this one
replaced went stale.

| Want | Recipe |
|---|---|
| the smallest complete Dockerfile | [`examples/base/`](../../../examples/base/) |
| a tmux session that survives detach | [`examples/tmux/`](../../../examples/tmux/) |
| a headless agent supervisor | [`examples/herdr/`](../../../examples/herdr/) |
| a destructive-command guard | [`examples/dcg/`](../../../examples/dcg/) |
| Postgres + pgvector inside the cage | [`examples/postgres-pgvector/`](../../../examples/postgres-pgvector/) |
| the Claude Code session wrapper | [`examples/claude/`](../../../examples/claude/) |
| the pi coding agent | [`examples/pi/`](../../../examples/pi/) |
| herdr's pi extension alongside DCG | [`examples/herdr-pi/`](../../../examples/herdr-pi/) |
| an egress mediator add-on | [`examples/mitmproxy/`](../../../examples/mitmproxy/) |

[`examples/README.md`](../../../examples/README.md) is the index, and the
`examples/compose-*.md` files are longer walk-throughs that wire several
recipes together.

Guided paths through them:

- [`recipes/add-a-tool.md`](recipes/add-a-tool.md) — a binary on PATH, nothing
  starts. The common case.
- [`recipes/add-a-daemon.md`](recipes/add-a-daemon.md) — something has to run:
  a server, a multiplexer, a guard.

## References

- [`references/boot-descriptor.md`](references/boot-descriptor.md) — how the
  three arrays behave at boot, and the failures each one produces.
- [`references/build-inputs.md`](references/build-inputs.md) — why `rc build`
  takes one file and a fixed argv, and what that rules out.

## rip-cage blesses no tool

`rc`'s code names no optional tool — not a multiplexer, not a guard, not a
database. Adding one is a Dockerfile you write, with zero `rc` edits
([ADR-005](../../../docs/decisions/ADR-005-ecosystem-tools.md) D12). If a change
you are considering would put a tool's NAME inside `rc`, that is the signal it
belongs in a recipe instead.

Likewise: do not build a script that reads recipes and assembles a Dockerfile.
Composition is the judgment; automating it is the drift this design is holding
against.

## microsandbox itself

The image is `docker build`-produced and msb-run. For anything about msb's own
image handling — loading, caching, inspecting — read the maintained skill at
`~/code/personal/superradcompany-skills/microsandbox/SKILL.md` rather than a
copy.

## Done condition — report this

1. **The Dockerfile path**, and that it resolves outside every mount in the
   cage config that will use the image.
2. **`rc build --file <path>` exited 0**, and `docker image inspect <tag>`
   succeeds.
3. **Every added tool has a build-time assertion** that would have failed the
   build if the tool were missing.
4. **If you shipped a fragment:** the cage boots and the thing it declared is
   live. Init runs each declared daemon's `health` at boot and warns on failure,
   so the evidence is in the `rc up` output — grep it for `[rip-cage] daemon`.
   Confirm independently by running the `health` command yourself:
   `msb exec <cage> -- sh -c '<the health command>'`. A fragment that merged
   cleanly but declares a daemon that never becomes healthy is a green build and
   a broken cage.

Name any of the four that is not green, and stop.
