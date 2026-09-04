# postgres-pgvector consumer suite (fixture)

The **harness target** for [`examples/postgres-pgvector/`](../../../examples/postgres-pgvector/README.md):
a stand-in for a real project's DB-backed test suite, run **in-cage** against the recipe's cluster.

The recipe's own [`smoke.sh`](../../../examples/postgres-pgvector/smoke.sh) proves the cluster
works at the SQL level and runs automatically under `rc test`. This suite proves the thing a
consuming project actually cares about: that a normal pytest run, selecting the database through
one `DATABASE_URL` variable, gets a working pgvector.

## Running it

```bash
rc exec <cage> -- bash -lc \
  'cd /workspace && DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/test \
     python3 -m pytest tests/fixtures/postgres-pgvector-consumer-suite -q'
```

**Expected green:** 7 passed. **Expected red** on a cage built *without* the recipe's daemon
entry: the DB tests fail to connect. That negative control is the point — a suite that was
already green before the recipe existed proves nothing.

## Two composition notes

- **`python3-psycopg2` is the consumer's dependency, not the recipe's.** It is composed as a
  separate manifest entry for the demonstration. The recipe provisions the *database*; a project
  brings its own driver.
- **`uv` is the house default for Python but cannot run here.** A cage's egress allowlist does
  not carry pypi, so third-party wheels are unresolvable in-cage. Apt-provided
  `python3-psycopg2` + `python3-pytest` is the path that works without widening egress — which
  the recipe must never require ([ADR-005 D14](../../../docs/decisions/ADR-005-ecosystem-tools.md)).
