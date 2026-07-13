# ADR-028: Mount-Shape Label-Lock Pattern

**Status:** Accepted — pattern promoted 2026-07-07 (`rip-cage-izi2`) from four shipped instances; rule-of-three exceeded

**Firmness:** per-decision, see each Dn

> **Migration status (ADR-029, 2026-07-10):** This ADR is evolved by [ADR-029](ADR-029-msb-migration.md) — the pattern survives, but its substrate (Docker labels) re-binds to msb sandbox metadata, and the instance tally shrinks (instance 1 retires with ADR-022; the scope-boundary `rc.mediator-ca-env` sibling retires with ADR-026 D5). **The msb cutover has landed (S1-S14, branch `wave/s13-docs` off `msb-cutover`) — this ADR is NOT retired.** Instance 1 retires with ADR-022 and the `rc.mediator-ca-env` sibling retires with ADR-026 D5. But **the mount-shape label-lock pattern itself survives and is LIVE under msb** — re-bound to msb sandbox metadata by S8 (`rip-cage-qzsx`), current and shipped. The mount-mutability verdict below is S8's own content, not touched by this docs sweep. See [ADR-029](ADR-029-msb-migration.md) for the migration decisions.

## Context

Docker bind mounts are immutable after `docker create`. Several rip-cage config fields decide *mount shape* — which mounts exist, their mode, or their content-set — at create time: `ssh.allowed_keys` (filter mount on/off), `mounts.symlinks.*` (the followed-symlink mount set), `mounts.config_mode` (`ro`/`rw` shadow-mount over `.rip-cage.yaml`), and `auth.credential_mounts` (+ per-tool overrides). When such a field changes between create and resume, the running container silently keeps its create-time shape while `rc config show` displays the new value — the cage's actual posture and its displayed posture diverge, and the divergence *fails open and quiet* (the most dangerous class per ADR-001).

Four independent guards shipped against this drift class, each cloning the previous one:

1. `rc.ssh-key-filter` (`rip-cage-jxy`, 2026-05-12; documented in ADR-022 implementation notes) — boolean on/off mount toggle. [ADR-029 D3: this instance RETIRES with ADR-022 — there is no ssh-agent-filter mount to guard once the ssh cluster retires.]
2. `rc.symlink-follow-fingerprint` (`rip-cage-c1p.2`; ADR-021 D4a) — sha256 over the symlink mount set.
3. `rc.config-mode` (`rip-cage-cw51`, 2026-07-01; ADR-021 D7) — `ro`/`rw` present-vs-absent shadow-mount.
4. `rc.auth.credential-mounts` + per-tool `rc.auth.credential-mounts.{claude,pi}` (`rip-cage-xhgr`, 2026-07-04; ADR-026 D7) — per-tool credential-mount posture, with a legacy derivation ladder. [ADR-029 D5: this instance RE-SHAPES rather than retires — per-tool posture survives and matters more (ADR-026 D7's disposition), now gating `--secret` non-possession vs real-credential mounting instead of gating a composed-mediator placeholder.]

**Instance tally under ADR-029:** four instances at promotion; instance 1 retires (above), instance 4 re-shapes (above), instances 2 and 3 are unaffected by the migration.

The recipe existed only as fragments (per-instance ADR notes + the `rip-cage-mount-shape-label-lock-pattern` bd memory). Per the rule-of-three promotion trigger, this ADR is the pattern's canonical home; the instance ADRs describe their instances and this ADR owns the recipe. Two hard-won coupling rules (D2, D3) and one deliberate non-instance sibling (D4) ride along.

## Decisions

### D1: The canonical label-lock recipe

> [ADR-029: EVOLVED — the recipe (create-time record, resume-time compare on both branches, abort-loud with the established message template, reload-ineligible by omission, backward-compat derivation ladder) survives; the substrate re-binds from Docker `rc.<feature>` container labels to msb's own sandbox metadata record (`msb inspect NAME --format json`'s `.config.labels`/`.config.manifest_digest`, read via `cli/lib/msb_runtime.sh`'s `_msb_label`/`_msb_sandbox_image_digest`) — shipped by `rip-cage-rj68` (S6) for all three surviving mount-shape instances (`_up_resolve_resume_config_mode`, `_up_resolve_resume_symlink_fingerprint`, `_up_resolve_resume_credential_mounts`) and the image-drift sibling (`_up_image_drift_status`), both branches, unchanged message templates.]
>
> **Mount-mutability verdict (`rip-cage-qzsx`, S8, 2026-07-12): NOT amendable — the D-clause invalidation does NOT fire; the label-lock guard family survives unchanged.** Evidence (msb v0.6.4, direct CLI inspection):
> - `msb modify --help` — the one true in-place amend-a-sandbox verb (mutates a running/stopped sandbox's OWN config without minting a new sandbox identity) — has **zero** mount-related flags. Its full surface is `--cpus/--max-cpus/--memory/--max-memory/--env/--env-rm/--label/--label-rm/--workdir/--secret/--secret-rm` plus `--dry-run/--next-start/--restart`. No `--net-rule` either, contrary to this ADR's original framing of net-rule as the amendable-via-`modify` counterexample.
> - `msb start --help` — the resume primitive `_up_resolve_resume_*`'s abort actually guards (via `_msb_start`, S6) — takes **no configuration flags at all** (`[NAMES]...`/`--label`/`-q` only). A resumed sandbox boots with exactly the mount table it was created with; there is no flag surface through which `rc up`'s resume path could even ask for a different shape.
> - The "snapshot-amend" mechanism ADR-029 D4 named (`msb run --snapshot <artifact> --net-rule <amended> ...`) is, on inspection, **not** an amend of the existing sandbox at all: `msb snapshot create --from <stopped-sandbox> <dest>` captures a disk-state artifact, and `msb run --snapshot <dest> ...` then boots a **fresh sandbox** (`msb run --help`: "Boot a **fresh** sandbox from a snapshot artifact... equivalent to specifying the snapshot's image plus pre-populating the upper layer") through the **same flag surface `msb create`/`msb run` always accept at boot** — mount flags (`--mount-file`/`--mount-dir`/`--mount-disk`/`--mount-named`) included. Mechanically this is "destroy-and-recreate, but seed the new instance's disk from the old one's snapshot" — the same *class* of operation Docker's bind-mount immutability already forced (`rc destroy && rc up`), not a new mutability primitive. It only ever looked net-rule-specific because ADR-029 D4's prose illustrated it with `--net-rule`; the mechanism itself is flag-agnostic and would apply identically (or not) to mount flags — it just isn't an *amend*.
> - Converging, independent confirmation: `rip-cage-rj68` (S6) shipped `rc reload` as **cold-recreate** (`_msb_stop_graceful` → `_msb_remove` → `cmd_up`), not snapshot-amend, specifically because "net-rule changes are recreate/snapshot-amend, not hot-swap" (S6 design notes) — even the ADR-029 D4 net-rule case that motivated this open question did not end up using a true amend mechanism in the shipped implementation.
>
> **Consequence:** the invalidation clause below ("a docker/OCI runtime feature that makes bind-mount shape mutable on a stopped container") is **discharged, not fired** — msb offers no such feature; mount shape remains exactly as immutable-per-sandbox-generation under msb as it was under Docker. The label-lock recipe (D1) is the correct, load-bearing guard on msb, not a legacy artifact to collapse into re-synthesis. **Instance tally: unchanged by this verdict** — the tally already recorded in "Instance tally under ADR-029" above (instance 1 retires, instance 4 re-shapes, instances 2/3 unaffected) stands as-is; no instance moves to re-synthesis as a result of this adjudication.

**Firmness: FLEXIBLE** — the pattern is proven by four shipped instances, but its codification here is new; edits land in place. The underlying invariant (never silently re-mount on resume) is effectively load-bearing across all instances and a candidate for FIRM once this write has soaked.

Any config field whose value determines create-time mount shape gets a **label-lock guard**:

1. **Create-time label.** At `docker create`, persist the effective policy value as a container label `rc.<feature>` (boolean/enum instances) or `rc.<feature>-fingerprint=<sha256>` (set-valued instances: sha256 over sorted policy-header + structural-input lines).
2. **Resume-time compare — BOTH branches.** On `rc up` against an existing container, a `_up_resolve_resume_<feature>` resolver reads the label, recomputes the current effective value, and compares — on the **running-container branch AND the stopped-container branch**. Guards that check only one branch were the original bug shape.
3. **Abort loud, established message template.** On mismatch, refuse with the template: `Container <name> was created with <label>=<stored> but current effective config has <field>=<current>. Mount shape is immutable on resume — run: rc destroy <name> && rc up <path> to apply the change.` JSON mode carries a stable error code (`<FEATURE>_MOUNT_SHAPE_CHANGED`). Per-instance wording may vary slightly; the load-bearing parts are naming both values, the immutability statement, and the destroy-and-re-up remediation. Never silently re-mount, never warn-and-proceed (ADR-001).
4. **Reload-ineligible by omission.** `rc reload` hot-reloads only fields listed in the `_RC_RELOAD_ELIGIBLE_PATHS` allowlist (content-only changes, e.g. `ssh.allowed_hosts` per ADR-022 D6). Mount-shape fields are guarded by *never adding them* — the allowlist-of-stable-zone shape, so a new guarded field is safe by default with zero reload-side edits.
5. **Backward-compat derivation ladder.** When a guard is added (or its grain refined, e.g. global → per-tool in instance 4), resume of a pre-guard container must not brick: derive the stored value as *specific label if present, else coarser/older label if present, else the historical default*. Upgrading `rc` never invalidates a running cage whose effective posture is unchanged.

**Residuals repaired (`rip-cage-7gr9`, 2026-07-07):** at promotion two instances drifted from this recipe; both are now aligned. Instance 1 (`_up_resolve_resume_ssh_key_filter`) had run on the **stopped branch only** — the one-branch bug shape step 2 warns about — and now also runs on both running branches (dry-run + real), keeping the rip-cage-3y9g mirror invariant. Instance 2 (`_up_resolve_resume_symlink_fingerprint`) had **no JSON error code**; both its fail branches now emit the stable `SYMLINK_FINGERPRINT_MOUNT_SHAPE_CHANGED` code under `--json`, per step 3. Both drifts surfaced during this ADR's adversarial review.

**Rationale:** docker owns the mount table and offers no rebind; the honest contract is "mount shape is immutable per container generation." A create-time label is the cheapest durable record of the shape actually built; comparing at resume converts silent divergence into a loud, actionable refusal at the exact moment the operator can still choose (destroy-and-re-up vs keep the old shape). Four instances converged on this recipe independently enough that divergence risk now exceeds codification cost.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Evolve ADR-022 in place — promote its implementation-note guard to the canonical pattern decision (the overlap scout's 4/5 recommendation, per the global methodology ADR-008 D7 overlap-detection discipline — distinct from this repo's ADR-008, open-source publication) | `reasoned:` the overlap is with an *implementation note* documenting instance 1, not with ADR-022's decision space (SSH host/key allowlisting). The pattern is cross-cutting — instances live in ADR-021 D4a/D7 and ADR-026 D7 too; housing the recipe inside the SSH ADR makes three non-SSH ADRs depend on an SSH doc for a docker-lifecycle pattern. Scored honestly, overlap is moderate (2-3/5) → create-and-flag per the same discipline's thresholds; the flag is discharged by this table + cross-refs. |
| Silently re-filter / re-mount on resume to match new config | `direct:` rejected in ADR-022 D6's alternatives — resume preserves labels, mutations are explicit; `rc reload` is the explicit mutate verb for content-eligible fields. |
| Warn-and-proceed on mismatch | `reasoned:` fails open — the operator's next 200 agent-turns run against a posture that contradicts displayed config; ADR-001 requires loud failure with remediation. |
| Denylist mount-shape fields from reload instead of allowlisting eligible ones | `direct:` bd memory `allowlist-stable-zone-over-denylist-of-growing-floor-set` — the guarded set grows with every instance; a denylist requires an edit-per-instance and fails open when forgotten. |
| Keep the recipe in the bd memory only (no ADR) | `reasoned:` the memory is agent-substrate, invisible to human contributors reading `docs/decisions/`; four instances plus two coupling rules exceed the rule-of-three promotion bar the memory itself documented. |

**What would invalidate this:** a docker/OCI runtime feature that makes bind-mount shape mutable on a stopped container (rebind at start) — the guard family would collapse into plain re-synthesis at resume; or a fifth instance that cannot express its policy as a label-comparable value (would force a generalization of the label encoding, evolving D1 in place). **Checked against msb (`rip-cage-qzsx`, S8, 2026-07-12): discharged, not fired** — see the mount-mutability verdict above (`msb modify`/`msb start` carry no mount flags; `msb run --snapshot` boots a fresh sandbox rather than amending the existing one). msb is not the runtime feature this clause anticipates.

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

> [ADR-029: EVOLVED — the label-free drift-detect principle survives; the shipped instance's mechanism (`docker inspect '{{.Image}}'` vs current image ID) re-binds to msb's own image record at cutover — the underlying logic ("compare what the platform already persists on both sides, don't mint a label") is platform-agnostic and needs no redesign, only a different inspect call.]

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

Likewise out of scope: `_up_resolve_resume_mediator_ca_env` (`rc.mediator-ca-env`, `rip-cage-yid0`) guards create-time-frozen **ENV shape**, not mount shape — same guard family and message posture, both branches, but not counted toward this ADR's instance tally. [ADR-029 D2/D5: this scope-boundary sibling RETIRES with [ADR-026](ADR-026-containment-mediation-identity.md) D5 — the MEDIATOR archetype and its CA-env injection are deleted wholesale at cutover, so there is no mediator CA env to guard.]

## Consequences

- New mount-shape config fields have a named recipe to clone: label at create, `_up_resolve_resume_<feature>` resolver on both branches, fixed message shape, no `_RC_RELOAD_ELIGIBLE_PATHS` entry, derivation ladder if retrofitting.
- The instance ADRs (ADR-021 D4a/D7, ADR-022 implementation notes, ADR-026 D7) remain the authority on their instances' policy semantics; this ADR owns only the guard recipe. No back-edits to those ADRs were made with this promotion (follow-up pointers may land as discovered-from beads if drift appears).
- The `rip-cage-mount-shape-label-lock-pattern` bd memory slims to a tally + pointer; the recipe content here is canonical.

## canonical_refs

- ADR-001 (fail-loud pattern) — the abort-loud posture D1 step 3 instantiates.
- ADR-021 D4a (`mounts.symlinks.*` fingerprint, instance 2), D7 (`mounts.config_mode`, instance 3).
- ADR-022 implementation notes (`rc.ssh-key-filter` resume guard, instance 1); D6 (`rc reload` eligibility, the allowlist D1 step 4 rides on).
- ADR-026 D7 (per-tool credential-mount posture, instance 4).
- Beads: `rip-cage-jxy`, `rip-cage-c1p.2`, `rip-cage-cw51`, `rip-cage-xhgr` (instances); `rip-cage-36u` (D2), `rip-cage-jnvb` (D4), `rip-cage-h2hl` (D4 residual); `rip-cage-rcw` (image-shape sibling, Scope boundary); `rip-cage-yid0` (env-shape sibling, Scope boundary); `rip-cage-7gr9` (instance-residual repairs); `rip-cage-izi2` (this promotion); `rip-cage-rj68` (S6, msb re-bind of the D1 recipe's substrate); `rip-cage-qzsx` (S8, msb mount-mutability verdict — D1's invalidation clause discharged, guard family unchanged).
- ADR-029 D1/D4 (msb migration — hard cutover; snapshot-amend/cold-recreate mechanics the mount-mutability verdict adjudicates against).
- Global methodology ADR-008 (ADR-authoring conventions; D7 overlap-detection thresholds) — external namespace, distinct from this repo's ADR-008 (open-source publication); same cross-repo collision noted for ADR-011/ADR-013 in INDEX.md.
- bd memory `rip-cage-mount-shape-label-lock-pattern` (pre-promotion home; now tally + pointer).
- bd memory `allowlist-stable-zone-over-denylist-of-growing-floor-set` (D1 step 4 warrant).
