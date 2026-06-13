# CLI Reference

## Commands

| Command | Description |
|---------|-------------|
| `rc build [docker-args...]` | Build the rip-cage Docker image |
| `rc init [--force] [path]` | Scaffold `.devcontainer/devcontainer.json` for VS Code |
| `rc up <path> [--port PORT] [--env-file FILE] [--new] [--session NAME]` | Start or resume a container |
| `rc ls` | List rip-cage containers |
| `rc attach [name]` | Attach to a running container (multiplexer-neutral — plain shell under `none`, tmux attach under `tmux`, supervisor view under `herdr`) |
| `rc exec <cage> -- <cmd...>` | Run a one-off command in a running container non-interactively (safe for CI and scripts); supports `--output json` |
| `rc down [name]` | Stop a container |
| `rc destroy [-f] [name]` | Remove a container and its volumes (prompts for confirmation) |
| `rc reload [name] [--dry-run]` | Hot-reload `ssh.allowed_hosts` from `.rip-cage.yaml` without recreating the container ([details](ssh-routing.md#rc-reload)) |
| `rc allowlist add <host> [--cage=<name>]` | Append a host to `network.allowed_hosts` in `.rip-cage.yaml` (idempotent); `--cage` applies it live via `rc reload` ([details](egress.md#rc-allowlist-command-reference)) |
| `rc allowlist show [--effective] [--observed]` | Show configured / effective / observed-blocked egress hosts ([details](egress.md#rc-allowlist-command-reference)) |
| `rc allowlist promote --from-observed [--cage=<name>]` | Merge observed blocked hosts into `network.allowed_hosts`, flip `network.mode` to `block`, and `rc reload` ([details](egress.md#the-observe--promote--block-workflow)) |
| `rc test [name]` | Run the safety stack smoke test inside a container |
| `rc doctor [name]` | Per-container diagnostic — labels + live probes (egress proxy, SSH forwarding, auth) |
| `rc config show [--json]` | Print effective `.rip-cage.yaml` config with provenance ([details](config.md)) |
| `rc config init [--yes] [--force]` | Bootstrap a starter `.rip-cage.yaml` from `git remote -v` + `ssh -G` ([details](config.md)) |

## Flags

| Flag | Description |
|------|-------------|
| `--output json` | Machine-readable JSON output (human messages go to stderr) |
| `--dry-run` | Preview what would happen without executing (supported for `up`, `destroy`, and `reload`) |
| `--version` | Print version |

### `rc up` — denylist and `--allow-risky-mount`

`rc up` runs a secret-path denylist check on every non-workspace mount surface (e.g. `--env-file`) before starting the container. If the path matches a default pattern (`.aws`, `.ssh`, `credentials`, etc.), `rc up` aborts with a fail-loud error naming the matched path, the matched pattern, and the available escape hatches.

| Flag | Description |
|------|-------------|
| `--allow-risky-mount <resolved-path>` | One-shot bypass: allow the named path to pass the denylist check for this invocation only. Accepts the **resolved (realpath)** form of the path — copy it from the error message. May be repeated for multiple paths. |

Example:
```bash
# Allow a specific credential path for this invocation only
rc up --allow-risky-mount /Users/alice/.aws/my-tools-creds \
      --env-file /Users/alice/.aws/my-tools-creds \
      /path/to/project
```

For a persistent per-project allow, use `mounts.allow_risky` in `.rip-cage.yaml`. To add custom patterns on top of the global defaults, use `mounts.denylist` in `.rip-cage.yaml`. Run `rc config show` to see the effective denylist with provenance.

See [ADR-023](../decisions/ADR-023-secret-path-mount-denylist.md) and [`docs/reference/config.md`](config.md#mountsdenylist-and-mountsallow_risky----secret-path-denylist) for the full denylist design.

### `rc allowlist` — egress allowlist

Manage the network egress allowlist (`network.allowed_hosts` / `network.mode` in `.rip-cage.yaml`). New cages start in **observe mode** (log, don't block); `show --observed` lists what the agent reached, and `promote --from-observed` merges it into the allowlist and flips to **block mode**.

`add` and `promote` are **host-only** (they mutate effective config via `rc reload`); `show` is read-only and works inside the cage too.

| Subcommand | Description |
|------|-------------|
| `add <host> [--cage=<name>]` | Append `<host>` to `network.allowed_hosts` (idempotent). With `--cage`, runs `rc reload` to apply live. Supports `--output json`. |
| `show [--effective] [--observed]` | Default: configured `network.allowed_hosts`. `--effective`: merged allowlist with provenance. `--observed`: hosts blocked / would-block in the egress logs. |
| `promote --from-observed [--cage=<name>]` | Merge observed blocked hosts into `network.allowed_hosts`, set `network.mode: block`, emit a diff, and `rc reload` when `--cage` is given. |

```bash
# Add one host and apply it live
rc allowlist add api.deepseek.com --cage my-cage

# See what the agent reached in observe mode, then lock down
rc allowlist show --observed --cage my-cage
rc allowlist promote --from-observed --cage my-cage
```

See [`docs/reference/egress.md`](egress.md) and [ADR-012](../decisions/ADR-012-egress-firewall.md) for the full egress model.

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

## `rc attach` — multiplexer-neutral attach

`rc attach [name]` attaches to a running container. Its behavior depends on the `session.multiplexer` config field ([details](config.md#sessionmultiplexer--in-cage-multiplexer)):

| `session.multiplexer` | `rc attach` behavior |
|---|---|
| `none` (default) | Drops into a plain interactive shell; closing the window ends the process |
| `tmux` | Attaches the tmux session (with a session picker when multiple sessions exist) |
| `herdr` | Opens the herdr supervisor view |

## `rc exec` — one-off commands

```
rc exec <cage> -- <cmd...>
rc --output json exec <cage> -- <cmd...>
```

Runs a single command inside a running cage non-interactively. The `--` separator is required. Safe for CI pipelines, scripts, and host-side automation — does not open a TTY or attach a session.

```bash
# Run a test suite inside the cage
rc exec my-cage -- pytest tests/

# Get structured output from a command
rc --output json exec my-cage -- cat /workspace/VERSION
```

`rc exec` is **container resolution**-aware (auto-selects the cage if only one is running).

## Running multiple agents

When `session.multiplexer` is set to `tmux`, a cage supports multiple independent tmux sessions. `rc up <path>` shows a numbered picker when one or more sessions already exist, letting you attach an existing session or spawn a new one. The first `rc up` on a fresh cage creates a session named `rip-cage` and attaches it directly (no picker — current behavior preserved).

With the default `session.multiplexer: none`, each `rc up` connects a single shell process — multiple agents means multiple cages (one per workspace path).

### Session picker (tmux multiplexer only)

When `rc up <path>` finds one or more existing sessions, it renders a numbered list sorted by most-recently-attached first, with a `[new] new session` entry at the bottom. Pressing **Enter** (empty input) attaches the most-recently-attached session. Type a number to select. `rc attach <cage>` uses the same picker.

On a cage with no sessions, `rc up` creates and attaches `rip-cage` with no picker.

### `rc up` session flags

| Flag | Behavior |
|------|----------|
| `--new` | Skip picker; always create a new auto-named session (`rip-cage-2`, `rip-cage-3`, …). |
| `--session NAME` | Attach session `NAME` if it exists; create and attach it if not. |
| `--dry-run` | Previews the container action; never shows the picker. |

`--new` and `--session` are mutually exclusive (exits 2 if both are given).

Non-TTY invocations (CI, devcontainer `initializeCommand`, piped stdin) skip the picker entirely and fall back to attaching `rip-cage` if it exists or creating it.

### Other shapes still supported

**Multiple windows in one cage (tmux multiplexer, one session, multiple windows).** From inside an attached cage with `session.multiplexer: tmux`, press `Ctrl-b c` to create a new tmux window, then run `claude` (or `pi`, etc.) in it. `Ctrl-b n` / `Ctrl-b p` switch between windows; `Ctrl-b 0..9` jumps directly. The windows share the same workspace bind mount, credentials, and tmux session — useful when you want a second agent slot without a separate terminal on the host.

**Multiple cages (one per workspace).** `rc up <other-path>` from a second host terminal starts an independent cage on a different project path. Each cage has its own container and state. This is the right shape when you want full container isolation between agents — e.g. one cage per git worktree (see [Quick start → The worktree workflow](../../README.md#the-worktree-workflow)).
