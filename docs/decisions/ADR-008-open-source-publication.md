# ADR-008: Open-Source Publication

**Status:** Proposed
**Date:** 2026-04-13
**Design:** [Open-Source Readiness](../2026-04-13-open-source-readiness-design.md)
**Related:** [ADR-002](ADR-002-rip-cage-containers.md) (container architecture), [ADR-003](ADR-003-agent-friendly-cli.md) (CLI design)

## Context

rip-cage is a functional Docker sandbox for Claude Code agents. The core CLI (`rc up .`) works, the safety stack (DCG + compound command blocker + allowlists) is tested with 40+ checks, and the architecture is documented in 6 ADRs and 13+ design docs.

However, the repo cannot be published as-is. There is no LICENSE file (legal blocker), personal data is embedded in docs, there's no versioning or CI, and contributors have no onboarding docs. A comprehensive scan identified 11 actionable items across 4 priority tiers.

## Decisions

### D1: MIT License

**Firmness: FIRM**

Use the MIT license. The repo already claims MIT in the README. Copyright holder: "rip-cage contributors" (not an individual name). Year: 2025-present.

**Rationale:** MIT is the most permissive widely-recognized license. It's compatible with the Apache-2.0 licensed DCG dependency built into the Docker image. The "contributors" copyright holder avoids tying the project to a single person.

**What would invalidate this:** Discovery of a dependency with an incompatible license (e.g., AGPL). Currently all dependencies are MIT or Apache-2.0 compatible.

### D2: Scrub personal data from tracked files only

**Firmness: FIRM**

Replace personal paths, usernames, and emails in all tracked files with generic placeholders. Do NOT attempt to rewrite git history — the cost (force-push, broken forks) outweighs the benefit (old commits contain paths that are already public via GitHub).

Specific replacements:
- `/Users/jonat/code/...` → `~/projects/...` or context-appropriate generic path
- `jsnyde0` in docs → `youruser`
- `jonatansnyders@gmail.com` in docs → `you@example.com`
- Error message examples with personal paths → generic `$HOME/projects`

**Rationale:** Current file state is what users see. Git history is rarely browsed and contains no secrets (paths and usernames are not credentials). History rewriting breaks all existing clones and forks.

### D3: Semantic versioning starting at v0.1.0

**Firmness: FIRM**

Use semantic versioning (major.minor.patch). Start at `0.1.0` to signal "usable but pre-1.0". Store the version in a `VERSION` file in repo root (single source of truth). The `rc --version` flag reads this file.

**Rationale:** `0.1.0` communicates that the tool works but the API may change. A `VERSION` file is simpler than parsing `git describe` and works in release tarballs without `.git/`. Docker images are tagged with the same version string.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **VERSION file** | Simple, works without git | Extra file to maintain |
| `git describe --tags` | Automatic | Breaks in tarballs, CI needs git history |
| Hardcoded in `rc` | No extra file | Easy to forget updating |

### D4: CI pipeline — lint and build first, integration tests later

**Firmness: FLEXIBLE**

Start with a GitHub Actions workflow that runs:
1. `shellcheck` on all bash scripts
2. `docker build` to verify the image compiles

Integration tests (`rc test`) require Docker-in-Docker or a self-hosted runner. Defer this to a follow-up rather than blocking the initial release.

**Rationale:** Shellcheck + build catches the majority of contribution errors (syntax, Dockerfile issues) without the complexity of DinD. Integration tests are valuable but shouldn't block the first public release.

**What would invalidate this:** If shellcheck + build proves insufficient to catch real contribution breakage. In that case, invest in DinD or a self-hosted runner.

### D5: Bash 3.2 compatibility is a hard requirement

**Firmness: FIRM**

The `rc` script must work with bash 3.2 (macOS default). Any bash 4+ syntax is a bug. Currently, only `rc:928` (`${var,,}`) uses bash 4+ syntax.

**Rationale:** macOS ships bash 3.2 due to GPLv3 licensing of bash 4+. Requiring users to install bash 4+ just to run `rc` is unnecessary friction. The `rc` script uses only basic bash features; the one 4+ usage is easily replaced with `tr`.

### D6: Pre-built Docker image on GHCR

**Firmness: FLEXIBLE**

Publish images to `ghcr.io/jsnyde0/rip-cage:<version>` on tagged releases. Update `rc` to attempt `docker pull` before `docker build` when the local image doesn't exist.

**Rationale:** Building the multi-stage image (Go + Rust + Debian) takes 5-10 minutes on a clean machine. A pre-built image reduces first-use time to ~30 seconds. GHCR is free for public repos and integrates natively with GitHub Actions.

**What would invalidate this:** If the image size becomes unmanageable (>2GB) or if users need to customize the build (e.g., different base image). In that case, provide a `--build` flag instead of auto-pulling.

### D7: Makefile is optional, not required

**Firmness: FLEXIBLE**

A Makefile with `install`, `uninstall`, `build`, `test`, `lint` targets is nice-to-have. The primary installation method remains the symlink (`ln -sf .../rc ~/.local/bin/rc`).

**Rationale:** The single-file CLI design is a feature — `rc` is one bash script with no build step. A Makefile adds convenience but shouldn't replace the direct symlink. Power users prefer the symlink; the Makefile helps casual contributors.

## Deferred

- **Homebrew formula** — Requires a tap repo and versioned releases working first. Evaluate after v0.1.0 is tagged and GHCR publishing is stable.
- **Multi-platform images** — `linux/arm64` (Apple Silicon native) would benefit M1/M2 users. Defer until there's demand — Docker Desktop handles architecture translation.
- **Git history rewrite** — Personal data in old commits is not a security risk (paths, not credentials). The cost of force-pushing outweighs the benefit.
- **Windows support** — `rc` is bash; WSL2 works but is untested. Not a launch blocker.
