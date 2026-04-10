# Troubleshooting: Beads/Dolt Connectivity in Containers

## Symptom

`bd` commands inside a rip-cage container fail with:
```
Error: failed to open database: Dolt server unreachable at host.docker.internal:<port>
```

## Root Cause

The container's `BEADS_DOLT_SERVER_PORT` env var is set at creation time (`docker run -e`). If the host's Dolt server restarts with a new port, the container has a stale port and can't connect.

Check the mismatch:
```bash
# Host's current port:
cat /path/to/project/.beads/dolt-server.port

# Container's frozen port:
docker inspect <container-name> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep BEADS_DOLT_SERVER_PORT
```

## Fix

Destroy and recreate the container — this picks up the current port from the port file:

```bash
rc destroy <container-name>
rc up /path/to/project
```

## DANGER: Do NOT run `bd dolt start` inside the container

If an agent "fixes" the connection by starting a local Dolt server inside the container, **two servers will access the same bind-mounted database files simultaneously**, causing journal corruption and data loss.

This happened on 2026-04-07: the container agent started a local Dolt server on port 49564, then a host session auto-started a host Dolt server on port 53059. Both accessed the same `.beads/dolt/` files. Result: corrupted journal, checksum errors, SIGSEGV panics.

## Recovery from Dolt Corruption

If the database is corrupted (checksum errors, corrupted journal):

```bash
# 1. Stop all containers accessing this .beads/
rc down <container-name>

# 2. Stop the host Dolt server for this repo
cd /path/to/project
bd dolt stop

# 3. Move corrupted data aside
mv .beads/dolt .beads/dolt-corrupted

# 4. Reinitialize and restore from backup JSONL
bd init --force
bd backup restore --force

# 5. Verify
bd list --status=all

# 6. Clean up (manual — DCG blocks rm -rf)
rm -rf .beads/dolt-corrupted
```

## Prevention (Planned)

- PreToolUse hook to block `bd dolt start` when `BEADS_DOLT_SERVER_MODE=1`
- Architectural fix for stale port problem (design in progress)
