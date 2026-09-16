#!/usr/bin/env bash
# test-floor-probe.sh -- the fail-closed floor probe's contract, proven against
# real built images and real booting cages (rip-cage-ely4.12, rip-cage-ely4.15).
#
# WHY THE NEGATIVE CASES ARE THE POINT. The probe replaced a declaration
# validator (ADR-005 D11) that could not see a `USER root` an extension
# Dockerfile ends with. A suite that only booted a good image would prove the
# probe was *deleted*, not that it *replaced* anything. So two of the three
# cases below build a DELIBERATELY BROKEN extension image and require the boot
# to fail, naming the property:
#
#   F1  the stock base boots to the agent shell, the probe's own PASS lines are
#       in the boot transcript, `rc test` reports every floor line green, and
#       nothing else `rc test` reports is red except three known checks that
#       are not image properties (rip-cage-ely4.7.5, rip-cage-ely4.7.6 -- see
#       the comment at that assertion).
#   F2  an extension ending `USER root` fails init with FAIL: floor: runtime-user.
#       (Today, without the probe, this boots SILENTLY -- measured,
#       rip-cage-ely4.16 Q2.)
#   F3  a `chmod o+w` on a root-owned guard file fails init with
#       FAIL: floor: guard-file <path>. This case IS rip-cage-ely4.15's test:
#       the old check asserted owner and never mode bits, so a root-owned but
#       world-writable guard passed.
#
# Each negative case also carries a NEGATIVE CONTROL: an init that died of
# something unrelated would satisfy "exited non-zero" vacuously, so the
# assertions require the probe's own refusal line too.
#
# Tier: NEEDS_CONTAINER. Self-skips when docker or msb is absent, or when the
# base image predates the probe.
#
# SCRATCH-TAG DISCIPLINE: builds only under scratch tags and NEVER rebuilds or
# msb-loads rip-cage:latest. ONE cage is up at a time; each is destroyed before
# the next is created.
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
  echo "SKIP: docker and msb are both required for the floor-probe contract (NEEDS_CONTAINER)."
  exit 0
fi

# The image under test defaults to rip-cage:latest. RC_FLOORPROBE_BASE_TAG points
# this at a scratch base instead, which is how the probe gets proven BEFORE the
# human decides to rebuild rip-cage:latest itself.
BASE_TAG="${RC_FLOORPROBE_BASE_TAG:-rip-cage:latest}"

if ! docker image inspect "$BASE_TAG" >/dev/null 2>&1; then
  echo "SKIP: no ${BASE_TAG} to extend -- run 'rc build' first (NEEDS_CONTAINER)."
  exit 0
fi
# An image built before the probe landed carries no probe, so every case below
# would fail on the fixture rather than on the contract. Skip loudly, naming the
# fix -- a red suite that means "your local image is old" teaches people to
# ignore red.
if ! docker run --rm --entrypoint sh "$BASE_TAG" \
     -c 'test -x /usr/local/lib/rip-cage/floor-probe.sh' >/dev/null 2>&1; then
  echo "SKIP: ${BASE_TAG} predates the floor probe (no /usr/local/lib/rip-cage/floor-probe.sh in it)."
  echo "      Rebuild it with 'rc build', or point this at a scratch base: RC_FLOORPROBE_BASE_TAG=<tag> bash $0"
  exit 0
fi

WORK=$(mktemp -d)
BUILT_TAGS=()
LIVE_CAGE=""

cleanup() {
  [[ -n "$LIVE_CAGE" ]] && "$RC" destroy "$LIVE_CAGE" >/dev/null 2>&1
  if [[ "${#BUILT_TAGS[@]}" -gt 0 ]]; then
    for _t in "${BUILT_TAGS[@]}"; do
      msb image remove -f "$_t" >/dev/null 2>&1
    done
    docker image rm -f "${BUILT_TAGS[@]}" >/dev/null 2>&1
  fi
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT INT TERM

# build_extension <slug> <tag> -- build $WORK/<slug>/Dockerfile under <tag> and
# load it into msb's cache. Returns non-zero on any failure.
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
# leave the whole boot transcript in $WORK/<slug>-up.log. Sets LIVE_CAGE and
# UP_RC to `rc up`'s own exit status, which is the contract under test: init
# failing must make `rc up` fail.
UP_RC=0
boot_cage() {
  local _slug="$1" _tag="$2"
  local _proj="${WORK}/${_slug}-proj"
  mkdir -p "$_proj"
  local _conf
  _conf=$(cage_conf_for "$_proj" "$_tag")
  LIVE_CAGE="$(basename "$(dirname "$_proj")")-$(basename "$_proj")"
  scratch_cage_register "$LIVE_CAGE"
  UP_RC=0
  RC_CAGE_CONF="$_conf" "$RC" up "$_proj" </dev/null >"${WORK}/${_slug}-up.log" 2>&1 || UP_RC=$?
}

drop_cage() {
  [[ -n "$LIVE_CAGE" ]] && "$RC" destroy "$LIVE_CAGE" >/dev/null 2>&1
  LIVE_CAGE=""
  return 0
}

# --------------------------------------------------------------------------
echo "=== F1: the stock base boots, and its floor lines are green ==="
mkdir -p "$WORK/stock-proj"
STOCK_CONF=$(cage_conf_for "$WORK/stock-proj" "$BASE_TAG")
# The shared fixture allows one host. `rc test` also resolves github.com, and
# under msb's DNS default-deny an unlisted host does not resolve — so without
# this line F1 would report a red `rc test` that says nothing about the image.
echo '    - "github.com:tcp:443"' >> "$STOCK_CONF"
STOCK_CAGE="$(basename "$(dirname "$WORK/stock-proj")")-stock-proj"
scratch_cage_register "$STOCK_CAGE"
LIVE_CAGE="$STOCK_CAGE"
STOCK_RC=0
RC_CAGE_CONF="$STOCK_CONF" "$RC" up "$WORK/stock-proj" </dev/null >"${WORK}/stock-up.log" 2>&1 || STOCK_RC=$?

if [[ "$STOCK_RC" -eq 0 ]]; then
  pass "rc up exited 0 on the stock base"
else
  fail "rc up exited ${STOCK_RC} on the stock base -- the probe rejects a good image"
  grep -E '^FAIL' "${WORK}/stock-up.log" >&2 || tail -25 "${WORK}/stock-up.log" >&2
fi
if grep -q "Initialization complete" "${WORK}/stock-up.log"; then
  pass "the cage reached the agent shell"
else
  fail "the cage did not reach 'Initialization complete'"
  tail -25 "${WORK}/stock-up.log" >&2
fi
if grep -q "Rip Cage floor probe" "${WORK}/stock-up.log"; then
  pass "the probe ran at boot (its banner is in the transcript)"
else
  fail "no floor-probe banner in the boot transcript -- init did not run it"
fi
# It must run FIRST: the probe's banner has to precede init's own first
# side-effecting log line, or "fail-closed at boot" is only nominally true.
PROBE_LINE=$(grep -n "Rip Cage floor probe" "${WORK}/stock-up.log" | head -1 | cut -d: -f1)
BEADS_LINE=$(grep -n "\[rip-cage\] Beads:" "${WORK}/stock-up.log" | head -1 | cut -d: -f1)
if [[ -n "$PROBE_LINE" && -n "$BEADS_LINE" && "$PROBE_LINE" -lt "$BEADS_LINE" ]]; then
  pass "the probe ran before init's first side-effecting section"
else
  fail "the probe did not run first (probe line=${PROBE_LINE:-none}, first init section=${BEADS_LINE:-none})"
fi
if ! grep -qE '^FAIL' "${WORK}/stock-up.log"; then
  pass "no FAIL line anywhere in the stock boot transcript"
else
  fail "the stock boot transcript carries a FAIL line"
  grep -E '^FAIL' "${WORK}/stock-up.log" >&2
fi

# `rc test` must report the SAME floor lines. Read them out of the JSON branch,
# which is the machine-readable contract; a floor check that is missing there is
# a floor check `rc test` silently stopped reporting.
RC_TEST_JSON=$("$RC" test "$STOCK_CAGE" --output json 2>/dev/null)
FLOOR_TOTAL=$(jq '[.checks[] | select(.name | startswith("floor: "))] | length' <<<"$RC_TEST_JSON" 2>/dev/null || echo 0)
FLOOR_FAILED=$(jq -r '[.checks[] | select(.name | startswith("floor: ")) | select(.status == "fail") | .name] | join("; ")' <<<"$RC_TEST_JSON" 2>/dev/null || echo "")
if [[ "${FLOOR_TOTAL:-0}" -ge 10 ]]; then
  pass "rc test reported ${FLOOR_TOTAL} floor lines"
else
  fail "rc test reported only ${FLOOR_TOTAL:-0} floor lines -- the probe is not wired into rc test"
fi
if [[ -z "$FLOOR_FAILED" ]]; then
  pass "every floor line rc test reported is green"
else
  fail "rc test reported failing floor lines: ${FLOOR_FAILED}"
fi
# Everything ELSE `rc test` reports must be green too, with three named
# exceptions, none of which is a property of the IMAGE this case is about:
#
#   Cage topology section / At least one skill present -- both assert an artifact
#     a COMPOSED RECIPE or the host provides (the topology block comes from
#     examples/claude; the skills come from the host's own ~/.claude/skills), so
#     a MINIMAL cage legitimately has neither and both hard-fail on it anyway.
#     That mis-tiering is rip-cage-ely4.7.5.
#   DNS resolution (github.com) -- red even with `github.com:tcp:443` listed in
#     this cage's own allow list (the line appended above). Whether that is the
#     wrong allow FORM or a real gap is an open question, spiked by
#     rip-cage-ely4.7.6; it is not something the floor probe can answer.
#
# The assertion is deliberately "nothing OUTSIDE this set fails", not "these
# three fail": a NEW red still fails this case, and the day those beads land and
# these go green, this check stays green with no edit.
KNOWN_MINIMAL_CAGE_REDS='Cage topology section present (exactly one marker pair)
At least one skill present
DNS resolution (github.com)'
UNEXPECTED_REDS=$(jq -r '.checks[] | select(.status == "fail") | .name' <<<"$RC_TEST_JSON" 2>/dev/null \
  | grep -vxF "$KNOWN_MINIMAL_CAGE_REDS" || true)
RC_TEST_OVERALL=$(jq -r '.overall // "?"' <<<"$RC_TEST_JSON" 2>/dev/null || echo "?")
if [[ -z "$UNEXPECTED_REDS" ]]; then
  pass "rc test reports no failure outside the three known non-image checks (overall='${RC_TEST_OVERALL}')"
else
  fail "rc test reports failures beyond the known non-image set"
  jq -r '.checks[] | select(.status == "fail") | "    " + .name + " — " + .detail' <<<"$RC_TEST_JSON" >&2 2>/dev/null
fi

drop_cage

# --------------------------------------------------------------------------
echo ""
echo "=== F2: an extension ending USER root refuses to boot, naming runtime-user ==="
mkdir -p "$WORK/asroot"
cat > "$WORK/asroot/Dockerfile" <<DOCKER
FROM ${BASE_TAG}
USER root
DOCKER

ASROOT_TAG="rip-cage-x-floor-asroot:1"
if ! build_extension asroot "$ASROOT_TAG"; then
  fail "building/loading the USER-root extension image failed"
  tail -20 "$WORK/asroot-build.log" >&2
else
  boot_cage asroot "$ASROOT_TAG"
  if [[ "$UP_RC" -ne 0 ]]; then
    pass "rc up exited ${UP_RC} (non-zero) on the USER-root image"
  else
    fail "rc up exited 0 on an image that ends USER root -- it booted silently, which is the bug the probe exists to close"
  fi
  if grep -q '^FAIL: floor: runtime-user' "$WORK/asroot-up.log"; then
    pass "the transcript carries FAIL: floor: runtime-user"
    grep '^FAIL: floor: runtime-user' "$WORK/asroot-up.log" | head -1 | sed 's/^/    /'
  else
    fail "no 'FAIL: floor: runtime-user' line in the transcript"
    grep -E '^FAIL' "$WORK/asroot-up.log" >&2 | head -5
  fi
  # Named-damage assertion: runtime-user alone says "you are root"; agent-home
  # is the line that says WHAT that costs, and rip-cage-ely4.16 Q2 is the reason
  # it exists. Both must fire on this image.
  if grep -q '^FAIL: floor: agent-home' "$WORK/asroot-up.log"; then
    pass "the transcript also carries FAIL: floor: agent-home (the stranded-mounts damage, named)"
  else
    fail "no 'FAIL: floor: agent-home' line -- the probe named the wrong user but not the stranded mounts"
  fi
  # NEGATIVE CONTROL: without this, an init that died of anything at all would
  # satisfy the non-zero assertion above.
  if grep -q "Refusing to start the agent shell" "$WORK/asroot-up.log"; then
    pass "the refusal came from the floor probe, not from something else in init"
  else
    fail "init failed without the probe's refusal line -- the assertions above are vacuous"
    tail -15 "$WORK/asroot-up.log" >&2
  fi
  # Fail-CLOSED, not fail-late: init must not have gone on to do its work.
  if ! grep -q "Initialization complete" "$WORK/asroot-up.log"; then
    pass "init never reached 'Initialization complete' -- it refused, it did not warn"
  else
    fail "init completed anyway -- the probe warned instead of refusing"
  fi

  drop_cage
fi

# --------------------------------------------------------------------------
echo ""
echo "=== F3: a group/other-writable root-owned guard refuses to boot (rip-cage-ely4.15) ==="
# /etc/rip-cage/boot.json is the guard chosen deliberately: root:root 0444 in the
# base image, and it declares what STARTS inside the cage, so an agent that could
# write it could start whatever it liked. chmod o+w leaves it root-OWNED -- which
# is exactly the case the old owner-only check passed.
mkdir -p "$WORK/guardmode"
cat > "$WORK/guardmode/Dockerfile" <<DOCKER
FROM ${BASE_TAG}
USER root
RUN chmod o+w /etc/rip-cage/boot.json
USER agent
DOCKER

GUARD_TAG="rip-cage-x-floor-guardmode:1"
if ! build_extension guardmode "$GUARD_TAG"; then
  fail "building/loading the chmod-o+w extension image failed"
  tail -20 "$WORK/guardmode-build.log" >&2
else
  # Prove the fixture is the case we mean: root-owned AND world-writable. A
  # fixture that also flipped ownership would make F3 pass for the wrong reason.
  FIXTURE_STAT=$(docker run --rm --entrypoint sh "$GUARD_TAG" \
    -c 'stat -c "%U:%G %a" /etc/rip-cage/boot.json' 2>/dev/null)
  if [[ "$FIXTURE_STAT" == "root:root 446" ]]; then
    pass "the fixture guard file is root-owned AND other-writable (${FIXTURE_STAT})"
  else
    fail "the fixture guard file is '${FIXTURE_STAT}', not 'root:root 446' -- F3 would prove the wrong thing"
  fi

  boot_cage guardmode "$GUARD_TAG"
  if [[ "$UP_RC" -ne 0 ]]; then
    pass "rc up exited ${UP_RC} (non-zero) on the world-writable-guard image"
  else
    fail "rc up exited 0 with a root-owned but world-writable guard file -- rip-cage-ely4.15 is still open"
  fi
  if grep -q '^FAIL: floor: guard-file /etc/rip-cage/boot.json' "$WORK/guardmode-up.log"; then
    pass "the transcript names the guard file"
    grep '^FAIL: floor: guard-file /etc/rip-cage/boot.json' "$WORK/guardmode-up.log" | head -1 | sed 's/^/    /'
  else
    fail "no 'FAIL: floor: guard-file /etc/rip-cage/boot.json' line in the transcript"
    grep -E '^FAIL' "$WORK/guardmode-up.log" >&2 | head -5
  fi
  # The mode bits, not just the path: ely4.15's whole point is that the message
  # has to say WHICH property failed, because owner was already green.
  if grep '^FAIL: floor: guard-file /etc/rip-cage/boot.json' "$WORK/guardmode-up.log" \
     | grep -q 'mode 0446 is group/other-writable'; then
    pass "the message names the mode bits and the property"
  else
    fail "the message did not name the mode -- it reads as an ownership failure, which this is not"
  fi
  if grep -q "Refusing to start the agent shell" "$WORK/guardmode-up.log"; then
    pass "the refusal came from the floor probe, not from something else in init"
  else
    fail "init failed without the probe's refusal line -- the assertions above are vacuous"
    tail -15 "$WORK/guardmode-up.log" >&2
  fi
  if ! grep -q "Initialization complete" "$WORK/guardmode-up.log"; then
    pass "init never reached 'Initialization complete'"
  else
    fail "init completed anyway -- the probe warned instead of refusing"
  fi

  drop_cage
fi

echo ""
echo "=== test-floor-probe.sh: ${FAILURES} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
