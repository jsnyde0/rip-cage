#!/usr/bin/env bash
# test-boot-descriptor.sh -- the boot descriptor's contract, proven in a live cage.
#
# WHY THIS FILE EXISTS. The tools manifest retired whole (ADR-031 D4) and took
# about 12,000 lines of tests with it. One small declarative file replaced it:
# /etc/rip-cage/boot.json, read by init's three generic loops. Almost all of the
# deleted corpus tested a SCHEMA VALIDATOR -- a check on a description. This
# file deliberately does not do that. It tests the two things that are actually
# load-bearing, against a built image and a booting cage, which is the point of
# ADR-031 D5(b)'s "check the artifact, not the declaration":
#
#   B1  a daemon declared in the descriptor STARTS and PASSES ITS HEALTH CHECK
#       in a live cage, and a second init is a true no-op (same pid), not a
#       kill-and-restart.
#   B2  a descriptor entry missing a required field makes init EXIT NON-ZERO and
#       NAME THE FIELD. This is the deliberate behaviour CHANGE from the
#       manifest era, where the loop warned and skipped: a cage that silently
#       lacks the daemon it was built for is worse than one that refuses to boot.
#
# Tier: NEEDS_CONTAINER. Self-skips when docker or msb is absent, or when there
# is no rip-cage:latest to extend.
#
# SCRATCH-TAG DISCIPLINE (rip-cage-ely4.11 dispatch constraint): this builds its
# own images under scratch tags and NEVER rebuilds or msb-loads rip-cage:latest.
# ONE cage is up at a time; each is destroyed before the next is created.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

if ! command -v docker >/dev/null 2>&1 || ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: docker and msb are both required for the boot-descriptor contract (NEEDS_CONTAINER)."
  exit 0
fi
if ! docker image inspect "${RC_BOOTDESC_BASE_TAG:-rip-cage:latest}" >/dev/null 2>&1; then
  echo "SKIP: no ${RC_BOOTDESC_BASE_TAG:-rip-cage:latest} to extend -- run 'rc build' first (NEEDS_CONTAINER)."
  exit 0
fi
# The base image must itself predate nothing: an image built before the boot
# descriptor landed carries no rc-boot-merge, so every case below would fail on
# the fixture rather than on the contract. Skip loudly, naming the fix -- a red
# suite that means "your local image is old" teaches people to ignore red.
if ! docker run --rm --entrypoint sh "${RC_BOOTDESC_BASE_TAG:-rip-cage:latest}" \
     -c 'command -v rc-boot-merge' >/dev/null 2>&1; then
  echo "SKIP: ${RC_BOOTDESC_BASE_TAG:-rip-cage:latest} predates the boot descriptor (no rc-boot-merge in it)."
  echo "      Rebuild it with 'rc build', or point this at a scratch base: RC_BOOTDESC_BASE_TAG=<tag> bash $0"
  exit 0
fi

# The image under test is rip-cage:latest by default. RC_BOOTDESC_BASE_TAG
# points this at a scratch base tag instead, which is how the descriptor gets
# proven BEFORE the human decides to rebuild rip-cage:latest itself.
BASE_TAG="${RC_BOOTDESC_BASE_TAG:-rip-cage:latest}"
WORK=$(mktemp -d)
BUILT_TAGS=()
LIVE_CAGE=""

cleanup() {
  [[ -n "$LIVE_CAGE" ]] && "$RC" destroy "$LIVE_CAGE" >/dev/null 2>&1
  # Both stores, not just docker. build_extension loads every scratch tag into
  # msb's own cache as well, and msb keeps it independently -- a docker-only
  # cleanup left rip-cage-x-bootdesc:1 and -bad:1 behind on every run (the
  # human cleaned them by hand four times before this line existed).
  if [[ "${#BUILT_TAGS[@]}" -gt 0 ]]; then
    docker image rm -f "${BUILT_TAGS[@]}" >/dev/null 2>&1
    msb image remove -f "${BUILT_TAGS[@]}" >/dev/null 2>&1
  fi
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT INT TERM

# build_extension <slug> <tag> -- build $WORK/<slug>/Dockerfile under <tag> and
# load it into msb's cache. Echoes nothing; returns non-zero on any failure.
build_extension() {
  local _slug="$1" _tag="$2"
  BUILT_TAGS+=("$_tag")
  RC_IMAGE="$_tag" "$RC" build --file "${WORK}/${_slug}/Dockerfile" >"${WORK}/${_slug}-build.log" 2>&1 || return 1
  docker save "$_tag" -o "${WORK}/${_slug}.tar" >/dev/null 2>&1 || return 1
  msb load --tag "$_tag" -i "${WORK}/${_slug}.tar" >/dev/null 2>&1 || return 1
  rm -f "${WORK}/${_slug}.tar"
  return 0
}

# boot_cage <slug> <tag> -- create a scratch project, launch a cage on <tag>,
# and leave the whole boot transcript in $WORK/<slug>-up.log. Sets LIVE_CAGE.
# Returns rc up's own exit status.
boot_cage() {
  local _slug="$1" _tag="$2"
  local _proj="${WORK}/${_slug}-proj"
  mkdir -p "$_proj"
  local _conf
  _conf=$(cage_conf_for "$_proj" "$_tag")
  LIVE_CAGE="$(basename "$(dirname "$_proj")")-$(basename "$_proj")"
  scratch_cage_register "$LIVE_CAGE"
  RC_CAGE_CONF="$_conf" "$RC" up "$_proj" </dev/null >"${WORK}/${_slug}-up.log" 2>&1
}

drop_cage() {
  [[ -n "$LIVE_CAGE" ]] && "$RC" destroy "$LIVE_CAGE" >/dev/null 2>&1
  LIVE_CAGE=""
  return 0
}

# --------------------------------------------------------------------------
echo "=== B1: a descriptor daemon starts and health-checks in a live cage ==="
# A daemon that needs nothing installed: a listener on a port, with a health
# check that actually connects to it. `exec` in front of the real server is the
# PID-identity rule the descriptor's own header states -- without it, init
# records the wrapper's pid instead of the daemon's.
mkdir -p "$WORK/ok"
cat > "$WORK/ok/boot-fragment.json" <<'FRAG'
{
  "daemons": [
    {
      "name": "probe",
      "start": "exec python3 -m http.server 8731 --directory /tmp",
      "health": "python3 -c \"import socket; socket.create_connection(('127.0.0.1',8731),2).close()\"",
      "state_dir": "/tmp/rip-cage-probe"
    }
  ]
}
FRAG
cat > "$WORK/ok/Dockerfile" <<DOCKER
FROM ${BASE_TAG}
USER root
COPY boot-fragment.json /tmp/boot-fragment.json
RUN rc-boot-merge /tmp/boot-fragment.json && rm /tmp/boot-fragment.json
USER agent
DOCKER

OK_TAG="rip-cage-x-bootdesc:1"
if ! build_extension ok "$OK_TAG"; then
  fail "building/loading the extension image failed"
  tail -20 "$WORK/ok-build.log" >&2
else
  pass "rc build --file built the extension image under a scratch tag"

  # Read the descriptor back OUT OF THE IMAGE rather than trusting the fragment
  # we wrote -- the artifact is the thing under test.
  MERGED=$(docker run --rm --entrypoint sh "$OK_TAG" -c 'cat /etc/rip-cage/boot.json' 2>/dev/null)
  jq -e '(.daemons // []) | any(.name == "probe")' <<<"$MERGED" >/dev/null 2>&1 \
    && pass "rc-boot-merge landed the daemon in the image's descriptor" \
    || fail "the merged descriptor in the image carries no 'probe' daemon"
  jq -e '(.tools // []) | any(.name == "claude")' <<<"$MERGED" >/dev/null 2>&1 \
    && pass "the merge preserved the base image's own tools[] entries" \
    || fail "the merge dropped the base descriptor's tools[] -- a fragment must ADD, not replace"

  boot_cage ok "$OK_TAG"
  if grep -q "Initialization complete" "$WORK/ok-up.log"; then
    pass "the cage booted on the extension image"
  else
    fail "the cage did not reach 'Initialization complete'"
    tail -25 "$WORK/ok-up.log" >&2
  fi

  if grep -q "daemon 'probe' health OK" "$WORK/ok-up.log"; then
    pass "the descriptor daemon started AND passed its own health check"
  else
    fail "no \"daemon 'probe' health OK\" line in the boot log -- the loop did not run it"
    grep -i "daemon\|ERROR" "$WORK/ok-up.log" | tail -10 >&2
  fi

  PID1=$(msb exec "$LIVE_CAGE" -- cat /tmp/rip-cage-daemon-probe.pid 2>/dev/null | tr -d '[:space:]')
  msb exec "$LIVE_CAGE" -- /usr/local/bin/init-rip-cage.sh >"$WORK/ok-init2.log" 2>&1
  PID2=$(msb exec "$LIVE_CAGE" -- cat /tmp/rip-cage-daemon-probe.pid 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$PID1" && "$PID1" == "$PID2" ]]; then
    pass "a second init left the daemon's pid unchanged (a true no-op, not kill-and-restart)"
  else
    fail "the daemon's pid changed across a second init (${PID1:-none} -> ${PID2:-none})"
  fi

  drop_cage
fi

# --------------------------------------------------------------------------
echo ""
echo "=== B2: a descriptor missing a required field makes init exit non-zero, naming it ==="
# 'start' is omitted on purpose.
mkdir -p "$WORK/bad"
cat > "$WORK/bad/boot-fragment.json" <<'FRAG'
{
  "daemons": [
    { "name": "noStart", "health": "true", "state_dir": "/tmp/rip-cage-nostart" }
  ]
}
FRAG
cat > "$WORK/bad/Dockerfile" <<DOCKER
FROM ${BASE_TAG}
USER root
COPY boot-fragment.json /tmp/boot-fragment.json
RUN rc-boot-merge /tmp/boot-fragment.json && rm /tmp/boot-fragment.json
USER agent
DOCKER

BAD_TAG="rip-cage-x-bootdesc-bad:1"
if ! build_extension bad "$BAD_TAG"; then
  fail "building/loading the malformed-descriptor image failed"
  tail -20 "$WORK/bad-build.log" >&2
else
  boot_cage bad "$BAD_TAG"
  # The cage is created -- this is init failing, not rc refusing -- so run init
  # itself and read its own exit status, which is the contract under test.
  msb exec "$LIVE_CAGE" -- /usr/local/bin/init-rip-cage.sh >"$WORK/bad-init.log" 2>&1
  BAD_RC=$?
  if [[ "$BAD_RC" -ne 0 ]]; then
    pass "init exited non-zero on the missing required field"
  else
    fail "init exited 0 with a daemon declaration missing 'start' -- it must fail the boot"
  fi
  if grep -q "missing required field 'start'" "$WORK/bad-init.log"; then
    pass "init named the missing field"
  else
    fail "init's message did not name the missing field"
    tail -10 "$WORK/bad-init.log" >&2
  fi
  if grep -q "daemons\[0\]" "$WORK/bad-init.log"; then
    pass "init named the offending entry"
  else
    fail "init's message did not identify which entry was wrong"
  fi
  # A NEGATIVE CONTROL for the pair above: without it, an init that died of
  # something unrelated would satisfy the non-zero assertion vacuously.
  if grep -q "boot descriptor" "$WORK/bad-init.log"; then
    pass "the failure came from the descriptor check, not from something else in init"
  else
    fail "init failed for a reason that never named the boot descriptor -- the assertion above is vacuous"
  fi

  drop_cage
fi

echo ""
echo "=== test-boot-descriptor.sh: ${FAILURES} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
