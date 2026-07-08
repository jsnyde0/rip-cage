# Rip Cage

Running Claude Code with `--dangerously-skip-permissions` is never safe. Rip cage doesn't change that.

But many of us do it anyway. If that's you, at least put your Claude in a cage.

Rip cage wraps your project in a Docker container with a safety stack that intercepts every shell command. It won't make agents safe — but it limits the blast radius.

Two things set it apart from a generic dev container:

- **It's your workflow, caged — not a new environment to learn.** `rc up .` and your real repo (a live bind-mount), your credentials, your skills, agents, memories, and beads are all just *there*. Nothing to migrate, changes sync instantly.
- **It's composable, not bundled.** Rip cage welds a containment floor and blesses nothing above it. Every agent, guard, multiplexer, and egress mediator is a reviewable recipe you compose into the image — so you build exactly the cage you want, and every layer is auditable YAML before it's baked.

## Install

```bash
brew install jsnyde0/rip-cage/rip-cage
```

This drops `rc` on your PATH, pulls in `jq` + `yq`, and installs zsh/bash completions. Works on macOS and Linux (Linuxbrew / WSL2).

**Prerequisite:** Docker (or OrbStack on macOS), with Claude Code authenticated on your host.

<details>
<summary>From source instead</summary>

```bash
git clone https://github.com/jsnyde0/rip-cage.git
cd rip-cage && make install   # symlinks rc to ~/.local/bin/rc
rc setup                      # optional: shell completions
```
</details>

## First run

```bash
cd ~/projects/my-app
rc up .
```

That's it. On first run `rc` asks which directories cages may touch, then pulls the pre-built image from GHCR (~30s, with a local-build fallback). You land in a caged shell — run `claude` (or `pi`) and let it rip.

New here? The [Getting Started guide](docs/guides/getting-started.md) walks a first run end to end.

> **Pushing from inside the cage?** Your host `ssh-agent` is forwarded by default (ADR-017), so `git push` just works — on macOS you load your key into the system agent once. Details and the `--no-forward-ssh` opt-out are in [SSH routing](docs/reference/ssh-routing.md).

## Compose your cage

Rip cage is a **composable seam, not a bundler**: the `rc` binary welds the containment floor and defines the composition interfaces — and blesses no specific tool (ADR-005 D12). Everything above the floor — the agents themselves (Claude Code, pi), command guards, multiplexers, egress mediators, plain tools, in-cage daemons — is a **recipe you compose in**.

A cage is defined by a **manifest** (`tools.yaml`) listing what gets baked into the image at `rc build`. Adding a Postgres CLI, a mediator, or a locked-down guard is a manifest entry — never an `rc` source edit. The recipes live in [`examples/`](examples/README.md), each a copy-pasteable fragment; the composition surface — plain tools, guards, multiplexers, mediators, daemons — is documented as a small set of seams in the [reference + seam catalog](docs/reference/README.md).

**The simplest way to compose is to ask your agent.** Since composition *is* the agent's job here, the [`configure-cage`](.claude/skills/configure-cage/SKILL.md) skill (ships in this repo) does it for you: it reads the maintained reference manifest, then hand-writes the tools, guards, mediators, and posture you want into a **reviewable `~/.config/rip-cage/tools.yaml`** — which you inspect like a diff before you ever run `rc build`.

> "Set up a rip-cage cage with a Postgres CLI and my credentials kept out of it."

Config layers so you set host-wide defaults once and override per project:

| Layer | File | Governs |
|---|---|---|
| **Image manifest** | `~/.config/rip-cage/tools.yaml` | which tools, guards, multiplexers, and mediators get baked in at `rc build` |
| **Global posture** | `~/.config/rip-cage/config.yaml` + `rc.conf` | host-wide guardrails: mount denylist, which host paths `rc up` may target |
| **Per-project** | `<repo>/.rip-cage.yaml` | per-workspace runtime posture: egress mode + allowlist, SSH hosts, multiplexer |

Global and project configs merge on every `rc up` (lists union, project can expand but never contract the floor — ADR-021). `rc config show` prints the merged result with the source of each field. Full details in [layered config](docs/reference/config.md).

## The safety model

Rip cage is honest about what a container can and can't hold: **layers, not walls.** No single layer is a hard boundary against a motivated attacker — together they limit the blast radius of an agent that goes wrong, including one following instructions injected via a fetched web page, README, or MCP output (ADR-024). A determined *adversarial* agent is explicitly out of scope.

**Containment floor — always on.** Welded into the base image, never composable away: the container boundary, an egress firewall (every outbound connection forced through a chokepoint with an IOC + DNS-exfil denylist), a filesystem sandbox, a non-root user with scoped sudo, a secret-path mount denylist, and a read-only weld over `.git/hooks`.

**Command guards — default-on, composable recipes.** The published image ships two guards on top of the floor (ADR-025, ADR-026):

- **DCG (Destructive Command Guard)** blocks dangerous commands — `rm -rf /`, `dd if=/dev/zero` → `DENIED`. It matches the whole command unanchored, so chaining with `&&`, `;`, or `||` doesn't slip past it. Ships **open** by default (agents still auto-load their own extensions; the guard loads first and always denies) — a locked posture closes that residual at the cost of auto-loading.
- **ssh-bypass blocker** stops the agent from routing around the guards over SSH.

Omit them for a minimal cage and containment still holds — you just lose the accident guardrails.

**Egress: observe → block.** New cages start in **observe mode** — nothing blocked, everything logged. When you're ready, one command promotes what the agent actually used into an allowlist and flips to **block mode**:

```bash
rc allowlist show --observed         # where did the agent connect?
rc allowlist promote --from-observed # allow those hosts + switch to block mode
```

**Credential non-possession — opt-in.** By default a cage mounts your real credentials, so a prompt-injected agent could exfiltrate them. Instead you can run the agent on a **placeholder** while a composed **mediator** (e.g. iron-proxy) injects the real secret on egress — the agent never holds it, proven end-to-end for Claude Code on the Anthropic subscription. Ask the `configure-cage` skill for it, or see the [iron-proxy recipe](examples/compose-rc-with-iron-proxy.md).

The split is deliberate: containment is low-drift and welded; content and credential policy is high-drift, so it's delegated to a composed mediator rather than baked in — "customs, not the postal service" (ADR-026). The full stack lives in [safety-stack.md](docs/reference/safety-stack.md) and [egress.md](docs/reference/egress.md).

## Everyday commands

| Command | What it does |
|---|---|
| `rc up [path]` | Start or resume a cage (default: `.`) |
| `rc ls` | List cages |
| `rc attach [name]` | Attach to a running cage |
| `rc exec <cage> -- <cmd>` | Run a one-off command in a cage |
| `rc down [name]` / `rc destroy [name]` | Stop / remove a cage |
| `rc doctor [name]` | Diagnose a cage (or `--host` for daemon liveness) |
| `rc config show [path]` / `rc config get <key>` | Inspect merged config |
| `rc allowlist show \| promote` | Manage egress allowlist |
| `rc reload [name]` | Hot-reload `.rip-cage.yaml` allowlist changes |
| `rc auth refresh` | Refresh credentials from the host keychain |

Every command, flag, and JSON output: [CLI reference](docs/reference/cli-reference.md).

## Run agents in parallel

Git worktrees let you run multiple caged agents at once, each in its own container:

```bash
git worktree add ../worktrees/feature-auth
rc up ../worktrees/feature-auth   # meanwhile you stay on main
```

File changes sync instantly — it's a bind mount, no git push needed. Spin up as many as you want. For more than one agent inside a *single* cage, see [running multiple agents](docs/reference/cli-reference.md#running-multiple-agents).

## Going further

- **[Recipe catalog](examples/README.md)** — every composable fragment: tools, guards, multiplexers, mediators, launch composition
- **[Reference + seam catalog](docs/reference/README.md)** — the composition seams and every reference doc
- **[Walk-away / headless cages](examples/compose-walk-away-cage.md)** — unattended agent runs
- **[Mediators](docs/reference/composition-seam.md)** — credential injection & content policy: [iron-proxy](examples/compose-rc-with-iron-proxy.md), [mitmproxy](examples/compose-rc-with-mitmproxy.md)
- **[Multi-account rotation](docs/guides/multi-account-rotation.md)** — spread rate limits across Claude accounts
- **[Auth](docs/reference/auth.md)** — OAuth, Keychain, API-key fallback, pi's Codex/Anthropic/Gemini providers

**pi is a first-class citizen** alongside Claude Code in the same image — same DCG enforcement, container isolation, and egress firewall. With a ChatGPT Plus/Pro subscription, pi's Codex OAuth runs OpenAI Codex in the cage with no API key. See [Auth → Pi](docs/reference/auth.md#pi-auth).

Looking for a batteries-included dev environment with pre-built language profiles instead? Tools like [ClaudeBox](https://github.com/RchGrav/claudebox) may fit better — rip cage cages the workflow you already have.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
