# herdr-pi — worked example: composing two pi launch extensions

This recipe composes herdr's semantic-status pi extension alongside the DCG
guard, both loaded into the same pi launch line. It exists to teach one
mechanical fact about the boot descriptor that bites the first time you try
to combine two recipes that each want to add a `tools[].launch` command for
the same tool: `rc-boot-merge` **replaces a `tools[]` entry by name,
wholesale — it does not combine two fragments' `launch` values.** Paste
herdr's own Dockerfile snippet and DCG's own Dockerfile snippet, each running
its own boot-fragment merge, and whichever one merges *last* silently drops
the other's `-e` flag rather than adding to it.

This is not a bug to work around — it is ADR-005 D12's composable-seam
promise taken literally: composition is the composing agent's judgment, not
something `rc` automates. This recipe is the worked example of doing that
judgment call correctly.

## What problem this solves

herdr tracks the semantic status (working/blocked/idle) of coding agents. For
pi agents specifically, herdr can use either an **integration path** (pi loads
the herdr extension via `-e`, and the extension reports state transitions
over a unix socket in real time) or a **screen-detection fallback** (herdr
infers state by watching terminal output patterns). The integration path is
more reliable, but composing it and the DCG guard naively — one Dockerfile
snippet's merge stepping on the other's — silently loses one of the two.

## What is in here

| file | what it is |
|---|---|
| `Dockerfile.snippet` | generates herdr's pi extension at build time, then runs the ONE merge that matters |
| `boot-fragment.json` | the combined fragment: the herdr multiplexer entry AND pi's `launch` with BOTH `-e` flags |

## How to compose

1. Paste [`examples/herdr/Dockerfile.snippet`](../herdr/Dockerfile.snippet)
   into your own Dockerfile (installs the herdr binary — required before this
   recipe's `herdr integration install pi` step can run), **but drop its final
   two lines** (`COPY boot-fragment.json ...` / `RUN rc-boot-merge ...`).
2. If you want the guard too, also paste
   [`examples/dcg/Dockerfile.snippet`](../dcg/Dockerfile.snippet) (its builder
   stage AND its wiring block), **again dropping its final two lines.**
3. Paste this recipe's `Dockerfile.snippet` last. Copy `boot-fragment.json`
   next to your Dockerfile alongside every other file the two recipes above
   asked you to copy.
4. Build:

   ```bash
   RC_IMAGE=my-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
   ```

5. `RC_MULTIPLEXER=herdr rc up` — add the durable state mount from
   [`examples/herdr/README.md`](../herdr/README.md#the-durable-state-mount-required-for-restart-survival)
   to your project's cage config first.

The assembled pi launch command ends up:

```
/usr/local/lib/rip-cage/bin/pi-real -e /etc/rip-cage/pi/dcg-gate.ts -e /etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts
```

pi auto-discovers extensions normally alongside both explicit `-e` flags
(OPEN default, ADR-027 D1, FIRM 2026-07-02) — see
[`examples/dcg/README.md`](../dcg/README.md) for the LOCKED opt-in
(`--no-extensions`), which you would add by hand-editing this recipe's own
`boot-fragment.json` copy.

## Without the DCG guard

Drop step 2 above and edit this recipe's `boot-fragment.json` to remove the
`-e /etc/rip-cage/pi/dcg-gate.ts` flag from the `launch` string, keeping only
the herdr extension flag. pi auto-discovers extensions normally either way;
composing DCG only changes whether a command-level guard runs at all.

## D8 open-verification finding

`herdr integration install pi` accepts no output-directory flag — it always
writes to `<PI_CODING_AGENT_DIR>/extensions/herdr-agent-state.ts`, defaulting
to `~/.pi/agent/extensions/` when unset (inside this build stage, running as
root with no override, that resolves to `/root/.pi/agent/extensions/`). This
recipe runs the CLI first (the file content is 100% herdr-generated — never
hand-authored) and relocates only the *location* to the cage-owned path. The
herdr maintainer could close this fully by adding an `--output-dir` flag;
until then, generate-then-relocate is the correct minimal deviation.

## Socket mount: do not mount the host's `~/.config/herdr` over the cage's own

The herdr pi extension connects over the unix socket at `HERDR_SOCKET_PATH`.
When herdr runs as this cage's own multiplexer (the setup above), the server
needs a **writable** `~/.config/herdr` to create that socket — even a
read-only mount over it makes the in-cage server die at start with
`server did not become ready within 5s` (`Os code 30 ReadOnlyFilesystem`,
live-verified). The durable-state mount line from
[`examples/herdr/README.md`](../herdr/README.md) covers `session.json`
durability without colliding with this — it is a real host directory mounted
read-write at the same cage path the server already needs writable.

If instead a host-side supervisor watches this cage's herdr server from
*outside* (no in-cage server of its own), mount the host's `~/.config/herdr`
to a **non-colliding** cage path (e.g. `/home/agent/.config/herdr-host`) and
point `HERDR_SOCKET_PATH` at that path — never at the cage-local
`~/.config/herdr`.

## Upgrading herdr

1. Update the pinned version and checksums in
   [`examples/herdr/Dockerfile.snippet`](../herdr/Dockerfile.snippet).
2. Re-`rc build` — this recipe's own `RUN herdr integration install pi` step
   regenerates the extension from the updated binary automatically; nothing
   here needs a version bump of its own, since the file content is always
   herdr-generated.
