# ADR-002: Rip Cage — Containerized Agentic Development Flywheel

**Status:** Accepted
**Date:** 2026-03-25
**Design:** [Rip Cage Design](../2026-03-25-rip-cage-design.md)
**Related:** [ADR-001 Approval Agent](ADR-001-approval-agent-architecture.md), [ACFS](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup)

## Context

The AA (Approval Agent) project addresses the "approval monkey" problem by semantically evaluating commands. But there's a complementary approach: run agents inside containers where the blast radius is inherently limited. The container is the flywheel housing — it holds safety tools together and lets you be bolder with the tool stack inside. ACFS (Jeffrey Emanuel) proves this model works on throwaway Ubuntu VPSes. We want it locally on Mac too.

The ecosystem already has several containerized Claude Code solutions (ClaudeCage, ClaudeBox, Docker Sandboxes, Trail of Bits devcontainer) but none combine hooks-inside-containers, auto mode, and VPS portability.

## Decisions

### D1: OrbStack as container runtime on Mac

**Firmness: FIRM**

Use OrbStack for running containers on Mac. Includes `docker buildx` out of the box (needed for multi-arch builds in Phase 2).

**Rationale:** OrbStack is significantly faster and lighter than Docker Desktop. Better filesystem performance for bind mounts (critical for hot reload). Native Mac integration. Includes buildx plugin (Colima does not). The agentic dev community (including ACFS docs) increasingly recommends it.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **OrbStack** | Fast, low memory, great bind mount perf, buildx included | Commercial ($8/mo after trial) |
| Docker Desktop | Free tier, most documented | Slow, heavy, worse bind mount perf |
| Colima | Free, open-source | No buildx, less polished, fewer features |
| Lima | Free, very lightweight | More manual setup |
| Podman | Rootless, daemonless | Less Mac-native, fewer integrations |

**What would invalidate this:** OrbStack pricing becomes unreasonable. Apple ships native container support.

### D2: One base image for all projects

**Firmness: FLEXIBLE**

A single "rip-cage" Docker image with Python/uv, Bun/Node, git, tmux, Claude Code, beads (bd, built from Go source), DCG (pre-built binary), and hooks. No per-project Dockerfiles. 2-stage build: Go builder for bd → debian:bookworm runtime (~1.1 GB).

**Rationale:** Projects are mostly Python and/or JS/TS. A universal image avoids maintaining N Dockerfiles and means `rc up <path>` works for any project without setup. The image is ~2-3GB but built once. Project-specific deps (node_modules, .venv) are installed inside the persistent container on first run. Bun is included as primary JS runtime (faster than Node for Claude Code, from ClaudeCage's approach). Beads (bd + Dolt) enables issue tracking inside containers.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **One base image** | Zero per-project setup, simple | Larger image, some unused tools |
| Per-project Dockerfile | Minimal image per project | Maintenance burden, slower onboarding |
| Layered images (base + project) | Best of both | Docker layer complexity, rebuild coordination |
| devcontainer.json per project | Industry standard | Overkill for current needs, unfamiliar |

**What would invalidate this:** Projects require wildly different system deps (e.g., CUDA, system libraries). Image size becomes a problem on VPS with limited disk.

### D3: Persistent containers with manual lifecycle

**Firmness: FIRM**

Containers are persistent (one per working directory). Started with `rc up`, stopped with `rc down`, destroyed with `rc destroy`. Deps survive across sessions.

**Rationale:** ACFS uses persistent tmux sessions on a persistent VPS — same principle. Cold-starting a container with `npm install` or `uv sync` every time is too slow. Persistent containers mean deps are installed once. If state gets messy, `rc destroy` + `rc up` is fast (seconds, not minutes).

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Persistent containers** | Fast reconnect, deps cached | State accumulates |
| Ephemeral per task | Clean slate every time | Cold start cost (deps) |
| Warm pool with volume caching | Clean + fast | More infrastructure to manage |

**What would invalidate this:** Containers frequently get into bad state requiring destruction. Volume caching turns out to be simple enough to implement.

### D4: Path-based launch, no special flags for worktrees

**Firmness: FIRM**

`rc up <path>` mounts whatever directory you point it at. No `--worktree`, `--repo`, or `--branch` flags. The container doesn't care if it's a repo root, a worktree, or any directory.

**Rationale:** Emerged from brainstorming — worktrees, repo roots, and arbitrary directories are all just paths. The container mounts a path at `/workspace`. Adding worktree-awareness would be unnecessary complexity. Users create worktrees on the host (or inside the container) as they normally would.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Path-based, no flags** | Simplest, most flexible | No worktree-aware features |
| `--worktree` flag | Explicit intent | Unnecessary — it's just a path |
| Container-per-worktree (automatic) | Maximum isolation | Over-engineered for Phase 1 |

**What would invalidate this:** Need for automatic worktree creation + container pairing for parallel agents. But that's Phase 3.

### D5: Auto mode with phased hooks

**Firmness: FIRM**

Agents run in Claude Code's **auto mode** (`--permission-mode auto`) inside containers. Auto mode uses a background classifier (Sonnet 4.6) to review actions autonomously, falling back to human prompts only when the classifier blocks repeatedly (3x in a row or 20x total).

Safety comes from multiple layers: container isolation (hard boundary), hooks (DCG + block-compound return `"deny"`), auto mode classifier (reviews everything else), and human fallback (rare).

Unlike `--dangerously-skip-permissions`, auto mode **respects allow/deny lists** (checked before the classifier) and doesn't bypass the permission system — it replaces human judgment with classifier judgment for most decisions.

Phase 1 hooks: DCG (pre-built release binary), `block-compound-commands.sh`, and `bd prime` (beads, on both SessionStart and PreCompact). Host-specific hooks (`restrict-sensitive-paths.sh`, `allow-directory-commands.sh`, `notify.sh`, `block-harvest.sh`) are excluded — they depend on macOS binaries, host paths, or are redundant with container isolation.

**Rationale:** Auto mode is Claude Code's officially recommended alternative to `--dangerously-skip-permissions`. It provides meaningful safety (classifier reviews each action, sees CLAUDE.md context, does NOT see tool results so can't be influenced by malicious file content) without constant human prompts. The container makes this even safer — if the classifier makes a mistake, the blast radius is limited to a container with dev credentials.

ACFS uses `--dangerously-skip-permissions` because it predates auto mode and runs on throwaway VPSes where the risk tolerance is higher. For local Mac containers, auto mode is the better fit — you get 99%+ autonomous operation with a real safety net.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Auto mode + phased hooks** | Classifier-based safety, respects allow/deny, human fallback | Requires Sonnet/Opus 4.6, slight latency per action |
| `--dangerously-skip-permissions` + hooks | Zero latency, zero prompts | Bypasses allow/deny entirely, no classifier safety net |
| Normal permissions + AA | Maximum human control | Still an approval monkey (AA is Phase 2+) |
| Normal permissions + expanded allow list | No new tools needed | Can't safely allow opaque commands |

**Allow list policy (amended 2026-03-26):** The allow list must be narrow — only commands with no security-relevant side effects. Commands that read arbitrary files (`cat`, `grep`, `find`) or that can embed execution (`find -exec`) must go through the classifier, not the allow list. The allow list is a fast path for known-safe operations (build tools, version checks, git read commands), not a convenience shortcut. Review found `cat:*`, `find:*`, `grep:*` auto-approving auth file reads and arbitrary command execution — removed.

**What would invalidate this:** Auto mode classifier causes too many false positives (blocking legitimate work). In that case, tune allow list to pre-approve known-safe patterns, or fall back to skip-permissions for specific containers.

### D6: Bind mount default, clone mode as flag

**Firmness: FLEXIBLE**

Default: bind mount host path into container (interactive, hot reload). Flag: `--clone` for git clone inside container (VPS, background tasks).

**Rationale:** Local interactive work is the Phase 1 primary use case. Bind mount gives immediate hot reload and bidirectional file access. Clone mode is for Phase 2 VPS where the host has no repo — agent clones, works, pushes a branch.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Bind mount default, clone flag** | Matches use cases | Two modes to maintain |
| Always bind mount | Simpler | Doesn't work on VPS without the repo |
| Always clone | Maximum isolation | No hot reload, no bidirectional access |
| rsync on change | Compromise | Complex, fragile, latency |

**What would invalidate this:** Bind mount performance on Mac is unacceptable even with OrbStack. Clone mode needed locally more often than expected.

### D7: Same image for local and VPS

**Firmness: FIRM**

The same Docker image runs on Mac (via OrbStack) and on VPS (via Docker/Podman). Phase 2 VPS portability is a deployment change, not an image change.

**Rationale:** This is cheap foresight. The image is Linux-based regardless (Docker on Mac runs Linux containers). VPS is also Linux. Same image, same hooks, same tools. The only difference is how the container is launched (bind mount vs clone) and where it runs.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Same image everywhere** | Zero porting effort, consistent behavior | Must work on both arm64 (Mac) and amd64 (most VPS) |
| Mac-specific + VPS-specific images | Optimized per platform | Two images to maintain, divergence risk |

**What would invalidate this:** arm64/amd64 differences cause significant issues. VPS needs tools that don't make sense locally (monitoring, etc.).

### D8: Dev credentials only, not `.env` mounting

**Firmness: FIRM**

Do not mount `.env` files into containers. Inject **dev/test credentials only** via `docker run -e` or `--env-file`. Never inject production credentials into local containers.

**Rationale:** Dev-only credentials are the primary secret protection strategy — simpler and more robust than network firewalls or file-access hooks. If dev credentials leak (via agent exfiltration or any other vector), the damage is limited to dev/test systems. This also avoids two independent holes in `.env` file protection: (1) `restrict-sensitive-paths.sh` uses `"ask"` which can be auto-approved, and (2) `cat .env` via Bash bypasses Read/Edit/Write tool matchers. Rather than patching both holes, the architecturally clean solution is: no production secrets in the container, period.

On VPS (Phase 2), credentials are for the disposable environment. Rotate after use if the VPS handled sensitive data.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Dev credentials via `--env-file`** | No production secrets at risk, architecturally clean | Must maintain separate `.env.dev` files |
| Mount `.env` + hook protection | `.env` file "just works" for apps | Two independent bypass paths, incomplete protection |
| Network firewall (egress filtering) | Blocks exfiltration even with real creds | Too restrictive — agents need network for packages, docs, APIs |
| Docker secrets | Industry standard for secrets | Overkill for local dev, complex setup |

**What would invalidate this:** Projects where dev credentials don't exist or can't replicate production behavior adequately. In that case, accept the risk of injecting production creds into a container with limited blast radius.

### D9: Devcontainer as primary local UX

**Firmness: FLEXIBLE**

The Dockerfile is structured to work as both a standalone container (via `rc` CLI) and a VS Code devcontainer. Devcontainer is the primary local UX; CLI mode is for headless/VPS use.

**Rationale:** Auto mode occasionally falls back to human prompts (when the classifier blocks repeatedly). In VS Code, these prompts appear naturally in the terminal — the user can respond immediately. In tmux, the user must `rc attach` to see/respond. VS Code also provides extensions, port forwarding, and file editing natively. Anthropic's own [Claude Code devcontainer](https://code.claude.com/docs/en/devcontainer) validates this pattern — same Dockerfile structure (non-root user, build args, postStartCommand, named volumes).

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Devcontainer primary + CLI fallback** | Best UX for local, prompts visible, VS Code integration | Requires VS Code; two paths to maintain |
| CLI only (tmux) | Simpler, one path | Must manually attach to see auto mode fallback prompts |
| Devcontainer only | Simplest local story | No headless/VPS story |

**What would invalidate this:** VS Code becomes too heavyweight or devcontainer support regresses. CLI-only workflows prove sufficient for all use cases.

### D10: Beads (bd + Dolt) in the base image

**Firmness: FLEXIBLE**

The base image includes the `bd` CLI and Dolt database engine, enabling beads-based issue tracking inside containers. `.beads/` data comes with the project via bind mount (local) or git clone (VPS).

**Rationale:** Beads is the standard issue tracking tool for this workflow. Without it in the container, agents can't create/close/track issues. The `bd prime` SessionStart hook loads beads context. Dolt is already a dependency (beads backend) and adds ~103MB to the image — acceptable for the capability it provides.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **bd + Dolt in image** | Full issue tracking, consistent with host workflow | Adds ~103MB, Dolt is a large binary |
| Exclude beads (Phase 1) | Smaller image | Agents can't track issues; track on host instead |
| bd without Dolt (read-only) | Smaller | Can't create/close issues, limited utility |

**What would invalidate this:** Beads replaced by a different issue tracking system. Dolt size becomes a problem on constrained VPS instances.

### D11: Deny `.git/hooks` writes in bind-mount mode

**Firmness: FIRM**

**Added:** 2026-03-26 (review finding)

In bind-mount mode, `/workspace` IS the host filesystem. An agent writing to `.git/hooks/` creates scripts that execute on the host with full privileges when the user runs git commands — a container escape via the project's own git hooks. Settings.json denies `Write(.git/hooks/*)` and `Edit(.git/hooks/*)`.

**Rationale:** The design doc's Known Limitations section identified this vector. The Write/Edit tools have no PreToolUse hooks in the container (container boundary is the protection for most paths), but `.git/hooks/` is special — it bridges back to the host via git's hook execution. A deny rule is low-cost defense-in-depth. Clone mode (Phase 2) eliminates this vector entirely since the container filesystem is isolated.

**What would invalidate this:** Legitimate need for agents to modify git hooks inside the container (e.g., setting up pre-commit linting). In that case, use `core.hooksPath` pointing to a container-only directory instead.

### D12: Scoped sudo, not blanket NOPASSWD

**Firmness: FIRM**

**Added:** 2026-03-26 (review finding)

The agent user has sudo access scoped to: `apt-get`, `dpkg`, `npm install -g`, `chown`. Blanket `NOPASSWD:ALL` is replaced with command-specific allowances.

**Rationale:** The agent needs sudo for installing project dependencies (`apt-get install`, `npm install -g`). But blanket sudo lets the agent disable its own safety stack (`sudo rm /usr/local/bin/dcg`, `sudo chmod -x block-compound-commands.sh`). Scoping sudo to dependency installation commands preserves the needed capability while preventing safety-stack tampering. The safety stack is the container's internal defense-in-depth layer — it should not be user-modifiable at runtime.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Scoped sudo** | Prevents safety tampering, preserves dep install | Must enumerate allowed commands |
| Blanket NOPASSWD:ALL | Maximum flexibility | Agent can disable all safety hooks |
| No sudo at all | Maximum safety | Can't install system packages |
| `--security-opt=no-new-privileges` | Kernel-level enforcement | Breaks all sudo, too restrictive |

**What would invalidate this:** Agent needs sudo for commands not in the allow list (e.g., `systemctl`, custom build tools). Add them to the sudoers file as needed.

### D13: Image-based devcontainer with `rc init` scaffolding

**Firmness: FIRM**

**Added:** 2026-03-26 (brainstorming session)

The generated `devcontainer.json` references a pre-built image (`rip-cage:latest`) rather than a Dockerfile path. `rc init <path>` scaffolds `.devcontainer/devcontainer.json` into any target project. `rc build` builds the image locally.

**Rationale:** Rip-cage is intended to be a distributable tool (eventually `brew install rip-cage` or similar). Users won't have the source repo cloned, so devcontainer.json cannot reference a Dockerfile path — it must reference an image. Using a pre-built image also means:
- No per-project Dockerfile paths to manage
- `rc init` generates identical config regardless of where rip-cage is installed
- Migration from local image (`rip-cage:latest`) to registry image (`ghcr.io/jsnyde0/rip-cage:latest`) is a one-line change in `rc`'s template
- Works on rip-cage's own repo too (build the image first, then `rc init .`)

This merges the previous Phase 1a (devcontainer) and Phase 1b (`rc` CLI) into a single Phase 1, since `rc` is now the entry point for both paths: `rc init` for devcontainer setup, `rc up` for CLI/tmux mode.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Pre-built image + `rc init`** | Distributable, no source dependency, simple template | Must build image before first use |
| Dockerfile path in devcontainer.json | No pre-build step | Breaks without source repo, path management headache |
| Copy Dockerfile into each project | Self-contained per project | N copies to keep in sync, defeats "one image" principle |
| No `rc init`, manual setup | Less code | Poor UX, error-prone, blocks adoption |

**What would invalidate this:** Per-project Dockerfile customization becomes necessary (e.g., projects need different system deps baked into the image). In that case, consider a layered image approach (project Dockerfile `FROM rip-cage:latest`).

## Related

- [Rip Cage Design](../2026-03-25-rip-cage-design.md) — full design document
- [ADR-001 Approval Agent](ADR-001-approval-agent-architecture.md) — complementary approach (semantic evaluation); future flywheel tool
- [AA Design v2](../2026-03-23-approval-agent-design-v2.md) — the guardrails that may run inside containers in Phase 3
- [ACFS](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup) — Jeffrey Emanuel's flywheel, inspiration for VPS-based approach
- [Claude Code Auto Mode](https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode) — official docs on the permission mode we use
- [Claude Code Devcontainer](https://code.claude.com/docs/en/devcontainer) — Anthropic's reference devcontainer setup
- [CAAM](https://github.com/Dicklesworthstone/coding_agent_account_manager) — credential manager for multi-account Claude Code; Phase 3 reference for multi-agent credential pooling
- [Review Fixes Design](../2026-03-26-rip-cage-review-fixes.md) — fixes from 3-pass competitive review
- **Competitive landscape:** [ClaudeCage](https://github.com/PACHAKUTlQ/ClaudeCage), [ClaudeBox](https://github.com/RchGrav/claudebox), [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/), [Trail of Bits devcontainer](https://github.com/trailofbits/claude-code-devcontainer), [Spritz](https://github.com/textcortex/spritz)
