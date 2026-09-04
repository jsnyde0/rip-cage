#!/usr/bin/env bash
# test-manifest-postgres-pgvector-fragment.sh — guards for the postgres-pgvector
# IN-CAGE-DAEMON recipe (rip-cage-z40e). Host-only; no container, no network.
#
# WHY THIS FILE EXISTS
#
# 1. FRESHNESS. examples/postgres-pgvector/manifest-fragment.yaml is GENERATED — it
#    embeds postgres-start.sh and smoke.sh as base64 inside a single-line install_cmd.
#    Editing either script without re-running build-fragment.sh ships a fragment whose
#    payload silently no longer matches its source. Asserting on ENCODED text is exactly
#    how the retired ssh-bypass hook rotted unnoticed (rip-cage-bqm8); the claude recipe
#    already has such a guard, and this recipe is the second generated fragment in the
#    tree. Same rot, same guard.
#
# 2. EXEC-PREFIX REGRESSION. The manifest's `start` MUST begin with `exec`. Without it,
#    init records a forked wrapper shell's PID instead of the postmaster's, that wrapper
#    outlives a crashed cluster, and `kill -0` reports a dead database as healthy forever
#    (measured live, rip-cage-z40e). That defect is INVISIBLE to a start-then-health-check
#    test — both the healthy path and the idempotent-no-op path look correct — so a plain
#    lifecycle test would not catch its return. This assertion is the only cheap guard.
#
# 3. NEVER-BLESSED. ADR-005 D12 (FIRM): the recipe lives in examples/ only. It must never
#    reach manifest/default-tools.yaml, and rc source must never name it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RECIPE_DIR="${REPO_ROOT}/examples/postgres-pgvector"
FRAGMENT="${RECIPE_DIR}/manifest-fragment.yaml"
DIST_MANIFEST="${REPO_ROOT}/manifest/default-tools.yaml"

FAILURES=0
TOTAL=0
TMP_DIRS=()

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1${2:+ -- $2}"; }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup EXIT

echo "=== test-manifest-postgres-pgvector-fragment.sh ==="

# ---------------------------------------------------------------------------
# T1: the checked-in fragment is what the generator produces RIGHT NOW.
# Regenerate into a COPY of the recipe dir so the test never mutates the repo.
# ---------------------------------------------------------------------------
_scratch="$(mktemp -d)"
TMP_DIRS+=("$_scratch")
if cp -R "$RECIPE_DIR" "${_scratch}/recipe" 2>/dev/null \
   && bash "${_scratch}/recipe/build-fragment.sh" >/dev/null 2>&1; then
  if diff -q "$FRAGMENT" "${_scratch}/recipe/manifest-fragment.yaml" >/dev/null 2>&1; then
    pass "fragment freshness: build-fragment.sh reproduces the checked-in manifest-fragment.yaml"
  else
    fail "fragment freshness: checked-in manifest-fragment.yaml is STALE" \
         "re-run: bash examples/postgres-pgvector/build-fragment.sh"
  fi
else
  fail "fragment freshness: could not regenerate into a scratch copy"
fi

# ---------------------------------------------------------------------------
# T2: the required IN-CAGE-DAEMON shape, read from the fragment itself.
# ---------------------------------------------------------------------------
if ! command -v yq >/dev/null 2>&1; then
  fail "yq is required to read the fragment"
else
  _archetype="$(yq -r '.tools[0].archetype' "$FRAGMENT" 2>/dev/null)"
  [[ "$_archetype" == "IN-CAGE-DAEMON" ]] \
    && pass "archetype is IN-CAGE-DAEMON" \
    || fail "archetype is IN-CAGE-DAEMON" "got: $_archetype"

  for _field in install_cmd start health state_dir; do
    _v="$(yq -r ".tools[0].${_field} // \"\"" "$FRAGMENT" 2>/dev/null)"
    [[ -n "$_v" ]] \
      && pass "required field '${_field}' present" \
      || fail "required field '${_field}' present" "empty or absent"
  done

  # T2b: THE EXEC PREFIX. See header note 2 — this is the false-healthy guard.
  _start="$(yq -r '.tools[0].start' "$FRAGMENT" 2>/dev/null)"
  if [[ "$_start" == exec\ * ]]; then
    pass "start is exec-prefixed (recorded PID is the postmaster, not a wrapper shell)"
  else
    fail "start MUST begin with 'exec'" \
         "got: '${_start}' — without exec, init records a wrapper shell that outlives a crashed cluster, so a dead database reports healthy forever (rip-cage-z40e)"
  fi

  # T2c: egress must stay empty — the cluster is loopback-only (acceptance #3).
  _egress_n="$(yq -r '.tools[0].egress | length' "$FRAGMENT" 2>/dev/null)"
  [[ "$_egress_n" == "0" ]] \
    && pass "egress is empty (loopback-only; recipe adds no host to any allowlist)" \
    || fail "egress is empty" "got ${_egress_n} entries — a localhost daemon must need none"

  # T2d: install_cmd must be ONE line (the validator rejects multi-line; a generator
  # change that line-wrapped the base64 would break the build, not this test's absence).
  _lines="$(yq -r '.tools[0].install_cmd' "$FRAGMENT" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$_lines" == "1" ]] \
    && pass "install_cmd is a single line" \
    || fail "install_cmd is a single line" "got ${_lines} lines"
fi

# ---------------------------------------------------------------------------
# T3: the fragment passes the fail-closed validator as a standalone manifest.
# That is the copy-paste path a reader actually takes.
# ---------------------------------------------------------------------------
if [[ -f "${REPO_ROOT}/cli/lib/manifest_checks.sh" ]]; then
  if ( set +u; source "${REPO_ROOT}/cli/lib/manifest_checks.sh" >/dev/null 2>&1 \
       && _manifest_validate "$FRAGMENT" >/dev/null 2>&1 ); then
    pass "fragment passes _manifest_validate fail-closed (ADR-005 D11)"
  else
    fail "fragment passes _manifest_validate fail-closed"
  fi
else
  fail "cli/lib/manifest_checks.sh not found"
fi

# ---------------------------------------------------------------------------
# T4: never blessed by default (ADR-005 D12, FIRM).
# ---------------------------------------------------------------------------
if grep -q "postgres-pgvector" "$DIST_MANIFEST" 2>/dev/null; then
  fail "recipe is NOT in manifest/default-tools.yaml" "found — ADR-005 D12 FIRM forbids blessing it"
else
  pass "recipe is NOT in manifest/default-tools.yaml (ADR-005 D12 FIRM)"
fi

_named_in_rc=$(grep -rl "postgres-pgvector" \
  "${REPO_ROOT}/rc" "${REPO_ROOT}/cli" "${REPO_ROOT}/cage" "${REPO_ROOT}/manifest" 2>/dev/null | wc -l | tr -d ' ')
[[ "$_named_in_rc" == "0" ]] \
  && pass "rc source never names the recipe (composable seam, not a bundler)" \
  || fail "rc source never names the recipe" "${_named_in_rc} file(s) reference it"

# ---------------------------------------------------------------------------
# T5: the smoke test the recipe bakes is the one checked in beside it.
# ---------------------------------------------------------------------------
if [[ -x "${RECIPE_DIR}/smoke.sh" && -x "${RECIPE_DIR}/postgres-start.sh" ]]; then
  pass "launcher and smoke test are present and executable"
else
  fail "launcher and smoke test are present and executable"
fi

echo ""
echo "=== Results: $((TOTAL - FAILURES)) passed, ${FAILURES} failed (of ${TOTAL}) ==="
[[ "$FAILURES" -eq 0 ]]
