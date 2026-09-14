#!/usr/bin/env bash
# tests/test-host-scratch-root.sh — unit tests for the suite's scratch-root
# helper (tests/_host-sandbox-lib.sh, rip-cage-6v34.6).
#
# Any temp dir that becomes a cage WORKSPACE or a `HOME` handed to `rc up`
# must live under a root that is SHORT and SYMLINK-FREE:
#
#   SHORT     msb derives a per-sandbox Unix socket path from MSB_HOME (which
#             defaults to $HOME/.microsandbox) and refuses to create the
#             sandbox when the shortest derived path exceeds the platform's
#             104-byte AF_UNIX limit. Measured on msb 0.6.18: a 71-byte HOME
#             produced a 135-byte derived path, i.e. msb spends ~64 bytes of
#             the budget on its own suffix.
#   SYMLINK-  msb >= 0.6.16 refuses any mount whose host source traverses a
#   FREE      symlink, killing guest boot with `mount <tag>: Not a directory
#             (os error 20)`. macOS's default temp root is /var/folders/...,
#             and /var is a symlink to /private/var.
#
# Pure host-side — no cage, no msb daemon.
#
# Run from repo root: bash tests/test-host-scratch-root.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

# Bytes msb adds to MSB_HOME's parent when deriving a sandbox socket path,
# measured on 0.6.18 (71-byte HOME -> "shortest derived path is 135 bytes").
MSB_SOCKET_OVERHEAD=64
MSB_SOCKET_LIMIT=104

# shellcheck source=tests/_host-sandbox-lib.sh
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"

_CLEANUP_DIRS=()
# shellcheck disable=SC2317  # invoked via the EXIT trap below
_cleanup() { local d; for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do rm -rf "$d"; done; }
trap '_cleanup' EXIT

echo "=== test-host-scratch-root.sh — suite scratch-root helper ==="

echo ""
echo "=== S1: helper returns a dir under the short root ==="
S1_DIR=$(_host_scratch_mktemp_d s1)
_CLEANUP_DIRS+=("$S1_DIR")
if [[ -d "$S1_DIR" && "$S1_DIR" == "${_HOST_SCRATCH_ROOT}/"* ]]; then
  pass "S1: created under \$_HOST_SCRATCH_ROOT -- $S1_DIR"
else
  fail "S1: not under the short root" "root='${_HOST_SCRATCH_ROOT}' got='$S1_DIR'"
fi

echo ""
echo "=== S2: the returned path is symlink-free ==="
S2_PHYS=$(cd "$S1_DIR" && pwd -P)
if [[ "$S2_PHYS" == "$S1_DIR" ]]; then
  pass "S2: path equals its own physical form (no symlink traversal)"
else
  fail "S2: path traverses a symlink" "given='$S1_DIR' physical='$S2_PHYS'"
fi

echo ""
echo "=== S3: the path fits msb's 104-byte socket budget ==="
S3_BUDGET=$(( ${#S1_DIR} + MSB_SOCKET_OVERHEAD ))
if [[ "$S3_BUDGET" -lt "$MSB_SOCKET_LIMIT" ]]; then
  pass "S3: ${#S1_DIR} bytes + ${MSB_SOCKET_OVERHEAD} msb overhead = ${S3_BUDGET} < ${MSB_SOCKET_LIMIT}"
else
  fail "S3: scratch root too long for msb" \
    "'$S1_DIR' is ${#S1_DIR} bytes; +${MSB_SOCKET_OVERHEAD} = ${S3_BUDGET} >= ${MSB_SOCKET_LIMIT}. Fix-hint: export RC_TEST_TMPDIR=<a shorter dir under \$HOME> and re-run."
fi

echo ""
echo "=== S4: RC_TEST_TMPDIR overrides the default root ==="
S4_ROOT="${HOME}/.cache/rc-t4"
mkdir -p "$S4_ROOT"
_CLEANUP_DIRS+=("$S4_ROOT")
S4_OUT=$( RC_TEST_TMPDIR="$S4_ROOT" bash -c '
  SCRIPT_DIR="'"${SCRIPT_DIR}"'"
  source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
  _host_scratch_mktemp_d s4' )
if [[ "$S4_OUT" == "${S4_ROOT}/"* ]]; then
  pass "S4: honored RC_TEST_TMPDIR -- $S4_OUT"
else
  fail "S4: RC_TEST_TMPDIR ignored" "want prefix='${S4_ROOT}/' got='$S4_OUT'"
fi

echo ""
echo "=== S5: NEGATIVE CONTROL -- a bare \`mktemp -d\` does NOT land in the short root ==="
# This is the case that proves the helper earns its keep. Exporting TMPDIR is
# NOT sufficient on macOS: BSD mktemp ignores $TMPDIR when called with no
# template. If this assertion ever flips on a platform where a bare
# `mktemp -d` DOES honor TMPDIR (GNU coreutils), the check reports that
# explicitly rather than silently passing for the wrong reason.
S5_BARE=$(mktemp -d)
_CLEANUP_DIRS+=("$S5_BARE")
if [[ "$S5_BARE" != "${_HOST_SCRATCH_ROOT}/"* ]]; then
  pass "S5: bare mktemp -d escaped the root ($S5_BARE) -- the explicit helper is load-bearing"
elif [[ "$(uname -s)" != "Darwin" ]]; then
  pass "S5: bare mktemp -d honors \$TMPDIR on $(uname -s) -- helper still correct, just redundant here"
else
  fail "S5: bare mktemp -d unexpectedly landed in the short root on macOS" \
    "got='$S5_BARE' -- re-check whether the helper is still needed"
fi

echo ""
echo "=== test-host-scratch-root.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
