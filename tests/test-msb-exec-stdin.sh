#!/usr/bin/env bash
set -uo pipefail

# tests/test-msb-exec-stdin.sh -- host-tier proof for rip-cage-q146: rc's
# non-interactive msb exec never hands the caller's stdin to msb.
#
# Measured on msb 0.7.3: `msb exec <cage> -- true` does not return until its
# stdin hits EOF when that stdin is a pipe or socket (a tty is fine). An
# agent's shell and a test harness both hold such a stdin open, so rc doctor
# hung forever. The fake msb below behaves the same way (it reads stdin to
# EOF), and the caller's stdin is a pipe that stays open for 8s.
#
#   S1  _msb_exec returns within 5s with the fake's exit code
#   S2  rc doctor's two direct `msb exec -w` calls close stdin too

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

T=$(mktemp -d /private/tmp/rc-exec-stdin-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "${T}/bin"
cat > "${T}/bin/msb" <<'FAKEEOF'
#!/usr/bin/env bash
cat >/dev/null
exit 7
FAKEEOF
chmod +x "${T}/bin/msb"

# S1 -- perl alarm bounds the call (macOS has no timeout(1)); 142 = SIGALRM.
sleep 8 | PATH="${T}/bin:${PATH}" perl -e 'alarm 5; exec @ARGV' \
  bash -c "source '${RC}' >/dev/null 2>&1; _msb_exec fake-cage -- true"
s1_rc=${PIPESTATUS[1]}
if [[ $s1_rc -eq 7 ]]; then
  pass "S1 _msb_exec returned the guest exit code (7) with an open stdin pipe"
elif [[ $s1_rc -eq 142 ]]; then
  fail "S1 _msb_exec hung on the caller's open stdin (killed after 5s)"
else
  fail "S1 _msb_exec exit ${s1_rc}, want 7"
fi

# S2 -- every direct non-interactive `msb exec` in cli/ closes stdin.
open_calls=$(grep -rn 'msb exec ' "${REPO_ROOT}/cli" \
  | grep -v '^[^:]*:[0-9]*:\s*#' | grep -v 'exec -t\|</dev/null\|echo \|Shell into' || true)
if [[ -z "$open_calls" ]]; then
  pass "S2 no direct non-interactive msb exec in cli/ leaves stdin open"
else
  fail "S2 msb exec call(s) without </dev/null: ${open_calls//$'\n'/ | }"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then echo "=== all passed ==="; exit 0; fi
echo "=== ${FAILURES} failed ==="
exit 1
