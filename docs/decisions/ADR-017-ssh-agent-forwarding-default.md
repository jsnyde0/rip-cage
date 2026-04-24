# ADR-017: SSH-Agent Forwarding On By Default — The Cage Can Push

**Status:** Accepted (D4 amended by [ADR-018](ADR-018-macos-ssh-agent-discovery.md))
**Date:** 2026-04-23
**Supersedes:** [ADR-014](ADR-014-push-less-cage.md) D1 (no outbound push credentials) and D3 (push-less session-close protocol). ADR-014 D2 (non-interactive SSH posture) and D4 (LFS pointer detection) remain in force.
**Amended by:** [ADR-018](ADR-018-macos-ssh-agent-discovery.md) — D4's macOS host-prereq model is replaced by a host-side probe-and-pick loop. D1, D2, D3 unchanged.
**Related:** [ADR-002](ADR-002-rip-cage-containers.md) (blast radius), [ADR-012](ADR-012-egress-firewall.md) (egress), project [CLAUDE.md](../../CLAUDE.md) philosophy section

## Context

ADR-014 landed with a containment-flavored framing: "the thing inside the cage is not you," no push credentials, human pushes at the session boundary. Several days of dogfooding surfaced the cost:

- Session-close requires a human context switch every time the agent finishes work, even for trivial commits. This breaks the "walk away, let it run" property that is the whole point of rip-cage.
- The project README explicitly frames the cage as **blast-radius reduction, not prevention**. ADR-014's "the cage architecturally refuses push capability" reads as an adversarial containment stance that contradicts the project's own positioning.
- The user's lived experience: "it's annoying we can't have the agent push in our name." CLAUDE.md now names this pattern — "it's annoying" is a design signal that a default is probably wrong.

ADR-014 D1 was the right call for a containment cage. It is the wrong call for an autonomy cage. This ADR flips the default.

## Decisions

### D1: SSH-agent forwarding is on by default

**Firmness: FIRM**

`rc up` forwards the host `ssh-agent` socket into the container by default. The agent inside the cage can use the host's SSH keys to authenticate git pushes, `gh` write operations, and other SSH-based flows, exactly as a human on the host would.

Specifically:

- `rc up` mounts the host's ssh-agent socket read-write into the container at `/ssh-agent.sock` and sets `SSH_AUTH_SOCK=/ssh-agent.sock` inside the container.
- The host socket path depends on platform (see D4):
  - **Linux / WSL2**: `$SSH_AUTH_SOCK` is a normal AF_UNIX socket on the same kernel Docker runs on; mount it directly.
  - **macOS (Docker Desktop / OrbStack)**: the session `$SSH_AUTH_SOCK` lives in a launchd-managed path that does not survive the VM boundary. The supported path is `/run/host-services/ssh-auth.sock`, which the VM proxies to the macOS system agent. Keys must be reachable via the system agent — see D4 for the host-setup prereq.
- No private key material is copied or mounted. Keys stay on the host; the agent borrows signing capability for the session lifetime only.
- Forwarding stops when the container stops. No persistent credential state inside the volume.

**Rationale:** ssh-agent forwarding is strictly better than mounting `~/.ssh` — the agent inside the cage can *use* keys but cannot *exfiltrate* them. Private keys never cross the container boundary. When the container dies, access dies. This is the standard model for CI runners and dev containers, and it matches the project's 80/20 posture: block accidents, preserve autonomy.

The blast radius is real and accepted: an agent compromised inside the cage can, during its session, push to any repo the human can push to. That is consistent with rip-cage's framing (layers, not walls). DCG, compound blocker, egress denylist, and filesystem sandbox remain the primary containment mechanisms; push capability is not what those layers exist to stop.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **ssh-agent forwarding on by default (this decision)** | Autonomy preserved; keys never enter container; matches CI/devcontainer norms | Session-long push capability if container is compromised |
| Mount `~/.ssh` read-only | Simpler | Private key material enters container; exfil possible; strictly worse than forwarding |
| Bot identity (GitHub App / scoped PAT) | Narrow scope per repo; audit trail | Setup burden (second account / App registration, token rotation); not worth it for solo dev |
| Push-less (ADR-014 D1) | Smallest blast radius | Breaks autonomy — the thing we are optimizing for |

**What would invalidate this:** evidence that ssh-agent-forwarded sessions are a practical exfil vector in agentic workflows (not just theoretical). Revisit with Option 3 (bot identity) if it becomes a real problem.

### D2: Opt-out via `rc up --no-forward-ssh`

**Firmness: FIRM**

Users who want the ADR-014 containment posture can pass `--no-forward-ssh` to `rc up`. This skips the socket mount, leaves `SSH_AUTH_SOCK` unset inside the container, and restores the "cage cannot push" behavior.

The flag is persisted on the container via an `rc.forward-ssh=off` label, so resume-path `rc up` reads the original posture instead of silently upgrading a containment container to a forwarding one.

**Rationale:** some projects (shared credentials, compliance environments, high-stakes repos) warrant the stricter posture. Making containment available as an opt-in preserves the choice without making it the default. Persistence via label matches how `rc.egress=on/off` works today — one pattern for per-container security posture.

**What would invalidate this:** usage telemetry (or explicit requests) showing that nobody uses `--no-forward-ssh`, at which point it becomes dead surface and can be removed.

### D3: Session-close protocol restores `git push`

**Firmness: FIRM**

The project-level CLAUDE.md session-close protocol is reverted from ADR-014 D3 ("do not push from inside the container") back to the pre-ADR-014 form: commit locally, then push.

`bd dolt push` is included in the same revert — the agent should push beads state at session end, on its own, from inside the cage.

**Rationale:** D1 makes pushing work again. D3 makes the protocol match reality, closing the loop that ADR-014 opened. The new session-close is "commit, push, done" — no human intervention required for the normal case.

**What would invalidate this:** same as D1.

### D4: Cross-platform reachability — loud failure, not silent

**Firmness: FIRM**

"Forwarding on by default" has a platform-specific prereq, and the cage must fail loudly when the prereq is not met rather than silently forward an empty agent.

**Host-side prereq by platform:**

| OS | How it works | Host prereq |
|---|---|---|
| Linux | bind-mount `$SSH_AUTH_SOCK` directly | `ssh-agent` running with keys loaded (standard dev setup) |
| macOS (OrbStack / Docker Desktop) | mount `/run/host-services/ssh-auth.sock`; VM proxies to macOS system agent (keychain-backed) | `ssh-add --apple-use-keychain <key>` run once + `UseKeychain yes`, `AddKeysToAgent yes` in `~/.ssh/config`. An ad-hoc session agent is not reachable — its socket does not survive the VM boundary. |
| WSL2 | bind-mount `$SSH_AUTH_SOCK` directly | `ssh-agent` running in the WSL side |

**Preflight behavior:** at `rc up`, after the socket is forwarded, probe the agent from inside the container (`timeout 5 ssh-add -l`). Five status values feed the sentinel at `/etc/rip-cage/ssh-agent-status`, read by the shell banner and `rc ls`:

1. `ok:N` — Agent reachable, N≥1 keys loaded → proceed silently.
2. `empty` — Agent reachable, 0 keys → **loud warning** naming the platform-specific fix (Linux: `ssh-add ~/.ssh/<key>`; macOS: keychain snippet above).
3. `unreachable` — Socket mounted but agent did not respond (connection refused or 5s timeout; also covers platform mismatch like a launchd socket surviving the VM boundary) → **loud warning** with platform hint.
4. `no_host_agent` — Forwarding was on by default but the host provided no agent to forward (e.g. Linux with `SSH_AUTH_SOCK` unset). The label is written as `off` — nothing was wired, so a later resume must not re-attempt a doomed mount. **Loud warning** at create, banner surfaces it on every attach.
5. `disabled` — User passed `--no-forward-ssh` (or the project-level `RIP_CAGE_FORWARD_SSH=off` env default). Silent at create, banner clarifies on every attach.

`rc up` does not abort on any non-`ok:N` status — a cage with no push capability is still useful (read-only work, exploration, HTTPS git). The guarantee is that the reason is visible at every entry point, never silent.

**Visibility beyond `rc up`:** `rc up` stdout is swallowed by the tmux auto-attach. Preflight results are surfaced in three places so users see them on any path:
- **stderr at `rc up`** (one-shot, plan-time).
- **tmux welcome banner** (every attach — `init-rip-cage.sh` reads a sentinel written by preflight).
- **`rc ls` column** (fleet view).

**Rationale:** the worst outcome is a "working" cage that silently loses push capability. Empty-agent detection converts that into a loud-at-start, loud-in-banner, loud-in-`rc ls` condition. Platform-specific preflight keeps the ADR honest without splitting the default across platforms.

**What would invalidate this:** a future shift to bot-identity tokens (Deferred option in ADR-014) makes the agent-reachability question moot.

## What carries over from ADR-014

- **D2 (non-interactive SSH posture):** pinned `known_hosts.github`, `BatchMode=yes`, `StrictHostKeyChecking=yes`. Still in force — it is valuable *because* SSH works now. Without D2, a broken known_hosts or a rotated GitHub key would hang the agent on a TTY prompt. With D2 + this ADR, SSH either works silently or fails loudly.
- **D4 (LFS pointer detection):** unchanged. Independent concern.

## Consequences

**Positive:**
- Agent runs end-to-end without human push intervention. Autonomy restored.
- CLAUDE.md philosophy (autonomy over containment) matches the codebase.
- Containment posture remains available to users who want it (`--no-forward-ssh`).
- Session-close protocol is enforceable again — either the push succeeds or a real error surfaces.

**Negative:**
- Blast radius increases for the default case. A compromised session has the human's full git push capability for its lifetime.
- Platform-specific host prereq (see D4). Linux is effectively free; macOS requires one-time keychain setup; WSL2 matches Linux.
- One more `rc.*` label to maintain (`rc.forward-ssh`).

## Implementation notes

- `rc up`: add `--no-forward-ssh` flag and `RIP_CAGE_FORWARD_SSH` env var (sibling to `RIP_CAGE_EGRESS`; CLI wins), `--label rc.forward-ssh=on|off`. Host-side socket selection: on macOS use `/run/host-services/ssh-auth.sock`; on Linux/WSL2 use `$SSH_AUTH_SOCK`. Mount to `/ssh-agent.sock` inside container and set `SSH_AUTH_SOCK=/ssh-agent.sock`. If no host socket resolves, write label=off (nothing was wired) and record `_UP_FORWARD_SSH_WIRED=no_host_agent` so the preflight can distinguish the case from explicit opt-out.
- Preflight: after `docker run` / `docker start`, probe `timeout 5 ssh-add -l` inside container. Write result to `/etc/rip-cage/ssh-agent-status` (sentinel) and print to stderr. Status values: `ok:N_keys`, `empty`, `unreachable`, `no_host_agent`, `disabled`.
- `rc ls`: surface the forward-ssh posture as a column (on/off/invalid from label) the way egress is surfaced today.
- `cmd_up` resume path: read `rc.forward-ssh` label, not the current environment, to preserve the original choice.
- `init-rip-cage.sh`: read the ssh-agent-status sentinel and include it in the tmux welcome banner so users see the posture on every attach.
- Tests: add `test-ssh-forwarding.sh` (host-side) asserting socket is mounted, `ssh-add -l` works inside, `--no-forward-ssh` produces the opposite state, sentinel is written, label is set. Add a regression guard to the e2e lifecycle suite (ADR-013 P1) once it exists.
- CLAUDE.md session-close protocol: already updated (pre-ADR-017 commit) to restore `git push` / `bd dolt push`.
- README quickstart: add a note on host prereqs per platform (Linux: running agent; macOS: keychain setup; WSL2: WSL-side agent) and how to opt out.
- `rc doctor` (deferred to separate bead): per-container diagnostic view covering all `rc.*` labels + live probes (egress firewall, ssh-agent reachability, beads connectivity). Natural complement to `rc ls` (fleet view).
