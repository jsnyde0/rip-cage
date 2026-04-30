# ADR-020: SSH identity routing — the cage carries over your SSH config, not just your agent

**Status:** Reviewed — pending implementation
**Date:** 2026-04-27
**Design:** [Design doc](../design/2026-04-27-ssh-identity-routing-design.md)
**Builds on:** [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (forward-by-default), [ADR-018](ADR-018-macos-ssh-agent-discovery.md) (probe-and-pick agent)
**Amends:** [ADR-017](ADR-017-ssh-agent-forwarding-default.md) D2 — `--no-forward-ssh` extended to imply `--no-ssh-config` by default; D1, D3 unchanged.
**Related:** [ADR-001](ADR-001-fail-loud-pattern.md) (loud + actionable failure), [ADR-014](ADR-014-push-less-cage.md) D2 (non-interactive SSH posture), project [CLAUDE.md](../../CLAUDE.md) philosophy section (autonomy over containment, "it's annoying" as a design signal)

## Context

ADR-017 forwarded the host ssh-agent into the cage so the agent could push without human intervention. ADR-018 made that forwarding honest by probing for the agent the user actually populated. Together they solve "can the cage *sign* with my keys?" — the agent socket is wired and reachable.

What they leave open: "*which* of my keys signs *what*?". OpenSSH normally answers that via `~/.ssh/config` — `Host` blocks, `IdentityFile` directives, `IdentitiesOnly yes`. The cage has none of that. With multiple keys in the forwarded agent, OpenSSH falls back to "offer every identity in load order; the server picks the first authenticated one." On GitHub, this means whichever key was loaded first into the agent decides which GitHub *account* the cage is logged into for the entire session.

Concretely (verified 2026-04-27 inside two running cages):
- `ssh -T git@github.com` returns `Hi jsnyde0!` from the work cage `platform-mapular-gtm`, despite the project requiring the `jonatan-mapular` (work) account.
- `git push` to `git@github.com:mapular/mapular-gtm.git` fails with "Repository not found" — wrong identity, not wrong repo. `bd dolt push` fails the same way.
- Repos cloned with host-alias URLs (`git@github-work:mapular/...`) — a common host pattern — fail with "Could not resolve hostname github-work" because the alias only exists in the host's `~/.ssh/config`, which the cage doesn't have.

This is the same class of footgun ADR-018 closed for the agent socket: the cage *looks* like it's wired correctly (forwarding is on, keys are loaded, banner is green), but the routing silently lands on the wrong identity. The user finds out via a misleading downstream error, hours later. CLAUDE.md is explicit: that is a design signal, not a documentation gap.

The fix is structurally the same as ADR-018: **the cage inherits the user's host SSH posture**. ADR-018 inherited the agent state (which keys are loadable). This ADR inherits the agent config (which key for which destination). Together they restore the invariant the project framing assumes: "your existing setup carries over via `rc up`."

## Decisions

### D1: Strict mount — config + referenced public keys + known_hosts only

**Firmness: FIRM**

`rc up` generates a cage-specific `/home/agent/.ssh/config` from the host's `~/.ssh/config`, mounts the public keys referenced by that config, and bind-mounts `~/.ssh/known_hosts`. **No private key material is mounted.** The threat model from ADR-017 D1 ("private keys never cross the container boundary") is preserved structurally — bytes that aren't there can't be exfiltrated, regardless of mount mode.

Specifically:
- Mount target: `/home/agent/.ssh/`, owned `agent:agent`, mode `0700`. Files inside are read-only bind mounts.
- Files mounted: the generated config (one file), each `<keyname>.pub` referenced by an `IdentityFile` directive (zero or more), and `known_hosts` (additive to the cage-baked `/etc/ssh/ssh_known_hosts`).
- Files **not** mounted: any private key file, `config.d/` directories not explicitly traversed, agent-related files, `authorized_keys`.

This rules out the simpler `bind-mount ~/.ssh:ro` shape. Read-only is not a security boundary against an in-cage process that wants to read bytes; ADR-017 D1's structural invariant ("keys aren't in the container") would be lost. Strict mount preserves the property.

**Rationale:** Public keys are not sensitive; they exist on GitHub already. The cage needs them to honor `IdentitiesOnly yes` (filter the forwarded agent down to a specific identity). `known_hosts` carries the user's TOFU history (gitlab.com, internal hosts) and is also non-sensitive. Anything else from `~/.ssh/` is either secret material or unrelated and stays on the host.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Bind-mount `~/.ssh:ro` whole | `direct:` ADR-017 D1 stakes "private keys never cross the boundary" as the structural property; read-only mount still makes bytes readable — the invariant is structural, not access-control-level |
| Generate config-only, no pubkey mount | `reasoned:` `IdentitiesOnly yes` cannot filter the forwarded agent without a matching pubkey file on disk; without the pubkey, `IdentitiesOnly yes` is inert and SSH falls back to first-key-wins — the exact bug this design fixes |
| Source pubkeys from `ssh-add -L` (synthesize cage `.pub` files from forwarded agent's identities) | `reasoned:` Identity matching becomes fingerprint/comment-based instead of filename-based; rules-file `<keyname>` → agent-identity matching then requires a fingerprint or comment lookup against `ssh-add -L` output; adds indirection at debug time. Revisit if 1Password/Secure Enclave users hit the pubkey-file gap in dogfooding. |
| In-cage agent (load keys into a cage-local ssh-agent) | `direct:` ADR-017 D1 prohibits private key material crossing the container boundary |
| Per-project `.cage/ssh-config` checked into each repo | `reasoned:` Forces every project author to ship the file; doesn't cover repos cloned with host aliases; doesn't help `bd dolt push` (daemon, not per-project ssh consumer); regresses "your existing setup carries over via `rc up`" |

**What would invalidate this:** evidence that strict allowlist generation is so brittle in practice that users are routinely turning it off via `--no-ssh-config`. At that point, revisit per-project files or whole-`~/.ssh:ro` with a different threat model. Separately, if real users hit the "no pubkey files on disk" gap (1Password agent, Secure Enclave, forwarded from another host — see Limitation), promote the `ssh-add -L`-as-source alternative from rejected to chosen and rework D4's mount semantics.

**Invalidation check (mechanical, optional):** In `tests/test-ssh-config.sh`, after `rc up`, verify `docker exec "$container" find /home/agent/.ssh -maxdepth 1 -type f | grep -vE '\.pub$|/config$|/known_hosts$'` returns empty. Non-empty output means a private key crossed the container boundary and D1 is violated.

**Limitation (host-filesystem pubkey dependency).** This decision assumes the host has `<name>.pub` files under `~/.ssh/` for every key the user wants the cage to use. That holds for the dogfooding setup (`~/.ssh/id_ed25519_personal.pub`, `id_ed25519_work.pub`). It does **not** hold for: 1Password SSH agent (pubkeys live in the vault, not on disk), macOS Secure Enclave / Secretive (keys never touch disk by design), agent forwarded from a remote workstation where pubkey files exist on a third machine, and users who `ssh-add`'d a key then deleted the file. In those configurations the forwarded agent works perfectly but D4's mount finds nothing and lands the user in the "user-config-block missing-pubkey" warn-and-degrade branch — strictly worse than today, since the fallback is "first-key-wins" with a confusing warning. Captured here rather than fixed in v1: switching to `ssh-add -L` as the canonical pubkey source is a single-decision pivot (see alternative in the table above) but reshapes D4 enough that we want dogfooding signal first.

### D2: Translate the host config; re-run on every `rc up`; write to a stable per-container path

**Firmness: FIRM**

The host config is shaped for the host. `IdentityFile ~/.ssh/<key>` paths resolve to `/Users/jonat/.ssh/...`, which doesn't exist inside the cage. `Include ~/.orbstack/ssh/config` references host-only paths. macOS-specific directives (`UseKeychain yes`) error on Debian openssh-client. And several real-world directives (`Match exec`, `ProxyCommand`, `ControlPath`) reference host binaries or filesystem state the cage does not share.

Six transforms applied at `rc up`:

1. **Path rewrite.** `IdentityFile $HOME/.ssh/<name>` → `IdentityFile /home/agent/.ssh/<name>`. Tilde-expanded and absolute paths under `$HOME/.ssh/` both handled. The rewritten path points at the *private-key* basename even though no private key is mounted (D1) — OpenSSH falls back to reading `<path>.pub` automatically when given a private-key path that doesn't exist, and the agent does the actual signing. Pointing `IdentityFile` directly at a `.pub` file also works (OpenSSH accepts either as the public-key identity), but keeping the host's private-key path makes the translation a pure rewrite of the user's directive rather than a semantic edit, which keeps the "your config carries over" mental model intact.
2. **`IgnoreUnknown` shim.** Prepend `IgnoreUnknown UseKeychain,AddKeysToAgent,UseRoaming` so non-Apple openssh treats macOS-only directives as no-ops.
3. **Strip unsafe `Include`s.** `Include` directives outside `$HOME/.ssh/` are commented out (with `# rip-cage:` prefix). Includes inside `$HOME/.ssh/` are translated and their targets mounted recursively.
4. **Strip host-only directives.** `Match exec`, `ProxyCommand`, `ProxyJump`, `ControlMaster`, `ControlPath`, `IdentityAgent` are commented out with `# rip-cage: stripped (host-only)`. Each references binaries or filesystem state the cage does not share; leaving them produces confusing "No such file" errors at SSH-time. (`IdentityAgent` is special — it overrides the agent socket; rewriting would lie about the user's intent. Stripping lets the forwarded `SSH_AUTH_SOCK` from ADR-017 take over.)
5. **Override ADR-014 D2 directives at per-Host level.** If user config sets `BatchMode no`, `StrictHostKeyChecking accept-new`, `UserKnownHostsFile`, or `GlobalKnownHostsFile` inside a `Host` block, those values would defeat the cage's TTY-hang fail-loud posture (the `Match final Host *` system block at `/etc/ssh/ssh_config.d/00-rip-cage.conf` does not override per-Host user values per OpenSSH "first value wins"). Translation rewrites these four to ADR-014 D2 values with `# rip-cage: overridden (ADR-014 D2)` comment.
6. **Append synthesized `Host github.com` block** (D3) when layered resolution selects a pin and user's config doesn't already contain one.

**Translation runs on every `rc up`** — both create and resume paths — and writes to a **stable per-container path** at `~/.cache/rip-cage/<container-name>/ssh-config`. The bind-mount points to that stable path. Two correctness consequences:
- **No tempfile GC failure mode.** A path under `~/.cache/` is not a candidate for `/tmp` cleanup.
- **Host-config edits propagate on the next resume.** Users edit `~/.ssh/config`, run `rc up <project>`, the cage picks up the change. No `rc down && rc up` ceremony required.

The transform is idempotent — running twice with identical input produces identical output.

**Rationale:** The host config encodes user intent (which key for which host); the cage needs that intent in a form it can execute. A pure passthrough mount fails parse on `UseKeychain` lines, has wrong `IdentityFile` paths, and can defeat ADR-014 D2's loud-fail posture. The six transforms are the smallest set that produces a valid cage config from a real-world host config. Re-running on every `rc up` is the smallest design that eliminates two silent-staleness failure modes (resume drift; tempfile GC) — the cost is ~10ms of host-side awk per resume, which is below noise compared to existing `docker start` cost.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Translate at `rc up`, tempfile, create-only | `reasoned:` Resume staleness — host config edits don't propagate; tempfile GC risks a broken bind-mount on the next container start |
| Bind-mount host config directly | `direct:` ADR-014 D2's non-interactive SSH posture can be defeated by per-Host user values; macOS-only directives (`UseKeychain`) error on Debian openssh-client; `IdentityFile` paths resolve to host-only paths |
| Generate cage config from scratch (ignore host config) | `reasoned:` Loses user's per-host preferences; defeats the goal of "your existing setup carries over via `rc up`" |
| `docker cp` injection on `docker start` rather than bind mount | `reasoned:` More moving parts; harder to introspect from host; identical staleness fix with no advantage over the bind-mount + stable-path approach |

**What would invalidate this:** the translation set grows past ~8 transforms or starts requiring real ssh_config grammar parsing. At that point, vendor a small Python helper using a real parser.

**Invalidation check (mechanical, optional):** In `tests/test-ssh-config.sh`, run the translation against a fixture `~/.ssh/config` containing `UseKeychain yes` and verify (a) the translated output leads with `IgnoreUnknown UseKeychain,...` and (b) `ssh -G github.com` inside the cage returns no fatal-directive errors. If the `IgnoreUnknown` shim is absent, Debian openssh-client will error on macOS-only directives and transform 2 is broken.

### D3: github.com identity pin uses a four-layer priority list with no built-in inference defaults

**Firmness: FIRM**

For users whose host config already pins `Host github.com` (e.g., bot accounts, single-identity setups), D2 carries that over and we're done. The hard case is the user whose host config only has aliases (`Host github-work`, `Host github-personal`) — `git@github.com:` URLs in the cage have no anchor.

Resolution priority at `rc up`:
1. `--github-identity=<keyname>` CLI flag, or `RIP_CAGE_GITHUB_IDENTITY=<keyname>` env var.
2. `rc.github-identity=<keyname>` container label (resume only — set by prior `rc up`).
3. First matching glob from `~/.config/rip-cage/identity-rules` against `rc.source.path`. **No built-in defaults.** File absent → layer 3 yields no match.
4. No match → no synthesized `Host github.com` block; preflight (D6) surfaces `unset` loudly.

Rules-file format is one rule per line, glob + key basename, no parser:

```
# ~/.config/rip-cage/identity-rules
~/code/mapular/*    id_ed25519_work
~/code/personal/*   id_ed25519_personal
```

Empty lines and `#`-comments skipped. Bash `[[ "$path" == $pattern ]]` glob semantics, no regex. Patterns are tilde-expanded (`~` → `$HOME`) before matching so that `~/code/mapular/*` works as expected.

When a layer matches, `rc` appends a synthetic `Host github.com / IdentityFile /home/agent/.ssh/<name> / IdentitiesOnly yes / User git` block to the translated config and persists `rc.github-identity=<name>` as a label. The chosen layer is recorded in `/etc/rip-cage/ssh-config-source`.

**CLI override on resume errors loud.** `rc up --github-identity=<name>` against a container already labeled errors with `Error: container <name> already labeled rc.github-identity=<existing>. Run 'rc destroy <name> && rc up …' to reset.` This matches ADR-018's posture-immutable-on-resume contract; silent relabel-on-resume is exactly the silent-fallback ADR-001 outlaws.

**Rationale:** Layer 3 with **no built-in defaults** is the deliberate choice over hardcoding `~/code/mapular/*` and `~/code/personal/*` directly into `rc`. Hardcoded paths in shared code encode one user's directory layout — fine for closed-source dotfiles, wrong for an open-source project. The cost to users is one three-line text file authored once per machine; the benefit is that the open-source code makes no assumption about where users keep their projects. Layers 1–2 cover the explicit-override use case; layer 4 is the honest "we don't know, ask the human" failure mode that explicitly does not silently fall back to first-key-wins.

This explicitly *does not* generalize to other hosts (bitbucket, gitlab, internal). Those route only via D2 (host config carryover). Adding more hosts follows the same four-layer pattern but is a separate change.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Four-layer priority with hardcoded `~/code/mapular`/`~/code/personal` defaults | `reasoned:` One user's directory layout shipped as project default; bad open-source posture for an open-source project |
| Always require explicit pin (no rules file) | `reasoned:` CLAUDE.md: "'It's annoying' is a design signal"; forcing explicit pin for every project is the kind of friction the cage is designed to avoid |
| Random/first key wins (today's behavior) | `direct:` The confirmed bug — `mapular-gtm` cage auth'd as `jsnyde0`, pushing to wrong identity |

**What would invalidate this:** the rules-file format proves insufficient (users want regex, env-var interpolation, conditional rules). Promote to YAML/TOML in a follow-up.

**Invalidation check (mechanical, optional):** `grep -n "code/mapular\|code/personal" rc | wc -l` must return 0. Any non-zero result means a hardcoded user path was added to `rc`, violating the "no built-in inference defaults" rule. (Runnable now against current source.)

### D4: Allowlist pubkey mount; explicit-pin missing-pubkey aborts; `IdentitiesOnly yes` is load-bearing

**Firmness: FIRM**

The translation step in D2 produces the set of `IdentityFile` paths the cage config references. Those `.pub` files (and only those, plus `~/.ssh/known_hosts`) get bind-mounted read-only into `/home/agent/.ssh/`.

**`IdentitiesOnly yes` correctness contract.** The synthesized `Host github.com` block from D3 includes `IdentitiesOnly yes`, which is what *prevents* the agent from offering all keys — it filters the agent down to the named identity using the matching pubkey file on disk. **If the named pubkey is missing, `IdentitiesOnly yes` is inert** and SSH falls back to "offer every agent key in load order" — the exact bug this design exists to fix. So design correctness depends on `IdentitiesOnly yes` AND the pubkey file being present.

This shapes missing-pubkey handling:

| Pin source | Missing pubkey behavior | Why |
|---|---|---|
| Layer 1, 2 (explicit pin via CLI/label) | **`rc up` aborts loud** | The user named a specific identity; producing a config that silently selects a different key is a silent-fallback per ADR-001. |
| Layer 3 (rules file) | **`rc up` aborts loud** | Rules file is a user-declared convention; honoring it requires keys present. Same loud-fail logic. |
| Layer 4 (no pin) | No-op | No synthesized block, no missing-pubkey condition. Preflight surfaces `unset`. |
| User-config Host block referencing missing pubkey | Skip mount + warn at `rc up`; do not abort | The user's host config is in their domain; cage is a guest. Surface loudly but don't gate startup on host-config hygiene. |

Abort message follows ADR-001 actionability: `Error: --github-identity=id_ed25519_work selected, but ~/.ssh/id_ed25519_work.pub does not exist on host. Generate the key (ssh-keygen) or correct the rules file.`

**Rationale:** This decision is the difference between "loudly correct" and "silently wrong" — without it, every other piece of the design can be in place and the cage still routes to the wrong identity. The pubkey-availability invariant is load-bearing; surfacing it as an explicit decision (rather than an implementation note) keeps it visible to future readers.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Warn-and-degrade always (never abort) | `direct:` ADR-001: fail-loud + actionable; silently regressing to first-key-wins on explicitly-named keys defeats the design — the user named a key, we must honor it or stop |
| Mount whole `~/.ssh:ro` to guarantee pubkeys always present | `direct:` D1 prohibits — private keys cross the container boundary |

**What would invalidate this:** users routinely hitting the explicit-pin abort and finding it more annoying than helpful. Then degrade-with-loud-warning becomes the right call. Unlikely — users hit this at exactly the moment they typo'd a key name, which is exactly when loud is right.

**Invalidation check (mechanical, optional):** In `tests/test-ssh-config.sh`, run `rc up <staging-path> --github-identity=nonexistent_key_xyz_abc` and assert exit code non-zero with an actionable message containing the key name. If it exits 0 or silently degrades to first-key-wins, D4's abort-on-missing-pubkey rule is broken.

### D5: Sentinels feed banner + `rc ls`; first-shell echo closes devcontainer visibility gap

**Firmness: FIRM**

Two new sentinels join the existing pair from ADR-018 D3:

- `/etc/rip-cage/github-identity` — single line. Resolved github.com username (e.g., `jonatan-mapular`); empty/`unset`/`unreachable` per state.
- `/etc/rip-cage/ssh-config-source` — single line. One of `host-config`, `cli-flag`, `label`, `rules-file`, `none`, `disabled`. Aids debugging.

Both are written by the in-cage preflight (D6), running via `docker exec` as root — same posture as ADR-018 D3 sentinels. `/etc/rip-cage/` is root-owned; agent-uid writes would fail. A regression test asserts ownership/perms after fresh `rc up`.

The zshrc ssh-agent banner block reads both. `rc ls` gains a `GH-IDENTITY` column. `rc doctor` (deferred bead) surfaces full provenance plus the `gh api user` cross-check (D6).

**First-shell echo (devcontainer visibility parity).** The tmux banner is rc-up-attached, which means `rc init` (devcontainer) users never see it. To close the visibility gap regardless of entry path, `init-rip-cage.sh` reads both sentinels and echoes a one-line identity status during init. The line appears in the first shell's startup output on every attach — `rc up` users see it from tmux; devcontainer users see it from the integrated terminal. Routing is named on both paths; full devcontainer routing parity (translation runs `init-rip-cage.sh`-side) is a follow-up tracked in `rip-cage-akd`.

**Rationale:** Consistent with ADR-018 D3 — separate single-line sentinels keep the zshrc `case` matchers simple and avoid multi-line parsing. The first-shell echo is the smallest change that makes routing *visible* on the devcontainer entry path even before *routing* is implemented there — visibility-without-correctness is strictly better than the current silent-and-wrong baseline, and it does not block this ADR on the larger `rip-cage-akd` scope.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| tmux banner only (no first-shell echo) | `reasoned:` devcontainer entry path (`rc init` → VS Code "Reopen in Container") never shows the tmux banner — visibility would be rc-up-attached only, leaving devcontainer users with no identity routing feedback on any entry path |

**What would invalidate this:** if a future ADR consolidates rip-cage sentinels into one structured file (yaml/json), this and ADR-018 D3 are migrated together. Not in scope here.

**Invalidation check (mechanical, optional):** After `rc up`, `docker exec "$container" stat -c "%U %a" /etc/rip-cage/github-identity /etc/rip-cage/ssh-config-source` must output `root 644` for both files. Missing files or non-root ownership means D5's root-preflight write path regressed.

### D6: github.com identity preflight in cage; greeting probe primary; cache shipped in v1

**Firmness: FIRM**

After ADR-018 D3's agent-reachability preflight passes (`ok:N`), a new identity preflight runs from inside the cage:

```bash
ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com 2>&1
```

GitHub's SSH greeting (`Hi <user>!`) names the authenticated user. The preflight extracts it, writes to `/etc/rip-cage/github-identity`, and compares against the expected username (looked up from `rc.github-identity` label via a `<keyname> → <github-user>` cache at `~/.cache/rip-cage/identity-map.json`).

**Cache is shipped in v1, not deferred.** Without the cache, the preflight can only report "resolved as <user>" with no expectation to compare against — `match`/`mismatch` detection collapses to "report-only," which is strictly worse than today. Cache TTL: 24h. Refresh on `rc auth refresh`. Lives on the host (not in the container) so multiple cages share resolved identities.

**Cold-cache behavior (populate-then-compare).** On first `rc up` for a given keyname, the cache has no `<keyname> → <github-user>` entry. The preflight writes the greeting result to the cache *before* comparing, so a correctly-configured first run produces `match`, not `unset`. The `unset` state applies only when no pin was resolved at all (layer 4 — no `Host github.com` block synthesized, no `rc.github-identity` label).

**Host-config-carries-over path.** When source is `host-config` (user's own `Host github.com` block carried over by D2, no `rc.github-identity` label written), the label-based cache comparison is skipped — the user's block is authoritative by design. The greeting probe still runs; the resolved identity is written to `/etc/rip-cage/github-identity` and shown in the banner. No `unset` prefix — routing is explicitly configured in the user's host config.

**Greeting probe is primary; `gh api user` is a parallel diagnostic.** The greeting answers the SSH-side question this design is about — "which SSH identity does GitHub see?" — directly. `gh api user --jq .login` answers a different question — "which OAuth identity is `gh` auth'd as?" — using the host's forwarded Claude Code credentials. The two can disagree (gh OAuth'd as `personal`, SSH key for `work`), and the disagreement is information, not noise. `rc doctor` (deferred bead) runs both and surfaces conflicts; v1 ships only the greeting probe in the rc-up critical path.

Three resolution states:

| Outcome | When | Action |
|---|---|---|
| `match` | resolved == expected | silent at create, banner green |
| `unset` | no expectation set, resolved=anything | yellow banner: `github.com routing unspecified — pushes will go to <resolved>; pin via 'rc up --github-identity=<name>' (requires fresh container)` |
| `mismatch` | expected != resolved | red banner: `github.com expected <expected> but resolved as <resolved>. Recreate with: rc destroy <name> && rc up <path> --github-identity=<name>. Debug: ssh -vT git@github.com (in cage).` |

The mismatch hint explicitly names `rc destroy && rc up` because `--github-identity` on resume errors per D3.

If github.com is unreachable (egress firewall, no network), the sentinel records `unreachable` and the banner says so. Consistent with ADR-018 D3.

`rc up` does not abort on `unset`/`mismatch`/`unreachable` — read-only work and HTTPS git remain useful. The guarantee is that the routing is **named and visible**, never silent.

**Rationale:** The agent-reachability preflight from ADR-018 catches "can the cage sign?" but not "is it signing as who you expected?" This decision closes that gap. Greeting probe is contractual-enough for a 5-year-old format, has zero new dependencies (`ssh` is already in the cage), and is fast (one SSH round-trip). `gh api user` is the right tool for the OAuth-vs-SSH cross-check but adding it to the critical path conflates two distinct identity questions. Shipping the cache in v1 (rather than deferring) makes the dependent decision (mismatch detection) ship-able on day one.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| `gh api user` as primary | `reasoned:` Answers "which OAuth identity is `gh` auth'd as?" — a different question from "which SSH identity does GitHub see?"; the two can disagree; conflates two distinct identity questions and adds gh-auth dependency to the rc-up critical path |
| Run both probes, treat conflict as third state | `reasoned:` More LOC in critical path; two-axis state matrix complicates banner; the SSH vs OAuth conflict is better surfaced in `rc doctor` (deferred bead) than as a third banner state on every `rc up` |
| No preflight, surface only on first push failure | `direct:` ADR-001 fail-loud; user finds out via a misleading "Repository not found" downstream error rather than a clear identity mismatch — the exact silent-failure class this design closes |
| Defer cache, ship "report-only" v1 | `reasoned:` Without a `<keyname> → <github-user>` cache, mismatch detection (expected vs resolved) is non-shippable; D6 collapses to logging and the dependent match/mismatch/unset state machine cannot ship |

**What would invalidate this:** GitHub deprecates the SSH greeting format. Switch to `gh api user` as primary and demote the greeting to fallback.

**Invalidation check (mechanical, optional):** After `rc up` with a resolved identity, `jq -e 'keys | length > 0' ~/.cache/rip-cage/identity-map.json` must exit 0. An absent or empty cache means the cold-cache populate-then-compare step was dropped and first `rc up` with correct config will show `unset` instead of `match`.

### D7: `--no-ssh-config` opt-out; `--no-forward-ssh` implies `--no-ssh-config` by default

**Firmness: FIRM**

Sibling to ADR-017 D2's `--no-forward-ssh`. Skips config translation, pubkey mount, and identity preflight. Cage behaves exactly as today: forwarded agent (per ADR-017/018), no config, first-key-wins. Persisted as `rc.ssh-config=on|off` label so resume preserves posture.

**`--no-forward-ssh` implies `--no-ssh-config` by default.** A user reaching for ADR-014 containment finds `--no-forward-ssh`; without the implicit chain, they'd end up with a cage that has translated config + pubkey mounts but no agent — confusing posture ("I asked for no SSH, why does my cage have my pubkey files?"). Mirrors the existing `_UP_NO_HOST_AGENT` auto-relabel pattern at `rc:1097-1107`. To opt out of the implication (forward agent off, but ssh-config on), pass `--no-forward-ssh --ssh-config` explicitly.

Use cases for opting out:
- ADR-014 containment posture (`--no-forward-ssh` alone gets you both off, atomically).
- A user whose host setup is already minimal.
- Debugging: comparing pre-vs-post behavior.
- Single-identity hosts where no routing logic is needed.

**Rationale:** Preserves choice for users whose host setup is minimal or who want to debug pre-vs-post behavior. The implication chain reduces the common-case (containment) from "remember two flags" to "remember one." Same posture-persistence pattern as `rc.egress`, `rc.forward-ssh` keeps `rc` consistent.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Independent flags, no implication | `reasoned:` Containment user reaches for `--no-forward-ssh`, ends up with a cage that has config + pubkey mounts but no agent — confusing half-state ("I asked for no SSH, why are my pubkeys mounted?"); discoverability footgun |
| New `--no-ssh` alias toggling both atomically | `reasoned:` Yet-another-flag; doesn't reduce the existing flag count and doesn't address the discoverability gap for users who already know `--no-forward-ssh` |

**What would invalidate this:** telemetry showing nobody opts out, or that the implication chain confuses more than it helps. Then drop the flag or the chain as dead surface.

**Invalidation check (mechanical, optional):** `rc up <path> --no-forward-ssh` then `docker inspect "$container" --format '{{index .Config.Labels "rc.ssh-config"}}'` must print `off`. Also verify no ssh-config bind-mount appears in `docker inspect "$container" --format '{{json .Mounts}}'`. If the label is missing or the mount is present, the implication chain is broken.

## Consequences

**Positive:**
- The cage's `git push`, `bd dolt push`, `gh` write ops route to the right identity by default for users with a routing rules file.
- Repos cloned with host aliases work without modification.
- Identity routing is named, visible, and debuggable at every layer (preflight, sentinel, banner, first-shell echo, `rc ls`).
- ADR-017 D1's structural property ("private keys never cross the container boundary") preserved.
- ADR-014 D2's loud-fail posture preserved at the per-Host translation layer (override-on-conflict).
- Mental model collapses to "the cage has your SSH posture" — agent and config both carry over.
- Host `~/.ssh/config` edits propagate on resume — no `rc down && rc up` ceremony.

**Negative:**
- `rc` gains ~80 LOC of bash/awk for translation + ~30 LOC for layered resolution + ~30 LOC for identity preflight + ~20 LOC for rules-file parsing + cache management.
- Two new labels (`rc.github-identity`, `rc.ssh-config`), two new sentinels, one new opt-out flag with implication chain, one new host-side cache file, one new rules file convention.
- Users wanting path-based inference must author a rules file once (3 lines for the typical case).
- `--no-forward-ssh` + `--no-ssh-config` is now the way to reach push-less containment, with the implicit chain doing the second flag for free.

**Neutral:**
- Greeting probe is one SSH round-trip per `rc up`. Cost negligible vs existing rc-up time.

## Implementation notes

- `rc`: add `_translate_ssh_config()` (host-side, six transforms, idempotent), `_resolve_github_identity()` (host-side, four-layer), `_parse_identity_rules()` (host-side, ~20 LOC), `_up_github_identity_preflight()` (in-container, mirrors ADR-018 `_up_ssh_preflight`).
- Translation output path: `~/.cache/rip-cage/<container-name>/ssh-config`. Created with `mkdir -p`. Re-runs on every `rc up` (create + resume) and overwrites in place.
- `rc up`: add `--github-identity` and `--no-ssh-config` / `--ssh-config` flags. New labels `rc.github-identity`, `rc.ssh-config`. Resume path reads labels (same pattern as `rc.forward-ssh`) and re-runs translation. CLI override on existing `rc.github-identity` label errors loud; missing pubkey on explicit pin (CLI/label/rules) errors loud (D4).
- `init-rip-cage.sh`: reads `/etc/rip-cage/github-identity` + `/etc/rip-cage/ssh-config-source` and echoes a one-line status during init log (D5 first-shell echo).
- `zshrc`: extend ssh-agent banner block to read the two new sentinels and surface a github.com line.
- `rc ls`: add `GH-IDENTITY` column.
- `rc doctor` (deferred bead): show resolved identity + source per container, run `gh api user` cross-check, name in-cage `ssh -vT git@github.com` debug command.
- Cache: `~/.cache/rip-cage/identity-map.json`, 24h TTL, refresh on `rc auth refresh`.
- `tests/test-ssh-config.sh`: 16 cases per design doc.
- README + auth.md: document `--github-identity`, the four-layer priority, the rules-file format and location, and how to override.
- `rip-cage-akd` (devcontainer parity): expand scope to include config translation in `initializeCommand`. May split into separate bead for translation vs. visibility.

## Carries over from ADR-017 / ADR-018 / ADR-014

- ADR-017 D1 (forward-by-default), D2 (`--no-forward-ssh`), D3 (LFS / session-close): unchanged.
- ADR-018 D1 (probe-and-pick agent), D2 (convention socket fallback), D3 (sentinel format), D4 (rewritten prereq table): unchanged.
- ADR-014 D2 (non-interactive SSH posture: `BatchMode=yes`, pinned `known_hosts`, `StrictHostKeyChecking yes`): unchanged but actively defended at the translation layer (D2 transform 5).
- The structural property "private keys stay on host" carries over to the new mount surface: this ADR adds the public half.
