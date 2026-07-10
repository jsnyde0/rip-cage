# ADR-022: SSH host + key allowlist as the first `.rip-cage.yaml` consumer

**Status:** Accepted — D1–D4 shipped (`rip-cage-b0c`); D5 hook-layer added 2026-05-12 (`rip-cage-nww`) closing the OpenSSH CLI-override class; D4 mount-path corrected 2026-05-13 (`rip-cage-g2q`) so the filtered cache is actually read by ssh; D6 host-side hot-reload added 2026-05-13 (`rip-cage-ocn`) for `allowed_hosts` content changes

> **Migration status (ADR-029, 2026-07-10):** All decisions D1–D6 are retired per [ADR-029](ADR-029-msb-migration.md) D3 — the entire ssh cluster (host+key allowlist) retires in favor of HTTPS + `--secret` credential injection. The mechanisms below remain shipped and load-bearing in the Docker path until the msb cutover release lands; until then this ADR describes current behavior.

**Date:** 2026-05-12
**Design:** [Design doc](../design/2026-05-12-ssh-allowlist-design.md); [D6 design (rc reload)](../../history/2026-05-13-rc-reload-design.md)
**Builds on:** [ADR-021](ADR-021-layered-rip-cage-config.md) (`.rip-cage.yaml` substrate), [ADR-020](ADR-020-ssh-identity-routing.md) (config translation, pubkey mount), [ADR-018](ADR-018-macos-ssh-agent-discovery.md) (host-side socket discovery), [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (forward-by-default)
**Edits in place per the in-place-evolution convention** (the global methodology rule that ADRs reflect target architecture — edits land in place, no supersession chains; see bead `rip-cage-bwwm` for the in-repo cross-repo namespace decision)**:** ADR-014 D2 caveat (line 79), ADR-014 D2 directive list (dual-file `UserKnownHostsFile`, 2026-05-13), ADR-020 D1 (mount description), ADR-020 D2 transform 5
**Related:** [ADR-001](ADR-001-fail-loud-pattern.md) (loud + actionable failure), project [CLAUDE.md](../../CLAUDE.md) philosophy section ("layers, not walls"; "80/20, not 100/0")

## Context

ADR-014 D2 introduced an image-baked `/etc/ssh/ssh_known_hosts` (github.com pins) plus a system `ssh_config` setting `UserKnownHostsFile=/etc/ssh/ssh_known_hosts`, intended as a non-interactive SSH posture defaulting to "github.com only." Its caveat at line 79 honestly named the reach limit: `Match final Host *` does not defeat explicit CLI `-o` flags or per-Host user-config values.

ADR-020 D2 transform 5 was added to defend D2's posture at the per-Host translation layer (rewrite user-config `UserKnownHostsFile` directives back to the image-baked file). It defends against per-Host *config* overrides but not against CLI `-o`. Combined with ADR-020 D1's wholesale `~/.ssh/known_hosts` mount, the result is: the file the rewrite redirects *away from* is mounted right next to the file it redirects *to*. Any caller passing `-o UserKnownHostsFile=~/.ssh/known_hosts` walks past the rewrite to the mounted file and reaches every host the user has ever pinned.

Confirmed 2026-05-11 in `~/code/personal/kinky-bubbles`: `ssh -o UserKnownHostsFile=~/.ssh/known_hosts switch.berlin` succeeds. The ADR-014 D2 caveat predicted exactly this.

The deeper architectural point: the cage controls two SSH-relevant capabilities, both at the mount layer — the `known_hosts` file content visible inside the cage, and the ssh-agent socket exposed inside the cage. Scoping at the *config* layer (transform 5) is at best a hint a polite caller will respect; scoping at the *mount* layer is enforcement, because there is no `-o` flag that can re-mount a file.

ADR-021 shipped the `.rip-cage.yaml` substrate (`rip-cage-o4z`). It explicitly anticipated this bead at three points:
- Line 14: "the downstream consumer (`rip-cage-b0c` SSH host+key allowlist) is what will actually replace ADR-014 D2's `known_hosts` rewrite with capability scoping."
- Line 257: "the right time to tighten defaults is when a downstream consumer ships, not when the substrate ships."
- Lines 67–68: pre-defined `ssh.allowed_hosts` as additive_list and `ssh.allowed_keys` as selection_list with full merge semantics.

This ADR is that consumer.

## Decisions

### D1: Schema — `ssh.allowed_hosts` (additive_list) + `ssh.allowed_keys` (selection_list)

> [ADR-029 D3: RETIRED — the ssh cluster retires wholesale; `.rip-cage.yaml` no longer carries `ssh.allowed_hosts`/`ssh.allowed_keys` at cutover. Per-project git identity selection survives, re-homed to a token-selection design (see D6's carry-forward below).]

**Firmness: FIRM**

`.rip-cage.yaml` and `~/.config/rip-cage/config.yaml` may declare:

```yaml
version: 1
ssh:
  allowed_hosts:
    - github.com
    - switch.berlin
    - "*.internal.example.com"
  allowed_keys:
    - id_ed25519_work
```

Per ADR-021 D2 merge rules:
- `allowed_hosts` is **additive_list** — global ∪ project, deduplicated, order-preserving.
- `allowed_keys` is **selection_list**, three-state — absent ⇒ inherit; non-empty ⇒ replace; `[]` ⇒ explicit zero-out.

`allowed_hosts` patterns mirror OpenSSH `known_hosts` semantics: exact, `*`/`?` wildcards, `[host]:port`, comma-separated host lines split per-host. Negation (`!host`) is **not supported** — composition footgun; users can omit entries instead.

`allowed_keys` matches by key **comment** (the trailing field of the `.pub` line, e.g. `id_ed25519_work`). Comment-matching maps cleanly to the established `id_ed25519_<role>` naming convention. Fingerprint matching is supported by the underlying tool (`ssh-agent-filter`) and may be added in a follow-up; v1 ships comment-only.

**Rationale:** Schema and merge semantics were settled in ADR-021 D2; this decision pins them as the v1 contract for downstream consumers and tooling. Comment-matching trades a small loss in robustness (key comments can collide; fingerprints can't) for a large gain in legibility (humans read comments, not fingerprints) — appropriate for the brevity-over-precision sweet spot rip-cage already lives in.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Filter by SHA256 fingerprint | `reasoned:` Robust but unreadable; user can't audit `.rip-cage.yaml` against memory. Add as opt-in if comment collisions show up in practice. |
| Per-destination scoping (`{host: github.com, keys: [id_ed25519_work]}`) | `reasoned:` Already provided at the config layer by ADR-020 D4 + `IdentitiesOnly yes`. Re-implementing here would duplicate D4 with worse ergonomics. |
| Single flat list mixing hosts and keys | `direct:` ADR-021 D2 distinguishes additive from selection list precisely because they have different blast-radius semantics; merging them violates D2. |

**What would invalidate this:** key-comment collisions become a routine source of misconfiguration. Promote fingerprint matching from "follow-up" to "v2 default."

### D2: Defaults — host arrow locks down; key arrow stays open

> [ADR-029 D3: RETIRED — both arrows retire with the ssh cluster. The "what would invalidate this" concern below (open-by-default key-arrow polarity) resolves by elimination: HTTPS + `--secret` forwards no keys at all, so there is no key arrow left to be open or closed by default.]

**Firmness: FIRM**

When neither layer declares `ssh.allowed_hosts`:
- The filtered `~/.ssh/known_hosts` mounted into the cage is **empty**.
- The image-baked `/etc/ssh/ssh_known_hosts` (github.com pins) remains the floor.
- Net effect: the cage trusts github.com only, regardless of `-o UserKnownHostsFile=~/.ssh/known_hosts` (the file inside is empty).

When neither layer declares `ssh.allowed_keys`:
- The host ssh-agent socket is bind-mounted directly to `/ssh-agent.sock` (today's behavior preserved).
- All keys in the host agent are usable, but only against hosts in `allowed_hosts`.

**Rationale:** The two arrows compose multiplicatively. Locking the host arrow alone closes the 2026-05-11 bypass at the source — the only host trust visible inside the cage is what the user explicitly authorizes via `allowed_hosts` (plus the github.com floor). Keeping the key arrow fully open by default preserves the "your existing workflow, caged" promise: today's pushes keep working without any `.rip-cage.yaml` authoring. Users who want to narrow further opt in by listing `allowed_keys`.

This deliberately tightens behavior on rc upgrade for users who currently SSH to non-github.com hosts via the cage. ADR-021 line 257 anticipated this — "the right time to tighten defaults is when a downstream consumer ships." Mitigation: `rc config init` (rip-cage-97n) inspects `git remote -v` + `ssh -G <host>` (with an `ssh-add -L` comment-and-basename fallback) and writes a starter `.rip-cage.yaml` interactively. `rc up` prints a 1-line tip pointing at the wizard whenever a workspace lacks a project-level config but has at least one SSH remote, so the upgrade-tighten path is discoverable from the dominant CLI surface (not just `rc init` / VS Code).

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Both arrows lock down by default (no agent forwarding either when `allowed_keys` absent) | `direct:` Breaks today's `git push` for everyone on rc upgrade. Per CLAUDE.md ("'It's annoying' is a design signal"), gating the legitimate path on opt-in config is exactly the friction the cage avoids. |
| Both arrows stay open (preserve all of today's behavior) | `direct:` Defeats the bead's purpose. The 2026-05-11 bypass remains; ADR-014 D2 caveat stays unfulfilled; the substrate's first consumer ships zero capability change. |
| Host arrow locks, key arrow auto-narrows to "first key whose comment matches the project's git remote" | `reasoned:` Magic — can't tell from a comment which key actually authenticates where; one heuristic away from the wrong-identity bug ADR-020 D3 exists to prevent. |

**What would invalidate this:** users routinely tightening `allowed_keys` to `[]` (cage shouldn't push) or to a single key (cage shouldn't see the others) frequently enough that "open by default" feels like the wrong polarity. At that point, flip to "all-narrow-by-default, full-forward opt-in."

### D3: Mechanism — `ssh-agent-filter` for the agent half; bash + openssl HMAC for the host half

> [ADR-029 D3: RETIRED — `ssh-agent-filter`, the host-side HMAC known_hosts filter, and the socket-symlink launcher all retire; no agent-half or host-half mechanism survives, since no ssh credential crosses the boundary under HTTPS + `--secret`.]

**Firmness: FIRM**

**Agent half — `ssh-agent-filter` (Debian package `ssh-agent-filter`)**. A small C++ program that speaks the ssh-agent wire protocol, applies a comment- or fingerprint-based filter, and forwards matching requests to an upstream agent named via the `SSH_AUTH_SOCK` env var. Already packaged for Debian/Ubuntu; install via `apt-get install -y ssh-agent-filter` in the runtime stage of the Dockerfile. The package also ships a sibling binary `afssh` — that one is a one-shot wrapper that starts the filter, runs `ssh -A` once, and tears the filter down on ssh exit; it is **not** the daemon and is not used here. `init-rip-cage.sh` starts `ssh-agent-filter` when the in-cage sentinel `/etc/rip-cage/ssh-allowed-keys` signals filtering: from an agent-owned working directory (`/tmp/rip-cage-filter/`), invoke `SSH_AUTH_SOCK=/ssh-agent-upstream.sock ssh-agent-filter --comment c1 --comment c2 ...`. The daemon forks, picks `$PWD/agent.<PID>` as its socket path, and prints the path + PID to stdout (matching `ssh-agent`'s contract). `init` parses that output and `sudo ln -sfT <parsed-sock> /ssh-agent.sock` so the cage's existing `SSH_AUTH_SOCK=/ssh-agent.sock` contract holds without needing every consumer to learn a new path.

**Host half — bash + awk + openssl**. `rc up` calls `_filter_known_hosts` on the host: read `~/.ssh/known_hosts`, apply `allowed_hosts` patterns line-by-line, write to `~/.cache/rip-cage/<container>/known_hosts`. Bind-mount that into the cage at `~/.ssh/known_hosts` (read-only). For hashed entries (`|1|salt|hash`), compute HMAC-SHA1 via `openssl dgst -sha1 -mac HMAC -macopt hexkey:<salt>` against each exact `allowed_hosts` pattern; matches get unhashed and included. Wildcard patterns can't be exhaustively HMAC'd against unknown hashed entries → emit a warning naming the pattern and the `ssh-keyscan` workaround.

**Rationale:** `ssh-agent-filter` exists, is mature, and matches the sketch exactly — using it is a library choice, not a build project. ~70 LOC of bash to drive it (parse stdout, manage the symlink) vs ~200 LOC of new Python + a new ADR for the protocol implementation. The host-side filter is small enough (≈50 LOC awk + ≈20 LOC openssl HMAC) that bash without new dependencies wins on simplicity over a vendored Python helper.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Custom Python ssh-agent proxy daemon | `reasoned:` ~200 LOC of binary protocol implementation when a packaged tool exists; ongoing maintenance surface for a problem someone else already solved. |
| Per-identity agent multiplexer (ssh-ident pattern) | `direct:` Requires private keys as files in the cage, violating ADR-017 D1 + ADR-020 D1 ("no private key material crosses the boundary"). |
| OpenSSH 8.9 destination constraints (`ssh-add -h <host>`) | `reasoned:` Native protocol extension, but enforcement requires updated `sshd` on every destination — outside our control. Useful as a defense-in-depth layer when widely deployed; not enforcement today. |
| Custom agent with allowlist (1Password agent.toml model) | `direct:` Only works if the agent is yours. The host agent is the user's, and the design goal is to *not* replace it. |
| Sidestep entirely — HTTPS with token broker (nanoclaw / Vault SSH CA) | `direct:` Different paradigm — no credentials in container, gateway injects per-request. Abandons "your existing workflow, caged" positioning. Worth knowing about; not what rip-cage is. |
| Host-side `ssh-keyscan` to auto-resolve hashed entries | `reasoned:` Adds silent TOFU on every `rc up` for any allowed host that's only present hashed; Option 3 (HMAC-against-salt) covers the same case without new TOFU. |

**What would invalidate this:** `ssh-agent-filter` is removed from Debian, or proves to have a wire-protocol regression that breaks newer ssh-agent features. Then the custom-proxy alternative gets promoted.

**Invalidation check (mechanical, runnable post-implementation):** `docker run --rm <rip-cage-image> apt list --installed 2>/dev/null | grep -q ssh-agent-filter` exits 0. Missing package means the agent half regressed to today's full-forward behavior.

### D4: Two arrows compose multiplicatively at the mount layer

> [ADR-029 D3: RETIRED — the mount-layer known_hosts/agent-socket composition retires with the ssh cluster; there is no mount-layer ssh surface left to compose once git authenticates over HTTPS with a placeholder token.]

**Firmness: FIRM**

The cage's effective SSH reach is the intersection of the two filters:
- `allowed_hosts` × `(image-baked github.com floor)` = which destinations are trusted on the system path.
- `allowed_keys` × `(host agent contents)` = which credentials are offered.

A connection through the system path (`~/.ssh/known_hosts` + `/etc/ssh/ssh_known_hosts` + the forwarded ssh-agent) succeeds only if both filters pass. Either filter on its own narrows the cage; both together narrow it further.

**Mount-layer scope — explicit limit (edit in place 2026-05-12, rip-cage-nww).** The mount-layer filter narrows the system-path known_hosts surface but does **not**, by itself, defeat command-line `-o` overrides. OpenSSH semantics: command-line `-o UserKnownHostsFile=<writable-path>` combined with `-o StrictHostKeyChecking=accept-new` walks past the system file (CLI -o always wins over `Match final` in `/etc/ssh/ssh_config`); openssh writes the new host key to whatever path the caller supplies, treats accept-new as carte blanche, and the forwarded ssh-agent (ADR-017 default) signs whatever the destination requests. Verified 2026-05-12 in `personal-kinky-bubbles` (no `.rip-cage.yaml`): `ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts_bypass git@gitlab.com` reached publickey-auth (failed there only because the forwarded key wasn't trusted by gitlab — would have succeeded against `switch.berlin` per the original 2026-05-11 transcript). Earlier wording in this decision claiming the bypass was "structurally closed" by the mount alone was an overclaim; it is corrected here per the in-place-evolution convention.

The CLI-flag bypass is closed at the **PreToolUse hook layer** — see D5. Mount layer + hook layer compose: mount-layer enforcement is the floor (cannot be widened by anything inside the cage); hook-layer enforcement closes the OpenSSH-CLI override path that sits above it.

This still fulfills ADR-014 D2's line-79 caveat ("a future ... forwarded-agent scenario that requires real enforcement against user/CLI overrides would need a read-only `~/.ssh` bind mount akin to ADR-002 D11") — the read-only filtered mount provides the floor; the hook layer in D5 provides the CLI-override enforcement the caveat asked for. Per the in-place-evolution convention, the caveat in ADR-014 D2 is edited in place to reference this ADR (D4 + D5 together) rather than call the gap open.

**Rationale:** Multiplicative composition at the mount layer is the simplest enforceable model — neither arrow can silently widen the other through any in-cage code path. The hook layer in D5 extends this to also defeat the CLI-override class. Calling out the mount-layer scope honestly here matters: future agents reading the ADR should not infer the mount alone closes CLI-flag classes it doesn't, and reviewers of mount-layer changes should know which classes still rely on D5.

**What would invalidate this:** evidence of an in-cage attack vector that bypasses both the mount-layer filter AND the hook layer (e.g. a child process that re-mounts paths via root, or a hook-bypass shape the detector misses). Cage user namespace + read-only mounts make root-level remount implausible without root, and root is not given to the agent user. Hook-detection gaps are tracked in D5.

**Invalidation check (mechanical, runnable post-implementation):** In `tests/test-e2e-lifecycle.sh` checks 24–25, with no `.rip-cage.yaml` present, the in-cage `/home/agent/.ssh/known_hosts` byte-equals the host-side filtered cache (proof the cage sees the filtered file, not the raw mount) and is empty (schema default `allowed_hosts=[]`). The CLI-override class is covered by D5's invalidation check (Check 26).

### D5: PreToolUse hook closes the OpenSSH CLI-override bypass class

> [ADR-029 D3: RETIRED — `hooks/block-ssh-bypass.sh` and the `examples/ssh-bypass/` composable recipe retire at cutover; there is no OpenSSH CLI-override class to close once ssh itself is not the git transport. The implementation notes below are preserved as historical record — the label-lock instance this decision's mechanism participates in is referenced by [ADR-028](ADR-028-mount-shape-label-lock.md), whose own disposition notes that instance retiring alongside this ADR.]

**Firmness: FIRM**

A rip-cage-specific PreToolUse Bash hook (`hooks/block-ssh-bypass.sh`) runs before every Bash tool call alongside the upstream `dcg` binary. (A compound-command blocker previously ran alongside these; it was removed in rip-cage-4r8 — DCG is chaining-robust. See ADR-002 D5.) The hook denies any ssh-family invocation (`ssh`, `scp`, `sftp`, `/usr/bin/ssh` direct path, `rsync -e ssh`) carrying any of:

- `-o UserKnownHostsFile=<anything>` (the verified writable-path bypass)
- `-o GlobalKnownHostsFile=<anything>`
- `-o StrictHostKeyChecking=(no|accept-new|off)`

Detection runs a single perl regex pass over the command (after stripping single-quoted bodies and heredocs only — double-quoted bodies are kept so legitimate `rsync -e "ssh -o ..."` idioms are caught). Identification of ssh-family commands uses basename-of-token match so `/usr/bin/ssh` and PATH-resolved `ssh` are treated identically.

**Refusal message — load-bearing.** The deny message names the offending flag, then surfaces the legitimate path (per CLAUDE.md "'It's annoying' is a design signal" — block, but make self-recovery friction-free):

```
Blocked ssh-family command: -o UserKnownHostsFile defeats the cage host arrow.
OpenSSH CLI -o always overrides /etc/ssh/ssh_config Match final, and the
forwarded ssh-agent (ADR-017 default) will sign for whatever host the override
accepts. To let the cage reach a host legitimately:
  - Add to .rip-cage.yaml at the workspace root:
        version: 1
        ssh:
          allowed_hosts: [<host>]
  - Or run on the host: rc config init  (bootstraps from git remotes — rip-cage-97n)
  - Then on the host:   rc destroy <cage> && rc up <workspace>
To override this single command (requires human-on-keyboard): dcg allow-once <code>
```

This composes with `rip-cage-97n` (closed): `rc config init` is exactly the path the refusal message points at. Together: the hook blocks the bypass shape, and the agent (or human) can self-recover without hand-authoring YAML.

**Rationale:** Per CLAUDE.md ("layers, not walls" + "80/20, not 100/0"), the hook layer is the right place to close this class. The mount layer (D4) is the floor and is unbypassable from inside the cage; the hook layer enforces against the OpenSSH-CLI shape that sits above it. Together they cover the (1) accidental wrong-host class fully. The (2) forwarded-agent oracle abuse class — a hostile in-cage process that connects to a host the agent already trusts and asks the agent to sign — remains a documented limitation that `ssh.allowed_keys` narrows; this ADR does not claim to close it.

**Layer choice: rip-cage-specific hook, NOT extending the upstream `dcg` `remote.ssh` pack.** `dcg` is a generic command classifier that does not know about `.rip-cage.yaml` or `rc config init`. The refusal message must reference rip-cage's own concepts to be actionable. Keeping the SSH-bypass hook as a rip-cage-native hook in `hooks/` lets the message stay rip-cage-native and keeps `dcg` free of project-specific coupling. Both hooks run; either can deny.

**Quote-stripping tradeoff.** Single-quoted bodies are stripped (truly literal); double-quoted bodies are kept (preserves `rsync -e "ssh -o ..."` detection). False positives from `echo "ssh -o ..."` are guarded by the basename-of-token check: `"ssh` does not match `^ssh$`. Determined evasion via `bash -c '...single-quoted...'` is in the same documented-limitation class as oracle abuse — the hook is for blast-radius reduction, not adversarial isolation.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Outbound port-22 firewall (block all SSH from the cage) | `direct:` Defeats `git push` to allowed hosts. Per CLAUDE.md ("agent autonomy is the product"), gating the legitimate path defeats the cage's purpose. |
| `ssh` wrapper shim earlier in PATH that filters argv | `reasoned:` Bypassable via `/usr/bin/ssh` direct path; not load-bearing. The PreToolUse hook sees argv before any program runs and is not bypassable by absolute-pathing. |
| Extend the upstream `dcg` `remote.ssh` pack | `reasoned:` `dcg` doesn't know about `.rip-cage.yaml` or `rc config init`; the actionable refusal message has to live in a rip-cage-owned hook. |
| `dcg allow-once` as the only escape (no in-message hint) | `direct:` Per CLAUDE.md "'It's annoying' is a design signal" — agents must be able to self-recover by reading the message, not by guessing. The message names both `.rip-cage.yaml` (the durable fix) and `dcg allow-once` (the one-shot human-on-keyboard escape). |

**What would invalidate this:** the hook-detection regex misses a real bypass shape used in practice (e.g. a future OpenSSH option that disables host-key verification under a different name). Add the new pattern to the hook; this is detection-rule maintenance, not architectural change.

**Invalidation check (mechanical, runnable post-implementation):** `tests/test-e2e-lifecycle.sh` Check 26 series invokes the hook with the verified bypass shape (`-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts_bypass git@gitlab.com`) plus `/usr/bin/ssh` direct-path variant; both must return `permissionDecision: deny` with a message naming `.rip-cage.yaml` and `rc config init`. A legitimate `ssh -T git@github.com` (no override flags) must be allowed (empty hook output). `tests/test-safety-stack.sh` checks 12b–12e cover the same matrix at unit level.

### D6: `rc reload <cage>` — host-side hot-reload for `allowed_hosts` content changes

> [ADR-029 D3/D4: RETIRED-WITH-CARRY-FORWARD — the `ssh.allowed_hosts`-specific reload mechanism retires with the ssh cluster, but three properties re-home into the ADR-029 D4 deny→fix→reload repair loop: the `rc reload` verb itself, the human-as-approval-step posture (the human runs the reload, the agent cannot self-grant), and the refuse-loud taxonomy (named exit codes for out-of-scope field changes, cage-not-running, concurrent-reload). What does NOT carry forward: the inode-preserving truncate-not-mv bind-mount rewrite mechanics — those are Docker-bind-mount-specific and need re-verification on msb virtiofs, per [ADR-010](ADR-010-auth-refresh.md) D4's fired predicate ("a different file-sharing backend" is exactly what virtiofs is).]

**Firmness: FLEXIBLE**

`rc reload <cage>` is a host-side command that re-applies `.rip-cage.yaml` to a running cage **without `rc destroy && rc up`**, scoped narrowly to `ssh.allowed_hosts` content. Every other field — including `ssh.allowed_keys` (content or mount-shape) — refuses loud with a message naming the field and the required `rc destroy && rc up` remediation.

**Mechanism.** Read effective config; compare to current cage state recovered from `rc.*` labels and bind-mounted cache files. If only `allowed_hosts` differs, re-run `_filter_known_hosts` (D3) against host `~/.ssh/known_hosts` and rewrite `~/.cache/rip-cage/<cname>/known_hosts` **in-place** per the rip-cage-rx8 recipe (truncate + write, never `mv`-into-place — the bind mount points at the host path by inode). The cage's `/home/agent/.ssh/known_hosts` view reflects the new content on the next SSH call. No `docker exec`, no daemon restart, no tmux interruption. `--dry-run` prints the effective-config diff without mutating the cache file.

**Security boundary — exposure only, no in-cage hook.** Enforcement is the same as `rc up` today: `rc` is not on the cage's PATH, the docker socket is not mounted into the cage. The human running `rc reload <cage>` on the host is the approval step. **Config-write posture (revised 2026-07-01, ADR-021 D7, rip-cage-cw51):** `.rip-cage.yaml` is now read-only inside the cage by default, so the agent no longer self-edits `ssh.allowed_hosts` in-cage — it **surfaces the request in prose** and the human (or a host-side assistant the human relays to) authors the `allowed_hosts` edit host-side, then runs `rc reload`. Author-side authorship structurally prevents a hijacked agent from *burying* an extra host in an otherwise-legitimate edit (ADR-024). Under `mounts.config_mode: rw` (opt-in) the original in-cage self-edit-then-reload flow remains available. An in-cage `block-rc-reload.sh` PreToolUse hook was deliberately rejected (a) because the registration glue `~/.claude/settings.json` is agent-writable so the hook is bypassable from inside (broader hook-enforceability gap tracked in rip-cage-2uv), and (b) because a deny message would advertise the existence of `rc reload` to an agent that hadn't otherwise discovered it — a self-defeating defense per CLAUDE.md's "the cage telling you how to undermine itself" anti-pattern.

**Refuse-loud taxonomy.** Four explicit verdicts beyond happy-path apply. Detection uses **effective-config JSON-path diff** (not the `rc.*` container labels — those are mount-shape-only and frozen at create-time per Docker semantics):

1. `allowed_keys` changed (content or mount-shape) → exit 1, message naming `ssh.allowed_keys` and `rc destroy && rc up <workspace>`. Re-uses the `_up_resolve_resume_ssh_key_filter` comparison logic (rip-cage-jxy F2).
2. Any other path in the effective config JSON differs → exit 1, message naming the path. Catch-all for fields that have their own reconfig paths (egress, ports, identity, env_file) — none fit a content-only reload.
3. Cage not running → exit 2, message pointing at `rc up <workspace>`. Rationale: writing the cache file while the cage is stopped technically works (bind mount is host-side), but the user-visible promise of "reload" is "the cage sees the change now" — keeping the verb running-only avoids the confusing "you reloaded but nothing changed because the cage was stopped" failure mode.
4. Concurrent reload in progress → exit 3, message pointing at the lock dir. Enforced via atomic `mkdir ~/.cache/rip-cage/<cname>/.reload.lock.d` around the rewrite, released via `trap rmdir EXIT`. Chosen over `flock` for macOS portability (macOS has no native flock binary); POSIX-atomic `mkdir` gives equivalent serialization semantics. `rc up` resume's filter-refresh path is not currently lock-protected — the race window (concurrent resume + reload writing the same cache file) is benign because both paths write the same effective-config content; fixed in a follow-up if torn writes become observable.

**D5 hook deny-message update.** `hooks/block-ssh-bypass.sh` deny message is extended to suggest `rc reload <cage>` as the lighter-weight option when only `allowed_hosts` is being added (the dominant case). The full `rc destroy && rc up` path remains available for everything else and is the only path the deny-message recommends when the change is structural.

**Drift-hint update — `_config_emit_hint` becomes path-aware.** The container's `rc.config-loaded=<sha>` label is set at create-time and is immutable per Docker semantics. After `rc reload` applies an `allowed_hosts` change, the sha label is frozen at the pre-reload value, and naive sha comparison on `rc up` resume would emit a false-positive drift warning forever. The fix: `cmd_up` writes a per-container "applied-config snapshot" at `~/.cache/rip-cage/<cname>/config-applied.json` (effective-config JSON) on create. `rc reload` updates this snapshot to the live effective config after a successful apply. `rc up` resume merges reload-eligible paths from live into the snapshot (since resume re-applies allowed_hosts content via `_up_resolve_ssh_allowlists`). `_config_emit_hint` then computes a JSON-path diff between live and snapshot: empty → silent; only reload-eligible paths differ → hint at `rc reload <cage>`; any non-eligible path differs → hint at `rc destroy && rc up`. Legacy containers (created before ocn) lack the snapshot and fall back to the original sha-label comparison. The snapshot is host-side; not visible inside the cage; not a security primitive.

**Rationale.** The 2026-05-13 `switch.berlin` incident (the originating bead rip-cage-ocn surfaced from) demonstrated that the destroy/recreate friction is sized to the wrong dimension. Adding an SSH host is mechanically a one-line content change in a single bind-mounted file. Forcing tmux death + a fresh init cycle for content-only changes violates the project philosophy that "agent autonomy is the product" (CLAUDE.md): the cage's containment promise is at the mount layer (D4) regardless of which trigger (initial `rc up` or `rc reload`) wrote the filtered file, so the operational cost should match the actual change, not the operational shape of the system that produces it.

The scope-narrowing to `allowed_hosts` content reflects 80/20-not-100/0: the empirical 2026-05-13 incident was an `allowed_hosts` change; everything else is speculation about future demand. Mount-shape changes (rip-cage-jxy) and daemon-reconfig classes (`allowed_keys` content) remain explicitly out-of-scope, with the refuse-loud message naming `rc destroy && rc up` as the path forward.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Extend `rc up` to silently re-filter on resume | `reasoned:` Silently mutating cage state on `rc up` violates the resume-path's existing contract (resume preserves labels; mutations are explicit). Also re-introduces the surprise the `rc.ssh-key-filter` label-lock was added to prevent. Better to keep `rc up`-on-existing as attach-only and have `rc reload` be the explicit mutate verb. |
| Filesystem-watcher in `rc` that auto-reloads on `.rip-cage.yaml` write | `direct:` Defeats the human-approval gate. The agent can edit `.rip-cage.yaml` from inside the cage; an auto-reload would let the agent grant itself capability without any host-side decision. The human pushing the verb is the approval. |
| Support `allowed_keys` content reload via in-cage `ssh-agent-filter` daemon restart | `reasoned:` Possible but invasive (kill PID, relaunch with new `--comment` args, re-establish socket symlink). In-flight ssh-agent sign operations would break briefly. Not justified by current pain. Latent extension if usage demands. |
| In-cage `block-rc-reload.sh` PreToolUse hook as defense-in-depth | `direct:` (a) Bypassable via `~/.claude/settings.json` edit (agent-writable). (b) Deny message would advertise `rc reload` existence inside the cage — a tutorial for the bypass workflow. The exposure boundary (rc not on cage PATH, no docker socket) is the actual enforcement; an in-cage hook adds nothing and leaks. |

**What would invalidate this:** users routinely changing `allowed_keys` (content or mount-shape) often enough that the loud-refusal friction becomes the new "destroy+up is overkill" pain point. At that volume, promote the `ssh-agent-filter` daemon-restart path from "out of scope" to a D7. Mirror trigger: a `rc reload` regression where the in-place cache rewrite breaks the cage's view of the file (rx8-class) — would require a `docker cp` fallback path or a contract-on-bind-mount change.

**Invalidation check (mechanical, runnable post-implementation):** `tests/test-rc-reload.sh` (new) covers (a) `allowed_hosts` add + reload → `ssh-keygen -F newhost` inside cage finds the key; (b) `allowed_keys` content change → exit 1 naming the field; (c) `allowed_keys` mount-shape toggle → exit 1; (d) no-change → exit 0 no-op; (e) `--dry-run` → diff printed, cache file mtime unchanged; (f) inode-preservation guard: cache file inode equals pre-reload inode; (g) concurrent reload → second invocation exits 3 within 1s while first holds the lock; (h) post-reload `rc up` resume on the same cage emits no false-positive drift warning when only `allowed_hosts` differs from the create-time sha; (i) `rc up` resume DOES still warn when a non-reload-eligible field (e.g. egress) differs; (j) cache file mode (0644) and ownership (host user) preserved across reload; (k) `rc reload` invoked from inside the cage (simulated `docker exec`) fails — `rc` not on PATH, exit code is shell's command-not-found.

## Consequences

**Positive:**
- The 2026-05-11 / 2026-05-12 `-o UserKnownHostsFile` + `accept-new` bypass is closed by the combination of mount-layer narrowing (D4) and PreToolUse hook (D5). The mount layer narrows the system-path known_hosts; the hook denies the OpenSSH CLI-override shape that walks past it.
- `.rip-cage.yaml` gets a real first consumer; the layered config substrate proves itself in a non-trivial use case.
- ADR-014 D2's predicted enforcement gap is filled; the caveat collapses to a one-line cross-reference.
- The "your existing workflow, caged" positioning holds: today's pushes keep working with no config authoring. Tightening further is opt-in.
- Two new mount-layer enforcement surfaces (filtered known_hosts; filtered agent socket) that no in-cage code path can re-mount, plus a PreToolUse hook layer that catches the OpenSSH CLI-override class above them.
- Scope reduction in ADR-020: D2 transform 5 narrows from defending four directives to defending two.
- The hook's refusal message composes with `rip-cage-97n` (`rc config init`) so agents can self-recover from a legitimate-but-blocked attempt without hand-authoring YAML.

**Negative:**
- One new Debian package in the runtime image (`ssh-agent-filter` is small, ~30 KB).
- One new sentinel file (`/etc/rip-cage/ssh-allowed-keys`), one new background process inside the cage when `allowed_keys` is set (`ssh-agent-filter`), one new host-side cache file (`~/.cache/rip-cage/<container>/known_hosts`).
- Behavior change on rc upgrade for users who currently SSH to non-github.com hosts via the cage — they need a one-line `~/.config/rip-cage/config.yaml` or `.rip-cage.yaml`. Mitigation: `rip-cage-97n` ergonomics bead.
- Hashed `known_hosts` entries with wildcard `allowed_hosts` patterns can't be auto-resolved; a warning + `ssh-keyscan` recipe is the ergonomics seam.
- D5 hook adds detection-rule maintenance surface: future OpenSSH options that disable host-key verification under a different name need to be added to the hook regex. Tracked as detection-rule maintenance, not architectural change.

**Neutral:**
- ~50 LOC bash agent-launcher + ~70 LOC bash known-hosts filter + ~80 LOC tests. Net ~200 LOC delta. Comparable to ADR-020 implementation.
- Filtering happens at `rc up` (host-side) and at `init-rip-cage.sh` start (cage-side). No per-SSH-call cost beyond `ssh-agent-filter`'s per-request filter, which is negligible.

## Implementation notes

- **`rc`** (host-side): add `_resolve_ssh_allowlists` (calls o4z `_load_effective_config`, aborts loud on D3 version drift via the existing central gate); add `_filter_known_hosts` (awk + openssl HMAC, idempotent, writes to `~/.cache/rip-cage/<container>/known_hosts`); edit `_build_ssh_mount_args` to bind-mount the filtered file (replacing the wholesale `~/.ssh/known_hosts` source) and to mount the upstream agent socket as `/ssh-agent-upstream.sock` when `allowed_keys` is set; edit `_tsc_process_file` transform 5 to drop the `UserKnownHostsFile`/`GlobalKnownHostsFile` rewrites (keep `BatchMode`/`StrictHostKeyChecking`).
- **D5 hook** (`hooks/block-ssh-bypass.sh`, added 2026-05-12 by `rip-cage-nww`): bash + perl, ~80 lines. Registered as a PreToolUse Bash matcher in `settings.json` (after `dcg`; previously third after `dcg` and `block-compound-commands.sh` — the compound blocker was removed in rip-cage-4r8). Auto-copied into the image via the existing `COPY hooks/` directive; auto-chmodded by the existing `chmod +x .../hooks/*.sh` line. No Dockerfile changes required.
- **`Dockerfile`**: add `ssh-agent-filter` to the apt-get install list in the runtime stage.
- **Resume mount-shape guard** (added 2026-05-12 by `rip-cage-jxy`): the `/etc/rip-cage/ssh-allowed-keys` bind mount is wired only when `ssh.allowed_keys` is non-null at create time. Toggling the field between null and non-null after create is a mount-shape change, not just a content change. To prevent silent divergence between displayed config and in-cage filter behavior, `cmd_up` persists `--label rc.ssh-key-filter=on|off` at create and `_up_resolve_resume_ssh_key_filter` aborts loud on resume when the label disagrees with the current effective config (`SSH_KEY_FILTER_MOUNT_SHAPE_CHANGED`). User remediation: `rc destroy <name> && rc up <path>`. Mirrors the `rc.forward-ssh` / `rc.ssh-config` / `rc.github-identity` label-lock pattern. ADR-021 D5's sha-drift hint still fires for any config change, but this guard is the enforcement.
- **`init-rip-cage.sh`**: add an `ssh-agent-filter` launcher block that reads `/etc/rip-cage/ssh-allowed-keys`. If empty/absent, fall back to today's chown-and-use path; if present, run `ssh-agent-filter` from `/tmp/rip-cage-filter/` with upstream `SSH_AUTH_SOCK=/ssh-agent-upstream.sock`, parse the `SSH_AUTH_SOCK='…'` line it prints, and `sudo ln -sfT <parsed-sock> /ssh-agent.sock` so consumers find the filtered socket at the expected path. PID file at `/tmp/rip-cage.afssh.pid` (legacy filename retained for backward compat with diagnostic scripts).
- **Sentinel format**: `/etc/rip-cage/ssh-allowed-keys` is one comment per line; absent file = no allowlist (forward all); present file with zero non-comment lines = explicit zero-out (forward none); present file with N lines = forward those N.
- **Tests**: `tests/test-ssh-allowlist.sh` (new, ~14 cases per design doc); update `tests/test-ssh-config.sh` D2 transform-5 invalidation check.
- **Docs**: update `docs/reference/ssh.md` (or equivalent) with `.rip-cage.yaml` SSH section; cross-reference from ADR-021's "first consumer" section.
- **ADR alignment** (per the in-place-evolution convention): see in-place edits to ADR-014 D2 caveat, ADR-020 D1 mount description, ADR-020 D2 transform 5.

## Carries over from upstream ADRs

- **ADR-021** D1 (precedence), D2 (per-field merge — additive_list, selection_list), D3 (version drift abort) — substrate this ADR consumes; unchanged.
- **ADR-020** D3 (github.com identity routing), D4 (`IdentitiesOnly yes` + pubkey mount), D5 (sentinels), D6 (identity preflight), D7 (opt-out flag) — orthogonal to this ADR; unchanged.
- **ADR-018** D1–D4 (host-side socket discovery) — unchanged. The discovered socket is bind-mounted as `/ssh-agent-upstream.sock` instead of `/ssh-agent.sock` when filtering is active; the discovery logic itself is untouched.
- **ADR-017** D1 (no private keys cross the boundary), D2 (`--no-forward-ssh`), D3 (LFS / session-close) — unchanged. The agent half adds a filter in front of the forwarded socket; it does not introduce key material into the cage.
- **ADR-014** D2 (non-interactive SSH posture: image-baked pins, `BatchMode=yes`, `StrictHostKeyChecking=yes`) — image-baked pins remain the floor; `BatchMode`/`StrictHostKeyChecking` overrides in ADR-020 D2 transform 5 remain. The line-79 caveat is updated in place to reference this ADR.
