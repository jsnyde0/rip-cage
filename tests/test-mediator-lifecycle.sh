#!/usr/bin/env bash
# test-mediator-lifecycle.sh — Host-tier unit tests for the egress-mediator launch
# seam (rip-cage-ta1o.5.7 / ADR-026 D5).
#
# Proves the "third leg" of the composable-mediator seam:
#   A (child .5.1): select a provider via config + bake hooks to registry
#   B (child .5.4): router forwards to mediator's port + uid-exemption
#   C (THIS / .5.7): cage init LAUNCHES the selected mediator
#
# =============================================================================
# Test structure (all host-only; NO docker required for this suite)
# =============================================================================
#
#   G1  — grep-guard (always / host-only):
#     G1a — 'mitmproxy|iron-proxy|clawpatrol' returns ZERO hits in rc + init-rip-cage.sh
#     G1b — 'RC_MEDIATOR' IS present in rc (the threading exists)
#     G1c — 'RC_MEDIATOR' IS present in init-rip-cage.sh (the dispatch exists)
#
#   U1  — cmd_up RC_MEDIATOR threading (source-level unit test, no docker):
#     U1a — config with network.egress.mediator: my-proxy => RC_MEDIATOR=my-proxy in _UP_RUN_ARGS
#     U1b — config with network.egress.mediator: none (default) => RC_MEDIATOR NOT in _UP_RUN_ARGS
#     U1c — no config file at all => RC_MEDIATOR NOT in _UP_RUN_ARGS (byte-identical to today)
#
#   U2  — init-rip-cage.sh dispatch logic (sourced-function unit test, no docker):
#     U2a    — RC_MEDIATOR set => dispatch block fires; prints "starting mediator" message
#     U2a-uid— su is called with configured non-root uid (loop-prevention assertion; Finding 5)
#     U2b    — RC_MEDIATOR unset => dispatch block skips; prints "none" message
#     U2c    — RC_MEDIATOR set but registry dir absent => exits non-zero with error
#     U2d    — run_as_uid file contains empty string => fail-closed (Finding 2)
#     U2e    — run_as_uid="0" => fail-closed / refuse to su as root (Finding 2)
#     U2f    — run_as_uid="root" => fail-closed / refuse to su as root (Finding 2)
#
#   U3  — teardown trap baking (Finding 1):
#     U3  — teardown hook is invoked on EXIT (trap values baked at registration, not single-quoted)
#
#   U4  — egress=off + mediator != none => reject loud (Finding 3):
#     U4a — validation guard for egress=off+mediator present in rc source
#     U4b — with egress=off, mediator=my-proxy is NOT threaded (or explicitly rejected)
#
#   O1  — ordering assertion (source-level):
#     O1a         — mediator dispatch AFTER mux section (real firewall anchor), BEFORE daemon
#     O1a-integrity — CA-vars firewall-env source is above mux section (confirms old grep was vacuous)
#     O1b — RC_MEDIATOR threading in rc appears AFTER RC_MULTIPLEXER threading (parallel placement)
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

echo "=== test-mediator-lifecycle.sh — egress-mediator launch seam (rip-cage-ta1o.5.7) ==="
echo ""

# ---------------------------------------------------------------------------
# G1: Grep-guard (always / host-only)
# ---------------------------------------------------------------------------
echo "--- G1: grep-guards ---"

# G1a — zero hardcoded mediator names (ADR-005 D12 FIRM)
G1A_HITS=$(grep -nE 'mitmproxy|iron-proxy|clawpatrol' "${REPO_ROOT}/rc" "${REPO_ROOT}/init-rip-cage.sh" 2>/dev/null || true)
if [[ -z "$G1A_HITS" ]]; then
  pass "G1a zero hardcoded mediator names in rc + init-rip-cage.sh (ADR-005 D12)"
else
  fail "G1a hardcoded mediator names found in rc or init-rip-cage.sh" "${G1A_HITS}"
fi

# G1b — RC_MEDIATOR IS present in rc (the threading exists)
G1B_HITS=$(grep -c 'RC_MEDIATOR' "${REPO_ROOT}/rc" 2>/dev/null || echo "0")
if [[ "${G1B_HITS:-0}" -gt 0 ]]; then
  pass "G1b RC_MEDIATOR threading present in rc (${G1B_HITS} occurrences)"
else
  fail "G1b RC_MEDIATOR threading NOT found in rc — cmd_up wiring missing"
fi

# G1c — RC_MEDIATOR IS present in init-rip-cage.sh (the dispatch exists)
G1C_HITS=$(grep -c 'RC_MEDIATOR' "${REPO_ROOT}/init-rip-cage.sh" 2>/dev/null || echo "0")
if [[ "${G1C_HITS:-0}" -gt 0 ]]; then
  pass "G1c RC_MEDIATOR dispatch present in init-rip-cage.sh (${G1C_HITS} occurrences)"
else
  fail "G1c RC_MEDIATOR dispatch NOT found in init-rip-cage.sh — init dispatch missing"
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
# U2: init-rip-cage.sh dispatch logic (unit test, no docker)
#
# Extract the mediator dispatch block (section 11b) from init-rip-cage.sh and
# run it in a controlled subshell with a fake /etc/rip-cage/mediators/ registry.
# We stub 'su' to bypass privilege dropping (tests run as unprivileged user).
# ---------------------------------------------------------------------------
echo "--- U2: init-rip-cage.sh dispatch logic unit tests ---"

# Extract the mediator dispatch block.
# Markers: "# 11b." to "# 12." — drop the last line (the "# 12." marker itself).
DISPATCH_FILE="${U1_TMP}/mediator-dispatch-block.sh"
# Extract from the "if [ -n" guard to just before "# 12." — portable on BSD + GNU
awk '/^# 11b\. Egress-mediator lifecycle/,/^# 12\./' \
  "${REPO_ROOT}/init-rip-cage.sh" \
  | grep -v '^# 12\.' \
  > "$DISPATCH_FILE"

if [[ ! -s "$DISPATCH_FILE" ]]; then
  fail "U2 FATAL: could not extract mediator dispatch block from init-rip-cage.sh"
  echo "Results: FAILURES=${FAILURES}"
  [[ $FAILURES -eq 0 ]] || exit 1
fi

# Build a fake registry dir for testing — use a NON-ROOT uid ("testuser1000").
FAKE_REG="${U1_TMP}/fake-etc/rip-cage"
mkdir -p "${FAKE_REG}/mediators/test-mediator"
printf 'testuser1000' > "${FAKE_REG}/mediators/test-mediator/run_as_uid"
printf '#!/bin/sh\necho "[fake-start] started" >> %s/start.log\n' "${U1_TMP}" \
  > "${FAKE_REG}/mediators/test-mediator/start"
chmod 0755 "${FAKE_REG}/mediators/test-mediator/start"

# Patch the dispatch block to use our fake registry path.
PATCHED_DISPATCH="${U1_TMP}/patched-dispatch.sh"
sed "s|/etc/rip-cage/mediators|${FAKE_REG}/mediators|g" "$DISPATCH_FILE" > "$PATCHED_DISPATCH"

# U2a — RC_MEDIATOR set => dispatch fires AND su is called with the configured
# non-root uid (not root, not empty) — Finding 5 strengthened assertion.
# The su stub records the uid argument it receives so we can assert it.
cat > "${U1_TMP}/driver-u2a.sh" <<DRIVER
#!/usr/bin/env bash
# Stub 'su' to run as current user (no root needed in tests) AND record uid arg.
SU_CALLED_UID_FILE="${U1_TMP}/su-called-uid.txt"
su() {
  local _shell="" _uid="" _cmd=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -s) shift; _shell="\$1"; shift ;;
      -c) shift; _cmd="\$1"; shift ;;
      *)  _uid="\$1"; shift ;;
    esac
  done
  # Record the uid argument for the assertion (append, since start + health may call su).
  printf '%s\n' "\${_uid}" >> "\${SU_CALLED_UID_FILE}"
  sh -c "\${_cmd}"
}
export -f su 2>/dev/null || true

RC_MEDIATOR='test-mediator'
# shellcheck source=/dev/null
source "${PATCHED_DISPATCH}"
DRIVER

U2A_OUT=""
U2A_EXIT=0
bash "${U1_TMP}/driver-u2a.sh" > "${U1_TMP}/u2a.out" 2>&1 || U2A_EXIT=$?
U2A_OUT=$(cat "${U1_TMP}/u2a.out")

if echo "$U2A_OUT" | grep -qE "starting mediator|start hook launched"; then
  pass "U2a RC_MEDIATOR set: dispatch fires (start hook launched message present)"
else
  fail "U2a RC_MEDIATOR set: dispatch did not fire as expected" "out='${U2A_OUT}' exit=${U2A_EXIT}"
fi

# U2a-uid — su must have been called with the configured uid (not root, not empty).
# This is the loop-prevention-load-bearing assertion (ADR-026 D5 / Finding 5).
if [[ -f "${U1_TMP}/su-called-uid.txt" ]]; then
  U2A_UID_CALLED=$(head -1 "${U1_TMP}/su-called-uid.txt")
  if [[ -z "$U2A_UID_CALLED" ]]; then
    fail "U2a-uid SAFETY: su was called with an EMPTY uid — mediator would run as root or fail" \
      "su-uid-file was empty"
  elif [[ "$U2A_UID_CALLED" == "0" || "$U2A_UID_CALLED" == "root" ]]; then
    fail "U2a-uid SAFETY: su was called with root uid ('${U2A_UID_CALLED}') — loop-prevention void (ADR-026 D5)" \
      "expected configured non-root uid 'testuser1000', got '${U2A_UID_CALLED}'"
  elif [[ "$U2A_UID_CALLED" == "testuser1000" ]]; then
    pass "U2a-uid su called with configured non-root uid '${U2A_UID_CALLED}' — loop-prevention intact (ADR-026 D5)"
  else
    fail "U2a-uid su called with unexpected uid '${U2A_UID_CALLED}'" \
      "expected 'testuser1000'"
  fi
else
  fail "U2a-uid SAFETY: su-called-uid.txt not created — su stub was not called (mediator may not have started)" \
    "out='${U2A_OUT}' exit=${U2A_EXIT}"
fi

# U2b — RC_MEDIATOR unset => dispatch skips
cat > "${U1_TMP}/driver-u2b.sh" <<DRIVER
#!/usr/bin/env bash
unset RC_MEDIATOR
# shellcheck source=/dev/null
source "${PATCHED_DISPATCH}"
DRIVER

U2B_OUT=""
U2B_EXIT=0
bash "${U1_TMP}/driver-u2b.sh" > "${U1_TMP}/u2b.out" 2>&1 || U2B_EXIT=$?
U2B_OUT=$(cat "${U1_TMP}/u2b.out")

if echo "$U2B_OUT" | grep -qE "starting mediator|start hook launched"; then
  fail "U2b RC_MEDIATOR unset: dispatch fired unexpectedly" "out='${U2B_OUT}'"
else
  pass "U2b RC_MEDIATOR unset: dispatch skips (no start hook launched)"
fi

# U2c — RC_MEDIATOR set but registry dir absent => exits non-zero with error
NONEXISTENT_DISPATCH="${U1_TMP}/nonexistent-dispatch.sh"
sed "s|/etc/rip-cage/mediators|/nonexistent-reg-u2c/mediators|g" "$DISPATCH_FILE" > "$NONEXISTENT_DISPATCH"

cat > "${U1_TMP}/driver-u2c.sh" <<DRIVER
#!/usr/bin/env bash
RC_MEDIATOR='nonexistent-mediator'
# shellcheck source=/dev/null
source "${NONEXISTENT_DISPATCH}"
DRIVER

U2C_OUT=""
U2C_EXIT=0
bash "${U1_TMP}/driver-u2c.sh" > "${U1_TMP}/u2c.out" 2>&1 || U2C_EXIT=$?
U2C_OUT=$(cat "${U1_TMP}/u2c.out")

if [[ "$U2C_EXIT" -ne 0 ]] && echo "$U2C_OUT" | grep -qiE "ERROR.*mediator|registry dir"; then
  pass "U2c registry absent: exits non-zero with error about missing registry"
elif [[ "$U2C_EXIT" -ne 0 ]]; then
  pass "U2c registry absent: exits non-zero (error surfaced)"
else
  fail "U2c registry absent: should exit non-zero but exited 0" "out='${U2C_OUT}'"
fi

# ---------------------------------------------------------------------------
# U2d-U2g: fail-closed run_as_uid validation (Finding 2 / ADR-001)
#
# If the run_as_uid file contains empty, "0", "root", or does not exist after the
# registry check, the mediator MUST NOT start — fail closed with a loud error.
# This prevents the mediator from running as root, which would void the
# uid-exemption loop-prevention (ADR-026 D5).
# ---------------------------------------------------------------------------

# Helper: build a registry with a specific uid value and run dispatch.
# Argument: uid_val — what to write in run_as_uid (or "EMPTY" for zero-byte file,
#           "MISSING" to not create the run_as_uid file).
# Outputs exit code to variable U2X_EXIT; message to U2X_OUT.
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

  local patched="${U1_TMP}/uid-patched-${uid_val}.sh"
  sed "s|/etc/rip-cage/mediators|${test_reg}/mediators|g" "$DISPATCH_FILE" > "$patched"

  local driver="${U1_TMP}/uid-driver-${uid_val}.sh"
  cat > "$driver" <<UDRIVER
#!/usr/bin/env bash
su() {
  local _shell="" _uid="" _cmd=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -s) shift; _shell="\$1"; shift ;;
      -c) shift; _cmd="\$1"; shift ;;
      *)  _uid="\$1"; shift ;;
    esac
  done
  sh -c "\${_cmd}"
}
export -f su 2>/dev/null || true
RC_MEDIATOR='baduid-med'
# shellcheck source=/dev/null
source "${patched}"
UDRIVER

  bash "$driver" > "${U1_TMP}/uid-out-${uid_val}.txt" 2>&1
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
# U3: Teardown trap actually runs with baked values (Finding 1)
#
# The EXIT trap must invoke the teardown hook. The bug is that the trap is
# single-quoted, so the path variables are NOT expanded at registration time;
# then they are unset before EXIT fires, causing teardown to silently not run.
# The fix is to bake the values into the trap string at registration time
# (double-quoted expansion or equivalent).
# ---------------------------------------------------------------------------
echo "--- U3: Teardown trap baking (Finding 1) ---"

# Add a teardown hook to the existing test-mediator fixture.
TEARDOWN_LOG="${U1_TMP}/teardown-ran.log"
printf '#!/bin/sh\necho "[teardown] ran" >> %s\n' "${TEARDOWN_LOG}" \
  > "${FAKE_REG}/mediators/test-mediator/teardown"
chmod 0755 "${FAKE_REG}/mediators/test-mediator/teardown"

# Re-patch dispatch with teardown hook present.
PATCHED_DISPATCH_TD="${U1_TMP}/patched-dispatch-teardown.sh"
sed "s|/etc/rip-cage/mediators|${FAKE_REG}/mediators|g" "$DISPATCH_FILE" > "$PATCHED_DISPATCH_TD"

cat > "${U1_TMP}/driver-u3.sh" <<DRIVER
#!/usr/bin/env bash
SU_CALLED_UID_FILE="${U1_TMP}/u3-su-uid.txt"
su() {
  local _shell="" _uid="" _cmd=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -s) shift; _shell="\$1"; shift ;;
      -c) shift; _cmd="\$1"; shift ;;
      *)  _uid="\$1"; shift ;;
    esac
  done
  printf '%s\n' "\${_uid}" >> "\${SU_CALLED_UID_FILE}"
  sh -c "\${_cmd}"
}
export -f su 2>/dev/null || true

RC_MEDIATOR='test-mediator'
# shellcheck source=/dev/null
source "${PATCHED_DISPATCH_TD}"
# Trigger EXIT trap explicitly by exiting normally.
DRIVER

rm -f "${TEARDOWN_LOG}"
U3_EXIT=0
bash "${U1_TMP}/driver-u3.sh" > "${U1_TMP}/u3.out" 2>&1 || U3_EXIT=$?

if [[ -f "${TEARDOWN_LOG}" ]] && grep -q "teardown" "${TEARDOWN_LOG}"; then
  pass "U3 teardown trap: hook invoked on EXIT (trap values were baked at registration)"
else
  fail "U3 teardown trap: FUNCTIONAL BUG — teardown hook NOT invoked on EXIT" \
    "trap may use single-quoted vars that were unset before EXIT; teardown.log='$(cat "${TEARDOWN_LOG}" 2>/dev/null || echo MISSING)' exit=${U3_EXIT}"
fi

# ---------------------------------------------------------------------------
# U4: egress=off + mediator != none => cmd_up fails loud (Finding 3)
#
# When egress=off, the iptables uid-exemption is never installed and there is no
# egress router to forward to the mediator. Threading RC_MEDIATOR in this case
# produces an incoherent, non-functional config. cmd_up must fail CLOSED with a
# loud error at preflight (ADR-001 fail-closed) rather than silently starting an
# incoherent cage.
# ---------------------------------------------------------------------------
echo "--- U4: egress=off + mediator reject (Finding 3) ---"

# We test by extracting the snippet from rc that validates mediator+egress
# compatibility and running it directly. The snippet must exit non-zero and
# print a loud error when rc_egress=off and _rc_mediator != "none".
#
# We look for a validation guard that rejects egress=off + mediator != none.
# The check must exist in the threading snippet or in cmd_up preflight.
U4_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rc-med-u4-XXXXXX")

# Extract both the threading snippet AND any preflight mediator-egress-off guard.
# We source rc and call a minimal function that simulates the create path with
# rc_egress=off and a non-none mediator to see if it rejects the combo.
cat > "${U4_TMP}/driver-u4a.sh" <<'UDRIVER'
#!/usr/bin/env bash
# Minimal driver: verify egress=off + mediator=my-proxy is rejected loud.
# We simulate the rc validation by checking for the guard in the source.

REPO_ROOT_U4="$1"
RC_PATH="$2"

# Source rc to get helper functions (suppress output; we only need the guards).
# shellcheck source=/dev/null
source "${RC_PATH}" 2>/dev/null

# Stub the helpers so we do not need real config files.
_config_global_path()  { echo "/no-global-config-u4.yaml"; }
_config_project_path() { echo "/no-project-config-u4.yaml"; }

# Simulate the cmd_up create path with egress=off and mediator=my-proxy.
# If the validation guard is present, it should exit non-zero before we get to
# the docker run step.
local_cmd_up_preflight() {
  local rc_egress="off"
  local _rc_mediator="my-proxy"

  # The guard we require: if egress is off and mediator is non-none, fail closed.
  if [[ "$_rc_mediator" != "none" && "$rc_egress" == "off" ]]; then
    echo "ERROR: network.egress.mediator='${_rc_mediator}' requires egress to be on — with egress=off, no iptables uid-exemption is installed and there is no egress router to forward to the mediator (ADR-001 fail-closed; ADR-026 D5). Set network.egress.mediator: none or remove --no-egress." >&2
    exit 1
  fi
  echo "PASS: no rejection (should not reach here)"
}
local_cmd_up_preflight
UDRIVER

# First check: does rc contain the validation guard at all?
# We grep for the pattern that should exist in the threading/preflight section.
# Use grep -E without -c to get actual match lines, then count them with wc -l.
U4_GUARD_HITS=$(grep -E "egress.*off.*mediator|mediator.*egress.*off|_rc_mediator.*rc_egress.*off|rc_egress.*off.*_rc_mediator" "${REPO_ROOT}/rc" 2>/dev/null | wc -l | tr -d ' ')

if [[ "${U4_GUARD_HITS:-0}" -gt 0 ]]; then
  pass "U4a egress=off+mediator guard: validation present in rc (${U4_GUARD_HITS} occurrence(s))"
else
  fail "U4a SAFETY: egress=off+mediator guard NOT found in rc — with egress=off+mediator configured, cage starts in incoherent state (no router, no uid-exemption, but RC_MEDIATOR threaded)"
fi

# Second check: the threading snippet must NOT thread RC_MEDIATOR when rc_egress=off.
# We write a driver that sets rc_egress=off in the context of the threading snippet.
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

# The snippet must either:
# (a) exit non-zero with a loud error when egress=off+mediator!=none, OR
# (b) not thread RC_MEDIATOR into _UP_RUN_ARGS when egress=off
# Either behaviour is acceptable; both are correct from a safety perspective.
# The critical thing is it must NOT silently thread RC_MEDIATOR with egress=off.
if [[ "$U4B_EXIT" -ne 0 ]]; then
  # Loud rejection is the preferred path.
  if echo "$U4B_OUT" | grep -qiE "ERROR|REFUSE|egress.*off|mediator.*egress|requires egress"; then
    pass "U4b threading: egress=off+mediator=my-proxy rejected with loud error (ADR-001 fail-closed)"
  else
    pass "U4b threading: egress=off+mediator=my-proxy exits non-zero (fail-closed)"
  fi
elif echo "$U4B_OUT" | grep -q "RC_MEDIATOR=my-proxy"; then
  fail "U4b SAFETY: egress=off+mediator=my-proxy silently threaded RC_MEDIATOR — cage starts incoherent (no router, no uid-exemption)" \
    "out='${U4B_OUT}' exit=${U4B_EXIT}"
else
  # Snippet exited 0 but did not thread RC_MEDIATOR — also acceptable if a loud error was printed.
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
# O1: Ordering assertion (source-level)
#
# The mediator dispatch block MUST appear AFTER firewall references and BEFORE
# the daemon section in init-rip-cage.sh.
#
# Architectural guarantee: in cmd_up, _up_init_firewall runs (docker exec as
# root) BEFORE _up_init_container (which calls init-rip-cage.sh). So when the
# init script runs, init-firewall.sh has already installed the uid-exemption.
# Within init-rip-cage.sh, section 11b is between section 11 (mux) and 12
# (daemons), which makes the ordering correct by construction.
# ---------------------------------------------------------------------------
echo "--- O1: Ordering assertions ---"

# O1a — mediator dispatch AFTER the uid-exemption install section in init-rip-cage.sh,
# BEFORE daemon section (Finding 4 fix: do NOT use the CA-vars firewall-env source
# at line 7 as the firewall marker — that is just the cert-trust source, not the
# uid-exemption install. Use the section 11 multiplexer dispatch as the ordering
# anchor: the mediator section 11b MUST appear AFTER section 11 (mux) which is
# itself AFTER the firewall phase. Additionally, verify it is NOT before the mux
# section — if someone moves the mediator block before the mux/firewall sections,
# the uid-exemption would not yet be in place.)
#
# Robust ordering: look for the section 11 marker (mux dispatch) and section 12
# (daemon) as the structural anchors, NOT the CA-vars source line which can appear
# at the very top of the file and would trivially satisfy any line-number comparison.
MUX_DISPATCH_LINE=$(grep -n "^# 11\. " "${REPO_ROOT}/init-rip-cage.sh" | head -1 | cut -d: -f1)
MEDIATOR_DISPATCH_LINE=$(grep -n "^# 11b\. Egress-mediator lifecycle" "${REPO_ROOT}/init-rip-cage.sh" | head -1 | cut -d: -f1)
DAEMON_SECTION_LINE=$(grep -n "^# 12\. IN-CAGE DAEMON" "${REPO_ROOT}/init-rip-cage.sh" | head -1 | cut -d: -f1)

if [[ -z "$MUX_DISPATCH_LINE" || -z "$MEDIATOR_DISPATCH_LINE" || -z "$DAEMON_SECTION_LINE" ]]; then
  fail "O1a ordering: could not find all section markers in init-rip-cage.sh" \
    "mux_section=${MUX_DISPATCH_LINE:-<missing>} mediator=${MEDIATOR_DISPATCH_LINE:-<missing>} daemon=${DAEMON_SECTION_LINE:-<missing>}"
elif [[ "$MEDIATOR_DISPATCH_LINE" -gt "$MUX_DISPATCH_LINE" && "$MEDIATOR_DISPATCH_LINE" -lt "$DAEMON_SECTION_LINE" ]]; then
  pass "O1a mediator dispatch ordered correctly: mux section (L${MUX_DISPATCH_LINE}) < mediator (L${MEDIATOR_DISPATCH_LINE}) < daemon (L${DAEMON_SECTION_LINE}) — uid-exemption is installed before mediator starts"
else
  fail "O1a mediator dispatch ordering wrong" \
    "mux_section=L${MUX_DISPATCH_LINE} mediator=L${MEDIATOR_DISPATCH_LINE} daemon=L${DAEMON_SECTION_LINE} — mediator must be AFTER mux/firewall sections and BEFORE daemon section"
fi

# O1a-integrity — sanity check: the CA-vars firewall-env source at line 7 MUST be
# far above the mediator section (proving the old grep would have been vacuous).
CAENV_LINE=$(grep -n "source /etc/rip-cage/firewall-env" "${REPO_ROOT}/init-rip-cage.sh" | head -1 | cut -d: -f1)
if [[ -n "$CAENV_LINE" && -n "$MEDIATOR_DISPATCH_LINE" && "$CAENV_LINE" -lt "$MUX_DISPATCH_LINE" ]]; then
  pass "O1a-integrity CA-vars source at L${CAENV_LINE} is above mux dispatch L${MUX_DISPATCH_LINE} — confirms the CA-vars line is NOT a valid firewall-install ordering anchor"
else
  fail "O1a-integrity could not verify CA-vars line position" \
    "caenv=${CAENV_LINE:-<missing>} mux_section=${MUX_DISPATCH_LINE:-<missing>}"
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
FIREWALL_CALL_LINE=$(grep -n "_up_init_firewall" "${REPO_ROOT}/rc" | grep -v "^[0-9]*:#\|^[0-9]*:  #\|^[0-9]*:    #\|^[0-9]*:# " | grep -v "^[0-9]*:_up_init_firewall()" | tail -1 | cut -d: -f1)
CONTAINER_CALL_LINE=$(grep -n "_up_init_container" "${REPO_ROOT}/rc" | grep -v "^[0-9]*:#\|^[0-9]*:  #\|^[0-9]*:    #\|^[0-9]*:# " | grep -v "^[0-9]*:_up_init_container()" | tail -1 | cut -d: -f1)

if [[ -z "$FIREWALL_CALL_LINE" || -z "$CONTAINER_CALL_LINE" ]]; then
  fail "O1c ordering: could not find _up_init_firewall or _up_init_container call in rc" \
    "firewall_call=${FIREWALL_CALL_LINE:-<missing>} container_call=${CONTAINER_CALL_LINE:-<missing>}"
elif [[ "$FIREWALL_CALL_LINE" -lt "$CONTAINER_CALL_LINE" ]]; then
  pass "O1c rc cmd_up: _up_init_firewall (L${FIREWALL_CALL_LINE}) called BEFORE _up_init_container (L${CONTAINER_CALL_LINE}) — ordering guarantee holds"
else
  fail "O1c rc cmd_up: _up_init_firewall called AFTER _up_init_container — ordering bug" \
    "firewall_call=L${FIREWALL_CALL_LINE} container_call=L${CONTAINER_CALL_LINE}"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== test-mediator-lifecycle.sh complete ==="
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
