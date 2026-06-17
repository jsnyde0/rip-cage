#!/usr/bin/env bash
# test-mediator-lifecycle.sh — Host-tier unit tests for the egress-mediator launch
# seam (rip-cage-ta1o.5.8 / ADR-026 D5).
#
# Proves the "third leg" of the composable-mediator seam after the .5.8 fix:
#   A (child .5.1): select a provider via config + bake hooks to registry
#   B (child .5.2): router forwards to mediator's port + uid-exemption
#   C (THIS / .5.8): mediator is launched via host-driven root docker exec
#                    (option-a fix: moves launch from init-rip-cage.sh to
#                    _up_init_mediator + init-mediator.sh)
#
# Architecture change from .5.7 to .5.8:
#   OLD (.5.7): init-rip-cage.sh section 11b ran as USER agent -> could not su
#   NEW (.5.8): init-mediator.sh runs via docker exec -u root -> can su to mediator uid
#               + nohup survives exec session return + no EXIT trap timing bug
#
# =============================================================================
# Test structure (all host-only; NO docker required for this suite)
# =============================================================================
#
#   G1  — grep-guard (always / host-only):
#     G1a — 'mitmproxy|iron-proxy|clawpatrol' returns ZERO hits in rc + init-rip-cage.sh
#           + init-mediator.sh (ADR-005 D12 FIRM)
#     G1b — 'RC_MEDIATOR' IS present in rc (the threading exists)
#     G1c — '_up_init_mediator' IS present in rc (the host-exec launch function exists)
#     G1d — 'init-mediator.sh' IS referenced in rc (the new launch script is wired in)
#     G1e — init-mediator.sh exists in the repo (not just referenced)
#     G1f — section 11b in init-rip-cage.sh is COMMENT-ONLY (no dispatch code remains)
#
#   U1  — cmd_up RC_MEDIATOR threading (source-level unit test, no docker):
#     U1a — config with network.egress.mediator: my-proxy => RC_MEDIATOR=my-proxy in _UP_RUN_ARGS
#     U1b — config with network.egress.mediator: none (default) => RC_MEDIATOR NOT in _UP_RUN_ARGS
#     U1c — no config file at all => RC_MEDIATOR NOT in _UP_RUN_ARGS (byte-identical to today)
#
#   U2  — init-mediator.sh dispatch logic (sourced-function unit test, no docker):
#     U2a    — RC_MEDIATOR set => init-mediator.sh fires; prints "starting" message
#     U2a-uid— su is called with configured non-root uid (loop-prevention assertion)
#     U2b    — RC_MEDIATOR unset => init-mediator.sh exits 0 silently
#     U2c    — RC_MEDIATOR set but registry dir absent => exits non-zero with error
#     U2d    — run_as_uid file contains empty string => fail-closed (ADR-001)
#     U2e    — run_as_uid="0" => fail-closed / refuse to start as root (ADR-001)
#     U2f    — run_as_uid="root" => fail-closed / refuse to start as root (ADR-001)
#
#   U3  — No EXIT trap in init-rip-cage.sh (F4 fix from .5.8):
#     U3  — init-rip-cage.sh has NO 'trap.*teardown.*EXIT' in the mediator block
#           (the EXIT-trap timing bug that killed the mediator is gone)
#
#   U4  — egress=off + mediator != none => reject loud (Finding 3):
#     U4a — validation guard for egress=off+mediator present in rc source
#     U4b — with egress=off, mediator=my-proxy is NOT threaded (or explicitly rejected)
#
#   M1  — mediator-env secret channel (F2 / rip-cage-ta1o.5.8):
#     M1a — --mediator-env flag is parsed by cmd_up (source-level check)
#     M1b — --mediator-env-file flag is parsed by cmd_up (source-level check)
#     M1c — _UP_MEDIATOR_ENV_ARGS is set by --mediator-env (never goes into _UP_RUN_ARGS)
#
#   O1  — ordering assertion (source-level):
#     O1a  — _up_init_mediator called AFTER _up_init_firewall and BEFORE _up_init_container
#            in rc cmd_up (both create and resume paths)
#     O1b  — RC_MEDIATOR threading in rc appears AFTER RC_MULTIPLEXER threading
#     O1c  — _up_init_firewall call appears BEFORE _up_init_container call in rc
#
# =============================================================================
# Conventions:
#   * FAILURES counter + [[ $FAILURES -eq 0 ]] || exit 1 (no prose-only red)
#   * No docker / no live container required for any test in this file
#   * Source rc with explicit path (per rip-cage-source-rc-bare-vs-explicit)
#   * Cleanup via trap
# =============================================================================
#
# Run:
#   bash tests/test-mediator-lifecycle.sh
#
# Wired into tests/run-host.sh (host-only tier — no NEEDS_CONTAINER).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
U1_TMP=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329
cleanup() {
  [[ -n "${U1_TMP:-}" && -d "${U1_TMP:-}" ]] && rm -rf "$U1_TMP"
}
trap cleanup EXIT

echo "=== test-mediator-lifecycle.sh — egress-mediator launch seam (rip-cage-ta1o.5.8) ==="
echo ""

# ---------------------------------------------------------------------------
# G1: Grep-guard (always / host-only)
# ---------------------------------------------------------------------------
echo "--- G1: grep-guards ---"

# G1a — zero hardcoded mediator names (ADR-005 D12 FIRM)
G1A_HITS=$(grep -nE 'mitmproxy|iron-proxy|clawpatrol' \
  "${REPO_ROOT}/rc" "${REPO_ROOT}/init-rip-cage.sh" "${REPO_ROOT}/init-mediator.sh" 2>/dev/null || true)
if [[ -z "$G1A_HITS" ]]; then
  pass "G1a zero hardcoded mediator names in rc + init-rip-cage.sh + init-mediator.sh (ADR-005 D12)"
else
  fail "G1a hardcoded mediator names found in rc or init-rip-cage.sh or init-mediator.sh" "${G1A_HITS}"
fi

# G1b — RC_MEDIATOR IS present in rc (the threading exists)
G1B_HITS=$(grep -c 'RC_MEDIATOR' "${REPO_ROOT}/rc" 2>/dev/null || echo "0")
if [[ "${G1B_HITS:-0}" -gt 0 ]]; then
  pass "G1b RC_MEDIATOR threading present in rc (${G1B_HITS} occurrences)"
else
  fail "G1b RC_MEDIATOR threading NOT found in rc — cmd_up wiring missing"
fi

# G1c — _up_init_mediator IS present in rc (the host-exec launch function exists)
G1C_HITS=$(grep -c '_up_init_mediator' "${REPO_ROOT}/rc" 2>/dev/null || echo "0")
if [[ "${G1C_HITS:-0}" -gt 0 ]]; then
  pass "G1c _up_init_mediator function present in rc (${G1C_HITS} occurrences)"
else
  fail "G1c _up_init_mediator NOT found in rc — host-exec launch function missing"
fi

# G1d — init-mediator.sh IS referenced in rc (the new launch script is wired in)
G1D_HITS=$(grep -c 'init-mediator.sh' "${REPO_ROOT}/rc" 2>/dev/null || echo "0")
if [[ "${G1D_HITS:-0}" -gt 0 ]]; then
  pass "G1d init-mediator.sh referenced in rc (${G1D_HITS} occurrences)"
else
  fail "G1d init-mediator.sh NOT referenced in rc — launch script not wired into cmd_up"
fi

# G1e — init-mediator.sh exists in the repo
if [[ -f "${REPO_ROOT}/init-mediator.sh" ]]; then
  pass "G1e init-mediator.sh exists in repo"
else
  fail "G1e init-mediator.sh NOT found in repo — launch script missing"
fi

# G1f — section 11b in init-rip-cage.sh is comment-only (no active dispatch code remains).
# The old su/dispatch/EXIT trap code was removed in .5.8 (the bug fix).
# Check that no `if [ -n "${RC_MEDIATOR` guard exists in init-rip-cage.sh (it has moved).
# shellcheck disable=SC2016
# Intentional: grepping for a literal shell-script fragment (not expanding variables in the pattern)
if grep -qF 'if [ -n "${RC_MEDIATOR' "${REPO_ROOT}/init-rip-cage.sh" 2>/dev/null; then
  fail "G1f init-rip-cage.sh still contains RC_MEDIATOR dispatch code — old broken block not removed"
else
  pass "G1f init-rip-cage.sh has no RC_MEDIATOR dispatch code (removed in .5.8 — moved to init-mediator.sh)"
fi

echo ""

# ---------------------------------------------------------------------------
# U1: cmd_up RC_MEDIATOR threading (source-level unit test, no docker)
#
# We write a small driver script that sources rc, stubs the config helpers to
# return controlled values, runs the threading snippet, and prints the args.
# Using a driver file avoids quoting/escaping nightmares in bash -c heredocs.
# ---------------------------------------------------------------------------
echo "--- U1: cmd_up RC_MEDIATOR threading unit tests ---"

U1_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rc-med-u1-XXXXXX")

# Write the threading snippet under test — extracted by line-range from rc.
# The snippet: everything from the "rip-cage-ta1o.5.7" comment to the "unset _rc_mediator" line.
# We write it to a file and include it in each driver.
THREADING_SNIPPET_FILE="${U1_TMP}/mediator-threading-snippet.sh"
awk '/rip-cage-ta1o\.5\.7: resolve network\.egress\.mediator/,/^  unset _rc_mediator$/' \
  "${REPO_ROOT}/rc" > "$THREADING_SNIPPET_FILE"

if [[ ! -s "$THREADING_SNIPPET_FILE" ]]; then
  fail "U1 FATAL: could not extract RC_MEDIATOR threading snippet from rc — markers may have changed"
  echo "Results: FAILURES=${FAILURES}"
  [[ $FAILURES -eq 0 ]] || exit 1
fi

# Helper: write a driver script for U1 tests.
# The threading snippet uses 'local' (function context) and references $path.
# We wrap it in a function, set path to a dummy value, and export the results.
#
# Arguments:
#   $1 = driver file to create
#   $2 = what _config_global_path() returns
#   $3 = what _load_effective_config() returns (or empty to skip _load_effective_config stub)
_write_u1_driver() {
  local driver_file="$1" global_path_val="$2" eff_config_json="${3:-}"
  local load_stub=""
  if [[ -n "$eff_config_json" ]]; then
    load_stub="_load_effective_config() { echo '${eff_config_json}'; }"
  fi
  cat > "$driver_file" <<DRIVER
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "\${RC_PATH}" 2>/dev/null

# Override config helpers.
_config_global_path()  { echo '${global_path_val}'; }
_config_project_path() { echo "/nonexistent-project-stub.yaml"; }
${load_stub}

# Wrap the snippet in a function so 'local' keyword works.
# rc_egress defaults to "on" — the normal create path (egress=off is tested by U4b).
_run_threading_snippet() {
  local path="/tmp/stub-workspace"
  local rc_egress="on"
  _UP_RUN_ARGS=()
  # shellcheck source=/dev/null
  source "\${SNIPPET}"
  for arg in "\${_UP_RUN_ARGS[@]:-}"; do
    printf 'ARG: %s\n' "\$arg"
  done
}
_run_threading_snippet
DRIVER
}

# U1a — mediator=my-proxy => RC_MEDIATOR=my-proxy in _UP_RUN_ARGS
_write_u1_driver "${U1_TMP}/driver-u1a.sh" \
  "$RC" \
  '{"config":{"network":{"egress":{"mediator":"my-proxy"}}}}'

U1A_OUT=""
U1A_EXIT=0
RC_PATH="$RC" SNIPPET="$THREADING_SNIPPET_FILE" \
  bash "${U1_TMP}/driver-u1a.sh" > "${U1_TMP}/u1a.out" 2>&1 || U1A_EXIT=$?
U1A_OUT=$(cat "${U1_TMP}/u1a.out")

if echo "$U1A_OUT" | grep -q "RC_MEDIATOR=my-proxy"; then
  pass "U1a mediator=my-proxy: RC_MEDIATOR=my-proxy found in _UP_RUN_ARGS"
else
  fail "U1a mediator=my-proxy: RC_MEDIATOR=my-proxy NOT found in _UP_RUN_ARGS" "out='${U1A_OUT}' exit=${U1A_EXIT}"
fi

# U1b — mediator=none => RC_MEDIATOR NOT in _UP_RUN_ARGS
_write_u1_driver "${U1_TMP}/driver-u1b.sh" \
  "$RC" \
  '{"config":{"network":{"egress":{"mediator":"none"}}}}'

U1B_OUT=""
U1B_EXIT=0
# shellcheck disable=SC2034
RC_PATH="$RC" SNIPPET="$THREADING_SNIPPET_FILE" \
  bash "${U1_TMP}/driver-u1b.sh" > "${U1_TMP}/u1b.out" 2>&1 || U1B_EXIT=$?
U1B_OUT=$(cat "${U1_TMP}/u1b.out")

if echo "$U1B_OUT" | grep -q "RC_MEDIATOR"; then
  fail "U1b mediator=none: RC_MEDIATOR found in _UP_RUN_ARGS (should be absent)" "out='${U1B_OUT}'"
else
  pass "U1b mediator=none: RC_MEDIATOR NOT in _UP_RUN_ARGS (byte-identical to today)"
fi

# U1c — no config file => RC_MEDIATOR NOT in _UP_RUN_ARGS
# Use a non-existent path for _config_global_path so the -f check fails.
_write_u1_driver "${U1_TMP}/driver-u1c.sh" \
  "/no-config-exists-for-u1c/rip-cage.yaml" \
  ""

U1C_OUT=""
U1C_EXIT=0
# shellcheck disable=SC2034
RC_PATH="$RC" SNIPPET="$THREADING_SNIPPET_FILE" \
  bash "${U1_TMP}/driver-u1c.sh" > "${U1_TMP}/u1c.out" 2>&1 || U1C_EXIT=$?
U1C_OUT=$(cat "${U1_TMP}/u1c.out")

if echo "$U1C_OUT" | grep -q "RC_MEDIATOR"; then
  fail "U1c no config: RC_MEDIATOR found in _UP_RUN_ARGS (should be absent)" "out='${U1C_OUT}'"
else
  pass "U1c no config: RC_MEDIATOR NOT in _UP_RUN_ARGS (no regression)"
fi

echo ""

# ---------------------------------------------------------------------------
# U2: init-mediator.sh dispatch logic (unit test, no docker)
#
# Extract init-mediator.sh and run it in a controlled subshell with a fake
# /etc/rip-cage/mediators/ registry. We stub 'su' to bypass privilege
# dropping (tests run as unprivileged user on the host).
# ---------------------------------------------------------------------------
echo "--- U2: init-mediator.sh dispatch logic unit tests ---"

# Build a fake registry dir for testing — use a NON-ROOT uid ("testuser1000").
FAKE_REG="${U1_TMP}/fake-etc/rip-cage"
mkdir -p "${FAKE_REG}/mediators/test-mediator"
printf 'testuser1000' > "${FAKE_REG}/mediators/test-mediator/run_as_uid"
printf '#!/bin/sh\necho "[fake-start] started" >> %s/start.log\n' "${U1_TMP}" \
  > "${FAKE_REG}/mediators/test-mediator/start"
chmod 0755 "${FAKE_REG}/mediators/test-mediator/start"

# Patch init-mediator.sh to use our fake registry path AND a temp-based PID dir.
# /run/... doesn't exist on macOS; redirect to U1_TMP instead.
PATCHED_INIT_MED="${U1_TMP}/patched-init-mediator.sh"
sed \
  -e "s|/etc/rip-cage/mediators|${FAKE_REG}/mediators|g" \
  -e "s|/run/rip-cage-mediator-|${U1_TMP}/pid-rip-cage-mediator-|g" \
  "${REPO_ROOT}/init-mediator.sh" > "$PATCHED_INIT_MED"
chmod +x "$PATCHED_INIT_MED"

# U2a — RC_MEDIATOR set => dispatch fires AND su is called with the configured
# non-root uid (not root, not empty) — loop-prevention assertion (ADR-026 D5).
# The su stub records the uid argument it receives so we can assert it.
SU_CALLED_UID_FILE="${U1_TMP}/su-called-uid.txt"
cat > "${U1_TMP}/driver-u2a.sh" <<DRIVER
#!/usr/bin/env bash
# Stub 'su' to run as current user (no root needed in tests) AND record uid arg.
SU_CALLED_UID_FILE="${SU_CALLED_UID_FILE}"
su() {
  local _shell="" _uid="" _cmd=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -s) shift; _shell="\$1"; shift ;;
      -c) shift; _cmd="\$1"; shift ;;
      *)  _uid="\$1"; shift ;;
    esac
  done
  # Record the uid argument for the assertion.
  printf '%s\n' "\${_uid}" >> "\${SU_CALLED_UID_FILE}"
  # Run the command. Capture output to a temp PID "file" so the script can read it.
  local _out
  _out=\$(sh -c "\${_cmd}" 2>/dev/null || true)
  echo "\${_out:-0}"
}
export -f su 2>/dev/null || true
# Stub update-ca-certificates (may not exist on macOS host)
update-ca-certificates() { return 0; }
export -f update-ca-certificates 2>/dev/null || true
# Stub getent (may not exist on macOS)
getent() { echo "${U1_TMP}"; }
export -f getent 2>/dev/null || true

export RC_MEDIATOR='test-mediator'
bash "${PATCHED_INIT_MED}"
DRIVER

U2A_OUT=""
U2A_EXIT=0
bash "${U1_TMP}/driver-u2a.sh" > "${U1_TMP}/u2a.out" 2>&1 || U2A_EXIT=$?
U2A_OUT=$(cat "${U1_TMP}/u2a.out")

if echo "$U2A_OUT" | grep -qE "starting|start hook launched|done"; then
  pass "U2a RC_MEDIATOR set: init-mediator.sh fires (start message present)"
else
  fail "U2a RC_MEDIATOR set: dispatch did not fire as expected" "out='${U2A_OUT}' exit=${U2A_EXIT}"
fi

# U2a-uid — the configured non-root uid must appear in the "starting" message.
# This verifies the uid is read from the registry and passed to the privilege-drop.
# init-mediator.sh prints: "[rip-cage] init-mediator: starting '<name>' as uid '<uid>'..."
# Primary check: the uid appears in the start message (struct assertion on the dispatch).
# Secondary check: if the su stub recorded the uid, verify it matches.
if echo "$U2A_OUT" | grep -qE "as uid 'testuser1000'"; then
  pass "U2a-uid init-mediator.sh targets configured non-root uid 'testuser1000' — loop-prevention intact (ADR-026 D5)"
elif [[ -f "${SU_CALLED_UID_FILE}" ]]; then
  U2A_UID_CALLED=$(head -1 "${SU_CALLED_UID_FILE}")
  if [[ "$U2A_UID_CALLED" == "testuser1000" ]]; then
    pass "U2a-uid su called with configured non-root uid '${U2A_UID_CALLED}' — loop-prevention intact (ADR-026 D5)"
  elif [[ -z "$U2A_UID_CALLED" || "$U2A_UID_CALLED" == "0" || "$U2A_UID_CALLED" == "root" ]]; then
    fail "U2a-uid SAFETY: su was called with unsafe uid '${U2A_UID_CALLED:-EMPTY}' — loop-prevention void (ADR-026 D5)"
  else
    fail "U2a-uid su called with unexpected uid '${U2A_UID_CALLED}'" "expected 'testuser1000'"
  fi
else
  fail "U2a-uid SAFETY: uid not visible in output and su stub not invoked" \
    "out='${U2A_OUT}' exit=${U2A_EXIT}"
fi

# U2b — RC_MEDIATOR unset => init-mediator.sh exits 0 silently (or with "none" message)
# (no env: RC_MEDIATOR is unset for this test)
U2B_OUT=""
U2B_EXIT=0
env -i HOME="${HOME}" PATH="${PATH}" bash "${PATCHED_INIT_MED}" > "${U1_TMP}/u2b.out" 2>&1 || U2B_EXIT=$?
U2B_OUT=$(cat "${U1_TMP}/u2b.out")

if echo "$U2B_OUT" | grep -qE "starting|start hook launched"; then
  fail "U2b RC_MEDIATOR unset: dispatch fired unexpectedly" "out='${U2B_OUT}'"
elif [[ "$U2B_EXIT" -eq 0 ]]; then
  pass "U2b RC_MEDIATOR unset: dispatch skips, exits 0 (no mediator started)"
else
  pass "U2b RC_MEDIATOR unset: dispatch skips (exit=${U2B_EXIT})"
fi

# U2c — RC_MEDIATOR set but registry dir absent => exits non-zero with error
NONEXISTENT_PATCHED="${U1_TMP}/nonexistent-init-med.sh"
sed \
  -e "s|/etc/rip-cage/mediators|/nonexistent-reg-u2c/mediators|g" \
  -e "s|/run/rip-cage-mediator-|${U1_TMP}/pid-u2c-|g" \
  "${REPO_ROOT}/init-mediator.sh" > "$NONEXISTENT_PATCHED"
chmod +x "$NONEXISTENT_PATCHED"

U2C_OUT=""
U2C_EXIT=0
RC_MEDIATOR='nonexistent-mediator' bash "$NONEXISTENT_PATCHED" > "${U1_TMP}/u2c.out" 2>&1 || U2C_EXIT=$?
U2C_OUT=$(cat "${U1_TMP}/u2c.out")

if [[ "$U2C_EXIT" -ne 0 ]] && echo "$U2C_OUT" | grep -qiE "ERROR.*mediator|registry dir absent"; then
  pass "U2c registry absent: exits non-zero with error about missing registry"
elif [[ "$U2C_EXIT" -ne 0 ]]; then
  pass "U2c registry absent: exits non-zero (error surfaced)"
else
  fail "U2c registry absent: should exit non-zero but exited 0" "out='${U2C_OUT}'"
fi

# ---------------------------------------------------------------------------
# U2d-U2f: fail-closed run_as_uid validation (ADR-001)
#
# If the run_as_uid file contains empty, "0", or "root", the mediator MUST NOT
# start — fail closed with a loud error. This prevents the mediator from running
# as root, which would void the uid-exemption loop-prevention (ADR-026 D5).
# ---------------------------------------------------------------------------

# Helper: build a registry with a specific uid value and run init-mediator.sh.
_run_uid_test() {
  local uid_val="$1"
  local test_reg="${U1_TMP}/uid-test-reg-${uid_val}"
  local test_med="${test_reg}/mediators/baduid-med"
  mkdir -p "$test_med"
  if [[ "$uid_val" == "MISSING" ]]; then
    : # do not create run_as_uid
  elif [[ "$uid_val" == "EMPTY" ]]; then
    printf '' > "${test_med}/run_as_uid"
  else
    printf '%s' "$uid_val" > "${test_med}/run_as_uid"
  fi
  printf '#!/bin/sh\necho started\n' > "${test_med}/start"
  chmod 0755 "${test_med}/start"

  local patched="${U1_TMP}/uid-init-med-${uid_val}.sh"
  sed \
    -e "s|/etc/rip-cage/mediators|${test_reg}/mediators|g" \
    -e "s|/run/rip-cage-mediator-|${U1_TMP}/pid-uid-${uid_val}-|g" \
    "${REPO_ROOT}/init-mediator.sh" > "$patched"
  chmod +x "$patched"

  RC_MEDIATOR='baduid-med' bash "$patched" > "${U1_TMP}/uid-out-${uid_val}.txt" 2>&1
  U2X_EXIT=$?
  U2X_OUT=$(cat "${U1_TMP}/uid-out-${uid_val}.txt")
}

# U2d — empty run_as_uid => fail closed (refuse to start mediator as root)
U2X_EXIT=0 U2X_OUT=""
_run_uid_test "EMPTY"
if [[ "$U2X_EXIT" -ne 0 ]] && echo "$U2X_OUT" | grep -qiE "ERROR|REFUSE|invalid.*uid|empty.*uid|uid.*empty|uid.*invalid|root"; then
  pass "U2d run_as_uid=empty: fail-closed with error (ADR-001 / ADR-026 D5)"
elif [[ "$U2X_EXIT" -ne 0 ]]; then
  pass "U2d run_as_uid=empty: exits non-zero (fail-closed)"
else
  fail "U2d run_as_uid=empty: SAFETY — mediator started with empty uid (would run as root)" \
    "out='${U2X_OUT}' exit=${U2X_EXIT}"
fi

# U2e — run_as_uid="0" => fail closed (numeric root uid)
U2X_EXIT=0 U2X_OUT=""
_run_uid_test "0"
if [[ "$U2X_EXIT" -ne 0 ]] && echo "$U2X_OUT" | grep -qiE "ERROR|REFUSE|invalid.*uid|root.*uid|uid.*root|uid.*0"; then
  pass "U2e run_as_uid=0: fail-closed with error (ADR-001 / ADR-026 D5)"
elif [[ "$U2X_EXIT" -ne 0 ]]; then
  pass "U2e run_as_uid=0: exits non-zero (fail-closed)"
else
  fail "U2e run_as_uid=0: SAFETY — mediator started as uid 0 (root), loop-prevention void" \
    "out='${U2X_OUT}' exit=${U2X_EXIT}"
fi

# U2f — run_as_uid="root" => fail closed (name of root user)
U2X_EXIT=0 U2X_OUT=""
_run_uid_test "root"
if [[ "$U2X_EXIT" -ne 0 ]] && echo "$U2X_OUT" | grep -qiE "ERROR|REFUSE|invalid.*uid|root.*uid|uid.*root"; then
  pass "U2f run_as_uid=root: fail-closed with error (ADR-001 / ADR-026 D5)"
elif [[ "$U2X_EXIT" -ne 0 ]]; then
  pass "U2f run_as_uid=root: exits non-zero (fail-closed)"
else
  fail "U2f run_as_uid=root: SAFETY — mediator started as 'root', loop-prevention void" \
    "out='${U2X_OUT}' exit=${U2X_EXIT}"
fi

echo ""

# ---------------------------------------------------------------------------
# U3: No EXIT trap for mediator in init-rip-cage.sh (.5.8 fix)
#
# Bug: the old init-rip-cage.sh section 11b registered an EXIT trap that
# tore down the mediator when one-shot init exited (immediately, since
# init-rip-cage.sh is a one-shot docker exec and the entrypoint is sleep
# infinity). This killed the mediator every time.
# Fix: the launch is now in init-mediator.sh (root docker exec); init-rip-cage.sh
# has no mediator dispatch and no EXIT trap for the mediator. The mediator
# survives because it's nohup-backgrounded before the exec session returns.
# ---------------------------------------------------------------------------
echo "--- U3: No EXIT trap for mediator in init-rip-cage.sh (F4 fix) ---"

# Check that init-rip-cage.sh has NO mediator EXIT trap.
if grep -qE 'trap.*teardown.*EXIT|trap.*EXIT.*teardown' \
    "${REPO_ROOT}/init-rip-cage.sh" 2>/dev/null; then
  fail "U3 SAFETY: mediator EXIT trap found in init-rip-cage.sh — this kills the mediator when one-shot init exits"
else
  pass "U3 No mediator EXIT trap in init-rip-cage.sh — teardown-timing bug is gone"
fi

# Also check that init-mediator.sh does NOT have an EXIT trap for teardown.
if grep -qE 'trap.*teardown.*EXIT|trap.*EXIT.*teardown' \
    "${REPO_ROOT}/init-mediator.sh" 2>/dev/null; then
  fail "U3b SAFETY: mediator EXIT trap found in init-mediator.sh — this kills the mediator when root exec returns"
else
  pass "U3b No mediator EXIT trap in init-mediator.sh — nohup pattern used instead"
fi

echo ""

# ---------------------------------------------------------------------------
# U4: egress=off + mediator != none => cmd_up fails loud (Finding 3)
# ---------------------------------------------------------------------------
echo "--- U4: egress=off + mediator reject (Finding 3) ---"

U4_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rc-med-u4-XXXXXX")

# First check: does rc contain the validation guard?
U4_GUARD_HITS=$(grep -cE "egress.*off.*mediator|mediator.*egress.*off|_rc_mediator.*rc_egress.*off|rc_egress.*off.*_rc_mediator" "${REPO_ROOT}/rc" 2>/dev/null || echo "0")

if [[ "${U4_GUARD_HITS:-0}" -gt 0 ]]; then
  pass "U4a egress=off+mediator guard: validation present in rc (${U4_GUARD_HITS} occurrence(s))"
else
  fail "U4a SAFETY: egress=off+mediator guard NOT found in rc — with egress=off+mediator configured, cage starts in incoherent state (no router, no uid-exemption, but RC_MEDIATOR threaded)"
fi

# Second check: the threading snippet must NOT thread RC_MEDIATOR when rc_egress=off.
THREADING_SNIPPET_FILE_U4="${U4_TMP}/mediator-threading-snippet.sh"
awk '/rip-cage-ta1o\.5\.7: resolve network\.egress\.mediator/,/^  unset _rc_mediator$/' \
  "${REPO_ROOT}/rc" > "$THREADING_SNIPPET_FILE_U4"

cat > "${U4_TMP}/driver-u4b.sh" <<UDRIVER4B
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "\${RC_PATH}" 2>/dev/null

_config_global_path()  { echo '${RC}'; }
_config_project_path() { echo "/nonexistent-project-u4b.yaml"; }
_load_effective_config() { echo '{"config":{"network":{"egress":{"mediator":"my-proxy"}}}}'; }

_run_threading_with_egress_off() {
  local path="/tmp/stub-workspace"
  local rc_egress="off"
  _UP_RUN_ARGS=()
  # shellcheck source=/dev/null
  source "\${SNIPPET}"
  for arg in "\${_UP_RUN_ARGS[@]:-}"; do
    printf 'ARG: %s\n' "\$arg"
  done
}
_run_threading_with_egress_off
UDRIVER4B

U4B_OUT=""
U4B_EXIT=0
RC_PATH="$RC" SNIPPET="$THREADING_SNIPPET_FILE_U4" \
  bash "${U4_TMP}/driver-u4b.sh" > "${U4_TMP}/u4b.out" 2>&1 || U4B_EXIT=$?
U4B_OUT=$(cat "${U4_TMP}/u4b.out")

if [[ "$U4B_EXIT" -ne 0 ]]; then
  if echo "$U4B_OUT" | grep -qiE "ERROR|REFUSE|egress.*off|mediator.*egress|requires egress"; then
    pass "U4b threading: egress=off+mediator=my-proxy rejected with loud error (ADR-001 fail-closed)"
  else
    pass "U4b threading: egress=off+mediator=my-proxy exits non-zero (fail-closed)"
  fi
elif echo "$U4B_OUT" | grep -q "RC_MEDIATOR=my-proxy"; then
  fail "U4b SAFETY: egress=off+mediator=my-proxy silently threaded RC_MEDIATOR — cage starts incoherent (no router, no uid-exemption)" \
    "out='${U4B_OUT}' exit=${U4B_EXIT}"
else
  if echo "$U4B_OUT" | grep -qiE "ERROR|REFUSE|egress.*off|mediator.*egress"; then
    pass "U4b threading: egress=off+mediator rejected (error message present, RC_MEDIATOR not threaded)"
  else
    fail "U4b SAFETY: egress=off+mediator=my-proxy produced no rejection and no error — silent incoherent config" \
      "out='${U4B_OUT}' exit=${U4B_EXIT}"
  fi
fi

rm -rf "${U4_TMP}"

echo ""

# ---------------------------------------------------------------------------
# M1: Mediator-only secret channel (rip-cage-ta1o.5.8 / F2)
#
# --mediator-env KEY=VALUE (repeatable) and --mediator-env-file PATH populate
# _UP_MEDIATOR_ENV_ARGS, which goes ONLY into the _up_init_mediator docker exec,
# NEVER into docker run / _UP_RUN_ARGS.
# ---------------------------------------------------------------------------
echo "--- M1: mediator-env secret channel ---"

# M1a — --mediator-env flag is parsed by cmd_up (source-level check in rc)
M1A_HITS=$(grep -c '\-\-mediator-env' "${REPO_ROOT}/rc" 2>/dev/null || echo "0")
if [[ "${M1A_HITS:-0}" -gt 0 ]]; then
  pass "M1a --mediator-env flag present in rc (${M1A_HITS} occurrences)"
else
  fail "M1a --mediator-env NOT found in rc — secret channel flag missing"
fi

# M1b — --mediator-env-file flag is parsed by cmd_up (source-level check in rc)
M1B_HITS=$(grep -c '\-\-mediator-env-file' "${REPO_ROOT}/rc" 2>/dev/null || echo "0")
if [[ "${M1B_HITS:-0}" -gt 0 ]]; then
  pass "M1b --mediator-env-file flag present in rc (${M1B_HITS} occurrences)"
else
  fail "M1b --mediator-env-file NOT found in rc — secret channel file flag missing"
fi

# M1c — _UP_MEDIATOR_ENV_ARGS is declared in rc and NOT referenced in _UP_RUN_ARGS
M1C_DECL=$(grep -c '_UP_MEDIATOR_ENV_ARGS' "${REPO_ROOT}/rc" 2>/dev/null || echo "0")
if [[ "${M1C_DECL:-0}" -gt 0 ]]; then
  pass "M1c _UP_MEDIATOR_ENV_ARGS declared in rc (${M1C_DECL} occurrences)"
else
  fail "M1c _UP_MEDIATOR_ENV_ARGS NOT declared in rc — secret channel array missing"
fi

# M1d — _UP_MEDIATOR_ENV_ARGS must NOT be appended to _UP_RUN_ARGS
# (the secret must not leak into docker run / container-level env)
if grep -qE '_UP_RUN_ARGS.*_UP_MEDIATOR_ENV_ARGS|_UP_MEDIATOR_ENV_ARGS.*_UP_RUN_ARGS' "${REPO_ROOT}/rc" 2>/dev/null; then
  fail "M1d SECURITY: _UP_MEDIATOR_ENV_ARGS found appended to _UP_RUN_ARGS — secret would leak into container env (/proc/1/environ)"
else
  pass "M1d _UP_MEDIATOR_ENV_ARGS NOT leaked into _UP_RUN_ARGS (secret stays out of docker run)"
fi

echo ""

# ---------------------------------------------------------------------------
# O1: Ordering assertion (source-level)
# ---------------------------------------------------------------------------
echo "--- O1: Ordering assertions ---"

# O1a — _up_init_mediator is called AFTER _up_init_firewall and BEFORE _up_init_container
# on the CREATE path. Check line ordering for the create-path calls.
# We look for the LAST occurrence of each call (create path comes after resume path
# in the source; both are in cmd_up which runs serially).
# Filter: extract only lines that are actual CALL SITES (not function defs or comments).
# We look for lines of the form: <spaces><function_name> "$name" (a call pattern).
_rc_call_lines() {
  local fn="$1"
  grep -n "${fn} " "${REPO_ROOT}/rc" \
    | grep -vE '^[0-9]+:[[:space:]]*#|^[0-9]+:'"${fn}"'[[:space:]]*\(\)' \
    | cut -d: -f1
}

FIREWALL_LINES=$(_rc_call_lines '_up_init_firewall')
MEDIATOR_LINES=$(_rc_call_lines '_up_init_mediator')
CONTAINER_LINES=$(_rc_call_lines '_up_init_container')

FIREWALL_LAST_LINE=$(echo "$FIREWALL_LINES" | tail -1)
MEDIATOR_LAST_LINE=$(echo "$MEDIATOR_LINES" | tail -1)
CONTAINER_LAST_LINE=$(echo "$CONTAINER_LINES" | tail -1)

FIREWALL_FIRST_LINE=$(echo "$FIREWALL_LINES" | head -1)
MEDIATOR_FIRST_LINE=$(echo "$MEDIATOR_LINES" | head -1)
CONTAINER_FIRST_LINE=$(echo "$CONTAINER_LINES" | head -1)

if [[ -z "$FIREWALL_LAST_LINE" || -z "$MEDIATOR_LAST_LINE" || -z "$CONTAINER_LAST_LINE" ]]; then
  fail "O1a ordering: could not find all three init-function calls in rc" \
    "firewall=${FIREWALL_LAST_LINE:-<missing>} mediator=${MEDIATOR_LAST_LINE:-<missing>} container=${CONTAINER_LAST_LINE:-<missing>}"
elif [[ "$FIREWALL_LAST_LINE" -lt "$MEDIATOR_LAST_LINE" && "$MEDIATOR_LAST_LINE" -lt "$CONTAINER_LAST_LINE" ]]; then
  pass "O1a create path: _up_init_firewall (L${FIREWALL_LAST_LINE}) < _up_init_mediator (L${MEDIATOR_LAST_LINE}) < _up_init_container (L${CONTAINER_LAST_LINE}) — ordering correct"
else
  fail "O1a create path ordering wrong" \
    "firewall=L${FIREWALL_LAST_LINE} mediator=L${MEDIATOR_LAST_LINE} container=L${CONTAINER_LAST_LINE} — must be firewall < mediator < container"
fi

# O1a-resume — same for the resume path (first occurrence of each call).
if [[ -z "$FIREWALL_FIRST_LINE" || -z "$MEDIATOR_FIRST_LINE" || -z "$CONTAINER_FIRST_LINE" ]]; then
  fail "O1a-resume ordering: could not find all three init-function calls in rc (resume path)" \
    "firewall=${FIREWALL_FIRST_LINE:-<missing>} mediator=${MEDIATOR_FIRST_LINE:-<missing>} container=${CONTAINER_FIRST_LINE:-<missing>}"
elif [[ "$FIREWALL_FIRST_LINE" -lt "$MEDIATOR_FIRST_LINE" && "$MEDIATOR_FIRST_LINE" -lt "$CONTAINER_FIRST_LINE" ]]; then
  pass "O1a-resume resume path: _up_init_firewall (L${FIREWALL_FIRST_LINE}) < _up_init_mediator (L${MEDIATOR_FIRST_LINE}) < _up_init_container (L${CONTAINER_FIRST_LINE}) — ordering correct"
else
  fail "O1a-resume resume path ordering wrong" \
    "firewall=L${FIREWALL_FIRST_LINE} mediator=L${MEDIATOR_FIRST_LINE} container=L${CONTAINER_FIRST_LINE}"
fi

# O1b — in rc: RC_MEDIATOR threading appears AFTER RC_MULTIPLEXER threading
MUX_THREADING_LINE=$(grep -n 'RC_MULTIPLEXER.*_UP_RUN_ARGS\|_UP_RUN_ARGS.*RC_MULTIPLEXER' "${REPO_ROOT}/rc" | head -1 | cut -d: -f1)
MED_THREADING_LINE=$(grep -n 'RC_MEDIATOR.*_UP_RUN_ARGS\|_UP_RUN_ARGS.*RC_MEDIATOR' "${REPO_ROOT}/rc" | head -1 | cut -d: -f1)

if [[ -z "$MUX_THREADING_LINE" || -z "$MED_THREADING_LINE" ]]; then
  fail "O1b ordering: could not find RC_MULTIPLEXER or RC_MEDIATOR threading lines in rc" \
    "mux=${MUX_THREADING_LINE:-<missing>} mediator=${MED_THREADING_LINE:-<missing>}"
elif [[ "$MED_THREADING_LINE" -gt "$MUX_THREADING_LINE" ]]; then
  pass "O1b rc: RC_MEDIATOR threading (L${MED_THREADING_LINE}) appears AFTER RC_MULTIPLEXER threading (L${MUX_THREADING_LINE}) — parallel placement confirmed"
else
  fail "O1b rc: RC_MEDIATOR threading appears before RC_MULTIPLEXER threading" \
    "mux=L${MUX_THREADING_LINE} mediator=L${MED_THREADING_LINE}"
fi

# O1c — in rc: _up_init_firewall call appears BEFORE _up_init_container call (ordering guarantee)
if [[ -z "$FIREWALL_LAST_LINE" || -z "$CONTAINER_LAST_LINE" ]]; then
  fail "O1c ordering: could not find _up_init_firewall or _up_init_container call in rc" \
    "firewall_call=${FIREWALL_LAST_LINE:-<missing>} container_call=${CONTAINER_LAST_LINE:-<missing>}"
elif [[ "$FIREWALL_LAST_LINE" -lt "$CONTAINER_LAST_LINE" ]]; then
  pass "O1c rc cmd_up (create path): _up_init_firewall (L${FIREWALL_LAST_LINE}) called BEFORE _up_init_container (L${CONTAINER_LAST_LINE}) — ordering guarantee holds"
else
  fail "O1c rc cmd_up: _up_init_firewall called AFTER _up_init_container — ordering bug" \
    "firewall_call=L${FIREWALL_LAST_LINE} container_call=L${CONTAINER_LAST_LINE}"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== test-mediator-lifecycle.sh complete ==="
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
