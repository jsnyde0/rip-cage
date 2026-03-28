# ADR-004: Phase 1 Hardening

**Status:** Proposed
**Date:** 2026-03-27
**Design:** [Phase 1 Hardening Design](../2026-03-27-phase1-hardening-design.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [ADR-003 Agent-Friendly CLI](ADR-003-agent-friendly-cli.md)

## Context

Phase 1 of rip-cage is feature-complete: the `rc` CLI, Dockerfile, init script, safety stack, and smoke tests all exist. But the image has never been built end-to-end, and several gaps would cause failures on real use. This ADR covers the hardening decisions needed before the first real agent session.

Key problems: Dolt is 103MB and unusable in containers (no SSH keys), containers have no resource limits, OAuth tokens can expire silently, the test suite only has 6 checks, and the shell config is too bare for productive agent use.

## Decisions

### D1: Drop Dolt from container image, use bd no-db mode

**Firmness: FIRM**

Remove the Dolt installation step from the Dockerfile. Set `BD_NO_DB=true` as a container environment variable so bd uses JSONL-only storage instead of Dolt.

**Rationale:** Dolt adds ~103MB to the image and is non-functional inside containers. bd's Dolt driver requires SSH keys and host aliases for `dolt push/pull`, neither of which exist in the container. The design doc (ADR-002, "Beads local-only") already acknowledged this: "bd dolt push/pull fails inside containers." bd's `no-db` mode provides the same `bd create/close/list/show` workflow with flat-file storage. Beads changes still persist via the `/workspace` bind mount and normal git commits.

The Go builder stage is kept because bd does not publish pre-built binaries. Only the Dolt install step is removed.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Remove Dolt, use BD_NO_DB=true** | 103MB savings, no sync failures, zero config | Loses `bd dolt push/pull` (already broken) |
| Mount SSH keys into container | Dolt sync would work | Security risk, complex key management |
| Use Dolt HTTPS remotes | No SSH keys needed | Requires remote setup, auth token management |
| Remove bd entirely | Simpler image | Loses issue tracking inside containers |

**What would invalidate this:** bd publishes pre-built binaries (remove Go builder stage too). Or Dolt adds HTTPS remote auth that works with GH_TOKEN.

### D2: Default container resource limits, overridable via flags

**Firmness: FLEXIBLE**

Add default resource limits to `docker run` in `cmd_up`:

- `--cpus=2`
- `--memory=4g`
- `--memory-swap=4g`
- `--pids-limit=500`

Add `--cpus`, `--memory`, and `--pids-limit` flags to `rc up` for user override.

**Rationale:** A runaway agent (infinite loop, fork bomb, memory leak) can starve the host. Default limits bound the blast radius to 2 CPUs and 4GB RAM, which is enough for normal development (builds, test suites, language servers) but prevents host starvation. The `--memory-swap` matching `--memory` disables swap, keeping behavior predictable. 500 PIDs prevents fork bombs while allowing normal process trees (shell, tmux, Claude Code, build tools).

These are defaults, not hard caps. A user building a large project can override with `rc up --cpus=4 --memory=8g /path/to/project`.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Defaults + flags** | Safe by default, flexible | One more thing to configure |
| No limits (current) | Simple | Runaway agent can crash host |
| Fixed limits, no override | Simple, safe | Too restrictive for heavy builds |
| Per-project config file (.rc.yaml) | Project-specific tuning | Over-engineering for Phase 1 |

**What would invalidate this:** OrbStack or Docker adds per-container resource defaults at the runtime level. Or containers gain cgroup-v2 auto-tuning.

### D3: Credential health check on container start (warning, not hard failure)

**Firmness: FLEXIBLE**

Before `docker run` in `cmd_up`, parse `~/.claude/.credentials.json` for token expiry. If the token expires in less than 10 minutes, print a warning to stderr. If the token is already expired, print a stronger warning. Do not block container start.

**Rationale:** OAuth tokens have finite lifetimes. An expired token causes an opaque auth error mid-session. Checking at start time gives the user a chance to re-authenticate (`claude auth login` on the host) before the agent begins work.

This is a warning, not a hard failure, because:
- The agent may use `ANTHROPIC_API_KEY` instead of OAuth (common on VPS)
- Claude Code handles its own token refresh internally (the mounted credentials file is read-write)
- A token expiring in 9 minutes may be refreshed by Claude Code before it actually expires

The check uses `jq` and `date`, both available on macOS and in the container.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Warning on start** | Early detection, non-blocking | May warn unnecessarily (token gets refreshed) |
| Hard failure on expired token | Prevents wasted time | Blocks valid API-key workflows |
| Background health monitor | Catches mid-session expiry | Complexity, daemon management |
| No check (current) | Simple | Silent auth failures mid-session |

**What would invalidate this:** Claude Code adds its own token expiry warning. Or OAuth tokens become long-lived (unlikely).

### D4: Expand rc test to 15+ checks with structured output

**Firmness: FIRM**

Expand the `rc test` command from 6 checks to 21 checks covering: user identity, filesystem, settings validation, safety stack, auth, tools (git, jq, tmux, bd, python3, uv, node, bun), network (DNS resolution), and disk space. Support both human-readable and `--output json` output modes (per ADR-003 D1).

**Rationale:** The current 6 tests verify the safety stack but miss everything else. An agent session can fail because of missing tools, bad auth, no disk space, or broken DNS -- none of which the current tests catch. Expanding to 21 checks means catching these issues before the agent starts work, not 20 minutes in.

Structured JSON output (per ADR-003) enables programmatic health checking by orchestrators in Phase 3.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Expand rc test** | Single source of truth, JSON support | Larger function in rc script |
| Separate test script per category | Modular | Scattered, harder to run all at once |
| Docker healthcheck | Automatic, periodic | Limited output, no JSON, no user-triggered |
| No expansion (current) | Simple | False confidence from 6/6 PASS |

**What would invalidate this:** A proper monitoring/observability stack replaces ad-hoc health checks. Or container images are tested in CI before use.

### D5: Richer zshrc with conditional modern CLI aliases

**Firmness: FLEXIBLE**

Expand the container's zshrc with: modern CLI aliases (eza/lsd for ls, bat for cat, rg for grep -- all conditional on the tool being present), git shorthand aliases (gs, gd, gp, gl, glog, ga, gc), utility functions (mkcd, extract), terminal type fallback, and PATH setup.

**Rationale:** The current zshrc is nearly empty. Agents (and humans debugging inside containers) benefit from productive shell defaults. Conditional aliases (`command -v eza && alias ls='eza'`) mean no errors if a tool is missing -- the aliases simply don't activate. Git aliases reduce command length for the most common operations. The `extract` function handles common archive formats without remembering tar flags.

This is low-risk: all aliases are optional, conditional, and override-able. No behavioral changes to existing tools.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Conditional aliases in zshrc** | Productive, safe, no errors on missing tools | More lines in zshrc |
| Install oh-my-zsh or similar framework | Rich features | Heavy, opinionated, large attack surface |
| No expansion (current) | Minimal | Bare shell, agents type more |
| Mount host zshrc | User's exact config | Host-specific, may break in container |

**What would invalidate this:** Claude Code gets its own shell configuration that conflicts. Or agents stop using shell commands directly (unlikely).

## Deferred

- **Per-project resource config (.rc.yaml)** -- flags are sufficient for Phase 1. Revisit if projects diverge significantly in resource needs.
- **Background credential monitoring** -- start-time check is sufficient. Revisit if mid-session expiry becomes a real problem.
- **Installing modern CLI tools (eza, bat, rg) in the image** -- the aliases are conditional and ready. Adding the tools to the Dockerfile is a separate, low-priority change.
- **CI-based image testing** -- currently manual (`rc build && rc test`). Add when the project has CI.
