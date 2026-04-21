# ADR-003: Agent-Friendly CLI Interface for `rc`

**Status:** Accepted
**Date:** 2026-03-26
**Design:** [Agent-Friendly CLI Design](../2026-03-26-agent-friendly-cli-design.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [Rewrite Your CLI for AI Agents](https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/), [Agent DX CLI Scale](https://raw.githubusercontent.com/jpoehnelt/skills/refs/heads/main/agent-dx-cli-scale/SKILL.md)

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

**Firmness: FIRM** (allowlist model); **FLEXIBLE** (default behavior)

Validate all path arguments against an allowed-roots list. Reject paths with control
characters, null bytes, or that resolve (via `realpath`, which follows symlinks —
security-critical) outside allowed roots.

**Default behavior when `RC_ALLOWED_ROOTS` is unset:**

- **Interactive (TTY):** prompt the user once, default `$HOME`, write to
  `~/.config/rip-cage/rc.conf`. Operation continues immediately. One-time only.
- **Non-interactive (no TTY, agent, `--output json`):** auto-allow only the exact
  resolved path requested (minimum necessary grant); warn to stderr; do not write config.

See [zero-config first-run design](../../docs/2026-04-13-zero-config-first-run-design.md).

**Rationale:** The article emphasizes that "agents make predictable hallucination errors"
and the CLI must be the last line of defense. `rc up` takes an arbitrary path and
bind-mounts it into a container — an agent hallucinating `/etc` or `~/.ssh` would expose
sensitive host files. Allowed roots constrain the blast radius to known project
directories.

The original "must be set explicitly" stance was stricter than necessary for the actual
threat model (agent hallucinations, not sophisticated adversaries). Industry tools (Docker
Desktop, Lima, Rancher Desktop) all default to `$HOME` — this matches that standard while
preserving the allowlist guarantee. Non-TTY minimum grant is stricter than the human
default, which is appropriate: agents calling `rc` programmatically should have
`RC_ALLOWED_ROOTS` configured; if they don't, they get minimum viable access only.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Allowlist + TTY prompt (current)** | Zero friction for humans; minimum grant for agents | Prompt adds code path |
| No default, explicit required | Maximum strictness | Blocks every new user before first use; no practical security gain against hallucinations |
| Blocked paths (denylist) | No config needed | Easy to miss sensitive paths, bypassable |
| Default to `$HOME` silently | Simple | No user awareness; `rc.conf` never written |
| No validation (trust caller) | Zero effort | Agents will hallucinate paths eventually |

**What would invalidate this:** Container filesystem isolation becomes strong enough that
bind-mounting any host path is safe (unlikely — bind mounts bypass container isolation by
design).

### D4: Agent context in CLAUDE.md

**Firmness: FLEXIBLE**

Add rules for AI agents invoking `rc` programmatically to the project's `CLAUDE.md`. Encodes invariants like "always use `--output json`", "always `--dry-run` before `rc destroy`", "don't construct container names, use `rc ls`".

**Rationale:** The article calls these "agent skills" — structured context that makes implicit knowledge explicit. `CLAUDE.md` is loaded automatically by Claude Code on session start, making it the most reliable delivery path for agent context. Originally planned for `AGENTS.md`, but `CLAUDE.md` proved more effective.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Project CLAUDE.md** | Auto-loaded by Claude Code, no extra discovery step | Mixes agent rules with project docs |
| Extend AGENTS.md | Dedicated agent context file | Not auto-loaded; agents must know to look for it |
| Separate CONTEXT.md | Clean separation | Another file to maintain |
| `rc --help` improvements | Discoverable | Agents don't read `--help` efficiently |
| MCP tool descriptions | Native agent context | MCP surface doesn't exist yet |

**What would invalidate this:** MCP surface with tool descriptions replaces the need for file-based agent context.

### D5: `rc schema` for agent-readable command signatures

**Firmness: FLEXIBLE**

Add a `rc schema` subcommand that outputs a machine-readable JSON description of all commands, their arguments, accepted flags, and flag value constraints.

**Rationale:** The [jpoehnelt Agent DX CLI Scale](https://raw.githubusercontent.com/jpoehnelt/skills/refs/heads/main/agent-dx-cli-scale/SKILL.md) scores schema introspection as axis 3 of 7. Without it, `rc` scores ~14/21 (agent-ready). With it, `rc` reaches ~16/21 (agent-first). The schema is static — `rc` has a fixed command set and no runtime reflection is needed. It can be a hardcoded JSON block with a version field, making it cheap to implement and easy to keep in sync.

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
      "args": [{"name": "name", "type": "string", "required": false, "note": "resolved from CWD first, then singleton fallback"}],
      "flags": {
        "--output": {"values": ["json"], "default": null}
      }
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
      "flags": {
        "--output": {"values": ["json"], "default": null}
      }
    },
    "test": {
      "args": [{"name": "name", "type": "string", "required": false}],
      "flags": {
        "--output": {"values": ["json"], "default": null}
      }
    },
    "attach": {
      "args": [{"name": "name", "type": "string", "required": false}],
      "flags": {}
    },
    "build": {
      "args": [],
      "flags": {
        "--output": {"values": ["json"], "default": null}
      }
    },
    "init": {
      "args": [{"name": "path", "type": "path", "required": false, "default": "."}],
      "flags": {
        "--force": {"type": "bool", "default": false}
      }
    },
    "schema": {
      "args": [],
      "flags": {}
    }
  }
}
```

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **`rc schema`** | Dedicated, discoverable, composable with `--output json` | New subcommand |
| `rc help --json` | Consistent with `--output json` convention | Overloads `--help` semantics |
| AGENTS.md only | No code required | File-based, can drift from implementation; not version-aware |
| MCP tool descriptions | Native agent context | MCP surface doesn't exist yet |

**What would invalidate this:** MCP tool definitions replace runtime schema discovery.

## Deferred

- **MCP surface** — CLI-first, MCP can wrap later when orchestrator exists
- **Schema introspection** — 8 commands; `--help` and AGENTS.md are sufficient
- **Field masks** — payloads are small, no context window concern
- **Response sanitization** — `rc` doesn't return untrusted external data
