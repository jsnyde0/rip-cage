# Handoff: rip-cage-tsf2.10 — config-model redesign (Fable → Fable, 2026-07-14)

You are a Fable-class agent taking over **rip-cage-tsf2.10** (design epic: reconsider the msb-era
config model) as brain-of-scope and the human's design partner in this tab. The human (Jonatan)
will converse with you directly. The originating Fable session stays focused on rip-cage-tsf2.9
(rc up drift convergence) and the tsf2 epic — raise cross-scope effects to the human, don't fold
them sideways.

## Why now (human's call, verbatim intent)

"NOW is the time to reconsider/redesign/refactor hard, before we really start using rip cage on
msb." Adoption is near-zero post-cutover, the reference docs were swept to accuracy yesterday
(tsf2.3 — accurate baseline to diff against), so schema breaks are as cheap as they will ever be.

## Where convergence already stands (from the 2026-07-14 session — do NOT re-derive)

The bead description (`bd show rip-cage-tsf2.10`) carries the seeded assessment. Summary + the
conversational nuance not in the bead:

**KEEP (settled, defend against redesign zeal):**
- The build-time / runtime split (image manifest vs boot-time posture) — physical distinction.
- The **in-repo** `.rip-cage.yaml` — travels/reviewed with the repo, read-only inside the cage
  (prompt-injection defense, ADR-021 D7). The human floated the mem system's central-store model
  (`~/.memories`, per-project buckets) as *inspiration* and explicitly said "I'm not saying let's
  copy it" — the agreed take: **centralize the VIEW and the VERBS, never the project-config file.**

**DEBT 1 — merge semantics (the core of the redesign):** layers merge lists additively and can
never narrow, which forced the workaround placement rule "only universal earns global." The human
independently pointed at docker compose's answer (override files with explicit merge-control:
`!override` / `!reset` YAML tags, ordered multi-file merge). Direction: per-key merge control so a
project layer can visibly replace or clear an inherited list; dissolves the placement rule.

**DEBT 2 — verbs-over-files interface:** operators must learn a 3-file taxonomy (the
configure-cage skill needs a whole table to teach it — smell). Inspiration the human named:
dotpi-3bi.25 (verbs-over-scopes; read it via `bd show dotpi-3bi.25` in ~/code/personal/dotpi) —
intent expressed as verb + scope, system routes storage. rc's own `rc allowlist add` is the
existing seed of this pattern. Direction: `rc config set/add/remove --scope global|project` +
a first-class unified effective-view with provenance ("what can this cage reach and WHY") that
spans all three sources including the manifest-egress union (rip-cage-tsf2.8, landed 2026-07-14).

**EXPLORATORY — profiles/inheritance (compose `extends`/`include`):** fills a real gap (no named
postures; "walk-away cage" is a prose recipe). Hard line already drawn: rc-SHIPPED profile
libraries are out (ADR-005 D12 — composition is the agent's job; CLAUDE.md names "config-merge
step" as the classic composition-freezing drift). Operator-AUTHORED extends is judged by: does it
automate wiring judgment, or just deduplicate the operator's own data?

## Open questions (the actual remaining convergence work)

1. Exact merge-control mechanism: YAML tags (compose-style `!override`/`!reset`) vs a per-key
   strategy declaration vs ordered multi-file. Constraint: must stay legible to a human reviewing
   the project file in a PR, and the schema validator must reject ambiguity loudly.
2. Same-break cleanup: drop vestigial fields (`network.mode` parse-compat, dead
   `network.http.forward_to`, etc.) in the same `version: 1 → 2` bump? (Cheap now, never cheaper.)
3. Verb-write mechanics: `rc allowlist add` already edits YAML — check how it handles comment
   preservation (yq round-trips famously eat comments; operator config files here are heavily
   commented and the comments are load-bearing documentation). A verbs interface that destroys
   comments is worse than files.
4. Interplay: tsf2.8's manifest-egress union and tsf2.9's `rc up --reload` drift work (in flight,
   other Fable's scope) both read the effective config — the provenance view should be designed
   so those seams plug in, not bolted after.
5. Migration story for the ~2 existing real configs (this machine's global + this repo's project
   file) — likely trivial, but say so explicitly in the design.

## Constraints (binding)

- Threat model: project config stays read-only inside the cage; any new write-verbs are host-side
  only; no self-grant path from inside a cage. ADR-024 (prompt-injection) applies.
- No tool blessing in rc (ADR-005 D12) — the redesign is about config *mechanics*, which are
  legitimately rc's invariant seam; keep tool/posture *content* on the operator side.
- ADRs evolve in place (no supersession chains). The landing zone is an ADR-021 evolution, with a
  possible interplay note on ADR-005 D12 if profiles survive review.

## Process expectation

Converse with the human to close the open questions → record the converged design on the bead
(`--design`, `--acceptance`) → fresh-context adversarial DESIGN review before any code (house
norm; it has already earned its keep twice today) → ADR-021 edit + decomposition into
implementation beads only after review + human sign-off. Beads discipline: `bd show`/`bd list`
only (never grep issues.jsonl); export flush is `bd export --all -o .beads/issues.jsonl`; stage
beads files explicitly (never `git add -A .beads/` — sweeps stray temp files). Commit as you go.
NEVER git push — human-approval gate.

## Reading list (orient before first substantive reply)

1. `bd show rip-cage-tsf2.10` (the seeded assessment)
2. ADR-021 (docs/decisions/ADR-021-layered-rip-cage-config.md) — the thing being evolved
3. ADR-005 D12 (docs/decisions/ADR-005-ecosystem-tools.md) — the composition philosophy guardrail
4. `.claude/skills/configure-cage/SKILL.md` — freshly accurate; its 3-layer table is the UX being
   redesigned; its placement-rule paragraph is DEBT 1's workaround in the wild
5. docs/reference/config.md + egress.md (freshly swept, accurate field inventory)
6. `bd show dotpi-3bi.25` from ~/code/personal/dotpi (verbs-over-scopes inspiration)
7. This repo's live examples: `~/.config/rip-cage/config.yaml` + `tools.yaml` and `./.rip-cage.yaml`
   (the real artifacts the redesign must keep working)
