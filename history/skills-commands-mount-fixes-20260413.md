# Fixes: skills-commands-mount
Date: 2026-04-13
Review passes: 1

## Critical
- **rc:196-197, 215-216** — devcontainer.json mounts skills/commands unconditionally; if `~/.claude/skills` or `~/.claude/commands` don't exist on the host, VS Code Dev Containers fails to open (Docker creates root-owned dirs at mount source). **Fixed:** added `mkdir -p "${HOME}/.claude/skills" "${HOME}/.claude/commands"` to the `initializeCommand` in both footer heredocs (DEVCONTAINER_FOOTER_SERVER and DEVCONTAINER_FOOTER_EMBEDDED), matching the existing `touch` pattern for CLAUDE.md.

## Important
- **init-rip-cage.sh:48-53** — `ln -sfn` against a pre-existing real directory silently creates a nested symlink (`~/.claude/skills/skills ->`) instead of replacing the directory, making skills invisible to Claude Code. **Fixed:** added a guard that removes any real (non-symlink) directory at the target path before symlinking.
- **rc:801-812** — dry-run human-readable output omitted the skills/commands mounts, making `rc --dry-run up .` incomplete. **Fixed:** added two conditional `echo` lines after the git hooks dry-run output.

## Minor
- **init-rip-cage.sh** — step numbering collision: new block was labeled `3a` while the next block was `3`, making the sequence read `1, 2, 3a, 3, 4, 5, 6, 7, 8`. **Fixed:** renumbered to `1` through `9` sequentially.

## ADR Updates
- **ADR-002 D17 (new):** Added decision documenting that host skills/commands are mounted read-only via the `.rc-context/` staging pattern. Explains security posture (user-authored, read-only, no new secret exposure — distinct from D8's `.env` refusal), alternatives considered, and what would invalidate the decision.

## Discarded
- **Mount ordering inconsistency** (rc up vs rc init paths): skills/commands appear at different positions relative to other mounts in the two code paths. Not a bug — the two paths have different structural constraints and the functional behavior is identical. Not worth the churn.
- **Test coverage gap**: Both reviewers flagged zero test coverage for the new feature. Valid long-term concern but out of scope for this immediate fix pass. The worktree feature's `test-worktree-support.sh` is the right template when tests are added.
