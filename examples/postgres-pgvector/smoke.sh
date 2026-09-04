#!/usr/bin/env bash
# smoke.sh — behavioural smoke test for the postgres-pgvector recipe (rip-cage-z40e).
#
# Baked to /usr/local/lib/rip-cage/recipe-tests/postgres-pgvector-smoke.sh (root:root 0755)
# by the recipe's install_cmd, and run in-cage by the generic name-free runner
# (tests/run-recipe-smokes.sh) as part of `rc test`. Contract: exit 0 = PASS.
#
# ANTI-VACUITY: "postgres is running" is not what this recipe promises. The promise is a
# WORKING pgvector, so the test creates a real vector column, runs a real distance query,
# and builds a real hnsw index. An extension that is installed on disk but fails to load
# would pass a connectivity check and fail this one.

set -uo pipefail

PGBIN="${RC_PG_BIN:-/usr/lib/postgresql/17/bin}"
PGHOST=127.0.0.1
PGPORT="${RC_PG_PORT:-5432}"
PGSUPERUSER="${RC_PG_SUPERUSER:-postgres}"
SMOKE_DB=rc_pgvector_smoke

PASS=0
FAIL=0

ok()   { echo "PASS: $*"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

psql_super() { "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGSUPERUSER" -d postgres "$@"; }
psql_smoke() { "$PGBIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGSUPERUSER" -d "$SMOKE_DB" "$@"; }

echo "=== postgres-pgvector recipe smoke ==="

# ---------------------------------------------------------------------------
# 1. No nested docker. The whole point of the recipe: a DB-backed suite runs
#    in-cage with no container runtime inside the cage (acceptance #1).
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  bad "docker is on PATH inside the cage — this recipe exists so it does not have to be"
else
  ok "no docker inside the cage"
fi

# ---------------------------------------------------------------------------
# 2. The daemon is up and accepting TCP on loopback.
# ---------------------------------------------------------------------------
if "$PGBIN/pg_isready" -q -h "$PGHOST" -p "$PGPORT"; then
  ok "postgres accepting connections on $PGHOST:$PGPORT"
else
  bad "postgres not accepting connections on $PGHOST:$PGPORT (see /tmp/rip-cage-daemon-postgres-pgvector.log)"
  echo "=== smoke summary: ${PASS} passed, ${FAIL} failed ==="
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. The bootstrap database the launcher creates exists.
# ---------------------------------------------------------------------------
if psql_super -tAc "SELECT 1 FROM pg_database WHERE datname='${RC_PG_DB:-test}';" | grep -q '^1$'; then
  ok "bootstrap database '${RC_PG_DB:-test}' exists"
else
  bad "bootstrap database '${RC_PG_DB:-test}' missing"
fi

# ---------------------------------------------------------------------------
# 4. pgvector is LOADED, not merely installed: extension + column type +
#    distance operator + index. Scratch DB so the run leaves no residue.
# ---------------------------------------------------------------------------
psql_super -q -c "DROP DATABASE IF EXISTS $SMOKE_DB;" >/dev/null 2>&1
if ! psql_super -q -c "CREATE DATABASE $SMOKE_DB;" >/dev/null 2>&1; then
  bad "could not create scratch database $SMOKE_DB"
  echo "=== smoke summary: ${PASS} passed, ${FAIL} failed ==="
  exit 1
fi

VEC_OUT=$(psql_smoke -v ON_ERROR_STOP=1 -tAq \
  -c "CREATE EXTENSION vector;" \
  -c "SELECT 'extversion=' || extversion FROM pg_extension WHERE extname='vector';" \
  -c "CREATE TABLE smoke_vec (id int, v vector(3));" \
  -c "INSERT INTO smoke_vec VALUES (1,'[1,2,3]'),(2,'[9,9,9]');" \
  -c "SELECT 'nearest=' || id FROM smoke_vec ORDER BY v <-> '[1,2,3]' LIMIT 1;" \
  -c "CREATE INDEX ON smoke_vec USING hnsw (v vector_l2_ops);" 2>&1)
VEC_RC=$?

if [[ "$VEC_RC" -eq 0 ]]; then
  ok "pgvector extension loads ($(echo "$VEC_OUT" | grep -o 'extversion=[^ ]*' || echo 'version unknown'))"
else
  bad "pgvector exercise failed (exit $VEC_RC): $VEC_OUT"
fi

if echo "$VEC_OUT" | grep -q '^nearest=1$'; then
  ok "vector(3) column + '<->' distance operator return the correct nearest row"
else
  bad "distance query did not return the expected nearest row; got: $VEC_OUT"
fi

if echo "$VEC_OUT" | grep -qi 'CREATE INDEX'; then
  ok "hnsw index builds on a vector column"
else
  # -tAq suppresses command tags; treat a clean exit as the signal instead.
  if [[ "$VEC_RC" -eq 0 ]]; then
    ok "hnsw index builds on a vector column (clean exit)"
  else
    bad "hnsw index build failed"
  fi
fi

psql_super -q -c "DROP DATABASE IF EXISTS $SMOKE_DB;" >/dev/null 2>&1

echo "=== smoke summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
