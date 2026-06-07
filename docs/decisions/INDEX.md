# Anchored Decision Records — Index

Navigable index of rip-cage's ADRs. Each ADR captures a cross-cutting, load-bearing decision; firmness is **per-decision** (`FIRM` / `FLEXIBLE` / `EXPLORATORY` / `PROPOSED`), not per-document, so the doc-level **Status** column below is a coarse signal — open the ADR for the firmness of a specific decision (Dn).

**How to consult:** scan the *By topic* map for the scope you're touching, open the ADR, and check the relevant decision's firmness before contradicting it. Decisions evolve **in place** (ADR-011 D1) — git history carries predecessor wording; there are no supersession chains. ADRs link upstream via a `## canonical_refs` section where present.

When a decision evolves, edit the ADR in place and update this row. Drift between this index and `ls docs/decisions/ADR-*.md` is the failure this file exists to prevent.

## By topic

- **Safety / fail-loud:** [001](ADR-001-fail-loud-pattern.md), [004](ADR-004-phase1-hardening.md), [023](ADR-023-secret-path-mount-denylist.md), [024](ADR-024-prompt-injection-threat-model.md), [025](ADR-025-host-adoptable-dcg-policy.md)
- **Containers / cage model:** [002](ADR-002-rip-cage-containers.md), [016](ADR-016-cage-host-network-awareness.md)
- **CLI / UX:** [003](ADR-003-agent-friendly-cli.md), [009](ADR-009-ux-overhaul.md), [011](ADR-011-shell-completions.md)
- **Testing / CI:** [013](ADR-013-test-coverage.md)
- **Egress / network:** [012](ADR-012-egress-firewall.md)
- **SSH / identity:** [014](ADR-014-push-less-cage.md), [017](ADR-017-ssh-agent-forwarding-default.md), [018](ADR-018-macos-ssh-agent-discovery.md), [020](ADR-020-ssh-identity-routing.md), [022](ADR-022-ssh-allowlist.md)
- **Auth / credentials:** [010](ADR-010-auth-refresh.md)
- **Config substrate:** [021](ADR-021-layered-rip-cage-config.md), [016](ADR-016-cage-host-network-awareness.md)
- **Beads / persistence:** [007](ADR-007-beads-dolt-container-resilience.md)
- **Toolchain provisioning:** [005](ADR-005-ecosystem-tools.md), [015](ADR-015-mise-toolchain-provisioning.md)
- **Release / open-source:** [008](ADR-008-open-source-publication.md)
- **Multi-agent:** [006](ADR-006-multi-agent-architecture.md)
- **pi-coding-agent:** [019](ADR-019-pi-coding-agent-support.md)

## All ADRs

| ADR | Title | Scope | Status | Summary |
|---|---|---|---|---|
| [001](ADR-001-fail-loud-pattern.md) | Fail-Loud Error Handling | safety | Accepted | Silent fallbacks in the safety harness downgrade guarantees; fail loud with actionable remedies |
| [002](ADR-002-rip-cage-containers.md) | Rip Cage Containers | containers | Accepted (D2a provisional) | Docker sandbox for Claude Code agents — OrbStack, persistent containers, bypassPermissions; D2a base = debian:trixie (glibc 2.41, legacy-iptables pin), provisional spike |
| [003](ADR-003-agent-friendly-cli.md) | Agent-Friendly CLI Interface | cli-ux | Accepted | Structured JSON output, dry-run, allowed-roots validation, agent context in CLAUDE.md |
| [004](ADR-004-phase1-hardening.md) | Phase 1 Hardening | safety | Accepted | Conditional Dolt server, resource limits, credential health check, expanded test suite |
| [005](ADR-005-ecosystem-tools.md) | Ecosystem Tools Integration | toolchain | Proposed (revised 2026-06-05) | Build-arg toggles + pinned versions; D7–D10 add composable host-only tool manifest (3 archetypes, in-cage-only, floor-untouchable, fail-warn daemons) |
| [006](ADR-006-multi-agent-architecture.md) | Multi-Agent Architecture | multi-agent | Proposed (revised 2026-06-06) | Progressive tiers; D7 specs Tier 1a as mechanical session levers (`rc agent`/`sessions`/`kill`/`attach`), orchestration lives in the consumer; concurrency is agent-specific (pi safe, claude gated on rip-cage-p1p) |
| [007](ADR-007-beads-dolt-container-resilience.md) | Beads/Dolt Container Resilience | beads | Accepted | bd wrapper for dynamic port refresh + server-start guard; worktree auto-redirect |
| [008](ADR-008-open-source-publication.md) | Open-Source Publication | release/oss | Proposed | MIT license, scrub personal data, semver, CI lint+build, bash 3.2 compat; D4 local==CI |
| [009](ADR-009-ux-overhaul.md) | UX Overhaul | cli-ux | Proposed | Harm-reduction positioning, auto-build on first up, focused README |
| [010](ADR-010-auth-refresh.md) | Credential Hot-Swap (`rc auth refresh`) | auth | Proposed | Re-extract OAuth from Keychain; in-place credential write preserves inode |
| [011](ADR-011-shell-completions.md) | Shell Completions for `rc` | cli-ux | Proposed | `rc completions` + `rc setup`; default-deny consent for shell integration |
| [012](ADR-012-egress-firewall.md) | Network Egress Firewall | egress/network | Accepted (evolved) | L7 TLS-MITM proxy + default-deny whitelist; observe-mode-first; DNS exfil heuristic; D10 legacy-iptables backend is safety-critical on trixie |
| [013](ADR-013-test-coverage.md) | Test Coverage Tiers | testing | Accepted (revised 2026-05-29) | In-container / e2e / host-only tiers; CI = lint+build+host-only; D6 host-only determinism |
| [014](ADR-014-push-less-cage.md) | The Cage Is Push-Less | ssh | Partially superseded | D1/D3 reversed by ADR-017; D2 non-interactive SSH posture + D4 LFS detection remain |
| [015](ADR-015-mise-toolchain-provisioning.md) | Project Toolchain Provisioning | toolchain | Accepted | Mise as invisible plumbing; shared cache volume; auto-install at init |
| [016](ADR-016-cage-host-network-awareness.md) | Cage Host-Network Awareness | config | Accepted | Append cage topology to CLAUDE.md; probe host-bridge hostname; no docker.sock |
| [017](ADR-017-ssh-agent-forwarding-default.md) | SSH-Agent Forwarding On By Default | ssh | Accepted (amended) | Forward by default, scoped by network whitelist; opt-out flag; loud failure on empty agent |
| [018](ADR-018-macos-ssh-agent-discovery.md) | macOS ssh-agent Discovery | ssh | Amended | Probe host candidates; mount the one with keys; launchd convention fallback |
| [019](ADR-019-pi-coding-agent-support.md) | pi-coding-agent Support | pi-agent | Proposed | Container-local pi dir + narrow durable sub-mounts (D1 rev 2026-06-01), no auth-warn, cage topology reference; D4 phase-1 promoted to required; D8 phase-1 SHIPPED (rip-cage-bl1, auto-loaded dcg-gate.ts, rev 2026-06-02) |
| [020](ADR-020-ssh-identity-routing.md) | SSH Identity Routing | ssh | Reviewed | Translate host SSH config; four-layer github.com identity resolution; filtered pubkey mount |
| [021](ADR-021-layered-rip-cage-config.md) | Layered rip-cage Config | config | Proposed | Two-file substrate: global + project `.rip-cage.yaml`; per-field merge rules; versioning |
| [022](ADR-022-ssh-allowlist.md) | SSH Host + Key Allowlist | ssh | Accepted (evolved) | ssh-agent-filter (agent half) + bash/openssl (host half); `rc reload` for content changes |
| [023](ADR-023-secret-path-mount-denylist.md) | Secret-Path Mount Denylist | safety | Proposed | Default-on pattern denylist for `--env-file` / `.beads` redirect; realpath-first validation |
| [024](ADR-024-prompt-injection-threat-model.md) | Prompt-Injection Threat Model | threat-model | Accepted | Names the threat class: a non-adversarial agent following hostile instructions in content |
| [025](ADR-025-host-adoptable-dcg-policy.md) | Host-Adoptable DCG Policy Layer | safety | Proposed | Additive-only DCG policy via `.rip-cage.yaml`; baked core floor uncrossable; CWD-anchor wrapper + pinned DCG_CONFIG close the `/workspace/.dcg.toml` self-disable hole |
