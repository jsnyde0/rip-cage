# Fixes: open-source readiness
Date: 2026-04-13
Review passes: 2

## Critical
- **`.github/workflows/release.yml`:16** — Release workflow bypasses CI entirely. Tag pushes (`v*`) trigger image build+push to GHCR without running shellcheck, build verification, or tests. Fix: add CI jobs to `release.yml` (either inline or via reusable workflow) and make the release job `needs: [lint, build]` at minimum.

## Important
- **`rc:761`** — `shasum` is macOS-only; breaks container name disambiguation on Linux. Fix: use `cksum` (POSIX) or `sha1sum` with macOS fallback: `hash=$(printf '%s' "$path" | cksum | cut -d' ' -f1)` and take last 4 chars.
- **`rc:504`** — `mktemp` failure handler doesn't `return`, so execution continues with empty `creds_tmp`. Fix: add `return` inside the handler: `creds_tmp=$(mktemp) || { echo "Warning: ..." >&2; return; }`
- **`rc:1152`** — tmux check blocks `rc --output json up` callers who never need tmux. Breaks agent orchestration (ADR-003 use case). Fix: `up) [[ "$OUTPUT_FORMAT" == "json" ]] || check_tmux ;;`
- **`.github/workflows/release.yml:34`** — VERSION file and git tag can diverge with no validation, contradicting ADR-008 D3 (VERSION as single source of truth). Fix: add a step that reads VERSION and asserts `== ${GITHUB_REF_NAME#v}`, failing the workflow if they differ.
- **`Makefile:28-30`** — `make test` runs shellcheck (linting), `make lint` aliases `test`. Semantically inverted vs ADR-008 D4 and CI. Fix: rename so `make lint` runs shellcheck, `make test` runs host-only test scripts (or both).
- **`Makefile:5`** — `BASH_SCRIPTS` omits `bd-wrapper.sh` (in CI) and includes `test-safety-stack.sh` (not in CI). Fix: align both lists to match.
- **`.github/workflows/ci.yml`** — `test-prerequisites.sh` is shellchecked but never executed in the test job. Fix: add `bash test-prerequisites.sh` step to the test job.
- **`test-prerequisites.sh:115-120`** — Test 4 header claims 7 docker-dependent commands are tested but loop only covers `build ls`. Fix: expand loop to include `attach down destroy test` (they'll hit the docker check with an invalid container name) or fix the description.
- **`test-prerequisites.sh:83`** — Test 2 assumes tmux is absent from the host environment. If tmux is installed, the test passes for the wrong reason. Fix: use the same PATH-manipulation technique as `_build_nojq_path` to exclude tmux.
- **`rc:305-316,443-454,613-624`** — RC_ALLOWED_ROOTS validation logic is copy-pasted in 3 places with a comment "if hardening one, harden all three." Fix: extract `_path_under_allowed_roots()` helper. (Lower urgency than other Important items — the duplication is documented.)

## Minor
- **`README.md:26` vs `CONTRIBUTING.md:32`** — Placeholder divergence: `yourusername` vs `youruser`. ADR-008 D2 specifies `youruser`. Fix: change README line 26 to `youruser`.
- **`rc:1136-1141`** — `--output json` with no command silently falls through to human-readable `usage`. Fix: add `""` to unsupported branch: `init|attach|schema|"")`.
- **`CHANGELOG.md`** — Claims Keep a Changelog 1.1.0 compliance but missing `[Unreleased]` section and reference links. Fix: add `## [Unreleased]` above `[0.1.0]` and add `[0.1.0]: https://github.com/youruser/rip-cage/releases/tag/v0.1.0` at bottom.
- **`rc:666-667`** — Comment misstates redirect evaluation order ("redirects stderr first, then stdout" — actually evaluates left-to-right: `2>&1` copies stderr to capture pipe, then `>/dev/null` discards stdout). Fix: reword comment.
- **`rc:728-733`** — Duplicate `docker info` check in `cmd_up` is dead code (top-level `check_docker` already ran). Also has macOS-specific "OrbStack" message. Fix: remove lines 728-733.

## ADR Updates
- No ADR changes needed. Findings #A2-1 (release bypasses CI) and #A2-2 (VERSION/tag divergence) are implementation gaps vs ADR-008 D4/D3, not ADR design problems.

## Discarded
- **Schema missing global flags** (A1-5) — nice-to-have, not blocking v0.1.0 launch
- **Helpers use parent-scope vars** (A1-7, I2-1) — acknowledged design trade-off in design doc ("maintainability improvement, not a behavior change")
- **initializeCommand uses direct redirect** (I1-6, A2-3) — different code path (VS Code devcontainer), larger refactor to share extraction logic. Defer to follow-up.
- **cmd_init beads redirect validation gap** (A2-4) — edge case on VS Code path, lower risk
- **CI no gate job** (A2-6) — branch protection can list all three jobs individually
- **amd64-only image** (A2-8) — explicitly deferred in ADR-008 and design doc non-goals
- **mkdir ~/.cache/rc error handling** (A2-9) — unlikely enterprise edge case
- **Credential date parsing order** (A2-10) — minor accuracy issue on Linux, not blocking
- **GitHub Actions pinned to mutable tags** (I2-6) — standard practice for initial release, harden post-launch
