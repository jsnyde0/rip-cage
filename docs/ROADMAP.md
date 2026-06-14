# Rip Cage Roadmap

**Last updated:** 2026-05-29
**Philosophy:** Build → test → learn → adjust. This roadmap is directional, not a contract. Expect changes as we gain real experience using the tool.

---

## Phase 1: Hardening (current)

### Network egress firewall + observe mode (ADR-012) — shipped 2026-05-27 (v0.4.0)

- [x] `network.*` config schema + writable-subset validation ([ADR-012](decisions/ADR-012-egress-firewall.md))
- [x] Per-cage egress-rules pipeline — generate + mount at `rc up` / `rc reload`
- [x] Default-deny whitelist with `observe` / `block` / legacy modes + structured stderr
- [x] `network.allowed_hosts`; method-axis `writable_hosts` write-gating ([ADR-012 D6](decisions/ADR-012-egress-firewall.md))
- [x] DNS-exfil resolver sidecar + transparent port-53 REDIRECT ([ADR-012 D9](decisions/ADR-012-egress-firewall.md))
- [x] `rc allowlist add/show/promote` agent-first CLI; `rc doctor` egress sections; `rc ls` mode column
- [x] Workspace-trust validator — refuse hostile base-URL redirect at cage start
- [x] Injection-exfil integration harness (`rc test --e2e-security`)

### SSH host + key allowlist + hot-reload (ADR-022) — shipped 2026-05-12/13

- [x] `ssh.allowed_hosts` (additive_list) + `ssh.allowed_keys` (selection_list) schema ([ADR-022 D1](decisions/ADR-022-ssh-allowlist.md))
- [x] ssh-agent-filter (agent half) + bash/openssl host half make the allowlist load-bearing
- [x] Hook-layer guard closes the OpenSSH CLI-override bypass class
- [x] `rc reload <cage>` host-side hot-reload for `allowed_hosts` content changes ([ADR-022 D6](decisions/ADR-022-ssh-allowlist.md))

### Secret-path mount denylist (ADR-023) — shipped 2026-05-13 (v0.3.0)

- [x] `mounts.denylist` schema + realpath-first matcher ([ADR-023](decisions/ADR-023-secret-path-mount-denylist.md))
- [x] `mounts.allow_risky` config bypass + `rc up --allow-risky-mount` one-shot override
- [x] Host-side preflight validation on `--env-file` / `.beads` redirect; `rc install`

### Prompt-injection threat model (ADR-024) — landed 2026-05-22

- [x] Name the threat class: a non-adversarial agent following hostile instructions in content ([ADR-024](decisions/ADR-024-prompt-injection-threat-model.md))

### Cage host-network awareness (ADR-016)

- [x] Ship `/etc/rip-cage/cage-claude.md` in image; append under fenced markers in init ([ADR-016 D1](decisions/ADR-016-cage-host-network-awareness.md))
- [x] Preflight probe writes `CAGE_HOST_ADDR` to `/etc/rip-cage/cage-env`; source from `~/.zshrc` ([ADR-016 D2](decisions/ADR-016-cage-host-network-awareness.md))
- [x] Inject `CAGE_HOST_ADDR` via settings.json `env` block for Claude Code child processes ([ADR-016 D2](decisions/ADR-016-cage-host-network-awareness.md))
- [x] `rc test` asserts `$CAGE_HOST_ADDR` set + exactly one `begin:rip-cage-topology` marker in `~/.claude/CLAUDE.md`

**Design:** [Cage Host-Network Awareness](2026-04-22-cage-host-network-awareness-design.md)

### Toolchain provisioning (ADR-015)

- [ ] Install mise in runtime stage of Dockerfile ([ADR-015 D1](decisions/ADR-015-mise-toolchain-provisioning.md))
- [ ] Add `rc-mise-cache` shared named volume to `rc up` + devcontainer mounts ([ADR-015 D2](decisions/ADR-015-mise-toolchain-provisioning.md))
- [ ] `init-rip-cage.sh` runs `mise install` when workspace declares a toolchain ([ADR-015 D3](decisions/ADR-015-mise-toolchain-provisioning.md))
- [ ] Set `MISE_TRUSTED_CONFIG_PATHS=/workspace` in image ([ADR-015 D4](decisions/ADR-015-mise-toolchain-provisioning.md))
- [ ] Tier 1 + Tier 2 test coverage per ADR-013

**Design:** [Toolchain Provisioning](2026-04-22-toolchain-provisioning-design.md)

### Existing Phase 1 items

Get the existing implementation working end-to-end and solid.

- [x] Validate Dockerfile builds cleanly (CI builds + publishes the image per release)
- [x] Connect container bd to host Dolt server ([ADR-004 D1](decisions/ADR-004-phase1-hardening.md))
- [ ] Add container resource limits ([ADR-004 D2](decisions/ADR-004-phase1-hardening.md))
- [ ] Credential health check on start ([ADR-004 D3](decisions/ADR-004-phase1-hardening.md))
- [ ] Expand `rc test` to 15+ checks ([ADR-004 D4](decisions/ADR-004-phase1-hardening.md))
- [ ] Richer zshrc ([ADR-004 D5](decisions/ADR-004-phase1-hardening.md))
- [ ] First real agent session in the container
- [ ] Test devcontainer flow in VS Code
- [x] Add `rc test --e2e` lifecycle suite ([ADR-013 D1](decisions/ADR-013-test-coverage.md))
- [x] Fix + wire host-side tests via `rc test --host`; CI = lint+build+host-only ([ADR-013 D2](decisions/ADR-013-test-coverage.md), [D5/D6](decisions/ADR-013-test-coverage.md))
- [x] Expand egress perimeter tests (IPv6, WebSocket, non-HTTP ports, DoH) ([ADR-013 D4](decisions/ADR-013-test-coverage.md))

**Design:** [Phase 1 Hardening](2026-03-27-phase1-hardening-design.md), [Test Coverage](2026-04-20-test-coverage-design.md)

## Phase 1b: First Ecosystem Tool

Add UBS (bug scanner) as the first external tool. Validates the integration pattern.

> **Superseded (2026-06-14, rip-cage-hqvk):** the build-arg customization layer this phase originally planned — per-tool `INCLUDE_<TOOL>` toggles, `versions.env`, `--with` flags — was never built. The host-only tool manifest ([ADR-005 D7–D11](decisions/ADR-005-ecosystem-tools.md)) is the realized tool-inclusion + version-pin surface. The items below are kept for history with their realized status.

- [x] Build-time (not runtime) tool inclusion — realized via the host-only manifest, not per-tool build-arg toggles ([ADR-005 D1](decisions/ADR-005-ecosystem-tools.md))
- [x] Add UBS as default tool — baked unconditionally ([ADR-005 D2](decisions/ADR-005-ecosystem-tools.md))
- [ ] Per-cage tool selection (the `--with` role) — **deferred** onto the manifest (Open-decision 8 / rip-cage-4c5) ([ADR-005 D4](decisions/ADR-005-ecosystem-tools.md))
- [x] Version pinning — bundled tools as hardcoded Dockerfile `ARG` defaults, user tools via manifest `version_pin`; no `versions.env` ([ADR-005 D3](decisions/ADR-005-ecosystem-tools.md))
- [x] Standard integration pattern — generalized into the manifest archetypes ([ADR-005 D5](decisions/ADR-005-ecosystem-tools.md))

**Design:** [Ecosystem Tools](2026-03-27-ecosystem-tools-design.md)

## Phase 2a: Optional Tools

Add RANO (network monitoring) and CASS (session search) as optional tools.

- [ ] RANO as optional build-arg
- [ ] `rc monitor <name>` command wrapping RANO
- [ ] CASS as optional build-arg
- [ ] Session indexing in init script

## Phase 2b: Multi-Agent Foundations

Enable basic multi-agent workflows.

- [ ] Container labels for agent identity ([ADR-006 D3](decisions/ADR-006-multi-agent-architecture.md))
- [ ] `rc up --label` support
- [ ] `rc ls` filtering by label
- [ ] Optional `bv` (beads viewer) and `cm` (CASS memory) tools
- [ ] Document Tier 1b multi-agent workflow (shared bind mount + git)

**Design:** [Multi-Agent Architecture](2026-03-27-multi-agent-architecture.md)

## Phase 2c: Swarm Grouping (Tier 2)

Named groups of containers with lifecycle management.

- [ ] `rc swarm create/ls/down/destroy`
- [ ] Broadcast messaging
- [ ] Optional worktree isolation per agent

## Phase 3: Coordinated Agents (Tier 3)

Structured multi-agent coordination.

- [ ] Agent Mail integration (file reservations + messaging)
- [ ] SLB integration (peer approval for dangerous commands)
- [ ] `rc dashboard` TUI
- [ ] VPS / clone mode support

---

## Reference

| Document | What |
|----------|------|
| [Flywheel Investigation](2026-03-27-flywheel-investigation.md) | Full analysis of 18 Emanuel ecosystem tools |
| [Phase 1 Hardening Design](2026-03-27-phase1-hardening-design.md) | Host Dolt connection, resource limits, health checks, zshrc |
| [Ecosystem Tools Design](2026-03-27-ecosystem-tools-design.md) | Build-arg toggles, UBS, tool integration pattern |
| [Multi-Agent Architecture](2026-03-27-multi-agent-architecture.md) | 3-tier progressive model, coordination, monitoring |
| [ADR-004](decisions/ADR-004-phase1-hardening.md) | Phase 1 hardening decisions |
| [ADR-005](decisions/ADR-005-ecosystem-tools.md) | Ecosystem tools integration decisions |
| [ADR-006](decisions/ADR-006-multi-agent-architecture.md) | Multi-agent architecture decisions |
| [ADR-015](decisions/ADR-015-mise-toolchain-provisioning.md) | Project toolchain provisioning via mise |
| [ADR-016](decisions/ADR-016-cage-host-network-awareness.md) | Cage host-network awareness (CLAUDE.md + preflight probe) |
| [ADR-012](decisions/ADR-012-egress-firewall.md) | Network egress firewall — L7 proxy, observe/block modes, DNS exfil heuristic |
| [ADR-022](decisions/ADR-022-ssh-allowlist.md) | SSH host + key allowlist; `rc reload` hot-reload |
| [ADR-023](decisions/ADR-023-secret-path-mount-denylist.md) | Secret-path mount denylist; `--allow-risky-mount` override |
| [ADR-024](decisions/ADR-024-prompt-injection-threat-model.md) | Prompt-injection threat model |

## Flywheel Research Repos

Rip-cage draws on several tools from [Dicklesworthstone's agentic coding flywheel](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup). The table below lists upstream repos relevant to the roadmap.

| Upstream | What |
|----------|------|
| `Dicklesworthstone/ntm` | Named Tmux Manager — multi-agent session orchestration |
| `Dicklesworthstone/simultaneous_launch_button` | SLB — two-person rule for dangerous commands |
| `Dicklesworthstone/mcp_agent_mail` | Agent Mail — inter-agent communication + file reservations |
| `Dicklesworthstone/coding_agent_account_manager` | CAAM — credential management + rotation |
| `Dicklesworthstone/coding_agent_session_search` | CASS — unified session search |
| `Dicklesworthstone/cass_memory_system` | CM — procedural memory with confidence decay |
| `Dicklesworthstone/cross_agent_session_resumer` | CASR — session portability across providers |
| `Dicklesworthstone/beads_rust` | br — Rust beads (JSONL, no Dolt) |
| `Dicklesworthstone/beads_viewer` | bv — graph-aware TUI for beads |
| `Dicklesworthstone/ultimate_bug_scanner` | UBS — bug scanner, 9 languages |
| `Dicklesworthstone/meta_skill` | ms — knowledge management with semantic search |
| `Dicklesworthstone/process_triage` | pt — Bayesian zombie process cleanup |
| `Dicklesworthstone/wezterm_automata` | FrankenTerm — swarm terminal platform |
| `Dicklesworthstone/system_resource_protection_script` | SRPS — workstation resource protection |
| `Dicklesworthstone/toon_rust` | TOON — token-optimized notation |
| `Dicklesworthstone/rano` | RANO — network observer for AI CLIs |
| `Dicklesworthstone/post_compact_reminder` | Post-compact context reminder hook |
| `Dicklesworthstone/agent_settings_backup_script` | asb — agent config backup (NOT for rip-cage) |
