# Design: Agent-Friendly CLI for `rc`

**Date:** 2026-03-26
**Status:** Draft
**Decisions:** [ADR-003](decisions/ADR-003-agent-friendly-cli.md)
**Origin:** Analysis of [Rewrite Your CLI for AI Agents](https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/) applied to rip-cage's `rc` CLI. Primary consumer: a Phase 3 orchestrating agent that manages container lifecycles programmatically.
**Supersedes:** None
**Related:** [Rip Cage Design](2026-03-25-rip-cage-design.md), [ADR-002](decisions/ADR-002-rip-cage-containers.md)

---

## Problem

The `rc` CLI currently outputs human-readable plain text. This works for interactive use, but Phase 3 envisions an orchestrating agent that programmatically spins up, monitors, and tears down worker containers via `rc`. An orchestrator parsing prose output with regex is fragile and error-prone.

Additionally, `rc` accepts arbitrary filesystem paths from its caller with minimal validation. If that caller is an AI agent constructing paths from task descriptions, hallucinated or malicious inputs need to fail safely.

## Goal

Make `rc` a **dual-audience CLI** — human-friendly by default, machine-readable on request — without breaking existing workflows. Specifically:

1. Structured JSON output via `--output json` on commands that return data or perform actions
2. `--dry-run` on mutating commands to validate without side effects
3. Input hardening on path arguments to reject dangerous patterns
4. Ship an agent context file encoding `rc`-specific invariants for AI consumers

## Non-Goals

- MCP server surface — deferred; CLI-first, MCP can wrap later
- Schema introspection (`rc describe`) — 8 commands, not worth the complexity
- Field masks / response filtering — payloads are small
- Response sanitization — `rc` doesn't return untrusted external data
- Changing the default human-readable output format

---

## Design

### 1. `--output json` Flag

**Applies to:** `rc ls`, `rc up`, `rc down`, `rc destroy`, `rc test`, `rc build` (not `rc init` or `rc attach`)

**Behavior:**
- Default (no flag): current human-readable output, unchanged
- `--output json`: structured JSON to stdout, no prose. All status/progress messages go to stderr.
- Detect non-TTY stdout as a hint (log to stderr), but do NOT auto-switch to JSON — explicit flag required

**JSON Schemas:**

#### `rc ls --output json`

```json
[
  {
    "name": "personal-myproject",
    "status": "running",
    "source_path": "~/projects/my-app",
    "uptime": "2 hours ago"
  }
]
```

Returns `[]` (empty array) when no containers exist. Never returns null. Additional fields (e.g., multi-agent labels per ADR-006 D3) will be added as optional keys — consumers should tolerate unknown fields.

#### `rc up <path> --output json`

```json
{
  "name": "personal-myproject",
  "action": "created" | "resumed" | "attached",
  "source_path": "~/projects/my-app",
  "status": "running",
  "init": "success" | "failed",
  "name_disambiguated": false
}
```

The `init` field is present only when `action` is `created` or `resumed` (not for `attached`, since no init runs). The `name_disambiguated` field is `true` when the container name required a hash suffix due to a name collision with a different source path — the `name` field in the response is always the source of truth.

Note: when `--output json` is passed, `rc up` must NOT `exec -it` into tmux on **any** code path — newly created, resumed from stopped, or attaching to already-running. All three paths currently exec into tmux; all three must be suppressed in JSON mode. The JSON response indicates which path was taken via the `action` field (`created`, `resumed`, `attached`). The caller can `rc attach` separately if needed.

#### `rc down <name> --output json`

```json
{
  "name": "personal-myproject",
  "action": "stopped",
  "status": "exited"
}
```

#### `rc destroy <name> --output json`

```json
{
  "name": "personal-myproject",
  "action": "destroyed",
  "volumes_removed": ["rc-state-personal-myproject", "rc-history-personal-myproject"]
}
```

#### `rc test <name> --output json`

```json
{
  "name": "personal-myproject",
  "checks": [
    {"name": "DCG denies rm -rf", "status": "pass", "detail": ""},
    {"name": "Compound commands blocked", "status": "pass", "detail": ""},
    ...
  ],
  "overall": "pass" | "fail"
}
```

`checks` is an array of objects, each with `name`, `status` (`"pass"` | `"fail"`), and `detail` (extra context, may be empty). The array grows automatically as `test-safety-stack.sh` adds checks (currently 27 per ADR-004 D4) — no schema change needed for new tests.

#### `rc build --output json`

```json
{
  "image": "rip-cage:latest",
  "action": "built",
  "status": "success" | "failed"
}
```

**Error format (all commands):**

```json
{
  "error": "Image rip-cage:latest not found. Run: rc build",
  "code": "IMAGE_NOT_FOUND"
}
```

Exit code is always non-zero on error, regardless of output format.

**Error codes:** `IMAGE_NOT_FOUND`, `DOCKER_NOT_RUNNING`, `PATH_NOT_FOUND`, `PATH_INVALID`, `CONTAINER_NOT_FOUND`, `INIT_FAILED`, `BUILD_FAILED`, `NAME_CONFLICT`

This list is illustrative. New error codes will be added as failure modes are discovered during implementation.

### 2. `--dry-run` Flag

**Applies to:** `rc up`, `rc destroy`

**Behavior:**
- Runs all **pre-condition** validation (path checks, Docker availability, image existence, container state detection)
- Prints what *would* happen, but does not execute
- Returns the same JSON shape as the real command but with `"dry_run": true` added and runtime-only fields (like `init`) omitted — dry-run cannot predict init script success without actually running the container
- Exit code 0 if pre-conditions pass, non-zero if validation fails

**Examples:**

```bash
# Human mode
$ rc up ~/code/myproject --dry-run
Would create container personal-myproject for ~/projects/my-app
Would mount ~/projects/my-app → /workspace
Would run init script

# Machine mode
$ rc up ~/code/myproject --dry-run --output json
{
  "dry_run": true,
  "name": "personal-myproject",
  "action": "would_create",
  "source_path": "~/projects/my-app"
}
```

```bash
$ rc destroy mycontainer --dry-run
Would remove container mycontainer
Would remove volumes: rc-state-mycontainer, rc-history-mycontainer
```

### 3. Input Hardening

**Applies to:** All commands that accept a path argument (`rc up`, `rc init`)

**Validation rules (applied after `realpath` resolution — note: `realpath` resolves symlinks, which is security-critical; do not replace with naive string prefix matching):**

| Rule | Rejects | Rationale |
|------|---------|-----------|
| No `..` after realpath | Paths resolving outside allowed roots | Path traversal |
| No control characters | Bytes 0x00-0x1F in path | Shell injection |
| No null bytes | `\0` in arguments | C-string truncation |
| Must resolve to existing directory | Nonexistent paths | Hallucinated paths |
| Allowed roots only | Paths outside `~/code/` (configurable) | Blast radius limiting |

**Allowed roots:** No default. `RC_ALLOWED_ROOTS` env var (colon-separated absolute paths) **must** be set. If unset, `rc up` and `rc init` exit with an error explaining how to configure it.

Example: `export RC_ALLOWED_ROOTS="$HOME/projects"`

This fail-closed approach avoids shipping opinionated defaults that only work for one user's machine layout.

**On rejection:** Exit 1 with clear error message. In JSON mode, return error object with code `PATH_INVALID`.

```bash
$ rc up /etc/shadow
Error: /etc/shadow is outside allowed roots. Set RC_ALLOWED_ROOTS.

$ RC_ALLOWED_ROOTS=~/projects rc up ~/projects/../../../etc --output json
{"error": "Path resolves outside allowed roots", "code": "PATH_INVALID", "resolved": "/etc"}
```

### 4. Agent Context File

Ship agent-specific rules for invoking `rc` in the project's `CLAUDE.md` (which Claude Code loads automatically on session start). See also: `rc schema` (section 5) for the machine-readable complement to this human-readable guidance.

```markdown
## Rules for AI agents calling `rc`

- Always use `--output json` when parsing output programmatically
- Always use `--dry-run` before `rc destroy` to confirm the target
- Use `rc ls --output json` to discover containers before operating on them
- Container names are derived from paths — use `rc ls` to get exact names, don't construct them
- The `name` field in `rc up --output json` is the source of truth; names may include a hash suffix when disambiguation occurs
- If multiple containers exist for the same source path, `rc ls` returns all of them — track names from `rc up` responses
- `rc up --output json` does NOT attach to tmux — use `rc attach` separately
- `rc attach` has no `--output json` mode — use `rc ls --output json` to verify container status before calling attach
- Never call `rc destroy` without confirming with the user first
```

### 5. `rc schema` Subcommand

**Applies to:** top-level `rc` invocation — `rc schema`

Returns a static JSON document describing all commands, their arguments, and accepted flags. The schema is hardcoded (no runtime reflection needed — `rc` has a fixed command set) with a `version` field so callers can detect changes.

**Output format:**

```json
{
  "version": "1",
  "commands": {
    "up": {
      "args": [{"name": "path", "type": "path", "required": true}],
      "flags": {
        "--output": {"values": ["json"], "default": null},
        "--dry-run": {"type": "bool", "default": false},
        "--env-file": {"type": "path", "optional": true},
        "--port": {"type": "string", "optional": true},
        "--cpus": {"type": "string", "default": "2"},
        "--memory": {"type": "string", "default": "4g"},
        "--pids-limit": {"type": "string", "default": "500"}
      }
    },
    "down": {
      "args": [{"name": "name", "type": "string", "required": false, "note": "auto-selected if exactly one container exists"}],
      "flags": {"--output": {"values": ["json"], "default": null}}
    },
    "destroy": {
      "args": [{"name": "name", "type": "string", "required": false}],
      "flags": {
        "--output": {"values": ["json"], "default": null},
        "--dry-run": {"type": "bool", "default": false}
      }
    },
    "ls": {
      "args": [],
      "flags": {"--output": {"values": ["json"], "default": null}}
    },
    "test": {
      "args": [{"name": "name", "type": "string", "required": false}],
      "flags": {"--output": {"values": ["json"], "default": null}}
    },
    "attach": {
      "args": [{"name": "name", "type": "string", "required": false}],
      "flags": {}
    },
    "build": {
      "args": [],
      "flags": {"--output": {"values": ["json"], "default": null}}
    },
    "init": {
      "args": [{"name": "path", "type": "path", "required": false, "default": "."}],
      "flags": {"--force": {"type": "bool", "default": false}}
    },
    "schema": {
      "args": [],
      "flags": {}
    }
  }
}
```

**Rationale:** The [jpoehnelt Agent DX CLI Scale](https://raw.githubusercontent.com/jpoehnelt/skills/refs/heads/main/agent-dx-cli-scale/SKILL.md) axis 3 (Schema Introspection) rewards CLIs that expose their own interface for runtime discovery. Without it, `rc` scores ~14/21 (agent-ready). With it, `rc` reaches ~16/21 (agent-first). An agent can call `rc schema` on first contact to understand what's available without needing to read AGENTS.md or parse `--help` prose.

**Increment the `version` field** any time a command is added, a flag is added/removed, or an arg type changes. Callers can check `version` to detect drift. The schema follows an **additive-only** policy: new fields and commands may appear, but existing fields will not be removed or renamed. Consumers should tolerate unknown keys.

---

## Implementation Notes

### Schema stability

JSON schemas are **unstable** during initial implementation. Fields may be added, renamed, or removed. Once a Phase 3 orchestrator exists and depends on these schemas, they will be frozen with an additive-only policy (new fields may appear; existing fields will not be removed or renamed without a major version bump).

### Shared JSON output helper

Add a `json_output()` helper function that:
- Checks if `--output json` was passed (global flag parsed in main dispatch)
- Outputs JSON to stdout via `jq` (already available) or printf
- Routes all human messages to stderr when JSON mode is active

### TTY detection

When stdout is not a TTY and `--output json` is not explicitly set, the CLI should still output human text (no auto-switching). But progress/status messages should go to stderr so stdout stays clean for piping.

### Error handling and `set -euo pipefail`

The `rc` script uses `set -euo pipefail`, which causes immediate exit on any unhandled failure — before a JSON error object can be emitted. In JSON mode, all Docker calls must be wrapped to catch failures and emit structured errors. Options: `trap 'emit_json_error' ERR` global handler, or explicit `if ! docker ...; then json_error ...; fi` per call. The latter is more predictable and recommended.

### Signal handling (deferred)

If `rc up` is interrupted (SIGINT/SIGTERM) after `docker run` but before init completes, the container is left in an indeterminate state. Signal handlers (`trap`) are not yet implemented. The workaround is `rc destroy` + `rc up` to recover cleanly. If implemented, expected behavior by stage:

- **Pre-create:** clean exit, no cleanup needed
- **Post-create, pre-init:** stop and remove the container
- **Post-init, pre-attach:** container is usable; no cleanup needed (JSON mode returns normally, human mode skips attach)

### Concurrency

Concurrent `rc up` calls for the same path have a TOCTOU race between `docker inspect` and `docker run`. The window is wider than a simple check-then-act because credential extraction, mount setup, and env-file validation run between the check and the create. This is a known limitation. Docker's name conflict error should be caught and mapped to `NAME_CONFLICT` error code (currently mapped to generic `DOCKER_ERROR`). The Phase 3 orchestrator must serialize `rc up` calls per path, or handle `NAME_CONFLICT` as a retriable condition.

### Backward compatibility

- No existing flags or behavior changes without `--output json` or `--dry-run`
- `rc up` without `--output json` still attaches to tmux as today
- Error messages on stderr remain human-readable regardless of output mode

---

## Phasing

| Phase | Changes | Effort | Agent DX Score |
|-------|---------|--------|---------------|
| **P1: JSON output** | `--output json` on `ls`, `up`, `down`, `destroy`, `test`, `build` | Medium | ~11/21 |
| **P2: Dry-run** | `--dry-run` on `up` and `destroy` | Small | ~13/21 |
| **P3: Input hardening** | Path validation with allowed roots | Small | ~14/21 |
| **P4: Agent context** | Update AGENTS.md with `rc` invocation rules | Tiny | ~14/21 |
| **P5: Schema** | `rc schema` subcommand | Small | ~16/21 (agent-first) |

Score bands per [jpoehnelt Agent DX CLI Scale](https://raw.githubusercontent.com/jpoehnelt/skills/refs/heads/main/agent-dx-cli-scale/SKILL.md): 11–15 = agent-ready, 16–21 = agent-first.

P1-P3 can be implemented independently. P4 is documentation-only.

