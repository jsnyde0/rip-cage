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

**Install (recommended):**
```bash
brew install jsnyde0/rip-cage/rip-cage
```

This pulls in `jq`, drops `rc` on your PATH, and installs zsh/bash completions automatically. macOS and Linux (via Linuxbrew/WSL2).

**From source:**
```bash
git clone https://github.com/jsnyde0/rip-cage.git
cd rip-cage && make install      # symlinks rc to ~/.local/bin/rc
rc setup                         # optional: enable shell completions
```

**Use:**
```bash
cd ~/projects/my-app
rc up .
```

That's it. On first run, `rc` prompts for allowed directories and pulls the pre-built image from GHCR (~30s, with local-build fallback if GHCR is unreachable). You're in a caged shell — run `claude` and let it rip.

New to rip cage? The [Getting Started guide](docs/guides/getting-started.md) walks through a first run on a throwaway project, what `rc up` actually does, and the handful of commands you'll use day to day.

## What does the cage do?

The cage runs your agent behind independent layers. Three intercept every shell command before it runs; a fourth watches the network.

**DCG (Destructive Command Guard)** blocks dangerous commands:
```
$ rm -rf /          → DENIED by DCG
$ dd if=/dev/zero   → DENIED by DCG
```

**bypassPermissions with hooks** — Claude Code runs with bypassPermissions enabled, but DCG and the ssh-bypass blocker fire as PreToolUse hooks on every command regardless. DCG uses unanchored whole-command regex matching, so chaining (`&&`, `;`, `||`) does not bypass it. Writing to `.git/hooks/*` is hard-denied.

**Network egress firewall** — the cage watches every outbound connection. New cages start in **observe mode**: nothing is blocked, but the agent's traffic is logged. When you're ready to lock things down, one command promotes everything the agent actually talked to into an allowlist and flips the cage to **block mode** — so it can still reach the APIs it needs and nothing else:

```bash
rc allowlist show --observed        # see where the agent connected in observe mode
rc allowlist promote --from-observed # allow those hosts + switch to block mode
```

For the full safety stack, see [docs/reference/safety-stack.md](docs/reference/safety-stack.md). For the egress model in detail — observe vs. block, DNS exfil detection, the baseline allowlist — see [docs/reference/egress.md](docs/reference/egress.md).

## The worktree workflow

Once you're hooked, git worktrees let you run multiple caged agents in parallel from a single VS Code window:

```bash
git worktree add ../worktrees/feature-auth
rc up ../worktrees/feature-auth

# Meanwhile, you stay on main, managing things.
# File changes sync instantly — it's a bind mount, no git push needed.
```

Spin up as many as you want. Each agent is sandboxed in its own container.

For running more than one agent inside a *single* cage (or a note on what happens when you `rc up` the same path from a second terminal), see [Running multiple agents](docs/reference/cli-reference.md#running-multiple-agents).

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

> **Note:** pi cages get the same DCG destructive-command enforcement as Claude Code cages (via the auto-loaded `dcg-gate.ts` extension) plus container isolation and the egress firewall. See [Pi safety model](docs/reference/auth.md#pi-safety-model).

## Configuration & recipes

Rip cage reads layered config, so you set host-wide defaults once and override per project:

- `~/.config/rip-cage/config.yaml` — global defaults (egress, SSH allowlist, mount denylist, DCG packs, multiplexer)
- `~/.config/rip-cage/tools.yaml` — the global **tool manifest**: optional tools and egress mediators the cage installs
- `<project>/.rip-cage.yaml` — per-project overrides, layered over the global defaults (lists merge additively; single selections override)

`rc config show` prints the merged result with the source of each field. Full details in [docs/reference/config.md](docs/reference/config.md).

**Composing an egress mediator** (L7 credential injection or content policy) is a manifest entry, not a source change — rip cage stays tool-agnostic. Worked recipes for two proven providers:

- [mitmproxy](examples/compose-rc-with-mitmproxy.md) — credential injection via a Python addon
- [iron-proxy](examples/compose-rc-with-iron-proxy.md) — out-of-the-box transparent proxy with placeholder-secret injection

See [docs/reference/composition-seam.md](docs/reference/composition-seam.md) for the seam these plug into.

## More info

**Reference:**
- [CLI reference](docs/reference/cli-reference.md) — all commands, flags, JSON output
- [Auth](docs/reference/auth.md) — OAuth, Keychain, API key fallback
- [SSH identity routing](docs/reference/ssh-routing.md) — `--github-identity`, rules file, banner states
- [Layered config (`.rip-cage.yaml`)](docs/reference/config.md) — global + per-project posture, `rc config show`
- [Network egress](docs/reference/egress.md) — observe vs. block mode, `rc allowlist`, DNS exfil detection
- [Safety stack](docs/reference/safety-stack.md) — hook config, allowlists, denied commands
- [Dev containers](docs/reference/devcontainer.md) — VS Code setup via `rc init`
- [What's in the box](docs/reference/whats-in-the-box.md) — tools, Dockerfile layers

**Guides:**
- [Getting started](docs/guides/getting-started.md) — your first caged session, end to end
- [Multi-account rotation](docs/guides/multi-account-rotation.md) — spread rate limits across Claude accounts

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
