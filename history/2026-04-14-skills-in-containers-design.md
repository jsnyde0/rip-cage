# Skills in Containers

**Date:** 2026-04-14
**Decisions:** [ADR-002 D17 (revised), D18 (new)](decisions/ADR-002-rip-cage-containers.md)

## Problem

Claude Code skills (`~/.claude/skills/<name>/SKILL.md`) are mounted into
rip-cage containers and symlinked to `~/.claude/skills`. Yet agents inside
the container see:

```
❯ Unknown skill: send-it
```

Despite the files being present at the correct path.

## Root Cause

Claude Code discovers skills via an MCP server — the `ms` (meta-skill) binary
from Anthropic (`github.com/anthropics/ms`). On the host, `~/.claude/settings.json`
registers:

```json
"mcpServers": {
  "meta-skill": {
    "type": "stdio",
    "command": "/Users/you/.local/bin/ms",
    "args": ["mcp", "serve"]
  }
}
```

Claude Code queries this server at session start to build its skill registry.
Without `ms` running, it has no skill registry — files on disk are invisible.

The container's `settings.json` (`/etc/rip-cage/settings.json`) has no
`mcpServers` block. `ms` is not in the container. Skills are mounted but
invisible.

**What `ms mcp serve` exposes** (probed live):
- Protocol: MCP 2024-11-05, tools-only (no resources, no prompts)
- 11 tools: `list`, `show`, `load`, `search`, `suggest`, `validate`, `lint`,
  `index`, `feedback`, `evidence`, `config`
- Claude Code uses at minimum: `list` (discovery at startup) and `load`/`show`
  (content injection at invocation)

**Why `ms` can't simply be installed in the image:**
- `ms` is macOS arm64 only
- The `anthropics/ms` GitHub repo is private — no public Linux releases
- `ms` is not bundled with the `@anthropic-ai/claude-code` npm package

---

## Investigation

### Spike 1 Result: FAILED — MCP Is Required

**Hypothesis tested:** Claude Code discovers skills from `~/.claude/skills/`
via native filesystem scanning, without any MCP server.

**Setup:**
- Mounted host `~/.claude/skills/` directly to `/home/agent/.claude/skills:ro`
  (no symlinks, no `.rc-context/` staging)
- Dockerfile pre-created `~/.claude/skills/` and `~/.claude/commands/` with
  agent ownership
- Verified files readable inside container:
  `~/.claude/skills/asana/SKILL.md`, `~/.claude/skills/cass/SKILL.md`, etc.
- Claude Code v2.1.100 inside container

**Result:**
- `/asana` — **worked** (this skill has a registered MCP server in settings.json)
- `/send-it` — **"Unknown skill"** (filesystem-only, no MCP server)

**Conclusion:** Claude Code does NOT discover skills from the filesystem.
The `ms` MCP server (or equivalent) is the required discovery mechanism.
Native filesystem discovery is not a viable path.

**Incidental finding — symlinks:** Skills that are symlinks on the host
(e.g., `send-it` → `~/code/mapular/platform/...`) appear as **broken symlinks**
inside the container because the target paths don't exist there. Any solution
must either resolve symlinks before mounting, or handle broken symlinks gracefully
at read time.

### Simple-Cause Theories: Both Ruled Out

**CLAUDE_CONFIG_DIR environment variable** (GitHub issue #36172): Setting this
variable (even to `~/.claude`) is documented to break skill discovery. Ruled out:
grep of entire repo shows zero matches — Dockerfile, `rc`, `init-rip-cage.sh`,
and `zshrc` never set `CLAUDE_CONFIG_DIR`.

**YAML frontmatter multi-line descriptions:** Prettier-reformatted multi-line
description fields were claimed to cause "Unknown skill." Ruled out: the
`n8n-workflow` skill uses multi-line YAML (block scalar, 8 physical lines) and
works fine on the host.

### Competitive Landscape: Nobody Has Built This

Four projects analyzed — none are viable replacements:

| Project | Status | Why not |
|---------|--------|---------|
| K-Dense-AI/claude-skills-mcp (374★) | Abandoned Apr 2026 | Wrong problem (semantic search, not serving); PyTorch + sentence-transformers (~250MB) |
| jcc-ne/mcp-skill-server (1★) | v0.1.2, 2mo old | Wrong abstraction (executes skills, not serves them); non-stdlib deps |
| Dicklesworthstone/meta_skill (148★) | Active, Rust | Full platform (Tantivy, SQLite, Thompson sampling); different skill format; not embeddable |
| Dicklesworthstone/jeffreysprompts.com (98★) | Active, TypeScript | Web-based curation platform; not container skill serving |

Community Docker setups (ClaudeBox 1k+★, Docker MCP Toolkit, Anthropic's own
devcontainer) all skip skills entirely or don't solve the in-container discovery
problem. GitHub issue #26254 confirms this is a known, unfixed gap.

**Lessons to steal from Dicklesworthstone/meta_skill:**
- Use stderr for debug logs — stdout is the protocol channel, mixing them corrupts JSON-RPC
- ANSI sanitization before JSON-RPC responses — terminal escape codes break JSON parsing
- Three-layer JSON safety: detect → sanitize → validate

**Lessons from jeffreysprompts.com:**
- Scan-once caching — enumerate at startup, serve from memory rather than hitting disk per call

**ClaudeBox comparison:**

| Aspect | ClaudeBox | rip-cage |
|--------|-----------|----------|
| Skills | Not used. Ship **commands** (`~/.claudebox/commands/*.md`) | Mounts `~/.claude/skills/` from host |
| MCP | No custom servers. `--mcp-config` flag for external configs | Python MCP shim (selected) |
| Config | Three-tier merge (user/project/local) via `jq` | Single `settings.json` copy on start |
| Security | Network-level (`iptables` allowlist) | Command-level (DCG + compound blocker) |

ClaudeBox's key insight: commands (`~/.claude/commands/`) work via native
filesystem discovery — no MCP server needed. They trade progressive disclosure
(skills loaded on demand) for simplicity (commands always available). Their
approach is a viable fallback but has meaningful trade-offs (see Option C below).

---

## Decision: Python MCP Shim (Branch B)

Branch A (native filesystem discovery) is eliminated by Spike 1.

Three remaining options:

| Option | Description | Verdict |
|--------|-------------|---------|
| **B: Python MCP shim** | ~100 lines stdlib Python, replaces `ms` in-container | **Selected** |
| C: Skills-to-Commands | Transform SKILL.md → command `.md` files at container start | Fallback |
| D: Host MCP forwarding | Mount host `ms` socket / use `--mcp-config` to delegate | Ruled out |

**Branch B is selected.** It is self-contained (no host dependency), maintains
full skill UX (progressive disclosure, `/skill-name` invocation, context loaded
on demand), has a clean one-command upgrade path when `ms` publishes Linux
binaries, and the protocol surface is small (3 real tools). The ~100 lines of
stdlib Python is less maintenance burden than the operational complexity of C or D.

**Option C rationale (fallback only):** Commands work via native discovery — zero
MCP infrastructure needed. But they are always pre-loaded into context, which
bloats context with 50+ skills and removes progressive disclosure. Loses
`/slash-command` invocation semantics. Use if MCP protocol compliance proves harder
than expected.

**Option D ruled out:** Couples container to a running host process. Breaks in
CI/headless environments. Not viable as a general solution.

---

## Implementation: skill-server.py

### Design Constraints

- **Python3 pre-installed** — Dockerfile line ~26 (`apt-get install -y ... python3`).
  No additional install needed.
- **Zero pip dependencies** — Python stdlib only (regex for frontmatter,
  json/sys for MCP protocol)
- **Server named `meta-skill`** — matches host, eliminates a variable
- **Stubs return empty/success, never errors** — silent degradation for
  unimplemented tools (`suggest`, `feedback`, etc.)
- **Long-lived process** — MCP stdio servers start once per session, not per
  invocation; Python startup time is irrelevant
- **Notifications must be silently discarded** — MCP requires the client to send
  a `notifications/initialized` notification after `initialize` and before any
  `tools/list` call. This is a JSON-RPC notification (no `id` field, no response
  expected). The server must discard messages without an `id` field rather than
  treating them as unknown requests.
- **Stderr for debug logs** — stdout is the protocol channel; any debug output
  on stdout corrupts JSON-RPC responses. All logging goes to stderr.
- **ANSI sanitization** — sanitize any text content before embedding in JSON-RPC
  responses. Terminal escape codes in SKILL.md content will break JSON parsing.
- **Scan-once caching** — enumerate `~/.claude/skills/*/SKILL.md` at startup,
  build an in-memory index, serve from memory. Avoids per-call filesystem hits.
- **Broken symlink handling** — skills that are symlinks on host pointing to
  paths not present in the container will appear as broken symlinks. Skip these
  gracefully (log to stderr, do not crash).
- **Crash resilience** — the main read loop must be wrapped in a top-level
  `try/except` that logs to stderr and continues rather than exiting. An
  unhandled exception on malformed input must not terminate the server.
- **ADR-006 exception** — ADR-006 D6 defers "custom MCP servers inside
  containers" to Phase 2+. `skill-server.py` is an infrastructure shim (it
  replaces a missing host binary, not a custom agent tool), and falls within
  the spirit of D18. ADR-006 D6-deferred is amended to carve out this case.

### Protocol Flow

```
Initialize → [client sends notifications/initialized, server discards] → tools/list
tools/call: list   → return skills from in-memory index (built at startup)
                     returns [] (empty array) when no skills are present — not an error
tools/call: show   → read full SKILL.md for named skill
tools/call: load   → alias for show
tools/call: search → substring match over skill names/descriptions (in-memory)
tools/call: *      → return empty success for all other tools
```

Frontmatter parsing via regex (no yaml library needed):
```python
import re
m = re.match(r'^---\n(.*?)\n---', content, re.DOTALL)
```

MCP stdio transport uses newline-delimited JSON (one message per line). Not
HTTP Content-Length framing.

### Wired Up in `settings.json`

```json
"mcpServers": {
  "meta-skill": {
    "type": "stdio",
    "command": "python3",
    "args": ["/usr/local/lib/rip-cage/skill-server.py"]
  }
}
```

`settings.json` is already COPY'd into the image. `init-rip-cage.sh` line 29
overwrites `~/.claude/settings.json` from `/etc/rip-cage/settings.json` on
every container start. This is intentional: the MCP server config is static
(no runtime state in `settings.json` needs to persist across restarts). Any
session-level settings Claude Code writes to `settings.json` (e.g., granted
permissions) are reset on restart — a known limitation of the current init
flow, pre-existing this design and out of scope here.

### Symlink Resolution

Skills that are symlinks on the host (e.g., `send-it` → `~/code/mapular/platform/skills/send-it/`)
will appear as broken symlinks inside the container because the symlink target
path doesn't exist in the container's filesystem namespace.

Two mitigations:

1. **`skill-server.py` handles gracefully (required):** When building the
   in-memory index at startup, skip any entry where `Path.resolve()` fails or
   `SKILL.md` is unreadable. Log the skip to stderr. This prevents crashes and
   gives useful diagnostics.

2. **`rc` resolves symlinks before mounting (optional, better UX):** If `rc`
   detects that `~/.claude/skills/<name>` is a symlink, it can mount the
   resolved target directory instead of the symlink. This makes all skills
   available regardless of how they're organized on the host. This is a
   follow-on improvement — not required for initial implementation.

The test script (`test-skills.sh`) validates that at least one skill is readable;
broken-symlink skills that get skipped will naturally fail this check if they
happen to be the only skills present.

### What Is NOT Implemented (Intentional Stubs)

- `suggest` — Thompson sampling / bandit-based skill recommendations
- `feedback`, `evidence` — provenance and ranking data
- `validate`, `lint` — skill quality checking
- `index` — pre-indexing for fast search (server indexes at startup instead)
- `config` — ms configuration management
- Semantic/BM25 search (keyword match only)

These are UX features on top of basic skill loading. Agents inside containers
invoke skills by exact name; they don't need ranking or quality scoring.

---

## Upgrade Path: When `ms` Linux Binary Becomes Available

When `anthropics/ms` publishes Linux binaries (repo is private as of 2026-04-14,
v0.1.0), the upgrade is:

**Dockerfile** (add `ms` binary):
```dockerfile
ARG MS_VERSION=0.1.0
RUN curl -L https://github.com/anthropics/ms/releases/download/v${MS_VERSION}/ms-linux-aarch64 \
    -o /usr/local/bin/ms && chmod +x /usr/local/bin/ms
```

**`settings.json`** (swap command and args — two fields):
```json
"command": "/usr/local/bin/ms",
"args": ["mcp", "serve"]
```

Remove `skill-server.py`. The Dockerfile addition and two-field settings.json
swap (command + args) are the full scope of the upgrade.

The server name (`meta-skill`), the mount, the init flow, and the test script
are all unchanged.

---

## What Does NOT Change

- The bind-mount itself: `~/.claude/skills` from host is always mounted
- The `:ro` security posture: skills are read-only inside the container
- The `rc.conf` allowlist model: unchanged
- The devcontainer path: same mounts, same init script

---

## File Changes

| Action | File |
|--------|------|
| Create | `skill-server.py` |
| Modify | `Dockerfile` (COPY skill-server.py) |
| Modify | `settings.json` (add `mcpServers` block) |
| Modify | `init-rip-cage.sh` (add `command -v python3` warning per ADR-005 D5 point 2) |
| Modify | `CLAUDE.md` (document skill availability in containers, per ADR-005 D5 point 3) |
| Update | `docs/decisions/ADR-002-rip-cage-containers.md` (D17 revised, D18 new) |
| Update | `docs/decisions/ADR-006-multi-agent-architecture.md` (amend D6-deferred carve-out) |

Branch B does not modify `rc` — symlink resolution is a follow-on improvement
(tracked separately), not a blocker for initial implementation.

**Note on file paths:** These paths assume current repo layout. If ADR-009 D4
(moving test scripts to `tests/`) lands before this change, adjust the
Dockerfile COPY source for `test-skills.sh` accordingly.
