# Beads Embedded Dolt Container Support

**Date:** 2026-04-09
**Decisions:** [ADR-004 D1 amendment](decisions/ADR-004-phase1-hardening.md), [ADR-007 D5](decisions/ADR-007-beads-dolt-container-resilience.md)
**Related:** [ADR-007](decisions/ADR-007-beads-dolt-container-resilience.md) (wrapper), [ADR-002 D10](decisions/ADR-002-rip-cage-containers.md) (beads in base image)

## Problem

Agents inside rip-cage containers cannot use beads when the project uses embedded Dolt mode. The container unconditionally sets `BEADS_DOLT_SERVER_MODE=1`, which tells bd to connect to an external Dolt server. But embedded-mode projects store data in `.beads/embeddeddolt/` using an in-process Dolt engine — there is no external server to connect to. The server is reachable but responds with "database not found."

### Root cause

`rc up` (line 614) and the devcontainer template (line 156) set `BEADS_DOLT_SERVER_MODE=1` unconditionally. This was based on the incorrect assumption in ADR-004 D1 that all projects use a Dolt server. In fact, bd 1.0.0 defaults to embedded Dolt mode — an in-process engine that stores data in `.beads/embeddeddolt/`, no external server needed.

When `BEADS_DOLT_SERVER_MODE=1` is set, bd ignores the project's embedded mode and attempts to connect to a Dolt server. For embedded-mode projects, no such database exists on the server, so all bd commands fail.

### Earlier wrong assumption: `no-db: true`

The initial diagnosis pointed to `no-db: true` in `.beads/config.yaml` as the detection mechanism. Research on bd source code (`/Users/jonat/code/mapular/beads`) proved this wrong: `no-db: true` is a vestigial config key that bd parses but never uses in storage initialization. `store_factory.go` lines 41-46 always use Dolt (embedded or server). The actual source of truth is `dolt_mode` in `.beads/metadata.json`.

### Impact

- `bd ready`, `bd list`, `bd close`, etc. all fail inside the container for embedded-mode projects
- Agents cannot track work via beads — defeating a core design goal (ADR-002 D10)

### Discovery

Observed on 2026-04-09: `bd ready` inside a rebuilt personal-rip-cage container returns:
```
Error: failed to open database: database "rip_cage" not found on Dolt server at host.docker.internal:53193
```

On the host, `bd list` works fine — bd reads `.beads/metadata.json`, sees `dolt_mode: "embedded"`, and uses the in-process engine.

## Solution

Make `rc up`, `rc init`, and `init-rip-cage.sh` read `.beads/metadata.json` to determine the storage mode. Only set `BEADS_DOLT_SERVER_MODE=1` when `dolt_mode` is NOT `"embedded"`.

### Detection mechanism

The source of truth is `.beads/metadata.json`:
```json
{
  "dolt_mode": "embedded"   // or "server", "owned", "external"
}
```

Read with: `jq -r '.dolt_mode // empty' .beads/metadata.json`

Logic:
- `dolt_mode == "embedded"` or missing/empty: **embedded mode** — no server env vars
- Any other value (`"server"`, `"owned"`, `"external"`): **server mode** — set `BEADS_DOLT_SERVER_MODE=1`, `HOST`, `PORT`

### Changes

#### rc script — `cmd_up`

Before setting beads env vars, resolve the beads directory (including redirects), then read `metadata.json`:

```bash
# Determine beads storage mode from metadata.json
local beads_dolt_mode=""
if [[ -f "${beads_dir}/metadata.json" ]]; then
  beads_dolt_mode=$(jq -r '.dolt_mode // empty' "${beads_dir}/metadata.json" 2>/dev/null || true)
fi
if [[ "$beads_dolt_mode" == "embedded" ]] || [[ -z "$beads_dolt_mode" ]]; then
  log "Beads: embedded mode — no Dolt server connection"
else
  run_args+=(-e "BEADS_DOLT_SERVER_MODE=1")
  run_args+=(-e "BEADS_DOLT_SERVER_HOST=host.docker.internal")
  # ... port file reading ...
  log "Beads: server mode — connecting to host Dolt server"
fi
```

#### rc script — `cmd_init` (devcontainer template)

Same detection: read `metadata.json` before generating `containerEnv`. Embedded-mode projects get no server env vars; server-mode projects get `BEADS_DOLT_SERVER_MODE` and `HOST`.

#### init-rip-cage.sh

Replace unconditional `export BEADS_DOLT_SERVER_MODE=1` with conditional check:

```bash
if [[ -f /workspace/.beads/metadata.json ]]; then
  _beads_dolt_mode=$(jq -r '.dolt_mode // empty' /workspace/.beads/metadata.json 2>/dev/null || true)
  if [[ "$_beads_dolt_mode" != "embedded" ]] && [[ -n "$_beads_dolt_mode" ]]; then
    export BEADS_DOLT_SERVER_MODE=1
    export BEADS_DOLT_SERVER_HOST="${BEADS_DOLT_SERVER_HOST:-host.docker.internal}"
  fi
fi
```

#### bd-wrapper.sh

No changes needed. The wrapper's `bd dolt start` guard checks `BEADS_DOLT_SERVER_MODE` — if it's not set (embedded projects), the guard doesn't fire. The port re-read is harmless (skips if file doesn't exist). Both behaviors are correct.

### What doesn't change

- **bd-wrapper.sh** — works correctly for both modes (guard is conditional on env var)
- **Dockerfile** — Dolt stays in the image (needed by bd's embedded engine)
- **ADR-007 D1-D3** — wrapper remains correct for server-mode projects

## Data flow

### Embedded project (e.g., rip-cage)

```
.beads/metadata.json → dolt_mode: "embedded"

rc up:
  reads metadata.json → embedded
  does NOT set BEADS_DOLT_SERVER_MODE
  → container bd uses in-process Dolt engine on bind mount ✓

init-rip-cage.sh:
  reads metadata.json → embedded → no server env vars
  bd prime → uses embedded engine ✓
```

### Server project (e.g., mapular-platform)

```
.beads/metadata.json → dolt_mode: "server"

rc up:
  reads metadata.json → server
  sets BEADS_DOLT_SERVER_MODE=1, HOST, PORT
  → container bd connects to host Dolt server ✓

init-rip-cage.sh:
  reads metadata.json → server → exports env vars
  bd prime → connects to host server ✓
```

## Edge cases

| Scenario | Behavior |
|----------|----------|
| No `.beads/` directory | No env vars set, no beads initialization (existing behavior) |
| `.beads/metadata.json` missing | Defaults to embedded mode (safest default) |
| `dolt_mode` key absent in metadata | Defaults to embedded mode |
| `dolt_mode: "embedded"` | Embedded mode — no server env vars |
| `dolt_mode: "server"` | Server mode — connect to host Dolt server |
| `.beads/redirect` + embedded | Redirect resolves first, then metadata.json is read from resolved dir |
| Dolt server not running (server project) | `bd prime` fails with warning (existing behavior, non-fatal) |
| File lock on `.beads/embeddeddolt/` | Not observed — bd uses short-lived per-operation locks, not long-held ones |

## Validation

Empirically verified on 2026-04-09:

1. Built image with conditional init-rip-cage.sh
2. Started container with `rc up .` (rip-cage = embedded project)
3. Container logs: "Beads: embedded mode — no Dolt server connection"
4. `bd list` inside container: success
5. Created bead from container (`rip-cage-cq4`): visible on host
6. Closed bead from host: visible in container
7. Full 42-issue history accessible from container
8. Safety stack tests: 35/35 PASS
