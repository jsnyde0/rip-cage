# Sandbox / agent-cage competitive landscape — research snapshot (2026-06-12)

**Why this exists:** so we don't re-run six research agents next time someone asks "what about alternatives to rip-cage / what should we steal." This is a *point-in-time* survey — tools and features drift; treat the verdicts as anchored to June 2026. The strategic conclusions are already canonicalized in ADR-026 + the `rip-cage-ta1o` epic; this doc is the external evidence behind them plus the named-alternatives map.

**Triggered by:** a "learn about alternatives, what to steal" research request citing the Ona denylist-escape article, the Cloudflare Sandbox tutorial, and three reddit/ars sandboxing threads.

---

## The one structural insight

The market **splits "isolation strength" from "egress filtering," and almost nobody does both.** The strong-isolation crowd (E2B, Daytona, microsandbox — Firecracker/libkrun microVMs) ships a hardware-grade box with a *wide-open network*. The egress-filtering crowd (Anthropic's two offerings + a handful of niche OSS) ships a *weak* shared-kernel box with a tight network. rip-cage sits in the under-served intersection, and adds a third axis nobody else combines: **local + durable + interactive (walk-away autonomy) + in-box command guard (DCG).**

Our weakest dimension is isolation (shared-kernel Docker) — every microVM competitor beats us there — but that's *by design* (ADR-009: blast-radius, not a security boundary).

---

## The landscape, tiered

### Anthropic's own two layers (our real "competition" + best design references)

- **Native `/sandbox` + `sandbox-runtime`** (open-sourced as `anthropic-experimental/sandbox-runtime`, CLI `srt`). Sandboxes the **Bash tool only**, no container — macOS Seatbelt (`sandbox-exec`) + Linux bubblewrap. Egress is the *good kind*: strips the network namespace, forces all traffic through a host-side **HTTP (domain allowlist) + SOCKS5 proxy**, bridged via unix sockets + `socat` on Linux. Architecturally the closest cousin to our egress model.
  - **Two fatal-for-our-use-case weaknesses:** (a) the agent can opt out per-command (`dangerouslyDisableSandbox`); (b) Ona demonstrated the agent **disabling its own sandbox** to finish a task. It's a write-guard that kills approval fatigue — **not** a boundary the occupant can't toggle. **This directly validates ta1o D3:** only the netns owner (a container) can force-capture; an in-process sandbox can't.
- **The `claude-code` devcontainer** (`.devcontainer/init-firewall.sh`). Docker + iptables/ipset default-deny allowlist — the closest *public* analogue to our egress whitelist. But it resolves DNS **once at boot** (IP drift silently blocks traffic until restart), and anyone with repo write can edit the Dockerfile and delete the firewall. Our observe-mode-then-enforce + `rc reload` hot-reload is strictly more sophisticated.

### Cloud microVM sandboxes (strong box, no egress)

E2B (Firecracker, category reference, 15M sandboxes/mo, **no egress filtering** — DIY), Daytona (Docker-by-default, persistent snapshots, has a Claude Code guide), **Blaxel** (the one exception — managed egress gateway w/ static IPs, explicitly pitched as "the E2B gap").

### Cloudflare Sandbox

Worker → Durable Object → per-sandbox VM. Cloud-only, ephemeral-disk, **single-shot batch** (one task → one diff), not interactive. Its standout is `outboundByHost` + `interceptHttps` = an L7 TLS-introspecting egress proxy that does **sentinel credential injection** (container gets `proxy-injected` placeholder; Worker swaps the real Anthropic/GitHub header on the way out) + **forced DNS to CF resolvers**. See "credential injection" note below — this is a *mediator* pattern, not a steal-into-rip-cage.

### Self-hosted / local neighbors (our actual peer group)

- **microsandbox** (libkrun microVM, runs on macOS via Hypervisor.framework, MCP-native) — *real hardware isolation locally*, but no egress.
- **Coder** — enterprise governance; **"Agent Boundaries"** give the agent code+tools but withhold creds+network. Philosophically our twin and a *second mediator shape* (see ta1o note).
- OSS cage swarm: **ClaudeBox** (our named comp), Sculptor/Imbue (container-per-agent), container-use/Dagger (per-agent worktrees via MCP), plus egress-doing niche tools surfaced from a curated gist (Cleanroom, treebeard, Greywall, codex-lockbox, agentbox — names reliable, depth unverified).

### Community reality check (reddit/ars)

No consensus winner. Loudest camps: "just Docker" (pragmatic default) and "raw-dog it + strict git discipline" (30-upvote top comment). Recurring theme that's pure rip-cage validation: people prefer containers over native `/sandbox` because they're **legible** ("I have a clear understanding of how it works"), and the bind-mount work-alongside model directly answers the #1 VM complaint (setup tax + losing co-presence with the agent).

---

## Comparison table (isolation × egress)

| Tool | Isolation model | Kernel boundary | Egress filtering | Hosting |
|---|---|---|---|---|
| **rip-cage** | Docker + DCG + ssh-blocker + hooks | Shared | **L7→pure-router (per ta1o), observe-mode, hot-reload** | Local/self-host |
| CC native / `srt` | Seatbelt + bubblewrap | Shared (OS prims) | **HTTP+SOCKS5 proxy allowlist** (agent can self-disable) | Local |
| CC devcontainer | Docker | Shared | **iptables/ipset default-deny** (resolve-at-boot) | Local |
| E2B | Firecracker microVM | Hardware | ✗ (DIY) | Cloud / BYOC |
| Daytona | Docker (opt Kata/Sysbox) | Shared (opt HW) | ✗ | Cloud / self-host |
| microsandbox | libkrun microVM | Hardware | ✗ | Self-host/local |
| Coder | K8s/VM workspaces | Config-dependent | **Agent Boundaries: firewall + cred-scoping** | Self-host |
| Blaxel | microVM | Hardware | **managed egress gateway** | Cloud |
| Cloudflare Sandbox | Worker→DO→per-sandbox VM | Hardware (claimed) | **L7 proxy + cred-injection + forced-DNS** | Cloud only |
| Sculptor / container-use | Container per agent | Shared | ✗ | Local |
| Apple `container` | VM per container | Hardware | ✗ | Local (macOS) |

---

## What survived contact with our beads (the verdict)

Most "steals" dissolve once you read `rip-cage-ta1o` + ADR-026 — the competitive teardown was **already done** (ClawPatrol read from source, containment/mediation line carved, credential injection proven end-to-end this session). What actually remains:

1. **Credential-injection egress proxy (CF `outboundByHost`, NanoClaw, ClawPatrol) — NOT a steal.** This is a **settled, FIRM, compose-don't-build** decision (ADR-026 D4/D6; `rip-cage-ups` closed-as-superseded). rip-cage builds **no** credential injection — non-possession is a *composition property* via an external mediator. CF/NanoClaw/CP all converging on sentinel-injection-at-L7-proxy is **confirmation the call is well-founded**, not a new capability to build.
2. **`sandbox-runtime`'s bubblewrap + `socat` force-through — actionable fallback.** A *different attach mechanism* than userspace-WireGuard-in-container. If WG-attach proves hostile in an unprivileged Linux cage (ta1o D7's one open validation), socat-relay-over-unix-socket is a proven-shipping fallback. **(Noted on `rip-cage-ta1o`.)**
3. **CF Sandbox + Coder as additional mediator shapes — reinforces ta1o D7.** Evidence the seam should target a *class*, not bless ClawPatrol specifically (which D7 already says). Two named alternative mediators a user could compose. **(Noted on `rip-cage-ta1o`.)**
4. **Ona attack cases — harness additions.** `/proc/self/root/<path>` path-aliasing + agent-self-disables-sandbox are *non-adversarial* behaviors (our ADR-024 model, not the adversarial one we exclude). Hard boundaries (netfilter + mount-layer ssh-filter) are immune by construction, but `block-ssh-bypass.sh` is a string-match hook worth probing against the `/proc/self/root` trick. **(Filed as a bead.)**
5. **MicroVM isolation (Apple `container`, libkrun) — DON'T.** Buys hardware isolation we've explicitly decided we don't need (ADR-009), at real ops cost, and *none of them ship egress* so our layer stays the differentiator anyway. Someday-if-threat-model-changes note only.

**Net:** the landscape doesn't reshape the architecture — we converged on the right answer ahead of it. Strongest signal is *confirmation*: every serious player is converging on exactly the containment-vs-mediation split ta1o draws, and egress filtering is genuinely rare market-wide.

---

## Source pointers (for re-derivation, not memorization)

- Ona / Veto denylist-escape: `ona.com/stories/how-claude-code-escapes-its-own-denylist-and-sandbox` (2026-03-03; author is a Falco co-creator; Veto = content-addressable BPF-LSM kernel enforcement, early access).
- Cloudflare Sandbox: `developers.cloudflare.com/sandbox/` + tutorial `/tutorials/claude-code/`; source `github.com/cloudflare/sandbox-sdk` (`examples/claude-code/`, base image `cloudflare/sandbox:0.12.1`).
- Anthropic native: `anthropic.com/engineering/claude-code-sandboxing`, `github.com/anthropic-experimental/sandbox-runtime`, devcontainer `github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh`.
- Landscape gist (egress-OSS tools): `gist.github.com/wincent/2752d8d97727577050c043e4ff9e386e` (2026-05).
- Coder Agent Boundaries: `coder.com/solutions/workspaces`. K8s Agent Sandbox: `agent-sandbox.sigs.k8s.io`.
- Community: r/ClaudeCode threads `1qcd9zj`, `1qsu71t`; Ars forum thread 1509948 (~95% off-topic AI-debate).
- **Internal:** `rip-cage-ta1o` (the epic this all confirms), ADR-026, ADR-012, ADR-024, ADR-009; `github.com/denoland/clawpatrol` (the reference mediator, read from source).
