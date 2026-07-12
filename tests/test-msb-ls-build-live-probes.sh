#!/usr/bin/env bash
# tests/test-msb-ls-build-live-probes.sh -- LIVE effect-based proof for bead
# rip-cage-tsf2.1 criterion 3: "cli/build.sh + cli/ls.sh live-probe paths ...
# operate against msb cages (no docker-only assumption on the msb path)."
#
# Drives the REAL `rc up` + `rc ls` verbs, and the REAL
# `_build_warn_stale_containers` function (cli/build.sh's live-probe path,
# invoked internally by `cmd_build` after every successful build -- this
# test calls it directly with a REAL msb sandbox + REAL msb image digests
# rather than paying for a full multi-minute `docker build`, per the same
# "isolated-resolver idiom" tests/test-json-output.sh already uses for
# other host-side resolvers).
#
# Coverage:
#   LS1  `rc --output json ls` lists a REAL msb-created cage (name/status/
#        source_path/mode), sourced from `msb list`/`msb inspect` (not
#        docker ps/inspect -- proven by a cage that ONLY exists in msb,
#        never in `docker ps -a`)
#   LS2  after `rc down`, the SAME cage is listed with status "exited"
#        (real msb state, not a stale docker read)
#   LS3  after `rc destroy`, the cage is no longer listed at all
#   BUILD1 `_build_warn_stale_containers` does NOT warn when a real cage's
#        stored image digest (`_msb_sandbox_image_digest`) matches the
#        "just built" image's REAL digest (`_msb_current_image_digest`) --
#        the common case, no false-positive noise
#   BUILD2 `_build_warn_stale_containers` DOES warn, naming the real cage,
#        when the "just built" image's digest differs from the cage's
#        stored digest -- proven with two genuinely DIFFERENT digests
#        already in msb's local image cache (rip-cage:latest vs alpine),
#        not a fake/simulated digest string
#
# NEEDS_CONTAINER (docker, rc up's image-provisioning preflight) + NEEDS_MSB
# + a pre-built rip-cage:latest image already `msb load`-ed + an `alpine`
# image already in msb's local cache (used only as a second, genuinely
# different digest for BUILD2 -- never booted). Self-skips (exit 0, SKIP:
# ...) when any prerequisite is missing -- never fakes a PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker not available/responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | jq -e '.[] | select(.reference == "alpine")' >/dev/null 2>&1; then
  echo "SKIP: no 'alpine' image in msb's local image cache (needed as a second, genuinely different digest for BUILD2) -- skipping $(basename "$0")"
  exit 0
fi

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-ls-build-live-XXXXXX")
WS="${TEST_HOME}/workspace"
mkdir -p "${TEST_HOME}/.config/rip-cage" "$WS"
CAGE_NAME=""
cleanup() {
  [[ -n "$CAGE_NAME" ]] && msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
  [[ -n "$CAGE_NAME" ]] && msb volume remove "rc-state-${CAGE_NAME}" "rc-history-${CAGE_NAME}" >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

git -C "$WS" init -q
touch "${WS}/README.md"
git -C "$WS" add README.md
git -C "$WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial"

cat > "${WS}/.rip-cage.yaml" <<'EOF'
version: 1
network:
  allowed_hosts: [example.com]
EOF

run_rc() {
  XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$WS" "$RC" --output json "$@"
}

CR_OUT=$(run_rc up "$WS" 2>&1)
CR_RC=$?
if [[ "$CR_RC" -ne 0 ]]; then
  fail "setup: rc up failed" "$CR_OUT"
  echo ""
  echo "=== test-msb-ls-build-live-probes.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
pass "setup: rc up created a real running msb sandbox ${CAGE_NAME}"

# Independent proof this cage is msb-only, never docker: it must NOT appear
# in `docker ps -a` at all (rules out ls silently still reading docker).
if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qF "$CAGE_NAME"; then
  pass "setup: the cage does NOT exist in docker ps -a (msb-only, proves ls can't be reading docker for it)"
else
  fail "setup: unexpectedly found the cage in docker ps -a" "$(docker ps -a --format '{{.Names}}' 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# LS1: rc --output json ls lists the real msb cage (name/status/source_path/mode).
# ---------------------------------------------------------------------------
echo ""
echo "=== LS1: rc --output json ls lists the REAL msb-created cage ==="
LS1_OUT=$(run_rc ls 2>&1)
LS1_ENTRY=$(echo "$LS1_OUT" | jq -c --arg n "$CAGE_NAME" '.[] | select(.name == $n)' 2>/dev/null)
if [[ -n "$LS1_ENTRY" ]]; then
  pass "LS1: rc ls includes the real cage entry: ${LS1_ENTRY}"
else
  fail "LS1: rc ls did not include the real cage" "$LS1_OUT"
fi
LS1_STATUS=$(echo "$LS1_ENTRY" | jq -r '.status' 2>/dev/null)
if [[ "$LS1_STATUS" == "running" ]]; then
  pass "LS1: status=running matches the real msb state"
else
  fail "LS1: expected status=running" "got '$LS1_STATUS'"
fi
LS1_SRC=$(echo "$LS1_ENTRY" | jq -r '.source_path' 2>/dev/null)
LS1_WS_REAL=$(cd "$WS" && pwd -P)
if [[ "$LS1_SRC" == "$LS1_WS_REAL" ]]; then
  pass "LS1: source_path matches the real rc.source.path label"
else
  fail "LS1: source_path mismatch" "got '$LS1_SRC' want '$LS1_WS_REAL'"
fi

# ---------------------------------------------------------------------------
# LS2: after rc down, the same cage lists as exited (real msb state).
# ---------------------------------------------------------------------------
echo ""
echo "=== LS2: after rc down, rc ls shows the REAL exited state ==="
run_rc down "$CAGE_NAME" >/dev/null 2>&1
LS2_OUT=$(run_rc ls 2>&1)
LS2_STATUS=$(echo "$LS2_OUT" | jq -r --arg n "$CAGE_NAME" '.[] | select(.name == $n) | .status' 2>/dev/null)
if [[ "$LS2_STATUS" == "exited" ]]; then
  pass "LS2: rc ls shows status=exited after a real rc down"
else
  fail "LS2: expected status=exited" "got '$LS2_STATUS'"
fi

# ---------------------------------------------------------------------------
# LS3: after rc destroy, the cage is no longer listed.
# ---------------------------------------------------------------------------
echo ""
echo "=== LS3: after rc destroy, rc ls no longer lists the cage ==="
run_rc destroy --force "$CAGE_NAME" >/dev/null 2>&1
LS3_OUT=$(run_rc ls 2>&1)
LS3_PRESENT=$(echo "$LS3_OUT" | jq -e --arg n "$CAGE_NAME" '.[] | select(.name == $n)' >/dev/null 2>&1; echo $?)
if [[ "$LS3_PRESENT" -ne 0 ]]; then
  pass "LS3: rc ls no longer lists the destroyed cage"
else
  fail "LS3: destroyed cage still listed" "$LS3_OUT"
fi
CAGE_NAME=""  # already destroyed -- cleanup trap should not try again

# ---------------------------------------------------------------------------
# BUILD1 / BUILD2: _build_warn_stale_containers (build.sh's live-probe path).
# Recreate a real cage from IMAGE (rip-cage:latest) for these two checks.
# ---------------------------------------------------------------------------
echo ""
echo "=== BUILD1 / BUILD2: _build_warn_stale_containers real digest comparison ==="
CR2_OUT=$(run_rc up "$WS" 2>&1)
CR2_RC=$?
if [[ "$CR2_RC" -ne 0 ]]; then
  fail "BUILD setup: rc up failed" "$CR2_OUT"
  echo ""
  echo "=== test-msb-ls-build-live-probes.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR2_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
pass "BUILD setup: rc up created a second real cage ${CAGE_NAME} from ${IMAGE}"

# shellcheck disable=SC1090
source "$RC" 2>/dev/null

# BUILD1: IMAGE (rip-cage:latest) is the SAME image the cage was created
# from -- digests match, so no warning.
BUILD1_OUT=$(IMAGE="$IMAGE" _build_warn_stale_containers 2>&1)
if [[ -z "$BUILD1_OUT" ]]; then
  pass "BUILD1: no warning when the cage's stored digest matches the just-built image's real digest"
else
  fail "BUILD1: expected no warning (digests match)" "$BUILD1_OUT"
fi

# BUILD2: point IMAGE at 'alpine' (a genuinely different, already-cached
# image/digest) to simulate "just built a different image" -- the cage was
# created from rip-cage:latest, so this IS a real digest mismatch.
BUILD2_OUT=$(IMAGE="alpine" _build_warn_stale_containers 2>&1)
if echo "$BUILD2_OUT" | grep -qF "$CAGE_NAME"; then
  pass "BUILD2: warns, naming the real cage, on a genuine digest mismatch: '${BUILD2_OUT}'"
else
  fail "BUILD2: expected a warning naming the cage on digest mismatch" "$BUILD2_OUT"
fi

echo ""
echo "=== test-msb-ls-build-live-probes.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
