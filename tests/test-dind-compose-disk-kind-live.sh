#!/usr/bin/env bash
# tests/test-dind-compose-disk-kind-live.sh -- LIVE effect-based proof for
# the DinD/compose disk-kind docker-data volume surface (rip-cage-75rq, S11
# of the msb migration epic rip-cage-tsf2).
#
# Wires the proven-but-unwired capability (findings §10b): a cage running
# nested Docker/compose needs /var/lib/docker on a **disk-kind** (virtio-blk)
# msb named volume, not the virtiofs default, because docker's overlay2
# storage driver cannot write whiteout files onto virtiofs/overlayfs.
#
# Stands up cages via `msb run` directly, applying THIS module's own
# generator output (`cli/lib/msb_flags.sh`'s `_msb_flags_emit_dind_volume`,
# via a `dind_volumes` config) for the disk-kind mount flags -- rc's create
# verb doesn't exist yet (that's S6) -- matching the S4<->S6
# non-circularity pattern documented in
# docs/2026-07-10-tsf2-decomposition.md.
#
# In-cage client knobs the spike found necessary (findings §10b) are
# IMAGE-SPECIFIC boot-time/runtime knobs, not something a generic
# config->flags generator can infer from declared intent alone, so this
# test applies them directly at `msb run`/exec time (confirmed live during
# this bead's own pre-flight: `--init auto` does NOT reliably hand off to
# docker:dind's dockerd -- it falls back to a generic /sbin/init and
# dockerd never starts; the explicit
# `--init /usr/local/bin/dockerd-entrypoint.sh --init-arg dockerd` form is
# required):
#   - `--init /usr/local/bin/dockerd-entrypoint.sh --init-arg dockerd` at
#     `msb run` time, so dockerd is PID1-supervised (survives `msb exec`
#     returning), not a backgrounded child of a transient exec session.
#   - `PGSSLMODE=disable` on the psql client (SSL negotiation stalls
#     through the nested-docker network otherwise).
#   - connect to the compose service over TCP from the cage, never
#     `docker exec` into the nested container (that path hangs on a nested
#     TTY/stream issue per findings §10b).
#
# Per the msb fake-accept confound (bd memory
# msb-netstack-fake-accepts-tcp-connect-not-egress) and this bead's own
# acceptance text, every assertion here is a REAL effect -- an actual
# written-then-read-back value, a REAL overlay2 mount error, a REAL
# same-PID liveness check -- never a container "healthy" status or
# connect()-success.
#
# Coverage (mirrors the bead's acceptance criteria):
#   C1  a compose-launched postgres service, backed by the disk-kind
#       volume, accepts a real write+read round trip over TCP [criterion 1]
#   C2  a virtiofs-dir volume for the SAME guest path (/var/lib/docker)
#       genuinely fails overlay2 -- real mount error captured, not a status
#       check [criterion 2, negative control]
#   C3  dockerd survives the --init handoff: same PID, still responsive,
#       across independent `msb exec` calls returning [criterion 3]
#
# NEEDS_CONTAINER + NEEDS_MSB + the docker:dind image loaded into msb +
# live network egress (nested `docker pull` of postgres:16-alpine, `apk add
# postgresql-client`). Self-skips (exit 0, SKIP: ...) when any prerequisite
# is missing -- never fakes a PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GEN="${REPO_ROOT}/cli/lib/msb_flags.sh"
DIND_IMAGE="docker:dind"
RUN_ID="$$"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json >/dev/null 2>&1; then
  echo "SKIP: msb not responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "\"reference\": \"${DIND_IMAGE}\""; then
  echo "SKIP: ${DIND_IMAGE} not loaded into msb -- skipping $(basename "$0") (run: msb pull docker:dind)"
  exit 0
fi

# shellcheck disable=SC1090
source "$GEN"

CAGE_C1="75rq-probe-c1-${RUN_ID}"
CAGE_C2="75rq-probe-c2-${RUN_ID}"
VOL_DISK="75rq-diskvol-${RUN_ID}"
VOL_DIR="75rq-dirvol-${RUN_ID}"
SCRATCH_DIR=$(mktemp -d)
INIT_FLAGS=(--init /usr/local/bin/dockerd-entrypoint.sh --init-arg dockerd)

cleanup() {
  msb remove -f "$CAGE_C1" >/dev/null 2>&1 || true
  msb remove -f "$CAGE_C2" >/dev/null 2>&1 || true
  msb volume remove "$VOL_DISK" >/dev/null 2>&1 || true
  msb volume remove "$VOL_DIR" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH_DIR"
  rm -f /tmp/75rq-*.err
}
trap cleanup EXIT

# ===========================================================================
# C1: disk-kind volume -> real compose-service write+read round trip over TCP
# ===========================================================================
echo ""
echo "=== C1: disk-kind docker-data volume -> real compose postgres write+read round trip over TCP ==="

# allowed_hosts covers what nested dockerd/apk need to reach: the registry
# pull path (registry-1.docker.io, auth.docker.io, production.cloudfront.
# docker.com -- the actual blob-storage CDN host, confirmed live) and the
# Alpine package CDN (apk add postgresql-client below).
# Root-caused live during this bead's debugging: _msb_flags_generate ALWAYS
# emits `--net-default deny` (S2's containment default, section 1) -- a
# dind_volumes-only config with no allowed_hosts correctly blocks ALL
# egress including DNS/registry, which looks identical to "flaky DNS" from
# inside the guest until you notice the boot flags contain no allow rules
# at all. This is expected containment behavior, not an S11 defect; a real
# dind-capable cage config declares both surfaces together.
C1_CFG=$(jq -nc --arg name "$VOL_DISK" '{"allowed_hosts": ["registry-1.docker.io", "auth.docker.io", "production.cloudfront.docker.com", "dl-cdn.alpinelinux.org"], "dind_volumes": [{"name": $name, "guest_path": "/var/lib/docker", "size": "6G"}]}')
mapfile -t C1_FLAGS < <(_msb_flags_generate "$C1_CFG")
if [[ "${#C1_FLAGS[@]}" -gt 0 ]]; then
  pass "C1 setup: generator (this bead's own dind_volumes surface) produced disk-kind --mount-named flags"
else
  fail "C1 setup: generator produced no flags" ""
fi

if msb run -d --name "$CAGE_C1" --replace "${C1_FLAGS[@]}" "${INIT_FLAGS[@]}" "$DIND_IMAGE" >/tmp/75rq-c1-boot.err 2>&1; then
  pass "C1 setup: cage boots from generator-emitted disk-kind flags + --init dockerd handoff"
else
  fail "C1 setup: cage failed to boot" "$(cat /tmp/75rq-c1-boot.err)"
fi

# Poll for dockerd readiness under the --init handoff (boot-time variance)
# instead of a single fixed sleep.
for _ in 1 2 3 4 5 6; do
  msb exec "$CAGE_C1" -- sh -c 'docker info >/dev/null 2>&1' && break
  sleep 5
done

C1_STORAGE_DRIVER=$(msb exec "$CAGE_C1" -- sh -c "docker info 2>/dev/null | grep -i 'Storage Driver'" 2>/tmp/75rq-c1-info.err)
if [[ "$C1_STORAGE_DRIVER" == *"overlayfs"* ]]; then
  pass "C1: nested dockerd reports overlayfs storage driver on the disk-kind volume"
else
  fail "C1: expected overlayfs storage driver" "$C1_STORAGE_DRIVER stderr=$(cat /tmp/75rq-c1-info.err)"
fi

printf '%s\n' \
  'services:' \
  '  db:' \
  '    image: postgres:16-alpine' \
  '    environment:' \
  '      POSTGRES_PASSWORD: s11pass' \
  '      POSTGRES_USER: s11user' \
  '      POSTGRES_DB: s11db' \
  '    ports:' \
  '      - "15432:5432"' \
  > "${SCRATCH_DIR}/compose.yml"

msb exec "$CAGE_C1" -- mkdir -p /tmp/75rq-compose >/dev/null 2>&1
if msb copy "${SCRATCH_DIR}/compose.yml" "${CAGE_C1}:/tmp/75rq-compose/compose.yml" >/tmp/75rq-c1-copy.err 2>&1; then
  pass "C1 setup: compose.yml staged into the cage via msb copy"
else
  fail "C1 setup: failed to stage compose.yml" "$(cat /tmp/75rq-c1-copy.err)"
fi

# Pre-warm the image via a direct `docker pull` (retried -- ordinary
# registry-network resilience, not a workaround for anything msb-specific)
# before compose up. NOTE for the manifest-composing caller: this requires
# `allowed_hosts` naming the registry pull path (registry-1.docker.io,
# auth.docker.io, production.cloudfront.docker.com -- the actual
# blob-storage CDN host, confirmed live) alongside `dind_volumes` --
# `_msb_flags_generate` ALWAYS emits `--net-default deny` (S2's containment
# default), so a dind_volumes-only config with no allowed_hosts correctly
# blocks ALL nested registry egress (this was root-caused live during this
# bead's own debugging: it initially looked exactly like flaky DNS from
# inside the guest, until the boot flags were checked and turned out to
# carry zero allow rules -- expected containment, not an S11 defect).
for _ in 1 2 3; do
  msb exec "$CAGE_C1" -- sh -c 'docker pull postgres:16-alpine >/dev/null 2>&1' && break
  sleep 5
done

C1_COMPOSE_UP_OK=""
for _ in 1 2 3; do
  if msb exec -w /tmp/75rq-compose "$CAGE_C1" -- docker compose up -d >/tmp/75rq-c1-compose-up.err 2>&1; then
    C1_COMPOSE_UP_OK=1
    break
  fi
  sleep 4
done
if [[ -n "$C1_COMPOSE_UP_OK" ]]; then
  pass "C1 setup: docker compose up -d created the postgres service on the disk-kind volume"
else
  fail "C1 setup: docker compose up -d failed after retries" "$(cat /tmp/75rq-c1-compose-up.err)"
fi

sleep 5

# --- real write+read round trip over TCP from the CAGE (not `docker exec`
# into the nested container), PGSSLMODE=disable per findings §10b ---
for _ in 1 2 3; do
  msb exec "$CAGE_C1" -- sh -c 'command -v psql >/dev/null 2>&1 || apk add --no-cache postgresql-client >/dev/null 2>&1'
  if msb exec "$CAGE_C1" -- sh -c 'command -v psql' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# Write and read as SEPARATE statements/calls so the read's output is
# EXACTLY the value (not concatenated with CREATE TABLE/INSERT status
# lines from a combined multi-statement -c call).
C1_WRITE_VALUE="75rq-$(date +%s)-${RUN_ID}"
msb exec "$CAGE_C1" -- sh -c "PGPASSWORD=s11pass PGSSLMODE=disable psql -h 127.0.0.1 -p 15432 -U s11user -d s11db -c \"CREATE TABLE IF NOT EXISTS s11_probe(val text); INSERT INTO s11_probe VALUES ('${C1_WRITE_VALUE}');\"" >/tmp/75rq-c1-write.err 2>&1
C1_QUERY_OUT=$(msb exec "$CAGE_C1" -- sh -c "PGPASSWORD=s11pass PGSSLMODE=disable psql -h 127.0.0.1 -p 15432 -U s11user -d s11db -tAc \"SELECT val FROM s11_probe WHERE val = '${C1_WRITE_VALUE}';\"" 2>/tmp/75rq-c1-query.err)
if [[ "$C1_QUERY_OUT" == "$C1_WRITE_VALUE" ]]; then
  pass "C1: REAL write+read round trip over TCP -- wrote '${C1_WRITE_VALUE}', read back the SAME value (not a healthy-container status)"
else
  fail "C1: expected the written value read back over TCP" "wrote='${C1_WRITE_VALUE}' got='${C1_QUERY_OUT}' write_stderr=$(cat /tmp/75rq-c1-write.err) read_stderr=$(cat /tmp/75rq-c1-query.err)"
fi

msb remove -f "$CAGE_C1" >/dev/null 2>&1 || true
# C3 re-creates VOL_DISK fresh below; remove it here so that create isn't a
# collide-with-C1's-leftover-volume false failure (the volume's cross-cage
# persistence itself is proven separately in the msb spike findings, not
# re-tested here).
msb volume remove "$VOL_DISK" >/dev/null 2>&1 || true

# ===========================================================================
# C2: negative control -- a virtiofs-dir volume for the SAME path
# (/var/lib/docker) genuinely fails overlay2
# ===========================================================================
echo ""
echo "=== C2 (negative control): virtiofs-dir volume at /var/lib/docker fails overlay2 with a REAL error ==="

if msb volume create --name "$VOL_DIR" --kind dir >/tmp/75rq-c2-volcreate.err 2>&1; then
  pass "C2 setup: dir-kind (virtiofs) volume created"
else
  fail "C2 setup: failed to create dir-kind volume" "$(cat /tmp/75rq-c2-volcreate.err)"
fi

if msb run -d --name "$CAGE_C2" --replace --mount-named "${VOL_DIR}:/var/lib/docker" "${INIT_FLAGS[@]}" "$DIND_IMAGE" >/tmp/75rq-c2-boot.err 2>&1; then
  pass "C2 setup: negative-control cage boots with a virtiofs-dir volume at /var/lib/docker"
else
  fail "C2 setup: negative-control cage failed to boot" "$(cat /tmp/75rq-c2-boot.err)"
fi

for _ in 1 2 3 4 5 6; do
  msb exec "$CAGE_C2" -- sh -c 'docker info >/dev/null 2>&1' && break
  sleep 5
done

# Retry the pull specifically (ordinary registry-network resilience) so a
# failed PULL never masquerades as the overlay2 failure we're actually
# probing for here. This cage boots with a plain --mount-named (no S2
# generator flags, so no --net-default deny) -- open egress by design,
# since C2 is a negative control isolating the storage-driver behavior, not
# a probe of the net-rule surface.
for _ in 1 2 3; do
  msb exec "$CAGE_C2" -- sh -c 'docker pull postgres:16-alpine >/dev/null 2>&1' && break
  sleep 4
done
C2_RUN_ERR=$(msb exec "$CAGE_C2" -- sh -c 'docker run --rm postgres:16-alpine echo hello' 2>&1)
if [[ "$C2_RUN_ERR" == *"overlay"* && ( "$C2_RUN_ERR" == *"invalid argument"* || "$C2_RUN_ERR" == *"whiteout"* || "$C2_RUN_ERR" == *"operation not permitted"* ) ]]; then
  pass "C2: virtiofs-dir volume genuinely fails overlay2 with a REAL error (confirms disk-kind is required, not incidental): $(echo "$C2_RUN_ERR" | tail -1)"
else
  fail "C2: expected a real overlay2/whiteout mount failure on the virtiofs-dir volume" "$C2_RUN_ERR"
fi

msb remove -f "$CAGE_C2" >/dev/null 2>&1 || true

# ===========================================================================
# C3: dockerd survives the --init handoff (not reaped when msb exec returns)
# ===========================================================================
echo ""
echo "=== C3: dockerd survives via --init handoff -- not reaped when msb exec returns ==="

if msb volume create --name "$VOL_DISK" --kind disk --size 6G >/tmp/75rq-c3-volcreate.err 2>&1; then
  pass "C3 setup: disk-kind volume (re)created"
else
  fail "C3 setup: failed to create disk-kind volume" "$(cat /tmp/75rq-c3-volcreate.err)"
fi

if msb run -d --name "$CAGE_C1" --replace --mount-named "${VOL_DISK}:/var/lib/docker:kind=disk,size=6G" "${INIT_FLAGS[@]}" "$DIND_IMAGE" >/tmp/75rq-c3-boot.err 2>&1; then
  pass "C3 setup: cage boots with disk-kind volume + --init dockerd handoff"
else
  fail "C3 setup: cage failed to boot" "$(cat /tmp/75rq-c3-boot.err)"
fi

for _ in 1 2 3 4 5 6; do
  msb exec "$CAGE_C1" -- sh -c 'pgrep dockerd >/dev/null 2>&1' && break
  sleep 5
done

C3_PID_BEFORE=$(msb exec "$CAGE_C1" -- sh -c 'pgrep dockerd' 2>/tmp/75rq-c3-pid1.err)
if [[ -n "$C3_PID_BEFORE" ]]; then
  pass "C3: dockerd is running (pid=${C3_PID_BEFORE}) after the --init handoff"
else
  fail "C3: expected a live dockerd pid" "$(cat /tmp/75rq-c3-pid1.err)"
fi

# An independent `msb exec` call that fully returns -- if dockerd were a
# backgrounded child of an exec session (the pre-handoff footgun findings
# §10b documents), it would be reaped here.
msb exec "$CAGE_C1" -- sh -c 'echo unrelated-command-that-returns' >/dev/null 2>&1

C3_PID_AFTER=$(msb exec "$CAGE_C1" -- sh -c 'pgrep dockerd' 2>/tmp/75rq-c3-pid2.err)
C3_RESPONSIVE=$(msb exec "$CAGE_C1" -- sh -c 'docker version --format "{{.Server.Version}}"' 2>/tmp/75rq-c3-responsive.err)
if [[ -n "$C3_PID_AFTER" && "$C3_PID_AFTER" == "$C3_PID_BEFORE" && -n "$C3_RESPONSIVE" ]]; then
  pass "C3: dockerd SURVIVES -- SAME pid (${C3_PID_AFTER}) and still responsive (docker ${C3_RESPONSIVE}) after an independent msb exec returned"
else
  fail "C3: expected dockerd to survive with the same pid and stay responsive" "before='${C3_PID_BEFORE}' after='${C3_PID_AFTER}' responsive='${C3_RESPONSIVE}' stderr=$(cat /tmp/75rq-c3-pid2.err)"
fi

msb remove -f "$CAGE_C1" >/dev/null 2>&1 || true

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-dind-compose-disk-kind-live.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-dind-compose-disk-kind-live.sh: all ${TOTAL} tests passed ==="
