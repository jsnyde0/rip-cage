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

## Spike 1: Native Filesystem Discovery (30 min)

**Hypothesis:** Claude Code discovers skills from `~/.claude/skills/` via native
filesystem scanning, without any MCP server.

The current mount method (staging via `.rc-context/` + symlink) is an
implementation detail that is orthogonal to this hypothesis. Any working mount
that places `SKILL.md` files at `~/.claude/skills/*/SKILL.md` is sufficient to
test it. However, pre-creating `~/.claude/skills/` as a real directory in the
Dockerfile (rather than relying on a symlink) is a worthwhile cleanup regardless
of spike outcome — it removes an indirection layer. Do both changes together.

**Changes:**
1. Add to Dockerfile: `RUN mkdir -p /home/agent/.claude/skills /home/agent/.claude/commands`
2. Change `rc` to mount directly: `-v "${HOME}/.claude/skills:/home/agent/.claude/skills:ro"`
3. Remove symlink step from `init-rip-cage.sh` (lines 48–57; retain `.rc-context/` only for CLAUDE.md, lines 33–45)

**Automated test (run after spike):**
```bash
rc build && rc up /path/to/project
rc test <container-name>
# test-skills.sh check 4 must pass: confirms real directory (not symlink) — validates mount only
```
**Manual validation required:** Start `claude` inside the container and invoke a
skill (e.g., `/send-it`). A working invocation means native discovery works.
A "Unknown skill" error means MCP is required — proceed to Spike 2.

**Result matters:** If native discovery works, proceed to Branch A (trivial, done).
If "Unknown skill" persists despite files present, proceed to Spike 2.

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
responses just enough to not crash). MCP stdio uses newline-delimited JSON:
```bash
#!/bin/bash
while IFS= read -r line; do
  echo "$line" >> /tmp/ms-probe.log
  # Respond to initialize only; echo back the request id
  if echo "$line" | grep -q '"method":"initialize"'; then
    req_id=$(echo "$line" | jq -r '.id')
    echo "{\"jsonrpc\":\"2.0\",\"id\":${req_id},\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"probe\",\"version\":\"0.0.1\"}}}"
  fi
  # Silently discard notifications (JSON-RPC messages with no "id" field)
done
```

**Test:** Start container, run `claude`, attempt a skill, check
`/tmp/ms-probe.log`. If Claude Code sent JSON-RPC to the probe, MCP is
confirmed as the mechanism.

**Also verifies server name sensitivity — run twice:**
1. First run: `mcpServers.meta-skill` (name matches host)
2. Second run: rename key to `mcpServers.skill-server` and repeat

If Claude Code only queries `meta-skill`, the name matters and Branch B must
use that exact key. If it queries any name, either works.

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
The `.rc-context/` pattern is still used for CLAUDE.md files (lines 33–45, which
don't have a pre-created target directory), so retain it for those.

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
- **Python3 is pre-installed** — Dockerfile line ~26 (`apt-get install -y ... python3`).
  No additional install needed; this is a dependency that is already satisfied.
- **Notifications must be silently discarded** — MCP requires the client to send
  a `notifications/initialized` notification after `initialize` and before any
  `tools/list` call. This is a JSON-RPC notification (no `id` field, no response
  expected). The server must discard messages without an `id` field rather than
  treating them as unknown requests.
- **ADR-006 exception** — ADR-006 D6 defers "custom MCP servers inside
  containers" to Phase 2+. `skill-server.py` is an infrastructure shim (it
  replaces a missing host binary, not a custom agent tool), and falls within
  the spirit of D18. ADR-006 D6-deferred is amended to carve out this case.
- **Crash resilience** — The main read loop must be wrapped in a top-level
  `try/except` that logs to stderr and continues rather than exiting. An
  unhandled exception on malformed input must not terminate the server.

### `skill-server.py` (stdlib only, ~100 lines)

Placed at `/usr/local/lib/rip-cage/skill-server.py` in the image:

```
Initialize → [client sends notifications/initialized, server discards] → tools/list
tools/call: list   → enumerate ~/.claude/skills/*/SKILL.md, return id/name/description
                     returns [] (empty array) when no skills are present — not an error
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

`settings.json` is already COPY'd into the image. `init-rip-cage.sh` line 29
overwrites `~/.claude/settings.json` from `/etc/rip-cage/settings.json` on
every container start. This is intentional: the MCP server config is static
(no runtime state in `settings.json` needs to persist across restarts). Any
session-level settings Claude Code writes to `settings.json` (e.g., granted
permissions) are reset on restart — a known limitation of the current init
flow, pre-existing this design and out of scope here.

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

**Branch B** (our skill server): swap the command and args in `settings.json`,
and add the binary to the Dockerfile:
```json
"command": "/usr/local/bin/ms",
"args": ["mcp", "serve"]
```
Remove `skill-server.py`. The Dockerfile addition and two-field settings.json
swap (command + args) are the full scope of the upgrade.

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
| Modify | `init-rip-cage.sh` (remove skills/commands symlink block, lines 48–57) |
| Update | `docs/decisions/ADR-002-rip-cage-containers.md` (D17 revised, D18 new) |

### Branch B (MCP server, if Branch A fails)

| Action | File |
|--------|------|
| Create | `skill-server.py` |
| Modify | `Dockerfile` (COPY skill-server.py) |
| Modify | `settings.json` (add `mcpServers` block) |
| Modify | `init-rip-cage.sh` (add `command -v python3` warning per ADR-005 D5 point 2) |
| Modify | `CLAUDE.md` (document skill availability in containers, per ADR-005 D5 point 3) |
| Update | `docs/decisions/ADR-002-rip-cage-containers.md` (D17 revised, D18 new) |
| Update | `docs/decisions/ADR-006-multi-agent-architecture.md` (amend D6-deferred carve-out) |

Branch B does not modify `rc` — skills remain staged via `.rc-context/` since
the symlink still points the server at the right place.

**Note on file paths:** These paths assume current repo layout. If ADR-009 D4
(moving test scripts to `tests/`) lands before this change, adjust the
Dockerfile COPY source for `test-skills.sh` accordingly.
