# ADR-007: Beads/Dolt Container Resilience

**Status:** Proposed
**Date:** 2026-04-08
**Design:** [Beads/Dolt Container Resilience](../2026-04-08-beads-dolt-container-resilience.md), [Beads no-db Container Support](../2026-04-09-beads-no-db-container-support.md)
**Related:** [ADR-004 D1](ADR-004-phase1-hardening.md) (host Dolt server connection), [ADR-002 D10](ADR-002-rip-cage-containers.md) (beads in base image)

## Context

ADR-004 D1 established that the container's `bd` connects to the host's Dolt server via `host.docker.internal`. This works at container creation time but breaks when the host Dolt server restarts with a new port — the container's `BEADS_DOLT_SERVER_PORT` env var is frozen at creation time.

On 2026-04-07, this stale port caused an agent to start a local Dolt server inside the container (`bd dolt start`), resulting in two servers accessing the same bind-mounted `.beads/dolt/` files. The journal was corrupted. Recovery required `bd init --force` + `bd backup restore --force`.

`BEADS_DOLT_SERVER_MODE=1` suppresses auto-start but does not block the explicit `bd dolt start` command (confirmed in beads source: `servermode.go:61-63`, `doltserver.go:550-560`).

## Decisions

### D1: bd wrapper script for dynamic port and server start guard

**Firmness: FIRM**

Replace the `bd` binary in the container with a wrapper script that:
1. Re-reads `/workspace/.beads/dolt-server.port` on every invocation (fixes stale port)
2. Blocks `bd dolt start` when `BEADS_DOLT_SERVER_MODE=1` (prevents dual-server corruption)

The real binary is renamed to `bd-real` at `/usr/local/bin/bd-real`. The wrapper is installed at `/usr/local/bin/bd`. The wrapper is a first-class file in the repo (`bd-wrapper.sh`), COPYed directly into the image (no runtime `mv`).

The start guard scans past global flags (`--verbose`, `--json`, etc.) to find the subcommand pair, preventing bypass via `bd --verbose dolt start`.

**Rationale:** The stale port problem is structural — env vars are immutable after `docker run`. The port file is bind-mounted and always current. Reading it on every invocation eliminates staleness with negligible overhead (one `cat` per `bd` call). The wrapper is also the natural enforcement point for blocking `bd dolt start`, since it intercepts all `bd` invocations before the real binary.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **Wrapper script** | Self-contained, testable, no upstream dep | Extra indirection, one more file in image |
| Fixed Dolt port | Eliminates staleness entirely | Not supported by bd — no `--port` flag or config key |
| PATH-priority wrapper at `~/.local/bin/bd` | No rename needed | Fragile if PATH changes, harder to test |
| PreToolUse hook for `bd dolt start` | Uses existing hook infra | Doesn't fix the stale port problem |
| Upstream bd change (read port file as fallback) | Cleanest long-term | Not our code, uncertain timeline |
| Destroy/recreate container on port change | Works | Terrible UX, loses container state |

**What would invalidate this:** bd adds a `--port` flag or config key for pinning the Dolt server port. Or bd adds built-in port file fallback when `BEADS_DOLT_SERVER_MODE=1`.

### D2: Allow `bd dolt stop` inside containers

**Firmness: FIRM**

Do NOT block `bd dolt stop`. It is harmless inside containers because:
- It works via PID file (`.beads/dolt-server.pid`), sending SIGTERM to the process
- The host's PID doesn't exist in the container's PID namespace
- No PID file exists inside the container (the host's PID file is not bind-mounted separately)
- Result: "server is not running" — no side effects

**Rationale:** Over-blocking creates friction without safety benefit. `bd dolt stop` is a read-PID-then-signal operation that is container-scoped by the kernel's PID namespace isolation. Blocking it would confuse agents that check server status.

### D3: Extend test coverage for wrapper

**Firmness: FLEXIBLE**

Add verification for the wrapper in both test suites:

**test-safety-stack.sh** (runs inside container):
- `bd dolt start` returns blocked message (exit 1)
- `bd --version` works (wrapper passes through to bd-real)

**test-integration.sh** (runs on host, spins up container):
- `/usr/local/bin/bd` is a shell script (not a Go binary)
- `/usr/local/bin/bd-real` exists and is executable

**Rationale:** The wrapper is a safety-critical component. If it's missing or broken, the container loses both stale-port resilience and the server start guard. Testing it in both suites catches both "wrapper absent" and "wrapper broken" failure modes.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **Both test suites** | Catches absence and breakage | Two places to maintain |
| test-safety-stack.sh only | Single location | Doesn't catch missing wrapper before init |
| No tests | Simple | Silent regression when Dockerfile changes |

### D4: Clean up redundant port export in init-rip-cage.sh

**Firmness: FLEXIBLE**

Remove the `BEADS_DOLT_SERVER_PORT` export from `init-rip-cage.sh` (lines 82-84). The wrapper handles port reading on every invocation, making the init-time export redundant.

Consolidate the duplicate `BEADS_DOLT_SERVER_MODE=1` and `BEADS_DOLT_SERVER_HOST` exports — they appear at both the top-level (lines 8-9) and inside the beads block (lines 80-81). Keep only the top-level exports; the wrapper depends on these.

Also fix the pre-existing bug in test-safety-stack.sh check 7 which asserts `auto` mode instead of `bypassPermissions`.

**Rationale:** Eliminates a misleading code path that suggests the port is set once at init time. With the wrapper, the port is always fresh. Removing it prevents confusion about which mechanism is authoritative. The duplicate export consolidation and test fix are opportunistic cleanups in the same files.

### D5: Respect project's beads storage mode (embedded vs server)

**Firmness: FIRM**

**Added:** 2026-04-09

Do NOT set `BEADS_DOLT_SERVER_MODE=1` for projects using embedded Dolt mode. Read `.beads/metadata.json` `dolt_mode` to determine the storage mode. Only set server env vars when `dolt_mode` is `"server"`, `"owned"`, or `"external"`.

`rc up`, `rc init`, and `init-rip-cage.sh` all read `.beads/metadata.json` (after resolving any redirect) before deciding whether to configure Dolt server connectivity. The check uses `jq -r '.dolt_mode // empty'`.

When `dolt_mode` is `"embedded"` (or absent):
- No `BEADS_DOLT_SERVER_MODE`, `BEADS_DOLT_SERVER_HOST`, or `BEADS_DOLT_SERVER_PORT` env vars
- bd uses its in-process Dolt engine on the bind-mounted `.beads/embeddeddolt/` directory
- The bd wrapper's `dolt start` guard doesn't fire (checks `BEADS_DOLT_SERVER_MODE`)
- The wrapper's port re-read is harmless (skips if port file absent)

When `dolt_mode` is anything else (`"server"`, `"owned"`, `"external"`):
- Server env vars are set as before (ADR-007 D1 wrapper handles port refresh)

**Rationale:** On 2026-04-09, `bd ready` inside a container failed for rip-cage (an embedded-mode project) because the unconditional `BEADS_DOLT_SERVER_MODE=1` told bd to look for database "rip_cage" on the host Dolt server — which doesn't exist for embedded projects. Research on bd source code confirmed that `no-db: true` in config.yaml is vestigial (parsed but ignored); the real source of truth is `dolt_mode` in `metadata.json`. Embedded mode uses an in-process Dolt engine; server mode connects to an external Dolt server.

See [design doc](../2026-04-09-beads-no-db-container-support.md) and [ADR-004 D1 amendment](ADR-004-phase1-hardening.md).

**What would invalidate this:** bd changes `metadata.json` format or removes embedded mode. Or bd's server connection gracefully falls back to embedded when the database doesn't exist on the server.

## Deferred

- **Upstream bd change for port file fallback** — Would eliminate the need for the wrapper entirely. Monitor bd releases for this capability.
- **Blocking env var modification** — An agent could `unset BEADS_DOLT_SERVER_MODE` to bypass the wrapper guard. This is low-risk: without the mode flag, `bd dolt start` would try to start on an ephemeral port different from the host's, failing to connect rather than corrupting. Defense-in-depth for this is not worth the complexity.
- **Health check for host Dolt connectivity** — A startup check that verifies the host server is reachable before `bd prime`. Would improve error messages but doesn't prevent the corruption scenario (which is already handled by the wrapper).
