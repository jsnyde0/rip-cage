# ADR-018: macOS ssh-agent discovery — probe and forward the user's actual agent

**Status:** Accepted
**Date:** 2026-04-24
**Design:** [Design doc](../../history/2026-04-24-macos-ssh-agent-discovery-design.md)
**Parent:** [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (ssh-agent forwarding default)
**Amends:** [ADR-017](ADR-017-ssh-agent-forwarding-default.md) D4 (cross-platform reachability). D1, D2, D3 carry over unchanged.
**Related:** project [CLAUDE.md](../../CLAUDE.md) philosophy section (autonomy over containment, "it's annoying" as a design signal)

## Context

ADR-017 made ssh-agent forwarding on-by-default and documented a per-platform host prereq in D4. The macOS prescription was: run `ssh-add --apple-use-keychain <key>`, set `UseKeychain yes` / `AddKeysToAgent yes` in `~/.ssh/config`, and the cage's forwarded socket (`/run/host-services/ssh-auth.sock`, proxied by Docker Desktop / OrbStack to the launchd system agent) will find keys via Keychain-backed on-demand loading.

Dogfooding surfaced that this only works for **passphrase-protected** keys. Passphrase-less keys — the common dev-machine default — cannot participate in the Keychain flow because `--apple-use-keychain` has no passphrase to stash. Users doing the documented prereq and seeing working SSH on their host still get `Permission denied (publickey)` inside the cage, because the agent the user populated (their shell session agent at `/var/folders/.../agent.NNNN`) is not the agent the cage forwards (the launchd system agent, which remains empty).

The concrete incident: a `mapular-gtm` session left 12 commits and bead updates stranded locally for ~24 hours because the cage's agent was empty despite `ssh-add -l` on the host showing both keys loaded. The banner pointed at "See ADR-017 D4 for host-side fix," and D4's fix did not address this case. That is a philosophy violation: "it's annoying we can't push" is explicitly a CLAUDE.md design signal that a default is wrong.

## Decisions

### D1: On macOS, probe host-side agent candidates and mount the first populated one

**Firmness: FIRM**

`rc up` on macOS no longer hard-codes the forwarded socket path. It iterates a priority-ordered list of host socket candidates, validates each is bind-mountable on the active Docker backend, runs `ssh-add -l` against each from the host, and bind-mounts the first one that reports ≥1 key to `/ssh-agent.sock` inside the container.

Candidates in order:
1. `$SSH_AUTH_SOCK` (the user's shell/session agent — whatever `ssh-add -l` on host sees)
2. `/run/host-services/ssh-auth.sock` (Docker Desktop / OrbStack convention proxying to the launchd system agent)

Expected winners: OrbStack passes `/var/folders/...` through transparently, so candidate #1 wins there. Docker Desktop requires `/var/folders` to be in the user's file-share config and typically isn't, so candidate #2 wins there via the convention socket. Backend is detected via `docker context inspect`; unknown backends assume mountable and let `docker run` fail loudly if not.

If none report keys, the first *reachable and mountable* candidate is mounted anyway — the in-container preflight still fires its `empty` warning, but now against a specific, named host socket.

An earlier draft included a third candidate (`/private/tmp/com.apple.launchd.*/Listeners`) but it was dropped: glob semantics are ambiguous, the exact socket filename varies by launchd label, and candidate #2 already covers the Keychain-backed launchd flow.

**Rationale:**

The invariant this establishes is "what `ssh-add -l` shows on host is what the cage sees." That collapses the user's mental model from "macOS has two agents, one of which only works for passphrase-protected keys, and the cage listens to that one" down to "the cage forwards your agent." The probe is cheap (≤10s worst case across two timeouts; milliseconds in practice), honest (picks what actually has keys rather than hoping a convention has them), and preserves all existing flows (Keychain-backed setups still win when `$SSH_AUTH_SOCK` isn't set, because they're candidate #2).

Matches the project's 80/20 posture: the common case (passphrase-less keys, session agent populated by shell login) now works without macOS-specific ceremony. The less-common case (Keychain-backed, passphrase-protected) continues to work through the fallback candidate. Nothing about this ADR increases blast radius or changes the threat model — it just picks a better socket.

**Probe must not hang.** `timeout(1)` is not installed by default on macOS. The probe uses the portable bash background-and-kill pattern (same as `_probe_tcp`) to cap each candidate at 5s. When forwarding is disabled (`--no-forward-ssh` or `RIP_CAGE_FORWARD_SSH=off`), the probe is skipped entirely so users who opted out don't pay the 10s worst-case tax.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Probe candidate sockets, mount the first with keys (this decision)** | • Works for passphrase-less keys without ceremony • Unified mental model (host agent == cage agent) • Backward compatible via fallback candidate • Cross-backend (OrbStack/Docker Desktop/Colima) uniform | • Implicit selection — requires logging the chosen socket for debuggability • ~10s worst-case probe time (2 candidates × 5s) • Small new dependency on host-side `ssh-add` execution |
| Require users to set passphrases on all keys | • Preserves current single-path design • Keychain-backed model is technically "better" security posture | • Forces behavior change on thousands of existing dev setups • "It's annoying" signal writ large • Not the cage's job to dictate host key hygiene |
| Switch macOS to always forward `$SSH_AUTH_SOCK` only (drop the launchd path entirely) | • Simplest code • Perfectly matches Linux/WSL2 semantics | • Regresses users who set up the Keychain-agent path from ADR-017 • Docker Desktop historically cannot bind-mount arbitrary macOS socket paths — only OrbStack reliably passes `/var/folders/...` through |
| Spawn a persistent cage-side ssh-agent and have the user load keys into it | • Fully predictable | • Loses "keys stay on host" property — violates ADR-017 rationale • Significant new surface (key mounting, lifecycle) |

**What would invalidate this:**

- Evidence that host-side probing introduces a consistent latency problem at `rc up` (not yet observed; 5s timeout per candidate is a ceiling, not the common path).
- A future shift to bot-identity tokens (deferred option in ADR-014) would make the agent-reachability question moot and this ADR irrelevant.
- OrbStack or Docker Desktop changing their proxy semantics in a way that breaks candidate #2 — would require adjusting the candidate list but not the probe model.

### D2: Docker Desktop / OrbStack convention socket remains a fallback candidate

**Firmness: FIRM**

`/run/host-services/ssh-auth.sock` is retained at priority 2. Users who set up the Keychain-backed flow per ADR-017 D4 (passphrase-protected keys, `UseKeychain yes`) continue to work without changes — their session `$SSH_AUTH_SOCK` may or may not be set, and if unset the probe naturally selects the convention socket, which on macOS is proxied to the launchd agent backed by Keychain.

**Rationale:**

No regression is a hard requirement: ADR-017 D4 has been in force since 2026-04-23 and any working setup must keep working after this ADR lands. The fallback keeps that promise. It also gives us an escape hatch for environments where `$SSH_AUTH_SOCK` points at something the container cannot reach (e.g., a macOS path not in OrbStack's passthrough mounts) — the convention socket is always reachable on both supported backends.

**What would invalidate this:**

- Evidence that no user has adopted the Keychain-agent model since ADR-017 shipped. Then candidate #2 becomes dead surface and can drop.

### D3: Preflight failure messages name the mounted socket and give a one-line fix

**Firmness: FIRM**

A companion sentinel at `/etc/rip-cage/ssh-agent-socket` records the host socket that was actually mounted (single line, empty string if nothing was mounted). The existing status sentinel at `/etc/rip-cage/ssh-agent-status` is unchanged — keeping them in separate files avoids breaking the zshrc `case` matcher, which is already built around single-line sentinels (matching the `host-os` precedent). Banner text and `rc doctor` output read both and incorporate the path into fix hints:

- `empty` → `host agent at <path> is empty — run 'ssh-add ~/.ssh/id_ed25519' on host, then 'rc down && rc up'`
- `unreachable` → `socket <path> mounted but not responding — check that ssh-agent is running on host`

No more pointing at `ADR-017 D4 for host-side fix`. The fix is inline and the reader can copy-paste.

**Rationale:**

ADR-001 (fail-loud) requires not just visibility but actionability. A loud warning that sends the user to read an ADR to recover is a regression from actionable. Naming the mounted socket also makes the probe's choice debuggable — if the wrong socket was picked, the user sees which one and can override via `SSH_AUTH_SOCK=<path> rc up`.

**What would invalidate this:**

- Telemetry that nobody hits `empty`/`unreachable` in practice. Unlikely in the short term; this is a common bootstrapping failure.

### D4: ADR-017 D4's macOS host-prereq table is rewritten, not retired

**Firmness: FLEXIBLE**

ADR-017 D4's table still serves a real purpose — documenting that macOS and Linux have different agent-discovery stories. It is amended (via this ADR's `Amends` link), not superseded. The new macOS row reads: "whatever gives you a populated `$SSH_AUTH_SOCK` on host (typical: `ssh-add ~/.ssh/<key>` in your login shell, or 1Password/Secretive integration, or Keychain-backed launchd agent)." The Keychain-backed setup moves from required prereq to one of several ways to populate the agent.

**Rationale:**

Leave the ADR-017 text in place so readers arriving via git history or old banners see the evolution. Mark this ADR as the current authority via `Amends`. Consistent with how ADR-017 handled ADR-014 — partial supersede, explicit carryover list, no surgery on the old doc's body.

**What would invalidate this:**

- A future ADR that consolidates ADR-017 + ADR-018 into a single document. Worth doing if the amendment trail grows to three+ revisions.

## Related

- [Design doc](../../history/2026-04-24-macos-ssh-agent-discovery-design.md) — implementation details, probe loop, sentinel format
- [ADR-017](ADR-017-ssh-agent-forwarding-default.md) — parent decision (forward-by-default, opt-out semantics, LFS carryover)
- [ADR-001](ADR-001-fail-loud-pattern.md) — upstream principle (loud + actionable failure modes)
- `rc` `_up_ssh_preflight`, `_up_prepare_environment` — touch points for implementation
- `zshrc` ssh-agent-status banner block — consumer of the enriched sentinel
