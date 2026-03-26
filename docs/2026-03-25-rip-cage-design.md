# Design: Rip Cage — Containerized Agentic Development Flywheel

**Date:** 2026-03-25
**Status:** Draft (5-pass review complete, findings integrated)
**Decisions:** [ADR-002](decisions/ADR-002-rip-cage-containers.md)
**Origin:** Discussion comparing AA guardrails approach vs ACFS container-based approach. Realized containers are the flywheel housing — they hold the safety tools together, limit blast radius, and let you be bolder with the tool stack inside.
**Supersedes:** None
**Related:** [AA Design v2](2026-03-23-approval-agent-design-v2.md), [ACFS repo](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup)

---

## Problem

Running Claude Code agents on a local Mac requires constant permission approvals — the "approval monkey" problem. Tools like DCG, allow lists, and AA (in development) progressively reduce approvals, but on the host machine you must stay conservative because mistakes hit your real environment.

ACFS (Jeffrey Emanuel's Agentic Coding Flywheel Setup) solves this differently: agents run on throwaway Ubuntu VPSes where the blast radius is inherently limited. But it's Ubuntu-only, requires a remote server, and has no local development story for UI work with hot reload.

We want: a **flywheel environment** where safety tools compound, the container limits blast radius so you can be bolder, and the same setup works locally (Mac) and on VPS.

## Goal

A containerized environment ("Rip Cage") for agentic development where Claude Code runs in **auto mode** with hooks as guardrails. The container is the flywheel housing — it holds the safety tools together and contains the energy if something goes wrong.

Two interfaces:
- **VS Code devcontainer** — primary local UX. Auto mode prompts appear naturally in the editor when the classifier needs human input.
- **`rc` CLI + tmux** — headless/VPS story. `rc up <path>` for standalone containers.

Same Dockerfile powers both. Same safety stack inside.

"Let it rip" means: Claude Code's auto mode classifier handles most decisions autonomously. DCG and hooks hard-deny catastrophic commands. The container limits blast radius. Humans only see prompts when the classifier is genuinely uncertain — and even then, it's rare.

## Non-Goals

- Replacing AA — containers and AA are complementary layers; AA can be added to the flywheel over time
- Multi-agent orchestration (NTM-style) — Phase 3
- Cloud orchestration / Kubernetes — out of scope
- Per-project Dockerfiles — one base image handles common toolchains
- Network firewall / egress filtering — too restrictive for real agentic work (agents need to fetch packages, browse docs, call APIs). Dev-only credentials are the primary secret protection.
- MCP servers / plugins inside containers — Phase 1 uses base Claude Code only

---

## Proposed Architecture

```
┌──────────────────────────────────────────────────────┐
│  Host (Mac / VPS)                                    │
│                                                      │
│  VS Code devcontainer     rc up <path> --clone       │
│  (or rc up <path>)              │                    │
│       │                         │                    │
│  ┌────▼──────────────┐   ┌─────▼──────────────┐     │
│  │  Container A       │   │  Container B        │     │
│  │  (bind mount)      │   │  (git clone)        │     │
│  │                    │   │                     │     │
│  │  /workspace ───────┤   │  /workspace         │     │
│  │  = host path       │   │  = cloned repo      │     │
│  │                    │   │                     │     │
│  │  Safety stack:     │   │  Safety stack:      │     │
│  │  1. allow/deny     │   │  1. allow/deny      │     │
│  │  2. DCG (deny)     │   │  2. DCG (deny)      │     │
│  │  3. block-compound │   │  3. block-compound  │     │
│  │  4. auto mode      │   │  4. auto mode       │     │
│  │     classifier     │   │     classifier      │     │
│  │  5. human fallback │   │  5. human fallback  │     │
│  │                    │   │                     │     │
│  │  + beads (bd/Dolt) │   │  + beads (bd/Dolt)  │     │
│  └────────────────────┘   └─────────────────────┘     │
│                                                      │
│  Container = flywheel housing (blast radius limiter) │
│  Note: Container B (clone mode) is Phase 2           │
└──────────────────────────────────────────────────────┘
```

### Safety Stack (inside every container)

```
Command arrives (Bash tool call)
    ↓
┌─────────────────────────────────┐
│ PreToolUse hooks                │  Fire FIRST, before Claude Code's
│                                 │  permission system sees anything
│  1. DCG (Rust, <1ms)            │  → hard DENY catastrophic patterns
│  2. block-compound-commands.sh  │  → hard DENY compound commands
│                                 │
│  Hook denials do NOT count      │  (agent sees denial, retries or
│  toward auto mode's block       │   moves on — classifier never
│  counters.                      │   involved)
└──────────────┬──────────────────┘
               │ passes all hooks
               ↓
┌─────────────────────────────────┐
│ Allow/deny list (settings.json) │  Known-safe commands auto-allowed
│                                 │  Auto mode respects these
└──────────────┬──────────────────┘
               │ not in list
               ↓
┌─────────────────────────────────┐
│ Auto mode classifier            │  Sonnet 4.6 reviews the action
│ (built into Claude Code)        │  Sees user messages + CLAUDE.md
│                                 │  Does NOT see tool results
│                                 │  → auto-approve or block
└──────────────┬──────────────────┘
               │ blocked 3x in a row or 20x total
               ↓
┌─────────────────────────────────┐
│ Human fallback                  │  Auto mode pauses, prompts user
│ (rare — classifier handles 99%) │  User approves/denies, resets counters
└─────────────────────────────────┘

Note: In the container, no PreToolUse hooks are registered for
Read/Edit/Write tools — the container boundary provides equivalent
protection. On the host, these tools do have hooks (e.g.,
restrict-sensitive-paths.sh).

Outer layer: Container isolation (blast radius limiter)
- Host filesystem limited to /workspace bind mount (not ~/.ssh, ~/.aws, other projects)
- CLAUDE.md files mounted read-only; auth files mounted read-write (for token refresh)
- Dev credentials only — nothing production to steal
- No Docker socket mounted, no --privileged, default capabilities only
- Docker-in-Docker is not supported in Phase 1
```

### Base Image (`rip-cage`)

A single Docker image containing the full agent toolchain:

- **Python**: uv, Python 3.12+
- **Node/JS**: Bun (primary — faster than Node for Claude Code), Node 22 LTS, npm
- **Git**: git, gh CLI
- **Shell**: zsh, tmux, jq
- **Claude Code**: installed via npm (`@anthropic-ai/claude-code`)
- **DCG**: pre-built release binary from [DCG repo](https://github.com/Dicklesworthstone/destructive_command_guard) (sigstore-signed, multi-arch)
- **Beads**: `bd` CLI (built from Go source via `go install`, includes Dolt driver)
- **Hooks**: `block-compound-commands.sh` (pure shell, no binary deps)
- **Config**: auto mode enabled, hooks registered in container's `~/.claude/settings.json`
- **User context**: `CLAUDE.md` files mounted read-only from host (see [User Context Propagation](#user-context-propagation))

The image is built once, tagged with a version, and reused across all projects. Rebuild when toolchain versions change.

**Multi-arch support** (Phase 2): The Dockerfile uses `ARG TARGETARCH` for architecture-aware steps. Phase 1a builds arm64 only (Mac). In Phase 2, build with `docker buildx build --platform linux/arm64,linux/amd64` for VPS (amd64) support. OrbStack includes buildx out of the box.

**devcontainer compatibility**: The Dockerfile is structured to also work as a devcontainer target — supports build args for version pinning, non-root user model, and `postStartCommand` for hook initialization. See [Devcontainer Mode](#devcontainer-mode-local-primary-ux).

**Dockerfile skeleton** (2-stage build):

```dockerfile
# ── Stage 1: Go builder (compile bd) ──────────────────────────
FROM golang:1.25-bookworm AS go-builder

RUN apt-get update && apt-get install -y libicu-dev libzstd-dev pkg-config
RUN go install github.com/steveyegge/beads/cmd/bd@latest

# ── Stage 2: Runtime ──────────────────────────────────────────
FROM debian:bookworm

ARG DCG_VERSION=0.4.3
ARG CLAUDE_CODE_VERSION=latest
ARG PYTHON_VERSION=3.12
ARG BUN_VERSION=latest
ARG TARGETARCH

# System packages (least-frequently-changed first for layer caching)
RUN apt-get update && apt-get install -y \
    curl wget git ssh openssh-client \
    zsh tmux jq sudo \
    build-essential pkg-config \
    libicu-dev libzstd-dev \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# uv (Python package manager — standalone installer, no pip dependency)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv

# Node 22 LTS + Bun
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g bun@${BUN_VERSION}

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# DCG (pre-built binary, multiarch — map Docker arch to Rust triple)
RUN case "${TARGETARCH}" in \
      arm64) ARCH=aarch64 ;; \
      amd64) ARCH=x86_64 ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL \
    "https://github.com/Dicklesworthstone/destructive_command_guard/releases/download/v${DCG_VERSION}/dcg-${ARCH}-unknown-linux-gnu.tar.xz" \
    | tar xJ -C /usr/local/bin/

# bd (from Go builder stage)
COPY --from=go-builder /go/bin/bd /usr/local/bin/bd

# Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Non-root user
RUN groupadd -r agent && useradd -r -g agent -m -d /home/agent -s /bin/zsh agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/agent

# Hooks + config template
COPY hooks/ /usr/local/lib/rip-cage/hooks/
COPY settings.json /etc/rip-cage/settings.json
COPY init-rip-cage.sh /usr/local/bin/init-rip-cage.sh

USER agent
WORKDIR /home/agent
CMD ["zsh"]
```

**Estimated image size**: ~1.1 GB (acceptable for dev environment; built once, reused across projects).

**Key build args** (all pinnable for reproducibility):
- `DCG_VERSION` — DCG release tag
- `CLAUDE_CODE_VERSION` — npm package version
- `PYTHON_VERSION` — Python minor version
- `BUN_VERSION` — Bun version
- `TARGETARCH` — set automatically by `docker buildx`

Future extensibility: Rust toolchain, Django deps, AA, or other flywheel tools added to the image over time. Each tool compounds — the image is your "what can agents do" definition.

### Container Settings (`settings.json`)

The container has its own `~/.claude/settings.json` baked into the image. Unlike with `--dangerously-skip-permissions` (which bypasses allow/deny lists entirely), **auto mode respects allow/deny lists** — they're checked before the classifier. This means we can have meaningful permission rules inside the container.

Container `settings.json` contains:
- **Permission mode**: `auto`
- **Allow list**: narrow, safe patterns (e.g., `Bash(npm test)`, `Bash(uv sync)`) — auto mode drops overly broad rules like `Bash(*)` for safety
- **DCG hook** pointing to `/usr/local/bin/dcg` (pre-built binary)
- **`block-compound-commands.sh`** hook at a container path
- **`bd prime`** (SessionStart + PreCompact hooks) — beads context loading and recovery after compaction
- No host-specific hooks (`notify.sh`, `allow-directory-commands.sh`, `block-harvest.sh`, `restrict-sensitive-paths.sh`)

**Hook disposition from host:**

| Host Hook | Container | Reason |
|-----------|-----------|--------|
| DCG | **Include** (pre-built binary) | Blocks catastrophic commands |
| `block-compound-commands.sh` | **Include** (copied) | Blocks compound command bypass |
| `bd prime` (SessionStart + PreCompact) | **Include** (bd + Dolt in image) | Beads context loading + recovery after compaction |
| `restrict-sensitive-paths.sh` | **Exclude** | Container boundary protects sensitive paths; nothing to restrict |
| `allow-directory-commands.sh` | **Exclude** | Host-specific trusted paths, irrelevant in container |
| `block-harvest.sh` | **Exclude** | Host-only operation |
| `notify.sh` | **Exclude** | Uses macOS `afplay` |

### Devcontainer Mode (Local, Primary UX)

The same image works as a VS Code devcontainer. This is the **primary local interface** because:
- Auto mode prompts appear naturally in the VS Code terminal when the classifier needs human input
- VS Code extensions (Claude Code, GitLens, etc.) work inside the container
- Port forwarding for dev servers is handled natively
- File editing works bidirectionally

**Setup:** `rc init <path>` generates `.devcontainer/devcontainer.json` in the target project. The generated config references the pre-built `rip-cage:latest` image — no Dockerfile path, no dependency on the rip-cage source repo. This is the same image used by `rc up`. See [D13 in ADR-002](decisions/ADR-002-rip-cage-containers.md) for rationale.

**`devcontainer.json`** (generated by `rc init`, per-project):
```json
{
  "name": "Rip Cage",
  "image": "rip-cage:latest",
  "remoteUser": "agent",
  "mounts": [
    "source=rc-state-${devcontainerId},target=/home/agent/.claude-state,type=volume",
    "source=rc-history-${devcontainerId},target=/commandhistory,type=volume",
    "source=${localEnv:HOME}/.claude.json,target=/home/agent/.claude.json,type=bind",
    "source=${localEnv:HOME}/.claude/CLAUDE.md,target=/home/agent/.rc-context/global-claude.md,type=bind,readonly",
    "source=${localEnv:HOME}/CLAUDE.md,target=/home/agent/.rc-context/home-claude.md,type=bind,readonly"
  ],
  "initializeCommand": "bash -c 'touch \"${HOME}/.claude/CLAUDE.md\" \"${HOME}/CLAUDE.md\" 2>/dev/null; true'",
  "containerEnv": {
    "NODE_OPTIONS": "--max-old-space-size=4096"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=delegated",
  "workspaceFolder": "/workspace",
  "postStartCommand": "/usr/local/bin/init-rip-cage.sh"
}
```

**Image reference evolution:** Phase 1 uses `rip-cage:latest` (locally built). When published, this becomes `ghcr.io/jsnyde0/rip-cage:latest` — a one-line change in `rc`'s template, no per-project updates needed (existing devcontainer.json files would need updating, but new ones get the registry reference automatically).

**Volume strategy**: The named volume is at `/home/agent/.claude-state` (not `~/.claude` directly) to avoid shadowing bind-mounted files. The `init-rip-cage.sh` script assembles `~/.claude/` from three sources: baked-in template (settings.json, hooks — always overwritten from image on startup), host context (CLAUDE.md files from `.rc-context/`), and persistent state (session data from `.claude-state/`). See [init-rip-cage.sh Contract](#init-rip-cagesh-contract).

**Auth mounts**: OAuth files (`~/.claude.json`, `~/.config/claude-code/auth.json`) are mounted **read-write** so Claude Code can refresh expired tokens internally. This keeps host tokens fresh too. CAAM research confirmed Claude Code handles its own token refresh — external refresh is not supported (the OAuth endpoint is undocumented).

Follows patterns from Anthropic's [official Claude Code devcontainer](https://code.claude.com/docs/en/devcontainer):
- Non-root user with scoped sudo
- Named volumes for persistent state
- `delegated` consistency for better bind mount performance on Mac
- `postStartCommand` for hook initialization

### `init-rip-cage.sh` Contract

This script runs as `postStartCommand` (devcontainer) or entrypoint (CLI mode). It assembles the runtime `~/.claude/` directory from multiple sources. Ordered responsibilities:

1. **Overwrite settings template** — always copy `/etc/rip-cage/settings.json` → `~/.claude/settings.json` from the image template. This is baked config (hooks, auto mode, allow list), not user state — overwriting on every start ensures image upgrades propagate new hooks/settings to persistent containers. Session data lives in `.claude-state/` volume, not `settings.json`.
2. **Copy CLAUDE.md files** — copy `/home/agent/.rc-context/global-claude.md` → `~/.claude/CLAUDE.md` and `/home/agent/.rc-context/home-claude.md` → `~/CLAUDE.md` (these are snapshots from the host at container start, not live links).
3. **Restore persistent state** — symlink or copy session data from `.claude-state/` volume into `~/.claude/` as needed.
4. **Verify hooks** — confirm DCG binary at `/usr/local/bin/dcg` is executable, `block-compound-commands.sh` exists at its configured path.
5. **Set git identity** — configure `user.name` and `user.email` from env vars (`GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`) or fall back to defaults from the image.
6. **Verify Claude Code** — run `claude --version` to confirm it starts. Check for auth: OAuth files (`~/.claude.json`) or `ANTHROPIC_API_KEY` env var. Warn if neither is present.
7. **Initialize beads** — run `bd prime` if `.beads/` exists in `/workspace`.
8. **Start tmux** (CLI mode only) — create a tmux session for the user to attach to.

**Inputs:** env vars (`ANTHROPIC_API_KEY`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GH_TOKEN`), mounted paths (`.rc-context/`, `.claude-state/`, `/workspace`).
**Failure behavior:** If hooks are missing or Claude Code fails to start, exit with non-zero status and print diagnostics. In devcontainer mode, VS Code shows the error. In CLI mode, `rc up` exits with an error and shows logs.

### CLI Mode (`rc`) — Headless/VPS

Simple shell script for container lifecycle (no VS Code):

```bash
# Build the rip-cage image (prerequisite, once)
rc build

# Scaffold .devcontainer/ into a project (for VS Code devcontainer UX)
rc init /path/to/any-project

# Start a container mounting a path (CLI/tmux mode)
rc up /Users/jonat/code/mapular/platform/mapular-platform

# Start in clone mode (for VPS / background work)
rc up https://github.com/jsnyde0/mapular-platform --clone

# List running containers
rc ls

# Attach to a running container's tmux
rc attach mapular-platform

# Stop (preserves state)
rc down mapular-platform

# Destroy (full reset)
rc destroy mapular-platform

# Health check — verify safety stack is working
rc test mapular-platform
```

**`rc build`** is a thin wrapper around `docker build -t rip-cage:latest`. It locates the Dockerfile relative to the `rc` script itself (so it works regardless of where `rc` is installed). Phase 2 adds `--push` to push to `ghcr.io`.

**`rc init <path>`** generates `.devcontainer/devcontainer.json` in the target directory, referencing `image: rip-cage:latest`. Won't overwrite an existing file without `--force`. Works on any project, including rip-cage itself (the image must be built first via `rc build`).

**Health check (`rc test`)**: Runs a smoke test that verifies: (a) DCG denies a test destructive command, (b) block-compound denies a test compound command, (c) `settings.json` contains expected hooks and auto mode config, (d) `claude --version` succeeds. Exits 0 if all pass, non-zero with diagnostics on failure.

**Future: `rc health`**: For long-running persistent containers, extend `rc ls` or add `rc health <name>` to show container uptime, disk usage, whether Claude Code is running, and Dolt responsiveness. Not Phase 1 — add when persistent containers run long enough to accumulate state issues.

Container naming: derived from the last two path components to avoid collisions. E.g., `~/code/personal/platform` -> `personal-platform`, `~/code/mapular/platform` -> `mapular-platform`. If a container for that name exists, attach to it. **Collision risk**: paths like `~/a/foo/bar` and `~/b/foo/bar` both derive `foo-bar`. If `rc up` detects a container exists for a different source path with the same name, it should warn and use a hash suffix for disambiguation.

### First Run Experience

When a new container launches (via devcontainer or `rc up`):

1. Container starts with `/workspace` mounted (bind) or cloned
2. In devcontainer: user is in VS Code. In CLI mode: user lands in a tmux session
3. Project deps are **not** auto-installed — user runs `npm install` / `uv sync` manually (or tells the agent to)
4. Claude Code is available as the `claude` command, configured for auto mode
5. `CLAUDE.md` files from host are available (read-only mount)
6. Beads (`bd`) is available for issue tracking; `.beads/` comes with the project via bind mount or clone. **Beads is local-only in Phase 1** — `bd create/close/list/show` work, but `bd dolt push/pull` will fail (no SSH keys or host aliases mounted). Beads changes persist via the `/workspace` bind mount and are committed with normal git workflow.
7. On reconnect: devcontainer resumes in VS Code; `rc attach` resumes the tmux session

### Bind Mount Mode (Local, Interactive)

- Mounts the host path at `/workspace` inside the container
- Changes appear on host immediately — hot reload works
- Dev servers bind to `0.0.0.0`, ports forwarded to host
- `.env` is **not mounted** — dev/test credentials injected via `docker run -e` or `--env-file`. Never inject production credentials locally.
- Git operations: `git add/commit/diff/log` work inside the container (auto mode runs these freely). `git push/pull` require auth — in bind mount mode, do these on the host. Git identity (`user.name/email`) set by `init-rip-cage.sh` from env vars.

### Clone Mode (VPS, Background)

- `git clone` inside the container — fully isolated
- Agent pushes to a branch when done
- No bind mount — container is self-contained
- Git auth via `GH_TOKEN` environment variable injected at container start
- Dev/test env vars for the app injected via `--env-file` at container start
- Designed for: "work on this feature overnight on the VPS, I'll review the PR tomorrow"

### User Context Propagation

Claude Code reads `CLAUDE.md` files at multiple levels. Host context is bind-mounted read-only into a staging directory (`.rc-context/`), then copied into place by `init-rip-cage.sh`:

- `~/.claude/CLAUDE.md` → bind-mounted to `.rc-context/global-claude.md` → copied to `~/.claude/CLAUDE.md` by init script
- `~/CLAUDE.md` → bind-mounted to `.rc-context/home-claude.md` → copied to `~/CLAUDE.md` by init script
- Project-level `CLAUDE.md` → present via `/workspace` bind mount (or cloned with repo)
- Auto-memory (`~/.claude/projects/`) → **not mounted** in Phase 1. Container agents start without accumulated memory. This is acceptable — memory is convenience, not correctness.

**Note:** CLAUDE.md files are snapshots at container start, not live links. If you edit CLAUDE.md on the host, restart the container (or re-run `init-rip-cage.sh`) to pick up changes.

### Credential Strategy

**Two categories of credentials:**

**1. Agent infrastructure** (needed for Claude Code itself to function):
- **Auth** (required — without this, the container cannot run Claude Code):
  - **Primary (local):** Mount OAuth files **read-write** from host — `~/.claude.json` and `~/.config/claude-code/auth.json`. Reuses existing host login, no extra setup. Read-write is required because Claude Code handles token refresh internally by writing back to these files (confirmed via CAAM research — external refresh endpoint is undocumented). This also keeps host tokens fresh.
  - **Alternative (VPS/headless):** `ANTHROPIC_API_KEY` env var via `--env-file` or `-e`. For environments where there's no browser-based OAuth login.
- `GH_TOKEN` — optional in bind mount mode (git push happens on host), required in clone mode (Phase 2) for git auth.
- **Future (Phase 3)**: [CAAM](https://github.com/Dicklesworthstone/coding_agent_account_manager) for multi-agent credential pooling — isolated profiles per container, automatic rotation on rate limits.

**2. Project credentials** (dev-only, primary secret protection strategy):
- Inject dev/test credentials via `--env-file .env.dev`. Database URLs point to local/dev instances. API keys are test-mode keys (e.g., Stripe `sk_test_...`). Nothing production enters the container.
- On VPS: credentials are for the disposable environment. Rotate after use if needed.
- The container boundary ensures even if dev credentials leak, the blast radius is limited to dev/test systems.
- No network firewall needed — agents need unrestricted network access (package registries, documentation, APIs). Dev credentials mean there's nothing valuable to exfiltrate.

### Port Forwarding

For frontend/UI work with hot reload:

```bash
rc up /path/to/frontend-project --port 3000
# or auto-detect from package.json / common frameworks
```

In devcontainer mode, VS Code handles port forwarding natively. In CLI mode, OrbStack handles it — containers are accessible at `localhost:<port>` on the host.

---

## Key Design Decisions

See [ADR-002](decisions/ADR-002-rip-cage-containers.md) for full rationale on each.

1. **OrbStack** — faster, lower memory, better Mac integration, buildx included
2. **One base image** — avoids per-project Dockerfile maintenance
3. **Persistent containers** — deps installed once, fast reconnect
4. **Path-based launch** — `rc up <path>`, no special worktree/repo flags
5. **Bind mount default, clone as flag** — local interactive is the common case
6. **Auto mode + hooks** — classifier handles most decisions, hooks hard-deny catastrophic commands, humans only see rare fallbacks
7. **Same image local and VPS** — Phase 2 portability is a config change, not a rebuild
8. **Dev credentials, not `.env` mounting** — never inject production secrets; dev creds are the primary protection
9. **Devcontainer compatibility** — same image works standalone or as VS Code devcontainer
10. **Beads in the image** — `bd` CLI + Dolt for issue tracking inside containers
11. **Image-based devcontainer, `rc init` scaffolding** — devcontainer.json references pre-built image, not Dockerfile path; `rc init` generates it per-project

---

## Phased Rollout

### Phase 1: Local flywheel (this design)

- Dockerfile + `init-rip-cage.sh` + safety stack (DCG, block-compound, auto mode)
- `rc` CLI: `build`, `init`, `up`, `down`, `ls`, `attach`, `destroy`, `test`
- `rc build` — build the `rip-cage:latest` image locally
- `rc init <path>` — scaffold `.devcontainer/devcontainer.json` (image-based, not Dockerfile-based)
- `rc up <path>` — CLI/tmux mode for headless use
- VS Code devcontainer as primary local UX (via `rc init`)
- OrbStack as runtime (standard Docker CLI)
- Beads (`bd` + Dolt) for issue tracking
- Dev credentials via `--env-file`, no `.env` mounting, never production
- `CLAUDE.md` mounted read-only for user context
- Bind mount only — **clone mode is Phase 2**

### Phase 2: VPS + Clone Mode

- Same image deployed to VPS (Contabo/OVH/Hetzner)
- VPS provisioning: ACFS as a reference for what tools to install and how. Evaluate what to adopt vs do ourselves when we get there.
- Clone mode for background tasks (`rc up --clone`)
- Git auth via `GH_TOKEN` environment variable
- SSH access + tmux for monitoring
- `rc up --remote vps1:<path>` for remote container management (VPS connection details in `~/.config/rc/hosts.toml`)

### Phase 3: Multi-Agent + Orchestration

- NTM-style tmux orchestration (multiple agents per container or per-container)
- Agent Mail for coordination
- Worktree-per-agent pattern for parallel work on same repo
- AA (Approval Agent) as additional flywheel tool inside containers
- MCP servers / plugins inside containers

---

## Phase 1 Capability Gaps

The containerized agent is **not identical** to the host agent. Known gaps in Phase 1:

| Capability | Host | Container | Impact |
|-----------|------|-----------|--------|
| Permission prompts | Many (approval monkey) | Rare (auto mode + classifier) | **This is the point** |
| MCP servers (meta-skill, etc.) | Yes | No | Loses specialized tools |
| Plugins (ast-grep, superpowers, etc.) | Yes | No | Loses structural search, skills |
| Auto-memory | Yes | No | Agent starts fresh each session |
| Beads task tracking | Yes | **Yes** (bd + Dolt in image) | Full issue tracking inside container |
| `restrict-sensitive-paths.sh` | Yes | No | Container boundary is the protection |
| Notification sounds | Yes | No | No `afplay` in Linux |

These gaps are acceptable because the primary value proposition is speed (minimal permission prompts), and the missing capabilities are convenience features, not correctness requirements. They're addressed incrementally in Phase 2-3.

---

## Competitive Landscape

Rip Cage exists in a growing ecosystem of containerized Claude Code solutions:

| Project | Isolation | Hooks Inside? | Auto Mode? | VPS Story |
|---------|-----------|--------------|------------|-----------|
| **Rip Cage** | Docker + hooks + auto mode | DCG + block-compound | Yes (primary) | Phase 2 |
| [ClaudeCage](https://github.com/PACHAKUTlQ/ClaudeCage) | Linux namespaces (Bubblewrap) | None | No | None |
| [ClaudeBox](https://github.com/RchGrav/claudebox) | Docker, 15+ profiles | None | No | None |
| [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) | MicroVMs (official) | None | No | None |
| [Trail of Bits devcontainer](https://github.com/trailofbits/claude-code-devcontainer) | DevContainer | None | No | None |
| [Spritz](https://github.com/textcortex/spritz) (TextCortex) | Kubernetes | None | No | Cloud |
| [ACFS](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup) | Full VPS | None | No (skip-perms) | **Native** |

**Rip Cage differentiators:**
1. **Hooks inside containers** — defense-in-depth with DCG and block-compound, not just container boundary
2. **Auto mode** — classifier-based safety instead of skip-permissions or full prompting
3. **Flywheel design** — tools compound over time (DCG, AA, pattern graduation), container is the housing
4. **Devcontainer + CLI** — VS Code primary UX locally, tmux for headless/VPS
5. **VPS portability** — same image, different launch mode

---

## Consequences

**What becomes easier:**
- Running agents with minimal permission fatigue (auto mode + container)
- Iterating on safety tools (container limits blast radius of mistakes)
- UI/frontend dev with hot reload inside containers (devcontainer + port forwarding)
- Moving agent workloads to VPS when needed
- Onboarding new projects — just open in devcontainer or `rc up <path>`

**What becomes harder:**
- Debugging host <-> container file permission issues
- Managing container runtime (OrbStack) as an additional dependency
- Keeping base image up to date with toolchain changes
- Auto mode classifier may occasionally block legitimate actions (tune allow list)

**Tradeoffs:**
- Container overhead (minimal with OrbStack, but not zero)
- Dev credential management requires knowing which vars the app needs
- One base image means some unused tools in every container
- Agent lacks MCP/plugin capabilities available on host
- Auto mode adds slight latency per action (classifier network round-trip)

---

## Known Limitations

- **Bind mount write-back** — `/workspace` IS the host filesystem. An agent could write to `.git/hooks/` or `.vscode/tasks.json`, which execute on the host. DCG blocks `git config` modifications inside the container. For higher-security use cases, clone mode (Phase 2) eliminates this vector entirely. Consider `core.hooksPath` pointing outside `/workspace` as an additional host-side mitigation.
- **No GPU access** — not relevant for current workloads but would matter for ML
- **Filesystem performance** — bind mounts on Mac have historically been slow; OrbStack is much better than Docker Desktop but not native speed
- **Single agent per container** — Phase 1 doesn't address multi-agent orchestration
- **No `.env` mounting** — dev credentials injected via `--env-file` instead; requires knowing which vars to set
- **Auto mode requires Sonnet 4.6 or Opus 4.6** — older models not supported
- **No network egress filtering** — intentional; agents need full network access
- **No Docker socket** — Docker-in-Docker not supported; containers run unprivileged with default capabilities
- **Beads local-only** — `bd dolt push/pull` fails inside containers (no SSH keys/aliases). Beads changes persist via bind mount and normal git commits.

---

## Open Questions

1. **Shell config inside container** — how much of the host's zsh/tmux config should be replicated? Minimal (just what agents need) or full (user can also work interactively)?

2. **Image update strategy** — rebuild and replace all containers? Or `rc update` that rebuilds image and recreates containers preserving volumes?

3. ~~**Beads Dolt sync**~~ — **Resolved: local-only in Phase 1.** Dolt remote uses SSH aliases/keys not available in containers. `bd create/close/list` work locally; `bd dolt push/pull` does not. If cross-container sync is needed later, use HTTPS remotes with `GH_TOKEN` or a beads HTTP sync endpoint.

---
<!-- Review findings (passes 1-5) removed after triage — folded into design above -->
