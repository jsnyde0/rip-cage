# Design: Rip Cage Phase 1 Hardening

**Date:** 2026-03-27
**Status:** Reviewed
**Decisions:** [ADR-004](decisions/ADR-004-phase1-hardening.md)
**Origin:** Phase 1 is feature-complete but has not been tested end-to-end. Several gaps (bloated image, no resource limits, no credential checks, thin test suite, minimal shell config) need fixing before real use.

---

## Problem

The rip-cage implementation has all the pieces: `rc` CLI (592 lines bash), Dockerfile, init script, safety stack, and 6-test smoke suite. But the image has never been built end-to-end, and several practical issues would bite on first real use:

1. **Dolt adds 103MB and fails inside containers.** bd's Dolt driver needs SSH keys and host aliases that don't exist in the container. The `bd dolt push/pull` commands fail. bd supports `no-db: true` config for JSONL-only storage (no Dolt needed). Note: the original claim that `no-db` mode was removed in bd v0.62.0 was incorrect — bd 1.0.0 fully supports it. See [ADR-004 D1 amendment](decisions/ADR-004-phase1-hardening.md).

2. **No resource limits on containers.** A runaway agent can consume all host CPU, memory, or spawn unlimited processes. There are no `--cpus`, `--memory`, or `--pids-limit` defaults in `cmd_up`.

3. **No credential health checking.** OAuth tokens have expiry times. If a token expires mid-session, the agent hits an opaque auth error with no prior warning. The credentials file is available at container start but never inspected.

4. **`rc test` only has 6 checks.** The smoke test verifies the safety stack (DCG, compound blocker, settings.json, auto mode) but skips tools, auth, network, disk, and permissions. Not enough confidence for real use.

5. **Minimal zshrc.** The container's shell config is bare. Agents benefit from aliases, modern CLI tool detection, and utility functions.

6. **Allowlist includes file-reading commands.** `head:*` and `tail:*` are auto-approved in settings.json, contradicting the ADR-002 D5 amendment that removed `cat`, `grep`, and `find` for reading arbitrary files.

## Scope

Internal improvements only. No new external tools, no architectural changes, no new commands. All changes are to existing files.

---

## Changes by File

### Dockerfile

**Keep Dolt in the image.** Dolt is required by bd's embedded engine. For **embedded-mode projects** (default, `dolt_mode: "embedded"` in `.beads/metadata.json`), bd uses an in-process Dolt engine on the bind-mounted `.beads/embeddeddolt/` — no server connection needed. For **server-mode projects** (`dolt_mode: "server"`), the container's bd connects to the host's Dolt server via `host.docker.internal`. See [ADR-004 D1 amendment](decisions/ADR-004-phase1-hardening.md) and [embedded Dolt container support design](2026-04-09-beads-no-db-container-support.md).

For server-mode projects, three env vars are set by `rc up` and `init-rip-cage.sh`: `BEADS_DOLT_SERVER_MODE=1` (external server, no auto-start), `BEADS_DOLT_SERVER_HOST=host.docker.internal`, and `BEADS_DOLT_SERVER_PORT` (read dynamically from `.beads/dolt-server.port`). These are omitted for embedded-mode projects.

### rc script

**Default resource limits in `cmd_up`.** Add to the `docker run` invocation:

```
--cpus=2 --memory=4g --memory-swap=4g --pids-limit=500
```

These are sane defaults for a single-agent container. They prevent a runaway process from starving the host while leaving enough room for normal development work (builds, test suites, language servers).

Resource limits are set at container creation time. Passing `--cpus`/`--memory`/`--pids-limit` when resuming a stopped container has no effect — destroy and recreate to apply new limits.

**User-overridable flags.** Add `--cpus`, `--memory`, and `--pids-limit` flags to `rc up`. These override the defaults. Parsing follows the existing flag-parsing pattern in `rc` (positional args first, flags after).

**Credential health check before container start.** In `cmd_up`, after extracting OAuth tokens but before `docker run`:

1. Check if `~/.claude/.credentials.json` exists and is non-empty (`-s` test — the keychain extraction can produce an empty file on failure)
2. If it exists, parse the `expiry` or `expiresAt` field (ISO 8601 timestamp)
3. On macOS, strip timezone and fractional seconds before parsing: `${expiry%%[.+Z]*}` (macOS `date -jf` cannot handle timezone offsets like `+00:00`)
4. If expiry is less than 10 minutes from now, print a warning to stderr
5. If expiry is in the past, print a stronger warning but do not block (the agent may use `ANTHROPIC_API_KEY` instead)

This is a warning, not a hard failure. The check uses `jq` and `date`, both available on macOS and in the container.

**Expand `rc test` to 25 checks.** Replace (or extend) the current 6-test smoke suite with a comprehensive health check:

| # | Check | How |
|---|-------|-----|
| 1 | Container user is `agent` | `whoami` returns `agent` |
| 2 | Not running as root | `id -u` is not 0 |
| 3 | `/workspace` is mounted | Directory exists |
| 4 | `/workspace` is writable | Touch and remove a temp file |
| 5 | `~/.claude/settings.json` exists | File exists |
| 6 | `settings.json` is valid JSON | `jq . < settings.json` succeeds |
| 7 | `settings.json` has auto mode | `jq` query for `permissions.defaultMode` |
| 8 | `settings.json` has DCG hook | `jq` query for hook command path |
| 9 | `settings.json` has compound blocker hook | `jq` query for hook command path |
| 10 | `settings.json` denies `.git/hooks` writes | `jq` query for deny rule |
| 11 | DCG denies destructive command | Pipe test input to DCG binary |
| 12 | Compound blocker denies chain | Pipe test input to blocker script |
| 13 | Auth present (non-empty) | `~/.claude/.credentials.json` exists and is non-empty (`-s`), OR `ANTHROPIC_API_KEY` is set |
| 14 | Token not expired | Parse expiry from credentials file |
| 15 | git available and identity set | `git config user.name` and `user.email` return values |
| 16 | claude available | `claude --version` |
| 17 | jq available | `jq --version` |
| 18 | tmux available | `tmux -V` |
| 19 | bd available | `bd --version` |
| 20 | python3 available | `python3 --version` |
| 21 | uv available | `uv --version` |
| 22 | node available | `node --version` |
| 23 | bun available | `bun --version` |
| 24 | gh available | `gh --version` |
| 25 | DNS resolution works | `getent hosts github.com` or equivalent |
| 26 | Sufficient disk space | `df /workspace` shows >1GB free |

Tool availability checks (16-24) use `command -v` as a gate before running the version command, to avoid false-positives where a "command not found" error message is captured as the "version" string.

Output format: each check prints `PASS` or `FAIL` with a description. Summary line at the end with pass/fail counts. In `--output json` mode, emit a JSON object with a `checks` array (each entry has `name`, `status`, `detail`). The output format is parsed by `cmd_test` in `rc` — changes to the format must be coordinated.

### rc init (devcontainer template)

**Add Dolt server env vars and resource limits to devcontainer.json.** The devcontainer path must receive the same hardening as `rc up`:

- Add `"BEADS_DOLT_SERVER_MODE": "1"` and `"BEADS_DOLT_SERVER_HOST": "host.docker.internal"` to `containerEnv`
- The port is dynamic and must be read at startup by `init-rip-cage.sh`
- Add `"runArgs": ["--cpus=2", "--memory=4g", "--memory-swap=4g", "--pids-limit=500"]` for resource limit parity.

### init-rip-cage.sh

**Conditional beads configuration based on storage mode.** Read `.beads/metadata.json` to determine `dolt_mode`:

- **Embedded mode** (`dolt_mode: "embedded"` or absent): do not set any server env vars. bd uses its in-process Dolt engine on the bind-mounted `.beads/embeddeddolt/`.
- **Server mode** (`dolt_mode: "server"/"owned"/"external"`): set `BEADS_DOLT_SERVER_MODE=1` and `BEADS_DOLT_SERVER_HOST=host.docker.internal`. Port is read dynamically by the bd wrapper (ADR-007 D1).

This gives the container full read-write access to beads in both modes. For server-mode projects, the host must have bd/Dolt running.

### settings.json

**Remove `head:*` and `tail:*` from the allowlist.** These read arbitrary files with the same security profile as `cat`, which was explicitly removed per the ADR-002 D5 amendment. `head ~/.claude/.credentials.json` reads auth tokens just as `cat` would. Consistency requires removing them.

### zshrc

Expand the minimal zshrc with agent-productive defaults. All aliases are conditional on the tool being present (no errors if a tool is missing).

```zsh
# Modern CLI aliases (conditional)
command -v eza  &>/dev/null && alias ls='eza'    || \
command -v lsd  &>/dev/null && alias ls='lsd'    || true
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
```

### test-safety-stack.sh

The existing 6-test file is either replaced by the expanded test logic in `rc test`, or kept as a subset and extended. The expanded checks (26 items above) are implemented in the `cmd_test` function of the `rc` script, which already supports `--output json`. The standalone `test-safety-stack.sh` may be kept for running inside the container without `rc`.

### Documentation updates

- **CLAUDE.md:** Update the "Container user model" section to reflect current sudoers policy. The `npm install -g *` entry was removed (commit e9fcc85) and `chown *` was narrowed to exact paths (commit f7db60c). The docs still describe the old policy.
- **ADR-002 D10:** Amend to reflect host-server connection approach per ADR-004 D1. Container bd connects to host's Dolt server via `host.docker.internal`.

---

## Consequences

**Beads works in both storage modes.** Embedded-mode projects use bd's in-process Dolt engine on the bind mount (no server connection). Server-mode projects connect to the host's Dolt server via `host.docker.internal`. The mode is detected from `.beads/metadata.json` `dolt_mode`. Dolt is kept in the image as a required dependency for bd's embedded engine.

**Containers have predictable resource usage.** Default limits (2 CPUs, 4GB RAM, 500 PIDs) prevent host starvation. Both `rc up` and devcontainer paths get the same defaults. Power users can override via flags or by editing the generated devcontainer.json.

**Auth failures detected early.** Token expiry warnings at container start, not opaque errors mid-session. The credential check handles macOS date-parsing edge cases and avoids false-positives from empty credentials files.

**Richer shell experience.** Agents get productive defaults without explicit setup. Conditional aliases mean no errors on missing tools.

**More confidence from expanded health checks.** 26 checks vs 6 means catching missing tools, bad auth, disk pressure, network issues, and — critically — that the safety stack hooks and deny rules are wired correctly in settings.json, not just that the binaries exist.

**Settings are ephemeral.** `init-rip-cage.sh` overwrites `~/.claude/settings.json` on every start. This is intentional — it ensures image upgrades propagate new hooks/settings and prevents agents from weakening their own safety stack. For persistent customization, modify the image's `settings.json` and rebuild.

**Tighter allowlist.** Removing `head:*` and `tail:*` closes a gap where file-reading commands were auto-approved despite the ADR-002 D5 policy.

**No architectural changes.** All changes are within existing files and patterns. No new commands. Dolt is kept (required by bd v0.62.0+).

---

## Open Questions

1. **Should resource limits be configurable per-project?** A `.rc.yaml` in the project root could override defaults (e.g., a heavy build project might need `--cpus=4 --memory=8g`). Not needed for Phase 1 hardening -- the `rc up` flags handle this -- but worth considering if projects diverge significantly.
