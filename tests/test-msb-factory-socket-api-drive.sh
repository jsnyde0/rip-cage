#!/usr/bin/env bash
# tests/test-msb-factory-socket-api-drive.sh -- effect-based proof for bead
# rip-cage-lczu (S14): the dotpi-3bi factory stack drives herdr via the
# socket-API pane run/read path (not interactive attach) on msb.
#
# Acceptance (bd show rip-cage-lczu):
#  (1) A dotpi-3bi cage on msb drives a real herdr pane via the socket-API
#      path -- a command run through the socket returns its ACTUAL output
#      read back (real data, not attach-liveness).
#  (2) The pane is correctly sized (no ~4-col headless wrap) when
#      dimensions are set explicitly.
#
# HONESTY NOTE (mirrors rip-cage-rj68/S6's test-msb-lifecycle-cockpit-
# reregistration.sh): the rip-cage:latest image available in this
# environment was NOT built with the herdr MULTIPLEXER manifest entry
# baked in. This test sideloads the SAME pinned herdr binary (URL + sha256)
# examples/herdr/manifest-fragment.yaml's TOOL entry uses -- a real herdr
# binary, checksum-verified, not a stub. The rc-build-integration path
# (tools.yaml -> Dockerfile -> baked image) is already covered by
# S6/rj68 + examples/herdr; this test's job is the socket-API DRIVE
# mechanics dotpi-3bi's drover/herdr automation depends on
# (docs/2026-07-07-microvm-spike-findings.md §8a/§8a-follow-up).
#
# DESIGN FINDING (Fable ruling 4 -- fake-accept limit is a design finding,
# not a thing to test around): this entire drive path is HOST->GUEST only
# -- the host runs `msb exec`/`msb exec -t` into the guest CLI, and the
# herdr control surface itself is a guest-local UNIX domain socket, never
# TCP. No leg of the socket-API pane run/read path requires guest->host
# TCP, so msb's fake-accept-on-denied-TCP property is simply not
# implicated here. (A *future* factory leg that needed the cage to reach a
# host-side service directly -- e.g. the parked host-service beads seam,
# ADR-029 D7 -- would be the trigger for that finding, not this one.)
#
# Session-scoped socket path (epic gotcha 1) and explicit pane sizing via
# a host-driven sized PTY into `msb exec -t` (epic gotcha 2) are both
# exercised for real. Gotcha 2's proof is a CONTENT DIFFERENTIAL: the
# identical wide token is run through pane run/read once before the sized
# client attaches (asserted WRAPPED) and once after (asserted the SAME
# token now reads back as one UNWRAPPED line) -- not a `pane layout`
# dimension self-report alone, and not a bare "pane exists" liveness check.
#
# NEEDS_MSB + a pre-built rip-cage:latest image + live network path to
# github.com (to fetch the herdr binary) + python3 (host-side PTY sizer).
# Self-skips otherwise.

set -uo pipefail

MSB_BIN="$(command -v msb || true)"
IMAGE="rip-cage:latest"
SESSION="dotpi3bi"
PANE="w1:p1"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if [[ -z "$MSB_BIN" ]]; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available (needed for the host-driven sized-PTY sizer) -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi

NAME="factory-drive-$$"
SIZER_PID=""
cleanup() {
  [[ -n "$SIZER_PID" ]] && kill "$SIZER_PID" >/dev/null 2>&1
  msb remove --force "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== SETUP: create cage, sideload herdr, start a NAMED-SESSION headless server ==="
if ! msb create "$IMAGE" --name "$NAME" \
    --net-default deny --net-rule "allow@github.com:tcp:443,allow@*.githubusercontent.com:tcp:443,allow@objects.githubusercontent.com:tcp:443" \
    >/dev/null 2>&1; then
  fail "setup: msb create failed"
  echo ""
  echo "=== test-msb-factory-socket-api-drive.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

# Sideload herdr: same pinned URL/checksum examples/herdr/manifest-fragment.yaml's TOOL entry uses.
SIDELOAD=$(mktemp)
cat > "$SIDELOAD" <<'SCRIPT'
set -e
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then TARGET=aarch64; EXPECTED_SHA=77407959c514c25c870bbcc6d2a2c86fef5b5701ed0c7c37745d7412e8563d72; else TARGET=x86_64; EXPECTED_SHA=ad2a5d480a4e04609a9dd30a19ec07854578df6b5f0ea9299246963baf40363b; fi
curl -fsSL "https://github.com/ogulcancelik/herdr/releases/download/v0.7.0/herdr-linux-${TARGET}" -o /tmp/herdr
echo "${EXPECTED_SHA}  /tmp/herdr" | sha256sum -c -
install -m 755 /tmp/herdr /usr/local/bin/herdr
rm -f /tmp/herdr
SCRIPT
msb copy "$SIDELOAD" "${NAME}:/tmp/herdr-sideload.sh" >/dev/null 2>&1
SIDELOAD_OUT=$(msb exec "$NAME" -u root -- sh /tmp/herdr-sideload.sh 2>&1)
SIDELOAD_RC=$?
rm -f "$SIDELOAD"
if [[ "$SIDELOAD_RC" -eq 0 ]]; then
  pass "setup: herdr sideloaded (pinned URL, checksum verified against the real manifest-fragment.yaml value)"
else
  fail "setup: herdr sideload failed" "$SIDELOAD_OUT"
  echo ""
  echo "=== test-msb-factory-socket-api-drive.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

# Headless named-session server: the factory pattern (not `herdr` interactive
# attach). A bare `&` backgrounding is proven (rip-cage-rj68/S6 precedent) to
# survive across separate `msb exec` calls on an already-`create`d sandbox.
msb exec "$NAME" -- sh -c "herdr --session ${SESSION} server > /tmp/herdr-session.log 2>&1 &" >/dev/null 2>&1
sleep 1
STATUS_JSON=$(msb exec "$NAME" -- herdr --session "$SESSION" status server --json 2>&1)
if echo "$STATUS_JSON" | grep -q '"running":true'; then
  pass "setup: a real named-session herdr server is running in-guest"
else
  fail "setup: expected the named-session server to report running" "$STATUS_JSON"
  echo ""
  echo "=== test-msb-factory-socket-api-drive.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

echo ""
echo "=== GOTCHA 1 (socket path): a --session NAME server's socket is session-scoped, not the default path ==="
SESSION_SOCK=$(msb exec "$NAME" -- sh -c "test -S ~/.config/herdr/sessions/${SESSION}/herdr.sock && echo present" 2>/dev/null)
DEFAULT_SOCK=$(msb exec "$NAME" -- sh -c 'test -S ~/.config/herdr/herdr.sock && echo present || echo absent' 2>/dev/null)
if [[ "$SESSION_SOCK" == "present" ]]; then
  pass "GOTCHA1: session-scoped socket exists at ~/.config/herdr/sessions/${SESSION}/herdr.sock"
else
  fail "GOTCHA1: expected the session-scoped socket to exist" "got '${SESSION_SOCK}'"
fi
if [[ "$DEFAULT_SOCK" == "absent" ]]; then
  pass "GOTCHA1: the DEFAULT herdr.sock path was never created (proves the session-scoped path is real, not a copy/alias)"
else
  fail "GOTCHA1: expected no default-path socket for a --session server" "got '${DEFAULT_SOCK}'"
fi

echo ""
echo "=== Materialize a pane via the socket API (no interactive attach) ==="
WS_OUT=$(msb exec "$NAME" -- herdr --session "$SESSION" workspace create --label factory --cwd /home/agent 2>&1)
if echo "$WS_OUT" | grep -q "\"pane_id\":\"${PANE}\""; then
  pass "socket-API workspace create materialized pane ${PANE}"
else
  fail "socket-API workspace create did not materialize the expected pane" "$WS_OUT"
  echo ""
  echo "=== test-msb-factory-socket-api-drive.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

echo ""
echo "=== GOTCHA 2 baseline: BEFORE explicit sizing, a long line wraps at the narrow headless default ==="
UNSIZED_TOKEN="UNSIZED-$$-0123456789012345678901234567890123456789012345678901234567890123456789"
msb exec "$NAME" -- herdr --session "$SESSION" pane run "$PANE" "printf '%s\n' '${UNSIZED_TOKEN}'" >/dev/null 2>&1
sleep 1
UNSIZED_READ=$(msb exec "$NAME" -- herdr --session "$SESSION" pane read "$PANE" --source visible 2>&1)
if echo "$UNSIZED_READ" | grep -qF "$UNSIZED_TOKEN"; then
  fail "GOTCHA2 baseline: expected the unsized token to be WRAPPED (not present as one contiguous substring) pre-sizing -- sizing differential would be meaningless" "$UNSIZED_READ"
else
  pass "GOTCHA2 baseline: the unsized token is hard-wrapped pre-sizing, as the headless-default gotcha predicts"
fi

echo ""
echo "=== GOTCHA 2 fix: attach a HOST-DRIVEN, explicitly-sized PTY client (rows=40 cols=120, the epic's own spike figures) and hold it attached ==="
SIZER=$(mktemp)
cat > "$SIZER" <<PYEOF
import fcntl, os, pty, struct, subprocess, sys, termios, time
master_fd, slave_fd = pty.openpty()
fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
proc = subprocess.Popen(["${MSB_BIN}", "exec", "-t", "${NAME}", "--", "herdr", "--session", "${SESSION}"],
                         stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, start_new_session=True)
os.close(slave_fd)
try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    pass
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PYEOF
python3 "$SIZER" &
SIZER_PID=$!

SIZED=""
for _ in $(seq 1 15); do
  LAYOUT=$(msb exec "$NAME" -- herdr --session "$SESSION" pane layout --pane "$PANE" 2>/dev/null)
  if echo "$LAYOUT" | grep -q '"width":94' && echo "$LAYOUT" | grep -q '"height":39'; then
    SIZED="$LAYOUT"
    break
  fi
  sleep 1
done

# Secondary signal only: the layout self-report. The load-bearing proof is the
# content differential below (SAME wide token, wrapped pre-sizing above, now
# read back unwrapped) -- a dimension self-report alone doesn't prove `pane
# read` output actually stopped wrapping.
if [[ -n "$SIZED" ]]; then
  pass "GOTCHA2 fix (secondary signal): pane layout reports width=94 height=39 (matches the epic spike's own sized-attach figures, not the ~4-col/narrow headless default)"
else
  fail "GOTCHA2 fix (secondary signal): pane never reported the expected sized dimensions" "last layout: ${LAYOUT:-<none>}"
fi

echo ""
echo "=== GOTCHA 2 fix -- CONTENT DIFFERENTIAL: the SAME wide token that WRAPPED pre-sizing above now reads back as ONE UNWRAPPED line post-sizing ==="
msb exec "$NAME" -- herdr --session "$SESSION" pane run "$PANE" "printf '%s\n' '${UNSIZED_TOKEN}'" >/dev/null 2>&1
sleep 1
RESIZED_READ=$(msb exec "$NAME" -- herdr --session "$SESSION" pane read "$PANE" --source visible 2>&1)
rm -f "$SIZER"
if echo "$RESIZED_READ" | grep -qF "$UNSIZED_TOKEN"; then
  pass "GOTCHA2 fix (content differential): the identical token that wrapped pre-sizing (GOTCHA2 baseline above) now reads back as ONE CONTIGUOUS UNWRAPPED line post-sizing -- a genuine wrapped-before/unwrapped-after proof, not a dimension self-report"
else
  fail "GOTCHA2 fix (content differential): expected the same token that wrapped pre-sizing to read back UNWRAPPED (as one contiguous substring) post-sizing" "$RESIZED_READ"
fi

echo ""
echo "=== ACCEPTANCE (1): a REAL command run through the socket returns its ACTUAL output (real data, not attach-liveness) ==="
COMPUTED=$(( (RANDOM % 900) + 100 ))
msb exec "$NAME" -- herdr --session "$SESSION" pane run "$PANE" "printf 'FACTORY_MARKER_%s\n' \$(( ${COMPUTED} * 3 - ${COMPUTED} * 2 ))" >/dev/null 2>&1
sleep 1
SIZED_READ=$(msb exec "$NAME" -- herdr --session "$SESSION" pane read "$PANE" --source visible 2>&1)
EXPECTED_LINE="FACTORY_MARKER_${COMPUTED}"
if echo "$SIZED_READ" | grep -qxF "$EXPECTED_LINE"; then
  pass "ACCEPTANCE(1): the socket-API pane run/read round-trip returned the REAL COMPUTED value '${EXPECTED_LINE}' (arithmetic performed in-guest by the pane's own shell, not echoed) -- real data, not attach-liveness"
else
  fail "ACCEPTANCE(1): expected an exact line '${EXPECTED_LINE}'" "$SIZED_READ"
fi

echo ""
echo "=== test-msb-factory-socket-api-drive.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
