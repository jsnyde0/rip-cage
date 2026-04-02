# Fixes: phase1-hardening
Date: 2026-03-27
Review passes: 1 (code-reviewer + 2 competing reviewers)

## Critical
- **rc:102-122** — Devcontainer template missing `BD_NO_DB=true` in `containerEnv`. The `rc up` path sets it via `-e`, and `init-rip-cage.sh` exports it, but the init script's `export` only affects its own process tree. Agent terminal sessions in VS Code won't inherit it, so `bd` will try to use Dolt (which is no longer installed). Fix: add `"BD_NO_DB": "true"` to `containerEnv` in the devcontainer.json template.

## Important
- **test-safety-stack.sh** — Dropped settings.json hook-wiring checks. The original tests 4 & 5 verified that `settings.json` actually registers the DCG and compound-blocker hooks. The new suite tests the binaries directly (checks 8-9) but not the wiring. If settings.json ships without hook entries, the binaries would exist but never fire. Fix: re-add two checks verifying the hook registrations in settings.json.
- **test-safety-stack.sh** — `claude --version` check removed. Claude Code is the entire purpose of the container — it was the one tool checked in the original suite and is now the one tool NOT checked. Fix: add `"claude:claude --version"` to the tool check loop.
- **test-safety-stack.sh:137** — Tool availability check false-positive. `version=$($tool_cmd 2>&1 | head -1 || true)` merges stderr into stdout, so a missing tool's "command not found" message becomes the non-empty `$version`, reporting PASS. Fix: use `command -v "$tool_name"` as a gate, or check exit code separately.
- **rc:348** — macOS date parsing silently fails on ISO 8601 with timezone offset (e.g. `+00:00`). The `${expiry%%.*}` strip only removes fractional seconds after a dot, not `+00:00` or `Z` suffixes without dots. On macOS, `date -jf` fails and GNU `date -d` doesn't exist, so the check silently skips. Fix: strip timezone more aggressively — `${expiry%%[.+Z]*}`.
- **CLAUDE.md:52-55** — Sudoers documentation is stale. Still says `chown *` (narrowed to exact paths in f7db60c) and `npm install -g *` (removed in e9fcc85). Agents reading this will have wrong expectations. Fix: update to match current sudoers policy.

## Minor
- **rc:586-601** — `cmd_test` JSON parsing spawns one `jq` per check line (22 invocations). Works but fragile. Low priority — not worth fixing unless check count grows significantly.
- **zshrc:18-19** — Conditional alias chain logic is correct but reads oddly due to `|| \` continuation. Not a bug. No action needed.

## ADR Updates
- **ADR-002 D10** needs amendment: currently says "bd + Dolt in the base image" but Dolt was removed per ADR-004 D1 (FIRM). Add a note that D10 is superseded by ADR-004 D1.

## Needs Alignment
Two items where design intent is unclear — flagged for your call:

1. **Devcontainer resource limits**: `rc up` now defaults to `--cpus=2 --memory=4g --pids-limit=500`, but the devcontainer template has no equivalent (`runArgs`). The design doc only discusses `cmd_up`. Should the devcontainer path also get resource limits via `runArgs`, or is that VS Code's problem?

2. **Resource limits on container resume**: `docker start` doesn't accept resource flags, so `rc up --cpus=4 --memory=8g` on a stopped container silently ignores the new values. Options: (a) use `docker update` after start to apply new limits, or (b) document that limits are set at creation time only.

## Discarded
- **Redundant BD_NO_DB in two places** (rc + init-rip-cage.sh): Intentional defense-in-depth for the two usage paths. Not a bug.
- **--memory-swap not user-overridable**: Intentional per ADR-004 D2, which only lists 3 override flags.
- **Test count 22 vs design's 21**: Added `gh` to the tool loop — reasonable addition.
- **jq-per-line O(n) in cmd_test**: 22 items is negligible. Not worth refactoring.
- **Input validation on resource limit flags**: Docker itself validates and gives clear errors. Adding our own validation is marginal value for Phase 1.
