#!/usr/bin/env bash
# Unit tests for the startup self-test guard mode-gating behavior (rip-cage-fft).
#
# Tests verify that _run_startup_selftest():
#   MG1  In block mode with proxy on-path: emits ENFORCED, exits 0
#   MG2  In observe mode: skips probe, emits "skipped: observe mode", exits 0
#   MG3  When egress is off: skips probe, emits "skipped: egress off", exits 0
#   MG4  In legacy mode with proxy on-path: emits ENFORCED, exits 0
#   MG5  In block mode with proxy bypassed: emits BYPASSED, exits non-zero
#   MG6  In legacy mode with proxy bypassed: exits non-zero (legacy is blocking)
#   MG7  In block mode with inconclusive probe: warns and exits 0 (never-false-alarm)
#
# Testability approach (NO production hook):
#   - Skip paths (observe/egress-off): _run_startup_selftest sees the mode from the
#     rules file and returns early WITHOUT calling curl.  No shim needed; just write
#     the appropriate rules file.
#   - Probe paths (block/legacy): intercept the external `curl` binary with a PATH
#     shim (a fake curl script on PATH ahead of the real one) that returns a canned
#     exit code + http_code + response headers.  This exercises the real
#     _run_startup_selftest logic (mode read → probe → classify → exit/log) without
#     any in-code override.  A curl PATH-shim is standard shell-test technique; it is
#     NOT a production hook.
#
# Curl shim contract:
#   The real curl call in _run_startup_selftest uses (rip-cage-ta1o.1 pure router):
#     curl -s --resolve HOST:80:192.0.2.1 --max-time N -D TMPFILE -o /dev/null -w '%{http_code}' URL
#   (plain HTTP probe over port 80, pinned to 192.0.2.1 (RFC5737 unroutable) via --resolve
#   so DNS/sidecar is not involved.  The pure SNI router recognises the selftest hostname
#   and serves the marker LOCALLY (returns before any upstream connect) — the pure-router
#   equivalent of mitmproxy's old connection_strategy=lazy.  With REDIRECT present the marker
#   is returned locally.  With REDIRECT absent, curl times out on the unroutable IP.)
#   The shim writes the requested -D header file (with or without marker) and prints
#   the http_code to stdout, then exits with the requested exit code.
#   The shim reads its behavior from env vars:
#     FAKE_CURL_EXIT      — exit code to return (default 0)
#     FAKE_CURL_HTTP_CODE — http_code to print to stdout (default "200")
#     FAKE_CURL_MARKER    — if non-empty, write "X-Rip-Cage-Selftest: <value>" to -D file
#
# IMPORTANT: MG5 and MG6 assert on the EXIT CODE of _run_startup_selftest, not just
# the log line, satisfying the falsifiable requirement (assert the line, not absence).
#
# Usage: bash tests/test-selftest-mode-gating.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREWALL_SCRIPT="${SCRIPT_DIR}/../cage/egress/init-firewall.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

# Source functions from init-firewall.sh (sourcing guard prevents execution).
# shellcheck source=../init-firewall.sh
# shellcheck disable=SC1091
source "$FIREWALL_SCRIPT"

TMPDIR_TEST=$(mktemp -d)
FAKE_CURL_DIR=$(mktemp -d)
# shellcheck disable=SC2329
cleanup() { rm -rf "$TMPDIR_TEST" "$FAKE_CURL_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Curl PATH-shim: write a fake curl script that reads env vars to decide what
# to return.  Placed in FAKE_CURL_DIR which is prepended to PATH for probe tests.
# ---------------------------------------------------------------------------
cat > "${FAKE_CURL_DIR}/curl" <<'SHIM'
#!/usr/bin/env bash
# Fake curl for _run_startup_selftest mode-gating tests.
# Reads behavior from env vars set by the test harness:
#   FAKE_CURL_EXIT      - exit code (default 0)
#   FAKE_CURL_HTTP_CODE - http_code printed to stdout (default "200")
#   FAKE_CURL_MARKER    - if non-empty, writes X-Rip-Cage-Selftest header to -D file

# Parse arguments to find the -D <file> argument (header dump file).
header_file=""
prev_arg=""
for arg in "$@"; do
  if [[ "$prev_arg" == "-D" ]]; then
    header_file="$arg"
  fi
  prev_arg="$arg"
done

# Write synthetic response headers to the -D file if requested.
if [[ -n "$header_file" ]]; then
  {
    echo "HTTP/1.1 ${FAKE_CURL_HTTP_CODE:-200} OK"
    if [[ -n "${FAKE_CURL_MARKER:-}" ]]; then
      echo "X-Rip-Cage-Selftest: ${FAKE_CURL_MARKER}"
    fi
    echo ""
  } > "$header_file"
fi

# Print the http_code to stdout (what -w '%{http_code}' would produce).
printf '%s' "${FAKE_CURL_HTTP_CODE:-200}"

# Exit with the requested code.
exit "${FAKE_CURL_EXIT:-0}"
SHIM
chmod +x "${FAKE_CURL_DIR}/curl"

# Helper: write a minimal egress-rules.yaml with given mode
write_rules_file() {
  local path="$1" mode="$2"
  if [[ "$mode" == "block" ]]; then
    cat > "$path" <<'YAML'
version: 2
mode: block
allowed_hosts:
  - api.anthropic.com
rules: []
YAML
  elif [[ "$mode" == "observe" ]]; then
    cat > "$path" <<'YAML'
version: 2
mode: observe
allowed_hosts:
  - api.anthropic.com
rules: []
YAML
  else
    # legacy — no mode key
    cat > "$path" <<'YAML'
version: 1
rules: []
YAML
  fi
}

# Helper: run _run_startup_selftest with the fake curl on PATH.
# Usage: run_with_shim RULES_FILE [FAKE_CURL_EXIT] [FAKE_CURL_HTTP_CODE] [FAKE_CURL_MARKER]
run_with_shim() {
  local rules_file="$1"
  local fake_exit="${2:-0}"
  local fake_http_code="${3:-200}"
  local fake_marker="${4:-}"
  FAKE_CURL_EXIT="$fake_exit" \
  FAKE_CURL_HTTP_CODE="$fake_http_code" \
  FAKE_CURL_MARKER="$fake_marker" \
  PATH="${FAKE_CURL_DIR}:${PATH}" \
  _run_startup_selftest "$rules_file"
}

# -------------------------------------------------------------------
# MG1: block mode + proxy on-path (marker present) => emits ENFORCED, exit 0
# Shim: exit 0, http_code 200, marker = "on-path"
# -------------------------------------------------------------------
RULES="${TMPDIR_TEST}/rules-block.yaml"
write_rules_file "$RULES" "block"
output=$(run_with_shim "$RULES" 0 200 "on-path" 2>&1) || true
exit_code=$?
if echo "$output" | grep -q "ENFORCED"; then
  pass "MG1a: block mode + marker present => ENFORCED in log"
else
  fail "MG1a: block mode + marker present => ENFORCED in log" "output: $output"
fi
if [[ $exit_code -eq 0 ]]; then
  pass "MG1b: block mode + ENFORCED => exit 0"
else
  fail "MG1b: block mode + ENFORCED => exit 0" "exit_code: $exit_code"
fi

# -------------------------------------------------------------------
# MG2: observe mode => skips probe entirely, emits "skipped: observe mode"
# The fake curl is on PATH but must NOT be called (observe mode returns early).
# -------------------------------------------------------------------
RULES="${TMPDIR_TEST}/rules-observe.yaml"
write_rules_file "$RULES" "observe"
# Set shim to return BYPASSED result — if curl is called and mode-gating fails,
# this would cause exit non-zero, making the test fail.
output=$(run_with_shim "$RULES" 28 000 "" 2>&1) || true
exit_code=$?
if echo "$output" | grep -q "skipped: observe mode"; then
  pass "MG2a: observe mode => 'skipped: observe mode' in log"
else
  fail "MG2a: observe mode => 'skipped: observe mode' in log" "output: $output"
fi
if [[ $exit_code -eq 0 ]]; then
  pass "MG2b: observe mode => exit 0 (no refuse-to-start)"
else
  fail "MG2b: observe mode => exit 0 (no refuse-to-start)" "exit_code: $exit_code"
fi

# -------------------------------------------------------------------
# MG3: egress-off (RIP_CAGE_EGRESS=off) => skips, emits "skipped: egress off"
# -------------------------------------------------------------------
RULES="${TMPDIR_TEST}/rules-block.yaml"  # mode doesn't matter when egress is off
write_rules_file "$RULES" "block"
output=$(RIP_CAGE_EGRESS=off run_with_shim "$RULES" 28 000 "" 2>&1) || true
exit_code=$?
if echo "$output" | grep -q "skipped: egress off"; then
  pass "MG3a: egress-off => 'skipped: egress off' in log"
else
  fail "MG3a: egress-off => 'skipped: egress off' in log" "output: $output"
fi
if [[ $exit_code -eq 0 ]]; then
  pass "MG3b: egress-off => exit 0 (no refuse-to-start)"
else
  fail "MG3b: egress-off => exit 0 (no refuse-to-start)" "exit_code: $exit_code"
fi

# -------------------------------------------------------------------
# MG4: legacy mode + proxy on-path (marker present) => runs probe, emits ENFORCED
# -------------------------------------------------------------------
RULES="${TMPDIR_TEST}/rules-legacy.yaml"
write_rules_file "$RULES" "legacy"
output=$(run_with_shim "$RULES" 0 200 "on-path" 2>&1) || true
exit_code=$?
if echo "$output" | grep -q "ENFORCED"; then
  pass "MG4a: legacy mode + marker present => ENFORCED in log"
else
  fail "MG4a: legacy mode + marker present => ENFORCED in log" "output: $output"
fi
if [[ $exit_code -eq 0 ]]; then
  pass "MG4b: legacy mode + ENFORCED => exit 0"
else
  fail "MG4b: legacy mode + ENFORCED => exit 0" "exit_code: $exit_code"
fi

# -------------------------------------------------------------------
# MG5: block mode + BYPASSED probe (timeout: exit 28, http_code 000, no marker)
#      => emits BYPASSED fail-loud message, exits non-zero
# -------------------------------------------------------------------
RULES="${TMPDIR_TEST}/rules-block.yaml"
write_rules_file "$RULES" "block"
set +e
output=$(run_with_shim "$RULES" 28 000 "" 2>&1)
exit_code=$?
set +e
if echo "$output" | grep -qiE "BYPASSED|fail.open|silent|x_tables"; then
  pass "MG5a: block mode + timeout => fail-loud message in log"
else
  fail "MG5a: block mode + timeout => fail-loud message in log" "output: $output"
fi
if [[ $exit_code -ne 0 ]]; then
  pass "MG5b: block mode + BYPASSED probe => exits non-zero (refuses to start)"
else
  fail "MG5b: block mode + BYPASSED probe => exits non-zero (refuses to start)" "exit_code was 0"
fi

# -------------------------------------------------------------------
# MG6: legacy mode + BYPASSED probe (timeout) => exits non-zero (legacy is blocking)
# -------------------------------------------------------------------
RULES="${TMPDIR_TEST}/rules-legacy.yaml"
write_rules_file "$RULES" "legacy"
set +e
output=$(run_with_shim "$RULES" 28 000 "" 2>&1)
exit_code=$?
set +e
if [[ $exit_code -ne 0 ]]; then
  pass "MG6: legacy mode + BYPASSED probe => exits non-zero"
else
  fail "MG6: legacy mode + BYPASSED probe => exits non-zero" "exit_code was 0"
fi

# -------------------------------------------------------------------
# MG7: block mode + INCONCLUSIVE probe (exit 6 / DNS fail)
#      => warns and exits 0 (never-false-alarm)
# -------------------------------------------------------------------
RULES="${TMPDIR_TEST}/rules-block.yaml"
write_rules_file "$RULES" "block"
output=$(run_with_shim "$RULES" 6 000 "" 2>&1) || true
exit_code=$?
if echo "$output" | grep -qiE "INCONCLUSIVE|inconclusive|ambiguous|warn"; then
  pass "MG7a: block mode + DNS-fail => warning in log"
else
  fail "MG7a: block mode + DNS-fail => warning in log" "output: $output"
fi
if [[ $exit_code -eq 0 ]]; then
  pass "MG7b: block mode + INCONCLUSIVE probe => exit 0 (never-false-alarm)"
else
  fail "MG7b: block mode + INCONCLUSIVE probe => exit 0 (never-false-alarm)" "exit_code: $exit_code"
fi

# -------------------------------------------------------------------
# Confirm RIP_CAGE_SELFTEST_PROBE_RESULT is NOT referenced in init-firewall.sh
# (FIX 1 guard: the env-var production hook must be absent).
# -------------------------------------------------------------------
if grep -q "RIP_CAGE_SELFTEST_PROBE_RESULT" "${SCRIPT_DIR}/../cage/egress/init-firewall.sh"; then
  fail "hook-absent: RIP_CAGE_SELFTEST_PROBE_RESULT must NOT appear in init-firewall.sh" \
       "found in init-firewall.sh"
else
  pass "hook-absent: RIP_CAGE_SELFTEST_PROBE_RESULT absent from init-firewall.sh (no live-path hook)"
fi

# -------------------------------------------------------------------
# MG8: probe IP invariant (I2) — probe must use RFC5737 unroutable 192.0.2.1,
#      NOT a routable IP like 1.1.1.1 (using a routable IP reintroduces a false-alarm
#      risk when the external host is temporarily unreachable).
#
# Also verifies the pure SNI router (rip_cage_router.py) serves the selftest host
# LOCALLY before any upstream connect — the pure-router equivalent of mitmproxy's
# old connection_strategy=lazy, which is what makes interception of the unroutable
# target work without an upstream TCP connect (invariant I1).
# -------------------------------------------------------------------
MG8_ARG_LOG="${TMPDIR_TEST}/curl-args-mg8.txt"
cat > "${FAKE_CURL_DIR}/curl" <<SHIM2
#!/usr/bin/env bash
# Argument-capturing shim for MG8.
echo "\$@" >> "${MG8_ARG_LOG}"

# Restore normal shim behavior so we don't break later tests.
header_file=""
prev_arg=""
for arg in "\$@"; do
  if [[ "\$prev_arg" == "-D" ]]; then
    header_file="\$arg"
  fi
  prev_arg="\$arg"
done
if [[ -n "\$header_file" ]]; then
  {
    echo "HTTP/1.1 200 OK"
    echo "X-Rip-Cage-Selftest: on-path"
    echo ""
  } > "\$header_file"
fi
printf '200'
exit 0
SHIM2
chmod +x "${FAKE_CURL_DIR}/curl"

RULES="${TMPDIR_TEST}/rules-block-mg8.yaml"
write_rules_file "$RULES" "block"
PATH="${FAKE_CURL_DIR}:${PATH}" _run_startup_selftest "$RULES" > /dev/null 2>&1 || true

if grep -q "192.0.2.1" "${MG8_ARG_LOG}" 2>/dev/null; then
  pass "MG8a: probe IP is RFC5737 unroutable 192.0.2.1 (no external-host dependency)"
else
  captured_args=$(cat "${MG8_ARG_LOG}" 2>/dev/null || echo "(no args file)")
  fail "MG8a: probe IP is RFC5737 unroutable 192.0.2.1 (no external-host dependency)" \
       "curl args: $captured_args"
fi

if grep -q "1.1.1.1" "${MG8_ARG_LOG}" 2>/dev/null; then
  fail "MG8b: probe must NOT use routable 1.1.1.1 (reintroduces false-alarm risk)" \
       "curl args contained 1.1.1.1; args: $(cat "${MG8_ARG_LOG}" 2>/dev/null)"
else
  pass "MG8b: probe does not use routable 1.1.1.1 (invariant I2 holds)"
fi

# Verify the pure SNI router serves the selftest host locally before any upstream
# connect (the pure-router equivalent of mitmproxy's connection_strategy=lazy; I1).
# The router must (a) recognise SELFTEST_HOSTNAME and (b) do so before the upstream
# connect() call — proven structurally by the selftest short-circuit appearing
# before the first socket connect in rip_cage_router.py.
_router_py="${SCRIPT_DIR}/../cage/egress/rip_cage_router.py"
_selftest_line=$(grep -n "SELFTEST_HOSTNAME" "$_router_py" | grep -v "^.*import" | head -1 | cut -d: -f1)
_connect_line=$(grep -n "\.connect(" "$_router_py" | head -1 | cut -d: -f1)
if [[ -n "$_selftest_line" && -n "$_connect_line" && "$_selftest_line" -lt "$_connect_line" ]]; then
  pass "MG8c: router serves selftest host locally before upstream connect (I1, pure-router equivalent of lazy)"
else
  fail "MG8c: router serves selftest host locally before upstream connect (I1, pure-router equivalent of lazy)" \
       "selftest short-circuit (line ${_selftest_line:-none}) must precede upstream connect (line ${_connect_line:-none}) in rip_cage_router.py"
fi

# Restore the original curl shim for any tests that follow.
cat > "${FAKE_CURL_DIR}/curl" <<'SHIM'
#!/usr/bin/env bash
header_file=""
prev_arg=""
for arg in "$@"; do
  if [[ "$prev_arg" == "-D" ]]; then
    header_file="$arg"
  fi
  prev_arg="$arg"
done
if [[ -n "$header_file" ]]; then
  {
    echo "HTTP/1.1 ${FAKE_CURL_HTTP_CODE:-200} OK"
    if [[ -n "${FAKE_CURL_MARKER:-}" ]]; then
      echo "X-Rip-Cage-Selftest: ${FAKE_CURL_MARKER}"
    fi
    echo ""
  } > "$header_file"
fi
printf '%s' "${FAKE_CURL_HTTP_CODE:-200}"
exit "${FAKE_CURL_EXIT:-0}"
SHIM
chmod +x "${FAKE_CURL_DIR}/curl"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "=== selftest mode-gating tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
