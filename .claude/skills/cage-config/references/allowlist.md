# Reference: the egress allowlist

What each entry in `network.allow` is for, why the port is written out, and how
to add a host without guessing.

The shipped list lives in
[`share/rip-cage/cage.yaml.template`](../../../../share/rip-cage/cage.yaml.template)
under `network:`. That file is the source of truth for the current set; this
page is the rationale behind it.

---

## The rule that catches people: name the port

```yaml
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"     # correct
    - "api.anthropic.com"             # opens EVERY port on that host
    - "api.anthropic.com:443"         # REJECTED at create — no protocol
```

Measured on msb 0.6.18:

- `host:tcp:443` — resolves AND connects. This is the form to write.
- a bare `host` — records a rule for all ports. Not what you meant.
- `host:443` (no protocol) — rejected when the cage is created, loudly.

The DNS forwarder gates on this same list. There is no separate `udp:53` rule
to add, and adding one is not how you fix a name that will not resolve.

---

## Why each shipped entry is there

| Entry | Without it |
|---|---|
| `api.anthropic.com` | the agent cannot talk to the model at all — nothing else matters |
| `mcp-proxy.anthropic.com` | MCP servers reached through the proxy fail |
| `http-intake.logs.us5.datadoghq.com` | Claude Code's telemetry endpoint stalls |
| `github.com`, `api.github.com` | `git` over HTTPS and `gh` both fail |
| `objects.githubusercontent.com`, `codeload.github.com` | release assets and tarball fetches fail even though `github.com` resolves |
| `registry.npmjs.org` | `npm install` fails |
| `pypi.org`, `files.pythonhosted.org` | `pip` / `uv` resolve a package and then cannot download it — BOTH are needed |
| `proxy.golang.org` | `go mod download` fails |
| `crates.io`, `static.crates.io` | `cargo` resolves and then cannot fetch — again both |
| `doltremoteapi.dolthub.com` | beads sync fails; drop it if the project does not track work in beads |

The pattern worth internalising: **an index host and a content host are two
different names.** PyPI, crates.io and GitHub each need both, and allowing only
the first produces a confusing half-failure where a tool finds the package and
then hangs or errors on the download.

---

## Adding a host

Do not guess the hostname. When a cage hits a denied host, `rc doctor <cage>`
mines the sandbox's own trace log and prints the exact line to paste, along
with the config file to paste it into. Then recreate:

```bash
rc doctor <cage>                 # prints: <host> (add "<host>:tcp:443" under network.allow)
# edit the config file it named
rc up --replace <project>
```

That loop belongs to the **cage-ops** skill; this page is the file it edits.

---

## What a denial looks like, and what is invisible

- **A denied domain name** fails DNS resolution client-side, immediately. This
  is the case `rc doctor` can see — msb logs a line naming the domain, and that
  is what gets mined into the fix-hint.
- **A denied IP** fails at TCP connect within a couple of milliseconds. **msb
  logs nothing at that stage, at any verbosity.** No fix-hint exists for it.
- **A port-scoped denial on an already-allowed host** is the same invisible
  case: the host is on the list, the port is not, nothing is logged. It
  surfaces client-side as an immediate connection refused. If a host is on the
  list and still fails, check the PORT in the entry before anything else.

(Measured on msb 0.6.18. Older msb versions — before 0.6.10 — fake-accepted the
connect and hung delivering zero bytes, which is a much worse failure. If a
cage hangs rather than failing fast, check the msb version.)

---

## Two things the allowlist is not

1. **It is not a security boundary against a motivated attacker.** It is a
   layer that catches a class of accident — including an agent following
   instructions injected via a fetched page or a workspace file. Over-tightening
   it to defeat an adversary buys little and costs unattended runs.
2. **It is not editable from inside the cage.** The config sits outside every
   cage mount. An agent that needs a host **says so in prose** and waits. A
   caged agent that could add its own allowlist entry would make the list
   decorative.
