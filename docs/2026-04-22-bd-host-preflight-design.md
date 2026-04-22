# Design: Host-side bd connectivity pre-flight

**Date:** 2026-04-22
**Status:** Draft
**Decisions:** [ADR-007 D8, D9](decisions/ADR-007-beads-dolt-container-resilience.md)
**Related:** [ADR-001](decisions/ADR-001-adr-format.md), [ADR-003 D1](decisions/ADR-003-agent-friendly-cli.md), [ADR-004 D1](decisions/ADR-004-phase1-hardening.md), [ADR-007 D1, D5, D6, D7](decisions/ADR-007-beads-dolt-container-resilience.md), [ADR-013](decisions/ADR-013-test-coverage.md)

## Motivation

On 2026-04-21 a mapular-platform rc container failed every `bd` call with `Dolt server unreachable at host.docker.internal:49775` / `…:49805` — a drifting port in a confusing TCP error. Root cause (diagnosed in `history/2026-04-21-mapular-dolt-wedge-recovery.md`):

1. A legacy host Dolt server, started from *inside* a rip-cage container before ADR-007 D1's `bd dolt start` guard existed, was still running with `/workspace/.beads/` paths baked in, holding the db lock.
2. Subsequent host-side `bd dolt start` calls failed on lock contention. Each failed start stamped a fresh ephemeral port into bd's runtime expectation but never wrote `.beads/dolt-server.port`.
3. `rc up` found no port file, baked no `BEADS_DOLT_SERVER_PORT` into the container, and handed the container over. The in-container wrapper's D7 diagnostic did fire on the first call — but the user had already seen bd's raw TCP error from an earlier rebuild when the env *had* been stale, and the wedge's symptom (drifting ports) didn't match D7's "port is 0/empty" wording.

The deeper issue: **`rc up` treats the server-mode bd contract as best-effort.** It reads whatever port file exists, sets env, and starts the container. Nothing on the host verifies the contract holds before handing control over. ADR-007's existing decisions all operate inside the container, which is the wrong layer — by then the broken state already exists.

The existing ADR-007 "Deferred" list names this exactly: *"Health check for host Dolt connectivity — would improve error messages but doesn't prevent the corruption scenario."* The mapular incident shows improved error messages aren't cosmetic; they're the difference between a 30-second recovery and an hour of port-drift debugging.

## Scope

In scope:
- A host-side pre-flight at `rc up` that diagnoses server-mode bd contract violations and warns with a specific next action.
- Same diagnostic logic, invocable on demand via `rc test`.

Out of scope:
- Blocking container start on failure — bd is optional; many rip-cage users never touch it. (Explicit ADR-001 exception: fail-loud is the project default; bd pre-flight warns and continues because bd is an optional subsystem. See ADR-007 D8 rationale.)
- Wrapper-level detection of stale (listening-but-wrong) ports — subsumed by host-side pre-flight; the wrapper's existing D7 handles the port-missing/zero case, which is sufficient defense-in-depth.
- Automatic recovery (killing wedged PIDs, auto-starting dolt) — escalation to the user is correct. The incident showed that wedged state can have legitimate non-obvious causes (legacy containers) the tool shouldn't guess at.

## Design

### Component: `_bd_host_preflight()` helper in `rc`

A single function, called from `cmd_up` (after `dolt_mode` is determined, before `docker run`) and from `cmd_test`. Inputs: resolved `beads_dir` on host, `beads_dolt_mode`. Output: one of five states, each with a tailored warning.

```
State                                               Action at rc up    Action at rc test
-----                                               ----------------    -----------------
embedded / dolt_mode unset                          skip check           PASS (not applicable)
server-mode + port file present + listening         no warning           PASS
server-mode + port file missing                     warn (case A)        FAIL with case A diag
server-mode + port file present + unreachable      warn (case B)        FAIL with case B diag
server-mode + port file present + corrupt content  warn (case C)        FAIL with case C diag
```

**Port file validation.** `bd dolt start` writes a bare integer plus a trailing newline. The helper reads with `$(cat "$port_file")` (strips the trailing newline) and validates `[[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 ))`. Empty files, whitespace-only content, non-numeric content, zero, and out-of-range values all fall into **case C (corrupt)** — distinct from case A (file absent) because the remediation differs slightly (the user may need to delete the file before `bd dolt start` will rewrite it cleanly). This also prevents the pathological `/dev/tcp/127.0.0.1/` (empty port) construct, which would be a bash syntax error at runtime.

**Port probe mechanism.** bash `/dev/tcp/127.0.0.1/$port` with a 1-second timeout. `timeout(1)` is **not** installed by default on macOS (the primary dev platform, bash 3.2), so the helper uses a bash-3.2-compatible background-kill idiom:

```bash
# probe returns 0 if connected, non-zero otherwise
_probe_tcp() {
  local host=$1 port=$2
  (
    exec 3<>/dev/tcp/"$host"/"$port"
  ) 2>/dev/null &
  local pid=$!
  ( sleep 1; kill "$pid" 2>/dev/null ) 2>/dev/null &
  local killer=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$killer" 2>/dev/null
  return "$rc"
}
```

Rationale: no `nc` dependency, no `timeout` dependency, localhost-only (`host.docker.internal` is a Docker-side alias — on macOS/Windows Docker Desktop hosts the server lives on `127.0.0.1`; on Linux hosts bd binds loopback by default, so `127.0.0.1` is correct there too — if a user has reconfigured bd to bind elsewhere, pre-flight may warn spuriously). 1s is generous for a loopback connect. The check runs once per `rc up` and once per `rc test` invocation — latency budget is trivial.

**Case A (port file missing):**
```
Warning: beads server-mode enabled but .beads/dolt-server.port is missing.
  Likely cause: bd server has not been started yet in this project (or has never started successfully).
  Fix: on the host, run `bd dolt start` in <project-root>
  If that fails with "database locked", a stale dolt process is holding the lock.
  Check with: lsof -iTCP -sTCP:LISTEN -P -n | grep dolt
  Then kill the wedged PID and retry.
Continuing anyway — bd calls inside the container will fail until resolved.
```

**Case B (port file present but unreachable):**
```
Warning: .beads/dolt-server.port says port <N>, but nothing is listening there.
  Likely cause: the bd server crashed or was killed; the port file is stale.
  Fix: on the host, run `bd dolt start` in <project-root>
  (this will rewrite the port file to the new port).
Continuing anyway — bd calls inside the container will fail until resolved.
```

**Case C (port file corrupt):**
```
Warning: .beads/dolt-server.port contains invalid content (expected a port number).
  Likely cause: interrupted write, disk issue, or a non-bd writer touched the file.
  Fix: on the host, delete the file and re-run `bd dolt start` in <project-root>:
    rm <project-root>/.beads/dolt-server.port
    bd dolt start
Continuing anyway — bd calls inside the container will fail until resolved.
```

All three messages end with **"Continuing anyway"** — `rc up` proceeds and creates the container. The user may not need bd in this session, or may be prepared for the failure.

### Integration point 1: `cmd_up`

Insert the preflight call immediately after `rc:947` (the line that bakes `BEADS_DOLT_SERVER_PORT` into `_UP_RUN_ARGS`), still inside the server-mode branch. Running it after env baking — rather than before — keeps the decision order clean: env is authoritative regardless of probe result; the probe only affects whether we *warn*.

**Ordering dependency on D6 (worktree auto-redirect).** At this insertion point, `beads_dir` has already been rewritten by the D6 block (rc:905-931) to the *main repo's* `.beads/` when a worktree with no runtime data is detected. This is deliberate — worktree projects probe the main repo's port file, matching what the container will actually see at `/workspace/.beads/`. If D6 fell through with its own "main repo .beads/ not found" warning, the pre-flight will additionally emit case A; stacked warnings are fine, both actionable. A future refactor must not move the pre-flight earlier than the D6 block without reconsidering this.

### Integration point 2: `cmd_test`

Today's `cmd_test` (rc:1575-1622) is entirely host-side-thin: it `docker exec`s four in-container test scripts (`test-safety-stack.sh`, `test-skills.sh`, `test-egress-firewall.sh`, `test-bd-roundtrip.sh`) and parses their `PASS|FAIL [N] name — detail` lines, with per-script-local `[N]` numbering (there is no global check count). The host-side bd pre-flight is a new class of check — it has no container-side counterpart to delegate to.

**Splicing approach.** Before the existing `docker exec` in `cmd_test`, `_bd_host_preflight` emits one line to stdout in the same `PASS|FAIL [N] slug — detail` format used by the in-container scripts. That line is prepended to the captured output, so the existing JSON parser (`while IFS= read -r line`) handles it identically. The text-mode branch prints the line directly before invoking the container scripts. Concretely:

- Embedded / unset: `PASS [0] beads-host-dolt — not applicable (embedded mode)`
- Server-healthy: `PASS [0] beads-host-dolt — dolt reachable on 127.0.0.1:<N>`
- Case A: `FAIL [0] beads-host-dolt — port file missing; run \`bd dolt start\``
- Case B: `FAIL [0] beads-host-dolt — stale port <N>; run \`bd dolt start\``
- Case C: `FAIL [0] beads-host-dolt — corrupt port file; rm + \`bd dolt start\``

`[0]` signals "host-side" (in-container scripts number from 1). The existing JSON shape (`{name, status, detail}` per check) is preserved without adding new fields — the detail string carries the state.

**`beads_dir` discovery from a running container.** `cmd_up` has `beads_dir` as a local after D6; `cmd_test` does not. For D9 the helper derives `beads_dir` from `docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/workspace" }}{{ .Source }}{{ end }}{{ end }}' <container>` → that returns the host-side project root, and `beads_dir="${source}/.beads"`. If the mount isn't present (non-rc container, or a dev-container with a different destination) the check emits `PASS [0] beads-host-dolt — workspace mount not found (skipped)` rather than failing. Then the same D6-style auto-redirect logic runs (if `beads_dir` lacks runtime data and the project is a git worktree, resolve to the main repo's `.beads/`) so the probe matches what the container sees.

### What this does *not* solve

- The very first `rc up` of a fresh server-mode project, before the user has ever run `bd dolt start`, will always warn (case A). That's correct — the contract genuinely isn't met yet. The warning is exactly what the user needs, and the softened wording ("has not been started yet … or has never started successfully") avoids implicit blame on a clean project.
- Race conditions where the host dolt dies *between* the pre-flight check and an in-container `bd` call. The wrapper's existing D7 remains the last line of defense; this design doesn't weaken it.
- First-use race in the other direction: user runs `bd dolt start` in one terminal and `rc up` in another within a sub-second window; port file may briefly contain the previous run's stale content, producing a spurious case B. Extremely rare in practice (port file rewrite is atomic enough), and the warning remains actionable — left uncaught intentionally to avoid complexity.
- Legacy containers created before this change ships. They'll still hit the in-container D7 path on first bd failure.

## Testing

Tiers per [ADR-013](decisions/ADR-013-test-coverage.md):

- **Tier 1 (host-unit, no docker).** Add `tests/test-bd-host-preflight.sh` with fixture `.beads/` directories covering all five states (embedded, server-healthy, server-port-missing, server-port-stale, server-port-corrupt). Assert helper's stdout `PASS|FAIL [0] beads-host-dolt — …` line per case and non-zero exit only for cases A/B/C when called via a test-only "strict" entry point (the real helper never exits non-zero — it always warns-and-continues at integration points).
- **Tier 3 (host-integration).** Extend `tests/test-rc-commands.sh` with an assertion that `rc test` on an embedded-mode fixture produces the `beads-host-dolt` line with `status=pass` in JSON mode and text mode. The stale-port case is synthesised by writing a bogus port (e.g., `65000` with nothing listening) into `.beads/dolt-server.port`; the corrupt case by writing `not-a-number`.
- **Tier 4 (e2e, optional).** A single lifecycle run in `tests/test-e2e-lifecycle.sh` or the equivalent, confirming `rc up` against a server-mode project with a missing port file produces the case A warning on stderr and still brings the container up.

## Migration / rollout

No migration. The change is additive:
- Existing containers keep working. If they were broken, they were broken before.
- No config changes, no breaking env var changes, no Dockerfile rebuild required (host-side only).
- ADR-007 D7 stays in place; this design explicitly layers on top of it.

## Risks

- **False-positive warnings** in the first-use case. Mitigated by the warning text telling users exactly what to do. Acceptable because the alternative is the mapular scenario: a silent contract violation.
- **Probe hitting the wrong service.** The probe tests `127.0.0.1:<port-from-port-file>`. If an unrelated service is listening on that exact port, the probe succeeds and we stay silent — a true-positive on "something is listening" but a false-negative on "it's actually dolt". Acceptable: the port file was written by bd itself, so the port is bd's allocation; collisions are rare and the in-container wrapper will still surface the real error when bd actually tries to talk to it.
- **Non-macOS host divergence.** Probe assumes bd binds loopback. On Linux hosts where a user has explicitly reconfigured bd to bind a non-loopback interface, pre-flight will false-negative. Documented; no code path for now. If it becomes a real complaint, the fix is to read bd's config rather than hard-coding `127.0.0.1`.
