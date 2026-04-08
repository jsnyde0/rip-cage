# Rip Cage

A Docker-based sandbox for running Claude Code agents safely. Let them rip without worrying about `rm -rf /` or other creative self-destruction.

## What it does

Rip Cage wraps your project in a container with a **safety stack** that intercepts every shell command Claude Code tries to run:

1. **DCG (Destructive Command Guard)** — blocks destructive commands like `rm -rf /`, `dd if=/dev/zero`, etc.
2. **Compound command blocker** — prevents `&&`, `;`, `||` chaining that could sneak dangerous commands past the allowlist (e.g., `git add . && curl evil.com`)
3. **Auto-mode with allowlists** — Claude Code runs in full auto mode but only pre-approved commands (git, uv, npm, etc.) execute without review
4. **Non-root user** — the agent runs as `agent`, not root. Sudo is limited to `apt-get`, `chown`, and `npm install -g`.

The agent gets a full dev environment — Node, Bun, Python (uv), Go, gh CLI, and Claude Code itself — but can't blow up your machine.

## Quick start

### Prerequisites

- Docker (or OrbStack on macOS)
- Claude Code authenticated on your host (the container borrows your OAuth token)

### Setup

```bash
git clone https://github.com/jsnyde0/rip-cage.git
cd rip-cage
./rc build

# Tell rc which directories it's allowed to sandbox (add to ~/.zshrc):
export RC_ALLOWED_ROOTS=$HOME/code/personal:$HOME/code/mapular
```

### Using rip-cage on a project

```bash
cd /path/to/your/project
~/path/to/rip-cage/rc up .
```

That's it — you're in a caged tmux session. Run `claude` and let it rip.

```bash
# Manage containers:
rc ls              # list running containers
rc attach <name>   # re-attach tmux
rc down <name>     # stop
rc destroy <name>  # remove container + volumes
```

### Option A: VS Code Dev Container

Best for interactive development — VS Code runs inside the cage.

```bash
./rc init /path/to/your/project
```

Then open the project in VS Code and run **"Dev Containers: Reopen in Container"**.

That's it. You're now in a caged environment. Open the terminal, run `claude`, and let it rip.

### Option B: CLI mode

Best for headless agents, running multiple agents in parallel, or when you just prefer the terminal.

```bash
./rc up /path/to/your/project
```

This creates a container, runs the safety init, and drops you into a tmux session inside the cage. Run `claude` and go.

Detach with `Ctrl-B d` — the container keeps running. Reattach anytime:

```bash
./rc attach <container-name>
```

## The worktree workflow

This is where it gets interesting. If you're using git worktrees (or want to run multiple agents on different tasks), CLI mode lets you spin up isolated caged agents from a single VS Code window:

```bash
# You're in VS Code on main branch, planning work
git worktree add ../worktrees/feature-auth

# Spin up a caged agent on that worktree
./rc up ../worktrees/feature-auth

# The agent rips on implementation in its cage.
# Meanwhile, you stay in VS Code on main, managing things.
# File changes appear live because it's a bind mount — no git push needed.
```

You can run as many of these as you want:

```
Terminal tab 1: rc attach → agent working on feature-auth
Terminal tab 2: rc attach → agent fixing bug-123
Terminal tab 3: your shell, reviewing diffs across worktrees
```

Each agent is sandboxed in its own container. All file changes sync instantly to your host via bind mounts — you see them in VS Code's file explorer and source control panel in real time.

## CLI reference

```
rc build [docker-args...]                       Build the rip-cage image
rc init [--force] [path]                        Scaffold .devcontainer/devcontainer.json
rc up <path> [--port PORT] [--env-file FILE]    Start or resume a container
rc ls                                           List rip-cage containers
rc attach <name>                                Attach to container tmux session
rc down <name>                                  Stop a container
rc destroy <name>                               Remove container and volumes
rc test <name>                                  Run safety stack smoke test
```

## Auth

Rip Cage uses your existing Claude Code OAuth session — no API keys needed.

- **macOS**: The `rc` script extracts your OAuth token from the macOS Keychain automatically. Nothing to configure.
- **Linux**: If you have `~/.claude/.credentials.json` (from a previous `claude /login`), it gets mounted into the container.
- **API key fallback**: Set `ANTHROPIC_API_KEY` in an env file and pass it with `--env-file`.

## What's in the box

The image is based on `debian:bookworm` and includes:

| Tool | Purpose |
|------|---------|
| Claude Code | The agent itself |
| Node 22 + Bun | JS/TS runtime |
| Python 3 + uv | Python runtime + package manager |
| Go | For building Go tools |
| gh CLI | GitHub operations |
| git | Version control |
| DCG | Destructive command guard |
| Dolt + bd | Issue tracking (beads) |
| tmux | Session persistence for CLI mode |
| zsh | Shell with sensible defaults |

## Safety stack details

The safety stack is configured via Claude Code's hook system in `settings.json`:

**PreToolUse hooks** (run before every Bash command):
- `/usr/local/bin/dcg` — denies destructive commands
- `block-compound-commands.sh` — denies compound command chains, suggests splitting into separate calls

**Allowlisted commands** (auto-approved, no confirmation needed):
- File ops: `ls`, `pwd`, `head`, `tail`, `echo`, `mkdir`, `touch`, `wc`, `tree`, `du`, `df`
- Git (read): `git log`, `git diff`, `git show`, `git status`, `git branch`, `git tag`, `git remote`
- Git (write): `git add`, `git commit`
- Python: `uv sync`, `uv lock`, `uv run pytest`, `uv init`
- Node: `npm test`, `npm install`, `npm ci`, `bun test`, `bun install`
- Beads: `bd *`

Everything else prompts for confirmation (but since the agent runs in a container, the blast radius is limited anyway).

**Denied** (hard block):
- Writing to `.git/hooks/*` — prevents the agent from modifying git hooks

## Running the safety tests

After starting a container, verify the safety stack:

```bash
./rc test <container-name>
```

Expected output:
```
=== Rip Cage Safety Stack Smoke Test ===
Test 1: DCG blocks destructive command... PASS
Test 2: block-compound blocks compound command... PASS
Test 3: settings.json has auto mode... PASS
Test 4: settings.json has DCG hook... PASS
Test 5: settings.json has block-compound hook... PASS
Test 6: claude --version succeeds... PASS

=== Results: 6 passed, 0 failed ===
```

## License

MIT
