# Non-Interactive SSH Posture in the Cage

**Date:** 2026-04-21
**ADR:** [ADR-014](decisions/ADR-014-push-less-cage.md)
**Related:** [ADR-001](decisions/ADR-001-fail-loud-pattern.md), [ADR-002](decisions/ADR-002-rip-cage-containers.md), [ADR-012](decisions/ADR-012-egress-firewall.md), [ADR-013](decisions/ADR-013-test-coverage.md)

## Problem

An agent running inside a rip-cage container hit this prompt and hung:

```
The authenticity of host 'github.com (140.82.121.4)' can't be established.
ED25519 key fingerprint is SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Triggered by a git operation against an SSH remote (`git@github.com:…`). The OpenSSH client has no `known_hosts` entry for `github.com`, no system `ssh_config` setting a non-interactive policy, and a TTY is attached under tmux — so `ssh` reaches for stdin and blocks. The agent cannot supply input; the session stalls silently from its perspective.

This is the worst possible failure mode: not loud, not fast, not recoverable without human intervention. ADR-001's fail-loud pattern is violated in spirit.

## Goal

When any SSH-based outbound operation runs inside the cage, it must either:

1. Succeed non-interactively (requires credentials — out of scope per ADR-014 D1), or
2. Fail immediately with a clear, non-interactive error the agent can observe and route around.

No prompts. No TTY dialogs. No silent hangs.

## Design

### Image-build posture + coherent session-close instructions

All SSH posture lives in the Dockerfile and two static files in the repo. No behavior in `init-rip-cage.sh`, no runtime network calls, no per-container state. The design also updates project-level agent instructions (`CLAUDE.md`) so the session-close protocol matches the cage's push-less architecture — without that rewrite, ADR-014 D3 is paper-only and the hang recurs the next time an agent follows the stale instructions.

**1. Pinned `ssh_known_hosts` file (`ssh/known_hosts.github`)**

A repo-tracked file containing GitHub's published SSH host keys. Source: `https://api.github.com/meta` → `.ssh_keys[]`, plus the ED25519 fingerprint `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU` (which is the one the failing prompt displayed — matches GitHub's documented current key).

The file begins with a provenance comment so a future reader can tell whether it's stale without re-running this design:

```
# GitHub SSH host keys — pinned from api.github.com/meta (.ssh_keys[]).
# Fetched: 2026-04-21. SHA256_ED25519: +DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
# Refresh: scripts/refresh-github-known-hosts.sh
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
```

Placed at `/etc/ssh/ssh_known_hosts` in the image with mode `0644`. A trivial refresh script (`scripts/refresh-github-known-hosts.sh`) fetches `api.github.com/meta` and rewrites this file; it is only invoked manually when GitHub rotates keys.

**2. System `ssh_config` fragment (`ssh/ssh_config`)**

A repo-tracked file placed at `/etc/ssh/ssh_config.d/00-rip-cage.conf`. Verified on `debian:bookworm` (OpenSSH 9.2p1): `/etc/ssh/ssh_config` already contains `Include /etc/ssh/ssh_config.d/*.conf` above its own `Host *` defaults, so the fragment is parsed first and no fallback-to-appending is required.

```
# rip-cage: non-interactive SSH posture. See ADR-014.
Match final Host *
    UserKnownHostsFile /etc/ssh/ssh_known_hosts
    GlobalKnownHostsFile /etc/ssh/ssh_known_hosts
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
```

`Match final` applies our block during the final resolution pass, which gives our settings precedence for options **not already set** by user config — notably `UserKnownHostsFile`, `GlobalKnownHostsFile`, and `ConnectTimeout`. OpenSSH's "first value wins" rule applies across all passes including the `Match final` re-evaluation: a user-config `Host github.com` block that sets `BatchMode no` or `StrictHostKeyChecking accept-new` before our system block will **not** be overridden by `Match final`. The incident-case fix (default container with no `~/.ssh/config`) is unaffected — `Match final` is the first place these options get set, so they stick. A container where an agent or user has written a `~/.ssh/config` before SSH runs is not covered by this config-level mechanism; that scenario would require physical enforcement (e.g., a read-only `~/.ssh` bind mount). See ADR-014 D2 for the documented caveat.

`ConnectTimeout 10` bounds failure latency. Note that port 22 is *not* blocked by ADR-012's egress firewall — see the "Interaction with existing ADRs" section — so the TCP handshake to `github.com:22` succeeds, and the timeout only trips against genuinely unreachable hosts. The real non-interactive guarantee comes from `BatchMode=yes` and `StrictHostKeyChecking=yes`.

**3. Dockerfile additions**

Add near the existing `openssh-client` install (Dockerfile:23):

```dockerfile
COPY ssh/known_hosts.github /etc/ssh/ssh_known_hosts
COPY ssh/ssh_config /etc/ssh/ssh_config.d/00-rip-cage.conf
RUN chmod 0644 /etc/ssh/ssh_known_hosts /etc/ssh/ssh_config.d/00-rip-cage.conf
```

Place these with the "stable files first" COPYs near the top of the runtime stage so they don't bust the cache on every edit of `init-rip-cage.sh` or `settings.json`.

**4. `CLAUDE.md` session-close protocol rewrite**

The project-level `CLAUDE.md` currently mandates `git push` + `bd dolt push` at session end ("Work is NOT complete until `git push` succeeds", "NEVER stop before pushing"). That instruction is what drove the reproducer: the agent inherited an SSH remote, obeyed the push mandate, and hung on the first-contact prompt. ADR-014 D3 (FIRM) replaces the mandate with a push-less protocol — hand off to the human, don't push. Without this text edit, the SSH posture fix is only half the story: agents will keep attempting pushes the cage cannot complete.

The `Session Completion` block in `CLAUDE.md` is replaced with:

- Commit all changes locally.
- Produce a handoff summary (branch name, commits ahead of `origin`, work summary, anything pending).
- **Do not run `git push` or `bd dolt push` from inside the container.** Pushing is the human's responsibility on the host at the session boundary.

Every "NEVER stop before pushing" / "If push fails, resolve and retry" clause is removed.

### Interaction with existing ADRs

- **ADR-001 (fail-loud):** `BatchMode=yes` converts the "silent hang on prompt" failure into an immediate non-interactive error. Direct compliance.
- **ADR-002 (blast radius):** No credential material is introduced. `/etc/ssh/ssh_known_hosts` is public data — identical to what GitHub publishes. No mount changes.
- **ADR-012 (egress firewall):** ADR-012's L7 proxy intercepts TCP 80/443 only (verified: `init-firewall.sh` REDIRECTs `--dport 443` and `--dport 80`; `egress-rules.yaml` has no port entries). Non-HTTP egress remains allowed in the default posture, so the TCP connection to `github.com:22` succeeds. This design's protections (`BatchMode`, `StrictHostKeyChecking`, pinned `known_hosts`) are therefore the only guards — the firewall does not provide a belt-and-suspenders layer for SSH. If the egress override is in effect (`RIP_CAGE_EGRESS=off` per ADR-012 D6), or if a future bot-identity scenario introduces a host that *is* allowlisted, this design's posture still guarantees non-interactive behavior.
- **ADR-013 (test-coverage):** Tier 1 asserts land in `tests/test-safety-stack.sh`. Tier 2 asserts target `tests/test-e2e-lifecycle.sh` (to be created per ADR-013 D3 P1); if that file doesn't yet exist when this lands, the Tier 2 assert goes into `tests/test-integration.sh` as a temporary landing spot with a comment flagging the ADR-013 D3 move target.
- **ADR-014 D1 (push-less cage):** This design supports D1 by ensuring the failure mode of any stray SSH attempt is immediate and observable, not interactive.
- **ADR-014 D3 (push-less session-close):** Implemented directly by the `CLAUDE.md` rewrite (Design change 4 above). This is what closes the instruction/architecture incoherence ADR-014 named.
- **ADR-014 Deferred (SSH-agent forwarding escape valve):** If that valve ever lands, a forwarded user's `~/.ssh/config` could override `BatchMode` and `StrictHostKeyChecking` in our system fragment (OpenSSH "first value wins" applies even under `Match final` for options the user-config already sets). Real enforcement in that scenario would require a read-only `~/.ssh` bind mount, not config-level precedence.

## Verification

New test cases, tiered per ADR-013:

**Tier 1 (safety-stack, runs inside container):**

- `ssh -G github.com | grep -E '^batchmode yes$'` — confirms `BatchMode=yes` is resolved.
- `ssh -G github.com | grep -E '^stricthostkeychecking (yes|true)$'` — confirms strict host-key checking. OpenSSH 9.2 on Debian bookworm normalizes `yes` to `true` in `ssh -G` output; accept either.
- `ssh -G github.com | grep -E '^userknownhostsfile /etc/ssh/ssh_known_hosts$'` — confirms pinned user-known-hosts file.
- `ssh -G github.com | grep -E '^globalknownhostsfile /etc/ssh/ssh_known_hosts$'` — confirms pinned global-known-hosts file (symmetry with the user side).
- `grep -q '^github.com ssh-ed25519 ' /etc/ssh/ssh_known_hosts` — confirms the pinned key is present.
- **Override-resistance:** plant a hostile `~/.ssh/config` with `Host github.com\n  StrictHostKeyChecking accept-new\n  BatchMode no`, then assert `ssh -G github.com | grep -E '^batchmode yes$'` still holds. This is the regression test for `Match final`; if someone changes the fragment back to `Host *` this test fails loudly.
- **`CLAUDE.md` push-less (2 check() calls):** (N7a) assert `/workspace/CLAUDE.md` contains no push-mandate regex (`git push.*(succeeds|required|mandatory|must)`); (N7b) assert no `bd dolt push` literal (both are removed by the ADR-014 D3 rewrite). These are text-level guards against the old mandate being reintroduced.

**Tier 2 (integration, requires network):**

- `GIT_SSH_COMMAND='ssh -o ConnectTimeout=5' ssh -T git@github.com; [ $? -ne 0 ]` with output **not** containing `"Are you sure you want to continue connecting"`. Under the default egress posture the TCP connect succeeds (port 22 isn't intercepted) and the agent gets `Permission denied (publickey)` — that's the expected exit path. The interactive prompt is not acceptable.

**Regression target:** re-running the exact reproducer from the opening prompt of this doc should not hang. It should exit non-zero within `ConnectTimeout + epsilon` seconds.

## Implementation sketch

Files to add/change:

- **New** `ssh/known_hosts.github` — pinned GitHub SSH host keys with provenance comment header (source URL, fetch date, SHA256_ED25519 fingerprint, refresh-script path).
- **New** `ssh/ssh_config` — system SSH client config fragment using `Match final Host *`.
- **New** `scripts/refresh-github-known-hosts.sh` — fetches `api.github.com/meta` and rewrites `ssh/known_hosts.github`. Manual invocation only; not wired into build.
- **Edit** `Dockerfile` — two `COPY` lines + `chmod`, placed near the existing `openssh-client` install (line ~23) in the "stable files" block.
- **Edit** `/workspace/CLAUDE.md` — replace the `Session Completion` block with the push-less protocol (ADR-014 D3). Remove every `git push` / `bd dolt push` / "NEVER stop before pushing" clause.
- **Edit** `tests/test-safety-stack.sh` — add the seven Tier 1 checks (five `ssh -G` asserts, the pinned-key presence check, the override-resistance test, and the CLAUDE.md text guard).
- **Edit** `tests/test-e2e-lifecycle.sh` (per ADR-013 D3 P1) — add the Tier 2 non-interactive-failure check. If `test-e2e-lifecycle.sh` doesn't exist yet when this lands, add the assert to `tests/test-integration.sh` as a temporary home with a comment flagging the move target.

No changes to:

- `init-rip-cage.sh` — this is purely build-time configuration.
- `rc` — no flags, no detection logic.
- `settings.json` — no Claude Code surface involvement.

## Risks and open questions

- **GitHub SSH host-key rotation.** GitHub last rotated its RSA key in 2023. When it happens again, `ssh -T git@github.com` will fail with a host-key-verification error even from inside the cage, and the Dockerfile needs a new `known_hosts.github` + image rebuild. `scripts/refresh-github-known-hosts.sh` makes that a one-command refresh. Acceptable cost, low frequency. Documented in ADR-014 D2 "What would invalidate this."
- **User-file override of system SSH config.** OpenSSH's normal "first value wins" ordering means a `~/.ssh/config` the agent writes after the fact could override `BatchMode` and `StrictHostKeyChecking` — the exact TOFU regression ADR-014 D2 rejected. Mitigated by `Match final Host *` (defers our settings to the last resolution step). The override-resistance Tier 1 test guards this. A residual risk remains: `GIT_SSH_COMMAND` with explicit `-o BatchMode=no -o StrictHostKeyChecking=accept-new` *does* override `Match final` (command-line beats config). Accepted: the agent would have to pass that explicitly, which is a deliberate act, not an accidental hang.
- **Other hosts.** The pinned `known_hosts` only covers github.com. Other hosts an agent might reach (gitlab, bitbucket, a private git server) will hit `StrictHostKeyChecking=yes` with no entry → immediate failure. That is the correct behavior under ADR-014 D1 (no outbound push credentials anyway), but worth stating explicitly so future contributors don't file it as a bug.
- **Git submodules.** A `git clone --recurse-submodules` or `git submodule update` against a repo whose submodule URLs use SSH will hit the same pinned-host posture: github.com submodules succeed up to the credential wall, other-host submodules fail immediately on host-key verification. Fails loudly, which is the right outcome under ADR-001.

## Not doing

- Runtime `ssh-keyscan` at `init-rip-cage.sh` — rejected (TOFU-on-first-fetch; depends on egress at init; doesn't compose with ADR-012).
- `StrictHostKeyChecking=accept-new` — rejected (silent TOFU).
- Any key material inside the container — explicitly forbidden by ADR-014 D1.
- Rewriting SSH remotes to HTTPS automatically — considered, rejected for now. It's a larger UX change that belongs in a dedicated ADR if it ever lands; the push-less model makes it unnecessary because the agent isn't expected to push regardless of remote protocol.

