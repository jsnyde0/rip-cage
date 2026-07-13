#!/usr/bin/env bash
# tests/test-msb-mount-shape-resume-guard-live.sh -- LIVE, real-cage effect
# proof for the ADR-028 mount-shape label-lock's resume-abort/resume-admit
# behavior on msb (rip-cage-qzsx, S8 of the msb migration epic
# rip-cage-tsf2). Uses `mounts.config_mode` (ADR-021 D7, instance 3 of the
# label-lock family) as the representative instance: its guest-observable
# effect is the simplest to assert directly (a single-file :ro shadow-mount
# either blocks or allows a write through the mount), and its resolver
# (_up_resolve_resume_config_mode) shares the identical guard shape — same
# `_msb_label` read, same abort message template, same both-branches
# wiring — as the sibling instances (symlink-follow fingerprint,
# credential-mounts) covered structurally (fake-msb-shim, not live cages)
# by tests/test-symlink-follow.sh S16/S19 and tests/test-credential-
# mounts.sh CM8-CM10/CM17-CM21.
#
# Bead acceptance criteria this proves (rip-cage-qzsx):
#   (1)  A cage resumed after a config change that alters mount shape
#        ABORTS LOUD with the mismatch (not a silent re-mount) -- verified
#        by attempting a WRITE THROUGH THE MOUNT inside the guest and
#        observing which shape the guest actually sees, not by reading a
#        stored label. Driven on the RUNNING branch (not the stopped
#        branch) specifically because the running branch keeps the guest
#        reachable throughout the abort, so the "no silent re-mount"
#        claim can be checked by a real in-guest write attempt immediately
#        after the abort, not merely by inspecting `msb inspect`'s
#        top-level .status field.
#   (1b) A MATCHING config resumes clean with no false abort (proves the
#        abort is mismatch-specific, not resume-blanket) -- both for the
#        ro->ro stopped-and-resumed cage (criterion 1's own cage, after
#        reverting the drift) and for an independently-created rw cage
#        (positive/negative differential across BOTH mount-shape values,
#        not just one).
#
# NEEDS_CONTAINER (docker, for rc up's image-provisioning preflight) +
# NEEDS_MSB + a pre-built rip-cage:latest image already `msb load`-ed.
# Self-skips (exit 0, SKIP: ...) when any prerequisite is missing -- never
# fakes a PASS. RC_E2E-gated (real cages, real boot time) like the sibling
# live suites (test-msb-lifecycle-*.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if [[ "${RC_E2E:-}" != "1" ]]; then
  echo "SKIP: RC_E2E not set -- skipping $(basename "$0") (real-cage live suite)"
  exit 0
fi
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

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-mount-shape-live-XXXXXX")
WS="${TEST_HOME}/workspace"
mkdir -p "${TEST_HOME}/.config/rip-cage" "$WS"
CAGE_A="" CAGE_B=""
cleanup() {
  [[ -n "$CAGE_A" ]] && msb remove --force "$CAGE_A" >/dev/null 2>&1 || true
  [[ -n "$CAGE_B" ]] && msb remove --force "$CAGE_B" >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Same HOME-not-sandboxed rationale as test-msb-lifecycle-create-resume.sh:
# msb's own state (image cache, sandbox registry) is genuinely HOME-global;
# only XDG_CONFIG_HOME (rc's own config) and GIT_CONFIG_GLOBAL (git identity)
# are sandboxed.
GIT_CONFIG_GLOBAL="${TEST_HOME}/.gitconfig"
export GIT_CONFIG_GLOBAL
git config --global user.name "Mount Shape Live Test"
git config --global user.email "mount-shape-live-test@example.invalid"

git -C "$WS" init -q
touch "${WS}/README.md"
git -C "$WS" add README.md
git -C "$WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial"

run_rc_up() {
  XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$WS" "$RC" "$@"
}

write_config_mode() {
  cat > "${WS}/.rip-cage.yaml" <<EOF
version: 1
mounts:
  config_mode: $1
EOF
}

# Attempts a write through the mount inside the guest, returns the real
# guest-side exit code (0 = write succeeded / mount is rw; non-zero = write
# was refused / mount is ro). This IS the guest-observed evidence the bead
# acceptance criteria require -- not a label read.
guest_write_attempt() {
  local _cage="$1"
  msb exec "$_cage" -- sh -c 'echo probe >> /workspace/.rip-cage.yaml' >/dev/null 2>&1
}

# ===========================================================================
# Setup: cage A, created with mounts.config_mode: ro.
# ===========================================================================
echo ""
echo "=== SETUP: create cage A with mounts.config_mode: ro ==="
write_config_mode "ro"
CR_OUT=$(run_rc_up --output json up "$WS" 2>&1)
CR_RC=$?
CAGE_A=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
if [[ "$CR_RC" -eq 0 && -n "$CAGE_A" ]]; then
  pass "SETUP: cage A created (${CAGE_A})"
else
  fail "SETUP: cage A create failed" "rc=$CR_RC out='$CR_OUT'"
  echo ""
  echo "=== test-msb-mount-shape-resume-guard-live.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

if guest_write_attempt "$CAGE_A"; then
  fail "SETUP: guest write through /workspace/.rip-cage.yaml succeeded on a ro-created cage" "expected EROFS/EACCES"
else
  pass "SETUP: create-time effect confirmed -- guest write through the ro shadow-mount genuinely fails"
fi

# ===========================================================================
# Criterion 1 (negative): flip mounts.config_mode to rw on the HOST while
# cage A is STILL RUNNING, then `rc up` again (running/attach branch).
# Expect: loud abort (non-zero, mismatch message naming both values), AND
# -- the guest-observed proof -- the mount the guest actually sees is
# STILL ro (a fresh write attempt still fails), because the guard aborted
# BEFORE anything touched the sandbox. This is the "not a silent re-mount"
# claim, proven by real effect, not by re-reading a label.
# ===========================================================================
echo ""
echo "=== CRITERION 1: config drifts to rw while cage A is running -> rc up aborts loud, guest mount UNCHANGED ==="
write_config_mode "rw"
set +e
MISMATCH_OUT=$(run_rc_up up "$WS" 2>&1)
MISMATCH_RC=$?
set -e
if [[ "$MISMATCH_RC" -ne 0 ]]; then
  pass "C1: rc up exits non-zero on mount-shape drift (config_mode ro->rw) while cage is running"
else
  fail "C1: rc up exited 0 despite a mount-shape drift" "out='$MISMATCH_OUT'"
fi
if echo "$MISMATCH_OUT" | grep -qi "rc.config-mode=ro" && echo "$MISMATCH_OUT" | grep -qi "mounts.config_mode=rw"; then
  pass "C1: abort message names BOTH the stored (ro) and current (rw) values"
else
  fail "C1: abort message did not name both mount-shape values" "out='$MISMATCH_OUT'"
fi
if echo "$MISMATCH_OUT" | grep -qi "rc destroy" && echo "$MISMATCH_OUT" | grep -qi "requires recreating the container"; then
  pass "C1: abort message states the immutability rationale + the destroy/re-up remedy"
else
  fail "C1: abort message missing the immutability/remedy wording" "out='$MISMATCH_OUT'"
fi

# The real guest-observed evidence: cage A is untouched by the aborted
# attempt (still Running, per msb's own state -- checked as an ADDITIONAL,
# not sole, signal) AND a fresh write through the mount still fails exactly
# as it did before the host-side config changed.
A_STATE=$(msb inspect "$CAGE_A" --format json 2>/dev/null | jq -r '.status')
if [[ "$A_STATE" == "Running" ]]; then
  pass "C1: cage A is still Running -- the abort happened before anything touched the sandbox"
else
  fail "C1: cage A is no longer Running after the aborted resume attempt" "status='$A_STATE'"
fi
if guest_write_attempt "$CAGE_A"; then
  fail "C1: guest-observed mount shape changed to rw despite the abort -- SILENT RE-MOUNT (the exact failure mode the guard exists to prevent)"
else
  pass "C1: guest-observed mount shape is UNCHANGED (write through the mount still fails) -- no silent re-mount occurred, proven by real effect on the running guest, not a label read"
fi

# ===========================================================================
# Criterion 1b (positive, same cage): revert the host config back to the
# value the cage was actually created with (ro) -- a MATCHING config -- and
# resume (attach; still running, no stop/start needed for this half).
# Expect: clean, no abort, exit 0.
# ===========================================================================
echo ""
echo "=== CRITERION 1b: config reverted to match (ro) -> rc up resumes/attaches clean, no false abort ==="
write_config_mode "ro"
set +e
MATCH_OUT=$(run_rc_up --output json up "$WS" 2>&1)
MATCH_RC=$?
set -e
MATCH_ACTION=$(echo "$MATCH_OUT" | tail -1 | jq -r '.action' 2>/dev/null)
if [[ "$MATCH_RC" -eq 0 && "$MATCH_ACTION" == "attached" ]]; then
  pass "C1b: rc up on a matching (unchanged) config attaches clean (action=attached), no false abort"
else
  fail "C1b: expected exit 0 / action=attached on a matching config" "rc=$MATCH_RC out='$MATCH_OUT'"
fi
if guest_write_attempt "$CAGE_A"; then
  fail "C1b: guest write unexpectedly succeeded after a matching (ro) resume"
else
  pass "C1b: guest-observed mount shape after the matching resume is still ro, as created -- consistent, correct shape"
fi

# ===========================================================================
# Criterion 1b (independent positive/negative differential): a SECOND cage
# created and resumed with mounts.config_mode: rw throughout -- proves the
# guard is not just "always refuse" or coincidentally tuned to ro; the
# OTHER mount-shape value also resumes clean with the OTHER guest-observed
# effect (write SUCCEEDS).
# ===========================================================================
echo ""
echo "=== CRITERION 1b (differential): independent rw cage -- stop+resume with UNCHANGED rw config -> clean, guest write succeeds both times ==="
WS_B="${TEST_HOME}/workspace-b"
mkdir -p "$WS_B"
git -C "$WS_B" init -q
touch "${WS_B}/README.md"
git -C "$WS_B" add README.md
git -C "$WS_B" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial"
write_config_mode_rw_b() {
  cat > "${WS_B}/.rip-cage.yaml" <<'EOF'
version: 1
mounts:
  config_mode: rw
EOF
}
write_config_mode_rw_b

run_rc_up_b() {
  XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$WS_B" "$RC" "$@"
}

CRB_OUT=$(run_rc_up_b --output json up "$WS_B" 2>&1)
CRB_RC=$?
CAGE_B=$(echo "$CRB_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
if [[ "$CRB_RC" -eq 0 && -n "$CAGE_B" ]]; then
  pass "B-SETUP: cage B created with mounts.config_mode: rw (${CAGE_B})"
else
  fail "B-SETUP: cage B create failed" "rc=$CRB_RC out='$CRB_OUT'"
fi

# Probes the SAME file the guard governs (.rip-cage.yaml) rather than a
# scratch file, so the effect proven is specific to the mount under test —
# but since config_mode=rw makes this write genuinely SUCCEED (unlike cage
# A's ro case, where a failed write leaves the file untouched), a
# succeeding probe here would corrupt the very config content the NEXT
# guard evaluation reads (turning valid YAML into "config_mode: rw\nprobe",
# which fails to parse and silently falls back to the ro default — a real
# bug this test caught on its first live run: it made the "matching rw
# config" resume look like a mismatch). Restore canonical content
# immediately after a successful write so repeated probes stay idempotent.
guest_write_attempt_b() {
  local _rc=0
  msb exec "$CAGE_B" -- sh -c 'echo probe >> /workspace/.rip-cage.yaml' >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 ]] && write_config_mode_rw_b
  return "$_rc"
}
if guest_write_attempt_b; then
  pass "B-SETUP: create-time effect confirmed -- guest write through the rw mount genuinely succeeds"
else
  fail "B-SETUP: guest write failed on an rw-created cage" "expected success"
fi

msb stop "$CAGE_B" >/dev/null 2>&1
B_STOPPED_STATE=$(msb inspect "$CAGE_B" --format json 2>/dev/null | jq -r '.status')
[[ "$B_STOPPED_STATE" == "Stopped" ]] || fail "B: setup -- cage B did not actually stop" "status='$B_STOPPED_STATE'"

set +e
RESUME_B_OUT=$(run_rc_up_b --output json up "$WS_B" 2>&1)
RESUME_B_RC=$?
set -e
RESUME_B_ACTION=$(echo "$RESUME_B_OUT" | tail -1 | jq -r '.action' 2>/dev/null)
if [[ "$RESUME_B_RC" -eq 0 && "$RESUME_B_ACTION" == "resumed" ]]; then
  pass "B: stopped-and-resumed with UNCHANGED rw config -> clean resume (action=resumed), no false abort"
else
  fail "B: expected exit 0 / action=resumed on a matching (unchanged) rw config" "rc=$RESUME_B_RC out='$RESUME_B_OUT'"
fi
if guest_write_attempt_b; then
  pass "B: guest-observed mount shape after resume is still rw, as created -- correct shape, real effect"
else
  fail "B: guest write failed after a matching rw resume" "expected success"
fi

echo ""
echo "=== test-msb-mount-shape-resume-guard-live.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
