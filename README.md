# Rip Cage

Rip cage is a tested **distribution** of [**microsandbox**](https://github.com/microsandbox/microsandbox) for running Claude Code and pi with permissions off.

It finds your Claude login in your macOS keychain, so a fresh cage starts authenticated with nothing for you to paste. It wires up msb's `--secret`, so a credential you nominate reaches its one allowed host without ever entering the VM. It turns a blocked host into a one-line fix. And it ships the suite that proves your cage holds.

Running Claude Code with `--dangerously-skip-permissions` is never safe. Rip cage doesn't change that. But many of us do it anyway. If that's you, at least put your Claude in a cage.

## What msb provides, what rip-cage adds

microsandbox (`msb`) boots an OCI image as a libkrun microVM — its own kernel, its own network stack — from a small YAML config. That is the isolation. Rip cage is the curation on top of it.

| msb provides | rip-cage adds |
|---|---|
| The microVM boundary — own kernel, own network stack | The curated agent image and its init |
| Default-deny egress and DNS at that boundary | The denial → fix → relaunch repair loop |
| `--secret`: a credential the guest never holds | Credential discovery — your Claude login, found in the keychain |
| Read-only mounts | The protected-paths mount floor |
| Recreate a sandbox with the same mounts | The floor probe and the proving suite (`rc test`) |
| The config schema | The operating knowledge, in three skills |

Rip cage never reimplements what msb ships, and never claims msb's isolation as its own.

## Where this sits

Anthropic's [sandbox environments guide](https://code.claude.com/docs/en/sandbox-environments) compares six ways to isolate Claude Code, from the built-in Bash sandbox up to a virtual machine, and says to run `--dangerously-skip-permissions` inside a container, a VM, or the sandbox runtime.

Rip cage is the **virtual machine** row: a full operating system with its own kernel. That row's listed cost is *setup effort: high*. Removing that cost is the whole job.

## Quick start

**1. Install.** macOS or Linux. You need Docker (to build the image) and msb (to run it), with Claude Code already authenticated on your host.

```bash
brew install jsnyde0/rip-cage/rip-cage
```

**2. Write the cage config.** Ask your agent: the [`cage-config`](.claude/skills/cage-config/SKILL.md) skill writes one reviewable file at `~/.config/rip-cage/projects/<cage>.yaml` — mounts, secrets, egress allowlist. That file is the whole project config; `rc` merges nothing into it.

**3. Build the image and run:**

```bash
rc build
cd ~/projects/my-app
rc up .          # then, in the caged shell: claude
```

New here? [Getting Started](docs/guides/getting-started.md) walks a first run end to end.

Need a tool the base image lacks? The [`cage-image`](.claude/skills/cage-image/SKILL.md) skill writes a Dockerfile that starts `FROM rip-cage:latest`. Something blocked or broken at runtime? [`cage-ops`](.claude/skills/cage-ops/SKILL.md).

## The safety model

**Layers, not walls.** No single layer stops a motivated attacker. Together they contain the blast radius of an agent that goes wrong — including one following instructions injected via a fetched web page or README ([ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md)).

- **The microVM boundary.** msb runs the cage as a separate kernel on virtualized hardware. Never composable away.
- **Egress: default-deny.** Nothing leaves the cage except the hosts your config names. A denied host fails at DNS, client-side, in milliseconds — `rc doctor` reads the trace and prints the exact line to add.
- **Credentials the cage never holds.** The config binds a credential name to the hosts it may travel to; msb injects the real value on the wire and the guest sees only a placeholder. This is msb's `--secret`. Rip cage keeps it unattended-friendly: it reads the value from a host-side file outside every cage mount, so nobody has to export a variable before every launch. Separately, `rc up` finds your Claude login in the macOS keychain so a cage starts authenticated — that path mounts the credential file, and is possession, not non-possession. See [secret-posture.md](docs/reference/secret-posture.md) for which is which.
- **A mount floor you don't write.** `rc up` reads a shipped list of credential locations and refuses to launch a config that mounts one, covering any it finds inside a mounted tree.
- **A floor probe on the built image.** It inspects the artifact — non-root user, sudo scope, PATH resolution, guard-file ownership — not a declaration describing it. It runs at every boot and at the head of `rc test`, with no opt-out.

Full stack: [safety-stack.md](docs/reference/safety-stack.md) · [egress.md](docs/reference/egress.md) · [secret-posture.md](docs/reference/secret-posture.md).

## Composable, not bundled

Rip cage welds a containment floor and blesses nothing above it ([ADR-005 D12](docs/decisions/ADR-005-ecosystem-tools.md)). Agents, command guards, multiplexers and plain tools are all things you compose into your own image:

```dockerfile
FROM rip-cage:latest
RUN ...
```

Adding a Postgres client is a few lines you (or the [`cage-image`](.claude/skills/cage-image/SKILL.md) skill) paste from a [recipe](examples/README.md). A long-running process or a multiplexer also drops a small boot-descriptor fragment into the image, which init reads at start. No `rc` source edits, ever.

## Everyday commands

Six verbs. Each does something plain shell cannot do identically every run.

| Command | What it does |
|---|---|
| `rc up [path]` | Start or resume a cage (`--replace` to recreate a running one against the current config) |
| `rc build [--file PATH]` | Build the image from one host-side Dockerfile, then load it into msb |
| `rc doctor [name]` | Diagnose a cage — including which host it was just denied |
| `rc test [name]` | Run the proving suite against your composed image |
| `rc auth refresh` | Re-pull the Claude login from your keychain |
| `rc destroy <name>` | Remove the cage and the volumes `rc` created for it |

Everything else is an msb one-liner or a file edit; the [`cage-ops`](.claude/skills/cage-ops/SKILL.md) skill is the sole home of the table that says which. Every flag and JSON output: [CLI reference](docs/reference/cli-reference.md).

## The worktree workflow

Git worktrees let you run several caged agents at once, each in its own microVM:

```bash
git worktree add ../worktrees/feature-auth
rc up ../worktrees/feature-auth   # meanwhile you stay on main
```

Changes sync live over the mount — no git push. Each worktree needs its own cage config.

## Going further

- [Recipe catalog](examples/README.md) · [reference index](docs/reference/README.md) · [roadmap](docs/ROADMAP.md)
- [Config](docs/reference/config.md) — the one file a cage launches from, field by field
- [Egress](docs/reference/egress.md) — the denied-host repair loop
- [Auth](docs/reference/auth.md) — OAuth, keychain, and pi's Codex / Anthropic / Gemini providers
- [Multi-account rotation](docs/guides/multi-account-rotation.md) — spread rate limits across accounts

**pi is first-class** alongside Claude Code in the same image — same floor, same isolation, same egress policy. Want a batteries-included dev environment instead? [ClaudeBox](https://github.com/RchGrav/claudebox) may fit better.

## Contributing · License

See [CONTRIBUTING.md](CONTRIBUTING.md). MIT.
