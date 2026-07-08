# Rip Cage

Running Claude Code with `--dangerously-skip-permissions` is never safe. Rip cage doesn't change that.

But many of us do it anyway. If that's you, at least put your Claude in a cage.

Rip cage wraps your project in a Docker container that intercepts every shell command and outbound connection. It won't make your agent safe — it limits the blast radius when it goes wrong. And it's **your existing Claude Code (or pi) workflow, caged** — your repo, credentials, skills, and tools come with you. Nothing to migrate.

## Quick start

**1. Install** (macOS / Linux — needs Docker or OrbStack, with Claude Code authenticated on your host):

```bash
brew install jsnyde0/rip-cage/rip-cage
```

**2. Compose your cage.** Ask your agent — the [`/configure-cage`](.claude/skills/configure-cage/SKILL.md) skill reads the reference manifest and writes a **reviewable `~/.config/rip-cage/tools.yaml`** (your tools, guards, credential posture). Review it, then bake it in with `rc build`.

**3. Run it:**

```bash
cd ~/projects/my-app
rc up .          # then run: claude
```

You're in a caged shell — run `claude` (or `pi`) and let it rip.

> **Just kicking the tires?** Skip step 2 — `rc up .` pulls a ready-made default cage (Claude Code + pi + destructive-command guard) from GHCR. Compose your own when you need more. First run asks which directories cages may touch.

New here? [Getting Started](docs/guides/getting-started.md) walks a first run end to end.

## Composable, not bundled

Rip cage welds a containment floor and blesses nothing above it (ADR-005 D12): agents, command guards, multiplexers, egress mediators, and plain tools are all **recipes you compose into the image** via the `tools.yaml` manifest — never `rc` source edits. Adding a Postgres CLI or a mediator is a manifest entry you (or `/configure-cage`) copy from a [recipe](examples/README.md); the composition surface is a small set of documented [seams](docs/reference/README.md).

Config layers so you set host-wide defaults once and override per project — global `~/.config/rip-cage/config.yaml` + per-project `<repo>/.rip-cage.yaml`, merged on every `rc up` (`rc config show` prints the merged result with each field's source). See [layered config](docs/reference/config.md).

## The safety model

**Layers, not walls.** No single layer stops a motivated attacker — together they contain the blast radius of an agent that goes wrong, including one following instructions injected via a fetched web page or README (ADR-024).

- **Containment floor — always on.** Container boundary, egress firewall (every connection forced through a chokepoint with exfil detection), filesystem sandbox, non-root user, secret-path denylist, read-only `.git/hooks`. Welded in; never composable away.
- **Command guards — default-on recipes.** DCG blocks destructive commands (`rm -rf /` → `DENIED`; chaining with `&&`/`;` doesn't slip past); an ssh-bypass blocker stops routing around them.
- **Egress: observe → block.** New cages log everything and block nothing; `rc allowlist promote --from-observed` turns what the agent actually used into an allowlist and flips to block mode.
- **Credential non-possession — opt-in.** Run the agent on a placeholder token while a composed mediator injects the real secret on egress, so a prompt-injected agent has nothing to exfiltrate.

Containment is low-drift and welded; content and credential policy is high-drift, so it's delegated to a composed mediator — "customs, not the postal service" (ADR-026). Full stack: [safety-stack.md](docs/reference/safety-stack.md), [egress.md](docs/reference/egress.md).

## Everyday commands

| Command | What it does |
|---|---|
| `rc up [path]` / `rc down` / `rc destroy` | Start-or-resume / stop / remove a cage |
| `rc ls` / `rc attach [name]` | List / re-attach to cages |
| `rc exec <cage> -- <cmd>` | Run a one-off command in a cage |
| `rc doctor [name]` | Diagnose a cage (`--host` for daemon liveness) |
| `rc config show \| get` · `rc allowlist show \| promote` | Inspect config · manage egress |

Every command, flag, and JSON output: [CLI reference](docs/reference/cli-reference.md).

## The worktree workflow

Git worktrees let you run multiple caged agents at once, each in its own container:

```bash
git worktree add ../worktrees/feature-auth
rc up ../worktrees/feature-auth   # meanwhile you stay on main
```

Changes sync instantly (bind mount, no git push). Spin up as many as you want.

## Going further

- [Recipe catalog](examples/README.md) · [reference + seam catalog](docs/reference/README.md)
- [Walk-away / headless cages](examples/compose-walk-away-cage.md) — unattended runs
- [Mediators](docs/reference/composition-seam.md) — credential injection & content policy: [iron-proxy](examples/compose-rc-with-iron-proxy.md), [mitmproxy](examples/compose-rc-with-mitmproxy.md)
- [Auth](docs/reference/auth.md) — OAuth, Keychain, and pi's Codex/Anthropic/Gemini providers
- [Multi-account rotation](docs/guides/multi-account-rotation.md) — spread rate limits across accounts

**pi is first-class** alongside Claude Code in the same image — same guards, isolation, and egress firewall. Want a batteries-included dev environment instead? [ClaudeBox](https://github.com/RchGrav/claudebox) may fit better — rip cage cages the workflow you already have.

## Contributing · License

See [CONTRIBUTING.md](CONTRIBUTING.md). MIT.
