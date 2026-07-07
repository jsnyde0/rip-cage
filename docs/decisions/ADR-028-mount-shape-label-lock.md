# ADR-028: Mount-Shape Label-Lock Pattern

**Status:** Accepted — pattern promoted 2026-07-07 (`rip-cage-izi2`) from four shipped instances; rule-of-three exceeded

**Firmness:** per-decision, see each Dn

## Context

Docker bind mounts are immutable after `docker create`. Several rip-cage config fields decide *mount shape* — which mounts exist, their mode, or their content-set — at create time: `ssh.allowed_keys` (filter mount on/off), `mounts.symlinks.*` (the followed-symlink mount set), `mounts.config_mode` (`ro`/`rw` shadow-mount over `.rip-cage.yaml`), and `auth.credential_mounts` (+ per-tool overrides). When such a field changes between create and resume, the running container silently keeps its create-time shape while `rc config show` displays the new value — the cage's actual posture and its displayed posture diverge, and the divergence *fails open and quiet* (the most dangerous class per ADR-001).

Four independent guards shipped against this drift class, each cloning the previous one:

1. `rc.ssh-key-filter` (`rip-cage-jxy`, 2026-05-12; documented in ADR-022 implementation notes) — boolean on/off mount toggle.
2. `rc.symlink-follow-fingerprint` (`rip-cage-c1p.2`; ADR-021 D4a) — sha256 over the symlink mount set.
3. `rc.config-mode` (`rip-cage-cw51`, 2026-07-01; ADR-021 D7) — `ro`/`rw` present-vs-absent shadow-mount.
4. `rc.auth.credential-mounts` + per-tool `rc.auth.credential-mounts.{claude,pi}` (`rip-cage-xhgr`, 2026-07-04; ADR-026 D7) — per-tool credential-mount posture, with a legacy derivation ladder.

The recipe existed only as fragments (per-instance ADR notes + the `rip-cage-mount-shape-label-lock-pattern` bd memory). Per the rule-of-three promotion trigger, this ADR is the pattern's canonical home; the instance ADRs describe their instances and this ADR owns the recipe. Two hard-won coupling rules (D2, D3) and one deliberate non-instance sibling (D4) ride along.

## Decisions

### D1: The canonical label-lock recipe

**Firmness: FLEXIBLE** — the pattern is proven by four shipped instances, but its codification here is new; edits land in place. The underlying invariant (never silently re-mount on resume) is effectively load-bearing across all instances and a candidate for FIRM once this write has soaked.

Any config field whose value determines create-time mount shape gets a **label-lock guard**:

1. **Create-time label.** At `docker create`, persist the effective policy value as a container label `rc.<feature>` (boolean/enum instances) or `rc.<feature>-fingerprint=<sha256>` (set-valued instances: sha256 over sorted policy-header + structural-input lines).
2. **Resume-time compare — BOTH branches.** On `rc up` against an existing container, a `_up_resolve_resume_<feature>` resolver reads the label, recomputes the current effective value, and compares — on the **running-container branch AND the stopped-container branch**. Guards that check only one branch were the original bug shape.
3. **Abort loud, fixed message shape.** On mismatch, refuse with the established shape: `Container <name> was created with <label>=<stored> but current effective config has <field>=<current>. Mount shape is immutable on resume — run: rc destroy <name> && rc up <path> to apply the change.` JSON mode carries a stable error code (`<FEATURE>_MOUNT_SHAPE_CHANGED`). Never silently re-mount, never warn-and-proceed (ADR-001).
4. **Reload-ineligible by omission.** `rc reload` hot-reloads only fields listed in the `_RC_RELOAD_ELIGIBLE_PATHS` allowlist (content-only changes, e.g. `ssh.allowed_hosts` per ADR-022 D6). Mount-shape fields are guarded by *never adding them* — the allowlist-of-stable-zone shape, so a new guarded field is safe by default with zero reload-side edits.
5. **Backward-compat derivation ladder.** When a guard is added (or its grain refined, e.g. global → per-tool in instance 4), resume of a pre-guard container must not brick: derive the stored value as *specific label if present, else coarser/older label if present, else the historical default*. Upgrading `rc` never invalidates a running cage whose effective posture is unchanged.

**Rationale:** docker owns the mount table and offers no rebind; the honest contract is "mount shape is immutable per container generation." A create-time label is the cheapest durable record of the shape actually built; comparing at resume converts silent divergence into a loud, actionable refusal at the exact moment the operator can still choose (destroy-and-re-up vs keep the old shape). Four instances converged on this recipe independently enough that divergence risk now exceeds codification cost.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Evolve ADR-022 in place — promote its implementation-note guard to the canonical pattern decision (the ADR-008 D7 overlap scout's 4/5 recommendation) | `reasoned:` the overlap is with an *implementation note* documenting instance 1, not with ADR-022's decision space (SSH host/key allowlisting). The pattern is cross-cutting — instances live in ADR-021 D4a/D7 and ADR-026 D7 too; housing the recipe inside the SSH ADR makes three non-SSH ADRs depend on an SSH doc for a docker-lifecycle pattern. Scored honestly, overlap is moderate (2-3/5) → create-and-flag per D7 thresholds; the flag is discharged by this table + cross-refs. |
| Silently re-filter / re-mount on resume to match new config | `direct:` rejected in ADR-022 D6's alternatives — resume preserves labels, mutations are explicit; `rc reload` is the explicit mutate verb for content-eligible fields. |
| Warn-and-proceed on mismatch | `reasoned:` fails open — the operator's next 200 agent-turns run against a posture that contradicts displayed config; ADR-001 requires loud failure with remediation. |
| Denylist mount-shape fields from reload instead of allowlisting eligible ones | `direct:` bd memory `allowlist-stable-zone-over-denylist-of-growing-floor-set` — the guarded set grows with every instance; a denylist requires an edit-per-instance and fails open when forgotten. |
| Keep the recipe in the bd memory only (no ADR) | `reasoned:` the memory is agent-substrate, invisible to human contributors reading `docs/decisions/`; four instances plus two coupling rules exceed the rule-of-three promotion bar the memory itself documented. |

**What would invalidate this:** a docker/OCI runtime feature that makes bind-mount shape mutable on a stopped container (rebind at start) — the guard family would collapse into plain re-synthesis at resume; or a fifth instance that cannot express its policy as a label-comparable value (would force a generalization of the label encoding, evolving D1 in place).

### D2: Filter-the-fingerprint-too coupling (set-valued instances)

**Firmness: FLEXIBLE** (promoted from bd memory EXTENSION, `rip-cage-36u`, 2026-05-29)

When a filter/skip is added to a mount surface that carries a fingerprint-shape (set-valued) label, the **identical filter must be applied inside the fingerprint computation** — the fingerprint function re-scans the source set independently of the mount-synthesis loop, so an unduplicated filter desyncs drift detection from reality: a config change that newly skips a target produces no fingerprint change, and resume silently carries a now-denied mount (fails open and quiet).

Checklist when adding a filter to a fingerprinted surface: (1) is the fingerprint fn an independent re-scan or a reuse of the loop's result? (2) if independent, duplicate the filter into it; (3) thread any new filter input (e.g. the workspace path for `_check_secret_path_denylist`) through **every** fingerprint call site, including the empty-set/baseline site; (4) warn at the mount site only — the fingerprint site stays silent.

**Rationale:** `direct:` rip-cage-36u shipped exactly this desync and the fix required touching three fingerprint call sites.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Make the fingerprint reuse the mount-loop's filtered result | `reasoned:` the fingerprint must be computable on resume paths where the mount loop does not run (compare-only); an independent recompute is structural, so the coupling rule is the honest fix. |

**What would invalidate this:** refactoring the fingerprint to consume a single shared enumerate-and-filter helper (the D3 shape applied to set enumeration) — then the duplication rule dissolves into the shared-resolver rule.

### D3: Shared-resolver coupling (derived policy inputs)

**Firmness: FLEXIBLE** (promoted from bd memory EXTENSION 2, `rip-cage-xhgr`, 2026-07-04)

When a label-locked field's policy input stops being a raw config read and becomes a **derived effective value** (e.g. `effective(pi) = auth.per_tool.pi // auth.credential_mounts // "real"`), every computation site must call the **same named resolver function** — never re-derive inline. Before adding a second derivation source, grep every site currently inlining the derivation and factor a single resolver first.

**Rationale:** `direct:` in rip-cage-xhgr, the create-time site and the resume-side recompute each carried their own inline `jq` derivation; extending only one to the new per-tool logic would have silently reintroduced the create/resume asymmetry the label-lock exists to prevent (caught in design review round 2). The fix factored `_up_resolve_effective_credential_mounts_for_tool`, called from all three sites (create resolver, resume label-guard, resume fingerprint-recompute).

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Rely on review to keep parallel inline derivations in sync | `direct:` the xhgr R1 fold-in fixed create-time only; the asymmetry survived one full review round before R2 caught it. |

**What would invalidate this:** the config layer exposing pre-resolved effective values to all consumers (resolution moves wholesale into `_config_effective_*`), making per-feature resolvers redundant.

### D4: Label-free drift-detect sibling — NOT an instance

**Firmness: FLEXIBLE** (from bd memory EXTENSION 3, `rip-cage-jnvb`, 2026-07-05)

When docker already persists **both sides** of the comparison, compare them directly instead of minting a label — a create-time label would duplicate state docker owns. Shipped instance: image-ID drift at resume (container's pinned image via `docker inspect '{{.Image}}'` vs current image ID). Same abort-loud message shape and `_up_resolve_resume_*` guard family as D1, but **branch-asymmetric**: abort on stopped/created (pre-`docker start`), warn-only on running (a running drifted container is safe — its init ran against its own image; refusing would interrupt a live session).

Do **not** count label-free guards toward the label-lock instance tally — the promotion-worthy pattern is *drift-detect at resume*; labels are only the mechanism when docker does not already persist the state. Known residual: `rc` script newer than image with matching IDs can still crash resume-side execs (`rip-cage-h2hl`).

**Rationale:** `reasoned:` duplicating docker-owned state into a label creates a second source of truth that can itself drift; `direct:` rip-cage-jnvb shipped label-free and the tally confusion it caused is why this decision exists.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Mint a label anyway for family uniformity | `reasoned:` two sources of truth for image identity; docker's own record cannot be stale, a label can. |

**What would invalidate this:** a case where docker's persisted state is inspectable but not stable across docker upgrades — then a label pins the rc-side semantics and becomes the lesser evil.

## Scope boundary — image-shape label-locks

The sibling **image-shape** label-lock (label on the IMAGE, compared at the provisioning gate: `org.opencontainers.image.version`, `rip-cage-rcw`) is a distinct shape with its own tally (1/3 as of this writing) and is *not* governed by this ADR. If it reaches its own rule-of-three, it gets its own promotion (likely a Dn here, evolved in place).

## Consequences

- New mount-shape config fields have a named recipe to clone: label at create, `_up_resolve_resume_<feature>` resolver on both branches, fixed message shape, no `_RC_RELOAD_ELIGIBLE_PATHS` entry, derivation ladder if retrofitting.
- The instance ADRs (ADR-021 D4a/D7, ADR-022 implementation notes, ADR-026 D7) remain the authority on their instances' policy semantics; this ADR owns only the guard recipe. No back-edits to those ADRs were made with this promotion (follow-up pointers may land per ADR-008 D4 if drift appears).
- The `rip-cage-mount-shape-label-lock-pattern` bd memory slims to a tally + pointer; the recipe content here is canonical.

## canonical_refs

- ADR-001 (fail-loud pattern) — the abort-loud posture D1 step 3 instantiates.
- ADR-021 D4a (`mounts.symlinks.*` fingerprint, instance 2), D7 (`mounts.config_mode`, instance 3).
- ADR-022 implementation notes (`rc.ssh-key-filter` resume guard, instance 1); D6 (`rc reload` eligibility, the allowlist D1 step 4 rides on).
- ADR-026 D7 (per-tool credential-mount posture, instance 4).
- Beads: `rip-cage-jxy`, `rip-cage-c1p.2`, `rip-cage-cw51`, `rip-cage-xhgr` (instances); `rip-cage-36u` (D2), `rip-cage-jnvb` (D4), `rip-cage-h2hl` (D4 residual); `rip-cage-izi2` (this promotion).
- bd memory `rip-cage-mount-shape-label-lock-pattern` (pre-promotion home; now tally + pointer).
- bd memory `allowlist-stable-zone-over-denylist-of-growing-floor-set` (D1 step 4 warrant).
