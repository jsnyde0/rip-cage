# Network egress allowlist (msb)

> **Retired ([ADR-029](../decisions/ADR-029-msb-migration.md) D2/D4):** this page used to describe an in-cage engine — a pure SNI destination router, a DNS resolver sidecar, iptables REDIRECT rules, and an observe→promote→block workflow driven by JSONL traffic logs (`rip_cage_router.py`, `rip_cage_egress.py`, `rip_cage_dns.py`, `init-firewall.sh`). **That engine is deleted, not ported.** Egress control is now an msb host-side runtime primitive rip-cage *declares against*, not a process it runs. This page describes the current, msb-based behavior.

Cages run on microsandbox (msb, libkrun microVMs). Every cage boots with `--net-default deny` plus one `--net-rule allow@<host>` per entry in the effective `network.allowed_hosts` — generated straight from `.rip-cage.yaml` by `cli/lib/msb_flags.sh`. A host not on the allowlist is unreachable: msb **fake-accepts** the TCP connect (the `connect()` call succeeds, but zero application bytes ever flow), and a denied DNS query is refused and logged at the trace level. There is no content-layer (method/path) policy or credential injection built in — that remains a composed-mediator concern (see [composition-seam.md](composition-seam.md)).

---

## There is no observe mode

msb logs nothing for *allowed* flows — only denials. Rebuilding an "observe everything, then promote" workflow on top of that would mean rebuilding the deleted in-cage engine, so it isn't done. Instead:

1. **A curated default allowlist** ships in the auto-seeded global config (`~/.config/rip-cage/config.yaml`, written on first `rc up`), so a fresh cage isn't denial whack-a-mole for the hosts every Claude Code turn needs: `api.anthropic.com` (hard requirement), `mcp-proxy.anthropic.com`, `http-intake.logs.us5.datadoghq.com` (both attempted-but-nonblocking, included for denial-log-noise-free defaults).
2. **A fast deny→fix→reload repair loop** replaces observe→promote→block for everything else (below).

**`github.com` (or any other git host) is NOT in the curated seed.** Add it explicitly — see the worked example below.

---

## The deny→fix→reload repair loop

**1. The agent hits a denied host.** A request against a host not on `network.allowed_hosts` hangs or returns nothing meaningful (fake-accepted connect, zero bytes) — from inside the cage this looks like a network outage, not a clean 403.

**2. Find out what was denied.** Two surfaces mine the sandbox's trace-level log for `DNS query denied by network policy domain=<X>` lines and turn them into a fix-hint (`_msb_denied_domains_from_trace_log`, `cli/lib/msb_runtime.sh` — only DNS-stage denials are covered; a right-domain-wrong-port TCP-connect denial logs nothing at any verbosity, a documented msb-side gap):

```bash
$ rc doctor my-cage
...
Live probes:
  posture        : OK — net-default=deny, 3 allow-rule(s); recently denied: files.example-cdn.net

$ rc reload my-cage --dry-run
Fix-hint: recently denied domain(s) on my-cage (not necessarily related to this diff):
    domain=files.example-cdn.net
(--dry-run: snapshot NOT updated, cage NOT recreated.)
```

**3. Add the host.** Either edit `.rip-cage.yaml` directly and add to `network.allowed_hosts`, or use the host-only helper:

```bash
rc allowlist add files.example-cdn.net --cage my-cage
```

**4. Apply it.** `rc allowlist add --cage` runs `rc reload` for you; if you hand-edited the file, run it yourself:

```bash
rc reload my-cage
```

**`rc reload` is a COLD-RECREATE, not a hot-reload** (`rip-cage-rj68`, [ADR-029](../decisions/ADR-029-msb-migration.md) D4). msb's `--net-rule`/`--net-default` have no live-mutation path on a running sandbox (`msb modify` carries no network parameter — confirmed live, `docs/2026-07-09-msb-spike-egress-observability.md` Q1), so `rc reload` runs **graceful stop → remove → the same create pipeline `cmd_up` uses**, against the now-current `.rip-cage.yaml`:

- **Survives the recreate:** everything host-mounted or volume-backed — the workspace, `~/.claude/{projects,sessions}` (your Claude session **resumes**, it is not lost), pi's `auth.json`, and the named volumes (`rc-state-*`, `rc-history-*`, `rc-mise-cache`).
- **Lost:** only the guest's own ephemeral rootfs overlay — state an in-cage process wrote that was never baked into the image or captured by a mount (e.g. an ad-hoc `apt-get install` at runtime). A narrow, documented tradeoff, not a session-continuity loss.

**5. Retry.** The multiplexer/cockpit state re-registers automatically on every resume (every resume is a fresh kernel boot under msb).

---

## Worked example: a project that pushes to GitHub over HTTPS

Reachability and credential injection are **two separate declarations** — a host must be on `network.allowed_hosts` (or the connection is denied before any secret is ever considered), and a credential binding is needed for msb `--secret` to inject the real token on the wire:

```yaml
# <project>/.rip-cage.yaml
version: 1
network:
  allowed_hosts:
    - github.com
auth:
  credentials:
    - source_env: GH_TOKEN     # a host env var holding a scoped GitHub PAT
      hosts: [github.com]
```

```bash
export GH_TOKEN=ghp_your_scoped_token_here
rc up ~/code/my-project
```

Inside the cage, `git push` authenticates as `https://x-access-token:$GH_TOKEN@github.com/...` — the guest holds only a synthesized placeholder; msb injects the real token on the wire toward `github.com` only ([ADR-029](../decisions/ADR-029-msb-migration.md) D3/D5). `source_env` must be set and non-empty in the **host** environment at every `rc up`/`resume`/`reload` (msb re-resolves `--secret` from host env at every boot); an unset or empty var fails loud, naming the var, before any sandbox is created.

There is no ssh cluster to configure — ADR-017/018/020/022's mechanisms, `block-ssh-bypass.sh`, and `examples/ssh-bypass/` are all retired/deleted. See [auth.md](auth.md) for Claude/pi's own OAuth credential mounting (a separate, unrelated concern from git host tokens).

---

## `rc allowlist` command reference

| Command | Effect |
|---|---|
| `rc allowlist add <host> [--cage=<name>]` | Append `<host>` to `network.allowed_hosts` in `.rip-cage.yaml` (idempotent — skips if already present). With `--cage`, runs `rc reload <name>` to apply (cold-recreate). Supports `--output json`. Host-only. |
| `rc allowlist show [--effective]` | Default: list configured `network.allowed_hosts`. `--effective`: merged allowlist with provenance (ADR-021 D4). Read-only; works inside the cage too. |
| `rc allowlist show --observed` / `rc allowlist promote --from-observed` | **Legacy, non-functional under msb.** These pre-cutover subcommands read `.rip-cage/egress.log` / `.rip-cage/egress-dns.log` — JSONL files the now-deleted in-cage router/DNS-sidecar used to write. Nothing writes those files anymore, so `--observed` always reports empty and `promote --from-observed` always has nothing to promote. The code paths still exist (`cli/allowlist.sh`) but are dead under the current runtime; use the `rc doctor` / `rc reload --dry-run` trace-log fix-hint instead (see the repair loop above). Flagged as a follow-up finding, not fixed here (docs-only sweep; see the bead notes). |

```bash
# Add one host and apply it live (cold-recreate)
rc allowlist add api.deepseek.com --cage my-cage

# Inspect configured vs. effective (curated-seed + user) allowlist
rc allowlist show
rc allowlist show --effective
```

`--cage` resolves the workspace (and its log paths) from the container; without it, the commands operate on `.rip-cage.yaml` under the current directory.

---

## `network.mode` — vestigial

`network.mode` (`observe`/`block`) is retained in the config schema for `.rip-cage.yaml` parse-compatibility with pre-cutover files and is still shown by `rc ls`/`rc allowlist show`, but **no msb-flags-generation code path reads it**. Enforcement is always default-deny + `network.allowed_hosts`, regardless of this field's value. Setting it or leaving it unset changes nothing about what the cage can reach.

---

## The IOC floor

A curated denylist of known exfil sinks is enforced by the msb-runtime floor (re-homed from the deleted in-cage IOC check, [ADR-029](../decisions/ADR-029-msb-migration.md) D2) and **cannot be overridden** by `network.allowed_hosts`. The project allowlist can broaden but never shrink below this floor.

---

## Diagnosing

- **`rc doctor <cage>`** reports the declared network policy (default action + rule count, read from `msb inspect`) and any recently denied domains mined from the trace log — a **declaration** read plus a **recent-denial** signal, not a live enforcement re-proof. Effect-based enforcement is what the msb-side test suite (`tests/test-msb-*-effect-probes.sh`) proves.
- **`rc reload <cage> --dry-run`** shows the same denied-domain fix-hint and the pending config diff without applying anything.

---

## See also

- [ADR-029](../decisions/ADR-029-msb-migration.md) D2/D4 — full design rationale for the msb-runtime egress model and the deny→fix→reload repair loop
- [config.md → `network.*`](config.md#network----msb-egress-allowlist) — the config schema
- [CLI reference → `rc allowlist`](cli-reference.md#rc-allowlist----egress-allowlist) — command summary
- [composition-seam.md](composition-seam.md) — opt-in composed mediators for L7 content policy / credential injection beyond `--secret` (compose-only, never rc-launched)
- [auth.md](auth.md) — Claude/pi's own OAuth credential mounting (separate from git host tokens)
