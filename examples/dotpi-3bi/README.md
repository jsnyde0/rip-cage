# dotpi-3bi — factory socket-API drive recipe

This recipe documents how the dotpi-3bi self-driving bead factory (a dotpi-side consumer;
see `docs/decisions/ADR-006-multi-agent-architecture.md` and
`docs/decisions/ADR-027-agent-substrate-projection.md` §"in-cage drover dogfood") drives a
rip-cage cage's herdr multiplexer via the **socket-API pane run/read path**, not interactive
attach. It composes on top of [`examples/herdr/`](../herdr/) — no new manifest archetype, no
rc source edits (ADR-005 D12). Per the epic (`rip-cage-tsf2`), dotpi-3bi is **one cage
config/recipe here, not the product**; dogfooding the full drover orchestrator is the next
step after migration. This recipe captures the drive mechanics validated in
`tests/test-msb-factory-socket-api-drive.sh` (bead `rip-cage-lczu`, S14) so the pattern is
reproducible without re-discovering the two headless-herdr gotchas from scratch.

## Why not `rc attach` / interactive attach?

`rc attach` (→ `msb exec -t`) is the human-facing path — S6 (`rip-cage-rj68`) proves
cockpit/herdr re-registration and interactive attach across resume. The factory is a
different consumer: a host-side orchestrator (dotpi-3bi's *drover*) spawns agent panes and
drives them programmatically — run a command, read back its output, loop — with no human at
a terminal. herdr's socket API is built for exactly this (`herdr pane run` / `herdr pane
read`), and it's what this recipe composes.

## Compose steps

1. Add the `herdr-bin` (TOOL) + `herdr` (MULTIPLEXER) entries from
   [`examples/herdr/manifest-fragment.yaml`](../herdr/manifest-fragment.yaml) to your
   `tools.yaml`, per [`compose-rc-with-herdr.md`](../compose-rc-with-herdr.md).
2. `rc build` — bakes the herdr binary + start/attach hooks into the image.
3. Set `session.multiplexer: herdr` in the workspace `.rip-cage.yaml`, and `rc up` as usual —
   the baked `start` hook launches a herdr server.
4. For the **factory drive path specifically** (as opposed to `rc attach`), the orchestrator
   drives herdr with an explicit `--session NAME` rather than the default session, and drives
   it entirely over `msb exec` (never `msb exec -t` for the drive calls themselves — see
   gotcha 2 below for the one place a sized `-t` client is still needed).

## Gotcha 1 — the session-scoped socket path

A `herdr --session NAME ...` server's control socket lives at
`~/.config/herdr/sessions/NAME/herdr.sock`, **not** the default `~/.config/herdr/herdr.sock`
a plain `herdr status` checks. Every factory call must target the session explicitly:

```bash
msb exec <cage> -- herdr --session dotpi3bi status server --json
msb exec <cage> -- herdr --session dotpi3bi pane list
```

A bare `herdr status` (no `--session`) against a session-scoped server falsely reports "not
running" — it's checking the wrong socket, not a real liveness failure.

## Gotcha 2 — headless pane width defaults narrow

A freshly created pane (`herdr workspace create` over the socket API) starts at whatever
narrow width the headless server defaults to until a client has sized it (observed 54 cols in
this recipe's validation run, ~4 cols in the original spike on an older herdr build — the
exact number drifts by version, the *shape* of the gotcha does not). `pane read --source
visible` hard-wraps at that width, corrupting anything wider than a few dozen characters.

**Fix: attach one explicitly-sized client and hold it attached.** `herdr pane resize` is
directional-only (relative to an existing layout, not an absolute size) — there is no
socket-API call to set absolute pane dimensions. The only way to size a headless pane is a
real sized terminal attach, held open for as long as the pane needs to stay sized (dimensions
revert to the narrow default once the sizing client detaches — verified live, not assumed).
`msb exec -t` propagates real PTY dimensions end-to-end (host PTY size → guest `stty size` →
herdr's attached-client sizing), including live resize. Drive it from a host-side PTY of a
known size (Python `pty.openpty()` + `TIOCSWINSZ`, since a live interactive attach blocks a
non-interactive orchestrator process):

```python
import fcntl, os, pty, struct, subprocess, termios
master_fd, slave_fd = pty.openpty()
fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
proc = subprocess.Popen(
    ["msb", "exec", "-t", "<cage>", "--", "herdr", "--session", "dotpi3bi"],
    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, start_new_session=True,
)
os.close(slave_fd)
# hold `proc` running for the cage's operating lifetime (or at minimum for
# as long as sized pane reads are needed) -- terminating it reverts the pane
# to the narrow headless default.
```

At 40×120 this sizes the pane to 94×39 usable (120 total − 26-col herdr sidebar chrome = 94;
39 rows + 1 status row = 40). `herdr pane layout --pane <id>` reporting those numbers is a
useful secondary signal, but the load-bearing proof in
`tests/test-msb-factory-socket-api-drive.sh` is a **content differential**: the identical
wide token is run through `pane run`/`pane read` twice — once before the sized client
attaches (where it comes back hard-wrapped across multiple lines) and once after (where the
exact same token comes back as a single contiguous unwrapped line). A dimension self-report
alone doesn't prove `pane read` output actually stopped wrapping; re-running the same content
across the resize and diffing the two reads does.

## The drive loop itself

Once sized, the factory loop is plain socket-API calls, no `-t`, no interactive terminal:

```bash
msb exec <cage> -- herdr --session dotpi3bi pane run w1:p1 '<command>'
msb exec <cage> -- herdr --session dotpi3bi pane read w1:p1 --source visible
```

`pane run` submits and executes; `pane read` returns the real, currently-rendered pane
content — assert on the **actual output value**, not merely that the calls returned exit 0
(exit-0/connect-success is not proof of anything real per ADR-029's fake-accept warning; the
same discipline applies here even though this path never touches TCP — see the design finding
below).

## Design finding: this path is host→guest only

The entire factory socket-API drive path is `msb exec`/`msb exec -t` from the **host** into
the guest CLI, and herdr's control surface is a guest-local **UNIX domain socket**, never TCP.
No leg of this recipe requires guest→host TCP, so msb's fake-accept-on-denied-TCP property
(ADR-029, `msb-netstack-fake-accepts-tcp-connect-not-egress`) is not implicated here. A
*future* factory leg that needed the cage to reach a host-side service directly — e.g. the
parked host-service beads seam, ADR-029 D7 — would be the place that finding could fire, not
this recipe.

## Validated by

`tests/test-msb-factory-socket-api-drive.sh` (bead `rip-cage-lczu`) exercises both gotchas
live against a real msb cage: session-scoped socket presence (gotcha 1); for gotcha 2, the
same wide token run through `pane run`/`pane read` before sizing (wraps) and again after
sizing (reads back as one unwrapped line) — a genuine wrapped→unwrapped content differential,
not just a `pane layout` dimension self-report; and, separately, a real computed value
(arithmetic performed in-guest by the pane's own shell) round-tripped through `pane
run`/`pane read` (not a static echo, not attach-liveness).
