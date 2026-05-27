# ADR-019: pi-coding-agent support — Phase 0

**Status:** Proposed
**Date:** 2026-04-25
**Design:** [Design doc](../../history/2026-04-25-pi-coding-agent-phase0-design.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [ADR-006 Multi-Agent Architecture](ADR-006-multi-agent-architecture.md), [ADR-010 Auth Refresh](ADR-010-auth-refresh.md), project [CLAUDE.md](../../CLAUDE.md) philosophy section
**Supersedes (in part):** the original Phase 0 handoff doc (`docs/handoff-pi-phase0.md`) — that doc's B2 mount strategy and B3 auth-warn matrix are revised here based on prior-art research.

## Context

Rip-cage today supports one harness: Claude Code. Pi (`@mariozechner/pi-coding-agent`) is a multi-provider coding agent (Anthropic, OpenAI/Codex, Gemini, Cerebras, Groq, …) that fits the same container shape and unlocks two near-term goals:

1. Use the user's existing **OpenAI Codex (ChatGPT Plus/Pro)** subscription from inside the cage.
2. Establish the substrate for a future learning project: building a pi extension (`pi.on("tool_call", ...)`) that calls rip-cage's existing `dcg` Rust binary, achieving DCG-equivalent enforcement on pi's bash tool calls.

Phase 0 is "pi runs cleanly in the cage." Phase 1 (DCG-on-pi extension) is deliberately scoped out — see D8.

Prior art surveyed before designing:

| Project | Lesson |
|---|---|
| `pi-less-yolo` (cjermain) | Single bind mount of `~/.pi/agent` to a fixed path with `PI_CODING_AGENT_DIR` env var sidesteps HOME-resolution issues. Provider env-var passthrough list. No auth-warn — let pi fail naturally. |
| `pi-coding-agent-container` | LD_PRELOAD syscall firewall + V8 fs hook + SUID gh-vault. Adversarial threat model. **Out of philosophy** — see D7. |
| `gondolin/pi-gondolin.ts` | Lazy VM init + `pi.registerTool()` override + 4 hooks. Heavier than needed for Phase 1 DCG; useful as Phase 2+ reference. |
| `agent-safehouse` | macOS `sandbox-exec`-only. Doesn't apply to rip-cage's Docker model. |
| pi-mono `examples/extensions/permission-gate.ts` | 30-line `tool_call` regex blocker. **Direct template** for Phase 1 DCG-on-pi extension. |

## Decisions

### D1: Single bind mount of `~/.pi/agent` with `PI_CODING_AGENT_DIR` env var

**Firmness: FIRM**

`rc up` mounts the host's `${HOME}/.pi/agent` directory as a single bind to `/pi-agent` (read-write) inside the container, and exports `PI_CODING_AGENT_DIR=/pi-agent`. Pi's `getAgentDir()` (pi-mono `src/config.ts:208-263`) honors this env var ahead of `~/.pi/agent`, so all pi state — `auth.json`, `sessions/`, `settings.json`, `AGENTS.md`, `extensions/`, `themes/`, `prompts/`, `tools/`, `bin/`, `models.json`, debug logs — resolves to a single, host-owned location with no per-file mounts.

**Rationale:**

- Avoids HOME-resolution and UID-mapping headaches that would arise from per-file mounts under `/home/agent/.pi/agent/...`.
- Future pi state additions (new dirs, new files) "just work" without rip-cage changes.
- Matches the pattern proven by pi-less-yolo, which has been running this shape for months.
- One mount, one env var — minimal surface for B2.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Single mount + `PI_CODING_AGENT_DIR` (this decision)** | One mount; future-proof; matches pi-less-yolo | Whole `~/.pi/agent` is writable from cage (incl. `extensions/`) |
| Per-file mounts at `/home/agent/.pi/agent/...` (handoff doc original plan) | Selective; mirrors Claude per-file pattern | More mounts; UID/HOME complexity; doesn't pick up new state automatically |
| Mount at `~/.pi/agent` inside container (no env var) | No env var | Requires HOME=`/home/agent` to align; more constraints |

**What would invalidate this:**

- Pi removes or renames `PI_CODING_AGENT_DIR` (low risk — long-standing config knob).
- A future need to scope `extensions/` separately (e.g., ship a rip-cage-internal extension at a different path). At that point the mount can be split into `auth.json` + `sessions/` + a repo-internal extensions mount, but Phase 0 doesn't justify it.
- Multi-cage usage (ADR-006 D2) produces noticeable `proper-lockfile` contention on `~/.pi/agent/auth.json` token refresh. At that point, switch to per-cage `auth.json` copies with periodic sync.

### D2: No pi-specific auth-warn at container start

**Firmness: FIRM**

`init-rip-cage.sh` does **not** add an auth-presence check for pi. If `${HOME}/.pi/agent/auth.json` is missing on the host and no provider env var is set, pi will surface that on first request (it shows `/login` guidance in its own UI). The existing Claude-only auth-warn (lines 257-261) stays untouched; its message remains accurate (it claims absence of Claude credentials, not absence of all auth).

**Rationale:**

- Enumerating provider env vars (Anthropic / OpenAI / Cerebras / Groq / Gemini / Mistral / xAI / OpenRouter / Vercel / ZAI / OpenCode / Kimi / MiniMax / MiniMax-CN / Azure) creates a list that will rot every time pi adds a provider.
- Pi's own UI is the right surface for "you're not authed" — it's contextual, actionable (`/login`), and provider-agnostic.
- Matches pi-less-yolo's design (no warn).
- Reduces startup-banner noise. Per project CLAUDE.md, "it's annoying" is a design signal — that applies preemptively to misleading or redundant warnings.

**What would invalidate this:**

- Pi hides auth failures behind silent retries (it currently does not).
- User testing shows the Codex-OAuth-only flow fails confusingly without a pre-flight check. In that case, narrow the check to "no `auth.json` AND no `OPENAI_API_KEY` AND no `ANTHROPIC_API_KEY`" rather than the full provider matrix.

### D3: Cage-topology metadata lives in cage-owned paths only; init never mutates host-bind-mounted dotfiles

**Firmness: FIRM**

A `cage-pi.md` at the repo root (parallel to `cage-claude.md`) is `COPY`'d into the image at `/etc/rip-cage/cage-pi.md`. This is a cage-owned path — image-baked, never written by init.

Cage-topology is surfaced to agents via a reference line inside the `<!-- begin:rip-cage-topology -->` fence in `~/.claude/CLAUDE.md` (the cage-owned Claude Code context file, maintained by init from `cage-claude.md`). The reference line reads:

```
For pi-specific cage topology, see /etc/rip-cage/cage-pi.md
```

`init-rip-cage.sh` does **not** append any content to `/pi-agent/AGENTS.md`. `/pi-agent/` is bind-mounted from the host's `~/.pi/agent/` directory (ADR-019 D1). When the user manages that directory via dotpi (a dotfiles manager that symlinks to a canonical file), init-side writes propagate across every machine using dotpi. Treating a host-bind-mounted dotfile as a writable surface for cage-owned metadata is therefore unsafe. Init logs a discovery message when the pi mount is present but writes nothing.

**Rationale:**

- Cage-owned metadata belongs in cage-owned paths. `/etc/rip-cage/` (image-baked) and `~/.claude/CLAUDE.md` (written from cage-claude.md by init) are both cage-owned. `/pi-agent/AGENTS.md` (bind-mounted from `~/.pi/agent/`) is host-owned.
- A user managing `~/.pi/agent/AGENTS.md` via dotpi gets that file symlinked to a canonical dotpi repo entry. Init-side appends write to the symlink target, propagating cage internals to every machine in the dotpi repo. This was observed as a real failure mode.
- The reference approach gives pi agents equivalent discoverability: the cage-authored CLAUDE.md (loaded by Claude Code) contains the path; pi agents can read `/etc/rip-cage/cage-pi.md` directly. The path is stable and documented.
- `cage-pi.md` retains its fenced `<!-- begin:rip-cage-topology-pi -->` markers for grep-ability by tests and agents, but those markers live inside the image-baked file, not in any host file.

**Alternatives considered:**

| Approach | Verdict |
|---|---|
| Append to `/pi-agent/AGENTS.md` with `awk` strip-and-replace (original D3) | Rejected — mutates host-bind-mounted dotfile; unsafe with dotpi |
| Per-cage copy of `AGENTS.md` (not a bind mount) | Would lose user's real pi global context; breaks pi workflows |
| Reference in `~/.claude/CLAUDE.md` only (this decision) | Cage-owned path; discovered via Claude Code's auto-loaded CLAUDE.md; no host mutation |

**What would invalidate this:**

- Pi's context discovery for AGENTS.md stops relying on `~/.claude/CLAUDE.md` references entirely (e.g., pi drops CLAUDE.md scanning). At that point, add a cage-owned `~/.pi/agent/AGENTS.md`-equivalent at a path that is NOT bind-mounted from the host.
- The project wants to inject project-scoped pi context. Different feature, different bead.

**Canonical refs:**

- ADR-011 D1 (in-place rule — this decision edited in place, no supersession chain)
- ADR-016 D1 (fence convention for `~/.claude/CLAUDE.md` topology appends)
- `cage-claude.md`, `cage-pi.md`, `init-rip-cage.sh` (implementation locus)

### D4: Pi must have on-device-harm protection equivalent to Claude Code's DCG + compound-blocker surface (Phase 1 promoted)

**Firmness: FIRM (goal). Mechanism FLEXIBLE pending pi-hook research bead.**

**Evolved 2026-05-27 per [ADR-024](ADR-024-prompt-injection-threat-model.md).** The pre-evolution decision deferred Phase 1 (DCG-on-pi extension) as a "learning project" while pi ran in the cage without command-level enforcement. Phase 0's deferral was acceptable under the "agent not adversarial" framing. Under ADR-024 D1's prompt-injection threat class, on-device-harm is named as a first-class harm axis (ADR-024 D2); pi's lack of DCG / compound-blocker is now an under-covered axis, no longer acceptable as a phase-0 gap. Phase 1 is promoted from "deferred learning project" to required.

**Current decision (goal — FIRM):** pi cages must have on-device-harm protection equivalent to Claude Code's DCG + compound-blocker active surface. Specifically, pi cages must refuse the same destructive-command class (per DCG) and the same chaining-bypass class (per compound-blocker) that Claude Code cages refuse.

**Current decision (mechanism — FLEXIBLE):** the specific extension shape for pi's hook surface is open. Pi uses a different agent runtime / hook config than Claude Code's PreToolUse hooks. A pi-hook research bead (filed alongside the epic that evolves this decision) determines the mechanism — plausible shapes: extend `hooks/block-compound-commands.sh` to pi's PreToolUse equivalent if pi has one; OR a pi-side bash wrapper that intercepts shell invocations; OR a pi-MCP-server shim that DCG-checks pi tool calls before forwarding; OR the original D8 Phase 1 extension shape (`pi.on("tool_call", ...)` calling the `dcg` Rust binary).

Until the research bead determines the mechanism and the impl bead delivers it, **pi cages must not be shipped to users as a finalized configuration.** The transient gap is acceptable for the design-and-research bead set; it is not acceptable for a released-to-users pi cage under the new threat model.

This evolves D8 of this ADR as well: D8's "Phase 1 deferred as learning project" reasoning is retired; the work is required, the mechanism research is split off.

**Rationale:**

- ADR-024 D2 names on-device-harm as one of two harm axes the cage covers. The pre-evolution carve-out for pi left that axis uncovered for pi cages specifically — asymmetric coverage with no threat-model justification.
- The mechanism research is the right way to handle "pi's hook surface differs from Claude Code's" without locking the design prematurely. FIRM on the goal + FLEXIBLE on the mechanism is the rigor-correct shape per ADR-008 D1.
- The user's learning-project rationale from the pre-evolution D8 is preserved at the implementation layer — the research bead and impl bead are where the learning happens; the threat-model commitment is what changes.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Promote Phase 1; goal-FIRM + mechanism-FLEXIBLE (this decision)** | Honest about what's known vs unknown; addresses ADR-024 D2 symmetry | More substrate work (research bead + impl bead) |
| Keep Phase 0 deferral | Smaller scope | `direct:` rejected — ADR-024 D2 admits on-device-harm; pi cages cannot remain asymmetrically uncovered |
| FIRM-bind the mechanism (e.g., "extend block-compound-commands.sh") | Tighter | `reasoned:` rejected — premature; pi's hook surface may not support it; locking the mechanism without research is the failure mode reviewer S-2/S-3 flagged during the brainstorm |
| Defer Phase 1 indefinitely with documented gap | Easiest | `reasoned:` rejected — the gap is now load-bearing for ADR-024 D2 coverage; can't be left as documented residual |

**What would invalidate this:**

- Pi's runtime architecture admits no usable hook surface (no PreToolUse equivalent, no wrapper point, no MCP gate). At that point the goal stands but requires a different layer (e.g., container-level seccomp profile) the current design doesn't scope. Research bead reports this as a structural finding if it surfaces.
- Pi-in-cage demonstrates a class of accident in normal use that container-level mitigations DO catch (contradicting the threat-model assumption). Unlikely but would re-open the deferral question.

### D5: Provider env vars are passed through unconditionally

**Firmness: FLEXIBLE**

`rc up` forwards a fixed list of pi-relevant env vars from host to container **only when set to a non-empty value**. The list mirrors pi-less-yolo's, minus host-path-only vars:

```
ANTHROPIC_API_KEY, AZURE_OPENAI_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY,
MISTRAL_API_KEY, GROQ_API_KEY, CEREBRAS_API_KEY, XAI_API_KEY,
OPENROUTER_API_KEY, AI_GATEWAY_API_KEY, ZAI_API_KEY, OPENCODE_API_KEY,
KIMI_API_KEY, MINIMAX_API_KEY, MINIMAX_CN_API_KEY,
PI_SKIP_VERSION_CHECK, PI_CACHE_RETENTION
```

`PI_PACKAGE_DIR` is **excluded** from the passthrough list — it points at a host filesystem path used in pi development and would resolve to a non-existent path inside the cage, breaking pi startup. Empty-string vars are filtered out at forward time (both `rc up` and devcontainer paths) so pi's `auth.json`-over-env priority order isn't perturbed by `OPENAI_API_KEY=""` style entries.

If `auth.json` is also present, it takes priority (pi behavior — see pi-mono `docs/providers.md`).

**Rationale:**

- Enables non-OAuth flows (CI, scripted runs, providers without an OAuth path).
- Trivial to maintain — copying pi-less-yolo's list is one shell array.
- Setting an env var on the host is an explicit user action; pass-through is not a privacy regression.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Fixed allowlist (this decision)** | Predictable; easy to audit | List rots as pi adds providers |
| Pass through every `*_API_KEY` env var | Self-maintaining | Surprising — leaks API keys for unrelated services |
| Auth.json only (no env vars) | Smallest surface | Forces every user through `pi /login` even when they have an API key in shell env |

**What would invalidate this:**

- Pi provider count grows fast enough that the list rots noticeably. Switch to pattern-based passthrough (`*_API_KEY` matching pi's known providers, sourced from pi-mono).

### D6: TOS callout lives in docs only — no runtime warning

**Firmness: FIRM**

`docs/reference/auth.md` gains a "Pi auth" section with a clear TOS callout: pi-mono's "Personal use only" line for Codex OAuth, the Anthropic January 2026 third-party-tool enforcement precedent, and a link to OpenAI's Service Terms. `init-rip-cage.sh` does **not** print a runtime banner.

**Rationale:**

- Runtime banners get banner-blind fast and add startup noise. Users see them once, then never read again.
- Docs are the right surface for legal/policy context — searchable, version-controlled, citable.
- The user has explicitly opted in by running `pi /login`. Re-warning at every `rc up` is the kind of UX limp the philosophy section flags as a design smell.

**What would invalidate this:**

- A specific incident where a user runs into TOS enforcement and reports they didn't see the doc. At that point, consider a one-time first-run banner (write a sentinel to `/pi-agent/.rip-cage-tos-acked`).

### D7: Reject adversarial in-container hardening

**Firmness: FIRM**

Rip-cage explicitly does **not** adopt pi-coding-agent-container's hardening techniques: LD_PRELOAD syscall firewall (`fs-vault.so`), Node.js V8 fs hook (`app-firewall.js`), SUID gh-vault binary, `/etc/ld.so.preload` enforcement, removal of privilege-escalation binaries (`su`, `mount`, `passwd`, etc.).

Documented in `docs/reference/auth.md` under "Why rip-cage doesn't ship paranoid mode" with rationale: those mitigations target a motivated-attacker threat model, while rip-cage's threat model is "limit blast radius of an autonomous agent's accidents." Adversarial mitigations add complexity, fragility, and force the agent through detection-evasion-flavored UX (write blocked, retry, fail confusingly) — which violates the autonomy-over-containment philosophy.

**Rationale:**

- See project CLAUDE.md philosophy section: "the thing inside the cage is not you" framing is explicitly out of scope.
- Container isolation + egress firewall + non-root + DCG (for Claude) + compound-blocker (for Claude) + Phase 1 DCG extension (for pi) catches the realistic failure modes.
- Carrying the paranoid-mode dependencies (a C compiler in build, a SUID binary, runtime LD_PRELOAD) would be a substantial new attack surface in itself.

**What would invalidate this:**

- A demonstrated class of bug where a misbehaving agent reads credential files via a child process that bypasses pi's tool layer, and where fs-vault-style preload would have blocked it. So far this is hypothetical.

### D8: Phase 1 (DCG-on-pi extension) deferred — designated as user's learning project

**Firmness: FLEXIBLE**

Phase 1 — a pi extension at `extensions/pi/dcg-gate.ts` (or similar) that registers `pi.on("tool_call", ...)` and spawns the existing `dcg` Rust binary as a subprocess to validate every bash command — is **not** filed as Phase 0 beads. Reference template: pi-mono `examples/extensions/permission-gate.ts` (regex blocker; 30 lines) plus the subprocess pattern from `examples/extensions/sandbox/index.ts:134-199`.

Three things must hold for Phase 1 to land:

1. The extension is checked into the rip-cage repo (not the user's personal `~/.pi/agent/extensions/`), distributed with the cage, version-controlled with the rest of the safety stack.
2. It's wired in via either `pi -e <path>` in `init-rip-cage.sh` or via a `settings.json` `extensions` entry — not via host-side `~/.pi/agent/extensions/` mount.
3. It calls the same `dcg` binary the Claude Code PreToolUse hook calls, so policy stays in one place.

**Rationale:**

- The extension is sized right for a learning project — small, well-defined, with reference implementations.
- Splitting Phase 0 from Phase 1 keeps the Phase 0 bead set tight and gives the user the satisfying part of the work (the actual safety layer) without an agent doing it for them.
- The transient safety gap (D4) is bounded by how long Phase 1 takes.

**What would invalidate this:**

- D4's "what would invalidate" condition triggers (real-world accident class that container-level mitigations miss). At that point, accelerate to a non-learning-project implementation.
- The user later prefers to defer Phase 1 indefinitely. Reasonable; the gap is documented; pi-in-cage remains the safer-than-host default.

## Deferred (out of Phase 0 scope; file as separate beads)

- **Read-only mode** — `rc up --readonly` analogous to pi-less-yolo's `pi:readonly` (mounts cwd `:ro`, restricts pi tools to `read,grep,find,ls`). Useful for "audit this code without letting the agent touch it." Separate scope.
- **`rc auth refresh`-equivalent for pi** — pi auto-refreshes via the mounted `auth.json` (uses `proper-lockfile` for concurrent refresh). Not needed; file a follow-up bead only if observed otherwise.
- **Pi-mom / always-on / Slack / Telegram transport** — completely separate.
- **Mac mini deployment doc** — separate piece of work after Phase 0 lands.

## Implementation summary

Phase 0 ships as 6 beads (B1-B6 in the [design doc](../../history/2026-04-25-pi-coding-agent-phase0-design.md)) plus a parent bead "Phase 0: pi-coding-agent support":

| Bead | One-liner |
|---|---|
| B1 | Add `npm install -g @mariozechner/pi-coding-agent@${PI_VERSION}` to Dockerfile |
| B2 | Mount `~/.pi/agent` → `/pi-agent`, set `PI_CODING_AGENT_DIR`, pass through provider env vars |
| B3 | `init-rip-cage.sh` verifies `pi --version`; no auth-warn added |
| B4 | New `cage-pi.md`; init script appends fenced block to `/pi-agent/AGENTS.md` |
| B5 | Docs: `auth.md` Pi-auth section + TOS callout + paranoid-mode rejection rationale; README one-liner |
| B6 | New `tests/test-pi-e2e.sh`: `pi -p` smoke test |

Order: B1 → B2 → B3 → B4 → B6 → B5.
