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
# strings above (in this header, and in the grep patterns themselves) plus a
# synthetic negative-control fixture below. Every grep call below explicitly
# excludes THIS script's own path so the gate cannot trip on itself.
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

# ---------------------------------------------------------------------------
# (a) mapfile / readarray -- bash-4 builtins, absent entirely on bash 3.2.
# ---------------------------------------------------------------------------
echo "=== (a) no mapfile/readarray (bash-4 builtins) ==="
_hits=$(grep -nE '\<(mapfile|readarray)\>' "${_targets[@]}" 2>/dev/null | grep -vF "$SELF" || true)
if [[ -z "$_hits" ]]; then
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
_hits=$(grep -nE 'declare[[:space:]]+-[a-zA-Z]*A' "${_targets[@]}" 2>/dev/null | grep -vF "$SELF" || true)
if [[ -z "$_hits" ]]; then
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
_hits=$(grep -nE '\$\{[a-zA-Z_][a-zA-Z0-9_]*(\[[^]]*\])?(\^\^?|,,?)' "${_targets[@]}" 2>/dev/null | grep -vF "$SELF" || true)
if [[ -z "$_hits" ]]; then
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
