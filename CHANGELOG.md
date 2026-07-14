# Changelog

All notable changes to rip-cage will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking)

- **`.rip-cage.yaml` config schema v2 — supported version set is now `{2}`** (rip-cage-tsf2.10; [ADR-021](docs/decisions/ADR-021-layered-rip-cage-config.md) D2/D3/D9). The config-schema namespace (`~/.config/rip-cage/config.yaml` + `<repo>/.rip-cage.yaml`) is a breaking bump; the tool-manifest namespace (`tools.yaml`) is a separate version namespace and is untouched.
  - **Merge model:** the v1 `additive_list` / `selection_list` split is retired. **All `list` fields now union by default** across the fold-left stack `[schema defaults, global, project]` (order-preserving dedup, lower layers first); a file layer may tag a list `!replace` to discard everything inherited from lower layers (`!replace []` is the explicit zero-out). The override is visible in the project-file diff at point of use. `mounts.denylist` is the one **replace-forbidden** list (`!replace` on it aborts loud — ADR-023 D2, the secret-path denylist is additive-only). Enum-shaped scalars are renamed schema type `enum` (semantics unchanged: project replaces global, unknown value aborts loud). One consequence: `mounts.allow_risky` flips replace→union (use `!replace` to restore narrowing).
  - **Versioning:** `version: 1` files **abort loud** with a migration hint (change to `version: 2`; express v1 replace-narrowing with `!replace`). Version-absent files assume `2` with a per-invocation warning — **except** a version-absent file declaring `mounts.allow_risky`, which aborts demanding an explicit version. A higher-than-supported version aborts iff the file uses `!replace`, else warn-and-skip.
  - **Vestigial fields dropped:** `network.mode`, `network.dns.forward_to`, `network.http.forward_to` are removed from the schema and join the loud-reject retired-fields table (a file still carrying them aborts naming the field + fix, not a silent drop).

### Added

- **Host-side write verbs `rc config set/add/remove --scope global|project`** (rip-cage-tsf2.10; [ADR-021](docs/decisions/ADR-021-layered-rip-cage-config.md) D8). Surgical, comment-preserving edits to the posture files (`yq` reads only; a minimal textual splice of the original bytes, re-validated by the full loader — `yq` re-emit is forbidden as a write path). The verbs are sugar; the two YAML files stay the source of truth. Refusals (each says "edit the file"): tag placement/removal, structural keys (`auth.credentials`), `mounts.denylist` remove, ambiguous value shapes. `add` is idempotent; created files declare `version: 2`; host-side only. `rc allowlist add` becomes sugar over `rc config add network.allowed_hosts`.
- **Unified effective view — `rc config show` with four provenance sources** (rip-cage-tsf2.10; [ADR-021](docs/decisions/ADR-021-layered-rip-cage-config.md) D4). Each effective value is attributed to `default` / `global` / `project` / `manifest:<tool>`. Tool-manifest egress is a separate provenance field (`manifest_egress` + `manifest_egress_source` in `--json`; a distinct block in the YAML view), never folded into `network.allowed_hosts` — so a manifest egress change surfaces as **"requires rebuild"**, distinct from reload-eligible config drift. `rc config show` itself takes no `--cage` and always reads the current host manifest (`pending`); `rc allowlist show --effective --cage <name>` and `rc doctor <name>` are the two consumers that name a cage in scope and read that cage's *applied* state instead (not the possibly-drifted host manifest). "What can this cage reach and why" is one command family; `rc allowlist show --effective`, `rc doctor`, and `rc reload --dry-run` converge on the same contract.

## [0.12.1] - 2026-07-07

Stabilization patch on the 0.12.0 non-possession release: the remaining false alarms on healthy cages, a stale-manifest drift detector for `rc build`, and the test-suite reliability fixes that make CI trustworthy again.

### Added

- **Seed-drift detection on `rc build` + `rc manifest reconcile`** (rip-cage-6vt9). `rc build` no longer silently bakes a stale layout from an un-reconciled `~/.config/rip-cage/tools.yaml` (the repro silently reverted a shipped guard relocation). A seed-provenance fingerprint stamp plus an entry-level structural comparison for unstamped legacy manifests warns — naming the diverging entries — when the seeded recipe entries have drifted from the current `dist/default-tools.yaml`; provably-current or all-custom manifests stay silent. The new `rc manifest reconcile` merges by entry name (dist entries refreshed, user-added entries preserved verbatim, validated before writing, timestamped backup first).

### Fixed

- **The remaining cry-wolf cluster on healthy cages** (rip-cage-i7s9, rip-cage-ebdd, rip-cage-towm). Three false alarms fixed in one cross-probe sweep: `rc doctor`'s dead-mounts probe downgrades a dead single-file mount to INFO when the init snapshot convention covers it (seed-only mount — runtime reads the snapshot; mounts without a seed, like the live `.credentials.json` refresh channel, still FAIL); the doctor auth probe is posture-aware (recognizes the non-possession container label, then the `CLAUDE_CODE_OAUTH_TOKEN` env) instead of FAILing on a healthy placeholder-token cage; and the keychain-extraction warning only fires when no usable credentials file exists. No-signal cages still fail loud on all three.
- **E2e probe auth pre-flights recognize non-possession cages** (rip-cage-6k2u). The two managed-settings probe suites' pre-flights only knew the credentials-file and `ANTHROPIC_API_KEY` signals, so they FATALed on healthy non-possession cages; they now mirror the doctor probe's label + env-token recognition. Absent every signal, they still refuse to run.
- **`apt-get install yq` hint removed everywhere** (rip-cage-7nls). Six `rc` hint sites and two doc surfaces recommended apt's `yq` on Debian/Ubuntu — which installs the kislyuk python-yq, flag-incompatible with the mikefarah v4 `yq` rc requires (`-e`, `... style=`, `eval` positional). All now point at `brew install yq` or the mikefarah release binary and name the trap.
- **Test-suite reliability: errexit leakage + reserved-scratch CI reds** (rip-cage-1b91, rip-cage-29sp, rip-cage-5fsy). Seven test files carried `set +e … set -e` brackets whose restore silently switched errexit ON for files baselined without it — later checks in the file were truncated instead of recorded as failures (the mechanism behind the CM15-CM21 silent truncation on Linux CI). All 43 leaking restores flipped to restore-to-baseline; the credential-mounts and config-ro-mount suites additionally gained visible SKIPs on reserved-scratch hosts, un-redding the Linux CI host-only job. The new keychain-warning test also stubs `uname` alongside `security`, so it exercises the macOS branch it documents on Linux CI instead of failing there.

## [0.12.0] - 2026-07-06

The headline is **credential non-possession**: a cage can now run `claude` while never holding the real credential — the cage carries only a placeholder token and a composed external mediator injects the real secret on egress. The posture is per-project, per-tool config (default unchanged: full possession), and the release rounds it out with the doctor probes, seed synthesis, and warning fixes that make a non-possession cage boot clean and verifiable.

### Added

- **Credential non-possession — config-gated credential mounts + persisted mediator env-file pointer** (rip-cage-seqc.4; [ADR-026](docs/decisions/ADR-026-containment-mediation-identity.md) D4/D5). New per-project key `auth.credential_mounts: real | none` gates the previously hardcoded, unconditional Claude/pi credential mounts *and* the keychain extraction (default `real` preserves today's behavior bit-for-bit). Under `none` the cage never possesses the real secret — including via the symlink-follow re-mount path, a second previously-ungated pi-credential route closed in design review — so a placeholder-only cage plus a composed egress mediator (which swaps in the real token on the way out) leaves a prompt-injected agent nothing to exfiltrate ([ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md) D2). The companion key `network.egress.mediator_env_file` persists a host **pointer** to the mediator's secret env-file, applied on every up/resume (fail-loud on create, warn-and-continue on resume so an unattended restart degrades instead of stranding a half-init cage) — rc persists the path, never the secret value, which flows only into a root-scoped docker exec. Injector-agnostic: rc names no mediator tool ([ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12) and no mediation logic enters the floor (ADR-026 D4). The first live-Anthropic injected run went end-to-end, discharging ADR-026 D5's tripwire 4 (rip-cage-seqc.5). `.rip-cage.yaml` stays read-only in-cage, so the caged agent cannot self-upgrade to `real`.
- **Per-tool credential posture — mixed possession in one cage** (rip-cage-xhgr; [ADR-026](docs/decisions/ADR-026-containment-mediation-identity.md) D7). `auth.per_tool.{claude,pi}` null-default overrides on the global `auth.credential_mounts` scalar (`effective(T) = per_tool.T // global // real`), re-keyed at all four gate sites (keychain extraction, the Claude config-file unit, the symlink-follow leaf + fingerprint, the pi `auth.json` mount). Why per-tool: pi's openai-codex provider has no static long-lived token, so pi cannot ride static header-swap injection — the pragmatic caged-pi shape is mixed posture `{claude: none, pi: real}`, previously inexpressible under the all-or-nothing scalar. Per-tool resume labels (`rc.auth.credential-mounts.{claude,pi}`) carry a legacy derivation ladder, so upgrading rc never bricks a running cage; a posture flip refuses loud **naming the tool**, and the symlink-follow fingerprint stays byte-identical when `effective(pi)` equals the prior global (no spurious refusals on upgrade). Unknown keys under `auth.per_tool.` abort loud at config load — fail-closed, because a typo'd suppression key must never silently mount real credentials. Live-proven with a mixed cage: claude credential files absent, pi `auth.json` present.
- **`auth.placeholder_env_file` — the placeholder-token pointer persists in config** (rip-cage-b9to). With non-possession as a global default, every cage create needed a retyped `rc up --env-file` for the placeholder `CLAUDE_CODE_OAUTH_TOKEN`; forgetting it yielded a silently unauthed claude ("Not logged in"). The new key (scalar, null default) persists the pointer, resolved create-only by a phase-aware resolver mirroring the mediator one: the CLI flag wins with an ignore-log, a missing pointer file is fatal at create naming the key, and — unlike the mediator pointer, whose secret rides a root-scoped exec channel — the secret-path denylist applies, because this file lands agent-readable in the container (an operator pointing it at `~/.aws/credentials` is refused like the CLI path refuses it). Never runs on resume/dry-run; non-adopters see zero new output.
- **`rc doctor`: dead-handle detection for single-file bind mounts** (rip-cage-uben). A host writer replacing a single-file mount source via atomic temp+rename — the standard safe-rewrite pattern — severs the bind mount's inode: the in-cage path goes ENOENT while `docker inspect` still lists the mount. Observed live as in-cage claude "Not logged in" 30 seconds after cage start, when a host Claude Code session rewrote `~/.claude/.credentials.json`. Doctor now runs a generic probe over **all** single-file bind mounts, destination-first (a healthy in-cage destination is never flagged regardless of host-source visibility — avoiding the ssh-agent-socket cry-wolf a source-first check has on macOS/OrbStack); a dead destination is classified by source state (regular file → atomic-rename FAIL with a re-bind hint; missing → "deleted, not renamed" WARN; non-regular → plain WARN). Deliberate non-fix recorded: `.credentials.json` is *not* snapshotted (unlike `.claude.json`) — credentials expire, so a snapshot trades a detectable accident for guaranteed staleness, and the live mount is what lets `rc auth refresh` propagate; non-possession retires this mount class entirely. The probe caught a real severed mount on its first live run.
- **`rc doctor`: cage-runnability probes** (rip-cage-2cks). Three per-cage checks (text + JSON): a fresh exec's cwd is `/workspace` (guards the rip-cage-0rng agent-cwd regression); `bd status` + `git status` resolve cleanly from `/workspace`, with a bd schema error a hard FAIL (the honest rip-cage-aq70 symptom — fires exactly when a baked bd cannot read the store it's handed); host-vs-cage bd version skew is WARN-only (skew alone is not a failure — the parse invariant belongs to the resolution probe). No optional tool named, no multiplexer/pane probing ([ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12); `rc test` gains the in-cage-observable cells (cwd + bd/git resolution). Verified against real broken fixtures: a workdir-broken cage fails the cwd probe, a stale-bd image fails resolution and only WARNs on version.

### Changed

- **Non-possession claude cages now carry `~/.claude.json`, read-only** (rip-cage-t7cu). Under `effective(claude)=none`, `~/.claude.json` was previously suppressed as part of the credential gate alongside `~/.claude/.credentials.json`. It holds no token-shaped fields — account metadata (org/tier/email), MCP server config, and workspace-trust/onboarding state, not a secret — so it was swept into the gate by association, not because it's a credential. It now mounts (skip-if-missing, same as `real`) but read-only (`:ro`): an RW bind would give a prompt-injected in-cage agent a write primitive into the host's real-credential claude config (poisoned `mcpServers`/hooks executed later by host claude with real creds); under possession RW is no escalation, so the possession path is unchanged (bit-for-bit). The actual gated-as-a-unit credential set under `none` is now `~/.claude/.credentials.json` + keychain extraction only. **Existing non-possession cages are unaffected until recreated** — no resume guard fires (the `rc.auth.credential-mounts.claude=none` label is unchanged), so a running/stopped `none` cage simply lacks the new mount until `rc destroy <name> && rc up`. See [docs/reference/config.md](docs/reference/config.md) and [ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md) D2 (named residual: rip-cage's fixed `/workspace` mount path collapses Claude Code's per-project workspace-trust flag across cages sharing the same host file).
- **`configure-cage` rewritten substrate-thick; walk-away composition recipe added** (rip-cage-q7i5, with non-possession knowledge folds rip-cage-s5d0). The skill's spine is now "read `dist/default-tools.yaml` as the reference base — it is literally what the published image builds from — and propose deltas by judgment": the six-dimension one-question-at-a-time interview, the MANDATORY-to-surface gates, and the numbered composition procedure are gone. What they carried lands as knowledge and judgment cues instead — the footguns (DCG OPEN residual, pi headless throttle), reconcile-awareness ("you are probably not starting from zero"), the 3-layer config model, and the non-possession/mediator posture (possession's single-file-mount inode fragility vs a static injected token, `platform.claude.com` needed in both egress layers, posture flips are create-time-only). New `examples/compose-walk-away-cage.md` delta recipe (dist + herdr + herdr-pi; mediator situational per [ADR-026](docs/decisions/ADR-026-containment-mediation-identity.md); pi provider pin), indexed in `examples/README.md`. No pre-composed reference manifests — copies of generated blobs drift — and `dist/default-tools.yaml` / the default manifest are untouched ([ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12).

### Fixed

- **Non-possession cages no longer cry wolf about missing auth** (rip-cage-df1c, rip-cage-73bz). Both the init-time boot warning and `rc test`'s auth-present check predated the env-token path, so a cage running on a placeholder `CLAUDE_CODE_OAUTH_TOKEN` booted with "WARNING: No auth found" and false-FAILed `rc test` despite live claude turns working. Both now also accept a non-empty `CLAUDE_CODE_OAUTH_TOKEN` (additive — existing branches untouched, and negative controls prove neither check was weakened: emptying the token variable still warns/fails).
- **Interactive claude no longer hits the onboarding/login wall under non-possession** (rip-cage-vwka). With no `~/.claude.json` mounted, the wrapper seed chain came up empty — a no-seed WARNING on every launch and, worse, interactive claude stuck at the full theme+login onboarding (login is browser-OAuth, unusable in-cage and unnecessary: the env token auths the API path). Init now synthesizes a minimal `{"hasCompletedOnboarding": true, "theme": "dark"}` seed when the live mount is absent and no seed exists; the possession snapshot path is untouched and an existing seed is never clobbered. Minimal key set live-proven (trust dialog → prompt → model round-trip, no login).
- **`rc up --dry-run` runs the full resume-guard set** (rip-cage-3y9g). Dry-run's stopped branch ran only 4 of the 10 resume guards and the running branch none of its 5, so config/label drift a real `rc up` refuses loudly (config_mode, credential_mounts, mediator-CA env, ssh posture, symlink fingerprint) was invisible to dry-run planners. The missing guards are wired into both dry-run sub-branches mirroring the real branches' order; every wired guard is read-only (label read + effective-config compare), so resume-side mutation stays excluded from dry-run.
- **`rc up` refuses blind-resume of a container pinned to a stale image** (rip-cage-jnvb). After `rc build`, a stopped container stays pinned to the *old* image ID; fast-resume then ran the *new* image's resume logic (mediator init docker-execs a baked-in file) against the old container filesystem — a raw OCI stat crash and self-stop. A single-sourced image-drift comparator now aborts loud **before** `docker start` on the stopped/created branch (structured error in `--output json`; the remedy names destroy+re-up and the `RC_IMAGE` nuance, no unconsulted override), warns-only on the running branch, applies the same hard stop under `--dry-run` would_resume, aborts loud when the current image is missing (fail-open there would re-open the crash), and `rc build` warns about containers left pinned to the replaced image. Named residual (filed rip-cage-h2hl): an rc script newer than the image with matching image IDs can still crash resume-side execs.
- **Mediator CA trust reaches Node/python in every entry path** (rip-cage-yid0). When a mediator is composed, `rc up` now passes `NODE_EXTRA_CA_CERTS` (rc-owned mediator CA path) and `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` (system bundle) as `docker run -e` vars, so every docker-exec descendant — attach shells, `rc exec` headless dispatch, multiplexer panes — inherits CA trust. The prior firewall-env sourcing only covered init-spawned processes, and `rc exec` interposes no shell, so no shell-startup-file mechanism could work (pi failed `SELF_SIGNED_CERT_IN_CHAIN`). Also: a `rc.mediator-ca-env` create-time label with a loud resume guard refusing stale pre-fix cages (sibling to the egress/config_mode/credential_mounts guards), and the init CA-wait timeout now fails closed via the mediator hard-failure path.
- **Baked beads pin bumped v1.0.2 → v1.0.5** (rip-cage-aq70). Host `bd` at 1.0.5 (Homebrew) against a cage baking v1.0.2 from source made in-cage `bd status` fail with a `depends_on_id` schema error (a 1.0.5-schema query against the 1.0.2 embeddeddolt store). The Go builder stage moves golang 1.25 → 1.26 alongside (bd v1.0.5 requires Go ≥ 1.26.2); `rc doctor`'s new runnability probe (see Added) is the regression guard.
- **iron-proxy recipe: `platform.claude.com` is required, not deliberately omitted** (rip-cage-e770, docs). Interactive Claude Code ≥ 2.1.19x hard-fails startup (`ERR_SOCKET_CLOSED`) when the host is unreachable, and it is on Anthropic's documented required-domains list; the old "deliberately omit the token-refresh host" defense-in-depth protected nothing under non-possession anyway — the agent holds only the placeholder. The example `allowed_hosts` and iron-proxy domains guidance are flipped, with a dated supersession note on the original history doc.
- **Test hygiene** — the pi-substrate-mounts fixture created absolute-valued symlinks (despite its own "relative symlinks" comment) whose targets landed under `/tmp` on Linux CI (`TMPDIR` unset), tripping rc's symlink-follow reserved-path guard and failing 8 checks that macOS dodged via `/private/var`; the fixture now creates genuinely relative symlinks like real dotpi ships, so the test finally exercises the intended pi-substrate resolution path — rc itself was correct and untouched (rip-cage-7hrw).

## [0.11.1] - 2026-07-03

### Fixed

- **Caged agents start in the repo (`/workspace`), not `/home/agent`** (rip-cage-0rng) — nothing rooted the agent's cwd at the workspace, so every entry mode landed in `/home/agent` (the Docker `WORKDIR` default), where `bd`'s upward `.beads/` search fails, `git` isn't a repo, and relative paths break — forcing a per-session `cd /workspace` that broke AFK / drover use. Fixed at two layers, each at its correct home: `rc` adds `--workdir /workspace` to the `docker run` args (covers `rc attach` / `rc exec`; mux-agnostic per [ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12), and the herdr `start` hook exports `HERDR_STARTUP_CWD=/workspace` before `herdr server`. herdr roots its default workspace from that env var — not its process cwd or the container `WORKDIR`, falling back to `$HOME` when unset, which is why `--workdir` alone didn't reach herdr panes; `new_cwd=follow` then carries it to subsequent panes.

## [0.11.0] - 2026-07-03

### Changed

- **DCG's default extension posture flipped from LOCKED to OPEN** (security-default behavior change; epic rip-cage-p35a; [ADR-027](docs/decisions/ADR-027-agent-substrate-projection.md) D1/D4 — FIRM, human-confirmed). The DCG recipe's default no longer contributes `--no-extensions` to pi's launch. A default cage now lets **pi auto-discover and load its own extensions** (`~/.pi/agent/extensions/`, `/workspace/.pi/extensions/`) — restoring pi's extension-write autonomy and making an ordinarily-installed herdr integration "just work" — while the DCG guard still loads first (`-e /etc/rip-cage/pi/dcg-gate.ts`) and still **DENIES destructive commands**. The honest tradeoff: this **reopens "vector-b"** — a prompt-injected pi could write a guard-bypassing extension into an auto-discovery path that then auto-loads — as a **knowingly-accepted residual** backstopped by containment (the guard itself stays unreplaceable on its root-owned path; the container / egress / filesystem floor is untouched, so blast radius stays bounded). The tighter **LOCKED** posture (`--no-extensions`) is now a **documented opt-in** for operators who want vector-b closed. (rip-cage-p35a.1)
- **pi recipe owns its full lifecycle; base init names no tool** (rip-cage-p35a.3; [ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D7/D12). pi's extension-directory creation moved out of the shared `init-rip-cage.sh` into pi's own recipe **`init` boot-hook**, and a `--model <provider/model>` pin mechanism was added to the pi recipe. Base infrastructure no longer carries pi-specific logic.

### Added

- **`TOOL` archetype `init` boot-hook seam** (rip-cage-p35a.2; [ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D7). Plain `TOOL` recipes can now contribute a cage-boot hook (fires at attach, agent context), making the three-phase lifecycle (build / boot / launch) uniform across archetypes — a recipe owns its full lifecycle and base infra names no tool.
- **`configure-cage` skill** (rip-cage-p35a.5) — an agent-run interview that composes a cage manifest (`~/.config/rip-cage/tools.yaml`) **by judgment**, one question at a time: which tools, the DCG guard and its **open-vs-locked posture**, multiplexer, egress posture, and a **pi provider/model pin**. It surfaces the open-vs-locked tradeoff at setup so the OPEN default is a conscious, agent-relayed choice — the naive-user mitigation the open default's safety argument rests on — and writes a reviewable manifest the operator inspects before `rc build`. No generator/installer/merger: the agent reads the `examples/` recipes and hand-writes the entries ([ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12).
- **pi provider/model pin surfaced by `configure-cage`** (rip-cage-tl6q) — pinning a **static-key provider** (e.g. `openai-codex/gpt-5.5`) keeps headless / walk-away pi runs from stalling on the Anthropic third-party subscription throttle (a fresh headless pi that defaults to Claude-subscription resolution now gets a 400).

### Fixed

- **`herdr integration install pi` succeeds in a composed herdr+pi cage** (rip-cage-fwp3) — pi's agent-owned `extensions/` directory is now created at cage boot (gated on pi being present), so herdr's pi integration installs and `herdr integration status` reports pi installed.
- **Release / test hygiene** — the mount-seam integration test's arbitrary-`TOOL` fixture now mounts under the agent-writable zone to match the rc09 dest allowlist (rip-cage-p35a.6); the `RC_E2E_DCGHP_ONLY` gate no longer clobbers the operator's daily-driver `rip-cage:latest` (threaded an `RC_IMAGE` override, rip-cage-2mpn).

## [0.10.0] - 2026-06-30

### Changed

- **pi launch composition is fully manifest-declared** (epic rip-cage-l72i; [ADR-027](docs/decisions/ADR-027-agent-substrate-projection.md) D4, [ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12). pi's launch wrapper no longer hardcodes `--no-extensions -e <dcg-gate>` plus a single `SUBAGENT_EXT` slot. A generic `launch_args` list field on `TOOL` fragments is concatenated by `rc build` in fragment order (guard-first) and baked into a generic pi shim — `rc` names no tool and the wrapper hardcodes no path. The DCG guard, the sub-agent extension, and herdr's pi extension are now **identical manifest contributions**; adding an extension is a recipe declaration with **zero `rc` edits**. Because `rc build` is host-side, the "agent drops a hostile extension into a scanned dir" prompt-injection vector is closed **by construction** — no runtime code-inspection validator is needed ([ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md) D4). The DCG guard stays loaded first and tamper-proof (root-owned file **and** parent dir on its own `/etc/rip-cage/pi` load path). (rip-cage-l72i.1)

### Added

- **`examples/herdr-pi/` recipe** (rip-cage-l72i.4) — composes herdr's pi integration extension into a cage: runs `herdr integration install pi` (the public CLI, [ADR-006](docs/decisions/ADR-006-cli-interface.md) D8), relocates the generated extension to a root-owned load path, and declares its `launch_args` + herdr socket-directory mount. This enables herdr semantic working/idle status for caged pi agents — the gap that the hardcoded `SUBAGENT_EXT` slot used to silently swallow.
- **`examples/pi/subagent-fragment.yaml`** (rip-cage-l72i.3) — a self-contained opt-in recipe that mounts the host sub-agent extension and adds its `-e` launch arg. This is the explicit, composable successor to the retired `SUBAGENT_EXT` wrapper slot.
- **herdr binary pin bumped v0.6.10 → v0.7.0** (rip-cage-1pgp.2) in `examples/herdr/` (per-arch SHA-256, fail-closed).

### Removed

- **`SUBAGENT_EXT` hardcoded slot in the pi wrapper** (rip-cage-l72i.3) — pi sub-agent extension dispatch is now **opt-in** via `examples/pi/subagent-fragment.yaml` rather than a hardcoded wrapper slot. The default cage no longer auto-loads a sub-agent extension; compose the recipe to retain it. `grep -ni subagent rc` is now empty — the special-casing is fully retired from `rc`.

## [0.9.1] - 2026-06-29

### Fixed

- **DNS non-QUERY opcode exfil bypass closed** (rip-cage-d9d3). The DNS resolver forwarded non-QUERY opcodes (UPDATE/STATUS/NOTIFY/etc.) straight to upstream with no exfil-heuristic and no mode awareness — a hole in the DNS chokepoint that also reached a configured `forward_to` specialist uninspected. The opcode branch now mirrors the QUERY path: **block mode refuses (never forwards)**, observe mode logs a `would-block` event then forwards, legacy mode passes through silently, and an unrecognized mode coerces to block (fail-closed). ([ADR-026](docs/decisions/ADR-026-containment-mediation-identity.md) D2/D3, [ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md) D4)
- **symlink-follow broken-chain detection repaired on macOS, fail-loud end-to-end** (rip-cage-l0bu). A truly-broken symlink chain (missing target parent) was silently missed on macOS — `readlink -f` returns a non-empty partial path with exit 1 there (Linux returns empty), so the empty-stdout-only guard fired on Linux but not macOS; and the consumer swallowed the collector's non-zero exit through a process-substitution loop under `set -e`, so the loud abort never reached the caller ([ADR-001](docs/decisions/ADR-001-architecture.md) D1). Both fixed; broken chains now abort loud on both platforms.
- **symlink-follow `scope: parent` validates the actual mount source** (rip-cage-6uz). In `scope: parent` mode the fingerprint and secret-path denylist now check the parent directory that actually mounts, not the leaf target — restoring the "validate exactly what mounts" invariant ([ADR-023](docs/decisions/ADR-023-symlink-follow.md) D7) and closing the leaf-check hole. (The residual that `parent` exposes the whole directory including sensitive-named leaf files is now documented in `docs/reference/config.md`; prefer `scope: file` for directories holding secrets — rip-cage-hs70.)
- **Spurious config "recreate to apply" hint suppressed** (rip-cage-1f59.9) when a field is absent from an older config snapshot but the live value already equals the schema default ([ADR-021](docs/decisions/ADR-021-rip-cage-yaml.md) D5).
- **`rc up` Claude-OAuth warnings reworded to an agent-neutral tone** (rip-cage-5kt) so they read sensibly for pi-only / API-key-only users (still actionable for Claude users; the warning is kept, not suppressed).

### Added

- **tmux recipe: copy-on-select via OSC 52** (rip-cage-q5i) — drag-select + release relays the selection to the host clipboard with no Cmd-C and no `y` keystroke. Opt-in recipe polish (`examples/tmux/`), not core-cage UX.

### Removed

- **VS Code devcontainer usage path removed** (rip-cage-kt25). The `.devcontainer/` path was legacy; `rc up` is the supported entry. (`.devcontainer/` / `.vscode/` remain gitignored.)

## [0.9.0] - 2026-06-25

### Changed

- **Agents, command-guards, and substrate collapse to two composable seams: `TOOL` + per-asset ro/rw mount** (epic rip-cage-wlwc; [ADR-025](docs/decisions/ADR-025-host-adoptable-dcg-policy.md) D2, [ADR-027](docs/decisions/ADR-027-agent-substrate-projection.md) D1/D3, [ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12). There is no longer a bespoke AGENT archetype or an `agents.enabled` switch — an agent (Claude Code, pi) and its command-guard are each just a `TOOL` manifest recipe plus per-asset read-only / read-write mounts. Composing or swapping one is "edit the manifest, `rc build`" with **zero `rc` edits** and no `compose:` directive or auto-wiring (the agent does the wiring per ADR-005 D12). The welded floor is now strictly **containment** (container boundary, egress firewall, fs sandbox, non-root + scoped sudo, secret-path denylist, git-hooks RO weld, ssh known_hosts). (rip-cage-wlwc.2/.3/.9/.12)
- **DCG and the ssh-bypass blocker demoted from baked-in floor to composable recipes** ([ADR-025](docs/decisions/ADR-025-host-adoptable-dcg-policy.md) D2, [ADR-026](docs/decisions/ADR-026-containment-mediation-identity.md) D2). dcg is now a from-source `TOOL` recipe (`examples/dcg/`, cargo-install at a pinned tag) and the ssh-bypass hook a composable recipe (`examples/ssh-bypass/`); **both are un-baked from the base image**, and their wiring rides a root-owned, separate load path — ownership (not mere presence) is what makes the guard wiring un-tamperable. The default published image still composes **CC + pi + dcg + ssh-bypass** via the default manifest; blessing happens at the distribution layer, not in `rc` code or the seam. (rip-cage-wlwc.10/.11/.12)
- **Guard floor-lock unified; the per-agent root-own + sudo "olen" machinery retired** ([ADR-027](docs/decisions/ADR-027-agent-substrate-projection.md) D1/D3, [ADR-002](docs/decisions/ADR-002-rip-cage-containers.md) D5). Each agent's guard wiring is delivered as a root-owned asset on its own cage-owned load path — the Claude Code DCG guard via root-owned managed-settings, the pi guard relocated to `/etc/rip-cage/pi` (root-owned file **and** parent dir) — replacing the previous per-agent ownership+sudo snowflake. pi's workspace-path extension auto-discovery bypass is closed; the `/usr/bin/pi` direct-binary launch remains a documented best-effort residual (containment holds underneath). (rip-cage-wlwc.4 / rip-cage-sn1h / rip-cage-r9n4)
- **`rc test` and the in-cage safety suite name zero specific guards** (rip-cage-m8zc, rip-cage-wiwa; [ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12/D13). Drop-detection rides a generic per-tool `required` / `assert_loaded` manifest declaration (a baked, root-owned assert file), and each recipe carries its own behavioral smoke test (`examples/<recipe>/smoke.sh`) run by a generic name-free runner — so adding a guard recipe needs no `rc` edits.
- **Egress reshaped from a TLS-MITM proxy into a pure SNI destination router** (epic rip-cage-ta1o; [ADR-026](docs/decisions/ADR-026-containment-mediation-identity.md), [ADR-012](docs/decisions/ADR-012-egress-firewall.md) D2/D4/D5/D6). HTTP/HTTPS egress no longer terminates TLS or installs a rip-cage CA — the router reads the SNI in the clear, allow/denies the **destination host**, and splices the still-sealed bytes through. The agent now sees the **real upstream certificate**; no `NODE_EXTRA_CA_CERTS` / rip-cage CA is installed. Force-through (iptables capture + startup on-path selftest), destination allow/deny, the IOC floor, and the DNS sidecar all carry over. Content-layer enforcement (method/path, credential injection) is delegated to a **composed external mediator** — see the new `docs/reference/composition-seam.md` + `examples/compose-rc-with-clawpatrol.md`. (rip-cage-ta1o.1/.3)
- **DNS resolver gains a `network.dns.forward_to` forward-to-specialist seam** — clean queries (those the built-in exfil heuristic passes) can forward to a configurable upstream resolver (NextDNS / Umbrella / dnsdist / Zeek / a local forwarder) instead of the default `8.8.8.8`. Tool-agnostic (a configurable address, not a blessed product). The built-in heuristic and port-53 force-through are unchanged. (rip-cage-ta1o.2; [ADR-012](docs/decisions/ADR-012-egress-firewall.md) D9)

### Removed

- **AGENT archetype and the `agents.enabled` config key** (BREAKING) — removed in epic rip-cage-wlwc. The AGENT archetype, the `agents.enabled` schema row, the `rc.agents` image label, the `/etc/rip-cage/agents/<name>/` bake, and the AGENT-only guard validators are all gone; an `agents:` / `agents.enabled` block in your config is no longer recognized. Agents are now expressed as `TOOL` recipes + ro/rw mounts (see Changed above). (rip-cage-wlwc.9)
- **DCG and ssh-bypass no longer baked into the base image** (BREAKING) — a from-source or custom `rc build` that does not compose the dcg / ssh-bypass recipes produces a cage **without** those command-guards. The default published `rip-cage:latest` is unaffected (it composes both via the default manifest); custom manifests must add the `examples/dcg/` and `examples/ssh-bypass/` entries to retain them. The containment floor is unchanged. (rip-cage-wlwc.10/.11)
- **`network.writable_hosts` method-axis write-gate** — removed with the TLS-MITM stack it depended on (a pure SNI router can't see HTTP method/path). A `writable_hosts:` block in `.rip-cage.yaml` is now silently ignored. Method-asymmetry was leaky theater (GET still leaks via DNS / URL-query / allowlisted-API abuse) and is superseded by destination-only routing; per-request method/path policy returns when an external mediator is composed. (rip-cage-ta1o.1; [ADR-012](docs/decisions/ADR-012-egress-firewall.md) D2)

## [0.8.0] - 2026-06-15

### Changed

- **In-cage multiplexer is now a manifest-declared composable provider** — `rc` no longer hardcodes the multiplexer set. Adding a multiplexer (tmux, herdr, zellij, …) is a manifest entry with **zero edits to `rc` / `init-rip-cage.sh`**: `rc build` bakes each declared provider's hooks into the image (`/etc/rip-cage/multiplexers/<name>/<hook>`), the `session.multiplexer` allowed-set is derived dynamically from the baked registry (surfaced as the `rc.multiplexers` image label) rather than a hardcoded enum, and `rc` dispatches by name through that registry. A fixture multiplexer named nowhere in the source drives build → validate → start → attach end-to-end, and `grep 'tmux\|herdr' rc init-rip-cage.sh` is empty. The provider hooks are bounded at build by the fail-closed validator (they cannot weaken the welded CONTAINMENT floor). Realizes ADR-005 D12 (rip-cage is a composable seam, not a bundler); see ADR-005 D7 (MULTIPLEXER archetype) + D9 (realized mechanism). (epic rip-cage-61al)

### Removed

- **`rc agent` and `rc sessions`** — both commands were removed in epic rip-cage-1f59 (2026-06-13). They are no longer in the command dispatch, `--help`, schema, or completions. The in-cage multiplexer (`session.multiplexer: none | <any manifest-declared provider>`, ADR-021 D6) is the successor for spawning, listing, and supervising agent sessions inside a cage. `rc exec` (`rc exec <cage> -- <cmd>`) is the rip-cage box-entry replacement for running an arbitrary command inside a running cage (ADR-006 D7 re-decision). See ADR-006 D7 for the full rationale.

- **tmux unbaked from the default cage image** (BREAKING) — `tmux` is no longer installed in the Dockerfile's system-package stage, and `tmux.conf` is no longer COPY'd into the image. **Users relying on `session.multiplexer: tmux` with a default `rip-cage:latest` build will find `tmux` absent after `rc build`.** Migration: add a tmux entry to your manifest (`~/.config/rip-cage/tools.yaml`) using the example at `examples/tmux/`, then run `rc build` to bake tmux into your cage image. The `examples/tmux/tmux.conf` is the exact config previously shipped in the image. The init missing-multiplexer path (B1a/B1b) will fail loud and point at this migration. (ADR-005 D12; rip-cage-61al.5)

- **herdr removed from the default manifest** (BREAKING) — herdr is no longer seeded in `_manifest_default_yaml`. **Users relying on the default `rc build` to install herdr will find it absent after the next seed (first-run or explicit manifest reset).** Users with an existing `~/.config/rip-cage/tools.yaml` that already contains a herdr entry are unaffected. Migration: add the herdr entry to your manifest using the example at `examples/herdr/`, then run `rc build`. The default cage is now core-only: `beads`, `dolt`, `gh`, `claude`, `pi`, `dcg` — all bundled with no extra download steps. (ADR-005 D12; rip-cage-61al.5)

## [0.7.0] - 2026-06-12

This release rolls up everything user-facing since 0.5.3 — including the work tagged as 0.6.0, which never got its own changelog entry. Two big themes: **agent-first tool composability** (the cage now bakes in host-defined tools through a declarative, fail-closed manifest instead of hardcoded Dockerfile stages) and **concurrency** (`rc up` cages now run multiple Claude and multi-agent sessions side by side). The base OS also moves to Debian 13 trixie.

### Added

- **Declarative host-only tool manifest** — `rc build` now bakes host-defined tools into the cage from a manifest under `~/.config/rip-cage`, instead of every tool being a hand-wired Dockerfile stage (ADR-005 D7–D11, epic rip-cage-4c5 + rip-cage-buuo). Three tool archetypes are supported: plain `TOOL` binaries, `SHELL-INTEGRATION` tools that bake an eval line into `.zshrc` at build time, and `IN-CAGE-DAEMON` tools with full lifecycle plumbing. Each tool carries a per-tool egress declaration that the firewall floor enforces, and a `mounts[]` field that mounts host paths (with `~` / `$HOME` expansion) into the cage at `rc up`. The manifest is host-only by design — a host-side agent under human supervision can draft entries, but the in-cage agent can never reach or modify it (ADR-024, ADR-005 D7).
- **From-source tool builds** — a manifest entry can declare a `build_source` (builder image + host-side build script + output path) and rip-cage generates one isolated builder stage that COPYs out only the artifact, keeping the build toolchain out of the runtime image. Arch-adaptive (no hardcoded `--platform`), so it builds native-arch on Apple Silicon and amd64 alike (rip-cage-buuo.2).
- **Fail-closed manifest validator** — every build path that can produce a from-source tool (both `rc build` and the `rc up` auto-build path) now runs build-isolation assertions (no bind/VOLUME/ssh/secret leakage into the build) before the build and a binary-root-owned check after it, untagging any tainted image. A non-compliant tool is rejected loud, not silently shipped (ADR-005 D11 FIRM; rip-cage-buuo.1/.3/.6).
- **Tool-authoring skill** — a repo-shipped skill (`rip-cage-tool-manifest-author`) lets a host-side agent, pointed at a target tool, draft a manifest entry (and build script for the from-source case) as human-reviewable files. The human approves before `rc build`; the validator enforces the safety contract (ADR-005 D11 mechanism 3; rip-cage-buuo.4).
- **`am` / agent_mail as the worked-example in-cage daemon** — agent_mail ships as the real `IN-CAGE-DAEMON` worked example (docs + fixture, not a seeded default). Bash-only agents (pi) reach it through its own `am` CLI over their bash tool (`am mail send` / `am mail inbox` / `am mail read`, `am agents register`), and MCP-capable agents (Claude) reach it via an `mcp_fragment` — canonicalized as ADR-019 D9: in-cage daemons are reached by CLI-over-bash for bash-only agents, never via an MCP bridge (rip-cage-gucm, rip-cage-swv).
- **`cm` (cass-memory) as an opt-in manifest tool** — the cass-memory CLI is available in cages that opt in via a from-source manifest entry. The host L2A memory store mounts read-write into the cage, `cm context` / `cm playbook add` operations round-trip back to the host store, and the in-cage binary makes zero external network connections. `cm` started this release as a hardcoded Dockerfile stage (rip-cage-l0u2) and is now re-expressed purely through the generic manifest mechanism — the default cage no longer bakes it in (ADR-005 D2/D6).
- **Per-session Claude config isolation** — `rc up` cages now support multiple concurrent `claude` sessions. A wrapper resolves `CLAUDE_CONFIG_DIR` per tmux session and seeds each session its own config dir (shared inputs symlinked, `.claude.json` seeded from a stable container-local snapshot taken at init), fixing the non-atomic `.claude.json` write that previously dropped a second concurrent agent into a "configuration file not found" loop. Interactive sessions also get their git author identity from the session handle (rip-cage-p1p, ADR-006 D7).
- **`rc agent` multi-agent lever** — `rc agent <cage> --name=<handle> -- <command>` spawns a named tmux session running a command verbatim inside a running cage (Tier 1a parallel agents in one cage). Argv is passed through intact, a duplicate `--name` is refused without clobbering the existing session, and existing `rc sessions` / `--kill` / `rc attach` manage the spawned agents (no new kill surface). Combined with the per-session isolation above, `rc agent --name -- claude` gets config isolation for free (rip-cage-tlm, ADR-006 D7).
- **Egress firewall startup self-test** — the cage now verifies the egress firewall is *actually enforcing* (not merely that rules are present) and refuses to start on a confident fail-open. It probes a guaranteed-unroutable address through a locally-generated marker, so a kernel or backend change that silently no-ops the traffic REDIRECT is caught at startup instead of leaving the cage open with every status light green. Enforced in `block`/`legacy` modes; ambiguous results warn-and-proceed so it never false-alarms (rip-cage-fft, ADR-012 D11).
- **Getting Started guide** — `docs/guides/getting-started.md`: a throwaway-first first-run walkthrough covering what `rc up` does, the cage denying destructive commands, and the daily-loop command table. Linked from the README quick start.
- **ADR-024 D6 — MCP posture**: CLI-over-bash is the blessed in-cage integration path; third-party / user-added MCP servers remain allowed-but-unsupported (in-cage MCP egress is already caught by the firewall, so the only named residual is host-placed MCP). No MCP trust machinery is built (rip-cage-b4c).
- **`rc agent` / `rc sessions` shell completion** — both commands now complete running-container names in bash and zsh.

### Changed

- **Base OS bumped Debian 12 bookworm → Debian 13 trixie** (glibc 2.41). Both the Go (beads) and Rust (DCG) builder stages move to trixie too, so they compile against the same ICU 76 / glibc the runtime ships — removing a four-major-version ICU ABI shim (ADR-002 D2a).
- **Default cage no longer bakes in `cm`** — the cass-memory builder stage and runtime COPY are gone; a no-manifest cage is the previous default image minus cm. cm is now opt-in via the manifest (see Added).

### Fixed

- **Egress firewall stays enforcing on trixie** — Debian 13 defaults `iptables` to the nft backend, which would silently no-op the firewall's nat REDIRECT rules and fail *open*. rip-cage now pins the legacy backend at build time (`update-alternatives --set iptables iptables-legacy`), keeping the firewall armed; the startup self-test above is the backstop if this pin ever fails (ADR-012 D10).

### Documentation

- ADR-005 evolved through D7–D11: host-only manifest, generic from-source builder stage, fail-closed validator (with the FIRM clause that the validator must be wired into *every* build path, not just `rc build`), and the agent-first authoring skill. ADR-019 D9 (bash-only agents reach in-cage daemons via CLI over bash). ADR-024 D6 (MCP posture). ADR-006 D7 (Tier 1a session-granularity multi-agent levers + presence-only status). ADR-002 D2a (trixie forward base) and ADR-012 D10/D11 (iptables-legacy pin + effect-based egress self-test).
- Reference docs added/updated for the tool manifest, agent-mail daemon (`am` CLI surface + `serve-http` mode), and `cm` (opt-in-via-manifest mount mechanics).

## [0.5.3] - 2026-06-04

### Added

- **pi cold-start verified + fixed**: `rc up` seeds `~/.pi/agent/auth.json` with `{}` when absent so a first-run in-cage `pi /login` persists across rebuilds without re-login (rip-cage-wo9). Persistence verified against pi source (`auth.json` is written in place via `writeFileSync`, so a single-file bind mount round-trips to the host) and unit-tested in `tests/test-pi-cold-start-seed.sh` (cold / empty-dir / idempotent / dangling-symlink cases). The auth-present path was previously confirmed on real Apple Silicon hardware (v0.5.0).

### Fixed

- **`rc test` portability**: the DCG additive-rule safety check baked its sentinel fixture into the image instead of reading it from `/workspace`, so `rc test <container>` no longer spuriously fails in any cage that isn't the rip-cage repo's own (rip-cage-16t).
- **e2e auth-warn coverage**: the auth-warn checks asserted against empty `docker logs` (init output goes to `rc up` stdout), so the "no warning" branches passed trivially; they now assert on real captured init output, and a deterministic no-auth case exercises the "WARNING present" branch (rip-cage-igm, rip-cage-f4i).

### Documentation

- Documented the hook-layer enforceability limitation in ADR-002 D5: PreToolUse hook *registration* lives in agent-writable `~/.claude/settings.json`, so the command-hook layer is loaded-by-default, not tamper-proof; the network (egress) and filesystem/container layers are independent of it (rip-cage-2uv). Doc-hygiene: removed dead ADR-001 links and the stale "push-less defaults" claim (rip-cage-pr0).

## [0.5.2] - 2026-06-03

### Removed

- **Compound-command blocker** (`hooks/block-compound-commands.sh`) removed from the in-container safety stack (both Claude Code `settings.json` and pi `dcg-gate.ts`). The blocker's only real protection was permission-allowlist bypass (Claude Code prefix-matches only the first command in a chain), which is moot under `bypassPermissions` — the cage default since rip-cage 0.4.x. The destructive-command class is fully covered by DCG regardless of chaining: DCG rules are unanchored whole-command regexes, verified live against `echo hi && rm -rf ~`, `ls; rm -rf /important`, and `git status && git reset --hard HEAD~5` — all DENY. `block-ssh-bypass.sh` is likewise chaining-robust. Regression tests 11f/11g/11h in `test-safety-stack.sh` lock in DCG and ssh-bypass chaining-robustness. See ADR-002 D5.

## [0.5.1] - 2026-06-03

Smoother first run. A fresh `brew install` no longer needs a separate setup step before the first cage starts.

### Changed

- First `rc up` now **auto-seeds** the default secret-path denylist config instead of failing loud and directing the user to run `rc install`. Previously a new machine hit a chain of setup stops — and the sharp one was self-inflicted: rc told you to run `rc install`, which is exactly what made the next `rc up` fail on a missing `yq`. The seeded default only ever *adds* blocking (never widens capability), so it satisfies the "a valid config must exist before the mount matcher runs" invariant rather than bypassing it; seeding runs *before* config validation so the `yq` check still covers it (ADR-023 D6 evolved). `rc install` / `rc config init` remain for re-seeding and customization.

### Added

- `yq` is now a declared Homebrew dependency. It is required to parse rip-cage config, but `brew install rip-cage` previously didn't pull it, so the first `rc up` after a config existed failed on a missing parser.
- `rc doctor --host` now reports `yq` presence and global-config presence, surfacing fresh-device prerequisites up front instead of one failed `rc up` at a time.

### Fixed

- The `yq`-missing error no longer misleadingly references `.rip-cage.yaml`; it names `yq` as a rip-cage config dependency with install instructions.

## [0.5.0] - 2026-06-02

Security-layer expansion. The destructive-command guard becomes host-extensible without weakening its baked-in floor, the pi-coding-agent reaches guard parity with Claude Code, and the pi credential mount tightens to a container-local layout.

### Added

- **Host-adoptable DCG policy** — a project's `.rip-cage.yaml` can now add destructive-command rules above the baked-in guard floor via `dcg.*` fields. The additive layer is read-only and floor-uncrossable: host config can only tighten the guard, never disable or downgrade a baked rule (ADR-025). The cage routes through a CWD-anchoring `dcg-guard` wrapper that neutralizes the agent-writable `/workspace/.dcg.toml` self-disable hole.
- **pi-coding-agent DCG + compound-command parity** — pi cages now block the same destructive commands (`rm -rf`, `git reset --hard`, force-push, …) and chained commands (`&&`, `;`, `||`) that Claude Code cages do, via an image-baked `dcg-gate.ts` extension auto-loaded from a cage-owned path (ADR-019 D8).

### Changed

- **pi config is now container-local** — the pi agent directory lives at `/home/agent/.pi/agent` inside the cage; only `auth.json` bind-mounts (read-write) from the host, replacing the whole-directory mount (ADR-019 D1).

### Security

- Secret-path mount denylist now also covers the symlink-follow mount surface (its 5th surface; ADR-023).
- `dcg.custom_rule_paths` entries are sanitized against `../` path traversal before use.

### Fixed

- CI now reports every failing test instead of aborting at the first, and runs through a single test driver against a pinned `shellcheck` image so local lint == CI lint by construction (no more divergence-burned tags).

## [0.4.2] - 2026-05-28

### Fixed

- `rc` is now clean under the release CI's shellcheck (0.9.0). v0.4.2 is the first release of the prompt-injection security upgrade that ships a pre-built multi-arch GHCR image. v0.4.0 and v0.4.1 install identically via Homebrew but fall back to a local image build on first `rc up` (their release CI lint failed, so no image was published — SC2116 in v0.4.0, then SC2015 in v0.4.1 surfaced by the older CI shellcheck).

## [0.4.1] - 2026-05-28

### Fixed

- Removed a useless `echo` subshell in the `rc allowlist promote` path (`shellcheck` SC2116).

## [0.4.0] - 2026-05-28

Prompt-injection security upgrade. The egress layer flips from a denylist of known-bad hosts to a default-deny host allowlist, DNS becomes a first-class exfil surface, SSH is scoped into the allowlist, and a workspace-trust validator refuses hostile config at cage start. Threat model canonicalized in ADR-024.

### Added

- Default-deny egress: `network.allowed_hosts` whitelist with `observe` / `block` / `legacy` / `off` modes (ADR-012 D1 evolved). A non-allowlisted HTTP(S) host is refused with a structured 6-field stderr body (pattern, target, why, fix_command, config_file, config_path) that the in-cage agent can read and act on.
- `network.writable_hosts` — method-axis write-gating: a host can be read-only (GET/HEAD pass) while POST/PUT/etc. are refused (ADR-012 D6).
- DNS-exfil resolver sidecar: a transparent port-53 REDIRECT routes `dig` / `nslookup` / `ping` / `host` through an in-cage Python resolver that refuses subdomain-encoded exfil shapes (over-long labels or high per-second cardinality) against non-allowlisted apexes. Mode-aware like the HTTP layer (ADR-012 D9).
- SSH scoped into the egress allowlist: TCP-22 to non-allowlisted hosts is refused, closing the git-mirror exfil path (ADR-012 D8 evolved).
- QUIC / HTTP3 blocked (UDP-443 DROP) so traffic can't slip past the inspecting proxy.
- Workspace-trust validator: `rc up` refuses to start when `.claude/settings.json` redirects `ANTHROPIC_BASE_URL` to a non-trusted host, naming the key and value; `--allow-config-override` is the escape hatch (ADR-024).
- Agent-first allowlist CLI: `rc allowlist add` / `remove`, `rc doctor` egress sections, an `rc ls` mode column, and `rc promote --from-observed` to lift observed would-block hosts into the allowlist.
- ADR-024 — prompt-injection threat model (named exfil and on-device-harm vectors).

### Changed

- `rc reload` now bounces the egress proxy and DNS sidecar so allowlist/mode changes reach the running processes (both cache their rules at startup). Previously a host added inside the cage and reloaded stayed blocked until teardown — an autonomy bug this release fixes.
- Build resilience: npm per-request timeout capped at 90 s plus bounded retry loops around the Claude Code and pi installs, so a flaky registry fails in minutes instead of stalling a build for up to ~80.

### Known limitations

- pi cages get container isolation and the egress firewall, but not yet the command-level DCG / compound-blocker enforcement that Claude Code cages get. On-device-harm parity for pi is still in research; see "Pi safety model" in `docs/reference/auth.md`.

## [0.3.0] - 2026-05-22

### Added

- Secret-path denylist: host-side validation refuses mounting secret-heavy paths (e.g. `~/.aws`, `~/.ssh`) by default; `--allow-risky-mount` is the escape hatch (ADR-023). Closes the most common accidental-mount miss without proxy infrastructure.
- `rc install` command for first-time setup.
- Multi-session picker on `rc up <path>` and `rc attach <cage>`: when one or more tmux sessions already exist, a numbered list is shown (most-recently-attached first) with a `[new] new session` option. Enter reattaches the most-recent; no picker on the first `rc up`. `rc up --new` always creates a new auto-named session; `rc up --session NAME` attaches or creates by name; `rc sessions <cage>` lists active sessions (`--json`, `--kill NAME`, `--force`).
- `mounts.symlinks.*` config + host-side symlink resolution.

### Changed

- ADR-006 D1 evolved in place: Tier 1 (multiple containers) renamed Tier 1b; new Tier 1a (parallel tmux sessions in one cage) added. Cascade applied to `docs/2026-03-27-multi-agent-architecture.md` and `docs/ROADMAP.md`.
- `tmux.conf` gains `remain-on-exit on` and `pane-died 'respawn-pane -c /workspace'` as build-time globals (moved from `init-rip-cage.sh` runtime stanzas so picker-spawned sessions benefit).
- pi cage-topology written to cage-owned paths (stopped writing to `/pi-agent/AGENTS.md`).

## [0.2.0] - 2026-05-14

Super-easy install: rip-cage now ships via Homebrew, and first-run pulls a pre-built image from GHCR instead of building locally.

### Added

- Homebrew formula: `brew install jsnyde0/rip-cage/rip-cage` (ADR-008 D8 — single-repo tap pattern)
- `rc up` pulls the pre-built image from `ghcr.io/jsnyde0/rip-cage:<VERSION>` before falling back to local `docker build` (ADR-008 D6). Cuts first-run from 5–10 min to ~30 s.
- `RIP_CAGE_IMAGE_REGISTRY` env var to override the GHCR registry path or opt out of pull entirely (set to empty string for "always build locally").
- `scripts/update-formula-sha.sh` — release-helper that computes the sha256 of the current VERSION tarball and patches `Formula/rip-cage.rb` after a tag push.
- Multi-arch Docker image publish (`linux/amd64,linux/arm64`) — Apple Silicon no longer falls back to Rosetta.
- zsh + bash completions are now installed automatically by the Homebrew formula (from-source users still run `rc setup`).

### Changed

- README install lead is now `brew install jsnyde0/rip-cage/rip-cage`; the git-clone-and-symlink path moves to "From source."
- README quick-start no longer claims "builds the image automatically" — names the GHCR pull-first behavior with local-build fallback.
- CONTRIBUTING.md acknowledges that `rc build` is now the contributor path (end users pull from GHCR).
- ADR-008 D6 (pre-built image on GHCR) marked implemented at v0.2.0.
- ADR-008 D7 (install method) primary install changed from "symlink" to "Homebrew formula"; symlink retained as from-source path.
- ADR-008 Deferred section: "Homebrew formula" and "Multi-platform images" bullets removed (both now shipped).
- ADR-008 D8 (new, FLEXIBLE): documents the single-repo tap shape with full Alternatives table.
- ADR-002 D24 and ADR-011 D1 updated in place to reflect the new install paths and completion bundling.

### Release ceremony notes

- GHCR packages default to **private** on first push. After the v0.2.0 tag triggers the release workflow, set visibility to Public at `https://github.com/users/jsnyde0/packages/container/rip-cage/settings`. Until then, unauthenticated `docker pull` from end users fails silently and falls back to local build.
- The formula's stable `sha256` is updated post-tag via `scripts/update-formula-sha.sh`. Between the tag push and the sha256-update commit, `brew install jsnyde0/rip-cage/rip-cage` against the stable url is briefly broken; `brew install --HEAD jsnyde0/rip-cage/rip-cage` covers that window.
- Between this epic merging to main and the v0.2.0 tag being pushed, `brew install --HEAD` users' first `rc up` will try `docker pull :0.2.0`, get a 404, and fall back to local build. Resolves on tag.

## [0.1.0] - 2026-04-13

First public release of rip-cage — a Docker-based sandbox for running Claude Code
agents safely in full auto mode.

### Added

- `rc` CLI with commands: `build`, `init`, `up`, `ls`, `attach`, `down`, `destroy`, `test`, `schema`
- Multi-stage Dockerfile: Go (beads) → Rust (DCG) → Debian runtime
- Two usage paths: VS Code devcontainer (`rc init`) and headless CLI (`rc up`)
- Bind-mount workspace: file changes sync instantly, no git push needed
- Safety stack with two layers:
  - DCG (Rust binary) — blocks destructive shell commands
  - Compound command blocker (Perl) — denies `&&`, `;`, `||` chains to prevent allowlist bypass
- `settings.json` with auto mode, allowlisted safe commands, and `PreToolUse` hooks
- 32-check safety stack smoke test (`rc test`)
- OAuth credential extraction from macOS Keychain for container auth
- Git worktree support with corrected `.git` pointer inside the container
- Read-only `.git/hooks` bind mount to prevent hook tampering (D11)
- Resource limits: CPU, memory, and PID caps via `--cpus`, `--memory`, `--pids-limit`
- `--output json` for machine-readable output on all major commands
- `--dry-run` for `up` and `destroy` to preview actions without executing
- `--version` / `-V` flag to print the current version
- `VERSION` file as single source of truth for the version number
- Beads issue tracker integration (embedded and server Dolt modes)
- `rc.conf` for configuring allowed project roots
- Container user model: non-root `agent` user with restricted sudo paths

[0.7.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.7.0
[0.6.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.6.0
[0.5.3]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.3
[0.5.2]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.2
[0.5.1]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.1
[0.5.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.0
[0.4.2]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.4.2
[0.4.1]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.4.1
[0.4.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.4.0
[0.3.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.3.0
[0.2.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.2.0
[0.1.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.1.0
