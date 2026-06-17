# ADR-027: Agent-Substrate Projection into the Cage

Status: PROPOSED — D1 FIRM (human-confirmed 2026-06-16), D2 FLEXIBLE, D3 EXPLORATORY
Date: 2026-06-16 (D2 prose revised 2026-06-17 — describe the shipped hardcoded-symmetric interim accurately)

## Context

A pi orchestrator running *inside* a rip-cage cage has zero methodology skills today: the cage bakes only `dcg-gate.ts` and bind-mounts only `~/.pi/agent/auth.json`. Claude Code's skills/commands/agents ARE projected (ro-mount of `~/.claude/{skills,commands,agents}` → `.rc-context/*` → `init-rip-cage.sh` symlink). This asymmetry blocks the dotpi self-driving factory: the drover spawns `pi --prompt "/skill:send-it <bead>"` (the ADR-003 D7 keystone), and the spawned sessions dispatch implementer/reviewer sub-agents.

Verified facts (2026-06-16) that shaped this ADR:
1. **Skill discovery is native** — pi scans the filesystem (`readdirSync` of `<PI_CODING_AGENT_DIR>/skills`; any dir with a `SKILL.md` + `description`), invoked `/skill:<name>`. No MCP shim (unlike CC, whose `meta-skill` shim exists because CC ignores the filesystem).
2. **Sub-agent spawning is not native** — pi ships 6 tools (read/bash/edit/find/grep/write) and no spawn primitive; dotpi's `subagent` extension provides it (registers a `subagent` tool wrapping `pi -p` + role loading). So instruction-content alone lets skills *resolve* but not *run* — the `subagent` extension must be projected too.
3. **The `subagent` extension is tool-only** — it calls `pi.registerTool` and registers no `tool_call` handler (`dotpi/agent/extensions/subagent/index.ts:510`), so it cannot interfere with the DCG guard.
4. **pi's `tool_call` blocking is monotonic** — a handler can only return `{block:true}`; there is no "allow" return that overrides a prior block (pi docs/extensions.md). So a co-loaded extension cannot "allow past" the guard. (A separate vector — a malicious handler ordered *after* the guard mutating `event.input.command` post-approval — exists in general but not for the vetted `subagent` extension; it is the epic's validator's job, and relates to rip-cage-olen below.)
5. **Host symlink shape** — `~/.pi/agent/{prompts,roles}` are *relative* symlinks into the dotpi repo; rip-cage's symlink-follow machinery only acts on absolute links and defaults to read-write, so projection must resolve realpaths and force `:ro` explicitly.

This surfaced a question the corpus does not own: **what host substrate is admissible into a cage, and how is it projected?** ADR-019 is pi-specific (config); ADR-005 owns archetypes; ADR-021 D6 / ADR-026 D5 are the seam pattern. None owns the cross-agent admission rule. This ADR does.

## Decisions

### D1 (FIRM) — Agent-substrate admission rests on containment + read-only host-ownership, not on restricting executable code

The cage exists **precisely to contain a coding agent executing arbitrary code** — DCG, the egress firewall, non-root, and the fs sandbox are the safety model. Skills already carry executable scripts (CC and pi alike), so "inert content" was never the real category. **Host agent-substrate — skills (incl. scripts), prompts, roles, AGENTS.md/SYSTEM.md, AND extensions — is admissible to run inside the contained cage**, under two invariants:

- **(a) read-only + host-owned.** The mount is `:ro` (no cage→host write-back; a compromised cage can't rewrite host substrate) and the source is host-owned / not-agent-writable (closes the ADR-005 D7 pre-stage threat). This is the property that already justifies mounting `CLAUDE.md`/CC-skills read-only — not "inertness" (`SYSTEM.md`/`AGENTS.md` auto-inject; skills run scripts). **Note:** read-only projection is *strictly safer* than the former status quo, where the baked guard's own directory was agent-writable (rip-cage-olen — **closed 2026-06-17**: the guard file + its `extensions/` dir are now root-owned, so an in-cage agent can neither replace the guard nor drop a competing extension).
- **(b) cannot weaken the welded safety floor.** A *projected* extension is admissible only when it cannot disable or bypass the floor. For the interim (D2) this is established **per-extension by vetting** the specific extension projected (e.g. the `subagent` extension is verified tool-only, no `tool_call` interceptor — fact #3) combined with **read-only** projection (the agent cannot mutate the projected copy) and pi's **monotonic block** (fact #4). The *general* mechanism — a fail-closed validator that rejects any projected extension hook that mutates a command post-approval, shadows the guard, or registers a bypassing interceptor — is built by the D3 seam (the MULTIPLEXER hook-bounds checks at `rc:6766+` are the template). This ADR does NOT assume "the floor is already uncrossable from inside": that holds for the config vector (ADR-025) and, as of **rip-cage-olen (closed 2026-06-17)**, for the **pi** agent-writable-extension vector (the baked guard + its `extensions/` dir are root-owned, so the agent cannot replace the guard nor drop a competing post-approval-mutating extension). The **CC** hook-registration vector (rip-cage-r9n4, open) remains. Making the floor uncrossable-from-inside was a sibling precondition, not a premise of D1; for pi's baked-guard-write vector it is now satisfied (the *projected*-extension case stays per-extension-vetted until the D3 validator).

`CONFIG` (settings/keybindings/trust/themes/models), `CREDENTIALS` (`auth.json` — the lone RW mount, ADR-019 D1), and `RUNTIME-STATE` (sessions/git/npm/logs) stay **cage-owned** — for config-integrity, secret, and mutable-state reasons respectively, unrelated to whether they execute.

This generalizes ADR-019 D1: the host→cage surface is no longer "only auth.json" but "auth.json (RW) + read-only host-owned agent-substrate." The previously-hardcoded CC projection is retroactively the canonical instance.

**Inline counter-argument (FIRM rigor, ADR-013 D3):** *ADR-019 D1 narrowed the pi host→cage surface to only `auth.json` to shrink attack surface under ADR-024; admitting skills/extensions re-expands it, and extensions are executable code that could subvert the guard — verification even confirmed the guard is self-disablable (olen).* **Rebuttal:** ADR-024's threat is the agent following hostile instructions from **attacker-controllable channels it fetches** (web/READMEs/MCP/workspace) — not operator-owned, host-controlled, read-only methodology substrate. "Executable code in the cage" is the cage's premise, not a new risk. And the guard-subversion concern is handled without assuming an uncrossable floor: the interim projects ONE vetted tool-only extension read-only (so the agent can't tamper with it and it registers no interceptor), and pi's block is monotonic (no allow-past). The agent-writable-guard weakness (olen) is *pre-existing and independent* of this projection — our read-only projection does not worsen it and is strictly safer than the status quo; olen's fix (**done for pi 2026-06-17**: root-owned guard + `extensions/` dir) closes the baked-guard-write vector, and the D3 validator closes the *projected*-extension case generally. The real anomaly the narrow D1 reading created is the CC/pi asymmetry.

**What would invalidate D1:** if a *read-only, vetted, tool-only* projected extension could still weaken the floor (e.g. pi's block turns out non-monotonic, or extension load can preempt the guard despite vetting), invariant (b)'s interim basis fails and extensions must be baked-root-owned only, not mountable.

| Alternative | Rejected because |
|---|---|
| Keep ADR-019 D1 "only auth.json"; bake everything | `reasoned:` methodology substrate changes constantly (edited this session) → image rebuild per edit; and leaves the CC/pi asymmetry unprincipled. |
| Exclude executable extensions; mount only "inert" content | `direct:` skills already carry executable scripts (CC + pi), and pi can't spawn sub-agents without the `subagent` extension (verified fact #2) — so "inert-only" neither matches reality nor unblocks the factory. |
| Admit substrate read-write (parity with auth.json) | `reasoned:` opens a cage→host write-back path — a compromised cage could rewrite host methodology/extensions. RO is necessary. |

### D2 (FLEXIBLE) — pi substrate (instruction-content + the `subagent` extension) projected as a hardcoded per-bundled-agent block, symmetric with CC (interim)

Project pi's instruction-content (skills, prompts, roles, AGENTS.md, SYSTEM.md/APPEND_SYSTEM.md seam) **and** dotpi's `subagent` extension into the cage, read-only, so `/skill:send-it` and `/drover` both *resolve and run*. The shipped interim (rip-cage-kstk) implements this as a **hardcoded per-bundled-agent projection block in `rc`** — a presence-gated (`[[ -d ~/.pi/agent ]]`) loop that is data-driven over *that agent's asset table* (`{asset → cage-path}` tuples), with **no `if/elif` branch on agent identity** beyond the presence gate. This is **symmetric with the pre-existing hardcoded CC projection block** (the `~/.claude/{skills,commands,agents}` mounts), which is the same shape.

This is **D12-clean by classification, not by manifest-derivation**: ADR-005 D12 forbids `rc` naming a specific *optional* tool (the herdr-leak anti-pattern); `claude` and `pi` are **bundled cage-infra** (per D1, agent-substrate projection is cage-infrastructure), so a hardcoded bundled-agent block does not trip D12. The interim is therefore **NOT yet manifest-derived** — `rc` does not read the seeded manifest to discover which agents declare substrate; that, and a per-agent substrate *declaration* schema, is the **D3 target** (the CONTENT-MOUNT archetype + manifest-derived allowed-set, isomorphic to the multiplexer allowed-set).

Mechanism per asset: resolve host realpath (the dotpi symlinks) → bind-mount `:ro` → `/home/agent/.rc-context/pi-<asset>` → ADR-023 denylist check (warn-and-skip, incidental tier) → symlink into `~/.pi/agent/<asset>` (pi discovers via `PI_CODING_AGENT_DIR`). The `subagent` extension is projected **selectively** (just that extension, vetted tool-only per fact #3) so the baked `dcg-gate` is not shadowed.

**Rationale:** projecting a bundled agent's substrate is cage-infrastructure, not optional-tool composition; the **bundled-vs-optional classification** (not manifest-derivation) is what keeps the hardcoded block D12-clean. This is **acknowledged interim debt** — pre-seam hardcode, NOT "floor", NOT a D12 exception — to be absorbed by D3. (A fresh-context reviewer read the hardcoded `pi` block as a D12 violation precisely because the earlier D2 prose promised manifest-derivation the interim never implemented; this revision removes that trap.)

**What would invalidate D2:** D3's seam ships → CC + pi migrate onto it and this retires.

### D3 (EXPLORATORY) — target: a composable agent-substrate seam carrying ALL substrate types incl. extensions

Lift BOTH the hardcoded CC projection and pi onto the composable pattern of `session.multiplexer` (ADR-021 D6) and `network.egress.mediator` (ADR-026 D5): agents become **manifest-declared configurable entries**, and their substrate — skills/prompts/roles **and extensions** — projects via a new **CONTENT-MOUNT archetype** (ro-mount + symlink-into-config; for extensions, + a **fail-closed floor-protection validator** that rejects projected hooks which mutate commands post-approval, shadow the guard, or register bypassing interceptors). Config selection + manifest-derived allowed-set + baked label + zero `rc` edits to add an agent.

**Nuance:** agent-substrate is **additive** (all present agents project simultaneously, TOOL-like set semantics), unlike single-select multiplexer/mediator. This is the "enable agent extensions, cleanly" design — extensions are admitted as *validated* providers, not excluded. The validator here is what makes invariant (b) structural rather than per-extension-vetted.

Anchors a follow-on **epic isomorphic to ta1o.5** (build seam → migrate CC → migrate pi off the D2 interim debt). Relates to rip-cage-olen (the guard-integrity fix the validated seam assumes — **closed 2026-06-17 for pi**).

**What would invalidate D3:** if CC+pi is the permanent agent set (no third harness), the archetype may be over-engineering vs acknowledged-debt hardcoded projections.

## Consequences

- D2 *actually unblocks* the in-cage drover dogfood (dotpi-3bi.8/.4) — skills resolve AND sub-agent dispatch runs — without weakening the floor.
- The CC/pi asymmetry is named interim debt with a defined retirement path (D3).
- Spawned child `pi` processes inherit the guard (they load the baked `dcg-gate.ts` via the inherited `PI_CODING_AGENT_DIR`); the agent-writable-guard weakness once tracked in rip-cage-olen is **closed for pi** (root-owned guard + `extensions/` dir).
- The "is executable substrate admissible?" question is resolved (yes, under containment + read-only/host-owned + per-extension vetting now / validator later), dissolving the earlier executable-exclusion.

## canonical_refs

- ADR-019 D1/D3 — pi cage-config (generalized by D1); init never mutates host dotfiles
- ADR-005 D7/D9/D11/D12 — host-only manifest; safety-floor-untouchable; fail-closed validator; composable-seam-not-bundler
- ADR-025 — floor uncrossable from inside for the config vector (the **pi** extension vector is now closed by rip-cage-olen; the **CC** registration vector remains open — rip-cage-r9n4)
- ADR-023 D5/D7 — symlink-target-parent denylist; post-realpath validation
- ADR-024 D1/D2 — prompt-injection threat model (attacker-channel scope, not operator substrate)
- ADR-021 D6 — session.multiplexer seam (reference pattern for D3)
- ADR-026 D5 — egress-mediator seam (reference pattern for D3; in-flight via ta1o.5)
- ADR-006 D7 — orchestration-lives-in-consumer (projection adds substrate, must not move orchestration into the cage)
- rip-cage-olen — agent-writable pi DCG guard, **closed 2026-06-17** (root-owned guard + `extensions/` dir; sibling floor-integrity fix)
- rip-cage-r9n4 — CC PreToolUse DCG hook registration is agent-editable (settings.json unregister vector; sibling, open)
- rip-cage-kstk — the interim ship; rip-cage-wlwc — the composable-seam epic
