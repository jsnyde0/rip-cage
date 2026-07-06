# ADR-019: pi-coding-agent support — Phase 0

**Status:** Proposed
**Date:** 2026-04-25 (D1 revised 2026-06-01; D4 evolved 2026-05-27; D8 revised 2026-06-02 — Phase 1 shipped; D8 revised again 2026-06-09 — PI_VERSION=latest + guard-parity tripwire wired; D9 added 2026-06-09 — bash-only agents reach in-cage daemons via CLI, not MCP; D1 mechanism prose reconciled 2026-07-06 to the post-9b67bb6 un-baked reality — rip-cage-5vs4)
**Design:** [Design doc](../../history/2026-04-25-pi-coding-agent-phase0-design.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [ADR-006 Multi-Agent Architecture](ADR-006-multi-agent-architecture.md), [ADR-010 Auth Refresh](ADR-010-auth-refresh.md), project [CLAUDE.md](../../CLAUDE.md) philosophy section, **dotpi ADR-002 Cross-Harness Substrate** (cross-repo: `dotpi/docs/decisions/ADR-002-cross-harness-substrate.md` — its D1 re-affirms this ADR's D7 no-evasion stance)
**Supersedes (in part):** the original Phase 0 handoff doc (`docs/handoff-pi-phase0.md`) — that doc's B2 mount strategy and B3 auth-warn matrix are revised here based on prior-art research.

## Context

Rip-cage today supports one harness: Claude Code. Pi (`@mariozechner/pi-coding-agent`) is a multi-provider coding agent (Anthropic, OpenAI/Codex, Gemini, Cerebras, Groq, …) that fits the same container shape and unlocks two near-term goals:

1. Use the user's existing **OpenAI Codex (ChatGPT Plus/Pro)** subscription from inside the cage.
2. Establish the substrate for a future learning project: building a pi extension (`pi.on("tool_call", ...)`) that calls rip-cage's existing `dcg` Rust binary, achieving DCG-equivalent enforcement on pi's bash tool calls.

Phase 0 is "pi runs cleanly in the cage." Phase 1 (DCG-on-pi extension) was scoped out of Phase 0, later promoted to required (D4, 2026-05-27 per ADR-024), and has now shipped (D8, rip-cage-bl1).

Prior art surveyed before designing:

| Project | Lesson |
|---|---|
| `pi-less-yolo` (cjermain) | Single bind mount of `~/.pi/agent` to a fixed path with `PI_CODING_AGENT_DIR` env var sidesteps HOME-resolution issues. Provider env-var passthrough list. No auth-warn — let pi fail naturally. |
| `pi-coding-agent-container` | LD_PRELOAD syscall firewall + V8 fs hook + SUID gh-vault. Adversarial threat model. **Out of philosophy** — see D7. |
| `gondolin/pi-gondolin.ts` | Lazy VM init + `pi.registerTool()` override + 4 hooks. Heavier than needed for Phase 1 DCG; useful as Phase 2+ reference. |
| `agent-safehouse` | macOS `sandbox-exec`-only. Doesn't apply to rip-cage's Docker model. |
| pi-mono `examples/extensions/permission-gate.ts` | 30-line `tool_call` regex blocker. **Direct template** for Phase 1 DCG-on-pi extension. |

## Decisions

### D1: Container-local cage-owned pi config dir with narrow durable sub-mounts

**Firmness: FIRM** *(revised 2026-06-01 — evolved from the original "single bind mount of the whole `~/.pi/agent`"; the original is preserved in git history and as the rejected first row of the Alternatives table below. Triggered per this decision's own invalidation clause once D4 made a cage-owned pi extension path required.)*

`rc up` gives pi a **container-local, cage-owned** config dir at `/home/agent/.pi/agent` — materialized at container-create time by the `auth.json` bind mount below (Docker auto-creates the missing parent **root-owned**; `init-rip-cage.sh` immediately `chown`s it `agent:agent`, and — since rip-cage-fwp3, 2026-07-02 — also creates an agent-owned `extensions/` subdir, gated on `command -v pi`) — and exports `PI_CODING_AGENT_DIR` pointing at it. *(Mechanism reconciled 2026-07-06, rip-cage-5vs4: the dir was originally image-baked via a Dockerfile `mkdir` after `USER agent`; the ADR-027 D4 un-bake migration — commit 9b67bb6, wlwc.2.2 — removed that image-time mkdir without this prose being updated. The root-owned-parent hazard this decision's alternatives table names is now briefly incurred by the accepted path too, and is closed by init's chown; see the reconciled table note below.)* Only **durable user state** is bind-mounted from the host into subpaths of that dir:

- `auth.json` — **read-write** (required). Pi rewrites it in place on automatic OAuth token refresh (pi-mono `core/auth-storage.ts:151-153`, refresh path `:440`, triggered by `getApiKey` when the token is expired `:476-481`), exactly like Claude Code's `.credentials.json` — so a read-only mount would EROFS and silently drop auth.
- `sessions/` — read-write, **optional** (resume history; losing it is annoying, not fatal).

All **cage-config** paths resolve to the cage-owned dir and are baked or container-regenerated, never sourced from the host: chiefly `extensions/` (the guard-extension target), plus `settings.json`, `models.json`, `prompts/`, `themes/`, `keybindings.json`. `bin/` (fd/rg) is container-regenerated and **must not** be host-mounted — host macOS binaries are the wrong platform for the Linux container.

This mirrors the existing `~/.claude` pattern (agent-owned dir + narrow RW credential sub-mount + init `chown` + cage-installed config files; `~/.claude` itself is still image-baked — pi's dir takes the mount-materialized variant per above). The guard load path has since moved past this paragraph's original expectation: the D4/Phase-1 guard was first designed to ride a cage-owned `extensions/` auto-discovery path, but the shipped mechanism (D8; ADR-027 D1/D3) loads the guard via an explicit `-e` of the root-owned `/etc/rip-cage/pi/dcg-gate.ts` from the `pi` wrapper — `extensions/` stays agent-owned for pi's own use.

**Cold-start seeding (added 2026-06-04, rip-cage-wo9).** When the host has no `~/.pi/agent/auth.json` (fresh machine), `rc up` creates the directory and seeds the file with `{}` *before* binding it, rather than skipping the mount. Without seeding, an in-cage `pi /login` writes to the container-local path and is lost on `rc destroy`/`up` — forcing re-login on every rebuild, the autonomy "limp" the philosophy section flags. Seeding is host-side (in `rc up`, **not** `init-rip-cage.sh`, so D3 is untouched) and verified safe against pi source (`core/auth-storage.ts`, read 2026-06-04): pi loads an empty/`{}`/malformed `auth.json` gracefully as "no auth → `/login`" (`parseStorageData` returns `{}` for empty content; JSON-parse errors are caught into a non-fatal `loadError`), and both `/login` (`set`→`persistProviderChange`) and token-refresh (`:151-153`) write **in place** via `writeFileSync` to the same inode — no temp-file-plus-rename — so a single-file bind mount persists the credentials back to the host. The seed is a regular file, so it is transparent to the symlink-follow fingerprint (which hashes only symlinks + policy header), and existing cold cages see no spurious resume drift. Seeding is skipped if the path is a (possibly dangling) symlink — dotpi-managed state is left to the symlink-follow machinery. This preserves D1's narrow single-file mount and D2's no-startup-auth-check.

**Rationale:**

- **D4 (FIRM) now requires** DCG-equivalent enforcement on pi, and **D3 (FIRM) forbids** writing cage-owned metadata into host-bind-mounted dotfiles. The guard extension is cage-owned metadata; under the old whole-dir mount its only home was `/pi-agent/extensions/` — a host-mounted path D3 prohibits. A container-local dir is the topology that satisfies D3 + D4 together; this evolution *advances* D3 rather than contradicting it.
- Pi resolves its entire dir from one env var and **never builds or clobbers the dir as a tree** — each subsystem lazily `mkdir`s its own subpath (pi-mono `config.ts:209-263`), so a split dir (container-local + sub-mounts) is safe; there is no first-run routine that overwrites the tree.
- Durable state is minimal — only `auth.json` must persist. Narrow sub-mounts keep host pi state unexposed and not wholesale-writable, which is **strictly safer** than the old whole-dir RW mount.
- The per-file UID/HOME complexity the original D1 avoided is already a **solved problem** — `~/.claude` runs this shape (image-baked agent-owned parent + skip-if-missing mount guards + init `chown` + sudoers-scoped `chown`); pi's dir now runs the mount-materialized variant of the same shape (Docker implicit-create + init `chown`).

**Counter-argument to the original rationale (FIRM-path requirement):** The original D1 rested on three pillars — (a) avoid per-file UID/HOME complexity, (b) future pi state "just works", (c) one mount = minimal surface. **(a)** is moot: the `~/.claude` pattern already solves per-file mounts cleanly, so the complexity is solved, not incurred. **(b)**'s future-proofing is now the *harm*: auto-picking-up `extensions/` from the host mount is precisely the D3 violation, and it forecloses the D4-required cage-owned guard path. **(c)** inverts: a whole-dir RW mount of host pi state is *more* attack/pollution surface, not less, than a narrow `auth.json` sub-mount. The original rationale no longer holds because **the invalidation condition D1 itself named has materialized** (a rip-cage-internal extension must now ship at a cage-owned path), and the Phase-0 "doesn't justify it" caveat has lapsed — we are past Phase 0.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Container-local dir + narrow durable sub-mounts (this decision)** | Cage-owned topology; satisfies D3; host pi state unexposed; mirrors proven `~/.claude` shape | A few mounts + implicit-created parent reconciled by init `chown` (`reasoned:` already-solved pattern — `~/.claude` runs the image-baked variant today) |
| Single mount of the whole `~/.pi/agent` (the prior D1) | One mount; future-proof; matches pi-less-yolo | `reasoned:` `extensions/` would live on the host-writable mount → violates D3 (FIRM) and forecloses the D4-required (FIRM) cage-owned guard path; host pi state wholesale-writable from the cage |
| Keep the whole-dir mount, load the guard via the `-e` flag | No topology change | `reasoned:` pi is launched interactively (no cage-controlled launch line to attach `-e` to); a shell-wrapper `-e` is bypassable (`command pi` / absolute path) and not default-loaded — strictly weaker than Claude Code's cage-installed-config parity |
| Per-file mounts with no container-local dir (handoff doc original) | Selective | `direct:` UID/HOME complexity with no parent-dir ownership story; Docker auto-creates missing mount parents as root **with no chown reconciliation**. *(Reconciled 2026-07-06: since 9b67bb6 the accepted path also relies on Docker implicit-create, but pairs it with init's immediate `chown` — this rejection stands against per-file mounts lacking that ownership reconciliation, not against implicit-create per se.)* |

**What would invalidate this:**

- Pi changes extension discovery so `<agentDir>/extensions/` is no longer auto-scanned without a flag → would force back to an explicit-load mechanism for the guard.
- Pi consolidates config + durable state into a single artifact that doesn't tolerate a split dir (e.g., one sqlite spanning auth + settings + sessions) → re-widen the persist set or revisit the topology.
- Pi removes or renames `PI_CODING_AGENT_DIR` (low risk — long-standing config knob).
- Multi-cage usage (ADR-006 D2) produces noticeable `proper-lockfile` contention on the host-mounted `auth.json` token refresh → switch to per-cage `auth.json` copies with periodic sync. (Carried over from the original D1.)
- Pi switches `auth.json` writes from in-place (`writeFileSync`) to atomic temp-file-plus-rename → a single-file bind mount would no longer persist in-cage writes back to the host, breaking cold-start seeding; re-verify against pi source on each version bump (pinned-dep coupling) and, if changed, mount the directory or widen the persist set.

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

- In-place-evolution convention (this decision edited in place, no supersession chain; note: rip-cage's local ADR-011 is shell-completions, not this rule)
- ADR-016 D1 (fence convention for `~/.claude/CLAUDE.md` topology appends)
- `cage-claude.md`, `cage-pi.md`, `init-rip-cage.sh` (implementation locus)

### D4: Pi must have on-device-harm protection equivalent to Claude Code's DCG + compound-blocker surface (Phase 1 promoted)

**Firmness: FIRM (goal). Mechanism FLEXIBLE pending pi-hook research bead.**

**Evolved 2026-05-27 per [ADR-024](ADR-024-prompt-injection-threat-model.md).** The pre-evolution decision deferred Phase 1 (DCG-on-pi extension) as a "learning project" while pi ran in the cage without command-level enforcement. Phase 0's deferral was acceptable under the "agent not adversarial" framing. Under ADR-024 D1's prompt-injection threat class, on-device-harm is named as a first-class harm axis (ADR-024 D2); pi's lack of DCG / compound-blocker is now an under-covered axis, no longer acceptable as a phase-0 gap. Phase 1 is promoted from "deferred learning project" to required.

**Current decision (goal — FIRM):** pi cages must have on-device-harm protection equivalent to Claude Code's DCG active surface. Specifically, pi cages must refuse the same destructive-command class (per DCG) that Claude Code cages refuse. Note: the compound-blocker was removed from both Claude Code and pi cages in rip-cage-4r8 (ADR-002 D5) — DCG is chaining-robust; the equivalence goal remains in force via DCG alone.

**Equivalence axis (FIRM, added 2026-06-02 per rip-cage-bl1):** "equivalent enforcement" means **loaded-by-default + active**, NOT **tamper-proof**. Claude Code's own DCG hook lives in an agent-writable `settings.json`; the parity bar for pi is therefore "the guard is loaded by default via a cage-owned path and actively enforces," not "the guard is unstrippable by the caged agent." This is consistent with D7 (rejects adversarial in-container hardening) and the layers-not-walls philosophy (CLAUDE.md) — a future agent must NOT over-invest in making the pi extension tamper-resistant beyond the cage-owned-path + auto-load default that D1/D8 already provide. Closing the multi-tool bypass and the workspace-config self-disable hole (ADR-025 D3/D4) is in-scope; defeating a motivated in-cage attacker is not.

**Current decision (mechanism — FLEXIBLE):** the specific extension shape for pi's hook surface is open. Pi uses a different agent runtime / hook config than Claude Code's PreToolUse hooks. A pi-hook research bead (filed alongside the epic that evolves this decision) determines the mechanism — plausible shapes: a pi-side bash wrapper that intercepts shell invocations; OR a pi-MCP-server shim that DCG-checks pi tool calls before forwarding; OR the original D8 Phase 1 extension shape (`pi.on("tool_call", ...)` calling the `dcg` Rust binary).

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
- Container isolation + egress firewall + non-root + DCG (chaining-robust, for both Claude and pi) + ssh-bypass blocker catches the realistic failure modes. (Compound-blocker removed rip-cage-4r8; DCG covers the chaining gap.)
- Carrying the paranoid-mode dependencies (a C compiler in build, a SUID binary, runtime LD_PRELOAD) would be a substantial new attack surface in itself.
- Cross-repo: **dotpi ADR-002** (cross-harness substrate, `dotpi/docs/decisions/ADR-002-cross-harness-substrate.md`) D1 re-affirms this no-evasion stance from the dotpi side — the two decisions cross-reference each other (rip-cage-e0w).

**What would invalidate this:**

- A demonstrated class of bug where a misbehaving agent reads credential files via a child process that bypasses pi's tool layer, and where fs-vault-style preload would have blocked it. So far this is hypothetical.

### D8: Phase 1 (DCG-on-pi extension) — SHIPPED (rip-cage-bl1); PI_VERSION=latest with guard-parity tripwire (rip-cage-9yg0)

**Firmness: FLEXIBLE** *(revised 2026-06-02 — Phase 1 shipped; the original "deferred as user's learning project" framing is retired and preserved in git history. D4's threat-model promotion (2026-05-27, ADR-024) made the work required; rip-cage-1m7 researched the mechanism and rip-cage-bl1 delivered it. Revised again 2026-06-09 — PI_VERSION=latest (user wants fresh pi; pinning explicitly rejected); guard-parity tripwire added (rip-cage-9yg0) as the bump-safety mechanism.)*

Phase 1 shipped as the pi `dcg-gate.ts` extension (source `examples/pi/dcg-gate.ts`, baked root-owned at `/etc/rip-cage/pi/dcg-gate.ts`) — a pi extension that registers `pi.on("tool_call", ...)` and, for every exec-capable tool call, forwards the command to the existing `dcg` binary (via the CWD-anchor wrapper `/usr/local/lib/rip-cage/bin/dcg-guard`, ADR-025 D3/D4), blocking via `{ block, reason }`. Reference template: pi-mono `examples/extensions/permission-gate.ts` plus the subprocess pattern from `examples/extensions/sandbox/index.ts`. Note: the compound-command blocker that was part of the original two-gate design was removed in rip-cage-4r8 (ADR-002 D5) — DCG is chaining-robust.

All three landing conditions hold, with condition 2's mechanism **superseded before implementation**:

1. ✅ The extension is checked into the rip-cage repo (`examples/pi/dcg-gate.ts`, a composable recipe artifact per ADR-027 D3) and baked root-owned at `/etc/rip-cage/pi/dcg-gate.ts` — distributed with the cage and version-controlled with the rest of the safety stack, not the user's personal `~/.pi/agent/extensions/`.
2. ✅ It is wired in by an **explicit `-e` load of the root-owned guard at launch**: the cage's root-owned `pi` wrapper (`/usr/local/bin/pi`) loads `-e /etc/rip-cage/pi/dcg-gate.ts`. **As of 2026-07-02 (ADR-027 D1, FIRM) the DCG default posture is OPEN** — the wrapper does NOT add `--no-extensions` by default, so pi auto-discovers (and can write) its own extensions; pi's vector-b (an injected agent dropping a competing/shadowing extension into the workspace-writable `.pi/extensions/`) is a **knowingly-accepted residual** in the default, mitigated by the construction skill surfacing the tradeoff at cage setup. The **LOCKED** opt-in adds `--no-extensions` to disable auto-discovery and close vector-b for operators who want the tighter cage. *(This **reverses** the original Phase-1 auto-discovery mechanism: auto-scanning an agent-reachable `extensions/` dir was itself the bypass — an injected agent could drop a post-approval-mutating extension — so rip-cage-sn1h moved to explicit `-e` of a vetted guard. And olen is **retired** (rip-cage-wlwc.4, ADR-027 D1/D3): the guard lives on its OWN separate root-owned load path `/etc/rip-cage/pi/`, NOT inside the agent's `extensions/` dir, which is agent-owned — a dir cannot be both root-locked and agent-writable.)* See D1, ADR-027 D1/D3.
3. ✅ It calls the same `dcg` binary (through the shared `dcg-guard` wrapper) the Claude Code PreToolUse hook calls, so policy stays in one place (ADR-025).

**Implementation specifics (rip-cage-bl1):** the dcg stdin envelope pins `tool_name:"bash"` regardless of the originating pi tool name (else dcg's tool-name filter returns no-command and fails OPEN); the decision is read from dcg stdout JSON `hookSpecificOutput.permissionDecision` (not exit code); the guard fails OPEN on internal error (agent not wedged) and fails CLOSED-loud on a genuine deny (readable reason naming rule + safe alternative); a fail-loud init presence check refuses to launch pi unguarded; DCG-PI-* checks in `examples/dcg/smoke.sh` (run in-cage by run-recipe-smokes.sh via `rc test`) regression-guard parity in both `rc test` branches. Live LOAD+FIRE verified in a real authed pi cage. (test-pi-dcg-gate.sh removed rip-cage-wiwa — probes co-located with the recipe.)

**PI_VERSION=latest + guard-parity tripwire (rip-cage-9yg0):** pi is installed at `latest` (`Dockerfile ARG PI_VERSION=latest`) — pinning to a specific version is explicitly rejected (user wants fresh pi). The "known acceptable gap" from the original rip-cage-bl1 shipping note (exec-capable tools that use a non-`command` field pass unguarded) is bounded by a **guard-parity re-verify check** in `examples/dcg/smoke.sh` (DCG-PI-PARITY-5a/5b/5c, run via `rc test`). The check is a content/schema parity check (Option 1 — FAIL altitude, not a soft WARN): it locates the installed pi dist at the stable npm path (`/usr/lib/node_modules/@mariozechner/pi-coding-agent/dist/core/tools/bash.js`), asserts `bashSchema` is found with a `command: Type.String` field (positive sentinel — the check cannot false-green if the dist path moves), and then asserts no alternative exec-field names (`script`, `cmd`, etc.) appear in schema position in the dist. A parallel check on `allToolNames` in `index.js` catches newly-registered exec-capable tools not in the known set. The check fires ONLY on real exec-surface drift (not on harmless version bumps), making it the 80/20 bump-safety mechanism for `PI_VERSION=latest`. When the check fires FAIL, the corrective action is: re-read the pi dist exec-tool schemas, update `extractCommand` in `examples/pi/dcg-gate.ts` (and regenerate the recipe fragment) to cover the new field, and re-verify before the next cage build.

**Rationale (retained):**

- The extension was sized right and delivered the actual safety layer rather than an open-ended deferral.
- Splitting research (rip-cage-1m7) from implementation (rip-cage-bl1) kept the mechanism decision honest (FLEXIBLE per D4) without locking it prematurely.
- `PI_VERSION=latest` with a content-based tripwire is the right balance: agents get fresh pi, and exec-surface drift is caught before it reaches a running cage (the check runs in `rc test`, which every cage validation uses).

**What would invalidate this:**

- Pi drops or changes the `-e <path>` launch flag the wrapper relies on to load the guard (post-sn1h the guard is loaded explicitly, not by auto-discovery; `--no-extensions` is the LOCKED opt-in, not the default — ADR-027 D1, 2026-07-02) → re-wire the launch mechanism.
- A richer pi exec-tool surface emerges (MCP bridge, custom exec tools with non-`command` fields) — this is exactly what the guard-parity tripwire detects; it will FAIL in `rc test` when it happens → broaden `extractCommand` and re-verify.
- Pi moves its dist layout so `dist/core/tools/bash.js` is no longer the installed path → the 5a positive sentinel FAILS LOUD; update the dist path constant in `examples/dcg/smoke.sh` (DCG-PI-PARITY-5a).
- Pi renames `bashSchema` or changes the field name → 5a FAILS LOUD; update `extractCommand` in `examples/pi/dcg-gate.ts`.
- DCG version bump changes the stdin protocol or the `is_supported_shell_tool` allowlist → re-verify the `tool_name:"bash"` pin (ADR-025 D3/D5 coupling).

### D9: Bash-only agents reach in-cage daemons via the daemon's own CLI over bash, not via MCP

**Firmness: FLEXIBLE** *(added 2026-06-09, rip-cage-swv; promoted from the swv design via `/compound`.)*

A bash-only agent (pi ships only the `bash` exec tool and has **no MCP bridge** as of the current `latest` install — D8 above; pi docs `usage.md` "intentionally does not include built-in MCP"; the guard-parity tripwire in D8 catches if this changes) reaches an in-cage daemon (ADR-005 D7 IN-CAGE-DAEMON archetype, e.g. agent_mail) by invoking the **daemon's own CLI over its bash tool** — never via an MCP client. agent_mail's `am mail send` / `am mail inbox` / `am mail read` (the `am` CLI proxies to the daemon's `/mcp/` endpoint under the hood) is the worked example: pi runs `am ...` in bash, no MCP client in the loop. This is rip-cage's adoption of the pi/Zechner "No MCP — build CLI tools with READMEs" stance for *agent-to-in-cage-service* integration.

This is the agent-side counterpart to ADR-005 D7's daemon archetype: D7's optional `mcp_fragment` registers the daemon with **MCP-capable** agents (Claude Code), which is the reach mechanism for *those* agents; it is **not** the reach mechanism for bash-only agents. Both agent classes talk to the same daemon over the same `/mcp/` endpoint — Claude via its MCP client, pi via the daemon's CLI. (Reconciled into ADR-005 D7's archetype wording, in place, same change-set.)

**Rationale:**

- It is the **only** path for pi today — pi has no MCP client to register a daemon with (D8). Framing this as a deliberate decision (not an accident of pi's surface) prevents the recurring mis-derivation: the *first* swv design assumed "pi drives agent_mail MCP," was adversarially REJECTED on the no-MCP-bridge fact, and only then found the CLI path. Canonicalizing it stops the next daemon-integration from re-assuming MCP and re-failing.
- It matches the broader CLI-over-MCP design default (`~/.claude/skills/design-claude-extension`): a CLI + short discovery doc avoids MCP's always-loaded per-tool schema overhead, and any bash-capable agent already knows how to run a CLI.
- The daemon needs no per-agent integration work for bash-only agents — shipping a CLI serves pi, humans, scripts, and any future bash-only agent uniformly.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Daemon CLI over bash (this decision)** | Only path that works for pi today; zero per-agent integration; CLI serves humans + scripts + any bash agent; matches the CLI-over-MCP default | Agent must discover the CLI surface (README / `--help`); no schema-typed results (acceptable — the agent reads the CLI like any tool) |
| Build/adopt an MCP bridge for pi (e.g. `pi-mcp-extension` / `pi-mcp-adapter`) | Typed MCP tools in pi | `direct:` pi has no MCP bridge (D8; pi `usage.md` "intentionally does not include built-in MCP"); surveyed community bridges are immature (1-star/2-days) or target a renamed/different pi line (`@earendil-works` `^0.74`) vs our `@mariozechner` line at `latest`; reintroduces the MCP schema-overhead the CLI default avoids — over-engineering for a need the CLI already meets |
| Native pi typed tool via `pi.registerTool()` wrapping the daemon | pi-native typed surface; we already bake a pi `-e` extension for DCG | `reasoned:` more code than calling an already-shipped CLI over bash; reserve for a future case where a typed surface is genuinely wanted, not the default reach |
| Support only MCP-capable agents (Claude) talking to in-cage daemons | Simplest; one reach mechanism | `reasoned:` defeats pi multi-agent coordination — the entire point of ADR-006 D7 Tier 1a + rip-cage-swv; leaves pi asymmetrically unable to use in-cage daemons with no threat-model justification |

**What would invalidate this:**

- Pi ships a built-in MCP client / bridge → MCP becomes an *option* for pi (though the CLI-over-bash path may still be preferred on token-cost grounds; re-evaluate, don't auto-switch).
- An in-cage daemon ships **no** CLI (MCP-only surface) → a bash-only agent then needs a thin CLI shim or the `pi.registerTool()` path; D9's "use the daemon's CLI" assumes one exists (agent_mail's does).
- pi's exec surface gains non-`bash` tool types that change how it reaches external processes → re-verify the bash-tool assumption (couples to D8's `command`-field note).

**Canonical refs:**

- ADR-005 D7 (IN-CAGE-DAEMON archetype + `mcp_fragment`; its agent-reach wording is reconciled here, in place)
- ADR-006 D7 (Tier 1a many-agents-in-one-cage — the coordination D9 enables for pi)
- ADR-019 D8 (pi has only the `bash` exec tool / no MCP bridge — the load-bearing premise)
- bead `rip-cage-swv` (worked example: concurrent two-pi agent_mail round-trip over `am` CLI; the rejected-MCP-first-design history)
- `docs/reference/agent-mail-daemon.md` (the `am` CLI message surface + `am serve-http --no-auth` daemon mode)
- Mario Zechner, "What if you don't need MCP at all?" — the CLI-over-MCP stance this adopts

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
