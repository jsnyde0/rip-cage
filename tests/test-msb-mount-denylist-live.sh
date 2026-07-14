#!/usr/bin/env bash
# tests/test-msb-mount-denylist-live.sh -- LIVE effect-based re-verification of
# the ADR-023 secret-path mount-denylist against msb mount-flag syntax
# (rip-cage-l9hn, S9 of the msb migration epic rip-cage-tsf2).
#
# ADR-029 canonical_refs flags ADR-023's realpath-resolution mechanics for
# re-verification on msb's --mount-file/--mount-dir SOURCE:DEST[:OPTIONS]
# syntax (S2's generator, cli/lib/msb_flags.sh). The denylist itself
# (_check_secret_path_denylist, cli/lib/path.sh) is host-side, pre-flight,
# and msb-independent -- this test proves the PIPELINE it gates (host check
# -> generator -> a REAL msb cage) still holds the invariant end to end, per
# the msb fake-accept confound (bd memory
# msb-netstack-fake-accepts-tcp-connect-not-egress; the same "don't trust
# the mechanism, prove the effect" discipline applies to mount
# presence/absence, not just network): a denied path's content must be
# UNREADABLE FROM INSIDE A REAL GUEST, never merely "the host validator
# returned an error".
#
# No real secrets anywhere -- the "denylisted" content is a synthetic
# sentinel string under a scratch directory shaped like a denylist pattern
# (.aws/credentials), never a real credential. Nothing here touches the
# user's real ~/.ssh, ~/.aws, or any live credential.
#
# Coverage (mirrors the bead's acceptance criteria):
#   H1  host-side: _check_secret_path_denylist denies the direct
#       denylisted (resolved) path
#   H2  host-side: _check_secret_path_denylist denies the SYMLINK-ESCAPE
#       form -- a symlink whose realpath resolves into the denylisted
#       target (D7 realpath-first) [criterion 3, host-side half]
#   H3  host-side: a non-denylisted control path is allowed (setup for the
#       live positive control)
#   L1  live: the control mount is readable in-guest with its REAL content,
#       proving mounts work and the denylist isn't a broken-mount artifact
#       [criterion 2]
#   L2  live: the control mount's `:ro` OPTIONS suffix is enforced -- an
#       in-guest write fails and the content is unchanged [S2 carry-forward
#       flag: ":ro" was implemented per msb grammar but not previously
#       live-verified]
#   L3  live: with the denylisted mount excluded (per H1's host-side gate,
#       mirroring what the real create-path pipeline does before ever
#       building the generator's mounts array), the sentinel content is
#       UNREADABLE anywhere in the guest filesystem -- a real in-guest read
#       attempt, not a host-side error check [criterion 1]
#   L4  live, red-capability control: mounting the RESOLVED denylisted
#       target directly (the same content L3 proved absent) makes the
#       sentinel readable in-guest. This proves the L3 absence assertion
#       is red-capable -- the same sentinel-grep technique DOES catch the
#       content when it is actually mounted, so L3's silence isn't a
#       broken assertion or a vacuous "undeclared path" artifact.
#
#       DISCOVERY (documented here, not asserted as a persistent
#       regression -- it is not itself a denylist acceptance criterion):
#       msb's `--mount-file` does NOT dereference a symlink SOURCE. Staging
#       the raw (unresolved) symlink path directly as `--mount-file`
#       SOURCE fails to BOOT the cage at all (`agentd: init failed: ...
#       ENOENT: No such file or directory` binding the staged symlink,
#       captured via `msb logs --source system`) -- the symlink's absolute
#       host target is meaningless inside the guest's staging namespace.
#       This is a SAFE failure mode (fails loud/closed, no exposure) but
#       it means msb provides no independent symlink-following safety net
#       of its own: rc's D7 realpath-first resolution is not just a
#       security nicety here, it is functionally REQUIRED for a symlink
#       mount source to work under msb at all. Reproduced live during this
#       bead's investigation; not re-asserted per-run to avoid coupling
#       test-suite-green to a specific msb version's staging quirk.
#
# NEEDS_CONTAINER + NEEDS_MSB + a pre-built rip-cage:latest image loaded into
# msb. Self-skips (exit 0, SKIP: ...) when any prerequisite is missing --
# never fakes a PASS. Not wired into tests/run-host.sh (mirrors the sibling
# live-msb effect probes tests/test-msb-flags-effect-probes.sh and
# tests/test-msb-claude-home-resume.sh -- run directly; registered in the
# Makefile's BASH_SCRIPTS for shellcheck only).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
GEN="${REPO_ROOT}/cli/lib/msb_flags.sh"
IMAGE="rip-cage:latest"
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
if ! msb image list --format json 2>/dev/null | grep -qF "\"reference\": \"${IMAGE}\""; then
  echo "SKIP: ${IMAGE} not loaded into msb -- skipping $(basename "$0") (run: rc build, then msb load)"
  exit 0
fi

# shellcheck disable=SC1090
source "$GEN"

# ---------------------------------------------------------------------------
# Scratch fixtures (never real secrets, never the user's real ~/.ssh or
# ~/.aws -- a throwaway directory shaped like a denylist pattern).
# ---------------------------------------------------------------------------
SCRATCH_DIR=$(mktemp -d)
TEST_HOME=$(mktemp -d)

CONTROL_DIR="${SCRATCH_DIR}/control"
mkdir -p "$CONTROL_DIR"
CONTROL_CONTENT="rc-l9hn-control-content-${RUN_ID}-$(date +%s)"
printf '%s' "$CONTROL_CONTENT" > "${CONTROL_DIR}/data.txt"

DENYLISTED_DIR="${SCRATCH_DIR}/denylist-shaped/.aws"
mkdir -p "$DENYLISTED_DIR"
SENTINEL="rc-l9hn-sentinel-${RUN_ID}-$(date +%s)-should-never-be-guest-readable"
printf '%s' "$SENTINEL" > "${DENYLISTED_DIR}/credentials"
DENYLISTED_FILE="${DENYLISTED_DIR}/credentials"

WORKSPACE_DIR="${SCRATCH_DIR}/workspace"
mkdir -p "$WORKSPACE_DIR"
SYMLINK_PATH="${WORKSPACE_DIR}/sneaky-link"
ln -s "$DENYLISTED_FILE" "$SYMLINK_PATH"

RESOLVED_CONTROL=$(realpath "${CONTROL_DIR}/data.txt")
RESOLVED_DENYLISTED=$(realpath "$DENYLISTED_FILE")
RESOLVED_SYMLINK=$(realpath "$SYMLINK_PATH")

# Sandbox global config: minimal denylist covering the fixture shape
# (.aws directory component, "credentials" bareword filename) -- same
# patterns as the real D4 defaults, scoped down for a deterministic test.
mkdir -p "${TEST_HOME}/.config/rip-cage"
cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'CFGEOF'
version: 2
mounts:
  denylist:
    - .aws
    - credentials
CFGEOF
TEST_WS="${TEST_HOME}/workspace"
mkdir -p "$TEST_WS"

CAGE_MAIN="l9hn-probe-main-${RUN_ID}"
CAGE_SYMLINK="l9hn-probe-symlink-${RUN_ID}"

cleanup() {
  msb remove -f "$CAGE_MAIN" >/dev/null 2>&1 || true
  msb remove -f "$CAGE_SYMLINK" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH_DIR" "$TEST_HOME"
  rm -f /tmp/l9hn-*.err
}
trap cleanup EXIT

# _host_denylist_check RESOLVED_PATH
# Runs _check_secret_path_denylist in a sandboxed HOME/XDG_CONFIG_HOME.
# Returns the function's exit code (0 = deny, 1 = allow).
_host_denylist_check() {
  local _path="$1"
  local _exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "
      source '$RC'
      _check_secret_path_denylist '$_path' '$TEST_WS'
    " 2>/dev/null || _exit_code=$?
  return "$_exit_code"
}

# ===========================================================================
# H1/H2/H3: host-side pre-flight gate -- still correct against msb-bound
# resolved paths (msb doesn't change what realpath means on the host; this
# confirms the invariant the live section then builds on)
# ===========================================================================
echo ""
echo "=== H1/H2/H3: host-side _check_secret_path_denylist against the fixture paths ==="

_h1_rc=0
_host_denylist_check "$RESOLVED_DENYLISTED" || _h1_rc=$?
if [[ "$_h1_rc" -eq 0 ]]; then
  pass "H1: direct denylisted path (${RESOLVED_DENYLISTED}) denied (exit 0)"
else
  fail "H1: expected deny (exit 0) for the direct denylisted path" "got exit ${_h1_rc}"
fi

_h2_rc=0
_host_denylist_check "$RESOLVED_SYMLINK" || _h2_rc=$?
if [[ "$_h2_rc" -eq 0 && "$RESOLVED_SYMLINK" == "$RESOLVED_DENYLISTED" ]]; then
  pass "H2: symlink-escape path resolves to the denylisted target and is denied (D7 realpath-first)"
else
  fail "H2: expected deny (exit 0) for the symlink-escape path, and resolved==denylisted" "exit=${_h2_rc} resolved_symlink=${RESOLVED_SYMLINK} resolved_denylisted=${RESOLVED_DENYLISTED}"
fi

_h3_rc=0
_host_denylist_check "$RESOLVED_CONTROL" || _h3_rc=$?
if [[ "$_h3_rc" -eq 1 ]]; then
  pass "H3: non-denylisted control path allowed (exit 1)"
else
  fail "H3: expected allow (exit 1) for the control path" "got exit ${_h3_rc}"
fi

# ===========================================================================
# L1/L2: CAGE_MAIN -- only the control mount is emitted (mirrors what the
# real create-path pipeline does: the denylisted mount never reaches the
# generator's config because H1 already denied it upstream)
# ===========================================================================
echo ""
echo "=== L1/L2: control mount readable + :ro enforced on a real msb cage ==="

MAIN_CFG=$(jq -nc --arg hp "$RESOLVED_CONTROL" \
  '{"mounts": [{"host_path": $hp, "guest_path": "/home/agent/rc-l9hn-control.txt", "kind": "file", "mode": "ro"}]}')
mapfile -t MAIN_FLAGS < <(_msb_flags_generate "$MAIN_CFG")
if [[ "${#MAIN_FLAGS[@]}" -gt 0 ]]; then
  pass "L setup: generator produced --mount-file flags for the control-only config"
else
  fail "L setup: generator produced no flags" ""
fi

if msb run -d --name "$CAGE_MAIN" --replace "${MAIN_FLAGS[@]}" "$IMAGE" -- sleep 300 >/tmp/l9hn-main-boot.err 2>&1; then
  pass "L setup: CAGE_MAIN boots from generator-emitted flags (control mount only)"
else
  fail "L setup: CAGE_MAIN failed to boot" "$(cat /tmp/l9hn-main-boot.err)"
fi

L1_OUT=$(msb exec "$CAGE_MAIN" -- sh -c 'cat /home/agent/rc-l9hn-control.txt' 2>/tmp/l9hn-l1.err)
if [[ "$L1_OUT" == "$CONTROL_CONTENT" ]]; then
  pass "L1 (criterion 2, positive control): control mount readable in-guest with its REAL content"
else
  fail "L1: expected the real control content in-guest" "got: '${L1_OUT}' stderr: $(cat /tmp/l9hn-l1.err)"
fi

L2_WRITE_RC=0
msb exec "$CAGE_MAIN" -- sh -c 'echo appended-by-test >> /home/agent/rc-l9hn-control.txt' >/tmp/l9hn-l2-write.err 2>&1 || L2_WRITE_RC=$?
if [[ "$L2_WRITE_RC" -ne 0 ]]; then
  pass "L2a (:ro live-verify): in-guest write to the :ro mount failed (exit ${L2_WRITE_RC})"
else
  fail "L2a: expected the in-guest write to a :ro mount to fail" "write succeeded, exit 0: $(cat /tmp/l9hn-l2-write.err)"
fi

L2_VERIFY=$(msb exec "$CAGE_MAIN" -- sh -c 'cat /home/agent/rc-l9hn-control.txt' 2>/dev/null)
if [[ "$L2_VERIFY" == "$CONTROL_CONTENT" ]]; then
  pass "L2b (:ro live-verify): content unchanged after the blocked write attempt"
else
  fail "L2b: expected content unchanged after the blocked write" "got: '${L2_VERIFY}'"
fi

# ===========================================================================
# L3: the denylisted mount was never emitted -- its content must be
# unreadable ANYWHERE in this real guest (not a host-side error check)
# ===========================================================================
echo ""
echo "=== L3: excluded denylisted mount -- sentinel unreadable anywhere in-guest ==="

L3_DEST_OUT=$(msb exec "$CAGE_MAIN" -- sh -c 'cat /home/agent/rc-l9hn-denied.txt' 2>/dev/null)
if [[ -z "$L3_DEST_OUT" ]]; then
  pass "L3a (criterion 1): in-guest read attempt of the would-be mount destination returns nothing"
else
  fail "L3a: expected empty read at the would-be denylisted destination" "got: '${L3_DEST_OUT}'"
fi

L3_GREP_OUT=$(msb exec "$CAGE_MAIN" -- sh -c "grep -ra '${SENTINEL}' / --exclude-dir=proc" 2>/dev/null)
if [[ -z "$L3_GREP_OUT" ]]; then
  pass "L3b (criterion 1): whole-guest-filesystem grep finds the sentinel NOWHERE -- confirms absence is real, not just the one undeclared path"
else
  fail "L3b: sentinel content found somewhere in the guest filesystem" "$L3_GREP_OUT"
fi

msb remove -f "$CAGE_MAIN" >/dev/null 2>&1 || true

# ===========================================================================
# L4: red-capability control -- mount the RESOLVED denylisted target
# directly (never the raw symlink; see the DISCOVERY note in the header --
# msb's --mount-file does not dereference a symlink SOURCE, so this probe
# uses the same resolved path H1 denied). Proves the L3 absence assertion
# would have gone RED had the mount actually been included.
# ===========================================================================
echo ""
echo "=== L4: red-capability control -- the same sentinel content IS readable in-guest when actually mounted ==="

RED_CFG=$(jq -nc --arg hp "$RESOLVED_DENYLISTED" \
  '{"mounts": [{"host_path": $hp, "guest_path": "/home/agent/rc-l9hn-would-be-denied.txt", "kind": "file"}]}')
mapfile -t RED_FLAGS < <(_msb_flags_generate "$RED_CFG")
if [[ "${#RED_FLAGS[@]}" -gt 0 ]]; then
  pass "L4 setup: generator produced --mount-file flags for the resolved-denylisted-path control config"
else
  fail "L4 setup: generator produced no flags" ""
fi

if msb run -d --name "$CAGE_SYMLINK" --replace "${RED_FLAGS[@]}" "$IMAGE" -- sleep 300 >/tmp/l9hn-symlink-boot.err 2>&1; then
  pass "L4 setup: CAGE_SYMLINK boots mounting the resolved denylisted target directly"
else
  fail "L4 setup: CAGE_SYMLINK failed to boot" "$(cat /tmp/l9hn-symlink-boot.err)"
fi

L4_OUT=$(msb exec "$CAGE_SYMLINK" -- sh -c 'cat /home/agent/rc-l9hn-would-be-denied.txt' 2>/tmp/l9hn-l4.err)
if [[ "$L4_OUT" == "$SENTINEL" ]]; then
  pass "L4 (red-capability check for L3): the same sentinel content IS readable in-guest when the mount is actually included -- proves L3's absence assertion is a real, red-capable detector, not a vacuous/broken check"
else
  fail "L4: expected the real sentinel content when the resolved path is actually mounted" "got: '${L4_OUT}' stderr: $(cat /tmp/l9hn-l4.err)"
fi

msb remove -f "$CAGE_SYMLINK" >/dev/null 2>&1 || true

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-msb-mount-denylist-live.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-msb-mount-denylist-live.sh: all ${TOTAL} tests passed ==="
