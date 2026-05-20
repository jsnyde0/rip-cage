# CLI Reference

## Commands

| Command | Description |
|---------|-------------|
| `rc build [docker-args...]` | Build the rip-cage Docker image |
| `rc init [--force] [path]` | Scaffold `.devcontainer/devcontainer.json` for VS Code |
| `rc up <path> [--port PORT] [--env-file FILE]` | Start or resume a container |
| `rc ls` | List rip-cage containers |
| `rc attach [name]` | Attach to a container's tmux session |
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

A cage starts a single tmux session named `rip-cage` and attaches it. Two shapes are supported today for running more than one agent at a time:

**Multiple windows in one cage (one tmux session, multiple windows).** From inside an attached cage, press `Ctrl-b c` to create a new tmux window, then run `claude` (or `pi`, etc.) in it. `Ctrl-b n` / `Ctrl-b p` switch between windows; `Ctrl-b 0..9` jumps directly. The windows share the same workspace bind mount, credentials, and tmux session — useful when you want a second agent slot inside the same cage without a separate terminal on the host.

**Multiple cages (one per workspace).** `rc up <other-path>` from a second host terminal starts an independent cage on a different project path. Each cage has its own container, its own tmux session, and its own state. This is the right shape when you want full isolation between agents — e.g. one cage per git worktree (see [Quick start → The worktree workflow](../../README.md#the-worktree-workflow)).

**Heads up — second-terminal `rc up <same-path>` mirrors.** Today, opening a second terminal on the host and running `rc up` against a path that already has a running cage attaches the *same* tmux session as the first terminal. Both terminals see the same active window in lockstep; this is not a fresh agent slot. Use one of the two shapes above instead. A picker UX that lets `rc up` spawn or attach a separate session inside the same cage is planned for v0.3.
