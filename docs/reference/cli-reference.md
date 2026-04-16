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
| `rc destroy [name]` | Remove a container and its volumes |
| `rc test [name]` | Run the safety stack smoke test inside a container |

## Flags

| Flag | Description |
|------|-------------|
| `--output json` | Machine-readable JSON output (human messages go to stderr) |
| `--dry-run` | Preview what would happen without executing (supported for `up` and `destroy`) |
| `--version` | Print version |

## JSON output

When `--output json` is set, structured output goes to stdout. Human-readable messages (progress, warnings) go to stderr. Error responses include `"error"` and `"code"` fields.

## Container resolution

Commands that target a container (`attach`, `down`, `destroy`, `test`) resolve the name in order:

1. **Explicit name** — if you pass a name, it's used directly
2. **CWD match** — derives the expected name from your current directory (same logic as `rc up`) and checks if that container exists
3. **Singleton fallback** — if only one rip-cage container exists, it's auto-selected

This means `rc down` from a project directory targets that project's container, just like `rc up` does.

## Container naming

Container names are derived from the last two path components of the project directory. When collisions occur, a 4-character hash suffix is appended. Use `rc ls --output json` to discover exact container names — do not construct them manually.
