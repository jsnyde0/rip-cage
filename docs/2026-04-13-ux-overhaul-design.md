# UX Overhaul — Design

**Date:** 2026-04-13
**Decisions:** [ADR-009](decisions/ADR-009-ux-overhaul.md)
**Related:** [ADR-008](decisions/ADR-008-open-source-publication.md) (open-source publication), [ADR-003](decisions/ADR-003-agent-friendly-cli.md) (agent-friendly CLI)

## Problem

The repo works well but the first-user experience has too much friction and the wrong framing:

1. **Positioning is generic.** "A Docker-based sandbox for running Claude Code agents safely" doesn't tell you *why you'd want this* or *when to reach for it*.

2. **Too many steps to first use.** Clone → `rc build` (5-10 min) → export env var → `rc up`. Three commands before you see anything work.

3. **Too many concepts upfront.** The README presents devcontainers, CLI mode, worktrees, the full CLI reference, auth internals, and the safety stack in one scroll. A new user has to parse all of it to find the happy path.

4. **Root directory is cluttered.** 14 test files (13 `test-*.sh` scripts + `test_skill_server.py`) sit alongside `rc`, `Dockerfile`, and `README.md`. First impression on GitHub is "a pile of shell scripts."

5. **Documentation is duplicated.** README, CLAUDE.md, and AGENTS.md all repeat the quickstart, safety stack overview, and auth flow. Changes must be made in 3 places. (Note: AGENTS.md is currently identical to CLAUDE.md — they are the same content, not merely overlapping.)

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

**Change:** Replace the exit with an automatic `cmd_build` call (with no arguments — do NOT forward `cmd_up`'s args to `cmd_build`). Print a clear message: "Building rip-cage image (first run only, takes a few minutes)..."

This eliminates `rc build` from the quickstart entirely. Power users can still call `rc build` directly (e.g., to rebuild after Dockerfile changes).

Pre-built GHCR image pull (ADR-008 D6) remains a future optimization — auto-build is the simple immediate fix.

**Edge cases:**

- **`--output json` mode:** Currently `cmd_build` in JSON mode suppresses all Docker output (`>/dev/null 2>&1`). For auto-build triggered by `cmd_up`, emit a `{"status": "building", "message": "Building rip-cage image (first run only)"}` progress object to stderr before the build starts (consistent with ADR-003 D1: human messages to stderr in JSON mode). Stream Docker build progress to stderr so agent callers see something during the multi-minute build. If the build fails, return a `BUILD_FAILED` JSON error (not `IMAGE_NOT_FOUND`).

- **`--dry-run` mode:** If the image doesn't exist and `--dry-run` is active, report "would build image, then create container" but do NOT execute the build. Building an image is a mutation; dry-run must stay non-mutating.

**First-run narrative (combined with zero-config D7):**

When a brand-new user runs `rc up .` for the first time with no prior configuration:

```
$ rc up ~/projects/my-app

rip-cage: no allowed roots configured.
Allow projects under [/Users/alice]: ⏎

Building rip-cage image (first run only, takes a few minutes)...
[Docker build output streams here — ~5-10 minutes]

✓ Image built. Starting container...
[normal rc up output]
```

The zero-config prompt (ADR-009 D7) fires first (before the image check), then auto-build starts. This is the only time a user sees both prompts — subsequent `rc up` calls skip both.

### 2. README restructure

The README becomes a focused landing page. Structure:

```
# Rip Cage

[One-paragraph pitch with harm-reduction framing]

## Quick start
  - Prerequisites (Docker + Claude Code auth — 2 bullets)
  - Install (clone + symlink — 2 lines; RC_ALLOWED_ROOTS auto-prompted on first run)
  - Use (cd project && rc up — 1 line)
  - "That's it. You're in a caged tmux session."

## What does the cage do?
  - 3 concrete examples of blocked commands (the aha moment)
  - Brief explanation of the 3 safety layers (bypassPermissions + DCG + compound blocker)
  - Link to docs/reference/safety-stack.md for details

## The worktree workflow
  - Keep this section — it's the power-user story
  - But position it as "once you're hooked" not "getting started"

## Contributing / License
  - One-liner + links
```

**For humans** (README quickstart): `rc up .` and `Ctrl-B d`. That's literally it. Container management (`ls`, `attach`, `down`, `destroy`) appears in the CLI reference doc, not the quickstart.

**`rc --help`** stays comprehensive — it's the reference for both audiences. But the README doesn't dump it all on page 1.

**Important:** The current README has stale safety stack claims — "Auto-mode with allowlists" (should be "bypassPermissions") and "Sudo is limited to `apt-get`, `chown`, and `npm install -g`" (npm install -g was removed per ADR-002 D12 amendment). The rewrite must use correct terminology.

Everything else moves to `docs/reference/`:
- `docs/reference/cli-reference.md` — full command reference, flags, JSON output format, `--dry-run` behavior. Technical reference for all audiences.
- `docs/reference/auth.md` — OAuth flow, Keychain extraction, Linux path, API key fallback
- `docs/reference/safety-stack.md` — detailed hook config, allowlists, denied commands, bypassPermissions explanation
- `docs/reference/devcontainer.md` — VS Code setup via `rc init`
- `docs/reference/whats-in-the-box.md` — tools table, Dockerfile layers

Using `docs/reference/` separates user-facing reference material from the date-prefixed internal design docs in `docs/`.

**Content migration guide** (what moves where from current sources):

| Destination | Content from README | Content from CLAUDE.md | Content from AGENTS.md |
|-------------|-------------------|----------------------|----------------------|
| `docs/reference/cli-reference.md` | CLI reference section (commands, flags, `--output json`, `--dry-run`) | — | — |
| `docs/reference/auth.md` | Auth section | Auth flow details (CLAUDE.md "Auth" section) | — |
| `docs/reference/safety-stack.md` | Safety stack details | Safety stack section | — |
| `docs/reference/devcontainer.md` | Devcontainer/"Reopen in Container" section | — | — |
| `docs/reference/whats-in-the-box.md` | "What's in the box" tools table | Container user model section | — |

### 3. Move tests to `tests/`

Move all 14 test files (13 `test-*.sh` scripts + `test_skill_server.py`) to `tests/`. Update:
- `Dockerfile` — COPY source paths for `test-safety-stack.sh` and `test-skills.sh` change from root to `tests/` (only these 2 of the 14 files are COPYed into the image; the other 12 are host-only). Destination paths (`/usr/local/lib/rip-cage/`) stay the same.
- `Makefile` — `BASH_SCRIPTS` list and `test` target paths. Currently lists individual test scripts by name; all need `tests/` prefix.
- CI workflow (`.github/workflows/ci.yml`) — 9 individually named test steps need path updates.
- `CONTRIBUTING.md` — the "Running the safety stack tests" section (lines 54-101) and the shellcheck lint command (line 151: `shellcheck rc init-rip-cage.sh hooks/*.sh test-safety-stack.sh`) need full path updates.

The root directory shrinks from 34 items to ~20.

**Implementation note:** This must be one atomic commit — move files AND update all references (Dockerfile, Makefile, CI, CONTRIBUTING.md) simultaneously. Intermediate states with broken references would fail CI.

**Note:** `rc init` devcontainer template does NOT need updating — it references in-container paths, not repo source paths. `rc test` references the in-container path (`/usr/local/lib/rip-cage/test-safety-stack.sh`) which stays the same.

### 4. Deduplicate CLAUDE.md / AGENTS.md

**CLAUDE.md** is for agents working *on* rip-cage (contributors/developers). Keep:
- Architecture overview
- Key gotchas
- Testing workflow
- Beads integration block (`<!-- BEGIN BEADS INTEGRATION -->` ... `<!-- END BEADS INTEGRATION -->`) — auto-injected, preserve as-is
- Link to `docs/reference/` for details instead of repeating them

Remove from CLAUDE.md:
- Installation section (→ README)
- Quick start (→ README)
- Auth details (→ `docs/reference/auth.md`)
- Safety stack details (→ `docs/reference/safety-stack.md`)

**Fix stale content in retained sections:** CLAUDE.md currently says "full auto mode" (line 1), "auto mode, allowlisted commands" (line 12), and "auto-approves safe commands...Everything else requires confirmation" (line 71). These are inaccurate under bypassPermissions (ADR-002 D5 amendment). Fix as part of the dedup work.

**AGENTS.md** is for agents *using* rip-cage (calling `rc` from outside). Currently it is identical to CLAUDE.md — this is a full rewrite, not a trim. New content:
- Behavioral rules for AI agents calling `rc` (the 9 bullet points from current CLAUDE.md lines 114-124: use `--output json`, use `--dry-run` before destroy, etc.)
- Container naming conventions
- Link to `docs/reference/cli-reference.md` for technical details (JSON output format, flag reference)

**Single source of truth for agent content:** Agent behavioral rules live in AGENTS.md only. Technical CLI reference (JSON fields, flag behavior) lives in `docs/reference/cli-reference.md` only. AGENTS.md links to the CLI reference for technical details. This avoids re-creating the duplication problem.

### ~~5. Human vs agent command presentation~~ *(merged into sections 2 and 4)*

The human-vs-agent presentation philosophy is now embedded directly in sections 2 (README: humans see `rc up` + `Ctrl-B d` only) and 4 (AGENTS.md: agent behavioral rules; `docs/reference/cli-reference.md`: technical reference). No separate implementation task.

### 6. `rc auth refresh` — credential hot-swap without container restart

**Current:** Credentials are extracted from the macOS Keychain into `~/.claude/.credentials.json` once during `cmd_up` (lines 598-613). The file is bind-mounted read-write into the container (`-v "${HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json"`). When a user switches accounts or refreshes auth on the host, the Keychain updates but the file doesn't — the container sees stale credentials until `rc destroy` + `rc up`.

**Discovery:** The bind mount means the file is live-shared. Updating `~/.claude/.credentials.json` on the host propagates instantly to all running containers. The missing piece is just a convenient command to trigger the keychain-to-file extraction.

**Change:**

1. Extract the keychain-to-file logic (lines 598-613 of `rc`) into a helper function `_extract_credentials`.
2. Add `cmd_auth_refresh` that calls `_extract_credentials` and reports success/failure.
3. Update `cmd_up` to call `_extract_credentials` instead of inline code (dedup).
4. On Linux: print a message explaining that credentials must be updated manually at `~/.claude/.credentials.json`.

```bash
# User switches account on host:
claude auth login          # updates macOS Keychain
rc auth refresh            # extracts to file → bind mount propagates to all containers

# Inside container: Claude Code picks up new credentials on next API call
```

**Edge cases:**
- `--output json` mode: emit `{"status": "ok", "credentials_updated": true}` or `{"status": "error", "code": "KEYCHAIN_EXTRACTION_FAILED", ...}`.
- No running containers: still works — updates the file for next `rc up`.
- Linux: no keychain to extract from. Print: `"On Linux, update ~/.claude/.credentials.json directly. Running containers will see the change immediately via bind mount."`

**Documentation:** Add a "Switching accounts" section to `docs/reference/auth.md`. Mention in README quickstart as a tip (not a required step).

## Implementation ordering

The 5 changes have dependencies that constrain ordering:

1. **Tests to `tests/`** (section 3) — first. Pure mechanical refactor, no behavior change. All subsequent work uses the new paths.
2. **Auto-build** (section 1) — second. Small, isolated `rc` code change. Can be implemented and tested independently.
3. **`rc auth refresh`** (section 6) — third. Small `rc` refactor (extract helper + new command). Independent of docs work.
4. **README + CLAUDE.md/AGENTS.md dedup** (sections 2 + 4) — together, fourth. They share content — you can't write `docs/reference/auth.md` without knowing what's removed from README AND CLAUDE.md. Doing them separately risks content in limbo (removed from source but not yet in destination). `docs/reference/auth.md` now also covers the credential hot-swap from section 6.
5. **Zero-config test isolation fix** — depends on step 1 (test files have new paths).

## File changes summary

| Action | Files |
|--------|-------|
| **Modify** | `rc` (auto-build logic in `cmd_up`, `_extract_credentials` helper, new `cmd_auth_refresh`), `Dockerfile` (COPY source paths for 2 test files), `README.md` (full rewrite), `CLAUDE.md` (dedup + fix stale content), `Makefile` (test paths), `.github/workflows/ci.yml` (test paths), `CONTRIBUTING.md` (test paths + lint command) |
| **Rewrite** | `AGENTS.md` (currently identical to CLAUDE.md → agent-only rules) |
| **Move** | 14 test files (`test-*.sh` + `test_skill_server.py`) → `tests/` |
| **Create** | `docs/reference/cli-reference.md`, `docs/reference/auth.md`, `docs/reference/safety-stack.md`, `docs/reference/devcontainer.md`, `docs/reference/whats-in-the-box.md` |
| **Delete** | None (files move, not deleted) |

## What this does NOT change

- The `rc` CLI itself (beyond auto-build and `auth refresh`) — no other commands added or removed
- The safety stack — DCG, compound blocker, allowlists stay as-is
- Container behavior — no runtime changes
- `--output json` / `--dry-run` semantics — agent-facing features stay (auto-build adds new behavior in these modes, documented above)
- Skills infrastructure — `skill-server.py` is NOT a test file and does not move
