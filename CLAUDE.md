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
├── test-safety-stack.sh    32-check health check for the safety stack
└── zshrc                   Minimal zshrc for the container agent user
```

**Two usage paths:**
- `rc init` → VS Code "Reopen in Container" (generates `.devcontainer/devcontainer.json`)
- `rc up` → CLI/headless mode (creates container, runs init, attaches tmux)

Both paths mount the project directory as a bind mount at `/workspace` — file changes sync instantly, no git push needed.

## Installation

```bash
# One-time setup — symlink rc onto your PATH:
ln -sf /path/to/rip-cage/rc ~/.local/bin/rc

# Configure allowed roots (directories rc is permitted to mount):
mkdir -p ~/.config/rip-cage
cat > ~/.config/rip-cage/rc.conf << 'EOF'
RC_ALLOWED_ROOTS="${RC_ALLOWED_ROOTS:-$HOME/projects}"
EOF
# Edit the line above to list your code directories, colon-separated.
```

## Quick start (using rip-cage on another repo)

```bash
# From the project (or worktree) you want to sandbox:
cd ~/projects/my-app
rc up .

# Manage containers:
rc ls              # list running containers
rc attach <name>   # re-attach tmux
rc down <name>     # stop
rc destroy <name>  # remove container + volumes
```

**Known issue:** Credential bind mounts break if the host rewrites `~/.claude/.credentials.json` (e.g., token refresh by host Claude Code). Symptom: "Not logged in" inside container. Fix: `rc destroy <name>` and `rc up .` again.

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
./rc test <container-name>    # should be 32/32 PASS
```

For changes to `rc` itself, you can test without rebuilding the image.

## Roadmap & design docs

See [docs/ROADMAP.md](docs/ROADMAP.md) for the phased plan, design docs, and ADRs.

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

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
