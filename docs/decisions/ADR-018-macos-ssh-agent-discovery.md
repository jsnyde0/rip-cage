# ADR-018: macOS ssh-agent discovery — probe and forward the user's actual agent

**Status:** Amended 2026-04-25 (see Amendments)
**Date:** 2026-04-24
**Design:** [Design doc](../../history/2026-04-24-macos-ssh-agent-discovery-design.md)
**Parent:** [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (ssh-agent forwarding default)
**Amends:** [ADR-017](ADR-017-ssh-agent-forwarding-default.md) D4 (cross-platform reachability). D1, D2, D3 carry over unchanged.
**Related:** project [CLAUDE.md](../../CLAUDE.md) philosophy section (autonomy over containment, "it's annoying" as a design signal)

## Amendments

### 2026-04-25 — sudoers grant for `/ssh-agent.sock` chown; macOS "empty" guidance targets launchd

Two coupled bugs surfaced in dogfooding after the 2026-04-24 amendment landed:

**Bug 1 — `unreachable` masquerading for permission-denied.** The OrbStack proxy at `/run/host-services/ssh-auth.sock` exposes the bind-mounted socket inside the container with `uid=<host-uid>:gid=<orbstack-internal-gid>` mode `0660` (e.g. `501:67278` on a typical macOS host). The cage's `agent` user (uid 1000) is neither owner nor group → `Permission denied` on connect → `ssh-add` exits 2 → preflight reports `unreachable`. `init-rip-cage.sh` already attempts `sudo chown agent:agent /ssh-agent.sock` for exactly this reason, but the sudoers NOPASSWD list omitted the command, so the chown silently failed (it ran with `2>/dev/null || true`). The result was a fresh `rc up` on macOS that always reported "socket UNREACHABLE" even when the host agent was alive — and the banner pointed users at "verify ssh-agent on host," which was actively wrong (the host agent was fine; the cage couldn't reach it).

Fix: add `/usr/bin/chown agent\:agent /ssh-agent.sock` to the sudoers grant in the Dockerfile. This is the same pattern as the existing `/home/agent/.claude` and `/home/agent/.claude-state` entries — narrow path, fixed target ownership, idempotent, no escalation surface beyond what the cage already trusts itself with.

**Bug 2 — "empty" guidance pointed at the wrong agent.** Once chown works and the cage reaches the proxy, the next failure mode is the launchd agent itself being empty. The pre-2026-04-25 banner said `Fix: run 'ssh-add ~/.ssh/id_ed25519' on host`. On macOS that adds keys to the user's *session* agent (`/var/folders/.../agent.NNN`), which the cage cannot reach (per the 2026-04-24 amendment, only the launchd path is proxied across the VM boundary). Users following the banner saw their host `ssh-add -l` show keys, but the cage stayed empty.

Fix: when the recorded socket path is `/run/host-services/ssh-auth.sock`, the banner and `rc up` warning surface the launchd-targeted form: `SSH_AUTH_SOCK=$(launchctl getenv SSH_AUTH_SOCK) ssh-add ~/.ssh/id_ed25519`. This populates the agent the proxy actually forwards. Passphrase-less keys work — `--apple-use-keychain` is no longer required (it never was, but the original ADR-017 D4 prereq table implied it).

**Why the 2026-04-24 amendment didn't catch this:** the amendment was correct that only `/run/host-services/ssh-auth.sock` is proxied, but its testing happened against a pre-existing container where the chown had already taken effect at create time *before* the sudoers entry was tightened in a later refactor. Fresh `rc up` regressed silently. The 2026-04-25 fix restores the invariant the original ADR-017 D1 quietly assumed: agent user can reach the forwarded socket.

Test additions (`tests/test-ssh-forwarding.sh`): a sudoers regression guard that asserts `sudo -n -l` includes the chown grant, run as part of Test 1.

### 2026-04-24 — D1's candidate ordering dropped; macOS uses convention path only

Host-side testing on OrbStack + macOS invalidated D1's premise that `$SSH_AUTH_SOCK` is a reachable candidate inside the cage. OrbStack (and Docker Desktop) only proxy **one** AF_UNIX path across the VM boundary: `/run/host-services/ssh-auth.sock`. Arbitrary paths like `/tmp/*.sock` or `/var/folders/.../agent.NNN` bind-mount successfully (no error from `docker run`) but yield `Connection refused` on any `ssh-add -l` inside the container — the socket file entry exists in the VM's view but nothing is listening on the other side.

Consequences:
- D1's probe, which preferred `$SSH_AUTH_SOCK` as candidate #1 and verified it with host-side `ssh-add -l`, was consistently picking a socket that probed OK from the host but was dead inside the cage. Fresh `rc up` lost push capability.
- The Gate 1 `[[ -S "$_candidate" ]]` check on candidate #2 always failed on macOS, because `/run/host-services/` doesn't exist on the macOS host filesystem — it only exists in the Docker VM's view. So candidate #2 was never actually selectable via the probe.
- Net effect: on OrbStack + macOS, the ADR-018 probe loop picked candidate #1 (unreachable) or nothing. The only reason the pre-existing `platform-mapular-gtm` container kept working is that it was created before ADR-018 and is wired to candidate #2 unconditionally.

Revised behavior (implemented 2026-04-24):
- On macOS, `_resolve_host_ssh_sock` unconditionally returns `/run/host-services/ssh-auth.sock` when forwarding is on. No host-side probing, no candidate list, no backend detection.
- Reachability is reported by the in-container preflight (`ok:N` / `empty` / `unreachable`) and surfaced in the banner via the existing sentinel files.
- Linux/WSL2 path is unchanged — `$SSH_AUTH_SOCK` works natively across the docker boundary because there is no VM.

D2 (convention socket as fallback) is effectively promoted to "the only choice on macOS." D3 (preflight names the socket) is unaffected. D4 (rewritten prereq table in ADR-017) remains valid — the user-facing advice ("populate whatever `ssh-add -l` shows") still holds, it just now always routes through the launchd/convention path on macOS.

Test suite updates: Tests 5 & 6 in `tests/test-ssh-forwarding.sh` are Linux-only (they set a custom `$SSH_AUTH_SOCK`, which macOS now ignores). Test 8 (Docker Desktop `/var/folders` guard) was deleted — the guarded code path is gone.

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
