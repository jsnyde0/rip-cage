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

## Version

The snippet pins **herdr v0.9.0**, sha256-checked per architecture. dotpi's seat
tooling needs herdr 0.8.2 or later; 0.9.0 is the release rip-cage has proven in
a cage (2026-09-29): socket-API drive, the boot hook's integration install, and
attach. One change from 0.7.x you can see: a headless pane now starts 120x40
instead of wrapping long lines at a narrow default.

To bump: take the new `herdr-linux-aarch64` and `herdr-linux-x86_64` digests
from the GitHub release, replace the version (URL and `Pinned release` comment)
and both checksums in `Dockerfile.snippet`, and rebuild. Then run, against your
image:

- `tests/test-herdr-roster-resume-recipe.sh` — host-only; reads the pin from
  the snippet and checks the digests' shape.
- `RC_TEST_IMAGE=<your image> tests/test-msb-factory-socket-api-drive.sh` —
  asserts the in-cage `herdr --version` equals the snippet's pin.
- `tests/test-msb-lifecycle-cockpit-reregistration.sh` — boots the start hook
  on your image: integration install, attach, re-registration on resume.

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

   Plain `rc up` also picks herdr when it is the only multiplexer the image
   declares; name it when the image declares more than one.

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

**Skip the first-run modal: put `onboarding = false` in that directory's
`config.toml`** (`<ABSOLUTE_HOST_DIR>/herdr-<cage-name>/config.toml`, host-side).
Without it, a fresh cage's `rc up` attach opens on herdr's onboarding screen
until someone presses Enter once. The modal is decided when the in-cage herdr
server starts, so the line is expected to take effect at the cage's next boot
(`rc up` on a stopped cage, or `rc up --replace`), not on a cage already showing
it (inferred from the modal being server-side; not measured in a cage). This is
your composition: rc and init never write herdr's config.

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

## Three things worth knowing before you change this

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
until then, it adds a bounded ~15s to boot whenever herdr is the multiplexer.

**The start hook exports `SHELL` from passwd before `herdr server`.** herdr
picks a new pane's shell from `terminal.default_shell`, then `$SHELL`, then
`/bin/sh`. Init runs the hook with no `SHELL` set, so without the export every
pane would open `/bin/sh` instead of the agent's login shell (zsh plus the base
zshrc). The hook reads the running user's login shell with `getent passwd` —
the base image owns that value, the recipe names no shell. Baking
`terminal.default_shell` into an image-side `~/.config/herdr/config.toml`
would not work: the `~/.config/herdr` host mount above, required for roster
persistence, masks whatever the image put at that path (rip-cage-f0rl).

## herdr CLI control surface

Inside the cage (or via `msb exec <cage> -- ... </dev/null`, with
`HERDR_SOCKET_PATH=/tmp/rip-cage-herdr.sock` exported in the guest command):

```bash
herdr workspace create --label <label> --cwd /workspace   # new workspace; prints its pane id
herdr pane run <pane-id> "<command>"                      # run a command in a pane
herdr pane read <pane-id> --source visible                # read back what the pane shows
herdr agent start <name> --kind pi --pane <pane-id> -- ...  # start an agent under supervision
herdr agent list                                          # agents + semantic status
```

`herdr --help` inside the cage is the full surface; the lines above are the ones
a driving agent reaches for first.

`start`'s integration-install loop runs `herdr integration install <agent>`
for whichever of `pi`/`claude` are present on PATH, so `herdr agent list`
reports real semantic status (`working`/`blocked`/`idle`) via the integration
path rather than the screen-detection fallback. herdr's pi install needs
`${PI_CODING_AGENT_DIR:-~/.pi/agent}/extensions` to exist. examples/pi's
boot-fragment init hook creates it (rip-cage-p35a.3); this loop also creates it,
so the herdr recipe works standalone, and prints a `[rip-cage] WARNING` if it
cannot.

`examples/herdr-pi/boot-fragment.json` carries a byte-identical copy of this
multiplexer entry, and a cage composed with herdr-pi boots that copy. Edit both;
`tests/test-herdr-roster-resume-recipe.sh` checks they match.

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
