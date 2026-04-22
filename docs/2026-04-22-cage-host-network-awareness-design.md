# Cage Host-Network Awareness

**Status:** Draft
**Date:** 2026-04-22
**ADR:** [ADR-016](decisions/ADR-016-cage-host-network-awareness.md)

## Problem

On 2026-04-22, an agent inside a rip-cage container (running `/send-it` on a Django project) hit a pipeline blocker: it could not reach Postgres to run tests. The agent's recovery loop, reconstructed from the transcript:

1. Tried `localhost:5432` — failed. Cage localhost ≠ host localhost.
2. Tried `127.0.0.1`, `db`, `postgres` — failed.
3. Proposed four workarounds to the user (run PG on host / external test runs / static-only / SQLite override), all with real costs.
4. Eventually discovered `host.orb.internal` resolves via `getent hosts`.
5. Discovered the project's `docker-compose.yml` had no `ports:` mapping on `db`, so even with the right bridge name the port wasn't exposed.
6. Added `ports: - "5432:5432"` to the project's compose; user ran `docker compose up -d db`; agent connected via `host.orb.internal:5432`. Green.

The workaround took ~10 minutes of round-tripping with the user. **None of the knowledge required to short-circuit this loop is in the cage's context today.**

What the agent had to rediscover:

- The cage is a Docker container — `localhost` is cage-local, not host-local.
- The host is reachable at `host.docker.internal` (Docker Desktop, OrbStack) and also at `host.orb.internal` (OrbStack-specific alias).
- A docker-compose service on the host is only reachable from a *sibling* container if it publishes a port; services without `ports:` live on their compose-private network.
- The egress firewall (ADR-012) may or may not permit the host IP; currently `host.docker.internal` resolves to a LAN-adjacent address that is allowed by the default allowlist (this happens to work but is not documented).

## Design

Two small, independently useful additions:

### Part A: Cage-side CLAUDE.md

A baked-in `/etc/rip-cage/cage-claude.md` is appended to the agent's `~/.claude/CLAUDE.md` at init time. It documents the cage's network topology **from the cage's perspective**, including:

- You are in a Linux container on macOS/Linux host; host FS is mounted at `/workspace` only.
- `localhost` / `127.0.0.1` refer to the cage, not the host.
- To reach a service running on the host, use `$CAGE_HOST_ADDR` (populated by preflight — see Part B) or `host.docker.internal`.
- A docker-compose service in another project is reachable from the cage only if:
  (a) it publishes a port (`ports:` mapping), *or*
  (b) the cage is attached to that project's compose network (future `rc up --join-network`; not in this ADR).
- Diagnostic one-liners: `getent hosts host.docker.internal`, `python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('host.docker.internal', PORT)); print('OPEN')"`.
- The cache mount / beads Dolt server / firewall CA trust already use this bridge — examples the agent can pattern-match against.

**Shape:** ~40 lines, prose + two fenced code blocks. Short enough to not bloat context; specific enough that an agent hitting "connection refused" sees the answer.

**Placement in global CLAUDE.md:** appended under a fenced section marker, e.g.:

```
<!-- begin:rip-cage-topology -->
...
<!-- end:rip-cage-topology -->
```

Host-authored global CLAUDE.md content stays above; cage-authored content below. Idempotent: init re-runs `cat` to rebuild the file each boot, so edits the agent makes to `~/.claude/CLAUDE.md` are not preserved across restarts (they shouldn't be anyway — that's what beads memories / `bd remember` is for).

### Part B: Startup preflight probe

`init-rip-cage.sh` gains a new step (between toolchain provisioning and Claude-Code-verify) that probes host reachability and writes the result to `/etc/rip-cage/cage-env`:

```bash
# Probe host bridges in preference order.
# host.docker.internal is universal (Docker Desktop, OrbStack, Podman Desktop).
# host.orb.internal is an OrbStack-specific alias kept as a secondary signal.
_cage_host_addr=""
for candidate in host.docker.internal host.orb.internal; do
  if getent hosts "$candidate" >/dev/null 2>&1; then
    _cage_host_addr="$candidate"
    break
  fi
done

if [ -n "$_cage_host_addr" ]; then
  sudo tee /etc/rip-cage/cage-env >/dev/null <<EOF
export CAGE_HOST_ADDR="$_cage_host_addr"
EOF
  echo "[rip-cage] Host bridge: $_cage_host_addr"
else
  echo "[rip-cage] WARNING: no host bridge resolvable (host services will be unreachable)" >&2
fi
```

Sourced by `~/.zshrc` (same pattern as `firewall-env`), so every interactive shell, tmux pane, and Claude Code child process gets `$CAGE_HOST_ADDR` on PATH.

**No port probing.** The probe confirms DNS resolution only; we do not try ports because we don't know which services the user is running. The CLAUDE.md documents how the agent can probe a specific port when it needs to.

**No runtime detection.** We don't try to classify "this is OrbStack vs Docker Desktop vs Podman" — the relevant datum is the resolvable hostname, not the runtime.

**Fail-warn, not fail-loud.** A cage without host bridging is unusual but not unusable (offline work, air-gapped envs). Warn and continue.

## Non-goals

- **Auto-joining project compose networks.** Useful (sketched as Option C in the exploration) but scope creep for this ADR; has real ergonomic and safety-model questions. Deferred.
- **Mounting docker.sock so the cage can run `docker compose up`.** Rejected — gives cage processes host-root, breaks the safety stack premise.
- **Rewriting project compose files to add port mappings.** The agent already does this when needed; it's not rip-cage's job to mutate user projects.
- **Per-port reachability probe.** Project-specific; agent can do it in seconds with the documented one-liner.

## Rollout / test plan

- `tests/` gets a new assertion: after `rc up`, `docker exec <c> bash -lc 'echo $CAGE_HOST_ADDR'` is non-empty and resolvable.
- `tests/` asserts `grep -c 'begin:rip-cage-topology' ~/.claude/CLAUDE.md` is 1 (not 0, not 2 — catches double-append regressions).
- `tests/` asserts disk (`cage-env`) and merged `settings.json` agree on the value (catches silent jq-merge failures).
- `tests/` asserts `.zshrc` sources `cage-env` exactly once (catches duplicate-source regressions on container resume).
- `SKIP_HOST_BRIDGE=1` demotes the resolution assertion to INFO for air-gapped CI.
- Manual check: start any service on host (`python3 -m http.server 8765 --bind 0.0.0.0`), `rc up` a test project, from cage run `curl -s "http://$CAGE_HOST_ADDR:8765/"` — expect HTML.

## Open questions

- **Should `$CAGE_HOST_ADDR` be exported to Claude Code as an env var too?** Leaning yes (via settings.json `env` block) so tool calls from the agent inherit it without needing an interactive shell. Trivial to add.
- **Firewall allowlist interaction.** `host.docker.internal` currently resolves to a host-gateway IP that the default egress allowlist permits for outbound. Worth a line in the CLAUDE.md confirming "host is reachable, internet is filtered per ADR-012" so the agent doesn't conflate the two.
