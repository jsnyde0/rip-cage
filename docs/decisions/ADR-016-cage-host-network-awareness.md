# ADR-016: Cage Host-Network Awareness

**Status:** Accepted
**Date:** 2026-04-22
**Design:** [Cage Host-Network Awareness](../2026-04-22-cage-host-network-awareness-design.md)
**Related:** [ADR-002](ADR-002-rip-cage-containers.md) (container model), [ADR-007](ADR-007-beads-dolt-container-resilience.md) (`host.docker.internal` precedent for beads), [ADR-012](ADR-012-egress-firewall.md) (egress allowlist), [ADR-015](ADR-015-mise-toolchain-provisioning.md) (init-script extension pattern)

## Context

On 2026-04-22 a cage-side agent running a test pipeline could not reach the host's Postgres and spent a ten-minute round-trip with the user rediscovering that (a) `localhost` in the cage is cage-local, (b) `host.docker.internal` / `host.orb.internal` resolve to the host, and (c) a sibling compose service without a `ports:` mapping is not reachable across compose networks. None of this knowledge lives in the cage's context today. The cage's `init-rip-cage.sh` already hardcodes `host.docker.internal` for the beads Dolt server (ADR-007), but that's invisible to the agent.

The cost of the gap is not a one-off: every project that puts services (DB, Redis, a local API, a Vite dev server on the host) outside `/workspace` will hit the same wall. The fix is informational plumbing, not architectural surgery.

## Decisions

### D1: Baked-in cage-side CLAUDE.md appended to `~/.claude/CLAUDE.md` at init

**Firmness: FIRM**

A file `/etc/rip-cage/cage-claude.md` ships in the image and is appended (under fenced `<!-- begin:rip-cage-topology --> ... <!-- end -->` markers) to `~/.claude/CLAUDE.md` during `init-rip-cage.sh`, after the host-authored global CLAUDE.md is copied in. It documents:

- The cage is a Linux container; `localhost` is cage-local.
- The host is reachable at `$CAGE_HOST_ADDR` (populated by D2) — fallback literal `host.docker.internal`.
- Sibling docker-compose services need `ports:` exposed or a shared compose network; provides a one-line `getent` / `socket.connect` probe recipe.
- Points to ADR-012 to distinguish "host is reachable" from "internet is filtered."

**Rationale:** The agent's failure mode was *informational*, not structural — it recovered correctly once it had the facts. CLAUDE.md is the right delivery mechanism because Claude Code loads it into every session automatically; no tool call, no MCP wiring, no probe latency. Appending (rather than replacing) preserves the host-authored content that the user already relies on. Fenced markers make the cage section idempotently rewriteable across reboots and trivially greppable in tests.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Append to `~/.claude/CLAUDE.md` at init (this decision)** | Auto-loaded by Claude Code; no MCP; idempotent; testable | Adds ~40 lines to every agent's global context |
| Ship as a standalone skill | Loaded on demand; zero context cost when unused | Agents only trigger skills they know about; failure here is "agent doesn't know there's relevant guidance" — skill discovery doesn't help |
| Write to a new `/etc/cage/network.md` and rely on agent discovery | Zero context cost | Agent has no reason to read it; defeats the point |
| Put the content in the project-level `CLAUDE.md` | Lowest-level wins in Claude's precedence | Would require rip-cage to mutate the user's project files; non-starter |
| Replace (not append) global CLAUDE.md with cage content | Cleaner layering | Loses the user's host-authored guidance, which is the main reason CLAUDE.md copy exists |

**What would invalidate this:** Context-length cost observed to matter in practice (e.g., CLAUDE.md crossing a budget that degrades agent performance). Mitigation is to move detail into the skill tier and keep only a pointer in CLAUDE.md. Not needed today.

### D2: Startup preflight probe populating `$CAGE_HOST_ADDR`

**Firmness: FIRM**

A step in `init-rip-cage.sh` (new step 7a, after toolchain / before Claude-Code-verify) probes candidate host-bridge hostnames in order — `host.docker.internal`, then `host.orb.internal` — using `getent hosts`. The first that resolves is written to `/etc/rip-cage/cage-env` as `export CAGE_HOST_ADDR=...`, and that file is sourced by `~/.zshrc` (same mechanism as `firewall-env`). It is also injected into Claude Code's process env via the settings.json `env` block so agent-initiated `Bash` tool calls inherit it without an interactive shell.

If no candidate resolves, the probe logs a WARNING and **still writes the literal `host.docker.internal`** to `cage-env` as a fallback. Agents reading the cage-authored CLAUDE.md (D1) expect `$CAGE_HOST_ADDR` to always be defined; leaving it unset on air-gapped boots produced a confusing empty-string expansion (`connect(('', 5432))`) instead of a `connection refused` the agent can diagnose. Offline / air-gapped use remains valid — the variable is set, it just won't resolve, which is the same failure mode an agent sees when the host has no service on that port.

**Rationale:** DNS-only probe is the smallest correct thing — it confirms the bridge exists without making assumptions about what services the user is running or on which ports. The ordering matters: `host.docker.internal` is the standard across Docker Desktop, OrbStack, Podman Desktop, and Rancher Desktop; `host.orb.internal` is an OrbStack-specific alias kept only as a secondary probe because it appeared in the incident transcript. Writing to `/etc/rip-cage/cage-env` mirrors the firewall-env pattern so downstream tooling (agent shells, tmux panes, Claude Code child processes) gets a uniform surface.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **DNS-only probe, write env var (this decision)** | Cheap (<100ms); runtime-agnostic; one clear surface | Doesn't verify any specific service is reachable |
| Probe DNS + a well-known port (e.g., 22, 80) | Stronger signal | No port is universally present on a dev host; false negatives |
| Skip probe, hardcode `CAGE_HOST_ADDR=host.docker.internal` | Zero init cost | Breaks on rare runtimes where the name differs; no warning signal |
| Detect runtime (Docker vs OrbStack vs Podman) and pick a name | Most principled | More code for a problem solved by "try names in order" |
| Expose the host IP directly (`host-gateway`) | Skips DNS entirely | IP is not stable across runtimes/restarts; hostname is |

**What would invalidate this:** A runtime emerging that uses neither `host.docker.internal` nor `host.orb.internal`. Extend the candidate list; no architectural change. Alternately, a future decision to join project compose networks (`rc up --join-network`) would make `$CAGE_HOST_ADDR` less often the right answer — the CLAUDE.md would then grow a section on when to prefer compose-DNS names. Revisit at that point.

### D3: No port probing, no compose-network join, no docker.sock

**Firmness: FIRM**

This ADR scopes strictly to informational plumbing:

- **Port probes are the agent's job.** A cage startup that tries to probe ports would be guessing at user intent and would either be too slow (probe many) or too narrow (probe few). The CLAUDE.md hands the agent the one-liner; the agent decides what to probe.
- **Joining project compose networks is out of scope.** It is a real future option (sketched as "Option C" in the exploration transcript) but touches `rc up`'s CLI surface, the project-network trust boundary, and lifecycle semantics. Separate ADR when demand materializes.
- **Mounting `/var/run/docker.sock` is rejected, not deferred.** Sock-in-cage ≈ host root in cage; incompatible with the safety-stack premise of ADR-002.

**Rationale:** The incident cost was bounded by lack of knowledge, not lack of capability. Informational fixes first; structural fixes when they pay their blast-radius cost.

**What would invalidate this:** Three or more recurring incidents where the agent correctly had the network info but still could not reach a service because of missing compose-network membership. That's the signal to revisit `--join-network`. Track via beads.

## Deferred

- **`rc up --join-network <name>`.** Attach the cage to an existing docker network so sibling compose services are reachable by service DNS name, no port mapping needed. Requires separate ADR covering network selection, trust, and teardown.
- **Host-service bootstrapping hints.** A command like `rc doctor --host-services` that scans the user's running compose projects and lists reachability status. Possibly useful; not essential.
- **Firewall-allowlist coupling.** Verifying `$CAGE_HOST_ADDR` is allowed by the egress firewall (ADR-012) is currently implicit (gateway IP is permitted by default). Making it explicit — e.g., the probe asserts reachability against the firewall ruleset — is a nicety, not a blocker.
- **Runtime-specific diagnostics in `rc doctor`.** E.g., "you're on OrbStack, both `host.docker.internal` and `host.orb.internal` resolve — here's which one we picked and why." Nice-to-have.
