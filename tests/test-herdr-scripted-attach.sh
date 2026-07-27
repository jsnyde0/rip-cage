#!/usr/bin/env bash
# tests/test-herdr-scripted-attach.sh -- host-only unit test for
# examples/herdr/scripted-attach.py (rip-cage-46s5, ADR-029 D8 decision 2).
#
# S4 spike finding (docs/2026-07-27-msb-spike-roster-resume.md): herdr's native
# roster restore does NOT fire on server start alone -- it fires within ~10s of
# ANY client attach (human or scripted), and a scripted headless PTY client
# (python pty.fork + TIOCSWINSZ, no human, no real terminal) is sufficient.
# Pane processes survive client detach.
#
# This test does NOT require a real herdr binary or a booted cage -- it stubs
# 'herdr' on PATH with a fake client that proves: (a) it was actually invoked
# under a real pty (not just a plain subprocess -- winsize is nonzero), and
# (b) the scripted-attach script waits, then detaches (terminates the client)
# rather than hanging forever. The live in-cage effect (real roster restore)
# is the bead's deferred in-cage e2e, not this file's job.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
ATTACH_SCRIPT="${REPO_ROOT}/examples/herdr/scripted-attach.py"

FAILURES=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

echo "=== test-herdr-scripted-attach.sh (rip-cage-46s5) ==="
echo ""

# =============================================================================
# T1 -- script exists and is syntactically valid python3.
# =============================================================================
echo "--- T1: script exists + syntax check ---"
if [[ ! -f "$ATTACH_SCRIPT" ]]; then
  fail "T1: ${ATTACH_SCRIPT} does not exist"
else
  if python3 -m py_compile "$ATTACH_SCRIPT" 2>"${TMPROOT}/py-compile.err"; then
    pass "T1: scripted-attach.py compiles cleanly (python3 -m py_compile)"
  else
    fail "T1: scripted-attach.py failed to compile" "$(cat "${TMPROOT}/py-compile.err")"
  fi
fi

# =============================================================================
# Setup shared by T2-T4: a stub 'herdr' on PATH that proves it ran under a
# REAL pty (writes the winsize it sees to a marker file) and stays alive
# until signaled (so we can prove the attach script actually detaches it,
# not just waits for it to exit on its own).
# =============================================================================
STUB_DIR="${TMPROOT}/stub-bin"
mkdir -p "$STUB_DIR"
MARKER="${TMPROOT}/attach-marker.txt"
ALIVE_MARKER="${TMPROOT}/alive-at-exit.txt"

cat > "${STUB_DIR}/herdr" <<'STUB'
#!/usr/bin/env python3
# Stub 'herdr' CLI for test-herdr-scripted-attach.sh: proves it was invoked
# under a real pty (nonzero TIOCGWINSZ) and stays alive until SIGTERM.
import fcntl
import os
import signal
import struct
import sys
import termios
import time

marker = os.environ["RC_TEST_MARKER"]
alive_marker = os.environ["RC_TEST_ALIVE_MARKER"]

rows, cols = 0, 0
try:
    packed = fcntl.ioctl(sys.stdin.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
    rows, cols, _, _ = struct.unpack("HHHH", packed)
except OSError:
    pass

with open(marker, "w") as f:
    f.write(f"rows={rows} cols={cols} pid={os.getpid()}\n")

terminated = {"flag": False}


def _on_term(signum, frame):
    terminated["flag"] = True


signal.signal(signal.SIGTERM, _on_term)

# Stay alive up to 30s (long past any reasonable test wait), but exit
# early+cleanly on SIGTERM so the attach script's detach is provable.
deadline = time.time() + 30
while time.time() < deadline and not terminated["flag"]:
    time.sleep(0.1)

with open(alive_marker, "w") as f:
    f.write("terminated\n" if terminated["flag"] else "timed-out\n")
STUB
chmod +x "${STUB_DIR}/herdr"

run_attach_script() {
  local wait_seconds="$1"
  RC_TEST_MARKER="$MARKER" RC_TEST_ALIVE_MARKER="$ALIVE_MARKER" \
    PATH="${STUB_DIR}:${PATH}" \
    python3 "$ATTACH_SCRIPT" --wait-seconds "$wait_seconds"
}

# =============================================================================
# T2 -- the script actually invokes 'herdr' (the stub ran, marker written).
# =============================================================================
echo ""
echo "--- T2: scripted-attach invokes 'herdr' ---"
rm -f "$MARKER" "$ALIVE_MARKER"
T2_OUT=$(run_attach_script 1 2>&1)
T2_RC=$?
if [[ "$T2_RC" -ne 0 ]]; then
  fail "T2: scripted-attach.py exited non-zero (rc=$T2_RC)" "$T2_OUT"
elif [[ -f "$MARKER" ]]; then
  pass "T2: scripted-attach.py invoked the stub 'herdr' client"
else
  fail "T2: stub 'herdr' never ran (no marker file)" "$T2_OUT"
fi

# =============================================================================
# T3 -- the client runs under a REAL pty (nonzero winsize) -- proves
# pty.fork()+TIOCSWINSZ, not a plain subprocess.Popen with no tty at all.
# =============================================================================
echo ""
echo "--- T3: client attaches under a real pty (nonzero winsize) ---"
if [[ -f "$MARKER" ]]; then
  marker_content=$(cat "$MARKER")
  rows_seen=$(echo "$marker_content" | grep -oE 'rows=[0-9]+' | cut -d= -f2)
  cols_seen=$(echo "$marker_content" | grep -oE 'cols=[0-9]+' | cut -d= -f2)
  if [[ -n "$rows_seen" && "$rows_seen" -gt 0 && -n "$cols_seen" && "$cols_seen" -gt 0 ]]; then
    pass "T3: client saw a real pty winsize (rows=${rows_seen} cols=${cols_seen})"
  else
    fail "T3: client saw a zero/absent winsize -- not a real pty" "$marker_content"
  fi
else
  fail "T3: no marker from T2 to inspect (prior test failed)"
fi

# =============================================================================
# T4 -- the script detaches (terminates) the client rather than waiting for
# it to exit on its own (the stub sleeps up to 30s; --wait-seconds 1 means
# the attach script must SIGTERM it well before the 30s timeout).
# =============================================================================
echo ""
echo "--- T4: scripted-attach detaches the client (does not hang) ---"
if [[ -f "$ALIVE_MARKER" ]]; then
  alive_content=$(cat "$ALIVE_MARKER")
  if [[ "$alive_content" == "terminated" ]]; then
    pass "T4: client was terminated by the attach script (detach proven)"
  else
    fail "T4: client hit its own 30s timeout instead of being detached -- attach script never signaled it" "$alive_content"
  fi
else
  fail "T4: no alive-marker written (client may still be running, or T2 failed)"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-herdr-scripted-attach.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-herdr-scripted-attach.sh: all ${TOTAL} tests passed ==="
