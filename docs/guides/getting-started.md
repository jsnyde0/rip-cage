# Getting Started

Your first caged session, end to end. Assumes `rc` is installed and Docker is running (see the [README](../../README.md#quick-start) for both).

## Try it on a throwaway first

The safest way to see how the cage behaves is a scratch directory — the agent can't touch anything you care about:

```bash
mkdir -p ~/scratch/rc-trial
cd ~/scratch/rc-trial
git init
rc up .
```

> First run only: `rc` asks which directories it's allowed to mount, then pulls the pre-built image from GHCR (~30s, with a local-build fallback). Every run after that is near-instant.

## What `rc up` does

1. Creates the container and bind-mounts your project at `/workspace` (file changes sync both ways instantly — no git push).
2. Carries your existing setup in: credentials, `~/.claude/skills` and `agents`, the project's `CLAUDE.md`, git identity, and beads.
3. Drops you into a **tmux session inside the cage**. Your shell prompt changes — you're now in the box.

Type `claude` (or `pi`) and let it work.

## See the cage earning its keep

Inside the session, ask the agent to run something destructive:

```
rm -rf /              → DENIED by DCG
echo hi && rm -rf ~   → DENIED (chaining doesn't bypass it)
```

DCG fires on every command regardless of Claude Code's permission mode. Meanwhile the egress firewall logs everything the agent connects to — in observe mode it blocks nothing yet. After the agent has fetched something, detach and run `rc allowlist show --observed` on the host to see where it went.

## The commands you'll actually use

| Action | Command |
|---|---|
| Start / resume a cage | `rc up <path>` |
| Detach (leave it running) | `Ctrl-B` then `d` |
| Re-attach later | `rc attach` |
| See what's running | `rc ls` |
| Stop a cage | `rc down <name>` |
| Remove it entirely | `rc destroy <name>` |

That's the whole daily loop. Everything else is occasional.

## Where to go next

- **[CLI reference](../reference/cli-reference.md)** — every command and flag.
- **[Network egress](../reference/egress.md)** — promoting observe-mode traffic into an allowlist and flipping to block mode.
- **[The worktree workflow](../../README.md#the-worktree-workflow)** — running several caged agents in parallel.
- **[Auth](../reference/auth.md)** — OAuth, Keychain, API-key fallback, and pi's Codex flow.
