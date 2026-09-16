# postgres-pgvector recipe

A Postgres 17 cluster with pgvector, running inside one cage as an ordinary
unprivileged process. It exists so an agent can run a database-backed test suite
without a container runtime inside the cage.

Not floor, never on by default (ADR-005 D12 FIRM). Nothing in `rc` names it.

## What is in here

| file | what it is |
|---|---|
| `Dockerfile.snippet` | the lines to paste into your own Dockerfile |
| `boot-fragment.json` | the daemon declaration, merged into the image's boot descriptor at build time |
| `postgres-start.sh` | the launcher: initdb on first start, then become the postmaster |
| `smoke.sh` | the behavioural check `rc test` runs in-cage |

## Use it

1. Write your own Dockerfile outside every directory your cage config mounts —
   `rc build` refuses one inside a cage mount, fail-closed, no opt-out
   (ADR-031 D5(a)). `~/.config/rip-cage/images/` is a good home.

   ```dockerfile
   FROM ghcr.io/jsnyde0/rip-cage:latest
   # ...paste Dockerfile.snippet here...
   ```

   Copy `boot-fragment.json`, `postgres-start.sh` and `smoke.sh` next to it: the
   `COPY` lines read them from the build context, which is that Dockerfile's own
   directory.

2. Build and point your cage config's `image:` key at the result:

   ```bash
   RC_IMAGE=my-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
   ```

3. `rc up`. Init starts the daemon and runs its health check; the cluster is on
   `127.0.0.1:5432` with database `test` and superuser `postgres`.

**This recipe needs no egress and no config edit.** The cluster binds loopback
inside one cage's network namespace, so it adds no host to any allowlist.

## Connecting from the project under test

```bash
export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/test
```

Trust auth ignores the password, so this is shape-identical to a typical
docker-compose DSN with the service host swapped for loopback. The project's own
host compose path is untouched.

`CREATE EXTENSION vector` is deliberately left to the consuming project's
migration. Pre-loading it into `template1` would break a migration that runs a
bare `CREATE EXTENSION vector` — which is exactly the shape real projects ship.
The recipe provisions the extension; the project loads it.

## Two things worth knowing before you change this

**`exec` in front of the launcher buys PID identity.** Init backgrounds `start`
and records `$!`. Backgrounding always forks a wrapper shell, so without `exec`
the recorded pid is that wrapper rather than the postmaster. This holds for every
start shape — a script path, a simple command, an env-prefixed command alike.
There is no exempt shape (measured, `rip-cage-6zlo`).

It is **not** a liveness fix. A killed daemon becomes an unreaped zombie under
msb's PID 1, its pid still passes `kill -0`, and init would skip it as "already
running" — identically with and without `exec`. That is why the descriptor makes
`health`, not the pid, the liveness authority. Full measurement:
[docs/reference/in-cage-daemon.md](../../docs/reference/in-cage-daemon.md).

**`initdb` runs at first start, not at image build.** `state_dir` is
cage-lifetime and is wiped by `rc destroy`. Point it under `/workspace` instead
and the cluster survives a destroy — a one-line change here and nowhere else,
which is only possible because the cluster is created at first start rather than
baked into the image.
