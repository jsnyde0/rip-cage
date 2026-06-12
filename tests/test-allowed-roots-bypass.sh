#!/usr/bin/env bash
# Regression net for RC_ALLOWED_ROOTS bypass attempts (rip-cage-36j).
#
# Pins the CURRENT behavior of validate_path / _path_under_allowed_roots
# against known bypass classes. No rc changes expected — these tests document
# how rc behaves today. If any REJECTION case fails, mark the bead blocked and
# file a follow-up for the actual fix.
#
# Coverage:
#   (1) workspace path that is a SYMLINK to a target OUTSIDE allowed roots
#       → rejected by validate_path after realpath (rc:750)
#   (2) --env-file that is a SYMLINK to a path OUTSIDE allowed roots
#       → rejected after realpath (validate_path on dirname of resolved env)
#   (3) .beads/redirect with ../ traversal resolving OUTSIDE allowed roots
#       → GRACEFUL IGNORE: warning logged, rc continues, no bad mount
#   (4) Non-existent leaf under a SYMLINKED parent (NanoClaw's case)
#       → rejected (symlink's target is outside roots; leaf doesn't exist)
#   (5) POSITIVE CONTROL: workspace genuinely INSIDE allowed roots
#       → accepted (exit 0, no error)
#
# ADR refs: ADR-003 D3 (allowed-roots check), ADR-023 D6 (denylist)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TEST_TMPDIR=""

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# Create a fresh sandbox per test:
#   TEST_TMPDIR     — temporary root (removed on EXIT)
#   INSIDE_ROOTS    — the directory configured as RC_ALLOWED_ROOTS
#   OUTSIDE_ROOTS   — a sibling directory NOT under RC_ALLOWED_ROOTS
#   TEST_HOME       — fake HOME with a minimal global config
#   TEST_WS         — a real workspace inside INSIDE_ROOTS
setup_sandbox() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-arb-test-XXXXXX")
  INSIDE_ROOTS="${TEST_TMPDIR}/inside"
  OUTSIDE_ROOTS="${TEST_TMPDIR}/outside"
  TEST_HOME="${TEST_TMPDIR}/home"
  TEST_WS="${INSIDE_ROOTS}/workspace"

  mkdir -p "$INSIDE_ROOTS"
  mkdir -p "$OUTSIDE_ROOTS"
  mkdir -p "$TEST_HOME/.config/rip-cage"
  mkdir -p "$TEST_WS"

  # Minimal global config: empty denylist (we test allowed-roots logic only)
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
}

teardown_sandbox() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
  INSIDE_ROOTS=""
  OUTSIDE_ROOTS=""
  TEST_HOME=""
  TEST_WS=""
}

echo "=== test-allowed-roots-bypass.sh — RC_ALLOWED_ROOTS bypass regression net (rip-cage-36j) ==="

# ---------------------------------------------------------------------------
# POSITIVE CONTROL (5): workspace genuinely INSIDE allowed roots → accepted
#
# This case MUST be tested first so we know validate_path is actually callable
# and RC_ALLOWED_ROOTS is correctly set. If this fails, the suite config is
# broken — a misset RC_ALLOWED_ROOTS would fail this case loud.
# ---------------------------------------------------------------------------
setup_sandbox

# Use realpath so that macOS /tmp → /private/tmp expansion is handled
REAL_INSIDE=$(realpath "$INSIDE_ROOTS" 2>/dev/null)

stderr_out5=""
exit_code5=0
stderr_out5=$(
  HOME="$TEST_HOME" \
  XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$REAL_INSIDE" \
  bash "$RC" up --dry-run "$TEST_WS" 2>&1 >/dev/null
) || exit_code5=$?

# --dry-run should not exit non-zero due to validate_path when path is inside roots.
# It may fail for Docker-absence or image-absence reasons — that is acceptable.
# What we must NOT see is "outside allowed roots" in stderr.
if printf '%s' "$stderr_out5" | grep -q "outside allowed roots"; then
  fail "(5) POSITIVE CONTROL: valid inside-roots workspace incorrectly rejected — stderr: $stderr_out5"
else
  pass "(5) POSITIVE CONTROL: inside-roots workspace accepted (no 'outside allowed roots' error)"
fi

teardown_sandbox

# ---------------------------------------------------------------------------
# REJECTION (1): workspace path is a SYMLINK to a target OUTSIDE allowed roots
#
# validate_path follows symlinks via realpath; the resolved path lands outside
# RC_ALLOWED_ROOTS; rc exits non-zero with "outside allowed roots" on stderr.
# ---------------------------------------------------------------------------
setup_sandbox

REAL_INSIDE=$(realpath "$INSIDE_ROOTS" 2>/dev/null)

# Create a symlink inside the roots pointing to the outside directory
ln -s "$OUTSIDE_ROOTS" "${INSIDE_ROOTS}/symlink_workspace"

stderr_out1=""
exit_code1=0
stderr_out1=$(
  HOME="$TEST_HOME" \
  XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$REAL_INSIDE" \
  bash "$RC" up --dry-run "${INSIDE_ROOTS}/symlink_workspace" 2>&1 >/dev/null
) || exit_code1=$?

if [[ "$exit_code1" -ne 0 ]] && printf '%s' "$stderr_out1" | grep -q "outside allowed roots"; then
  pass "(1) symlink workspace → outside roots rejected (exit=$exit_code1)"
else
  fail "(1) expected exit non-zero + 'outside allowed roots'; got exit=$exit_code1 stderr=$stderr_out1"
fi

teardown_sandbox

# ---------------------------------------------------------------------------
# REJECTION (2): --env-file is a SYMLINK to a path OUTSIDE allowed roots
#
# rc resolves the env-file via realpath, then calls validate_path on the
# resolved env-file's dirname. The resolved dirname is outside RC_ALLOWED_ROOTS
# so validate_path exits non-zero with "outside allowed roots" on stderr.
# ---------------------------------------------------------------------------
setup_sandbox

REAL_INSIDE=$(realpath "$INSIDE_ROOTS" 2>/dev/null)

# Create a real env file outside roots and a symlink inside roots pointing to it
touch "${OUTSIDE_ROOTS}/real.env"
ln -s "${OUTSIDE_ROOTS}/real.env" "${INSIDE_ROOTS}/symlink.env"

stderr_out2=""
exit_code2=0
stderr_out2=$(
  HOME="$TEST_HOME" \
  XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$REAL_INSIDE" \
  bash "$RC" up --dry-run --env-file "${INSIDE_ROOTS}/symlink.env" "$TEST_WS" 2>&1 >/dev/null
) || exit_code2=$?

if [[ "$exit_code2" -ne 0 ]] && printf '%s' "$stderr_out2" | grep -q "outside allowed roots"; then
  pass "(2) symlink env-file → outside roots rejected (exit=$exit_code2)"
else
  fail "(2) expected exit non-zero + 'outside allowed roots'; got exit=$exit_code2 stderr=$stderr_out2"
fi

teardown_sandbox

# ---------------------------------------------------------------------------
# GRACEFUL-IGNORE (3): .beads/redirect with ../ traversal resolving OUTSIDE
#
# The _up_prepare_environment function (rc:1725-1755) resolves the redirect,
# detects it is outside allowed roots, logs a warning, and CONTINUES without
# mounting the bad target. This is NOT a hard reject.
#
# We call _up_prepare_environment directly in a subshell (same technique as
# test-secret-path-denylist.sh case b') to reach the beads redirect code path
# that is only exercised after the --dry-run exit point.
# ---------------------------------------------------------------------------
setup_sandbox

REAL_INSIDE=$(realpath "$INSIDE_ROOTS" 2>/dev/null)

# Create a workspace with a .beads/ dir and a redirect file pointing outside roots.
# The redirect is a relative path that resolves to OUTSIDE_ROOTS via traversal.
mkdir -p "${TEST_WS}/.beads"
# Compute relative path from TEST_WS to OUTSIDE_ROOTS
# TEST_WS = INSIDE_ROOTS/workspace; OUTSIDE_ROOTS = TEST_TMPDIR/outside
# relative: ../../outside
printf '../../outside\n' > "${TEST_WS}/.beads/redirect"
# Make OUTSIDE_ROOTS look like a beads dir (must be a directory for realpath to resolve it)
mkdir -p "$OUTSIDE_ROOTS"

# Call _up_prepare_environment directly in a subshell, capturing stdout (log goes to stdout)
stdout_out3=""
exit_code3=0
stdout_out3=$(
  HOME="$TEST_HOME" \
  XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$REAL_INSIDE" \
  bash -c "
    source '$RC' 2>/dev/null
    _UP_RUN_ARGS=()
    wt_detected=false
    wt_main_git=''
    _up_prepare_environment '$TEST_WS' '' '' '2.0' '4g' '1024'
    # Print _UP_RUN_ARGS to check no outside-roots path was mounted
    for arg in \"\${_UP_RUN_ARGS[@]}\"; do
      printf 'ARG: %s\n' \"\$arg\"
    done
  "
) || exit_code3=$?

# Assert:
# a) rc does NOT exit non-zero due to the redirect (graceful ignore, not hard fail)
# b) stdout contains the "outside allowed roots — ignoring" warning
# c) OUTSIDE_ROOTS path is NOT in any mount arg (the bad target was not mounted)
REAL_OUTSIDE=$(realpath "$OUTSIDE_ROOTS" 2>/dev/null)

has_warning=false
has_bad_mount=false
if printf '%s' "$stdout_out3" | grep -q "outside allowed roots"; then
  has_warning=true
fi
if printf '%s' "$stdout_out3" | grep -q "ARG:.*${REAL_OUTSIDE}"; then
  has_bad_mount=true
fi

if [[ "$exit_code3" -eq 0 ]] && [[ "$has_warning" == "true" ]] && [[ "$has_bad_mount" == "false" ]]; then
  pass "(3) .beads/redirect outside roots: warning logged, no bad mount, rc continues (exit=$exit_code3)"
else
  reason=""
  [[ "$exit_code3" -ne 0 ]] && reason="exited non-zero ($exit_code3) — should be graceful ignore"
  [[ "$has_warning" == "false" ]] && reason="${reason:+$reason; }no 'outside allowed roots' warning in output"
  [[ "$has_bad_mount" == "true" ]] && reason="${reason:+$reason; }outside-roots path found in mount args"
  fail "(3) .beads/redirect graceful-ignore: $reason — stdout=$stdout_out3"
fi

teardown_sandbox

# ---------------------------------------------------------------------------
# REJECTION (4): Non-existent leaf under a SYMLINKED parent (NanoClaw's case)
#
# The symlink exists and points to a directory OUTSIDE allowed roots. A leaf
# path inside that symlinked directory does not exist yet. validate_path is
# called with the full leaf path. Expected: rejected (nonzero exit) because
# either the path doesn't exist or the resolved parent is outside allowed roots.
#
# Called via `rc up --dry-run` with the leaf path as the workspace argument.
# ---------------------------------------------------------------------------
setup_sandbox

REAL_INSIDE=$(realpath "$INSIDE_ROOTS" 2>/dev/null)

# Create the symlink to outside roots (the target dir exists)
ln -s "$OUTSIDE_ROOTS" "${INSIDE_ROOTS}/symlink_parent"
# The leaf directory does NOT exist inside the symlinked parent
LEAF_PATH="${INSIDE_ROOTS}/symlink_parent/nonexistent_leaf"

stderr_out4=""
exit_code4=0
stderr_out4=$(
  HOME="$TEST_HOME" \
  XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$REAL_INSIDE" \
  bash "$RC" up --dry-run "$LEAF_PATH" 2>&1 >/dev/null
) || exit_code4=$?

# The path does not exist → validate_path exits with "does not exist" error,
# OR if the path existed it would exit with "outside allowed roots". Either
# way, exit must be non-zero AND the message must be a validate_path rejection
# (not an incidental failure like docker-absence) — else this case could pass
# vacuously if --dry-run ever started exiting non-zero for unrelated reasons.
if [[ "$exit_code4" -ne 0 ]] && printf '%s' "$stderr_out4" | grep -qE "does not exist|outside allowed roots"; then
  pass "(4) non-existent leaf under symlinked outside-roots parent rejected (exit=$exit_code4)"
else
  fail "(4) expected exit non-zero + validate_path rejection message; got exit=$exit_code4 stderr=$stderr_out4"
fi

teardown_sandbox

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "--- Results: ${FAILURES} failure(s) ---"

exit "$FAILURES"
