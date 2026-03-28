# Design: Multi-Agent Architecture (Directional Sketch)

**Date:** 2026-03-27
**Status:** Draft
**Decisions:** [ADR-006](decisions/ADR-006-multi-agent-architecture.md)
**Origin:** Flywheel investigation of Emanuel's ecosystem surfaced patterns for multi-agent orchestration (NTM, SLB, Agent Mail, FrankenTerm, CAAM). This doc establishes the directional vision so Phase 1 choices do not foreclose Phase 2-3.
**Related:** [Rip Cage Design](2026-03-25-rip-cage-design.md), [Flywheel Investigation](2026-03-27-flywheel-investigation.md)

---

## Problem

Running a single agent per project is the Phase 1 model. But real agentic workflows quickly demand more: a planning agent and an implementation agent on the same codebase, two feature agents working in parallel on different branches, a review agent that checks work before commit. Today, you can run `rc up` twice for the same path, but there is no grouping, coordination, or monitoring across those containers.

Multi-agent matters because it unlocks parallel feature work, agent specialization (planner vs implementer vs reviewer), and faster iteration cycles. The question is not whether to support it, but how to do so progressively without overbuilding.

---

## Multi-Agent Models (Three Tiers)

### Tier 1: Multiple Containers, Shared Bind Mount

**Already works.** Run `rc up <path>` twice with different labels. Both containers see the same `/workspace` via bind mount. Agents coordinate through git: each works on a branch, commits, and the other sees the changes on pull.

What is needed from Phase 1 to support this cleanly:

- Container labels that encode identity: `rc.swarm`, `rc.agent.type`, `rc.agent.index`
- `rc ls --output json` must surface these labels for filtering
- Container naming already handles disambiguation via hash suffix when multiple containers target the same path

Tier 1 is sufficient for 2 agents doing independent work on the same repo (e.g., one on frontend, one on backend).

### Tier 2: Swarm Grouping

A `rc swarm` command for named groups of containers. Lifecycle management, broadcast messaging, and optional worktree isolation.

```
rc swarm create payments /path/to/project --agents 3
rc swarm send payments --all "Auth module is done, proceed with billing"
rc swarm ls
rc swarm down payments
```

Key capabilities:

- **Named groups** -- a swarm has a name and contains N containers for the same project path
- **Broadcast** -- send a message (injected as user input) to all agents in the swarm
- **Lifecycle** -- `swarm up/down/destroy` manages all containers in the group
- **Optional worktree isolation** -- `--worktree` flag gives each agent its own `git worktree`, avoiding merge conflicts during parallel branch work. Default remains shared working directory.
- **Agent types** -- labels distinguish planner, implementer, reviewer agents within a swarm

Containers still share the bind mount (or their respective worktrees under the same repo). No container networking needed. Git remains the coordination protocol.

### Tier 3: Coordinated Agents

Structured coordination via Agent Mail (or equivalent). File reservations prevent clobbering. Async messaging enables handoffs. SLB provides peer approval for dangerous commands.

Components:

- **Agent Mail** -- HTTP sidecar container. Advisory file reservations with TTL. Async markdown messaging with threading. Git-backed audit trail. Agents call via MCP or HTTP.
- **SLB** -- Two-person rule for dangerous commands. Risk tiers (CRITICAL needs 2 approvals, DANGEROUS needs 1, CAUTION auto-approves after timeout). Daemon on host, socket mounted into containers.
- **Dashboard** -- TUI showing all containers, agent states (Active/Thinking/Stuck/Idle), resource usage, recent messages. Pattern: passive observation by default, explicit intervention opt-in.

Tier 3 is justified when agents actively need to coordinate on shared files or approve each other's dangerous operations. Not needed until 3+ agents work on overlapping parts of the same codebase.

---

## Key Decisions That Phase 1 Must Preserve

These are constraints on Phase 1 implementation to keep multi-agent viable:

1. **Container labels** -- `rc up` must set Docker labels: `rc.swarm` (group name, default empty), `rc.agent.type` (planner/implementer/reviewer/general), `rc.agent.index` (integer within swarm), `rc.labels` (user-defined comma-separated tags). `rc ls` must expose these.

2. **Container naming for same path** -- Multiple containers for the same path already get hash-suffix disambiguation. This must remain stable. The `container_name()` function must not assume one container per path.

3. **Independent safety stacks** -- Each container has its own `settings.json`, hooks, and auto mode state. No shared safety state across containers. This is already the case and must remain so.

4. **Bind mount as default** -- The shared filesystem (bind mount at `/workspace`) is the coordination substrate. No container networking is required for agent coordination. This keeps the model simple and debuggable.

5. **Labels over config files** -- Agent identity lives in Docker labels, not in config files inside the container. This means `docker inspect` (and `rc ls`) is the single source of truth for who is who.

---

## Coordination Model

**Primary channel: shared filesystem via bind mount.** All agents see the same files. Git is the protocol -- agents work on branches, commit, pull. This is the simplest model and scales to 2-4 agents comfortably.

**Structured coordination (Tier 3): Agent Mail.** When agents need to explicitly reserve files or send messages, Agent Mail adds a structured layer on top of the filesystem. File reservations are advisory (not enforced by the filesystem). This is a deliberate choice -- enforced locking adds complexity and deadlock risk. Advisory reservations plus audit trail is sufficient for cooperative agents.

**What we do NOT use for coordination:**

- Container networking / service discovery -- unnecessary complexity when agents share a filesystem
- Message queues (Redis, RabbitMQ) -- overkill; Agent Mail's HTTP + SQLite is sufficient
- Shared Docker volumes (non-bind-mount) -- bind mount to the host path is simpler and keeps files visible to the user

---

## Isolation Model

Three levels, chosen per-agent:

| Level | Mechanism | When to use |
|-------|-----------|-------------|
| **Shared working directory** (default) | All agents see same `/workspace` | Independent work areas (frontend vs backend) |
| **Worktree isolation** | Each agent gets `git worktree add` | Parallel branch work on overlapping files |
| **Clone isolation** (Phase 2 VPS) | Each container clones the repo | Full isolation, no shared state |

Worktree isolation is a per-agent opt-in (`rc up --worktree`), not the default. It adds complexity (worktree lifecycle, cleanup on container destroy) that is unnecessary when agents work on non-overlapping files.

---

## Monitoring Vision

Progressive monitoring across tiers:

**Tier 1:** `rc ls --output json` shows all containers with labels, status, uptime. Sufficient for manual oversight.

**Tier 2:** `rc status <swarm>` adds agent state detection. Patterns from FrankenTerm: parse tmux pane output to classify agents as Active (producing output), Thinking (waiting for API response), Stuck (no output for N minutes), or Idle (at prompt). JSON output for programmatic consumption.

**Tier 3:** `rc dashboard` TUI. Live view of all containers grouped by swarm. Resource usage (CPU, memory). Agent state with color coding. Recent messages from Agent Mail. Policy engine for auto-intervention (pause stuck agents, notify on errors). Robot mode API: `rc robot state --output json`.

Design principle: **passive observation by default**. Monitoring reads container state, tmux output, and Docker stats. It does not modify agent behavior. Active intervention (pause, restart, inject messages) requires explicit opt-in via `--policy` flags or dashboard actions.

---

## What We Explicitly Defer

- **Kubernetes / cloud orchestration** -- rip-cage is local-first. VPS support (Phase 2) uses plain Docker, not K8s.
- **Distributed agent fleets** -- multi-machine coordination is out of scope. Each machine runs its own `rc` instance.
- **Custom MCP servers inside containers** -- Phase 1 uses base Claude Code. MCP servers are a Phase 3 addition.
- **CAAM credential pooling** -- single credential per container is sufficient through Tier 2. Credential rotation across a pool of accounts is Tier 3 at earliest.
- **Enforced file locking** -- advisory reservations only. No FUSE, no mandatory locks.
- **Agent-to-agent direct communication** -- all coordination goes through Agent Mail or git. No direct container-to-container channels.

---

## Summary

The multi-agent architecture is progressive: Tier 1 (already works), Tier 2 (swarm grouping), Tier 3 (coordinated agents). Each tier is independently useful. The key Phase 1 constraint is: add container labels for identity, preserve multi-container-per-path naming, keep safety stacks independent, and keep shared bind mount as the default coordination substrate. Everything else can be added incrementally.
