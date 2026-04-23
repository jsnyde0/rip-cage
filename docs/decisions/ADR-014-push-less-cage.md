# ADR-014: The Cage Is Push-Less

**Status:** Partially superseded by [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (2026-04-23). D1 (no push credentials) and D3 (push-less session-close) are reversed — ssh-agent forwarding is now on by default. D2 (non-interactive SSH posture) and D4 (LFS pointer detection) remain in force.
**Date:** 2026-04-21
**Design:** [Non-interactive SSH posture](../2026-04-21-non-interactive-ssh-design.md)
**Related:** [ADR-001](ADR-001-fail-loud-pattern.md) (fail-loud), [ADR-002](ADR-002-rip-cage-containers.md) (blast radius, no `~/.ssh` mount), [ADR-010](ADR-010-auth-refresh.md) (auth surface), [ADR-012](ADR-012-egress-firewall.md) (egress allowlist)

## Context

On 2026-04-21, a Claude Code session inside a rip-cage container hung on the OpenSSH first-contact prompt while attempting a git operation against `git@github.com:…`:

```
The authenticity of host 'github.com (140.82.121.4)' can't be established.
ED25519 key fingerprint is SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Two separate gaps combined to produce this:

1. **No non-interactive SSH posture in the image.** The Dockerfile installs `openssh-client` (Dockerfile:24) but never seeds `/etc/ssh/ssh_known_hosts` and never sets a system `ssh_config`. OpenSSH defaults to prompting on unknown hosts, and with an allocated TTY under tmux it blocks on stdin instead of failing. This violates the spirit of ADR-001: the failure mode is a silent hang, not a loud error.

2. **Incoherent position on outbound push credentials.** The 2026-03-25 design explicitly excluded `~/.ssh` from container bind mounts ("Host filesystem limited to /workspace bind mount", design:117) and called out that `bd dolt push/pull` won't work inside containers (design:555). Meanwhile, the project-level `CLAUDE.md` session-close protocol mandates `git push` + `bd dolt push` at session end. The agent is instructed to do something the cage architecturally prevents, producing either (a) hangs like the one above, or (b) silent failures the agent papers over.

The architectural question is: **who owns the identity that pushes from inside the cage?** Three candidate owners exist — the human (borrow host SSH keys), the cage itself (a dedicated bot identity with a scoped token or GitHub App), or nobody (the cage has no outbound write credentials and integration with remotes is a human responsibility at the session boundary). Today's de-facto answer is "nobody" at the container level, but "the agent must" at the instruction level — the incoherence is the bug.

## Decisions

### D1: No outbound push credentials live in the cage

**Firmness: FIRM**

The cage does **not** carry credentials for writing to remote source-control or issue-tracking systems. Specifically:

- No SSH private keys are mounted or generated inside the container.
- No Git/GitHub write tokens (`GH_TOKEN`, PAT, deploy key, GitHub App installation token) are injected by `rc up` / `rc init`.
- No `ssh-agent` socket is forwarded from the host.

Read-only outbound traffic (git `clone`/`fetch` over HTTPS, `gh` read APIs, `npm`/`apt`/`pip` fetches) remains allowed subject to ADR-012's egress allowlist.

**Rationale:** The cage's value proposition is that the thing inside it is not you. Mounting your host SSH key or forwarding `ssh-agent` gives the agent your full push capability across every repo you can touch for the lifetime of the container — a blast radius that defeats ADR-002. A dedicated bot identity (GitHub App or scoped PAT) would be architecturally cleaner, but carries real setup cost (a second account or a GitHub App registration, token rotation, per-repo scoping). Deferring that choice is better than adopting option 1 by accident.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Push-less cage (this decision)** | Preserves ADR-002 blast radius; no credential plumbing; honest about current state | Human pushes at session boundary; session-close protocol must change |
| Human identity in the cage (mount `~/.ssh` or forward `ssh-agent`) | Agent can push autonomously | Container holds keys to every repo you can touch; defeats the cage |
| Bot identity in the cage (GitHub App or scoped PAT) | Autonomous pushes with narrow scope; CI-grade model | Requires bot account or App registration; token rotation; not worth it today |

**What would invalidate this:** A decision to run agents autonomously enough that human-boundary pushes become the bottleneck. At that point, revisit with Option 3 (GitHub App) — see Deferred.

### D2: Non-interactive SSH posture in the image

**Firmness: FIRM**

The base image ships a deterministic, non-interactive SSH client posture:

- `/etc/ssh/ssh_known_hosts` contains pinned host keys for `github.com` (from GitHub's published `api.github.com/meta` `ssh_keys`, baked at image build time).
- `/etc/ssh/ssh_config` sets system-wide defaults:
  - `UserKnownHostsFile /etc/ssh/ssh_known_hosts`
  - `GlobalKnownHostsFile /etc/ssh/ssh_known_hosts`
  - `StrictHostKeyChecking yes`
  - `BatchMode yes`

**Rationale:** Even under D1, an agent will occasionally attempt an SSH-based git operation (a remote inherited from `git clone git@github.com:…`, a misconfigured alias, a tool that hardcodes SSH). The correct behavior is to **fail loudly and immediately** with `Permission denied (publickey)` or an equivalent non-interactive error — not to hang on a TTY prompt waiting for input the agent cannot provide. `BatchMode=yes` enforces this. Pinned host keys ensure that *if* a key ever is introduced (e.g., a future bot-identity ADR), the connection is already trust-bootstrapped and doesn't regress into TOFU behavior. Baking the fingerprints at build time is safe: they're public, long-lived, and GitHub publishes rotation events.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Pinned `known_hosts` + `BatchMode=yes` in image** | Deterministic, loud-failing, no runtime dependency | One more Dockerfile step; must refresh if GitHub rotates keys |
| `StrictHostKeyChecking=accept-new` | Zero-config UX | Silent TOFU; first attacker-in-the-middle is trusted |
| `StrictHostKeyChecking=no` | Simplest | Defeats host-key verification entirely |
| Runtime `ssh-keyscan` in `init-rip-cage.sh` | No build-time coupling to GitHub's keys | Requires egress at init; vulnerable to a compromised first fetch |
| Do nothing | No work | Current behavior — interactive hang, which is exactly the bug |

**What would invalidate this:** GitHub rotates its SSH host keys (rare; last rotation was 2023 after the accidental key exposure). A rotation would require a Dockerfile update and image rebuild — acceptable given the frequency.

**Caveat — `Match final` reach limits:** `Match final Host *` does not defeat (a) explicit CLI `-o` flags (command-line beats config), nor (b) user-config values for options the user already set (OpenSSH's "first value wins" applies across all passes including `Match final`). The FIRM posture holds for the default container (no user config, no `-o` override); a future bot-identity or forwarded-agent scenario that requires real enforcement against user/CLI overrides would need a read-only `~/.ssh` bind mount akin to ADR-002 D11.

### D3: Session-close protocol is push-less at the cage boundary

**Firmness: FIRM**

The project-level `CLAUDE.md` session-close protocol is updated so that "complete" means:

- All changes committed locally.
- A handoff summary produced (branch name, commits ahead of `origin`, summary of work, anything still pending).
- **No `git push` or `bd dolt push` attempted from inside the container.**

Pushing is the human's responsibility at the session boundary, on the host. `bd dolt push` is in the same bucket.

**Rationale:** The prior protocol ("work is NOT complete until `git push` succeeds") assumed a capability the cage architecturally refuses to provide (D1). Asking the agent to push anyway produces either silent failures or the interactive hang that triggered this ADR. Codifying "hand off, don't push" makes the instruction match reality and removes the footgun.

**What would invalidate this:** Adoption of Option 3 (bot identity) would flip this decision: the cage gains push capability, and the protocol goes back to requiring it.

### D4: LFS materialization is host-side, parallel to push

**Firmness: FIRM**

Git LFS blob materialization (`git lfs pull`, `git lfs fetch`, `git lfs checkout`) is the human's responsibility on the host, at session boundaries. The cage:

- Does **not** install or carry a `git-lfs` binary in the image.
- Does **not** carve out an egress allowlist entry for LFS endpoints.
- Does **not** mutate the host workspace from `rc up` / `rc init` to materialize blobs.
- **Does** detect LFS pointer stubs at `rc up` / `rc init` and print an advisory warning naming the exact host-side command (`git -C <path> lfs pull`) and up to 5 stub paths.

**Rationale:** The architectural shape is identical to D1/D3: LFS pull is a network-touching git operation that the cage's credential and egress posture deliberately refuses to provide. Because `/workspace` is a bind mount, any materialization the human performs on the host is immediately visible inside the cage — no container restart, no special plumbing. Auto-running `git lfs pull` from `rc` would cross the host/cage boundary that rip-cage otherwise respects (`rc` is a container-provisioning tool, not a host-side git wrapper); a warning accomplishes the same error-surfacing without that overreach.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Detect and warn (this decision)** | Zero new network surface; zero new binaries in the image; zero host mutation; keeps `rc` scope tight | Human must run one command once per branch switch involving LFS files |
| `rc` auto-runs `git lfs pull` on host | Fully automatic | `rc` starts mutating the host workspace; scope creep from container provisioning into git operations |
| Install `git-lfs` in the image + egress allowlist for LFS endpoints | In-cage autonomy | Permanent egress hole in every container to paper over a one-shot host action; credential surface for authenticated LFS servers |
| Bind-mount `~/.git/lfs/objects` + in-image `git-lfs` for `git lfs checkout` from host cache | Offline materialization | Still requires `git-lfs` in the image; the bind-mounted workspace already is the cache (once materialized on host, cage sees real files) |
| Do nothing | No work | Tests/tools that depend on LFS fixtures fail in the cage with cryptic format errors (e.g., "parquet file invalid (footer != PAR1)") and no hint why |

**What would invalidate this:** Adoption of a bot-identity model (see Deferred, Option 3) that also provisioned an LFS token — at that point, autonomous in-cage `git lfs pull` becomes a real option and the calculus changes.

## Deferred

- **Option 3 — dedicated bot identity via GitHub App.** Mint short-lived installation tokens per session, inject as `GH_TOKEN`, scope by repo-install. Would restore autonomous pushes with a narrow blast radius. Deferred until the session-boundary handoff becomes a real friction point. Keep an eye on the auth-refresh surface (ADR-010) as the natural integration point when the time comes.
- **Per-repo deploy keys.** Simpler than an App but doesn't scale and provides write without identity; considered strictly worse than Option 3.
- **SSH-agent forwarding as an opt-in escape valve.** Doable via `-v $SSH_AUTH_SOCK` and an `rc up --forward-ssh` flag, but the blast-radius tradeoff needs its own ADR. Not worth pre-building.
