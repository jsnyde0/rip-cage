#!/usr/bin/env python3
"""Host-side gatekeeper for the host-tool line (ADR-032 D3/D6).

Launched by rc as
  <abs python3> -I host-tool-gatekeeper.py --socket P --decl J --log L --pid F --cwd D [--bound N]

Serves one JSON line per request and reply on an AF_UNIX socket. Runs each
declared verb as an argv array (never a shell) from a fresh per-call
directory, with an environment of exactly PATH, HOME, LANG. Reply messages
come from a fixed table; no exception text, path or argument value enters a
reply. Python 3 standard library only.
"""
import argparse
import json
import os
import re
import select
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata

PATH_CONSTANT = "/usr/bin:/bin"  # Linux and macOS alike; no /usr/local/bin
LINE_CAP = 32 * 1024  # max bytes of an encoded request or reply line, measured WITHOUT its newline terminator
READ_TIMEOUT = 10.0  # seconds to receive the whole request line
TERM_GRACE = 5.0  # in-flight commands at SIGTERM
KILL_GRACE = 0.3  # SIGTERM -> SIGKILL on a command group
LISTEN_BACKLOG = 128
BUSY_DRAIN = 2.0  # seconds a busy connection is drained before close

# Fixed message table keyed by error kind. Only bad-argument (declared slot
# name) and tool-failed (exit status) vary.
MESSAGES = {
    "no-such-tool": "no such tool",
    "no-such-verb": "no such verb",
    "bad-argument": "bad argument",
    "request-too-large": "request too large",
    "reply-too-large": "reply too large",
    "timeout": "timed out",
    "tool-failed": "tool failed",
    "busy": "busy",
    "unavailable": "unavailable",
}

LOG_FD = -1
LOG_LOCK = threading.Lock()


def log(msg):
    line = ("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg)).encode("utf-8", "replace")
    with LOG_LOCK:
        try:
            os.write(LOG_FD if LOG_FD >= 0 else 2, line)
        except OSError:
            pass


def err_reply(kind, detail=None):
    msg = MESSAGES[kind]
    if kind == "bad-argument":
        msg = "bad-argument: slot %s" % detail if detail else "bad-argument: request"
    elif kind == "tool-failed":
        msg = "tool-failed: exit %d" % detail
    return {"ok": False, "error": {"kind": kind, "message": msg}}


def encode(reply):
    return json.dumps(reply, separators=(",", ":")).encode("ascii") + b"\n"


class Refuse(Exception):
    def __init__(self, kind, detail=None):
        Exception.__init__(self, kind)
        self.kind = kind
        self.detail = detail


# --- validation -----------------------------------------------------------

def has_control(s):
    return any(unicodedata.category(c) in ("Cc", "Zl", "Zp") for c in s)


def check_slot(name, spec, value, rx):
    """Raise Refuse('bad-argument', name) unless value fits spec."""
    t = spec["type"]
    if t == "int":
        if type(value) is not int:
            raise Refuse("bad-argument", name)
        if "min" in spec and value < spec["min"]:
            raise Refuse("bad-argument", name)
        if "max" in spec and value > spec["max"]:
            raise Refuse("bad-argument", name)
        return
    if t == "enum":
        if not isinstance(value, str) or value not in spec["values"]:
            raise Refuse("bad-argument", name)
        return
    # string
    if not isinstance(value, str):
        raise Refuse("bad-argument", name)
    if len(value.encode("utf-8")) > spec["max"]:
        raise Refuse("bad-argument", name)
    if rx is not None and rx.fullmatch(value) is None:
        raise Refuse("bad-argument", name)
    if has_control(value):
        raise Refuse("bad-argument", name)
    if value.startswith("-") and not spec["allow_dash"]:
        raise Refuse("bad-argument", name)
    if not spec["allow_slash"] and ("/" in value or value == ".."):
        raise Refuse("bad-argument", name)


class Gatekeeper(object):
    def __init__(self, decl, regexes, state, bound, env_lang):
        self.tools = decl["tools"]
        self.regexes = regexes  # (tool, verb, slot) -> compiled
        self.calls_dir = os.path.join(state, "calls")
        self.lang = env_lang
        self.sem = threading.Semaphore(bound)
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.procs = set()
        self.threads = set()

    # -- request handling --
    def read_line(self, conn):
        """Return (kind, bytes): ('line', b) | ('big', None) | ('closed', None).

        The line is the bytes before the newline; EOF (half-close) also ends it.
        """
        deadline = time.monotonic() + READ_TIMEOUT
        buf = b""
        while True:
            nl = buf.find(b"\n")
            if nl >= 0:
                return ("line", buf[:nl]) if nl <= LINE_CAP else ("big", None)
            if len(buf) > LINE_CAP:
                return ("big", None)
            left = deadline - time.monotonic()
            if left <= 0:
                return ("closed", None)
            conn.settimeout(left)
            try:
                chunk = conn.recv(4096)
            except (socket.timeout, OSError):
                return ("closed", None)
            if not chunk:  # EOF terminates the line if any bytes arrived
                return ("line", buf) if buf else ("closed", None)
            buf += chunk

    def list_reply(self):
        out = {}
        for tool, tv in self.tools.items():
            out[tool] = {}
            for verb, v in tv["verbs"].items():
                out[tool][verb] = {
                    "timeout": int(v["timeout"]),
                    "slots": dict((s, sp["type"]) for s, sp in v["slots"].items()),
                }
        return {"ok": True, "result": {"tools": out}}

    def parse(self, line):
        """Return ('list',) or ('call', tool, verb, argv); raise Refuse."""
        try:
            req = json.loads(line.decode("utf-8"))
        except Exception:
            raise Refuse("bad-argument")
        if not isinstance(req, dict):
            raise Refuse("bad-argument")
        # One kind for every unknown/ill-shaped top-level field: bad-argument.
        if "list" in req:
            if set(req) != {"v", "list"} or req["list"] is not True:
                raise Refuse("bad-argument")
        elif not set(req) <= {"v", "tool", "verb", "args"}:
            raise Refuse("bad-argument")
        if type(req.get("v")) is not int or req["v"] != 1:
            raise Refuse("bad-argument")
        if "list" in req:
            return ("list",)
        tool, verb = req.get("tool"), req.get("verb")
        if not isinstance(tool, str) or not isinstance(verb, str):
            raise Refuse("bad-argument")  # malformed: missing or wrong type
        if tool not in self.tools:
            raise Refuse("no-such-tool")
        verbs = self.tools[tool]["verbs"]
        if verb not in verbs:
            raise Refuse("no-such-verb")
        spec = verbs[verb]
        args = req.get("args", {})
        if not isinstance(args, dict):
            raise Refuse("bad-argument")
        values = {}
        for name, sp in spec["slots"].items():
            # Order: take the supplied value, else fill the declared default,
            # else missing -> bad-argument; then validate whichever value we
            # hold through the same rules (a default is never trusted).
            if name in args:
                val = args[name]
            elif "default" in sp:
                val = sp["default"]
            else:
                raise Refuse("bad-argument", name)
            try:
                check_slot(name, sp, val, self.regexes.get((tool, verb, name)))
            except Refuse:
                raise
            except Exception:
                raise Refuse("bad-argument", name)
            values[name] = val
        for name in args:
            if name not in spec["slots"]:
                raise Refuse("bad-argument", "unknown")  # never echo agent text
        argv = []
        for el in spec["argv"]:
            m = re.fullmatch(r"\{(.+)\}", el)
            if m and m.group(1) in values:
                v = values[m.group(1)]
                argv.append(str(v) if type(v) is int else v)
            else:
                argv.append(el)
        return ("call", tool, verb, argv, int(spec["timeout"]))

    # -- execution --
    def kill_group(self, proc):
        for sig, wait in ((signal.SIGTERM, KILL_GRACE), (signal.SIGKILL, 0)):
            try:
                os.killpg(proc.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
            end = time.monotonic() + wait
            while wait and proc.poll() is None and time.monotonic() < end:
                time.sleep(0.02)
        try:
            proc.wait(timeout=2)
        except Exception:
            pass

    def run(self, argv, timeout):
        """Return (reply_dict, nbytes, outcome)."""
        try:
            cdir = tempfile.mkdtemp(prefix="c", dir=self.calls_dir)
        except OSError:
            log("calldir-failed")
            return err_reply("unavailable"), 0, "unavailable"
        proc = None
        try:
            env = {"PATH": PATH_CONSTANT, "HOME": cdir, "LANG": self.lang}
            # Stop check and spawn share the lock: once SIGTERM has set the flag
            # nothing new starts, and teardown sees everything that did.
            with self.lock:
                if self.stop.is_set():
                    return err_reply("unavailable"), 0, "unavailable"
                try:
                    proc = subprocess.Popen(
                        argv, shell=False, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                        stderr=LOG_FD, start_new_session=True, cwd=cdir, env=env)
                except OSError:
                    return err_reply("unavailable"), 0, "unavailable"
                self.procs.add(proc)
            fd = proc.stdout.fileno()
            deadline = time.monotonic() + timeout
            data = bytearray()
            outcome = None
            while outcome is None:
                left = deadline - time.monotonic()
                if left <= 0:
                    outcome = "timeout"
                    break
                r, _, _ = select.select([fd], [], [], min(left, 0.1))
                if r:
                    chunk = os.read(fd, 65536)
                    if not chunk:
                        outcome = "eof"
                        break
                    data += chunk
                    if len(data) > LINE_CAP:
                        outcome = "big"
                        break
                elif proc.poll() is not None:
                    # exited; a grandchild may still hold the pipe: drain what is there
                    while select.select([fd], [], [], 0)[0]:
                        chunk = os.read(fd, 65536)
                        if not chunk:
                            break
                        data += chunk
                        if len(data) > LINE_CAP:
                            break
                    outcome = "big" if len(data) > LINE_CAP else "eof"
            if outcome in ("timeout", "big"):
                self.kill_group(proc)
                return err_reply("timeout" if outcome == "timeout" else "reply-too-large"), len(data), outcome
            # stdout finished: reap, then clear any stragglers left in the group
            try:
                rc = proc.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                self.kill_group(proc)
                return err_reply("timeout"), len(data), "timeout"
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            if rc != 0:
                return err_reply("tool-failed", rc), len(data), "tool-failed"
            reply = {"ok": True, "result": bytes(data).decode("utf-8", "replace")}
            if len(encode(reply)) - 1 > LINE_CAP:
                return err_reply("reply-too-large"), len(data), "reply-too-large"
            return reply, len(data), "ok"
        finally:
            if proc is not None:
                with self.lock:
                    self.procs.discard(proc)
                try:
                    proc.stdout.close()
                except Exception:
                    pass
            rmtree(cdir)

    # -- connections --
    def send_and_close(self, conn, reply, drain=True):
        try:
            conn.settimeout(10)
            conn.sendall(encode(reply))
            if drain:
                conn.shutdown(socket.SHUT_WR)
                conn.settimeout(0.5)
                got = 0
                while got < (1 << 20):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    got += len(chunk)
        except Exception:
            pass

    def handle(self, conn):
        t0 = time.monotonic()
        tool = verb = "-"
        outcome, nbytes = "closed", 0
        held = True
        try:
            try:
                kind, line = self.read_line(conn)
                if kind == "closed":
                    return
                if kind == "big":
                    outcome = "request-too-large"
                    self.send_and_close(conn, err_reply("request-too-large"))
                    return
                nbytes = len(line)
                try:
                    parsed = self.parse(line)
                    if parsed[0] == "list":
                        outcome = "list"
                        self.send_and_close(conn, self.list_reply(), drain=False)
                        self.sem.release()  # freed the instant the list reply is written
                        held = False
                        return
                    _, tool, verb, argv, timeout = parsed
                except Refuse as r:
                    outcome = r.kind
                    self.send_and_close(conn, err_reply(r.kind, r.detail))
                    return
                except Exception:
                    outcome = "bad-argument"
                    self.send_and_close(conn, err_reply("bad-argument"))
                    return
                reply, nbytes, outcome = self.run(argv, timeout)
                self.send_and_close(conn, reply, drain=False)
            finally:
                try:
                    conn.close()
                except Exception:
                    pass
        except Exception:
            outcome = "internal"
            log("handler-exception")
        finally:
            if held:
                self.sem.release()
            if outcome != "closed":
                log("tool=%s verb=%s outcome=%s ms=%d bytes=%d" % (
                    tool, verb, outcome, int((time.monotonic() - t0) * 1000), nbytes))
            with self.lock:
                self.threads.discard(threading.current_thread())

    def busy_inline(self, conn):
        """Write busy on the accept path (one tiny line, never blocks), then hand
        the connection to a short-lived thread that drains the peer to EOF so a
        request landing after the reply cannot turn the close into a reset."""
        try:
            conn.settimeout(1)
            conn.sendall(encode(err_reply("busy")))
            conn.shutdown(socket.SHUT_WR)
        except Exception:
            try:
                conn.close()
            except Exception:
                pass
            return
        try:
            threading.Thread(target=self.drain_close, args=(conn,), daemon=True).start()
        except RuntimeError:
            # Thread exhaustion must never take the line down: the busy
            # reply is already written; drop the connection instead.
            try:
                conn.close()
            except Exception:
                pass

    def drain_close(self, conn):
        try:
            end = time.monotonic() + BUSY_DRAIN
            got = 0
            while got < (1 << 20):
                left = end - time.monotonic()
                if left <= 0:
                    break
                conn.settimeout(left)
                chunk = conn.recv(65536)
                if not chunk:
                    break
                got += len(chunk)
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def serve(self, srv):
        srv.settimeout(0.2)
        while not self.stop.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.stop.is_set():
                    break
                continue
            if self.sem.acquire(blocking=False):
                t = threading.Thread(target=self.handle, args=(conn,), daemon=True)
                with self.lock:
                    self.threads.add(t)
                t.start()
            else:
                self.busy_inline(conn)

    def teardown(self):
        # In-flight commands get TERM_GRACE; nothing new can start (see run()).
        end = time.monotonic() + TERM_GRACE
        while time.monotonic() < end:
            with self.lock:
                if not self.procs:
                    break
            time.sleep(0.05)
        with self.lock:
            left = list(self.procs)
        for p in left:
            self.kill_group(p)
        # Join the handlers (bounded) so each removes its own call directory,
        # then sweep any group that still stands.
        end = time.monotonic() + 3
        while time.monotonic() < end:
            with self.lock:
                if not self.threads:
                    break
            time.sleep(0.05)
        with self.lock:
            left = list(self.procs)
        for p in left:
            self.kill_group(p)


def rmtree(path):
    def onerr(func, p, exc):
        try:
            os.chmod(os.path.dirname(p), stat.S_IRWXU)
            os.chmod(p, stat.S_IRWXU)
        except OSError:
            pass
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=onerr)
    else:
        shutil.rmtree(path, onerror=onerr)
    if os.path.lexists(path):
        shutil.rmtree(path, ignore_errors=True)


def load_decl(path):
    with open(path, "rb") as fh:
        decl = json.loads(fh.read().decode("utf-8"))
    if not isinstance(decl, dict) or decl.get("v") != 1 or not isinstance(decl.get("tools"), dict):
        raise ValueError("declaration shape")
    regexes = {}
    for tool, tv in decl["tools"].items():
        for verb, v in tv["verbs"].items():
            for slot, sp in v["slots"].items():
                if sp["type"] == "string":
                    sp.setdefault("allow_dash", False)
                    sp.setdefault("allow_slash", False)
                    sp.setdefault("max", 4096)
                    if "regex" in sp:
                        regexes[(tool, verb, slot)] = re.compile(sp["regex"])  # fail closed
            int(v["timeout"])
            if not all(isinstance(a, str) for a in v["argv"]):
                raise ValueError("argv")
    return decl, regexes


def environment_clean(clean):
    """True when the launch environment is exactly `clean`.

    LC_CTYPE is left out of the os.environ comparison: Python's own locale
    coercion (PEP 538) adds it at startup, even under -I, and setenv() after
    exec does not touch the kernel-visible block. On Linux that block
    (/proc/self/environ) is the authoritative check: its entries must be
    exactly PATH, HOME, LANG with the expected values (an entry without '='
    cannot match). Without /proc only the os.environ comparison applies.
    """
    if {k: v for k, v in os.environ.items() if k != "LC_CTYPE"} != clean:
        return False
    try:
        with open("/proc/self/environ", "rb") as fh:
            raw = fh.read()
    except OSError:
        return True
    entries = sorted(e for e in raw.split(b"\0") if e)
    want = sorted(("%s=%s" % kv).encode("utf-8", "surrogateescape") for kv in clean.items())
    return entries == want


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--decl", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--pid", required=True)
    ap.add_argument("--cwd", required=True)
    ap.add_argument("--bound", type=int, default=4)
    ap.add_argument("--_reexeced", action="store_true", help=argparse.SUPPRESS)
    a = ap.parse_args()
    sock_path, decl_path, log_path, pid_path, state = (
        os.path.abspath(p) for p in (a.socket, a.decl, a.log, a.pid, a.cwd))

    if os.geteuid() == 0:
        sys.stderr.write("host-tool gatekeeper: refusing to run as uid 0\n")
        return 2
    # os.environ.clear() leaves the kernel-visible environ block (/proc/<pid>/environ,
    # readable by any same-uid tool) as launched. Unless the launch environment is
    # already exactly the three variables, build that dict from scratch and exec into it.
    lang = os.environ.get("LANG") or "C.UTF-8"
    clean = {"PATH": PATH_CONSTANT, "LANG": lang, "HOME": state}
    if not environment_clean(clean):
        if a._reexeced:
            sys.stderr.write("host-tool gatekeeper: environment not clean after re-exec; refusing\n")
            return 1
        try:
            os.execve(sys.executable, [sys.executable, "-I", os.path.abspath(__file__)] + sys.argv[1:] + ["--_reexeced"], clean)
        except OSError:
            sys.stderr.write("host-tool gatekeeper: cannot re-exec; refusing\n")
            return 1
    try:
        os.setsid()
    except OSError:
        pass  # already a session leader
    os.chdir(state)

    global LOG_FD
    LOG_FD = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    dn = os.open(os.devnull, os.O_RDONLY)
    os.dup2(dn, 0)
    os.dup2(LOG_FD, 1)
    os.dup2(LOG_FD, 2)
    os.close(dn)

    if os.path.lexists(sock_path):
        log("start refused: socket path exists")
        return 1
    try:
        decl, regexes = load_decl(decl_path)
    except Exception:
        log("start refused: declaration unusable (shape or regex)")
        return 1
    if a.bound < 1:
        log("start refused: bound")
        return 1
    try:
        os.makedirs(os.path.join(state, "calls"), mode=0o700, exist_ok=True)
        old = os.umask(0o177)
        try:
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(sock_path)
        finally:
            os.umask(old)
        srv.listen(LISTEN_BACKLOG)
        gk = Gatekeeper(decl, regexes, state, a.bound, lang)
        signal.signal(signal.SIGTERM, lambda *_: gk.stop.set())
        signal.signal(signal.SIGINT, lambda *_: gk.stop.set())
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        old = os.umask(0o177)
        try:
            with open(pid_path, "w") as fh:
                fh.write("%d\n" % os.getpid())
        finally:
            os.umask(old)
    except Exception:
        log("start failed")
        return 1
    log("serving")
    try:
        gk.serve(srv)
    finally:
        try:
            srv.close()
        except Exception:
            pass
        for p in (sock_path,):
            try:
                os.unlink(p)
            except OSError:
                pass
        gk.teardown()
        for entry in os.listdir(gk.calls_dir):
            rmtree(os.path.join(gk.calls_dir, entry))
        try:
            os.unlink(pid_path)
        except OSError:
            pass
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
