# Contributing to Rip Cage

Thank you for your interest in contributing! This document covers how to build, test, and submit changes.

## Prerequisites

Before you start, make sure you have the following installed:

| Tool | Version | Notes |
|------|---------|-------|
| Docker | 20.10+ | Or OrbStack on macOS |
| bash | 3.2+ | macOS default bash works |
| jq | 1.6+ | For JSON output parsing |
| tmux | 2.x+ | For CLI mode containers |
| shellcheck | 0.8+ | Required for linting contributions |

Install on macOS with Homebrew:

```bash
brew install jq tmux shellcheck
```

Install on Debian/Ubuntu:

```bash
apt-get install jq tmux shellcheck
```

## Getting the code

```bash
git clone https://github.com/jsnyde0/rip-cage.git
cd rip-cage
```

## Building the image

The Docker image is multi-stage (Go → Rust → Debian runtime) and takes 5-10 minutes on a clean machine:

```bash
./rc build
```

Pass extra arguments directly to `docker build` if needed:

```bash
./rc build --no-cache
./rc build --progress=plain
```

The built image is tagged `rip-cage:latest` locally.

## Running the safety stack tests

After building, spin up a container against any project directory and run the test suite:

```bash
./rc up /path/to/any/project
./rc ls                          # note the container name
./rc test <container-name>
```

### What the tests check

The test suite (`tests/test-safety-stack.sh`) runs 30+ checks organized into sections:

**User & Environment** — verifies the container agent runs as the `agent` user (uid 1000, not root) and that `/workspace` is mounted and writable.

**Settings & Safety Stack** — verifies `settings.json` is present, valid JSON, has `bypassPermissions` mode, and has all hooks wired: DCG, compound command blocker, and the `.git/hooks` write deny rule.

**DCG functional** — sends a destructive command through DCG and confirms it returns a `deny` decision.

**Compound blocker functional** — sends a `&&`-chained command through the compound blocker and confirms denial.

**Auth** — verifies OAuth credentials or API key is present and (if OAuth) the token is not expired.

**Git** — verifies the `agent` user has a git identity configured.

**Tools** — verifies all pre-installed tools are present and executable: `claude`, `jq`, `tmux`, `bd`, `python3`, `uv`, `node`, `bun`, `gh`.

**Beads functional** — if the workspace has a `.beads/` directory, verifies `bd list` returns a valid response.

**Beads wrapper** — verifies the `bd` wrapper script blocks `dolt start` in server mode and that `--verbose` flag bypass is prevented.

**Network & Disk** — verifies DNS resolution for github.com and at least 1GB free disk space on `/workspace`.

**Git hooks protection** — verifies `/workspace/.git/hooks` is read-only (both shell `touch` and Python `open()` must fail).

**Worktree git** (conditional) — if the workspace is a git worktree, verifies git operations work: `git status`, `.git` pointer validity, `--show-toplevel`, and that the worktree hooks directory is read-only.

Expected output when everything passes:

```
=== Rip Cage Health Check ===

-- User & Environment --
PASS  [1] Container user is agent — agent
PASS  [2] Not running as root — uid=1000
...
=== Results: 32 passed, 0 failed (of 32) ===
```

## Making changes

### `rc` (the CLI)

`rc` is a single bash script. A few things to keep in mind:

- **Bash 3.2 compatibility is required.** macOS ships bash 3.2 (GPLv3 licensing prevents Apple from shipping 4+). Do not use bash 4+ features: no `${var,,}`, no `${var^^}`, no associative arrays (`declare -A`), no `mapfile`/`readarray`. Use `tr '[:upper:]' '[:lower:]'` for case conversion.
- Run `shellcheck rc` before submitting. All shellcheck warnings must be resolved (not suppressed unless there is a specific, documented reason).
- Keep functions focused. `cmd_up()` is already large; avoid making it larger.

### `Dockerfile`

The image is multi-stage. Changes to earlier stages invalidate the build cache for later stages. Test your Dockerfile change with:

```bash
./rc build --no-cache    # full clean build
```

### Hooks and settings

`hooks/block-compound-commands.sh` and `settings.json` are security-critical. Changes to either require careful review. Any change that weakens the safety stack must include an explicit rationale.

### Test script

`tests/test-safety-stack.sh` runs inside the container. If you add a new safety feature, add a corresponding check to this file.

## Code style

- Follow existing bash conventions in `rc` — local variables, `set -euo pipefail`, quoting.
- Use `shellcheck` to catch common bash issues.
- Error messages go to stderr (`>&2`). Normal output goes to stdout.
- When adding a new `rc` subcommand, add it to the help text and the CLI reference in `docs/reference/cli-reference.md`.
- Keep the `--output json` contract stable — callers depend on the JSON field names.

## Submitting a pull request

1. **Fork** the repository and create a branch from `main`:

   ```bash
   git checkout -b my-feature
   ```

2. **Make your changes** following the guidelines above.

3. **Lint** your bash changes:

   ```bash
   shellcheck rc init-rip-cage.sh hooks/*.sh tests/test-safety-stack.sh
   ```

4. **Test** by building the image and running the safety stack checks:

   ```bash
   ./rc build
   ./rc up /path/to/test-project
   ./rc test <container-name>
   ```

5. **Push** and open a pull request against `main`. Fill in the PR template.

## Reporting issues

Use GitHub Issues. Bug reports should include:

- OS and Docker version
- The `rc` command that failed
- The full error output
- Output of `./rc test <name>` if the container is running

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
