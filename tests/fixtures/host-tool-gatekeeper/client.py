#!/usr/bin/env python3
"""Tiny AF_UNIX client for tests/test-host-tool-gatekeeper.sh.

usage: client.py <socket> [--delay N] [--halfclose]
         send stdin verbatim, then print the reply line
         --delay N     connect first, wait N seconds, then send
         --halfclose   shutdown(SHUT_WR) after sending (EOF ends the line)
       client.py <socket> --idle   connect, send nothing, print seconds until the peer closes
Prints the reply line with its newline stripped; "NOREPLY" when the peer closed with no reply.
"""
import socket
import sys
import time

args = sys.argv[2:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(120)
s.connect(sys.argv[1])
if "--idle" in args:
    t0 = time.monotonic()
    try:
        while s.recv(4096):
            pass
    except OSError:
        pass
    print("%.2f" % (time.monotonic() - t0))
    sys.exit(0)
if "--delay" in args:
    time.sleep(float(args[args.index("--delay") + 1]))
data = sys.stdin.buffer.read()
try:
    s.sendall(data)
    if "--halfclose" in args:
        s.shutdown(socket.SHUT_WR)
except OSError:
    # never mask a send failure: a reset here is exactly the lost-reply class
    print("SENDFAIL")
    sys.exit(1)
buf = b""
try:
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
except OSError:
    pass
sys.stdout.write(buf.decode("utf-8", "replace").rstrip("\n") if buf else "NOREPLY")
sys.stdout.write("\n")
