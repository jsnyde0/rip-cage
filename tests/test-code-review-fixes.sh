#!/usr/bin/env bash
# rip-cage-tsf2 (msb-cutover, coordinator branch fix): the old top-of-file
# `command -v docker` guard self-skipped only if the docker BINARY was
# absent -- but docker is still installed on this branch (used for
# `docker build`/`docker save` -> `msb load` image conversion, see
# cli/build.sh), so the guard never fired and the body ran regardless.
# It was also the WRONG precondition either way: this file is a KEEP-class
# host-side static-source-grep test (docs/2026-07-11-msb-test-classification.md)
# that never needs Docker for C1/C2/I1-I4/L2-static/syntax-check -- the only
# genuinely Docker-dependent sub-checks (L2 live paused/legacy-container
# probes) already have their OWN local Docker+daemon guard further down
# (`command -v docker &>/dev/null && docker info &>/dev/null`, with a SKIP
# path when absent). Removed rather than replaced: no single top-level
# precondition covers what the file actually needs (jq/yq, both are baseline
# `rc` dependencies with no existing skip-guard convention in this suite).
set -uo pipefail

# Tests for code review fixes (C1, C2, I1, I2, I3, I4)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# rc is now a thin shim (rip-cage-gto1 decomposition); this test's static
# grep/awk source-content assertions (json_error, LEGACY_CONTAINER, cmd_up/
# cmd_ls bodies, etc.) need the decomposed cli/lib/*.sh + cli/*.sh modules,
# concatenated in the shim's own sourcing order so relative-position checks
# (e.g. "cmd_up appears before the next cmd_ function") still hold. Real `rc`
# INVOCATIONS below (executing the CLI, not grepping its source) still use
# $RC unchanged.
RC_SRC="$(mktemp)"
cat "${REPO_ROOT}"/cli/lib/*.sh "${REPO_ROOT}"/cli/*.sh > "$RC_SRC" 2>/dev/null
FAILURES=0
PASSES=0

# Bare per-file runs of this file (e.g. `bash tests/test-code-review-fixes.sh`
# directly, outside run-host.sh/run-one.sh) are non-hermetic against a real
# developer ~/.config/rip-cage/tools.yaml: a stale entry there (e.g. a
# retired archetype, or an IOC-denylisted egress host) makes the live L2 `rc
# up` calls below fail for reasons unrelated to what L2 actually tests.
# Same shared sandbox fixture run-host.sh/run-one.sh build (rip-cage-w3lq) —
# empty tools.yaml (default bundled stack) + benign config.yaml.
# shellcheck source=tests/_host-sandbox-lib.sh
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
_host_sandbox_setup
trap '_host_sandbox_cleanup; rm -f "$RC_SRC"' EXIT

pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== Code Review Fix Tests ==="

# --- C1: json_error uses jq --arg (no string interpolation) ---
echo ""
echo "=== C1: json_error uses jq --arg ==="
# Verify json_error implementation uses jq --arg, not string interpolation
if grep -A2 'json_error()' "$RC_SRC" | grep -q 'jq -nc --arg'; then
  pass "json_error uses jq --arg for safe JSON construction"
else
  fail "json_error does not use jq --arg"
fi

# --- C2: json_out eliminated — verify no json_out calls with interpolation ---
echo ""
echo "=== C2: No unsafe json_out with interpolated variables ==="
# Count json_out *function calls* (exact name, not _up_json_output) with $ (variable interpolation).
# Exclude variable assignments (json_out=...) and variable substitutions (${json_out}, "$json_out") —
# those are not function calls and don't carry the interpolation-injection risk this check guards.
unsafe_count=$(grep -w 'json_out' "$RC_SRC" \
  | grep -v 'json_out()' \
  | grep -v 'json_out=' \
  | grep -v '\${json_out' \
  | grep -v '"\$json_out' \
  | grep '\$' \
  | wc -l | tr -d ' ')
if [[ "$unsafe_count" -eq 0 ]]; then
  pass "No json_out calls with variable interpolation"
else
  fail "Found $unsafe_count json_out calls with variable interpolation"
fi

# --- I1: RETIRED with `rc ls` (rip-cage-ely4.10 / ADR-031 D3) ---
# Asserted that `rc ls --output json` returns [] rather than [{name:null}] when
# no cage exists. The verb is deleted; listing cages is `msb list`, whose empty
# output is msb's contract, not rc's.

# --- I2: Empty volumes_removed check ---
# This requires a running container to test fully, but we verify the code pattern
echo ""
echo "=== I2: volumes_removed empty array handling ==="
# Verify the code uses select(length > 0) pattern
if grep -q 'select(length > 0)' "$RC_SRC"; then
  pass "volumes_removed uses select(length > 0) filter"
else
  fail "volumes_removed missing select(length > 0) filter"
fi

# --- I3: No duplicate --dry-run/--output in cmd_up ---
echo ""
echo "=== I3: No duplicate --dry-run/--output in cmd_up ==="
# Extract the cmd_up function and check its local case statement
# The cmd_up while loop should not contain --dry-run or --output cases
in_cmd_up=false
dup_found=false
while IFS= read -r line; do
  if [[ "$line" =~ ^cmd_up\(\) ]]; then
    in_cmd_up=true
  elif [[ "$in_cmd_up" == true ]] && [[ "$line" =~ ^cmd_ ]] && [[ ! "$line" =~ ^cmd_up ]]; then
    break
  elif [[ "$in_cmd_up" == true ]]; then
    if [[ "$line" =~ "--dry-run)" ]] || [[ "$line" =~ "--output)" ]]; then
      dup_found=true
    fi
  fi
done < "$RC_SRC"
if [[ "$dup_found" == false ]]; then
  pass "cmd_up does not have duplicate --dry-run/--output parsing"
else
  fail "cmd_up still has duplicate --dry-run or --output parsing"
fi

# --- I4: RETIRED with `rc down` (rip-cage-ely4.10 / ADR-031 D3) ---
# Asserted that `rc down <missing>` returns CONTAINER_NOT_FOUND rather than the
# already-stopped error. The verb is deleted; stopping a cage is `msb stop`.
# cmd_destroy's own CONTAINER_NOT_FOUND path -- the surviving verb that still
# makes that distinction -- is covered by tests/test-destroy-orphaned-volumes.sh.

# --- L1 (resume path fails loud on missing/invalid rc.egress label, ADR-001)
# retired: _up_resolve_resume_egress, the rc.egress label, and its
# LEGACY_CONTAINER/INVALID_EGRESS_LABEL error codes were deleted per
# ADR-029 D2 (engine-deletion sweep, rip-cage-3vj2 / S4) -- there is no more
# in-cage engine on/off posture to guard on resume. ---

# --- L2: cmd_up fail-loud on unsupported container states (ADR-001) ---
echo ""
echo "=== L2: cmd_up fail-loud on unsupported container states ==="

# Static: CONTAINER_STATE_UNSUPPORTED error code present
if grep -q '"CONTAINER_STATE_UNSUPPORTED"' "$RC_SRC"; then
  pass "CONTAINER_STATE_UNSUPPORTED error code present in rc"
else
  fail "CONTAINER_STATE_UNSUPPORTED error code missing from rc"
fi

# Capture function slices once. Avoids `awk … | grep -q …` under `set -o pipefail`:
# grep -q closes the pipe on first match → awk dies with SIGPIPE (141) → pipefail
# treats the whole pipeline as failed even though the pattern was found.
cmd_up_slice=$(awk '/^cmd_up\(\)/,/^}/' "$RC_SRC")

# Static: all four unsupported states have explicit elif branches (scoped to cmd_up)
for state in paused restarting removing dead; do
  if grep -q "\"$state\"" <<<"$cmd_up_slice"; then
    pass "cmd_up has explicit branch for state: $state"
  else
    fail "cmd_up missing explicit branch for state: $state"
  fi
done

# Static: CONTAINER_STATE_UNSUPPORTED appears at least 8 times (four states × two paths: dry-run + real)
state_unsupported_count=$(grep -c '"CONTAINER_STATE_UNSUPPORTED"' <<<"$cmd_up_slice" || true)
if [[ "$state_unsupported_count" -ge 8 ]]; then
  pass "CONTAINER_STATE_UNSUPPORTED referenced >= 8 times in cmd_up ($state_unsupported_count)"
else
  fail "CONTAINER_STATE_UNSUPPORTED only referenced $state_unsupported_count times in cmd_up; expected >= 8 (four states × two paths)"
fi

# The two cmd_ls egress-normalization assertions that lived here -- "legacy"
# for a missing rc.egress label, "invalid:<value>" for an unreadable one --
# RETIRED with `rc ls` (rip-cage-ely4.10 / ADR-031 D3). They read a display
# column of a verb that no longer exists.

# The L2 live block RETIRED (rip-cage-ely4.10 / ADR-031 D3).
#
# L2-a was already retired: it paused a raw docker container to force
# CONTAINER_STATE_UNSUPPORTED, and msb has no pause. L2-b booted a real cage and
# asserted its egress column read "legacy" in `rc ls` -- both the verb and the
# column are now gone, and the probe had additionally gone stale against ely4.9
# (it wrote a `.rip-cage.yaml`, which `rc up` stopped reading when the config
# schema retired).
#
# Retiring it loses no coverage of the ADR-001 property this file is about: the
# fail-loud-on-unsupported-state behaviour stays pinned by the static
# source-shape assertions above, and this file stops booting a real cage to
# check a display string.



# --- Syntax check ---
echo ""
echo "=== Syntax check ==="
if bash -n "$RC" 2>&1; then
  pass "rc is valid bash"
else
  fail "rc has syntax errors"
fi

echo ""
echo "=== Results: $PASSES passed, $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]] || exit 1
