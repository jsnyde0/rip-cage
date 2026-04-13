# Changelog

All notable changes to rip-cage will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[0.1.0]: https://github.com/youruser/rip-cage/releases/tag/v0.1.0
