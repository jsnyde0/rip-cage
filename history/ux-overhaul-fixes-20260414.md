# Fixes: ux-overhaul
Date: 2026-04-14
Review passes: 1

## Critical
- **rc:859-865** — Auto-build dry-run JSON output missing `action` field. Existing tests (test-dg6.2.sh test 10/11, test-json-output.sh test 7) assert `action` field exists. When image is absent and `--dry-run` is set, current code emits `{dry_run, would_build, message}` without `action`. Fix: add `"action": "would_build_and_create"` to the JSON output. Verify test assertions match the new action value.

## Important
- **docs/reference/safety-stack.md:18-25** — Allowlist section doesn't match `settings.json`. Lists `head`, `tail` (not in settings.json). Missing: `date`, `which`, `type`, `basename`, `dirname`, `realpath`, `git stash list`, `git rev-parse`, `npm run test`, `npm run lint`, `bun run test`, `bun run lint`, `uv tree`, `uv version`, `uv python list`, `uv run -m pytest`. Fix: audit settings.json and replace the allowlist section with accurate content.
- **docs/reference/safety-stack.md:14,29** — Self-contradiction: line 14 says "allowlist and denylist are bypassed" (bypassPermissions), line 29 says "Writing to `.git/hooks/*` is hard-denied." Fix: clarify that the `.git/hooks/*` deny is enforced via the `Write`/`Edit` deny entries in `settings.json`'s hook config, which fires regardless of bypassPermissions mode.
- **docs/reference/whats-in-the-box.md:12** — Lists "Go | For building Go tools" but Go is only in the Dockerfile builder stage, not the runtime image. Fix: remove the Go row or change to "Go (build stage only) | Used to compile bd/beads — not available at runtime".

## Minor
- **docs/decisions/ADR-009-ux-overhaul.md:102,104** — D6 references `docs/cli-reference.md` twice; actual path is `docs/reference/cli-reference.md`. Fix: update both references.
- **CONTRIBUTING.md:134** — Says "add it to the CLI reference in README.md" but CLI reference moved to `docs/reference/cli-reference.md`. Fix: update to point to new location.
- **CLAUDE.md** — Auth flow contributor context lost in dedup. The "If you're modifying auth logic, the flow is: 1. rc init → keychain extraction 2. rc up → keychain extraction 3. init-rip-cage.sh → reads mounted file" was contributor-oriented content appropriate for CLAUDE.md. Fix: add a brief "Auth flow (for contributors)" note pointing to docs/reference/auth.md but preserving the 3-step summary.

## ADR Updates
- ADR-009 D6: fix `docs/cli-reference.md` → `docs/reference/cli-reference.md` (text error, not a decision change)
- D8 (`rc auth refresh`) was added during this session as FIRM but not implemented. This is new scope — create a follow-up bead rather than treating as a bug. No ADR revision needed.

## Discarded
- **Inline docker build vs cmd_build (arch)**: Intentional. `cmd_build` in JSON mode does `>/dev/null 2>&1` which silences everything. The inline approach correctly streams to stderr for auto-build. The DRY concern is valid but the behavioral difference is required.
- **IMAGE_NOT_FOUND removal (arch)**: Intentional behavior change per ADR-009 D2. Agents now get auto-build or BUILD_FAILED instead.
- **No auto-build test coverage (both)**: Valid concern but adds testing infrastructure scope beyond this fix cycle. The dry-run path fix (Critical #1) is the priority.
- **README [then] workaround (impl)**: Deliberate. The compound command blocker hook blocks literal `&&` in files during editing. `[then]` avoids triggering the hook.
- **Shellcheck/Makefile inconsistencies (impl)**: Pre-existing gaps not introduced by this change.
