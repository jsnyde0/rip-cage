#!/usr/bin/env bash
set -uo pipefail

# tests/test-up-resume-conf-secrets.sh -- host-tier proof for rip-cage-l18a: the
# plain-resume branch of `rc up` (a STOPPED cage whose config is unchanged)
# exports the conf's `secrets:` names from $XDG_CONFIG_HOME/rip-cage/secrets/
# <NAME> before `msb start`, exactly as the create path does. msb re-resolves
# every secret binding from the host env at START time, so without the export
# resume dies with "secret CCTOK: host environment variable CCTOK is not set".
#
#   S1  CCTOK unset in the shell, token in the secrets file: rc up resumes,
#       exits 0, and msb start sees CCTOK set (presence + length recorded,
#       never the value).
#   S2  no secrets file and CCTOK unset: rc up exits non-zero and msb start
#       never sees CCTOK (rc's own auth preflight or the stub's msb-like
#       failure stops it), so it does not silently succeed.
#
# The state reads and the resume-only guards are stubbed in the driving shell
# (same technique as test-up-resource-flags.sh R3); the branch under test,
# _up_prepare_resume_secrets, runs for real. Fake docker + msb are on PATH.
# XDG_CONFIG_HOME is a temp dir; the operator's real secrets are never read.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC="${REPO_ROOT}/rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"
# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

T=$(mktemp -d /private/tmp/rc-resume-secrets-XXXXXX)
T=$(cd "$T" && pwd -P)
_FAKE_RT=$(fake_runtime_bin)
trap 'rm -rf "$T" "$_FAKE_RT"' EXIT
export PATH="${_FAKE_RT}:${PATH}"

WS="${T}/proj/ws"
mkdir -p "$WS"
CONF=$(cage_conf_for "$WS")
printf 'secrets:\n  CCTOK:\n    hosts:\n      - api.anthropic.com\n' >> "$CONF"

XDG="${T}/xdg"
mkdir -p "${XDG}/rip-cage/secrets"
SFILE="${XDG}/rip-cage/secrets/CCTOK"

FAKE_TOKEN="sk-ant-oat01-$(printf 'x%.0s' $(seq 1 90))"

# Run rc up on the stopped cage. The msb start stub prints "START CCTOK=set:LEN"
# or "START CCTOK=unset" (never the value) and fails like msb when it is unset.
resume_run() {
  XDG_CONFIG_HOME="$XDG" RC_CAGE_CONF="$CONF" bash -c '
    unset CCTOK
    source "$1"; shift
    set -euo pipefail   # rc sets this only when executed, not sourced
    _msb_sandbox_state() { echo "exited"; }
    _up_converge_needed() { return 1; }
    _up_resolve_resume_image_drift_stopped() { :; }
    _up_resolve_resume_symlink_fingerprint() { :; }
    _up_init_container() { _UP_INIT_OK=true; }
    _msb_start() {
      # Read CCTOK from a CHILD process (printenv), the way msb does: an
      # assigned-but-unexported value must read as unset here.
      local _len
      _len=$(printenv CCTOK | tr -d "\n" | wc -c | tr -d " ")
      if [[ "$_len" -gt 0 ]]; then
        echo "START CCTOK=set:${_len}"
      else
        echo "START CCTOK=unset"
        echo "error: invalid config: secret CCTOK: host environment variable CCTOK is not set" >&2
        return 1
      fi
    }
    cmd_up "$@"
  ' resume "$RC" "$WS" 2>&1
}

echo "=== S1: CCTOK unset in shell, token in secrets file -> resume sources it ==="
printf '%s' "$FAKE_TOKEN" > "$SFILE"; chmod 0600 "$SFILE"
S1=$(resume_run); S1_RC=$?
if [[ "$S1_RC" -eq 0 && "$S1" == *"START CCTOK=set:${#FAKE_TOKEN}"* ]]; then
  pass "S1 resume exits 0 and msb start sees CCTOK (length ${#FAKE_TOKEN})"
else
  fail "S1 exit=${S1_RC}; output: $(tr '\n' '|' <<<"$S1")"
fi

echo "=== S2: no secrets file, CCTOK unset -> resume does not silently succeed ==="
rm -f "$SFILE"
S2=$(resume_run); S2_RC=$?
if [[ "$S2_RC" -ne 0 && "$S2" != *"START CCTOK=set"* ]]; then
  pass "S2 no token anywhere: rc up exits ${S2_RC} and never reaches a booted msb start"
else
  fail "S2 exit=${S2_RC}; output: $(tr '\n' '|' <<<"$S2")"
fi

echo ""
[[ "$FAILURES" -eq 0 ]] && { echo "All tests passed"; exit 0; }
echo "${FAILURES} test(s) failed"; exit 1
