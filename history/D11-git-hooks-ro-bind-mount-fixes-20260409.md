# Fixes: D11 Git Hooks RO Bind Mount
Date: 2026-04-09
Review passes: 1

## Critical
(none)

## Important
- **rc:400-403,430-433,464-467,484-487,679-682,699-702** — `git_hooks_ro` field is missing from all worktree JSON output paths. Design doc requires it in both bind-mount and worktree JSON for consistent machine-readable querying. Fix: add `--argjson git_hooks_ro true` (hardcoded — worktree mode always mounts hooks ro) to all 6 worktree `jq` calls. Also fix the computation at lines 380-383 to set `git_hooks_ro=true` when `wt_detected == "true"`.

## Minor
- **rc:120-150** — Devcontainer.json mounts array is fully duplicated across two heredoc branches (`DEVCONTAINER_WITH_HOOKS` / `DEVCONTAINER_NO_HOOKS`). Only difference is one mount entry. Refactor to build the mounts array programmatically or use a placeholder. Defer to future cleanup.
- **rc:102-113** — Worktree detection in `cmd_init` is a simplified subset of `cmd_up`'s detection without error handling. Works correctly by coincidence (`.git` file means no `.git/hooks` dir). Extract to shared function in future refactor.

## ADR Updates
No ADR changes needed.

## Discarded
- **CLAUDE.md test count stale** (arch reviewer): Pre-existing issue, not introduced by this change. Already tracked elsewhere.
- **Test 35 unconditional pass** (both reviewers): Intentional per design doc — documents accepted risk, not meant to verify behavior. Counter inflation is cosmetic.
- **Docker sub-mount behavior assumption** (impl reviewer): Implementation-specific but tests 33-34 verify the observable outcome. No code change needed.
- **Static devcontainer.json snapshot limitation** (impl reviewer): Already documented in design doc's "Why conditional generation" section.
