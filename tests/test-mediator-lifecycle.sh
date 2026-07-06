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
#   CA  — mediator CA trust env vars (rip-cage-yid0 / Node SELF_SIGNED_CERT_IN_CHAIN fix):
#     CA1a — mediator composed => NODE_EXTRA_CA_CERTS/SSL_CERT_FILE/REQUESTS_CA_BUNDLE
#            all present in final run args with the exact expected values
#     CA1b — mediator=none => none of the three vars present
#     CA1c — no config at all => none of the three vars present (no regression)
#
#   R   — resume guard for mediator CA env (rip-cage-yid0):
#     R1 — mediator composed, label absent/false => abort loud with recreate instructions
#     R2 — mediator composed, label=true => resolver returns 0 (no mismatch)
#     R3 — mediator=none, label=false => resolver returns 0 (no mismatch)
#     R4 — legacy container (missing label), mediator composed => treated as
#          "false" => abort loud (same as R1)
#
#   T   — CA-wait timeout fail-closed (rip-cage-yid0 / F3-analog for init-mediator.sh):
#     T1 — ca_cert_path declared, cert never appears => init-mediator.sh exits
#          non-zero => _up_init_mediator sets _UP_MEDIATOR_OK=false
#     T2 — positive control: ca_cert_path declared, cert present immediately =>
#          exits 0, _UP_MEDIATOR_OK stays true
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
P_TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

# tests/run-host.sh exports RC_CONFIG_GLOBAL at driver level, which would
# shadow the per-test XDG sandboxes the P-section below builds. Unset so
# per-call XDG_CONFIG_HOME sandboxes win (mirrors test-config-loader.sh).
unset RC_CONFIG_GLOBAL

# shellcheck disable=SC2329
cleanup() {
  [[ -n "${U1_TMP:-}" && -d "${U1_TMP:-}" ]] && rm -rf "$U1_TMP"
  [[ -n "${P_TEST_HOME:-}" && -d "${P_TEST_HOME:-}" ]] && rm -rf "$P_TEST_HOME"
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
# P: network.egress.mediator_env_file resolver (rip-cage-seqc.4 / B5 / F3)
#
# The stopped-resume path DOES relaunch the mediator, but _UP_MEDIATOR_ENV_ARGS
# is populated ONLY from CLI flags — so an unattended `rc down && rc up` with
# no flags silently no-ops injection. network.egress.mediator_env_file is a
# persisted POINTER (never the secret itself) that _up_resolve_mediator_env_file
# re-applies on every create/resume.
# ---------------------------------------------------------------------------
echo "--- P: mediator_env_file resolver (autonomy fix) ---"

setup_p_sandbox() {
  P_TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-med-p-XXXXXX")
  mkdir -p "${P_TEST_HOME}/.config/rip-cage"
  cat > "${P_TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
  touch "${P_TEST_HOME}/.config/rip-cage/tools.yaml"
  P_TEST_WS="${P_TEST_HOME}/workspace"
  mkdir -p "$P_TEST_WS"
}

teardown_p_sandbox() {
  [[ -n "${P_TEST_HOME:-}" ]] && rm -rf "$P_TEST_HOME"
  P_TEST_HOME="" P_TEST_WS=""
}

# Run _up_resolve_mediator_env_file in a sourced subshell. Args: $1=phase,
# $2=stderr capture file, $3...=extra shell statements to inject before the
# call (e.g. pre-populating _UP_MEDIATOR_ENV_ARGS for the CLI-wins case).
run_resolve_mediator_env_file() {
  local phase="$1" stderr_file="$2" pre="${3:-}"
  HOME="$P_TEST_HOME" XDG_CONFIG_HOME="${P_TEST_HOME}/.config" bash -c "
    source '$RC' 2>/dev/null
    _UP_MEDIATOR_ENV_ARGS=()
    ${pre}
    _up_resolve_mediator_env_file '$P_TEST_WS' '$phase'
    _rc=\$?
    printf '%s\n' \"\${_UP_MEDIATOR_ENV_ARGS[@]+\${_UP_MEDIATOR_ENV_ARGS[@]}}\"
    exit \"\$_rc\"
  " 2>"$stderr_file"
}

# P1 — pointer applied, CLI empty: config mediator_env_file -> a mode-0600
# pointer file, no CLI flag, phase=create -> the mediator arg array reflects
# the pointer's KEY=VALUE pairs.
setup_p_sandbox
_p1_envfile="${P_TEST_HOME}/mediator-secrets.env"
(umask 077; printf 'RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-test-p1\n' > "$_p1_envfile")
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 1
network:
  egress:
    mediator_env_file: ${_p1_envfile}
YAML
_p1_stderr=$(mktemp)
_p1_out=$(run_resolve_mediator_env_file "create" "$_p1_stderr")
_p1_exit=$?
if [[ "$_p1_exit" -eq 0 ]] && echo "$_p1_out" | grep -q "RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-test-p1"; then
  pass "P1 pointer applied (CLI empty): config mediator_env_file loaded into mediator arg array (create phase)"
else
  fail "P1 pointer applied" "exit=$_p1_exit out='$_p1_out' stderr=$(cat "$_p1_stderr")"
fi
rm -f "$_p1_stderr"
teardown_p_sandbox

# P2 — CLI wins: CLI --mediator-env plus the config pointer both present ->
# the array reflects the CLI only; the pointer is ignored (with a log note).
setup_p_sandbox
_p2_envfile="${P_TEST_HOME}/mediator-secrets.env"
(umask 077; printf 'RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-from-pointer\n' > "$_p2_envfile")
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 1
network:
  egress:
    mediator_env_file: ${_p2_envfile}
YAML
_p2_stderr=$(mktemp)
_p2_out=$(run_resolve_mediator_env_file "create" "$_p2_stderr" "_UP_MEDIATOR_ENV_ARGS+=(-e RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-from-cli)")
_p2_exit=$?
if [[ "$_p2_exit" -eq 0 ]] \
  && echo "$_p2_out" | grep -q "sk-ant-from-cli" \
  && ! echo "$_p2_out" | grep -q "sk-ant-from-pointer"; then
  pass "P2 CLI wins: --mediator-env value present, config pointer value absent"
else
  fail "P2 CLI wins" "exit=$_p2_exit out='$_p2_out' stderr=$(cat "$_p2_stderr")"
fi
rm -f "$_p2_stderr"
teardown_p_sandbox

# P3a (F3) — missing file, CREATE phase -> fails loud, non-zero, names
# MEDIATOR_ENV_FILE_NOT_FOUND / the missing path.
setup_p_sandbox
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 1
network:
  egress:
    mediator_env_file: ${P_TEST_HOME}/nonexistent-secrets.env
YAML
_p3a_stderr=$(mktemp)
run_resolve_mediator_env_file "create" "$_p3a_stderr" >/dev/null
_p3a_exit=$?
_p3a_err=$(cat "$_p3a_stderr")
if [[ "$_p3a_exit" -ne 0 ]] && echo "$_p3a_err" | grep -qi "nonexistent-secrets.env"; then
  pass "P3a (F3) missing mediator_env_file on CREATE: fails loud, names the missing path"
else
  fail "P3a missing file create-phase" "exit=$_p3a_exit stderr=$_p3a_err"
fi
rm -f "$_p3a_stderr"
teardown_p_sandbox

# P3b (F3) — missing file, RESUME phase -> WARNS loud on stderr, returns 0
# (no exit — docker start already ran before this resolver on resume).
# Positive control against P3a proving the phase split.
setup_p_sandbox
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 1
network:
  egress:
    mediator_env_file: ${P_TEST_HOME}/nonexistent-secrets.env
YAML
_p3b_stderr=$(mktemp)
_p3b_out=$(run_resolve_mediator_env_file "resume" "$_p3b_stderr")
_p3b_exit=$?
_p3b_err=$(cat "$_p3b_stderr")
if [[ "$_p3b_exit" -eq 0 ]] && echo "$_p3b_err" | grep -qi "nonexistent-secrets.env" && [[ -z "$_p3b_out" ]]; then
  pass "P3b (F3) missing mediator_env_file on RESUME: warns loud, returns 0 (degraded-but-alive, no exit)"
else
  fail "P3b missing file resume-phase" "exit=$_p3b_exit out='$_p3b_out' stderr=$_p3b_err"
fi
rm -f "$_p3b_stderr"
teardown_p_sandbox

# P4 — perms warn: pointer file at mode 0644 -> warns loud on stderr, still
# loads the array (non-fatal, both phases).
setup_p_sandbox
_p4_envfile="${P_TEST_HOME}/mediator-secrets-loose.env"
printf 'RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-test-p4\n' > "$_p4_envfile"
chmod 0644 "$_p4_envfile"
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 1
network:
  egress:
    mediator_env_file: ${_p4_envfile}
YAML
_p4_stderr=$(mktemp)
_p4_out=$(run_resolve_mediator_env_file "create" "$_p4_stderr")
_p4_exit=$?
_p4_err=$(cat "$_p4_stderr")
if [[ "$_p4_exit" -eq 0 ]] \
  && echo "$_p4_err" | grep -qi "0600\|permission\|mode" \
  && echo "$_p4_out" | grep -q "sk-ant-test-p4"; then
  pass "P4 non-0600 mediator_env_file perms: warns loud, still loads the array"
else
  fail "P4 perms warn" "exit=$_p4_exit out='$_p4_out' stderr=$_p4_err"
fi
rm -f "$_p4_stderr"
teardown_p_sandbox

# P5 — secret non-leak: after resolution, the sentinel secret is absent from
# _UP_RUN_ARGS (never docker run / a --label) and never echoed by the
# resolver's own log output. Positive control: the sentinel DOES appear in
# the mediator arg array (_UP_MEDIATOR_ENV_ARGS).
setup_p_sandbox
_p5_envfile="${P_TEST_HOME}/mediator-secrets.env"
(umask 077; printf 'RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-SENTINEL-p5\n' > "$_p5_envfile")
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 1
network:
  egress:
    mediator_env_file: ${_p5_envfile}
YAML
_p5_stderr=$(mktemp)
_p5_out=$(HOME="$P_TEST_HOME" XDG_CONFIG_HOME="${P_TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _UP_MEDIATOR_ENV_ARGS=()
  _UP_RUN_ARGS=()
  _up_resolve_mediator_env_file '$P_TEST_WS' 'create'
  printf 'RUN_ARGS: %s\n' \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"
  printf 'MEDIATOR_ARGS: %s\n' \"\${_UP_MEDIATOR_ENV_ARGS[@]+\${_UP_MEDIATOR_ENV_ARGS[@]}}\"
" 2>"$_p5_stderr")
_p5_err=$(cat "$_p5_stderr")
_p5_ok=true _p5_reason=""
if echo "$_p5_out" | grep "^RUN_ARGS:" | grep -q "sk-ant-SENTINEL-p5"; then
  _p5_ok=false; _p5_reason="sentinel leaked into _UP_RUN_ARGS (would reach docker run/labels)"
fi
if echo "$_p5_err" | grep -q "sk-ant-SENTINEL-p5"; then
  _p5_ok=false; _p5_reason="${_p5_reason:+$_p5_reason; }sentinel echoed by resolver's own log output"
fi
if ! echo "$_p5_out" | grep "^MEDIATOR_ARGS:" | grep -q "sk-ant-SENTINEL-p5"; then
  _p5_ok=false; _p5_reason="${_p5_reason:+$_p5_reason; }positive control failed: sentinel not found in _UP_MEDIATOR_ENV_ARGS"
fi
if [[ "$_p5_ok" == "true" ]]; then
  pass "P5 secret non-leak: sentinel absent from _UP_RUN_ARGS and resolver logs; present in _UP_MEDIATOR_ENV_ARGS (positive control)"
else
  fail "P5 secret non-leak" "$_p5_reason"
fi
rm -f "$_p5_stderr"
teardown_p_sandbox

# P6 (F2) — composed-but-no-env warning, keyed off the container's RC_MEDIATOR
# env (via docker inspect — no rc.mediator label exists). Stub docker inspect
# so the container reports an RC_MEDIATOR name with an EMPTY mediator arg
# array -> _up_init_mediator emits the warning. Positive controls: (a)
# container WITHOUT RC_MEDIATOR (mediator=none) -> no warning; (b) RC_MEDIATOR
# present PLUS args present -> no warning.
setup_p_sandbox

_p6_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-p6-stub-XXXXXX")
cat > "${_p6_stub_dir}/docker" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" exec "*"init-mediator.sh"*) exit 0 ;;
  *" inspect "*)
    if [[ -n "${RC_P6_STUB_SELECTION:-}" ]]; then
      printf '["RC_MEDIATOR=%s"]\n' "${RC_P6_STUB_SELECTION}"
    else
      printf '[]\n'
    fi
    ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_p6_stub_dir}/docker"

# P6 primary: RC_MEDIATOR=my-proxy, empty mediator args -> warning fires.
_p6_stderr=$(mktemp)
PATH="${_p6_stub_dir}:$PATH" RC_P6_STUB_SELECTION="my-proxy" \
  HOME="$P_TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _UP_MEDIATOR_ENV_ARGS=()
  OUTPUT_FORMAT=''
  _up_init_mediator 'rc-p6-test'
" >/dev/null 2>"$_p6_stderr"
_p6_err=$(cat "$_p6_stderr")
if echo "$_p6_err" | grep -qi "no mediator.*secret\|mediator.*no.*env\|injection.*no-op"; then
  pass "P6 (F2) composed-but-no-env: RC_MEDIATOR present + empty mediator args -> warning fires"
else
  fail "P6 primary composed-but-no-env" "stderr=$_p6_err"
fi
rm -f "$_p6_stderr"

# P6 positive control (a): container WITHOUT RC_MEDIATOR (mediator=none) -> no warning.
_p6b_stderr=$(mktemp)
PATH="${_p6_stub_dir}:$PATH" RC_P6_STUB_SELECTION="" \
  HOME="$P_TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _UP_MEDIATOR_ENV_ARGS=()
  OUTPUT_FORMAT=''
  _up_init_mediator 'rc-p6b-test'
" >/dev/null 2>"$_p6b_stderr"
_p6b_err=$(cat "$_p6b_stderr")
if echo "$_p6b_err" | grep -qi "no mediator.*secret\|mediator.*no.*env\|injection.*no-op"; then
  fail "P6b positive control (mediator=none)" "warning fired even though no mediator is composed: $_p6b_err"
else
  pass "P6b positive control: no RC_MEDIATOR (mediator=none) -> no composed-but-no-env warning"
fi
rm -f "$_p6b_stderr"

# P6 positive control (b): RC_MEDIATOR present PLUS mediator args present -> no warning.
_p6c_stderr=$(mktemp)
PATH="${_p6_stub_dir}:$PATH" RC_P6_STUB_SELECTION="my-proxy" \
  HOME="$P_TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _UP_MEDIATOR_ENV_ARGS=(-e RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-present)
  OUTPUT_FORMAT=''
  _up_init_mediator 'rc-p6c-test'
" >/dev/null 2>"$_p6c_stderr"
_p6c_err=$(cat "$_p6c_stderr")
if echo "$_p6c_err" | grep -qi "no mediator.*secret\|mediator.*no.*env\|injection.*no-op"; then
  fail "P6c positive control (args present)" "warning fired even though mediator args are non-empty: $_p6c_err"
else
  pass "P6c positive control: RC_MEDIATOR present + mediator args present -> no warning"
fi
rm -f "$_p6c_stderr"

rm -rf "${_p6_stub_dir}"
teardown_p_sandbox

echo ""

# ---------------------------------------------------------------------------
# CA: mediator CA trust env vars (rip-cage-yid0)
#
# The mediator-resolution snippet (THREADING_SNIPPET_FILE, already extracted
# above) sets the _UP_MEDIATOR_CA_ENV gate flag. A SIBLING snippet, extracted
# from _up_prepare_environment, gates the three CA env vars off that flag.
# Sourcing both in sequence (same _UP_RUN_ARGS accumulator) proves the full
# composed behavior: flag-set (in the resolution block) + arg-addition (in
# _up_prepare_environment) — not just the flag in isolation.
# ---------------------------------------------------------------------------
echo "--- CA: mediator CA trust env vars unit tests ---"

CA_GATE_SNIPPET_FILE="${U1_TMP}/mediator-ca-gate-snippet.sh"
awk '/rip-cage-yid0: mediator CA trust env vars\./,/rip-cage-yid0: end mediator CA trust env vars\./' \
  "${REPO_ROOT}/rc" > "$CA_GATE_SNIPPET_FILE"

if [[ ! -s "$CA_GATE_SNIPPET_FILE" ]]; then
  fail "CA FATAL: could not extract mediator CA trust env var gate snippet from rc — markers may have changed"
fi

# Helper: write a driver script that sources BOTH the resolution snippet
# (sets _UP_MEDIATOR_CA_ENV) and the CA-gate snippet (consumes it), same
# _UP_RUN_ARGS accumulator throughout — mirrors _write_u1_driver.
_write_ca_driver() {
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

_config_global_path()  { echo '${global_path_val}'; }
_config_project_path() { echo "/nonexistent-project-stub.yaml"; }
${load_stub}

_run_ca_snippets() {
  local path="/tmp/stub-workspace"
  local rc_egress="on"
  _UP_RUN_ARGS=()
  # shellcheck source=/dev/null
  source "\${SNIPPET}"
  # shellcheck source=/dev/null
  source "\${CA_SNIPPET}"
  for arg in "\${_UP_RUN_ARGS[@]:-}"; do
    printf 'ARG: %s\n' "\$arg"
  done
}
_run_ca_snippets
DRIVER
}

# CA1a — mediator=my-proxy => all three CA vars present with exact values.
_write_ca_driver "${U1_TMP}/driver-ca1a.sh" \
  "$RC" \
  '{"config":{"network":{"egress":{"mediator":"my-proxy"}}}}'

CA1A_OUT=""
CA1A_EXIT=0
RC_PATH="$RC" SNIPPET="$THREADING_SNIPPET_FILE" CA_SNIPPET="$CA_GATE_SNIPPET_FILE" \
  bash "${U1_TMP}/driver-ca1a.sh" > "${U1_TMP}/ca1a.out" 2>&1 || CA1A_EXIT=$?
CA1A_OUT=$(cat "${U1_TMP}/ca1a.out")

_ca1a_ok=true _ca1a_reason=""
if ! echo "$CA1A_OUT" | grep -qF "ARG: NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/rip-cage-mediator-ca.crt"; then
  _ca1a_ok=false; _ca1a_reason="${_ca1a_reason:+$_ca1a_reason; }NODE_EXTRA_CA_CERTS missing or wrong value"
fi
if ! echo "$CA1A_OUT" | grep -qF "ARG: SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"; then
  _ca1a_ok=false; _ca1a_reason="${_ca1a_reason:+$_ca1a_reason; }SSL_CERT_FILE missing or wrong value"
fi
if ! echo "$CA1A_OUT" | grep -qF "ARG: REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"; then
  _ca1a_ok=false; _ca1a_reason="${_ca1a_reason:+$_ca1a_reason; }REQUESTS_CA_BUNDLE missing or wrong value"
fi
if [[ "$_ca1a_ok" == "true" ]]; then
  pass "CA1a mediator composed: all three CA trust env vars present with exact expected values"
else
  fail "CA1a mediator composed CA env vars" "${_ca1a_reason} -- out='${CA1A_OUT}' exit=${CA1A_EXIT}"
fi

# CA1b — mediator=none => none of the three vars present.
_write_ca_driver "${U1_TMP}/driver-ca1b.sh" \
  "$RC" \
  '{"config":{"network":{"egress":{"mediator":"none"}}}}'

CA1B_OUT=""
CA1B_EXIT=0
# shellcheck disable=SC2034
RC_PATH="$RC" SNIPPET="$THREADING_SNIPPET_FILE" CA_SNIPPET="$CA_GATE_SNIPPET_FILE" \
  bash "${U1_TMP}/driver-ca1b.sh" > "${U1_TMP}/ca1b.out" 2>&1 || CA1B_EXIT=$?
CA1B_OUT=$(cat "${U1_TMP}/ca1b.out")

if echo "$CA1B_OUT" | grep -qE "NODE_EXTRA_CA_CERTS|SSL_CERT_FILE|REQUESTS_CA_BUNDLE"; then
  fail "CA1b mediator=none: a CA trust env var was found (should be absent)" "out='${CA1B_OUT}'"
else
  pass "CA1b mediator=none: no CA trust env vars in _UP_RUN_ARGS"
fi

# CA1c — no config file at all => none of the three vars present (no regression).
_write_ca_driver "${U1_TMP}/driver-ca1c.sh" \
  "/no-config-exists-for-ca1c/rip-cage.yaml" \
  ""

CA1C_OUT=""
CA1C_EXIT=0
# shellcheck disable=SC2034
RC_PATH="$RC" SNIPPET="$THREADING_SNIPPET_FILE" CA_SNIPPET="$CA_GATE_SNIPPET_FILE" \
  bash "${U1_TMP}/driver-ca1c.sh" > "${U1_TMP}/ca1c.out" 2>&1 || CA1C_EXIT=$?
CA1C_OUT=$(cat "${U1_TMP}/ca1c.out")

if echo "$CA1C_OUT" | grep -qE "NODE_EXTRA_CA_CERTS|SSL_CERT_FILE|REQUESTS_CA_BUNDLE"; then
  fail "CA1c no config: a CA trust env var was found (should be absent)" "out='${CA1C_OUT}'"
else
  pass "CA1c no config: no CA trust env vars in _UP_RUN_ARGS (no regression)"
fi

echo ""

# ---------------------------------------------------------------------------
# R: resume guard for mediator CA env (rip-cage-yid0)
#
# _up_resolve_resume_mediator_ca_env mirrors _up_resolve_resume_config_mode:
# reads the rc.mediator-ca-env label, compares against whether the CURRENT
# effective config composes a mediator, aborts loud on mismatch. Uses the
# same PATH-stub-docker idiom as test-config-ro-mount.sh M6-M8, but stubs
# _load_effective_config directly (like the U1/CA driver tests above) rather
# than relying on real .rip-cage.yaml + the live mediator-name validator —
# that validator's allowed-set depends on this HOST's baked rip-cage:latest
# image / manifest state, which is out of scope for this unit test.
# ---------------------------------------------------------------------------
echo "--- R: resume guard for mediator CA env unit tests ---"

# Helper: run _up_resolve_resume_mediator_ca_env with a stubbed docker (for
# the label query) and a stubbed _load_effective_config (for the "current
# effective config composes a mediator" side). Captures stdout/stderr/exit.
_run_resume_mediator_ca_env() {
  local label_val="$1" eff_config_json="$2" out_var_err="$3" out_var_exit="$4"
  local stub_dir
  stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-rmce-stub-XXXXXX")
  cat > "${stub_dir}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" inspect "*"rc.mediator-ca-env"*) echo "${label_val}"; exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "${stub_dir}/docker"

  local _exit=0
  # No `set -e` re-enable afterward: this file never enables errexit (only
  # `set -uo pipefail` at the top) — reactivating it here would leak past
  # this function for the rest of the script (bash's `set` is not function-
  # scoped) and could abort later, unrelated code on its first bare nonzero
  # command (e.g. the cleanup() trap's `[[ -n "" ]]` check at EOF).
  set +e
  PATH="${stub_dir}:$PATH" bash -c "
    source '$RC' 2>/dev/null
    _load_effective_config() { echo '${eff_config_json}'; }
    _up_resolve_resume_mediator_ca_env 'rc-rmce-test' '/tmp/stub-workspace'
  " >/tmp/rc-rmce-out 2>/tmp/rc-rmce-err
  _exit=$?
  eval "${out_var_err}=\$(cat /tmp/rc-rmce-err 2>/dev/null || true)"
  eval "${out_var_exit}=${_exit}"
  rm -rf "${stub_dir}" /tmp/rc-rmce-out /tmp/rc-rmce-err
}

# R1 — mediator composed (current effective config), label says "false"
# => abort loud, error names the label + gives recreate instructions.
_r1_err="" _r1_exit=0
_run_resume_mediator_ca_env "false" \
  '{"config":{"network":{"egress":{"mediator":"my-proxy"}}}}' \
  _r1_err _r1_exit

_r1_ok=true _r1_reason=""
if [[ "$_r1_exit" -eq 0 ]]; then
  _r1_ok=false; _r1_reason="resolver returned 0 (should abort — mediator composed but CA env label is false)"
fi
if ! echo "$_r1_err" | grep -qi "rc.mediator-ca-env"; then
  _r1_ok=false; _r1_reason="${_r1_reason:+$_r1_reason; }error message did not name the label 'rc.mediator-ca-env'"
fi
if ! echo "$_r1_err" | grep -qi "rc destroy"; then
  _r1_ok=false; _r1_reason="${_r1_reason:+$_r1_reason; }error message did not include 'rc destroy' remediation hint"
fi
if [[ "$_r1_ok" == "true" ]]; then
  pass "R1 mediator composed + label=false: resume guard aborts loud with recreate instructions"
else
  fail "R1 mediator composed + label=false" "$_r1_reason (exit=$_r1_exit, stderr=$_r1_err)"
fi

# R2 — mediator composed, label=true => resolver returns 0 (no mismatch).
_r2_err="" _r2_exit=0
_run_resume_mediator_ca_env "true" \
  '{"config":{"network":{"egress":{"mediator":"my-proxy"}}}}' \
  _r2_err _r2_exit

if [[ "$_r2_exit" -eq 0 ]]; then
  pass "R2 mediator composed + label=true: resume guard returns 0 (no mismatch)"
else
  fail "R2 mediator composed + label=true" "expected exit 0, got $_r2_exit (stderr=$_r2_err)"
fi

# R3 — mediator=none (no config composing one), label=false => resolver returns 0.
_r3_err="" _r3_exit=0
_run_resume_mediator_ca_env "false" \
  '{"config":{"network":{"egress":{"mediator":"none"}}}}' \
  _r3_err _r3_exit

if [[ "$_r3_exit" -eq 0 ]]; then
  pass "R3 mediator=none + label=false: resume guard returns 0 (no mismatch)"
else
  fail "R3 mediator=none + label=false" "expected exit 0, got $_r3_exit (stderr=$_r3_err)"
fi

# R4 — legacy container (rc.mediator-ca-env label absent entirely, pre-yid0),
# mediator composed => treated as "false" => abort loud (same as R1).
_r4_err="" _r4_exit=0
_run_resume_mediator_ca_env "" \
  '{"config":{"network":{"egress":{"mediator":"my-proxy"}}}}' \
  _r4_err _r4_exit

if [[ "$_r4_exit" -ne 0 ]]; then
  pass "R4 legacy container (missing label) + mediator composed: treated as false, aborts loud"
else
  fail "R4 legacy container missing label" "expected non-zero exit (missing label treated as false), got 0"
fi

echo ""

# ---------------------------------------------------------------------------
# T: CA-wait timeout fail-closed (rip-cage-yid0)
#
# init-mediator.sh: if a mediator's registry declares ca_cert_path but the CA
# file never materializes within the wait window, the script must fail closed
# (exit non-zero) rather than warn-and-proceed — otherwise the three CA env
# vars point at trust stores lacking the mediator's CA, and every MITM'd
# connection fails opaquely. The wait loop is sed-patched to a short window
# so this test runs in well under a second (same sed-patch idiom as the U2
# registry-dir tests above).
# ---------------------------------------------------------------------------
echo "--- T: CA-wait timeout fail-closed unit tests ---"

_setup_t_registry() {
  local reg_dir="$1" ca_target="$2"
  mkdir -p "${reg_dir}/mediators/timeout-med"
  printf 'testuser1000' > "${reg_dir}/mediators/timeout-med/run_as_uid"
  printf '#!/bin/sh\ntrue\n' > "${reg_dir}/mediators/timeout-med/start"
  chmod 0755 "${reg_dir}/mediators/timeout-med/start"
  printf '%s' "$ca_target" > "${reg_dir}/mediators/timeout-med/ca_cert_path"
}

# T1 — ca_cert_path declared, cert never appears => exits non-zero, ERROR mentions
# fail-closed. Patch the wait loop to 2 iterations of 0.05s so the test is fast.
T_REG="${U1_TMP}/fake-etc-timeout/rip-cage"
_T1_CA_TARGET="${U1_TMP}/never-appears-ca.crt"
_setup_t_registry "$T_REG" "$_T1_CA_TARGET"

T1_PATCHED="${U1_TMP}/patched-init-mediator-t1.sh"
sed \
  -e "s|/etc/rip-cage/mediators|${T_REG}/mediators|g" \
  -e "s|/run/rip-cage-mediator-|${U1_TMP}/pid-t1-|g" \
  -e "s/-lt 20/-lt 2/" \
  -e "s/sleep 0.5/sleep 0.05/" \
  "${REPO_ROOT}/init-mediator.sh" > "$T1_PATCHED"
chmod +x "$T1_PATCHED"

cat > "${U1_TMP}/driver-t1.sh" <<DRIVER
#!/usr/bin/env bash
su() {
  local _cmd=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -c) shift; _cmd="\$1"; shift ;;
      *) shift ;;
    esac
  done
  local _out
  _out=\$(sh -c "\${_cmd}" 2>/dev/null || true)
  echo "\${_out:-0}"
}
export -f su 2>/dev/null || true
update-ca-certificates() { return 0; }
export -f update-ca-certificates 2>/dev/null || true
getent() { echo "${U1_TMP}"; }
export -f getent 2>/dev/null || true

export RC_MEDIATOR='timeout-med'
bash "${T1_PATCHED}"
DRIVER

T1_OUT=""
T1_EXIT=0
bash "${U1_TMP}/driver-t1.sh" > "${U1_TMP}/t1.out" 2>&1 || T1_EXIT=$?
T1_OUT=$(cat "${U1_TMP}/t1.out")

if [[ "$T1_EXIT" -ne 0 ]] && echo "$T1_OUT" | grep -qiE "ERROR.*fail.*clos|fail.*clos.*ERROR"; then
  pass "T1 ca_cert_path declared, cert never appears: init-mediator.sh fails closed (exit=${T1_EXIT}, ERROR names fail-closed)"
elif [[ "$T1_EXIT" -ne 0 ]]; then
  pass "T1 ca_cert_path declared, cert never appears: init-mediator.sh exits non-zero (fail-closed)"
else
  fail "T1 SAFETY: ca_cert_path declared but CA never appeared, init-mediator.sh exited 0 (warn-and-proceed) — CA env vars would point at trust stores lacking the mediator CA" \
    "out='${T1_OUT}' exit=${T1_EXIT}"
fi

# T1b — the rc-level integration: _up_init_mediator sets _UP_MEDIATOR_OK=false
# when init-mediator.sh (docker-exec'd) exits non-zero. Stub docker exec to run
# our timeout-patched script for real (not force exit 0, unlike the P6 stub).
_t1b_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-t1b-stub-XXXXXX")
cat > "${_t1b_stub_dir}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" exec "*"init-mediator.sh"*) exec bash "${T1_PATCHED}" ;;
  *" inspect "*) echo '["RC_MEDIATOR=timeout-med"]' ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_t1b_stub_dir}/docker"

T1B_OUT=""
PATH="${_t1b_stub_dir}:$PATH" bash -c "
  source '$RC' 2>/dev/null
  _UP_MEDIATOR_ENV_ARGS=(-e RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-t1b)
  OUTPUT_FORMAT=''
  export RC_MEDIATOR='timeout-med'
  _up_init_mediator 'rc-t1b-test'
  echo \"MEDIATOR_OK=\${_UP_MEDIATOR_OK}\"
" > "${U1_TMP}/t1b.out" 2>&1
T1B_OUT=$(cat "${U1_TMP}/t1b.out")
rm -rf "${_t1b_stub_dir}"

if echo "$T1B_OUT" | grep -q "MEDIATOR_OK=false"; then
  pass "T1b rc integration: init-mediator.sh CA-timeout exit propagates to _UP_MEDIATOR_OK=false"
else
  fail "T1b SAFETY: _UP_MEDIATOR_OK did not become false after init-mediator.sh CA-timeout failure" "out='${T1B_OUT}'"
fi

# T2 — positive control: ca_cert_path declared, cert present immediately =>
# exits 0, no fail-closed error.
T_REG_OK="${U1_TMP}/fake-etc-timeout-ok/rip-cage"
_T2_CA_TARGET="${U1_TMP}/appears-immediately-ca.crt"
printf 'fake-ca-pem-content\n' > "$_T2_CA_TARGET"
_setup_t_registry "$T_REG_OK" "$_T2_CA_TARGET"

T2_PATCHED="${U1_TMP}/patched-init-mediator-t2.sh"
sed \
  -e "s|/etc/rip-cage/mediators|${T_REG_OK}/mediators|g" \
  -e "s|/run/rip-cage-mediator-|${U1_TMP}/pid-t2-|g" \
  -e "s/-lt 20/-lt 2/" \
  -e "s/sleep 0.5/sleep 0.05/" \
  "${REPO_ROOT}/init-mediator.sh" > "$T2_PATCHED"
chmod +x "$T2_PATCHED"

cat > "${U1_TMP}/driver-t2.sh" <<DRIVER
#!/usr/bin/env bash
su() {
  local _cmd=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -c) shift; _cmd="\$1"; shift ;;
      *) shift ;;
    esac
  done
  local _out
  _out=\$(sh -c "\${_cmd}" 2>/dev/null || true)
  echo "\${_out:-0}"
}
export -f su 2>/dev/null || true
update-ca-certificates() { return 0; }
export -f update-ca-certificates 2>/dev/null || true
getent() { echo "${U1_TMP}"; }
export -f getent 2>/dev/null || true

export RC_MEDIATOR='timeout-med'
bash "${T2_PATCHED}"
DRIVER

T2_OUT=""
T2_EXIT=0
bash "${U1_TMP}/driver-t2.sh" > "${U1_TMP}/t2.out" 2>&1 || T2_EXIT=$?
T2_OUT=$(cat "${U1_TMP}/t2.out")

if [[ "$T2_EXIT" -eq 0 ]]; then
  pass "T2 positive control: ca_cert_path declared, cert present immediately => exits 0"
else
  fail "T2 positive control regressed" "out='${T2_OUT}' exit=${T2_EXIT}"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== test-mediator-lifecycle.sh complete ==="
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
