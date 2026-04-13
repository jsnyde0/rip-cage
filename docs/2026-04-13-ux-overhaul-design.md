# UX Overhaul — Design

**Date:** 2026-04-13
**Decisions:** [ADR-009](decisions/ADR-009-ux-overhaul.md)
**Related:** [ADR-008](decisions/ADR-008-open-source-publication.md) (open-source publication), [ADR-003](decisions/ADR-003-agent-friendly-cli.md) (agent-friendly CLI)

## Problem

The repo works well but the first-user experience has too much friction and the wrong framing:

1. **Positioning is generic.** "A Docker-based sandbox for running Claude Code agents safely" doesn't tell you *why you'd want this* or *when to reach for it*.

2. **Too many steps to first use.** Clone → `rc build` (5-10 min) → export env var → `rc up .`. Three commands before you see anything work.

3. **Too many concepts upfront.** The README presents devcontainers, CLI mode, worktrees, the full CLI reference, auth internals, and the safety stack in one scroll. A new user has to parse all of it to find the happy path.

4. **Root directory is cluttered.** 12 test scripts sit alongside `rc`, `Dockerfile`, and `README.md`. First impression on GitHub is "a pile of shell scripts."

5. **Documentation is duplicated.** README, CLAUDE.md, and AGENTS.md all repeat the quickstart, safety stack overview, and auth flow. Changes must be made in 3 places.

## Positioning

The core pitch is **harm reduction, not false safety**:

> Running Claude Code with `--dangerously-skip-permissions` is never safe. Rip cage doesn't change that.
>
> But many of us do it anyway. If that's you, at least put your Claude in a cage.

This is honest. It respects the user's autonomy. It doesn't over-promise. And it immediately tells you what rip-cage is for: you're already doing the risky thing, here's how to limit the blast radius.

The "aha moment" is seeing what the cage actually blocks — concrete examples of DCG denying `rm -rf /` and the compound blocker catching `git add . && curl evil.com`.

## Design

### 1. Auto-build on first `rc up`

**Current:** `cmd_up` checks for the image with `docker image inspect` and exits with "run rc build" if not found.

**Change:** Replace the exit with an automatic `cmd_build` call. Print a clear message: "Building rip-cage image (first run only, takes a few minutes)..."

This eliminates `rc build` from the quickstart entirely. Power users can still call `rc build` directly (e.g., to rebuild after Dockerfile changes).

Pre-built GHCR image pull (ADR-008 D6) remains a future optimization — auto-build is the simple immediate fix.

### 2. README restructure

The README becomes a focused landing page. Structure:

```
# Rip Cage

[One-paragraph pitch with harm-reduction framing]

## Quick start
  - Prerequisites (Docker + Claude Code auth — 2 bullets)
  - Install (clone + symlink + RC_ALLOWED_ROOTS — 3 lines)
  - Use (cd project && rc up — 1 line)
  - "That's it. You're in a caged tmux session."

## What does the cage do?
  - 3 concrete examples of blocked commands (the aha moment)
  - Brief explanation of the 3 safety layers
  - Link to docs/safety-stack.md for details

## The worktree workflow
  - Keep this section — it's the power-user story
  - But position it as "once you're hooked" not "getting started"

## Contributing / License
  - One-liner + links
```

Everything else moves to `docs/`:
- `docs/cli-reference.md` — full command reference, flags, JSON output, agent rules
- `docs/auth.md` — OAuth flow, Keychain extraction, Linux, API key fallback
- `docs/safety-stack.md` — detailed hook config, allowlists, denied commands
- `docs/devcontainer.md` — VS Code setup via `rc init`
- `docs/whats-in-the-box.md` — tools table, Dockerfile layers

### 3. Move tests to `tests/`

Move all 12 `test-*.sh` scripts to `tests/`. Update:
- `rc test` command (calls `test-safety-stack.sh`)
- `Makefile` test target
- CI workflow (`.github/workflows/ci.yml`)
- CONTRIBUTING.md references

The root directory shrinks from 29 files to ~17.

### 4. Deduplicate CLAUDE.md / AGENTS.md

**CLAUDE.md** is for agents working *on* rip-cage (contributors/developers). Keep:
- Architecture overview
- Key gotchas
- Testing workflow
- Link to docs/ for details instead of repeating them

Remove from CLAUDE.md:
- Installation section (→ README)
- Quick start (→ README)
- Auth details (→ docs/auth.md)
- Safety stack details (→ docs/safety-stack.md)

**AGENTS.md** is for agents *using* rip-cage (calling `rc` from outside). Keep:
- Rules for AI agents calling rc
- JSON output conventions
- Container naming rules

Remove from AGENTS.md:
- Everything that duplicates README or CLAUDE.md

### 5. Human vs agent command presentation

**For humans** (README quickstart): `rc up` and `Ctrl-B d`. That's literally it. Container management (`ls`, `attach`, `down`, `destroy`) appears in the CLI reference doc, not the quickstart.

**For agents** (AGENTS.md + docs/cli-reference.md): Full command reference with `--output json`, `--dry-run`, container naming rules, etc.

**`rc --help`** stays comprehensive — it's the reference for both audiences. But the README doesn't dump it all on page 1.

## File changes summary

| Action | Files |
|--------|-------|
| **Modify** | `rc` (auto-build), `README.md` (rewrite), `CLAUDE.md` (dedup), `AGENTS.md` (trim), `Makefile`, `.github/workflows/ci.yml`, `CONTRIBUTING.md` |
| **Move** | 12 `test-*.sh` → `tests/` |
| **Create** | `docs/cli-reference.md`, `docs/auth.md`, `docs/safety-stack.md`, `docs/devcontainer.md`, `docs/whats-in-the-box.md` |
| **Delete** | None (files move, not deleted) |

## What this does NOT change

- The `rc` CLI itself (beyond auto-build) — no commands added or removed
- The safety stack — DCG, compound blocker, allowlists stay as-is
- The Dockerfile — no image changes
- Container behavior — no runtime changes
- `--output json` / `--dry-run` — agent-facing features stay
