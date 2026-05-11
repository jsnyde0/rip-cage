# ADR-021: Layered `.rip-cage.yaml` config — global defaults, per-project overrides

**Status:** Proposed
**Date:** 2026-05-11
**Beads:** `rip-cage-uzp` (this ADR), `rip-cage-o4z` (loader implementation), `rip-cage-b0c` (first user: SSH host+key allowlist)
**Related:** [ADR-014](ADR-014-push-less-cage.md) D2 (non-interactive SSH posture — partially superseded by the SSH allowlist that this substrate enables), [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (forward-by-default), [ADR-020](ADR-020-ssh-identity-routing.md) (ssh identity routing — coexists), project [CLAUDE.md](../../CLAUDE.md) philosophy section ("agent autonomy is the product", "layers, not walls", "'It's annoying' is a design signal")

## Context

Rip-cage's posture today is fixed at image-build / `rc up` time, with a few escape hatches via CLI flags (`--no-forward-ssh`, `--no-egress`, `--github-identity`, `--no-ssh-config`) and one rules file (`~/.config/rip-cage/identity-rules`). Per-project differences in trust posture have nowhere to live except the user's shell history.

A concrete trigger: 2026-05-11 the agent in `~/code/personal/kinky-bubbles` needed to SSH to `switch@switch.berlin` for legitimate prod-DB diagnosis. The ssh-agent forward (ADR-017) gave it the key. The mounted `~/.ssh/known_hosts` (ADR-020 D1) gave it the host pin. The agent worked around ADR-014 D2's `known_hosts` rewrite trivially with `-o UserKnownHostsFile=...`. The bypass wasn't a security hole — the agent used capabilities the user already provisioned — but it exposed two structural gaps:

1. **The `known_hosts` rewrite is theater.** It looks restrictive but isn't, because the real capability is the forwarded ssh-agent (the keys), not the address book. Fixing this needs to scope the *capability*, not the pin file. (See bead `rip-cage-b0c`.)
2. **There's no place for "this project is allowed to SSH to switch.berlin" to live.** The right answer isn't an env var (per-shell, undiscoverable, not committed) and it isn't a CLI flag (one-shot, easy to forget, no project memory). It's a tracked per-project file that anyone reading the repo can see, that the agent can edit, and that `git log` makes auditable.

The pattern is the same one CLAUDE.md uses: a global file (`~/.claude/CLAUDE.md` / `~/CLAUDE.md`) sets the user's defaults across all projects, and a per-project file (`<project>/CLAUDE.md`) adds project-specific context. Both apply. The agent reads both. The project file is committed.

This ADR introduces the equivalent primitive for cage *posture*: `.rip-cage.yaml`. The first downstream user is the SSH host+key allowlist (`rip-cage-b0c`). Other plausible users — egress allow/deny overrides, skill mount opt-outs, resource limits, per-project DCG additions — are out of scope here but shape the schema.

This ADR is the **substrate**. It does not change cage behavior on its own. The loader (`rip-cage-o4z`) implements it; the SSH allowlist (`rip-cage-b0c`) is the proof-of-concept first user.

## Decisions

### D1: Two files — `~/.config/rip-cage/config.yaml` (global) + `<project>/.rip-cage.yaml` (project, tracked in git)

**Firmness: FIRM**

Global file lives at `~/.config/rip-cage/config.yaml`. Project file lives at `<project-root>/.rip-cage.yaml` (dotfile at the workspace root, alongside `.gitignore` / `.editorconfig`). Project file is **tracked in git** by default (i.e., not added to `.gitignore` by `rc init`).

| File | Path | Scope | Tracked in git? |
|---|---|---|---|
| Global | `~/.config/rip-cage/config.yaml` | All projects on this host | N/A (host config) |
| Project | `<project-root>/.rip-cage.yaml` | This project only | **Yes** (committed) |

Both are optional. Both absent → identical behavior to today (D5).

**Rationale:**
- **Global path matches existing convention.** ADR-020 already uses `~/.config/rip-cage/identity-rules`. Putting global cage config under `~/.config/rip-cage/` keeps host-side rip-cage state in one place. XDG-compliant; standard in 2026.
- **Project path matches "tracked config at repo root" convention** users already understand from `.gitignore`, `.editorconfig`, `.dockerignore`, `.gitattributes`. Dot-prefix keeps repo tree clean. YAML is the right format (multi-key nested structure, comments, broad parser support, `yq` is already in the user's CLI inventory per `~/.claude/CLAUDE.md`).
- **Tracked-by-default is load-bearing.** The whole point of the project file is that *the team* (and future-you, and future agents) can see what posture this project runs under. Untracked = back to env-var failure mode where one user's local override is invisible to everyone else.
- **Asymmetric paths (`~/.config/...` vs `.rip-cage.yaml`) is intentional.** Users edit the project file often (visible in tree, looked at when reviewing PRs), the global file rarely (set once, forget). Both being dotfiles in their respective homes would be aesthetically symmetric but worse: `~/.rip-cage.yaml` clutters $HOME and conflicts with the existing `~/.config/rip-cage/` namespace.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Single file at `~/.config/rip-cage/config.yaml`, no per-project override | `direct:` Defeats the trigger — there's nowhere for "kinky-bubbles is allowed to SSH to switch.berlin" to live without leaking that posture into every other project on the host |
| `.rip-cage/` directory at project root with multiple files (`ssh.yaml`, `egress.yaml`, etc.) | `reasoned:` Premature factoring; today the file would have ~5–15 lines for the typical project. One file is easier to author, easier to diff, easier for `yq` consumers. Revisit if the file grows past ~100 lines in real projects. |
| Project file gitignored by default (user opts into committing) | `direct:` Defeats the audit trail and team-shared-posture goal. The whole reason this isn't an env var is that it should be visible. |
| Global path at `~/.rip-cage.yaml` (dotfile in $HOME) | `reasoned:` Conflicts with the existing `~/.config/rip-cage/` namespace from ADR-020; clutters $HOME; XDG is the standard for new tools in 2026 |
| TOML or JSON instead of YAML | `reasoned:` YAML wins on comments + nested structure + broad familiarity for ops/config use cases. JSON has no comments. TOML's nested tables get awkward for the merge semantics this design requires. `yq` is already a documented host CLI tool. |

**What would invalidate this:** The project file repeatedly grows past ~100 lines or develops natural sub-domains (SSH, egress, skills) that a directory split would clarify. At that point, promote `.rip-cage.yaml` to `.rip-cage/config.yaml` with optional per-domain files.

**Invalidation check (mechanical, optional):** `find . -name '.rip-cage.yaml' -not -path './.git/*' | xargs wc -l 2>/dev/null | tail -1` — flag projects whose config exceeds 100 lines as a signal to revisit the directory-split alternative.

### D2: Two-layer precedence with per-field-type merge rules

**Firmness: FIRM**

Both files load on every `rc up` / `rc init`. The merged result is the effective config. Merge follows three rules, applied per field declared in the schema:

| Field type | Examples | Merge rule |
|---|---|---|
| **Additive list** (capability grants — adding more "allowed things") | `ssh.allowed_hosts`, `egress.allow`, `skills.extra_mounts` | **Union** — global ∪ project, deduplicated, order-preserving (global first, then project additions) |
| **Selection list** (subsetting an existing capability) | `ssh.allowed_keys` | **Project replaces if present, else inherit global** |
| **Scalar** | `resources.memory_mb`, `version` | **Project replaces global if present** |

Each schema field declares its merge type explicitly in the loader's schema definition. There is no inference (e.g., "all lists are additive"). Misclassifying a field is a versioned schema change, not a silent semantic shift.

Concrete example (the SSH allowlist, the first downstream user):

```yaml
# ~/.config/rip-cage/config.yaml — global
ssh:
  allowed_keys:                   # selection list
    - id_ed25519_personal
    - id_ed25519_work
  allowed_hosts:                  # additive list
    - github.com                  # implicit anyway, but explicit OK
```

```yaml
# ~/code/personal/kinky-bubbles/.rip-cage.yaml — project, committed
ssh:
  allowed_hosts:                  # additive → final = [github.com, switch.berlin]
    - switch.berlin
  allowed_keys:                   # selection → project replaces → final = [id_ed25519_personal]
    - id_ed25519_personal
```

Effective config the loader hands to the cage:

```yaml
ssh:
  allowed_keys: [id_ed25519_personal]
  allowed_hosts: [github.com, switch.berlin]
```

**Rationale:**

The two list-merge modes correspond to two different intents that often share a YAML key shape but mean different things:

- **Additive (capability grant):** "On top of what's globally allowed, this project also allows X." Negating is impossible by design — you cannot un-grant a global capability from a project file. (Want to deny in one project? Don't grant it globally.) This matches the philosophy: project files *expand* trust, never silently *contract* it. The global file is the host's choice; the project file is the workspace's request.
- **Selection (subsetting):** "Of the globally available set, this project uses only this subset." Replace semantics are right because intent is restrictive: kinky-bubbles wants only the personal key forwarded, even though the global config makes both available. Union would be wrong — the project would inherit the work key it explicitly excluded.
- **Scalar:** Replace is the only semantics that makes sense.

The "no inference" rule (each field declares its type in schema) prevents the worst failure mode: a user reading a YAML file and guessing wrong about merge behavior. The `rc config show` output from D4 makes the resolved values inspectable.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Project always replaces global (simple, no per-field rules) | `reasoned:` Forces project files to redeclare global allowed_keys, allowed_hosts, etc., every time. Defeats the "global = my defaults across all projects" mental model — global becomes write-only state nobody benefits from |
| All lists union by default; opt-in replace via `_replace: true` marker | `reasoned:` Magic-key syntax is harder to read than declared schema. A user reading the project YAML can't tell from the syntax which fields union vs replace. Schema-declared per-field type makes `rc config show` provenance comprehensible. |
| Project additive-only (no scalar overrides allowed) | `reasoned:` Unblocks the SSH case but blocks future scalar overrides (resource limits, timeouts) without this design having to be revisited |
| Three files (global, project, user-local-untracked) like git config | `reasoned:` Each layer needs a real use case; user-local-untracked invites hidden state that's invisible to teammates and to PR reviewers — the exact failure mode this ADR avoids. Revisit if a real use case emerges. |

**What would invalidate this:** A schema field is genuinely ambiguous between additive and selection semantics, and users disagree about which one they want. At that point, split the field into two (`allowed_x_extra` additive + `allowed_x_only` selection) rather than introducing per-call merge-mode flags.

**Invalidation check (mechanical, optional):** `rc config show --json` produces effective config; for any additive-list field, asserting `(global_field ∪ project_field) == effective_field` and for any selection-list field asserting `(project_field if present else global_field) == effective_field` should hold for all fixtures in `tests/test-config-loader.sh`.

### D3: Schema versioning — `version: 1` required; unknown-higher-version warns and falls back to defaults

**Firmness: FIRM**

Both files declare `version: <integer>` at the top level. The loader knows the set of versions it supports (initially `{1}`).

| Condition | Behavior |
|---|---|
| `version` field absent | Treat as `version: 1` (current). Warn loud once: `'<file>' has no 'version:' field; assuming version 1. Add 'version: 1' to silence.` |
| `version` matches a supported version | Load normally. |
| `version` higher than highest supported | Warn loud, **skip that file entirely** (load defaults / other layer only): `'<file>' declares version: N but rc supports up to version: M. Skipping this file. Run 'rc --version' and consider upgrading.` |
| `version` lower than supported (deprecated past schema) | Warn loud, attempt load with documented compat shim if one exists, else skip with actionable upgrade message. Not relevant in v1 (no deprecated versions exist). |

**`rc up` does not abort on schema mismatch.** A user with rc v1.5 opening a project whose `.rip-cage.yaml` was written by a teammate using rc v2.0 is a normal team-coordination case, not a fatal error. The project file gets skipped; the cage runs with global + defaults. The user gets a clear upgrade message. This matches "agent autonomy is the product" — don't block the cage on host-vs-project version drift.

**Rationale:**

- **Required version field forces every file to declare its assumed schema.** Without this, a v2 schema change (e.g., renaming `ssh.allowed_hosts` to `ssh.hosts.allow`) silently misinterprets v1 files written under the old name.
- **Higher-than-supported warns rather than aborts** because of the team-coordination case above. The cost of warning is negligible; the cost of aborting is "user can't work in this project until they upgrade rc," which is exactly the friction the philosophy says to avoid.
- **Absent-version-defaults-to-1** for ergonomic ramp: early users won't have to remember to add the field to a 5-line config. The one-time warning makes the field discoverable.
- **No compat shims yet** because there's nothing to shim — v1 is the only version. Capturing the shape of how schema evolution works now (rather than retrofitting later) is what this decision is for.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| No version field; assume schema is whatever rc supports | `direct:` First breaking schema change silently misinterprets old files. The whole reason for versioning is that schema *will* evolve. |
| Higher-version aborts loud | `reasoned:` Forces team to coordinate rc upgrades atomically; first teammate to push a v2 file blocks everyone else. ADR-001 fail-loud is for things rc detects that should never happen; schema version drift is normal and recoverable. |
| Higher-version best-effort loads with warning | `reasoned:` Best-effort loading silently drops fields the loader doesn't know about; downstream consumers (SSH allowlist) see partial config and behave inconsistently. Skipping the file entirely is honest: "I cannot reason about this file; here are the defaults." |
| Absent-version aborts (force users to declare) | `reasoned:` Friction tax on the 80% case. Soft-default-with-loud-warning gets the same long-term behavior with better ramp. |

**What would invalidate this:** A real v1→v2 migration where the soft-default-with-warning is harmful (e.g., a security-sensitive field changes meaning). At that point, that specific field gets compat handling and the rest of the file still works.

**Invalidation check (mechanical, optional):** Fixture `tests/fixtures/config-future-version.yaml` declares `version: 99`; `rc config show` on that fixture must (a) exit 0, (b) not include any field from the fixture in the effective config, (c) print the upgrade-message warning to stderr. If exit non-zero or the fields appear in effective config, D3 is broken.

### D4: `rc config show` prints effective merged config with provenance

**Firmness: FIRM**

`rc config show` (and `rc config show --json`) prints the effective merged config. Each field is annotated with provenance — where the value came from (`global`, `project`, `default`, or `union(global,project)` for additive lists).

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

The command works without any project file (shows global + defaults), without a global file (shows project + defaults), and with neither (shows pure defaults). It runs entirely host-side; no container required.

**Rationale:**

The two-layer-with-per-field-merge-rules design from D2 is *nontrivial*. Without an effective-config view, a user staring at a project file that doesn't behave as expected has to mentally execute the merge against the global file plus the schema's per-field rules. That's exactly the failure mode this design replaces (vs env vars). `rc config show` makes the merged result inspectable in one command, with provenance — so a confused user (or agent) can see *why* a value resolved as it did, not just *what* it resolved to.

The JSON form lets `rc doctor`, hooks, and downstream tooling consume the effective config without re-implementing the loader.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| `rc config get <key>` only (single-field lookup, no full dump) | `reasoned:` Forces user to know the key they're looking for; doesn't help "why is this project allowing switch.berlin?" debugging. Worth adding later as sugar over the show command, not as a substitute. |
| Effective config without provenance | `reasoned:` Loses the "why" — user can see `ssh.allowed_hosts: [github.com, switch.berlin]` but can't tell which file each entry came from. Provenance is cheap to compute (loader knows it during merge) and load-bearing for debugging. |
| Defer `rc config show` to a follow-up bead | `direct:` The merge model in D2 is non-trivial enough that shipping it without an inspector means every confused user has to re-run the merge by hand. The inspector is part of the substrate, not a nicety. |

**What would invalidate this:** Telemetry showing nobody runs `rc config show` and `rc config get <key>` is what users actually want. Pivot, keep the JSON output for tooling.

**Invalidation check (mechanical, optional):** With both files present and an additive-list field that has values in each, `rc config show --json | jq '.provenance["ssh.allowed_hosts"]'` must return an array containing both `"global"` and `"project"`. If it returns a single string or omits one source, D4's union-provenance is broken.

### D5: Both files absent ⇒ behavior is byte-identical to today

**Firmness: FIRM**

When neither `~/.config/rip-cage/config.yaml` nor `<project>/.rip-cage.yaml` exists, `rc up` / `rc init` behave **byte-identically** to the current implementation (pre-loader). No new mounts, no new flags applied, no new sentinels written, no new banner content. The loader runs and produces an "all defaults" effective config that downstream consumers (SSH allowlist, future egress, etc.) interpret the same way they'd interpret no-config-loader-at-all.

This decision is the **regression contract** for everything else in the substrate.

**Rationale:**

- **Backward compatibility for existing users.** Anyone running rip-cage today should be able to upgrade and notice nothing.
- **Forces downstream consumers (SSH allowlist, etc.) to handle the empty/default case explicitly.** Each consumer's bead must include a "no .rip-cage.yaml present → behavior unchanged" test case. That test is what catches accidental coupling between loader presence and behavior change.
- **Makes the loader truly substrate.** The substrate ships first, alone, with no behavior change. Downstream beads opt in field by field.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Loader applies "sensible defaults" even when no file present (e.g., default `ssh.allowed_hosts: [github.com]` immediately tightens posture) | `direct:` Violates the regression contract; existing users see surprise behavior change on rc upgrade. The right time to tighten defaults is when a downstream consumer ships, not when the substrate ships. |
| Loader prints a one-time "no config found, here are your defaults" hint | `reasoned:` Adds noise for the 80% case who never need a config file. Defaults should be silent. `rc config show` is the discoverable entry point for users who care. |

**What would invalidate this:** A future ADR explicitly decides to ship a tightening default in the substrate itself (rather than in a consumer bead). At that point, this decision is amended, not silently broken.

**Invalidation check (mechanical, optional):** With both config files absent, `tests/test-e2e-lifecycle.sh` (full count today) must produce the same PASS/FAIL count as it did before the loader landed. A delta means D5 is broken.

## Consequences

**Positive:**
- Per-project cage posture is a tracked, diff-able, auditable artifact at the workspace root — visible in PR reviews, in `git log`, and to teammates / future agents.
- Agents can self-configure: hit a wall, edit `.rip-cage.yaml`, commit, ask the user to recreate the cage. No hidden env var required.
- Global file collapses repeated user preferences to one place across all projects.
- The substrate unblocks downstream work (SSH allowlist `rip-cage-b0c`, future egress overrides, future skill mount opt-outs, future resource limits) without each consumer re-inventing config plumbing.
- `rc config show` makes the merge model inspectable, so the per-field-type rules don't become a debugging trap.
- D5's regression contract means existing users see zero behavior change on upgrade.

**Negative:**
- New surface area: one schema, one loader, one CLI subcommand (`rc config show`), one new convention file at every project root that opts in.
- Schema versioning means schema evolution requires deliberate version bumps, not silent additions. (This is also positive — see D3 rationale.)
- YAML adds a parser dependency surface. `yq` is already a documented host CLI; loader uses it (or vendors a small parse-on-host shim).
- Two layers means `rc config show` is now part of the debugging vocabulary; users who don't know it exists will be confused by merged behavior. Mitigation: surface it in the next-step output of `rc up` when a config file is loaded for the first time.

**Neutral:**
- Loader adds host-side cost on every `rc up` (parse two YAML files, merge, write effective config). Cost: ~50ms with `yq`, well below `docker start`.
- The asymmetry between global path (`~/.config/rip-cage/config.yaml`) and project path (`.rip-cage.yaml`) requires a one-line explanation in docs. That's the cost of matching established conventions on both ends.

## Implementation notes

- **Schema definition** lives in the loader (initially as a bash associative array or a small declarative file). For each field: name, type (scalar / additive-list / selection-list), default value. The schema is the single source of truth for merge behavior.
- **Loader contract:** `_load_effective_config()` returns the merged config in a consumable form (JSON to stdout via `yq -o=json`, or as exported env vars for bash consumers — TBD in the loader bead).
- **`rc config show`:** new top-level subcommand. `rc config show` (YAML+comments), `rc config show --json` (JSON+provenance), `rc config show <key>` (single field).
- **First-run hint:** when `rc up` loads a `.rip-cage.yaml` for the first time on a given container (detected via label `rc.config-loaded=<sha256>`), print `Loaded .rip-cage.yaml ([N fields applied]). Run 'rc config show' to inspect.`
- **Schema version field:** the loader rejects/skips files with unsupported version per D3 *before* attempting to merge. Provenance for skipped files is recorded so `rc config show` can surface "this layer was skipped due to version mismatch."
- **Test fixtures:** `tests/fixtures/config-*.yaml` covering the matrix in D2 (additive, selection, scalar, mixed), plus D3 (missing version, unsupported version) and D5 (both absent).
- **Docs:** new reference page at `docs/reference/config.md`. README gets a one-paragraph mention with link.
- **Downstream consumer template (for SSH allowlist and future):** each consumer bead must include (a) the schema fields it owns + their merge types, (b) a "both files absent → behavior unchanged" regression test (D5 contract), (c) a "global + project both contribute" integration test that validates the merge rule for that consumer's fields.

## Carries over from prior ADRs

- **ADR-001** fail-loud-and-actionable applies to schema validation errors and to consumer-level errors (e.g., `ssh.allowed_keys` references a key the user doesn't have). It does NOT apply to schema version drift (D3) — that's a recoverable state, not an unrecoverable one.
- **ADR-014 D2** (non-interactive SSH posture) is partially superseded by the SSH allowlist (`rip-cage-b0c`) which uses this substrate. That bead either updates ADR-014 D2 in place (per the project's ADR-edit-in-place convention) or documents in its design notes why the override is replaced by the allowlist mechanism.
- **ADR-020** (ssh identity routing) coexists. Identity routing remains keyed by `~/.config/rip-cage/identity-rules` and CLI flags / labels; the SSH allowlist that this substrate enables is orthogonal (one is "which key for which github account?", the other is "which hosts and keys can the cage reach at all?"). They share the same `~/.config/rip-cage/` namespace by D1.
- **ADR-017** (ssh-agent forwarding) is the capability that the SSH allowlist consumer scopes. This substrate is what makes per-project scoping expressible.
