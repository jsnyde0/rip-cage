# CLI Reference

## Commands

| Command | Description |
|---------|-------------|
| `rc build [docker-args...]` | Build the rip-cage Docker image |
| `rc init [--force] [path]` | Scaffold `.devcontainer/devcontainer.json` for VS Code |
| `rc up <path> [--port PORT] [--env-file FILE] [--new] [--session NAME]` | Start or resume a container |
| `rc sessions <cage> [--json] [--kill NAME [--force]]` | List or kill tmux sessions in a cage |
| `rc ls` | List rip-cage containers |
| `rc attach [name]` | Attach to a container's tmux session (with picker) |
| `rc down [name]` | Stop a container |
| `rc destroy [-f] [name]` | Remove a container and its volumes (prompts for confirmation) |
| `rc reload [name] [--dry-run]` | Hot-reload `ssh.allowed_hosts` from `.rip-cage.yaml` without recreating the container ([details](ssh-routing.md#rc-reload)) |
| `rc test [name]` | Run the safety stack smoke test inside a container |
| `rc config show [--json]` | Print effective `.rip-cage.yaml` config with provenance ([details](config.md)) |
| `rc config init [--yes] [--force]` | Bootstrap a starter `.rip-cage.yaml` from `git remote -v` + `ssh -G` ([details](config.md)) |

## Flags

| Flag | Description |
|------|-------------|
| `--output json` | Machine-readable JSON output (human messages go to stderr) |
| `--dry-run` | Preview what would happen without executing (supported for `up`, `destroy`, and `reload`) |
| `--version` | Print version |

## JSON output

When `--output json` is set, structured output goes to stdout. Human-readable messages (progress, warnings) go to stderr. Error responses include `"error"` and `"code"` fields.

## Container resolution

Commands that target a container (`attach`, `down`, `destroy`, `reload`, `test`) resolve the name in order:

1. **Explicit name** — if you pass a name, it's used directly
2. **CWD match** — derives the expected name from your current directory (same logic as `rc up`) and checks if that container exists
3. **Singleton fallback** — if only one rip-cage container exists, it's auto-selected

This means `rc down` from a project directory targets that project's container, just like `rc up` does.

## Container naming

Container names are derived from the last two path components of the project directory. When collisions occur, a 4-character hash suffix is appended. Use `rc ls --output json` to discover exact container names — do not construct them manually.

## Running multiple agents

A cage supports multiple independent tmux sessions. `rc up <path>` shows a numbered picker when one or more sessions already exist, letting you attach an existing session or spawn a new one. The first `rc up` on a fresh cage creates a session named `rip-cage` and attaches it directly (no picker — current behavior preserved).

### Session picker

When `rc up <path>` finds one or more existing sessions, it renders a numbered list sorted by most-recently-attached first, with a `[new] new session` entry at the bottom. Pressing **Enter** (empty input) attaches the most-recently-attached session. Type a number to select. `rc attach <cage>` uses the same picker.

On a cage with no sessions (e.g. after `rc sessions <cage> --kill --force`), `rc up` creates and attaches `rip-cage` with no picker.

### `rc up` session flags

| Flag | Behavior |
|------|----------|
| `--new` | Skip picker; always create a new auto-named session (`rip-cage-2`, `rip-cage-3`, …). |
| `--session NAME` | Attach session `NAME` if it exists; create and attach it if not. |
| `--dry-run` | Previews the container action; never shows the picker. |

`--new` and `--session` are mutually exclusive (exits 2 if both are given).

Non-TTY invocations (CI, devcontainer `initializeCommand`, piped stdin) skip the picker entirely and fall back to attaching `rip-cage` if it exists or creating it.

### `rc sessions <cage>`

List, inspect, and clean up sessions inside a running cage.

```
rc sessions <cage>                       # list sessions: name  attached-count  idle-time
rc sessions <cage> --json                # JSON array: [{name, attached, idle_seconds}, …]
rc sessions <cage> --kill NAME           # kill named session (refuses if it is the last one)
rc sessions <cage> --kill NAME --force   # override last-session refusal
```

After a `--force` kill of the last session the container stays running on its `sleep infinity` entrypoint. The next `rc up` hits the N=0 path and creates `rip-cage`.

### Other shapes still supported

**Multiple windows in one cage (one tmux session, multiple windows).** From inside an attached cage, press `Ctrl-b c` to create a new tmux window, then run `claude` (or `pi`, etc.) in it. `Ctrl-b n` / `Ctrl-b p` switch between windows; `Ctrl-b 0..9` jumps directly. The windows share the same workspace bind mount, credentials, and tmux session — useful when you want a second agent slot without a separate terminal on the host.

**Multiple cages (one per workspace).** `rc up <other-path>` from a second host terminal starts an independent cage on a different project path. Each cage has its own container, sessions, and state. This is the right shape when you want full container isolation between agents — e.g. one cage per git worktree (see [Quick start → The worktree workflow](../../README.md#the-worktree-workflow)).
