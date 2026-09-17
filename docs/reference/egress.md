# Network egress

Every cage boots **default-deny**. Nothing leaves it except the hosts its config names.

This is msb's, at the VM boundary — not a process rip-cage runs inside the cage. What rip-cage adds is the repair loop that makes default-deny livable: when something is blocked, `rc doctor` tells you the exact line to add.

## The allowlist

```yaml
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
    - "github.com:tcp:443"
```

`policy: none` **is** msb's deny-everything-not-listed. `rc up` refuses, before any msb call, a config that does not declare it.

**The config's `allow` list is the only source.** The tools manifest used to union its own egress declarations into this set; that union is gone with the manifest ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D4), so what an operator reads in the config is exactly what msb enforces. The curated defaults every coding agent needs ship in the config template rather than being merged in behind your back.

`rc` never emits `--net-default`. That flag **replaces** the allow list a `--conf` file carries, which is how every cage once briefly ended up reaching nothing.

### Name the port

Each entry is `<host>:tcp:<port>`. A **bare host records every port** — narrower is better, and `tcp:443` covers the HTTPS that nearly everything a coding agent does rides on.

The DNS forwarder gates on the same list, so there is no separate `udp:53` rule to add.

## There is no observe mode

msb logs nothing for *allowed* flows — only denials. Rebuilding an observe-everything-then-promote workflow on top of that would mean rebuilding the in-cage engine the msb cutover deleted, so it is not done.

What replaces it is a **curated default list** in the shipped config template (the hosts a basic Claude turn, a git push over HTTPS, and the common package registries need), plus the repair loop below for everything else.

---

## The repair loop: deny → fix → relaunch

### 1. Something is blocked

From inside the cage it looks like the host is down, not like a clean refusal. Measured on msb 0.6.18:

| Denial | Client-side symptom | Logged? |
|---|---|---|
| A denied **domain** | DNS resolution fails — `curl: (6) Could not resolve host` | **Yes**, at trace level |
| A denied **IP** | TCP connect fails within a couple of milliseconds — `curl: (7) Failed to connect` | No, at any verbosity |
| An allowed domain on a **denied port** | Dropped at the NIC; connection refused | No, at any verbosity |

Both failures are immediate, which is a change: msb before 0.6.10 fake-accepted the connect on a full host denial and hung, delivering zero bytes.

### 2. Find out what was denied

`rc doctor` mines the cage's trace log for `DNS query denied by network policy domain=<host>` and turns it into a fix-hint:

```bash
$ rc doctor my-cage
...
Live probes:
  posture : OK — net-default=deny, 12 allow-rule(s); recently denied: files.example-cdn.net
```

**Only DNS-stage denials are mineable**, which is why the hint is DNS-keyed.

### 3. Add the host

Edit the cage config — `~/.config/rip-cage/projects/<cage>.yaml` — and add the line:

```yaml
network:
  allow:
    - "files.example-cdn.net:tcp:443"
```

This is host-side work. It is not reachable from inside the cage, on purpose: a prompt-injected agent must not be able to widen its own egress ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5a). A caged agent that hits this wall surfaces the request in prose and waits.

### 4. Relaunch

```bash
rc up --replace ~/code/my-project
```

**This is a cold recreate, not a hot reload.** msb's net rules have no live-mutation path on a running sandbox — `msb modify` carries no network parameter — so the cage is gracefully stopped, removed, and created again against the now-current config.

- **Survives:** everything host-mounted or volume-backed — the workspace, `~/.claude/{projects,sessions}` (so the Claude session **resumes**), pi's `auth.json`, and the named volumes.
- **Lost:** only the guest's own ephemeral rootfs overlay — an `apt-get install` you ran at runtime and never baked into the image.

A **stopped** cage converges on a plain `rc up`; `--no-reload` resumes it with the old rules instead. A **running** cage never recreates implicitly, because that would kill the live session.

### 5. Retry

Every resume is a fresh kernel boot, so init re-runs and multiplexer state re-registers on its own.

---

## When the fix-hint says nothing

If the failing domain is **already** in `network.allow` and does not appear under "recently denied", the DNS-stage miner saw nothing to mine — the name resolved fine and the drop happened silently at the NIC. **That is the wrong-port signature.**

Check the port on that host's entry. There is no log line to find and no fix-hint to mine for this class; it is an msb-side gap, tracked in `rip-cage-ffmc`.

The old way of telling the two apart is gone. Through msb 0.6.9 a full host denial hung while a wrong-port denial refused instantly, so an instant refusal told you which case you were in. As of 0.6.18 both refuse instantly.

---

## Worked example: pushing to GitHub over HTTPS

Reachability and credential injection are **two separate declarations**. A host must be on the allow list or the connection dies before any secret is considered; a `secrets:` entry is what puts the real token on the wire.

```yaml
# ~/.config/rip-cage/projects/<cage>.yaml
secrets:
  GH_TOKEN:                       # NO value: — msb reads the host env var of this name
    allow:
      - "github.com"

env:
  GH_TOKEN: "$MSB_GH_TOKEN"       # what git sees: the placeholder

network:
  policy: none
  allow:
    - "github.com:tcp:443"
```

```bash
mkdir -p ~/.config/rip-cage/secrets
printf %s 'ghp_your_scoped_token' > ~/.config/rip-cage/secrets/GH_TOKEN
chmod 600 ~/.config/rip-cage/secrets/GH_TOKEN
rc up ~/code/my-project
```

Inside the cage, `git push` authenticates as `https://x-access-token:$GH_TOKEN@github.com/...`. The guest holds only the placeholder; msb substitutes the real token on the wire toward `github.com` and nowhere else ([ADR-029](../decisions/ADR-029-msb-migration.md) D3/D5). A placeholder sent toward any other host is blocked and logged.

**`rc up` fills the host variable for you** from `~/.config/rip-cage/secrets/<NAME>`, so an unattended run needs no pre-export. Without that file, export the variable yourself; msb fails loud naming it before any sandbox is created.

There is no ssh cluster to configure — git goes over HTTPS ([ADR-029](../decisions/ADR-029-msb-migration.md) D3).

---

## What this does not do

msb's netstack allows and denies **by destination host**. It carries no content-layer policy, and the mediator seam that once composed one is deleted, not merely undocumented. You do not get:

- **Request-level policy** — method, path, or body rules; structured per-request refusals.
- **Credential handling beyond a per-host `--secret` binding** — for instance a shared credential needing different treatment per request path.
- **Human-in-the-loop approval**, or full request/response audit logging beyond msb's own denial log.

If you need any of those, it is fully operator-composed and unwired today: there is no archetype, launch hook, or forward-to seam left to attach to. [clawpatrol](https://github.com/denoland/clawpatrol) is an **alternative appliance** — something you run instead of rip-cage's containment, not a composition target.

---

## Diagnosing

- **`rc doctor <cage>`** reads the declared policy from `msb inspect` (default action plus rule count) and reports recently denied domains from the trace log. That is a declaration read plus a recent-denial signal — not a live re-proof that enforcement works.
- **Enforcement itself** is proven by the effect probes, `tests/test-msb-*-effect-probes.sh`, which send real traffic and check what arrives.

## See also

- [config.md](config.md) — the whole config file, field by field
- [secret-posture.md](secret-posture.md) — which credentials are worth the non-possession rework
- [auth.md](auth.md) — Claude and pi's own logins, a separate concern from git host tokens
- [ADR-029](../decisions/ADR-029-msb-migration.md) D2/D4 — the msb egress model and the repair loop it replaced observe mode with
- [ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2/D3 — one config file, and why the old hot-reload verb folded into `rc up --replace`
