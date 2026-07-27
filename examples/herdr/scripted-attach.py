#!/usr/bin/env python3
"""scripted-attach.py -- headless PTY client attach to trigger herdr's native
roster restore (rip-cage-46s5, ADR-029 D8 decision 2).

Spike finding (docs/2026-07-27-msb-spike-roster-resume.md, S4): herdr's
native per-runtime agent restore does NOT fire on server start alone (a
9-minute headless observation window with 9 eligible panes produced zero
re-execs). It fires within ~10s of ANY client attach -- human or scripted --
and a scripted headless PTY client (python pty.fork + TIOCSWINSZ, no human,
no real terminal) is sufficient to trigger it. Restored pane processes
survive the client detaching afterward (S4 finding #2 in the "rip-cage
roster-resume implications" section).

This script is the interim mechanism the cage's herdr 'start' hook invokes
right after the herdr server boots (recipe-owned, per ADR-029 D8's rationale:
"the only cage-side gaps are durability of its state dir ... AND a scripted
headless PTY attach to trigger restore"). It retires once herdr ships a
headless restore-on-start trigger (dotpi-s7ry feature request, noted in the
bead's NOTES) -- see ADR-029 D8's invalidation clause.

What it does:
  1. pty.fork() a child that execs the herdr TUI client (bare 'herdr' by
     default -- the same client the herdr MULTIPLEXER 'attach' hook uses).
  2. Sets a real winsize via TIOCSWINSZ on the pty master fd so the client
     sees plausible terminal dimensions (not a zero-size pty).
  3. Waits --wait-seconds (default 15s -- comfortably past S4's empirically
     observed ~10s restore-trigger window) while draining the client's
     output so it never blocks on a full pty buffer.
  4. Detaches: SIGTERMs the client and reaps it. Per S4, this does NOT kill
     the panes/processes herdr just restored -- only the scripted client
     that triggered the restore.

Usage:
  scripted-attach.py [--wait-seconds N] [-- herdr-args...]

Exit status: 0 once the client has been attached, waited on, and detached.
Non-zero only if the pty/exec setup itself fails (never for "restore hasn't
happened yet" -- this script has no way to observe herdr's internal restore
state; it only provides the client-attach trigger S4 proved is necessary).
"""
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

DEFAULT_WAIT_SECONDS = 15
DEFAULT_ROWS = 24
DEFAULT_COLS = 80


def _set_winsize(fd, rows=DEFAULT_ROWS, cols=DEFAULT_COLS):
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def _parse_args(argv):
    wait_seconds = DEFAULT_WAIT_SECONDS
    client_args = ["herdr"]

    args = list(argv)
    if "--wait-seconds" in args:
        idx = args.index("--wait-seconds")
        wait_seconds = int(args[idx + 1])
        del args[idx : idx + 2]
    if "--" in args:
        idx = args.index("--")
        client_args = ["herdr"] + args[idx + 1 :]

    return wait_seconds, client_args


def main(argv):
    wait_seconds, client_args = _parse_args(argv)

    pid, fd = pty.fork()
    if pid == 0:
        # Child: exec the real herdr TUI client under the new pty. Any exec
        # failure exits the child immediately; the parent's read loop below
        # sees EOF/OSError and moves on to the detach step (fail-soft: this
        # script cannot itself confirm herdr's restore fired, only that it
        # provided the attach trigger).
        try:
            os.execvp(client_args[0], client_args)
        finally:
            os._exit(127)  # pragma: no cover - only reached on exec failure

    # Parent: give the child a plausible window size before it reads it.
    try:
        _set_winsize(fd)
    except OSError as exc:
        print(
            f"[herdr-scripted-attach] WARNING: could not set pty winsize: {exc}",
            file=sys.stderr,
        )

    print(
        f"[herdr-scripted-attach] attached (pid={pid}); waiting {wait_seconds}s "
        "for native restore to fire...",
        file=sys.stderr,
    )

    # Drain any output the client writes so it never blocks on a full pty
    # buffer during the wait window. os.read(fd, ...) on a pty master is a
    # BLOCKING call with no timeout of its own -- a naive "read then check
    # deadline" loop would block indefinitely whenever the client goes quiet
    # (e.g. between screen redraws), silently defeating wait_seconds and
    # turning "wait N seconds, then force-detach" into "wait until the client
    # writes something or exits on its own" (caught by
    # tests/test-herdr-scripted-attach.sh T4 against a silent stub client).
    # select() with an explicit timeout is what actually bounds the wait.
    deadline = time.time() + wait_seconds
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        readable, _, _ = select.select([fd], [], [], remaining)
        if not readable:
            # Timed out waiting for output -- deadline reached, proceed to detach.
            break
        try:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
        except OSError:
            break

    # Detach: terminate the scripted client. Restored pane processes survive
    # this detach (S4 spike finding) -- only the CLIENT dies, never the panes
    # herdr just restored.
    try:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass

    print("[herdr-scripted-attach] detached", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
