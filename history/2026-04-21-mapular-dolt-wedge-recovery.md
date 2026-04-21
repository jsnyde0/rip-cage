# Handover: recover wedged host Dolt for mapular-platform beads

**Date:** 2026-04-21
**Run from:** host (macOS), NOT inside an rc container
**Target repo:** `/Users/jonat/code/mapular/platform/mapular-platform`
**Affected worktree/container:** `worktrees-feat-mp-c34-formula-input-coalesce`

## Symptom

Inside the rc container, `bd <anything>` intermittently fails with:

```
Error: failed to open database: Dolt server unreachable at host.docker.internal:NNNNN
```

…where `NNNNN` drifts between invocations (observed: 49775, 49805). `bd dolt status` inside
the container says "not running / Expected port: NNNNN". `bd dolt start` is (correctly)
blocked by the wrapper.

## Root cause (already diagnosed — don't re-investigate)

1. One legitimate host Dolt server is running: **PID 1799, port 51122, db locked**. Its
   runtime config references `/workspace/.beads/backup` — meaning it was started from
   *inside* a rip-cage container long ago (before `bd dolt start` was blocked) and has been
   running ever since with container-era paths. The giveaway in
   `/Users/jonat/code/mapular/platform/mapular-platform/.beads/dolt-server.log`:

   ```
   error="failed to create directory '/workspace/.beads/backup':
          mkdir /workspace: read-only file system"
   ```

2. Subsequent `bd` invocations (host or container) try to `bd dolt start` new servers on
   fresh ephemeral ports — each fails with lock contention. Each failed attempt leaves
   bd's runtime state pointing at a port that never actually came up. That's the drifting
   "Expected port" in the error.

3. No `.beads/dolt-server.port` file was ever written (successful starts write it; failed
   ones don't). So the rc container's bd-wrapper port re-read is a no-op, and the
   container is frozen on whatever `BEADS_DOLT_SERVER_PORT` was at `rc up` time.

## Recovery steps

Do these **in order**, from the host, outside any rc container.

### 1. Confirm the wedged dolt is still PID 1799 on port 51122

```
lsof -iTCP -sTCP:LISTEN -P -n | grep dolt
```

Expect to see a `dolt` process listening on `127.0.0.1:51122`. If the PID has changed, use
the new one. If there's no dolt on 51122, skip step 2.

### 2. Kill the wedged dolt server

```
kill <PID>
```

Wait ~2 seconds, re-run the `lsof` from step 1 to confirm it's gone. If it respawns, it's
being supervised by something — investigate before continuing (check `launchctl list | grep
dolt`, cron, etc.).

### 3. Start a fresh dolt server from the correct cwd

```
cd /Users/jonat/code/mapular/platform/mapular-platform
bd dolt start
```

Expect a success message. If it fails with "database locked" again, something else is
still holding the lock — re-run step 1.

### 4. Verify the port file now exists

```
cat /Users/jonat/code/mapular/platform/mapular-platform/.beads/dolt-server.port
```

Expect a 4–5 digit port. If the file is absent even after a successful `bd dolt start`,
that's an upstream bd bug and needs escalating to the beads maintainer — stop here and
flag it.

### 5. Destroy + recreate the rc container so it picks up the new port

```
rc destroy worktrees-feat-mp-c34-formula-input-coalesce
rc up /Users/jonat/code/mapular/platform/mapular-platform/.worktrees/feat-mp-c34-formula-input-coalesce
```

(Note: the compound-blocker hook is container-only; on the host these two can be one line
with `&&` if you prefer.)

### 6. Smoke test inside the new container

```
docker exec -w /workspace worktrees-feat-mp-c34-formula-input-coalesce bd list --status=open
```

Expect real issues. Re-run 2–3 times to confirm it's not flaky.

## Out of scope for this handover

- **Why the old dolt was started from inside a container** — historical, pre-`bd dolt
  start` block. No action needed once killed.
- **Why bd didn't write a port file on the failed starts** — expected; only successful
  starts do. Step 3 should fix this.
- **Rip-cage improvements (D7 should catch stale ports, wrapper should warn on missing
  port file)** — tracked separately in rip-cage beads, not part of this recovery.

## If something unexpected happens

Stop and report state. Do NOT try to "fix" the mapular-platform `.beads/` dolt directory
contents directly — that's the source of truth for the issue tracker and corrupting it is
expensive to recover from. The `backup/` subdirectory contains point-in-time snapshots if
escalation is needed.
