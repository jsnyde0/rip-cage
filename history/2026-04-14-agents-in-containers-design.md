# Agents in Containers

**Date:** 2026-04-14
**Decisions:** [ADR-002 D19, D20](decisions/ADR-002-rip-cage-containers.md)

## Problem

Claude Code agent definitions (`~/.claude/agents/<name>.md`) are not mounted
into rip-cage containers. When an agent inside the container calls
`Agent(subagent_type: "implementer")`, it silently falls back to the generic
built-in `Agent` type — the specialized instructions are gone and the
degradation is invisible.

Observed 2026-04-14: agent in container dispatched `Agent` instead of
`Implementer` despite the host having six custom agent definitions registered.

## Root Cause

The skills-in-containers fix (D17/D18) extended the asset mount loop to
`skills` and `commands`. Agent definitions live in a structurally separate
directory (`~/.claude/agents/`) that was never added to the loop.

On the host:

```
~/.claude/agents/
  implementer.md  → ~/code/mapular/.../agents/implementer.md
  reviewer.md     → ~/code/mapular/.../agents/reviewer.md
  code-reviewer.md
  debugger.md
  geospatial-analyst.md
  plan-writer.md
```

All six are symlinks into `mapular-platform/.claude/agents/`. Inside the
container, `~/.claude/agents/` simply does not exist.

## Security Analysis

### What mounting exposes

Mounting `~/.claude/agents/` requires also mounting the symlink-target parent:
`mapular-platform/.claude/agents/`. That directory contains only `.md`
instruction files — behavioral prompts, no secrets, no env vars, no
credentials.

**Exposure type:** Intellectual property (internal agent instructions), not
credentials. Same trust level as CLAUDE.md.

**Edit risk:** None. Mount is `:ro`. Container agents cannot modify the
mapular-platform source.

**Blast radius comparison to D8 (`.env` mounting, refused):** The `.env`
refusal was about secrets with external blast radius (API keys, DB passwords).
Agent definitions contain instructions — no external blast radius. This is the
same rationale that justified D17 for skills.

### Mitigations already in place

- Symlink-target parent is a subdirectory (`.claude/agents/`) not the repo
  root — adjacent `.env` and other secrets in mapular-platform root are **not
  in scope** of the mount
- Safety stack (DCG + compound-command blocker) still active inside the
  container — the agent cannot exfiltrate via shell even if it tries
- Future: if any agent definition ever contains sensitive instructions, an
  `agents_allowlist` in `rc.conf` (same pattern as proposed for skills in D17)
  can scope the mount

### Verdict

Mounting is safe to proceed with. The risk profile is identical to skills (D17).

---

## Discovery Mechanism: The Key Unknown

This is the critical design question. Skills require an MCP server for
discovery (Spike 1 confirmed — filesystem-only mounting fails). Do agents?

**What we know:**
- Skills: discovered via `ms` MCP server → `list` tool → skill registry
- Skills: files on disk are invisible without MCP (Spike 1 confirmed)
- Agents: discovered via `~/.claude/agents/` filesystem scanning (hypothesis)
- Agents: a different Claude Code concept — they're not slash commands, they're
  `subagent_type` values passed to the built-in `Agent` tool

**Why agents might use filesystem discovery (not MCP):**
- Agent definitions are loaded when the `Agent` tool is called — this is a
  core Claude Code tool invocation path, not a skill registry lookup
- The `ms` MCP server serves the "skills" namespace specifically; there is no
  known public API for an "agents" MCP server
- Agent type names in the `Agent` tool are strings; Claude Code likely resolves
  them by scanning `~/.claude/agents/<name>.md` directly

**Why agents might still require MCP:**
- Spike 1 showed Claude Code's discovery is more opaque than expected
- Skills also appear to be "just files" but still need MCP
- Claude Code may use a unified registry for both skills and agents

**Required spike:** Mount agents (filesystem only, no MCP changes) and verify
whether `subagent_type: "implementer"` resolves correctly in a container.
This is a fast spike — run `rc up`, dispatch `Agent(subagent_type: "implementer")`
in the container, observe result.

---

## Proposed Design

### Path A: Filesystem mount sufficient (expected)

Extend the `init-rip-cage.sh` asset loop and `rc` mount logic to include
`agents`, exactly parallel to `skills` and `commands`.

**Changes:**
1. `init-rip-cage.sh` line 62: `for _rc_asset in skills commands agents; do`
2. `rc cmd_up`: add `~/.claude/agents` to Docker bind-mount list (with
   symlink-parent collection, same as skills — see `_collect_skill_symlink_parents`)
3. `rc` devcontainer template: add agents bind-mount entry

**No new MCP server.** Agents are served from filesystem.

**Verification:** Inside container, confirm `~/.claude/agents/implementer.md`
is readable. Dispatch `Agent(subagent_type: "implementer")`. Confirm the agent
respects the implementer's system prompt, not the generic agent default.

### Path B: MCP required (fallback if Spike fails)

If filesystem mounting alone is insufficient, extend `skill-server.py` to also
serve agent definitions. Agents have a simpler structure than skills (no SKILL.md
wrapper, frontmatter is flat) so the extension is modest.

Or: wait until the `ms` binary publishes Linux releases and handles both skills
and agents natively (the D18 upgrade path).

**Assessment:** Path B is significantly higher effort. Attempt Path A first.

---

## Symlink Handling

All six current agent definitions are symlinks into
`mapular-platform/.claude/agents/`. The `_collect_skill_symlink_parents`
function in `rc` (added in the skills symlink fix) already handles this
pattern. Extending it to include `agents` requires only adding the directory
to the list it iterates over.

The resolved symlink target parent
(`~/code/mapular/platform/mapular-platform/.claude/agents/`) will be
bind-mounted read-only. Files in that directory that are not referenced by
any symlink in `~/.claude/agents/` are technically accessible but not surfaced.
This is acceptable — it's a directory we already trust (our own work repo).

---

## Test Coverage

Extend `tests/test-skills.sh` (or create `tests/test-agents.sh`) to verify:

1. `~/.claude/agents/implementer.md` readable inside container (filesystem check)
2. `~/.claude/agents/` contains expected count of agent definitions
3. If Path A works: dispatching `Agent(subagent_type: "implementer")` produces
   an agent that announces its type (behavioral check — may require a small
   integration test)

---

## Non-Goals

- **Per-container agent filtering** — all mounted agents are available to all
  containers. A future `agents_allowlist` in `rc.conf` could scope this.
- **Agents defined inside the workspace** — some projects define their own
  agents in `.claude/agents/` within the workspace. These are already
  accessible via the workspace bind-mount. This design is only about host-level
  `~/.claude/agents/`.
- **Agent-to-MCP shim** — deferred unless Spike confirms filesystem mount is
  insufficient.
