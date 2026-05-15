# ADR-021: Layered `.rip-cage.yaml` config — global defaults, per-project overrides

**Status:** Proposed
**Date:** 2026-05-11
**Beads:** `rip-cage-uzp` (this ADR), `rip-cage-o4z` (loader implementation), `rip-cage-b0c` (first user: SSH host+key allowlist)
**Related:** [ADR-001](ADR-001-fail-loud-pattern.md) (fail-loud + narrow exception scope — informs D3), [ADR-014](ADR-014-push-less-cage.md) D2 (non-interactive SSH posture — `Match final` reach limits caveat at line 79 anticipated CLI `-o` bypass), [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (forward-by-default — the capability the SSH allowlist scopes), [ADR-020](ADR-020-ssh-identity-routing.md) (ssh identity routing — coexists; shares `~/.config/rip-cage/` namespace), project [CLAUDE.md](../../CLAUDE.md) philosophy section ("agent autonomy is the product", "layers, not walls", "'It's annoying' is a design signal")

## Context

Rip-cage's posture today is fixed at image-build / `rc up` time, with a few escape hatches via CLI flags (`--no-forward-ssh`, `--no-egress`, `--github-identity`, `--no-ssh-config`) and one rules file (`~/.config/rip-cage/identity-rules`). Per-project differences in trust posture have nowhere to live except the user's shell history.

A concrete trigger: 2026-05-11 the agent in `~/code/personal/kinky-bubbles` needed to SSH to `switch@switch.berlin` for legitimate prod-DB diagnosis. The ssh-agent forward (ADR-017) gave it the key; the mounted `~/.ssh/known_hosts` (ADR-020 D1) gave it the host pin. The agent worked around ADR-014 D2's `known_hosts` rewrite trivially with `-o UserKnownHostsFile=...`. **This bypass is not a discovery** — ADR-014 D2's caveat at line 79 explicitly documents that `Match final Host *` does not defeat (a) explicit CLI `-o` flags, nor (b) per-Host user-config values. ADR-014 D2 was scoped honestly to the default container; the bypass is the `-o` reach limit that ADR-014 D2 already named.

What the trigger does expose is a different gap: **there is nowhere for "this project is allowed to SSH to switch.berlin" to live.** The right answer isn't an env var (per-shell, undiscoverable, not committed) and it isn't a CLI flag (one-shot, easy to forget, no project memory). It's a tracked per-project file that anyone reading the repo can see, that the agent can edit, and that `git log` makes auditable. The downstream consumer (`rip-cage-b0c` SSH host+key allowlist) is what will actually replace ADR-014 D2's `known_hosts` rewrite with capability scoping; per ADR-011 (ADRs reflect target architecture), that bead will edit ADR-014 D2 in place. **This substrate ADR alone does not modify ADR-014.**

The pattern is the same one CLAUDE.md uses: a global file (`~/.claude/CLAUDE.md` / `~/CLAUDE.md`) sets defaults across all projects, and a per-project file (`<project>/CLAUDE.md`) adds project-specific context. Both apply. The agent reads both. The project file is committed.

This ADR introduces the equivalent primitive for cage *posture*: `.rip-cage.yaml`. The first downstream consumer is the SSH host+key allowlist (`rip-cage-b0c`). Other plausible consumers — egress overrides, skill mount opt-outs, resource limits, per-project DCG additions — are out of scope here but shape the schema.

This ADR is the **substrate**. By itself it changes no cage behavior beyond informational output (D3 warnings, D4 inspector command, D5 first-run hint). The loader (`rip-cage-o4z`) implements it; the SSH allowlist (`rip-cage-b0c`) is the proof-of-concept first consumer.

## Decisions

### D1: Two files — `~/.config/rip-cage/config.yaml` (global) + `<project>/.rip-cage.yaml` (project, tracked in git)

**Firmness: FIRM**

Global file lives at `~/.config/rip-cage/config.yaml`. Project file lives at `<project-root>/.rip-cage.yaml` (dotfile at the workspace root, alongside `.gitignore` / `.editorconfig`). Project file is **tracked in git** by default.

| File | Path | Scope | Tracked in git? |
|---|---|---|---|
| Global | `~/.config/rip-cage/config.yaml` | All projects on this host | N/A (host config) |
| Project | `<project-root>/.rip-cage.yaml` | This project only | **Yes** (committed) |

Both are optional. Both absent → behavior contract per D5.

**Rationale:**
- **Global path co-locates with ADR-020's host-side namespace.** ADR-020 D3 illustrates the rules file at `~/.config/rip-cage/identity-rules` (D3 example, ADR-020:111). That path is illustrative inside ADR-020 D3 rather than a separately decided contract, but co-locating new global cage state under the same namespace keeps host-side rip-cage files in one place. XDG-compliant.
- **Project path matches "tracked config at repo root" convention** users already understand from `.gitignore`, `.editorconfig`, `.dockerignore`, `.gitattributes`. Dot-prefix keeps repo tree clean. YAML wins on multi-key nested structure, comments, and broad parser support; `yq` is in the user's documented host CLI set (see also D-impl notes for the loader-bead dependency contract).
- **Tracked-by-default is load-bearing for team repos.** The project file is the place "the team" (and future-you, and future agents) sees what posture this project runs under. Untracked = back to env-var failure mode where one user's local override is invisible to teammates and to PR reviewers.
  - **Solo/personal repo asymmetry acknowledged.** For solo `~/code/personal/...` repos (the kinky-bubbles trigger context), "team-shared" is not a benefit; the audit-trail (`git log .rip-cage.yaml`) is the residual warrant. The decision is "track by default" not "track always" — see `--gitignore-config` opt-in alternative below.
- **Asymmetric paths (`~/.config/...` vs `.rip-cage.yaml`) is about edit frequency.** Project files are looked at often (in tree, in PR review); global is set once and forgotten. Project as a workspace-root dotfile matches `.gitignore`/`.editorconfig` ergonomics; global as a `~/.config/` file matches `~/.config/rip-cage/identity-rules`.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| **Per-project locality discarded** — single global file with per-project keys (e.g. `projects: {kinky-bubbles: {ssh: {...}}}`) | `direct:` Defeats the trigger — switch.berlin allowance for kinky-bubbles ends up in the user's home file, not the project's repo. Lost: in-tree visibility, per-PR review, team shareability. The actual axis being decided is "where does per-project posture live?" — encoding it as keys in a global file regresses on every D1 warrant above. |
| **Project file gitignored by default** (user opts into committing) | `direct:` Defeats the audit trail and team-shared-posture goal. Whole reason this isn't an env var is that it should be visible. |
| **Tracked by default with `rc init --gitignore-config` opt-in** | `reasoned:` Ergonomically appealing for solo/personal repos and forks, but adds an init-time decision the user has to make per project, and the opt-in produces an untracked-on-purpose file that teammates can't audit. Revisit if dogfooding shows the solo case is common enough that the friction warrants the flag. |
| **`.rip-cage/` directory at project root** with multiple files (`ssh.yaml`, `egress.yaml`, etc.) | `reasoned:` Premature factoring; today the file is ~5–15 lines for the typical project. Single file is easier to author, easier to diff, easier for `yq` consumers. Revisit if file grows past ~100 lines in real projects. |
| **Global at `~/.rip-cage.yaml`** (dotfile in `$HOME`) | `reasoned:` Clutters `$HOME` and lives outside the existing `~/.config/rip-cage/` namespace from ADR-020. (Note: would *not* technically conflict with `~/.config/rip-cage/` files on disk; the rejection is about namespace coherence and home-dir hygiene, not collision.) |
| **TOML or JSON instead of YAML** | `reasoned:` YAML wins on comments + nested structure + familiarity for ops/config use. JSON has no comments. TOML's nested tables get awkward for the merge semantics of D2. |

**What would invalidate this:** The project file repeatedly grows past ~100 lines or develops natural sub-domains (SSH, egress, skills) that a directory split would clarify. At that point, promote `.rip-cage.yaml` to `.rip-cage/config.yaml` with optional per-domain files.

**Invalidation check (mechanical, optional):** `find . -name '.rip-cage.yaml' -not -path './.git/*' | xargs wc -l 2>/dev/null | tail -1` — flag projects whose config exceeds 100 lines as a signal to revisit the directory-split alternative.

### D2: Two-layer precedence with per-field-type merge rules

**Firmness: FIRM**

Both files load on every `rc up` / `rc init`. The merged result is the effective config. Merge follows three rules, applied per field declared in the schema:

| Field type | Examples | Merge rule | Capability direction |
|---|---|---|---|
| **Additive list** (capability grant — adding more "allowed things") | `ssh.allowed_hosts`, `egress.allow`, `skills.extra_mounts` | **Union** — global ∪ project, deduplicated, order-preserving (global first, then project additions) | Project EXPANDS what's granted; cannot contract |
| **Selection list** (subsetting an existing capability) | `ssh.allowed_keys` | **Project replaces if explicitly present, else inherit global**. Three-state: key absent ⇒ inherit global; key present + non-empty ⇒ subset selection; key present + empty list (`[]`) ⇒ explicit zero-out (project replaces global with empty set) | Project CAN narrow a global capability; this is intentional |
| **Scalar** | `resources.memory_mb`, `version` | **Project replaces global if present** | Project replaces; direction is field-specific |

Each schema field declares its merge type explicitly in the loader's schema definition. There is no inference. Misclassifying a field is a versioned schema change, not a silent semantic shift.

Concrete example (the SSH allowlist, the first downstream consumer):

```yaml
# ~/.config/rip-cage/config.yaml — global
version: 1
ssh:
  allowed_keys:                   # selection list
    - id_ed25519_personal
    - id_ed25519_work
  allowed_hosts:                  # additive list
    - github.com                  # implicit anyway, but explicit OK
```

```yaml
# ~/code/personal/kinky-bubbles/.rip-cage.yaml — project, committed
version: 1
ssh:
  allowed_hosts:                  # additive → final = [github.com, switch.berlin]
    - switch.berlin
  allowed_keys:                   # selection (subset) → project replaces → final = [id_ed25519_personal]
    - id_ed25519_personal
```

Effective config the loader hands to the cage:

```yaml
version: 1
ssh:
  allowed_keys: [id_ed25519_personal]
  allowed_hosts: [github.com, switch.berlin]
```

**Rationale:**

The two list-merge modes correspond to two different intents that share YAML key shape but mean different things:

- **Additive (capability grant):** "On top of what's globally allowed, this project also allows X." Cannot un-grant a global capability — that's the point. Want to deny in one project? Don't grant it globally.
- **Selection (subsetting):** "Of the globally available set, this project uses only this subset." Replace semantics are intentional: kinky-bubbles wants only the personal key forwarded, even though the global config makes both available. Union would defeat the user's narrowing intent. The three-state rule (absent / non-empty / empty list) gives the user the full control surface — including explicit zero-out — without inventing magic syntax.
- **Scalar:** Replace is the only semantics that makes sense.

**Note on selection-list capability direction:** Selection-list project overrides DO contract a global capability. This is deliberate — that's what selection lists are for. The "additive lists only expand" property does not generalize to selection lists, which has consequences for D3's version-drift behavior (see D3 below).

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Project always replaces global (simple, no per-field rules) | `reasoned:` Forces project files to redeclare global allowed_keys, allowed_hosts, etc., every time. Defeats the "global = my defaults across all projects" mental model — global becomes write-only state nobody benefits from |
| All lists union by default; opt-in replace via `_replace: true` marker | `reasoned:` Magic-key syntax is harder to read than declared schema. A user reading the project YAML can't tell from the syntax which fields union vs replace. Schema-declared per-field type makes `rc config show` provenance comprehensible. |
| Project additive-only (no scalar overrides allowed) | `reasoned:` Unblocks the SSH case but blocks future scalar overrides (resource limits, timeouts) without revisiting this ADR |
| Three files (global, project, user-local-untracked) like git config | `reasoned:` Each layer needs a real use case; user-local-untracked invites hidden state invisible to teammates and to PR reviewers — the exact failure mode this ADR avoids. Revisit if a real use case emerges. |

**What would invalidate this:** A schema field is genuinely ambiguous between additive and selection semantics, and users disagree about which one they want. At that point, split the field into two (`allowed_x_extra` additive + `allowed_x_only` selection) rather than introducing per-call merge-mode flags.

**Invalidation check (mechanical, runnable in `rip-cage-o4z`'s test suite, not in this ADR's substrate):** `rc config show --json` produces effective config; for any additive-list field, `(global_field ∪ project_field) == effective_field` must hold. For any selection-list field: project absent ⇒ effective == global; project present + non-empty ⇒ effective == project; project present + `[]` ⇒ effective == `[]`. These are the loader bead's contract test cases.

### D3: Schema versioning — `version: 1` per file; unknown-higher-version warns; missing-version warns once-per-invocation

**Firmness: FIRM**

Each file independently declares `version: <integer>` at the top level. The loader knows the set of supported versions (initially `{1}`).

| Condition | Behavior |
|---|---|
| `version` field absent | Treat as `version: 1`. Warn loud once per `rc up` invocation per file (no persisted "already warned" state — each `rc up` re-warns until the user adds the field): `'<file>' has no 'version:' field; assuming version 1. Add 'version: 1' to silence.` |
| `version` matches a supported version | Load normally. |
| `version` higher than highest supported | Warn loud, **skip that file's contents** (load defaults / other layer only): `'<file>' declares version: N but rc supports up to version: M. Skipping this file. Run 'rc --version' and consider upgrading.` |
| `version` lower than supported (deprecated past schema) | Warn loud, attempt load with documented compat shim if one exists, else skip with actionable upgrade message. Not relevant in v1 (no deprecated versions exist). |

**Per-file independence:** Both files declare their own version. A user with global `version: 1` and project `version: 2` (because the teammate who wrote the project file is on a newer rc) sees the project file skipped with a warning; the global file still loads.

**Warn-once-per-invocation semantics:** "Once" is per `rc up` call. There is no persisted "already warned" sentinel — each invocation re-warns until the user adds the version field. This is intentional: persisted suppression risks a user thinking they fixed the warning when they actually just hit the suppression cache.

**Unknown-higher-version handling is field-type-conditional (resolved 2026-05-11):**

When a file declares an unsupported version, the loader does a partial parse to enumerate which fields the file uses, classified against the loader's schema:

- **If the unknown-version file declares any selection-list field** (e.g. `ssh.allowed_keys`): `rc up` aborts loud per ADR-001. Silent skip would silently expand capability beyond user intent (the user's narrowing of a globally-available set is dropped) — exactly the ADR-001:13 failure mode ("user believes they have the firewall"). Error message: `Error: '<file>' declares version: N (rc supports up to M) AND uses selection-list field(s) [<names>]. Skipping the file would silently expand capability beyond your declared intent. Upgrade rc, or remove the selection-list field(s) and pin to a supported version.`
- **If the unknown-version file declares only additive-list fields and/or scalars whose defaults are ≤ user intent** (e.g. `ssh.allowed_hosts`): warn loud, skip the file's contents, load defaults / other layer only. `'<file>' declares version: N but rc supports up to M. Skipping this file (no selection-list fields detected — capability degradation is in the safer direction). Run 'rc --version' and consider upgrading.`
- **Loader's partial-parse contract:** detecting selection-list-field presence in an unknown-version file requires only field-name enumeration (e.g. `yq 'keys' <file>`), not value interpretation. The schema's name → field-type mapping is the loader's source of truth; misclassification is impossible because field names that don't appear in the schema are reported separately as "unknown fields."

**Why this resolution.** ADR-001's fail-loud rule applies to safety-relevant state mismatches (line 31). Selection-list scope-down IS safety-relevant — the user explicitly narrowed a capability, and silent expansion violates user intent in the firewall-direction. Additive-list capability-grants are NOT safety-relevant in the same direction — silent drop of a user-intended addition leaves the cage with less capability than declared, which is the conservative direction. The two failure directions justify two different responses; ADR-001's exception clause (informational fields) is a different distinction (informational vs decision-affecting), not the right axis here. The field-type-conditional rule honors ADR-001's spirit (fail-loud where user intent could be silently broken) without paying its tax on the additive-list case where the failure direction is inverted.

**Cost acknowledged:** Loader does a partial parse of unknown-version files to detect selection-list fields. This is ~5 lines of `yq` invocation; the schema's selection-list set is small and stable.

**`rc up` does not abort on unknown-higher-version skip when no selection-list field is present.** Team-coordination case (one teammate on newer rc) still works for additive-only/scalar-only files.

**Rationale:**

- **Required version field forces every file to declare its assumed schema.** Without this, a v2 schema change (e.g., renaming `ssh.allowed_hosts` to `ssh.hosts.allow`) silently misinterprets v1 files written under the old name.
- **Per-file version field** because the two files can be authored under different rc versions (global = your machine; project = whichever teammate wrote it last).
- **Absent-version-defaults-to-1** for ergonomic ramp; the per-invocation warning makes the field discoverable without locking out users with empty/minimal early files.
- **No compat shims yet** because there's nothing to shim — v1 is the only version. Capturing the shape of how schema evolution works now (rather than retrofitting later) is what this decision is for.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| No version field; assume schema is whatever rc supports | `direct:` First breaking schema change silently misinterprets old files. The whole reason for versioning is that schema *will* evolve. |
| Higher-version best-effort loads with warning | `reasoned:` Best-effort loading silently drops fields the loader doesn't know about; downstream consumers see partial config and behave inconsistently. Skipping the file's contents is honest: "I cannot reason about this file; here are the defaults." |
| Absent-version aborts (force users to declare) | `reasoned:` Friction tax on the 80% case. Soft-default-with-loud-warning gets the same long-term behavior with better ramp. |
| Persisted "already warned" suppression | `reasoned:` Risks user thinking the warning is fixed when it's actually suppressed. Re-warning per invocation is mildly annoying; that's intentional discoverability. |

**What would invalidate this:** A real v1→v2 migration where the soft-default-with-warning is harmful (e.g., a security-sensitive field changes meaning). At that point, that specific field gets compat handling and the rest of the file still works.

**Invalidation check (mechanical, runnable in `rip-cage-o4z`'s test suite):** Two fixtures: (a) `config-future-version-with-selection.yaml` declares `version: 99` and `ssh.allowed_keys: [...]` — `rc up` must exit non-zero with an error naming the selection-list field. (b) `config-future-version-additive-only.yaml` declares `version: 99` and `ssh.allowed_hosts: [...]` (additive only) — `rc up` must exit 0 with a warning, and the effective config must omit the file's contents (i.e. `allowed_hosts` resolves to defaults / global only).

### D4: `rc config show` prints effective merged config with provenance

**Firmness: FIRM**

`rc config show` (and `rc config show --json`) prints the effective merged config. Each leaf field is annotated with provenance — where the value came from (`global`, `project`, `default`, or `union(global,project)` for additive lists).

YAML-with-comments output for human reading:

```
$ rc config show
version: 1                        # from default
ssh:
  allowed_keys:                   # from project (replaces global)
    - id_ed25519_personal
  allowed_hosts:                  # union(global, project)
    - github.com                  # from global
    - switch.berlin               # from project
```

For nested-map fields and lists-of-maps (plausible v1+ schema growth: `egress.rules: [{host, port}]`, `dcg.rules: [{pattern, action}]`), provenance is annotated **at the field level** (one comment per containing key, naming the source layers) rather than per-element. Per-element provenance for nested structures is deferred to the loader bead (`rip-cage-o4z`) to specify; the substrate ADR commits only to field-level provenance for nested types.

JSON output (`--json`) embeds provenance as a parallel structure for machine consumers:

```json
{
  "config": { "version": 1, "ssh": { "allowed_keys": ["id_ed25519_personal"], ... } },
  "provenance": {
    "version": "default",
    "ssh.allowed_keys": "project",
    "ssh.allowed_hosts": ["global", "project"]
  }
}
```

The command works without any project file (shows global + defaults), without a global file (shows project + defaults), and with neither (shows pure defaults). Runs entirely host-side; no container required.

**Rationale:**

The two-layer-with-per-field-merge-rules design from D2 is *nontrivial*. Without an effective-config view, a user staring at a project file that doesn't behave as expected has to mentally execute the merge against the global file plus the schema's per-field rules. `rc config show` makes the merged result inspectable in one command, with provenance — so a confused user (or agent) can see *why* a value resolved as it did, not just *what* it resolved to. JSON form lets `rc doctor`, hooks, and downstream tooling consume the effective config without re-implementing the loader.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| `rc config get <key>` only (single-field lookup, no full dump) | `reasoned:` Forces user to know the key they're looking for; doesn't help "why is this project allowing switch.berlin?" debugging. Worth adding later as sugar over the show command, not as a substitute. |
| Effective config without provenance | `reasoned:` Loses the "why" — user can see `ssh.allowed_hosts: [github.com, switch.berlin]` but can't tell which file each entry came from. Provenance is cheap to compute (loader knows it during merge) and load-bearing for debugging. |
| Defer `rc config show` to a follow-up bead | `direct:` The merge model in D2 is non-trivial enough that shipping it without an inspector means every confused user has to re-run the merge by hand. The inspector is part of the substrate, not a nicety. |

**What would invalidate this:** Telemetry showing nobody runs `rc config show` and `rc config get <key>` is what users actually want. Pivot, keep the JSON output for tooling.

**Invalidation check (mechanical, runnable in `rip-cage-o4z`'s test suite):** With both files present and an additive-list field that has values in each, `rc config show --json | jq '.provenance["ssh.allowed_hosts"]'` must return an array containing both `"global"` and `"project"`.

### D4a: `mounts.symlinks.*` field group — host-side symlink follow (added in rip-cage-c1p.2)

**Firmness: FIRM** (inherited from D1-D3 schema framework)

Three enum-scalar fields (selection_list type) for controlling how absolute symlinks in rip-cage-managed dotfile mount roots are resolved at `rc up` time:

| Field | Type | Default | Allowed values |
|---|---|---|---|
| `mounts.symlinks.on_dangling` | selection_list (enum scalar) | `"follow"` | `follow`, `warn`, `skip`, `error` |
| `mounts.symlinks.scope` | selection_list (enum scalar) | `"file"` | `file`, `parent` |
| `mounts.symlinks.mode` | selection_list (enum scalar) | `"rw"` | `ro`, `rw` |

**Merge semantics:** per D2 selection-list rule (project replaces global if present; absent = inherit global or use default). Each field is a single-value scalar, not a list — the "selection_list" type here indicates enum-scalar semantics: unknown values abort loud per D3.

**Schema version:** stays at 1. Unknown enum values already abort loud via the selection-list abort path (D3). Future new `on_dangling` or `scope` values that break backward compatibility require a version bump.

**Whitelist:** The scan roots set is hardcoded — currently `{~/.pi/agent}` (the host path mapping to `/pi-agent`). `/workspace` is **never** on the scan whitelist. This is a positive-allow list, not a deny-list.

**ADR-019 D1 alignment:** The existing `~/.pi/agent:/pi-agent` rw bind mount is preserved unchanged. The new second bind mount (at host-target path) is **additional**, not a replacement.

**`rc reload` eligibility:** `mounts.symlinks.*` fields are NOT reload-eligible. `rc reload` refuses loud when any of these fields diverge from the applied-config snapshot.

**rc.symlink-follow-fingerprint label:** A `rc.symlink-follow-fingerprint=<sha256>` container label is persisted at create time and verified on resume. This is a **host-state-derived** label (see D5 clarification below) — its value depends on the host's symlink state, not config content alone.

### D5: Both files absent ⇒ no behavior change in cage posture; informational output is the substrate's only side-effect

**Firmness: FIRM**

Regression contract has two parts:

1. **Config-derived cage posture unchanged.** When neither `~/.config/rip-cage/config.yaml` nor `<project>/.rip-cage.yaml` exists, `rc up` / `rc init` produce **identical config-derived cage state**: same mounts, same flags applied, same defaults, same config-derived labels, same sentinels. No new env vars injected, no new `--mount` arguments, no new `docker exec` invocations, no new config-derived container labels. Downstream consumers (SSH allowlist, future egress, etc.) interpret the empty/default effective config the same way they'd interpret no-loader-at-all.

   **Clarification (rip-cage-c1p.2):** D5's "identical effective cage state" applies specifically to **config-derived emissions** — labels, mounts, and sentinels whose values come from the effective `.rip-cage.yaml` config. **Host-state-derived emissions** are a distinct emission class: their values depend on the host's runtime state (e.g. which symlinks exist under `~/.pi/agent`), not on config content. The `rc.symlink-follow-fingerprint` label is a host-state-derived emission — it will differ between two `rc up` runs with identical config (or both-absent config) if the host's symlink state differs. This is expected and correct behavior.

   **Documented-to-vary set (host-state-derived emissions):** `{rc.symlink-follow-fingerprint}`

   The invariant for D5 is therefore: with both config files absent, the set of `rc.*` labels must be byte-identical between runs EXCEPT for the documented-to-vary set. The ADR-021 D5 invariant test asserts this: compare all `rc.*` labels between a "no dangling symlinks" run and a "with dangling symlinks" run — only `rc.symlink-follow-fingerprint` should differ.

2. **Substrate-only informational output is in scope.** The substrate DOES introduce these net-new informational outputs even when both files are absent or when a file is malformed:
   - First-run hint when a `.rip-cage.yaml` is detected for the first time per container (one-time per `rc.config-loaded` label).
   - `rc config show` is a new top-level command (only emits when invoked).
   - Schema-version-absent warnings (per D3, only when a file exists).
   - Schema-version-mismatch warnings (per D3, only when a file exists).
   - Mount-expansion log lines emitted per `[rip-cage] follow-symlink: ...` (per ADR-001 D1 unconditional-log rule; these are stderr lines, not posture changes).

Net-new stdout/stderr text is not a regression in the sense this contract cares about: it changes what the user *sees*, not what the cage *does*. The byte-identical claim from earlier drafts is replaced with this scoped contract.

**Rationale:**

- **Backward compatibility for existing users.** Anyone running rip-cage today should be able to upgrade and notice no posture change.
- **Forces downstream consumers (SSH allowlist, etc.) to handle the empty/default case explicitly.** Each consumer's bead must include a "no .rip-cage.yaml present → posture unchanged" test case. That test catches accidental coupling between loader presence and behavior change.
- **Informational output is in scope** because hiding the substrate's existence (e.g., suppressing the first-run hint) defeats discoverability. The substrate is opt-in by adding a config file; users who don't add one see at most the one-time hint when they do.
- **Host-state-derived emissions are outside the config-derived invariant scope.** The `rc.symlink-follow-fingerprint` label exists to prevent mount-shape drift on resume; its value correctly varies with host state. Treating it as a regression would require either (a) not emitting it when configs are absent (violating D4 label-lock safety) or (b) requiring the host have no symlinks (too restrictive). The cleaner model is to enumerate the documented-to-vary set explicitly.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Loader applies "sensible defaults" even when no file present (e.g., default `ssh.allowed_hosts: [github.com]` immediately tightens posture) | `direct:` Violates the regression contract; existing users see surprise behavior change on rc upgrade. The right time to tighten defaults is when a downstream consumer ships, not when the substrate ships. |
| Strict byte-identical contract (no new stdout/stderr at all) | `reasoned:` Forbids the first-run hint and the version warnings, which are the substrate's discoverability surface. Hiding the substrate makes it harder to use, not safer. |
| Loader prints a one-time "no config found, here are your defaults" hint even when both absent | `reasoned:` Adds noise for the 80% case who never need a config file. Defaults should be silent. `rc config show` is the discoverable entry point for users who care. |
| Treat rc.symlink-follow-fingerprint as config-derived and suppress it when configs absent | `reasoned:` Would break D4a's label-lock safety on resume; the label must always be present so resume can detect drift even when the user subsequently adds config. |

**What would invalidate this:** A future ADR explicitly decides to ship a tightening default in the substrate itself. At that point, this decision is amended, not silently broken.

**Invalidation check (mechanical, runnable):** With both config files absent, `tests/test-e2e-lifecycle.sh` (full count today) must produce the same PASS/FAIL count and the same **config-derived** emitted mounts/labels/sentinels as it did before the loader landed. A delta in config-derived mounts, labels, or sentinels means the cage-posture-unchanged half of D5 is broken. Deltas in host-state-derived emissions (the documented-to-vary set `{rc.symlink-follow-fingerprint}`) are explicitly **in-scope** per the D5 clarification above. (Stdout/stderr deltas from the substrate's informational output are also explicitly in-scope per the contract.)

## Consequences

**Positive:**
- Per-project cage posture is a tracked, diff-able, auditable artifact at the workspace root — visible in PR reviews, in `git log`, and to teammates / future agents.
- Agents can self-configure: hit a wall, edit `.rip-cage.yaml`, commit, re-run `rc up` (or `rc destroy && rc up` for fields that require recreate — see Implementation notes). No hidden env var.
- Global file collapses repeated user preferences to one place across all projects.
- The substrate unblocks downstream work (`rip-cage-b0c` SSH allowlist, future egress overrides, future skill mount opt-outs, future resource limits) without each consumer re-inventing config plumbing.
- `rc config show` makes the merge model inspectable, so the per-field-type rules don't become a debugging trap.
- D5's regression contract means existing users see no posture change on upgrade.

**Negative:**
- New surface area: one schema, one loader, one CLI subcommand (`rc config show`), one new convention file at every project root that opts in.
- Schema versioning means schema evolution requires deliberate version bumps. (Also positive — see D3 rationale.)
- YAML adds a parser dependency surface (see Implementation notes for `yq` pinning).
- D3's field-type-conditional version-drift rule adds loader complexity (partial parse of unknown-version files to enumerate field names against the schema's selection-list set). ~5 lines of `yq`; cost is real but bounded.
- Two layers means `rc config show` is part of the debugging vocabulary; users who don't know it exists will be confused by merged behavior. Mitigation: D5's first-run hint surfaces it.

**Neutral:**
- Loader adds host-side cost on every `rc up` (parse two YAML files, merge, write effective config). Cost: ~50ms with `yq`, well below `docker start`.
- The asymmetry between global path (`~/.config/rip-cage/config.yaml`) and project path (`.rip-cage.yaml`) requires a one-line explanation in docs.

## Implementation notes

- **Schema definition** lives in the loader (initially as a bash associative array or a small declarative file). For each field: name, type (scalar / additive-list / selection-list), default value, **version-strict marker** (used by D3's Option B if chosen). Schema is the single source of truth for merge behavior.
- **Loader contract:** `_load_effective_config()` returns the merged config in a consumable form (JSON to stdout via `yq -o=json`, or as exported env vars for bash consumers — TBD in the loader bead).
- **`yq` dependency pinning:** Loader requires `yq` on host. If absent, `rc up` emits an actionable error per ADR-001: `Error: yq not found on PATH. Install yq (brew install yq | apt-get install yq) to use .rip-cage.yaml. Run rc with no .rip-cage.yaml present to keep today's behavior.` Loader does NOT silently degrade to "skip config" on missing parser — that would silently nullify a user-authored capability scoping (the same failure class as D3's Option A).
- **`rc config show`:** new top-level subcommand. `rc config show` (YAML+comments), `rc config show --json` (JSON+provenance), `rc config show <key>` (single field, deferred bead).
- **Container recreate vs `rc up`:** Most fields apply on `rc up` (resume re-runs the loader and re-translates downstream artifacts). Capability-changing fields that affect docker-create-time mounts or args (e.g., `ssh.allowed_keys` filtering the forwarded ssh-agent socket; `egress.allow` modifying iptables at create) require `rc destroy && rc up`. Each consumer bead documents which of its fields are recreate-required vs resume-applicable. Loader prints `Effective config changed since last rc up; some fields require 'rc destroy && rc up' to apply (see <field-list>).` when it detects a change against the `rc.config-loaded=<sha256>` label.
- **First-run hint:** when `rc up` loads a `.rip-cage.yaml` for the first time on a given container (detected via label `rc.config-loaded=<sha256>`), print `Loaded .rip-cage.yaml ([N fields applied]). Run 'rc config show' to inspect.` Subsequent `rc up` calls with the same content sha256 do not re-print.
- **Loader state location:** `rc.config-loaded=<sha256>` lives as a container label (host-side, queryable via `docker inspect`), matching ADR-020's `rc.github-identity` label pattern. "Skipped layer" diagnostics live in `rc config show` output (computed fresh each invocation), not in a sentinel — sentinel pattern from ADR-020 D5 is reserved for state that needs to be readable from inside the cage's first-shell echo.
- **Schema version field:** the loader applies D3's field-type-conditional rule **before** attempting to merge. Partial parse: enumerate top-level field names in the unknown-version file (`yq 'keys' <file>`); cross-reference against schema's selection-list set; if intersection non-empty → abort loud with the specific field names; else → warn and skip the file's contents. Provenance for skipped files is recorded so `rc config show` can surface "this layer was skipped due to version mismatch" rather than silently omitting it.
- **Test fixtures:** `tests/fixtures/config-*.yaml` covering the matrix in D2 (additive, selection three-state, scalar, mixed), plus D3 (missing version, unsupported version, version skew between layers) and D5 (both absent posture-unchanged check).
- **Docs:** new reference page at `docs/reference/config.md`. README gets a one-paragraph mention with link.
- **Downstream consumer template (for SSH allowlist `rip-cage-b0c` and future):** each consumer bead must include (a) the schema fields it owns + their merge types + version-strict markers, (b) a "both files absent → posture unchanged" regression test (D5 contract), (c) a "global + project both contribute" integration test that validates the merge rule for that consumer's fields, (d) explicit declaration of which fields are recreate-required vs resume-applicable.

## Carries over from prior ADRs

- **ADR-001** fail-loud-and-actionable applies to schema validation errors and to consumer-level errors (e.g., `ssh.allowed_keys` references a key the user doesn't have). Its application to D3's version-drift behavior is **field-type-conditional**: selection-list fields trigger fail-loud-abort (silent skip would silently expand capability past user intent — ADR-001:13 failure mode); additive-list and scalar fields warn-and-skip (silent skip yields LESS capability, not more — ADR-001's failure direction is inverted).
- **ADR-014 D2** (non-interactive SSH posture) is **not modified by this substrate**. The downstream `rip-cage-b0c` (SSH allowlist) bead will edit ADR-014 D2 in place per ADR-011 when shipped, replacing the `known_hosts` rewrite with capability-scoped allowlists. ADR-014 D2's caveat at line 79 (CLI `-o` reach limit) remains accurate as-stated for the default container.
- **ADR-020** (ssh identity routing) coexists. Identity routing remains keyed by `~/.config/rip-cage/identity-rules` and CLI flags / labels; the SSH allowlist enabled by this substrate is orthogonal (one is "which key for which github account?", the other is "which hosts and keys can the cage reach at all?"). Both share the `~/.config/rip-cage/` namespace by D1.
- **ADR-017** (ssh-agent forwarding) is the capability that the SSH allowlist consumer scopes. This substrate is what makes per-project scoping expressible.
