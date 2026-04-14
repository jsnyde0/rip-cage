# Skills in Containers — Research & Spike Results

**Date:** 2026-04-14
**Companion to:** [skills-in-containers-design.md](2026-04-14-skills-in-containers-design.md)
**Purpose:** Independent research findings and spike results to inform design decisions

---

## Spike 1 Result: FAILED — MCP Is Required

**Hypothesis:** Claude Code discovers skills from `~/.claude/skills/` via native
filesystem scanning, without any MCP server.

**Setup:**
- Mounted host `~/.claude/skills/` directly to `/home/agent/.claude/skills:ro`
  (no symlinks, no `.rc-context/` staging)
- Dockerfile pre-created `~/.claude/skills/` and `~/.claude/commands/` with
  agent ownership
- Verified files readable inside container:
  `~/.claude/skills/asana/SKILL.md`, `~/.claude/skills/cass/SKILL.md`, etc.
- Claude Code v2.1.100 inside container

**Result:**
- `/asana` — **worked** (MCP-based skill with a registered MCP server)
- `/send-it` — **"Unknown skill"** (filesystem-only, no MCP server)

**Conclusion:** Claude Code does NOT discover skills from the filesystem. The
`ms` MCP server (or equivalent) is the required discovery mechanism. **Branch A
is eliminated. Branch B (or alternatives below) is the path forward.**

**Incidental finding:** Skills that are symlinks on the host (e.g.,
`send-it` -> `~/code/mapular/platform/...`) appear as broken symlinks inside the
container because the target paths don't exist. Any solution must resolve
symlinks before mounting, or mount the resolved paths.

---

## Simple-Cause Theories: Both Ruled Out

Two simpler explanations for "Unknown skill" were investigated and eliminated:

### CLAUDE_CONFIG_DIR environment variable (GitHub issue #36172)
- **Claim:** Setting `CLAUDE_CONFIG_DIR` (even to `~/.claude`) breaks skill discovery
- **Verified:** The bug is real and documented
- **Ruled out for us:** Grep of entire repo shows zero matches for `CLAUDE_CONFIG_DIR`.
  Neither Dockerfile, rc, init-rip-cage.sh, nor zshrc set this variable.

### YAML frontmatter multi-line descriptions
- **Claim:** Prettier-reformatted multi-line description fields cause "Unknown skill"
- **Ruled out:** The `n8n-workflow` skill uses multi-line YAML (`>` block scalar,
  8 physical lines) and works fine on the host. Multi-line descriptions don't
  inherently break discovery.

---

## Competitive Landscape: Nobody Has Built This

Four projects were analyzed in depth. None are viable replacements for what
we need (a lightweight, stdlib-only MCP server that replaces `ms` for
container use).

### K-Dense-AI/claude-skills-mcp (374 stars)
- **Status:** Abandoned (April 2026 README: "no longer maintained")
- **Problem:** Semantic search over skill catalogs, not serving skills to Claude Code
- **Deps:** PyTorch, sentence-transformers (~250MB). Absurd for a container shim
- **Tools:** 3 tools, none matching `ms` interface
- **Verdict:** Dead, wrong problem, heavy

### jcc-ne/mcp-skill-server (1 star)
- **Status:** v0.1.2, single author, 2 months old
- **Problem:** Skill execution (runs scripts via subprocess), not discovery/serving
- **Deps:** `mcp`, `pydantic`, `pyyaml` — not stdlib-only
- **Tools:** 4 tools (`run_skill` instead of `show`/`load`)
- **Verdict:** Wrong abstraction, too immature

### Dicklesworthstone/meta_skill (148 stars)
- **Status:** Active, production Rust CLI with MCP server
- **Problem:** Full skill management platform (Tantivy search, SQLite, Thompson sampling)
- **Relevant:** Its MCP server exposes 12 tools including search, load, lint — close to `ms`
- **Not usable:** Full Rust binary with heavy deps, different skill format, its own ecosystem
- **Lessons to steal:**
  - Stderr for debug logs in MCP servers (stdout is the protocol channel)
  - ANSI sanitization before JSON-RPC responses
  - Three-layer JSON safety (detect -> sanitize -> validate)

### Dicklesworthstone/jeffreysprompts.com (98 stars)
- **Status:** Active, TypeScript prompt discovery platform
- **Problem:** Web-based prompt curation and export, not container skill serving
- **Lessons to steal:**
  - JSON-first CLI design (detect TTY, structured output by default)
  - Scan-once caching (enumerate at startup, serve from memory)
  - Exports to SKILL.md format natively (ecosystem convergence on this format)

### Community Docker setups
- **ClaudeBox** (1k+ stars): Does not handle skills. Uses commands exclusively. See below.
- **Docker MCP Toolkit:** For external APIs, not skill discovery
- **Anthropic's own devcontainer:** Mounts `~/.claude` but doesn't solve skills
- **GitHub issue #26254:** Confirms skills-in-containers is a known, unfixed gap

---

## ClaudeBox Architecture Comparison

ClaudeBox is the most mature Claude Code sandbox (1k+ stars). They take a
fundamentally different approach that sidesteps the skills problem entirely.

| Aspect | ClaudeBox | rip-cage |
|--------|-----------|----------|
| Skills | Don't use them. Ship **commands** (`~/.claudebox/commands/*.md`) | Mounts `~/.claude/skills/` from host |
| MCP | No custom servers. Uses `--mcp-config` flag to merge configs | Considering Python MCP shim |
| Config | Three-tier merge (user/project/local) via `jq` | Single `settings.json` copy on start |
| Security | Network-level (`iptables` allowlist) | Command-level (DCG + compound blocker) |
| User model | `runuser` to drop privileges | `sudo` with exact-path restrictions |
| Auth | Mounts `.claude.json` conditionally | Keychain extraction -> `.credentials.json` |
| Per-project | Slot directories with volume mounts | Container per project |

**Key insight:** ClaudeBox uses commands (markdown files in `~/.claude/commands/`)
as their extension mechanism. Commands work via native filesystem discovery —
no MCP server needed. They trade the progressive disclosure of skills (loaded
on demand) for the simplicity of commands (always available).

---

## Industry Patterns for Host-Only Tools in Containers

| Pattern | Who uses it | Trade-off |
|---------|------------|-----------|
| Ship binary in image | Codespaces, Gitpod | Best isolation; `ms` is private/macOS-only |
| Socket mount from host | Docker-in-Docker, VS Code | Simple but couples to running host process |
| Ship compatible server | VS Code (server agent in container) | Moderate protocol coupling, self-contained |
| Accept limitation | Nobody for this problem | Community actively building workarounds |

The VS Code pattern (ship your own compatible server in the container) is the
closest analogue to Branch B.

---

## Options for the Design Doc

With Spike 1 failed and the competitive landscape clear, three options remain:

### Branch B: Python MCP Shim (original proposal)
- ~100 lines stdlib Python, implements list/show/load/search
- Self-contained, no host dependency, clean upgrade path to `ms`
- Nobody else has built this — we'd be first
- Incorporate: stderr logging, ANSI sanitization, scan-once caching

### Option C: Skills-to-Commands Conversion
- At container start, transform SKILL.md -> command .md files in `~/.claude/commands/`
- Zero MCP infrastructure needed
- Trade-off: loses progressive disclosure (commands always loaded into context),
  loses `/slash-command` invocation, may bloat context with 50+ skills
- Inspired by ClaudeBox's commands-only approach

### Option D: Host MCP Forwarding via --mcp-config
- Use ClaudeBox's pattern: merge host MCP configs into container via `--mcp-config` flags
- Requires host `ms` to be network-accessible or socket-mountable
- Trade-off: couples container to host availability, breaks in CI/headless

### Recommendation
**Branch B remains the strongest option.** It's self-contained (no host dependency),
maintains full skill UX (progressive disclosure, `/slash-command` syntax), has a
clean upgrade path, and the protocol surface is small (3 real tools). The ~100
lines of stdlib Python is less maintenance burden than the operational complexity
of Options C or D.

Option C is a viable fallback if MCP protocol compliance proves harder than
expected. Option D is only viable for interactive use, not CI/headless.
