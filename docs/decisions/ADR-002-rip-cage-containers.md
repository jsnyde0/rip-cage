# ADR-002: Rip Cage — Containerized Agentic Development Flywheel

**Status:** Accepted

> **Migration status (ADR-029, 2026-07-10):** This ADR is evolved by [ADR-029](ADR-029-msb-migration.md) — the container runtime is reversed (D1) and several decisions' mechanics re-bind to msb (see per-decision dispositions below); D9 (devcontainer) is separately dead regardless of migration (rip-cage-kt25). The msb cutover has landed (S1-S14, branch `wave/s13-docs` off `msb-cutover`) — the mechanisms below are retired/replaced per the dispositions above; this ADR is retained for historical record, not current behavior. See [ADR-029](ADR-029-msb-migration.md) for what replaced them.

**Date:** 2026-03-25
**Design:** [Rip Cage Design](../2026-03-25-rip-cage-design.md)
**Related:** [ACFS](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup)

## Context

The AA (Approval Agent) project addresses the "approval monkey" problem by semantically evaluating commands. But there's a complementary approach: run agents inside containers where the blast radius is inherently limited. The container is the flywheel housing — it holds safety tools together and lets you be bolder with the tool stack inside. ACFS (Jeffrey Emanuel) proves this model works on throwaway Ubuntu VPSes. We want it locally on Mac too.

The ecosystem already has several containerized Claude Code solutions (ClaudeCage, ClaudeBox, Docker Sandboxes, Trail of Bits devcontainer) but none combine hooks-inside-containers, fully autonomous execution, and VPS portability.

## Decisions

### D1: OrbStack as container runtime on Mac

> [ADR-029 D1: REVERSED — msb (libkrun microVMs riding Apple's Hypervisor framework) replaces OrbStack as the isolation primitive. This decision's own "What would invalidate this" clause ("Apple ships native container support") is adjacent-not-fired: msb rides Apple's HVF hypervisor API, which is not Apple-native *container* support — the invalidation as literally written did not occur, but the runtime is reversed anyway on the strength of the boundary upgrade (host/VM vs co-located-uid).]

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

> [ADR-029 D2: EVOLVED — the one-image concept survives; msb consumes OCI images directly, so "no per-project Dockerfiles" carries forward with the runtime swapped underneath.]

**Firmness: FLEXIBLE**

A single "rip-cage" Docker image with Python/uv, Bun/Node, git, tmux, Claude Code, beads (bd, built from Go source), DCG (pre-built binary), and hooks. No per-project Dockerfiles. 2-stage build: Go builder for bd → debian:trixie runtime (~1.1 GB). (Runtime base was debian:bookworm until the 2026-06-07 base bump — see "Base-image selection" below.)

**Rationale:** Projects are mostly Python and/or JS/TS. A universal image avoids maintaining N Dockerfiles and means `rc up <path>` works for any project without setup. The image is ~2-3GB but built once. Project-specific deps (node_modules, .venv) are installed inside the persistent container on first run. Bun is included as primary JS runtime (faster than Node for Claude Code, from ClaudeCage's approach). Beads (bd + Dolt) enables issue tracking inside containers.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **One base image** | Zero per-project setup, simple | Larger image, some unused tools |
| Per-project Dockerfile | Minimal image per project | Maintenance burden, slower onboarding |
| Layered images (base + project) | Best of both | Docker layer complexity, rebuild coordination |
| devcontainer.json per project | Industry standard | Overkill for current needs, unfamiliar |

**What would invalidate this:** Projects require wildly different system deps (e.g., CUDA, system libraries). Image size becomes a problem on VPS with limited disk.

#### D2a: Base-image selection — debian:trixie (revised 2026-06-08)

> [ADR-029 D2: RETIRED (pin designation only) — the "safety-critical" designation this decision assigns to the legacy-iptables pin is retired: msb guests have no in-guest iptables at all, legacy or nft (per [ADR-012](ADR-012-egress-firewall.md) D10's disposition, a third unanticipated invalidator). The base-image choice itself (debian:trixie, glibc 2.41) stands independent of this — it is not an iptables-motivated pick alone and nothing here forces a base change at cutover.]

**Firmness: FLEXIBLE** (was EXPLORATORY / PROVISIONAL until the 2026-06-08 forward evaluation below)

The runtime base is **debian:trixie** (glibc 2.41); the builder stages are **golang:1.26-trixie** and **rust:1-slim-trixie**, so bd-real and DCG compile against trixie's libicu76 — no ICU soname shim is needed. The iptables backend is pinned to LEGACY via `update-alternatives --set iptables /usr/sbin/iptables-legacy` (Dockerfile ~line 40; this pin is safety-critical — see ADR-012 D10).

**Origin (2026-06-07):** trixie entered as a user-authorized spike (bead `rip-cage-4c5.10`) forced by agent_mail's glibc floor — "may revert or pick an alternative."

**Forward evaluation + confirmation (2026-06-08):** rather than treat trixie as an accidental landing spot, the base was deliberately re-evaluated against the field (debian:bookworm, ubuntu:24.04 LTS, ubuntu:26.04 LTS, Debian 14 forky, Wolfi) before committing. User (jsnyde0) confirmed **trixie as the forward base.** Decision basis: it is already migrated and the full safety stack is verified green on it (zero further cost); the marginal extra free-support runway of Ubuntu 24.04 (~1 yr) does not justify re-verifying the whole stack on a fresh base; and Ubuntu 26.04 — despite the newest glibc and longest support tail — defaults to Rust reimplementations of `sudo` (sudo-rs) and coreutils (uutils), a behavioral-compatibility risk for the sudo-dependent `init-rip-cage.sh` and exactly the silent-default-change class that caused the nft firewall regression. Firmness raised EXPLORATORY → FLEXIBLE on the strength of this deliberate field evaluation (not just the forced spike).

**Rationale:** A manifest-declared in-cage daemon (agent_mail, `rip-cage-4c5.6`) ships only prebuilt binaries requiring glibc ≥ 2.38; bookworm has 2.36, trixie has 2.41. The composable tool manifest (ADR-005 D7) is only useful if such tools can actually run inside the cage — a base too old to load their binaries makes the whole archetype dead on arrival.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Keep bookworm + per-tool glibc compat shims | `reasoned:` per-tool C++ ABI hazard — ICU 72→76 spans 4 major releases; a shim is fragile and does not generalize to the next tool. Also disqualified outright: bookworm's glibc 2.36 < the 2.38 floor. |
| Pin an older agent_mail release built against glibc 2.36 | `reasoned:` recent agent_mail releases target newer CI glibc; pinning backward abandons the pinned 8897497 commit the manifest fixture references. |
| Build agent_mail from source in-cage | `direct:` non-viable — the workspace patches ~40 deps to unpublished sibling path-checkouts (`Cargo.toml:160-224`); a clean in-cage source build is not reproducible. |
| ubuntu:24.04 LTS (glibc 2.39) | `reasoned:` (2026-06-08) viable and ~1 yr longer free support, keeps GNU userland — but switching costs a full safety-stack re-verification for marginal runway when trixie is already proven. Solves none of the forward iptables risk (shared Debian-family firewall model). The pick only if starting fresh. |
| ubuntu:26.04 LTS (glibc 2.42) | `reasoned:` (2026-06-08) best raw runway (support ~2031, ESM ~2041) but defaults to sudo-rs + uutils rust-coreutils — a compatibility risk for the sudo-dependent init and the same silent-default-swap class as the nft regression. Would need classic sudo/coreutils explicitly installed before it is "least-surprise." |
| Wolfi (Chainguard, glibc, rolling) | `reasoned:` (2026-06-08) sudo/tmux/zsh confirmed present, but no apt, no Debian update-alternatives legacy/nft machinery (firewall pin unproven), and a rolling model with no multi-year support guarantee — a from-scratch Dockerfile + firewall re-validation for a security sandbox. Not worth it now. |
| Debian 14 "forky" | `direct:` not released — active testing branch, expected mid-2027, and testing gets no timely security updates. Revisit in 2027. |

**What would invalidate this:** a trixie package or default breaks a safety-stack component on a future base/package bump that the legacy-iptables pin or the ICU alignment does not cover; OR a smaller/cleaner Debian (or slim) base that also provides glibc ≥ 2.38 is found. **Forward risk (base-independent, tracked as `rip-cage-fft`):** on very new host kernels (6.18+) the legacy iptables `x_tables` interface may be absent, silently no-op'ing the legacy pin and re-opening the egress firewall fail-OPEN — this affects any Debian-family base and is the likely trigger for an eventual nft-backend firewall migration + effect-based startup self-test, independent of the base choice. **Spike evaluation (2026-06-07):** on trixie, `rc test` is 76/76, the egress firewall is 18/18, and the daemon e2e is green — no safety-stack regression observed.

### D3: Persistent containers with manual lifecycle

> [ADR-029 D2/D4: EVOLVED — the persistent-cage concept survives; the "cheap-recreate" story (`rc destroy` + `rc up` is fast) re-mechanizes as ADR-029 D4's snapshot-amend (0.783s) / cold-recreate (0.303s) plus session resume, both markedly faster than the Docker-era destroy+up cycle this decision described.]

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

> [ADR-029 D6: EVOLVED — the transparent-worktree-handling property survives; the mount mechanics (four-mount worktree scheme, `:ro` hooks sub-mount) need to re-prove on msb virtiofs. Scoped macOS/HVF per ADR-029 D6's platform gate — Linux/KVM virtiofs behavior is a separate reconfirmation.]

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

> [ADR-029 D1/D2: EVOLVED-STRENGTHENED — "the container is the safety boundary, not the classifier" survives and strengthens: the boundary upgrades from co-located-uid container to microVM (ADR-029 D1). Below, the hook inventory and scope-note references to `block-ssh-bypass.sh` and the ADR-012 egress firewall are annotated per their own retirement (ADR-029 D2/D3).]

**Firmness: FIRM**

**Amended 2026-04-02:** Changed from auto mode to `bypassPermissions` after e2e validation showed auto mode's classifier prompts defeat the purpose of containerized autonomous execution.

**Amended 2026-06-03 (rip-cage-4r8):** Removed the compound-command blocker from the in-container hook set. **Counter-argument to its original inclusion:** it was kept to teach the agent away from "compound command abuse," but its real protected surface was permission-allowlist bypass (Claude Code prefix-matches only the *first* command) — and under `bypassPermissions` the allowlist does not gate commands at all, so that surface is moot. The destructive-command class it was imagined to backstop is in fact fully covered by DCG *regardless of chaining*: DCG's rules are unanchored regexes matched over the whole command string (verified live in a cage 2026-06-03 — `echo hi && rm -rf ~`, `ls; rm -rf /important`, and `git status && git reset --hard HEAD~5` all DENY). The only other command-string guard, `block-ssh-bypass.sh`, is likewise chaining-robust (whole-command scan) and SSH is additionally network-backstopped (ADR-012 D8). So the compound blocker imposed real friction (it fired repeatedly on benign read-only commands) for no *unique* protection — a net loss under "it's annoying is a design signal" and "layers not walls / optimize for uninterrupted runs over theoretical blast-radius." DCG + `block-ssh-bypass.sh` remain the command-string guards.

Agents run with `--dangerously-skip-permissions` (`"defaultMode": "bypassPermissions"` in settings.json) inside containers. The permission system is entirely bypassed. Safety comes from the container boundary (hard limit on blast radius) and PreToolUse hooks (DCG + `block-ssh-bypass.sh`), which fire regardless of permission mode.

The key insight: **the container is the safety boundary, not the classifier.** If auto mode still requires human approval for edits, you might as well run auto mode on the host — the container adds no value. The whole point of rip-cage is fully autonomous background execution.

Hooks provide two types of in-container safety:
- **DCG** — blocks destructive commands, returns `"deny"` with explanation. Agent self-corrects. Matches over the whole command string, so chaining (`&&`/`;`/`||`) does not evade it.
- **ssh-bypass blocker** (`block-ssh-bypass.sh`) — denies ssh-family flags that defeat the cage host arrow (`-o UserKnownHostsFile`, `StrictHostKeyChecking=no/accept-new`), whole-command. (A compound-command blocker was part of this set until 2026-06-03 — see the amendment above for why it was removed.) [ADR-029 D3: this hook retires along with the rest of the ssh cluster — no ssh CLI-override class to close once ssh is not the git transport.]

Both are "block and redirect" hooks — they teach the agent to fix its approach without requiring human intervention. This is the correct pattern for autonomous containers.

Phase 1 hooks: DCG (pre-built release binary), `block-ssh-bypass.sh`, and `bd prime` (beads, on both SessionStart and PreCompact). Host-specific hooks (`restrict-sensitive-paths.sh`, `allow-directory-commands.sh`, `notify.sh`, `block-harvest.sh`) are excluded — they depend on macOS binaries, host paths, or are redundant with container isolation.

**Rationale:** E2e validation (2026-04-02) confirmed that auto mode's classifier prompts for file edits and other operations, requiring human presence at the terminal. This contradicts rip-cage's core value proposition: launch an agent, walk away, come back to results. `bypassPermissions` eliminates all permission prompts while hooks continue to provide guardrails against destructive commands and ssh host-arrow bypass.

Allow/deny lists in settings.json are bypassed in this mode but retained as documentation of intent. They would re-activate if the devcontainer path (VS Code) uses auto mode instead.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **`bypassPermissions` + hooks** | Zero prompts, hooks still enforce safety, fully autonomous | No classifier safety net (container is the net) |
| Auto mode + phased hooks | Classifier reviews actions | Still prompts humans — defeats containerized autonomy |
| Normal permissions + AA | Maximum human control | Still an approval monkey (AA is Phase 2+) |
| Normal permissions + expanded allow list | No new tools needed | Can't safely allow opaque commands |

**What would invalidate this:** Hooks stop firing under `bypassPermissions` (currently confirmed they do fire). Or container isolation proves insufficient and an additional in-container safety layer is needed beyond hooks.

**Amended 2026-06-04 (rip-cage-2uv) — hook-registration glue is agent-writable (was: documented limitation, accepted-not-hardened):** The PreToolUse hook *scripts* and the DCG binary are root-owned and read-only to the agent (`/usr/local/lib/rip-cage/…`), so they cannot be edited from inside the cage. Their *registration*, however, lives in the agent-owned `~/.claude/settings.json` — so an agent could disable DCG / `block-ssh-bypass.sh` by editing that file (whether confused — "to make X work" — or following injected instructions). The original amendment accepted this as a documented limitation on two grounds: primarily the equivalence axis ("don't over-invest in tamper-resistance beyond loaded-by-default", ADR-019 D4/D7), secondarily that Claude Code writes `settings.json` at runtime so a read-only mount would risk breaking it.

**Revised 2026-06-22 (rip-cage-r9n4 / wlwc — SHIPPED, limitation CLOSED):** The **DCG** command-guard hook now lives in the baked-root-owned **`/etc/claude-code/managed-settings.json`** — Claude Code's **highest-precedence settings layer**. (Only the DCG hook was moved to the managed layer; `block-ssh-bypass.sh` stays registered in the agent-writable `settings.json` — see the scope note below.) Verified against the shipped CC binary (rip-cage-wlwc.1 / rip-cage-r9n4, commit c9aec68): managed hooks **merge with** (do not replace) user/project hooks and are **un-suppressible** by any edit to `~/.claude/settings.json` or `/workspace/.claude/settings.json`, and PreToolUse is **deny-wins** (an agent-added hook cannot un-block a managed DCG deny). The in-cage agent cannot edit or override this root-owned layer. Regression-proven: 15/15 tests, deny provably DCG-sourced.

This **sidesteps the secondary rejection ground**: `~/.claude/settings.json` STAYS agent-writable — we do **NOT** chmod the writable file (so the "CC writes settings.json at runtime" objection no longer applies); a **separate root-owned layer** is added instead. It **consciously REVERSES the primary equivalence-axis rejection** *for the command-guard specifically*: we now DO invest in guard-tamper-resistance, because [ADR-024](ADR-024-prompt-injection-threat-model.md)'s prompt-injection threat (a non-adversarial agent following injected instructions to "make X work" by unregistering the hook) makes guard-tamper-resistance worth it — the "don't over-invest beyond loaded-by-default" calculus that held when only honest mistakes were in scope no longer holds for the guard once injected-instruction-following is a named threat.

**Scope of this hardening:** the **DCG** command-guard *registration* is now tamper-resistant — and this is **DCG-specific**. `block-ssh-bypass.sh` used to remain registered in the agent-writable `settings.json` (agent-removable; it was never moved to the managed layer). [ADR-029 D3, LANDED: `block-ssh-bypass.sh`, its registration, and `examples/ssh-bypass/` retired wholesale with the ssh cluster at the msb cutover — the file and the hook are deleted, not merely undocumented.] This is not a claim that the whole agent layer is tamper-proof. The welded floor remains **containment** (ADR-025 D2 revised; ADR-026 D1/D2); DCG is now the sole command-string guard above containment (its sibling ssh-bypass is retired) — DCG's registration is tamper-resistant via the managed-settings layer. The other containment layers remain independent of `settings.json`: post-cutover, that floor is [ADR-029](ADR-029-msb-migration.md) D2's floor (the microVM boundary + msb default-deny egress/DNS + the surviving host-mount floor items, replacing the pre-cutover egress firewall + Docker filesystem/container boundary) — so even a residual command-guard disable path removes **neither network nor filesystem containment**.

### D6: Bind mount default, clone mode as flag

> [ADR-029 D6: EVOLVED — the bind-mount-default posture restates as an msb virtiofs share at cutover. This decision's "What would invalidate this" text is OrbStack-literal ("bind mount performance on Mac is unacceptable even with OrbStack") — note it re-binds to virtiofs performance under msb rather than OrbStack.]

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

> [ADR-029 D6: EVOLVED — "same image local and VPS" is exactly where the ADR-029 D6 Linux/KVM hard gate is written in: the mechanics proven on macOS/HVF (msb v0.6.4) are FIRM only within that platform scope, and this decision's VPS/Linux half inherits the gate — `rip-cage-4fxg` reconfirmation is required before any VPS/Linux deployment on msb.]

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

> [ADR-029 D5: EVOLVED-STRENGTHENED — msb `--secret` non-possession supersedes this decision's "limit damage if dev creds leak" framing: the real credential now need not enter the guest at all for the dominant secret, rather than merely being scoped to a low-value dev credential. Reconciling the alternatives-table rebuttal below: this decision rejected "Network firewall (egress filtering)" as "too restrictive — agents need network for packages, docs, APIs." Host-side egress control shipped anyway ([ADR-012](ADR-012-egress-firewall.md), now re-homed to [ADR-029](ADR-029-msb-migration.md) D2) without the predicted friction — observe-mode-first (and now the ADR-029 D4 repair loop) solved the friction problem this decision anticipated but didn't yet have an answer for.]

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

> [DEAD regardless of migration — the devcontainer path was removed (rip-cage-kt25); `.devcontainer/` is legacy and gitignored. This decision is retired independent of the msb migration; not an ADR-029 disposition.]

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

> [ADR-029 D7: REVERSED — `host.docker.internal` does not exist under msb, so the container-connects-to-host-Dolt-server mechanism this decision describes has no path forward as written. Interim posture (stated explicitly): while a cage is up rw on a repo, bd writes happen from exactly one side (single-writer discipline, convention-enforced, not physically guarded) — see [ADR-029](ADR-029-msb-migration.md) D7. The durable host-service topology is captured-not-committed in bead `rip-cage-o7tx`, decided later, not here.]

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

> [ADR-029 D2: EVOLVED — the rationale holds unchanged; the `:ro` sub-mount enforcement mechanism re-implements in msb mount syntax (scoped macOS/HVF per ADR-029 D6 until Linux/KVM reconfirmation). This is a named surviving floor item in ADR-029 D2's new welded-containment-floor enumeration (the `.git/hooks` read-only weld).]

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

> [ADR-029: UNAFFECTED-mechanism-prose-updated — the scoped-sudo posture is an in-guest floor item independent of the container-vs-microVM boundary and is not itself reversed or retired. Light touch only: this decision's rationale names the removed compound blocker ("`sudo chmod -x block-compound-commands.sh`") as an example of tampering it prevents — that blocker no longer exists (removed 2026-06-03, see D5's amendment) and is illustrative-historical text only, not a live consideration.]

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

> [Partially RETIRED / ADR-029 D1: EVOLVED — the devcontainer half is dead independent of the migration (rip-cage-kt25, same as D9). The image-distribution half (pre-built image, no per-project Dockerfile paths) evolves: distribution becomes an msb pull rather than a Docker registry pull, but the "distributable, no source dependency" property survives.]

**Firmness: FIRM**

**Added:** 2026-03-26 (brainstorming session)

The generated `devcontainer.json` references a pre-built image (`rip-cage:latest`) rather than a Dockerfile path. `rc init <path>` scaffolds `.devcontainer/devcontainer.json` into any target project. `rc build` builds the image locally.

**Rationale:** Rip-cage is a distributable tool — as of v0.2.0 it ships via `brew install jsnyde0/rip-cage/rip-cage` with the Docker image pulled from `ghcr.io/jsnyde0/rip-cage` on first `rc up`. Users won't have the source repo cloned, so devcontainer.json cannot reference a Dockerfile path — it must reference an image. Using a pre-built image also means:
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

> [ADR-029 D2: RETIRED-WITH-MECHANISM — `/.dockerenv` is absent in msb guests, so this decision's detection mechanism does not fire there. The "rc is a host tool" property it protects still needs an in-guest marker of some kind under msb — flagged as a decompose-time item, not decided here.]

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

> [ADR-029: EVOLVED (msb list) — the CWD-match + singleton-fallback resolution strategy carries over unchanged in shape; it resolves against msb sandbox listings rather than `docker ps` output.]

**Firmness: FLEXIBLE**

**Added:** 2026-03-27 (manual testing)

Commands that require a container name (`attach`, `down`, `destroy`, `test`) resolve the target container using a two-tier strategy:

1. **CWD match (primary):** Derive the expected container name from the current working directory (same `container_name()` logic as `rc up`) and check if an rc-managed container with that name exists. This mirrors `rc up`'s default-to-`.` behavior, so `rc down` from a project directory targets that project's container — even when many containers are running.
2. **Singleton fallback:** If no CWD match, auto-select when exactly one rip-cage container exists. When zero or multiple exist, error with a list.

Explicit names still work and are recommended for scripts/orchestrators.

**Rationale:** `rc up` defaults to the current directory when no path is given. But `rc down` and other commands had no CWD awareness — they required an explicit name whenever multiple containers existed. This asymmetry was confusing: `rc up` "just works" from a project directory but `rc down` doesn't. CWD-first resolution makes all commands behave consistently. The singleton fallback preserves backward compatibility for users with a single container.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **CWD match + singleton fallback (current)** | Consistent with `rc up`, works in multi-container setups | Slightly more complex resolution logic |
| Singleton auto-select only (previous) | Simple | Breaks with multiple containers; inconsistent with `rc up` |
| Always require name | Explicit, predictable | Tedious for single-container use |
| Fuzzy match / partial names | Flexible | Ambiguous, error-prone |
| `rc default <name>` | Explicit default | Extra state to manage |

**What would invalidate this:** CWD-based resolution produces surprising results (e.g., hash-suffixed names from `container_name()` collisions). In that case, fall back to explicit names or add `rc default <name>`.

### D16: TUI rendering — locale, tmux config, synchronized output

> [ADR-029: mostly UNAFFECTED — the multiplexer is already composable (session.multiplexer config; tmux is one option among none/tmux/herdr), so this decision's TUI concerns are largely orthogonal to the runtime swap. Only the docker-specific mentions age; the tmux/locale/rendering content itself is not an ADR-029 disposition.]

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

> [ADR-029 D6: EVOLVED (mount mechanics only) — the read-only `.rc-context/` staging pattern re-implements on msb mount syntax; the security posture and rationale are unaffected. Scoped macOS/HVF per ADR-029 D6 until Linux/KVM reconfirmation.]

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

> [ADR-029 D6: EVOLVED (mount mechanics only) — `skill-server.py` and the MCP-shim discovery mechanism are runtime-agnostic (they run in-guest regardless of container vs microVM); only the underlying `.rc-context/` mount mechanics (D17) re-bind. Not otherwise affected by the migration.]

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

> [ADR-029 D6: EVOLVED (mount mechanics only) — same disposition as D17: the `.rc-context/` mount pattern re-implements on msb mount syntax; security posture and rationale unaffected. Scoped macOS/HVF per ADR-029 D6 until Linux/KVM reconfirmation.]

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

> [ADR-029: UNTOUCHED — filesystem-scanning discovery is runtime-agnostic; the msb migration does not bear on this decision.]

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
- Approval Agent (separate project) — complementary approach (semantic evaluation); future flywheel tool
- [ADR-024 Prompt-Injection Threat Model](ADR-024-prompt-injection-threat-model.md) — expands the threat model the D5 bypassPermissions+hooks framing rests on; "accident" now includes a non-adversarial agent following injected hostile instructions
- [ADR-026 Containment + Delegated Mediation](ADR-026-containment-mediation-identity.md) — the network-composition extension of the container-as-boundary identity: D5's boundary holds *inward* (containment); content mediation (L7 policy, credential injection) is delegated *outward* to a composed mediator. The container stays self-contained for containment; composition is opt-in.
- [AA Design v2](../2026-03-23-approval-agent-design-v2.md) — the guardrails that may run inside containers in Phase 3
- [ACFS](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup) — Jeffrey Emanuel's flywheel, inspiration for VPS-based approach
- [Claude Code Permission Modes](https://code.claude.com/docs/en/permission-modes) — official docs; we use `bypassPermissions` (was auto mode, amended 2026-04-02)
- [Claude Code Devcontainer](https://code.claude.com/docs/en/devcontainer) — Anthropic's reference devcontainer setup
- [CAAM](https://github.com/Dicklesworthstone/coding_agent_account_manager) — credential manager for multi-account Claude Code; Phase 3 reference for multi-agent credential pooling
- [Worktree Git Mount Design](../2026-04-02-worktree-git-mount-design.md) — transparent git worktree support in containers
- [Review Fixes Design](../2026-03-26-rip-cage-review-fixes.md) — fixes from 3-pass competitive review
- [CLI UX + TUI Rendering Design](../2026-03-27-cli-ux-and-tui-rendering.md) — container self-detection, auto-select, tmux respawn, TUI fixes
- **Competitive landscape:** [ClaudeCage](https://github.com/PACHAKUTlQ/ClaudeCage), [ClaudeBox](https://github.com/RchGrav/claudebox), [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/), [Trail of Bits devcontainer](https://github.com/trailofbits/claude-code-devcontainer), [Spritz](https://github.com/textcortex/spritz)
