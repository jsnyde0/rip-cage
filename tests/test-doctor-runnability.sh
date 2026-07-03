#!/usr/bin/env bash
# test-doctor-runnability.sh — live-cage checks for `rc doctor`'s runnability
# probes (rip-cage-2cks): cwd floor (guards rip-cage-0rng), workspace
# resolution (guards rip-cage-aq70), bd version skew.
#
# NEEDS_CONTAINER: spins real cages via `rc up` + `docker run`. Self-skips
# (SKIP, exit 0) when docker or host `bd` is unavailable.
#
# Coverage:
#   D1  correct fresh cage: cwd probe is OK, workspace-resolution probe is OK
#       (bd status + git status both clean), bd-version-skew probe is not FAIL
#   D2  cage with WorkingDir forced to /home/agent: cwd probe FAILS loud
#   D3  cage whose baked bd schema-errors reading a host-1.0.5-written store
#       (the honest rip-cage-aq70 symptom): workspace-resolution probe FAILS
#       -- GATED behind RC_DOCTOR_STALE_BD_IMAGE (see note below); SKIPs
#       visibly when unset, never silently green.
#
# Judgment call (rip-cage-2cks review note): D3 needs a SECOND rip-cage image
# baked with an older bd than the host's, so a bind-mounted host-written
# store schema-errors inside it. There is no stable, CI-portable artifact for
# "an older bd release baked into a full rip-cage image" -- building one from
# scratch is a ~15min multi-stage image build, and a manually retagged
# dangling image (the fixture used to hand-verify this bead) does not
# survive past the implementing session. Rather than fake a fixture or skip
# the assertion entirely, D3 is wired for real but gated behind an env var
# naming a pre-built stale-bd image; set it locally (or in a longer-lived CI
# lane that keeps such an image around) to exercise it. See the bead's
# report for the real command + output captured against
# rip-cage:aq70-old-fixture during implementation.
set -uo pipefail

if ! command -v docker > /dev/null 2>&1; then
  echo "SKIP: Docker not available -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v bd > /dev/null 2>&1; then
  echo "SKIP: host bd not available -- skipping $(basename "$0") (fixtures need a real beads store)"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

DOCTOR_TMP=$(mktemp -d)
DOCTOR_TMP=$(realpath "$DOCTOR_TMP")
mkdir -p "${DOCTOR_TMP}/rc-doctor"
export RC_ALLOWED_ROOTS="${DOCTOR_TMP}"

trap 'rm -rf "$DOCTOR_TMP"' EXIT

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"

echo "=== test-doctor-runnability.sh ==="
echo "DOCTOR_TMP=${DOCTOR_TMP}"
echo ""

# ---------------------------------------------------------------------------
# Fixture: a git+beads workspace, written by the HOST's bd. Reused by both
# the correct cage (D1) and the schema-error cage (D3) -- same store, two
# different bd binaries reading it.
# ---------------------------------------------------------------------------
FIXTURE_WS="${DOCTOR_TMP}/rc-doctor/correct"
mkdir -p "$FIXTURE_WS"
git -C "$FIXTURE_WS" init -q
git -C "$FIXTURE_WS" config user.email "doctor-test@example.com"
git -C "$FIXTURE_WS" config user.name "doctor-test"
git -C "$FIXTURE_WS" commit --allow-empty -q -m "init"
(cd "$FIXTURE_WS" && bd init --non-interactive > /dev/null 2>&1)

# ---------------------------------------------------------------------------
# D1: correct fresh cage -- all three probes green (or WARN-at-worst for the
# version probe, never FAIL).
# ---------------------------------------------------------------------------
echo "-- D1: correct fresh cage --"

UP_OUT=$("$RC" up "$FIXTURE_WS" 2>&1) || { echo "$UP_OUT"; fail "D1 rc up succeeds" "rc up exited non-zero"; }
CORRECT_CAGE=$(echo "$UP_OUT" | grep -oE 'Container [^ ]+ is running' | awk '{print $2}' | head -1)
if [[ -z "$CORRECT_CAGE" ]]; then
  fail "D1 determine correct-cage container name" "could not parse from: $UP_OUT"
else
  scratch_cage_register "$CORRECT_CAGE"
  D1_JSON=$("$RC" --output json doctor "$CORRECT_CAGE" 2>&1) || true

  d1_cwd=$(echo "$D1_JSON" | jq -r '.probes.cwd // empty' 2>/dev/null)
  if [[ "$d1_cwd" == OK* ]]; then
    pass "D1 cwd probe OK on correct cage ($d1_cwd)"
  else
    fail "D1 cwd probe OK on correct cage" "got: $d1_cwd"
  fi

  d1_ws=$(echo "$D1_JSON" | jq -r '.probes.workspace_resolution // empty' 2>/dev/null)
  if [[ "$d1_ws" == OK* ]]; then
    pass "D1 workspace-resolution probe OK on correct cage ($d1_ws)"
  else
    fail "D1 workspace-resolution probe OK on correct cage" "got: $d1_ws"
  fi

  d1_ver=$(echo "$D1_JSON" | jq -r '.probes.bd_version_skew // empty' 2>/dev/null)
  if [[ "$d1_ver" != FAIL* ]]; then
    pass "D1 bd-version-skew probe is not FAIL on correct cage ($d1_ver)"
  else
    fail "D1 bd-version-skew probe is not FAIL on correct cage" "got: $d1_ver"
  fi
fi

# ---------------------------------------------------------------------------
# D2: WorkingDir forced to /home/agent -- cwd probe FAILS loud.
# Reuses the same rip-cage:latest image + fixture workspace as D1, but bypasses
# `rc up` to force the broken WorkingDir directly (mirrors the bead's fixture
# recipe: a container from the image with WorkingDir overridden).
# ---------------------------------------------------------------------------
echo ""
echo "-- D2: cwd forced to /home/agent --"

CWD_BROKEN_CAGE="rc-doctor-cwdbroken-$$"
docker rm -f "$CWD_BROKEN_CAGE" > /dev/null 2>&1 || true
if docker run -d --name "$CWD_BROKEN_CAGE" \
    --label "rc.source.path=${FIXTURE_WS}" \
    --workdir /home/agent \
    -v "${FIXTURE_WS}:/workspace" \
    rip-cage:latest sleep infinity > /dev/null 2>&1; then
  scratch_cage_register "$CWD_BROKEN_CAGE"
  D2_JSON=$("$RC" --output json doctor "$CWD_BROKEN_CAGE" 2>&1) || true
  d2_cwd=$(echo "$D2_JSON" | jq -r '.probes.cwd // empty' 2>/dev/null)
  if [[ "$d2_cwd" == FAIL* ]]; then
    pass "D2 cwd probe FAILS loud on /home/agent-workdir cage ($d2_cwd)"
  else
    fail "D2 cwd probe FAILS loud on /home/agent-workdir cage" "got: $d2_cwd"
  fi
else
  fail "D2 create cwd-broken cage" "docker run failed (is rip-cage:latest built?)"
fi

# ---------------------------------------------------------------------------
# D3: baked bd schema-errors reading a host-1.0.5-written store (rip-cage-aq70
# symptom) -- workspace-resolution probe FAILS. GATED (see file header).
# ---------------------------------------------------------------------------
echo ""
echo "-- D3: stale-bd schema-error cage (gated) --"

if [[ -n "${RC_DOCTOR_STALE_BD_IMAGE:-}" ]] && docker image inspect "$RC_DOCTOR_STALE_BD_IMAGE" > /dev/null 2>&1; then
  SCHEMA_ERR_CAGE="rc-doctor-schemaerr-$$"
  docker rm -f "$SCHEMA_ERR_CAGE" > /dev/null 2>&1 || true
  if docker run -d --name "$SCHEMA_ERR_CAGE" \
      --label "rc.source.path=${FIXTURE_WS}" \
      --workdir /workspace \
      -v "${FIXTURE_WS}:/workspace" \
      "$RC_DOCTOR_STALE_BD_IMAGE" sleep infinity > /dev/null 2>&1; then
    scratch_cage_register "$SCHEMA_ERR_CAGE"
    D3_JSON=$("$RC" --output json doctor "$SCHEMA_ERR_CAGE" 2>&1) || true
    d3_ws=$(echo "$D3_JSON" | jq -r '.probes.workspace_resolution // empty' 2>/dev/null)
    if [[ "$d3_ws" == FAIL* ]]; then
      pass "D3 workspace-resolution probe FAILS on stale-bd schema-error cage ($d3_ws)"
    else
      fail "D3 workspace-resolution probe FAILS on stale-bd schema-error cage" "got: $d3_ws"
    fi
  else
    fail "D3 create schema-error cage" "docker run failed against \$RC_DOCTOR_STALE_BD_IMAGE"
  fi
else
  echo "SKIP: RC_DOCTOR_STALE_BD_IMAGE not set (or image absent) -- schema-error live fixture not exercised (see file header)"
fi

echo ""
echo "=== doctor-runnability tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
