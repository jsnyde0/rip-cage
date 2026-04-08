# Beads/Dolt Container Resilience

**Date:** 2026-04-08
**Decisions:** [ADR-007](decisions/ADR-007-beads-dolt-container-resilience.md)
**Related:** [ADR-004 D1](decisions/ADR-004-phase1-hardening.md) (host Dolt server connection)

## Problem

On 2026-04-07, an agent inside a rip-cage container corrupted the Dolt database by starting a local Dolt server on the bind-mounted `.beads/dolt/` directory while the host's Dolt server was also running. Two servers accessing the same database files caused journal corruption, checksum errors, and SIGSEGV panics.

### Root cause chain

1. **Stale port (trigger):** The container's `BEADS_DOLT_SERVER_PORT` env var was set at creation time via `docker run -e`. The host Dolt server restarted with a new ephemeral port. The container kept trying the old port — connection refused.

2. **No guardrail on `bd dolt start` (escalation):** The agent diagnosed the connection failure and ran `bd dolt start` to start a local Dolt server inside the container. `BEADS_DOLT_SERVER_MODE=1` suppresses auto-start (via `EnsureRunning()`) but does NOT block the explicit `bd dolt start` command.

3. **Dual-server corruption (impact):** Two Dolt servers accessed the same bind-mounted `.beads/dolt/` files simultaneously. The journal became corrupted. The agent then deleted the journal file (`rm .dolt/noms/vvvv...`), making recovery harder.

### Why the port goes stale

`bd` uses OS-assigned ephemeral ports (port 0 → kernel picks a free port). The port changes every time the Dolt server starts. The `rc up` command reads `.beads/dolt-server.port` and passes the value via `docker run -e BEADS_DOLT_SERVER_PORT=<port>`. This env var is frozen for the container's lifetime. If the host Dolt server restarts (host reboot, crash, `bd dolt stop/start`), the port file updates but the container's env var does not.

`bd` does not support pinning the port — there's no `--port` flag on `bd dolt start` and no `dolt.port` config key. The port is intentionally ephemeral to avoid collisions across projects (replaced an earlier hash-based scheme that had birthday-problem collisions).

## Solution

A `bd` wrapper script inside the container that:

1. **Re-reads the port file on every invocation** — eliminates stale port entirely
2. **Blocks `bd dolt start`** when `BEADS_DOLT_SERVER_MODE=1` — prevents dual-server corruption

### Wrapper design

The real `bd` binary is renamed to `bd-real` at `/usr/local/bin/bd-real`. The wrapper is installed at `/usr/local/bin/bd` (same location, no PATH games).

```bash
#!/usr/bin/env bash
# bd wrapper for rip-cage containers
# Fixes stale port + blocks local server start in external server mode
#
# Path assumption: /workspace/.beads/dolt-server.port depends on rc mounting
# the resolved .beads/ directory at /workspace/.beads (see rc cmd_up beads
# redirect logic). If rc changes the mount point, this path must be updated.

# Block "bd dolt start" when server is externally managed
# Scans past global flags (--verbose, --json, etc.) to find the subcommand pair
if [[ "${BEADS_DOLT_SERVER_MODE:-}" == "1" ]]; then
  _bd_cmd="" _bd_sub=""
  for _bd_arg in "$@"; do
    case "$_bd_arg" in
      -*) continue ;;  # skip flags (--verbose, --json, --db=..., etc.)
      *)
        if [[ -z "$_bd_cmd" ]]; then _bd_cmd="$_bd_arg"
        elif [[ -z "$_bd_sub" ]]; then _bd_sub="$_bd_arg"; break
        fi ;;
    esac
  done
  if [[ "$_bd_cmd" == "dolt" ]] && [[ "$_bd_sub" == "start" ]]; then
    echo "BLOCKED: bd dolt start is not allowed in this container." >&2
    echo "The Dolt server is managed by the host (BEADS_DOLT_SERVER_MODE=1)." >&2
    echo "Starting a local server on bind-mounted data causes corruption." >&2
    exit 1
  fi
fi

# Re-read port from bind-mounted port file (fixes stale env var)
if [[ -f /workspace/.beads/dolt-server.port ]]; then
  port=$(cat /workspace/.beads/dolt-server.port 2>/dev/null || true)
  if [[ -n "$port" ]]; then
    export BEADS_DOLT_SERVER_PORT="$port"
  fi
fi

exec /usr/local/bin/bd-real "$@"
```

### What changes

| File | Change |
|------|--------|
| `bd-wrapper.sh` | New file: wrapper script (versioned in repo, COPYed into image) |
| `Dockerfile` | COPY bd binary to `/usr/local/bin/bd-real`, COPY `bd-wrapper.sh` to `/usr/local/bin/bd`, `chmod +x` |
| `test-safety-stack.sh` | Add check: `bd dolt start` is blocked, `bd --verbose dolt start` is blocked, port re-read works. Fix pre-existing check 7 (`auto` → `bypassPermissions`) |
| `test-integration.sh` | Add check: wrapper exists (shell script), bd-real exists (executable) |
| `init-rip-cage.sh` | Remove redundant `BEADS_DOLT_SERVER_PORT` export (wrapper handles it). Consolidate duplicate `BEADS_DOLT_SERVER_MODE` and `BEADS_DOLT_SERVER_HOST` exports to top-level block only |

### What doesn't change

- `settings.json` — `Bash(bd:*)` allowlist still works (wrapper is named `bd`)
- `rc` script — still passes `BEADS_DOLT_SERVER_PORT` via `docker run -e` (useful as initial value before first wrapper invocation)
- Host-side `bd` — unaffected, wrapper only exists inside the container image
- SessionStart/PreCompact hooks — `bd prime` runs through the wrapper automatically, getting fresh port on every session start and compaction recovery

## Data flow

```
Host:
  bd dolt start → Dolt server on port N → writes .beads/dolt-server.port

rc up:
  reads .beads/dolt-server.port → docker run -e BEADS_DOLT_SERVER_PORT=N
  (snapshot — may go stale)

Container (every bd invocation):
  wrapper reads /workspace/.beads/dolt-server.port  ← bind-mounted, always fresh
  exports BEADS_DOLT_SERVER_PORT=<current value>
  calls bd-real → connects to host.docker.internal:<current port>
```

## Testing strategy

### Unit test (host-side, no container needed)

The wrapper is a bash script. Test it by:
1. Creating a temp port file
2. Setting `BEADS_DOLT_SERVER_MODE=1`
3. Piping `bd dolt start` args → expect exit 1 + error message
4. Piping normal args → expect `bd-real` to be called with correct port

### Safety stack test (inside container)

Add to `test-safety-stack.sh`:
- Check: `bd dolt start 2>&1` returns blocked message (not a real server start)
- Check: wrapper re-reads port file (write a test port, run `bd --version`, verify env)

### Integration test (host-side, spins up container)

Add to `test-integration.sh`:
- Check: `/usr/local/bin/bd` is the wrapper (not a Go binary)
- Check: `/usr/local/bin/bd-real` exists and is executable

## Edge cases

| Scenario | Behavior |
|----------|----------|
| Host Dolt server not running | `bd` fails with connection error (same as today, but with correct port) |
| Port file doesn't exist | Wrapper skips port override, falls through to env var or bd-real default |
| Port file empty or corrupt | `bd-real` gets empty port, fails with connection error (not corruption) |
| `bd dolt stop` inside container | Allowed — PID-based, looks for local PID file, finds nothing, says "not running" |
| `bd dolt status` inside container | Allowed — read-only check |
| Agent modifies `BEADS_DOLT_SERVER_MODE` | Wrapper re-checks on each invocation; if agent unsets it, `bd dolt start` unblocked BUT ephemeral port allocation would likely pick a different port than host, so connection would fail rather than corrupt |
| `BEADS_DOLT_SERVER_MODE=0 bd dolt start` (prefix env override) | Bypasses guard — bash sets env for the command's duration. Low risk: same as above, ephemeral port mismatch prevents corruption (see ADR-007 Deferred) |
| `bd --verbose dolt start` (global flags before subcommand) | Blocked — wrapper scans past `-*` flags to find the subcommand pair. Note: `--flag value` pairs (e.g., `--db /path`) may cause the value to be misidentified as a subcommand, but this would result in a false negative (fail-open), not a false positive. The realistic bypass vectors (boolean flags like `--verbose`, `--json`) are handled correctly |
