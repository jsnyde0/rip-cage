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

**What `ms mcp serve` exposes** (probed live 2026-04-14):
- Protocol: MCP 2024-11-05, tools-only (no resources, no prompts)
- 12 tools: `list`, `show`, `load`, `search`, `suggest`, `validate`, `lint`,
  `index`, `feedback`, `evidence`, `config`, `doctor`
- Claude Code uses at minimum: `list` (discovery at startup) and `load`/`show`
  (content injection at invocation)
- `notifications/initialized`: `ms` returns an error response (without `id`);
  the correct behavior per the MCP spec is to silently discard notifications —
  our shim does not respond to them

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
- **Notifications must be silently discarded** — MCP notifications have no `id`
  field and require no response. Claude Code sends `notifications/initialized`
  after `initialize` and may send `notifications/cancelled` or others later.
  Discard ALL messages without an `id` field; do not respond. Note: `ms` itself
  returns an error response for notifications (a minor spec deviation); our shim
  is stricter and correct.
- **JSON parse errors** — malformed or partial JSON on stdin is logged to stderr
  and the line is skipped with no response. This is distinct from valid JSON with
  unexpected fields (handled by notification/stub logic). A partial line or binary
  garbage on stdin must be caught before the JSON-RPC dispatch logic.
- **Stderr for debug logs** — stdout is the protocol channel; any debug output
  on stdout corrupts JSON-RPC responses. All logging goes to stderr.
- **ANSI sanitization** — strip ANSI escape codes from SKILL.md file content
  before embedding in `show`/`load` responses. Skill names and description fields
  from frontmatter are controlled strings and do not require sanitization.
- **Scan-once caching** — enumerate `~/.claude/skills/*/SKILL.md` at startup,
  build an in-memory index, serve from memory. Avoids per-call filesystem hits.
  Skills added or removed on the host after the server starts are not visible
  until the next Claude Code session (which restarts the server). This is
  acceptable: skill authoring happens on the host, not inside the container.
- **Broken symlink handling** — `~/.claude/skills/` is itself a symlink
  (init-rip-cage.sh creates it pointing to `.rc-context/skills/`). Skills inside
  that directory may be further symlinks (host skills pointing to monorepo paths).
  After globbing `~/.claude/skills/*/SKILL.md`, check `path.is_file()` for each
  match. Entries where `is_file()` returns `False` (broken symlinks, dangling
  paths) are skipped with a stderr log. Do NOT rely on `Path.resolve()` raising
  an exception — on Python 3.11 (Debian bookworm), `resolve()` succeeds on broken
  symlinks without raising.
- **Process exit** — the server exits only on stdin EOF (normal session end) or
  SIGTERM. All other errors (malformed JSON, tool dispatch failures, broken skill
  files) are handled within the main loop and logged to stderr. If the server
  exits unexpectedly, Claude Code marks `meta-skill` as unavailable for the rest
  of the session — skills become inaccessible with no recovery path short of
  restarting the Claude Code session. This is a known failure mode.
- **Crash resilience** — the main read loop must be wrapped in a top-level
  `try/except` that logs to stderr and continues rather than exiting. An
  unhandled exception on malformed input must not terminate the server.
- **python3 availability** — the `init-rip-cage.sh` check for `command -v python3`
  must be a hard error (`exit 1`), not a warning. A missing Python3 means skill
  discovery is completely broken; the container should fail fast rather than
  silently degrading.
- **ADR-006 exception** — ADR-006 D6 defers "custom MCP servers inside
  containers" to Phase 2+. `skill-server.py` is an infrastructure shim (it
  replaces a missing host binary, not a custom agent tool), and falls within
  the spirit of D18. ADR-006 D6-deferred is amended to carve out this case.

### Protocol Flow

`tools/call` is a single MCP method. The tool name is in `params.name`:

```
Initialize → [client sends notifications/initialized, server silently discards] → tools/list

tools/call  params.name="list"   → return skills from in-memory index (built at startup)
                                   returns {"count":0,"skills":[]} when no skills — not an error
tools/call  params.name="show"   → read full SKILL.md for named skill (by id or name)
tools/call  params.name="load"   → identical to show
tools/call  params.name="search" → case-insensitive substring match over skill names/descriptions
tools/call  params.name="*"      → return empty success for all other tools
```

Unknown skill name in `show`/`load`: return a success response with `isError: true`
and a text content block "Skill not found: {name}". This matches `ms` behavior and
gives the agent actionable feedback.

Frontmatter parsing via regex (no yaml library needed):
```python
import re
m = re.match(r'^---\n(.*?)\n---', content, re.DOTALL)
```

MCP stdio transport uses newline-delimited JSON (one message per line). Not
HTTP Content-Length framing.

### ms Wire Format (Probed 2026-04-14)

Responses confirmed by probing `ms mcp serve` live. The shim must match these
exactly — mismatched format means Claude Code ignores the response.

**`list` response** (`tools/call` with `params.name="list"`):
```json
{
  "content": [{
    "type": "text",
    "text": "{\"count\": 2, \"skills\": [{\"id\": \"asana\", \"name\": \"asana\", \"description\": \"...\", \"layer\": \"project\"}]}"
  }]
}
```
The `text` field contains a JSON-encoded string. Skill `id` = directory name (shim
uses the directory name as both `id` and `name`). Empty result when no skills:
`{"count": 0, "skills": []}`.

**`show`/`load` response** (skill found):
```json
{
  "content": [{
    "type": "text",
    "text": "{\"content\": \"---\\nname: asana\\n...\\n<full SKILL.md text>\\n\"}"
  }]
}
```
The `text` field is a JSON-encoded object containing the full SKILL.md as the
`content` field. Not raw markdown — it is JSON-in-text. The skill is looked up
by the `id` field (i.e., directory name) from the `list` response.

**`show`/`load` error response** (skill not found):
```json
{
  "content": [{"type": "text", "text": "Skill not found: asana"}],
  "isError": true
}
```

**Tool lookup:** Claude Code calls `show`/`load` with the `id` value from the
`list` response. The shim uses the skill directory name as the id. Lookup by
exact id match; optionally also accept name match for robustness.

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
   in-memory index at startup, glob `~/.claude/skills/*/SKILL.md` and check
   `path.is_file()` for each match. Entries where `is_file()` returns `False`
   (broken symlinks, dangling paths) are skipped with a stderr log. Do not
   rely on `Path.resolve()` raising an exception — on Python 3.11 it returns
   a path to a non-existent target without raising, which would silently
   include broken-symlink skills in the index, then crash or return empty
   content at `show`/`load` time.

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

| Action | File | Notes |
|--------|------|-------|
| Create | `skill-server.py` | Placed at `/usr/local/lib/rip-cage/`; COPY'd before `USER agent` directive |
| Modify | `Dockerfile` | COPY `skill-server.py` to `/usr/local/lib/rip-cage/` alongside existing files (before `USER agent` line 82). Add to the existing `chmod` block if needed — `python3 skill-server.py` does not require the execute bit |
| Modify | `settings.json` | Add `mcpServers` block |
| Modify | `init-rip-cage.sh` | Add `command -v python3 \|\| { echo "ERROR: python3 not found ..."; exit 1; }` per ADR-005 D5 point 2. This must be a **hard error** (exit 1) — a missing Python3 means skill discovery is completely broken |
| Modify | `test-skills.sh` | (1) Check 8: use `jq -e '.mcpServers["meta-skill"]'` instead of `jq -r 'keys[0]'` (robust against future MCP server additions). (2) Branch A fallback: change from silent degradation to `FAIL` with "mcpServers.meta-skill not configured — skill discovery will not work" — Branch A is an eliminated alternative, not a supported path |
| Modify | `CLAUDE.md` | Document skill availability in containers, per ADR-005 D5 point 3 |
| Update | `docs/decisions/ADR-002-rip-cage-containers.md` | D17 revised (mount path corrected), D18 updated |
| Update | `docs/decisions/ADR-006-multi-agent-architecture.md` | D6-deferred carve-out (already done 2026-04-14) |

Branch B does not modify `rc` — symlink resolution is a follow-on improvement
(tracked separately), not a blocker for initial implementation.

**settings.json merge gap:** The init-time overwrite means any project-level
`mcpServers` entries are lost. This is a pre-existing limitation. If it becomes
a real blocker, `init-rip-cage.sh` should merge `mcpServers` from the project's
settings into the container's settings rather than overwriting.

**Note on file paths:** These paths assume current repo layout. If ADR-009 D4
(moving test scripts to `tests/`) lands before this change, adjust the
Dockerfile COPY source for `test-skills.sh` accordingly.

