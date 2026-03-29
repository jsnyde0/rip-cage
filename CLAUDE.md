# Rip Cage — Agent Context

You're working on **rip-cage**, a Docker-based sandbox for running Claude Code agents safely. The core idea: agents run in a container with a safety stack (DCG + compound command blocker + allowlists) so they can operate in full auto mode without nuking anything.

## Architecture

```
Host (macOS/Linux)
├── rc                      CLI entrypoint (bash). All commands: build, init, up, ls, attach, down, destroy, test
├── Dockerfile              Multi-stage: Go (beads) → Rust (DCG) → Debian runtime
├── init-rip-cage.sh        Runs inside the container on start. Sets up auth, settings, hooks, git identity, beads
├── settings.json           Claude Code config — auto mode, allowlisted commands, PreToolUse hooks
├── hooks/
│   └── block-compound-commands.sh   Denies &&, ;, || chains. Suggests splitting.
├── test-safety-stack.sh    27-check health check for the safety stack
└── zshrc                   Minimal zshrc for the container agent user
```

**Two usage paths:**
- `rc init` → VS Code "Reopen in Container" (generates `.devcontainer/devcontainer.json`)
- `rc up` → CLI/headless mode (creates container, runs init, attaches tmux)

Both paths mount the project directory as a bind mount at `/workspace` — file changes sync instantly, no git push needed.

## Auth

OAuth tokens are the primary auth method (not API keys). On macOS, tokens live in the system Keychain under `"Claude Code-credentials"`. The `rc` script extracts them to `~/.claude/.credentials.json` before mounting into the container. On Linux, that file is used directly.

If you're modifying auth logic, the flow is:
1. `rc init`: keychain extraction happens in `initializeCommand` (runs on host before container starts)
2. `rc up`: keychain extraction happens in `cmd_up` before `docker run`
3. `init-rip-cage.sh`: reads the mounted `.credentials.json`, does NOT extract from keychain (it's inside the container)

## Safety stack

The safety stack has two layers, both configured as `PreToolUse` hooks in `settings.json`:

1. **DCG** (`/usr/local/bin/dcg`) — Rust binary, built from source in the Dockerfile. Blocks destructive commands.
2. **Compound command blocker** (`hooks/block-compound-commands.sh`) — Perl-based detection of `&&`, `;`, `||` outside quotes/heredocs. Prevents permission bypass via chaining.

The allowlist in `settings.json` auto-approves safe commands (git read ops, uv, npm test, ls, etc.). Everything else requires confirmation. Writing to `.git/hooks/*` is hard-denied.

## Container user model

The container runs as `agent` (uid 1000), not root. Sudo is restricted to exact paths:
- `/usr/bin/apt-get`, `/usr/bin/dpkg` (install packages)
- `/bin/chown agent:agent /home/agent/.claude`, `/bin/chown agent:agent /home/agent/.claude-state` (fix bind-mount ownership)

npm global installs are not available at runtime — no sudo for npm. Global packages must be pre-installed in the Dockerfile. Sudo is defined in the Dockerfile's sudoers config with exact command paths (no wildcards).

## Key gotchas

- Docker creates parent dirs for bind mounts as root. That's why `init-rip-cage.sh` starts with `sudo chown agent:agent ~/.claude`.
- `.devcontainer/` and `.vscode/` are gitignored — they're generated per-project by `rc init`.
- The `container_name()` function in `rc` derives names from the last two path components. Collisions get a 4-char hash suffix.
- `sleep infinity` is the container entrypoint for CLI mode — tmux is started by `init-rip-cage.sh`, not the Dockerfile.

## Testing changes

After modifying the Dockerfile or any file that gets COPY'd into the image:
```bash
./rc build
./rc up /path/to/test/project
./rc test <container-name>    # should be 27/27 PASS
```

For changes to `rc` itself, you can test without rebuilding the image.

## Roadmap & design docs

See [docs/ROADMAP.md](docs/ROADMAP.md) for the phased plan, design docs, ADRs, and links to flywheel research repos (local clones at `~/code/personal/flywheel-research/`). Run `git pull` inside a research repo before reading it to get the latest upstream.

## Rules for AI agents calling rc

- Always use `--output json` when parsing output programmatically
- Always use `--dry-run` before `rc destroy` to confirm the target
- Use `rc ls --output json` to discover containers before operating on them
- Container names are derived from paths -- use `rc ls` to get exact names, don't construct them
- The `name` field in `rc up --output json` is the source of truth; names may include a hash suffix when disambiguation occurs
- `rc up --output json` does NOT attach to tmux -- use `rc attach` separately
- `rc attach` has no `--output json` mode -- use `rc ls --output json` to verify container status before calling attach
- Never call `rc destroy` without confirming with the user first
- Set `RC_ALLOWED_ROOTS` to colon-separated absolute paths before calling `rc up` or `rc init`
