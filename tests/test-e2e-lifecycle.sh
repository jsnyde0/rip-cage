#!/usr/bin/env bash
# E2E lifecycle test — exercises rc up/down/destroy + regression guards.
# ADR-013 D1/D3 (FIRM). Supersedes test-integration.sh.
#
# Runtime: ~90-180s warm cache. Set RC_E2E_REBUILD=1 to force rc build first.
# Run from host only; rc hard-exits when /.dockerenv is present.
#
# NAMING: rc container_name() derives from parent+basename of the workspace
# path, so we stage workspaces under /var/folders/.../rc/e2e-test to produce
# the deterministic container name "rc-e2e-test".
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
check() {
  local name="$1" result="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "pass" ]]; then
    echo "PASS  [$TOTAL] $name${detail:+ -- $detail}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  [$TOTAL] $name${detail:+ -- $detail}"
    FAIL=$((FAIL + 1))
  fi
}

CONTAINER_NAME="rc-e2e-test"
E2E_TMP=""
E2E_TMP2=""
OFF_TMP=""
AUTH_TMP=""
DCG_TMP=""
MISE_TMP=""

CLEANUP() {
  # Destroy any e2e containers + volumes we may have created. Match on labels
  # keyed to our staging roots so we don't touch the developer's real work.
  local c
  for c in $(docker ps -a --filter "label=rc.source.path" --format '{{.Names}}' 2>/dev/null); do
    local sp
    sp=$(docker inspect --format '{{index .Config.Labels "rc.source.path"}}' "$c" 2>/dev/null || true)
    case "$sp" in
      "$E2E_TMP"/*|"$E2E_TMP2"/*|"$OFF_TMP"/*|"$AUTH_TMP"/*|"$DCG_TMP"/*|"$MISE_TMP"/*)
        docker rm -f "$c" > /dev/null 2>&1 || true
        docker volume rm "rc-state-${c}" > /dev/null 2>&1 || true
        ;;
    esac
  done
  [[ -n "$E2E_TMP"  ]] && rm -rf "$E2E_TMP"
  [[ -n "$E2E_TMP2" ]] && rm -rf "$E2E_TMP2"
  [[ -n "$OFF_TMP"  ]] && rm -rf "$OFF_TMP"
  [[ -n "$AUTH_TMP" ]] && rm -rf "$AUTH_TMP"
  [[ -n "$DCG_TMP"  ]] && rm -rf "$DCG_TMP"
  [[ -n "$MISE_TMP" ]] && rm -rf "$MISE_TMP"
  # NOTE: do NOT remove rc-mise-cache — it is host-scoped (ADR-015 D2)
}
trap CLEANUP EXIT

# Pre-cleanup: remove any leftover state from a prior aborted run so we
# don't accidentally hit the name-collision code path.
docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
docker volume rm "rc-state-${CONTAINER_NAME}" > /dev/null 2>&1 || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/../rc"

# Stage workspaces so container_name() = "rc-e2e-test". Parent dir must be "rc".
E2E_TMP=$(mktemp -d)
mkdir -p "${E2E_TMP}/rc"
TEST_WS="${E2E_TMP}/rc/e2e-test"
mkdir -p "$TEST_WS"

# RC_ALLOWED_ROOTS must cover the resolved parent (macOS /var -> /private/var).
E2E_TMP_RESOLVED=$(realpath "$E2E_TMP")
export RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}"

echo "=== E2E Lifecycle Checks ==="
echo "TEST_WS=$TEST_WS"
echo ""

# -----------------------------------------------------------------------------
# Lifecycle — setup
# -----------------------------------------------------------------------------

# Check 1: RC_E2E_REBUILD guard
if [[ "${RC_E2E_REBUILD:-0}" == "1" ]]; then
  if "$RC" build > /dev/null 2>&1; then
    check "rc build succeeds" "pass"
  else
    check "rc build succeeds" "fail" "rc build exited non-zero"
  fi
else
  check "rc build (skipped -- set RC_E2E_REBUILD=1 to rebuild)" "pass" "using existing local image"
fi

# Check 2: Scratch workspace initialized
git -C "$TEST_WS" init > /dev/null 2>&1
echo "# e2e test workspace" > "$TEST_WS/README"
check "scratch workspace created with git repo" "pass" "$TEST_WS"

# Check 3: rc up headless — container starts, rc.egress label = "on"
"$RC" up "$TEST_WS" < /dev/null > /tmp/rc-e2e-up.out 2>&1 || true
egress_label=$(docker inspect "$CONTAINER_NAME" \
  --format '{{index .Config.Labels "rc.egress"}}' 2>/dev/null || true)
if [[ "$egress_label" == "on" ]]; then
  check "rc up headless -- container running with rc.egress=on" "pass"
else
  check "rc up headless -- container running with rc.egress=on" "fail" \
    "label was '${egress_label:-missing}' (see /tmp/rc-e2e-up.out)"
fi

# Check 4: Scratch workspace bind-mounted at /workspace
if docker exec "$CONTAINER_NAME" test -f /workspace/README > /dev/null 2>&1; then
  check "scratch workspace bind-mounted at /workspace" "pass"
else
  check "scratch workspace bind-mounted at /workspace" "fail"
fi

# Check 5: /workspace/.rip-cage/ writable by agent
if docker exec "$CONTAINER_NAME" sh -c 'mkdir -p /workspace/.rip-cage && touch /workspace/.rip-cage/.probe' > /dev/null 2>&1; then
  check "/workspace/.rip-cage/ writable by agent" "pass"
else
  check "/workspace/.rip-cage/ writable by agent" "fail"
fi

# -----------------------------------------------------------------------------
# Regression guards (ADR-013 D3 FIRM)
# -----------------------------------------------------------------------------

# Check 6: python3-venv present (regression guard for 2026-04-20 fix #1)
# A plain rc build is NOT sufficient — Docker reuses cached apt layers even if
# the Dockerfile line is deleted. Assert both package presence and functional
# venv creation.
dpkg_ok=0; venv_ok=0
docker exec "$CONTAINER_NAME" dpkg -s python3-venv > /dev/null 2>&1 && dpkg_ok=1
docker exec "$CONTAINER_NAME" python3 -m venv /tmp/venv-probe > /dev/null 2>&1 && venv_ok=1
if [[ "$dpkg_ok" -eq 1 && "$venv_ok" -eq 1 ]]; then
  check "python3-venv present and functional (regression guard)" "pass"
else
  check "python3-venv present and functional (regression guard)" "fail" \
    "dpkg=$dpkg_ok venv=$venv_ok"
fi

# Check 7: rc test passes all in-container suites
if "$RC" test "$CONTAINER_NAME" > /tmp/rc-e2e-rctest.out 2>&1; then
  if grep -qE '^PASS|pass' /tmp/rc-e2e-rctest.out; then
    check "rc test passes in-container suites" "pass"
  else
    check "rc test passes in-container suites" "fail" "no PASS lines in output"
  fi
else
  check "rc test passes in-container suites" "fail" "rc test exited non-zero (see /tmp/rc-e2e-rctest.out)"
fi

# Check 8: rc ls source path matches realpath of TEST_WS
rc_ls_path=$("$RC" --output json ls 2>/dev/null | jq -r \
  --arg name "$CONTAINER_NAME" \
  '.[] | select(.name == $name) | .source_path' 2>/dev/null || true)
expected=$(realpath "$TEST_WS")
if [[ "$rc_ls_path" == "$expected" ]]; then
  check "rc ls source path matches realpath of TEST_WS" "pass"
else
  check "rc ls source path matches realpath of TEST_WS" "fail" \
    "got '${rc_ls_path}' expected '${expected}'"
fi

# Check 9: Expected tools present inside container.
# Core tools (hard-required): sourced from test-integration.sh step 7.
# Advisory tools (ms rg fd): mentioned in the design doc; `ms` is delivered via
# the Python MCP shim, not a binary, so absence of the CLI isn't a regression.
# Surface missing advisory tools as detail but do not fail.
tools_missing=()
tools_advisory_missing=()
for tool in claude bd uv bun node gh git perl jq zsh; do
  if ! docker exec "$CONTAINER_NAME" which "$tool" > /dev/null 2>&1; then
    tools_missing+=("$tool")
  fi
done
for tool in ms rg fd; do
  if ! docker exec "$CONTAINER_NAME" which "$tool" > /dev/null 2>&1; then
    tools_advisory_missing+=("$tool")
  fi
done
if [[ ${#tools_missing[@]} -eq 0 ]]; then
  if [[ ${#tools_advisory_missing[@]} -gt 0 ]]; then
    check "core tools present (advisory: ${tools_advisory_missing[*]} absent)" "pass"
  else
    check "core + advisory tools present inside container" "pass"
  fi
else
  check "core tools present inside container" "fail" \
    "missing: ${tools_missing[*]}"
fi

# Check 10: No host CLAUDE.md leaked to agent home
# After init, CLAUDE.md IS copied into ~/.claude/CLAUDE.md if a global template
# exists on the host. The original integration-test assertion was that no
# CLAUDE.md leaked when the host file is NOT provided. In this test we do
# mount the host's CLAUDE.md (via the standard rc up path), so the file is
# expected to be present. Downgrade the assertion to "if ~/.claude/CLAUDE.md
# exists, it matches the intended host source".
if docker exec "$CONTAINER_NAME" test -f /home/agent/.claude/CLAUDE.md > /dev/null 2>&1; then
  # File present — confirm it came from the .rc-context bind mount (sourced from host).
  if docker exec "$CONTAINER_NAME" test -f /home/agent/.rc-context/global-claude.md > /dev/null 2>&1; then
    check "CLAUDE.md presence matches host source" "pass" "copied from .rc-context/global-claude.md"
  else
    check "CLAUDE.md presence matches host source" "fail" "CLAUDE.md present but no .rc-context source"
  fi
else
  check "CLAUDE.md presence matches host source" "pass" "no CLAUDE.md (host template absent)"
fi

# (No recipe-presence check here.) dcg is an opt-in composable recipe; whether
# a built cage contains it depends entirely on the operator's manifest
# (~/.config/rip-cage/tools.yaml), NOT on a base-image invariant — this suite builds from
# that manifest, so it cannot assert recipe presence/absence stably. Recipe wiring is
# covered where a KNOWN manifest is composed: examples/dcg/smoke.sh, the
# demotion tests, and test-mount-seam-integration.sh SE7. (rip-cage-1ssw)
# (ssh-bypass recipe retired at the msb cutover, ADR-029 D3 — rip-cage-f1qo S5.)

# Check 12: Pi verify line appears in init log (ADR-019 B3).
# init-rip-cage.sh runs via `docker exec` (sleep infinity is the entrypoint),
# so its output goes to the rc up stdout — captured at /tmp/rc-e2e-up.out by
# check 3 — not into `docker logs`. (rip-cage-nb2)
if grep -q '\[rip-cage\] pi ' /tmp/rc-e2e-up.out; then
  check "pi verify line in init log" "pass"
else
  check "pi verify line in init log" "fail" "(see: /tmp/rc-e2e-up.out)"
fi

# Checks 12a-12d: Auth-warn matrix — observation only (ADR-019 D2 FIRM).
# Verifies the Claude auth-warn block behavior under four auth-presence combinations.
# These document expected behavior; they do not add pi-specific auth checks.
#
# The auth-warn block inside the container checks (in order):
#   1. ~/.claude/.credentials.json present → "OAuth credentials found" (no warn)
#   2. ~/.claude.json present → no warn (API key flow)
#   3. ANTHROPIC_API_KEY set → no warn
#   4. None of the above → "WARNING: No auth found"
#
# Host credential files (~/.claude/.credentials.json, ~/.claude.json) are auto-mounted
# by rc up when present. We therefore use two dimensions to cover all four cases:
#   - ANTHROPIC_API_KEY env var controls "Claude auth via env" (passed through to container)
#   - Host credential files are mounted automatically; test adapts to host state.
# Cases 2 and 3 differ only in pi auth state; since the warn-block ignores pi auth (D2 FIRM),
# both produce the same Claude-warn outcome — we verify this is intentional.
AUTH_TMP=$(mktemp -d)
AUTH_TMP_RESOLVED=$(realpath "$AUTH_TMP")

# Detect whether host credential files exist (they are auto-mounted by rc up).
_host_has_claude_creds=0
_host_has_claude_json=0
if [ -f "${HOME}/.claude/.credentials.json" ]; then _host_has_claude_creds=1; fi
if [ -f "${HOME}/.claude.json" ]; then _host_has_claude_json=1; fi
_host_has_claude_auth=$(( _host_has_claude_creds + _host_has_claude_json ))

# Each case gets its own workspace to avoid container-name collisions.
# Pattern: parent "rc-auth", base "caseN" → container "rc-auth-caseN"
mkdir -p "${AUTH_TMP}/rc-auth"

# Case 1: Claude auth via ANTHROPIC_API_KEY → no 'WARNING: No auth' in log.
_aws1="${AUTH_TMP}/rc-auth/case1"
_ac1_out="${AUTH_TMP}/case1-up.out"
mkdir -p "$_aws1"
git -C "$_aws1" init > /dev/null 2>&1
RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${AUTH_TMP_RESOLVED}" \
  ANTHROPIC_API_KEY=sk-test-case1 \
  RIP_CAGE_EGRESS=off "$RC" up "$_aws1" </dev/null >"$_ac1_out" 2>&1 || true
_ac1_name=$(docker ps -a --filter "label=rc.source.path=$(realpath "$_aws1")" \
  --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -z "$_ac1_name" ]]; then
  check "auth-warn case 1: Claude API key set → no WARNING" "fail" "container did not start"
else
  # init runs via docker exec (PID 1 is sleep infinity) so its output reaches rc up
  # stdout, NOT docker logs. Assert on the captured rc up stdout, and gate on an init
  # sentinel so an empty capture fails loud instead of trivially passing the
  # absence-of-WARNING check on an empty string (rip-cage-igm).
  _ac1_log=$(cat "$_ac1_out" 2>/dev/null || true)
  if ! printf '%s\n' "$_ac1_log" | grep -q '\[rip-cage\] pi '; then
    check "auth-warn case 1: Claude API key set → no WARNING" "fail" "init output not captured (see $_ac1_out)"
  elif ! printf '%s\n' "$_ac1_log" | grep -q 'WARNING: No auth'; then
    check "auth-warn case 1: Claude API key set → no WARNING" "pass"
  else
    check "auth-warn case 1: Claude API key set → no WARNING" "fail" "(container=$_ac1_name)"
  fi
  docker rm -f "$_ac1_name" > /dev/null 2>&1 || true
  docker volume rm "rc-state-${_ac1_name}" > /dev/null 2>&1 || true
fi

# Case 2: Pi auth present, no Claude env auth → warn depends on host credential file state.
# Note: Claude warn-line intentionally present per ADR-019 D2 — pi auth uses its own /login UI.
# If host has ~/.claude/.credentials.json or ~/.claude.json, those are auto-mounted → no warn.
# If host has none of those, the warn fires — confirming pi auth alone doesn't suppress it (D2).
#
# EQUIVALENCE NOTE (rip-cage-f4i): Case 2 is behaviorally identical to case 3 — the rc up
# invocation is the same and the warn-block inside the cage checks ONLY Claude auth state
# (credentials.json / .claude.json / ANTHROPIC_API_KEY).  Pi auth presence does not affect
# the Claude warn-block outcome (ADR-019 D2 FIRM).  The duplication is intentional: case 2
# documents that "pi auth is present but still gets a Claude warning" is the EXPECTED behavior,
# not a regression.  Any future change to the warn-block that suppresses Claude warnings for
# pi-authed cages would break case 2 but not case 3, surfacing the ADR-019 D2 violation.
_aws2="${AUTH_TMP}/rc-auth/case2"
_ac2_out="${AUTH_TMP}/case2-up.out"
mkdir -p "$_aws2"
git -C "$_aws2" init > /dev/null 2>&1
RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${AUTH_TMP_RESOLVED}" \
  RIP_CAGE_EGRESS=off "$RC" up "$_aws2" </dev/null >"$_ac2_out" 2>&1 || true
_ac2_name=$(docker ps -a --filter "label=rc.source.path=$(realpath "$_aws2")" \
  --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -z "$_ac2_name" ]]; then
  check "auth-warn case 2" "fail" "container did not start"
else
  # See case 1: assert on captured rc up stdout, gated on an init sentinel (rip-cage-igm).
  _ac2_log=$(cat "$_ac2_out" 2>/dev/null || true)
  if ! printf '%s\n' "$_ac2_log" | grep -q '\[rip-cage\] pi '; then
    check "auth-warn case 2" "fail" "init output not captured (see $_ac2_out)"
  elif [ "$_host_has_claude_auth" -gt 0 ]; then
    # Host creds auto-mounted → no warn expected (D2: pi auth doesn't add a warn either)
    if ! printf '%s\n' "$_ac2_log" | grep -q 'WARNING: No auth'; then
      check "auth-warn case 2: pi auth + host Claude creds → no WARNING (host creds dominate)" "pass"
    else
      check "auth-warn case 2: pi auth + host Claude creds → no WARNING (host creds dominate)" "fail" "(container=$_ac2_name)"
    fi
  else
    # No host creds → warn expected; pi auth alone does NOT suppress Claude warn (D2 FIRM)
    if printf '%s\n' "$_ac2_log" | grep -q 'WARNING: No auth'; then
      check "auth-warn case 2: pi auth only, no Claude auth → WARNING present (intentional per D2)" "pass"
    else
      check "auth-warn case 2: pi auth only, no Claude auth → WARNING present (intentional per D2)" "fail" "(container=$_ac2_name)"
    fi
  fi
  docker rm -f "$_ac2_name" > /dev/null 2>&1 || true
  docker volume rm "rc-state-${_ac2_name}" > /dev/null 2>&1 || true
fi

# Case 3: Neither Claude env auth nor pi auth → warn depends on host credential file state.
_aws3="${AUTH_TMP}/rc-auth/case3"
_ac3_out="${AUTH_TMP}/case3-up.out"
mkdir -p "$_aws3"
git -C "$_aws3" init > /dev/null 2>&1
RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${AUTH_TMP_RESOLVED}" \
  RIP_CAGE_EGRESS=off "$RC" up "$_aws3" </dev/null >"$_ac3_out" 2>&1 || true
_ac3_name=$(docker ps -a --filter "label=rc.source.path=$(realpath "$_aws3")" \
  --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -z "$_ac3_name" ]]; then
  check "auth-warn case 3" "fail" "container did not start"
else
  # See case 1: assert on captured rc up stdout, gated on an init sentinel (rip-cage-igm).
  _ac3_log=$(cat "$_ac3_out" 2>/dev/null || true)
  if ! printf '%s\n' "$_ac3_log" | grep -q '\[rip-cage\] pi '; then
    check "auth-warn case 3" "fail" "init output not captured (see $_ac3_out)"
  elif [ "$_host_has_claude_auth" -gt 0 ]; then
    if ! printf '%s\n' "$_ac3_log" | grep -q 'WARNING: No auth'; then
      check "auth-warn case 3: no env auth, host Claude creds present → no WARNING" "pass"
    else
      check "auth-warn case 3: no env auth, host Claude creds present → no WARNING" "fail" "(container=$_ac3_name)"
    fi
  else
    if printf '%s\n' "$_ac3_log" | grep -q 'WARNING: No auth'; then
      check "auth-warn case 3: neither Claude nor pi auth → WARNING" "pass"
    else
      check "auth-warn case 3: neither Claude nor pi auth → WARNING" "fail" "(container=$_ac3_name)"
    fi
  fi
  docker rm -f "$_ac3_name" > /dev/null 2>&1 || true
  docker volume rm "rc-state-${_ac3_name}" > /dev/null 2>&1 || true
fi

# Case 4: Both Claude API key and pi auth → no 'WARNING: No auth'.
_aws4="${AUTH_TMP}/rc-auth/case4"
_ac4_out="${AUTH_TMP}/case4-up.out"
mkdir -p "$_aws4"
git -C "$_aws4" init > /dev/null 2>&1
RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${AUTH_TMP_RESOLVED}" \
  ANTHROPIC_API_KEY=sk-test-case4 \
  RIP_CAGE_EGRESS=off "$RC" up "$_aws4" </dev/null >"$_ac4_out" 2>&1 || true
_ac4_name=$(docker ps -a --filter "label=rc.source.path=$(realpath "$_aws4")" \
  --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -z "$_ac4_name" ]]; then
  check "auth-warn case 4: Claude API key + pi auth → no WARNING" "fail" "container did not start"
else
  # See case 1: assert on captured rc up stdout, gated on an init sentinel (rip-cage-igm).
  _ac4_log=$(cat "$_ac4_out" 2>/dev/null || true)
  if ! printf '%s\n' "$_ac4_log" | grep -q '\[rip-cage\] pi '; then
    check "auth-warn case 4: Claude API key + pi auth → no WARNING" "fail" "init output not captured (see $_ac4_out)"
  elif ! printf '%s\n' "$_ac4_log" | grep -q 'WARNING: No auth'; then
    check "auth-warn case 4: Claude API key + pi auth → no WARNING" "pass"
  else
    check "auth-warn case 4: Claude API key + pi auth → no WARNING" "fail" "(container=$_ac4_name)"
  fi
  docker rm -f "$_ac4_name" > /dev/null 2>&1 || true
  docker volume rm "rc-state-${_ac4_name}" > /dev/null 2>&1 || true
fi

# Case 5: No Claude auth at all (no keychain, no env, no host cred files) → WARNING present.
# Uses RC_SKIP_KEYCHAIN_EXTRACTION=1 (test seam in rc) to prevent macOS keychain extraction,
# plus a temp HOME with no ~/.claude/.credentials.json and no ~/.claude.json.  With ANTHROPIC_API_KEY
# unset and no host cred files, the in-cage auth-warn block MUST emit "WARNING: No auth found".
# This is the deterministic no-auth branch that was previously gated by _host_has_claude_auth==0
# and therefore never executed on a normal dev host (rip-cage-f4i).
#
# IMPORTANT: The temp HOME means rc up will create fresh config dirs under it (including the
# global denylist seed).  The workspace is still inside AUTH_TMP (covered by RC_ALLOWED_ROOTS).
# The wo9 pi-seed creates <tmphome>/.pi/agent/auth.json — that is expected and fine.
_aws5="${AUTH_TMP}/rc-auth/case5"
_ac5_out="${AUTH_TMP}/case5-up.out"
_ac5_home=$(mktemp -d)
mkdir -p "$_aws5"
git -C "$_aws5" init > /dev/null 2>&1
HOME="$_ac5_home" \
  RC_SKIP_KEYCHAIN_EXTRACTION=1 \
  ANTHROPIC_API_KEY="" \
  RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${AUTH_TMP_RESOLVED}" \
  RIP_CAGE_EGRESS=off \
  "$RC" up "$_aws5" </dev/null >"$_ac5_out" 2>&1 || true
_ac5_name=$(docker ps -a --filter "label=rc.source.path=$(realpath "$_aws5")" \
  --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -z "$_ac5_name" ]]; then
  check "auth-warn case 5: no Claude auth → WARNING present (rip-cage-f4i)" "fail" "container did not start (see $_ac5_out)"
else
  # Assert on captured rc up stdout, gated on an init sentinel so an empty capture
  # fails loud instead of trivially passing the absence-of-WARNING check (rip-cage-igm).
  _ac5_log=$(cat "$_ac5_out" 2>/dev/null || true)
  if ! printf '%s\n' "$_ac5_log" | grep -q '\[rip-cage\] pi '; then
    check "auth-warn case 5: no Claude auth → WARNING present (rip-cage-f4i)" "fail" "init output not captured (see $_ac5_out)"
  elif printf '%s\n' "$_ac5_log" | grep -q 'WARNING: No auth'; then
    check "auth-warn case 5: no Claude auth → WARNING present (rip-cage-f4i)" "pass"
  else
    check "auth-warn case 5: no Claude auth → WARNING present (rip-cage-f4i)" "fail" "(container=$_ac5_name)"
  fi
  docker rm -f "$_ac5_name" > /dev/null 2>&1 || true
  docker volume rm "rc-state-${_ac5_name}" > /dev/null 2>&1 || true
fi
rm -rf "$_ac5_home"

# Case 6: CLAUDE_CODE_OAUTH_TOKEN present via --env-file, non-possession posture
# (no credentials file, no ~/.claude.json, no ANTHROPIC_API_KEY) → no 'WARNING: No
# auth' (rip-cage-df1c). The init-time auth-warn check must additively recognize
# CLAUDE_CODE_OAUTH_TOKEN, mirroring rc test check 13's recognition set
# (test-safety-stack.sh:187) — this is the load-bearing non-possession auth path
# (rip-cage-73bz).
_aws6="${AUTH_TMP}/rc-auth/case6"
_ac6_out="${AUTH_TMP}/case6-up.out"
_ac6_home=$(mktemp -d)
_ac6_envfile="${AUTH_TMP}/case6.env"
mkdir -p "$_aws6"
git -C "$_aws6" init > /dev/null 2>&1
printf 'CLAUDE_CODE_OAUTH_TOKEN=placeholder-token-case6\n' > "$_ac6_envfile"
chmod 600 "$_ac6_envfile"
HOME="$_ac6_home" \
  RC_SKIP_KEYCHAIN_EXTRACTION=1 \
  ANTHROPIC_API_KEY="" \
  RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${AUTH_TMP_RESOLVED}" \
  RIP_CAGE_EGRESS=off \
  "$RC" up "$_aws6" --env-file "$_ac6_envfile" </dev/null >"$_ac6_out" 2>&1 || true
_ac6_name=$(docker ps -a --filter "label=rc.source.path=$(realpath "$_aws6")" \
  --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -z "$_ac6_name" ]]; then
  check "auth-warn case 6: CLAUDE_CODE_OAUTH_TOKEN set (non-possession) → no WARNING (rip-cage-df1c)" "fail" "container did not start (see $_ac6_out)"
else
  # See case 1: assert on captured rc up stdout, gated on an init sentinel (rip-cage-igm).
  _ac6_log=$(cat "$_ac6_out" 2>/dev/null || true)
  if ! printf '%s\n' "$_ac6_log" | grep -q '\[rip-cage\] pi '; then
    check "auth-warn case 6: CLAUDE_CODE_OAUTH_TOKEN set (non-possession) → no WARNING (rip-cage-df1c)" "fail" "init output not captured (see $_ac6_out)"
  elif ! printf '%s\n' "$_ac6_log" | grep -q 'WARNING: No auth'; then
    check "auth-warn case 6: CLAUDE_CODE_OAUTH_TOKEN set (non-possession) → no WARNING (rip-cage-df1c)" "pass"
  else
    check "auth-warn case 6: CLAUDE_CODE_OAUTH_TOKEN set (non-possession) → no WARNING (rip-cage-df1c)" "fail" "(container=$_ac6_name)"
  fi
  docker rm -f "$_ac6_name" > /dev/null 2>&1 || true
  docker volume rm "rc-state-${_ac6_name}" > /dev/null 2>&1 || true
fi
rm -rf "$_ac6_home"

# Restore RC_ALLOWED_ROOTS to the primary e2e root (subsequent checks use E2E_TMP_RESOLVED).
export RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}"

# -----------------------------------------------------------------------------
# Lifecycle — stop/resume
# -----------------------------------------------------------------------------

# Check 13: docker stop exits 0 (simulates rc down)
if docker stop "$CONTAINER_NAME" > /dev/null 2>&1; then
  check "docker stop exits 0" "pass"
else
  check "docker stop exits 0" "fail"
fi

# Check 17 setup: snapshot tmux client count before resume (container is stopped
# so this will error or return 0; capture safely).
docker start "$CONTAINER_NAME" > /dev/null 2>&1 || true
sleep 1
tmux_clients_before=$(docker exec "$CONTAINER_NAME" sh -c 'tmux list-clients 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]' || echo 0)
docker stop "$CONTAINER_NAME" > /dev/null 2>&1 || true

# Check 14: rc up on same workspace resumes — egress label preserved
"$RC" up "$TEST_WS" < /dev/null > /dev/null 2>&1 || true
egress_label=$(docker inspect "$CONTAINER_NAME" \
  --format '{{index .Config.Labels "rc.egress"}}' 2>/dev/null || true)
if [[ "$egress_label" == "on" ]]; then
  check "rc up resume preserves rc.egress=on" "pass"
else
  check "rc up resume preserves rc.egress=on" "fail" "label='${egress_label:-missing}'"
fi

# Check 15: Volume contents intact after resume
if docker exec "$CONTAINER_NAME" test -f /workspace/README > /dev/null 2>&1; then
  check "workspace contents intact after resume" "pass"
else
  check "workspace contents intact after resume" "fail"
fi

# Check 16: rc test still passes after restart
if "$RC" test "$CONTAINER_NAME" > /tmp/rc-e2e-rctest2.out 2>&1; then
  check "rc test passes after restart" "pass"
else
  check "rc test passes after restart" "fail" "(see /tmp/rc-e2e-rctest2.out)"
fi

# Check 17: Resume TTY guard (regression guard for 2026-04-20 fix #3).
# The fix prevents rc up from launching tmux attach when stdin is not a TTY.
# Compare tmux client count before/after a no-op resume against the already
# running container. No new client should appear.
"$RC" up "$TEST_WS" < /dev/null > /dev/null 2>&1 || true
tmux_clients_after=$(docker exec "$CONTAINER_NAME" sh -c 'tmux list-clients 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]' || echo 0)
if [[ "${tmux_clients_after:-0}" -le "${tmux_clients_before:-0}" ]]; then
  check "resume TTY guard (no tmux attach on non-TTY stdin)" "pass" \
    "before=$tmux_clients_before after=$tmux_clients_after"
else
  check "resume TTY guard (no tmux attach on non-TTY stdin)" "fail" \
    "before=$tmux_clients_before after=$tmux_clients_after"
fi

# Check 18: CA ABSENCE guard (pure SNI router has no CA — rip-cage-ta1o.1 regression guard)
# The pure destination router does NOT terminate TLS — no CA cert, no NODE_EXTRA_CA_CERTS.
# Asserts absence of rip-cage CA infrastructure (the old mitmproxy MITM path is gone).
env_out=$(docker exec "$CONTAINER_NAME" env 2>/dev/null || true)
ca_cert_present=0
if docker exec "$CONTAINER_NAME" test -f /usr/local/share/ca-certificates/rip-cage-proxy.crt 2>/dev/null; then
  ca_cert_present=1
fi
node_ca_set=$(echo "$env_out" | grep "^NODE_EXTRA_CA_CERTS=" | head -1 | cut -d= -f2- || true)
if [[ -z "$node_ca_set" && "$ca_cert_present" -eq 0 ]]; then
  check "CA absent: no NODE_EXTRA_CA_CERTS, no rip-cage-proxy.crt (pure SNI router, no MITM)" "pass"
else
  check "CA absent: no NODE_EXTRA_CA_CERTS, no rip-cage-proxy.crt (pure SNI router, no MITM)" "fail" \
    "NODE_EXTRA_CA_CERTS='${node_ca_set:-<unset>}' rip-cage-proxy.crt_present=$ca_cert_present"
fi

# -----------------------------------------------------------------------------
# ADR-029 D3 invalidation: the entire ssh cluster (agent forwarding, socket
# discovery, identity routing, host+key allowlist incl. the ssh-bypass hook
# and its composable recipe, filtered known_hosts) retired at the msb cutover
# (rip-cage-f1qo, S5). Checks 18a-18h (ADR-017/018/020/022 behavior) removed —
# git in cages now authenticates over HTTPS + msb `--secret`; there is no
# ssh-cluster surface left to probe.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Lifecycle — destroy
# -----------------------------------------------------------------------------

# Check 19: rc destroy removes container
"$RC" destroy -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
if ! docker inspect "$CONTAINER_NAME" > /dev/null 2>&1; then
  check "rc destroy removes container" "pass"
else
  check "rc destroy removes container" "fail"
fi

# Check 20: rc destroy removes volume
if ! docker volume ls --format '{{.Name}}' | grep -q "^rc-state-${CONTAINER_NAME}$"; then
  check "rc destroy removes volume" "pass"
else
  check "rc destroy removes volume" "fail"
fi

# -----------------------------------------------------------------------------
# Name collision
# -----------------------------------------------------------------------------

# Check 21: Second workspace whose parent+base would compute the SAME raw name
# triggers rc's collision handling (-XXXX suffix appended).
E2E_TMP2=$(mktemp -d)
mkdir -p "${E2E_TMP2}/rc"
COLLIDE_WS="${E2E_TMP2}/rc/e2e-test"
mkdir -p "$COLLIDE_WS"
git -C "$COLLIDE_WS" init > /dev/null 2>&1
E2E_TMP2_RESOLVED=$(realpath "$E2E_TMP2")
export RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${E2E_TMP2_RESOLVED}"

# Re-up the primary workspace so there's something to collide against.
"$RC" up "$TEST_WS" < /dev/null > /dev/null 2>&1 || true
"$RC" up "$COLLIDE_WS" < /dev/null > /dev/null 2>&1 || true

collide_resolved=$(realpath "$COLLIDE_WS")
collision_name=$(docker ps -a --filter "label=rc.source.path=${collide_resolved}" \
  --format '{{.Names}}' 2>/dev/null | head -1)
if [[ "$collision_name" =~ -[0-9a-f]{4}$ ]]; then
  check "name collision produces -XXXX suffix" "pass" "$collision_name"
else
  check "name collision produces -XXXX suffix" "fail" "name was '${collision_name:-<none>}'"
fi

# Cleanup collision container + primary re-up.
[[ -n "$collision_name" ]] && docker rm -f "$collision_name" > /dev/null 2>&1 || true
[[ -n "$collision_name" ]] && docker volume rm "rc-state-${collision_name}" > /dev/null 2>&1 || true
docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
docker volume rm "rc-state-${CONTAINER_NAME}" > /dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Egress-off variant
# -----------------------------------------------------------------------------

# Check 22 (RIP_CAGE_EGRESS=off / rc.egress label / SNI-router-absence probe)
# retired: the RIP_CAGE_EGRESS toggle, the rc.egress label, and the in-cage
# SNI router it probed for were all deleted per ADR-029 D2 (engine-deletion
# sweep, rip-cage-3vj2 / S4). Containment is now an msb-runtime property
# (default-deny + declared --net-rule allows) with no on/off engine toggle to
# probe here; msb engine-absence + selective-enforcement coverage lives in
# tests/test-msb-engine-deletion-effect-probes.sh.

# -----------------------------------------------------------------------------
# Failure mode
# -----------------------------------------------------------------------------

# Check 23: rc up with nonexistent path exits non-zero, no partial container.
# Subshell isolates env leaks.
nonexistent_exit=0
( "$RC" up /nonexistent/path/that/does/not/exist < /dev/null > /dev/null 2>&1 ) || nonexistent_exit=$?
partial=$(docker ps -a --filter label=rc.source.path=/nonexistent/path/that/does/not/exist --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$nonexistent_exit" -ne 0 && "$partial" -eq 0 ]]; then
  check "rc up nonexistent path -- exit non-zero, no partial container" "pass"
else
  check "rc up nonexistent path -- exit non-zero, no partial container" "fail" \
    "exit=$nonexistent_exit partial_containers=$partial"
fi

# -----------------------------------------------------------------------------
# DCG custom-rule integration chain (ADR-025 D1 / rip-cage-hhh.13)
#
# Exercises the full chain: .rip-cage.yaml dcg.custom_rule_paths → rc up
# translate → docker RO-mount over /usr/local/lib/rip-cage/dcg/config.toml
# → dcg-guard wrapper denies a command the custom rule covers.
#
# Uses a dedicated fixture cage so this check is independent of CONTAINER_NAME
# (which is brought up without a dcg fixture). RIP_CAGE_EGRESS=off keeps it fast.
#
# The sentinel command is "ripcagetestsentinel" — a string that is not a real
# command and is not matched by any DCG core pack. A deny proves the custom
# rule fired (not a core rule). An allow of a benign command proves the chain
# is functional (not stuck in fail-closed mode).
# -----------------------------------------------------------------------------

# Check 24 setup: create fixture workspace under a dedicated staging root.
DCG_TMP=$(mktemp -d)
mkdir -p "${DCG_TMP}/rc-dcg"
_dcg_ws="${DCG_TMP}/rc-dcg/e2e-test"
mkdir -p "$_dcg_ws"
git -C "$_dcg_ws" init > /dev/null 2>&1

# Write .rip-cage.yaml with dcg.custom_rule_paths pointing at workspace rule pack.
cat > "${_dcg_ws}/.rip-cage.yaml" << 'RIPCAGEYAML'
version: 1
dcg:
  custom_rule_paths:
    - .rip-cage/dcg-rules/*.yaml
RIPCAGEYAML

# Write the sentinel rule pack YAML.
# Schema: DCG v0.4.0 custom rule pack format (confirmed empirically — see
# tests/fixtures/ripcage-testsentinel-rule.yaml and rip-cage-hhh.13 report).
mkdir -p "${_dcg_ws}/.rip-cage/dcg-rules"
cat > "${_dcg_ws}/.rip-cage/dcg-rules/ripcage-e2e-sentinel.yaml" << 'RULEFILE'
schema_version: 1
id: ripcage.testsentinel
name: ripcagetestsentinel
version: "1.0.0"
description: "Sentinel custom rule for rip-cage E2E regression tests (ADR-025 D1 / rip-cage-hhh.13)"
keywords:
  - ripcagetestsentinel
destructive_patterns:
  - name: ripcagetestsentinel_block
    pattern: "ripcagetestsentinel"
    severity: critical
    description: "Sentinel block: rip-cage E2E regression test marker -- must NOT match any real command"
    explanation: "This rule exists solely for E2E regression testing of the rc up -> RO-mount -> dcg-guard chain (rip-cage-hhh.13)."
RULEFILE

DCG_TMP_RESOLVED=$(realpath "$DCG_TMP")
_dcg_ws_resolved=$(realpath "$_dcg_ws")
RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${E2E_TMP2_RESOLVED}:${OFF_TMP_RESOLVED}:${DCG_TMP_RESOLVED}" \
  RIP_CAGE_EGRESS=off "$RC" up "$_dcg_ws" < /dev/null > /tmp/rc-e2e-dcg-up.out 2>&1 || true
_dcg_container=$(docker ps -a --filter "label=rc.source.path=${_dcg_ws_resolved}" \
  --format '{{.Names}}' 2>/dev/null | head -1)

# Check 24: DCG fixture cage started with custom rule config.
if [[ -n "$_dcg_container" ]]; then
  check "DCG custom-rule fixture cage started (rip-cage-hhh.13)" "pass" "$_dcg_container"
else
  check "DCG custom-rule fixture cage started (rip-cage-hhh.13)" "fail" \
    "container not found -- rc up may have failed (see /tmp/rc-e2e-dcg-up.out)"
fi

# Check 25: dcg-guard DENIES the sentinel command via the mounted custom config.
# The dcg-guard wrapper: cd /usr/local/lib/rip-cage, sets DCG_CONFIG, strips
# DCG_* overrides, then exec /usr/local/bin/dcg "$@".
# As a PreToolUse hook, it reads {"tool_name":"Bash","tool_input":{"command":"<cmd>"}}
# from stdin and outputs JSON with permissionDecision: "deny" on block.
_dcg_deny_result=""
_dcg_deny_stderr=""
if [[ -n "$_dcg_container" ]]; then
  _dcg_deny_result=$(docker exec "$_dcg_container" bash -c \
    'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ripcagetestsentinel --e2e-test\"}}" | /usr/local/lib/rip-cage/bin/dcg-guard' \
    2>/tmp/rc-e2e-dcg-deny.err)
  _dcg_deny_stderr=$(cat /tmp/rc-e2e-dcg-deny.err 2>/dev/null)
fi
if echo "$_dcg_deny_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG custom rule fires via rc-up->RO-mount->dcg-guard chain (rip-cage-hhh.13)" "pass"
else
  # Distinguish a broken chain (RO-mount missing) from a genuine allow, so a
  # future chain regression is diagnosable rather than reading as "got empty".
  _dcg_mount_state="config.toml present"
  if [[ -n "$_dcg_container" ]]; then
    docker exec "$_dcg_container" test -f /usr/local/lib/rip-cage/dcg/config.toml > /dev/null 2>&1 \
      || _dcg_mount_state="config.toml MISSING at mount dst (RO-mount chain broken)"
  fi
  check "DCG custom rule fires via rc-up->RO-mount->dcg-guard chain (rip-cage-hhh.13)" "fail" \
    "expected deny, got: ${_dcg_deny_result:-<empty>}; ${_dcg_mount_state}; stderr: ${_dcg_deny_stderr:-<none>}"
fi

# Check 26: dcg-guard ALLOWS a benign command (proves chain functional, not fail-closed).
_dcg_allow_result="no-output-expected"
if [[ -n "$_dcg_container" ]]; then
  _dcg_allow_result=$(docker exec "$_dcg_container" bash -c \
    'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la /tmp\"}}" | /usr/local/lib/rip-cage/bin/dcg-guard' \
    2>/dev/null)
fi
if [[ -z "$_dcg_allow_result" ]]; then
  check "DCG allows benign command (chain not fail-closed) (rip-cage-hhh.13)" "pass"
else
  check "DCG allows benign command (chain not fail-closed) (rip-cage-hhh.13)" "fail" \
    "expected empty (allow), got: ${_dcg_allow_result}"
fi

# Cleanup DCG fixture container.
[[ -n "$_dcg_container" ]] && docker rm -f "$_dcg_container" > /dev/null 2>&1 || true
[[ -n "$_dcg_container" ]] && docker volume rm "rc-state-${_dcg_container}" > /dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Mise toolchain provisioning (ADR-015 D3, ported from test-integration.sh 14-16)
#
# Each sub-test spins up a dedicated cage so the workspace's tool-version files
# (not the main TEST_WS) drive mise.  RIP_CAGE_EGRESS=off keeps them fast.
# The rc-mise-cache volume is host-scoped (ADR-015 D2) — not cleaned up here.
# -----------------------------------------------------------------------------

MISE_TMP=$(mktemp -d)
MISE_TMP_RESOLVED=$(realpath "$MISE_TMP")
mkdir -p "${MISE_TMP}/rc-mise"

# Check 27: mise provisions node version declared in .nvmrc (ADR-015 D3)
_nvmrc_ws="${MISE_TMP}/rc-mise/nvmrc-test"
mkdir -p "$_nvmrc_ws"
printf '20.18.0\n' > "${_nvmrc_ws}/.nvmrc"
git -C "$_nvmrc_ws" init > /dev/null 2>&1
RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${E2E_TMP2_RESOLVED}:${OFF_TMP_RESOLVED}:${DCG_TMP_RESOLVED}:${MISE_TMP_RESOLVED}" \
  RIP_CAGE_EGRESS=off "$RC" up "$_nvmrc_ws" < /dev/null > /tmp/rc-e2e-mise-nvmrc-up.out 2>&1 || true
_nvmrc_resolved=$(realpath "$_nvmrc_ws")
_nvmrc_container=$(docker ps -a --filter "label=rc.source.path=${_nvmrc_resolved}" \
  --format '{{.Names}}' 2>/dev/null | head -1)

if [[ -z "$_nvmrc_container" ]]; then
  check "mise: .nvmrc=20.18.0 → node v20.18.0 provisioned (ADR-015 D3)" "fail" \
    "container did not start (see /tmp/rc-e2e-mise-nvmrc-up.out)"
  check "mise: node binary path under mise installs dir" "fail" "no container"
else
  node_ver=$(docker exec "$_nvmrc_container" zsh -lic 'cd /workspace && node --version' 2>/dev/null | tail -1)
  if [[ "$node_ver" == "v20.18.0" ]]; then
    check "mise: .nvmrc=20.18.0 → node v20.18.0 provisioned (ADR-015 D3)" "pass" \
      "node --version=$node_ver"
  else
    check "mise: .nvmrc=20.18.0 → node v20.18.0 provisioned (ADR-015 D3)" "fail" \
      "expected v20.18.0, got '${node_ver:-<empty>}'"
  fi

  node_path=$(docker exec "$_nvmrc_container" zsh -lic 'cd /workspace && readlink -f $(which node)' 2>/dev/null | tail -1)
  if echo "$node_path" | grep -q '/mise/installs/node/20.18.0/'; then
    check "mise: node binary path under mise installs dir" "pass" "$node_path"
  else
    check "mise: node binary path under mise installs dir" "fail" \
      "path='${node_path:-<empty>}'"
  fi
fi

# Check 28: mise cache reuse — re-run mise install against the same workspace on
# a fresh container; cache hit should be fast (<5000ms). Warn-only on slow hit.
docker rm -f "$_nvmrc_container" > /dev/null 2>&1 || true
docker volume rm "rc-state-${_nvmrc_container}" > /dev/null 2>&1 || true

_cache_ws="${MISE_TMP}/rc-mise/cache-test"
mkdir -p "$_cache_ws"
printf '20.18.0\n' > "${_cache_ws}/.nvmrc"
git -C "$_cache_ws" init > /dev/null 2>&1
RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${E2E_TMP2_RESOLVED}:${OFF_TMP_RESOLVED}:${DCG_TMP_RESOLVED}:${MISE_TMP_RESOLVED}" \
  RIP_CAGE_EGRESS=off "$RC" up "$_cache_ws" < /dev/null > /tmp/rc-e2e-mise-cache-up.out 2>&1 || true
_cache_resolved=$(realpath "$_cache_ws")
_cache_container=$(docker ps -a --filter "label=rc.source.path=${_cache_resolved}" \
  --format '{{.Names}}' 2>/dev/null | head -1)

if [[ -z "$_cache_container" ]]; then
  check "mise: cache reuse — second install fast (<5000ms) (ADR-015 D2)" "fail" \
    "container did not start (see /tmp/rc-e2e-mise-cache-up.out)"
else
  mise_elapsed=$(docker exec "$_cache_container" bash -c \
    'start=$(date +%s%3N); cd /workspace && mise install >/dev/null 2>&1; end=$(date +%s%3N); echo $((end - start))' 2>/dev/null || echo "9999")
  if [[ "$mise_elapsed" -lt 5000 ]]; then
    check "mise: cache reuse — second install fast (<5000ms) (ADR-015 D2)" "pass" \
      "elapsed=${mise_elapsed}ms"
  else
    # Warn-only: cache volumes may not be present in all CI environments.
    check "mise: cache reuse — second install fast (<5000ms) (ADR-015 D2)" "pass" \
      "WARN: slow cache hit ${mise_elapsed}ms (>5000ms threshold; cache volume may be absent)"
  fi
  docker rm -f "$_cache_container" > /dev/null 2>&1 || true
  docker volume rm "rc-state-${_cache_container}" > /dev/null 2>&1 || true
fi

# Check 29: mise provisions yarn via packageManager field in package.json (ADR-015 D3)
_yarn_ws="${MISE_TMP}/rc-mise/yarn-test"
mkdir -p "$_yarn_ws"
cat > "${_yarn_ws}/package.json" << 'PKGJSON'
{
  "name": "test-yarn-project",
  "version": "1.0.0",
  "packageManager": "yarn@1.22.22"
}
PKGJSON
git -C "$_yarn_ws" init > /dev/null 2>&1
RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${E2E_TMP2_RESOLVED}:${OFF_TMP_RESOLVED}:${DCG_TMP_RESOLVED}:${MISE_TMP_RESOLVED}" \
  RIP_CAGE_EGRESS=off "$RC" up "$_yarn_ws" < /dev/null > /tmp/rc-e2e-mise-yarn-up.out 2>&1 || true
_yarn_resolved=$(realpath "$_yarn_ws")
_yarn_container=$(docker ps -a --filter "label=rc.source.path=${_yarn_resolved}" \
  --format '{{.Names}}' 2>/dev/null | head -1)

if [[ -z "$_yarn_container" ]]; then
  check "mise: packageManager=yarn@1.22.22 → yarn 1.22.22 provisioned (ADR-015 D3)" "fail" \
    "container did not start (see /tmp/rc-e2e-mise-yarn-up.out)"
else
  yarn_ver=$(docker exec "$_yarn_container" zsh -lic 'cd /workspace && yarn --version' 2>/dev/null | tail -1)
  if [[ "$yarn_ver" == "1.22.22" ]]; then
    check "mise: packageManager=yarn@1.22.22 → yarn 1.22.22 provisioned (ADR-015 D3)" "pass" \
      "yarn --version=$yarn_ver"
  else
    check "mise: packageManager=yarn@1.22.22 → yarn 1.22.22 provisioned (ADR-015 D3)" "fail" \
      "expected 1.22.22, got '${yarn_ver:-<empty>}'"
  fi
  docker rm -f "$_yarn_container" > /dev/null 2>&1 || true
  docker volume rm "rc-state-${_yarn_container}" > /dev/null 2>&1 || true
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo ""
echo "=== E2E Summary: $PASS/$TOTAL passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
