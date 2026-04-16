# Fixes: shell-completions
Date: 2026-04-16
Review passes: 1

## Critical

- **tests/test-completions.sh:16** — Zsh syntax validation test is a false positive. Running `zsh --no-rcs -c "source completions/_rc"` without loading compinit makes `_arguments` unavailable. The `_rc` function call at the bottom of the file triggers `command not found: _arguments` on stderr (suppressed by `2>/dev/null`) but the source command itself exits 0. The test always passes, even for a broken file. Fix: use the design doc's exact command: `zsh -c 'autoload -Uz compinit && compinit && source completions/_rc'` which loads the completion framework first, making real syntax errors detectable.

## Important

- **rc:~1344-1351** — `cmd_completions()` is dead code. The fast-path at line ~30 intercepts every `rc completions ...` invocation and exits before reaching the dispatch table. No valid invocation path reaches `cmd_completions()` (`--dry-run` rejects it, `--output json` rejects it, `--version` exits). Remove `cmd_completions()` entirely. In the dispatch case, either remove the entry (let it fall to usage) or replace with a one-line inline that mirrors the fast-path as a safety net. Add a comment at the fast-path noting it is the canonical handler.

- **tests/test-completions.sh:~68-77** — Subcommand sync test only covers zsh completions. The bash completion file's subcommand list (`completions/rc.bash` line 9) can silently drift. Add a parallel sync check that extracts commands from the bash completion string and compares against `rc schema` output — same logic as the existing zsh check.

- **rc:~5-38** — Container guard at line ~5 blocks `rc completions` inside containers and CI. The fast-path is placed AFTER the container guard, so `rc completions zsh` (a pure-output command with zero Docker dependency) fails inside any container. Fix: move the fast-path block (lines ~28-38) ABOVE the container guard, immediately after SCRIPT_DIR resolution. This requires SCRIPT_DIR resolution to also move above the guard (it only does readlink, no Docker dependency).

## Minor

None.

## ADR Updates

- No ADR changes needed. All FIRM decisions (ADR-011 D1/D3/D4, ADR-008 D5, ADR-003 D5) are correctly implemented. The ADR-009 D3 tension (third quickstart step) is adequately mitigated by the "(optional)" label.

## Discarded

- **Bash `prev`-based completion architecture** (Arch reviewer): Design doc explicitly defers flag completion. Current `prev` approach is correct for the scoped feature. Noted for future flag-completion work.
- **ADR-009 D3 quickstart conflict** (Arch reviewer): Adding an optional third step is technically in tension with "exactly two interactions" but the "(optional)" framing makes it a non-issue. Not worth an ADR revision.
- **`.zprofile` fallback for fresh macOS** (Impl reviewer): Edge case affecting users with no `.zshrc` at all (rare — Homebrew/Oh My Zsh create it). Not worth a fix cycle.
- **Empty `schema_cmds` guard** (Impl reviewer): If python3 is absent, the test script fails at the line itself under `set -euo pipefail`. The empty-loop scenario requires both `rc schema` failure AND python3 success, which is extremely unlikely.
