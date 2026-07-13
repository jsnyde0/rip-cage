#!/usr/bin/env bash
# tests/test-msb-lifecycle-create-resume.sh -- LIVE effect-based proof that
# `rc up` (the REAL create/resume verb, not a direct `msb run` bypass) is
# rewired onto msb (rip-cage-rj68, S6 of the msb migration epic
# rip-cage-tsf2). Unlike S4/S5's siblings, which had to drive `msb run`
# directly because rc's create verb didn't exist yet, S6 IS that verb -- so
# this harness exercises `rc up` end-to-end (docs/2026-07-10-tsf2-
# decomposition.md, S6's "Verification note").
#
# Coverage (mirrors the bead's acceptance criteria):
#   PF   (criterion 7, Fold b) an unset required credential source_env
#        makes `rc up` fail LOUD, non-zero, NAMING the var, and creates NO
#        sandbox at all (not a booted cage carrying an empty secret)
#   CR   `rc up` on a fresh workspace creates a REAL msb sandbox (name
#        matches JSON output; msb list confirms it exists and is running)
#   INIT the create-time init run sets a real, checkable git identity
#        in-guest (git config --global user.name/user.email)
#   RES  (criterion 6) after a graceful stop + `rc up` resume, the SAME
#        init script re-runs (ADR-029 D4's "rc re-runs init on each
#        resume") and a REAL git commit made INSIDE the resumed cage
#        carries the correct identity -- read back via `git log`, not
#        merely "init ran" or "cockpit registered"
#
# NEEDS_CONTAINER (docker, for rc up's image-provisioning preflight) +
# NEEDS_MSB + a pre-built rip-cage:latest image already `msb load`-ed.
# Self-skips (exit 0, SKIP: ...) when any prerequisite is missing -- never
# fakes a PASS.

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

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-lifecycle-cr-XXXXXX")
WS="${TEST_HOME}/workspace"
mkdir -p "${TEST_HOME}/.config/rip-cage" "$WS"
CAGE_NAME=""
cleanup() {
  [[ -n "$CAGE_NAME" ]] && msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# rip-cage-rj68 (S6): deliberately does NOT override HOME for the rc/msb
# invocations below (only XDG_CONFIG_HOME + GIT_CONFIG_GLOBAL are
# sandboxed). msb's own state (image cache, sandbox registry --
# ~/.microsandbox/) is genuinely HOME-global, matching real usage; a
# sandboxed HOME makes msb (correctly) see an EMPTY local image cache and
# fall back to a real GHCR pull/rebuild, which is slow and not what this
# test is probing. XDG_CONFIG_HOME keeps rc's OWN config file sandboxed;
# GIT_CONFIG_GLOBAL (git >= 2.32) isolates the git identity this test
# controls without touching HOME at all.
GIT_CONFIG_GLOBAL="${TEST_HOME}/.gitconfig"
export GIT_CONFIG_GLOBAL

# shellcheck disable=SC2120 # "$@" is a deliberate general-purpose passthrough (unused by this file's current call sites)
run_rc_up() {
  XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$WS" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
    "$RC" --output json up "$WS" "$@"
}

# _up_prepare_environment forwards `git config user.name`/`user.email` AS
# RUN -- NOT the workspace's own local repo config (it never `-C`s into $WS
# for this read). So the identity this test expects init-rip-cage.sh to set
# (and criterion 6's resume to RE-set) must live in GIT_CONFIG_GLOBAL,
# resolved the same way the real `rc up` invocations below see it.
git config --global user.name "Lifecycle Test Host"
git config --global user.email "lifecycle-test-host@example.invalid"

# Real git repo in the workspace so criterion 6's commit has somewhere real
# to land (mounted rw as /workspace inside the cage). Uses its own -c
# identity (irrelevant to what the CAGE resolves -- see above) purely to
# make the initial host-side commit succeed.
git -C "$WS" init -q
touch "${WS}/README.md"
git -C "$WS" add README.md
git -C "$WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial"

cat > "${WS}/.rip-cage.yaml" <<'EOF'
version: 1
network:
  allowed_hosts: [example.com]
auth:
  credentials:
    - source_env: RJ68_LIFECYCLE_TOKEN
      hosts: [example.com]
EOF

# ---------------------------------------------------------------------------
# PF: unset source_env -> loud failure, no sandbox created.
# ---------------------------------------------------------------------------
echo ""
echo "=== PF: unset credential source_env -> rc up fails loud, no sandbox created ==="
unset RJ68_LIFECYCLE_TOKEN 2>/dev/null || true
PF_OUT=$(run_rc_up 2>&1)
PF_RC=$?
if [[ "$PF_RC" -ne 0 ]] && echo "$PF_OUT" | grep -q "RJ68_LIFECYCLE_TOKEN"; then
  pass "PF: rc up fails non-zero, naming RJ68_LIFECYCLE_TOKEN"
else
  fail "PF: expected non-zero exit naming the var" "rc=$PF_RC out='$PF_OUT'"
fi
PF_CAGE_NAME=$(basename "$(dirname "$WS")")-$(basename "$WS")
if ! msb inspect "$PF_CAGE_NAME" --format json >/dev/null 2>&1; then
  pass "PF: no sandbox was created (preflight ran BEFORE msb create)"
else
  fail "PF: a sandbox was created despite the unset source_env -- silent-empty-secret footgun"
  msb remove --force "$PF_CAGE_NAME" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# CR: real credential set -> rc up creates a real, running msb sandbox.
# ---------------------------------------------------------------------------
echo ""
echo "=== CR: rc up creates a real running msb sandbox ==="
export RJ68_LIFECYCLE_TOKEN="not-a-real-secret-lifecycle-test-value"
CR_OUT=$(run_rc_up 2>&1)
CR_RC=$?
if [[ "$CR_RC" -eq 0 ]]; then
  pass "CR: rc up exits 0 with the source_env set"
else
  fail "CR: rc up failed" "rc=$CR_RC out='$CR_OUT'"
  echo ""
  echo "=== test-msb-lifecycle-create-resume.sh: ${FAILURES}/${TOTAL} failure(s) (aborting -- create failed) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
CR_ACTION=$(echo "$CR_OUT" | tail -1 | jq -r '.action' 2>/dev/null)
if [[ -n "$CAGE_NAME" && "$CR_ACTION" == "created" ]]; then
  pass "CR: JSON output reports action=created, name=${CAGE_NAME}"
else
  fail "CR: unexpected JSON output" "$CR_OUT"
fi
if msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -e '.status == "Running"' >/dev/null 2>&1; then
  pass "CR: msb inspect confirms the sandbox is REALLY running (independent read-back)"
else
  fail "CR: sandbox not running per independent msb inspect" "$(msb inspect "$CAGE_NAME" 2>&1)"
fi

# ---------------------------------------------------------------------------
# INIT: the create-time init run set a real git identity in-guest.
# ---------------------------------------------------------------------------
echo ""
echo "=== INIT: create-time init sets a real in-guest git identity ==="
INIT_NAME=$(msb exec "$CAGE_NAME" -- git config --global user.name 2>/dev/null)
INIT_EMAIL=$(msb exec "$CAGE_NAME" -- git config --global user.email 2>/dev/null)
if [[ "$INIT_NAME" == "Lifecycle Test Host" && "$INIT_EMAIL" == "lifecycle-test-host@example.invalid" ]]; then
  pass "INIT: in-guest git identity set to the expected forwarded value: '${INIT_NAME} <${INIT_EMAIL}>'"
else
  fail "INIT: expected the forwarded host identity in-guest" "name='${INIT_NAME}' email='${INIT_EMAIL}'"
fi

# ---------------------------------------------------------------------------
# RES: graceful stop + rc up resume -> init re-runs -> real commit carries
# the correct identity (bead criterion 6).
# ---------------------------------------------------------------------------
echo ""
echo "=== RES: resume re-establishes git identity -- real in-guest commit ==="
msb stop "$CAGE_NAME" >/dev/null 2>&1
RES_STATE=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -r '.status')
if [[ "$RES_STATE" == "Stopped" ]]; then
  pass "RES setup: sandbox genuinely stopped before resume"
else
  fail "RES setup: expected Stopped" "got '$RES_STATE'"
fi

RES_OUT=$(run_rc_up 2>&1)
RES_RC=$?
RES_ACTION=$(echo "$RES_OUT" | tail -1 | jq -r '.action' 2>/dev/null)
if [[ "$RES_RC" -eq 0 && "$RES_ACTION" == "resumed" ]]; then
  pass "RES: rc up resumes the stopped sandbox (action=resumed)"
else
  fail "RES: expected action=resumed, exit 0" "rc=$RES_RC out='$RES_OUT'"
fi

RES_STATE2=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -r '.status')
if [[ "$RES_STATE2" == "Running" ]]; then
  pass "RES: independent msb inspect confirms Running after resume"
else
  fail "RES: expected Running after resume" "got '$RES_STATE2'"
fi

# The real effect: commit INSIDE the resumed cage, read the author back.
msb exec -w /workspace "$CAGE_NAME" -- git commit --allow-empty -m "post-resume commit" >/dev/null 2>&1
RES_AUTHOR=$(msb exec -w /workspace "$CAGE_NAME" -- git log -1 --format='%an <%ae>' 2>/dev/null)
if echo "$RES_AUTHOR" | grep -qF "Lifecycle Test Host" && echo "$RES_AUTHOR" | grep -qF "lifecycle-test-host@example.invalid"; then
  pass "RES: post-resume in-guest commit carries the correct re-established identity: '${RES_AUTHOR}'"
else
  fail "RES: post-resume commit author does not match the expected re-established identity" "got '${RES_AUTHOR}'"
fi

echo ""
echo "=== test-msb-lifecycle-create-resume.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
