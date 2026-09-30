#!/usr/bin/env bash
set -uo pipefail

# tests/test-claude-headless-live.sh -- container-tier probe for rip-cage-2dyy:
# headless `claude -p` run from the host into a live cage returns, and the one
# host-side mistake that makes it look hung.
#
# Measured on msb 0.7.4 (rip-cage-2dyy): a non-interactive `msb exec` whose
# stdin is a pipe does not START the guest command until that stdin hits EOF
# (a marker-file probe showed the command had not run; see the bead notes). A caller that
# leaves stdin open (an agent's shell, a harness pipe) sees nothing at all and
# its timeout reports exit 124 with empty output -- which reads as "claude -p
# hangs". With stdin closed, claude -p returns, but slowly: 6s to 8.3min in one
# cage over two hours, driven by load in the cage and on the host.
#
#   H1  msb exec with an open stdin pipe prints nothing within 5s (the msb
#       behaviour the docs warn about). This checks output, not start: an msb
#       that ran the command but held its output would still pass. If H1
#       FAILS with the guest's "started" line, msb changed and the caveat in
#       cage-ops step 1 and examples/claude can go.
#   H2  msb exec ... claude -p ... < /dev/null exits 0 with non-empty stdout
#       within RC_HEADLESS_BOUND seconds (default 600)
#
# Reads and execs only: it never creates, stops or reconfigures the cage.
#   RC_HEADLESS_CAGE=<running cage> bash tests/test-claude-headless-live.sh

CAGE="${RC_HEADLESS_CAGE:-}"
BOUND="${RC_HEADLESS_BOUND:-600}"
if ! [[ "$BOUND" =~ ^[1-9][0-9]*$ ]]; then
  echo "FAIL: RC_HEADLESS_BOUND must be a positive integer of seconds, got '${BOUND}'"
  exit 1
fi

if [[ -z "$CAGE" ]]; then
  echo "SKIP: set RC_HEADLESS_CAGE to a running, authed cage (msb ls)"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not on PATH"
  exit 0
fi
if ! msb exec "$CAGE" -- true < /dev/null >/dev/null 2>&1; then
  echo "SKIP: cage ${CAGE} is not running (msb exec -- true failed)"
  exit 0
fi

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/rc-headless-XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -f "$T"/out "$T"/err; rmdir "$T"' EXIT

# H1 -- perl alarm bounds the call (macOS has no timeout(1)); 142 = SIGALRM.
# The guest command only echoes; its line within 5s means msb ran it.
sleep 8 | perl -e 'alarm 5; exec @ARGV' \
  msb exec "$CAGE" -- sh -c 'echo started' > "$T/out" 2>&1
h1_rc=${PIPESTATUS[1]}
if [[ $h1_rc -eq 142 && ! -s "$T/out" ]]; then
  pass "H1 open stdin: msb exec printed nothing after 5s (exit 142)"
elif grep -qx started "$T/out"; then
  fail "H1 open stdin: the guest command ran and printed within 5s (exit ${h1_rc}) -- msb no longer waits for stdin EOF; retire the caveat in .claude/skills/cage-ops step 1 and examples/claude/README.md"
else
  fail "H1 open stdin: msb exec itself failed (exit ${h1_rc}): $(head -c 200 "$T/out" | tr '\n' ' ') -- not evidence about stdin; check the cage"
fi

# H2 -- the shape every caller should use: stdin closed, a generous bound.
start=$SECONDS
perl -e "alarm ${BOUND}; exec @ARGV" \
  msb exec "$CAGE" -- bash -lc 'claude -p "Reply with the single word ok" --output-format text' \
  < /dev/null > "$T/out" 2> "$T/err"
h2_rc=$?
elapsed=$((SECONDS - start))
if [[ $h2_rc -eq 0 && -s "$T/out" ]]; then
  pass "H2 claude -p returned in ${elapsed}s (bound ${BOUND}s): $(head -c 80 "$T/out" | tr '\n' ' ')"
else
  fail "H2 claude -p exit ${h2_rc} after ${elapsed}s (bound ${BOUND}s, 142 = bound hit), stdout '$(head -c 80 "$T/out")', stderr tail: $(tail -n 3 "$T/err" | tr '\n' ' ')"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then echo "=== all passed ==="; exit 0; fi
echo "=== ${FAILURES} failed ==="
exit 1
