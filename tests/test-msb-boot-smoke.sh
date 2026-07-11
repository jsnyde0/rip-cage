#!/usr/bin/env bash
# tests/test-msb-boot-smoke.sh -- effect-based boot-root smoke test for
# rip-cage-7dkq (S1 of the msb migration epic rip-cage-tsf2).
#
# This is the bead's "harness target" made literal: docker save a current rc
# image, msb load it, boot a cage from it, and run a REAL in-guest command
# that returns its REAL output value -- never accept `msb load` exit-0, an
# image-list entry, or a connect()-success as evidence (msb fake-accepts
# things; bd memory msb-netstack-fake-accepts-tcp-connect-not-egress).
#
# Coverage (mirrors the bead's three acceptance criteria exactly):
#   B1  docker save + msb load produces a cage that BOOTS (real in-guest
#       `whoami` returns the expected non-empty value, not just exit 0)
#   B2  the baked toolchain actually EXECUTES INSIDE THE GUEST: `bd --version`
#       run via msb matches an independently-captured ground truth of the
#       SAME command run via `docker run` against the SAME image (two
#       different runtimes must agree on the real value -- not tautological,
#       since msb's guest execution is a genuinely different code path)
#   B3  NEGATIVE CONTROL: booting an image never imported into msb FAILS
#       LOUD (non-zero exit) AND produces NO real in-guest output value (the
#       same effect-based value B1/B2 assert positively must be absent).
#       Uses `--pull never` so the failure is unambiguously "not present in
#       msb's local image cache" -- NOT "not pullable from docker.io" (a
#       registry-auth error is a namespace-collision hazard: if
#       docker.io/library/rip-cage:<tag> ever became a real pullable public
#       image, or an authed registry got configured, a plain absent-tag boot
#       could silently start succeeding, inverting this control to a false
#       pass). rip-cage-7dkq adversarial review, 2026-07-11: an earlier
#       version of this control relied on a docker.io "Not authorized" error,
#       which proves the wrong proposition -- fixed here.
#
# The Import step drives the ACTUAL SHIPPED `_build_msb_load` helper
# (cli/build.sh) end-to-end against a real image (sourced via `rc`), not a
# hand-rolled pipe form -- so this test proves the code that ships, not a
# parallel reimplementation of it.
#
# NEEDS_CONTAINER + NEEDS_MSB: requires live docker, live msb, and a
# pre-built rip-cage:latest image. Self-skips (exit 0, SKIP: ...) when any
# prerequisite is missing -- never fakes a PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available -- skipping $(basename "$0")"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon not responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no pre-built ${IMAGE} docker image -- skipping $(basename "$0") (run: rc build)"
  exit 0
fi

SMOKE_TAG="rip-cage:s1-smoke-$$"
cleanup() {
  msb image remove -f "$SMOKE_TAG" >/dev/null 2>&1 || true
  docker rmi "$SMOKE_TAG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Import: drive the ACTUAL SHIPPED `_build_msb_load` (cli/build.sh) helper,
# not a hand-rolled pipe form -- proves the code that ships (docker save -o
# <tempfile> then msb load --tag <IMAGE> -i <tempfile>), not a parallel
# reimplementation of it.
#
# Retag on the docker side FIRST (cheap -- same image ID, new local ref)
# rather than pointing IMAGE at "$IMAGE" directly: `docker save` embeds its
# source reference inside the tar, and `msb load --tag X` imports BOTH that
# embedded reference AND X (confirmed live here, matching
# docs/2026-07-09-msb-spike-lifecycle.md §9b) -- saving "$IMAGE" directly
# would silently mutate the operator's own rip-cage:latest msb-side cache as
# a side effect of this test. Retagging to a scratch name first keeps the
# embedded reference scoped to the scratch name, so cleanup is complete and
# this test never touches shared state.
# ---------------------------------------------------------------------------
echo ""
echo "=== Import: _build_msb_load (cli/build.sh, the shipped helper) against IMAGE=${SMOKE_TAG} ==="
docker tag "$IMAGE" "$SMOKE_TAG"
IMPORT_OUT=$(bash -c "source '${RC}' 2>/dev/null; IMAGE='${SMOKE_TAG}'; _build_msb_load" 2>&1)
IMPORT_RC=$?
if [[ "$IMPORT_RC" -eq 0 ]]; then
  pass "import: _build_msb_load exits 0"
else
  fail "import: _build_msb_load failed" "$IMPORT_OUT"
  echo ""
  echo "=== test-msb-boot-smoke.sh: ${FAILURES}/${TOTAL} failure(s) (aborting -- import failed, nothing else is verifiable) ==="
  exit 1
fi
if [[ -z "$IMPORT_OUT" ]]; then
  pass "import: _build_msb_load is silent on success (no spurious warning)"
else
  fail "import: expected zero output on success" "$IMPORT_OUT"
fi
if msb image list --format json 2>/dev/null | grep -qF "$SMOKE_TAG"; then
  pass "import: msb image list shows the loaded tag"
else
  fail "import: loaded tag not present in msb image list" "$(msb image list 2>&1)"
fi

# ---------------------------------------------------------------------------
# B1: the cage actually boots -- real in-guest `whoami`, real value.
# ---------------------------------------------------------------------------
echo ""
echo "=== B1: cage boots -- real in-guest whoami ==="
B1_OUT=$(msb run "$SMOKE_TAG" -- whoami 2>/tmp/s1-smoke-b1.err)
B1_RC=$?
if [[ "$B1_RC" -eq 0 ]]; then
  pass "B1: msb run whoami exits 0"
else
  fail "B1: msb run whoami exited ${B1_RC}" "$(cat /tmp/s1-smoke-b1.err)"
fi
if [[ -n "$B1_OUT" ]]; then
  pass "B1b: in-guest whoami returned a real non-empty value: '${B1_OUT}'"
else
  fail "B1b: in-guest whoami returned empty output" "stderr: $(cat /tmp/s1-smoke-b1.err)"
fi

# ---------------------------------------------------------------------------
# B2: the baked toolchain executes inside the guest -- cross-runtime value
# agreement (docker ground truth vs msb guest execution, SAME image).
# ---------------------------------------------------------------------------
echo ""
echo "=== B2: baked toolchain (bd) executes in-guest -- real output, cross-checked against docker ground truth ==="
DOCKER_GROUND_TRUTH=$(docker run --rm "$IMAGE" bd --version 2>/tmp/s1-smoke-b2-docker.err)
DOCKER_RC=$?
if [[ "$DOCKER_RC" -eq 0 && -n "$DOCKER_GROUND_TRUTH" ]]; then
  pass "B2 setup: captured docker ground truth for 'bd --version': '${DOCKER_GROUND_TRUTH}'"
else
  fail "B2 setup: could not capture docker ground truth for bd --version" "$(cat /tmp/s1-smoke-b2-docker.err)"
fi

MSB_OUT=$(msb run "$SMOKE_TAG" -- bd --version 2>/tmp/s1-smoke-b2-msb.err)
MSB_RC=$?
if [[ "$MSB_RC" -eq 0 ]]; then
  pass "B2: msb run bd --version exits 0"
else
  fail "B2: msb run bd --version exited ${MSB_RC}" "$(cat /tmp/s1-smoke-b2-msb.err)"
fi
if [[ "$MSB_OUT" == "$DOCKER_GROUND_TRUTH" && -n "$MSB_OUT" ]]; then
  pass "B2b: in-guest 'bd --version' returned the SAME real value as the independent docker ground truth: '${MSB_OUT}'"
else
  fail "B2b: in-guest bd --version output did not match docker ground truth" "msb='${MSB_OUT}' docker='${DOCKER_GROUND_TRUTH}' stderr=$(cat /tmp/s1-smoke-b2-msb.err)"
fi

# ---------------------------------------------------------------------------
# B3: negative control -- an image never imported into msb fails to boot
# LOUD, and produces NO real in-guest effect (the same class of value B1/B2
# assert positively -- stdout from a real command run in the guest -- must
# be absent here). `--pull never` removes the docker.io remote-pull escape
# hatch: msb is never even permitted to attempt a registry pull, so any
# resulting failure is unambiguously "not in msb's local image cache", not a
# public-registry auth artifact that could silently start succeeding if
# docker.io/library/rip-cage ever became pullable.
# ---------------------------------------------------------------------------
echo ""
echo "=== B3: negative control -- never-imported image fails LOUD with NO in-guest effect ==="
ABSENT_TAG="rip-cage:s1-smoke-absent-$$"
B3_OUT=$(msb run --pull never "$ABSENT_TAG" -- whoami 2>/tmp/s1-smoke-b3.err)
B3_RC=$?
B3_ERR=$(cat /tmp/s1-smoke-b3.err)
if [[ "$B3_RC" -ne 0 ]]; then
  pass "B3: booting a never-imported image (--pull never) exits non-zero (${B3_RC}), not a silent success"
else
  fail "B3: booting a never-imported image unexpectedly exited 0" "stdout='${B3_OUT}' stderr='${B3_ERR}'"
fi
if [[ -z "$B3_OUT" ]]; then
  pass "B3b: NO real in-guest output was produced (the same effect-based value B1/B2 assert positively is absent here)"
else
  fail "B3b: expected empty stdout (no in-guest effect), got real output" "'${B3_OUT}'"
fi
if echo "$B3_ERR" | grep -qi "not cached"; then
  pass "B3c: stderr names LOCAL image-cache absence ('not cached'), not a registry/pull artifact: '${B3_ERR}'"
else
  fail "B3c: expected stderr to name local image-cache absence ('not cached')" "$B3_ERR"
fi
# NOTE: msb canonicalizes image refs to their fully-qualified docker.io/library/...
# form in BOTH failure modes (confirmed live), so checking for the bare
# substring "docker.io" would false-fail on the correct local-absence
# message too. The markers that are UNIQUE to the registry-pull-attempt
# failure mode (confirmed live, side-by-side) are "registry error" and "not
# authorized" -- neither appears in the "image not cached" local-absence
# message.
if echo "$B3_ERR" | grep -qiE "registry error|not authorized"; then
  fail "B3d: stderr references a registry-pull-attempt outcome ('registry error'/'not authorized') -- proves the wrong proposition, the exact defect this control was fixed to avoid" "$B3_ERR"
else
  pass "B3d: stderr shows no registry-pull-attempt signature ('registry error'/'not authorized') -- the failure is local-cache-absence, not a namespace-collision-fragile registry artifact"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-msb-boot-smoke.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-msb-boot-smoke.sh: all ${TOTAL} tests passed ==="
