# Design: macOS ssh-agent discovery — forward the agent the user actually uses

**Date:** 2026-04-24
**Status:** Draft
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

Replace the hard-coded macOS socket path with a **host-side probe-and-pick loop**. At `rc up`, iterate candidate sockets in priority order; for each candidate, run `ssh-add -l` against it from the host. The first candidate that responds with at least one key wins and gets bind-mounted to `/ssh-agent.sock` inside the container. If none have keys, mount the first *reachable* candidate anyway so the `empty` preflight still produces a useful banner naming the specific socket the user should populate.

```
rc up (macOS)
  │
  ├── candidates = [ $SSH_AUTH_SOCK (if set),
  │                  /run/host-services/ssh-auth.sock,   # OrbStack/Docker Desktop convention
  │                  /private/tmp/com.apple.launchd.*/Listenders ]  # explicit launchd path
  │
  ├── for each candidate:
  │     host-side probe: SSH_AUTH_SOCK=<candidate> ssh-add -l
  │     → ok:N   → choose this candidate (exit loop)
  │     → empty  → remember as fallback
  │     → unreachable → skip
  │
  ├── mount chosen candidate → /ssh-agent.sock inside container
  └── write host-side probe result to ssh-agent-status sentinel
```

### Host-side probe (new)

A small function in `rc` — call it `_resolve_host_ssh_sock()` — runs before `_up_prepare_environment` wires the mount. It does exactly what the in-container preflight does today (`timeout 5 ssh-add -l`) but on the host, against each candidate socket, using the running rc process's own environment to resolve paths.

Probe is cheap: at most three sockets, each a 5-second timeout. In practice the first candidate responds in milliseconds or is obviously unreachable (ENOENT).

### Candidate priority

1. **`$SSH_AUTH_SOCK`** — the user's own session agent. This is what `ssh-add -l` on host reflects, so forwarding it gives the cage the exact same view the user has.
2. **`/run/host-services/ssh-auth.sock`** — Docker Desktop / OrbStack convention. Retained as fallback for users relying on the Keychain-agent model (passphrase-protected keys + `UseKeychain yes`). Works on both backends.
3. **`/private/tmp/com.apple.launchd.*/Listeners`** — explicit launchd system agent path, globbed. Last resort if Docker Desktop's proxy is not available (unusual environments).

On Linux/WSL2 the priority is simpler and unchanged: `$SSH_AUTH_SOCK` directly, fall through to `no_host_agent` if unset.

### Preflight semantics (tightened, not replaced)

The in-container `ssh-add -l` probe at `rc up` still runs — it catches socket-mounted-but-unreachable pathologies (permissions, kernel issues, launchd weirdness inside the VM). But with host-side probing making the mount selection honest, the `empty` case now *means* the host agent is empty, which is a single-line host-side fix (`ssh-add <key>`) rather than a platform-specific Keychain incantation.

The sentinel format gains one field — the socket path that was mounted — so the banner can name it in the fix hint: `host agent at /var/folders/.../agent.NNNN is empty — run 'ssh-add ~/.ssh/id_ed25519' on host`. No more pointing at an ADR.

### Resume path

Container labels persist the posture (`rc.forward-ssh=on|off`). On `rc up` of an existing container, the socket mount cannot be changed without recreating the container, so resume re-runs only the in-container preflight. If the user populated their agent after the first `rc up`, the cage will now see keys (because it was always listening to the same socket). If they populated a *different* agent than the one wired at create time, they need `rc down && rc up` to re-probe and re-mount. This is explicit in the banner text.

---

## Key Design Decisions

From [ADR-018](../docs/decisions/ADR-018-macos-ssh-agent-discovery.md):

- **D1 (FIRM):** On macOS, `rc up` probes candidate host sockets and mounts the first one with keys. Passphrase-less keys in the user's session agent now "just work."
- **D2 (FIRM):** Docker Desktop's `/run/host-services/ssh-auth.sock` stays as a fallback candidate. No regression for users on the Keychain-agent path.
- **D3 (FIRM):** Preflight failure messages name the actual mounted socket instead of pointing at ADR text. Fix commands are single-line `ssh-add <key>` invocations.
- **D4 (FLEXIBLE):** ADR-017 D4's "host prereq" table is rewritten to describe the new behavior. The macOS row collapses to "whatever gives you a populated `$SSH_AUTH_SOCK` on host."

---

## Consequences

**Easier:**
- Users with passphrase-less keys (the common case) get working push with no macOS-specific setup.
- The mental model collapses to "host agent == cage agent." No more two-agent confusion.
- `rc doctor` / banner messages are actionable one-liners, not doc references.
- Cross-backend parity: OrbStack, Docker Desktop, and Colima all resolve the same way via the probe loop.

**Harder:**
- `rc` gains host-side `ssh-add` execution. Adds one host-tool dependency (`ssh-add` — already required for the current flow, so not net-new) and ~20 lines of probe logic.
- Debugging "which socket did rc pick?" requires surfacing the choice. The sentinel field addition covers this; `rc doctor` displays the mounted socket path.

**Tradeoffs:**
- Implicit selection via probe is less predictable than hard-coded paths. Mitigated by logging the chosen socket at `rc up` and in the sentinel. Users who need determinism can pre-set `SSH_AUTH_SOCK` and it wins priority.
- If the user's session agent dies mid-session (terminal exit, sleep/wake oddness), the cage's mounted socket goes stale until `rc down && rc up`. This is not new — the previous design had the same failure mode, just with a different backing agent.

## Known Limitations

- **Reboot persistence remains a host-side problem.** If the user's keys don't survive login (no passphrase, no LaunchAgent, no 1Password), they still need to re-add on every boot. This design does not fix that; it just makes the failure mode honest.
- **Multi-agent systems.** Users running 1Password SSH agent, Secretive, or similar will have `$SSH_AUTH_SOCK` pointing at those agents. Those integrate cleanly with this design (they *are* the session agent). No special handling needed.
- **Probe cost at `rc up`.** At most ~15s worst case if all three candidates time out (none do in practice on a healthy host). Acceptable — `rc up` already takes seconds.

---

## Open Questions

1. **Should `rc doctor` expose the probe result retroactively?** I.e., on a running container, re-probe the host and warn if the currently-mounted socket has drifted (user switched agents since create). Low-priority UX polish; can be a follow-up. Leaning yes but not required for P2 ship.
2. **Colima coverage.** Colima exposes the host agent differently than OrbStack/Docker Desktop; verify the candidate list covers it or add a Colima-specific path. Test during implementation; the probe loop is forgiving.
