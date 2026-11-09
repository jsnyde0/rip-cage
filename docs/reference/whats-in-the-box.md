# What's in the Box

The base image is `debian:trixie`, built by a two-stage Dockerfile: a Go builder stage that compiles `bd` (beads), then the Debian runtime.

This is the **floor** — what every cage gets. Everything else is yours to add with `FROM rip-cage:latest` and a `RUN` line; see the [`cage-image`](../../.claude/skills/cage-image/SKILL.md) skill.

## What the base image carries

| Tool | Why it is floor |
|---|---|
| Claude Code | The agent |
| pi-coding-agent | Multi-provider agent (Anthropic, OpenAI/Codex, Gemini, …); `pi --version` in the cage for the installed version |
| Node 22 + Bun | JS/TS runtime |
| Python 3 + uv | Python runtime and package manager |
| git + gh CLI | Version control, and GitHub over HTTPS |
| Dolt + bd | Issue tracking (beads) |
| mise | Per-project toolchain provisioning |
| zsh | The interactive shell |
| floor probe | The fail-closed containment check; see [safety-stack.md](safety-stack.md) |

Go is build-stage only — it compiles `bd` and is not present at runtime.

**No multiplexer, and no command guard, are baked in.** `tmux`, `herdr` and a destructive-command guard are recipes in [`examples/`](../../examples/README.md); an image that declares one in its boot descriptor can be selected with `RC_MULTIPLEXER`. rip-cage blesses none of them ([ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)).

## The cage user model

The cage runs as `agent` (uid 1000), never root. Sudo is restricted to exact command paths in `/etc/sudoers.d/agent`, with no wildcards:

- `/usr/sbin/sysctl -w dev.tty.legacy_tiocsti=0` — init closes TIOCSTI keystroke injection each boot (the exact argv, so it can only lower the value)
- `/usr/local/lib/rip-cage/own-agent-dir` with one of four fixed targets — `claude`, `claude-state`, `pi-agent`, `mise` — so init can hand root-created mount dirs back to the agent. It refuses a symlink anywhere in the path and skips hardlinked files; a raw `chown` grant would follow a symlink to any root file

There is no sudo for a package manager — no `apt-get`, `dpkg` or `npm -g`. Each runs arbitrary code as root, which would let a steered agent rewrite every root-owned guard ([ADR-002 D12](../decisions/ADR-002-rip-cage-containers.md)). System packages go in your `FROM rip-cage:latest` Dockerfile at build time; user-level installs (`mise`, `uv`, `npm` without `-g`, `cargo`) need no root. A caged agent that needs a missing package asks the host to add it, the same loop as a denied egress host.

Anything installed at runtime outside a mount lives in the guest's ephemeral rootfs overlay, which does **not** survive a recreate. Anything you want to keep belongs in the image or behind a mount.
