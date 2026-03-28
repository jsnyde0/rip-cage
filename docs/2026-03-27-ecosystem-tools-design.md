# Design: Rip Cage Ecosystem Tools Integration

**Date:** 2026-03-27
**Status:** Draft
**Decisions:** [ADR-005](decisions/ADR-005-ecosystem-tools.md)

## Problem

Rip-cage needs to grow beyond its core safety stack (DCG + compound blocker) to include tools that make agents more effective: bug scanning, session search, network monitoring, task visualization. But adding tools naively — baking everything into one fat image — creates maintenance burden, bloated images, and forces choices on users who may only need a subset.

The ecosystem of agentic coding tools is maturing rapidly. UBS catches agent-generated bugs across 9 languages. RANO provides per-process network attribution. CASS indexes session history for search. These tools are independently developed with their own release cycles. Rip-cage's role is not to build these tools but to be an opinionated distribution that curates them into a coherent environment.

## Goal

Define how external tools are sourced, versioned, installed, configured, and kept optional. Establish the pattern so future tool additions are mechanical, not architectural decisions.

## Non-Goals

- Building our own versions of these tools (use upstream, contribute back)
- Mandatory inclusion of all tools (some must be optional)
- Plugin marketplace or dynamic loading (static image composition)
- Runtime tool installation (tools are baked into the image at build time)

## Architecture: Build-Arg Toggles

Each optional tool gets a build arg in the Dockerfile:

```dockerfile
ARG INCLUDE_UBS=true
ARG INCLUDE_RANO=false
ARG INCLUDE_CASS=false
ARG INCLUDE_BV=false
ARG INCLUDE_CM=false
```

The default image includes only core + UBS (the highest-value, lowest-cost addition). Users build custom images via `rc build` flags, which translate to Docker build args.

### Tool Installation Patterns

Four patterns based on tool type:

1. **Script tools (UBS):** `COPY` or `curl` script to `/usr/local/bin/`. No compilation. Modules lazy-download on first use. Cheapest to add.

2. **Rust tools (RANO, CASS):** Add to existing Rust builder stage, conditional on build arg. Prefer pre-built binaries from GitHub releases over source compilation when available — faster builds, smaller builder stages, no Rust toolchain needed for those tools.

3. **Go tools (bv):** Add to existing Go builder stage, conditional on build arg. Same preference for pre-built binaries.

4. **Runtime tools (CM):** `bun install` at image build time, conditional on build arg. Heavier than compiled tools due to runtime + node_modules.

### Conditional Installation in Dockerfile

Each tool follows this pattern:

```dockerfile
ARG INCLUDE_RANO=false
# In Rust builder stage:
RUN if [ "$INCLUDE_RANO" = "true" ]; then \
      curl -L "https://github.com/.../releases/download/v${RANO_VERSION}/rano-linux-$(dpkg --print-architecture)" \
        -o /usr/local/bin/rano && chmod +x /usr/local/bin/rano; \
    fi

# In runtime stage:
COPY --from=rust-builder /usr/local/bin/rano* /usr/local/bin/ 2>/dev/null || true
```

The `2>/dev/null || true` pattern means the COPY is a no-op when the tool was not built. The runtime stage does not need to know which tools were enabled.

### Tool Configuration

Each tool needs four integration points:

| Integration Point | When | Purpose |
|---|---|---|
| **Dockerfile** | Build time | Install binary/script (conditional on build arg) |
| **init-rip-cage.sh** | Container start | Configure if binary exists (conditional: `command -v tool`) |
| **CLAUDE.md** | Always | Document what's available so agents know their tools |
| **settings.json** | Optional | Register hooks (e.g., UBS as pre-commit gate) |

The `init-rip-cage.sh` pattern uses runtime detection, not build args:

```bash
# UBS setup (only if installed)
if command -v ubs >/dev/null 2>&1; then
  echo "UBS available: $(ubs --version)"
fi

# RANO setup (only if installed)
if command -v rano >/dev/null 2>&1; then
  mkdir -p ~/.config/rano
  [ -f ~/.config/rano/rano.toml ] || cat > ~/.config/rano/rano.toml << 'TOML'
# Default RANO config for rip-cage
[audit]
db_path = "/tmp/rano-audit.db"
TOML
fi
```

This means init-rip-cage.sh works correctly regardless of which tools are in the image.

### Version Pinning

Each tool version is pinned via build arg:

```dockerfile
ARG UBS_VERSION=5.0.7
ARG RANO_VERSION=0.1.0
ARG CASS_VERSION=0.1.0
ARG BV_VERSION=0.1.0
ARG CM_VERSION=0.1.0
```

A `versions.env` manifest at the repo root centralizes versions for easy updates:

```bash
# versions.env — tool version pins for rip-cage image
UBS_VERSION=5.0.7
RANO_VERSION=0.1.0
CASS_VERSION=0.1.0
BV_VERSION=0.1.0
CM_VERSION=0.1.0
```

The `rc build` command sources this file and passes values as build args.

### rc build Enhancements

```bash
rc build                          # Default: core + UBS
rc build --with rano              # Add RANO
rc build --with rano --with cass  # Add RANO + CASS
rc build --full                   # Everything
rc build --minimal                # Core only, no UBS
```

Each `--with <tool>` sets `INCLUDE_<TOOL>=true` as a Docker build arg. `--full` sets all to true. `--minimal` sets all to false (including UBS).

With `--output json`:

```json
{
  "image": "rip-cage:latest",
  "tools": {
    "core": true,
    "ubs": true,
    "rano": false,
    "cass": false,
    "bv": false,
    "cm": false
  },
  "build_time_seconds": 42
}
```

## Per-Tool Integration Details

### UBS (default)

**What:** Bug scanner meta-runner. Catches agent-generated bugs in <5s across 9 languages (Python, JS/TS, Go, Rust, Java, C/C++, Ruby, PHP, Bash). Runs shellcheck, mypy, eslint, clippy, etc. under the hood.

**Install:** `COPY` or `curl` the ubs script (~3MB) to `/usr/local/bin/`. No compilation. Language-specific checkers lazy-download on first use.

**Configure:** Verify available in init. Optionally register as pre-commit hook for auto-mode safety gate.

**Agent usage:**
```bash
ubs $(git diff --name-only --cached)   # Scan staged files
ubs --fix src/                          # Auto-fix where possible
ubs --json src/main.py                  # Machine-readable output
```

**Size cost:** ~3MB (script only; checker binaries download on demand)

**Why default:** Highest value/cost ratio. Direct safety gate for auto mode — catches bugs before they're committed. No compilation, minimal image impact.

### RANO (optional)

**What:** Network observer for AI CLIs. Per-process attribution of HTTP/DNS traffic. SQLite audit trail. Needs `/proc` (works in Linux containers on Mac).

**Install:** Pre-built binary from GitHub releases (~8MB). Falls back to Rust builder stage if no release available for the target architecture.

**Configure:** If binary exists, create default config at `~/.config/rano/rano.toml`. Set up audit database at `/tmp/rano-audit.db`.

**Agent usage:**
```bash
rano                              # Live TUI view
rano --preset audit               # Background audit logging
rano query --since 1h --json      # Query audit trail
```

**rc integration:** `rc monitor <name>` wraps `docker exec` + `rano` for host-side visibility.

**Size cost:** ~8MB

**Why optional:** Observability tool. Valuable for debugging and auditing but not needed for core agent work. Requires understanding of network patterns to be useful.

### CASS (optional)

**What:** Session search across 20+ AI provider session formats. Tantivy full-text search + SQLite FTS5 indexing.

**Install:** Pre-built binary from GitHub releases (~15MB). Falls back to Rust builder stage.

**Configure:** If binary exists and `.claude/` has sessions, run `cass index --incremental` on container start.

**Agent usage:**
```bash
cass search "auth error" --robot --json --limit 5
cass search "how did we fix the rate limiter" --json
cass sessions --provider claude --since 7d --json
```

**Size cost:** ~15MB (binary + index grows with session count)

**Why optional:** Requires session history to be useful. Most valuable for long-running projects with accumulated agent sessions.

### Beads Viewer / bv (optional)

**What:** Graph-aware TUI for beads tasks. Robot modes for agents (`--robot-triage`, `--robot-next`).

**Install:** Go builder stage, conditional on build arg. Or pre-built binary from releases.

**Configure:** No special setup needed — reads `.beads/` from the workspace.

**Agent usage:**
```bash
bv --robot-triage                 # Get triage recommendations as JSON
bv --robot-next                   # Get next task recommendation
bv graph --json                   # Dependency graph as JSON
```

**Size cost:** ~50-100MB (Go binary; Go binaries are large due to static linking)

**Why optional:** Large binary. Only useful if using beads extensively. The existing `bd` CLI covers basic beads operations.

### CASS Memory / CM (optional)

**What:** Procedural memory with confidence decay. Stores lessons learned with temporal weighting. Playbook YAML for team knowledge.

**Install:** `bun install` at build time, conditional on build arg.

**Configure:** If binary exists and playbook mounted, verify readable. Host mounts `~/.cass-memory/playbook.yaml` read-only.

**Agent usage:**
```bash
cm context "implementing auth middleware" --json    # Get relevant memories
cm learn "Redis connections need explicit close"    # Store new memory
cm playbook list --json                             # List playbook entries
```

**Size cost:** ~20MB (bun runtime + node_modules)

**Why optional:** Requires host-side playbook setup. Value increases over time as memories accumulate. New tool, less battle-tested.

## Phased Rollout

| Phase | Tools | Goal |
|---|---|---|
| **1b** | UBS (default) | Validate the build-arg toggle pattern. Prove one external tool integrates cleanly. |
| **2a** | RANO, CASS (optional) | Refine pattern with Rust tools. Test pre-built binary download flow. |
| **2b** | bv, CM (optional) | Complete the tool catalog. Test Go and runtime installation patterns. |

Each phase ships independently. A phase is complete when the tool installs correctly, init configures it, and an agent can use it inside the container.

## Image Size Budget

| Configuration | Estimated Size | Delta from Current |
|---|---|---|
| Current (core + Dolt + bd) | ~1.1GB | baseline |
| Minimal (core, no Dolt, no UBS) | ~1.0GB | -100MB |
| Default (core + UBS) | ~1.0GB | -100MB (Dolt removal offsets UBS) |
| Default + RANO + CASS | ~1.03GB | -70MB |
| Full (all tools) | ~1.2GB | +100MB |

Note: Dolt (~103MB) may be removed from the base image if beads moves to a lighter backend, which would offset the cost of adding several tools.

## Consequences

- Image stays lean by default — users only pay for tools they enable
- Each tool addition is a mechanical process (Dockerfile + init + docs), not an architectural decision
- No vendor lock-in to any tool — swap UBS for another scanner by changing the build arg and install script
- `rc build` becomes the primary image customization interface
- The `versions.env` manifest makes coordinated version bumps a single-file change
- Tools that don't exist in the image are invisible to agents (no broken commands, no confusing errors)
