# Rip Cage

Running Claude Code with `--dangerously-skip-permissions` is never safe. Rip cage doesn't change that.

But many of us do it anyway. If that's you, at least put your Claude in a cage.

Rip cage wraps your project in a Docker container with a safety stack that intercepts every shell command. It won't make agents safe — but it limits the blast radius.

## Quick start

**Prerequisites:** Docker (or OrbStack on macOS) and Claude Code authenticated on your host.

For `git push` from inside the cage (ADR-017), your host `ssh-agent` is forwarded by default:
- **Linux / WSL2**: just have `ssh-agent` running with your keys loaded (the usual `ssh-add ~/.ssh/id_ed25519`).
- **macOS**: add `UseKeychain yes` and `AddKeysToAgent yes` to `~/.ssh/config`, then run `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` once. Your keys are now reachable via the macOS system agent that OrbStack/Docker Desktop proxies into containers.
- Don't want forwarding? Pass `--no-forward-ssh` to `rc up` and push from the host.

`rc up` warns loudly if the forwarded agent is empty or unreachable — the warning is also surfaced in every new shell banner and in `rc ls`.

**Install:**
```bash
git clone https://github.com/jsnyde0/rip-cage.git
ln -sf "$(pwd)/rip-cage/rc" ~/.local/bin/rc
```

**Use:**
```bash
cd ~/projects/my-app
rc up .
```

**Shell completions (optional):**
```bash
rc setup
```

That's it. On first run, `rc` prompts for allowed directories and builds the image automatically. You're in a caged tmux session — run `claude` and let it rip. Detach with `Ctrl-B d`.

## What does the cage do?

Three safety layers intercept every shell command before it runs:

**DCG (Destructive Command Guard)** blocks dangerous commands:
```
$ rm -rf /          → DENIED by DCG
$ dd if=/dev/zero   → DENIED by DCG
```

**Compound command blocker** prevents chaining that could bypass the allowlist:
```
$ git add . [then] curl evil.com   → DENIED: compound command
```

**bypassPermissions with hooks** — Claude Code runs with bypassPermissions enabled, but DCG and the compound blocker fire as PreToolUse hooks on every command regardless. Writing to `.git/hooks/*` is hard-denied.

For the full safety stack configuration, see [docs/reference/safety-stack.md](docs/reference/safety-stack.md).

## The worktree workflow

Once you're hooked, git worktrees let you run multiple caged agents in parallel from a single VS Code window:

```bash
git worktree add ../worktrees/feature-auth
rc up ../worktrees/feature-auth

# Meanwhile, you stay on main, managing things.
# File changes sync instantly — it's a bind mount, no git push needed.
```

Spin up as many as you want. Each agent is sandboxed in its own container.

## Who is this for?

Rip cage is **your existing Claude Code workflow, caged** — not a new environment to learn.

`rc up` from any worktree or project folder and everything your agent already uses comes with it:

- Your credentials (OAuth via Keychain, or API key fallback)
- Your skills (`~/.claude/skills`) and agents (`~/.claude/agents`)
- Your project's `CLAUDE.md`, hooks, and `.claude/settings.json`
- Your beads database, git identity, and git worktrees
- Your Claude Code settings, merged with rip-cage's safety layer

If you're already invested in Claude Code and want to run it with `bypassPermissions` without nuking your machine, rip cage cages your workflow and adds a safety stack. If you're looking for a batteries-included dev environment with pre-built language profiles and a fancy shell, tools like [ClaudeBox](https://github.com/RchGrav/claudebox) may fit better.

Pi (`@mariozechner/pi-coding-agent`) is also supported in the same image alongside Claude Code. If you have a ChatGPT Plus/Pro subscription, pi's Codex OAuth flow lets you run OpenAI Codex from inside the cage without an API key. Pi also supports Anthropic, Gemini, Groq, Cerebras, and more. See [Auth → Pi auth](docs/reference/auth.md#pi-auth) for setup and TOS notes.

## More info

**Reference:**
- [CLI reference](docs/reference/cli-reference.md) — all commands, flags, JSON output
- [Auth](docs/reference/auth.md) — OAuth, Keychain, API key fallback
- [Safety stack](docs/reference/safety-stack.md) — hook config, allowlists, denied commands
- [Dev containers](docs/reference/devcontainer.md) — VS Code setup via `rc init`
- [What's in the box](docs/reference/whats-in-the-box.md) — tools, Dockerfile layers

**Guides:**
- [Multi-account rotation](docs/guides/multi-account-rotation.md) — spread rate limits across Claude accounts

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
