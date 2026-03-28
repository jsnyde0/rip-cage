# ADR-005: Ecosystem Tools Integration

**Status:** Proposed
**Date:** 2026-03-27
**Design:** [Ecosystem Tools Design](../2026-03-27-ecosystem-tools-design.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [Flywheel Investigation](../2026-03-27-flywheel-investigation.md)

## Context

Rip-cage's Phase 1 delivered a safety stack (DCG + compound command blocker) inside a containerized environment. The next step is integrating external tools that make agents more effective: bug scanning (UBS), network monitoring (RANO), session search (CASS), task visualization (bv), and procedural memory (CM). These tools are independently developed projects with their own release cycles. The question is how to integrate them without bloating the base image or creating maintenance burden.

## Decisions

### D1: Ecosystem tools are integrated via Dockerfile build-arg toggles, not runtime plugins

**Firmness: FIRM**

Each optional tool gets a `ARG INCLUDE_<TOOL>=true|false` in the Dockerfile. Tools are installed at build time, conditional on the arg. There is no runtime plugin system, no dynamic downloading, no post-start installation.

**Rationale:** Build-time composition produces deterministic, reproducible images. Runtime plugin systems add complexity (download failures, version mismatches, startup latency) without meaningful benefit — users rebuild images infrequently and want consistent environments. The Dockerfile already has a multi-stage pattern (Go builder, Rust builder, runtime) that naturally accommodates conditional tool installation.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Build-arg toggles** | Deterministic, reproducible, fits existing Dockerfile pattern | Must rebuild image to change tools |
| Runtime plugin download | Change tools without rebuild | Non-deterministic, download failures, startup latency |
| Separate image per tool combo | Maximum isolation | Combinatorial explosion of images |
| Docker multi-stage with `--target` | Clean separation | Doesn't support conditional inclusion within a stage |

**What would invalidate this:** Tool set changes so frequently that rebuilding the image becomes a bottleneck. In that case, consider a volume-mounted tool directory with version-locked binaries.

### D2: UBS is the only external tool included by default

**Firmness: FLEXIBLE**

UBS (Ultimate Bug Scanner) ships in the default image (`INCLUDE_UBS=true`). All other tools default to false.

**Rationale:** UBS has the highest value-to-cost ratio of any tool evaluated. It is a 3MB bash script (no compilation), catches bugs across 9 languages in <5s, and directly improves auto-mode safety by gating commits. Every other tool is either larger (bv: 50-100MB), requires setup (CM: host-side playbook), or serves a narrower use case (RANO: network debugging, CASS: session search). The default image should be opinionated toward safety — UBS is the one tool that makes every agent session safer.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **UBS only** | Lean default, clear value proposition | Users must opt-in to other tools |
| UBS + RANO | Safety + observability | RANO adds 8MB and complexity for a tool most users won't need immediately |
| All tools default | Feature-rich out of the box | ~200MB larger, longer build, tools users don't need |
| No external tools default | Smallest image | Misses the highest-value addition |

**What would invalidate this:** Another tool proves higher value-to-cost than UBS for the default use case (e.g., a lighter bug scanner, or a tool that prevents a class of errors UBS misses).

### D3: Tool versions are pinned via build args with a manifest file

**Firmness: FIRM**

Each tool version is a Dockerfile build arg (`ARG UBS_VERSION=5.0.7`). A `versions.env` file at the repo root centralizes all version pins. `rc build` sources this file and passes values as `--build-arg` flags.

**Rationale:** Pinned versions prevent silent breakage from upstream changes. A manifest file makes version bumps a single-file change that is easy to review, diff, and automate (e.g., Dependabot-style PRs). Build args are the standard Docker mechanism for parameterizing builds — no custom tooling needed.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Build args + versions.env** | Standard Docker pattern, single-file updates, easy to automate | Extra file to maintain |
| Hardcoded versions in Dockerfile | Simpler, fewer files | Versions scattered across Dockerfile, harder to review |
| `latest` tag always | No pinning needed | Non-reproducible builds, silent breakage |
| Lock file (versions.lock) | Cryptographic verification | Over-engineered for this use case |

**What would invalidate this:** Tool count grows large enough that a proper dependency resolver (like Nix) would be more appropriate than a flat env file.

### D4: `rc build` gains `--with <tool>` flags for user customization

**Firmness: FIRM**

The `rc build` command accepts `--with <tool>` to enable optional tools, `--full` to enable all, and `--minimal` to disable all (including UBS). These translate directly to Docker build args.

```bash
rc build                          # Default: core + UBS
rc build --with rano              # Add RANO
rc build --with rano --with cass  # Add RANO + CASS
rc build --full                   # Everything
rc build --minimal                # Core only
```

**Rationale:** Users should not need to know Docker build-arg syntax. `--with rano` is self-documenting and discoverable via `rc build --help`. The flag names match the tool names used throughout documentation. This is consistent with ADR-003's principle that `rc` is the primary interface for all container operations.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **`--with <tool>` flags** | Self-documenting, discoverable, matches tool names | Must maintain flag-to-arg mapping |
| Raw `--build-arg` passthrough | No new code | Poor UX, leaks Docker abstraction |
| Config file (rc.yaml) | Persistent preferences | Another config file, overkill for build-time choice |
| Profiles (rc build --profile heavy) | Curated combos | Opaque, hard to customize |

**What would invalidate this:** Tool count grows beyond ~10, making individual `--with` flags unwieldy. In that case, consider a config file or profile system.

### D5: Standard integration pattern for each tool

**Firmness: FIRM**

Every tool follows the same four-point integration pattern:

1. **Dockerfile:** Conditional install via build arg
2. **init-rip-cage.sh:** Conditional config via `command -v` runtime detection
3. **CLAUDE.md:** Always document available tools (agents should know their environment)
4. **settings.json:** Optional hook registration (e.g., UBS as pre-commit gate)

The init script uses runtime detection (`command -v tool`), not build args, so it works correctly regardless of which tools are in the image.

**Rationale:** A standard pattern makes tool additions mechanical. A contributor adding a new tool follows a checklist, not a design process. Runtime detection in init decouples the init script from the Dockerfile — you can swap tool installation methods (source build vs. pre-built binary) without changing init.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Standard 4-point pattern** | Mechanical additions, decoupled init | Slightly more boilerplate per tool |
| Ad-hoc per tool | Flexibility | Inconsistent, harder to maintain |
| Plugin manifest (tools.json) | Machine-readable tool registry | Over-engineered, another file to parse |
| Init reads build args from labels | Build-time and runtime in sync | Tighter coupling, Docker label complexity |

**What would invalidate this:** Tools require fundamentally different integration patterns (e.g., a tool that needs kernel modules or Docker socket access). In that case, extend the pattern rather than abandoning it.

### D6: Prefer pre-built binaries from GitHub releases over source compilation

**Firmness: FLEXIBLE**

When a tool publishes pre-built binaries for linux/arm64 and linux/amd64, download those in the Dockerfile rather than compiling from source. Fall back to source compilation only when pre-built binaries are unavailable for the target architecture.

**Rationale:** Pre-built binaries make builds faster (no Rust/Go toolchain needed for that tool), produce smaller builder stages (no source tree or build cache), and reduce the chance of build failures from upstream dependency changes. The Dockerfile already compiles DCG and bd from source — adding more source builds increases build time and fragility. For tools like RANO and CASS that publish releases, downloading a binary is a single `curl` command.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Pre-built binaries preferred** | Fast builds, small stages, simple | Trust upstream build, no local patching |
| Always compile from source | Full control, can patch | Slow builds, large builder stages, toolchain deps |
| Vendor binaries in repo | No network dependency at build time | Bloats repo, manual updates |
| Nix or Guix for all tools | Reproducible, declarative | Heavy dependency, unfamiliar tooling |

**What would invalidate this:** Need to patch tools locally (e.g., rip-cage-specific modifications). In that case, fork the tool and compile from source in the builder stage.

## Related

- [Ecosystem Tools Design](../2026-03-27-ecosystem-tools-design.md) — full design document with per-tool details
- [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md) — base image architecture this extends
- [ADR-003 Agent-Friendly CLI](ADR-003-agent-friendly-cli.md) — `rc build` JSON output pattern
- [Flywheel Investigation](../2026-03-27-flywheel-investigation.md) — tool evaluation and selection rationale
- [UBS](https://github.com/Dicklesworthstone/ultimate_bug_scanner) — Ultimate Bug Scanner
