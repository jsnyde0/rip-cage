#!/usr/bin/env bash
# tests/test-scratch-cage-cleanup.sh — Harness for rip-cage-aqww scratch-cage cleanup.
#
# Tests the D1 helper (_scratch-cage-lib.sh, register-array destroy-by-name —
# already fail-safe) and the D2 driver DETECT-AND-WARN (run-host.sh).
#
# rip-cage-neu7.9 (post code-personal destroy incident): the D2 mechanism used
# to be an enumerate-and-destroy sweep. It is now READ-ONLY — it names a
# leftover temp-root cage in a loud warning (with a suggested `rc destroy
# --force <name>` command) and NEVER destroys it. A cage the runner did not
# create must be structurally unreachable by any destroy call; individual
# tests self-reap their own cages via the D1 helper / explicit teardown.
#
# Cases:
#  (1) Normal-exit and SIGTERM-mid-run of a real scratch-cage test: assert zero
#      residual containers + volumes under the test temp root (D1 helper).
#  (2) Daemon-death residue: construct an Exited container (with volumes) whose
#      label is under the temp root, and a second whose workspace dir is DELETED
#      before the warn detector runs; both must be NAMED in the warning output
#      and both must STILL EXIST afterward (D2 never destroys).
#  (3) Positive controls: a container labeled OUTSIDE temp root survives and is
#      NOT named; a real cage's dangling rc-history-* volume (container removed)
#      survives (no blanket volume sweep).
#  (4) macOS realpath case: label carries realpath form (/private/var/folders/...)
#      is matched (NAMED, not destroyed) when the temp root is realpath'd (but
#      NOT the label).
#  (5) Trap composition: a shell with a pre-existing EXIT trap sources the helper
#      and registers a cage; BOTH the prior cleanup and scratch cleanup fire
#      (D1 helper — unaffected by the D2 detect-and-warn conversion).
#
# Exit: $FAILURES (silent-red guard per rip-cage-test-fail-prose-without-exit-silent-red).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FAILURES=0
PASS_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# rip-cage-5iti (S10, msb migration test-suite port): retargeted onto msb --
# fixtures are now real (cheap, ~0.15s) `msb create` sandboxes booted from
# the locally-cached `alpine` image, carrying the same rc.source.path label
# a real cage gets, plus two named `rc-state-*`/`rc-history-*` volumes
# (msb's own volume primitive — `msb volume create`/`remove`, no docker
# volume equivalent). `run_sweep()` below is the msb-side mirror of
# run-host.sh's `_sweep_scratch_cages` (same discriminator: enumerate every
# sandbox via `msb list --format json`, read each one's rc.source.path
# label via `msb inspect`, destroy only those under a swept temp root) —
# kept in lockstep with that function intentionally (comment there points
# back here).
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | jq -e '.[] | select(.reference == "alpine")' >/dev/null 2>&1; then
  echo "SKIP: msb has no locally-cached 'alpine' image -- skipping $(basename "$0") (fixtures need a fast-boot image; run 'msb pull alpine' once to cache it)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Temp root: realpath-resolved (macOS /var/folders -> /private/var/folders).
TEST_TEMP_ROOT=""
TEST_TEMP_ROOT=$(realpath "${TMPDIR:-/tmp}" 2>/dev/null || true)
if [[ -z "$TEST_TEMP_ROOT" ]]; then
  TEST_TEMP_ROOT="${TMPDIR:-/tmp}"
fi

# Create a scratch workspace under the temp root (realpath-resolved).
make_scratch_workspace() {
  local _tmp
  _tmp=$(mktemp -d)
  realpath "$_tmp" 2>/dev/null || echo "$_tmp"
}

# Count rc-{state,history} volumes for a given container name.
count_volumes_for() {
  local _cname="$1"
  local _cnt=0
  msb volume inspect "rc-state-${_cname}" >/dev/null 2>&1 && _cnt=$((_cnt + 1)) || true
  msb volume inspect "rc-history-${_cname}" >/dev/null 2>&1 && _cnt=$((_cnt + 1)) || true
  echo "$_cnt"
}

# msb-side counterpart of `docker inspect NAME` existence check.
sandbox_exists() {
  msb inspect "$1" --format json >/dev/null 2>&1
}

# Create a test fixture sandbox (not a real rc cage — a bare `alpine` boot)
# with the rc.source.path label set to $2 and two named volumes attached
# (mirrors what a real rc-created cage carries: rc-state-<name> +
# rc-history-<name>). Args: $1=sandbox-name $2=label-value
create_fixture_container() {
  local _cname="$1"
  local _label="$2"
  msb volume create "rc-state-${_cname}" >/dev/null 2>&1 || true
  msb volume create "rc-history-${_cname}" >/dev/null 2>&1 || true
  msb create -n "$_cname" alpine \
    --label "rc.source.path=${_label}" \
    --mount-named "rc-state-${_cname}:/rc-state-data" \
    --mount-named "rc-history-${_cname}:/rc-history-data" \
    -q >/dev/null 2>&1
}

# Force-remove a fixture sandbox and its volumes (for cleanup after a test).
teardown_fixture() {
  local _cname="$1"
  msb remove --force "$_cname" >/dev/null 2>&1 || true
  msb volume remove "rc-state-${_cname}" >/dev/null 2>&1 || true
  msb volume remove "rc-history-${_cname}" >/dev/null 2>&1 || true
}

# Run the D2 detect-and-warn inline (mirrors run-host.sh's
# _warn_leftover_scratch_cages exactly). READ-ONLY: enumerates via `msb list`
# same as before, but NEVER destroys — prints a warning naming each leftover
# temp-root cage (name + source path + a suggested `rc destroy --force`
# command) to stderr instead. rip-cage-neu7.9: replaces the former
# enumerate-and-destroy sweep (a leftover cage the runner did not create must
# be structurally unreachable by any destroy call).
# Args: $1=temp_root (already realpath-resolved)
run_warn() {
  local _root="$1"
  local _cname _raw_sp
  local _warn_roots=()
  _warn_roots+=("$_root")
  for _lit in "/private/var/folders" "/tmp" "/private/tmp"; do
    local _already=0
    local _existing
    for _existing in "${_warn_roots[@]+"${_warn_roots[@]}"}"; do
      [[ "$_existing" == "$_lit" ]] && _already=1
    done
    [[ "$_already" -eq 0 ]] && _warn_roots+=("$_lit")
  done

  for _cname in $(msb list --format json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true); do
    _raw_sp=$(msb inspect "$_cname" --format json 2>/dev/null | jq -r '.config.labels["rc.source.path"] // empty' 2>/dev/null || true)
    [[ -z "$_raw_sp" ]] && continue
    local _root2
    for _root2 in "${_warn_roots[@]+"${_warn_roots[@]}"}"; do
      if [[ "$_raw_sp" == "${_root2}"/* || "$_raw_sp" == "${_root2}" ]]; then
        echo "WARNING: leftover scratch cage detected: ${_cname} (source path: ${_raw_sp})" >&2
        echo "  Suggested cleanup: rc destroy --force ${_cname}" >&2
        break
      fi
    done
  done
}

echo "=== test-scratch-cage-cleanup.sh ==="

# ============================================================================
# Case (1): Normal-exit of a real scratch-cage test via the D1 helper.
#           Also tests SIGTERM-mid-run via a subprocess.
# ============================================================================
echo ""
echo "--- Case 1: D1 helper cleanup (normal-exit and SIGTERM) ---"

# Create a scratch workspace.
C1_WS=$(make_scratch_workspace)
# We will test the D1 helper by running it in a subprocess that creates a
# real rc cage (rc up) — BUT to avoid needing a full rc up (which needs an image,
# git repo, etc), we test the helper's destroy-on-exit behavior by creating a
# fixture container directly and then running a subprocess that sources the lib
# and registers a container by name. The trap should destroy it.

# Case 1a: Normal exit — subprocess sources lib, registers, exits normally.
C1A_WS="${C1_WS}/case1a"
mkdir -p "$C1A_WS"
C1A_NAME="rip-cage-cleanup-test-1a-$$"
# Create the fixture container with the label pointing to this workspace.
create_fixture_container "$C1A_NAME" "$C1A_WS"

# Run a subprocess that sources the lib and registers the container, then exits 0.
# The lib's EXIT trap should call rc destroy --force on the container.
bash -c "
  SCRIPT_DIR='${SCRIPT_DIR}'
  source '${SCRIPT_DIR}/_scratch-cage-lib.sh'
  scratch_cage_register '${C1A_NAME}'
  exit 0
" >/dev/null 2>&1
_exit=$?

# Verify: container and both volumes should be gone.
_cexists=0
sandbox_exists "$C1A_NAME" && _cexists=1 || true
_vols=$(count_volumes_for "$C1A_NAME")

if [[ "$_cexists" -eq 0 && "$_vols" -eq 0 ]]; then
  pass "Case 1a: normal-exit removes container + both volumes"
else
  fail "Case 1a: normal-exit — container_exists=$_cexists volumes=$_vols (expected 0+0)"
  # Cleanup manually so subsequent cases aren't polluted.
  teardown_fixture "$C1A_NAME"
fi

# Case 1b: SIGTERM mid-run — subprocess registers, then we SIGTERM it.
C1B_WS="${C1_WS}/case1b"
mkdir -p "$C1B_WS"
C1B_NAME="rip-cage-cleanup-test-1b-$$"
create_fixture_container "$C1B_NAME" "$C1B_WS"

# Run a subprocess that sources the lib, registers, then sleeps (simulating work).
# We SIGTERM it after giving it a moment to arm the trap.
bash -c "
  SCRIPT_DIR='${SCRIPT_DIR}'
  source '${SCRIPT_DIR}/_scratch-cage-lib.sh'
  scratch_cage_register '${C1B_NAME}'
  sleep 30
" >/dev/null 2>&1 &
_bg_pid=$!
# Give the subprocess time to arm the trap.
sleep 1
kill -TERM "$_bg_pid" 2>/dev/null || true
wait "$_bg_pid" 2>/dev/null || true
# Give the destroy a moment to complete.
sleep 1

_cexists=0
sandbox_exists "$C1B_NAME" && _cexists=1 || true
_vols=$(count_volumes_for "$C1B_NAME")

if [[ "$_cexists" -eq 0 && "$_vols" -eq 0 ]]; then
  pass "Case 1b: SIGTERM-mid-run removes container + both volumes"
else
  fail "Case 1b: SIGTERM-mid-run — container_exists=$_cexists volumes=$_vols (expected 0+0)"
  teardown_fixture "$C1B_NAME"
fi

# Cleanup workspace.
rm -rf "$C1_WS"

# ============================================================================
# Case (2): Daemon-death residue shape — Exited container with label under temp
#           root is reaped by the D2 sweep. Two fixtures:
#           (2a) workspace dir still exists when sweep runs
#           (2b) workspace dir DELETED before sweep (the dominant cross-run shape)
# ============================================================================
echo ""
echo "--- Case 2: D2 sweep reaps daemon-death residue ---"

# Case 2a: dir still exists.
C2A_WS=$(make_scratch_workspace)
C2A_NAME="rip-cage-cleanup-test-2a-$$"
create_fixture_container "$C2A_NAME" "$C2A_WS"

_warn_out=$(run_warn "$TEST_TEMP_ROOT" 2>&1)

_cexists=0
sandbox_exists "$C2A_NAME" && _cexists=1 || true
_vols=$(count_volumes_for "$C2A_NAME")

if [[ "$_cexists" -eq 1 && "$_vols" -eq 2 && "$_warn_out" == *"$C2A_NAME"* ]]; then
  pass "Case 2a: warn NAMES the leftover cage (dir exists) but does NOT destroy it (container+both volumes still present)"
else
  fail "Case 2a: expected warn-and-survive — container_exists=$_cexists volumes=$_vols named=$([[ "$_warn_out" == *"$C2A_NAME"* ]] && echo yes || echo no)"
fi
teardown_fixture "$C2A_NAME"
rm -rf "$C2A_WS"

# Case 2b: workspace dir DELETED before warn — this is the load-bearing case.
# A correct detector reads the label as a RAW STRING and compares to the
# realpath'd temp root WITHOUT realpath-ing the label.  If it were to realpath
# the label, BSD realpath would return empty on the missing path → silent miss.
C2B_WS=$(make_scratch_workspace)
C2B_NAME="rip-cage-cleanup-test-2b-$$"
create_fixture_container "$C2B_NAME" "$C2B_WS"
# DELETE the workspace dir before running the warn detector.
rm -rf "$C2B_WS"

_warn_out=$(run_warn "$TEST_TEMP_ROOT" 2>&1)

_cexists=0
sandbox_exists "$C2B_NAME" && _cexists=1 || true
_vols=$(count_volumes_for "$C2B_NAME")

if [[ "$_cexists" -eq 1 && "$_vols" -eq 2 && "$_warn_out" == *"$C2B_NAME"* ]]; then
  pass "Case 2b: warn NAMES the leftover cage (workspace dir ALREADY DELETED) but does NOT destroy it"
else
  fail "Case 2b: MISSED — this catches the realpath-label bug; container_exists=$_cexists volumes=$_vols named=$([[ "$_warn_out" == *"$C2B_NAME"* ]] && echo yes || echo no)"
fi
teardown_fixture "$C2B_NAME"

# ============================================================================
# Case (3): Positive controls — discriminator safety.
#           (3a) Container labeled OUTSIDE the temp root survives and is NOT
#                named in the warn output.
#           (3b) A dangling rc-history-* volume (no container) survives — proves
#                the blanket volume sweep is absent.
# ============================================================================
echo ""
echo "--- Case 3: Positive controls (discriminator safety) ---"

# Case 3a: container labeled outside the temp root.
C3A_OUTSIDE="/usr/local/share/rip-cage-test-positive-control-$$"
C3A_NAME="rip-cage-cleanup-test-3a-$$"
# Create fixture with label outside temp root.
msb create -n "$C3A_NAME" alpine \
  --label "rc.source.path=${C3A_OUTSIDE}" \
  -q >/dev/null 2>&1

_warn_out=$(run_warn "$TEST_TEMP_ROOT" 2>&1)

_cexists=0
sandbox_exists "$C3A_NAME" && _cexists=1 || true

if [[ "$_cexists" -eq 1 && "$_warn_out" != *"$C3A_NAME"* ]]; then
  pass "Case 3a: container labeled OUTSIDE temp root SURVIVES and is NOT named in warn output"
else
  fail "Case 3a: discriminator over-reach — container_exists=$_cexists named=$([[ "$_warn_out" == *"$C3A_NAME"* ]] && echo yes || echo no)"
fi
# Cleanup 3a.
msb remove --force "$C3A_NAME" >/dev/null 2>&1 || true

# Case 3b: a dangling rc-history-* volume (container already removed) survives.
C3B_VOL="rc-history-rip-cage-cleanup-test-3b-$$"
msb volume create "$C3B_VOL" >/dev/null 2>&1

run_warn "$TEST_TEMP_ROOT" >/dev/null 2>&1

_vexists=0
msb volume inspect "$C3B_VOL" >/dev/null 2>&1 && _vexists=1 || true

if [[ "$_vexists" -eq 1 ]]; then
  pass "Case 3b: dangling rc-history-* volume (no container) SURVIVES — blanket volume sweep is absent"
else
  fail "Case 3b: dangling volume without a matching container vanished (blanket sweep present — design violation)"
fi
# Cleanup 3b.
msb volume remove "$C3B_VOL" >/dev/null 2>&1 || true

# ============================================================================
# Case (4): macOS realpath case.
#           The cage label carries the realpath form (/private/var/folders/...)
#           The warn detector must match it when the temp root is
#           realpath-resolved. This proves: (a) the temp root IS realpath'd
#           before compare, (b) the label is NOT realpath'd at detect time,
#           (c) a match is NAMED, never destroyed.
# ============================================================================
echo ""
echo "--- Case 4: macOS realpath form (/private/var/folders/...) ---"

# Determine the realpath form of the temp root.
C4_REALPATH_ROOT=$(realpath "${TMPDIR:-/tmp}" 2>/dev/null || echo "${TMPDIR:-/tmp}")
C4_WS="${C4_REALPATH_ROOT}/rip-cage-cleanup-test-4-$$"
mkdir -p "$C4_WS"
C4_NAME="rip-cage-cleanup-test-4-$$"
# Create fixture with the label set to the ALREADY-realpath'd form (as rc does at cage creation).
create_fixture_container "$C4_NAME" "$C4_WS"

_warn_out=$(run_warn "$TEST_TEMP_ROOT" 2>&1)

_cexists=0
sandbox_exists "$C4_NAME" && _cexists=1 || true
_vols=$(count_volumes_for "$C4_NAME")

if [[ "$_cexists" -eq 1 && "$_vols" -eq 2 && "$_warn_out" == *"$C4_NAME"* ]]; then
  pass "Case 4: macOS realpath label form is matched and NAMED, but NOT destroyed"
else
  fail "Case 4: missed container with realpath label form — container_exists=$_cexists volumes=$_vols named=$([[ "$_warn_out" == *"$C4_NAME"* ]] && echo yes || echo no)"
fi
teardown_fixture "$C4_NAME"
rm -rf "$C4_WS"

# ============================================================================
# Case (5): Trap composition.
#           A shell with a pre-existing EXIT trap sources the helper and registers
#           a cage; BOTH the prior trap body AND the scratch cleanup fire.
# ============================================================================
echo ""
echo "--- Case 5: Trap composition (pre-existing EXIT trap + scratch cleanup) ---"

C5_WS=$(make_scratch_workspace)
C5_NAME="rip-cage-cleanup-test-5-$$"
create_fixture_container "$C5_NAME" "$C5_WS"

# Sentinel file: written by the pre-existing trap.
C5_SENTINEL="${C5_WS}/prior-trap-fired"

# Subprocess: has a pre-existing EXIT trap that writes the sentinel, THEN sources
# the lib and registers the container.  On exit, BOTH should fire.
bash -c "
  SCRIPT_DIR='${SCRIPT_DIR}'
  _sentinel='${C5_SENTINEL}'
  trap 'touch \"\$_sentinel\"' EXIT
  source '${SCRIPT_DIR}/_scratch-cage-lib.sh'
  scratch_cage_register '${C5_NAME}'
  exit 0
" >/dev/null 2>&1

_cexists=0
sandbox_exists "$C5_NAME" && _cexists=1 || true
_vols=$(count_volumes_for "$C5_NAME")
_sentinel_exists=0
[[ -f "$C5_SENTINEL" ]] && _sentinel_exists=1

if [[ "$_cexists" -eq 0 && "$_vols" -eq 0 && "$_sentinel_exists" -eq 1 ]]; then
  pass "Case 5: trap-composition — prior EXIT trap AND scratch cleanup both fired"
elif [[ "$_sentinel_exists" -eq 0 ]]; then
  fail "Case 5: prior EXIT trap did NOT fire (trap clobbered by scratch-cage-lib)"
  teardown_fixture "$C5_NAME"
else
  fail "Case 5: scratch cleanup did NOT fire — container_exists=$_cexists volumes=$_vols"
  teardown_fixture "$C5_NAME"
fi
rm -rf "$C5_WS"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== test-scratch-cage-cleanup.sh: PASS=$PASS_COUNT FAIL=$FAILURES ==="

exit "$FAILURES"
