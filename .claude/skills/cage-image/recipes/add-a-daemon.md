# Recipe: make something START in the cage

Use this when the thing you are adding has to run, not just exist: a database,
a multiplexer, a guard, a control socket. Two artifacts instead of one — a
Dockerfile and a boot-descriptor fragment.

Everything in [`add-a-tool.md`](add-a-tool.md) still applies (where the
Dockerfile lives, `USER root` → `USER agent`, the build assertion). This adds
the declaration.

---

## 1. Decide which array you are declaring into

| Array | Use when | Required |
|---|---|---|
| `daemons[]` | a server runs for the cage's life | `name`, `start`, `health` |
| `multiplexers[]` | `rc up` should attach to a session surface | `name`, `start`, `attach` |
| `tools[]` | an agent binary needs a launch wrapper or a one-shot boot hook | `name` |

Read the schema in the descriptor itself —
[`cage/boot/boot.json`](../../../../cage/boot/boot.json), the `_readme` key.
It is the file, so it cannot be stale. Do not work from a copy.

---

## 2. Copy the closest existing fragment

These are maintained and known to boot:

- a daemon: [`examples/postgres-pgvector/boot-fragment.json`](../../../../examples/postgres-pgvector/boot-fragment.json)
- a multiplexer: [`examples/tmux/boot-fragment.json`](../../../../examples/tmux/boot-fragment.json)
- a supervisor with a control socket: [`examples/herdr/boot-fragment.json`](../../../../examples/herdr/boot-fragment.json)
- a guard: [`examples/dcg/boot-fragment.json`](../../../../examples/dcg/boot-fragment.json)

Start from whichever is closest in shape and change the names and commands.

---

## 3. Write `start` and `health` with the gotcha in mind

Every `start` / `health` / `attach` value is a shell command string, run with
`sh -c`. Multiplexer hooks receive the `--session` name as `$1`.

**The daemon gotcha, stated in the descriptor's own header:**

- init backgrounds `start` and records `$!`. A `start` that does setup work
  before launching the server records the WRAPPER's pid, not the daemon's.
  **Prefix the real server with `exec`.**
- Nothing inside a cage reaps orphans — msb's PID 1 leaves an exited daemon as
  a zombie forever, where `kill -0` still succeeds. So **`health`, not the pid,
  is the liveness authority.** Write a `health` that actually asks the service
  whether it is serving (a socket connect, a `SELECT 1`), never one that checks
  a pid or a pidfile.

*Done when:* your `health` command returns non-zero against a stopped service.
Test that before you trust it.

---

## 4. Merge it at build time

```dockerfile
USER root
# ... install the thing, assert it ...
COPY boot-fragment.json /tmp/f.json
RUN rc-boot-merge /tmp/f.json && rm -f /tmp/f.json
USER agent
```

`rc-boot-merge` appends `daemons` and `multiplexers`, and replaces a `tools[]`
entry of the same name. It is fail-loud: a missing file, unparseable JSON, or an
unwritable descriptor aborts the build rather than producing a half-merged
image. Its header explains why this is a mechanical merge and not auto-wiring:
[`cage/boot/rc-boot-merge`](../../../../cage/boot/rc-boot-merge).

The descriptor is root-owned deliberately — a cage whose agent can edit it
decides what starts in its own cage.

---

## 5. Build, recreate, and check it is actually live

```bash
rc build --file ~/.config/rip-cage/images/Dockerfile
rc up --replace <project> 2>&1 | tee /tmp/up.out
grep '\[rip-cage\] daemon' /tmp/up.out
msb exec <cage> -- sh -c '<your health command>'
```

Init runs each declared daemon's `health` at boot and **warns** rather than
failing — a broken daemon degrades the cage, it does not strand the boot. So
the `rc up` output is where the verdict is, and running the `health` command
yourself is the independent check.

*Done when:* the health command returns 0 inside the running cage, or — for a
multiplexer — `rc up <project>` attaches to a session rather than dropping you
in a plain shell.

**A clean merge is not a working daemon.** The build can succeed, the fragment
can be valid JSON in the right array, and the service can still never come up.
Check the running cage, not the image.

---

## Using a multiplexer you declared

`rc up` reads `RC_MULTIPLEXER` and **refuses before any msb call** if it names
a multiplexer this image's descriptor does not declare. That refusal is the
feature: it catches the typo at launch instead of dropping you into a shell that
silently is not the session you asked for.

*Done when:* `RC_MULTIPLEXER=<name> rc up <project>` attaches, and the same
command with a misspelled name refuses loudly.

---

## If it did not work

| Symptom | Cause | Fix |
|---|---|---|
| build aborts in `rc-boot-merge` | fragment missing or not valid JSON | `jq . boot-fragment.json` before the build |
| init exits non-zero naming a field | a required field is absent or empty | add it — the descriptor's `_readme` lists them per array |
| daemon reported dead, process visible | the recorded pid is the wrapper's | `exec` the real server in `start` |
| daemon reported alive, service dead | `health` checks a pid, and the pid is a zombie | make `health` ask the service |
| `rc up` refuses naming the multiplexer | the image's descriptor does not declare it | rebuild with the fragment, then `rc up --replace` |
| the cage boots as root | the Dockerfile ends on `USER root` | end on `USER agent` |
