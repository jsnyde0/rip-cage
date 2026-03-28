# Design: Rip Cage Phase 1 Hardening

**Date:** 2026-03-27
**Status:** Draft
**Decisions:** [ADR-004](decisions/ADR-004-phase1-hardening.md)
**Origin:** Phase 1 is feature-complete but has not been tested end-to-end. Several gaps (bloated image, no resource limits, no credential checks, thin test suite, minimal shell config) need fixing before real use.

---

## Problem

The rip-cage implementation has all the pieces: `rc` CLI (592 lines bash), Dockerfile, init script, safety stack, and 6-test smoke suite. But the image has never been built end-to-end, and several practical issues would bite on first real use:

1. **Dolt adds 103MB and fails inside containers.** bd's Dolt driver needs SSH keys and host aliases that don't exist in the container. The `bd dolt push/pull` commands fail. bd has a `no-db: true` config option that uses JSONL-only storage, no Dolt needed.

2. **No resource limits on containers.** A runaway agent can consume all host CPU, memory, or spawn unlimited processes. There are no `--cpus`, `--memory`, or `--pids-limit` defaults in `cmd_up`.

3. **No credential health checking.** OAuth tokens have expiry times. If a token expires mid-session, the agent hits an opaque auth error with no prior warning. The credentials file is available at container start but never inspected.

4. **`rc test` only has 6 checks.** The smoke test verifies the safety stack (DCG, compound blocker, settings.json, auto mode) but skips tools, auth, network, disk, and permissions. Not enough confidence for real use.

5. **Minimal zshrc.** The container's shell config is bare. Agents benefit from aliases, modern CLI tool detection, and utility functions.

## Scope

Internal improvements only. No new external tools, no architectural changes, no new commands. All changes are to existing files.

---

## Changes by File

### Dockerfile

**Remove Dolt installation.** Dolt is installed as a system binary (~103MB) and used as bd's storage backend. Inside containers, Dolt sync fails (no SSH keys/aliases). bd supports a `no-db` mode that uses JSONL files instead of Dolt, which is sufficient for container-local issue tracking.

Keep the Go builder stage -- bd is still compiled from source (it does not publish pre-built binaries). Remove only the Dolt installation step.

**Expected savings:** ~103MB from the final image.

### rc script

**Default resource limits in `cmd_up`.** Add to the `docker run` invocation:

```
--cpus=2 --memory=4g --memory-swap=4g --pids-limit=500
```

These are sane defaults for a single-agent container. They prevent a runaway process from starving the host while leaving enough room for normal development work (builds, test suites, language servers).

**User-overridable flags.** Add `--cpus`, `--memory`, and `--pids-limit` flags to `rc up`. These override the defaults. Parsing follows the existing flag-parsing pattern in `rc` (positional args first, flags after).

**Credential health check before container start.** In `cmd_up`, after extracting OAuth tokens but before `docker run`:

1. Check if `~/.claude/.credentials.json` exists
2. If it exists, parse the `expiry` field (ISO 8601 timestamp)
3. If expiry is less than 10 minutes from now, print a warning to stderr
4. If expiry is in the past, print a stronger warning but do not block (the agent may use `ANTHROPIC_API_KEY` instead)

This is a warning, not a hard failure. The check uses `jq` and `date`, both available on macOS and in the container.

**Expand `rc test` to 15+ checks.** Replace (or extend) the current 6-test smoke suite with a comprehensive health check. New checks:

| # | Check | How |
|---|-------|-----|
| 1 | Container user is `agent` | `whoami` returns `agent` |
| 2 | Not running as root | `id -u` is not 0 |
| 3 | `/workspace` is mounted | Directory exists |
| 4 | `/workspace` is writable | Touch and remove a temp file |
| 5 | `~/.claude/settings.json` exists | File exists |
| 6 | `settings.json` is valid JSON | `jq . < settings.json` succeeds |
| 7 | `settings.json` has auto mode | `jq` query for `permissions.allow` |
| 8 | DCG denies destructive command | Existing test |
| 9 | Compound blocker denies chain | Existing test |
| 10 | Auth present | `~/.claude/.credentials.json` exists OR `ANTHROPIC_API_KEY` is set |
| 11 | Token not expired | Parse expiry from credentials file |
| 12 | git available and identity set | `git config user.name` and `user.email` return values |
| 13 | jq available | `jq --version` |
| 14 | tmux available | `tmux -V` |
| 15 | bd available | `bd --version` or `bd help` |
| 16 | DNS resolution works | `getent hosts github.com` or `dig +short github.com` |
| 17 | Sufficient disk space | `df /workspace` shows >1GB free |
| 18 | Python3 available | `python3 --version` |
| 19 | uv available | `uv --version` |
| 20 | Node available | `node --version` |
| 21 | bun available | `bun --version` |

Output format: each check prints `PASS` or `FAIL` with a description. Summary line at the end with pass/fail counts. In `--output json` mode, emit a JSON object with a `checks` array (each entry has `name`, `status`, `detail`).

### init-rip-cage.sh

**Set bd to no-db mode for the container context.** The `/workspace` directory is a bind mount from the host. We must not modify the host's `.beads/config.yaml`. Instead:

- Set `BD_NO_DB=true` as an environment variable in the container (via `docker run -e BD_NO_DB=true` in `cmd_up`, or in the init script's environment)
- If bd does not respect that env var, use `bd --no-db` flag on each invocation, or create a container-local config at `~/.config/beads/config.yaml` with `no-db: true` (bd checks XDG paths before `.beads/`)

This lets bd operate with JSONL storage only. No Dolt binary needed, no sync failures.

### zshrc

Expand the minimal zshrc with agent-productive defaults. All aliases are conditional on the tool being present (no errors if a tool is missing).

```zsh
# Modern CLI aliases (conditional)
command -v eza  &>/dev/null && alias ls='eza'    || \
command -v lsd  &>/dev/null && alias ls='lsd'
command -v bat  &>/dev/null && alias cat='bat --paging=never'
command -v rg   &>/dev/null && alias grep='rg'

# Git aliases
alias gs='git status'
alias gd='git diff'
alias gp='git push'
alias gl='git log --oneline -20'
alias glog='git log --oneline --graph --all -30'
alias ga='git add'
alias gc='git commit'

# Utility functions
mkcd() { mkdir -p "$1" && cd "$1"; }

extract() {
  case "$1" in
    *.tar.gz|*.tgz)  tar xzf "$1" ;;
    *.tar.bz2|*.tbz2) tar xjf "$1" ;;
    *.tar.xz)        tar xJf "$1" ;;
    *.zip)            unzip "$1" ;;
    *.gz)             gunzip "$1" ;;
    *.bz2)            bunzip2 "$1" ;;
    *)                echo "Unknown archive: $1" ;;
  esac
}

# Terminal type fallback (containers sometimes lack terminfo)
[[ -z "$TERM" || "$TERM" == "dumb" ]] && export TERM=xterm-256color

# PATH setup for container tools
export PATH="$HOME/.local/bin:$PATH"
```

### test-safety-stack.sh

The existing 6-test file is either replaced by the expanded test logic in `rc test`, or kept as a subset and extended. The expanded checks (21 items above) are implemented in the `cmd_test` function of the `rc` script, which already supports `--output json`. The standalone `test-safety-stack.sh` may be kept for running inside the container without `rc`.

---

## Consequences

**Image ~103MB smaller.** Removing Dolt is pure savings. bd continues to work with JSONL storage.

**Containers have predictable resource usage.** Default limits (2 CPUs, 4GB RAM, 500 PIDs) prevent host starvation. Power users can override.

**Auth failures detected early.** Token expiry warnings at container start, not opaque errors mid-session.

**Richer shell experience.** Agents get productive defaults without explicit setup. Conditional aliases mean no errors on missing tools.

**More confidence from expanded health checks.** 21 checks vs 6 means catching missing tools, bad auth, disk pressure, and network issues before the agent starts work.

**No architectural changes.** All changes are within existing files and patterns. No new commands, no new dependencies (Dolt is removed, not added).

---

## Open Questions

1. **Should resource limits be configurable per-project?** A `.rc.yaml` in the project root could override defaults (e.g., a heavy build project might need `--cpus=4 --memory=8g`). Not needed for Phase 1 hardening -- the `rc up` flags handle this -- but worth considering if projects diverge significantly.

2. **Should the credential check be a hard failure or warning?** Current proposal is warning-only because the agent may use `ANTHROPIC_API_KEY` instead of OAuth. But if neither auth method is present, should `rc up` refuse to start? Leaning toward: warn on expired token, hard-fail on no auth at all.

3. **Should the expanded test suite live in `rc test` or stay in `test-safety-stack.sh`?** The `rc test` function already exists and supports `--output json`. Duplicating in a standalone script adds maintenance burden. Proposal: move everything to `rc test`, keep `test-safety-stack.sh` as a thin wrapper that calls `rc test` from inside the container.
