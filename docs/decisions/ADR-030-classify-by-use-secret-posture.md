# ADR-030: Classify-by-Use Project-Secret Posture — an Opt-In Effort Gradient

**Status:** Proposed (firmness is per-decision below)
**Date:** 2026-07-27
**Design:** Brainstorm-converged (`rip-cage-23cp`, secret-posture brainstorm) — evidence base in `history/2026-07-26-secret-posture-convergence.md`, `-community-scan.md`, `-spikes.md` (spikes S1–S4). Canonicalized from bead `rip-cage-g5jg`.
**Related:**
- [ADR-024](ADR-024-prompt-injection-threat-model.md) (D2 exfil axis — this posture is the graduated content-level response; D2 gains two layer rows + the reflection residual, in place)
- [ADR-023](ADR-023-secret-path-mount-denylist.md) (secret-path denylist — orthogonal sibling: pattern-match *rejection* of a mount vs. explicit per-path *masking* of content already in the tree)
- [ADR-021](ADR-021-layered-rip-cage-config.md) (D2 union-by-default list merge + D7 `config_mode: ro` — the substrate `mounts.mask` rides)
- [ADR-029](ADR-029-msb-migration.md) (D5 `--secret` non-possession — the *mechanism* Tier 2 reuses; governs the **tool's own** credential by default, not project secrets — see the boundary note in D2/D3)
- [ADR-026](ADR-026-containment-mediation-identity.md) (D7 per-tool credential-mount posture — an *orthogonal* axis: WHO gets non-possession vs. HOW MUCH effort a project spends on its own secrets)
- [ADR-005](ADR-005-ecosystem-tools.md) (D12 composable seam FIRM — classification is agent judgment, never rc machinery)
- [ADR-001](ADR-001-fail-loud-pattern.md) (fail-loud + actionable — D5's missing-mask-source abort applies it)
- Project [CLAUDE.md](../../CLAUDE.md) philosophy ("layers not walls / 80/20 / autonomy is the product / 'it's annoying' is a design signal")

## Context

The cage limits blast radius; it is not a wall. A caged agent's mounted workspace tree — especially a **pooled** mount like `~/code/personal`, where one cage sees many sibling repos — routinely contains project secrets: a repo's `.env`, third-party API keys, DB credentials, signing keys. Today the only content-level defense for *project* secrets (distinct from the agent's own auth token) is the egress wall ([ADR-024](ADR-024-prompt-injection-threat-model.md) D2; [ADR-029](ADR-029-msb-migration.md) net-default-deny). That wall is strong against exfil-over-network, but the secrets remain readable in-cage — an accepted residual until now.

The `rip-cage-23cp` brainstorm converged a **classify-by-use** model and validated the mechanisms with spikes (S1: boot-time `ro` overmount masking; S2: full Class-A non-possession end-to-end with a sentinel credential; S3/S4: residual probes). This ADR canonicalizes that posture.

**The load-bearing design constraint is a philosophy constraint.** Per CLAUDE.md, autonomy is the product and "it's annoying" is a design signal. Any framing that reads as a *required per-repo `.env` migration* fails that test — it would force human rework on every project before a cage is useful, defeating the zero-friction "just works" value proposition. The posture is therefore an **opt-in effort gradient with a zero-work default**, not a checklist a project must complete.

**Boundary with ADR-029 D5 (stated up front because it is the natural misread).** ADR-029 D5 makes `--secret` non-possession the *default platform property* for the **tool's own dominant credential** — Claude Code's OAuth token. That is one artifact, per tool, mounted by the cage's own auth flow. This ADR governs a *different population*: **project secrets that live in the mounted workspace tree**, which the caged task may or may not use. Generalizing the `--secret` mechanism to a project's wire-bearer secret (Tier 2 below) is **opt-in per credential** and touches nothing about ADR-029 D5's tool-credential default. "Non-possession is default for the tool's token" and "non-possession is opt-in for a project's secrets" are both true, of different secrets; there is no contradiction.

## The classification model (used by D1–D3)

Secrets are classified by **how they are used**, not by name or type:

| Class | Definition | Response mechanism |
|---|---|---|
| **A — wire-bearer** | Sent verbatim toward a known host (API keys, PATs, bearer tokens) | Non-possession: placeholder in-tree, real value host-side only, msb `--secret` wire substitution (Tier 2) |
| **B1 — locally-consumed, dynamically issuable** | Consumed by local processes but issuable short-lived (DB passwords, cloud session creds) | Agent-composed recipe: per-cage short-lived issuance (Vault-style dynamic secrets) — outside the rc-provided gradient |
| **B2 — static key material** | Structurally static, locally consumed (signing keys, mTLS client keys, age/PGP keys) | None — substitution is on-the-wire; these never transit in substitutable form. Accept-or-exclude (irreducible) |
| **C — not-needed-by-caged-work** | Present in the mounted tree, unused by the cage's task | Boot-time `ro` overmount mask (Tier 1 `mounts.mask`), or relocate out of tree |

## Decisions

### D1: Classify-by-use is the organizing model — and classification is agent judgment, never rc machinery

**Firmness: FIRM**

Project secrets are reasoned about by **use-class** (A / B1 / B2 / C above), not by an enumerated list of credential names or file patterns. The mechanized responses rip-cage *provides* attach to two classes — masking for Class C (D4), non-possession for Class A (Tier 2, D2/D3) — while B1 (agent-composed issuance recipe) and B2 (accept-or-exclude) are named honestly as having no rc-provided mechanism.

**Which class a given secret is in is a per-situation judgment the agent (or human) makes** — rc never classifies. Per [ADR-005 D12](ADR-005-ecosystem-tools.md), rc owns the composition interfaces (the `mounts.mask` list, the `auth.credentials` binding), never the classification. A file is Class C in one cage (a sibling repo's `.env` the task never touches) and Class A in another (the credential the task actively sends upstream); only the situation decides.

**Rationale:** classifying by *use* rather than by *type* is what lets a single small model of the world cover new credential shapes without a schema change — the question "does the caged task send this, consume it locally, or never touch it?" is answerable per situation, whereas "is this one of the 17 known secret types?" ages badly (the [ADR-023](ADR-023-secret-path-mount-denylist.md) D4 pattern list is exactly the maintenance surface this model routes *around* for the posture question). Keeping classification as judgment is the composable-seam principle (ADR-005 D12): the moment rc tries to auto-classify, it has blessed a fixed taxonomy and owns its drift.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Classify by credential *type* (extend the ADR-023 pattern list to drive posture) | `reasoned:` a name/type list is the brittle-checklist shape the model exists to avoid — it ages with every new credential format and cannot express "this file is a secret *here* but not *there*." Use-class is situation-relative; type is not. `external:` ADR-023 D4 itself flags its pattern list as empirical/tunable, i.e. a maintenance surface, not a foundation to build posture on. |
| rc auto-detects secret files and proposes a class | `direct:` ADR-005 D12 (FIRM) — rc must never name/bless a taxonomy of tools-or-secrets; auto-classification hardcodes exactly that. Detection heuristics also fail-open (a missed secret reads as "no secret"), the wrong direction. Agent-assisted sweep belongs in a *skill* (`rip-cage-3npt`), not rc. |

**What would invalidate this:** a credential use-pattern that fits none of A/B1/B2/C (e.g. a secret that is simultaneously wire-borne and locally consumed in a way the split misclassifies). The class set extends; the "by use, not type" principle holds unless the extension itself proves untenable.

### D2: Opt-in effort gradient with a zero-work default — Tier 0 / 1 / 2

**Firmness: FIRM**

The posture is a three-tier gradient of **escalating effort and opt-in**, anchored by a zero-work default:

- **Tier 0 — cage + egress wall only (the default, zero work).** Nothing masked, nothing reworked. Class-C secrets sit readable in the tree; the egress wall (ADR-024 D2 / ADR-029 net-default-deny) prevents them leaving. This is the unchanged "just works" value proposition — a cage is useful with no secret-posture authoring at all.
- **Tier 1 — `mounts.mask` list (cheap).** The intended answer for pooled mounts: declare a handful of Class-C paths to boot-time-mask (D4). Per-file, additive, never per-repo rework. Reduces in-cage *visibility* of unused secrets.
- **Tier 2 — Class-A non-possession rework (expensive, per-credential).** Reuse ADR-029 D5's `--secret` mechanism for a *project* wire-bearer: placeholder in-tree, real value host-side, wire-substituted toward the bound host. Applied only to credentials the caged agent **actively uses** and only per D3's criterion.

**Tier 2 is never default and never prescribed.** No rip-cage surface — doc, skill, error message, or default config — may frame Tier 2 as a required migration or a step every project "should" complete. Doing so re-imports the "required `.env` migration" framing the philosophy rejects ("it's annoying"). The gradient's whole shape is: cost rises left-to-right, and a project stops wherever its risk judgment says stop — most stop at Tier 0.

B1 and B2 sit *outside* this rc-provided gradient by construction (D1): B1 is an agent-composed issuance recipe, B2 is accept-or-exclude. Naming them keeps the model honest without pretending rc mechanizes them.

**Rationale:** an opt-in gradient with a zero-work default is the 80/20 philosophy made concrete — the default blocks the obvious network-exfil accident for free, and a project pays incremental effort only for the incremental risk it actually carries. A single mandatory posture (whatever tier) would be either too weak for high-risk projects or too annoying for the common case; the gradient lets the *same* cage serve both by moving the opt-in decision to the situation.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| One mandatory posture for all cages | `direct:` CLAUDE.md "80/20 / autonomy is the product" — a mandatory non-possession rework is the "required `.env` migration" the human explicitly flagged as an "it's annoying" anti-pattern (`rip-cage-g5jg` notes, 2026-07-27); a mandatory *masking* list still forces per-project authoring before first useful run. |
| Default-on masking (Tier 1 as the floor) | `reasoned:` masking needs per-path declaration that is situation-specific (which sibling repos are Class C *here*); a non-empty default would either misfire on legitimate files or be a guess rc is forbidden to make (D1 / ADR-005 D12). Default empty (D4) keeps Tier 0 the true default. |
| Collapse tiers into ADR-029 D5 as "when to use --secret" | `reasoned:` D5 governs the tool's own credential (default non-possession); folding project-secret posture into it conflates two credential populations (see Context boundary note) and would make the tool-credential default read as contingent on project-secret opt-in. The posture is a distinct, cross-cutting response — same precedent as ADR-023 being its own ADR rather than folded into ADR-024's threat model. |

**What would invalidate this:** evidence that Tier 0's egress-wall-only default is insufficient in practice for the common case (a real project-secret exfil that the wall did not stop and masking would have) — at which point the *default* tier is reconsidered, not the gradient shape. Or: users routinely report the gradient's opt-in points are unclear/annoying, signalling the tier boundaries are drawn wrong.

### D3: The Tier-2 opt-in trigger is a judgment criterion, not a credential-type list

**Firmness: FIRM**

A project opts a credential into Tier 2 (non-possession) when that credential is **high-value AND the cost of a leak is great or irreversible**. This is a **judgment predicate applied per credential**, deliberately *not* an enumerated list of named credential types that "always need" Tier 2.

Illustrative — not enumerative: a production database password is a natural Tier-2 candidate (high-value, and a leak is great and hard to walk back). That is offered as *an example of the criterion in action*, not as an entry in a checklist; a staging DB password with rotate-on-demand and no blast radius may sit fine at Tier 0. The classification stays per-situation (D1).

**Rationale:** a fixed list of "credential types that need non-possession" is the exact brittle-checklist shape D1 routes around — it ages with every new service, tempts completeness ("did we cover every cloud provider?"), and encodes a false universal (the *same* credential type is high-stakes in one project and disposable in another). Canonicalizing the *criterion* instead means the judgment travels to new credential shapes for free, and keeps the composable-seam invariant (rc never blesses a secret taxonomy).

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Enumerate named high-value credential types that always warrant Tier 2 | `direct:` `rip-cage-g5jg` human refinement (2026-07-27) — "a fixed list is exactly the brittle-checklist shape being avoided"; `reasoned:` a type list mis-fires in both directions (over-covers disposable staging creds, under-covers a novel high-value token) and is a maintenance surface D1 exists to eliminate. |
| No guidance — leave Tier-2 entry fully unspecified | `reasoned:` a bare "opt in when you feel like it" gives the agent/human no anchor and invites both over- and under-application; canonicalizing the *criterion* (high-value ∧ leak-cost-great/irreversible) is the middle path — guidance without a checklist. |

**What would invalidate this:** the criterion proving too abstract to apply in practice (agents/humans consistently unable to decide from it, asking for examples every time) — at which point the fix is *more worked examples in the recipe docs* (`rip-cage-m613`), not a canonical type list, unless the list shape is affirmatively re-argued against this decision.

### D4: `mounts.mask` — the Tier-1 config key; rides ADR-021's substrate; default empty

**Firmness: FIRM**

Tier 1 is expressed by a config key `mounts.mask`: a list of **workspace-relative paths** that rc boot-time-masks with `ro` overmounts (a legible-breadcrumb file/dir shadowing the real content; the underlying file is unreadable in-cage, the rest of the workspace stays `rw` — spike S1). It rides [ADR-021](ADR-021-layered-rip-cage-config.md)'s existing config substrate: a **list field, union-by-default** across the three-layer merge (ADR-021 D2 v2 — global floor of masks a project expands), provenance surfaced by `rc config show`, governed `config_mode: ro` in-cage by default (ADR-021 D7 — a prompt-injected agent cannot self-edit the mask list in-cage; the human authors host-side).

**Default is empty** — no paths masked out of the box. This is what keeps **Tier 0 the true default** (D2): a cage with no `mounts.mask` authoring masks nothing and relies on the egress wall.

`mounts.mask` is **orthogonal to `mounts.denylist`** (ADR-023): the denylist *rejects a mount* by pattern-match at `rc up` validation (a path never enters the cage); the mask *hides content already legitimately in the tree* by explicit per-path declaration (the workspace mount is wanted; one file inside it is shadowed). Different surface, different mechanism, different merge posture — the denylist is the one replace-forbidden field (ADR-021 D2), whereas a project may narrow its own inherited mask via a diff-visible `!replace` (masking is visibility-reducing, so narrowing only re-exposes a file in-cage, behind the still-standing egress wall — not the protection-stripping direction the denylist guards).

**Rationale:** reusing ADR-021's substrate (rather than a bespoke mask config) gives `mounts.mask` union merge, provenance, `config_mode` governance, and `rc config show` visibility for free, and keeps all mount-shaping config in one legible place. Default-empty is forced by D1/ADR-005 D12 — rc must not guess which paths are Class C.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Hardcode a default mask list in rc | `direct:` ADR-005 D12 (FIRM) — rc must never bless a fixed set; `reasoned:` which paths are Class C is situation-specific (D1), so any default misfires. |
| A bespoke top-level `mask:` config outside `mounts.*` | `reasoned:` fragments the config substrate — loses ADR-021's union merge, provenance, and `config_mode` governance, all of which the mask needs; masking *is* a mount-shape concern, so `mounts.mask` is the honest home. |
| Fold masking into `mounts.denylist` | `reasoned:` opposite mechanisms — denylist rejects a whole mount by pattern; mask shadows one path inside a wanted mount by explicit declaration. Merging them would force denylist's replace-forbidden rule onto a visibility-reducing list where it is unwarranted. |

**What would invalidate this:** ADR-021's config substrate is restructured with a breaking schema change (migrate the field), or a masking need arises that is not expressible as a workspace-relative path list (e.g. content-pattern masking) — at which point the key's shape is revisited.

### D5: A missing mask source fails loud at `rc up` — never a silent bind-becomes-directory

**Firmness: FIRM**

If a `mounts.mask` entry names a path that does not exist on the host at `rc up` time, rc **aborts loud** with an actionable message (the path, that it was declared in `mounts.mask`, where). It must never fall through to the msb/bind failure mode where a nonexistent bind source silently becomes an empty **directory** mount (spike-S1 operational edge, convergence residual #9) — that both fails to mask (the intended file may still be reachable) and corrupts the tree shape with a phantom directory.

**Rationale:** applies [ADR-001](ADR-001-fail-loud-pattern.md) — a masking directive that silently does nothing is the worst outcome for a *security* posture (the operator believes a secret is masked when it is not). A declared-but-missing mask path is unambiguously an authoring error (typo, moved file); failing loud names it while the human is right there at `rc up`, consistent with ADR-023 D6's fail-loud-on-explicit-intent tier (a mask entry *is* explicit mount-intent).

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Warn-and-skip a missing mask source (mount nothing, continue) | `reasoned:` unlike ADR-023's incidental symlink surfaces (warn-and-skip appropriate because the secret is not mounted either way), here skipping *leaves the real secret exposed* if the path was a typo of a real file — silent under-masking of a security control. Explicit-intent surface → fail loud, per ADR-023 D6's own tiering. |
| Let the bind fall through to msb's default (empty-dir mount) | `direct:` ADR-001 (no silent degradation) — a phantom empty directory both fails to mask and desyncs the tree; the exact silent-failure ADR-001 forbids. |

**What would invalidate this:** a legitimate flow where a mask path is *expected* to be sometimes-absent (e.g. an optional secret present only in some sibling repos of a pooled mount) becomes common enough that fail-loud is routine friction — at which point an explicit `optional:`-style opt-in (diff-visible) is added for that entry, keeping fail-loud the default.

### D6: Mask content is a legible breadcrumb, not empty bytes

**Firmness: FIRM** (the principle; the exact breadcrumb string is a FLEXIBLE implementation detail)

The masking overmount presents **legible breadcrumb content** — e.g. `masked by rip-cage` — not empty bytes. When a process (or the agent) reads a masked path, it gets a self-describing marker, not a zero-length file or an opaque error.

**Rationale:** silent-breakage mitigation for the misclassification residual (D8 item 7). If a file is mislabeled Class C and masked but some local process actually needs it, an empty/zero-byte read produces a confusing downstream failure far from the cause; a legible breadcrumb turns that into an immediately-diagnosable "oh, rip-cage masked this" — the autonomy-preserving failure shape (the agent can read the breadcrumb and surface the misclassification, rather than thrashing on an empty read). The *content string* is tunable (FLEXIBLE); the *principle* that it is legible-not-empty is load-bearing (FIRM).

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Empty-bytes / zero-length mask | `reasoned:` an empty read of a needed-but-misclassified file fails opaquely downstream (convergence residual #8), the confusing-error shape; a breadcrumb self-describes the cause. |
| Deny-read (EACCES) on the masked path | `reasoned:` a hard permission error is *less* legible than a readable breadcrumb for the common misclassification case, and complicates the `ro` overmount mechanism (S1 used content shadowing, not ACLs); breadcrumb content is the lower-friction, more-diagnosable choice. |

**What would invalidate this:** a case where legible breadcrumb content is itself harmful (e.g. a consumer that must see *either* the real secret *or* a hard failure, never a placeholder string) — that consumer's path is Class B (locally-consumed), so it should not be masked at all (D1), rather than the breadcrumb rule changing.

### D7: Masked-but-git-tracked paths are handled by docs-warning, not machinery

**Firmness: FIRM**

If a masked path is **git-tracked**, an in-cage commit would capture the breadcrumb mask content in place of the real file (community-observed failure; convergence residual #7). rip-cage handles this by **documentation warning in the recipe** (`rip-cage-m613` / the `mounts.mask` reference), **not** by any rc machinery that inspects git state, refuses to mask tracked files, or rewrites commits.

`.env` — the archetypal mask target — is conventionally git-ignored, so the common case is already safe; the warning covers the exception. Per [ADR-005 D12](ADR-005-ecosystem-tools.md) and CLAUDE.md ("composition is the agent's job"), the mask primitive stays a dumb, deterministic overmount; detecting-and-reacting-to git-tracked state is the agent's/human's judgment, surfaced by docs, not automated into the seam.

**Rationale:** git-tracked-ness is situation-specific and the right response varies (gitignore the file, don't mask it, mask and never commit from that cage) — automating one response into rc would be the "freeze the varying part into machinery" anti-pattern CLAUDE.md warns against. A docs-warning informs the judgment without pre-empting it, and keeps the mask primitive trivially correct.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| rc refuses to mask a git-tracked path (fail loud) | `reasoned:` over-reaches into the agent's judgment (ADR-005 D12) — a masked-and-never-committed-from-here flow is legitimate; a hard refusal blocks it and adds git-state inspection to a primitive that should stay a dumb overmount. |
| rc auto-adds masked paths to `.git/info/exclude` | `direct:` CLAUDE.md "don't automate the wiring" — silently mutating git state is exactly the config-merge/auto-wire shape the philosophy forbids; also fails if the path is already tracked (exclude doesn't untrack). |

**What would invalidate this:** the tracked-file footgun causing real damage in practice despite the warning (agents/users committing mask content repeatedly) — at which point a *loud, non-mutating* warning at `rc up` (naming tracked masked paths) is added, still short of machinery that alters git state.

### D8: Named residuals — accepted, not closed here

**Firmness: FLEXIBLE**

The posture reduces blast radius; it does not eliminate secret risk (CLAUDE.md "layers not walls"). The following residuals are **named and accepted**, several with active follow-up beads; none is closed by this ADR:

1. **Reflection defeats non-possession (observed live, not hypothetical).** In spike S2 the bound host reflected the substituted *real* value in its response body and the guest read it; the violation guard is blind (it keys on the placeholder), so a reflected real value can then ride egress to any allowlisted host. Prompt-injection-relevant (an injected agent could deliberately elicit reflection). Probe/mitigation tracked in **`rip-cage-x640`**; docs warn meanwhile. This residual also belongs in the ADR-024 D2 threat-model text (evolved in place alongside this ADR).
2. **In-guest indistinguishability of a secret-violation block vs. a plain egress deny.** The block is host-log-only; `rc doctor` / `rc reload` fix-hints would today advise "add the host to the allowlist" for what was actually a blocked credential misdirection — an operator following the hint could convert a caught exfil into an allowed one. Tracked in **`rip-cage-jlu4`**.
3. **Create-time-only masking (spike S4).** Masking is applied at boot; a secret file *created after* boot is unmasked. Accident-class residual.
4. **Substitution dead zones.** Transformed credentials (Basic-auth base64, creds in bodies/query params) and mTLS/cert-pinned channels are outside the TLS-intercepting `--secret` substitution model — Tier 2 does not cover them.
5. **Capability outlives possession.** Non-possession does not shorten the upstream credential's lifetime; pair Tier 2 with short-lived/OIDC-style upstream creds where the leak-cost warrants (D3).
6. **B2 (and un-issuable B1) irreducibility.** Static key material has no substitutable-on-the-wire form; it remains accept-or-exclude. No technical closure.
7. **Misclassification → silent breakage** — mitigated but not eliminated by D6's legible breadcrumb.

**Rationale:** naming residuals explicitly is the honest-posture discipline — it prevents "we have a secret posture" from being read as "secrets are safe," and gives future beads a checked list rather than rediscovery. FLEXIBLE because the residual set is empirical and will evolve as the probe beads (x640, jlu4) resolve.

**What would invalidate this:** any residual promoted to closed (its probe bead lands a fix) — update this list in place; or a new residual surfaces from real use — add it.

## Consequences

**Positive:**
- The cage keeps its zero-work "just works" default (Tier 0) while gaining a legible, incremental path to stronger project-secret posture — the 80/20 philosophy made concrete.
- Classification stays agent judgment (D1/D3); rc gains exactly one new config key (`mounts.mask`) and reuses an existing mechanism (`--secret`) — no new taxonomy, no blessed tool/secret list (ADR-005 D12 held).
- The threat model (ADR-024 D2) gains two auditable content-level layers where it previously had only the egress wall for project secrets.

**Negative:**
- A real, named residual set (D8) — non-possession is defeated by reflection, masking is create-time-only, B2 is irreducible. The posture is blast-radius reduction, not a guarantee; docs must not oversell it.
- `mounts.mask` adds a config key and a boot-time mount step (`rip-cage-goaz` implements it); Tier 2 adds per-credential recipe authoring (`rip-cage-m613`).

**Neutral:**
- Tier boundaries are a judgment surface; the configure-cage skill's secret-posture sweep (`rip-cage-3npt`) is the agent-assist that helps a human place paths in `mounts.mask` and flag Tier-2 candidates — a skill, deliberately not rc machinery.

## canonical_refs

- `docs/decisions/ADR-024-prompt-injection-threat-model.md` — D1 threat class; D2 exfil axis, evolved in place alongside this ADR to add the Class-C-masking and Class-A-non-possession content layers + the reflection residual
- `docs/decisions/ADR-023-secret-path-mount-denylist.md` — D1/D4/D5/D6 secret-path denylist; the orthogonal sibling (pattern-match mount rejection vs. explicit per-path content mask), cross-referenced in place; D6's fail-loud-vs-warn-and-skip tiering is the precedent for D5
- `docs/decisions/ADR-021-layered-rip-cage-config.md` — D2 union-by-default list merge (v2) that `mounts.mask` rides; D7 `config_mode: ro` governance that keeps the mask list host-authored
- `docs/decisions/ADR-029-msb-migration.md` — D5 `--secret` non-possession; the Tier-2 mechanism, governing the tool's own credential by default (this ADR reuses it for project secrets, opt-in — no D5 text contradicted; D5's own "extension, not contradiction" pattern)
- `docs/decisions/ADR-026-containment-mediation-identity.md` — D7 per-tool credential-mount posture; the orthogonal axis (WHO gets non-possession) to this ADR's effort gradient (HOW MUCH effort on project secrets)
- `docs/decisions/ADR-005-ecosystem-tools.md` — D12 composable seam (FIRM); classification stays agent judgment, rc never blesses a secret taxonomy — the invariant governing D1/D3/D4/D7
- `docs/decisions/ADR-001-fail-loud-pattern.md` — no-silent-failure; D5's missing-mask-source abort and D6's legible-breadcrumb both apply it
- `rip-cage-23cp` — secret-posture brainstorm epic (design origin)
- `rip-cage-g5jg` — this canonicalization bead
- `rip-cage-goaz` — workspace-mask primitive (Tier-1 `mounts.mask` implementation)
- `rip-cage-m613` — Class-A wire-bearer recipe docs (Tier-2 via `auth.credentials`, zero rc code) — landed as [docs/reference/secret-posture.md](../reference/secret-posture.md)
- `rip-cage-x640` — reflection-residual probe (D8 #1)
- `rip-cage-jlu4` — denial-visibility disambiguation, doctor/reload fix-hints (D8 #2)
- `rip-cage-3npt` — configure-cage secret-posture sweep skill (agent-assist for tier placement)
- `history/2026-07-26-secret-posture-convergence.md`, `-community-scan.md`, `-spikes.md` — evidence base (spikes S1–S4, community scan)
