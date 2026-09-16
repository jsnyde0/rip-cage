# tmux multiplexer recipe

Gives a cage a tmux server, so a session survives a detach and `rc up` reattaches
to the work already in progress.

Not floor, never on by default (ADR-005 D12 FIRM). rip-cage's own code names no
multiplexer; this directory is a recipe you compose, and nothing in `rc` knows
it exists.

## What is in here

| file | what it is |
|---|---|
| `Dockerfile.snippet` | the lines to paste into your own Dockerfile |
| `boot-fragment.json` | the provider declaration, merged into the image's boot descriptor at build time |
| `tmux.conf` | the config the `start` command loads |

## Use it

1. Write your own Dockerfile somewhere the cage cannot reach — outside every
   directory your cage config mounts. `rc build` refuses a Dockerfile inside a
   cage mount, fail-closed, with no opt-out (ADR-031 D5(a)). A good home is
   `~/.config/rip-cage/images/`.

   ```dockerfile
   FROM ghcr.io/jsnyde0/rip-cage:latest
   # ...paste Dockerfile.snippet here...
   ```

   Copy `boot-fragment.json` and `tmux.conf` next to it — the `COPY` lines read
   them from the build context, which is that Dockerfile's own directory.

2. Build it:

   ```bash
   RC_IMAGE=my-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
   ```

3. Point your project's cage config at the image you just built — the `image:`
   key in `~/.config/rip-cage/projects/<cage>.yaml`:

   ```yaml
   image: my-cage:latest
   ```

4. Launch with tmux selected:

   ```bash
   RC_MULTIPLEXER=tmux rc up
   ```

   `RC_MULTIPLEXER` at launch is what selects the provider. (It replaced
   `session.multiplexer` in `.rip-cage.yaml`, which retired with the layered
   rip-cage config schema — ADR-031 D2.)

## The provider contract

A `multiplexers[]` entry declares shell commands, run with `sh -c` inside the
cage. `name`, `start` and `attach` are required; `exec`, `new_session` and
`teardown` are optional, and a caller that asks for a missing optional one falls
back rather than failing.

| field | when it runs |
|---|---|
| `start` | init, at every cage boot. Must be idempotent — a resume re-runs init. |
| `attach` | `rc up` on a running cage. Receives `--session NAME` as `$1`. |
| `new_session` | `rc up --new`. Omit it and `--new` falls back to `attach`. |

The entry above absorbs "duplicate session" on `start` and creates-then-attaches
in `attach`, so neither depends on which ran first.

## Swapping in a different multiplexer

Nothing here is tmux-specific except the commands. Change the `name` and the
three command strings and you have a different provider; `rc` needs no edit,
because it dispatches on whatever the descriptor declares. That is the seam
ADR-005 D12 protects.
