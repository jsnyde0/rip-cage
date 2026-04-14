# ADR-009: UX Overhaul

**Status:** Proposed
**Date:** 2026-04-13
**Design:** [UX Overhaul](../2026-04-13-ux-overhaul-design.md)
**Related:** [ADR-008](ADR-008-open-source-publication.md) (open-source publication), [ADR-003](ADR-003-agent-friendly-cli.md) (agent-friendly CLI)

## Context

Rip-cage v0.1.0 is published and functional. CI passes, the safety stack works, and the repo is public. But the first-user experience has unnecessary friction:

- The quickstart requires 3 commands (`build`, export env, `up`) before anything works
- The README front-loads 9 commands, devcontainer setup, auth internals, and safety stack details
- 12 test scripts clutter the repo root alongside core files
- Documentation is duplicated across README, CLAUDE.md, and AGENTS.md
- The positioning ("Docker-based sandbox for running Claude Code agents safely") is generic — it doesn't answer *when* or *why*

The actual usage pattern for the primary user is: `rc up .` → Claude works → `Ctrl-B d` to detach. Everything else is secondary.

## Decisions

### D1: Harm-reduction positioning

**Firmness: FIRM**

The pitch is: "Running Claude Code with `--dangerously-skip-permissions` is never safe. Rip cage doesn't change that. But many of us do it anyway. If that's you, at least put your Claude in a cage."

Do NOT claim rip-cage makes agents "safe." It limits blast radius. The framing is honest harm reduction, not false promises.

**Rationale:** Users running `--dangerously-skip-permissions` know they're taking a risk. Patronizing them with safety theater loses trust. Acknowledging the risk and offering mitigation earns it. This also sets correct expectations — rip-cage is defense-in-depth, not a guarantee.

**What would invalidate this:** If rip-cage achieves formal sandboxing guarantees (e.g., verified container isolation with no escape vectors). Currently it's a practical safety net, not a formal sandbox.

### D2: Auto-build on first `rc up`

**Firmness: FIRM**

When `rc up` doesn't find the `rip-cage:latest` image, it calls `cmd_build` automatically instead of exiting with an error. The message says: "Building rip-cage image (first run only, takes a few minutes)..."

`rc build` remains available for explicit rebuilds (after Dockerfile changes, etc.).

**Rationale:** Eliminating `rc build` from the quickstart removes one step and ~5 minutes of "is this even going to work?" uncertainty. The build only happens once. Users who clone and immediately `rc up .` should get a working cage.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **Auto-build** | Zero-step quickstart, simple | First `rc up` takes 5-10 min silently |
| **Auto-pull from GHCR** | Fast first run (~30s) | Requires GHCR infra, version pinning |
| **Keep explicit build** | User knows what's happening | Extra step, first-time friction |

Auto-pull (ADR-008 D6) is a future optimization. Auto-build is the simple immediate fix.

**What would invalidate this:** If auto-build causes confusion (users not realizing a long build is happening). Mitigated by clear progress output from `docker build`.

### D3: README as focused landing page

**Firmness: FIRM**

The README contains only:
1. One-paragraph harm-reduction pitch
2. Quick start (prerequisites, install, one-command use)
3. "What does the cage do?" (concrete blocked-command examples = aha moment)
4. Worktree workflow (power-user story)
5. Contributing/License links

Everything else lives in `docs/reference/`:
- `docs/reference/cli-reference.md` — full command reference, flags, JSON output
- `docs/reference/auth.md` — OAuth, Keychain, Linux, API key fallback
- `docs/reference/safety-stack.md` — hook config, allowlists, denied commands
- `docs/reference/devcontainer.md` — VS Code setup via `rc init`
- `docs/reference/whats-in-the-box.md` — tools table, Dockerfile architecture

**Rationale:** The README is the first thing people see. It should answer "what is this and how do I try it" in 30 seconds. Detailed reference material belongs one click away, not on the front page. GitHub renders links to docs/ as clickable — there's no discovery penalty.

**What would invalidate this:** If docs/ becomes a graveyard that nobody maintains. Mitigated by keeping docs minimal and linked from README.

### D4: Tests move to `tests/`

**Firmness: FIRM**

All 14 test files (13 `test-*.sh` scripts + `test_skill_server.py`) move to `tests/`. Update `Dockerfile` (COPY source paths for 2 test files), `Makefile`, CI workflow, and CONTRIBUTING.md accordingly.

**Rationale:** The repo root currently has 34 items. 14 are tests. Moving them to `tests/` reduces root items to ~20 and gives a cleaner first impression on GitHub. This is standard project layout.

**What would invalidate this:** Nothing — this is pure organization, no behavior change.

### D5: CLAUDE.md and AGENTS.md deduplication

**Firmness: FLEXIBLE**

**CLAUDE.md** (for agents working on rip-cage): Keep architecture overview, key gotchas, testing workflow. Remove duplicated quickstart, auth details, safety stack details — link to docs/ and README instead.

**AGENTS.md** (for agents using rip-cage): Currently identical to CLAUDE.md — requires a full rewrite, not a trim. New content: agent behavioral rules (JSON output, `--dry-run`, container naming), with links to `docs/reference/cli-reference.md` for technical reference. Agent rules live in AGENTS.md only; CLI reference lives in `docs/reference/cli-reference.md` only — no duplication.

**Rationale:** Three files repeating the same quickstart and safety stack overview means changes require 3 edits. Single-source each piece of information and cross-link.

### D6: Human commands vs agent commands

**Firmness: FLEXIBLE**

The README quickstart shows humans exactly two interactions: `rc up .` and `Ctrl-B d`. Container management commands (`ls`, `attach`, `down`, `destroy`) appear in `docs/cli-reference.md`, not the quickstart.

Agent-facing features (`--output json`, `--dry-run`, container naming rules) live in AGENTS.md and `docs/cli-reference.md`.

`rc --help` remains comprehensive for both audiences.

**Rationale:** Humans need one command to start and one keystroke to leave. Showing 9 commands upfront creates the impression that rip-cage is complex. It isn't — the complexity is in the safety stack, not the UX.

**What would invalidate this:** If users frequently need `destroy` or `ls` in normal flow. Current evidence: the primary user never uses these manually — agents handle container lifecycle.

### D7: Zero-config first run via `rc.conf` auto-generation

**Firmness: FIRM**

When `RC_ALLOWED_ROOTS` is unset and stdin is a TTY, prompt the user once:

```
rip-cage: no allowed roots configured.
Allow projects under [$HOME]: 
```

Default is `$HOME`. User confirms or types a narrower path. Written to
`~/.config/rip-cage/rc.conf`. Operation continues immediately. One-time only.

When stdin is not a TTY (agent, pipe, `--output json`): auto-allow only the exact
requested path (minimum grant), warn to stderr, do not write config.

See [zero-config first-run design](../../docs/2026-04-13-zero-config-first-run-design.md).

**Rationale:** The remaining first-run step after D2 (auto-build) is `RC_ALLOWED_ROOTS`
configuration. The interactive prompt removes it without weakening the security model:
humans get a guided one-time setup; agents get minimum-grant access unless they've
configured `RC_ALLOWED_ROOTS` explicitly (which they should). The allowlist model
(ADR-003 D3) is preserved — this only changes the "unset" default behavior.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **Interactive prompt (current)** | User makes explicit choice; rc.conf written once | Adds TTY detection code path |
| Silent default to `$HOME` | Simpler code | No user awareness; `rc.conf` never created |
| Keep "must be explicit" | Maximum strictness | Blocks every new user; no practical security gain |
| Homebrew tap | Eliminates clone+symlink too | Requires versioned releases first |

**What would invalidate this:** If the interactive prompt causes confusion (users not
understanding what "allowed roots" means). Mitigated by the prompt phrasing ("Allow
projects under") which conveys meaning without requiring prior knowledge of the term.

### D8: `rc auth refresh` command for credential hot-swap

**Firmness: FIRM**

Add an `rc auth refresh` command that re-extracts OAuth credentials from the macOS Keychain to `~/.claude/.credentials.json`. Because the credentials file is bind-mounted read-write into containers, the update propagates immediately — no container restart or destroy needed.

```bash
rc auth refresh   # re-extract credentials from keychain → file → all running containers see it
```

On Linux (no Keychain), print a message directing the user to update `~/.claude/.credentials.json` directly.

**Use case:** User hits usage limits or switches accounts on the host (`/login` or `claude auth login`). The host Keychain is updated but the bind-mounted file is stale. `rc auth refresh` bridges the gap without destroying the container (and its Claude Code session history).

**Implementation:** Extract the existing keychain-to-file logic from `cmd_up` (lines 598-613 of `rc`) into a shared helper `_extract_credentials`. New `cmd_auth_refresh` calls this helper. `cmd_up` also calls the helper (dedup). The command is ~10 lines.

**Rationale:** Destroying a container just to refresh credentials loses the Claude Code session, which is expensive (context, conversation history). The credentials file is already bind-mounted read-write, so the infrastructure for live updates exists — users just need a command to trigger the keychain re-extraction instead of remembering the `security find-generic-password` incantation.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **`rc auth refresh`** | Simple, no restart, preserves session | New command to learn |
| **Inotify/fswatch on keychain** | Fully automatic | Complex, platform-specific, brittle |
| **Document the `security` command** | No code change | User must remember macOS-specific incantation |
| **`rc destroy` + `rc up`** | Already works | Destroys session history — the whole problem |

**What would invalidate this:** If Claude Code changes to auto-refresh the credentials file on the host when `/login` runs (making the bind-mounted file always current). Currently `/login` updates the Keychain but not the file.

## Deferred

- **GHCR auto-pull** — Pull pre-built image instead of building locally. Depends on GHCR infra being stable (ADR-008 D6). Auto-build is the bridge.
- **Homebrew tap** — Would eliminate the clone+symlink install step entirely. Requires versioned releases working first.
