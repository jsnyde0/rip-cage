# What's in the Box

The rip-cage image is based on `debian:bookworm` with a multi-stage Dockerfile (Go → Rust → Debian runtime).

## Tools

| Tool | Purpose |
|------|---------|
| Claude Code | The agent itself |
| Node 22 + Bun | JS/TS runtime |
| Python 3 + uv | Python runtime + package manager |
| Go | For building Go tools |
| gh CLI | GitHub operations |
| git | Version control |
| DCG | Destructive command guard (Rust binary) |
| Dolt + bd | Issue tracking (beads) |
| tmux | Session persistence for CLI mode |
| zsh | Shell with sensible defaults |

## Container user model

The container runs as `agent` (uid 1000), not root. Sudo is restricted to exact paths:
- `/usr/bin/apt-get`, `/usr/bin/dpkg` — install packages
- `/bin/chown agent:agent /home/agent/.claude`, `/bin/chown agent:agent /home/agent/.claude-state` — fix bind-mount ownership

npm global installs are not available at runtime — no sudo for npm. Global packages must be pre-installed in the Dockerfile. Sudo is defined in the Dockerfile's sudoers config with exact command paths (no wildcards).
