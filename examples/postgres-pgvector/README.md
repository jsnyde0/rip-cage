# postgres-pgvector — composable recipe (rip-cage-z40e)

A **Postgres 17 + pgvector** cluster running as a plain unprivileged process inside one cage,
so a caged agent can run a DB-backed test suite with **no docker in the cage** and **no change
to the containment floor** — no msb flag, no egress allowlist entry, no `.rip-cage.yaml` edit.

This is the same pattern GitHub Actions runner images use: install the server at image build,
start it as an ordinary process at cage init. It needs zero privilege change because a database
server is just a program that binds a loopback port.

**Not floor, never blessed by default** ([ADR-005 D12](../../docs/decisions/ADR-005-ecosystem-tools.md) FIRM):
this recipe lives in `examples/` only. It is never added to `manifest/default-tools.yaml`, and no
`rc` source file names it.

## What this recipe provisions

One `IN-CAGE-DAEMON` manifest entry ([seam 8](../../docs/reference/README.md), walkthrough:
[in-cage-daemon.md](../../docs/reference/in-cage-daemon.md)) that:

| Field | What it does |
|---|---|
| `install_cmd` | Installs `postgresql-17` + `postgresql-17-pgvector` from **Debian trixie main** at image build (**+87 MiB**, measured), disables postgresql-common's unused default cluster, and bakes the launcher + smoke test at root-owned paths. |
| `start` | `exec /usr/local/lib/rip-cage/postgres-pgvector-start.sh` — runs as the agent user, `initdb`s on first start only, then becomes the postmaster on `127.0.0.1:5432`. The `exec` prefix is load-bearing; see below. |
| `health` | Polls `pg_isready` inside the probe's own budget, so a first boot that includes `initdb` earns no spurious fail-warn. |
| `state_dir` | `/var/lib/rip-cage-daemon/postgres-pgvector` — the PGDATA directory. |
| `egress` | `[]`. The cluster binds loopback inside one cage's network namespace and reaches nothing. |

### No third-party apt repo

The bead's original research called for the PGDG archive. The cage base image is `debian:trixie`
(`cage/Dockerfile:13`), and **trixie main already carries both packages** — `postgresql-17`
17.11 and `postgresql-17-pgvector` 0.8.0, for arm64 and amd64. So the recipe uses the base
image's own apt sources: no signing key, no extra repo, no build-time network beyond what every
`rc build` already does. Reach for PGDG only if you need a version trixie does not ship.

## Why `start` begins with `exec` — read this before writing your own daemon recipe

Init launches the daemon with `eval "$start" … &` and records the backgrounded job's PID,
which it later liveness-checks with `kill -0`. **If `start` is a bare script path, bash forks a
wrapper shell and the recorded PID is the wrapper, not the daemon.** The wrapper outlives a
crashed postmaster, so `kill -0` succeeds forever: init reports "already running — skipping" on
every resume and a dead cluster is never restarted. That is worse than a crash, because it looks
healthy.

Measured in a live cage while building this recipe: with a bare path, the recorded PID was
`init-rip-cage.sh` itself and survived killing the postmaster. With `exec` in front, the recorded
PID equals `PGDATA/postmaster.pid` and dies with the cluster.

**This bites any daemon whose `start` is a script path.** A daemon whose `start` is a simple
command (agent_mail's `STORAGE_ROOT=… mcp-agent-mail serve --no-tui`) is fine, because bash
execs it directly. If you write a launcher script, prefix it with `exec`.

## Why `initdb` at first start, not at image build

**Decision: `initdb` runs on the first daemon start.** Two reasons, one structural and one
contractual:

1. **The build stage has no agent user yet.** `rc` splices `install_cmd` steps *before* the
   `# Non-root user` sentinel in `cage/Dockerfile`, so at that point `useradd agent` has not run.
   `initdb` must run non-root as the user that will own the cluster, and at build time that user
   does not exist. A build-time `initdb` would need its own `useradd` gymnastics inside the
   recipe — machinery in exchange for about two seconds.
2. **It keeps `state_dir` the single source of truth.** The archetype documents durability as a
   one-line change: point `state_dir` under `/workspace` and the cluster survives `rc destroy`
   ([in-cage-daemon.md](../../docs/reference/in-cage-daemon.md), "State is cage-lifetime"). A
   cluster baked into the image sits at a build-fixed path, so repointing `state_dir` would
   silently give you an *empty* directory and a broken daemon. First-start `initdb` follows
   `state_dir` wherever you put it.

**Measured cost, first cage boot only:** `initdb` 0.8 s + create the `test` database 0.9 s +
postmaster ready 0.4 s ≈ **2.1 s** (debian:trixie, arm64). Every later boot skips straight to
`exec` on the `PGDATA/PG_VERSION` guard. The health probe's budget is ~18 s, so there is ample
headroom, and the probe polls rather than sampling once — a slower host does not produce a
spurious WARNING.

## How a consuming project selects the in-cage DSN

Set one environment variable in the cage:

```bash
export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/test
```

The cluster is initialised with `--auth=trust` and a superuser named `postgres`, so that string
is **shape-identical to a typical `docker-compose` DSN** with the service host swapped for
loopback — the password is present and ignored. A project whose settings already read
`DATABASE_URL` (Django + `dj-database-url`, Rails, most others) needs **no code change**, and its
host `docker-compose` path is untouched because that path supplies its own `DATABASE_URL`.

Trust auth is safe *here and only here*: the cluster binds `127.0.0.1` inside a single cage's
network namespace ([ADR-005 D8](../../docs/decisions/ADR-005-ecosystem-tools.md) FIRM — in-cage
only). No other cage and no host process can route to it.

For an interactive poke around, one flag:

```bash
psql -h 127.0.0.1 test
```

`-h` is needed because the cluster's unix socket lives in `/tmp` (the agent user cannot write
postgresql-common's default `/var/run/postgresql`). No `-U` is needed because the launcher creates
a superuser role named after the cage's OS user — without it, an unqualified connection logs
`FATAL: role "agent" does not exist`, which reads like a real fault to whoever opens the daemon
log next.

Exporting that variable is the **agent's composition step**, deliberately not automated by this
recipe. If you want it in every shell, add a `SHELL-INTEGRATION` entry of your own that emits the
`export` line — that is a second manifest entry you compose, not something this fragment decides
for you.

### `CREATE EXTENSION` is the project's job

The launcher does **not** pre-load pgvector into `template1`. Real projects ship a migration that
runs a bare `CREATE EXTENSION vector`, which would fail against a database where the extension is
already present. The recipe provisions the extension; your migration loads it.

### Parity with a `pgvector/pgvector:pg17` production image

Two things to pin on both sides:

- **Extension version.** This recipe gives you pgvector **0.8.0** (Debian trixie). Check prod with
  `SELECT extversion FROM pg_extension WHERE extname='vector';` and pin the production image tag to
  match.
- **Locale.** The cluster is created with `--locale-provider=builtin --locale=C.UTF-8`, so sort
  order does not drift with the base image's glibc/ICU version. Pin the same locale in production
  or your `ORDER BY` results can differ between environments.

## How to enable

1. Copy the `tools[]` entry from [`manifest-fragment.yaml`](manifest-fragment.yaml) into your
   `~/.config/rip-cage/tools.yaml`.
2. Run `rc build`.
3. Run `rc up` — init starts the daemon and logs
   `[rip-cage] daemon 'postgres-pgvector' health OK (PID=…)`.

The agent does the wiring. No `rc` source edits required.

Verify from inside the cage:

```bash
rc test <cage-name>        # runs the recipe smoke test (pgvector column + distance query)
rc exec <cage-name> -- pg_isready -h 127.0.0.1 -p 5432
```

## If the daemon does not come up

A broken cluster is **fail-warn, never brick** ([ADR-005 D10](../../docs/decisions/ADR-005-ecosystem-tools.md)):
init prints `WARNING: daemon 'postgres-pgvector' health check FAILED … cage continues without it`
and your agent session comes up normally. A database is not load-bearing for the cage; losing your
session over one would defeat the point.

The launcher's reason is in `/tmp/rip-cage-daemon-postgres-pgvector.log` inside the cage.

## Files

| File | What it is |
|---|---|
| [`manifest-fragment.yaml`](manifest-fragment.yaml) | The `tools[]` entry to copy. **Generated** — do not hand-edit the base64. |
| [`postgres-start.sh`](postgres-start.sh) | The launcher. Source of truth for the `start` field's behaviour. |
| [`smoke.sh`](smoke.sh) | Behavioural smoke test, run in-cage by `rc test` via the generic name-free runner. |
| [`build-fragment.sh`](build-fragment.sh) | Regenerates `manifest-fragment.yaml` from the two scripts. Run it after editing either. |
