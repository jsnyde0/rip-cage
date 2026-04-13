# Design: Open-Source Readiness

**Date:** 2026-04-13
**Status:** Draft
**Decisions:** [ADR-008 Open-Source Publication](decisions/ADR-008-open-source-publication.md)
**Origin:** rip-cage works as a CLI tool (`rc up .`) but lacks licensing, CI, versioning, and documentation needed for public release. Personal data is embedded in docs and examples.
**Related:** [ADR-002 Rip-Cage Containers](decisions/ADR-002-rip-cage-containers.md), [ADR-003 Agent-Friendly CLI](decisions/ADR-003-agent-friendly-cli.md)

---

## Problem

rip-cage is a working Docker sandbox for Claude Code agents, but it cannot be published as open source in its current state:

1. **No license file** — README claims MIT but no LICENSE file exists. Legally, nobody can use the code.
2. **Personal data in docs** — 29 occurrences across 5 files of `/Users/jonat/code/mapular/...` paths, `jsnyde0` GitHub username, and `jonatansnyders@gmail.com` email.
3. **No versioning** — No git tags, no `--version` flag, no CHANGELOG. Users can't pin versions or track changes.
4. **No CI** — 11 test scripts exist (~1,600 lines) but no GitHub Actions pipeline to run them on PRs.
5. **No contributor docs** — No CONTRIBUTING.md, CODE_OF_CONDUCT.md, or issue/PR templates.
6. **Bash 3.2 incompatibility** — `rc` line 928 uses `${var,,}` (bash 4+ only), breaking `rc test --output json` on macOS default bash.
7. **Missing prerequisite checks** — `jq` and `tmux` are used without checking if they're installed.
8. **No pre-built image** — New users must build the Docker image (5-10 min) instead of pulling from GHCR.
9. **Code quality** — `cmd_up()` is 497 lines; stderr capture bug at line 728; credentials path not cleared on extraction failure.

## Goal

Make rip-cage ready for public GitHub release so that:
- Anyone can install and use it (`rc up .`) within minutes
- Contributors can find issues, understand the codebase, and submit PRs
- CI validates all contributions automatically
- No personal data is exposed

## Non-Goals

- Homebrew formula (post-launch)
- Multi-platform Docker images (start with linux/amd64 only)
- Full refactor of `rc` (just the worst offenders)
- Windows support

---

## Design

### Phase 0: Legal & Privacy (P0 — blockers)

#### LICENSE file

Add standard MIT LICENSE file in repo root with copyright holder "rip-cage contributors" and year 2025-present. README already claims MIT — this makes it real.

#### Personal data scrub

Replace all personal data with generic placeholders:

| Pattern | Replacement |
|---------|-------------|
| `/Users/jonat/code/mapular/...` | `~/projects/my-app` or `$HOME/projects` |
| `/Users/jonat/code/personal/...` | `~/projects/my-app` |
| `jsnyde0` (in docs, not git history) | `youruser` |
| `jonatansnyders@gmail.com` (in docs) | `you@example.com` |
| `$HOME/code/personal:$HOME/code/mapular` | `$HOME/projects` |

Files to scrub:
- `rc` line 260 — error message example path
- `docs/2026-04-02-worktree-git-mount-design.md` — 12 occurrences
- `docs/2026-04-09-beads-no-db-container-support.md` — 2 occurrences
- `docs/2026-03-26-agent-friendly-cli-design.md` — 6 occurrences
- `docs/2026-03-25-rip-cage-design.md` — 8 occurrences
- `docs/decisions/ADR-002-rip-cage-containers.md` — 1 occurrence
- `README.md` — RC_ALLOWED_ROOTS example

Note: `.beads/` is already gitignored, so personal email in beads metadata is not exposed. Git history will retain old references but that's acceptable — the current state of files must be clean.

### Phase 1: Core Infrastructure (P1)

#### Versioning

- Add `VERSION` file in repo root with initial value `0.1.0`
- Add `--version` flag to `rc` that reads `VERSION` file
- Add `CHANGELOG.md` following Keep a Changelog format
- Tag the release commit as `v0.1.0`

#### GitHub Actions CI

Create `.github/workflows/ci.yml` that runs on PRs and pushes to main:
- **Lint job:** shellcheck on `rc`, `init-rip-cage.sh`, `hooks/*.sh`
- **Build job:** `docker build` to verify the image builds
- **Test job:** `rc build && rc up /tmp/test-project && rc test <name>` (requires Docker-in-Docker or a self-hosted runner)

The test job is the hardest part — the safety stack tests need a running container. Start with lint + build; add integration tests as a follow-up.

#### Community docs

- `CONTRIBUTING.md` — How to build, test, and submit PRs
- `CODE_OF_CONDUCT.md` — Contributor Covenant v2.1
- `.github/ISSUE_TEMPLATE/bug_report.md` and `feature_request.md`
- `.github/PULL_REQUEST_TEMPLATE.md`

#### Bash 3.2 fix

Replace `${BASH_REMATCH[1],,}` at `rc:928` with `$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')`. This is the only bash 4+ syntax in `rc`.

### Phase 2: Quality & Distribution (P2)

#### Pre-built Docker image on GHCR

Add `.github/workflows/release.yml` that triggers on version tags (`v*`):
- Builds the image
- Pushes to `ghcr.io/jsnyde0/rip-cage:<version>` and `:latest`
- Update `rc` to pull from GHCR when image doesn't exist locally (with `--build` flag to force local build)

Depends on: versioning (P1) and CI (P1) being in place.

#### Prerequisite checks

Add `check_prerequisites()` function at the top of `rc` that validates:
- `docker` — running and accessible
- `jq` — required for JSON output mode
- `tmux` — required for `rc up` (CLI mode)

Run checks once at CLI startup, not in every subcommand. Skip checks that aren't needed for the current command (e.g., `rc ls` doesn't need `tmux`).

#### Bug fixes

- `rc:728` — Fix reversed stderr redirect (`2>&1 >/dev/null` → `>/dev/null 2>&1`)
- Credentials extraction — ensure temp file is cleaned up on failure

#### Refactor cmd_up()

Extract logical sections of `cmd_up()` into named functions:
- `prepare_docker_mounts()` — build the mount argument list
- `prepare_environment()` — build the env var list
- `start_container()` — docker run
- `initialize_container()` — run init script, wait for readiness

This is a maintainability improvement, not a behavior change. Keep the function boundaries at logical seams where the existing comments already delineate sections.

### Phase 3: Nice to Have (P3)

#### Makefile

Add `Makefile` with targets: `install`, `uninstall`, `build`, `test`, `lint`. Alternative to the symlink installation method.

---

## Implementation Order

```
P0: LICENSE ──────────────────────────────┐
P0: Scrub personal data ─────────────────┤
                                          ├── P1: Versioning
                                          ├── P1: Bash 3.2 fix
                                          ├── P1: Community docs
                                          │       └── P1: CI pipeline
                                          │              └── P2: GHCR image
                                          ├── P2: Prereq checks
                                          ├── P2: Bug fixes
                                          ├── P2: Refactor cmd_up
                                          └── P3: Makefile
```

P0 items are parallel and block everything else. P1 items can proceed in parallel after P0. P2/P3 items can proceed independently once their dependencies are met.

## Risks

- **Docker-in-Docker CI** — Running `rc test` in GitHub Actions requires privileged containers or a self-hosted runner. Mitigation: start with shellcheck + build only; add integration tests later.
- **GHCR auth** — Requires a GitHub token with `packages:write` scope. Mitigation: use `GITHUB_TOKEN` from Actions, which has this scope by default for the repo owner.
- **Breaking changes during scrub** — Replacing paths in docs could break relative links or examples. Mitigation: grep for broken links after scrub.
