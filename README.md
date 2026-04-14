# Rip Cage

Running Claude Code with `--dangerously-skip-permissions` is never safe. Rip cage doesn't change that.

But many of us do it anyway. If that's you, at least put your Claude in a cage.

Rip cage wraps your project in a Docker container with a safety stack that intercepts every shell command. It won't make agents safe — but it limits the blast radius.

## Quick start

**Prerequisites:** Docker (or OrbStack on macOS) and Claude Code authenticated on your host.

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

## More info

- [CLI reference](docs/reference/cli-reference.md) — all commands, flags, JSON output
- [Auth](docs/reference/auth.md) — OAuth, Keychain, API key fallback
- [Safety stack](docs/reference/safety-stack.md) — hook config, allowlists, denied commands
- [Dev containers](docs/reference/devcontainer.md) — VS Code setup via `rc init`
- [What's in the box](docs/reference/whats-in-the-box.md) — tools, Dockerfile layers

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
