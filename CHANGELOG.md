# Changelog

All notable changes to rip-cage will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-14

Super-easy install: rip-cage now ships via Homebrew, and first-run pulls a pre-built image from GHCR instead of building locally.

### Added

- Homebrew formula: `brew install jsnyde0/rip-cage/rip-cage` (ADR-008 D8 — single-repo tap pattern)
- `rc up` pulls the pre-built image from `ghcr.io/jsnyde0/rip-cage:<VERSION>` before falling back to local `docker build` (ADR-008 D6). Cuts first-run from 5–10 min to ~30 s.
- `RIP_CAGE_IMAGE_REGISTRY` env var to override the GHCR registry path or opt out of pull entirely (set to empty string for "always build locally").
- `scripts/update-formula-sha.sh` — release-helper that computes the sha256 of the current VERSION tarball and patches `Formula/rip-cage.rb` after a tag push.
- Multi-arch Docker image publish (`linux/amd64,linux/arm64`) — Apple Silicon no longer falls back to Rosetta.
- zsh + bash completions are now installed automatically by the Homebrew formula (from-source users still run `rc setup`).

### Changed

- README install lead is now `brew install jsnyde0/rip-cage/rip-cage`; the git-clone-and-symlink path moves to "From source."
- README quick-start no longer claims "builds the image automatically" — names the GHCR pull-first behavior with local-build fallback.
- CONTRIBUTING.md acknowledges that `rc build` is now the contributor path (end users pull from GHCR).
- ADR-008 D6 (pre-built image on GHCR) marked implemented at v0.2.0.
- ADR-008 D7 (install method) primary install changed from "symlink" to "Homebrew formula"; symlink retained as from-source path.
- ADR-008 Deferred section: "Homebrew formula" and "Multi-platform images" bullets removed (both now shipped).
- ADR-008 D8 (new, FLEXIBLE): documents the single-repo tap shape with full Alternatives table.
- ADR-002 D24 and ADR-011 D1 updated in place to reflect the new install paths and completion bundling.

### Release ceremony notes

- GHCR packages default to **private** on first push. After the v0.2.0 tag triggers the release workflow, set visibility to Public at `https://github.com/users/jsnyde0/packages/container/rip-cage/settings`. Until then, unauthenticated `docker pull` from end users fails silently and falls back to local build.
- The formula's stable `sha256` is updated post-tag via `scripts/update-formula-sha.sh`. Between the tag push and the sha256-update commit, `brew install jsnyde0/rip-cage/rip-cage` against the stable url is briefly broken; `brew install --HEAD jsnyde0/rip-cage/rip-cage` covers that window.
- Between this epic merging to main and the v0.2.0 tag being pushed, `brew install --HEAD` users' first `rc up` will try `docker pull :0.2.0`, get a 404, and fall back to local build. Resolves on tag.

## [0.1.0] - 2026-04-13

First public release of rip-cage — a Docker-based sandbox for running Claude Code
agents safely in full auto mode.

### Added

- `rc` CLI with commands: `build`, `init`, `up`, `ls`, `attach`, `down`, `destroy`, `test`, `schema`
- Multi-stage Dockerfile: Go (beads) → Rust (DCG) → Debian runtime
- Two usage paths: VS Code devcontainer (`rc init`) and headless CLI (`rc up`)
- Bind-mount workspace: file changes sync instantly, no git push needed
- Safety stack with two layers:
  - DCG (Rust binary) — blocks destructive shell commands
  - Compound command blocker (Perl) — denies `&&`, `;`, `||` chains to prevent allowlist bypass
- `settings.json` with auto mode, allowlisted safe commands, and `PreToolUse` hooks
- 32-check safety stack smoke test (`rc test`)
- OAuth credential extraction from macOS Keychain for container auth
- Git worktree support with corrected `.git` pointer inside the container
- Read-only `.git/hooks` bind mount to prevent hook tampering (D11)
- Resource limits: CPU, memory, and PID caps via `--cpus`, `--memory`, `--pids-limit`
- `--output json` for machine-readable output on all major commands
- `--dry-run` for `up` and `destroy` to preview actions without executing
- `--version` / `-V` flag to print the current version
- `VERSION` file as single source of truth for the version number
- Beads issue tracker integration (embedded and server Dolt modes)
- `rc.conf` for configuring allowed project roots
- Container user model: non-root `agent` user with restricted sudo paths

[0.2.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.2.0
[0.1.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.1.0
