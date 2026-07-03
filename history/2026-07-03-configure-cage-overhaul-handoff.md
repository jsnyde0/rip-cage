# Handoff — configure-cage skill overhaul (for a refining reviewer)

**Date:** 2026-07-03
**Audience:** a fresh, high-capability model (fable) asked to **analyze, pressure-test, and refine** this design *before* implementation.
**Your job:** improve the design and the three beads below — find gaps, over-engineering, residual process-leak, and cleaner shapes. Do NOT implement. This doc gives you the full context so you spend zero effort re-gathering what's already known.

---

## 1. One-paragraph problem statement

rip-cage has a `configure-cage` skill (`.claude/skills/configure-cage/SKILL.md`): an agent-run interview that composes a cage's host manifest (`~/.config/rip-cage/tools.yaml`) plus per-project config. Applied to the "dotpi" project on 2026-07-03, two things went wrong: (1) the skill is **process-thick** — a numbered one-question-at-a-time interview over six fixed dimensions with "MANDATORY to surface" gates and a numbered composition procedure; (2) it produced a config that **composed cleanly but was never proven runnable** — the cage booted the agent into `/home/agent` with no beads DB (a real rip-cage design bug, since fixed) and baked a stale `bd` (still open). The interview wording was the minor pain; "looks-configured ≠ actually-runnable" was the real one. We are overhauling the skill to be **substrate-thick / process-thin** per the repo's core philosophy.

## 2. The governing philosophy (non-negotiable context)

rip-cage is deterministic about what is **invariant** (the containment floor + mechanical seams) and pushes to the **agent** what **varies** (which tools, how they wire). Two load-bearing rules bound this work:

- **ADR-005 D12 — "composable seam, not a bundler."** rc's *code* must never name, bundle, or bless an optional tool. Optional tools live as `examples/` recipes, never special-cased in the binary or the published default. The repo has been burned here before: *"it's how herdr leaked into the default manifest; hold it."* (quoted from `CLAUDE.md`).
- **ADR-012 — substrate-thick / process-thin.** Don't ossify model judgment into fixed step-orderings, checklists, keyword-gates, or numeric thresholds. Give the agent knowledge + legible material + mechanical tooling; let it compose by judgment. The bd memory `agentic-era-install-config-by-agents-not-scripts` is the project anchor; the user has stated this *repeatedly* and is sensitive to agents re-accreting process.

A subtle distinction that matters here: **deterministic tooling is GOOD** on the *invariant/mechanical* side (CLIs, scripts, `rc doctor`). The drift is only freezing the *varying* part (the composition/wiring). "Verify a cage is runnable" via `rc doctor` = good tooling. "Always ask these 6 questions in this order" = process-leak.

## 3. The five aligned decisions (already agreed with the user — refine, don't relitigate the direction)

- **D1 — skill spine = read a reference base manifest, then propose deltas by judgment.** The agent reads a maintained reference manifest (the current sane default), understands it, and proposes situational deltas — instead of composing from a blank interview.
- **D2 — two reference base manifests live in `examples/`, NOT blessed into rc code or the published `dist/default-tools.yaml`.** `minimal` (safety-composed floor) and `full` (walk-away: +herdr; mediator present but **commented-optional**, not hot). Keeping them in `examples/` is what keeps this a composable seam rather than a bundler (D12).
- **D3 — footguns become knowledge, not gates.** The DCG OPEN-posture residual and the pi headless-throttle are stated as lessons the agent relays by judgment, not "MANDATORY to surface" gates. (User: *"I prefer knowledge over gate."*)
- **D4 — runnability verification moves OUT of the skill into `rc doctor`/`rc test`.** "Fresh pane lands in `/workspace`, bd/git resolve, baked bd matches host" is invariant/mechanical tooling the agent invokes by judgment.
- **D5 — the skill is reconcile-aware.** It tells the agent it may be *reconciling* an existing manifest (read + diff), not always composing fresh.
- **No new ADR** — these *apply* existing FIRM anchors; they open no new decision space. (An ADR here would itself be process-heaviness.) Capture in the skill body + a bd memory written at overhaul-close.

## 4. The beads to refine (read authoritative state with `bd show <id>` — NOT the jsonl export)

- **Epic `rip-cage-k8p3`** — "Overhaul configure-cage skill: substrate-thick composition-by-judgment." Carries the full design (D1–D5).
- **Child `rip-cage-q7i5`** — rewrite `SKILL.md` substrate-thick + author `examples/manifests/{minimal,full}.yaml`.
- **Child `rip-cage-2cks`** — add the cage-runnability check to `rc doctor`/`rc test` (guards the two bugs below).

Related, already-filed:
- **`rip-cage-0rng`** (CLOSED) — the agent-cwd floor fix: caged agents now root at `/workspace` (docker `--workdir` + herdr `HERDR_STARTUP_CWD`). The runnability check's cwd assertion is its regression guard.
- **`rip-cage-aq70`** (OPEN) — cage bakes bd 1.0.2 vs host 1.0.5 → `bd status` schema error. The runnability check's version assertion guards it. (Also: `Dockerfile:3` `ARG BEADS_VERSION=v1.0.2` needs bumping.)

## 5. Grounding facts (so you don't re-discover them)

- **Current skill:** `.claude/skills/configure-cage/SKILL.md` (renamed from `construct-cage`, commit cdead48). It currently has the numbered interview + MANDATORY flags we're removing. **Read it first.**
- **Two existing defaults:**
  - `dist/default-tools.yaml` (~89KB, maintained) — the *published image's* composition: floor (beads/dolt/gh) + claude + pi + claude-recipe + pi-recipe + dcg + dcg-wiring + ssh-bypass-hook, DCG **OPEN** (no `--no-extensions`). This is the "minimal safety-composed" base.
  - `_manifest_default_yaml()` in `rc` (~rc:6472) — the **bare floor-only** manifest that `rc` *seeds* on first run. So a fresh operator's seeded file is thinner than `dist`. (We reframed this seed-vs-dist gap as intentional tiering, not a bug — the skill offers richer reference bases; the seed stays the safe minimum.)
- **Recipes to compose `full` from:** `examples/herdr/` (herdr-bin TOOL + herdr MULTIPLEXER), `examples/herdr-pi/` (herdr pi status extension launch_args), `examples/iron-proxy/` (the mediator — goes in `full` **commented out**). `examples/README.md` is the recipe index.
- **Runnability tooling homes:** `cmd_doctor` (rc:5796, per-container diagnostic), `cmd_test` (in-container safety-stack suite), `cmd_schema` (rc:10838). `rc generate-dockerfile` (`RC_MANIFEST_GLOBAL=<manifest> ./rc generate-dockerfile`) is how you prove a manifest parses/composes.
- **Config layers (the mental model the skill should teach):** (a) global image manifest `~/.config/rip-cage/tools.yaml`; (b) global posture `~/.config/rip-cage/config.yaml` + `rc.conf` (mount denylist, `RC_ALLOWED_ROOTS`); (c) per-project `<repo>/.rip-cage.yaml` (`session.multiplexer`, `ssh.allowed_hosts`, `network.mode`+allowlist, `mounts.config_mode`). `RC_ALLOWED_ROOTS` is a *launch guardrail* (which paths `rc up` may target), NOT a mount list — the cage mounts only the one project dir at `/workspace` plus a narrow dotfile whitelist minus a secret denylist.
- **The two footguns (state as knowledge in the skill):** DCG OPEN default reopens "vector-b" (a prompt-injected pi could write a self-loading bypass extension) as a knowingly-accepted residual bounded by containment (FIRM, ADR-027 D1/D4). pi headless default resolves the Claude subscription entitlement, which Anthropic throttles for third-party apps (400) — a scripted/herdr-spawned/`--print` pi can stall mid-run; pinning a static-key provider (`--model <provider/model>`, e.g. `openai-codex/gpt-5.5`) fixes it (rip-cage-tl6q / px6v spike).

## 6. Open questions worth your judgment (where refinement adds the most value)

1. **`full.yaml` vs `dist` drift.** `minimal.yaml` is ≈ `dist/default-tools.yaml`. Should `minimal` literally *be* `dist` (skill points at `dist` directly, no second copy), or a separate `examples/` file that will drift? Is a third "minimal reference" even needed, or does the skill point at `dist` for minimal and only add one new `full.yaml`? Find the shape with the least duplication.
2. **Reconcile without a procedure (D5).** How does the skill make "you may be reconciling — read + diff" a *judgment cue* rather than a diff-checklist? The dotpi failure and the rip-cage pi-recipe drift both came from assuming fresh; the fix must not become a mandated diff step.
3. **`rc doctor` check shape (bead 2cks).** Exactly which invariants, how to keep it tool-agnostic (the pane-cwd check must gate on "a multiplexer is composed" generically, never name herdr — D12), and `doctor` (interactive per-cage) vs `test` (CI/regression) placement. It must fail-loud on a `/home/agent` cage and on a stale-bd cage, and be vacuous on neither.
4. **Residual process-leak audit.** Re-read the three beads and the rewritten-skill *intent* for any surviving checklist/step-ordering/threshold. The user's explicit worry is that "overhaul" quietly re-thickens the skill. Flag anything that smells like a fixed procedure.
5. **Scope check.** Is the epic correctly two children, or does the `full.yaml` mediator-optional-block / the seed-vs-dist reframe deserve its own carve-out? Is anything under-specified for an implementer to execute without re-deciding?

## 7. How to run your pass

Read, in order: this doc → `bd show rip-cage-k8p3 rip-cage-q7i5 rip-cage-2cks` (authoritative) → the current `SKILL.md` → `dist/default-tools.yaml` (skim the entry list) → `examples/README.md`. Then return: (a) a findings list (gaps / over-engineering / process-leak / cleaner shapes), (b) concrete proposed edits to the three beads' `--design`/`--acceptance`, (c) a verdict on the two-reference-manifest approach and the `rc doctor` check shape. Cite ADR-005 D12 / ADR-012 when you flag a principle violation.

---

## 8. Refinement outcome (2026-07-03, fable pass — APPLIED to the beads; `bd show` is authoritative)

The five open questions were resolved and folded into the three beads. Headline changes:

1. **Q1 — no new reference manifests at all (revises D2's artifact shape, keeps its direction).** `dist/default-tools.yaml` is 143 lines whose recipe entries carry *generated* base64 `install_cmd` blobs — its own header says "re-run each recipe's `build-fragment.sh` and copy the result here to update." Any copied manifest (`minimal.yaml` AND `full.yaml`) duplicates generated content that silently drifts on every recipe update — the exact failure class D5 cites (the pi-recipe drift). And "generated from the same fragments so it doesn't drift" (the q7i5 hedge) would be a sync mechanism, i.e. machinery. Resolution: **minimal reference = `dist/default-tools.yaml` pointed at directly** (it is the published composition, guaranteed current, and dist's header already declares it the single data-layer home of the blessing); **walk-away reference = a delta composition recipe** (`examples/compose-walk-away-cage.md`-style, fitting the existing `compose-rc-with-*.md` genre): dist + herdr + herdr-pi fragments, mediator situational (ADR-026), pi provider pin (the throttle lesson lands here naturally — it only bites walk-away runs). The parse/runnability proof moves to where it's honest: the *operator's* composed manifest via `rc generate-dockerfile`, then `rc doctor` post-build.
2. **Q2 — reconcile as world-fact + failure story, not procedure.** The skill states the fact ("rc seeds a tools.yaml on first run; past sessions may have composed one — you are probably not starting from zero") plus the two failure stories, and lets the agent decide to read/diff. Folded into q7i5.
3. **Q3 — doctor shape resolved, including a spec bug.** The generic pane-cwd check was **unimplementable as written**: spawning a fresh pane is not in the MULTIPLEXER provider contract (start/attach hooks only), so a tool-agnostic implementation doesn't exist without growing the contract or naming tools — D12 violation either way. Resolution: rc asserts *floor* invariants only (fresh-exec cwd == `/workspace`; bd+git resolve clean from `/workspace`); pane-level verification belongs to the multiplexer's own recipe. Also symptom-first severity: an in-cage bd schema error on the host-written store = FAIL (the honest aq70 symptom); bare host-vs-cage version skew = WARN (a host may legitimately differ). Home: `rc doctor` owns all checks; `rc test` gains the in-cage cwd+resolution cell. Folded into 2cks.
4. **Q4 — process-leak audit.** Leaks found and removed: the "byte-alignable / generated from the same fragments" hedge in q7i5 (a drift-sync mechanism); the frontmatter `description:` itself encodes the interview shape ("Interviews a human, one question at a time") and is the trigger surface — q7i5 now covers frontmatter explicitly. Kept-as-knowledge (not steps): fragment-order combination, the composed-launch-line transparency, "I don't run rc build", the anti-machinery spine section (already correct).
5. **Q5 — scope confirmed.** Two children is right; no carve-outs. The seed-vs-dist tiering needs no bead (dist's header already documents it). aq70 unchanged and correct (pin `v1.0.2` → host runs 1.0.5, verified).

Minor correction: §5 says dist is "~89KB" — it's 143 lines (~9KB); the entry list matches §5's composition claim exactly.
