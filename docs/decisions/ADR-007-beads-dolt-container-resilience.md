# ADR-007: Beads/Dolt Container Resilience

**Status:** Accepted
**Date:** 2026-04-08
**Design:** [Beads/Dolt Container Resilience](../2026-04-08-beads-dolt-container-resilience.md), [Beads no-db Container Support](../2026-04-09-beads-no-db-container-support.md), [Host-side bd Pre-flight](../2026-04-22-bd-host-preflight-design.md)
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

### D6: Auto-redirect worktree `.beads/` to main repo when no runtime data

**Firmness: FIRM**

**Added:** 2026-04-21

When `rc up` mounts a git worktree, auto-mount the main repo's `.beads/` over `/workspace/.beads` if ALL of the following hold:

- A worktree was detected (`wt_detected=true`, `wt_main_git` set)
- The worktree's `.beads/` has **no** explicit `redirect` file
- The worktree's `.beads/` has **no** runtime Dolt data: no `dolt-server.port`, no `dolt/` dir, no `embeddeddolt/` dir
- The main repo's `.beads/` exists and is under `RC_ALLOWED_ROOTS` (ADR-003 D3)

Explicit `.beads/redirect` files still take precedence — the auto-redirect runs in an `elif` branch.

**Rationale:** A fresh git worktree inherits tracked `.beads/` files (`metadata.json`, `config.yaml`, hooks) but **not** the gitignored runtime files (`dolt-server.port`, `dolt/`, etc.). Without this fallback, for a server-mode project:
- `rc up` passes no `BEADS_DOLT_SERVER_PORT` (port file absent in worktree)
- The `bd` wrapper's per-invocation re-read also fails (same worktree, same absent file)
- `bd` inside the container dials `host.docker.internal:0` → confusing timeout

This was flagged as a pre-existing gap in the 2026-04-08 ADR-007 fixes notes ("Devcontainer lacks beads redirect resolution — out of scope"). Reproduced on 2026-04-21 in `worktrees-feat-mp-c34-formula-input-coalesce` (mapular-platform worktree, `dolt_mode=server`).

The auto-redirect uses the same mount mechanism as an explicit `.beads/redirect`, so there's no divergent code path. Nothing is written to the host filesystem at `rc up` time — the mount is ephemeral to the container.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **Auto-mount main repo `.beads/`** | No file creation, transparent, reuses existing mount | Implicit behavior; users might be surprised if they wanted a worktree-local beads |
| Auto-create `.beads/redirect` file on `rc up` | Explicit artifact | Writes to host filesystem at mount time; leaves stray files if container is destroyed |
| Document as manual step ("create redirect before `rc up`") | No code change | Friction; every worktree hits the footgun once |
| Fail loud with instructions if port missing | Loud failure | Doesn't fix the problem; adds friction without solving it |

The "worktree-local beads" case is handled by the runtime-data check: if the worktree has its own `dolt/` or `dolt-server.port`, the auto-redirect won't trigger. Embedded-mode worktrees with their own `embeddeddolt/` are also respected.

**What would invalidate this:** bd gains first-class worktree support (e.g., `bd worktree init` that sets up runtime files). Or users start intentionally creating worktree-local beads databases.

### D7: Wrapper diagnostic when server mode is set but port is unavailable

**Firmness: FIRM**

**Added:** 2026-04-21

When the `bd` wrapper detects `BEADS_DOLT_SERVER_MODE=1` but `BEADS_DOLT_SERVER_PORT` is unset/empty/0 after the port file re-read, emit a multi-line diagnostic to stderr identifying:

- The expected port-file path
- Whether the port file is absent vs. empty/zero
- Likely cause (worktree missing auto-redirect; host Dolt server not running)
- The remediation (`rc up` to pick up auto-redirect; `bd dolt start` on host)

The diagnostic is skipped for safe no-op subcommands (`--version`, `-v`, `--help`, `-h`, `help`, `completion`) so discovery flows aren't polluted.

**Rationale:** Before this change, the failure surface was `Dolt server unreachable at host.docker.internal:0: dial tcp 0.250.250.254:0: i/o timeout` — a confusing TCP error with no actionable context. The diagnostic catches the misconfiguration at the wrapper layer (earliest possible point) and translates it into instructions. The D6 auto-redirect should prevent the worktree case from ever hitting this path, but D7 is a cheap defense-in-depth for:

- Containers created before D6 shipped (stale containers)
- Host Dolt server genuinely not running (legitimate transient state)
- Edge cases in path resolution we haven't anticipated

**What would invalidate this:** bd itself adopts clearer error messages for unreachable-server scenarios.

### D8: Host-side bd connectivity pre-flight at `rc up`

**Firmness: FIRM**

**Added:** 2026-04-22

At `rc up`, for server-mode projects, probe the host's Dolt port (`127.0.0.1:<port-from-port-file>`) before handing the container over. Warn (do not block) on three failure states:

- **Port file missing** — bd server never started successfully. Warn with the host-side `bd dolt start` remediation and the `lsof`-for-wedged-dolt escalation.
- **Port file present but nothing listening** — stale port, dolt crashed or was killed. Warn with the host-side `bd dolt start` remediation.
- **Port file corrupt** — content fails numeric/range validation (empty, whitespace, non-numeric, or out of range). Warn to delete the file and rerun `bd dolt start`.

Healthy (port file present + listening) passes silently. Embedded-mode (`dolt_mode=embedded` or unset) skips the check entirely. Probe uses a bash-3.2-compatible `/dev/tcp` + background-kill idiom (macOS has no `timeout(1)` by default); no `nc` dependency, runs once per `rc up`.

The warning never blocks container start. bd is optional; users who don't need bd in this session can proceed, and the warning preserves the explicit next action for when they do. **This is a deliberate ADR-001 (fail-loud) exception:** bd is an optional subsystem, and a bd-contract violation must not block containers used for non-bd workflows. A future reader applying ADR-001 mechanically must not "fix" this to fail-loud.

**Rationale:** Before this change, a server-mode contract violation (port file stale or missing) surfaced as a confusing in-container TCP error with a drifting port number, sometimes hours into a session. The 2026-04-21 mapular-platform wedge took ~30 minutes of host-side diagnosis — a problem the host already had all the information to catch at `rc up` time. D7's in-container diagnostic handles the narrow "port env is 0 or empty" case but doesn't catch a set-but-unreachable port, and doesn't fire until the user has already tried to use bd.

Host-side pre-flight is strictly better-positioned: the host can `lsof`, can read the port file directly, can point at the correct `bd dolt start` cwd, and catches the problem at the moment before the broken state is handed over. See [design doc](../2026-04-22-bd-host-preflight-design.md) for the full state decision table, port-file validation rules, and warning text.

**Ordering dependency:** the pre-flight must run after the D6 worktree auto-redirect so that `beads_dir` resolves to the main repo's `.beads/` (matching what the container sees). This is the current integration point in `cmd_up`; future refactors must not move it earlier.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Host-side pre-flight warn at `rc up`** | Catches all four states before container exists, runs once per creation, targeted remediation text | Adds ~5ms probe latency to `rc up` |
| Wrapper-level probe on every `bd` call | Can catch mid-session server death | Per-call latency; wrong layer (the broken state already exists) |
| Block container start on failure | Guarantees contract | bd is optional; would break non-bd users |
| In-container self-test in `init-rip-cage.sh` | Runs automatically post-start | No access to host-side context (lsof, host paths), duplicates D7's layer |
| Status quo (D7 only) | No new code | Doesn't catch set-but-unreachable ports, fires too late |

**What would invalidate this:** bd adopts clearer error messages *and* a way to discover the correct port without the port file. Or rip-cage drops server-mode support entirely.

### D9: `rc test` bd-connectivity check

**Firmness: FLEXIBLE**

**Added:** 2026-04-22

Add one host-side check to `rc test` with slug `beads-host-dolt`, invoking the same helper as D8. The helper emits a line in the existing `PASS|FAIL [N] slug — detail` format (with `[0]` signalling host-side, since in-container scripts number from 1); the line is prepended to the `docker exec` output so the existing JSON parser handles it without shape changes. States map to test outcomes:

- Embedded / `dolt_mode` unset → `PASS [0] beads-host-dolt — not applicable (embedded mode)`
- Server-mode + healthy → `PASS [0] beads-host-dolt — dolt reachable on 127.0.0.1:<N>`
- Server-mode + port file missing → `FAIL [0] beads-host-dolt — port file missing; run bd dolt start`
- Server-mode + port file present, port unreachable → `FAIL [0] beads-host-dolt — stale port <N>; run bd dolt start`
- Server-mode + port file corrupt → `FAIL [0] beads-host-dolt — corrupt port file; rm + bd dolt start`
- Workspace mount not discoverable → `PASS [0] beads-host-dolt — workspace mount not found (skipped)`

JSON output mode preserves the existing `{name, status, detail}` shape per ADR-003 D1; the state distinction lives in the detail string. `cmd_test` discovers `beads_dir` from a running container via `docker inspect` on the `/workspace` mount source (the local `beads_dir` in `cmd_up` is not in scope here), then applies the same D6 auto-redirect rule so worktree probes match what the container sees.

**Rationale:** `rc test` is the agent-and-human escape hatch for diagnosing a container that's behaving oddly. D8 runs only at creation time; once a container is up, users need a way to re-run the diagnosis on demand — e.g., after restarting the host dolt server and wanting to confirm the fix before attempting bd calls. Adding to `rc test` reuses the existing harness and JSON output contract rather than inventing a new command.

**What would invalidate this:** `rc test` is deprecated in favor of another health mechanism. Or D8 is extended to a watcher that reports continuously, making on-demand redundant.

## Deferred

- **Upstream bd change for port file fallback** — Would eliminate the need for the wrapper entirely. Monitor bd releases for this capability.
- **Blocking env var modification** — An agent could `unset BEADS_DOLT_SERVER_MODE` to bypass the wrapper guard. This is low-risk: without the mode flag, `bd dolt start` would try to start on an ephemeral port different from the host's, failing to connect rather than corrupting. Defense-in-depth for this is not worth the complexity.
- **Automatic recovery of wedged dolt state** — D8 diagnoses; the user remediates. The 2026-04-21 incident showed wedged state can have legitimate non-obvious causes (legacy containers), which the tool shouldn't guess at. Revisit if a single wedge pattern becomes dominant.
