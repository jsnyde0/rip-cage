# ADR-003: Agent-Friendly CLI Interface for `rc`

**Status:** Proposed
**Date:** 2026-03-26
**Design:** [Agent-Friendly CLI Design](../2026-03-26-agent-friendly-cli-design.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [Rewrite Your CLI for AI Agents](https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/)

## Context

The `rc` CLI currently targets human users exclusively. All output is unstructured prose. Phase 3 of rip-cage envisions an orchestrating agent that manages container lifecycles programmatically — spinning up workers, monitoring health, tearing down completed tasks. This requires `rc` to be machine-readable.

Justin Poehnelt's article "You Need to Rewrite Your CLI for AI Agents" (Mar 2026) catalogs patterns for making CLIs agent-friendly. We evaluated all seven recommendations against rip-cage and selected the four with the highest impact-to-effort ratio.

## Decisions

### D1: `--output json` flag for structured output

**Firmness: FIRM**

Add `--output json` to all commands that return data or confirm actions (`ls`, `up`, `down`, `destroy`, `test`, `build`). Human-readable output remains the default. JSON goes to stdout; human messages go to stderr in JSON mode.

**Rationale:** This is the single highest-value change. An orchestrator needs to enumerate containers (`rc ls`), parse results of operations (`rc up`), and check health (`rc test`) without regex parsing. The article identifies this as step 1 for retrofitting any CLI.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **`--output json` flag** | Explicit, backward-compatible, simple | Two code paths per command |
| Auto-detect non-TTY → JSON | Zero config for piping | Surprising behavior, breaks `rc ls > file.txt` |
| NDJSON by default | Streaming-friendly | Breaking change, overkill for small payloads |
| Separate `rc api` subcommand | Clean separation | Duplicates every command, more surface area |

**What would invalidate this:** MCP surface makes the JSON CLI path redundant. (Even then, JSON output is useful for shell scripting.)

### D2: `--dry-run` on mutating commands

**Firmness: FLEXIBLE**

Add `--dry-run` to `rc up` and `rc destroy`. Runs all validation, reports what would happen, exits without side effects.

**Rationale:** The article recommends `--dry-run` for any mutation. `rc destroy` is irreversible (removes container + volumes). An orchestrator should be able to validate before committing. Also useful for humans previewing complex `rc up` invocations.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **`--dry-run` flag** | Standard pattern, easy to understand | Extra code path to maintain |
| `rc plan <command>` subcommand | Separate namespace | Unfamiliar pattern, doubles command surface |
| Confirmation prompt | Interactive safety | Blocks non-interactive (agent) use |

**What would invalidate this:** If `rc up` and `rc destroy` become idempotent and safe to retry (unlikely for destroy).

### D3: Input hardening with allowed roots

**Firmness: FIRM**

Validate all path arguments against an allowed-roots list. No default roots — `RC_ALLOWED_ROOTS` env var (colon-separated absolute paths) must be set explicitly. Reject paths with control characters, null bytes, or that resolve (via `realpath`, which follows symlinks — this is security-critical) outside allowed roots.

**Rationale:** The article emphasizes that "agents make predictable hallucination errors" and the CLI must be the last line of defense. `rc up` takes an arbitrary path and bind-mounts it into a container — an agent hallucinating `/etc` or `~/.ssh` as a project path would expose sensitive host files. Allowed roots constrain the blast radius to known project directories.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Allowed roots (allowlist)** | Strong guarantee, simple to reason about | Must configure per-user |
| Blocked paths (denylist) | No config needed | Easy to miss sensitive paths, bypassable |
| No validation (trust caller) | Zero effort | Agents will hallucinate paths eventually |
| Symlink resolution + warning | Catches some attacks | Complex, incomplete |

**What would invalidate this:** Container filesystem isolation becomes strong enough that bind-mounting any host path is safe (unlikely — bind mounts bypass container isolation by design).

### D4: Agent context in AGENTS.md

**Firmness: FLEXIBLE**

Extend the existing `AGENTS.md` with rules for AI agents invoking `rc` programmatically. Encodes invariants like "always use `--output json`", "always `--dry-run` before `rc destroy`", "don't construct container names, use `rc ls`".

**Rationale:** The article calls these "agent skills" — structured context that makes implicit knowledge explicit. Rip-cage already ships `AGENTS.md` for in-container agents; extending it for `rc` callers is near-zero effort.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Extend AGENTS.md** | Already exists, single source of truth | Mixes in-container and host-side rules |
| Separate CONTEXT.md | Clean separation | Another file to maintain |
| `rc --help` improvements | Discoverable | Agents don't read `--help` efficiently |
| MCP tool descriptions | Native agent context | MCP surface doesn't exist yet |

**What would invalidate this:** MCP surface with tool descriptions replaces the need for file-based agent context.

## Deferred

- **MCP surface** — CLI-first, MCP can wrap later when orchestrator exists
- **Schema introspection** — 8 commands; `--help` and AGENTS.md are sufficient
- **Field masks** — payloads are small, no context window concern
- **Response sanitization** — `rc` doesn't return untrusted external data
