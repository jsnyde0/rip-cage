# ADR-002: Rip Cage — Containerized Agentic Development Flywheel

**Status:** Accepted
**Date:** 2026-03-25
**Design:** [Rip Cage Design](../2026-03-25-rip-cage-design.md)
**Related:** [ADR-001 Approval Agent](ADR-001-approval-agent-architecture.md), [ACFS](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup)

## Context

The AA (Approval Agent) project addresses the "approval monkey" problem by semantically evaluating commands. But there's a complementary approach: run agents inside containers where the blast radius is inherently limited. The container is the flywheel housing — it holds safety tools together and lets you be bolder with the tool stack inside. ACFS (Jeffrey Emanuel) proves this model works on throwaway Ubuntu VPSes. We want it locally on Mac too.

The ecosystem already has several containerized Claude Code solutions (ClaudeCage, ClaudeBox, Docker Sandboxes, Trail of Bits devcontainer) but none combine hooks-inside-containers, fully autonomous execution, and VPS portability.

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

### D4: Path-based launch with transparent worktree handling

**Firmness: FIRM**

**Amended 2026-04-02:** Added transparent worktree git mount. No user-facing flags — `rc up` detects worktrees and fixes git paths automatically.

`rc up <path>` mounts whatever directory you point it at. No `--worktree`, `--repo`, or `--branch` flags. When the target is a git worktree (`.git` is a file, not a directory), `rc up` transparently mounts the main repo's `.git/` directory and overrides the `.git` file with container-correct paths. Git works inside the container without user intervention.

**Worktree mount strategy (four mounts):**
1. Detect: `.git` is a file containing `gitdir: <host-path>` with `/worktrees/` in the path (distinguishes from submodules which use `/modules/`)
2. Resolve: relative gitdir paths to absolute (Git 2.13+ allows relative); derive main `.git/` directory
3. Validate: main `.git/` path against `RC_ALLOWED_ROOTS` (ADR-003 D3)
4. Mount: main `.git/` at `/workspace/.git-main:delegated` (writable), corrected `.git` file at `/workspace/.git:ro`, hooks at `/workspace/.git-main/hooks:ro` (read-only sub-mount prevents container escape — see D11)
5. Report: `--output json` includes `worktree` metadata; `--dry-run` reports detection results
6. Cleanup: temp `.git` file removed on `rc destroy`

The corrected `.git` file contains `gitdir: /workspace/.git-main/worktrees/<name>`, which chains to `commondir: ../..` → `/workspace/.git-main/` for objects, refs, and config. The hooks `:ro` sub-mount is critical: under `bypassPermissions` (D5), deny rules are not enforced, so only a physical read-only mount prevents agents from writing host-executable hooks.

See: [Worktree Git Mount Design](../2026-04-02-worktree-git-mount-design.md)

**Rationale:** Emerged from brainstorming — worktrees, repo roots, and arbitrary directories are all just paths. The original design assumed git "just works" with a bind mount, but worktrees have host-absolute paths in their `.git` file that break inside containers. The fix is transparent: `rc up` detects and handles worktrees without any user-facing flags. The pattern mirrors the beads redirect fix (detect pointer file, resolve, validate, mount).

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Path-based, transparent worktree fix** | No flags, git just works, same UX for repos and worktrees | Slightly more complex mount setup |
| `--worktree` flag | Explicit intent | Unnecessary — detection is reliable |
| `GIT_DIR` / `GIT_WORK_TREE` env vars | No file manipulation | Global, breaks multi-repo work |
| Rewrite `.git` file in container | Simple | Modifies host file via bind mount |
| Mount at host-absolute path | Zero path rewriting | Leaks host structure, fragile |

**What would invalidate this:** Git changes worktree `.git` file format. Or submodules (which also use `.git` files) need different handling — test when submodule support is needed.

### D5: Bypass permissions with phased hooks

**Firmness: FIRM**

**Amended 2026-04-02:** Changed from auto mode to `bypassPermissions` after e2e validation showed auto mode's classifier prompts defeat the purpose of containerized autonomous execution.

Agents run with `--dangerously-skip-permissions` (`"defaultMode": "bypassPermissions"` in settings.json) inside containers. The permission system is entirely bypassed. Safety comes from the container boundary (hard limit on blast radius) and PreToolUse hooks (DCG + compound command blocker), which fire regardless of permission mode.

The key insight: **the container is the safety boundary, not the classifier.** If auto mode still requires human approval for edits, you might as well run auto mode on the host — the container adds no value. The whole point of rip-cage is fully autonomous background execution.

Hooks provide two types of in-container safety:
- **DCG** — blocks destructive commands, returns `"deny"` with explanation. Agent self-corrects.
- **Compound command blocker** — rejects `&&`/`;`/`||`, returns `"deny"` with instructions to split. Agent self-corrects.

Both are "block and redirect" hooks — they teach the agent to fix its approach without requiring human intervention. This is the correct pattern for autonomous containers.

Phase 1 hooks: DCG (pre-built release binary), `block-compound-commands.sh`, and `bd prime` (beads, on both SessionStart and PreCompact). Host-specific hooks (`restrict-sensitive-paths.sh`, `allow-directory-commands.sh`, `notify.sh`, `block-harvest.sh`) are excluded — they depend on macOS binaries, host paths, or are redundant with container isolation.

**Rationale:** E2e validation (2026-04-02) confirmed that auto mode's classifier prompts for file edits and other operations, requiring human presence at the terminal. This contradicts rip-cage's core value proposition: launch an agent, walk away, come back to results. `bypassPermissions` eliminates all permission prompts while hooks continue to provide guardrails against destructive commands and compound command abuse.

Allow/deny lists in settings.json are bypassed in this mode but retained as documentation of intent. They would re-activate if the devcontainer path (VS Code) uses auto mode instead.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **`bypassPermissions` + hooks** | Zero prompts, hooks still enforce safety, fully autonomous | No classifier safety net (container is the net) |
| Auto mode + phased hooks | Classifier reviews actions | Still prompts humans — defeats containerized autonomy |
| Normal permissions + AA | Maximum human control | Still an approval monkey (AA is Phase 2+) |
| Normal permissions + expanded allow list | No new tools needed | Can't safely allow opaque commands |

**What would invalidate this:** Hooks stop firing under `bypassPermissions` (currently confirmed they do fire). Or container isolation proves insufficient and an additional in-container safety layer is needed beyond hooks.

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

**Rationale:** VS Code provides extensions, port forwarding, and file editing natively. Anthropic's own [Claude Code devcontainer](https://code.claude.com/docs/en/devcontainer) validates this pattern — same Dockerfile structure (non-root user, build args, postStartCommand, named volumes). With `bypassPermissions` mode (D5, amended 2026-04-02), permission prompts are eliminated entirely, so the original rationale about VS Code making prompts easier to respond to no longer applies. Devcontainer value is now purely about VS Code's development UX, not prompt handling.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Devcontainer primary + CLI fallback** | Best UX for local, prompts visible, VS Code integration | Requires VS Code; two paths to maintain |
| CLI only (tmux) | Simpler, one path | Must manually attach to see auto mode fallback prompts |
| Devcontainer only | Simplest local story | No headless/VPS story |

**What would invalidate this:** VS Code becomes too heavyweight or devcontainer support regresses. CLI-only workflows prove sufficient for all use cases.

### D10: Beads (bd) in the base image

**Firmness: FLEXIBLE**

**Amended 2026-03-27:** Container bd connects to host's Dolt server via `host.docker.internal` (ADR-004 D1). Dolt is kept in the image as a required dependency for bd v0.62.0+.

The base image includes `bd` CLI and Dolt, enabling beads-based issue tracking inside containers. `.beads/` data comes with the project via bind mount (local) or git clone (VPS). The container's bd connects to the host's Dolt server (set via `BEADS_DOLT_SERVER_MODE=1` and `BEADS_DOLT_SERVER_HOST=host.docker.internal`), avoiding database lock conflicts between host and container.

**Rationale:** Beads is the standard issue tracking tool for this workflow. Without it in the container, agents can't create/close/track issues. The `bd prime` SessionStart hook loads beads context. Dolt is kept because bd v0.62.0+ requires it as a dependency; the container delegates actual Dolt serving to the host to avoid lock conflicts.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **bd + Dolt, connecting to host server** | Full bd functionality, no lock conflicts | Requires host Dolt server running |
| bd without Dolt (BD_NO_DB=true) | Smaller image (~103MB savings) | Incompatible with bd v0.62.0+ |
| Exclude beads entirely | Smaller image | Agents can't track issues |

**What would invalidate this:** Beads replaced by a different issue tracking system. bd publishes pre-built binaries (remove Go builder stage).

### D11: Deny `.git/hooks` writes in bind-mount mode

**Firmness: FIRM**

**Added:** 2026-03-26 (review finding)
**Amended 2026-04-02:** Under `bypassPermissions` (D5), deny rules are documentation-only. For worktree containers, `.git-main/hooks/` is protected by a read-only sub-mount (D4). The deny rules in settings.json remain as documentation of intent.
**Amended 2026-04-09:** Extended read-only sub-mount to bind-mount mode. In-container testing confirmed that Python `open()` via Bash tool bypasses settings.json deny rules — physical mount enforcement is required for both paths. See [design doc](../2026-04-09-git-hooks-ro-bind-mount-design.md).

In bind-mount mode, `/workspace` IS the host filesystem. An agent writing to `.git/hooks/` creates scripts that execute on the host with full privileges when the user runs git commands — a container escape via the project's own git hooks. Settings.json denies `Write(.git/hooks/*)` and `Edit(.git/hooks/*)`.

**Both bind-mount and worktree modes now use read-only sub-mounts for physical enforcement:**

- **Bind-mount mode:** `-v ${path}/.git/hooks:/workspace/.git/hooks:ro` — added after the workspace mount. Only applied when `${path}/.git/hooks` exists (i.e., the project is a git repo). The devcontainer.json template includes an equivalent mount entry.
- **Worktree mode:** `-v .../hooks:/workspace/.git-main/hooks:ro` — unchanged from D4 amendment.

Docker processes sub-mounts after parent mounts, so the `:ro` overlay on hooks physically prevents modification regardless of permission mode, Python filesystem access, or any other code path. Note: this enforces the *default* hooks path only — `core.hooksPath` redirect is an accepted risk (see design doc).

**Rationale:** The design doc's Known Limitations section identified this vector. The Write/Edit tools have no PreToolUse hooks in the container (container boundary is the protection for most paths), but `.git/hooks/` is special — it bridges back to the host via git's hook execution. Under `bypassPermissions` mode (D5), deny rules are not enforced by the permission system — they serve as documentation of intent only. The read-only sub-mount is the enforcement mechanism for both paths. Clone mode (Phase 2) eliminates this vector entirely since the container filesystem is isolated.

**Accepted risks (container-as-boundary):** In-container testing (2026-04-09) confirmed these vectors are possible but accepted under D5's container-as-boundary principle: (1) command substitution (`$(...)`, backticks), (2) Python `os.system()`/`subprocess` for non-destructive commands, (3) reading container-local files like `/etc/passwd`, (4) `core.hooksPath` redirect via `.git/config` — a multi-step container escape that cannot be blocked without making `.git/config` read-only (which breaks git operations). The container IS the safety boundary, not the in-container classifier. DCG still catches known-destructive patterns (e.g., `rm -rf`) even inside Python strings via content scanning.

**What would invalidate this:** Legitimate need for agents to modify git hooks inside the container (e.g., setting up pre-commit linting). In that case, use `core.hooksPath` pointing to a container-only directory instead.

### D12: Scoped sudo, not blanket NOPASSWD

**Firmness: FIRM**

**Added:** 2026-03-26 (review finding)

The agent user has sudo access scoped to: `apt-get`, `dpkg`, `chown`. Blanket `NOPASSWD:ALL` is replaced with command-specific allowances.

**Rationale:** The agent needs sudo for installing system packages (`apt-get install`) and fixing bind-mount ownership (`chown`). But blanket sudo lets the agent disable its own safety stack (`sudo rm /usr/local/bin/dcg`, `sudo chmod -x block-compound-commands.sh`). Scoping sudo to specific commands preserves the needed capability while preventing safety-stack tampering. The safety stack is the container's internal defense-in-depth layer — it should not be user-modifiable at runtime.

**Amendment (2026-03-27):** `npm install -g` removed from sudoers. npm lifecycle scripts (`postinstall`) run as root, allowing a malicious package to tamper with the safety stack — the exact vector D12 exists to prevent. Global npm packages should be pre-installed in the Dockerfile. The agent can still `npm install` locally (no sudo) or use `npx`.

**Amendment (2026-03-27):** `chown` scoped from wildcard (`chown *`) to exact paths: `/home/agent/.claude` and `/home/agent/.claude-state`. Pre-created directories in Dockerfile reduce chown necessity; exact-path sudoers serves as fallback when Docker overrides ownership at mount time. Wildcard `chown *` allowed argument-appending attacks (e.g., `sudo chown agent:agent /home/agent/.claude /usr/local/bin/dcg`). Symlink substitution risk acknowledged for Phase 1 — mitigated by `-L` check in init-rip-cage.sh.

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
- Migration from local image (`rip-cage:latest`) to registry image (`ghcr.io/youruser/rip-cage:latest`) is a one-line change in `rc`'s template
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

### D14: Container self-detection in `rc`

**Firmness: FIRM**

**Added:** 2026-03-27 (manual testing)

The `rc` script checks for `/.dockerenv` at startup and exits with a helpful message if running inside a container. This prevents confusing errors when the bind-mounted workspace includes `rc` and a user (or agent) tries to run it inside the container.

**Rationale:** `rc` calls Docker CLI commands to manage containers — it's inherently a host tool. Inside a container, Docker is not installed, so every `rc` command fails with `docker: command not found`. The `/.dockerenv` check is a Docker standard (not rip-cage-specific), so it catches the error regardless of which container the script ends up in.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **`/.dockerenv` check** | Docker standard, catches any container | Could false-positive in non-rip-cage containers |
| Check `rc.source.path` label | Rip-cage-specific | Requires Docker CLI inside container (the problem we're solving) |
| `command -v docker` check | Direct capability test | Fails differently if Docker is installed but broken |

**What would invalidate this:** Need to run `rc` inside a container (e.g., nested containers, Docker-in-Docker). In that case, install Docker CLI in the image and remove this guard.

### D15: Auto-select single container for name-required commands

**Firmness: FLEXIBLE**

**Added:** 2026-03-27 (manual testing)

Commands that require a container name (`attach`, `down`, `destroy`, `test`) auto-select when exactly one rip-cage container exists. When zero or multiple exist, they error with a list.

**Rationale:** The common case during development is a single container. Requiring `rc ls` → copy name → `rc test <name>` for every operation is tedious. Auto-select removes this friction without ambiguity risk (multiple containers still require explicit selection). Explicit names still work and are recommended for scripts/orchestrators.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Auto-select single** | Zero friction in common case, safe | Subtle behavior change |
| Always require name | Explicit, predictable | Tedious for single-container use |
| Fuzzy match / partial names | Flexible | Ambiguous, error-prone |
| `rc default <name>` | Explicit default | Extra state to manage |

**What would invalidate this:** Users frequently run multiple containers and find the auto-select confusing. In that case, revert to always requiring a name.

### D16: TUI rendering — locale, tmux config, synchronized output

**Firmness: FLEXIBLE**

**Added:** 2026-03-27 (manual testing)

The container ships with UTF-8 locale (`LANG=C.UTF-8`), `TERM=xterm-256color`, and a `tmux.conf` that enables true color, UTF-8 overrides, and synchronized output (DEC Mode 2026). This makes Claude Code's TUI render correctly inside tmux in the container.

**Rationale:** Claude Code's TUI uses box-drawing characters, 24-bit color, and emits 4,000-6,700 scroll events/sec during streaming. Without proper terminal settings, the TUI renders as garbled text with severe flickering. The fixes are: (1) UTF-8 locale so Unicode renders correctly, (2) `tmux-256color` terminal type so tmux advertises correct capabilities, (3) RGB terminal feature for true color passthrough, (4) synchronized output so tmux batches rapid scroll events into atomic redraws.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **tmux.conf + locale in image** | Works out of the box, no user config | Opinionated tmux config |
| Document manual setup | No image changes | Poor UX, users won't do it |
| Replace tmux with zellij | Better modern TUI support | Less mature, not yet supported by Claude Code |
| Build tmux from source | Full sync support guaranteed | Adds build complexity, larger image |

**What would invalidate this:** Claude Code stops relying on DEC 2026 for flicker-free rendering (e.g., ships its own frame batching). Or Claude Code ships a built-in terminal multiplexer, making tmux unnecessary.

### D17: Mount host skills and commands read-only

**Firmness: FLEXIBLE**

**Added:** 2026-04-13 | **Revised:** 2026-04-14

Mount `~/.claude/skills/` and `~/.claude/commands/` from the host into the
container read-only. This gives the agent inside the container access to the
same Claude Code skills and slash commands as the host user.

**Mount path:** `rc` mounts to `/home/agent/.rc-context/skills` and
`/home/agent/.rc-context/commands` (the `.rc-context/` staging pattern used
for all host context files). `init-rip-cage.sh` symlinks these to
`~/.claude/skills` and `~/.claude/commands` so Claude Code finds them at the
expected path. Dockerfile pre-creates `~/.claude/` with agent ownership.
The `:ro` flag is invariant.

**Symlink handling:** Skills that are symlinks on the host (e.g., pointing to
`~/code/mapular/platform/skills/send-it/`) will appear as broken symlinks inside
the container. `skill-server.py` (D18) handles this gracefully at read time
(skips broken symlinks with a stderr log). Full symlink resolution at mount time
is a follow-on improvement.

**Rationale:** Skills and commands are user-authored instruction sets (markdown
files, scripts). Without this mount the agent sees an unknown skill error.
The `:ro` flag preserves the safety-stack model: the container can execute
skill logic but cannot modify the host's skill definitions.

**Security posture:** Skills can contain arbitrary instruction text and may
reference shell scripts. However, the mount is read-only, user-authored (same
trust level as CLAUDE.md), and the agent already has full workspace access.
This is distinct from D8 (`.env` mounting refused) because `.env` files contain
secrets with external blast radius; skills contain agent instructions with no
new secret exposure.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Read-only bind mount (direct or via .rc-context)** | No secret exposure, live updates from host | Skills with host-absolute paths (e.g. Python venvs) won't work in container |
| Copy into image at build time | No runtime mount needed | Skills change frequently, would require constant rebuilds |
| Mount `~/.claude/` wholesale | Simpler single mount | Conflicts with init script managing settings.json, projects/, sessions/ |
| No skills support | Simplest | Agent loses access to all user skills |

**What would invalidate this:** Skills contain secrets or sensitive data that
should not be exposed inside the container. In that case, introduce a skills
allowlist in `rc.conf`.

### D18: Skill discovery mechanism in containers

**Firmness: FLEXIBLE**

**Added:** 2026-04-14
**Design:** [Skills in Containers](../../history/2026-04-14-skills-in-containers-design.md)

Skills mounted on disk are not automatically discovered by Claude Code — the
`ms` (meta-skill) MCP server is the required discovery mechanism (confirmed by
Spike 1, see design doc). `ms` is macOS arm64 only and not publicly released as
of 2026-04-14 — it cannot be installed in the container image.

**Decision:** Ship a minimal Python MCP server (`skill-server.py`) in the image
— stdlib only, no pip dependencies. Python3 is already pre-installed. Implements
`list` and `load`/`show` (the tools Claude Code needs), with scan-once startup
caching. Stubs all other tools as empty-success. Registered in `settings.json`
as `mcpServers.meta-skill` with `command: python3`.

**Implementation notes:**
- Stderr for all debug logging (stdout is the protocol channel)
- ANSI sanitization for SKILL.md content in `show`/`load` responses (escape codes corrupt JSON)
- Scan-once startup caching (build in-memory index, serve from memory)
- Broken symlink detection via `path.is_file()` — `Path.resolve()` does not raise on Python 3.11
- Crash resilience: top-level try/except in main loop, log and continue; exit only on stdin EOF/SIGTERM
- JSON parse errors on stdin are logged and skipped, never crash the server
- Wire format matches `ms` exactly (response format probed 2026-04-14; see design doc §"ms Wire Format")

**settings.json merge gap:** The init-time overwrite means project-level `mcpServers`
entries are lost. Pre-existing limitation, out of scope for this decision.

**Upgrade path:** When `ms` publishes Linux binaries, add the binary to the
Dockerfile and swap `command`/`args` in `settings.json` (`python3
skill-server.py` → `/usr/local/bin/ms mcp serve`). The server name stays
identical. Scope: one Dockerfile addition plus two settings.json field changes.

**Rationale:** `ms` adds semantic search, ranking, and quality scoring on top
of basic skill file loading. These UX features have no value for agents inside
containers that invoke skills by exact name. A minimal implementation is
sufficient and forward-compatible.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Minimal Python MCP server** | Self-contained, no host dependency, clean upgrade path | Maintains a skill loading shim until `ms` goes public |
| Native filesystem discovery | Zero new components | Confirmed not to work (Spike 1 failed — Claude Code requires MCP) |
| Skills-to-Commands conversion | Zero MCP infrastructure; commands work via native discovery | Loses progressive disclosure; context bloat with 50+ skills; no `/skill-name` invocation |
| Host MCP forwarding (`--mcp-config`) | No in-container server | Couples to running host process; breaks CI/headless |
| Mount `ms` binary from host | Works immediately on macOS | macOS-only, hidden host coupling, not portable |
| Build `ms` from source | Self-contained image | `anthropics/ms` repo is private |
| Wait for `ms` Linux releases | No new code | Skills broken in containers until then (unacceptable) |

**What would invalidate this:** `ms` publishes a Linux binary via GitHub
releases. At that point, add it to the Dockerfile (same pattern as DCG) and
replace the Python server command in `settings.json`.

### D19: Mount host agent definitions read-only

**Firmness: FLEXIBLE**

**Added:** 2026-04-14
**Design:** [Agents in Containers](../../history/2026-04-14-agents-in-containers-design.md)

Mount `~/.claude/agents/` from the host into the container read-only, using
the same `.rc-context/` staging pattern as D17 (skills and commands). This
gives agents inside the container access to the same custom subagent types
(`implementer`, `reviewer`, `code-reviewer`, etc.) as the host user.

**Mount path:** `rc` mounts to `/home/agent/.rc-context/agents`. `init-rip-cage.sh`
symlinks this to `~/.claude/agents` so Claude Code finds agent definitions at
the expected path. The `:ro` flag is invariant.

**Symlink handling:** Agent definitions that are symlinks on the host (all six
current definitions point into `mapular-platform/.claude/agents/`) require
their symlink-target parent directory to also be bind-mounted. The existing
`_collect_symlink_parents` function in `rc` handles this — extend it to
include the `agents` directory.

**Rationale:** Without this mount, `Agent(subagent_type: "implementer")` silently
degrades to the generic built-in `Agent`. The degradation is invisible — no
error, just lost behavioral specialization. This is a high-cost silent failure
for the multi-agent architecture (ADR-006).

**Security posture:** Agent definitions are `.md` instruction files — behavioral
prompts, not credentials. Mounting `mapular-platform/.claude/agents/` does not
expose the repo root, `.env` files, or any secrets. Risk profile is identical
to D17 (skills). See [design doc §Security Analysis](../../history/2026-04-14-agents-in-containers-design.md).

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Read-only bind mount via .rc-context** | Same pattern as skills, no new infrastructure | Requires spike to confirm filesystem discovery works (see D20) |
| Mount `~/.claude/` wholesale | Single mount | Conflicts with init-time settings management |
| Per-container agents allowlist | Finer-grained exposure control | Extra config burden; low-risk content doesn't warrant it |
| No agent mounting | Simplest | Silent degradation from specialized → generic agent types |

**What would invalidate this:** Agent definitions contain sensitive instructions
that should not be visible across projects. In that case, introduce an
`agents_allowlist` in `rc.conf` (same pattern proposed for skills in D17).

### D20: Agent definition discovery mechanism

**Firmness: EXPLORATORY**

**Added:** 2026-04-14
**Design:** [Agents in Containers §Discovery Mechanism](../../history/2026-04-14-agents-in-containers-design.md)

The discovery mechanism for agent definitions is unknown as of 2026-04-14.
Skills require an MCP server (D18, Spike 1 confirmed). Whether agents use
filesystem discovery or also require MCP is unconfirmed.

**Working hypothesis:** Agent definitions are discovered via direct filesystem
scanning of `~/.claude/agents/` — not via the `ms` MCP server. Rationale: the
`Agent` tool's `subagent_type` parameter is resolved at tool-call time (not at
session startup like skills), making a filesystem lookup more likely than a
pre-built registry.

**Decision:** Attempt filesystem-only mount (D19) first. Run spike inside a
container: mount agents, call `Agent(subagent_type: "implementer")`, verify
the agent respects implementer instructions.

- **If spike passes:** Filesystem discovery confirmed. D20 is closed — no MCP
  shim needed.
- **If spike fails:** Extend `skill-server.py` to also serve agent definitions,
  or wait for `ms` to publish a Linux binary that handles both.

**Rationale:** Proven-first approach avoids building MCP infrastructure that
may be unnecessary. The spike is low-cost (single container run, one tool call).

**What would invalidate this:** Spike confirms agents also require MCP, or a
future Claude Code version changes the discovery mechanism.

## Related

- [Rip Cage Design](../2026-03-25-rip-cage-design.md) — full design document
- [ADR-001 Approval Agent](ADR-001-approval-agent-architecture.md) — complementary approach (semantic evaluation); future flywheel tool
- [AA Design v2](../2026-03-23-approval-agent-design-v2.md) — the guardrails that may run inside containers in Phase 3
- [ACFS](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup) — Jeffrey Emanuel's flywheel, inspiration for VPS-based approach
- [Claude Code Permission Modes](https://code.claude.com/docs/en/permission-modes) — official docs; we use `bypassPermissions` (was auto mode, amended 2026-04-02)
- [Claude Code Devcontainer](https://code.claude.com/docs/en/devcontainer) — Anthropic's reference devcontainer setup
- [CAAM](https://github.com/Dicklesworthstone/coding_agent_account_manager) — credential manager for multi-account Claude Code; Phase 3 reference for multi-agent credential pooling
- [Worktree Git Mount Design](../2026-04-02-worktree-git-mount-design.md) — transparent git worktree support in containers
- [Review Fixes Design](../2026-03-26-rip-cage-review-fixes.md) — fixes from 3-pass competitive review
- [CLI UX + TUI Rendering Design](../2026-03-27-cli-ux-and-tui-rendering.md) — container self-detection, auto-select, tmux respawn, TUI fixes
- **Competitive landscape:** [ClaudeCage](https://github.com/PACHAKUTlQ/ClaudeCage), [ClaudeBox](https://github.com/RchGrav/claudebox), [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/), [Trail of Bits devcontainer](https://github.com/trailofbits/claude-code-devcontainer), [Spritz](https://github.com/textcortex/spritz)
