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

## Open Question: Is MCP Required?

Official docs claim Claude Code discovers skills natively from
`~/.claude/skills/` without MCP. The empirical evidence (error despite files
present) contradicts this. Two spikes resolve the ambiguity before building
anything.

## Spike 1: Direct Bind-Mount (30 min)

The current staging flow mounts skills at `/home/agent/.rc-context/skills` and
then symlinks to `~/.claude/skills`. The staging exists because Docker creates
bind-mount target directories as root when they don't exist. But `~/.claude/`
is already pre-created as `agent:agent` in the Dockerfile — if we also
pre-create `~/.claude/skills/`, Docker can bind-mount directly without the
ownership problem.

**Change:**
1. Add to Dockerfile: `RUN mkdir -p /home/agent/.claude/skills /home/agent/.claude/commands`
2. Change `rc` to mount directly: `-v "${HOME}/.claude/skills:/home/agent/.claude/skills:ro"`
3. Remove symlink step from `init-rip-cage.sh`

**Test:** Start a container, run `claude`, invoke `/send-it`. If skills resolve,
native filesystem discovery works and no MCP server is needed.

**Result matters:** If Spike 1 succeeds, proceed to Branch A (trivial, done).
If Spike 1 fails, the filesystem path is wrong theory — proceed to Spike 2.

## Spike 2: MCP Path Validation (30 min)

If Spike 1 fails, confirm that MCP is the required mechanism and that any
`mcpServers` entry (not just `ms` specifically) satisfies Claude Code.

**Add to `settings.json`** (temporarily, for test):
```json
"mcpServers": {
  "meta-skill": {
    "type": "stdio",
    "command": "/usr/local/lib/rip-cage/skill-probe.sh",
    "args": []
  }
}
```

**`skill-probe.sh`** (logs all stdin to `/tmp/ms-probe.log`, echoes valid MCP
responses just enough to not crash):
```bash
#!/bin/bash
while IFS= read -r line; do
  echo "$line" >> /tmp/ms-probe.log
  # Respond to initialize only
  if echo "$line" | grep -q '"method":"initialize"'; then
    echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"probe","version":"0.0.1"}}}'
  fi
done
```

**Test:** Start container, run `claude`, attempt `/send-it`, check
`/tmp/ms-probe.log`. If Claude Code sent JSON-RPC to the probe, MCP is
confirmed as the mechanism.

**Also verifies:** Does the server name need to be `meta-skill` specifically?
Test with a different name (e.g., `skill-server`) to confirm.

---

## Branch A: Direct Bind-Mount (if Spike 1 succeeds)

**This is a cleanup and simplification, not a new component.**

### Changes

**Dockerfile** — pre-create mount targets:
```dockerfile
RUN mkdir -p /home/agent/.claude /home/agent/.claude-state \
             /home/agent/.claude/skills /home/agent/.claude/commands
```

**`rc`** — mount directly, remove staging:
```bash
# Before:
_UP_RUN_ARGS+=(-v "${HOME}/.claude/skills:/home/agent/.rc-context/skills:ro")
# After:
_UP_RUN_ARGS+=(-v "${HOME}/.claude/skills:/home/agent/.claude/skills:ro")
```

Same change for `commands`.

**`init-rip-cage.sh`** — remove symlink steps for skills and commands (lines 48-57).
The `.rc-context/` pattern is still used for CLAUDE.md files (which don't have
a pre-created target directory), so retain it for those.

**`settings.json`** — no change. Native filesystem discovery needs no MCP config.

### Why this is cleaner

Removes an indirection layer (stage → symlink → file) with no corresponding
benefit. Skills and commands are regular user files, not sensitive config like
CLAUDE.md — they don't need the staging ceremony.

---

## Branch B: Container-Native Skill Server (if MCP required)

**If Spike 2 confirms MCP is the mechanism**, ship a minimal Python MCP server
in the image.

### Design constraints (from reviewer)

- **Zero pip dependencies** — Python stdlib only (regex for frontmatter,
  json/sys for MCP protocol)
- **Server named `meta-skill`** — matches host, eliminates a variable
- **Stubs return empty/success, never errors** — silent degradation for
  unimplemented tools (`suggest`, `feedback`, etc.)
- **Long-lived process** — MCP stdio servers start once per session, not per
  invocation; Python startup time is irrelevant

### `skill-server.py` (stdlib only, ~100 lines)

Placed at `/usr/local/lib/rip-cage/skill-server.py` in the image:

```
Initialize → tools/list (returns list + show + load + search as tools)
tools/call: list   → enumerate ~/.claude/skills/*/SKILL.md, return id/name/description
tools/call: show   → read full SKILL.md for named skill
tools/call: load   → alias for show
tools/call: search → substring match over skill names/descriptions
tools/call: *      → return empty success for all other tools
```

Frontmatter parsing via regex (no yaml library needed):
```python
import re
m = re.match(r'^---\n(.*?)\n---', content, re.DOTALL)
```

### Wired up in `settings.json`

```json
"mcpServers": {
  "meta-skill": {
    "type": "stdio",
    "command": "python3",
    "args": ["/usr/local/lib/rip-cage/skill-server.py"]
  }
}
```

`settings.json` is already COPY'd into the image and used by init-rip-cage.sh —
this is the only place the MCP config needs to live. No init script changes.

### What is NOT implemented (intentional stubs)

- `suggest` — Thompson sampling / bandit-based skill recommendations
- `feedback`, `evidence` — provenance and ranking data
- `validate`, `lint` — skill quality checking
- `index` — pre-indexing for fast search (server reads on-demand instead)
- `config` — ms configuration management
- Semantic/BM25 search (keyword match only)

These are UX features on top of basic skill loading. Agents inside containers
invoke skills by exact name; they don't need ranking or quality scoring.

---

## Upgrade Path: When `ms` Linux Binary Becomes Available

When `anthropics/ms` publishes Linux binaries (repo is private as of 2026-04-14,
v0.1.0), both branches converge to the same upgrade:

**Branch A** (no MCP server): add `ms` to the Dockerfile and wire it up:
```dockerfile
ARG MS_VERSION=0.1.0
RUN curl -L https://github.com/anthropics/ms/releases/download/v${MS_VERSION}/ms-linux-aarch64 \
    -o /usr/local/bin/ms && chmod +x /usr/local/bin/ms
```
Add `mcpServers.meta-skill` to `settings.json` (same structure as Branch B).

**Branch B** (our skill server): swap the command in `settings.json`:
```json
"command": "/usr/local/bin/ms",
"args": ["mcp", "serve"]
```
Remove `skill-server.py`. Settings structure is identical — one field change.

The upgrade is a Dockerfile + settings change, not an architectural change.

---

## What Does NOT Change

- The bind-mount itself: `~/.claude/skills` from host is always mounted
- The `:ro` security posture: skills are read-only inside the container
- The `rc.conf` allowlist model: unchanged
- The devcontainer path: same mounts, same init script

## File Changes Summary

### Branch A (direct bind-mount)

| Action | File |
|--------|------|
| Modify | `Dockerfile` (pre-create `~/.claude/skills` and `~/.claude/commands`) |
| Modify | `rc` (direct mount, drop `.rc-context/` for skills/commands) |
| Modify | `init-rip-cage.sh` (remove skills/commands symlink block) |
| Update | `docs/decisions/ADR-002-rip-cage-containers.md` (D17 revised, D18 new) |

### Branch B (MCP server, if Branch A fails)

| Action | File |
|--------|------|
| Create | `skill-server.py` |
| Modify | `Dockerfile` (COPY skill-server.py) |
| Modify | `settings.json` (add `mcpServers` block) |
| Update | `docs/decisions/ADR-002-rip-cage-containers.md` (D17 revised, D18 new) |

Branch B does not modify `rc` or `init-rip-cage.sh` — skills remain staged
via `.rc-context/` since the symlink still points the server at the right place.
