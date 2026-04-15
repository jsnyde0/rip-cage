# Fixes: agents-in-containers
Date: 2026-04-15
Review passes: 1

## Critical
(none)

## Important
- **rc:~656** — Duplicate `local _asset_tdir` declaration in `_up_prepare_docker_mounts`. The agents block copy-pasted from skills redeclares `local _asset_tdir` in the same function scope. Bash `local` is function-scoped, so the second declaration is redundant and resets the variable. Fix: remove the `local` keyword from the agents block's `_asset_tdir` declaration (keep the assignment in the `while read` loop, just don't re-declare it as local).

## Minor
- **docs/decisions/ADR-002-rip-cage-containers.md:~494-496** — D19 text still references old function name `_collect_skill_symlink_parents`. Fix: update to `_collect_symlink_parents`.

## ADR Updates
- ADR-002 D19: stale function name to be updated (included in Minor fixes above)

## Discarded
- Cross-asset deduplication of symlink parent mounts — pre-existing pattern, Docker tolerates duplicate mounts, no functional impact
- `commands` missing symlink parent resolution — pre-existing gap not introduced by this change, worth filing as separate follow-up
- `$HOME` vs `RC_ALLOWED_ROOTS` symlink validation — pre-existing, explicitly acknowledged and deferred in design doc
- Test functions copy-pasted (not sourced from rc) — pre-existing pattern across all symlink tests, small function unlikely to drift
- Test 14 environment-conditional (skips when ~/.claude/agents absent) — intentional design choice per bead spec
- Devcontainer agent mounts unconditional (no existence check) — pre-existing pattern for skills and commands too
- Test 12 RC_ALLOWED_ROOTS pattern difference — functional, minor inconsistency in test setup
