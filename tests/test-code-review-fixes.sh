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

# --- I1: cmd_ls no phantom null entry ---
echo ""
echo "=== I1: cmd_ls no phantom null when empty ==="
# When docker ps returns nothing, should get empty array not [{name:null}]
ls_output=$("$RC" --output json ls 2>/dev/null) || true
null_check=$(echo "$ls_output" | jq '[.[] | select(.name == null)] | length' 2>/dev/null || echo "unknown")
if [[ "$null_check" == "0" ]]; then
  pass "cmd_ls has no null entries"
else
  fail "cmd_ls has null entries. Got: $ls_output"
fi

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

# --- I4: cmd_down distinguishes not-found from already-stopped ---
echo ""
echo "=== I4: cmd_down distinguishes not-found vs not-running ==="
# Test with a container name that definitely doesn't exist
down_err=$("$RC" --output json down nonexistent-container-xyz123 2>/dev/null) || true
if echo "$down_err" | jq -e '.code == "CONTAINER_NOT_FOUND"' >/dev/null 2>&1; then
  pass "cmd_down returns CONTAINER_NOT_FOUND for missing container"
else
  fail "cmd_down did not return CONTAINER_NOT_FOUND. Got: $down_err"
fi

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
cmd_ls_slice=$(awk '/^cmd_ls\(\)/,/^}/' "$RC_SRC")

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

# Static: cmd_ls normalizes missing egress to "legacy" (scoped to cmd_ls)
if grep -q '"legacy"' <<<"$cmd_ls_slice"; then
  pass "cmd_ls normalization: \"legacy\" marker present"
else
  fail "cmd_ls normalization: \"legacy\" marker missing"
fi

# Static: cmd_ls normalizes invalid egress to "invalid:<value>" (scoped to cmd_ls)
if grep -q '"invalid:' <<<"$cmd_ls_slice"; then
  pass "cmd_ls normalization: \"invalid:\" prefix present"
else
  fail "cmd_ls normalization: \"invalid:\" prefix missing"
fi

# Live tests: require Docker and must not run under host-only CI mode
# (L2-b's `rc up` needs a real msb boot, which is a container-tier op)
if [[ -n "${RC_HOST_ONLY:-}" ]]; then
  echo ""
  echo "SKIP (host-only): L2-b live legacy-container egress check (needs a live container; runs via full run-host.sh / container tier)"
elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  echo ""
  echo "--- L2 live tests (Docker available) ---"

  # Live L2-a RETIRED (rip-cage-tsf2, coordinator-confirmed classification
  # call, 2026-07-13): this probe used to pause a raw `docker run` container
  # and assert `rc up` returned CONTAINER_STATE_UNSUPPORTED for it. That
  # `docker pause` construction has no msb equivalent -- `msb --help` has no
  # `pause` subcommand, and cli/lib/msb_runtime.sh's _msb_sandbox_state()
  # can never report the literal "paused" (its case statement only ever
  # produces running/exited/absent/unknown), so the cmd_up branch it targeted
  # is unreachable under msb by design (that branch's own comment: "msb has
  # no pause/restarting/removing/dead concept — unreachable under msb; kept
  # defensive"). Retiring this live probe loses zero coverage: the guarded
  # fail-loud-on-unsupported-state behavior (ADR-001) remains covered by the
  # static source-shape assertions above --
  # "CONTAINER_STATE_UNSUPPORTED error code present in rc",
  # "cmd_up has explicit branch for state: paused/restarting/removing/dead",
  # and "CONTAINER_STATE_UNSUPPORTED referenced >= 8 times in cmd_up" --
  # which all still pass. Follow-up (optional msb-status-stub re-platform,
  # if ever wanted): rip-cage-tsf2.7.

  # Live L2-b: msb-native construction (rip-cage-tsf2, coordinator branch
  # fix; CASE (a) — surviving behavior, mechanics re-platformed onto msb).
  # The OLD raw `docker run --label rc.source.path=... alpine sleep 600`
  # construction is dead: cmd_ls's enumeration is REWRITTEN onto msb
  # (cli/ls.sh:_rc_ls_enumerate, rip-cage-tsf2.1 — `msb list` + `msb
  # inspect`, never `docker ps`), so a raw docker container is invisible to
  # `rc ls` regardless of its labels.
  #
  # The "legacy" normalization itself is very much alive, and is now the
  # UNIVERSAL case for any cage a CURRENT `rc up` creates: grepping this
  # repo's own cli/*.sh confirms nothing sets the bare `rc.egress` label
  # any more (only the unrelated `rc.egress.config-override` label is set
  # — msb declares egress via host-side --net-rule/--net-default flags at
  # create time, not an in-cage engine on/off marker) — so
  # `_rc_ls_enumerate`'s `.config.labels["rc.egress"]` read is always
  # empty for a real msb cage, and cmd_ls's own egress-normalization
  # (`_ls_egress_norm`, cli/ls.sh) always falls to "legacy". Prove this
  # with a REAL `rc up` cage instead of a fake docker one.
  TEST_PATH_L2b=$(mktemp -d)/l2b-legacy-probe
  mkdir -p "$TEST_PATH_L2b"
  cat > "${TEST_PATH_L2b}/.rip-cage.yaml" <<'YAML'
version: 1
network:
  mode: block
  allowed_hosts:
    - example.com
YAML
  _l2b_parent=$(basename "$(dirname "$TEST_PATH_L2b")")
  _l2b_base=$(basename "$TEST_PATH_L2b")
  CNAME_L2b=$(echo "${_l2b_parent}-${_l2b_base}" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^[.-]*//' | sed 's/-$//')
  # Per-invocation RC_MANIFEST_GLOBAL (NOT exported -- test-manifest-cross.sh/
  # test-manifest-cm.sh idiom): _host_sandbox_setup's XDG_CONFIG_HOME isolation
  # above only takes effect when the CALLER's shell hasn't already exported
  # XDG_CONFIG_HOME to (or matching) the real default -- a live risk on any
  # dev shell that sets it explicitly, even to the default path. RC_MANIFEST_GLOBAL
  # outranks XDG_CONFIG_HOME in _manifest_global_path() (cli/lib/manifest_checks.sh),
  # so pointing it at a fresh empty (zero-byte = default bundled stack, D8) fixture
  # here guarantees isolation from a real ~/.config/rip-cage/tools.yaml regardless.
  _l2b_manifest_fixture=$(mktemp)
  RC_ALLOWED_ROOTS="$(dirname "$TEST_PATH_L2b")" RC_MANIFEST_GLOBAL="$_l2b_manifest_fixture" \
    "$RC" up "$TEST_PATH_L2b" < /dev/null > /tmp/rc-l2b-up.out 2>&1 || true
  l2b_result=$(RC_ALLOWED_ROOTS="$(dirname "$TEST_PATH_L2b")" RC_MANIFEST_GLOBAL="$_l2b_manifest_fixture" \
    "$RC" --output json ls 2>/dev/null) || true
  msb rm "$CNAME_L2b" --force >/dev/null 2>&1 || true
  rm -rf "$TEST_PATH_L2b"
  rm -f "$_l2b_manifest_fixture"
  if echo "$l2b_result" | jq -e --arg name "$CNAME_L2b" '.[] | select(.name == $name) | .egress == "legacy"' >/dev/null 2>&1; then
    pass "real msb cage (no rc.egress label set by any current cmd_up path) shown as egress=legacy in cmd_ls"
  else
    fail "legacy container not shown as egress=legacy. Got: $l2b_result (rc up output: $(cat /tmp/rc-l2b-up.out 2>/dev/null))"
  fi
  rm -f /tmp/rc-l2b-up.out
else
  echo "SKIP: Docker daemon not running — skipping L2 live tests"
fi

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
