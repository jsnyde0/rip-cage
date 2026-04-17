# Rip-Cage vs ClaudeBox — Competitive Analysis

**Date**: 2026-04-17
**Type**: Research / positioning
**Related**: beads rip-cage-2py (firewall investigation)

## Summary

Comparison of rip-cage against ClaudeBox (RchGrav/claudebox, ~849 stars) and the
broader Docker-sandbox-for-AI-agent landscape. Conclusion: rip-cage and ClaudeBox
target different users. Rip-cage has a clear positioning moat (defense-in-depth
safety + workflow continuity) but has a real network egress gap worth closing.

## Positioning

Both projects solve "run Claude Code with bypassPermissions safely in Docker"
but optimize for different users:

| | rip-cage | ClaudeBox |
|---|---|---|
| Target user | Power user with existing Claude Code setup | New user wanting a sandboxed dev env |
| Mental model | "Transparent wrapper around my workflow" | "New environment I work inside" |
| DX axis | Context continuity (credentials, skills, CLAUDE.md, beads, git) | Environment setup (20+ language profiles, fancy shell) |
| Tagline | "Your existing workflow, caged" | "Batteries-included sandboxed env" |

For a user already invested in Claude Code (skills, beads, agents, multi-account
rotation, custom hooks), ClaudeBox is a DX downgrade — none of that carries over.
Conversely, for someone starting from scratch, ClaudeBox's profile system and
pre-polished shell are genuinely nicer than rip-cage's minimal setup.

## Technical comparison

| Dimension | rip-cage | ClaudeBox |
|---|---|---|
| Container model | Persistent (one per project) | Ephemeral (--rm), multi-slot |
| Safety layers | 3 (container + DCG + compound blocker) | 1 (container + iptables firewall) |
| Language profiles | None (BYO Dockerfile) | 20+ pre-configured stacks |
| Auth | Keychain extraction + hot-swap via `rc auth refresh` | Env var passthrough |
| DevContainer | Yes (`rc init`) | No |
| CLI headless | Yes (`rc up`) | Yes (`claudebox`) |
| Network egress control | **No** | Per-project iptables allowlist |
| Multi-instance | One container per project | Multi-slot concurrent |
| Shell UX | Minimal zsh | Powerline + oh-my-zsh + fzf + delta |
| Test suite | 32-check safety tests + 15 test scripts | None visible |
| Docs | README + 12 ADRs + reference guides | README + CLAUDE.md + changelogs |
| Codebase | ~1,800 lines bash + Rust DCG + Go beads | ~6,000 lines bash (modular) |
| Maturity | v0.1.0 (April 2026) | v2.0.0 (~849 stars) |

## What rip-cage does better

1. **Safety depth** — DCG (Rust binary) blocks destructive commands; compound
   command blocker prevents `&&`/`;`/`||` chaining that bypasses permission
   classifiers. ClaudeBox has zero in-container safety hooks — the container
   boundary is its only defense.
2. **PreToolUse hooks** on every Bash command; agent self-corrects on denial.
3. **DevContainer support** — `rc init` generates `.devcontainer/devcontainer.json`.
4. **Git worktree support** — transparent detection, `.git` rewriting, read-only
   hooks mounting. ClaudeBox doesn't handle worktrees.
5. **Auth sophistication** — Keychain extraction, expiry warnings, hot-swap via
   `rc auth refresh`, multi-account rotation via CAAM.
6. **Skills/agents in containers** — host skills mounted read-only and discovered
   via MCP shim. Not addressed in ClaudeBox.
7. **Beads integration** — issue tracking with embedded/server Dolt modes,
   worktree sharing.
8. **JSON output + dry-run** — machine-readable output for CI/agent automation.
9. **Test suite** — 32-check health validation + 15 test scripts. ClaudeBox has
   no visible tests.
10. **ADR discipline** — every major decision documented with rationale and
    alternatives considered.

## What ClaudeBox does better

1. **Network firewall** — iptables allowlist with default-deny. This is a real
   safety feature rip-cage doesn't have. See beads rip-cage-2py.
2. **Language profiles** — 20+ pre-configured stacks (C, Rust, Python, Go, Java,
   Flutter, DevOps, ML). No Dockerfile editing needed.
3. **Multi-slot concurrent instances** — run multiple Claude instances on the
   same project simultaneously.
4. **Shell DX polish** — powerline, oh-my-zsh, autosuggestions, syntax
   highlighting, fzf, git-delta pre-configured.
5. **Admin mode** — `claudebox shell admin` commits image changes. Avoids
   rebuild cycle for ad-hoc tool installs.
6. **Saved flags** — `claudebox save --enable-sudo --disable-firewall`.
7. **Auto Docker install** — detects missing Docker and walks through install.

## Competitive landscape (beyond ClaudeBox)

- **Docker Sandboxes (`sbx` CLI)** — launched March 2026 by Docker Inc.
  microVM isolation (own kernel, own network stack). Supports Claude Code,
  Gemini, Codex, Copilot, Kiro, OpenCode. The 800-pound gorilla. Stronger
  isolation boundary than containers, but no in-container safety hooks.
- **Trail of Bits devcontainer** — security-audit focused, minimal, strong
  security pedigree. Optional iptables lockdown.
- **streamingfast/sbox** — dual backend (container or microVM), `sbox.yaml`
  team-shareable config. Clean CLI, no safety hooks.
- **textcortex/spritz** — evolved from local sandbox into Kubernetes control
  plane for multi-agent orchestration. Different category now.
- **Claude Code native sandbox** (bubblewrap/Seatbelt) — shipped October 2025
  but documented escape via `/proc/self/root/` path tricks (Ona research,
  March 2026). Validates need for external sandboxing.
- **E2B, Daytona, agent-infra/sandbox** — cloud/enterprise sandbox platforms.
  Different target (hosted, API-first).

## Community consensus

1. **Container-only isn't enough.** Shared kernel = shared risk. Palo Alto
   Unit 42 and Ona research both validate that containers are necessary but
   insufficient.
2. **Agent escape is a real threat.** Documented, not hypothetical.
3. **Defense in depth is the consensus.** Application hooks + OS enforcement +
   infrastructure isolation. This is rip-cage's exact model.
4. **DX matters** — friction drives users to `--dangerously-skip-permissions`
   in the first place.

## Things to steal (ranked by impact)

| Priority | Idea | Source | Effort |
|---|---|---|---|
| **High** | Network firewall / egress allowlist | ClaudeBox, ToB, Anthropic reference | Medium |
| Medium | Multi-slot concurrent instances | ClaudeBox | High (or: lean into worktrees) |
| Medium | Admin mode / commit image changes | ClaudeBox | Medium |
| Medium | Team-shareable config (`rc.yaml`) | sbox | Medium |
| Low | Language profiles | ClaudeBox | Medium — conflicts with minimalist positioning |
| Low | Shell DX polish (oh-my-zsh, fzf) | ClaudeBox | Low |
| Low | microVM backend option | Docker Sandboxes | High |
| Low | Auto Docker install | ClaudeBox | Low |

## Decisions

- **Positioning**: Added "Who is this for?" section to README clarifying rip-cage
  as "your existing Claude Code workflow, caged" with explicit pointer to
  ClaudeBox for users wanting a batteries-included dev environment.
- **Firewall gap**: Filed as beads rip-cage-2py for future investigation.
  Real safety gap, aligned with defense-in-depth positioning.
- **Profiles / shell polish**: Deferred. Conflicts with minimalist positioning
  and the "workflow continuity" promise (users bring their own environment).

## References

- [RchGrav/claudebox](https://github.com/RchGrav/claudebox)
- [Docker Sandboxes](https://www.docker.com/products/docker-sandboxes/)
- [Claude Code Sandboxing docs](https://code.claude.com/docs/en/sandboxing)
- [trailofbits/claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer)
- [Ona: How Claude Code escapes its own sandbox](https://ona.com/stories/how-claude-code-escapes-its-own-denylist-and-sandbox)
- [HN: Running Claude Code dangerously (safely)](https://news.ycombinator.com/item?id=46690907)
