# Handoff: Phase 0 — pi-coding-agent support in rip-cage

**Audience**: agent working inside rip-cage on `main` branch.
**Scope**: Phase 0 only. Phase 1+ (DCG/compound-blocker enforcement on pi tool calls) is explicitly **out of scope** here — see "Known gaps" below.

---

## 1. Mission

Make rip-cage support `pi` (`@mariozechner/pi-coding-agent`) as a second harness alongside the existing Claude Code support, on the **`main` branch** (not a feature branch — confirmed with the human). Both harnesses must remain runnable from the same image. A user with only pi auth, only Claude Code auth, or both, must be able to `rc up` cleanly.

The first concrete user goal this unlocks: authenticate pi with the user's **OpenAI Codex (ChatGPT Plus/Pro)** OAuth subscription on the macOS host, then run a pi session inside the cage with that subscription, with the cage's container/firewall isolation still active.

## 2. Constraints (non-negotiable)

1. **Single branch (`main`)**. No feature branch. The human decided.
2. **Both harnesses supported.** Don't remove or weaken Claude Code paths. Add pi alongside.
3. **Verified + tested.** Every change must ship with a test (`tests/test-*.sh`) that fails before the change and passes after, OR extend an existing test. No "I think this works" claims — run the test and report the output before closing a bead.
4. **Beads-tracked.** This repo uses beads (`.beads/`). File a bead per task before writing code (`bd create`), claim with `bd update <id> --claim`, close only after verification (`bd close <id>`). Cluster all this work under a parent bead titled "Phase 0: pi-coding-agent support".
5. **No skipped session-close.** `git status` → `git add <specific files>` → `git commit` → `git push` before claiming "done". See `.beads/CLAUDE.md` and the SessionStart hook output for the protocol.
6. **Honor existing conventions.** Match the style of `init-rip-cage.sh` (POSIX-ish bash, `set -euo pipefail`, fail-loud on broken invariants per ADR-001), the `tests/test-*.sh` pattern, and `docs/reference/*.md` style.

## 3. Background reading (do this first)

Read these files in order before filing beads. Don't skim — line numbers will be referenced below:

| File | Why |
|---|---|
| `README.md` | Mental model. Note the "Who is this for?" framing — keep it. |
| `Dockerfile` | Especially line 76 (`npm install -g @anthropic-ai/claude-code`) — that's the parallel install point for pi. |
| `rc` lines 216–245 | Devcontainer mount declarations for `~/.claude` paths. |
| `rc` lines 686–837 | Host-side credential extraction (macOS Keychain) and `cmd_up` mount-args assembly for `~/.claude/.credentials.json`, `~/.claude.json`, `~/.claude/skills`, etc. |
| `init-rip-cage.sh` lines 30–75 | Auth/settings handling inside the container. |
| `init-rip-cage.sh` lines 249–261 | Claude Code verification + auth presence check. The model for the parallel pi check. |
| `docs/reference/auth.md` | Document model for the new pi auth section. |
| `tests/test-prerequisites.sh`, `tests/test-safety-stack.sh`, `tests/test-e2e-lifecycle.sh` | Test patterns to mimic. |
| `cage-claude.md` | The cage-topology blob appended to host `CLAUDE.md` inside the cage (init-rip-cage.sh lines 91–106). You'll create a `cage-pi.md` parallel. |
| `.beads/CLAUDE.md` | Beads workflow for this repo. |

Then read these in `/Users/jonat/code/personal/pi-mono/packages/coding-agent/`:

| File | Why |
|---|---|
| `README.md` (skim, top + Quick Start + Providers sections) | Pi mental model. |
| `docs/providers.md` lines 19–42 | Confirms `ChatGPT Plus/Pro (Codex)` is a documented OAuth provider, "Personal use only". |
| `docs/settings.md`, `docs/skills.md` (skim) | Where pi state lives — see "auth flow" below. |

## 4. Auth flow (Codex OAuth, host-side)

Critical difference from Claude Code: **pi does NOT use the macOS Keychain.** Pi credentials are a plain JSON file at `~/.pi/agent/auth.json`, mode `0600`. Reference: pi-mono `docs/providers.md`:

> Use `/login` in interactive mode and select a provider to store an API key in `auth.json`... Tokens are stored in `~/.pi/agent/auth.json` and auto-refresh when expired.

This means:

- No `security find-generic-password` step on host (the Keychain extraction in `rc` lines 686–737 is Claude-Code-specific — keep it untouched).
- Mount the file directly: `~/.pi/agent/auth.json` → `/home/agent/.pi/agent/auth.json` (read-write, single-file bind, same caveat about Linux inode tracking as Claude Code's `.credentials.json` — note in docs).
- The user authenticates **on the host** with `pi /login` once (selecting "OpenAI Codex" → ChatGPT Plus/Pro flow), which writes the file. Then `rc up` mounts it.
- Per pi's own auth model, no `rc auth refresh`-style Keychain re-extraction is needed for pi. Token auto-refresh happens inside the container's pi process via the mounted file.

**TOS surface — must be documented**:

OpenAI's Service Terms forbid using ChatGPT credentials to power third-party services. Pi is a third-party harness. Pi-mono's docs explicitly mark Codex OAuth as "Personal use only." Anthropic's January 2026 enforcement wave (which banned accounts using Claude OAuth via OpenCode/pi-style harnesses) is the precedent for what could happen to OpenAI Codex usage at any time.

Document this in `docs/reference/auth.md` under a new "Pi auth" subsection. Don't bury it. User's eyes open going in.

## 5. Beads to file (concrete tasks)

File these as children of a parent "Phase 0: pi-coding-agent support" bead. Priority 2 unless noted. Each row's "Verification" column is the exit gate — do not close the bead without that evidence in the bead's `--notes`.

### B1 — Install pi-coding-agent in the image

- **Files**: `Dockerfile`
- **Change**: After line 76 (`RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}`), add a parallel install: `RUN npm install -g @mariozechner/pi-coding-agent@${PI_VERSION}` with `ARG PI_VERSION=latest` declared near the top of stage 3 (alongside `ARG CLAUDE_CODE_VERSION=latest`, `ARG BUN_VERSION=latest`).
- **Verification**: New `tests/test-pi-install.sh` that runs `rc up` and asserts `pi --version` returns 0 and prints something like `pi-coding-agent X.Y.Z`. Mirror the structure of `tests/test-prerequisites.sh`.

### B2 — Mount pi auth + state from host

- **Files**: `rc` (specifically `cmd_up`'s mount-args section around lines 776–837), `.devcontainer/devcontainer.json` (the two mount blocks at lines 216–245 and 237–245).
- **Change**: When `~/.pi/agent/auth.json` exists on host, append `-v "${HOME}/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json"` to `_UP_RUN_ARGS`. When `~/.pi/agent/` exists, also mount `${HOME}/.pi/agent/sessions` (or whatever pi's session dir is — verify by running `pi` once on host and checking `~/.pi/`) for session persistence. Skip mounts cleanly when host paths don't exist (log a `warning: pi auth not found, /login inside cage to authenticate`-style message — match the Claude path's tone at line 830). Mirror the same conditional pattern Claude uses: do not fail if pi auth is missing; just log.
- **Verification**: New `tests/test-pi-auth-mount.sh` that:
  1. Creates a fake `${HOME}/.pi/agent/auth.json` with dummy content
  2. Runs `rc up` (or `docker run` directly if rc-up is too heavyweight for tests — see how `test-safety-stack.sh` does it)
  3. Asserts the file is readable inside the container at `/home/agent/.pi/agent/auth.json`
  4. Removes the fake file and asserts `rc up` still works (warning logged, no fatal error)

### B3 — Container init: verify pi + handle auth presence

- **Files**: `init-rip-cage.sh`
- **Change**: After step 8 (line 254, the Claude Code verify), add step 8b that runs `pi --version` and exits non-zero if pi is missing. Update the auth-warn block (lines 257–261): warn only when **both** Claude credentials AND pi auth are absent, AND no `ANTHROPIC_API_KEY` is set, AND no OpenAI env var is set. The current Claude-only warning is misleading once pi is supported.
- **Verification**: Extend `tests/test-e2e-lifecycle.sh` to assert that the container init log contains `[rip-cage] pi X.Y.Z ready` and the auth-warn line behaves correctly across these cases:
  - only `~/.claude/.credentials.json` present → warn-free
  - only `~/.pi/agent/auth.json` present → warn-free
  - neither → warning logged
  - both → warn-free

### B4 — Cage-topology context for pi (`cage-pi.md`)

- **Files**: new `cage-pi.md` at repo root (parallel to `cage-claude.md`); `Dockerfile` line 105 area to `COPY cage-pi.md /etc/rip-cage/cage-pi.md`; `init-rip-cage.sh` to handle the AGENTS.md append.
- **Why**: pi's CLAUDE.md equivalent is `AGENTS.md` (per pi-mono README — pi loads `AGENTS.md` files). The cage's network-topology section needs to be appended to `~/.pi/AGENTS.md` (or wherever pi resolves its global agent context) the same way `cage-claude.md` is appended to `~/.claude/CLAUDE.md`. Verify pi's actual global AGENTS.md location by reading `/Users/jonat/code/personal/pi-mono/packages/coding-agent/docs/settings.md` — do not guess.
- **Change**: Replicate the `awk` strip-and-append pattern from `init-rip-cage.sh` lines 91–106, but for pi's AGENTS.md file. Use distinct fence markers (`<!-- begin:rip-cage-topology-pi -->`).
- **Verification**: Test that runs `rc up`, then inside the container reads pi's AGENTS.md location and asserts the cage-topology block is present and correctly fenced. Also test idempotency (run init twice, only one block present).

### B5 — Documentation

- **Files**: `docs/reference/auth.md`, `README.md`, optionally `docs/reference/whats-in-the-box.md`.
- **Change**:
  - `auth.md`: Add a "Pi auth" section parallel to existing Claude section. Cover: auth file path on host (`~/.pi/agent/auth.json`), no Keychain dance, mount semantics, supported providers (per pi providers.md), and a clear callout box on TOS — quote pi-mono's "Personal use only" line and reference the Anthropic 2026 enforcement precedent (link both URLs from the references section below).
  - `README.md`: One paragraph in the "Who is this for?" section noting pi is also supported. Don't restructure.
  - `whats-in-the-box.md`: Add pi to the tools list.
- **Verification**: Manual review by another agent (use the `code-reviewer` subagent) — does the doc accurately reflect the code changes in B1–B4? Are the TOS warnings present and findable?

### B6 — End-to-end smoke test (manual + scripted)

- **Files**: `tests/test-pi-e2e.sh` (new), checked-in.
- **Change**: New script that:
  1. Asserts host has `~/.pi/agent/auth.json` (skip with clear message if missing — e.g., `[skip] no pi auth on host; run 'pi /login' first`).
  2. `rc up .` from a temp project dir.
  3. Inside the container, runs `pi --print "Reply with the literal string PI_E2E_OK and nothing else"` (pi has a `--print` mode per its CLI reference) with a 30s timeout.
  4. Asserts stdout contains `PI_E2E_OK`.
  5. Tears down (`rc down` or container stop).
- **Verification**: The test itself is the verification. It must be runnable in CI eventually, but for Phase 0 manual run is acceptable as long as the script exits 0 on success and non-zero on failure with a useful message. Capture full output in the bead notes when closing.

## 6. Order of work

Strict dependency order. Don't parallelize without thinking — B3 depends on B1, B6 depends on B1+B2+B3.

```
B1 (install) ─┬─ B2 (mounts) ──┬─ B3 (init verify) ──┬─ B6 (e2e smoke)
              │                │                     │
              └─ B4 (cage-pi.md) ─────────────────────┤
                                                     │
                                B5 (docs) ───────────┘
```

Recommended: B1 → B2 → B3 → B4 → B6 → B5 (write docs last so they reflect what actually shipped, not what you planned).

## 7. Known gaps (Phase 1, NOT this milestone)

Document these in the parent bead's description so they don't get lost, but do not implement them here:

1. **DCG and compound-command blocker do NOT intercept pi's `bash` tool calls.** They're wired to Claude Code via PreToolUse hooks (`init-rip-cage.sh` lines 51–75 merging `settings.json`). Pi has a TypeScript extension API (`pi.on("tool_call", ...)`) but no Claude-Code-style hook config. Phase 1 will add a small pi extension that calls `dcg` on every bash tool call before execution. For Phase 0, document clearly in `auth.md` and the TOS callout: **"Inside the cage, pi runs without command-level DCG/compound-blocker enforcement. Container isolation, non-root user, and egress firewall are still active."**
2. **No pi-mom support.** Always-on / Slack / Telegram transport is later.
3. **No Mac mini deployment doc.** That's a separate piece of work after Phase 0 lands.
4. **No `rc auth refresh`-equivalent for pi.** Pi auto-refreshes its own token via the mounted file; we don't need a refresh subcommand. If that proves wrong, file a follow-up bead.

## 8. Self-check before claiming done

- [ ] Every bead in B1–B6 is closed with verification evidence in `bd update --notes`.
- [ ] `./test.sh` (or whatever the repo's main test runner is — check `Makefile`) passes.
- [ ] `tests/test-pi-install.sh`, `tests/test-pi-auth-mount.sh`, `tests/test-pi-e2e.sh` all pass.
- [ ] Existing `tests/test-safety-stack.sh`, `tests/test-prerequisites.sh`, `tests/test-e2e-lifecycle.sh` still pass (no Claude Code regressions).
- [ ] `git status` shows only intended files. `git add` lists each. `git commit` with a clear message referencing the parent bead. `git push` to origin/main.
- [ ] Parent bead closed.

## 9. References

**rip-cage internal:**
- `/Users/jonat/code/personal/rip-cage/Dockerfile` — image build
- `/Users/jonat/code/personal/rip-cage/rc` — host-side launcher (large, ~49k tokens — read in chunks)
- `/Users/jonat/code/personal/rip-cage/init-rip-cage.sh` — container init
- `/Users/jonat/code/personal/rip-cage/docs/reference/auth.md` — current auth doc
- `/Users/jonat/code/personal/rip-cage/.beads/CLAUDE.md` — beads workflow

**pi-mono internal:**
- `/Users/jonat/code/personal/pi-mono/packages/coding-agent/README.md`
- `/Users/jonat/code/personal/pi-mono/packages/coding-agent/docs/providers.md` (Codex OAuth, "Personal use only")
- `/Users/jonat/code/personal/pi-mono/packages/coding-agent/docs/settings.md` (auth file paths)
- `/Users/jonat/code/personal/pi-mono/packages/coding-agent/docs/extensions.md` (Phase 1 reference)

**External (TOS context — cite in `auth.md`):**
- pi-mono README, "Subscriptions" section: https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/README.md
- OpenAI Service Terms: https://openai.com/policies/service-terms/
- Anthropic third-party-tool ban (precedent for what enforcement looks like): https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access/
- HN discussion + ban report: https://news.ycombinator.com/item?id=47069299
- opencode#6930 — actual ban incident on OAuth: https://github.com/anomalyco/opencode/issues/6930
- The New Stack — softened "personal use OK" position: https://thenewstack.io/anthropic-agent-sdk-confusion/

---

**Last note**: if at any point you find an assumption in this doc that contradicts what you observe in the code, **stop and verify with the human before working around it**. Specifically: pi's actual auth file path, pi's AGENTS.md resolution, and pi's `--print`/`--json` flag names. The doc was written from documentation, not from running pi end-to-end inside the cage.
