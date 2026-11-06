#!/usr/bin/env python3
"""Fake gatekeeper for tests/test-host-tool-client.sh (ADR-032 D6 wire).

usage: host-tool-fake-gatekeeper.py <unix-socket> <table.json> <capture-file>

Serves AF_UNIX only; never a vsock. One request line per connection, one
reply line back. Each raw request line received is appended to <capture-file>.
<table.json> is {"list": <entry>, "calls": {"<tool> <verb>": <entry>}} where an
entry is {"raw": "<exact reply line>", "delay": <seconds>, "drop": <bool>}; a missing call key
falls back to calls["*"]. The fake validates nothing -- it only replays.
"""
import json
import os
import socket
import sys
import threading
import time

sock_path, table_path, capture_path = sys.argv[1:4]
with open(table_path) as fh:
    table = json.load(fh)


def entry_for(line):
    try:
        req = json.loads(line)
    except ValueError:
        return {"raw": '{"ok":false,"error":{"kind":"bad-argument","message":"x"}}'}
    if isinstance(req, dict) and req.get("list") is True:
        return table["list"]
    key = "%s %s" % (req.get("tool"), req.get("verb"))
    return table["calls"].get(key) or table["calls"]["*"]


def serve(conn):
    with conn:
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
        with open(capture_path, "ab") as cap:
            cap.write(buf)  # exactly the bytes received, terminator or not
        line = buf.decode("utf-8", "replace").strip()
        ent = entry_for(line)
        time.sleep(ent.get("delay", 0))
        if ent.get("drop"):
            return  # close without a reply: EOF mid-call
        try:
            conn.sendall(ent["raw"].encode() + b"\n")
        except OSError:
            pass


srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
if os.path.exists(sock_path):
    os.unlink(sock_path)
srv.bind(sock_path)
srv.listen(8)
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
