# dotpi-factory recipe — a cage that hosts a whole dotpi factory

Lets one cage run a complete [dotpi](https://github.com/jsnyde0/dotpi) factory
inside it: the grant registry, the mailbox, seats in herdr panes, and dispatch.
Everything the factory writes stays in the cage. The dotpi code itself stays on
the host and enters read-only.

Not floor, never on by default (ADR-005 D12 FIRM). `rc` names no tool and knows
nothing about this directory; it is a recipe you compose.

## What is in here

| file | what it is |
|---|---|
| `Dockerfile.snippet` | the lines to paste into your own Dockerfile: CLI symlinks, state dirs, the boot-fragment merge |
| `boot-fragment.json` | the boot-descriptor fragment; declares one daemon, the factory clock (see [The clock](#the-clock)) |

No dotpi code is copied into the image. `grants`, `seat`, `mail`, `dispatch`
and `pacemaker` in `/usr/local/bin` are symlinks into the dotpi checkout's
`scripts/` directory, which your cage config mounts read-only. A host-side edit
to dotpi reaches the cage live; no rebuild.

## Builds on

- [`examples/herdr/`](../herdr/) — dotpi's seat tooling drives herdr and needs
  herdr 0.8.2 or later. The herdr recipe pins a release that qualifies.
- [`examples/claude/`](../claude/) — the session wrapper a caged claude seat
  needs.

Paste their snippets first, then this one.

## Use it

1. **Write your Dockerfile** somewhere the cage cannot reach, outside every
   directory your cage config mounts (ADR-031 D5a). `~/.config/rip-cage/images/`
   is a good home.

   ```dockerfile
   FROM ghcr.io/jsnyde0/rip-cage:latest
   # ...paste examples/herdr/Dockerfile.snippet...
   # ...paste examples/claude/Dockerfile.snippet...
   # ...paste examples/dotpi-factory/Dockerfile.snippet...
   ```

   Copy each recipe's other files next to it. All three recipes ship a file
   named `boot-fragment.json`, so rename them apart and fix each `COPY` line to
   match.

2. **Set `DOTPI_DIR`** in the pasted snippet to where your dotpi checkout lands
   in the cage: your host checkout's path relative to your host home, placed
   under `/home/agent`. A checkout at `~/code/personal/dotpi` is
   `/home/agent/code/personal/dotpi`, the default. `rc build` takes no build
   arguments, so edit the `ARG` line itself.

   Why that path: your host `~/.claude/skills` entries link into
   `dotpi/agent/skills` by **relative** symlinks. rc projects those symlinks
   into the cage, where they resolve against the cage home, so the checkout
   must sit at the same path relative to it.

3. **Build it:**

   ```bash
   RC_IMAGE=my-factory-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
   ```

4. **Add the config lines below** to your project's cage config, and point its
   `image:` at the image you just built.

5. **Launch:**

   ```bash
   rc up
   ```

   A new cage picks herdr on its own when herdr is the only multiplexer the
   image declares. An existing cage keeps the multiplexer it was created with,
   so if yours ran without one, switch it once with
   `RC_MULTIPLEXER=herdr rc up --replace`; later launches keep herdr.

## Config lines

Add these to the `mounts:` list of `~/.config/rip-cage/projects/<cage>.yaml`,
beside the herdr recipe's durable state line. Replace `<DOTPI>` with the
absolute host path of your dotpi checkout, `<DOTPI_DIR>` with the value you set
in step 2, and `<CAGE-NAME>` with your cage's name.

```yaml
mounts:
  # dotpi code, read-only, at the path the CLI symlinks and skill symlinks expect.
  - "<DOTPI>/scripts:<DOTPI_DIR>/scripts:ro"
  - "<DOTPI>/agent:<DOTPI_DIR>/agent:ro"

  # Factory state, cage-local, on named volumes so it survives a recreate.
  - named: "dotpi-grants-<CAGE-NAME>"
    target: /home/agent/.grants
    create: ensure-exists
  - named: "dotpi-mail-<CAGE-NAME>"
    target: /home/agent/.dotpi-mail
    create: ensure-exists
  - named: "dotpi-pacemaker-<CAGE-NAME>"
    target: /home/agent/.pacemaker
    create: ensure-exists
  - named: "dotpi-timer-<CAGE-NAME>"
    target: /home/agent/.timer
    create: ensure-exists
  - named: "dotpi-home-<CAGE-NAME>"
    target: /home/agent/.dotpi
    create: ensure-exists
```

**Mount only `scripts/` and `agent/`, never the whole checkout.** A read-only
mount of the whole checkout fails the boot: rc's protected-paths rule covers
the checkout's `.env`, and that cover cannot bind inside a read-only mount
(rip-cage-dnwv).

**Why the named volumes.** The factory writes its grant registry to
`~/.grants`, its mail store to `~/.dotpi-mail`, pacemaker state to
`~/.pacemaker`, the clock's timer state and pidfile to `~/.timer`, and seat
briefs to `~/.dotpi`. Without these lines they live on
the cage's ephemeral overlay, and `rc up --replace` wipes them. That is the
command you run after every egress fix, so the factory would lose its registry
each time you widen the allowlist. Named volumes survive it. They also keep
the cage's factory apart from yours: the host registry and mailbox never see a
caged grant or letter.

`rc destroy` does not remove these volumes. When you retire the cage, list them
with `msb volume list` and remove each with `msb volume remove <name>`.

The dotpi CLIs are Python standard library under `uv run`; they need no egress
of their own.

## Reaching in from the host

Everything below runs on the host.

- **Close stdin on every `msb exec`.** A host-side `msb exec` with an open stdin
  waits for input that never comes. End each call with `< /dev/null`:

  ```bash
  msb exec <cage> -- bash -lc '<command>' < /dev/null
  ```

- **Export herdr's socket path in the guest command.** `seat` and anything else
  that talks to herdr find the server through `HERDR_SOCKET_PATH`. The herdr
  recipe sets it only inside its own start hook, so a reach-in shell does not
  have it. Take the path from [`examples/herdr/README.md`](../herdr/README.md#herdr-cli-control-surface):

  ```bash
  msb exec <cage> -- bash -lc 'export HERDR_SOCKET_PATH=/tmp/rip-cage-herdr.sock; seat ls' < /dev/null
  ```

  A `herdr --session NAME` server listens on a session-scoped socket instead;
  see [`examples/dotpi-3bi/README.md`](../dotpi-3bi/README.md) gotcha 1.

Panes herdr starts inside the cage inherit the variable from the server, so
seats working inside the cage need nothing extra.

## The clock

The boot fragment declares one daemon: `pacemaker serve --every 60`, the
factory's clock, ticking once a minute. Every boot starts it, so a caged seat
on the clock gets its pulses without anyone reaching in. A cage has no
launchd or systemd, so the pacemaker runs on its supervised adapter;
`pacemaker serve --help` says what that means.

**The daemon entry sets `restart: always`, so init restarts the clock.** serve
stops on a TERM, on `pacemaker disarm`, when its state file is deleted, and at
its lease bound. Each time, init starts it again 5 seconds later and writes a
`WARNING: daemon 'dotpi-pacemaker' exited (code N); restarting` line to
`/tmp/rip-cage-daemon-dotpi-pacemaker.log`.

- **To pause the clock**, run `pacemaker disarm` in the cage. That pause lasts
  only until the respawn, about 5 seconds.
- **To keep the clock off until the next boot**, stop its supervisor. That
  stops serve with it:

  ```bash
  msb exec <cage> -- sh -c 'kill "$(cat /tmp/rip-cage-daemon-dotpi-pacemaker.supervisor.pid)"' < /dev/null
  ```

  The next boot (`rc up` on a stopped cage, or `rc up --replace`) starts the
  clock again.
- **To keep the clock off for good**, remove the daemon from your copy of
  `boot-fragment.json` and rebuild.
- **To see whether it is running**, reach in and read the arm:

  ```bash
  msb exec <cage> -- bash -lc 'export HERDR_SOCKET_PATH=/tmp/rip-cage-herdr.sock; pacemaker status' < /dev/null
  ```

  Without the export, `status` reports a `registry_error` of its own; that is
  your shell missing herdr's socket and says nothing about the clock.
  `arm.armed` is `true` while serve runs; `false` means the clock is off.
  `last_tick.error` set means a tick ran and failed, so a recent tick time on
  its own does not prove the clock works.

**The clock needs herdr's socket.** Every tick reads the seat roster through
herdr. The daemon finds herdr's socket by reading `HERDR_SOCKET_PATH` out of
the cage's composed boot descriptor, `/etc/rip-cage/boot.json`, when it starts;
it never names another recipe's path. With no multiplexer setting that
variable, it logs a warning to `/tmp/rip-cage-daemon-dotpi-pacemaker.log` and
runs anyway, and every tick records `server_not_running`.

The first tick after boot may also record `server_not_running`, because the
clock can start before herdr's server is listening. Any tick after herdr is up
must be clean. If it is not, check that log.

## Troubleshooting

- **`grants: command not found`** or a symlink to a missing file: the mount
  path and `DOTPI_DIR` disagree. `ls -l /usr/local/bin/grants` in the cage
  shows the path the image expects; the config's `scripts` mount must land there.
- **The boot fails with a mount error**: a mount source traverses a host-side
  symlink, which msb does not follow. On macOS write `/private/tmp/...`, never
  `/tmp/...`.
- **`seat ls` cannot reach herdr**: `HERDR_SOCKET_PATH` is not exported in that
  shell, or herdr's start hook has not run. Check
  `/tmp/rip-cage-mux-herdr.log` in the cage.
- **The registry is empty after `rc up --replace`**: the named-volume lines are
  missing from the config.
