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

- `/usr/bin/apt-get`, `/usr/bin/dpkg` — install packages at runtime
- `chown agent:agent` on `/home/agent/.claude`, `/home/agent/.claude-state`, `/home/agent/.pi/agent` — fix mount ownership at init
- `chown -R agent:agent` on the mise data directory

npm global installs are not available at runtime — there is no sudo for npm. Put global packages in your Dockerfile.

Runtime `apt-get install`s live in the guest's ephemeral rootfs overlay, which does **not** survive a recreate. Anything you want to keep belongs in the image or behind a mount.
