# ADR-006: Multi-Agent Architecture (Directional)

**Status:** Proposed (revised 2026-06-13 — D7 re-decided: the mechanical lever leaves rip-cage for the composed in-cage multiplexer; `rc agent`/`rc sessions` removed; rip-cage owns box-entry only)
**Date:** 2026-03-27
**Design:** [Multi-Agent Architecture](../2026-03-27-multi-agent-architecture.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [Flywheel Investigation](../2026-03-27-flywheel-investigation.md)

## Context

Rip-cage Phase 1 runs one agent per container. The flywheel investigation of Emanuel's ecosystem (NTM, SLB, Agent Mail, FrankenTerm, CAAM) surfaced proven patterns for multi-agent orchestration. This ADR establishes directional decisions so Phase 1 implementation does not foreclose multi-agent support. These decisions are directional, not final -- they will be revisited with implementation-specific ADRs when each tier is built.

## Decisions

### D1: Progressive tiers, not big-bang

**Firmness: FIRM**

Multi-agent support is delivered in three tiers, each independently useful:
- Tier 1a: Parallel tmux sessions in one cage (multiple agents sharing the same container, workspace, and credentials — lightest-weight shape)
- Tier 1b: Multiple containers, shared bind mount, git coordination (already works — use when full container isolation or per-cage `.rip-cage.yaml` differences matter)
- Tier 2: Swarm grouping with `rc swarm`, broadcast, lifecycle management
- Tier 3: Agent Mail for structured coordination, SLB for peer approval, dashboard

**Rationale:** NTM and ACFS both evolved incrementally. Big-bang multi-agent systems are brittle -- each tier should be usable on its own before the next is built. Tier 1a is the lighter-weight choice when agents share workspace, credentials, and container lifecycle but want independent terminals; Tier 1b remains the choice when full isolation (or per-cage `.rip-cage.yaml` differences) matters. Together Tier 1a and Tier 1b cover most real use cases (2 agents on different parts of the same repo). Tier 2 adds convenience. Tier 3 adds coordination for overlapping work.

**What would invalidate this:** If a use case requires Tier 3 coordination from day one (e.g., 5+ agents on tightly coupled code). In practice, start with fewer agents and looser coupling.

### D2: Shared bind mount is the default coordination model

**Firmness: FIRM**

All agents in a group share the same `/workspace` bind mount by default. Git is the coordination protocol -- agents work on branches, commit, and pull. No container networking is required for agent coordination.

**Rationale:** The filesystem is the simplest coordination substrate. Every tool already understands files and git. Container networking adds DNS, port management, and failure modes that are unnecessary when agents share a filesystem. Emanuel's ecosystem confirms this: NTM coordinates agents through tmux panes sharing a filesystem, not through network services.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Shared bind mount + git** | Simple, debuggable, tools already work | Merge conflicts on shared files |
| Container networking + API | Clean separation | Complexity, failure modes, port management |
| Shared Docker volume (not bind) | Isolation from host | Files not visible to user, harder to debug |

**What would invalidate this:** If agents need real-time sub-second coordination (e.g., collaborative editing). Git's granularity is too coarse for that. In practice, agent tasks are minutes-long, not seconds-long.

### D3: Container labels encode agent identity

**Firmness: FIRM**

`rc up` sets Docker labels on every container: `rc.swarm` (group name), `rc.agent.type` (planner/implementer/reviewer/general), `rc.agent.index` (integer within swarm), `rc.labels` (user-defined tags). `rc ls` exposes these labels in JSON output.

**Rationale:** Docker labels are the standard mechanism for container metadata. They are queryable via `docker inspect` and `docker ps --filter`, which means `rc ls` can filter by swarm, type, or custom tags without maintaining a separate registry. NTM uses an equivalent pattern with tmux pane naming conventions.

**What would invalidate this:** If container identity needs to change at runtime (labels are immutable after creation). Workaround: recreate the container with new labels, which is acceptable for the expected use cases.

### D4: Agent Mail is the Tier 3 coordination layer

**Firmness: FLEXIBLE**

For structured multi-agent coordination (Tier 3), Agent Mail (or an equivalent HTTP service) provides file reservations and async messaging. File reservations are advisory, not enforced.

**Rationale:** Agent Mail solves two problems that git alone cannot: (1) declaring intent before editing ("I am about to modify `src/auth/**`") and (2) async messaging between agents ("auth module is done, proceed with billing integration"). Advisory reservations are sufficient for cooperative agents -- enforced locking adds deadlock risk and complexity. The git-backed audit trail means all coordination decisions are reviewable.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Agent Mail (advisory)** | Simple, auditable, cooperative | No enforcement, relies on agent compliance |
| FUSE-based mandatory locks | Strong enforcement | Deadlocks, complexity, breaks standard tools |
| Convention files (`.lock`) | Zero infrastructure | No TTL, no messaging, no discovery |
| No coordination layer | Simplest | Agents clobber each other's files |

**What would invalidate this:** If a simpler convention (e.g., directory-level ownership via CODEOWNERS + branch-per-agent) proves sufficient for all practical cases. Agent Mail may be overkill if worktree isolation handles most conflicts.

### D5: Worktree isolation is optional, not default

**Firmness: FLEXIBLE**

Each agent shares the working directory by default. Worktree isolation (`git worktree add` per agent) is opt-in via a flag like `--worktree`.

**Rationale:** Most multi-agent scenarios involve agents working on different parts of the codebase (frontend vs backend, different features). Shared working directory is simpler: no worktree lifecycle management, no cleanup on container destroy, no confusion about which worktree is "main." Worktree isolation is valuable for parallel branch work on overlapping files, but that is the minority case.

**What would invalidate this:** If shared working directory causes frequent merge conflicts in practice. If that happens, flip the default to worktree isolation.

### D6: Monitoring is passive-first

**Firmness: FIRM**

Monitoring observes container state (tmux output, Docker stats, agent activity) without modifying agent behavior. Active intervention (pause stuck agents, inject messages, restart) requires explicit opt-in via policy flags or dashboard actions.

**Rationale:** FrankenTerm's architecture validates this: passive observation with zero side effects is safe at any scale. Active intervention has failure modes (pausing an agent mid-commit, restarting during a long operation) that require careful policy design. Starting passive means monitoring is safe to enable by default; active features can be added incrementally with appropriate safeguards.

**What would invalidate this:** If stuck agents are common enough that manual intervention becomes a bottleneck. In that case, add a conservative auto-intervention policy (e.g., pause after 30 minutes of no output, with notification).

### D7: Tier 1a = the in-cage multiplexer's job, not rip-cage's; orchestration lives in the consumer (re-decided 2026-06-13)

**Firmness: FLEXIBLE** (specializes ADR-002's FIRM containment boundary; the lever *shapes* may shift under implementation). **Re-decided 2026-06-13 (rip-cage-1f59):** the mechanical lever's *locus* moved — it is no longer a rip-cage command (`rc agent` / `rc sessions` removed) but a capability of the composed in-cage multiplexer. This *tripped* the prior "what would invalidate this" predicate below (a standalone-human use case becoming primary with no cockpit present), and is resolved not by rip-cage absorbing a watch/engage UX but by making the multiplexer — which *is* the cockpit/consumer — a swappable composed choice (ADR-021 D6 `session.multiplexer`, ADR-026 composability posture). The boundary principle (orchestration lives in the consumer; rip-cage stays containment) is unchanged; rip-cage simply stopped half-owning the lever. The shipped v0.7.0 `rc agent` was the bridge built before a real multiplexer story existed; the composable multiplexer subsumes it.

Tier 1a (D1) is delivered by the **in-cage multiplexer**, not by rip-cage commands. rip-cage owns the **box** (sandbox, egress, safety, box-entry); spawning, listing, attaching, and supervising the agents/sessions running *inside* a box is the multiplexer's job.

- **Spawn / list / kill an agent** is the multiplexer's native surface: `tmux new-session` / `tmux ls` / `Ctrl-b c` for the tmux choice; `herdr agent start` / `herdr agent list` + its blocked/working/done view for the herdr choice. rip-cage holds **no** `rc agent` / `rc sessions` command — both were removed (rip-cage-1f59).
- **Which multiplexer (if any)** is a config choice — `session.multiplexer: none | tmux | herdr`, default `none` (ADR-021 D6). Default `none` = normal terminal semantics (close the window → the agent ends, ADR-009 D1); there is **no in-rip-cage lever** in the default. Persistence-across-disconnect and the supervisor view are capabilities you opt into by picking a multiplexer.
- **Box-entry stays rip-cage's** (ADR-003-honoring): `rc up` / `rc attach` (lands in the configured entry — a shell for `none`, `tmux attach` for tmux, the herdr client for herdr) / `rc exec <cage> -- <cmd>`. Multiple agents under `none` are reachable as multiple independent box-entry terminals; the multiplexer adds persistence + a managed view, not the bare ability to run two. Cage-management (`rc ls` / `down` / `destroy` / `doctor`) is unchanged.

All orchestration intelligence — *which* agents to spawn, *when*, recursion across the ready-frontier, *when* to surface a human — lives in the consumer (e.g. the dotpi factory + cmux cockpit), never in rip-cage. rip-cage stays the containment layer.

Identity has two distinct layers: the **per-session handle** (the multiplexer's own session/pane name within one container — the tmux session name, herdr's pane id; also the identity the per-session Claude config isolation keys off, ADR-021 D6 / rip-cage-1f59) and ADR-006 D3's per-container Docker labels (coarser grain). The handle complements D3, it does not replace it.

**Concurrency is agent-specific, not a lever property.** The levers run any command; whether two agents *coexist* in one cage depends on the agent's own config-write safety. Validated 2026-06-06: `pi` is concurrency-safe (it file-locks its auth/config writes — pi-mono `core/auth-storage.ts` `withLock`), so the dotpi pi-orchestrator path works today. Claude Code is **not** safe concurrently (it rewrites the shared `~/.claude.json` non-atomically; a second instance startup-loops on config-not-found) — the Claude path is **delivered** by per-session config isolation (bead `rip-cage-p1p`, shipped 2026-06-08: a `claude` wrapper gives each session its own `CLAUDE_CONFIG_DIR`, seeded from an init-time snapshot).

**Rationale:** The point of Tier 1a within the larger self-driving factory (dotpi) is that rip-cage is a *composable asset* — a containment layer the factory orchestrates from outside, not an orchestration engine. Keeping rip-cage to mechanical levers (mechanism, not policy — the Unix / CLI-over-MCP split) lets the factory's spawn-policy, recursion model, and human-engagement surface (cmux's two-plane cockpit) compose *on top* without rip-cage duplicating cmux or growing intelligence it must then keep in sync. The arbitrary-`-- <command>` shape is the purest expression: the caller owns binary choice, resume, and session identity entirely.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **In-cage multiplexer owns the lever; rip-cage owns box-entry** (chosen 2026-06-13, rip-cage-1f59) | rip-cage stops half-owning the multiplexer; any multiplexer (tmux/herdr/none) composes; default-`none` is transparent | `reasoned:` superseded `rc agent`-as-a-rip-cage-command — see the 2026-06-13 re-decision note above |
| rc owns a swappable multiplexer *adapter* (`rc agent` / `attach` dispatch to tmux/herdr backends) | one unified rc verb set across multiplexers | `reasoned:` re-imports per-multiplexer adapter maintenance into rip-cage — the monolith rip-cage-1f59 backs out of; rejected for box-only |
| **Mechanical levers as rip-cage commands** (`rc agent`, original 2026-06-08 choice — superseded) | thin tmux session levers; no orchestration intelligence | `reasoned:` welded rip-cage to tmux and half-owned the multiplexer; the v0.7.0 bridge the composable multiplexer subsumes (re-decided 2026-06-13) |
| rip-cage owns spawn+watch+engage UX (mini-orchestrator) | self-contained for standalone humans | `reasoned:` duplicates cmux's cockpit and grows intelligence rip-cage must keep in sync with the factory; contradicts the composable-asset/containment boundary (ADR-002) |
| `rc agent` launches a configured agent *type* (not arbitrary command) | ergonomic common case | `reasoned:` forces rip-cage to hold a "default agent" + resume policy — a sliver of orchestration intelligence; the arbitrary-command form keeps it zero-policy and was chosen explicitly |
| OSC terminal-title auto-naming (cmux-style) as the name source | "free" descriptive names | `direct:` live probe 2026-06-06 — claude emits **no** OSC title in-cage; pi emits only a generic `π - agent`, not a task description. Low value; explicit `--name` is simpler and deterministic |
| One window per agent inside a single tmux session (cmux-tab style) | single attached view shows all agents at once | `reasoned:` collides with the existing session-level `rc sessions`/`--kill`/picker (`rc:4686/4693/4827`) and needs a parallel window-level surface; the single-view payoff is not load-bearing (the factory is headless, watching via cmux+events not tmux). Session granularity reuses the built surface — chosen 2026-06-08 |
| Report running/exited status in `rc sessions` | consumer can *see* an orchestrator exited | `direct:` `tmux.conf:25-26` runs `remain-on-exit on` **with** `pane-died 'respawn-pane'`, so an exited pane is auto-resurrected as a fresh shell — "exited" is not tmux-observable. Presence-only is the honest signal; agent completion is the consumer's (agent_end hook + events plane). Corrected 2026-06-08 (the earlier "exited windows linger" claim ignored the respawn-pane hook) |

**What would invalidate this (post-re-decision):** If box-only proves to leave a UX gap the composition seam can't fill — i.e. users genuinely cannot run multi-agent workflows without bespoke per-multiplexer knowledge that rip-cage could cheaply have abstracted behind a thin adapter. Signal: repeated requests for an `rc`-native "spawn/list agent" verb that behaves identically across multiplexers, such that the box-only boundary reads as friction rather than clean composition. (The *prior* invalidation predicate — standalone-human-primary + no cockpit present — was **tripped** by the default-`none` path and resolved by making the multiplexer the composable cockpit per the re-decision note above; it no longer applies as written.)

### D8: The cage completes the multiplexer's supervision surface via the tool's public integration CLI (added 2026-06-14)

**Firmness: FLEXIBLE** (refines D7's "multiplexer owns supervise" with the composition *locus*; the specific CLI verb and bundled-agent set may shift as herdr's surface or the shipped agents evolve).

When `session.multiplexer: herdr` brings up the herdr server (`init-rip-cage.sh`), the cage **also installs each bundled coding-agent's herdr integration** via herdr's public `herdr integration install <agent>` CLI — looping over the agents present on PATH (pi, claude, …). Starting the server *without* the integrations ships a **half-built supervision surface**: herdr falls back to process-detection (the pane reads `idle` always) and never renders the semantic working/blocked/done states that are its supervise value-add (D7) and the autonomy value prop (an operator who walks away sees no agent state).

**Boundary principle (the reusable, cross-cutting part):** rip-cage is the *composition layer*; it wires tool↔tool integrations **only through each tool's public CLI/API, never by hand-placing another tool's internal files.** The cage calls `herdr integration install pi` (public) and lets herdr own where its extension lands; it does **not** copy herdr's `herdr-agent-state.ts` into pi's extension dir itself. Coupling stays at the stable public-API seam each tool designed for integrators — composition, not enmeshing — and each tool still does one thing (herdr supervises, pi/claude do agent work, the integration reports state; the cage composes them). This principle governs any future tool↔tool wiring the cage performs.

**Rationale:** `direct:` rip-cage-w621.3 (composed-cage validation, child A3) found the shipped herdr cage semantically dark — `init` runs `herdr server` but no `integration install`, so `herdr agent list` showed only process-detection `idle`; the `working` state was observable only after a manual `herdr integration install pi`. `reasoned:` completing a surface the cage half-built, via the tool's public CLI, is the same category as `init`'s existing auth / settings.json / hooks wiring — the agent-as-installer pattern the cage *is*. herdr exposes `integration install <agent>` (12 agents) precisely for an integrator; consuming that seam is the unix-composable path.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Cage auto-installs each present agent's integration via the public CLI** (chosen 2026-06-14) | supervisor view renders semantic states by default; generalizes over bundled agents; coupling at the public seam | `reasoned:` cage runs one more public-CLI call at herdr-server-start — negligible vs the dark-supervisor cost |
| Leave integrations opt-in (status quo: server only) | zero extra init work | `direct:` rip-cage-w621.3 / rip-cage-zshp — ships herdr's headline supervise feature dark by default; defeats D7 + the autonomy value prop; forces the human to hand-wire two tools the cage already bundled |
| Hand-place herdr's extension file into the agent's extension dir | no dependency on herdr's CLI surface | `reasoned:` reaches past both tools' public surfaces → enmeshing; brittle to herdr's internal format/path; the exact coupling the boundary principle forbids |
| Hardcode `herdr integration install pi` only | simplest one-liner | `direct:` the cage bundles pi **and** claude — pi-specific doesn't generalize; claude-through-herdr would stay dark. Loop over present agents instead |

**What would invalidate this:** if herdr makes `integration install` implicit on `agent start` (the server auto-wires integrations), the cage's explicit install becomes redundant — drop it. Or if a bundled agent's integration-install proves to have a harmful init-time side-effect (blocks/slows cage start, or writes outside the agent's own config), gate it behind agent-active detection rather than install-for-all-present.

## Deferred

- **Kubernetes / cloud orchestration** -- local Docker only; VPS uses plain Docker
- **CAAM credential pooling** -- single credential per container through Tier 2
- **Enforced file locking** -- advisory reservations only
- **Custom MCP servers inside containers** -- base Claude Code only through Phase 1.
  **Exception (2026-04-14):** `skill-server.py` is an infrastructure shim that
  replaces the unavailable `ms` (meta-skill) binary on Linux. It exposes skill
  file content only, not custom agent tooling. This is not a Phase 2 agent-tool
  MCP server — it is a temporary compatibility layer until Anthropic publishes
  Linux binaries for `ms`. See [ADR-002 D18](ADR-002-rip-cage-containers.md)
  and [Skills in Containers design](../../history/2026-04-14-skills-in-containers-design.md).
- **Agent-to-agent direct communication** -- all coordination through Agent Mail or git
- **Distributed multi-machine fleets** -- each machine runs its own `rc` instance

## canonical_refs

- [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md) — the containment boundary D7 specializes (rip-cage limits blast radius; it is not an orchestration engine).
- [ADR-003 Agent-Friendly CLI](ADR-003-agent-friendly-cli.md) — `--output json` machine-parseable contract + `rc schema` introspection; `rc exec` is the D7 box-entry lever (re-decided 2026-06-13, rip-cage-1f59: `rc sessions` removed; see ADR-021 D6 for the in-cage multiplexer as the Tier-1a lever).
- [ADR-019 pi-coding-agent Support](ADR-019-pi-coding-agent-support.md) — pi is the concurrency-safe in-cage agent (validated 2026-06-06); the arbitrary-command lever must work for pi.
- [ADR-005 Ecosystem Tools](ADR-005-ecosystem-tools.md) — D7–D10 composable tool manifest; agent_mail (in-cage daemon) is the Tier 3 coordination layer that composes with Tier 1a.
- bead `rip-cage-p1p` — concurrent-Claude `~/.claude.json` clobber; **delivers** the Claude (not pi) concurrency path under D7 (shipped + closed 2026-06-08).
- bead `rip-cage-4c5` — composable tool manifest / agent_mail in-cage coordination harness (Tier 3 sibling).
- bead `rip-cage-1f59` — the D7 re-decision: in-cage multiplexer becomes a swappable composed tool (default `none`), `rc agent`/`rc sessions` removed, rip-cage owns box-entry only.
- [ADR-021 Layered rip-cage Config](ADR-021-layered-rip-cage-config.md) — D6 `session.multiplexer` enum, the config-layer expression of this re-decision.
- [ADR-026 Containment + Delegated Mediation](ADR-026-containment-mediation-identity.md) — the composability posture (rip-cage as composable substrate) this extends to the process/session layer.
- Consumer (cross-repo): dotpi `ADR-003` (factory two-plane model — orchestrators in the cage, cmux cockpit outside) + `dotpi-3bi` (self-driving bead factory) — the orchestration intelligence D7 deliberately keeps OUT of rip-cage lives here.
- bead `rip-cage-w621.3` — composed-cage validation (child A3) that surfaced the dark-supervisor gap D8 closes; `rip-cage-zshp` — the integration-not-auto-installed bug D8 canonicalizes the fix for.
- herdr `integration install <agent>` — the public composition CLI D8's boundary principle consumes (12 agents: pi, omp, claude, codex, …); `herdr integration status --outdated-only` for freshness.
