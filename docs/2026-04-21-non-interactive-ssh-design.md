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

`Match final` evaluates after all other config is loaded, so this block gives the system policy last-word precedence over anything the agent might later write into `~/.ssh/config` (or pass via `GIT_SSH_COMMAND` without `-o` overrides). OpenSSH's normal "first value wins" ordering would let a user-file `Host github.com` block override `BatchMode` and `StrictHostKeyChecking` — the TOFU regression ADR-014 D2 rejected. `Match final` prevents that by deferring our settings until last, where they win as the final resolution step. This mirrors the pattern in ADR-002 D11 (move enforcement from defeatable config to authoritative substrate).

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
- **ADR-012 (egress firewall):** The firewall's default allowlist doesn't include github.com:22. An SSH attempt will fail at the network layer *before* host-key verification matters. This design is belt-and-suspenders: even if the firewall is off (`rc up --egress=off`), or if the connection is to a host that *is* allowlisted (some future bot-identity scenario), the posture is still non-interactive.
- **ADR-014 D1 (push-less cage):** This design supports D1 by ensuring the failure mode of any stray SSH attempt is immediate and observable, not interactive.

## Verification

New test cases, tiered per ADR-013:

**Tier 1 (safety-stack, runs inside container):**

- `ssh -G github.com | grep -E '^batchmode yes$'` — confirms `BatchMode=yes` is resolved.
- `ssh -G github.com | grep -E '^stricthostkeychecking yes$'` — confirms strict host-key checking.
- `ssh -G github.com | grep -E '^userknownhostsfile /etc/ssh/ssh_known_hosts$'` — confirms pinned file.
- `grep -q '^github.com ssh-ed25519 ' /etc/ssh/ssh_known_hosts` — confirms the pinned key is present.

**Tier 2 (integration, requires network):**

- `GIT_SSH_COMMAND='ssh -o ConnectTimeout=5' ssh -T git@github.com; [ $? -ne 0 ]` with output **not** containing `"Are you sure you want to continue connecting"`. The command should exit non-zero (no credentials), and the output should be either `Permission denied (publickey)` (if port 22 reachable) or a timeout error (if egress firewall blocks it). Either is acceptable; the interactive prompt is not.

**Regression target:** re-running the exact reproducer from the opening prompt of this doc should not hang. It should exit non-zero within `ConnectTimeout + epsilon` seconds.

## Implementation sketch

Files to add/change:

- **New** `ssh/known_hosts.github` — pinned GitHub SSH host keys (public data, 3 lines).
- **New** `ssh/ssh_config` — system SSH client config fragment.
- **Edit** `Dockerfile` — two `COPY` lines + `chmod`. Place with "stable files" block.
- **Edit** `tests/test-safety-stack.sh` — add the four Tier 1 checks.
- **New or edit** `tests/test-integration.sh` (if it exists for Tier 2 SSH checks) — add the non-interactive-failure check.

No changes to:

- `init-rip-cage.sh` — this is purely build-time configuration.
- `rc` — no flags, no detection logic.
- `settings.json` — no Claude Code surface involvement.

## Risks and open questions

- **GitHub SSH host-key rotation.** GitHub last rotated its RSA key in 2023. When it happens again, `ssh -T git@github.com` will fail with a host-key-verification error even from inside the cage, and the Dockerfile needs a new `known_hosts.github` + image rebuild. Acceptable cost, low frequency. Documented in ADR-014 D2 "What would invalidate this."
- **Debian's ssh_config.d handling.** Debian bookworm's default `/etc/ssh/ssh_config` includes `Include /etc/ssh/ssh_config.d/*.conf` at the top. Verify during implementation that the fragment path works; fall back to appending to the main file if not.
- **Other hosts.** The pinned `known_hosts` only covers github.com. Other hosts an agent might reach (gitlab, bitbucket, a private git server) will hit `StrictHostKeyChecking=yes` with no entry → immediate failure. That is the correct behavior under ADR-014 D1 (no outbound push credentials anyway), but worth stating explicitly so future contributors don't file it as a bug.

## Not doing

- Runtime `ssh-keyscan` at `init-rip-cage.sh` — rejected (TOFU-on-first-fetch; depends on egress at init; doesn't compose with ADR-012).
- `StrictHostKeyChecking=accept-new` — rejected (silent TOFU).
- Any key material inside the container — explicitly forbidden by ADR-014 D1.
- Rewriting SSH remotes to HTTPS automatically — considered, rejected for now. It's a larger UX change that belongs in a dedicated ADR if it ever lands; the push-less model makes it unnecessary because the agent isn't expected to push regardless of remote protocol.

## Review Pass 1 Findings

### ADRs reviewed

Full triage of `docs/decisions/ADR-*.md`:

- **ADR-001 (fail-loud)** — directly relevant. BatchMode converts a silent hang into an immediate error, which is the spirit of ADR-001. Design handles this well.
- **ADR-002 (rip-cage containers / blast radius)** — relevant. D8 ("dev credentials only, not .env mounting") and D11 (read-only bind mounts for `.git/hooks`) establish the pattern: anything exploitable goes into physical enforcement, not config. Relevant to Finding 2 below.
- **ADR-003 (agent-friendly CLI)** — peripheral. No conflict.
- **ADR-004 (phase-1 hardening)** — peripheral. No conflict.
- **ADR-005 (ecosystem tools)** — not relevant.
- **ADR-006 (multi-agent architecture)** — not relevant.
- **ADR-007 (beads-dolt-container-resilience)** — peripheral. `bd dolt push` is covered by ADR-014 D3 push-less policy.
- **ADR-008 (open-source publication)** — peripheral.
- **ADR-009 (UX overhaul)** — peripheral.
- **ADR-010 (auth-refresh)** — noted by ADR-014 as the integration point for a future bot-identity ADR. No conflict with this design.
- **ADR-011 (shell-completions)** — not relevant.
- **ADR-012 (egress firewall)** — **directly relevant and materially misrepresented in this design.** See Finding 3.
- **ADR-013 (test-coverage)** — directly relevant. D3 Implementation note says `tests/test-integration.sh` is to be superseded/deleted. See Finding 6.
- **ADR-014 (push-less cage, paired)** — directly relevant. Design covers D1 and D2 but is silent on D3's deliverable. See Finding 1.

### Findings

**Finding 1 — Missing D3 deliverable: CLAUDE.md update is not in the design [ARCH]**

ADR-014 D3 (FIRM) mandates rewriting the project-level `CLAUDE.md` session-close protocol: "no `git push` or `bd dolt push` attempted from inside the container." Verified against `/workspace/CLAUDE.md`: lines 91–113 currently read the opposite — "Work is NOT complete until `git push` succeeds", "NEVER stop before pushing", an explicit `bd dolt push` + `git push` sequence, and "If push fails, resolve and retry until it succeeds". The design doc enumerates implementation changes (Dockerfile, ssh files, tests) but does not list the CLAUDE.md rewrite as a deliverable, and its "Interaction with existing ADRs" section only cites ADR-014 D1. The agent instructions will keep producing the ADR-014 hang until the CLAUDE.md text is replaced.

Fix: add an explicit `Implementation sketch` entry: "Edit `/workspace/CLAUDE.md` — replace the `Session Completion` block (lines ~83–115) with the push-less protocol from ADR-014 D3. Remove every `git push` / `bd dolt push` / 'NEVER stop before pushing' mandate; add 'hand off, don't push' language and the handoff-summary requirement." Add a verification step confirming the CLAUDE.md no longer contains the phrases `"git push" succeeds` or `bd dolt push`.

**Finding 2 — `Host *` fragment is silently overridable by any agent-written `~/.ssh/config` [ARCH]**

OpenSSH parse order is: command-line → user file → system file, with **first value wins**. I verified this in the running cage by copying the proposed fragment and adding a user-file simulation with `Host github.com\n  StrictHostKeyChecking accept-new\n  BatchMode no`: `ssh -G` resolved `batchmode no` and `stricthostkeychecking accept-new`. The agent has no `~/.ssh` today (verified: `/home/agent/.ssh` does not exist), but under bypassPermissions (ADR-002 D5) nothing stops the agent from `mkdir ~/.ssh; printf ... > ~/.ssh/config` or from passing `GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new -o BatchMode=no'`. The design's sentence "Users inside the container can override per-host in `~/.ssh/config`" is not a documented tradeoff — it's the exact TOFU regression ADR-014 D2 rejects as an alternative.

This is the same class of problem as D11 in ADR-002: settings.json denies were defeated by Python `open()`, so the enforcement was moved from config to a physical `:ro` sub-mount. The parallel fix here is to either (a) use `Match final` so the system policy wins over user-file `Host` blocks, (b) bind-mount `/etc/ssh/ssh_config.d/00-rip-cage.conf:ro` so the agent can't even edit the system file, or (c) combine the fragment with `GIT_SSH_COMMAND` hardening via `/etc/profile.d/`. `Match final Host *` with `BatchMode yes` + `StrictHostKeyChecking yes` is a one-line change that gives the system fragment last-word precedence. Worth a Risks entry at minimum, and ideally an enforcement change.

Fix: add a Risks bullet naming the bypass vector. Strengthen the fragment with `Match final Host *` rather than `Host *`. Add a Tier 1 test that plants a hostile `~/.ssh/config` and asserts `ssh -G github.com` still resolves `batchmode yes`.

**Finding 3 — ADR-012 claim is wrong: port 22 is NOT blocked by the egress firewall**

Design says: "ADR-012 doesn't allowlist port 22 in the default posture. An SSH attempt will fail at the network layer *before* host-key verification matters." Verified by reading ADR-012 D2 ("Intercept HTTPS at layer 7 via a transparent TLS-terminating proxy") and its "Open: non-HTTP egress scope" section ("the current design intercepts TCP 80/443 only… Tentative position: non-HTTP egress remains allowed"). Confirmed empirically inside the running cage: `timeout 5 bash -c 'exec 3<>/dev/tcp/github.com/22'` returns exit 0 (connection established). Also verified `/workspace/init-firewall.sh` only adds REDIRECT rules for TCP 443/80 and a DROP for UDP 443; nothing touches TCP 22. Also verified `/workspace/egress-rules.yaml` has no port-based entries — it's pure L7 host+path rules.

So `ConnectTimeout 10` is not "bounding a network-layer timeout we'd otherwise hit"; port 22 connects instantly and OpenSSH proceeds to host-key verification. The design's belt-and-suspenders rationale stands (BatchMode + StrictHostKeyChecking are still the real guards), but the ADR-012 claim and the egress-firewall bullet need rewriting. This also changes the Tier 2 test expectations: the "timeout error if egress firewall blocks it" outcome will not happen under the default posture — only `Permission denied (publickey)` (with no creds mounted, there's no publickey, so actually `Permission denied (publickey)` after TCP connect + host-key match) or the hypothetical StrictHostKeyChecking failure.

Fix: correct the ADR-012 interaction paragraph — say "ADR-012's L7 proxy doesn't touch port 22; the TCP connection to github.com:22 succeeds. This design's protections (BatchMode, StrictHostKeyChecking, pinned known_hosts) are the only guards." Update the Tier 2 expected-output list accordingly. Also note that ADR-013 D4 P3 proposes an iptables-rule assertion that non-HTTP egress remains allowed — so this design and D4 P3 are consistent, but the doc must match reality.

**Finding 4 — `ssh -G` output uses `true`, not `yes`; two Tier 1 asserts will fail as written**

Verified in the cage: `OpenSSH_9.2p1 Debian-2+deb12u9`. With the proposed fragment loaded via `ssh -F`, `ssh -G github.com` outputs `stricthostkeychecking true` (not `yes`). The design's check `ssh -G github.com | grep -E '^stricthostkeychecking yes$'` will always fail. `batchmode` resolves to `yes` so that one is fine. `userknownhostsfile` resolves to exactly `/etc/ssh/ssh_known_hosts` so that one is fine. The `globalknownhostsfile` is not in the design's grep list but the design sets both — add the assert for symmetry.

Fix: change the strict-host-key-checking assert to `grep -E '^stricthostkeychecking (yes|true)$'` or simply `grep -E '^stricthostkeychecking yes|true'`. Add a `globalknownhostsfile /etc/ssh/ssh_known_hosts$` assert. Verify all asserts via `ssh -G -F <fragment-under-test>` during implementation, not against production `/etc/ssh/`.

**Finding 5 — GitHub API key format matches, BUT there's no drift-detection guard**

Confirmed the three `ssh_keys` values in the design match the live response from `https://api.github.com/meta` as of 2026-04-21 (pulled during review: ED25519/ECDSA/RSA byte-for-byte identical; SHA256_ED25519 fingerprint matches `+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`). The design acknowledges rotation as a manual refresh, but has no mechanism to detect drift before a real rotation causes a hard failure:

- No scripted refresh path (`make refresh-known-hosts` or similar)
- No CI check that diffs the committed file against `api.github.com/meta`
- Comment header on `ssh/known_hosts.github` is not specified — just "3 lines" — leaving no trace of when/where/how it was generated

Fix: add to Implementation sketch: "`ssh/known_hosts.github` has a comment header naming the source URL, fetch date, and the SHA256_ED25519 fingerprint from the `meta` endpoint." Add a trivial `scripts/refresh-github-known-hosts.sh` (or a `make` target) that fetches `api.github.com/meta` and rewrites the file. Optionally: a `rc test --host` check that compares committed bytes to live bytes with network — non-fatal warn, not block, to catch drift during routine test runs.

**Finding 6 — Tier 2 test placement conflicts with ADR-013 D3**

Design says: "**New or edit** `tests/test-integration.sh` (if it exists for Tier 2 SSH checks)". Verified `tests/test-integration.sh` exists (99 lines, runs on host). ADR-013 D3 "Implementation notes" item 2 says: "Write `tests/test-e2e-lifecycle.sh` + `rc test --e2e` (P1 — biggest coverage gain). **Supersedes `tests/test-integration.sh`; absorb its unique checks and delete it.**" So adding to `test-integration.sh` wires the SSH check into a file that ADR-013 plans to delete, and into a path (`--e2e`) that doesn't yet exist.

Fix: reword the Implementation sketch Tier 2 entry to: "New asserts in `tests/test-e2e-lifecycle.sh` (to be created per ADR-013 D3 P1). If `test-e2e-lifecycle.sh` doesn't exist yet when this design lands, add the assert to `tests/test-integration.sh` as a temporary landing spot with a comment flagging the move target." This avoids conflict and makes the dependency explicit.

**Finding 7 — Design has no mention of what happens with `~/.ssh` bind mounts the user may add later [ARCH]**

ADR-014 D1 forbids mounting `~/.ssh`, and the current `rc` has no flag for it. But the Deferred section of ADR-014 names "SSH-agent forwarding as an opt-in escape valve" — which, if ever implemented, silently inherits whatever `StrictHostKeyChecking` the user's host has configured (often `ask` or `accept-new`). When that day comes, the system fragment's pinned `known_hosts` helps, but only if `Match final` (Finding 2) is in place so a forwarded user's `~/.ssh/config` doesn't override it. Worth one sentence in "Interaction with existing ADRs" naming this forward-compatibility.

Fix: add a bullet to the ADR-014 interaction block: "If the Deferred 'SSH-agent forwarding' escape valve ever lands (ADR-014 Deferred), a forwarded user's `~/.ssh/config` may re-introduce `StrictHostKeyChecking=ask`. The `Match final` fragment (see Finding 2) is what preserves the posture under that future flag." This is cheap foresight.

**Finding 8 — Debian bookworm Include ordering is fine, but the verification step should be in the doc**

Open question called out in the design ("Debian's ssh_config.d handling") is resolvable *now*, not "during implementation". Verified: `/etc/ssh/ssh_config` on `debian:bookworm` (OpenSSH 9.2p1 Debian-2+deb12u9) contains `Include /etc/ssh/ssh_config.d/*.conf` on a line preceding the commented `Host *` defaults. An empty `/etc/ssh/ssh_config.d/` exists with mode `0755` root:root. The fragment at `/etc/ssh/ssh_config.d/00-rip-cage.conf` will be parsed before the (commented) `Host *` block in the main file, so the fragment wins. No fallback-to-appending is required.

Fix: replace the open question with a verified statement: "Verified on `debian:bookworm` (OpenSSH 9.2p1): `/etc/ssh/ssh_config` includes `/etc/ssh/ssh_config.d/*.conf` before its own `Host *` block. The fragment path works without fallback." Removes one "TODO during implementation" that can already be closed.

**Minor: Dockerfile line reference — current openssh-client lives on line 23, not 24**

Design says "Add near the existing `openssh-client` install (Dockerfile:24)". `/workspace/Dockerfile:23` is the correct line. Not load-bearing; fix on the next edit.

**Minor: egress flag syntax**

Design's ADR-012 paragraph mentions `rc up --egress=off`. Verified `rc`: the actual override is the `RIP_CAGE_EGRESS=off` env var (ADR-012 D6). There is no `--egress` flag. Change the parenthetical to `RIP_CAGE_EGRESS=off`.

**Minor: git submodules are not addressed**

Git submodules with SSH URLs (`git@github.com:org/submodule.git`) will trigger the same failure mode on a recursive clone/update. The design's pinned `known_hosts.github` plus `StrictHostKeyChecking=yes` + `BatchMode=yes` means submodule init will fail loudly and early (good — ADR-001 compliance) with `Permission denied (publickey)` or similar. Worth a one-line acknowledgement in "Other hosts" or a new "Submodules" bullet so future readers don't re-file it.

### Verdict

**REFINED.** The design's core approach (pinned `known_hosts` + `BatchMode=yes` + `StrictHostKeyChecking=yes` in an image-build-only change) is sound and aligns cleanly with ADR-001, ADR-002, and ADR-014 D1/D2. The mechanism is verified to work (confirmed the fragment resolves correctly under `ssh -G` in the running cage).

Blocking issues to fix before implementation:

1. **Add CLAUDE.md rewrite as a first-class deliverable** (Finding 1) — without it, ADR-014 D3 is paper-only and the hang recurs.
2. **Correct the ADR-012 claim** (Finding 3) — port 22 is open; rewrite that paragraph and the Tier 2 expected-output list.
3. **Fix the `stricthostkeychecking yes` grep** (Finding 4) — the test will always fail as written under OpenSSH 9.2.
4. **Harden against user-file override** (Finding 2) — use `Match final Host *` to make the system policy authoritative, and add a Tier 1 test that asserts the override doesn't work. Non-blocking if flagged as accepted risk, but a one-line change gives real enforcement parity with the physical mounts used elsewhere.

Non-blocking refinements: Findings 5, 6, 7, 8 and the three Minor items.
