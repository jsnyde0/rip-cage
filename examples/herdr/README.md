# herdr multiplexer recipe

Gives a cage a headless agent-supervisor: a unix-socket control surface plus a
TUI attach client, so multiple coding-agent panes can run under one
supervisor and be checked on (or driven) without a human holding a terminal
open the whole time.

Not floor, never on by default (ADR-005 D12 FIRM). rip-cage's own code names no
multiplexer; this directory is a recipe you compose, and nothing in `rc` knows
it exists.

## What is in here

| file | what it is |
|---|---|
| `Dockerfile.snippet` | the lines to paste into your own Dockerfile |
| `boot-fragment.json` | the provider declaration, merged into the image's boot descriptor at build time |
| `scripted-attach.py` | a headless PTY client that triggers herdr's native roster restore (see below) |

## Use it

1. Write your own Dockerfile somewhere the cage cannot reach — outside every
   directory your cage config mounts (fail-closed, no opt-out — ADR-031 D5(a)).
   `~/.config/rip-cage/images/` is a good home.

   ```dockerfile
   FROM ghcr.io/jsnyde0/rip-cage:latest
   # ...paste Dockerfile.snippet here...
   ```

   Copy `boot-fragment.json` and `scripted-attach.py` next to it.

2. Build it:

   ```bash
   RC_IMAGE=my-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
   ```

3. Point your project's cage config at the image you just built, and add the
   durable state mount below to the same config's `mounts:` list.

4. Launch with herdr selected:

   ```bash
   RC_MULTIPLEXER=herdr rc up
   ```

## The durable state mount (required for restart survival)

herdr persists its roster continuously to `~/.config/herdr/session.json` (plus
`session-history.json` and server logs) at fixed paths — not relocatable by any
variable herdr reads. Left on the cage's own ephemeral overlay, that state dies
on every `rc up --replace` cold-recreate and every crash-restart, so the roster
can never survive a restart. Add a line to your project's cage config
(`~/.config/rip-cage/projects/<cage>.yaml`) `mounts:` list to put it on a real
host directory instead:

```yaml
mounts:
  - "<ABSOLUTE_HOST_DIR>/herdr-<cage-name>:/home/agent/.config/herdr"
```

No `:ro` suffix — herdr writes this continuously. **Give every herdr-multiplexed
cage a distinct host directory.** Two cages pointed at the same directory will
read and write the same `session.json` and corrupt each other's roster. A real
host path is also a bonus: it gives host-side visibility into `session.json`
for diagnostics without exec-ing into the cage.

## The provider contract

A `multiplexers[]` entry declares shell commands, run with `sh -c` inside the
cage. `name`, `start` and `attach` are required; `exec`, `new_session` and
`teardown` are optional, and a caller that asks for a missing optional one
falls back rather than failing (herdr declares neither here — `rc up --new`
falls back to `attach`).

| field | when it runs |
|---|---|
| `start` | init, at every cage boot. Must be idempotent — a resume re-runs init. |
| `attach` | `rc up` on a running cage. Receives `--session NAME` as `$1`; herdr's hook ignores it (its sessions are addressed by `--session` on the `herdr` CLI itself, not by this positional arg). |

## Two things worth knowing before you change this

**The socket path must be exported before the server backgrounds, in the
parent shell, not inside the backgrounded job.** `start`'s command is one
`&`-backgrounded chain — the server runs backgrounded so the foreground
continuation can go on to install agent integrations and trigger the restore
step below. A background job forks a subshell; a socket-path export made
*inside* that subshell would never reach the foreground continuation, which
also needs to dial the same socket. Setting it before the backgrounded part
keeps it in the parent shell, so both halves inherit the identical value
(verified live against the `sh` interpreter init invokes this hook with). The
relocated path lives under `/tmp` — the cage's ephemeral overlay, recreated
fresh every boot, which is exactly right for a live socket (as opposed to the
durable `session.json` above, which must NOT live there).

**herdr's native roster restore does not fire on server start alone.** A
9-minute headless observation window with 9 eligible panes produced zero
re-execs; restore fires within about 10 seconds of *any* client attach —
human or scripted. `scripted-attach.py` is the interim mechanism: it forks a
headless PTY client (`pty.fork` + `TIOCSWINSZ`, no human, no real terminal),
holds it attached for 15 seconds while draining its output so it never blocks
on a full buffer, then detaches it. Restored pane processes survive that
detach — only the *scripted client* dies. Harmless on a genuinely fresh cage
with no prior roster (it just attaches the default pane's normal shell, waits,
detaches). This retires once herdr ships a headless restore-on-start trigger;
until then, it adds a bounded ~15s to boot whenever `RC_MULTIPLEXER=herdr`.

## herdr CLI control surface

Inside the cage (or via `msb exec`):

```bash
herdr agent start <name> -- pi ...   # start an agent under herdr supervision
herdr agent list                      # list agents + semantic status
herdr pane <name>                     # open a pane
herdr workspace <name>                # switch workspace
```

`start`'s integration-install loop runs `herdr integration install <agent>`
for whichever of `pi`/`claude` are present on PATH, so `herdr agent list`
reports real semantic status (`working`/`blocked`/`idle`) via the integration
path rather than the screen-detection fallback.

## Troubleshooting

- **herdr server not starting**: check `/tmp/rip-cage-mux-herdr.log` inside the cage.
- **Integration install failed**: check `/tmp/rip-cage-mux-herdr.log` for the
  per-agent warning; re-run `herdr integration install pi` (or `claude`) by hand.
- **Socket not found on attach**: the relocated socket only exists once `start`
  has run — confirm the cage actually booted past init before attaching.

## Swapping in a different multiplexer

Nothing here is herdr-specific except the commands. [`examples/tmux/`](../tmux/)
is the smaller worked example of the same contract — change the `name` and the
command strings and you have a different provider; `rc` needs no edit, because
it dispatches on whatever the descriptor declares. That is the seam ADR-005
D12 protects.
