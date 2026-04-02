# Design: CLI UX Improvements and TUI Rendering Fixes

**Date:** 2026-03-27
**Status:** Draft
**Decisions:** Updates to [ADR-002](decisions/ADR-002-rip-cage-containers.md) (D14-D16 added)
**Origin:** Manual testing of `rc up .` CLI path revealed three usability issues and one rendering quality problem.

---

## Problem

Testing the `rc up` → `rc attach` CLI path exposed four issues:

1. **`rc` runs (and fails) inside the container** — The bind-mounted workspace includes the `rc` script. Running `./rc ls` inside the container produces `docker: command not found` — confusing, since the user doesn't realize `rc` is a host-only tool.

2. **Commands require container name even when there's only one** — `rc test`, `rc down`, `rc attach`, `rc destroy` all require `<name>`. When only one rip-cage container exists (the common case), this forces an `rc ls` → copy-paste → `rc test <name>` round-trip.

3. **tmux session dies when shell exits** — After exiting `claude` or the shell, the tmux session terminates. `rc attach` then shows `[exited]` immediately. The user has to `rc down` + `rc up` to get a new session.

4. **Claude Code's TUI renders poorly in tmux** — Box-drawing characters misalign, colors are wrong or missing, and the UI flickers during streaming output. Claude Code emits 4,000-6,700 scroll events/sec during streaming (40-600x normal terminal usage). Without synchronized output, each event triggers a separate redraw.

## Goal

Fix all four issues so the CLI mode provides a polished experience comparable to the devcontainer path.

## Non-Goals

- Fixing Claude Code's internal rendering engine (upstream concern)
- Supporting alternative terminal multiplexers (zellij, screen) — tmux is the standard
- Auto-detecting the user's host terminal emulator for passthrough settings

---

## Design

### 1. Container Self-Detection

Add a guard at the top of `rc` that checks for `/.dockerenv` (present in all Docker containers). If detected, print a helpful message and exit:

```bash
if [[ -f /.dockerenv ]]; then
  echo "Error: rc is a host tool — it manages containers from outside." >&2
  echo "You're already inside a rip-cage container. Run commands directly here." >&2
  exit 1
fi
```

**Why `/.dockerenv` and not `/usr/local/lib/rip-cage/hooks/`:** `/.dockerenv` is a Docker standard, not rip-cage-specific. This means the guard works even if the user runs `rc` inside a non-rip-cage container (e.g., accidentally bind-mounting it). Using a rip-cage-specific path would miss that case.

**Alternative considered:** Checking for the `rc.source.path` Docker label on the current container. Rejected — requires Docker CLI inside the container, which is the very problem we're trying to prevent.

### 2. Auto-Select Single Container

Add a `resolve_name()` helper that commands use instead of requiring a positional argument:

```bash
resolve_name() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    echo "$name"
    return
  fi
  local containers
  containers=$(docker ps -a --filter label=rc.source.path --format '{{.Names}}')
  local count
  count=$(echo "$containers" | grep -c . || true)
  if [[ "$count" -eq 0 ]]; then
    echo "Error: no rip-cage containers found." >&2
    return 1
  elif [[ "$count" -eq 1 ]]; then
    echo "$containers"
    return
  else
    echo "Error: multiple containers — specify a name:" >&2
    echo "$containers" >&2
    return 1
  fi
}
```

**Applies to:** `cmd_attach`, `cmd_down`, `cmd_destroy`, `cmd_test`.

**Behavior:**
- Name provided → use it (no change)
- No name, exactly 1 container → auto-select
- No name, 0 containers → error
- No name, 2+ containers → error with list

**Why not auto-select in multi-container case:** Ambiguity. The user may have containers for different projects/worktrees. Guessing wrong on `rc destroy` is destructive.

**Usage help:** The usage string still says `<name>` is required. The auto-select is a convenience, not a documented contract — commands that receive a name from `rc ls` output (e.g., orchestrator scripts) should always pass it explicitly.

### 3. Persistent tmux Sessions

After creating the tmux session in `init-rip-cage.sh`, set options to keep the session alive:

```bash
tmux new-session -d -s rip-cage -c /workspace 2>/dev/null || true
tmux set-option -t rip-cage remain-on-exit on 2>/dev/null || true
tmux set-hook -t rip-cage pane-died 'respawn-pane' 2>/dev/null || true
```

- `remain-on-exit on` — when the shell (or `claude`) exits, the pane stays visible instead of destroying the session
- `set-hook pane-died 'respawn-pane'` — when a pane dies, tmux automatically respawns a new shell in it

Combined effect: the user can `rc attach` any time and get a working shell, even after `claude` exits. The session persists across shell restarts.

**Why `set-hook` instead of `respawn-panes-after`:** `respawn-panes-after` does not exist as a tmux option. The hook-based approach (`pane-died` → `respawn-pane`) achieves the same auto-respawn behavior using stable tmux API. `|| true` guards prevent init failure on older tmux versions that may not support hooks.

### 4. TUI Rendering Fixes

Three changes to make Claude Code's TUI render correctly inside tmux in the container:

#### 4a. Container locale (Dockerfile)

```dockerfile
ENV TERM=xterm-256color
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
```

`C.UTF-8` is a built-in glibc locale that does not require generation — no `locales` package or `locale-gen` step needed. Without a UTF-8 locale, Docker containers default to POSIX/ASCII — box-drawing characters and Unicode render as garbage.

#### 4b. tmux configuration (new `tmux.conf`)

```
set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm-256color:RGB"
set -ga terminal-overrides ',*:UTF-8'
set -as terminal-features ",*:sync"
set -g mouse on
set -g history-limit 50000
set -sg escape-time 10
```

Key settings:
- `tmux-256color` — correct terminal type for modern TUI apps inside tmux
- `RGB` terminal feature — enables 24-bit true color passthrough
- `UTF-8` override — forces UTF-8 rendering for all clients
- **`sync` terminal feature** — this is the big one. Enables DEC Mode 2026 (synchronized output). Tmux batches all screen updates between sync-start and sync-end markers into a single atomic redraw. This eliminates the flickering caused by Claude Code's 4,000+ scroll events/sec during streaming.
- `escape-time 10` — reduces delay when pressing Escape, making the TUI feel more responsive
- `history-limit 50000` — generous scrollback for long agent sessions

#### 4c. Image integration (Dockerfile)

```dockerfile
COPY --chown=agent:agent tmux.conf /home/agent/.tmux.conf
```

The tmux.conf is baked into the image so every container gets it automatically.

**Known limitation:** Full synchronized output support may require tmux built from source (the feature was recently upstreamed). The `tmux` package in Debian bookworm may not include it. If sync doesn't work, the other settings still provide significant improvement (correct colors, UTF-8, true color). A future enhancement could build tmux from source in the Dockerfile.

**Research sources:**
- [Claude Code Issue #1495](https://github.com/anthropics/claude-code/issues/1495) — rendering glitching in tmux
- [Claude Code Issue #9935](https://github.com/anthropics/claude-code/issues/9935) — 4,000-6,700 scroll events/sec
- [Claude Code Issue #29937](https://github.com/anthropics/claude-code/issues/29937) — terminal rendering corruption
- Claude Code v2.0.72+ ships differential renderer (85% flicker reduction)
- DEC Mode 2026 eliminates remaining flicker when tmux supports it

### 5. Fix `--env-file` Symlink Bypass (security, pre-existing)

The current `--env-file` validation in `rc` validates the *directory* containing the env file, not the file itself:

```bash
validate_path "$(dirname "$env_file")"
```

This misses symlinks. If `~/code/personal/project/.env` is a symlink to `/etc/shadow`, the directory (`~/code/personal/project/`) passes the allowed-roots check, but Docker reads the symlink target.

**Fix:** Resolve the full file path with `realpath` and validate the resolved path:

```bash
if [[ -n "$env_file" ]]; then
    local resolved_env
    resolved_env=$(realpath "$env_file" 2>/dev/null) || {
        echo "Error: env file not found: $env_file" >&2; exit 1
    }
    validate_path "$(dirname "$resolved_env")"
    run_args+=(--env-file "$resolved_env")
fi
```

This ensures the *actual file* (after symlink resolution) lives under an allowed root.

### 6. Restrict `npm install -g` Sudo Escalation (security, pre-existing)

ADR-002 D12 scopes sudo to prevent the agent from tampering with its own safety stack. However, `sudo npm install -g *` runs npm lifecycle scripts (`preinstall`, `postinstall`) as root. A malicious or hallucinated package with a `postinstall` script could:
- Remove DCG: `rm /usr/local/bin/dcg`
- Modify sudoers: write to `/etc/sudoers.d/`
- Overwrite hooks: `chmod -x /usr/local/lib/rip-cage/hooks/*.sh`

This undermines D12's claim that scoped sudo prevents safety-stack tampering.

**Fix:** Remove `npm install -g *` from sudoers. Pre-install all needed global npm packages in the Dockerfile instead. If the agent needs a global package at runtime, it should request it be added to the Dockerfile (image rebuild).

```diff
- agent ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/dpkg, /usr/bin/npm install -g *, /usr/bin/chown *
+ agent ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/dpkg, /usr/bin/chown *
```

The agent can still install packages locally via `npm install` (no sudo) or `npx`. Only global installs (which affect system paths) are restricted.

**Trade-off:** If a project genuinely needs a global npm package not in the image, the user must rebuild. This is acceptable — global packages should be in the image definition, not installed ad-hoc by agents.

---

## Files Changed

| File | Change |
|------|--------|
| `rc` | Add `/.dockerenv` guard (top), add `resolve_name()` helper, update 4 commands to use it, fix `--env-file` symlink validation |
| `init-rip-cage.sh` | Add `remain-on-exit` and `set-hook pane-died respawn-pane` to tmux session creation |
| `Dockerfile` | Add `TERM`, `LANG`, `LC_ALL` env vars, copy `tmux.conf`, remove `npm install -g` from sudoers |
| `tmux.conf` | New file — terminal type, true color, UTF-8, sync, mouse, scrollback, escape-time |

---

## Verification

1. `./rc build` succeeds with new Dockerfile changes
2. `./rc up .` creates container, init passes
3. Inside container: `./rc` (any subcommand) prints "rc is a host tool" error (not "docker: command not found")
4. On host: `./rc test` (no name) auto-selects the single container and runs 6/6 tests
5. On host: `./rc attach` → run `claude` → exit → session auto-respawns shell → `rc attach` again works
6. Inside tmux: `claude` TUI renders with correct box-drawing characters, colors, and minimal flicker
7. `locale` inside container shows `C.UTF-8`
8. `tmux show -g default-terminal` shows `tmux-256color`
9. `rc up /path --env-file symlink-to-outside` is rejected by path validation
10. Inside container: `sudo npm install -g anything` is denied by sudoers
