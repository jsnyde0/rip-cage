# R1 prior art: what rip-cage had for cage-to-host calls, and why each was removed (bead rip-cage-mgp6)

Date: 2026-11-06. Research only; no code touched. Citations are ADR+decision, commit (short sha), bead id, or doc path. Bead states are from `bd show`/`bd search`.

**Headline finding.** No configured "host-tool line" (a project-config line that names a host tool and the verbs the cage may call) ever existed in rip-cage. A repo-wide search of ADRs, docs, history, examples and `git log -S` found no such feature. What existed were five cage-to-host mechanisms, each with a different shape. Four are RETIRED. The fifth is a LIVE informational stub that carries no capability (section 4). A sixth item (section 5) is an idea that was captured but never built. The nearest things to the recalled "configured line" are the retired `network.egress.mediator` / `network.http.forward_to` config fields (section 2) and `ssh.allowed_hosts` / `ssh-agent-filter` (section 1). Neither was a host-tool call. One was an in-cage proxy and the other was a filtered ssh-agent socket.

---

## 1. ssh-agent forwarding (the only real host-socket forward) — RETIRED

**What it was.** `rc up` bind-mounted the host's ssh-agent socket read-write into the cage at `/ssh-agent.sock` and set `SSH_AUTH_SOCK` there, so the agent could sign git pushes with host keys. ADR-017 D1-D4 (2026-04-23) set this up, flipping ADR-014's push-less default. Cites: ADR-017 "Decisions" ("`rc up` mounts the host's ssh-agent socket read-write into the container at `/ssh-agent.sock`"); commit `3c6e74c` (design), bead rip-cage-29w.

**How the cage reached the host (Docker era).** This was a Docker bind-mount of a unix socket:
- Linux and WSL2 bind-mounted `$SSH_AUTH_SOCK` directly (ADR-017 platform table).
- macOS under OrbStack / Docker Desktop can proxy only ONE AF_UNIX path across the VM boundary, `/run/host-services/ssh-auth.sock`. ADR-018 (2026-04-24) replaced fixed paths with a host-side probe-and-pick loop (`ssh-add -l` against each candidate, then bind-mount the winner). It also wrote `/etc/rip-cage/ssh-agent-socket` and `ssh-agent-status` sentinels. Cite: ADR-018 Decision text and the 2026-04-25 amendment.
- A sudoers grant for `chown agent:agent /ssh-agent.sock` was needed because OrbStack exposes the proxy socket with an unusable gid (ADR-018 amendment 2026-04-25; bead rip-cage-okp, closed).

**Later layers, all around the same socket.**
- ADR-020 (2026-04-27): ssh identity routing, translating `~/.ssh/config` into the cage because the forwarded agent holds ALL host keys (`ssh -T git@github.com` answered as the wrong account in a work cage). Cite: ADR-020 Context.
- ADR-022 (2026-05-12, commit `fd9d07c`, `rip-cage-b0c`): `ssh.allowed_hosts` and key allowlist in `.rip-cage.yaml`, a filtered `ssh-agent-filter` socket, filtered `known_hosts`, and (D5, `rip-cage-nww`) a `block-ssh-bypass.sh` hook closing `-o` CLI overrides. This is the closest thing to a "configured line" that scoped what a cage could call on the host.

**Docker-era answer to "did Docker bind-mount a host socket?"**
- Yes, exactly one: the ssh-agent socket above.
- No docker.sock. ADR-016 D3: "Mounting `/var/run/docker.sock` is rejected, not deferred. Sock-in-cage ≈ host root in cage; incompatible with the safety-stack premise of ADR-002." Same in `docs/2026-04-22-cage-host-network-awareness-design.md` (non-goals list).
- No bd/dolt socket was mounted. beads reached the host over TCP (section 3).

**RETIRED when and why.**
1. The msb cutover, ADR-029 D3 (FIRM, 2026-07-10), retired the whole cluster ADR-017/018/020/022. The code removal landed in commit `cfa2a33` (2026-07-12, "S5 - retire the ssh cluster"). ADR-029 gives two reasons:
   - It retired by its own predicate. ADR-017 D4 and ADR-018 D1 had said that moving to bot-identity tokens would make the agent-reachability question moot. msb `--secret` made token non-possession free, so the canonical git path became HTTPS + `--secret`, with the per-cage token as the identity scope.
   - The mechanism could not work on msb as-is. Spike rip-cage-r6bo (`docs/2026-07-09-msb-spike-ssh-agent.md`) found:
     - msb refuses to mount a socket file (`mount: ... Not a directory`; `mount-file source is not a regular file`).
     - virtiofs shares the socket inode but not a live endpoint (`ssh-add -l` returns "Connection refused").
     - `msb ssh serve` does not support `-R` / stream-local forwarding.
     - The `host.microsandbox.internal` gateway fake-accepts TCP, so a socat bridge through it carries zero bytes.
2. A socat bridge over the host's real LAN IP DID work (rip-cage-akg5, `docs/2026-07-09-msb-spike-lan-ip-host-service.md` Q2: `ssh-add -l` listed host keys and `git ls-remote git@github.com` succeeded). ADR-029 D3 still declined it as the default. The reason given in its Alternatives table: "whole-agent forwarding with no per-key scoping (spike-observed work-account identity leak); would require rebuilding ssh-agent-filter atop an exposure surface D7's probe set is still measuring." It was demoted to "a composed example recipe only, never blessed (ADR-005 D12)".
3. What survived: only static files, the pinned `ssh_known_hosts` and `ssh_config.d` (`BatchMode yes`, `StrictHostKeyChecking yes`). They stay as no-prompt hygiene, not as a host call. Cite: ADR-029 D3 "What survives the retirement".

---

## 2. Egress MEDIATOR seam (`network.egress.mediator`, `network.http.forward_to`, `--mediator-env`) — RETIRED

**What it was.** ADR-026 D5 (2026-06-11/16/17, FIRM since the 2026-06-17 E4 proof) made egress mediation a composable-provider seam, isomorphic to the multiplexer seam (ADR-005 D12). It had these parts:
- A config selector `network.egress.mediator` (default `none`).
- A MEDIATOR tool-manifest archetype with `start` / `health_check` / `teardown` hooks baked to `/etc/rip-cage/mediators/<name>/`.
- `network.http.forward_to`: the cage's in-cage HTTP router CONNECT-forwarded allowed traffic to the mediator's listen address.
- A host-driven root launch step (`init-mediator.sh`, `--mediator-env` env file, `rc.mediators` and `rc.mediator-ca-env` container labels).
- `config`-level `auth.credential_mounts` and `network.egress.mediator_env_file` (bead rip-cage-seqc.4).
- Example recipes `examples/iron-proxy/` and `examples/mitmproxy/`.
- Beads: rip-cage-ta1o.5.1/.2/.3/.7/.8, rip-cage-nyst, rip-cage-oslv. Commits `72f957a`, `e92c1ae`.

**How the cage reached the host.** It did not call out to the host. The mediator ran CO-LOCATED IN THE CAGE (a proxy process launched by a host-driven root `docker exec`). The only host-to-cage channel was the secret, passed via an env file with a leak-free channel (commit `e92c1ae`, rip-cage-ta1o.5.8; seqc.4 "secret value flows only into docker exec -u root -e"). Relevance to a host-tool line: this was the only previous "declare an external thing in config and rc wires it" seam. It was about mediating HTTP, not about letting the cage invoke a host verb.

**RETIRED when and why.**
- ADR-029 D2 and D5 (2026-07-10): "`init-mediator.sh` and the MEDIATOR launch machinery: deleted, not ported". The deletion sweep was bead rip-cage-3vj2 (commit `cae1811`). The ADR-026 D5 banner lists the full sweep, including the `network.egress.mediator` + `forward_to` fields and the MEDIATOR archetype.
- Reason 1: its own predicate fired. ADR-026 D4 said to drop the in-house path if "a single-mechanism, genuinely low-drift injection covering the dominant secret... that does NOT pull in per-service maintenance" emerged. msb `--secret` is that mechanism (ADR-029 D5 "Alternatives": keeping iron-proxy as primary is rejected because the runtime primitive "needs no per-cage mediator lifecycle, and its violation guard is enforced below the guest").
- Reason 2 (drift): ADR-026 D2 sorts layers by maintenance drift-rate. A parallel in-cage engine "fails the same test that outsourced mediation" (ADR-029 D2 Rationale).
- Cleanup of the recipes: commit `ee1198a` (2026-09-17). `examples/README.md` section "Mediator recipes - DROPPED" says there is no `rc`-side mediator surface left, and that L7 policy is "fully operator-composed and unwired".
- The manifest itself retired in ADR-031 D4 (commit `dceaa10`, 2026-09-16, "retire the tools manifest"). That removed the archetype machinery for good. Composition is now the operator's own `FROM rip-cage:latest` Dockerfile plus `boot.json`.

**Surviving precedent.** ADR-026 D5's rule that rc "owns the interface, blesses no mediator, `none` ships by default". It is the template for a tool-agnostic seam under ADR-005 D12.

---

## 3. beads/Dolt server mode via `host.docker.internal` (cage dials a host TCP service) — RETIRED

**What it was.**
- ADR-007 D1 and ADR-002 D10 (amended 2026-03-27 per ADR-004 D1): the in-cage `bd` wrapper set `BEADS_DOLT_SERVER_MODE=1` and `BEADS_DOLT_SERVER_HOST=host.docker.internal`, and re-read `/workspace/.beads/dolt-server.port` on every call. The container's bd talked to the HOST's Dolt server, to avoid database lock conflicts.
- ADR-016 (2026-04-22, commit `d55ea48`) added the informational layer: `CAGE_HOST_ADDR` plus a cage-side CLAUDE.md block about how to reach the host.

**How the cage reached the host.** Via Docker's host gateway name (`host.docker.internal`, or `host.orb.internal`), a plain TCP dial to a host-bound service. No socket forwarding and no mediation.

**RETIRED when and why.**
- ADR-029 D7 (FLEXIBLE) says the name does not exist under msb: "`host.docker.internal` does not exist under msb, so the container-connects-to-host-Dolt-server mechanism ... has no path forward as written" (banners on ADR-002 D10 and ADR-007 D1).
- Measured basis: `host.microsandbox.internal` fake-accepts TCP and delivers nothing (r6bo, `docs/2026-07-09-msb-spike-ssh-agent.md` Q2 candidate (a), two-port control). Only the host's real LAN IP delivers (rip-cage-akg5).
- Replacement: an interim single-writer discipline over the virtiofs mount (ADR-029 D7, in CLAUDE.md "Beads over the msb mount"), because virtiofs does not propagate `flock` in either direction (rip-cage-9iab; rip-cage-606c A1 showed Docker bind mounts did not either).
- The durable host-service topology was explicitly NOT built. ADR-029 D7 Alternatives: "Build the host-service beads topology now - `direct:` user call 2026-07-10 - a beads-only service is poor ROI while beads itself is under re-evaluation". It was captured as rip-cage-o7tx (section 5).

---

## 4. `CAGE_HOST_ADDR` host-bridge probe (ADR-016) — LIVE, informational only

`cage/init/init-rip-cage.sh` (`_rc_probe_host_bridge`, lines ~25-55) still resolves a host address. It honors an rc-passed `CAGE_HOST_ADDR`, then tries `host.microsandbox.internal`, `host.docker.internal`, `host.orb.internal` (commit `77f1aac`, rip-cage-woox, 2026-09-14). Its own comment notes the msb name is a fake-accept gateway (ADR-029 D6 + the 2026-07-09 spike). So it tells the agent a name exists, but nothing behind it delivers. It is not a capability, and it should not be mistaken for a prior host-call seam. ADR-016 is still "Accepted" in `docs/decisions/INDEX.md`, and ADR-016 D3 pins "no port probing, no compose-network join, no docker.sock".

---

## 5. Host-service seam over scoped LAN-IP rules (rip-cage-o7tx) — CAPTURED, NEVER BUILT (EXPLORATORY)

**What it is.** A design capture. Operator-composed host services bind the host's LAN IP. rc owns LAN-IP discovery at cage start, liveness checks, the per-cage `--net-rule allow@<ip>:tcp:<port>`, and re-derivation on resume or network change. Services are never named or blessed (ADR-005 D12). The bead lists six candidate consumers: a beads single-writer, an OAuth refresher, pull-through caches, host MCP/agent tools, a telemetry collector, and a cross-cage bus. It is P3, open, with the instruction "Do NOT implement ... without an explicit user go" (bead `rip-cage-o7tx --design`; `docs/rip-cage-on-msb-direction.md`; ADR-029 D7 and Alternatives).

**Why it is not built (status, not removal).**
- The user deferred it on 2026-07-10, "beads-only service is poor ROI" (ADR-029 D7). The trigger is "a second consumer creates pull".
- The exposure is unresolved. A host listener MUST bind the LAN interface, because a 127.0.0.1 listener is unreachable from the guest even with an allow rule (akg5 Q4). The exposure floor is therefore the Wi-Fi/LAN, not the machine. Probe rip-cage-606c (`docs/2026-07-10-current-stack-parity-and-lan-exposure.md`) measured:
  - B1: guest traffic arrives from the host's OWN LAN IP, so an accept-only-from-self firewall rule is a candidate scoping, but the host cannot tell cage traffic from local processes.
  - B2: other-device reachability is PENDING-OPERATOR, never measured.
  - B3: offline shape is untested.
- Authentication: "reachable != authorized", so every service needs its own bearer token (o7tx NOTES).
- Facts proven that make it feasible: akg5 Q1 and Q2 show real byte exchange and an ssh-agent relay over the LAN IP. Verdicts are scoped to macOS/HVF, msb v0.6.4 (ADR-029 D6; Linux/KVM reconfirmation `rip-cage-4fxg` is a hard gate).
- Note: o7tx lists the OAuth-token refresher as a consumer. The 2026-10-25 / 2026-11-03 ruling on rip-cage-3w82 rejected an rc-side refresher; the operator re-runs the host helper `examples/pi-providers/codex-secret.sh` instead (ADR-029 D5 text, "rc never mounts the host's auth.json and never refreshes OAuth").

---

## 6. Adjacent channels that are NOT cage-to-host calls (for contrast)

- **Host-to-cage control (opposite direction):** the herdr unix-socket API inside the cage is driven by a host orchestrator via `msb exec`. See `examples/herdr/README.md` and commit `4ecd19a` (S14, rip-cage-lczu). The socket lives inside the guest. ARCHITECTURE is: host calls in, never cage calls out.
- **File-mount shims:** host-mounted skills reach the cage through read-only mounts and the in-guest `skill-server.py` MCP shim. This is a mount, not a call (CLAUDE.md "Skills in containers"). o7tx item 4 calls it "today served only by file-mount shims".
- **Secrets going in:** msb `--secret` (ADR-029 D5, ADR-031 D2). The `CCTOK` file is read host-side by `rc up`; the guest holds a placeholder. This is one-way and covers HTTP-header-swappable secrets only.

---

## Lessons for a host-tool line (recurring reasons things were removed)

1. **Platform could not carry it.** Unix-socket forwards died on msb because virtiofs shares no live endpoint, msb rejects socket mount sources, and `ssh serve` has no `-R` / stream-local forwarding (r6bo). The `host.*.internal` name is a fake-accept. The only delivering path is the host's real LAN IP (akg5). Any new line is TCP-over-LAN-IP or a non-network channel, and it inherits the exposure unknowns in section 5. Cites: ADR-029 D3/D6/D7; akg5; 606c.
2. **Exposure surface unresolved.** LAN-IP binding exposes the service to the LAN, and the host cannot distinguish cage traffic from local processes (606c B1). Other-device reachability was never measured (B2). This is the stated reason the ssh bridge was refused as default (ADR-029 D3 Alternatives) and why o7tx stays EXPLORATORY. Per-service auth tokens are required (o7tx NOTES).
3. **No scoping: the whole thing leaked identity.** Whole-agent forwarding gave the cage every host key, spawning ADR-020 identity routing and ADR-022's allowlist, filter and hook (about 4 ADRs of patch layers). Retirement was cleaner than the patches (ADR-029 D3). A host-tool line must declare verbs, not expose a general socket.
4. **Drift cost on a surface rc does not own.** The mediator and in-cage engine were deleted once the runtime offered the primitive, under ADR-026 D2's drift-rate test (ADR-029 D2). Anything rc builds on a host-service surface carries a lifecycle cost (liveness, network change, resume, repair loop), which is o7tx's "rc-altitude work" argument.
5. **Predicate-fired retirements.** ADR-017 D4, ADR-018 D1, and ADR-026 D4 each named the condition that would retire them, and msb `--secret` fired all of them. A host-tool line's ADR should state its invalidation predicate up front, in particular "what makes this unnecessary" (for example, if msb ships a native cage-to-host call).
6. **ADR-005 D12 / ADR-031 D4 pressure.** rc never names a tool. Tool wiring goes in the operator's Dockerfile and `boot.json`, and the manifest and tool archetypes were deleted (commit `dceaa10`). The surviving precedent for a tool-agnostic seam is the ADR-026 D5 shape: rc owns the interface and a deterministic wiring step, and ships with `none` by default. The retired mediator also had a config-level selector that rc read, which is the nearest design analogue to the human's recalled "configured line".
7. **Autonomy and prompt-injection (ADR-024).** The ssh agent was added specifically to remove a human-in-the-loop (ADR-017: "it's annoying we can't have the agent push"). Config must stay host-side outside every cage mount (ADR-031 D5a), so a prompt-injected agent cannot widen its own reach. A host-tool line's allowed verbs must live in that same host-side file.
8. **Build-vs-defer discipline.** The user repeatedly chose capture over build until a second consumer exists (ADR-029 D7 "poor ROI", o7tx triggers). mgp6's class (non-HTTP protocols, request signing, token-refresh return) is the "second consumer" o7tx was waiting for. That is a decision for the human, not for this document.
9. **Docker-era socket rule.** docker.sock was always refused as host-root-in-cage (ADR-016 D3). The only host socket ever mounted was the ssh-agent socket, and it is now gone.
