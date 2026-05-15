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

**Implemented at v0.2.0.** Publish images to `ghcr.io/jsnyde0/rip-cage:<version>` on tagged releases (multi-arch: `linux/amd64,linux/arm64`). `rc up`'s auto-build branch tries `docker pull "${RIP_CAGE_IMAGE_REGISTRY}:${RC_VERSION}"` (default registry `ghcr.io/jsnyde0/rip-cage`) and retags the pulled image to `rip-cage:latest`. On pull failure (offline, unauthenticated, missing tag), falls back to local `docker build`. `RIP_CAGE_IMAGE_REGISTRY=""` (explicit empty) opts out of the pull entirely — useful for local dev. `rc build` (the explicit command) is unchanged and always builds locally.

**Rationale:** Building the multi-stage image (Go + Rust + Debian) takes 5-10 minutes on a clean machine. A pre-built image reduces first-use time to ~30 seconds. GHCR is free for public repos and integrates natively with GitHub Actions.

**Release-ceremony note:** GHCR packages default to private on first push. The release-ceremony checklist includes a one-time human action to set the `rip-cage` package's visibility to Public on github.com.

**What would invalidate this:** If the image size becomes unmanageable (>2GB) or if users need to customize the build (e.g., different base image). In that case, the existing `RIP_CAGE_IMAGE_REGISTRY=""` opt-out and explicit `rc build` already provide escape hatches; no further design change needed.

### D7: Install methods — Homebrew is primary, from-source is supported

**Firmness: FLEXIBLE**

**Updated at v0.2.0** (was: "Makefile is optional, not required"). The primary installation method is `brew install jsnyde0/rip-cage/rip-cage`. The Makefile + symlink path (`git clone … && make install`) is retained as the "From source" install for contributors and users without Homebrew.

**Rationale:** The single-file CLI design is still a feature — `rc` is one bash script. Homebrew packages it without changing that design (the formula installs the repo to `libexec/` and symlinks `bin/rc`, and `rc`'s `_resolve_script_dir` follows the symlink). Brew handles upgrades, completion install, and the `jq` + `tmux` dependencies automatically — the friction wins from real-world install testing outweigh the "power users prefer symlinks" framing.

**Alternatives considered:** See D8 for the Homebrew packaging shape (single-repo tap vs separate tap vs homebrew-core).

### D8: Homebrew tap shape — separate tap repo

**Firmness: FLEXIBLE**

**Added at v0.2.0. Revised to separate tap repo after smoke-test showed single-repo pattern doesn't work with Homebrew's naming convention.**

The Homebrew formula lives in [`jsnyde0/homebrew-rip-cage`](https://github.com/jsnyde0/homebrew-rip-cage) (the standard Homebrew tap pattern). Users install via `brew install jsnyde0/rip-cage/rip-cage`. A canonical copy of the formula is kept at `Formula/rip-cage.rb` in this repo — `scripts/update-formula-sha.sh` patches it post-tag and auto-syncs to the tap repo if cloned as a sibling.

**Rationale:** Homebrew's `brew tap user/name` hardcodes a clone of `github.com/user/homebrew-name`. The `homebrew-` prefix is not optional. A "single-repo tap" only works if the project repo itself is named `homebrew-*`, which is awkward. The separate tap repo is the universal pattern (used by `gh`, GoReleaser, etc.) and the only one that makes `brew install user/tap/formula` work without a manual `brew tap ... URL` step.

**Release ceremony (tap sync):**
1. Tag → GHCR publish (existing)
2. `scripts/update-formula-sha.sh` patches `Formula/rip-cage.rb` in this repo and copies to `../homebrew-rip-cage/` if present
3. Commit + push both repos

**Alternatives considered:**

| Approach | Pros | Cons | Rejected (warrant) |
|----------|------|------|--------------------|
| **Separate `homebrew-rip-cage` tap repo (chosen)** | Standard pattern; `brew install` works out of the box | Two repos to keep in sync (mitigated by script) | — |
| Single-repo tap | One repo | Doesn't work — Homebrew prepends `homebrew-` to repo name, so `brew tap jsnyde0/rip-cage` looks for `homebrew-rip-cage` | `tested:` smoke-test on Mac Mini confirmed this fails |
| homebrew-core submission | Brew users get it for free (`brew install rip-cage`) | Strict review; usage threshold (~75 GH stars); slow merge | `external:` HB-core docs require sustained usage; revisit at v1.0 if there's demand |
| npm wrapper | Familiar for JS devs; ClaudeBox precedent | Node dependency for a bash tool is jarring | `reasoned:` doesn't fit the audience (Claude Code users mostly have docker + brew already) |
| curl-pipe-bash installer | Zero deps; works on any *nix | Divisive ("don't pipe curl to bash"); no upgrade story | `reasoned:` brew + git-clone covers everyone willing |

**What would invalidate this:** Formula needs to grow to multiple variants (rc-stable, rc-edge, rc-experimental), or homebrew-core submission becomes viable (project has clear traction and a stable API). Revisit then — separate tap or homebrew-core become the right shapes at that scale.

## Deferred

- **GH Action for auto-sha256 bump** — `scripts/update-formula-sha.sh` is the load-bearing piece; wrapping it in CI that fires on tag push (and either auto-commits or opens a PR) is a small follow-up. Shrinks the post-tag broken-`brew install` window from "however long the human takes" to "CI runtime."
- **DinD-based end-to-end `brew install` smoke test in CI** — would catch formula regressions automatically but requires Docker-in-Homebrew. Manual smoke check at release ceremony covers it for now.
- **Git history rewrite** — Personal data in old commits is not a security risk (paths, not credentials). The cost of force-pushing outweighs the benefit.
- **Windows support** — `rc` is bash; WSL2 works but is untested. Not a launch blocker.
