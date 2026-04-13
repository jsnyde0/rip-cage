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

Everything else lives in `docs/`:
- `docs/cli-reference.md` — full command reference, flags, JSON output, agent rules
- `docs/auth.md` — OAuth, Keychain, Linux, API key fallback
- `docs/safety-stack.md` — hook config, allowlists, denied commands
- `docs/devcontainer.md` — VS Code setup via `rc init`
- `docs/whats-in-the-box.md` — tools table, Dockerfile architecture

**Rationale:** The README is the first thing people see. It should answer "what is this and how do I try it" in 30 seconds. Detailed reference material belongs one click away, not on the front page. GitHub renders links to docs/ as clickable — there's no discovery penalty.

**What would invalidate this:** If docs/ becomes a graveyard that nobody maintains. Mitigated by keeping docs minimal and linked from README.

### D4: Tests move to `tests/`

**Firmness: FIRM**

All 12 `test-*.sh` scripts move to `tests/`. Update `rc test`, `Makefile`, CI workflow, and CONTRIBUTING.md accordingly.

**Rationale:** The repo root currently has 29 files. 12 are tests. Moving them to `tests/` cuts root clutter nearly in half and gives a cleaner first impression on GitHub. This is standard project layout.

**What would invalidate this:** Nothing — this is pure organization, no behavior change.

### D5: CLAUDE.md and AGENTS.md deduplication

**Firmness: FLEXIBLE**

**CLAUDE.md** (for agents working on rip-cage): Keep architecture overview, key gotchas, testing workflow. Remove duplicated quickstart, auth details, safety stack details — link to docs/ and README instead.

**AGENTS.md** (for agents using rip-cage): Keep agent-specific rules (JSON output, `--dry-run`, container naming). Remove everything that duplicates README or CLAUDE.md.

**Rationale:** Three files repeating the same quickstart and safety stack overview means changes require 3 edits. Single-source each piece of information and cross-link.

### D6: Human commands vs agent commands

**Firmness: FLEXIBLE**

The README quickstart shows humans exactly two interactions: `rc up .` and `Ctrl-B d`. Container management commands (`ls`, `attach`, `down`, `destroy`) appear in `docs/cli-reference.md`, not the quickstart.

Agent-facing features (`--output json`, `--dry-run`, container naming rules) live in AGENTS.md and `docs/cli-reference.md`.

`rc --help` remains comprehensive for both audiences.

**Rationale:** Humans need one command to start and one keystroke to leave. Showing 9 commands upfront creates the impression that rip-cage is complex. It isn't — the complexity is in the safety stack, not the UX.

**What would invalidate this:** If users frequently need `destroy` or `ls` in normal flow. Current evidence: the primary user never uses these manually — agents handle container lifecycle.

## Deferred

- **GHCR auto-pull** — Pull pre-built image instead of building locally. Depends on GHCR infra being stable (ADR-008 D6). Auto-build is the bridge.
- **`rc.conf` auto-generation** — Prompt user for allowed roots on first run instead of requiring manual export. Nice UX but adds interactive complexity.
- **Homebrew tap** — Would eliminate the clone+symlink install step entirely. Requires versioned releases working first.
