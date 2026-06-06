# ADR-006: Multi-Agent Architecture (Directional)

**Status:** Proposed (revised 2026-06-06 — D7 specs Tier 1a as mechanical session levers)
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

### D7: Tier 1a = mechanical session levers; orchestration lives in the consumer

**Firmness: FLEXIBLE** (specializes ADR-002's FIRM containment boundary; the lever *shapes* may shift under implementation)

Tier 1a (D1) is delivered as a thin set of mechanical levers over the cage's tmux, holding **no orchestration intelligence**:

- `rc agent <cage> --name=<handle> -- <command>` — open a tmux window named `<handle>`, run `<command>` verbatim, return. rip-cage does **not** know or decide which agent binary runs, cold-start vs resume, or any session semantics — the caller supplies all of that in `<command>` (e.g. `pi --session <id>` performs a resume; rip-cage never grows a "session" or "resume" concept).
- `rc sessions <cage> [--output json]` — enumerate in-cage agent windows with status (running / exited), agent-parseable per ADR-003.
- `rc kill <cage> <handle>` — terminate one window by handle.
- `rc attach <cage> [--window=<handle>]` — connect a human to one window; **secondary** (standalone use), since the primary watch/engage surface for the factory consumer is external (the cmux cockpit, dotpi ADR-003 two-plane model).

All orchestration intelligence — *which* agents to spawn, *when*, recursion across the ready-frontier, *when* to surface a human — lives in the consumer (e.g. the dotpi factory + cmux cockpit), never in rip-cage. rip-cage stays the containment layer.

Identity has two distinct layers: the **caller handle** (`--name`, targets kill/attach/resume; per-window within one container) and ADR-006 D3's per-container Docker labels (coarser grain). The handle complements D3, it does not replace it. OSC terminal-title auto-naming was evaluated and rejected as a name source (see Alternatives).

**Concurrency is agent-specific, not a lever property.** The levers run any command; whether two agents *coexist* in one cage depends on the agent's own config-write safety. Validated 2026-06-06: `pi` is concurrency-safe (it file-locks its auth/config writes — pi-mono `core/auth-storage.ts` `withLock`), so the dotpi pi-orchestrator path works today. Claude Code is **not** safe concurrently (it rewrites the shared `~/.claude.json` non-atomically; a second instance startup-loops on config-not-found) — the Claude path is gated on per-session config isolation (bead `rip-cage-p1p`).

**Rationale:** The point of Tier 1a within the larger self-driving factory (dotpi) is that rip-cage is a *composable asset* — a containment layer the factory orchestrates from outside, not an orchestration engine. Keeping rip-cage to mechanical levers (mechanism, not policy — the Unix / CLI-over-MCP split) lets the factory's spawn-policy, recursion model, and human-engagement surface (cmux's two-plane cockpit) compose *on top* without rip-cage duplicating cmux or growing intelligence it must then keep in sync. The arbitrary-`-- <command>` shape is the purest expression: the caller owns binary choice, resume, and session identity entirely.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Mechanical levers, orchestration in consumer** (chosen) | rip-cage stays containment; factory + cmux compose on top; mechanism-not-policy | `reasoned:` requires a capable consumer (the factory) to be useful for AFK runs — acceptable, that is the target use |
| rip-cage owns spawn+watch+engage UX (mini-orchestrator) | self-contained for standalone humans | `reasoned:` duplicates cmux's cockpit and grows intelligence rip-cage must keep in sync with the factory; contradicts the composable-asset/containment boundary (ADR-002) |
| `rc agent` launches a configured agent *type* (not arbitrary command) | ergonomic common case | `reasoned:` forces rip-cage to hold a "default agent" + resume policy — a sliver of orchestration intelligence; the arbitrary-command form keeps it zero-policy and was chosen explicitly |
| OSC terminal-title auto-naming (cmux-style) as the name source | "free" descriptive names | `direct:` live probe 2026-06-06 — claude emits **no** OSC title in-cage; pi emits only a generic `π - agent`, not a task description. Low value; explicit `--name` is simpler and deterministic |
| Window auto-closes on agent exit (clean list) | `rc sessions` trivially reflects the live set | `direct:` the cage runs `remain-on-exit on`; exited windows linger. Reporting status (running/exited) is more honest and suits the consumer's exit-and-resume model (it can *see* an orchestrator exited) — chosen over forcing close-on-exit |

**What would invalidate this:** If a standalone (no-factory) human use case becomes primary and no external cockpit is present, rip-cage might need to absorb a thin watch/engage UX after all (promote `rc attach`/`rc sessions` from secondary, possibly add light monitoring per D6). Or if a consumer needs rip-cage to *remember* how to relaunch an agent (restart a crashed agent without the factory re-supplying the command), or to spawn-by-agent-type — either pushes a sliver of orchestration into rip-cage, contradicting the boundary. Signal: repeated requests for `rc` to "remember" an agent's launch command or to spawn by type rather than being handed the command.

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
- [ADR-003 Agent-Friendly CLI](ADR-003-agent-friendly-cli.md) — `rc sessions --output json` machine-parseable contract (D7 lever).
- [ADR-019 pi-coding-agent Support](ADR-019-pi-coding-agent-support.md) — pi is the concurrency-safe in-cage agent (validated 2026-06-06); the arbitrary-command lever must work for pi.
- [ADR-005 Ecosystem Tools](ADR-005-ecosystem-tools.md) — D7–D10 composable tool manifest; agent_mail (in-cage daemon) is the Tier 3 coordination layer that composes with Tier 1a.
- bead `rip-cage-p1p` — concurrent-Claude `~/.claude.json` clobber; gates the Claude (not pi) concurrency path under D7.
- bead `rip-cage-4c5` — composable tool manifest / agent_mail in-cage coordination harness (Tier 3 sibling).
- Consumer (cross-repo): dotpi `ADR-003` (factory two-plane model — orchestrators in the cage, cmux cockpit outside) + `dotpi-3bi` (self-driving bead factory) — the orchestration intelligence D7 deliberately keeps OUT of rip-cage lives here.
