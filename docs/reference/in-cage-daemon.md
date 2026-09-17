# Running an In-Cage Daemon

How to give a cage a long-running localhost service that in-cage agents talk to —
a database, a mail daemon, anything with a resident process.

**No daemon is blessed or seeded by default** (ADR-005 D12 FIRM). rip-cage ships
none; every daemon named here is illustration. The worked recipe you can build
today is [`examples/postgres-pgvector/`](../../examples/postgres-pgvector/).

---

## The contract

Three lifecycle rules, straight from ADR-005:

1. **Install at build, start at init** (D1 FIRM + D7). The binary is baked into
   the image by your Dockerfile. Its *process* is launched by
   `init-rip-cage.sh` at cage start. There is no runtime download path.
2. **Fail-warn, never brick** (D10). A daemon that fails its health check prints
   `WARNING: daemon '<name>' health check FAILED … cage continues without it` —
   and the cage runs. Only safety interceptors fail closed; bricking a cage over
   a user daemon would defeat agent autonomy.
3. **In-cage only** (D8 FIRM). The daemon binds localhost inside one cage's
   network namespace. No cross-cage volume, network or coordination — two cages
   each run their own instance on the same port. Init is idempotent: a re-run, or
   a second in-cage agent, spawns no second binder.

## The boot descriptor

**`/etc/rip-cage/boot.json`** — one declarative JSON file inside the image, read
by init at boot (ADR-031 D4). Three optional top-level arrays; a required field
missing makes init exit non-zero naming the field and the entry:
`daemons[]` (`name`, `start`, `health` required, `state_dir` optional),
`multiplexers[]` (`name`, `start`, `attach` required, `exec`/`new_session`/`teardown` optional),
`tools[]` (`name` required, `launch`/`init` optional). Every value is a shell
command string run with `sh -c`. The file's own `_readme` key is the schema's
other home; there is no third copy to drift.

A daemon entry, in the fragment your Dockerfile merges in:

```json
{
  "daemons": [
    {
      "name": "my-daemon",
      "start": "STATE_ROOT=/var/lib/rip-cage-daemon/my-daemon exec my-daemon serve --no-tui",
      "health": "curl -sf http://127.0.0.1:8765/healthz",
      "state_dir": "/var/lib/rip-cage-daemon/my-daemon"
    }
  ]
}
```

- **`start`** — the launch command, run in the background at init. Make it
  headless (`--no-tui` or equivalent); stdout is not a TTY. **Prefix the real
  server with `exec`** — see below for what that buys.
- **`health`** — a cheap probe. Init runs it with `timeout 5`, up to 3 attempts
  a second apart, so a wedged daemon cannot hang cage start. This is the
  **liveness authority**, not the pid; see the zombie note below.
- **`state_dir`** — absolute path for the daemon's state. Pre-create it in your
  Dockerfile (root `mkdir -p` then `chown agent:agent`) so init, running as the
  agent, needs no write on the parent. **State is cage-lifetime** — wiped on
  `rc destroy`. For durable state, point `state_dir` under `/workspace`.

Getting the fragment into the image is two lines in your Dockerfile:

```dockerfile
USER root
COPY boot-fragment.json /tmp/f.json
RUN rc-boot-merge /tmp/f.json && rm -f /tmp/f.json
USER agent
```

`rc-boot-merge` appends your daemons and multiplexers and replaces a `tools[]`
entry of the same name. **End on `USER agent`** — an extension that ends on root
boots a root shell with every mount stranded, silently (measured, msb 0.6.18).

## The `exec` prefix on `start`

```json
"start": "exec /usr/local/lib/rip-cage/my-daemon-start.sh"
"start": "exec my-daemon serve --no-tui"
"start": "STATE_ROOT=/var/lib/… exec my-daemon serve --no-tui"
```

**Env assignments go BEFORE `exec`, never after.** `exec VAR=1 cmd` does not set
`VAR` and run `cmd` — `exec` takes `VAR=1` as the program name, so the daemon
never launches and the process is gone immediately (measured). `VAR=1 exec cmd`
is the working form.

**What the prefix buys: pid identity.** Init launches the daemon in the
background and records `$!` as its pid. Backgrounding always forks a wrapper
shell that bash does not optimise away, so **without `exec` the recorded pid is
that wrapper, not the daemon** — true for *every* start shape: a script path, a
plain simple command, an env-prefixed command, an absolute binary path. There is
no exempt shape. With `exec`, the wrapper replaces itself with the daemon and the
recorded pid is the daemon's own.

Measured on the cage's runtime (Debian trixie, bash 5.2.37) against a real
Postgres 17 cluster: without `exec`, recorded pid `20` (`comm=bash`) while
`postmaster.pid` held `22`; with `exec`, recorded pid `36` (`comm=postgres`)
matched `postmaster.pid` exactly. Re-measured 2026-09-16 on the descriptor:
recorded pid `310` == `postmaster.pid` `310`.

**What `exec` does NOT fix: a dead daemon can still look alive.** Inside a cage
nothing reaps orphans — msb's PID 1 (`init.krun`) leaves them as zombies
indefinitely, and `kill -0` on a zombie **succeeds**. Measured in a live cage:
SIGKILL the postmaster and the recorded pid stays in state `Z` while
`pg_isready` reports the database down. Both start shapes behave identically
here, so `exec` is no defence.

That is why init treats the pid as a **cheap pre-filter only** and asks the
entry's own `health` command before deciding a daemon is already running
(`rip-cage-893l`). A recorded pid that exists but fails its health check is
treated as dead: init terminates it and restarts, rather than skipping.

The blast radius is bounded by where the pid file lives:
`/tmp/rip-cage-daemon-<name>.pid` is wiped by the fresh kernel boot every msb
resume performs, so a stale skip never survives a resume.

Nothing enforces the `exec` prefix, deliberately. The false-healthy case above is
indifferent to the start shape, so a syntax rule would gate the wrong thing while
looking like a fix — and it would have to encode the `VAR=1 exec cmd` ordering
correctly, which is easy to get wrong.

## How agents reach the daemon

| Agent class | Reach mechanism |
|---|---|
| MCP-capable (Claude Code) | an `mcpServers` entry in the image's `settings.json`, written by your Dockerfile |
| Bash-only (pi — no MCP bridge) | the daemon's **own CLI over the bash tool** |

A daemon that wants to serve bash-only agents must ship a CLI; an MCP endpoint
alone is not enough (ADR-019 D9).

## A daemon, or something simpler?

The lifecycle decides it, not the tool's size:

| Your tool… | What it is |
|---|---|
| A binary the agent invokes per call; no resident process | just a `RUN` line in your Dockerfile — nothing to declare |
| Needs a one-shot setup at cage boot, then just gets invoked | a `tools[]` entry with an `init` command (one-shot, agent context, no sudo, fail-warn) |
| Runs continuously and answers requests over localhost | a `daemons[]` entry (this doc) |
| A terminal session the agent's session runs *inside* | a `multiplexers[]` entry — see [`examples/tmux/`](../../examples/tmux/) |

The common confusion is row two versus row three: an `init` hook is a **one-shot
command that exits**; a daemon `start` is a **process that stays up and answers a
health probe**. A "daemon" that exits after its setup earns you a failed health
check and a spurious warning at every cage start.

Also worth ruling out: a process meant to serve *multiple* cages or the host
fits nothing here. The cage boundary does not reach across cages (D8 FIRM) —
that is a deliberate structural answer, not a missing feature.

---

## See also

- [`examples/postgres-pgvector/`](../../examples/postgres-pgvector/) — a real daemon recipe, built and booted
- [`tests/test-boot-descriptor.sh`](../../tests/test-boot-descriptor.sh) — the descriptor contract, asserted in a live cage
- [docs/reference/README.md](README.md) — the reference index and the three things you compose
- [`cage-image`](../../.claude/skills/cage-image/SKILL.md) — the skill that writes the Dockerfile and the boot fragment
- [ADR-005 D7/D8/D10/D12](../decisions/ADR-005-ecosystem-tools.md), [ADR-031 D4](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md), [ADR-019 D9](../decisions/ADR-019-pi-coding-agent-support.md)
