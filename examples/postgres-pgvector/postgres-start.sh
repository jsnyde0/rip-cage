#!/usr/bin/env bash
# postgres-start.sh — IN-CAGE-DAEMON launcher for the postgres-pgvector recipe (rip-cage-z40e).
#
# Baked to /usr/local/lib/rip-cage/postgres-pgvector-start.sh (root:root 0755) by the
# recipe's Dockerfile COPY line. The boot descriptor's `daemons[].start` field
# invokes it; nothing else does.
#
# Contract with the IN-CAGE-DAEMON seam (docs/reference/in-cage-daemon.md):
#   - init-rip-cage.sh runs this via `eval "$start" >/tmp/rip-cage-daemon-<name>.log 2>&1 &`
#     as the AGENT user, and records $! as the daemon PID, which it later liveness-checks
#     with `kill -0`. THE MANIFEST'S `start` MUST THEREFORE BE `exec <this script>`, NOT a
#     bare path — the prefix buys PID IDENTITY. Backgrounding an eval always forks a wrapper
#     shell, so without exec $! records THAT wrapper rather than the postmaster; with exec the
#     backgrounded shell is replaced by this script, this script execs the postmaster, and the
#     recorded PID is the postmaster. Verified in a live cage: recorded PID ==
#     PGDATA/postmaster.pid on first start and again after a resume.
#     THIS HOLDS FOR EVERY START SHAPE — script path, simple command, env-prefixed command
#     alike. There is no exempt shape; an earlier revision of this header claimed agent_mail's
#     simple command was exempt, and that is wrong (measured, rip-cage-6zlo).
#   - THE PREFIX IS NOT A LIVENESS FIX. A SIGKILLed daemon becomes an unreaped zombie under
#     msb's PID 1, its PID still passes `kill -0`, and a re-run of init in the same boot skips
#     it as "already running" while the cluster is down — identically with and without exec.
#     That defect is rip-cage-893l and is init-side; nothing written here closes it. Full
#     measurement: docs/reference/in-cage-daemon.md "The exec prefix on start".
#   - state_dir is pre-created at build as root then chown'd agent:agent. It arrives mode
#     0755; initdb sets it to 0700 itself, so no chmod is needed here (verified on
#     debian:trixie, rip-cage-z40e probe).
#   - Fail-warn, never brick (ADR-005 D10): every failure path here exits non-zero and
#     leaves a reason in the log. init treats that as a failed health check, prints the
#     WARNING, and the cage comes up anyway. Never `exit 0` on a broken cluster — a silent
#     success would hide the breakage behind a green health probe.
#
# INITDB TIMING: FIRST START, not image build. See README.md "Why initdb at first start".

set -euo pipefail

PGDATA="${RC_PG_DATA:-/var/lib/rip-cage-daemon/postgres-pgvector}"
PGBIN="${RC_PG_BIN:-/usr/lib/postgresql/17/bin}"
PGPORT="${RC_PG_PORT:-5432}"
PGDB="${RC_PG_DB:-test}"
PGSUPERUSER="${RC_PG_SUPERUSER:-postgres}"

log() { echo "[postgres-pgvector] $*"; }

if [[ ! -x "$PGBIN/postgres" ]]; then
  log "ERROR: $PGBIN/postgres is not executable — is postgresql-17 installed in this image?" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# One-time bootstrap. Guarded on PGDATA/PG_VERSION, which initdb writes last-ish
# and which is the same marker pg_ctl uses to recognise a real cluster. A cage
# resume re-runs init, finds PG_VERSION, and skips straight to exec.
# ---------------------------------------------------------------------------
if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
  log "no cluster at $PGDATA — running initdb (first start only)"

  # --locale-provider=builtin --locale=C.UTF-8 pins collation to the C library-independent
  # builtin provider, so the cluster's sort order does not drift with the base image's
  # glibc/ICU version. Prod parity: pin the SAME locale on the production side.
  # --auth=trust is safe here and only here: the cluster binds 127.0.0.1 inside ONE cage's
  # network namespace (ADR-005 D8 FIRM, in-cage only) and is reachable from nothing else.
  if ! "$PGBIN/initdb" \
        -D "$PGDATA" \
        -U "$PGSUPERUSER" \
        --locale-provider=builtin \
        --locale=C.UTF-8 \
        --encoding=UTF8 \
        --auth=trust; then
    log "ERROR: initdb failed — see output above. Cluster not created." >&2
    exit 1
  fi

  # Create the application database while the server is up on a UNIX SOCKET ONLY
  # (-h "" disables TCP). Doing this before the real TCP listener starts means no window
  # where an agent can connect to a half-bootstrapped cluster.
  if ! "$PGBIN/pg_ctl" -D "$PGDATA" -o "-k /tmp -h ''" -w -t 60 start; then
    log "ERROR: bootstrap pg_ctl start failed — cluster created but database '$PGDB' missing." >&2
    exit 1
  fi

  _bootstrap_rc=0
  "$PGBIN/createdb" -h /tmp -U "$PGSUPERUSER" "$PGDB" || _bootstrap_rc=$?

  # A role matching the cage's OS user, so `psql test` works with no flags from the agent
  # shell. Without it every unqualified connection — including the health probe's — logs
  # `FATAL: role "agent" does not exist`, which is noise that looks like a real fault when
  # someone reads the daemon log to diagnose something else (observed, rip-cage-z40e).
  # Superuser because this is a throwaway test cluster on loopback, not a shared database.
  _os_user="$(id -un)"
  if [[ -n "$_os_user" && "$_os_user" != "$PGSUPERUSER" ]]; then
    "$PGBIN/createuser" -h /tmp -U "$PGSUPERUSER" --superuser "$_os_user" \
      || log "WARNING: could not create role '$_os_user'; connect with -U $PGSUPERUSER instead"
  fi

  "$PGBIN/pg_ctl" -D "$PGDATA" -w -t 60 stop || true

  if [[ "$_bootstrap_rc" -ne 0 ]]; then
    log "ERROR: createdb '$PGDB' failed (exit $_bootstrap_rc)." >&2
    exit 1
  fi

  # DELIBERATELY NOT DONE: `CREATE EXTENSION vector` is left to the consuming project's
  # own migration. Pre-loading it into template1 would make a consumer migration that runs
  # a bare `CREATE EXTENSION vector` (no IF NOT EXISTS) fail — which is exactly the shape
  # real projects ship. The recipe provisions the extension; the project loads it.
  log "bootstrap complete: cluster at $PGDATA, database '$PGDB', superuser '$PGSUPERUSER'"
else
  log "existing cluster at $PGDATA — skipping initdb"
fi

# ---------------------------------------------------------------------------
# Become the postmaster. -h 127.0.0.1 binds loopback only; there is no path from
# another cage or the host to this port (ADR-005 D8 FIRM).
# ---------------------------------------------------------------------------
log "starting postgres on 127.0.0.1:$PGPORT (PGDATA=$PGDATA)"
exec "$PGBIN/postgres" -D "$PGDATA" -k /tmp -h 127.0.0.1 -p "$PGPORT"
