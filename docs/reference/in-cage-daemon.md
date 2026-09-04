# Running an In-Cage Daemon (IN-CAGE-DAEMON archetype)

This is the **generic archetype walkthrough** for the IN-CAGE-DAEMON manifest entry ([ADR-005 D7](../decisions/ADR-005-ecosystem-tools.md)): a long-running localhost service that in-cage agents talk to. The concrete worked instance is [agent-mail-daemon.md](agent-mail-daemon.md) (`mcp-agent-mail` — pinned source, CLI surface, MCP fragment gotchas); read this doc for the archetype contract and manifest shape, that one for a real tool wired end to end.

**ADR-005 D12 (FIRM):** no daemon is blessed or seeded by default — agent_mail itself ships as docs + test fixtures, never in the default manifest (ADR-005 D7 clarification). Any daemon named here is illustration only.

---

## The archetype contract

Three lifecycle rules define the archetype; they come straight from ADR-005:

1. **Install at build, start at init** (D1 FIRM + D7). The daemon's binary is baked into the image by its `install_cmd` at `rc build`. Its *process* is launched by `init-rip-cage.sh` at cage start — the same lifecycle the cage already uses for the egress proxy and ssh-agent-filter. "Install = build-time, start = init-time"; there is no runtime download path.
2. **Fail-warn, never brick** (D10). A daemon that fails its health check produces a `WARNING: daemon '<name>' health check FAILED … cage continues without it` line — and the cage runs. Only *safety interceptors* fail-closed; a user daemon is not load-bearing, and bricking the cage over it would defeat agent autonomy.
3. **In-cage only** (D8 FIRM). The daemon binds localhost inside one cage's network namespace. No cross-cage volume, network, or coordination — two cages each run their own independent instance on the same port. Init is idempotent: a re-run (or a second in-cage agent) spawns no second binder.

## Manifest shape

```yaml
# ~/.config/rip-cage/tools.yaml — shape reference (see agent-mail-daemon.md for a real entry)
version: 1
tools:
  - name: my-daemon
    archetype: IN-CAGE-DAEMON
    version_pin: "1.2.3"
    install_cmd: "curl -fsSL https://…/my-daemon.tar.gz | tar -xz -C /usr/local/bin my-daemon"
    start: "STATE_ROOT=/var/lib/rip-cage-daemon/my-daemon my-daemon serve --no-tui"
    health: "curl -sf http://127.0.0.1:8765/healthz"
    state_dir: "/var/lib/rip-cage-daemon/my-daemon"
    egress: []
    mcp_fragment:          # optional — only for daemons exposing an MCP endpoint
      type: http
      url: "http://127.0.0.1:8765/mcp/"
```

Required fields (enforced fail-closed by `_manifest_validate` — see [manifest-validator.md](manifest-validator.md)):

- **`start`** — the launch command. It is run via `eval` in the background at init, so an env-assignment prefix (`STATE_ROOT=… cmd`) works. Make it headless (`--no-tui` or equivalent); stdout is not a TTY. **Prefix it with `exec`** — see [the exec prefix](#the-exec-prefix-on-start) below for what that buys and the one ordering gotcha.
- **`health`** — a cheap probe command (typically `curl -sf` against a health endpoint). Init runs it with `timeout 5`, up to 3 attempts 1s apart; a wedged daemon cannot hang cage start.
- **`state_dir`** — absolute path for the daemon's state. Validated as a strict path token: must start with `/`, no whitespace, no shell metacharacters. Pre-created at image build (root `mkdir -p` + `chown agent:agent`) so init, running as the agent user, needs no write access to the parent; init `mkdir -p`s it again idempotently. **State is cage-lifetime** — wiped on `rc destroy` (ADR-019 D1 container-local pattern). If you need durable state, point `state_dir` under `/workspace`.

Optional fields:

- **`mcp_fragment`** — a **nested YAML mapping** (never a quoted JSON string — see the gotcha in [agent-mail-daemon.md](agent-mail-daemon.md)) merged into `/etc/rip-cage/settings.json` `mcpServers` at build time, so MCP-capable agents (Claude Code) auto-discover the daemon.
- **`egress`** — hosts the daemon reaches at runtime; unioned into the cage allowlist and IOC-checked like any entry's. A localhost-only daemon declares `egress: []`.
- **`required: true` + `assert_loaded: "<check>"`** — opt the daemon into the baked presence assertion (ADR-005 D13). Non-TOOL archetypes have no declarable binary path, so `required: true` on a daemon **must** carry an explicit `assert_loaded` or the validator rejects it.

## The exec prefix on `start`

Write `start` with an `exec` prefix. The recommended forms:

```yaml
start: "exec /usr/local/lib/rip-cage/my-daemon-start.sh"   # script path
start: "exec my-daemon serve --no-tui"                     # simple command
start: "STATE_ROOT=/var/lib/… exec my-daemon serve --no-tui"  # env-prefixed
```

**Env assignments go BEFORE `exec`, never after.** `exec VAR=1 cmd` does not set `VAR` and run `cmd` — `exec` takes `VAR=1` as the program name, so the daemon never launches and the process is gone immediately (measured). `VAR=1 exec cmd` is the working form.

**What the prefix buys.** Init launches the daemon with `eval "$start" >log 2>&1 &` and records `$!` as the daemon's PID. Backgrounding an `eval` always forks a wrapper shell that bash does not optimise away, so **without `exec` the recorded PID is that wrapper, not the daemon** — and this is true for *every* start shape: a script path, a plain simple command, an env-prefixed command, an absolute binary path. There is no exempt shape. With `exec`, the wrapper replaces itself with the daemon and the recorded PID is the daemon's own.

Measured on the cage's runtime (Debian trixie, bash 5.2.37) against a real Postgres 17 cluster: without `exec`, recorded PID `20` (`comm=bash`) while `postmaster.pid` held `22`; with `exec`, recorded PID `36` (`comm=postgres`) matched `postmaster.pid` exactly.

Worked example shipping the exec form: [`examples/postgres-pgvector/`](../../examples/postgres-pgvector/). Measured in a live cage, that recipe's recorded PID matches `postmaster.pid` on first start and again after an `rc down`/`rc up` resume.

**What `exec` does NOT fix: a dead daemon can still report healthy.** Init's liveness check is `kill -0 <recorded PID>`, and inside a cage nothing reaps orphans — msb's PID 1 (`init.krun`) leaves them as zombies indefinitely. `kill -0` on a zombie **succeeds**. Measured in a live cage: SIGKILL the postmaster, and the recorded PID stays in state `Z` with `pg_isready` reporting the database down; re-running init in that boot prints `daemon '<name>' already running (PID=…) — skipping (idempotent no-op)` and the database stays down. Both start shapes behave identically here — a wrapper PID and an exec'd daemon PID both linger as zombies — so `exec` is not a defence against this. See [ADR-005 D10](../decisions/ADR-005-ecosystem-tools.md) fail-warn: this is the one case where the warning never fires. Tracked as `rip-cage-893l` — the fix is init-side, so nothing you write in a manifest entry closes it.

The blast radius is bounded by where the PID file lives: `/tmp/rip-cage-daemon-<name>.pid` is wiped by the fresh kernel boot every msb resume performs, so the stale-zombie skip does **not** survive a resume (measured: a resumed cage starts the daemon afresh rather than skipping). It fires when init re-runs *within one boot* — `rc up` against an already-running cage, a second in-cage agent, any re-init.

Nothing enforces the prefix: `_manifest_validate` does not reject a bare `start`, and it should not — the false-healthy case above is indifferent to the start shape, so a syntax rule would gate the wrong thing while looking like a fix. (It would also have to encode the `VAR=1 exec cmd` ordering rule correctly, which is easy to get wrong.) Write `exec` for PID identity; the liveness gap is init's to close, not a per-entry manifest rule's.

## How it flows through rc

At **`rc build`**: the manifest is host-only, so everything the cage needs at runtime is baked. `_manifest_generate_daemon_config_dockerfile_steps` writes each daemon's `{name, start, health, state_dir, mcp_fragment}` into `/etc/rip-cage/daemon-config.json` (root-owned) and pre-creates `state_dir`; `_manifest_generate_daemon_mcp_dockerfile_steps` merges any `mcp_fragment` into settings. A manifest with no daemons emits nothing (D8 byte-for-byte contract).

At **cage init**: `init-rip-cage.sh` reads the baked config and, per daemon: creates `state_dir`; checks the PID file (`/tmp/rip-cage-daemon-<name>.pid`) — if the recorded process is alive it **skips as a true no-op** (never kill-and-restart); otherwise launches `start` in the background (log: `/tmp/rip-cage-daemon-<name>.log`), writes the PID file, and runs the `health` probe. Health OK → one log line; health failed → the fail-warn WARNING and the cage continues.

## How agents reach the daemon (two paths)

Per ADR-019 D9, the `mcp_fragment` reaches **MCP-capable agents only**:

| Agent class | Reach mechanism |
|---|---|
| MCP-capable (Claude Code) | MCP client via the baked `mcp_fragment` |
| Bash-only (pi — no MCP bridge) | the daemon's **own CLI over the bash tool** |

A daemon that wants to serve bash-only agents must ship a CLI; `mcp_fragment` alone is not enough. agent_mail's `am` CLI is the worked example (including the auth-mode gotcha where the CLI path needs a different serve mode — see [agent-mail-daemon.md](agent-mail-daemon.md)).

## DAEMON vs TOOL — which archetype do you need?

The lifecycle decides it, not the tool's size or importance:

| Your tool… | Archetype |
|---|---|
| Is a binary the agent invokes per-call; no resident process | **TOOL** ([adding-a-tool.md](adding-a-tool.md)) |
| Needs a one-shot setup step at cage boot (mkdir, config seed) and then just gets invoked | **TOOL with an `init` hook** (ADR-005 D7 boot hook — one-shot, agent-context, *not* a process) |
| Runs continuously and serves requests from in-cage agents over localhost | **IN-CAGE-DAEMON** (this doc) |
| Hooks the interactive shell via an rc-file eval line | **SHELL-INTEGRATION** ([shell-integration.md](shell-integration.md)) |
| Is a terminal session the agent's interactive session runs *inside* | **MULTIPLEXER** (seam catalog entry 4, [README.md](README.md)) |

The former **MEDIATOR** archetype (an egress proxy mediating the cage's outbound traffic) is **deleted, not just undocumented** — msb's `--net-rule`/`--secret` absorbed that role as runtime primitives, not a manifest-declared, `rc`-launched process. See [composition-seam.md](composition-seam.md).

The common confusion is the second row vs. this archetype: a TOOL `init` hook is a **one-shot command that exits**; a DAEMON `start` is a **process that stays up and answers a health probe**. If your "daemon" would exit immediately after doing its setup, it is a TOOL `init` hook — declaring it as a DAEMON just earns you a failed health check and a spurious fail-warn at every cage start.

Also worth ruling out: if the process should serve *multiple cages* or the host, no archetype fits — the manifest never reaches across cages (D8 FIRM), and that is a deliberate structural answer, not a missing feature.

---

## See also

- [agent-mail-daemon.md](agent-mail-daemon.md) — the concrete worked instance (real manifest entry, CLI surface, MCP fragment pitfalls, egress caveats)
- [manifest-validator.md](manifest-validator.md) — the exact checks and error messages a daemon entry must pass
- [docs/reference/README.md](README.md) — the full seam catalog
- `tests/fixtures/manifest-agent-mail.yaml` / `tests/fixtures/manifest-agent-mail-concurrent.yaml` — annotated fixtures exercised by the harness
- [ADR-005 D7/D8/D10/D12](../decisions/ADR-005-ecosystem-tools.md), [ADR-019 D9](../decisions/ADR-019-pi-coding-agent-support.md)
