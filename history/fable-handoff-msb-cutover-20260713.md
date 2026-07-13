# Fable handoff — msb-cutover merge window (2026-07-13)

**You are Fable**: the stronger-model reviewer / brain-of-loop for the rip-cage→microsandbox
migration epic (**rip-cage-tsf2**). The user relays reports from a mac-mini orchestrator
("the mini") that dispatches implementer subagents. You make the judgment calls — design
rulings, sequencing, ADR ownership, review acceptance — record them durably, and hand back
a copy-paste prompt for the mini. This doc orients a fresh Fable session picking up the arc.

## Where the durable record lives (read these first, in order)

1. `bd show rip-cage-tsf2` — the epic. Its **notes** carry every Fable ruling as
   marker-titled sections (this is the authority; the summaries below are orientation):
   - `## Fable decomposition review (2026-07-11)` — REVISE verdict, folds R1–R7.
   - `## Fable mid-flight rulings (2026-07-12)` — trio-dev parallel GO; S2 generator
     contract approved as S6 wiring target + two folds.
   - `## Fable cutover merge-unit rulings (2026-07-12)` — tsf2.1 blocks merge; merge unit
     = whole branch; cold-recreate reload approved + riders.
   - `## Fable merge-go rulings (2026-07-13)` — the four calls (below). **Latest.**
2. `docs/decisions/ADR-029-msb-migration.md` — migration anchor (D1 hard cutover, D2 engine
   deletion, D3 HTTPS+--secret, D4 curated allowlist + repair loop, D5 non-possession, D6 KVM gate).
3. `docs/decisions/ADR-013-test-coverage.md` **D8** (added 2026-07-13, commit 4cc61f8) —
   fix-on-target-not-twice policy for stale tests during an active migration. Fable-authored
   from the harness orchestrator's /compound recommendation.

## State at handoff

- Branch **msb-cutover @ 68172c9** is build-complete + reconciled: all slots (S1–S14 +
  tsf2.1 verb-gap) landed and adversarially reviewed; IOC merge-gate verified file:line;
  full host suite green on a clean manifest; Part-B baseline ledger is an ancestor;
  lint + structural-guard green.
- **Merge is a GO** (main @ d3c1b7f rulings; this doc's commit is later), conditioned on:
  - (a) **Anchor tag first**: annotated tag `pre-msb-cutover` on the pre-merge main tip,
    pushed BEFORE merging. Deliberately not `v*`-shaped — a v* tag triggers release.yml
    (~1.5h multi-arch GHCR publish) and fails its VERSION-match check. v0.12.1 stays the
    last *distributed* (brew/GHCR) pre-cutover release; the tag is the source-rollback
    anchor (ADR-029 D1 gets a one-line annotation naming both, during the merge window).
  - (b) tsf2.2 (dead `rc allowlist --observed/--from-observed`): fast-follow only if they
    FAIL LOUD today; silent no-op ⇒ one-line loud-fail stub on the branch.
    tsf2.3 (stale agent-facing docs): runtime-read test — any doc that ships into the cage
    or an in-cage agent is directed to at runtime joins the merge; host-side human docs
    are fast-follow. Audit tsf2.3 scope vs what S13's close claimed.
  - (c) Retired-archetype config (mediator/ssh) **hard-fail stands**, warn+skip rejected
    (silently skipping declared containment machinery = posture surprise, the
    false-confidence class ADR-029 D1 rejects). Rider: rejection message must be
    actionable — archetype name, offending file+entry, "retired in the msb migration
    (ADR-029 D2/D3)", exact fix (ssh → HTTPS + `auth.credentials`). Release-notes material.
  - (d) One-line confirm that the deny→fix→reload repair loop was proven round-trip
    INCLUDING post-reload session resume (cold-recreate rider from 2026-07-12 rulings).
  - (e) Mini pushes its **beads channel** before merging — at ruling time the host store
    still showed tsf2.1 open and tsf2.2–.5 nonexistent.
  - Mini handles the E7 ledger annotation (rip-cage-7atw.20 acceptance 3) during the merge
    window with exclusive main access; that closes 7atw.20.
- tsf2.4 (unwired test) + tsf2.5 (completions query docker ps): fast-follow CONFIRMED.
- **After merge — epic-close gate**: full post-migration host suite green ON MAIN +
  spot-check S13 write-backs (ADR-029 D4 cold-recreate record, ADR-022 D6 retirement,
  CLAUDE.md reload prose, banner flips — zero grep hits for "remain shipped and
  load-bearing in the Docker path"). Then parent re-verify + `/compound` at epic close
  (default-on).
- The golden-harness orchestrator's lane is drained and its session closed; its one
  routed-back item became ADR-013 D8 (done). Its stale claim that "the reload-IOC contract
  call is still open" is resolved — ruling lives in rip-cage-7atw.20 notes.

## Expected next input

The mini reports back with the merge sha + confirmations of conditions (a)–(e). Your job:
verify the confirmations are evidence-shaped (not intent-shaped — re-run at least one
falsifiable check yourself or demand file:line/command output), rule on anything new,
record rulings in rip-cage-tsf2 notes (new marker-guarded section asserting on
`## Fable merge-go rulings (2026-07-13)` as the prior marker), flush export, commit, push
both channels, hand back a mini prompt.

## Open threads beyond the merge

- rip-cage-o7tx — host-service seam (decide-or-dismiss, Fable's).
- rip-cage-4fxg — KVM gate, parked for the future VPS thread (ADR-029 D6).
- rip-cage-9xll — doc-drift pair (ADR-005 D7 archetype count + adding-a-tool.md).
- B2 probe leg PENDING-OPERATOR.
- Operator loose ends: bdvfs fixture dirs on the mini (`/Users/jonatanpi/tmp/bdvfs-*`)
  need manual rm (DCG-blocked); scratch repo `jsnyde0/httpspush-msb-spike-scratch` deletion.
- Test re-platform (safety suite + golden-master onto msb) absorbs the 5 re-homed
  authed-cage tests + deferred shell-integration probe (rip-cage-7atw.22 / ADR-013 D8 pattern).

## Operating discipline (binding, learned this arc)

- **Beads**: `bd show`/`bd list` are authoritative; never grep `.beads/issues.jsonl`.
  After every bd write: `bd export --all -o .beads/issues.jsonl`, commit, and push BOTH
  channels (`git push` + `bd dolt push`) — multi-device pattern, explicitly authorized.
  Pull both channels (`git pull`, `bd dolt pull`) before writing; on contested push,
  `bd import` + re-export resolves cleanly.
- **Notes appends**: marker-guarded read-merge-write python via `uv run` — assert the
  prior section's marker is present, no-op if own marker already there. Scripts from this
  arc are in the prior session's scratchpad; the pattern is small enough to re-author.
- **Bash**: no compound commands (&&/;/||) — repo hooks block them; split calls. DCG blocks
  destructive patterns; list blocked cleanups for the operator, never bypass. Never read
  `.env` into the session. Always `uv` for Python.
- **User communication contract**: messages must read cold in ~10s. No bare bead IDs or
  internal labels without a plain-English gloss on first mention. Lead with the outcome.
  Caveats mentioned in prose MUST also land inside the copy-paste mini prompt (user
  instruction, standing). Orient-then-ask on decisions; terse on confirmations.
- **Acceptance**: evidence-shaped, not intent-shaped — before accepting a "done", re-run
  one falsifiable check or require command output / file:line (bd memory
  b-mpb4llhx-8pe7dv).
