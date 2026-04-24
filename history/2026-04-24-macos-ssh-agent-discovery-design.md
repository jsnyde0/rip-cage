# Design: macOS ssh-agent discovery — forward the agent the user actually uses

**Date:** 2026-04-24
**Status:** Accepted — pending implementation
**Decisions:** [ADR-018](../docs/decisions/ADR-018-macos-ssh-agent-discovery.md)
**Origin:** Dogfooding — `mapular-gtm` session left 12 commits stranded because `git push` inside the cage hit `Permission denied (publickey)` despite ssh-agent forwarding being wired. Diagnosis showed the cage's forwarded socket reached the macOS launchd system agent (empty), while the user's `ssh-add -l` keys lived in their shell session agent (populated). ADR-017 D4's documented "host prereq" (`ssh-add --apple-use-keychain`) does not close this gap for passphrase-less keys.
**Supersedes:** [ADR-017](../docs/decisions/ADR-017-ssh-agent-forwarding-default.md) D4 (partially — host-prereq model for macOS)

---

## Problem

ADR-017 made ssh-agent forwarding the default and documented a per-platform host prereq. The macOS column told users to run `ssh-add --apple-use-keychain <key>` and set `UseKeychain yes` / `AddKeysToAgent yes` in `~/.ssh/config`. This assumes a specific flow: the key has a passphrase, `--apple-use-keychain` stashes that passphrase in the macOS Keychain, and the launchd-managed system ssh-agent then auto-loads the key on demand via Keychain. The cage forwards that launchd agent (via `/run/host-services/ssh-auth.sock`, which OrbStack and Docker Desktop proxy to the launchd socket), so a populated launchd agent means working push.

The footgun: passphrase-less keys are the common dev-machine setup. `--apple-use-keychain` on a passphrase-less key is effectively a no-op — there is no passphrase to stash, so nothing ends up in Keychain, and the launchd system agent stays empty on every login. The keys the user sees via `ssh-add -l` live in their *shell session* agent (a separate per-terminal launchd-spawned process at `/var/folders/.../agent.NNNN`), which is not the agent the cage forwards. Result: the host has working SSH, the cage does not, and the failure mode is invisible until a push attempt.

This is worse than a documentation bug. ADR-017 D4's "host prereq" can be followed faithfully and still leave the cage with an empty agent. The user ends up doing the right thing, seeing it work on the host, and watching it silently fail in the cage. The cage's loud-at-start preflight does surface `empty`, but the banner points at `ADR-017 D4 for host-side fix` — a doc whose fix does not address this case.

## Goal

Forward **whichever host agent the user actually populates** into the cage, without requiring the user to understand that macOS has two ssh-agents and that `--apple-use-keychain` only helps one of them under one specific condition. The invariant: what `ssh-add -l` shows on the host is what the cage sees.

## Non-Goals

- Solving reboot persistence for passphrase-less keys. That is a host-side concern (LaunchAgent, 1Password agent, Keychain integration) and out of scope for the cage.
- Supporting mixed-agent scenarios (one agent for GitHub, another for a work SSH host). Priority ordering is good enough; users who want finer control can set `SSH_AUTH_SOCK` explicitly.
- Changing ADR-017 D1 (forward-by-default), D2 (`--no-forward-ssh` opt-out), or D3 (LFS carryover). Those remain in force.
- Linux/WSL2 behavior. Those platforms already forward `$SSH_AUTH_SOCK` directly and are unaffected.

---

## Proposed Architecture

Replace the hard-coded macOS socket path with a **host-side probe-and-pick loop**. At `rc up`, iterate candidate sockets in priority order; for each candidate, validate it is bind-mountable on the active Docker backend, then run `ssh-add -l` against it from the host. The first candidate that responds with at least one key wins and gets bind-mounted to `/ssh-agent.sock` inside the container. If none have keys, mount the first *reachable and mountable* candidate anyway so the `empty` preflight still produces a useful banner naming the specific socket the user should populate. The probe only fires when ssh-agent forwarding is enabled (i.e., `--no-forward-ssh` and `RIP_CAGE_FORWARD_SSH=off` short-circuit to `disabled` before any probing — no 10s tax when the user opted out).

```
rc up (macOS, forwarding enabled)
  │
  ├── candidates = [ $SSH_AUTH_SOCK (if set),
  │                  /run/host-services/ssh-auth.sock ]   # Docker Desktop / OrbStack convention
  │
  ├── for each candidate:
  │     1. exists + is a socket? (stat check)         → skip if no
  │     2. bind-mountable on this backend?            → skip if no
  │         (Docker Desktop: skip /var/folders paths unless file-share configured;
  │          OrbStack: always ok; detected via `docker context inspect`)
  │     3. host-side probe with 5s timeout:
  │         ssh-add -l against SSH_AUTH_SOCK=<candidate>
  │           → ok:N        → choose this candidate (exit loop)
  │           → empty       → remember as fallback
  │           → unreachable → skip
  │
  ├── mount chosen candidate → /ssh-agent.sock inside container
  └── write host-side probe result to ssh-agent-status sentinel
      and mounted-socket path to ssh-agent-socket companion sentinel
```

### Host-side probe (new)

A small function in `rc` — call it `_resolve_host_ssh_sock()` — runs before `_up_prepare_environment` wires the mount. It does what the in-container preflight does today (`timeout 5 ssh-add -l`), but on the host, against each candidate socket, using the running rc process's own environment to resolve paths.

The probe must not hang. `timeout(1)` is **not installed by default on macOS** (coreutils ships it as `gtimeout`), so the existing `timeout 5 ssh-add -l` pattern used by the in-container preflight is not safe on the host. The probe uses a portable bash "background + kill" pattern (same approach as `_probe_tcp`): spawn `ssh-add -l` in the background, wait up to 5 seconds, `kill -0` to check liveness, then `kill` if still running. Any wedged user agent is capped at 5s per candidate — not indefinite.

Backend detection for the bind-mount validation uses `docker context inspect --format '{{.Endpoints.docker.Host}}'` (or equivalent): OrbStack endpoints (`unix:///Users/.../.orbstack/run/docker.sock`) pass `/var/folders/...` through transparently; Docker Desktop endpoints (`unix:///Users/.../.docker/run/docker.sock` or `desktop-linux` context) require the path to be inside the user's configured file-share roots (defaults: `/Users`, `/Volumes`, `/private/tmp`, `/tmp`). For unknown backends, the probe assumes mountable and lets `docker run` fail loudly if not.

Probe is cheap: at most two sockets, each a 5-second timeout ceiling. In practice the first candidate responds in milliseconds or is obviously unreachable (ENOENT).

### Candidate priority

1. **`$SSH_AUTH_SOCK`** — the user's own session agent. This is what `ssh-add -l` on host reflects, so forwarding it gives the cage the exact same view the user has.
2. **`/run/host-services/ssh-auth.sock`** — Docker Desktop / OrbStack convention. Retained as fallback for users relying on the Keychain-agent model (passphrase-protected keys + `UseKeychain yes`). Works on both backends.

Expected winners per backend:

| Backend | Expected winner | Why |
|---|---|---|
| OrbStack | candidate #1 | `/var/folders/...` passthrough is transparent; user's session agent wins |
| Docker Desktop | candidate #2 | `/var/folders/...` requires explicit file-share config; most users hit the launchd/Keychain agent via the convention socket |
| Colima | #1 or #2 | Tested during implementation; probe loop is forgiving |

The explicit launchd path (`/private/tmp/com.apple.launchd.*/Listeners`) considered in an earlier draft was dropped: its glob expansion is ambiguous (which match wins?), the exact socket filename depends on launchd labels, and candidate #2 covers the Keychain-backed launchd flow anyway. Two candidates is enough.

On Linux/WSL2 the priority is simpler and unchanged: `$SSH_AUTH_SOCK` directly, fall through to `no_host_agent` if unset.

### Preflight semantics (tightened, not replaced)

The in-container `ssh-add -l` probe at `rc up` still runs — it catches socket-mounted-but-unreachable pathologies (permissions, kernel issues, launchd weirdness inside the VM). But with host-side probing making the mount selection honest, the `empty` case now *means* the host agent is empty, which is a single-line host-side fix (`ssh-add <key>`) rather than a platform-specific Keychain incantation.

Note that `no_host_agent` becomes a reachable state on macOS under this design: if `$SSH_AUTH_SOCK` is unset, the convention socket is unreachable, and no backend proxy is wired (unusual Colima configs, misconfigured Docker Desktop), the probe can return empty-handed. The existing 5-state sentinel handles this correctly; the banner fix hint (`ssh-add` on host) remains accurate.

### Sentinel format — companion file

Status and path are split across two sentinel files to avoid breaking the existing zshrc `case` matcher on multi-line values:

- `/etc/rip-cage/ssh-agent-status` — unchanged. Single line, one of `ok:N`, `empty`, `unreachable`, `no_host_agent`, `disabled`.
- `/etc/rip-cage/ssh-agent-socket` — **new**. Single line, the host-side path that was selected and mounted (empty string if nothing was mounted). Matches the `host-os` sentinel precedent.

The banner (`zshrc` ssh-agent-status block) reads both and always names the mounted socket when one exists. Fix hints become: `host agent at <path> is empty — run 'ssh-add ~/.ssh/id_ed25519' on host, then 'rc down && rc up'`. No more pointing at ADR text.

### Implementation globals

The current `_UP_FORWARD_SSH_WIRED` state variable (`rc:995`) encodes `on`/`off`/`no_host_agent`. It is renamed to `_UP_FORWARD_SSH_HOST_SOCK` and carries the selected host path (empty string means nothing wired, equivalent to the old `no_host_agent`). `_up_ssh_preflight` takes this as a second argument so it can record the path to the new sentinel alongside the status. This keeps both facts (status + socket) in lockstep at write time — no risk of them drifting.

### Resume path

Container labels persist the posture (`rc.forward-ssh=on|off`). On `rc up` of an existing container, the socket mount cannot be changed without recreating the container, so resume re-runs only the in-container preflight. If the user populated their agent after the first `rc up`, the cage will now see keys (because it was always listening to the same socket). If they populated a *different* agent than the one wired at create time, they need `rc down && rc up` to re-probe and re-mount. The banner (which now names the mounted socket) makes this debuggable — the user can compare the mounted path against their current `$SSH_AUTH_SOCK` and notice the drift.

---

## Key Design Decisions

From [ADR-018](../docs/decisions/ADR-018-macos-ssh-agent-discovery.md):

- **D1 (FIRM):** On macOS, `rc up` probes candidate host sockets (validating bind-mountability per backend) and mounts the first one with keys. Passphrase-less keys in the user's session agent now "just work."
- **D2 (FIRM):** Docker Desktop's `/run/host-services/ssh-auth.sock` stays as a fallback candidate. No regression for users on the Keychain-agent path.
- **D3 (FIRM):** Preflight failure messages name the actual mounted socket (via companion sentinel) instead of pointing at ADR text. Fix commands are single-line `ssh-add <key>` invocations.
- **D4 (FLEXIBLE):** ADR-017 D4's "host prereq" table is rewritten to describe the new behavior. The macOS row collapses to "whatever gives you a populated `$SSH_AUTH_SOCK` on host."

---

## Test plan

New and changed coverage in `tests/test-ssh-forwarding.sh`:

1. **Existing Test 4 generalizes to macOS.** Currently comments "on macOS, the OrbStack/Docker-Desktop magic path always resolves." With probing, Test 4 can run on macOS too by unsetting `SSH_AUTH_SOCK` and verifying candidate #2 is selected and recorded in the companion sentinel.
2. **New: session-agent probe.** Start a mock ssh-agent on host (`ssh-agent -a /tmp/rc-probe-test.sock`), `ssh-add` a test key into it, point `SSH_AUTH_SOCK` at it, run `rc up`, verify the cage sees the key via `ssh-add -l` inside and that `/etc/rip-cage/ssh-agent-socket` contains the host path.
3. **New: empty-agent fallback.** Session agent reachable but empty; verify sentinel=`empty`, companion sentinel names the candidate path, banner fix hint contains the path.
4. **New: unreachable path.** Point `SSH_AUTH_SOCK` at a non-existent path; verify probe skips it and falls through to candidate #2 (or `no_host_agent` if #2 also unreachable).
5. **New: Docker Desktop bind-mount guard.** When backend is Docker Desktop and `$SSH_AUTH_SOCK` is under `/var/folders/...`, verify the probe detects non-mountability and skips candidate #1 rather than letting `docker run` fail.
6. **New: short-circuit when disabled.** With `RIP_CAGE_FORWARD_SSH=off` or `--no-forward-ssh`, verify no host-side probing runs (timing-based: `rc up` completes comparable to forwarding-off baseline).
7. **Regression: existing Linux/WSL2 paths unchanged.**

---

## Consequences

**Easier:**
- Users with passphrase-less keys (the common case) get working push with no macOS-specific setup.
- The mental model collapses to "host agent == cage agent." No more two-agent confusion.
- `rc doctor` / banner messages are actionable one-liners, not doc references.
- Cross-backend parity: OrbStack, Docker Desktop, and Colima all resolve via the same probe loop (with backend-aware bind-mount validation).

**Harder:**
- `rc` gains host-side `ssh-add` execution and `docker context inspect` parsing. Adds one host-tool dependency (`ssh-add` — already required for the current flow, so not net-new) and ~30–40 lines of probe + validation logic.
- Debugging "which socket did rc pick?" requires surfacing the choice. The companion sentinel covers this; banner and `rc doctor` display the mounted socket path.

**Tradeoffs:**
- Implicit selection via probe is less predictable than hard-coded paths. Mitigated by logging the chosen socket at `rc up` and in the sentinel. Users who need determinism can pre-set `SSH_AUTH_SOCK` and it wins priority.
- If the user's session agent dies mid-session (terminal exit, sleep/wake oddness), the cage's mounted socket goes stale until `rc down && rc up`. This is not new — the previous design had the same failure mode, just with a different backing agent.
- `no_host_agent` is now reachable on macOS (previously Linux/WSL2-only). The banner fix hint is generic enough to cover both.

## Known Limitations

- **Reboot persistence remains a host-side problem.** If the user's keys don't survive login (no passphrase, no LaunchAgent, no 1Password), they still need to re-add on every boot. This design does not fix that; it just makes the failure mode honest.
- **Multi-agent systems.** Users running 1Password SSH agent, Secretive, or similar will have `$SSH_AUTH_SOCK` pointing at those agents. Those integrate cleanly with this design (they *are* the session agent). No special handling needed.
- **Probe cost at `rc up`.** Two candidates × 5s timeout ceiling = ~10s absolute worst case. Two realistic slow paths:
  - All candidates unreachable (5s + 5s = 10s; user gets `unreachable` banner).
  - No candidate has keys but one is reachable (under 10s; user gets `empty` banner naming the reachable socket).
  The fast path (first candidate responds with keys) is milliseconds. `rc up` already takes seconds; an extra ~10s in the pathological case is acceptable.

---

## Open Questions

1. **Should `rc doctor` re-probe live on a running container?** With the banner now naming the mounted socket (promoted from follow-up to P2-required), the need for a live re-probe is reduced — users can compare the mounted path against current `$SSH_AUTH_SOCK` themselves. Leaning no; revisit if drift confusion keeps surfacing.
2. **Colima coverage.** Colima exposes the host agent differently than OrbStack/Docker Desktop; verify the candidate list covers it during implementation. The probe loop is forgiving — worst case we add a Colima-specific path later.
