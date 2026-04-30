# Design: SSH identity routing — the cage forwards your SSH posture, not just your agent

**Date:** 2026-04-27
**Status:** Reviewed — pending implementation
**Decisions:** [ADR-020](../decisions/ADR-020-ssh-identity-routing.md)
**Origin:** Dogfooding — a `mapular-gtm` cage session left commits and `bd dolt push` stranded for ~24h. Diagnosis on 2026-04-27 showed `ssh -T git@github.com` from the cage authenticates as `jsnyde0` (personal account) despite the project requiring the work key. The forwarded ssh-agent has all 3 host keys; the cage has no `~/.ssh/config` to pin one. `git push mapular/mapular-gtm` returns "Repository not found" — wrong identity, not wrong repo. Repos cloned with host aliases (`git@github-work:...`, `git@github-personal:...`) fail differently inside the cage with "Could not resolve hostname".
**Related:** [ADR-017](../decisions/ADR-017-ssh-agent-forwarding-default.md) (forward-by-default), [ADR-018](../decisions/ADR-018-macos-ssh-agent-discovery.md) (probe-and-pick agent), [ADR-001](../decisions/ADR-001-fail-loud-pattern.md) (fail-loud + actionable), [ADR-014](../decisions/ADR-014-push-less-cage.md) D2 (non-interactive SSH posture)

---

## Problem

ADR-017/018 carry over half of the user's host SSH state into the cage: the *agent socket* (which keys are loadable for signing). They do not carry over the other half: the *config* (which key to offer for which destination). Without a `~/.ssh/config` inside the cage, OpenSSH falls back to "offer every identity in the agent in load order; the server picks one." On GitHub, that means "the first key the agent enumerated wins, regardless of which account that key belongs to."

For a developer with one GitHub account, this is invisible. For a developer with multiple accounts (personal + work, or a bot account, or org-scoped keys), it manifests as silent identity confusion:

1. **`git@github.com:<org>/<repo>` URLs auth as the wrong user.** `mapular/mapular-gtm` push fails with "Repository not found" because GitHub has authenticated the session as `jsnyde0` (personal) and `jsnyde0` is not a member of the `mapular` org. The error message is misleading — the repo exists; the wrong identity simply can't see it.
2. **`git@github-work:` / `git@github-personal:` aliased URLs fail with hostname resolution.** These aliases only exist in the user's host `~/.ssh/config`. Inside the cage, `github-work` is treated as a literal hostname → DNS lookup fails. The user's host repos cloned through their own conventions don't even reach an authentication step.

Both failure modes contradict the project philosophy from CLAUDE.md:
- "Agent autonomy is the product" — but the agent now needs human intervention to push from a multi-identity cage.
- "It's annoying is a design signal" — the failure modes are both annoying *and* misleading.
- The pattern from ADR-017/018 (host owns truth; cage inherits via mount; preflight is loud and actionable) was applied to the agent socket but not to the config.

The cage's existing scaffolding hints that this gap was anticipated:
- `Dockerfile:108-110` sets up `/etc/ssh/ssh_config.d/00-rip-cage.conf` for cage-authored ssh defaults (BatchMode, pinned known_hosts).
- `init-rip-cage.sh:42-49` already chowns the forwarded socket so the agent user can sign.
- But nothing wires the user's per-host identity preferences across the boundary.

This design closes that gap.

## Goal

The cage's SSH behavior matches the host's SSH behavior. What `ssh -T git@<host>` resolves to on the host is what it resolves to in the cage. Repositories cloned with host aliases on the host work without modification inside the cage. The default `git@github.com:` URLs route to the right identity automatically when the user has declared a routing rule, and route to a loudly-named "unset" state otherwise. Routing is visible at `rc up`, in the tmux banner, in the in-cage shell on every attach, and in `rc ls` / `rc doctor`.

## Non-Goals

- **Solving multi-identity GitHub on the host.** The user's host config is the source of truth; the cage inherits whatever the user already maintains. We don't generate or modify host config.
- **Per-tool routing.** A single ssh config covers git, gh, ssh, rsync. We don't try to route differently for different consumers.
- **Replacing the threat model from ADR-017 D1.** Private keys must continue to stay on the host. The forwarding-vs-mounting tradeoff stays where ADR-017 put it.
- **Host-side key management.** Adding keys to the agent, choosing passphrases, configuring 1Password — out of scope.
- **Changing ADR-017 D1 (forward-by-default), D2 (`--no-forward-ssh`), D3 (LFS carryover), or ADR-018 D1-D4.** All carry over unchanged.
- **Devcontainer parity in v1.** `rc init` does not gain config translation. Visibility is closed via in-cage banner echo (D5); routing parity is tracked in `rip-cage-akd`.

---

## Proposed Architecture

The cage gets a generated `~/.ssh/config` and a read-only set of public keys at `rc up`, derived from the host. The agent socket continues to come from ADR-018's probe-and-pick. SSH inside the cage now has both halves of the host posture: signing capability (forwarded agent) **and** routing intent (mounted config). Private keys never enter the cage.

```
rc up (create OR resume)
  │
  ├── (existing) probe + mount agent socket   → /ssh-agent.sock        [ADR-018]
  │
  ├── (NEW) translate host ~/.ssh/config       → ~/.cache/rip-cage/<container>/ssh-config
  │       runs on EVERY rc up (create + resume); overwrites in place
  │       bind-mount target → /home/agent/.ssh/config:ro
  │
  ├── (NEW) mount host *.pub files (read-only) → /home/agent/.ssh/*.pub:ro
  │       allowlist sourced from translated config's IdentityFile set
  │       plus ~/.ssh/known_hosts (additive to /etc/ssh/ssh_known_hosts)
  │
  ├── (NEW) resolve a github.com pin if not already in user's config
  │       priority: (1) --github-identity / RIP_CAGE_GITHUB_IDENTITY
  │                (2) rc.github-identity container label (resume only)
  │                (3) ~/.config/rip-cage/identity-rules → key basename
  │                (4) leave unset → loud preflight, no silent first-key-wins
  │
  └── (NEW) preflight: probe `ssh -T git@github.com` from inside cage
          • record resolved username to /etc/rip-cage/github-identity sentinel
          • compare against expected (label) → match=ok, mismatch=loud, unset=warning
          • surfaced in tmux banner + in-cage first-shell echo + rc ls + rc doctor
```

### D1 — Mount strategy: strict (config + pubkeys + known_hosts), never private keys

The cage has two precedents for handling host-side key material:

| Precedent | Approach | Rationale |
|---|---|---|
| OAuth credentials | Bind-mount `.credentials.json` rw | Cage and host share auth state |
| ssh-agent | Forward socket, no key files | "Agent borrows signing capability, can't exfiltrate keys" (ADR-017 D1) |

This design follows the **ssh-agent precedent**, not the credentials precedent. Public keys are mounted; private keys are never mounted, even read-only. The threat model from ADR-017 D1 ("private keys never cross the container boundary") is preserved verbatim. A compromised cage can sign anything the agent will sign for it during the session — that surface is unchanged from today. It cannot copy private key material out, because there is no private key material to copy.

This rules out three simpler alternatives:
- **Bind-mount `~/.ssh:ro` whole** — read-only is not a security boundary against an in-cage process; the bytes are still readable. ADR-017 D1's rationale is structural ("keys aren't visible because they aren't there"); a read-only mount loses that property.
- **Per-project `.cage/ssh-config` checked into each repo** — deterministic, no host-state coupling, no inference. Rejected: forces every project author to author the file; doesn't auto-cover repos cloned with host aliases on the user's machine; doesn't help `bd dolt push` (a daemon, not a per-project ssh consumer); regresses the "your existing setup carries over via `rc up`" property the project markets against ClaudeBox.
- **Source pubkeys from `ssh-add -L` instead of from `~/.ssh/*.pub` files.** The forwarded agent is by-definition a complete pubkey source; `ssh-add -L` dumps the loaded pub-key bytes. This alternative would make the design work for setups where pubkeys don't live on the rip-cage host's filesystem at all — 1Password SSH agent (pubkeys in the vault), macOS Secure Enclave / Secretive (keys never touch disk), agent forwarded from a remote workstation, or `ssh-add`'d-then-deleted keys. Architecturally it collapses D4's "allowlist + degraded fallback" branch into "agent IS the allowlist by definition." Rejected for v1: matching the cage config's `IdentityFile <name>` to a specific agent identity then needs fingerprint/comment matching against `ssh-add -L` output instead of filename matching, which adds a layer of indirection both at translation time and at debug time. Captured as a Known Limitation below; reconsidered in a follow-up if the dogfooding gap turns out to bite real users.

### D2 — Translate host config at every rc up; write to a stable per-container path

The host's `~/.ssh/config` is shaped for the host: `IdentityFile ~/.ssh/id_ed25519_work` resolves to `/Users/jonat/.ssh/...`, which doesn't exist inside the cage. `Include ~/.orbstack/ssh/config` references host-only paths. `UseKeychain yes` is only valid on Apple OpenSSH builds — Debian's openssh-client errors on it. And several directives (`Match exec`, `ProxyCommand`, `ControlPath`) reference host binaries or filesystem state the cage does not share.

Six transforms are applied at `rc up` to produce a cage-friendly config:

1. **Path rewrite.** Every `IdentityFile $HOME/.ssh/<name>` becomes `IdentityFile /home/agent/.ssh/<name>`. Tilde-expanded and absolute paths under `$HOME/.ssh/` both handled. The rewritten path retains the *private-key* basename even though no private key is mounted (D1) — OpenSSH transparently falls back to `<path>.pub` when given a private-key path that doesn't exist, and the forwarded agent handles the actual signing. Pointing `IdentityFile` directly at the `.pub` file would work equivalently (OpenSSH accepts either form as the public-key identity), but keeping the host's private-key path makes the translation a pure rewrite of the user's directive rather than a semantic edit — preserves the "your config carries over" mental model.
2. **`IgnoreUnknown` shim.** Prepend `IgnoreUnknown UseKeychain,AddKeysToAgent,UseRoaming` so non-Apple openssh treats macOS-only directives as no-ops.
3. **Drop unsafe `Include`s.** `Include` directives outside `$HOME/.ssh/` are commented out with `# rip-cage: stripped (host-only path)`. Includes inside `$HOME/.ssh/` are translated and their targets recursively mounted.
4. **Strip host-only directives.** `Match exec`, `ProxyCommand`, `ProxyJump`, `ControlMaster`, `ControlPath`, `IdentityAgent` are commented out with `# rip-cage: stripped (host-only)`. Each references binaries or filesystem state the cage does not share; leaving them produces confusing "No such file" errors at SSH-time rather than a clean translation. (`IdentityAgent` is special — its presence on the host means "ignore the env-var socket"; rewriting to `/ssh-agent.sock` would lie about the user's intent, so we strip and let the forwarded `SSH_AUTH_SOCK` from ADR-017 take over.)
5. **Override ADR-014 D2 directives at the per-Host level.** If the user's host config sets `BatchMode no`, `StrictHostKeyChecking accept-new`, `UserKnownHostsFile`, or `GlobalKnownHostsFile` inside any `Host` block, those values would re-enable TTY prompts on unknown hosts inside the cage — undoing the loud-fail posture ADR-014 D2 explicitly closed. Translation rewrites those four directives to the ADR-014 D2 values (`BatchMode yes`, `StrictHostKeyChecking yes`, system known_hosts paths) and adds `# rip-cage: overridden (ADR-014 D2)` for debuggability. The cage-authored `Match final Host *` system block (`/etc/ssh/ssh_config.d/00-rip-cage.conf`) does not defeat per-Host user values per OpenSSH "first value wins" — defensive override at translation time is the right layer.
6. **Append a synthesized `Host github.com` block** (D3) when the layered resolution selects a pin and the user's config doesn't already contain one.

The translation runs as a host-side bash/awk function in `rc` (`_translate_ssh_config`) on **every** `rc up` — both create and resume paths — and writes to `~/.cache/rip-cage/<container-name>/ssh-config`. The bind-mount target points to that stable path. Two correctness consequences:
- **No tempfile GC failure mode.** A persistent path under `~/.cache/` is not a candidate for `/tmp` cleanup.
- **Host-config edits propagate on the next resume.** User edits `~/.ssh/config`, runs `rc up <project>`, the cage picks up the change. No `rc down && rc up` ceremony required.

The translation is idempotent — running it twice with identical input produces identical output (modulo timestamp comments, which we omit).

If the host has no `~/.ssh/config`, the cage gets a config consisting only of the `IgnoreUnknown` shim and the synthesized `Host github.com` block from D3 (if the layered resolution wired one). Same minimal bootstrap as today's no-config cage but now with explicit routing.

### D3 — Default github.com pin: layered resolution, no built-in inference defaults

For users whose host config already has `Host github.com` (e.g., bot accounts, single-identity setups), D2 carries it over and we're done. The hard case is the user whose host config only has aliases (`Host github-work`, `Host github-personal`) — `git@github.com:` URLs in the cage have no anchor.

The cage resolves a github.com identity via a four-layer priority list at `rc up`:

| Priority | Source | Mechanism |
|---|---|---|
| 1 | `--github-identity=<keyname>` CLI flag, or `RIP_CAGE_GITHUB_IDENTITY=<keyname>` env var | Names a key file basename (e.g., `id_ed25519_work`). Generates a `Host github.com` block targeting that key. Persists as `rc.github-identity=<keyname>` container label. |
| 2 | `rc.github-identity` container label from a previous `rc up` (resume only) | Read from the existing container on resume. |
| 3 | Path-based rule from `~/.config/rip-cage/identity-rules` matched against `rc.source.path` | First matching rule wins. **No built-in defaults.** If the file does not exist, layer 3 yields no match and resolution falls through to layer 4. |
| 4 | Nothing matches | Cage config gets no synthesized `Host github.com` block; preflight (D6) surfaces this loudly. |

The rules file format is intentionally minimal — one rule per line, glob-pattern + key basename, no YAML parser:

```
# ~/.config/rip-cage/identity-rules
~/code/mapular/*    id_ed25519_work
~/code/personal/*   id_ed25519_personal
~/dev/clients/*     id_ed25519_client
```

Empty lines and `#`-prefixed comments are skipped. Glob matching uses bash `[[ "$path" == $pattern ]]` semantics, evaluated against the literal `rc.source.path` (already a stored label, verified `rc:1756`). No regex, no `~` expansion in the pattern (use `$HOME` or full paths).

**Layered-resolution rationale.** Layer 1 is the explicit override for fully-deterministic single-shot use. Layer 2 keeps resume idempotent — once a container is labeled, it stays labeled, and the resolution doesn't drift between sessions. Layer 3 is the user-declared convention; it costs the user a one-time three-line file and gives them ergonomic per-cage routing. Layer 4 is the honest "we don't know, ask the human" failure mode — the design ships **no `mapular`/`personal` defaults baked into `rc`**, because hardcoding one user's directory layout into open-source code is the wrong trade.

**CLI override on resume.** `rc up --github-identity=<name>` on an existing container errors loud rather than silently relabeling: `Error: container <name> already labeled rc.github-identity=<existing>. Run 'rc destroy <name> && rc up …' to reset.` This matches ADR-018's posture-immutable-on-resume contract; silently changing the label on resume is exactly the silent-fallback pattern ADR-001 outlaws.

**Generalization to other hosts.** This explicitly *does not* generalize to other hosts (bitbucket, gitlab, internal). Those route only via D2 (host config carryover). Adding more hosts follows the same four-layer pattern but is a separate change.

### D4 — Public keys are mounted as a small allowlist; explicit-pin missing-pubkey aborts

The translation step in D2 produces a list of `IdentityFile` paths the cage config references. Those `.pub` files (and *only* those, plus `~/.ssh/known_hosts`) get bind-mounted read-only into `/home/agent/.ssh/`. Mounting `~/.ssh:ro` wholesale would expose private key material under read-only mount, which violates D1's rationale.

Mount mechanics:
- `~/.ssh/known_hosts` → `/home/agent/.ssh/known_hosts:ro`. Augments the existing pinned `/etc/ssh/ssh_known_hosts` (which holds `github.com` only).
- For each `IdentityFile <path>` in the translated config: `<host-path>.pub → /home/agent/.ssh/<basename>.pub:ro`.
- `/home/agent/.ssh/` is created at chown time (init-rip-cage.sh), owned `agent:agent`, mode `0700`. The pub files inherit `0644` from the host.

**`IdentitiesOnly yes` correctness contract.** The synthesized `Host github.com` block from D3 includes `IdentitiesOnly yes`, which is what *prevents* the agent from offering all keys — it filters the agent down to the named identity using the matching pubkey file on disk. **If the named pubkey is missing, `IdentitiesOnly yes` is inert** and SSH falls back to "offer every agent key in load order" — the exact bug this design exists to fix. So the design's correctness depends on `IdentitiesOnly yes` AND the pubkey file being present, both at translation time and at SSH-time.

This shapes missing-pubkey handling:

| Resolution layer | Missing pubkey behavior | Why |
|---|---|---|
| 1, 2 (explicit pin via CLI/label) | **`rc up` aborts loud** | The user named a specific identity; producing a config that silently selects a different one is a silent-fallback and violates ADR-001. |
| 3 (rules-file inference) | **`rc up` aborts loud** | Same logic — the rules file is a user-declared convention; honoring it requires the keys to be present. |
| 4 (no pin) | No-op | No synthesized block, no missing-pubkey condition. Preflight surfaces `unset` per D6. |
| Any user-config Host block referencing missing pubkey | Skip mount + warn at `rc up`; do not abort | The user's host config is in their domain; the cage is a guest. Surface loudly but don't gate startup on host-config hygiene. |

Abort message follows ADR-001 actionability: `Error: --github-identity=id_ed25519_work selected, but ~/.ssh/id_ed25519_work.pub does not exist on host. Generate the key (ssh-keygen) or correct the rules file.`

### D5 — Sentinel + banner extension; first-shell echo for entry-path parity

Two new sentinel files joining the existing `ssh-agent-status` / `ssh-agent-socket` pair (ADR-018 D3):

- `/etc/rip-cage/github-identity` — single line. Resolved github.com username after preflight, e.g., `jonatan-mapular`. Empty if preflight didn't run; `unreachable` if probe failed; `unset` if no pin was wired.
- `/etc/rip-cage/ssh-config-source` — single line. Records the source of the pin: `host-config`, `cli-flag`, `label`, `rules-file`, `none`, or `disabled`. Aids debugging when the resolved identity surprises the user.

Both sentinels are written by the in-cage preflight (D6), which runs via `docker exec` as root (matching the ADR-018 D3 sentinel-writer pattern). `/etc/rip-cage/` is root-owned by Dockerfile convention; agent-uid writes would fail. A regression test asserts ownership and perms after fresh `rc up`.

The tmux banner (zshrc ssh-agent block) reads both and adds one line per running container:

```
ssh-agent: 3 keys loaded (host: /var/folders/.../agent.NNNN)
github.com: jonatan-mapular  (rules-file: ~/code/mapular/*)
```

Banner colorization mirrors ADR-018 D3: green if the resolved identity matches the expected label (or no expectation), yellow if `unset`, red if `mismatch` or `unreachable`.

`rc ls` gains a `GH-IDENTITY` column. `rc doctor` (deferred bead) surfaces full provenance.

**First-shell echo (devcontainer parity).** The tmux banner is rc-up-attached, which means devcontainer entry users (`rc init` path, VS Code "Reopen in Container") never see it. To close the visibility gap regardless of entry path, `init-rip-cage.sh` reads both sentinels and echoes a one-line identity status as part of its existing init log. The line appears in the first shell's startup output on every attach — `rc up` users see it from tmux, devcontainer users see it from the integrated terminal. Routing is named loudly on both paths; routing parity (devcontainer translation runs `init-rip-cage.sh`-side) is a follow-up tracked in `rip-cage-akd`.

### D6 — Preflight: probe github.com identity, fail loud on mismatch; cache shipped in v1

After the agent-reachability preflight from ADR-018 reports `ok:N`, a new preflight step runs inside the cage:

```bash
ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com 2>&1 \
  | sed -n 's/^Hi \([^!]*\)!.*/\1/p'
```

GitHub's SSH greeting (`Hi <user>!`) names the authenticated user. The preflight captures it, writes to `/etc/rip-cage/github-identity`, and compares against the expected username. The expected username is looked up via a per-host cache at `~/.cache/rip-cage/identity-map.json`, which maps `<keyname>` → `<github-user>` and is populated lazily from successful preflights with a 24h TTL. The cache lives on the host (not the container) so multiple cages share resolved identities. Refresh on `rc auth refresh` invalidates entries.

**Greeting probe is primary; `gh api user` is a parallel diagnostic.** The greeting probe answers the SSH-side question this design is *about* — "which SSH identity does GitHub authenticate the cage as?" — directly and contractually-enough for a 5-year-old format. `gh api user --jq .login` answers a different question — "which OAuth identity is `gh` auth'd as?" — using the OAuth token forwarded from the host's Claude Code credentials. The two can disagree (gh OAuth'd as `personal`, SSH key for `work`), and that disagreement is information. `rc doctor` (deferred bead) runs both and surfaces conflicts; v1 ships only the greeting probe in the rc-up critical path to keep the latency floor low.

Three resolution states:

| Outcome | When | Action |
|---|---|---|
| `match` | resolved == expected | silent at `rc up`, banner green |
| `unset` | no expectation set, resolved=anything | yellow banner: `github.com routing unspecified — pushes will go to <resolved>; pin via 'rc up --github-identity=<name>' (requires fresh container)` |
| `mismatch` | expected != resolved | red banner: `github.com expected <expected> but resolved as <resolved> — likely cause: IdentityFile not honored or pubkey missing. Recreate with: rc destroy <name> && rc up <path> --github-identity=<name>. Debug with: ssh -vT git@github.com (inside cage).` |

The mismatch hint explicitly names `rc destroy && rc up` because `--github-identity=<name>` on resume errors per D3 (CLI override on existing label is loud-fail).

If github.com is unreachable (egress firewall blocks it, or no network), the sentinel records `unreachable` and the banner says so. Consistent with ADR-018 D3's failure-mode posture.

`rc up` does not abort on `unset`, `mismatch`, or `unreachable` — a cage with unclear github.com routing is still useful for read-only work, exploration, and HTTPS git. The guarantee is that the routing is **named and visible**, never silent.

### D7 — Opt-out: `--no-ssh-config`, with `--no-forward-ssh` implying it by default

The same shape as `--no-forward-ssh` from ADR-017 D2. Skips config translation, pubkey mount, and the github.com preflight. Cage behaves exactly as today (forwarded agent, no config, first-key-wins). Persisted as `rc.ssh-config=on|off` label so resume preserves posture.

**`--no-forward-ssh` implies `--no-ssh-config`.** A user reaching for the ADR-014 containment posture finds `--no-forward-ssh`; without the implicit chain, they'd end up with a cage that has translated config + pubkey mounts but no agent — a confusing posture ("I asked for no SSH, why does my cage have my pubkey files?"). Mirrors the existing `_UP_NO_HOST_AGENT` auto-relabel pattern at `rc:1097-1107`. To opt out of the implication (forward agent off, but ssh-config on), pass `--no-forward-ssh --ssh-config` explicitly.

Use cases for opting out:
- ADR-014 containment posture (`--no-forward-ssh` alone gets you both off, atomically).
- A user whose host config is already minimal and who wants the cage simpler.
- Debugging: comparing pre-vs-post behavior.
- Single-identity hosts where no routing logic is needed.

---

## Key Design Decisions

From [ADR-020](../decisions/ADR-020-ssh-identity-routing.md):

- **D1 (FIRM):** Strict mount — translated config + referenced `.pub` files + `known_hosts`. Private keys never enter the cage. Preserves ADR-017 D1's structural property. Per-project `.cage/ssh-config` rejected as alternative.
- **D2 (FIRM):** Translate, don't pass through. Six transforms — path rewrite, `IgnoreUnknown` shim, strip unsafe Includes, strip host-only directives (`Match exec`, `ProxyCommand`, `ProxyJump`, `ControlMaster`, `ControlPath`, `IdentityAgent`), override ADR-014 D2 directives at per-Host level, append synthesized `Host github.com` block. Re-runs on every `rc up` (create + resume) to a stable per-container path under `~/.cache/rip-cage/`.
- **D3 (FIRM):** Layered github.com pin: explicit > label > rules-file > loud-fail. **No built-in inference defaults** — rules-file is user-declared. CLI override on resume errors loud (label is immutable on resume; recreate required).
- **D4 (FIRM):** Allowlist pubkey mount. **Explicit-pin missing-pubkey aborts `rc up`**; user-config-block missing-pubkey degrades loudly. `IdentitiesOnly yes` correctness contract documented as load-bearing.
- **D5 (FIRM):** Sentinels (`github-identity`, `ssh-config-source`) feed banner + `rc ls`; `init-rip-cage.sh` echoes status on first-shell start so devcontainer users see routing without needing the rc-up tmux banner.
- **D6 (FIRM):** Greeting probe is primary; identity-map cache shipped in v1 with 24h TTL; `gh api user` is a parallel diagnostic in `rc doctor` (deferred). Mismatch banner names `rc destroy && rc up` explicitly.
- **D7 (FIRM):** `--no-ssh-config` opt-out, label-persisted. **`--no-forward-ssh` implies `--no-ssh-config` by default**, with `--ssh-config` to un-imply.

---

## Test plan

New tests in `tests/test-ssh-config.sh` (mirrors `test-ssh-forwarding.sh` shape):

1. **Translation correctness — base transforms.** Sample host config with `IdentityFile ~/.ssh/id_ed25519_work`, `Include ~/.orbstack/...`, `UseKeychain yes`. Verify output has rewritten path, dropped Include, prepended IgnoreUnknown.
2. **Translation correctness — host-only directives.** Sample config with `ProxyCommand`, `ProxyJump`, `ControlMaster`, `ControlPath`, `Match exec`, `IdentityAgent`. Verify each is stripped with `# rip-cage: stripped (host-only)` comment.
3. **Translation correctness — ADR-014 D2 override.** Host config sets `BatchMode no` and `StrictHostKeyChecking accept-new` inside a `Host *` block. Verify output rewrites both with `# rip-cage: overridden (ADR-014 D2)` comment. Inside-cage `ssh -o BatchMode=$(ssh -G x | awk '/^batchmode/{print $2}') ...` confirms batch mode active.
4. **Pubkey allowlist mount.** Verify only `IdentityFile`-referenced `.pub` files appear in `/home/agent/.ssh/`. A `~/.ssh/id_unrelated.pub` not referenced by any Host block must NOT be mounted.
5. **No private key leakage.** Assert `ls /home/agent/.ssh/` contains no files matching `id_*` without `.pub` suffix.
6. **Host alias resolves.** Mount a host config with `Host github-work / IdentityFile ~/.ssh/id_ed25519_work`, set up agent with that key loaded, verify `ssh -T git@github-work` from cage resolves to expected user.
7. **github.com preflight outcomes.** Subcases: (a) host config has explicit pin → carried over verbatim; (b) `--github-identity` flag wins over rules-file; (c) rules-file picks correct key for `~/code/mapular/*`; (d) no rules file present → layer 4 (`unset`).
8. **Explicit-pin missing-pubkey aborts.** `--github-identity=missing_key` with no `~/.ssh/missing_key.pub` on host → `rc up` exits non-zero with the actionable error message.
9. **Mismatch detection.** Force a wrong-identity setup, verify preflight returns `mismatch`, sentinels written, banner red. Mismatch banner text contains `rc destroy && rc up …`.
10. **Resume re-translates.** First `rc up`, edit `~/.ssh/config` on host (add a Host alias), second `rc up` (resume). Verify the cage's `/home/agent/.ssh/config` reflects the edit and the stable path under `~/.cache/rip-cage/<name>/` was overwritten.
11. **CLI override on resume errors loud.** First `rc up --github-identity=work`, second `rc up --github-identity=personal`. Verify second invocation exits non-zero with the "container already labeled — destroy and recreate" message.
12. **Opt-out parity.** `--no-ssh-config`: no config mount, no pub-key mount, no github.com preflight.
13. **`--no-forward-ssh` implies `--no-ssh-config`.** `rc up --no-forward-ssh` → cage has neither agent forwarding nor config; `rc up --no-forward-ssh --ssh-config` → no agent but config + pubkeys mounted.
14. **Sentinel writer perms.** Fresh `rc up`, assert `ls -la /etc/rip-cage/github-identity` shows root-owned, mode 0644.
15. **First-shell echo (devcontainer parity).** Inspect `init-rip-cage.sh` startup log for the github.com identity line — present regardless of entry path.
16. **Linux/WSL2 parity.** Same translation logic runs on Linux; `UseKeychain` shim is no-op on a config that doesn't use it.

---

## Consequences

**Easier:**
- The cage's `git push`, `bd dolt push`, `gh` write operations route to the right identity by default for users who declare a routing rules file.
- Repos cloned with host aliases (`git@github-work:`, `git@github-personal:`) work without modification.
- Failure modes are loud and named: banner shows resolved identity, sentinel records source, preflight catches mismatches with actionable recreate-command hints.
- Mental model collapses to "the cage has your SSH posture" — config and agent both carry over.
- Host `~/.ssh/config` edits propagate on the next `rc up` resume — no `rc down && rc up` ceremony.

**Harder:**
- `rc` gains a config-translation function (~80 lines of bash + awk including the six transforms), a layered-resolution function (~30 lines), and a github.com preflight step (~30 lines). Plus rules-file parser (~20 lines).
- More state surface: two new sentinels, two new labels (`rc.github-identity`, `rc.ssh-config`), one new opt-out flag with implication chain, one new host-side cache file, one new rules file convention.
- Test suite grows by one file (`test-ssh-config.sh`) with 16 cases.
- Users who want path-based inference must author a 3-line rules file once. Friction, but the price for not hardcoding one user's directory layout in shared code.

**Tradeoffs:**
- **Mount complexity vs. simplicity.** A whole-`~/.ssh:ro` mount is one line of `rc` code; this design is ~160 lines. The complexity is bought for the property that ADR-017 D1 explicitly stakes the design on. Worth it.
- **Greeting probe vs. `gh api user`.** Greeting answers the SSH-side question; `gh api user` answers the OAuth-side question. They can disagree. Shipping greeting as primary is honest about which transport the design is fixing; `rc doctor` adds the cross-check.
- **Re-translate on every `rc up`.** Adds a ~10ms host-side awk pass to the resume path, in exchange for never serving a stale config. Cheap for the value.

## Known Limitations

- **Multiple GitHub identities per cage.** Pick one per cage. Workaround: clone with host aliases (`git@github-work:`) — D2 carries those over.
- **Non-github hosts not auto-routed.** `bitbucket.org`, `gitlab.com`, internal git hosts — covered only via D2 host-config carryover. The layered-resolution logic (D3) is github-only in v1.
- **Devcontainer routing parity is deferred.** `rc init` (devcontainer path) does not run config translation; only the visibility surface (D5 first-shell echo) is closed in v1. Devcontainer translation tracked in `rip-cage-akd`. Until that lands, devcontainer users see correct *status* on attach but get no actual *routing* — they'd hit the original bug, just visibly.
- **`Match` blocks are not deeply parsed.** Translation is line-by-line. `Match host`, `Match user`, `Match localnetwork` blocks pass through unchanged (path rewrite + ADR-014 D2 override still apply), but `Match exec` is stripped (D2 transform 4). Adequate for today's host configs; revisit if `Match`-based routing becomes common.
- **`--github-identity` accepts key basename only.** Username (`jonatan-mapular`) is more user-friendly but requires the cache to be populated; basename is unambiguous from first run. Future enhancement once cache is reliable.
- **Rules file format is intentionally minimal.** No regex, no `~` expansion in patterns, no env-var interpolation. If users hit this limit, promote to YAML/TOML in a follow-up.
- **Pubkey-on-host-filesystem dependency.** D4's allowlist mount sources pubkeys from `~/.ssh/<name>.pub` on the host. This works for the dogfooding setup but breaks for: 1Password SSH agent (pubkeys in vault, not on disk), macOS Secure Enclave / Secretive (keys never touch disk by design), ssh-agent forwarded from a remote workstation (pubkey files exist on a third machine), and users who `ssh-add`'d a key and then deleted the file. In all those cases the forwarded agent has the keys and signing works, but the pubkey allowlist mount finds nothing — the cage falls into the "user-config-block missing-pubkey" warn-and-degrade branch, which is silently first-key-wins under a yellow warning. The `ssh-add -L`-as-source alternative (called out under D1) fixes this cleanly but reshapes D4 enough to want dogfooding signal first. If someone hits this with a real workflow, that's the trigger to swap.
