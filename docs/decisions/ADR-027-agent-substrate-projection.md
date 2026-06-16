# ADR-027: Agent-Substrate Projection into the Cage

Status: PROPOSED — D1 FIRM (human-confirmed 2026-06-16), D2 FLEXIBLE, D3 EXPLORATORY
Date: 2026-06-16

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

- **(a) read-only + host-owned.** The mount is `:ro` (no cage→host write-back; a compromised cage can't rewrite host substrate) and the source is host-owned / not-agent-writable (closes the ADR-005 D7 pre-stage threat). This is the property that already justifies mounting `CLAUDE.md`/CC-skills read-only — not "inertness" (`SYSTEM.md`/`AGENTS.md` auto-inject; skills run scripts). **Note:** read-only projection is *strictly safer* than the status quo, where the baked guard's own directory is agent-writable (rip-cage-olen).
- **(b) cannot weaken the welded safety floor.** A *projected* extension is admissible only when it cannot disable or bypass the floor. For the interim (D2) this is established **per-extension by vetting** the specific extension projected (e.g. the `subagent` extension is verified tool-only, no `tool_call` interceptor — fact #3) combined with **read-only** projection (the agent cannot mutate the projected copy) and pi's **monotonic block** (fact #4). The *general* mechanism — a fail-closed validator that rejects any projected extension hook that mutates a command post-approval, shadows the guard, or registers a bypassing interceptor — is built by the D3 seam (the MULTIPLEXER hook-bounds checks at `rc:6766+` are the template). This ADR does NOT assume "the floor is already uncrossable from inside": that holds for the config vector (ADR-025) but NOT yet for the agent-writable-extension vector (rip-cage-olen, a separate P1) — making the floor uncrossable-from-inside generally is a sibling precondition, not a premise of D1.

`CONFIG` (settings/keybindings/trust/themes/models), `CREDENTIALS` (`auth.json` — the lone RW mount, ADR-019 D1), and `RUNTIME-STATE` (sessions/git/npm/logs) stay **cage-owned** — for config-integrity, secret, and mutable-state reasons respectively, unrelated to whether they execute.

This generalizes ADR-019 D1: the host→cage surface is no longer "only auth.json" but "auth.json (RW) + read-only host-owned agent-substrate." The previously-hardcoded CC projection is retroactively the canonical instance.

**Inline counter-argument (FIRM rigor, ADR-013 D3):** *ADR-019 D1 narrowed the pi host→cage surface to only `auth.json` to shrink attack surface under ADR-024; admitting skills/extensions re-expands it, and extensions are executable code that could subvert the guard — verification even confirmed the guard is self-disablable (olen).* **Rebuttal:** ADR-024's threat is the agent following hostile instructions from **attacker-controllable channels it fetches** (web/READMEs/MCP/workspace) — not operator-owned, host-controlled, read-only methodology substrate. "Executable code in the cage" is the cage's premise, not a new risk. And the guard-subversion concern is handled without assuming an uncrossable floor: the interim projects ONE vetted tool-only extension read-only (so the agent can't tamper with it and it registers no interceptor), and pi's block is monotonic (no allow-past). The agent-writable-guard weakness (olen) is *pre-existing and independent* of this projection — our read-only projection does not worsen it and is strictly safer than the status quo; closing it generally is the D3 validator + olen's fix. The real anomaly the narrow D1 reading created is the CC/pi asymmetry.

**What would invalidate D1:** if a *read-only, vetted, tool-only* projected extension could still weaken the floor (e.g. pi's block turns out non-monotonic, or extension load can preempt the guard despite vetting), invariant (b)'s interim basis fails and extensions must be baked-root-owned only, not mountable.

| Alternative | Rejected because |
|---|---|
| Keep ADR-019 D1 "only auth.json"; bake everything | `reasoned:` methodology substrate changes constantly (edited this session) → image rebuild per edit; and leaves the CC/pi asymmetry unprincipled. |
| Exclude executable extensions; mount only "inert" content | `direct:` skills already carry executable scripts (CC + pi), and pi can't spawn sub-agents without the `subagent` extension (verified fact #2) — so "inert-only" neither matches reality nor unblocks the factory. |
| Admit substrate read-write (parity with auth.json) | `reasoned:` opens a cage→host write-back path — a compromised cage could rewrite host methodology/extensions. RO is necessary. |

### D2 (FLEXIBLE) — pi substrate (instruction-content + the `subagent` extension) projected as bundled-agent cage-infra, manifest-derived, symmetric with CC (interim)

Project pi's instruction-content (skills, prompts, roles, AGENTS.md, SYSTEM.md/APPEND_SYSTEM.md seam) **and** dotpi's `subagent` extension into the cage, read-only, so `/skill:send-it` and `/drover` both *resolve and run*. Implement via a **loop driven by the bundled-agent set already declared in the seeded manifest** (claude, pi are seeded there) — `rc` reads which bundled agents declare substrate and projects each; it does NOT hardcode a `{claude, pi}` literal or a per-agent branch. This satisfies ADR-005 D12 (rc names no specific tool — the agent set comes from the manifest, exactly as the multiplexer allowed-set is manifest-derived) without inventing a "bundled-agent exception" D12 doesn't grant.

Mechanism per asset: resolve host realpath (the dotpi symlinks) → bind-mount `:ro` → `/home/agent/.rc-context/pi-<asset>` → ADR-023 denylist check (warn-and-skip, incidental tier) → symlink into `~/.pi/agent/<asset>` (pi discovers via `PI_CODING_AGENT_DIR`). The `subagent` extension is projected **selectively** (just that extension, vetted tool-only per fact #3) so the baked `dcg-gate` is not shadowed.

**Rationale:** projecting a bundled agent's substrate is cage-infrastructure, not optional-tool composition; the manifest-derived loop keeps it D12-clean. This is **acknowledged interim debt** — pre-seam hardcode, NOT "floor", NOT a D12 exception — to be absorbed by D3.

**What would invalidate D2:** D3's seam ships → CC + pi migrate onto it and this retires.

### D3 (EXPLORATORY) — target: a composable agent-substrate seam carrying ALL substrate types incl. extensions

Lift BOTH the hardcoded CC projection and pi onto the composable pattern of `session.multiplexer` (ADR-021 D6) and `network.egress.mediator` (ADR-026 D5): agents become **manifest-declared configurable entries**, and their substrate — skills/prompts/roles **and extensions** — projects via a new **CONTENT-MOUNT archetype** (ro-mount + symlink-into-config; for extensions, + a **fail-closed floor-protection validator** that rejects projected hooks which mutate commands post-approval, shadow the guard, or register bypassing interceptors). Config selection + manifest-derived allowed-set + baked label + zero `rc` edits to add an agent.

**Nuance:** agent-substrate is **additive** (all present agents project simultaneously, TOOL-like set semantics), unlike single-select multiplexer/mediator. This is the "enable agent extensions, cleanly" design — extensions are admitted as *validated* providers, not excluded. The validator here is what makes invariant (b) structural rather than per-extension-vetted.

Anchors a follow-on **epic isomorphic to ta1o.5** (build seam → migrate CC → migrate pi off the D2 interim debt). Relates to rip-cage-olen (the guard-integrity fix the validated seam assumes).

**What would invalidate D3:** if CC+pi is the permanent agent set (no third harness), the archetype may be over-engineering vs acknowledged-debt hardcoded projections.

## Consequences

- D2 *actually unblocks* the in-cage drover dogfood (dotpi-3bi.8/.4) — skills resolve AND sub-agent dispatch runs — without weakening the floor.
- The CC/pi asymmetry is named interim debt with a defined retirement path (D3).
- Spawned child `pi` processes inherit the guard (they load the baked `dcg-gate.ts` via the inherited `PI_CODING_AGENT_DIR`), modulo the agent-writable-guard weakness tracked in rip-cage-olen.
- The "is executable substrate admissible?" question is resolved (yes, under containment + read-only/host-owned + per-extension vetting now / validator later), dissolving the earlier executable-exclusion.

## canonical_refs

- ADR-019 D1/D3 — pi cage-config (generalized by D1); init never mutates host dotfiles
- ADR-005 D7/D9/D11/D12 — host-only manifest; safety-floor-untouchable; fail-closed validator; composable-seam-not-bundler
- ADR-025 — floor uncrossable from inside for the config vector (NOT the extension vector — see rip-cage-olen)
- ADR-023 D5/D7 — symlink-target-parent denylist; post-realpath validation
- ADR-024 D1/D2 — prompt-injection threat model (attacker-channel scope, not operator substrate)
- ADR-021 D6 — session.multiplexer seam (reference pattern for D3)
- ADR-026 D5 — egress-mediator seam (reference pattern for D3; in-flight via ta1o.5)
- ADR-006 D7 — orchestration-lives-in-consumer (projection adds substrate, must not move orchestration into the cage)
- rip-cage-olen — pre-existing agent-writable DCG guard (sibling floor-integrity fix)
- rip-cage-kstk — the interim ship; rip-cage-wlwc — the composable-seam epic
