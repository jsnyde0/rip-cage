#!/usr/bin/env bash
# Unit tests for _extract_credentials' false-alarm keychain-extraction warning
# (rip-cage-towm).
#
# _extract_credentials (rc, macOS branch) warns unconditionally on
# `security find-generic-password` failure, even when a valid
# ~/.claude/.credentials.json already exists and gets mounted anyway (the
# warning erodes trust and is a false alarm in that case). Fix: only emit the
# failure warning when extraction fails AND there is no usable existing
# credential file (exists, non-empty, best-effort not-expired). With NO
# existing credential file, the original warning must still print verbatim.
#
# Host-only, no live cage required. Sources rc directly (function-only —
# rc's own sourced-vs-executed guard skips dispatch when BASH_SOURCE[0] !=
# $0) and stubs `security` via a PATH shim that always fails, forcing the
# extraction-failure branch on every case here regardless of the real host's
# keychain state.
#
# ABSOLUTE RULE: never touches, writes, moves, or deletes the REAL
# ~/.claude/.credentials.json or ~/.claude.json — every fixture lives under a
# per-test mktemp sandbox with HOME overridden for the sourced-function call
# only; the test process's own $HOME is never reassigned.
#
# Coverage:
#   E1  valid-shaped non-empty existing .credentials.json + security fails
#       -> the "failed to extract" warning is suppressed (both lines absent).
#   E2  NO existing .credentials.json + security fails -> the original
#       two-line warning still prints verbatim (regression pin).
#   E3  EXPIRED existing .credentials.json (expiresAt in the past) + security
#       fails -> warning STILL prints (a stale file is not "usable" --
#       best-effort expiry gate, per the design's own invalidation clause).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

echo "=== test-extract-credentials.sh ==="
echo ""

# A `security` stub that ALWAYS fails (exit 1), simulating the observed
# keychain-extraction failure independent of the real host's keychain state.
SECURITY_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-extract-creds-security-stub-XXXXXX")
cat > "${SECURITY_STUB_DIR}/security" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "${SECURITY_STUB_DIR}/security"

_run_extract_credentials() {
  local sandbox_home="$1"
  local stderr_file
  stderr_file=$(mktemp)
  PATH="${SECURITY_STUB_DIR}:$PATH" HOME="$sandbox_home" bash -c "
    set +e
    # shellcheck source=../rc
    source '$RC' 2>/dev/null
    set +e
    _extract_credentials
  " >/dev/null 2>"$stderr_file"
  cat "$stderr_file"
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# E1: valid-shaped non-empty existing .credentials.json + security fails ->
# no "failed to extract" warning.
# ---------------------------------------------------------------------------
echo "-- E1: valid existing creds file + keychain extraction fails --"

E1_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-extract-creds-e1-XXXXXX")
mkdir -p "${E1_HOME}/.claude"
printf '{"accessToken":"fake-token-e1","tokenType":"Bearer"}' > "${E1_HOME}/.claude/.credentials.json"

E1_STDERR=$(_run_extract_credentials "$E1_HOME")

if [[ "$E1_STDERR" != *"failed to extract Claude credentials"* ]]; then
  pass "E1a no 'failed to extract' warning when a usable existing creds file is present"
else
  fail "E1a no 'failed to extract' warning with usable existing creds file" "got stderr: $E1_STDERR"
fi
if [[ "$E1_STDERR" != *"claude auth login"* ]]; then
  pass "E1b no 'claude auth login' follow-up line either (both warning lines suppressed together)"
else
  fail "E1b no 'claude auth login' follow-up line" "got stderr: $E1_STDERR"
fi
rm -rf "${E1_HOME}"

# ---------------------------------------------------------------------------
# E2: NO existing .credentials.json + security fails -> original warning
# still prints verbatim (regression pin).
# ---------------------------------------------------------------------------
echo ""
echo "-- E2: no existing creds file + keychain extraction fails --"

E2_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-extract-creds-e2-XXXXXX")
mkdir -p "${E2_HOME}/.claude"
rm -f "${E2_HOME}/.claude/.credentials.json"

E2_STDERR=$(_run_extract_credentials "$E2_HOME")

if [[ "$E2_STDERR" == *"failed to extract Claude credentials from macOS keychain — fine if you are not using Claude Code in this cage"* ]]; then
  pass "E2a original 'failed to extract' warning still prints verbatim with no existing creds file"
else
  fail "E2a original warning still prints verbatim with no existing creds file" "got stderr: $E2_STDERR"
fi
if [[ "$E2_STDERR" == *"claude auth login"* ]]; then
  pass "E2b original follow-up line (claude auth login) still prints too"
else
  fail "E2b original follow-up line still prints" "got stderr: $E2_STDERR"
fi
rm -rf "${E2_HOME}"

# ---------------------------------------------------------------------------
# E3: EXPIRED existing .credentials.json + security fails -> warning STILL
# prints (a stale file is not "usable" -- best-effort expiry gate).
# ---------------------------------------------------------------------------
echo ""
echo "-- E3: EXPIRED existing creds file + keychain extraction fails --"

E3_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-extract-creds-e3-XXXXXX")
mkdir -p "${E3_HOME}/.claude"
printf '{"accessToken":"fake-token-e3","tokenType":"Bearer","expiresAt":"2001-01-01T00:00:00Z"}' > "${E3_HOME}/.claude/.credentials.json"

E3_STDERR=$(_run_extract_credentials "$E3_HOME")

if [[ "$E3_STDERR" == *"failed to extract Claude credentials"* ]]; then
  pass "E3a warning still prints when the existing creds file is EXPIRED (stale file is not usable)"
else
  fail "E3a warning still prints for an EXPIRED existing creds file" "got stderr: $E3_STDERR"
fi
rm -rf "${E3_HOME}"

rm -rf "${SECURITY_STUB_DIR}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== extract-credentials tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
