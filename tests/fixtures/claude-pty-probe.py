#!/usr/bin/env python3
"""Drive interactive `claude` in a pseudo-terminal and print what it rendered.

Runs INSIDE a cage (python3 is in the base image). Used by
tests/test-claude-unattended-start-live.sh (rip-cage-jimf) to prove an
unattended spawn reaches the prompt with no startup dialog.

Usage: python3 claude-pty-probe.py [seconds] [cwd] [claude-arg ...]

Spawns `claude` (with any extra args given; the test passes none) -- exactly what a human or a multiplexer
spawn types -- answers nothing, reads the screen for up to <seconds> (default
25), then kills it. Stdout is the rendered text with ANSI escapes stripped, so
a caller greps it for dialog text. Exit 0 always; the caller judges.
"""
import os
import pty
import re
import select
import signal
import sys
import time

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 25.0
cwd = sys.argv[2] if len(sys.argv) > 2 else "/workspace"

pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLUMNS"] = "120"
    os.environ["LINES"] = "40"
    os.execvp("claude", ["claude"] + sys.argv[3:])

buf = b""
deadline = time.time() + secs
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.5)
    if not r:
        continue
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    # Answer a cursor-position query so a TUI waiting on it keeps rendering.
    if b"\x1b[6n" in chunk:
        os.write(fd, b"\x1b[1;1R")

try:
    os.kill(pid, signal.SIGKILL)
except ProcessLookupError:
    pass

text = buf.decode("utf-8", "replace")
text = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", " ", text)
text = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", text)
text = re.sub(r"\x1b[@-_]", "", text)
text = re.sub(r"[ \t]+", " ", text)
sys.stdout.write(text)
