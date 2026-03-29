# Rip Cage Roadmap

**Last updated:** 2026-03-27
**Philosophy:** Build → test → learn → adjust. This roadmap is directional, not a contract. Expect changes as we gain real experience using the tool.

---

## Phase 1: Hardening (current)

Get the existing implementation working end-to-end and solid.

- [ ] Validate Dockerfile builds cleanly
- [x] Connect container bd to host Dolt server ([ADR-004 D1](decisions/ADR-004-phase1-hardening.md))
- [ ] Add container resource limits ([ADR-004 D2](decisions/ADR-004-phase1-hardening.md))
- [ ] Credential health check on start ([ADR-004 D3](decisions/ADR-004-phase1-hardening.md))
- [ ] Expand `rc test` to 15+ checks ([ADR-004 D4](decisions/ADR-004-phase1-hardening.md))
- [ ] Richer zshrc ([ADR-004 D5](decisions/ADR-004-phase1-hardening.md))
- [ ] First real agent session in the container
- [ ] Test devcontainer flow in VS Code

**Design:** [Phase 1 Hardening](2026-03-27-phase1-hardening-design.md)

## Phase 1b: First Ecosystem Tool

Add UBS (bug scanner) as the first external tool. Validates the integration pattern.

- [ ] Implement build-arg toggle pattern in Dockerfile ([ADR-005 D1](decisions/ADR-005-ecosystem-tools.md))
- [ ] Add UBS as default tool ([ADR-005 D2](decisions/ADR-005-ecosystem-tools.md))
- [ ] `rc build --with` / `--minimal` flags ([ADR-005 D4](decisions/ADR-005-ecosystem-tools.md))
- [ ] Version pinning via `versions.env` ([ADR-005 D3](decisions/ADR-005-ecosystem-tools.md))
- [ ] Standard 4-point integration pattern proven ([ADR-005 D5](decisions/ADR-005-ecosystem-tools.md))

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
- [ ] Document Tier 1 multi-agent workflow (shared bind mount + git)

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

## Flywheel Research Repos

Local clones of Emanuel's tools at `~/code/personal/flywheel-research/`. These are shallow clones from 2026-03-27 — **run `git pull` inside a repo before investigating it** to get the latest.

Also: ACFS itself is at `~/code/personal/agentic_coding_flywheel_setup/`.

| Local path | Upstream | What |
|-----------|----------|------|
| `flywheel-research/ntm/` | `Dicklesworthstone/ntm` | Named Tmux Manager — multi-agent session orchestration |
| `flywheel-research/simultaneous_launch_button/` | `Dicklesworthstone/simultaneous_launch_button` | SLB — two-person rule for dangerous commands |
| `flywheel-research/mcp_agent_mail/` | `Dicklesworthstone/mcp_agent_mail` | Agent Mail — inter-agent communication + file reservations |
| `flywheel-research/coding_agent_account_manager/` | `Dicklesworthstone/coding_agent_account_manager` | CAAM — credential management + rotation |
| `flywheel-research/coding_agent_session_search/` | `Dicklesworthstone/coding_agent_session_search` | CASS — unified session search |
| `flywheel-research/cass_memory_system/` | `Dicklesworthstone/cass_memory_system` | CM — procedural memory with confidence decay |
| `flywheel-research/cross_agent_session_resumer/` | `Dicklesworthstone/cross_agent_session_resumer` | CASR — session portability across providers |
| `flywheel-research/beads_rust/` | `Dicklesworthstone/beads_rust` | br — Rust beads (JSONL, no Dolt) |
| `flywheel-research/beads_viewer/` | `Dicklesworthstone/beads_viewer` | bv — graph-aware TUI for beads |
| `flywheel-research/ultimate_bug_scanner/` | `Dicklesworthstone/ultimate_bug_scanner` | UBS — bug scanner, 9 languages |
| `flywheel-research/meta_skill/` | `Dicklesworthstone/meta_skill` | ms — knowledge management with semantic search |
| `flywheel-research/process_triage/` | `Dicklesworthstone/process_triage` | pt — Bayesian zombie process cleanup |
| `flywheel-research/wezterm_automata/` | `Dicklesworthstone/wezterm_automata` | FrankenTerm — swarm terminal platform |
| `flywheel-research/system_resource_protection_script/` | `Dicklesworthstone/system_resource_protection_script` | SRPS — workstation resource protection |
| `flywheel-research/toon_rust/` | `Dicklesworthstone/toon_rust` | TOON — token-optimized notation |
| `flywheel-research/rano/` | `Dicklesworthstone/rano` | RANO — network observer for AI CLIs |
| `flywheel-research/post_compact_reminder/` | `Dicklesworthstone/post_compact_reminder` | Post-compact context reminder hook |
| `flywheel-research/agent_settings_backup_script/` | `Dicklesworthstone/agent_settings_backup_script` | asb — agent config backup (NOT for rip-cage) |
