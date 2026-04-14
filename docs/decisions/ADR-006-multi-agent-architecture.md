# ADR-006: Multi-Agent Architecture (Directional)

**Status:** Proposed
**Date:** 2026-03-27
**Design:** [Multi-Agent Architecture](../2026-03-27-multi-agent-architecture.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [Flywheel Investigation](../2026-03-27-flywheel-investigation.md)

## Context

Rip-cage Phase 1 runs one agent per container. The flywheel investigation of Emanuel's ecosystem (NTM, SLB, Agent Mail, FrankenTerm, CAAM) surfaced proven patterns for multi-agent orchestration. This ADR establishes directional decisions so Phase 1 implementation does not foreclose multi-agent support. These decisions are directional, not final -- they will be revisited with implementation-specific ADRs when each tier is built.

## Decisions

### D1: Progressive tiers, not big-bang

**Firmness: FIRM**

Multi-agent support is delivered in three tiers, each independently useful:
- Tier 1: Multiple containers, shared bind mount, git coordination (already works)
- Tier 2: Swarm grouping with `rc swarm`, broadcast, lifecycle management
- Tier 3: Agent Mail for structured coordination, SLB for peer approval, dashboard

**Rationale:** NTM and ACFS both evolved incrementally. Big-bang multi-agent systems are brittle -- each tier should be usable on its own before the next is built. Tier 1 covers most real use cases (2 agents on different parts of the same repo). Tier 2 adds convenience. Tier 3 adds coordination for overlapping work.

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
