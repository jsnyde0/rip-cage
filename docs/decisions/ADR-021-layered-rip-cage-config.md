# ADR-021: Layered `.rip-cage.yaml` config — global defaults, per-project overrides

**Status:** Proposed (revised 2026-07-14 — v2 merge/version model: `!replace` tag, schema version {2}, four-source provenance, write verbs, migration posture, profiles deferred; FIRM D2/D3 mutation human-signed-off (Jonatan) + 3-round adversarial design review, rip-cage-tsf2.10. Prior revision 2026-07-01 — D7 config ro-mount-by-default, rip-cage-cw51)
**Date:** 2026-05-11
**Beads:** `rip-cage-uzp` (this ADR), `rip-cage-o4z` (v1 loader implementation), `rip-cage-b0c` (first user: SSH host+key allowlist, since retired), `rip-cage-tsf2.10` (config model v2 — the converged design this revision projects; review trail r1 REVISE/8 folded, r2 REVISE/4 folded, r3 PASS lives in that bead's `--design`)
**Related:** [ADR-001](ADR-001-fail-loud-pattern.md) (fail-loud + narrow exception scope — informs D3), [ADR-014](ADR-014-push-less-cage.md) D2 (non-interactive SSH posture — `Match final` reach limits caveat at line 79 anticipated CLI `-o` bypass), [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (forward-by-default — the capability the SSH allowlist scopes), [ADR-020](ADR-020-ssh-identity-routing.md) (ssh identity routing — coexists; shares `~/.config/rip-cage/` namespace), project [CLAUDE.md](../../CLAUDE.md) philosophy section ("agent autonomy is the product", "layers, not walls", "'It's annoying' is a design signal")

## Context

Rip-cage's posture today is fixed at image-build / `rc up` time, with a few escape hatches via CLI flags (`--no-forward-ssh`, `--no-egress`, `--github-identity`, `--no-ssh-config`) and one rules file (`~/.config/rip-cage/identity-rules`). Per-project differences in trust posture have nowhere to live except the user's shell history.

A concrete trigger: 2026-05-11 the agent in `~/code/personal/kinky-bubbles` needed to SSH to `switch@switch.berlin` for legitimate prod-DB diagnosis. The ssh-agent forward (ADR-017) gave it the key; the mounted `~/.ssh/known_hosts` (ADR-020 D1) gave it the host pin. The agent worked around ADR-014 D2's `known_hosts` rewrite trivially with `-o UserKnownHostsFile=...`. **This bypass is not a discovery** — ADR-014 D2's caveat at line 79 explicitly documents that `Match final Host *` does not defeat (a) explicit CLI `-o` flags, nor (b) per-Host user-config values. ADR-014 D2 was scoped honestly to the default container; the bypass is the `-o` reach limit that ADR-014 D2 already named.

What the trigger does expose is a different gap: **there is nowhere for "this project is allowed to SSH to switch.berlin" to live.** The right answer isn't an env var (per-shell, undiscoverable, not committed) and it isn't a CLI flag (one-shot, easy to forget, no project memory). It's a tracked per-project file that anyone reading the repo can see, that the agent can edit, and that `git log` makes auditable. The downstream consumer (`rip-cage-b0c` SSH host+key allowlist) is what will actually replace ADR-014 D2's `known_hosts` rewrite with capability scoping; per the in-place-evolution convention (ADRs reflect target architecture; note: rip-cage's local ADR-011 is shell-completions), that bead will edit ADR-014 D2 in place. **This substrate ADR alone does not modify ADR-014.**

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

### D2: Three-layer fold-left merge — lists union by default; explicit `!replace` tag for narrowing (schema v2)

**Firmness: FIRM** (revised 2026-07-14, rip-cage-tsf2.10 — v1's per-field-type merge rules replaced; FIRM mutation human-signed-off + 3-round design review)

The merge stack is exactly **three elements, folded left: [schema defaults, global file, project file]**. There is NO distinct "seed" merge layer — the curated default hosts are auto-seeded CONTENT of the global file (`_config_ensure_global_seeded` writes them into `~/.config/rip-cage/config.yaml` on first `rc up`; existing behavior, unchanged). Docs that say "seed ∪ global ∪ project" describe file-content *provenance*, not merge arity; the loader merges two file layers over schema defaults.

Merge rules:

- **ALL list fields union by default** across the stack, order-preserving dedup (lower layers first). v1's additive-list behavior becomes the universal list default.
- **A file layer may tag a list field `!replace`:** that layer's value replaces everything inherited from lower stack positions (a global tag replaces the schema default; a project tag replaces the default+global result), and becomes the new base for higher layers. `!replace []` is the explicit zero-out.
- **ONE replace-forbidden field: `mounts.denylist` stays union-only** — `!replace` on it aborts loud citing ADR-023 D2 (FIRM: project expands the secret-path denylist, never contracts it; a wholesale `!replace []` clear is exactly the operation it forbids, and under `mounts.config_mode: rw` it would hand a prompt-injected in-cage agent a denylist-clearing vector that additive-only structurally forecloses). The operator's own global-file edit remains the way to shape the global denylist. **ADR-023 is honored, not evolved.**
- **Scalars and enum scalars unchanged:** project replaces global replaces default; an unknown enum value aborts loud. The schema type formerly named `selection_list` for enum-shaped scalars (`mounts.config_mode`, `mounts.symlinks.*`, `session.multiplexer`, `auth.credential_mounts`, `auth.per_tool.*`) is renamed **`enum`**; semantics unchanged.
- **Validation aborts loud naming the exact path:** an unknown custom tag; `!replace` on a non-list or undeclared field; `!replace` on `mounts.denylist`. PR-legibility is the point — the override is visible in the project-file diff at point of use.

Concrete example (`network.allowed_hosts`, the dominant consumer):

```yaml
# ~/.config/rip-cage/config.yaml — global (auto-seeded content + operator additions)
version: 2
network:
  allowed_hosts:
    - api.anthropic.com
    - github.com
```

```yaml
# <project>/.rip-cage.yaml — default: union (project EXPANDS)
version: 2
network:
  allowed_hosts:            # effective = [api.anthropic.com, github.com, chatgpt.com]
    - chatgpt.com
```

```yaml
# <project>/.rip-cage.yaml — explicit narrowing via !replace
version: 2
network:
  allowed_hosts: !replace   # effective = [api.anthropic.com] — inherited set discarded
    - api.anthropic.com
```

**Counter-argument to v1's rationale (the FIRM-mutation warrant).** v1's additive/selection split assumed a list's "capability direction" is knowable per-field at schema time and that capability-grant lists never need narrowing. Dogfooding falsified this: because additive lists could never be narrowed per-project, nothing project-narrowable could safely live in the global file, which forced the workaround placement rule "only universal earns global" (taught at length in the configure-cage skill — a smell) and made global slots write-averse — the exact "global becomes write-only state nobody benefits from" failure v1 D2's first Alternatives row was written to avoid. Per-key merge control at point of use (Docker-compose-style) keeps the union default while restoring narrowing, and the override is *visible in the project-file diff* — which a schema-declared field type never was.

**Honest cost of the retirement:** `mounts.allow_risky` — v1's only list-shaped selection list — flips replace→union, which is the capability-WIDENING direction (v1: project `[b]` over global `[a]` = `[b]`; v2 default = `[a,b]`, and allow_risky is a denylist-BYPASS grant). Mitigations: declared-v1 files abort loud (forced migration awareness); a version-ABSENT file containing `mounts.allow_risky` aborts loud demanding an explicit version declaration (D3); `!replace` restores narrowing. Live incidence at flip time: zero (the global `allow_risky` is null).

**Vocabulary-migration note** (for readers arriving from ADR-022, ADR-025, or older docs that cite "additive_list per ADR-021 D2"): v1 `additive_list` ≙ v2 union-default list — those citations read correctly under v2 (ADR-025's `dcg.packs` / `dcg.custom_rule_paths` remain union-default; no semantic change). v1 `selection_list` split by shape: the list-shaped member (`mounts.allow_risky`) became union-default (see honest cost above); the enum-scalar members became type `enum` with unchanged replace semantics.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Keep v1 per-field-type merge declarations | `direct:` the "only universal earns global" placement rule (configure-cage SKILL.md taxonomy section) is the operational evidence the model failed — narrowing intent had nowhere to live, so global slots went unused. |
| Docker compose's two-tag set `!override` + `!reset` | `external:`+`reasoned:` compose is the prior art for tagged merge control, but one tag + empty list covers both operations; fewer concepts. |
| Schema-split `_extra`/`_only` field pairs | `reasoned:` v1 D2's own named invalidation path — works but doubles field count, and the override is invisible at point of use (you must know the schema to read the file). |
| Magic sibling keys (`_replace: true`) | `reasoned:` least legible; already rejected in v1 D2's Alternatives. |

**What would invalidate this:** operators demonstrably needing per-ELEMENT merge control (replace one inherited item, keep the rest) — a per-field tag cannot express it. Revisit with a finer mechanism then; do not reach for magic sibling keys.

**Invalidation check (mechanical, runnable in the loader's test suite):** the v2 matrix in `tests/test-config-loader.sh` — union default across the stack; `!replace` at global layer replaces the schema default; `!replace` at project layer replaces default+global; `!replace []` zero-out; `!replace` on `mounts.denylist` aborts naming ADR-023 D2; unknown tag / tag-on-non-list / tag-on-undeclared-path abort naming the exact path.

### D3: Schema versioning — supported set `{2}`; absent assumes 2 with loud warn; declared 1 aborts; higher aborts iff the file uses `!replace`

**Firmness: FIRM** (revised 2026-07-14, rip-cage-tsf2.10 — v1's field-type-conditional rule replaced with the tag-conditional rule; FIRM mutation human-signed-off + 3-round design review)

Each file independently declares `version: <integer>` at the top level. The loader's supported set is **`{2}`**.

| Condition | Behavior |
|---|---|
| `version` absent | Assume `version: 2`; warn loud once per invocation per file (no persisted "already warned" state): `'<file>' has no 'version:' field; assuming version 2. Add 'version: 2' to silence.` **EXCEPTION:** a version-absent file containing `mounts.allow_risky` **aborts loud demanding an explicit version declaration** — the single field whose v1→v2 semantic flip is capability-widening (D2 honest-cost note) must never be reinterpreted silently. |
| `version: 2` | Load normally. |
| `version: 1` | **LOUD ABORT** with an actionable migration hint. Never reinterpret (v1 selection-list files — `mounts.allow_risky` — would silently change meaning under v2 union rules); never silently skip (a skipped project file strands the cage without its hosts — silent capability loss the operator has no cue to notice). |
| `version` higher than supported | **Abort loud iff the file contains any `!replace`** (dropping a file whose narrowing intent is expressed by tags is the capability-EXPANDING failure direction); else warn loud + skip that file's contents (load defaults / other layer only). |

**Per-file independence** (unchanged from v1): both files declare their own version; a mixed pair is evaluated file-by-file under the table above.

**Warn-once-per-invocation semantics** (unchanged): no persisted suppression — each invocation re-warns until the field is added.

**Why the tag-conditional rule (translation of v1's failure-direction analysis).** v1 keyed the higher-version abort on selection-list field presence because selection lists were where narrowing intent lived; silent skip there = silent capability expansion (ADR-001's "user believes they have the firewall" failure mode). Under v2 the narrowing construct is the `!replace` tag, so the abort predicate follows it: higher-version file with `!replace` ⇒ abort; without ⇒ warn+skip (capability degradation in the safer direction; the team-coordination case — one teammate on a newer rc — still works for union-only files). The v1 selection-list partial-parse machinery and its fixtures are retired/re-authored; the higher-version classify is one tag-enumeration pass (`yq '[.. | select(tag | test("^![^!]"))]'` — mikefarah yq v4, verified 2026-07-14).

**Counter-argument to v1 D3's terms (FIRM-mutation warrant):** v1's rule was correct in direction but keyed to a schema-type vocabulary that D2 retires; keeping it would leave the abort predicate referencing a field class that no longer exists. The failure-direction analysis is preserved verbatim under translation. Two genuinely new elements carry their own warrant: (a) declared-v1 abort — a real v1→v2 migration now exists where soft-loading IS harmful (`mounts.allow_risky` changes meaning), which is exactly the invalidation trigger v1 D3 named for revisiting its soft-default posture; (b) the version-absent + `allow_risky` abort closes the silent-reinterpretation hole that the assume-2 default would otherwise open for exactly that field.

**Ergonomic ramp preserved:** absent ⇒ assume-current + warn survives (v1 D3's "absent-version aborts" rejected alternative STAYS rejected); the abort exception is scoped to the one dangerous field.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Reinterpret declared-v1 files under v2 rules (no abort) | `direct:` `mounts.allow_risky` semantics flip replace→union — silent capability widening on a denylist-bypass grant. |
| Compat shim for v1 files | `reasoned:` exactly two live v1 files exist (both migrated by hand in the same change, D9); adoption is near-zero; shim machinery is permanent dead weight for a one-time hand edit. |
| Absent-version aborts (force declaration) | `reasoned:` v1 D3's rejected alternative stays rejected — friction tax on minimal/new files; the `allow_risky` exception closes the one case where assume-2 is dangerous. |
| Higher-version: keep blanket warn+skip (v1's pre-resolution draft) | `reasoned:` silently drops `!replace` narrowing intent — the capability-expanding failure direction v1's own resolution refused. |

**What would invalidate this:** a future v3 schema change whose dangerous-reinterpretation surface is NOT expressible by tag presence (e.g. a scalar whose meaning inverts) — at that point the abort predicate needs a field-keyed exception table again, added alongside the tag rule.

**Invalidation check (mechanical, runnable in the loader's test suite):** fixtures — (a) higher-version file WITH `!replace` ⇒ non-zero exit naming the file; (b) higher-version file without tags ⇒ exit 0, warning, contents skipped; (c) declared `version: 1` ⇒ non-zero exit with migration hint; (d) version-absent ⇒ loads with per-invocation warning; (e) version-absent WITH `mounts.allow_risky` ⇒ non-zero exit demanding a version declaration.

### D4: Unified effective view — one loader contract, four provenance sources (revised 2026-07-14, rip-cage-tsf2.10)

**Firmness: FIRM**

`rc config show` (and `rc config show --json`) prints the effective merged config. Each leaf field is annotated with provenance — where the value came from (`global`, `project`, `default`, `union(global,project)` for union lists, or `manifest:<tool>` for tool-manifest-declared egress).

**Four provenance sources (v2 extension).** The loader JSON contract `{config, provenance, layers, sha256}` is extended with the image manifest as a fourth provenance source: tool-declared egress hosts (each baked TOOL entry's `egress:` list in `tools.yaml`) are annotated `manifest:<tool>`, so "what can this cage reach and WHY" is one command.

- **Field placement:** manifest-derived hosts live in a SEPARATE contract field (`manifest_egress`, with per-tool attribution) — **never folded into `.config.network.allowed_hosts`**. `rc reload`'s eligibility diff runs on `.config` only, so a manifest egress change can never surface as spurious config drift; the view/dry-run reports a manifest-vs-applied delta as **"requires rebuild"** (its real remedy: edit the manifest + `rc build` + recreate), distinct from reload-eligible config drift.
- **RUNTIME INVARIANT (binding on every implementation of this contract):** the msb rule materialization at cage create and `rc reload` remains `.config.network.allowed_hosts ∪ manifest_egress` — the contract split changes VIEW/provenance/drift accounting only; baked tools keep their egress reachability (the tsf2.8 runtime union is unchanged).
- **Source of truth per consumer** (the same dual-source pattern the multiplexer registry uses to close the validate-passes/runtime-fails hole): for a TARGET CAGE, "what can this cage reach" reads the cage's APPLIED state — the applied record written at create/reload: the config snapshot (`config-applied.json`) plus a SIBLING manifest-egress record (`manifest-egress-applied.json`; kept separate deliberately so `config-applied.json`'s top-level-config shape stays byte-stable and the reload/converge diff stays `.config`-only structurally) — never the current host `tools.yaml`, which may have drifted since the image was built. With no cage in scope (pre-create view), the host manifest is read and labeled pending/unbaked.
- **All effective-config consumers converge on this one contract:** `rc config show`, `rc allowlist show --effective`, `rc doctor`'s fix-hint, `rc reload`'s drift diff/dry-run. Nobody re-derives the merge.
- **Named residual (consequence of D2's dissolved placement rule):** manifest-declared tool egress remains an additive, un-narrowable source — a baked tool's `egress:` hosts travel with the tool; the only removal path is removing the tool from the manifest + rebuild. This residual is honestly surfaced in the provenance view, not dissolved.

YAML-with-comments output for human reading:

```
$ rc config show
version: 2                        # from default
network:
  allowed_hosts:                  # union(global, project)
    - api.anthropic.com           # from global
    - chatgpt.com                 # from project
# manifest egress (requires rebuild to change):
#   docs.astral.sh                # manifest:uv
```

For nested-map fields and lists-of-maps (plausible v1+ schema growth: `egress.rules: [{host, port}]`, `dcg.rules: [{pattern, action}]`), provenance is annotated **at the field level** (one comment per containing key, naming the source layers) rather than per-element. Per-element provenance for nested structures is deferred to the loader bead (`rip-cage-o4z`) to specify; the substrate ADR commits only to field-level provenance for nested types.

JSON output (`--json`) embeds provenance as a parallel structure for machine consumers:

```json
{
  "config": { "version": 2, "network": { "allowed_hosts": ["api.anthropic.com", "chatgpt.com"] } },
  "provenance": {
    "version": "default",
    "network.allowed_hosts": ["global", "project"]
  },
  "manifest_egress": { "uv": ["docs.astral.sh"] }
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

**Invalidation check (mechanical, runnable in the loader's test suite):** With both files present and a union-list field that has values in each, `rc config show --json | jq '.provenance["network.allowed_hosts"]'` must return an array containing both `"global"` and `"project"`. With a baked tool declaring egress, `manifest_egress` carries the host under the tool's name AND `.config.network.allowed_hosts` does NOT contain it (unless independently configured); the generated msb argv contains `--net-rule allow@<host>` for it regardless (the runtime-invariant effect probe).

### D4a: `mounts.symlinks.*` field group — host-side symlink follow (added in rip-cage-c1p.2)

**Firmness: FIRM** (inherited from D1-D3 schema framework)

Three enum fields (v1 type name: selection_list) for controlling how absolute symlinks in rip-cage-managed dotfile mount roots are resolved at `rc up` time:

| Field | Type | Default | Allowed values |
|---|---|---|---|
| `mounts.symlinks.on_dangling` | enum | `"follow"` | `follow`, `warn`, `skip`, `error` |
| `mounts.symlinks.scope` | enum | `"file"` | `file`, `parent` |
| `mounts.symlinks.mode` | enum | `"rw"` | `ro`, `rw` |

**Merge semantics:** per D2 enum rule (project replaces global if present; absent = inherit global or use default). Each field is a single-value enum scalar: unknown values abort loud per D2 validation.

**Schema version:** 2 (rip-cage-tsf2.10 bump; these fields carry over semantically unchanged). Unknown enum values abort loud via the enum validation path (D2). Future new `on_dangling` or `scope` values that break backward compatibility require a version bump.

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

### D6: `session.multiplexer` field — in-cage multiplexer selection (added 2026-06-13, rip-cage-1f59; revised 2026-06-15, rip-cage-61al — allowed-set is manifest-derived, not a fixed enum)

**Firmness: FIRM** (inherited from D1-D3 schema framework)

One enum field (v1 type name: selection_list) selecting which terminal multiplexer the cage runs inside, or none:

| Field | Type | Default | Allowed values |
|---|---|---|---|
| `session.multiplexer` | enum | `"none"` | `none` + any manifest-declared multiplexer provider (validated against the baked registry, **not** a fixed `tmux`/`herdr` enum) |

**Allowed-set is open and substrate-derived (revised 2026-06-15, rip-cage-61al):** the valid values are `none` plus whatever multiplexer providers the tool manifest declares and `rc build` bakes into the image (read host-side from the `rc.multiplexers` image label, with a pre-build fallback to the manifest's MULTIPLEXER entries). A selected-but-not-baked name fails loud at config-validate, naming the fix (`add the provider to your manifest and rc build`). Adding a multiplexer (e.g. `zellij`) is a manifest entry with **zero `rc` edits** — `tmux` and `herdr` are no longer special-cased in `rc` source; they ship as `examples/` provider definitions (ADR-005 D12 consequence 2).

**Merge semantics:** per D2 enum rule (project replaces global if present; absent ⇒ inherit global or use default). Single-value enum scalar: an unknown value (not `none`, not in the baked registry) aborts loud per D2's enum validation (same path as D4a's `mounts.symlinks.*`), but the *accepted* set is derived dynamically, not hardcoded.

**Schema version:** 2 (rip-cage-tsf2.10 bump; field carries over semantically unchanged). Unknown enum values abort loud via the enum validation path (D2). A future multiplexer needing sub-keys (not a bare enum value) would grow this into a field group like `mounts.symlinks.*` (D4a) and may require a version bump.

**Rationale:** makes the in-cage multiplexer a swappable composed component rather than a hardcoded coupling — the config-layer expression of ADR-006 D7's re-decision (the multiplexer owns session orchestration; rip-cage owns the box) and the process-layer sibling of the pluggable egress mediator (ADR-026) and tool manifest (ADR-005 D11). Default `none` = normal terminal semantics, imposing no surprising persistence on newcomers (ADR-009 D1); persistence + the supervisor view are opt-in by choosing a multiplexer provider (e.g. the `examples/tmux` or `examples/herdr` providers).

**Why the allowed-set evolved from a literal enum (revised 2026-06-15):** the original `none, tmux, herdr` listing was a 2026-06-13 snapshot of the then-available multiplexers, and it *contradicted this decision's own rationale* — D6 declares the multiplexer "a swappable composed component rather than a hardcoded coupling," yet a literal three-value enum hardcodes exactly the set it claims is swappable. ADR-005 D12 (FIRM) since made the composable-seam principle explicit: `rc` source must never name a specific optional tool, and adding a multiplexer is a manifest entry with zero `rc` edits. Deriving the allowed-set from the baked registry *completes* D6's stated intent rather than reversing it; the firmness stays FIRM because the open-substrate-derived set is the composable-seam invariant at the config layer, not a loosening of validation (an unbaked name still fails loud).

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Keep tmux hardcoded (no field) | `reasoned:` the coupling rip-cage-1f59 removes; welds one multiplexer into the box and forces tmux as a hard Homebrew dependency |
| Default `tmux` (batteries-included persistence) | `reasoned:` imposes "survives window close" semantics on users who expect plain Claude Code (documented confusion); persistence should be opt-in, not the surprising default |
| Keep the literal `none, tmux, herdr` enum (validate against a fixed known set) | `reasoned:` contradicts D6's own swappable-component rationale and ADR-005 D12 (FIRM composable seam); forces an `rc`-source edit per new multiplexer; the set is now derived from the manifest/baked registry (rip-cage-61al) |

**What would invalidate this:** (a) a multiplexer whose configuration cannot be expressed as a single enum value (needs per-multiplexer sub-keys) — then this grows into a field group (D4a shape); it is not abandoned. (b) A validated need to constrain the selectable set *below* "whatever the manifest bakes" — that would reintroduce a list, but derived from policy, not from hardcoded tool names in `rc`.

### D7: `.rip-cage.yaml` is read-only inside the cage by default; write-access is opt-in

**Firmness: FLEXIBLE**

The project `.rip-cage.yaml` is mounted **read-only** into the cage by default. An in-cage agent cannot modify the cage's own posture manifest. Write-access is an explicit opt-in via `mounts.config_mode` (enum scalar; default `"ro"`, allowed values `ro`, `rw`), authored **host-side**.

**Mechanism.** `.rip-cage.yaml` is writable in-cage today only as a side effect of riding the `/workspace` rw bind-mount — there is no dedicated config mount. Ro-by-default is implemented by a nested read-only bind-mount shadowing the single path: a more-specific `-v <workspace>/.rip-cage.yaml:/workspace/.rip-cage.yaml:ro` layered over the rw workspace mount. Host content still shows through (the file is not a copy); the host can still edit it; the in-cage agent cannot write through the ro mount, and cannot unlink or rename a live mount target. Scope is the **project file at the workspace root only** — the global `~/.config/rip-cage/config.yaml` is not mounted into the cage and is unaffected by this decision.

**Boundary — absent config.** If no `.rip-cage.yaml` exists at `rc up` time there is nothing to shadow-mount, and an agent may author one via the rw workspace mount. This is acceptable: the threat below is silently *modifying* an existing, human-trusted config; a from-scratch file is still surfaced to the human *wholesale* at the apply step (`rc reload` / next `rc up`), where there is no pre-existing trusted content for a malicious line to hide behind.

**Rationale.** Per ADR-024 the threat model covers a prompt-injected in-cage agent following hostile instructions. `.rip-cage.yaml` is the cage's own control-plane file — it declares egress allowlist, ssh hosts, and risky-mount exceptions. Left writable in-cage, a hijacked agent can *bury* a containment-weakening line (an extra `egress.allow` host, an `ssh.allowed_hosts` entry, a `mounts.allow_risky` path) inside an otherwise-legitimate edit, then ask the human to `rc reload` / `rc up` — and a human running a routine reload rubber-stamps the buried line without diffing the whole file. Ro-by-default removes the silent-staging vector entirely: the human (or a host-side assistant the human relays to) authors the change, so there are no hidden lines to approve. Autonomy is preserved because the human was *already* the approval step (`rc` is not on the cage PATH; the agent cannot `rc reload`/`rc up` itself per ADR-022 D6) — the only thing that changes is *who types the YAML*, not whether a human is in the loop. This is the config-file application of the per-asset `ro`-default / `rw`-opt-in pattern ADR-027 D1 established for agent substrate; host-side adversaries remain explicitly out of scope.

**Reconciliation with the self-service flows (edited in place).** Two prior FLEXIBLE decisions instructed the in-cage agent to edit `.rip-cage.yaml` directly; both are evolved in place by this decision:
- **ADR-022 D6** (ssh.allowed_hosts + `rc reload`) — the "agent edits `.rip-cage.yaml` (writable inside), human reloads" flow.
- **ADR-023 D3** (mounts.allow_risky before next `rc up`) — the "agent writes `mounts.allow_risky` entries" flow.

Under ro-default these become: the agent **surfaces the request in prose**; the human — or a host-side assistant the human relays to — authors the edit host-side, then runs `rc reload` / `rc up`. The `rc allowlist add` in-cage refusal message (which today redirects the agent to edit the file) is updated to point at host-side authorship. Under `mounts.config_mode: rw` the original in-cage self-edit flows remain available unchanged.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Fork B — keep `.rip-cage.yaml` writable in-cage, add a diff-and-confirm step to `rc reload`/`rc up` | `reasoned:` Only defends if the human actually reads the diff; a line buried in a large diff survives a skimming human. ADR-024's threat is specifically the buried/injected edit, and only author-side authorship *structurally* prevents hidden lines. Fork B is worthwhile complementary defense-in-depth (informs the human at the gate) but is not a substitute; tracked as a separate follow-up, not this decision. |
| Keep writable (status quo) | `direct:` Leaves the silent-staging vector open — the exact rubber-stamp gap this decision closes. The "writable but inert until reload" property (ADR-022 D6, ADR-023 D3) defangs *auto-apply* but not the buried-line-approved-on-reload path. |
| Make the whole `/workspace` mount read-only | `direct:` Over-broad — breaks the agent's legitimate code edits, which are the product (CLAUDE.md "agent autonomy is the product"). The shadow-mount scopes ro to the one control-plane file. |
| One-shot CLI flag (`--config-rw`) instead of a config field | `reasoned:` One-shot, untracked, undiscoverable — ADR-021 D1's own rationale rejects CLI flags for persistent per-project posture. `mounts.config_mode` lives in the tracked substrate and merges per D2 (enum: project replaces global if present). |

**What would invalidate this:** host-side-authorship friction shows up as the "just turn it off" signal (CLAUDE.md) — users setting `mounts.config_mode: rw` across many projects, or repeatedly filing the friction. That means the default polarity is wrong; flip to writable-by-default and add Fork B's diff-confirm at the host gate. Mirror trigger: a new legitimate in-cage config-write workflow emerges that genuinely cannot route through host-side authorship.

**Invalidation check (mechanical, runnable post-implementation):** With default config (`mounts.config_mode` absent or `ro`), an in-cage `test -w /workspace/.rip-cage.yaml` returns non-zero and `echo x >> /workspace/.rip-cage.yaml` fails — while a host-side edit + `rc reload` still applies the change. With `mounts.config_mode: rw` in effect, the in-cage write succeeds. Both `.rip-cage.yaml`-absent and `.rip-cage.yaml`-present-ro cases are covered.

### D8: Host-side write verbs — `rc config set/add/remove --scope global|project`; surgical edits; verbs are sugar, files stay truth (added 2026-07-14, rip-cage-tsf2.10)

**Firmness: FIRM**

New verbs: `rc config set <key> <value> --scope global|project`, `rc config add <key> <item> --scope ...`, `rc config remove <key> <item> --scope ...`. `rc allowlist add` becomes sugar over `rc config add network.allowed_hosts`. Storage stays in the two posture files (D1); the verbs route intent to the right home so the file taxonomy stops being prerequisite knowledge.

- **Threat model unchanged (ADR-024, D7):** verbs are host-side only, not on the cage PATH; the project file stays ro in-cage; there is no in-cage self-grant path.
- **Edit mechanics: SURGICAL textual line edits.** `yq` locates the key/anchor line; the edit inserts/removes/sets the minimal text; then a full loader parse re-validates the result. On validation failure the original file is restored byte-identical and the verb refuses, telling the operator to edit the file. **`yq` re-emit (`yq expr > tmp; cp`) is FORBIDDEN as a write path** — empirically shown (2026-07-14, yq 4.53.3) to drop blank lines, normalize comment spacing, and relocate free-standing comments; the live config files carry load-bearing comment prose.
- **Comment-preservation contract:** `set` on a scalar edits only the VALUE TOKEN and preserves any trailing same-line `#` comment. `add` on an inline empty/flow list (`key: []` — the shape `rc allowlist add` itself creates) performs exactly one defined structural transform: rewrite that single line to block-sequence form with the new item. No other multi-line transforms exist.
- **Verb/tag interaction:** verbs never ADD or REMOVE a `!replace` tag (tag placement is a hand edit — refuse with "edit the file"); `add`/`remove` on an already-tagged list preserve the tag and edit that layer's items (well-defined under D2's fold-left). Verbs that CREATE an absent file write `version: 2`.
- **Deliberately narrow surface:** add/remove a list entry, set a scalar/enum. Anything structural (nested maps, `auth.credentials` entries, tag placement) → the verb refuses with "edit the file." A verbs interface that destroys comments is worse than files.

**Rationale:** DEBT 2 of the redesign — the interface was files-over-verbs; the operator had to know WHICH of three files answers which question. Generalizing the `rc allowlist add` pattern (verb + scope, system routes storage) removes the taxonomy prerequisite without centralizing the files themselves (the KEEP constraint: centralize the VIEW and the VERBS, never the project-config file).

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| `yq` re-emit as the write engine (simplest implementation) | `direct:` empirical spike (2026-07-14, yq 4.53.3): drops blank lines, normalizes comment spacing, relocates free-standing comments — the live global config's load-bearing comment prose would be destroyed on first verb use. |
| Full-surface verbs (nested maps, credentials, tag placement) | `reasoned:` every additional structural transform is a comment-destruction risk; the narrow surface covers the high-frequency operations, and "edit the file" remains first-class for the rest. |
| Centralize storage (mem-style single home) instead of verbs | `reasoned:` rejected at the design KEEP layer — the in-repo tracked, PR-reviewed, ro-in-cage project file is load-bearing (D1/D7); verbs give the ergonomics without losing the substrate. |

**What would invalidate this:** operators routinely needing a structural edit the verbs refuse (the refusal message becomes a friction wall) — grow the one specific transform with its own defined+tested shape, or accept the hand edit; never widen to re-emit.

**Invalidation check (mechanical):** verb tests on a fixture carrying free-standing comment blocks AND same-line trailing comments AND an inline `[]` list — each verb's diff changes only the intended value tokens / the one defined `[]`-to-block transform, all comment bytes preserved; post-edit validation failure restores byte-identical (cmp) and exits non-zero.

### D9: Migration — no shim; supported set jumps to `{2}`; ALL config-schema version-1 emitters flip in the same change; vestigial fields dropped in the same break (added 2026-07-14, rip-cage-tsf2.10)

**Firmness: FIRM**

- **v1 FILES:** loud abort + actionable migration hint (D3; rationale there).
- **v1 GENERATORS (the bootstrap-critical part):** `version: 1` is emitted by CODE, not just the two live files. Every generator flips to `version: 2` in the same change: `_config_default_global_yaml` (the auto-seed template `rc up` writes on fresh installs BEFORE validation runs), `cmd_install`'s seed, `rc allowlist add`'s absent-file create. Enumeration is scoped to the CONFIG-SCHEMA namespace (`config.yaml` / `.rip-cage.yaml` emitters) only: the tool manifest (`tools.yaml`) carries its OWN independent `version:` namespace with its own validator and is explicitly UNTOUCHED — its emitters legitimately keep their own version 1. Fresh-install bootstrap (`rm` global config → `rc up`) must succeed and seed a v2 config file.
- **Live files:** the two known real configs (the maintainer machine's global + this repo's project file) use no replace-semantics fields; migration is `version: 1` → `version: 2` in two files, hand-applied in the same change, preserving every comment byte. No shim machinery.
- **Same-break cleanup — vestigial fields dropped in the 1→2 bump:** `network.mode`, `network.dns.forward_to`, `network.http.forward_to` (all parse-compat-only/dead post-msb-cutover, ADR-029) are removed from the schema and join the retired-fields loud-reject table (ADR cite + fix hint — same treatment as the retired ssh/mediator fields; not silent unknown-field drop). Code consumers cleaned in the same change: `rc ls`'s `network.mode` read and the reload-eligible path list (becomes `network.allowed_hosts` only).

**Rationale:** adoption is near-zero (post-msb-cutover, two live files, both ours) — a breaking bump with hand migration is strictly cheaper NOW than shim machinery that would have to live forever. Bundling the vestigial-field removal into the same version break avoids a second breaking bump later.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Compat shim (v1 files load with translation) | `reasoned:` two live files, zero external adoption; permanent machinery for a one-time hand edit. |
| Support set `{1,2}` (dual-version loader) | `direct:` `mounts.allow_risky` means the same YAML has different semantics per version — a dual loader doubles every merge test and keeps the v1 machinery alive; D3 chose abort-with-hint instead. |
| Keep vestigial fields as parse-compat no-ops | `reasoned:` a validator that accepts a field the runtime never executes is a hollow contract (documented failure shape); the retired-fields table is loud + actionable. |

**What would invalidate this:** evidence of external v1 adoption (a real user's config aborting) — the migration hint must be sufficient for self-service; if it demonstrably isn't, revisit with a targeted translation for the reported shape, not a general shim.

**Invalidation check (mechanical):** with no global config present, `rc up`'s seed path succeeds and the seeded file declares `version: 2`; a grep scoped to config-schema emitters finds no `version: 1` literal; the manifest namespace's own emitters still carry their version 1.

### D10: Profiles/extends — CUT from v2; revisit trigger recorded (added 2026-07-14, rip-cage-tsf2.10; resolves the redesign's exploratory item)

**Firmness: FIRM**

No `extends:` / `include:` / profile mechanism ships in v2.

**Rationale:** D2 removes most of the pressure — global slots are now safe for shared defaults since projects can narrow via `!replace`. An extends mechanism sits directly on ADR-005 D12's design tripwire (include-mechanism / config-merge machinery — automating the wiring that is the agent's compositional judgment). With near-zero adoption there is no operator data duplication to dedupe yet. Adding extends later is a backward-compatible schema addition — deferral costs nothing, while the merge semantics (D2) are breaking and had to land now.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Operator-authored profile files a project could `extends:` | `reasoned:` judged against ADR-005 D12's tripwire — today it automates wiring judgment rather than deduplicating real operator data (none exists yet); rc-SHIPPED profile libraries are categorically out under D12. |
| Named posture presets shipped by rc ("walk-away cage") | `direct:` ADR-005 D12 (FIRM) — rc never blesses/bundles tool or posture content; the walk-away cage remains a prose recipe in `examples/`. |

**What would invalidate this (the recorded revisit trigger):** operators demonstrably copy-pasting config blocks across projects — real duplicated data is the signal that an operator-authored extends deduplicates rather than automates judgment; bring it back through ADR-005 D12 review at that point.

**Invalidation check:** none mechanical — the trigger is observational (watch for repeated config-block copy-paste surfacing in configure-cage sessions or operator reports).

## Consequences

**Positive:**
- Per-project cage posture is a tracked, diff-able, auditable artifact at the workspace root — visible in PR reviews, in `git log`, and to teammates / future agents.
- Self-service loop with the human as the approval step (D7/D8): the in-cage agent surfaces the request in prose; the human (or host-side assistant) applies it via `rc config add/set` or a hand edit, then `rc reload` / `rc up --reload`. No hidden env var.
- Global file collapses repeated user preferences to one place across all projects.
- The substrate unblocks downstream work (egress overrides, skill mount opt-outs, resource limits, dcg policy — ADR-025) without each consumer re-inventing config plumbing.
- `rc config show` makes the merge model inspectable, so the merge rules don't become a debugging trap.
- D5's regression contract means existing users see no posture change on upgrade.
- **The "only universal earns global" placement rule DISSOLVES for the two posture layers (v2, D2):** a project can now narrow an inherited list explicitly via `!replace`, so shared defaults are safe in global slots. **NAMED RESIDUAL:** manifest-declared tool egress (the tsf2.8 runtime union) remains an additive, un-narrowable source — a baked tool's `egress:` hosts travel with the tool; the only removal path is removing the tool from the manifest + rebuild. The residual is honestly surfaced in the provenance view (D4), visible, not dissolved.

**Negative:**
- New surface area: one schema, one loader, the `rc config` subcommand family (`show`/`get`/`set`/`add`/`remove`), one new convention file at every project root that opts in.
- Schema versioning means schema evolution requires deliberate version bumps. (Also positive — see D3 rationale.)
- **The 1→2 bump is a breaking change:** declared-v1 files abort loud until hand-migrated (D3/D9). Accepted deliberately while adoption is near-zero — the abort carries an actionable migration hint.
- YAML adds a parser dependency surface (see Implementation notes for `yq` pinning).
- D3's tag-conditional higher-version rule adds loader complexity (a one-pass tag enumeration of unknown-version files). Bounded — one `yq` expression.
- Two layers means `rc config show` is part of the debugging vocabulary; users who don't know it exists will be confused by merged behavior. Mitigation: D5's first-run hint surfaces it.

**Neutral:**
- Loader adds host-side cost on every `rc up` (parse two YAML files, merge, write effective config). Cost: ~50ms with `yq`, well below `docker start`.
- The asymmetry between global path (`~/.config/rip-cage/config.yaml`) and project path (`.rip-cage.yaml`) requires a one-line explanation in docs.

## Implementation notes

- **Schema definition** lives in the loader (a declarative table in `cli/lib/config.sh`). For each field: name, type (scalar / list / enum), default value, allowed values for enums. Schema is the single source of truth for merge behavior; lists all union by default, `!replace` is a per-file-per-field tag, not a schema property (D2).
- **Loader contract:** `_load_effective_config()` returns the merged config in a consumable form (JSON to stdout via `yq -o=json`, or as exported env vars for bash consumers — TBD in the loader bead).
- **`yq` dependency pinning:** Loader requires `yq` on host. If absent, `rc up` emits an actionable error per ADR-001: `Error: yq not found on PATH. Install yq (brew install yq, or the mikefarah/yq release binary on Linux — NOT apt's yq, which is the incompatible python-yq) to use .rip-cage.yaml. Run rc with no .rip-cage.yaml present to keep today's behavior.` Loader does NOT silently degrade to "skip config" on missing parser — that would silently nullify a user-authored capability scoping (the same failure class as D3's Option A).
- **`rc config show`:** new top-level subcommand. `rc config show` (YAML+comments), `rc config show --json` (JSON+provenance), `rc config show <key>` (single field, deferred bead).
- **Recreate vs resume (msb era):** msb net rules have no live-mutation path, so config changes to create-time state (`network.allowed_hosts`, `auth.credentials`) apply via cold-recreate — `rc reload` / `rc up --reload` (ADR-029 D4; reload-eligible set is `network.allowed_hosts` post-D9). The drift hint compares live config against the applied snapshot (`config-applied.json`) and names the applying command. Manifest-egress drift is "requires rebuild," never reload-drift (D4).
- **First-run hint:** when `rc up` loads a `.rip-cage.yaml` for the first time on a given container (detected via label `rc.config-loaded=<sha256>`), print `Loaded .rip-cage.yaml ([N fields applied]). Run 'rc config show' to inspect.` Subsequent `rc up` calls with the same content sha256 do not re-print.
- **Loader state location:** `rc.config-loaded=<sha256>` lives as a sandbox label (host-side, queryable via the msb sandbox metadata — the ADR-028 label substrate, re-bound off `docker inspect` per ADR-029), with the applied-config snapshot file (`config-applied.json`) as the primary drift-comparison record. "Skipped layer" diagnostics live in `rc config show` output (computed fresh each invocation), not in a sentinel — sentinel pattern from ADR-020 D5 is reserved for state that needs to be readable from inside the cage's first-shell echo.
- **Schema version field:** the loader applies D3's rules **before** attempting to merge. For an unknown HIGHER version, the classify is one tag-enumeration pass (`yq '[.. | select(tag | test("^![^!]")) | {"path": path|join("."), "tag": tag}]'`): any `!replace` present → abort loud naming the file; else → warn and skip the file's contents. Declared `version: 1` → abort with migration hint before any parse-for-merge. Provenance for skipped files is recorded so `rc config show` can surface "this layer was skipped due to version mismatch" rather than silently omitting it. The tag-map pass also runs on supported-version files to drive D2 validation (`yq -o=json` strips custom tags, so the map is captured before the JSON conversion; the yq→JSON→jq merge engine is preserved).
- **Test fixtures:** `tests/fixtures/config-*.yaml` covering the v2 matrix in D2 (union default, `!replace` at each layer, `!replace []`, denylist replace-forbidden, tag validation), plus D3 (missing version, declared v1, higher-version ± `!replace`, version-absent-with-allow_risky) and D5 (both absent posture-unchanged check).
- **Docs:** reference page at `docs/reference/config.md`. README gets a one-paragraph mention with link.
- **Downstream consumer template:** each consumer bead must include (a) the schema fields it owns + their types, (b) a "both files absent → posture unchanged" regression test (D5 contract), (c) a "global + project both contribute" integration test that validates the merge rule for that consumer's fields, (d) explicit declaration of which fields are recreate-required vs resume-applicable.

## Carries over from prior ADRs

- **ADR-001** fail-loud-and-actionable applies to schema validation errors (unknown tags, retired fields, enum violations) and to consumer-level errors. Its application to D3's version-drift behavior is **tag-conditional** (v2 translation of the v1 field-type-conditional rule): a higher-version file using `!replace` triggers fail-loud-abort (silent skip would silently expand capability past user intent — ADR-001:13 failure mode); tag-free files warn-and-skip (silent skip yields LESS capability, not more — ADR-001's failure direction is inverted). Declared-v1 files abort unconditionally (D3/D9).
- **ADR-014 D2** (non-interactive SSH posture) is **not modified by this substrate**. The downstream `rip-cage-b0c` (SSH allowlist) bead will edit ADR-014 D2 in place per the in-place-evolution convention when shipped, replacing the `known_hosts` rewrite with capability-scoped allowlists. ADR-014 D2's caveat at line 79 (CLI `-o` reach limit) remains accurate as-stated for the default container.
- **ADR-020** (ssh identity routing) coexists. Identity routing remains keyed by `~/.config/rip-cage/identity-rules` and CLI flags / labels; the SSH allowlist enabled by this substrate is orthogonal (one is "which key for which github account?", the other is "which hosts and keys can the cage reach at all?"). Both share the `~/.config/rip-cage/` namespace by D1.
- **ADR-017** (ssh-agent forwarding) is the capability that the SSH allowlist consumer scopes. This substrate is what makes per-project scoping expressible.

## canonical_refs

- `docs/decisions/ADR-024-prompt-injection-threat-model.md` — D7's threat warrant: the prompt-injected in-cage agent that buries a containment-weakening edit for a human to rubber-stamp on reload.
- `docs/decisions/ADR-027-agent-substrate-projection.md` — D1's per-asset `ro`-default / `rw`-opt-in mount pattern that D7 applies to the config file (agent config/substrate is a distinct asset class; D7 governs rip-cage's own posture manifest).
- `docs/decisions/ADR-022-ssh-allowlist.md` — D6 (ssh.allowed_hosts self-edit + `rc reload`) evolved in place by D7: in-cage self-edit → host-side authorship under ro-default.
- `docs/decisions/ADR-023-secret-path-mount-denylist.md` — D3 (mounts.allow_risky self-edit before `rc up`) evolved in place by D7: same in-cage self-edit → host-side authorship change. ALSO: its D2 (FIRM additive-only denylist) is the warrant for this ADR's D2 replace-forbidden exception on `mounts.denylist` — honored, not evolved.
- `docs/decisions/ADR-005-ecosystem-tools.md` — D12 composable-seam guardrail: D10's profiles cut is judged against its tripwire; the D8 verbs and D2 merge mechanics are config MECHANICS (rc's legitimate invariant seam), not tool/posture content.
- `docs/decisions/ADR-029-msb-migration.md` — D2/D4 egress model the D4 effective view spans; the msb runtime union (`--net-default deny` + `--net-rule`) is the materialization target of the D4 runtime invariant; the D9 vestigial fields died with its cutover.
- `docs/decisions/ADR-025-host-adoptable-dcg-policy.md` — cites v1 vocabulary ("additive_list per ADR-021 D2"); reads correctly under the D2 vocabulary-migration note (dcg lists remain union-default); not edited.
- `rip-cage-tsf2.10` (bead) — the converged config-model-v2 design this revision projects; carries the full review trail and spike record.
