# Reference: the boot descriptor

What the descriptor is, how each array behaves at boot, and the failure each
one produces when it is written wrong.

**The schema is not here.** It lives in the file itself, in the `_readme` key of
[`cage/boot/boot.json`](../../../../cage/boot/boot.json) — JSON has no comment
syntax, so that key IS the header comment. Read it there: a copy in this skill
would drift from the artifact the moment either changed, which is the failure
mode that retired the skill this one replaced.

This page covers what the schema does not: behaviour and diagnosis.

---

## What it is

One JSON file at `/etc/rip-cage/boot.json` inside the cage, read by init on
every boot. Three optional top-level arrays — `daemons[]`, `multiplexers[]`,
`tools[]` — declare what starts, what `rc up` attaches to, and how agent
binaries launch.

It is **root-owned deliberately.** A cage whose agent can rewrite it decides
what starts in its own cage.

Extensions merge into it at BUILD time with `rc-boot-merge`. `rip-cage` never
edits it for you: appending your fragment is mechanical, deciding what to
declare is yours.

---

## `daemons[]` — something runs for the cage's life

init backgrounds `start`, records the pid, and uses `health` to answer "is it
up?".

**Two behaviours that decide whether your entry works:**

1. **The recorded pid is whatever `start` backgrounds.** A `start` that does
   setup before launching the server records the wrapper. Prefix the real
   server with `exec` so the recorded pid is the one that serves.
2. **Nothing in a cage reaps orphans.** msb's PID 1 leaves an exited daemon in
   state `Z` forever, and `kill -0` still succeeds against a zombie. So a pid
   check is not a liveness check. `health` is the authority — write one that
   asks the service (connect to the socket, run `SELECT 1`), not one that reads
   a pidfile.

**Diagnosing:** init runs `health` at boot and warns on failure — read the
`rc up` output for `[rip-cage] daemon` lines, then run the `health` command
yourself inside the cage. "Alive but not serving" is case 2 above; "dead but
the process is there" is case 1. (`rc doctor` covers mounts, auth, egress and
runnability — it does not probe declared daemons.)

---

## `multiplexers[]` — a session surface `rc up` attaches to

`start` brings the server up at boot. `attach` is what `rc up` runs to put you
in a session, and it receives the `--session` name as `$1` — handle the case
where `$1` is empty, and the case where the named session does not exist yet.
`new_session` backs `rc up --new`. `exec` and `teardown` are optional.

**The refusal worth knowing:** `rc up` reads `RC_MULTIPLEXER` and refuses,
before any msb call, when it names a multiplexer this image's descriptor does
not declare. A typo fails loudly at launch instead of silently dropping you
into a plain shell that is not the session you asked for.

`session.multiplexer: none` — no multiplexer started — is the default. A cage
does not need one.

**Diagnosing:** `rc up` lands you in a plain shell → either no multiplexer was
requested, or `attach` failed. Run the `attach` command by hand inside the cage
(`msb exec <cage> -- sh -c '<attach command>'`) and read the error.

---

## `tools[]` — how an agent binary launches, plus a boot hook

`launch` wraps how the tool STARTS. The base image bakes one generic wrapper per
agent binary; the entry supplies the command it runs.

`init` is a one-shot agent-context hook, run once at boot: no sudo, and
fail-WARN rather than fail-loud — a broken `init` hook degrades the cage's
context, it does not strand the boot.

`rc-boot-merge` **replaces** a `tools[]` entry of the same name (unlike daemons
and multiplexers, which append). That is what lets a recipe override how an
agent launches without ending up with two entries fighting.

---

## Failure catalogue

| What you see | Why | Where to look |
|---|---|---|
| build aborts inside `rc-boot-merge` | fragment missing, unparseable, or descriptor unwritable | `jq . <fragment>`; is the image `FROM` the rip-cage base? |
| init exits non-zero naming a field and an entry | a required field is missing or empty (fail-loud, ADR-001) | the `_readme`'s per-array required list |
| init restarts a daemon whose pid exists | recorded pid is the wrapper's, or the daemon is wedged | add `exec` in `start` |
| daemon looks alive, service refuses connections | `health` checks a pid; the pid is a zombie | make `health` ask the service |
| `rc up` refuses naming a multiplexer | image's descriptor does not declare it | rebuild with the fragment, `rc up --replace` |
| two entries for one agent binary | you appended into `tools[]` by hand | let `rc-boot-merge` do it — it replaces by name |

---

## Extending it

```dockerfile
COPY boot-fragment.json /tmp/f.json
RUN rc-boot-merge /tmp/f.json && rm -f /tmp/f.json
```

`rc-boot-merge`'s own header
([`cage/boot/rc-boot-merge`](../../../../cage/boot/rc-boot-merge)) states the
merge rule and why it is a mechanical step rather than auto-wiring: without it
every recipe would copy the same long `jq` expression, where one typo silently
drops a daemon. It names no tool and blesses none.

A one-line operator-facing pointer also lives in
[`docs/reference/in-cage-daemon.md`](../../../../docs/reference/in-cage-daemon.md).
