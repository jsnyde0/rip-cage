# Flywheel Investigation: Emanuel's Agentic Coding Ecosystem

**Date:** 2026-03-27
**Status:** Research complete
**Purpose:** Swarm investigation of Jeffrey Emanuel's Agentic Coding Flywheel Setup (ACFS) and all related tools. Identify opportunities to improve rip-cage or build complementary local-first tools.
**Method:** 18 repos cloned, 9 parallel investigation agents dispatched, each reading source code (not just READMEs).

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Tool-by-Tool Findings](#tool-by-tool-findings)
   - [NTM — Named Tmux Manager](#ntm--named-tmux-manager)
   - [SLB — Simultaneous Launch Button](#slb--simultaneous-launch-button)
   - [CAAM — Coding Agent Account Manager](#caam--coding-agent-account-manager)
   - [MCP Agent Mail](#mcp-agent-mail)
   - [CASS — Coding Agent Session Search](#cass--coding-agent-session-search)
   - [CASS Memory System (CM)](#cass-memory-system-cm)
   - [Cross-Agent Session Resumer (CASR)](#cross-agent-session-resumer-casr)
   - [Beads Rust (br)](#beads-rust-br)
   - [Beads Viewer (bv)](#beads-viewer-bv)
   - [Ultimate Bug Scanner (UBS)](#ultimate-bug-scanner-ubs)
   - [Meta Skill (ms)](#meta-skill-ms)
   - [Process Triage (pt)](#process-triage-pt)
   - [WezTerm Automata / FrankenTerm](#wezterm-automata--frankenterm)
   - [System Resource Protection Script (SRPS)](#system-resource-protection-script-srps)
   - [TOON Rust](#toon-rust)
   - [RANO — Network Observer](#rano--network-observer)
   - [Post-Compact Reminder](#post-compact-reminder)
   - [Agent Settings Backup (asb)](#agent-settings-backup-asb)
   - [ACFS Installer](#acfs-installer)
3. [Opportunity Matrix](#opportunity-matrix)
4. [Key Architectural Insights](#key-architectural-insights)
5. [Do Not Adopt](#do-not-adopt)

---

## Executive Summary

The Emanuel flywheel is a comprehensive ecosystem of ~20 tools designed for running AI coding agents on throwaway Ubuntu VPSes. Rip-cage takes a different approach (local Docker containers on Mac), but many patterns and tools transfer directly. The investigation surfaced **17 concrete opportunities** across 3 tiers.

**Top 6 findings:**
1. **beads_rust (br)** can replace bd+Dolt, saving ~130MB and solving the Dolt SSH sync problem
2. **UBS** (3MB bash script) catches agent-generated bugs — direct safety gate for auto mode
3. **Container resource limits** are free safety (`--cpus`, `--memory`, `--pids-limit`)
4. **CAAM's credential health pattern** is simple: parse token expiry, warn early, track errors with decay
5. **RANO** fills a real observability gap with per-process network attribution inside containers
6. **Agent Mail** is the right Phase 3 answer for multi-agent coordination (file reservations + async messaging)

---

## Tool-by-Tool Findings

### NTM — Named Tmux Manager

**Repo:** `github.com/Dicklesworthstone/ntm`
**Language:** Go | **Purpose:** Multi-agent session orchestration via tmux

**What it does:**
- Turns tmux into a local control plane for multi-agent development
- Named sessions tied to projects: `ntm spawn payments --cc=3 --cod=2 --gmi=1`
- Pane naming convention: `{session}__{label}_{type}_{index}`
- Durable checkpoints: save/restore entire session state
- Graph-aware triage via beads integration: `ntm work triage`, `ntm work next`
- Broadcast: `ntm send payments --all "Summarize progress"`
- Robot mode: `--robot-*` flags for structured JSON output
- REST API + WebSocket for dashboards

**Key patterns for rip-cage:**
1. **Named identity over IDs** — `project-main-agent` instead of `container-abc123`. Human-readable, grep-able
2. **Durable checkpoints** — serialize container config + volumes + git state for recovery
3. **Pane metadata via labels** — Docker labels encode agent type, model, tags for filtering
4. **Lazy initialization** — skip Docker validation for read-only commands (`rc ls`)
5. **Swarm grouping** — `rc swarm create proj /path --agents "claude:2,codex:1"`
6. **Broadcast** — `rc swarm send proj --all "Fix auth module"`

**Rip-cage opportunities:**
- Add `--label` flag to `rc up` for human-readable container naming
- Add `rc swarm` subcommand for multi-container grouping (Phase 2)
- Checkpoint/restore for container sessions (Phase 2)
- Worktree-first multi-agent: each agent gets its own git worktree for isolation

---

### SLB — Simultaneous Launch Button

**Repo:** `github.com/Dicklesworthstone/simultaneous_launch_button`
**Language:** Go | **Purpose:** Two-person rule for dangerous commands

**What it does:**
- Peer review + approval before executing risky commands
- Risk tiers: CRITICAL (2+ approvals), DANGEROUS (1 approval), CAUTION (auto-approve after 30s), SAFE (skip)
- Pattern engine: regex-based classification with compound command splitting
- Strict state machine: PENDING → APPROVED → EXECUTING → EXECUTED (or REJECTED/CANCELLED)
- 5 execution verification gates: status, TTL, SHA-256 hash, tier recheck, first-executor-wins
- Session-scoped identity: agent name, program, model, project path
- Daemon + Unix socket IPC, TUI dashboard
- Client-side execution (daemon is notary, not executor)

**Key patterns for rip-cage:**
1. **Fail-closed safety** — every failure mode is conservative. Parse error → upgrade risk tier
2. **Pattern engine** — reusable, runtime-customizable command classification
3. **Session-scoped identity** — tracks agent identity across container lifecycle
4. **Audit trail** — every state transition logged, fully replayable
5. **First-executor-wins** — atomic DB transitions prevent race conditions

**Rip-cage opportunities:**
- Optional SLB integration for multi-agent approval workflows (Phase 3)
- Could run SLB daemon on host with socket mounted into containers
- Each container is an "agent session" within the project's SLB space

---

### CAAM — Coding Agent Account Manager

**Repo:** `github.com/Dicklesworthstone/coding_agent_account_manager`
**Language:** Go | **Purpose:** Sub-100ms account switching for AI CLI tools

**What it does:**
- Vault-based file storage: `~/.local/share/caam/vault/{provider}/{email}/`
- On activation: copy vault files → replace `~/.claude.json` etc. → tool sees new identity
- Rate limit detection: regex-based monitoring of stdout/stderr for 429/quota patterns
- Cooldown tracking: rate-limited profiles marked unavailable with TTL
- Rotation algorithm: Smart (multi-factor: cooldown → health → recency → plan type → jitter), Round Robin, Random
- Credential health monitoring: token expiry, error counts, penalty with exponential decay (20% per 5min)
- Optional daemon for proactive token refresh
- Token refresh: works for Codex/Gemini; **disabled for Claude** (endpoint undocumented)

**Key patterns for rip-cage:**
1. **Health tracking with decay** — temporary errors don't permanently mark credentials as bad
2. **Atomic credential updates** — temp file + fsync + rename prevents corruption
3. **Profile state machine** — Unknown → Ready → Refreshing → Cooldown → Expired → Error
4. **Content-based detection** — SHA-256 hash matching instead of hidden state files
5. **Rate limit regex patterns** — reusable provider-specific detection

**Rip-cage opportunities (Tier 1 — simple):**
- Parse token expiry from `~/.claude.json` on mount
- Warn if token expiring within 10 minutes
- Simple health.json file tracking errors + expiry
- No refresh inside container (Claude endpoint undocumented); user re-auths on host

**Do NOT adopt:** Multi-account pooling, daemon architecture, distributed profile sync

---

### MCP Agent Mail

**Repo:** `github.com/Dicklesworthstone/mcp_agent_mail`
**Language:** Python (FastMCP) | **Purpose:** Inter-agent communication + file coordination

**What it does:**
- HTTP-only FastMCP server with memorable agent identities (GreenCastle, BlueLake)
- Async GFM markdown messaging with threading, importance levels, acknowledgment tracking
- **Advisory file reservations** with TTL: agents reserve file paths/globs before editing
- Optional pre-commit guard blocks commits violating exclusive reservations
- Dual persistence: Git (human-auditable) + SQLite (FTS5 searchable)
- Directory/LDAP queries for agent discovery
- Contact policies: open, auto, contacts_only, block_all
- Web UI at `/mail` for human supervision

**Architecture:**
```
Agents → HTTP (JSON-RPC 2.0) → Agent Mail Server → Git + SQLite
```

**Coordination patterns:**
1. Agent A reserves `src/auth/**` (exclusive, 1hr)
2. Agent B queries reservations → sees conflict → picks different path
3. Both work in parallel without collisions
4. Messages provide async explanation + handoff

**Rip-cage opportunities (Phase 3):**
- Run Agent Mail as sidecar container; agents call via HTTP
- File reservations prevent clobbering in multi-agent scenarios
- Git-backed audit trail of all coordination decisions
- Thread IDs align with beads issue IDs (`bd-123`)

**Not needed for Phase 1** — single-agent containers don't need coordination

---

### CASS — Coding Agent Session Search

**Repo:** `github.com/Dicklesworthstone/coding_agent_session_search`
**Language:** Rust | **Purpose:** Unified search across agent session history from 20+ tools

**What it does:**
- Indexes Claude Code, Codex, Cursor, Gemini CLI, Cline, Aider, and 14+ other providers
- Full-text engine: Tantivy (BM25 with edge n-gram) for <60ms lexical search
- Semantic engine: FastEmbed (MiniLM via ONNX) or hash-embedder fallback (FNV-1a, no ML)
- Hybrid search: Reciprocal Rank Fusion combining lexical + semantic
- TUI: 3-pane FrankenTUI with live search-as-you-type
- Robot mode: `cass search "auth error" --robot --json --limit 5`
- HTML export with AES-256-GCM encryption
- Remote multi-machine sync via SSH/rsync

**Rip-cage opportunities:**
- Add `cass` binary to Dockerfile
- Mount container CASS index as named volume (survives restarts)
- `cass index --full` on init, `--incremental` in SessionEnd hook
- Agents search their own history: `cass search "retry logic" --robot --json`
- Cross-container sync to host for global search (Phase 2)

---

### CASS Memory System (CM)

**Repo:** `github.com/Dicklesworthstone/cass_memory_system`
**Language:** TypeScript (Bun) | **Purpose:** Procedural memory with confidence decay

**What it does:**
- Three-layer memory: Episodic (CASS sessions) → Working (diary entries) → Procedural (playbook rules)
- Confidence decay: 90-day half-life; harmful multiplier is 4x
- Maturity progression: candidate → established → proven (or deprecated)
- Anti-pattern learning: rules marked harmful 3+ times become warnings
- Scientific validation: new rules checked against session history
- LLM-powered reflection: extracts rules from diary entries
- MCP server for Claude Code integration

**Key command:** `cm context "implement auth rate limiting" --json` returns relevant rules, anti-patterns, history snippets, suggested queries

**Rip-cage opportunities:**
- **Phase 1 (lightweight):** Mount host `~/.cass-memory/playbook.yaml` read-only. Agents call `cm context` before non-trivial work
- **Phase 1b:** Add diary entry recording post-session
- **Phase 2:** Mount playbook read-write, merge container updates back to host

**Design principle alignment:** "Memory is convenience, not correctness" — CLAUDE.md and beads remain authoritative

---

### Cross-Agent Session Resumer (CASR)

**Repo:** `github.com/Dicklesworthstone/cross_agent_session_resumer`
**Language:** Rust | **Purpose:** Session portability across AI coding providers

**What it does:**
- Canonical session IR: normalizes 13+ provider formats to common schema
- Convert sessions between providers: `casr cc resume <session-id>`
- Safety-first writes: atomic temp-then-rename, conflict detection, read-back verification, rollback
- Content flattening, timestamp parsing, role normalization

**Rip-cage relevance:** Low for Phase 1 (Claude Code focused). Useful if adding multi-provider support in Phase 3. Could enable session export for audit trails before container destruction.

---

### Beads Rust (br)

**Repo:** `github.com/Dicklesworthstone/beads_rust`
**Language:** Rust (~20K lines) | **Purpose:** Local-first issue tracking without Dolt

**What it does:**
- Freezes the "classic" beads architecture (SQLite + JSONL) that Steve Yegge's Go version evolved away from
- Storage: SQLite (fast queries) + JSONL (git-friendly, line-based merges)
- Sync: explicit `br sync --flush-only` (SQLite → JSONL) and `--import-only` (JSONL → SQLite)
- **Never executes git** — explicit, non-invasive
- No daemon, no Dolt, no SSH, no automatic hooks
- ~5-8MB binary vs ~30MB for Go beads + 103MB for Dolt

**Comparison with bd (Go beads):**

| Aspect | br (Rust) | bd (Go) |
|--------|-----------|---------|
| Code size | ~20K lines | ~276K lines |
| Storage | SQLite + JSONL | Dolt (modern) + SQLite (legacy) |
| Git operations | Never (explicit) | Auto-commits, installs hooks |
| Binary size | ~5-8 MB | ~30+ MB |
| Dolt dependency | None | Yes (103 MB) |
| Container sync | JSONL + git (works) | Dolt SSH (fails) |

**Rip-cage opportunities (HIGH PRIORITY):**
- Replace `bd`+Dolt with `br` in Dockerfile
- Saves ~130MB image size
- Solves the Dolt SSH sync problem entirely
- Simpler, frozen architecture (no upstream churn)
- Agent commands: `br ready`, `br create`, `br close`, `br list --json`

---

### Beads Viewer (bv)

**Repo:** `github.com/Dicklesworthstone/beads_viewer`
**Language:** Go | **Purpose:** Graph-aware TUI for beads task visualization

**What it does:**
- Read-only visualization of `.beads/beads.jsonl`
- Dependency graphs, critical path analysis, cycle detection, PageRank metrics
- Interactive TUI: list view, kanban board, graph view, history view
- **Robot modes for agents:**
  - `bv --robot-triage` — all insights in one call
  - `bv --robot-next` — single top pick + claim command
  - `bv --robot-plan` — parallel tracks with unblock info
  - `bv --robot-insights` — full metrics
- Works with JSONL from both `br` and `bd`

**Rip-cage opportunities:**
- Optional Phase 2 addition for agents that need task prioritization
- Robot modes help agents decide what to work on next
- ~50-100MB addition (Go binary)

---

### Ultimate Bug Scanner (UBS)

**Repo:** `github.com/Dicklesworthstone/ultimate_bug_scanner`
**Language:** Bash meta-runner + per-language modules | **Purpose:** Catch agent-generated bugs fast

**What it does:**
- 1000+ heuristic patterns across 9 languages (JS/TS, Python, C/C++, Rust, Go, Java, Ruby, Swift, C#)
- Per-language modules: self-contained, SHA-256 verified, lazy-downloaded, cached
- Sub-5-second feedback on staged files
- Output: text, JSON, SARIF, TOON
- Severity: Critical (null safety, XSS, missing await), Important (type narrowing, resource leaks), Contextual (TODOs)

**Size:** ~3MB bash script + modules. Dependencies: bash, jq (already in image), ripgrep (optional)

**Rip-cage opportunities (HIGH PRIORITY — Phase 1):**
- Copy `ubs` script into `/usr/local/bin/` in Dockerfile
- Wire into pre-commit hook or PreToolUse
- Agents see findings, fix issues, re-run before committing
- Direct safety gate for auto mode: catches bugs humans would catch in review

---

### Meta Skill (ms)

**Repo:** `github.com/Dicklesworthstone/meta_skill`
**Language:** Rust | **Purpose:** Local-first knowledge management with hybrid semantic search

**What it does:**
- Indexes SKILL.md files, builds FTS5 + hash-embedding search
- Thompson sampling bandit for adaptive suggestion ranking
- MCP server for Claude Code integration
- CASS integration for mining patterns from prior sessions
- ~8MB binary, 40+ Rust crate dependencies

**Rip-cage relevance:** Low for containers. Cold-start problem (new container = no learned skills). Better as host-side reference mount (`~/.ms:ro`) if team has accumulated skill database. Don't include in base image.

---

### Process Triage (pt)

**Repo:** `github.com/Dicklesworthstone/process_triage`
**Language:** Rust (8 crates) | **Purpose:** Bayesian zombie process detection and cleanup

**What it does:**
- 5-stage pipeline: Collect → Infer (40+ statistical models) → Decide → Act → Report
- Bayesian inference: BOCPD, HSMM, Kalman filter, EVT, conformal prediction
- 8 possible actions: Keep, Renice, Pause, Freeze, Throttle, Quarantine, Restart, Kill
- Expected-loss minimization with FDR control
- /proc-centric (Linux only)

**Rip-cage relevance:** Low for Phase 1 (single-agent, short-lived containers). Niche value for fleet-scale multi-agent with long-running containers. Over-engineered for the common case. Docker resource limits (`--cpus`, `--memory`) are the simpler solution.

---

### WezTerm Automata / FrankenTerm

**Repo:** `github.com/Dicklesworthstone/wezterm_automata`
**Language:** Rust | **Purpose:** Swarm-native terminal platform for 50-200+ concurrent agents

**What it does:**
- Passive-first observation: `ft watch` with zero side effects, <50ms latency
- Agent state detection: Active/Thinking/Stuck/Idle via pattern matching
- 21-subsystem policy engine with approval tokens and secret redaction
- PAC-Bayesian adaptive backpressure for 60fps UI under extreme load
- Tiered scrollback (hot/warm/cold) keeps 200+ panes under 1GB
- Circuit breaker with cascade detection
- Transactional multi-pane operations (prepare/commit/compensate)
- Robot Mode API: `ft robot state`, `ft robot wait-for <pane> "pattern"`
- MCP integration, distributed mode, flight recorder

**Rip-cage opportunities:**
- **Pattern detection** — adopt agent state detection (Active/Thinking/Stuck) for `rc status`
- **Robot Mode pattern** — `rc robot state` returns JSON of all containers + pane states
- **Container dashboard TUI** — `rc dashboard` showing all containers' states + resource usage (Phase 2)
- **Auto-handle stuck agents** — detect no-output-for-30min, pause/log/notify

---

### System Resource Protection Script (SRPS)

**Repo:** `github.com/Dicklesworthstone/system_resource_protection_script`
**Language:** Bash + Go (TUI) | **Purpose:** Keep dev workstations responsive under agent load

**What it does:**
- ananicy-cpp integration: process classification, priority/nice levels
- Sysctl kernel tuning: swap, dirty pages, inotify, TCP
- TUI monitor (`sysmoni`): CPU/MEM gauges, IO/NET throughput, GPU, per-core sparklines, process tables
- Never ships an automated process killer (safety-first)
- Linux-only (irrelevant on macOS directly)

**Rip-cage opportunities:**
- **Container resource limits** (the right lever for Docker on Mac):
  ```
  --cpus="2" --memory="4G" --memory-swap="4G" --pids-limit=500
  ```
- `sysmoni` TUI patterns (Bubble Tea) inform `rc dashboard` design
- SRPS itself runs on host, not in containers

---

### TOON Rust

**Repo:** `github.com/Dicklesworthstone/toon_rust`
**Language:** Rust | **Purpose:** Token-optimized JSON serialization (40-60% savings)

**What it does:**
- Encodes JSON in token-efficient format for LLMs
- 27x faster encode, 9x faster decode vs Node.js reference
- Streaming architecture for large files
- CLI tool + library API

**Rip-cage relevance:** Low. Niche optimization for very long sessions hitting context limits. Rip-cage's read-only CLAUDE.md already keeps context tight. Nice-to-have at most.

---

### RANO — Network Observer

**Repo:** `github.com/Dicklesworthstone/rano`
**Language:** Rust + SQLite | **Purpose:** AI CLI network monitoring with provider attribution

**What it does:**
- Polls `/proc/<pid>/fd` to map sockets to PIDs (no root needed for PTR mode)
- Tracks descendant processes via `/proc/<pid>/stat`
- Provider attribution: Anthropic, OpenAI, Google
- 4 presets: audit, quiet, live, verbose
- SQLite logging for post-session analysis
- Export to CSV/JSONL

**Rip-cage opportunities (Phase 1b-2):**
- Include RANO binary in image
- `rc monitor <name>` spawns RANO inside container, tails output to host terminal
- Audit trail: which processes made which network calls
- Detect unexpected exfiltration or API abuse
- Low overhead (polling, not ptrace)

---

### Post-Compact Reminder

**Repo:** `github.com/Dicklesworthstone/post_compact_reminder`
**Language:** Bash | **Purpose:** Force AGENTS.md re-read after context compaction

**What it does:**
- SessionStart hook with `matcher: "compact"`
- Outputs plain-text reminder to re-read AGENTS.md
- Atomic file operations for settings.json modification
- 4 built-in templates + custom message support

**Rip-cage relevance:** Low. Rip-cage already uses `bd prime` as PreCompact hook. Read-only CLAUDE.md is always available after compaction. Redundant safety measure.

---

### Agent Settings Backup (asb)

**Repo:** `github.com/Dicklesworthstone/agent_settings_backup_script`
**Language:** Bash | **Purpose:** Git-versioned config backup/restore for AI agent folders

**What it does:**
- Backs up 13 agent config folders to git-versioned repositories
- Named tags, history, diffing, portable archives
- Hooks for pre/post actions
- Scheduled backups via systemd/cron

**Rip-cage relevance:** NONE. **Architecturally incompatible.** Rip-cage intentionally overwrites settings on every container start. asb is designed for stateful local workflows; rip-cage embraces stateless containers.

---

### ACFS Installer

**Repo:** `github.com/Dicklesworthstone/agentic_coding_flywheel_setup`
**Language:** Bash | **Purpose:** Full VPS setup for agentic development

**Key sub-investigations:**

#### Doctor/Health Checks (`scripts/lib/doctor.sh` — 3500+ lines)

ACFS checks: identity, workspace, shell, modern CLIs, core tools, agent CLIs, PATH conflicts, DCG hook status, cloud/DB, network, SSH, deep functional tests. Per-check 15s timeout, 5min TTL caching, human/JSON output.

**Rip-cage gap:** Current `rc test` has 6 checks. Should expand to ~15-20: tools available, auth valid, network/DNS, disk space, mounts readable, permissions, JSON syntax validation of settings.json, hook executable bits.

#### Update Mechanism (`scripts/lib/update.sh` — 1100+ lines)

ACFS: modular update targets (`--apt`, `--agents`, `--stack`, `--self`), version tracking (before/after), retry logic with transient error detection, logging, dry-run, abort-on-failure.

**Rip-cage opportunity:** `rc update` with `--dcg-only`, `--claude-only`, `--hooks`, `--full` flags + version logging.

#### Shell Config (`acfs/zsh/acfs.zshrc` — 350 lines)

Key features: SSH stty guard, terminal type fallback, aggressive PATH setup, Oh My Zsh plugins, modern CLI aliases (lsd, bat, rg, zoxide), git/docker aliases, `mkcd`, `extract()`, auto-ls after cd, VS Code special case, local overrides.

**Rip-cage opportunity:** Expand minimal zshrc with these agent-productive patterns.

#### Security (`scripts/lib/security.sh` — 1100+ lines)

Patterns: HTTPS enforcement on all curls, checksum verification as security boundary, safe temp file handling (`mktemp` + trap cleanup), curl retry with exponential backoff, GitHub rate limit handling.

**Rip-cage opportunity:** Add HTTPS enforcement, retry logic, checksum verification for tool downloads.

#### AGENTS.md (35KB)

Key rules: human override prerogative, file deletion ban, irreversible git command prohibition, branch discipline, toolchain guidance, no script-based changes, backwards compatibility not required, compiler check discipline.

**Rip-cage opportunity:** Expand CLAUDE.md with file deletion rules, testing discipline, code style guide, scope-of-changes guidance.

---

## Opportunity Matrix

### Tier 1: High Impact, Low-Medium Effort (Phase 1)

| # | Opportunity | Source | What | Effort |
|---|------------|--------|------|--------|
| 1 | Replace bd+Dolt with br | beads_rust | Solves Dolt SSH sync, saves ~130MB | Medium |
| 2 | Add UBS to base image | UBS | 3MB bash catches agent bugs before commit | Low |
| 3 | Container resource limits | SRPS | `--cpus`, `--memory`, `--pids-limit` defaults | Low |
| 4 | Credential health monitoring | CAAM | Parse token expiry, warn if <10min, health.json | Low |
| 5 | Expand rc test to 15+ checks | ACFS doctor | Tools, auth, network, disk, mounts, permissions | Medium |
| 6 | Richer shell config | ACFS zshrc | Modern aliases, git shortcuts, terminal fallbacks | Low |

### Tier 2: High Impact, Medium Effort (Phase 1b-2)

| # | Opportunity | Source | What | Effort |
|---|------------|--------|------|--------|
| 7 | rc update command | ACFS update | Granular updates, version tracking, logging | Medium |
| 8 | Session memory via CASS/CM | CASS + CM | Mount playbook.yaml read-only, agents call cm context | Medium |
| 9 | RANO network monitoring | RANO | rc monitor shows real-time network by provider/process | Medium |
| 10 | Container labels + naming | NTM | `--label` flag, human-readable names, filtering | Low |
| 11 | Beads Viewer robot modes | bv | `bv --robot-triage` for agent task prioritization | Medium |
| 12 | CASS session indexing | CASS | Index sessions inside containers for pattern discovery | Medium |

### Tier 3: Medium Impact, High Effort (Phase 2-3)

| # | Opportunity | Source | What | Effort |
|---|------------|--------|------|--------|
| 13 | Multi-agent swarm command | NTM + SLB | `rc swarm create` with broadcast, grouping, lifecycle | High |
| 14 | MCP Agent Mail | Agent Mail | File reservations + async messaging for coordination | High |
| 15 | Container dashboard TUI | FrankenTerm + SRPS | `rc dashboard` with status, resources, agent state | High |
| 16 | SLB peer approval | SLB | Two-person rule for dangerous commands across containers | High |
| 17 | Checkpoint/restore | NTM | Serialize container configs + volume state for recovery | Medium |

---

## Key Architectural Insights

1. **beads_rust solves the biggest current pain point** — Dolt SSH sync failure in containers. JSONL+git is the right sync model for containerized agents.

2. **Shared bind mount IS the multi-agent coordination model** — NTM/SLB confirm that file-level coordination (via git working tree) is sufficient for 2-4 agents. No message bus needed until 5+ agents.

3. **CAAM's credential health pattern is simple and valuable** — even for single-agent: parse token expiry, warn early, track errors with exponential decay.

4. **Agent Mail is the right Phase 3 answer** — file reservations + async messaging via HTTP server. Advisory, not enforced. Git-backed audit trail. But overkill until you have 2+ agents on the same codebase.

5. **Container resource limits are free safety** — `--cpus=2 --memory=4G --pids-limit=500` prevents runaway agents with zero complexity. Docker already supports this; just add defaults to `rc up`.

6. **UBS fills the "auto mode safety gate" gap** — agents running in auto mode generate code without human review. UBS catches predictable bugs (null safety, XSS, missing await) in <5 seconds.

7. **RANO uniquely solves container observability** — per-process network attribution answers "what is this agent doing?" without adding enforcement overhead.

8. **FrankenTerm's observation model informs monitoring** — passive-first (zero side effects), delta-extracted (only new content), event-driven (not polling). These patterns apply to `rc monitor` / `rc dashboard`.

9. **ACFS doctor pattern is battle-tested** — 3500 lines of health checks with timeouts, caching, and structured output. Rip-cage's 6-check `rc test` should grow toward this.

10. **The flywheel is the differentiator** — tools compound over time. Each tool added to the container makes agents more capable. The container is the housing that holds the energy.

---

## Do Not Adopt

| Tool | Reason |
|------|--------|
| Agent Settings Backup (asb) | Conflicts with rip-cage's stateless container design |
| Post-Compact Reminder | Redundant — bd prime / br already handles PreCompact |
| Meta Skill in containers | Cold-start problem; better as host-side reference if at all |
| TOON | Niche optimization; only useful for very long sessions |
| Cross-Agent Session Resumer | Only relevant for multi-provider support (Phase 3+) |
| Process Triage in Phase 1 | Over-engineered for short-lived single-agent containers |

---

*Investigation conducted 2026-03-27 using 9 parallel research agents across 18 cloned repositories.*
