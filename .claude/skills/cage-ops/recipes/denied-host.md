# Recipe: a request from the cage is blocked

The agent says `pip install` fails, or `git push` cannot reach the forge, or a
fetch gets connection refused. The cage is default-deny: only the hosts in its
config's `network.allow` leave it. This is the loop from "blocked" back to
"working", on the HOST.

---

## 1. Name the host

```bash
rc doctor <cage>
```

Read the egress posture line. When a DNS-stage denial has been logged it prints,
per host:

```
<host> (add "<host>:tcp:443" under network.allow)  [config: <path> — then: rc up --replace]
```

That is the hostname, the exact line, and the file. You do not have to guess any
of the three.

The same information, one step earlier, straight from the cage's own log:

```bash
msb logs <cage> --source system --json | grep 'denied by network policy'
```

Each match reads `DNS query denied by network policy domain=<host>`.

**If `rc doctor` says `none observed`,** it means no DNS-stage denial was
logged — not that nothing was blocked. Two denials leave no trace at all:

- a connection to a literal **IP address** (fails at TCP connect, silently)
- a **port** that is not allowed on a host that is (same, silently)

In that case go to step 1b.

---

## 1b. When nothing was logged

Ask the agent — or the failing command — what it was actually reaching:

```bash
msb exec <cage> -- sh -c 'getent hosts <host>'   # resolves? then DNS is allowed
msb exec <cage> -- sh -c 'curl -sS -m 5 https://<host>/ -o /dev/null -w "%{http_code}\n"'
```

- **Name does not resolve** → the host is not on the allowlist. Add it.
- **Name resolves, connect fails immediately** → the host IS allowed but the
  PORT is not. Check the entry: `"<host>:tcp:443"` allows 443 and nothing else.
- **It hangs rather than failing fast** → suspect an msb older than 0.6.10,
  which fake-accepted a denied connect. Check `msb --version`.

---

## 2. Add the line

Edit the config file `rc doctor` named. Under `network:` → `allow:`:

```yaml
    - "<host>:tcp:443"
```

Three things go wrong here:

- **A bare `<host>`** opens every port on it. Name the port.
- **`<host>:443`** without the protocol is rejected when the cage is created.
- **Adding a `udp:53` rule** to fix a name that will not resolve does nothing.
  The DNS forwarder gates on this same list; allowing the host IS allowing its
  lookup.

Writing this file is the **cage-config** skill; its
`references/allowlist.md` covers the per-host rationale and the index-host /
content-host trap (PyPI, crates.io and GitHub each need two names).

*Done when:* the file contains the line and nothing else changed.

---

## 3. Recreate

```bash
rc up --replace <project>
```

This is a **cold recreate**, not a hot reload: msb has no live-mutation path
for network rules, so the cage is gracefully stopped, removed, and recreated
against the now-current config.

**What survives:** the workspace, the Claude session (via the
`~/.claude/projects` and `~/.claude/sessions` mounts), and the named volumes.
**What is lost:** the guest's own scratch — anything installed at runtime that
was not baked into the image and not on a mount.

*Done when:* `msb list` shows the cage running again.

---

## 4. Retry, and report what you actually saw

Re-run the thing that failed:

```bash
msb exec <cage> -- pip download --no-deps -d /tmp/probe <package>
```

*Done when:* it succeeds. Report that output — not "it should work now". A
config edit plus a recreate is not evidence that the specific failure is gone.

If it still fails, go back to step 1: a second host is common. `pip` needs both
`pypi.org` and `files.pythonhosted.org`; `cargo` needs `crates.io` and
`static.crates.io`; a GitHub release needs `github.com` plus
`objects.githubusercontent.com`. An index and its content are two hostnames.

---

## If you are inside the cage

You cannot do any of the above. The config is read-only to you, deliberately —
a caged agent that could add its own allowlist entry would make the allowlist
decorative.

Say this and wait:

> `<host>` is denied. Please add `"<host>:tcp:443"` under `network.allow` in the
> cage config, then `rc up --replace`.

Keep working on anything that does not need that host. Do not edit any config
file you can see from inside.
