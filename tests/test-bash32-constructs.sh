#!/usr/bin/env bash
# test-bash32-constructs.sh — bash-3.2 compatibility lint gate (rip-cage-vyko).
#
# rc must run on stock macOS /bin/bash 3.2.57 (FIRM, ADR-008-open-source-
# publication.md D5). Bash 3.2 predates bash 4's mapfile/readarray builtin,
# associative arrays (declare -A), and the ${VAR^^}/${VAR,,} case-conversion
# parameter expansions -- any of these silently break `rc up` etc. on a stock
# Mac with no error until the exact line executes (rip-cage-vyko: mapfile at
# cli/up.sh:1222/1233 did exactly this). This gate greps rc, cli/, cli/lib/,
# and cage/init/ for those bash-4-only constructs and fails naming file:line.
#
# Self-match note: this file's own body necessarily contains the pattern
# strings above (in this header, and in the grep patterns themselves). Every
# grep call below explicitly excludes THIS script's own path so the gate cannot
# trip on itself.
#
# Positive control (rip-cage-b8kd.18.5): the planted fixture is written at
# runtime (mktemp), holds one of each bash-4 construct, and each pattern below
# MUST hit it -- a typo that stops a pattern firing fails the self-check. The
# scans also run grep WITHOUT discarding stderr and treat grep exit >= 2 (an
# unreadable or missing target) as a failure, so an empty result can no longer
# mean "grep broke".
#
# Run from repo root: bash tests/test-bash32-constructs.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
SELF="${SCRIPT_DIR}/test-bash32-constructs.sh"
FAILURES=0

pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2 -- $3"; FAILURES=$((FAILURES + 1)); }

echo "=== test-bash32-constructs.sh — bash-3.2 compatibility lint gate ==="
echo ""

# Targets: rc (shim) + cli/ + cli/lib/ + cage/init/ -- the runtime surface
# that must execute under stock macOS /bin/bash 3.2.57.
_targets=("${REPO_ROOT}/rc")
while IFS= read -r _t; do
  [[ -z "$_t" ]] && continue
  _targets+=("$_t")
done < <(find "${REPO_ROOT}/cli" "${REPO_ROOT}/cage/init" -type f -name '*.sh' 2>/dev/null | grep -vF "$SELF")

# Patterns (one definition: the planted-fixture self-check and the scans share them).
_PAT_A='\<(mapfile|readarray)\>'
_PAT_B='declare[[:space:]]+-[a-zA-Z]*A'
_PAT_C='\$\{[a-zA-Z_][a-zA-Z0-9_]*(\[[^]]*\])?(\^\^?|,,?)'

# _scan <pattern> -- grep the targets; sets _hits and _scan_rc. Output minus this
# script's own lines. grep exit 0 = hit, 1 = clean, >= 2 = error (unreadable or
# missing target): stderr is NOT discarded, and the caller fails on >= 2.
_scan() {
  local _raw
  _raw=$(grep -nE "$1" "${_targets[@]}")
  _scan_rc=$?
  _hits=$(printf '%s\n' "$_raw" | grep -vF "$SELF" || true)
}

# ---------------------------------------------------------------------------
# (0) Self-check: each pattern fires on a planted fixture, and the target list
# is real. Without this, a broken pattern reads as a clean tree.
# ---------------------------------------------------------------------------
echo "=== (0) patterns fire on a planted fixture; targets readable ==="
_fixture=$(mktemp "${TMPDIR:-/tmp}/rc-bash32-fixture-XXXXXX")
trap 'rm -f "$_fixture"' EXIT
# shellcheck disable=SC2016 # literal bash-4 text, must not expand
printf '%s\n' 'mapfile arr < file' 'readarray arr < file' 'declare -A assoc' 'x=${VAR^^}' 'y=${VAR,,}' > "$_fixture"
# shellcheck disable=SC2016 # literal needle
for _p in A:_PAT_A:mapfile B:_PAT_B:declare C:_PAT_C:'${VAR'; do
  _id="${_p%%:*}"; _rest="${_p#*:}"; _var="${_rest%%:*}"; _needle="${_rest#*:}"
  if grep -E "${!_var}" "$_fixture" | grep -qF "$_needle"; then
    pass "(0$_id)" "pattern ${_var} fires on the planted fixture"
  else
    fail "(0$_id)" "pattern ${_var} did not fire on the planted bash-4 fixture" "$_fixture"
  fi
done
if [[ "${#_targets[@]}" -gt 1 ]]; then
  pass "(0T)" "${#_targets[@]} scan targets"
else
  fail "(0T)" "no cli/ or cage/init/ targets found" "${#_targets[@]} target(s)"
fi

echo ""

# ---------------------------------------------------------------------------
# (a) mapfile / readarray -- bash-4 builtins, absent entirely on bash 3.2.
# ---------------------------------------------------------------------------
echo "=== (a) no mapfile/readarray (bash-4 builtins) ==="
_scan "$_PAT_A"
if [[ "$_scan_rc" -ge 2 ]]; then
  fail "(a)" "grep error scanning targets" "exit ${_scan_rc}"
elif [[ -z "$_hits" ]]; then
  pass "(a)" "no mapfile/readarray usage found"
else
  while IFS= read -r _h; do
    [[ -z "$_h" ]] && continue
    fail "(a)" "bash-4 builtin (mapfile/readarray) found" "$_h"
  done <<< "$_hits"
fi

echo ""

# ---------------------------------------------------------------------------
# (b) declare -A -- associative arrays, bash-4-only.
# ---------------------------------------------------------------------------
echo "=== (b) no declare -A (associative arrays, bash-4-only) ==="
_scan "$_PAT_B"
if [[ "$_scan_rc" -ge 2 ]]; then
  fail "(b)" "grep error scanning targets" "exit ${_scan_rc}"
elif [[ -z "$_hits" ]]; then
  pass "(b)" "no declare -A usage found"
else
  while IFS= read -r _h; do
    [[ -z "$_h" ]] && continue
    fail "(b)" "bash-4 associative array (declare -A) found" "$_h"
  done <<< "$_hits"
fi

echo ""

# ---------------------------------------------------------------------------
# (c) ${VAR^^} / ${VAR,,} -- case-conversion parameter expansions, bash-4-only.
# ---------------------------------------------------------------------------
echo "=== (c) no \${VAR^^}/\${VAR,,} case-conversion expansions (bash-4-only) ==="
_scan "$_PAT_C"
if [[ "$_scan_rc" -ge 2 ]]; then
  fail "(c)" "grep error scanning targets" "exit ${_scan_rc}"
elif [[ -z "$_hits" ]]; then
  pass "(c)" "no \${VAR^^}/\${VAR,,} usage found"
else
  while IFS= read -r _h; do
    [[ -z "$_h" ]] && continue
    fail "(c)" "bash-4 case-conversion expansion found" "$_h"
  done <<< "$_hits"
fi

echo ""
echo "=== Summary: $FAILURES failure(s) ==="
exit $(( FAILURES > 0 ? 1 : 0 ))
