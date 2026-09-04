"""Consumer-side DB-backed suite for the postgres-pgvector recipe (rip-cage-z40e).

This is the *harness target* for examples/postgres-pgvector/: it stands in for a real
project's DB-backed test suite and is run IN-CAGE against the recipe's cluster.

What it proves that a connectivity check does not:
  - The project selects the cluster the way a real project does — one DATABASE_URL
    env var, no code change, DSN shape-identical to a docker-compose one.
  - pgvector is LOADED, not merely installed: a real `vector` column, a real `<->`
    distance query returning the right row, and a real hnsw index.
  - No nested docker was involved.

Red-to-green contract: against a cage built WITHOUT the recipe's daemon entry, the
DATABASE_URL host is not listening and every DB test fails to connect. That is the
negative control — without it, a green run proves nothing about the recipe.

Run in-cage:
    DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/test \
        python3 -m pytest tests/fixtures/postgres-pgvector-consumer-suite -q

(`uv run` is the house default for Python, but a cage's egress allowlist does not
carry pypi, so third-party wheels cannot be resolved in-cage. The driver here is
apt-provided python3-psycopg2, composed as a separate manifest entry — a consuming
project's own dependency, never part of the recipe.)
"""

import os
import shutil
import uuid

import psycopg2
import pytest

DSN = os.environ.get("DATABASE_URL")


@pytest.fixture(scope="module")
def conn():
    if not DSN:
        pytest.fail("DATABASE_URL is unset — the consuming project selects the in-cage "
                    "cluster through this variable and nothing else.")
    # No retry loop on purpose: if the daemon is not up, this suite must go RED.
    connection = psycopg2.connect(DSN, connect_timeout=5)
    connection.autocommit = True
    yield connection
    connection.close()


@pytest.fixture(scope="module")
def schema(conn):
    """A real vector column, created the way a project's migration would."""
    table = f"z40e_{uuid.uuid4().hex[:8]}"
    with conn.cursor() as cur:
        # Bare CREATE EXTENSION, exactly as a real migration ships it. This fails if the
        # recipe pre-loaded the extension into template1 — which is why it must not.
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        cur.execute(f"CREATE TABLE {table} (id int primary key, embedding vector(3));")
        cur.execute(
            f"INSERT INTO {table} VALUES (1, '[1,2,3]'), (2, '[9,9,9]'), (3, '[1,2,4]');"
        )
    yield table
    with conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {table};")


def test_no_docker_inside_the_cage():
    """The recipe exists so a DB-backed suite needs no container runtime in the cage."""
    assert shutil.which("docker") is None, (
        "docker is on PATH inside the cage — the recipe's whole premise is that it "
        "does not have to be"
    )


def test_dsn_points_at_cage_loopback():
    """In-cage only (ADR-005 D8): the cluster is loopback, not a host or sibling service."""
    assert DSN is not None
    assert "127.0.0.1" in DSN or "localhost" in DSN, (
        f"DATABASE_URL should target cage loopback, got: {DSN}"
    )


def test_server_is_postgres_17(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT current_setting('server_version');")
        version = cur.fetchone()[0]
    assert version.startswith("17."), f"expected Postgres 17, got {version}"


def test_pgvector_extension_is_loaded(conn, schema):
    """Installed-on-disk is not enough; the extension must be loaded in this database."""
    with conn.cursor() as cur:
        cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'vector';")
        row = cur.fetchone()
    assert row is not None, "pgvector extension is not loaded in this database"
    assert row[0], "pgvector extension reports no version"


def test_vector_column_type_round_trips(conn, schema):
    with conn.cursor() as cur:
        cur.execute(f"SELECT embedding FROM {schema} WHERE id = 1;")
        value = cur.fetchone()[0]
    assert value == "[1,2,3]", f"vector column did not round-trip; got {value!r}"


def test_distance_operator_orders_by_similarity(conn, schema):
    """The `<->` L2 operator is the actual pgvector behaviour under test."""
    with conn.cursor() as cur:
        cur.execute(
            f"SELECT id FROM {schema} ORDER BY embedding <-> '[1,2,3]' LIMIT 2;"
        )
        ids = [r[0] for r in cur.fetchall()]
    assert ids == [1, 3], f"nearest-neighbour order wrong; got {ids}"


def test_hnsw_index_builds_on_a_vector_column(conn, schema):
    with conn.cursor() as cur:
        cur.execute(f"CREATE INDEX ON {schema} USING hnsw (embedding vector_l2_ops);")
        cur.execute(
            "SELECT count(*) FROM pg_indexes WHERE tablename = %s AND indexdef ILIKE '%%hnsw%%';",
            (schema,),
        )
        count = cur.fetchone()[0]
    assert count == 1, f"expected one hnsw index on {schema}, found {count}"
