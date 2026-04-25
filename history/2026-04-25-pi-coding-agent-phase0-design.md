# Pi-Coding-Agent Support — Phase 0 Design

**Date:** 2026-04-25
**Decisions:** [ADR-019](../docs/decisions/ADR-019-pi-coding-agent-support.md)
**Supersedes:** the original handoff doc at [`docs/handoff-pi-phase0.md`](../docs/handoff-pi-phase0.md). Differences are flagged inline.

## Problem

Rip-cage today supports one harness: Claude Code. Adding pi (`@mariozechner/pi-coding-agent`) — a multi-provider coding agent — alongside it unlocks two near-term goals:

1. Use the user's existing **OpenAI Codex (ChatGPT Plus/Pro)** subscription from inside the cage.
2. Establish the substrate for a future learning project: building a pi extension that calls rip-cage's existing `dcg` Rust binary, achieving DCG-equivalent enforcement on pi's bash tool calls.

Both harnesses must remain runnable from the same image. A user with only pi auth, only Claude Code auth, or both, must be able to `rc up` cleanly. The work happens on `main` (no feature branch — confirmed with the human).

## Background research

Five sources were surveyed before settling the design:

### Pi internals (verified directly from pi-mono source)

| Fact | Source |
|---|---|
| Auth file: `~/.pi/agent/auth.json`, mode `0o600`, plain JSON, auto-refresh via `proper-lockfile` | `src/config.ts:231-232`, `src/core/auth-storage.ts:53,65` |
| Sessions: `~/.pi/agent/sessions/` (per-cwd encoded subdirs) | `src/config.ts:208-263` |
| Global AGENTS.md: `~/.pi/agent/AGENTS.md`. Project AGENTS.md / CLAUDE.md walking up from cwd are also loaded and concatenated | `src/core/resource-loader.ts:58-100`, README:281-286 |
| Non-interactive mode: `pi -p "..."` or `pi --print "..."` (text or JSON output) | `src/cli/args.ts:123-124,218`, `src/main.ts:105-106` |
| Tool-call extension API: `pi.on("tool_call", async (event, ctx) => ...)` returns `{ block: true, reason?: string }` to deny, `undefined` to allow, mutate `event.input` to modify | `docs/extensions.md:641-678` |
| Extensions auto-loaded from `~/.pi/agent/extensions/*.ts` (global) and `.pi/extensions/*.ts` (project) | `docs/extensions.md:115-118` |
| Pi state directory is overridable via `PI_CODING_AGENT_DIR` env var | `src/config.ts:208-263` |

### Other state under `~/.pi/agent/`

Pi state is richer than the original handoff doc anticipated. Beyond `auth.json` and `sessions/`, pi reads or writes: `settings.json`, `SYSTEM.md`, `APPEND_SYSTEM.md`, `extensions/`, `themes/`, `prompts/`, `tools/`, `bin/`, `models.json`, `<APP_NAME>-debug.log`. This argues for mounting the whole directory rather than picking files.

### Prior art

| Project | Container model | What we learned |
|---|---|---|
| **pi-less-yolo** (cjermain) | Docker, Chainguard base, mise tasks, `--cap-drop=ALL --no-new-privileges --ipc=none`, real-path cwd mount | **`PI_CODING_AGENT_DIR=/pi-agent` + single bind mount of `~/.pi/agent`** is the clean solution. Provider env-var passthrough list. No auth-warn — let pi fail naturally. Read-only mode is a clean idea. SSH agent forwarding pattern matches rip-cage. |
| **pi-coding-agent-container** (paranoid mode) | Docker, Debian base, `read_only: true`, tmpfs `noexec`, removed `su`/`mount`/`passwd`, `LD_PRELOAD=/usr/local/lib/fs-vault.so`, V8 monkeypatch (`NODE_OPTIONS=--require app-firewall.js`), SUID `gh-vault` binary, Docker Secrets mounted at `/run/secrets/gh_default` mode `000` | **Out of philosophy.** Adversarial threat model. Rip-cage rejects this approach by name (ADR-019 D7). |
| **gondolin/pi-gondolin.ts** | QEMU/krun micro-VMs, host-side TS policies, placeholder-token credential spoofing, allowlisted HTTP egress | Lazy VM init pattern + `pi.registerTool()` override + 4 hooks (`session_start`, `session_shutdown`, 4× `registerTool`, `before_agent_start`, `user_bash`) is heavier than we need for Phase 1. Useful as Phase 2+ reference. |
| **agent-safehouse** | macOS `sandbox-exec` only, deny-first profiles, agent-agnostic | Doesn't apply — Linux/Docker model only. |
| **permission-gate.ts** (official pi example) | Pi extension, 30 lines, `tool_call` regex blocker, falls back to block in non-interactive mode | **Direct template** for Phase 1 DCG-on-pi extension. |

## Architecture changes

### Mount model (B2)

A single bind mount + one env var replaces the per-file mount strategy in the original handoff doc:

```
host:   ${HOME}/.pi/agent/   (rw)
   ↓ bind mount
cage:   /pi-agent/           (rw)

env in cage: PI_CODING_AGENT_DIR=/pi-agent
```

Pi's `getAgentDir()` honors `PI_CODING_AGENT_DIR` ahead of `~/.pi/agent`, so all state — `auth.json`, `sessions/`, `settings.json`, `AGENTS.md`, `extensions/`, `themes/`, `prompts/`, `tools/`, `bin/`, `models.json`, debug logs — resolves to `/pi-agent/...` inside the cage. No HOME-resolution dance, no per-file mounts, future pi state additions just work.

**Mount-point ownership.** Docker creates parent dirs of bind mounts as root. The cage's existing convention (Dockerfile:129 for `/home/agent/.claude`) is to **pre-create the directory in the image and chown to `agent:agent` before `USER agent`**. B1 must add the same line for `/pi-agent`:

```dockerfile
RUN mkdir -p /pi-agent && chown agent:agent /pi-agent
```

Without this, on first `rc up` Docker creates `/pi-agent` as root; the bind mount overlays the host dir, but write/lock operations from agent uid 1000 against host-owned files will silently fail or be read-only. Pi's `proper-lockfile` token refresh would then break with a delayed permission error (one-request grace, then silent failure). Pre-creating in the Dockerfile avoids touching the scoped sudoers list (ADR-002 D12).

If `${HOME}/.pi/agent` doesn't exist on the host, `rc up` skips the mount and prints a non-fatal warning (matches the existing Claude path's tone). Pi will fail loudly on first request — that surface is correct (D2).

### Cage-topology context (B4)

A new `cage-pi.md` at the repo root (parallel to `cage-claude.md`) is `COPY`'d into `/etc/rip-cage/cage-pi.md`. `init-rip-cage.sh` strips any existing fenced block from `/pi-agent/AGENTS.md` and re-appends the current one:

```
<!-- begin:rip-cage-topology-pi -->
…cage-pi.md content…
<!-- end:rip-cage-topology-pi -->
```

Same `awk` strip-and-append pattern as cage-claude.md (init-rip-cage.sh lines 91-106). Idempotent — running init twice leaves exactly one block.

Pi sees the cage-topology block via its global AGENTS.md resolution. Project-scoped `AGENTS.md` / `CLAUDE.md` files are not modified, so no duplication.

### Container init (B3)

`init-rip-cage.sh` adds one verification step after step 8 (Claude Code verify, line 254):

```bash
# 8b. Pi verify
if command -v pi >/dev/null 2>&1; then
    echo "[rip-cage] pi $(pi --version) ready"
else
    echo "[rip-cage] FATAL: pi not found in image" >&2
    exit 1
fi
```

The existing Claude-only auth-warn block (lines 257-261) is **left untouched**. It claims absence of *Claude credentials*, not absence of all auth — that's still accurate. Pi's own `/login` UI is the right surface for "you're not authed" — see ADR-019 D2.

### Provider env-var passthrough (B2)

`rc` (in `cmd_up`) forwards these env vars when set on host **and non-empty**:

```
ANTHROPIC_API_KEY, AZURE_OPENAI_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY,
MISTRAL_API_KEY, GROQ_API_KEY, CEREBRAS_API_KEY, XAI_API_KEY,
OPENROUTER_API_KEY, AI_GATEWAY_API_KEY, ZAI_API_KEY, OPENCODE_API_KEY,
KIMI_API_KEY, MINIMAX_API_KEY, MINIMAX_CN_API_KEY,
PI_SKIP_VERSION_CHECK, PI_CACHE_RETENTION
```

`PI_PACKAGE_DIR` is **excluded** — it points at a host-side dev path that won't exist in the cage and would break pi startup. The empty-value filter is required because devcontainer's `${localEnv:VAR}` substitution emits empty strings for unset vars, and pi may treat `OPENAI_API_KEY=""` as "set but invalid" rather than falling back to `auth.json` (would invert ADR-019 D1's auth.json-over-env priority order).

`auth.json` takes priority over env vars when both are present (pi behavior). The list is fixed and easy to audit; if it rots, switch to a pattern-based forward (ADR-019 D5 "what would invalidate").

**`CAGE_HOST_ADDR` propagation.** Pi-spawned bash tool calls inherit env from the pi parent. For interactive `pi` launched from the cage's zsh, `.zshrc` sources `/etc/rip-cage/cage-env` and `CAGE_HOST_ADDR` flows. For non-interactive runs (`pi -p`, `docker exec ... pi`, B6 e2e test), the var must be added to `cmd_up`'s `-e` list directly (it is already exported in init-rip-cage.sh:229). Without this the cage-pi.md instructions referencing `$CAGE_HOST_ADDR` instruct pi to use an unset variable from non-interactive contexts.

## Phase 0 beads

Children of a parent bead "Phase 0: pi-coding-agent support" (priority 2 unless noted). Each bead's "Verification" is the exit gate — do not close without that evidence in `bd update --notes`.

### B1 — Install pi-coding-agent in the image

- **Files**: `Dockerfile`
- **Change**: After line 76 (`RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}`), add:
  ```dockerfile
  ARG PI_VERSION=latest
  RUN npm install -g @mariozechner/pi-coding-agent@${PI_VERSION}
  ```
  Place `ARG PI_VERSION` near `ARG CLAUDE_CODE_VERSION`. Also add (near Dockerfile:129's `/home/agent/.claude` pre-create, before `USER agent`):
  ```dockerfile
  RUN mkdir -p /pi-agent && chown agent:agent /pi-agent
  ```
  This avoids the bind-mount-as-root ownership trap (see "Mount model" above).
- **Verification**: New `tests/test-pi-install.sh` modeled on `tests/test-prerequisites.sh`. Asserts `docker run --rm <image> pi --version` exits 0 and the output contains a semver matching `^[0-9]+\.[0-9]+\.[0-9]+` (npm `--version` typically prints the bare semver, not the package name — don't lock the test to `pi-coding-agent X.Y.Z` without first verifying the actual output). Also asserts `docker run --rm <image> stat -c '%U:%G' /pi-agent` reports `agent:agent`. Capture command output in bead notes when closing.

### B2 — Mount pi state and pass through provider env vars

- **Files**: `rc` (`cmd_up` mount-args section, ~lines 776-837), `.devcontainer/devcontainer.json` (mount blocks at lines 216-245), `rc init` (devcontainer generation).
- **Change**:
  - When `${HOME}/.pi/agent` exists on host, append `-v "${HOME}/.pi/agent:/pi-agent"` and `-e PI_CODING_AGENT_DIR=/pi-agent` to `_UP_RUN_ARGS`. Skip cleanly when missing — log warning matching Claude path's tone (line 830).
  - Always append `-e CAGE_HOST_ADDR=<resolved value>` so non-interactive `pi -p` runs see the host bridge address (init-rip-cage.sh:229 already exports it inside the cage, but only via interactive zsh sourcing; non-interactive contexts need the explicit `-e`).
  - Add provider env-var passthrough loop (mirror pi-less-yolo `tasks/pi/_docker_flags:61-85`). Iterate the fixed list; for each var, only emit `--env "$var=$value"` when `[[ -n "${!var}" ]]` (skip empty). This is the same conditional shape used elsewhere in `cmd_up`.
  - **Devcontainer parity (env-file approach):** generating `containerEnv` entries with `${localEnv:VAR}` would emit empty strings for unset vars and risk inverting ADR-019 D1's auth.json-over-env priority. Instead, `rc init` writes `.devcontainer/.env-pi` (gitignored) at generation time, containing only set+non-empty vars from the same passthrough list. devcontainer.json gains `"runArgs": ["--env-file", "${localWorkspaceFolder}/.devcontainer/.env-pi"]`. The file is regenerated each `rc init` invocation; an empty file is harmless to `--env-file`.
  - Mirror the bind mount in `devcontainer.json`: add `${HOME}/.pi/agent:/pi-agent` to mounts; add `PI_CODING_AGENT_DIR=/pi-agent` and `CAGE_HOST_ADDR=${localEnv:CAGE_HOST_ADDR}` (or computed value) to `containerEnv`.
- **Verification**: New `tests/test-pi-auth-mount.sh`:
  1. Creates a fake `${HOME}/.pi/agent/auth.json` with dummy content (back up the real one if present).
  2. Runs `docker run` with the same flags `cmd_up` constructs. Replicate the conditional `-v ${HOME}/.pi/agent:/pi-agent` + `-e PI_CODING_AGENT_DIR=/pi-agent` flags directly inside the test (do **not** factor `cmd_up` mount-arg construction into a shared shell function for B2 — that's a separate refactor; mirror the same shape used by `test-worktree-support.sh` and `test-ssh-forwarding.sh`).
  3. Asserts the file is readable inside the container at `/pi-agent/auth.json` (`docker exec ... cat /pi-agent/auth.json`) AND that `/pi-agent/auth.json` is owned by `agent:agent` from the container's uid view (`docker exec ... stat -c '%U:%G' /pi-agent/auth.json`). Direct file inspection beats parsing pi CLI output; `pi --status` is not a verified command and `pi --print "where is your auth"` would require a real provider call. Also assert `docker exec ... env | grep ^PI_CODING_AGENT_DIR=` returns `PI_CODING_AGENT_DIR=/pi-agent`.
  4. With `OPENAI_API_KEY=""` exported in the test shell, asserts the resulting `docker run` invocation does **not** include `OPENAI_API_KEY=` (verifies the empty-value filter).
  5. Removes the fake file and asserts `rc up` still works (warning logged, no fatal error).
  6. Restores the original `auth.json` if backed up.

### B3 — Container init: verify pi

- **Files**: `init-rip-cage.sh`
- **Change**: After step 8 (line 254), add step 8b — `command -v pi`, run `pi --version`, fail-loud if missing (`exit 1` with a clear message; matches ADR-001 fail-loud pattern). Do **not** modify the existing auth-warn block.
- **Verification**: Extend `tests/test-e2e-lifecycle.sh` to assert the container init log contains the pi-ready line. Test the four auth-presence cases from the original handoff doc *only as observation*, not as warn-policy assertions. The test must echo a clarifying log before the case-2 assertion (e.g. `echo "# Note: Claude warn-line intentionally present per ADR-019 D2 — pi auth uses its own /login UI."`) so a reader skimming output doesn't misread case 2 as a regression:
  - only `~/.claude/.credentials.json` present → init succeeds, Claude warn-line absent (existing behavior)
  - only `~/.pi/agent/auth.json` present → init succeeds (Claude warn-line *present* — that's intentional per D2)
  - neither → init succeeds, Claude warn-line present
  - both → init succeeds, Claude warn-line absent

### B4 — Cage-topology context for pi (`cage-pi.md`)

- **Files**: new `cage-pi.md` at repo root; `Dockerfile` line 105 area to `COPY cage-pi.md /etc/rip-cage/cage-pi.md`; `init-rip-cage.sh` to handle the AGENTS.md append.
- **Change**:
  - Author `cage-pi.md` from `cage-claude.md` with explicit per-section disposition:
    - **Filesystem section** (cage-claude.md `### Filesystem`) — transfers 1:1.
    - **Networking section** (`### Networking`) — transfers 1:1; same `$CAGE_HOST_ADDR` guidance applies.
    - **Debug recipes** (`### Debug recipes`) — transfers 1:1.
    - **Precedents inside the cage** — reword: drop Claude-specific phrasing; mention pi auth at `/pi-agent/auth.json` and pi extensions at `/pi-agent/extensions/` as analogous precedents.
    - **Subagent troubleshooting section** (cage-claude.md lines 61–86, the "subagent fails fast" guide) — **deleted entirely**, not adapted. It covers `Agent(subagent_type=...)`, the `[1m]` Claude-Code model variant, and `claude -p --debug`. None of these apply to pi (different harness, different model, different debug surface). Re-introducing pi-equivalent guidance is out of scope for Phase 0.
  - The result is a single H2 section ("Cage topology (rip-cage)") with the same overall shape as cage-claude.md, minus the dropped Claude-specific subsection.
  - Two **independent** awk strip-and-append invocations exist after this change: one for cage-claude.md → `~/.claude/CLAUDE.md` (existing, unchanged, marker pair `<!-- begin:rip-cage-topology --> / <!-- end:rip-cage-topology -->`) and one for cage-pi.md → `/pi-agent/AGENTS.md` (new, marker pair `<!-- begin:rip-cage-topology-pi --> / <!-- end:rip-cage-topology-pi -->`). Marker pairs are unique per target file; the awk regexes match literal strings, so the `-pi` and unsuffixed pairs do not cross-match.
  - Three guards, in order, around the pi append:
    1. If `/pi-agent` does not exist (host dir was missing → `rc up` skipped the mount), skip the entire B4 step silently.
    2. If `/pi-agent` exists but `/pi-agent/AGENTS.md` does not, create the empty file with `: > /pi-agent/AGENTS.md` (mirror init-rip-cage.sh:85 for the Claude path).
    3. Then run the strip-and-append.
- **Verification**: New `tests/test-pi-cage-context.sh`:
  1. `rc up`, then inside container assert `/pi-agent/AGENTS.md` exists and contains the fenced cage-pi block.
  2. Run init twice (re-`docker exec` the init script) and assert exactly one block remains, anchored on the `-pi` marker pair only (no false-positive match against the unsuffixed Claude markers).
  3. Manually edit `/pi-agent/AGENTS.md` to add user content outside the fence, re-run init, assert user content survives and the cage block is updated in-place.
  4. With `${HOME}/.pi/agent` deliberately removed on host (mount skipped), assert init does not error and produces no `/pi-agent/AGENTS.md`-related log noise.

### B5 — Documentation

- **Files**: `docs/reference/auth.md`, `README.md`, `docs/reference/whats-in-the-box.md`.
- **Change**:
  - `auth.md`: New "## Pi auth" section. Subsections:
    - "Auth file location" — `~/.pi/agent/auth.json` (host), mounted via D1 mechanism.
    - "Supported providers" — link to pi providers.md.
    - "Subscription auth (TOS callout)" — ADR-019 D6 callout applies to **both** pi → OpenAI Codex (ChatGPT Plus/Pro) and pi → Anthropic OAuth (Claude Max/Pro). Both flows use a subscription credential through a third-party harness; the Anthropic January 2026 enforcement precedent applies to either. Cite pi-mono's "Personal use only" line, the Anthropic precedent, OpenAI Service Terms link, Anthropic Consumer Terms link.
    - "Pi safety model" — verbatim line per ADR-019 D4: *"Inside the cage, pi runs without command-level DCG / compound-blocker enforcement. Container isolation, non-root user, and the egress firewall remain active."* Phase 1 forward-link.
    - "Why rip-cage doesn't ship paranoid mode" — short paragraph naming pi-coding-agent-container, summarizing its mitigations, explaining why rip-cage rejects them per ADR-019 D7.
    - "Auth refresh" — one line: `rc auth refresh` is Claude-only (it shells into the macOS Keychain). Pi auto-refreshes via `proper-lockfile` against the mounted `auth.json`; no rip-cage helper is required. On Linux, both Claude and pi auth files are edited directly on host.
    - "Related projects" — pi-less-yolo (closest cousin), pi-coding-agent-container (different threat model), gondolin (heavier sandbox).
  - `README.md`: One paragraph in the "Who is this for?" section noting pi is also supported. Don't restructure.
  - `whats-in-the-box.md`: Add `pi` to the tools list with version line.
- **Verification**: Manual review by `code-reviewer` subagent — does the doc accurately reflect B1-B4? Are the TOS warnings findable from the auth.md TOC? Capture review output in bead notes.

### B6 — End-to-end smoke test

- **Files**: `tests/test-pi-e2e.sh` (new).
- **Change**: New script that:
  1. Asserts host has `~/.pi/agent/auth.json`. If missing, exit with `[skip]` and a clear message: `[skip] no pi auth on host; run 'pi /login' first`.
  2. Creates a temp project dir, `rc up` into it.
  3. Inside the container, runs `pi -p "Reply with the literal string PI_E2E_OK and nothing else"` with a 30s timeout.
  4. Asserts stdout contains `PI_E2E_OK`.
  5. Tears down (`rc down`).
- **Verification**: The script itself. Manual run for Phase 0 — must exit 0 on success and non-zero on failure with a useful message. Capture full output in bead notes when closing.

## Order of work

```
B1 (install) ─┬─ B2 (mounts) ──┬─ B3 (init verify) ──┬─ B6 (e2e smoke)
              │                │                     │
              └─ B4 (cage-pi.md) ─────────────────────┤
                                                     │
                                B5 (docs) ───────────┘
```

Recommended: **B1 → B2 → B3 → B4 → B6 → B5** (write docs last so they reflect what shipped, not what was planned).

## Differences from the original handoff doc

| Topic | Original plan | This design | Reason |
|---|---|---|---|
| Mount strategy (B2) | Per-file: `~/.pi/agent/auth.json` + `~/.pi/agent/sessions` mounted at `/home/agent/.pi/agent/...` | Single bind: `~/.pi/agent` → `/pi-agent` + `PI_CODING_AGENT_DIR=/pi-agent` | pi-less-yolo prior art; covers all current and future pi state without per-file mounts |
| Auth-warn (B3) | New matrix: warn iff no Claude creds AND no pi auth AND no `ANTHROPIC_API_KEY` AND no OpenAI env var | No new warn; existing Claude warn unchanged | Provider list rots; pi's own `/login` UI is the right surface (D2) |
| AGENTS.md path (B4) | `~/.pi/agent/AGENTS.md` (host path) | `/pi-agent/AGENTS.md` (container path, redirected via env var) | Consequence of single-mount strategy |
| Provider env vars (B2) | Implicit; only `ANTHROPIC_API_KEY` mentioned | Explicit 16-var passthrough list | Matches pi-less-yolo; enables non-OAuth flows |
| Phase 1 framing (Known gaps) | "DCG and compound-command blocker do NOT intercept pi's bash tool calls" — narrative gap | ADR-019 D8: explicit decision, designated as user's learning project, 30-line `permission-gate.ts` template named | User goal: learn pi extension API by building DCG hook themselves |
| TOS callout placement | "Document this in `auth.md`" | Docs-only confirmed in ADR-019 D6 (no runtime banner) | Banner-blindness avoidance; user already opts in via `pi /login` |
| Paranoid-mode rejection | Not addressed | ADR-019 D7 + auth.md "Why rip-cage doesn't ship paranoid mode" subsection | Pre-empt the question; codify the philosophy |

## Phase 1 outlook (for context only — not in scope here)

When the user starts the Phase 1 learning project, the skeleton is:

```typescript
// extensions/pi/dcg-gate.ts (in rip-cage repo, mounted into /etc/rip-cage/extensions/pi/)
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { spawn } from "child_process";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return undefined;
    const command = event.input.command as string;

    const result = await new Promise<{ allowed: boolean; reason?: string }>((resolve) => {
      const proc = spawn("/usr/local/bin/dcg", ["check", "--stdin"], { stdio: ["pipe", "pipe", "pipe"] });
      proc.stdin.write(command);
      proc.stdin.end();
      let stderr = "";
      proc.stderr.on("data", (d) => (stderr += d));
      proc.on("close", (code) => resolve({ allowed: code === 0, reason: stderr.trim() || undefined }));
    });

    return result.allowed ? undefined : { block: true, reason: `DCG: ${result.reason ?? "policy violation"}` };
  });
}
```

Wired in via `init-rip-cage.sh`:

```bash
# In Phase 1, append to settings or pass via -e
pi --settings-set 'extensions += "/etc/rip-cage/extensions/pi/dcg-gate.ts"'
```

…or via a `settings.json` snippet merged at init time, mirroring the Claude PreToolUse hook merge.

Reference: pi-mono `examples/extensions/permission-gate.ts` (regex blocker, 30 lines) and `examples/extensions/sandbox/index.ts:134-199` (subprocess pattern).

## Test plan

| Test | Layer | When |
|---|---|---|
| `tests/test-pi-install.sh` | B1 image | After B1 |
| `tests/test-pi-auth-mount.sh` | B2 mount + env var honored | After B2 |
| Extended `tests/test-e2e-lifecycle.sh` | B3 init log + auth-warn matrix observation | After B3 |
| `tests/test-pi-cage-context.sh` | B4 fenced block + idempotency | After B4 |
| `tests/test-pi-e2e.sh` | B6 end-to-end `pi -p` | After B6 |
| Existing `tests/test-safety-stack.sh` | Regression: Claude DCG / compound-blocker still enforce | Before close |
| Existing `tests/test-prerequisites.sh` | Regression: image still has all expected tools | Before close |
| `bd preflight` | Lint / stale / orphans | Before close |

## Self-check before closing the parent bead

- [ ] B1-B6 closed with verification evidence in `bd update --notes`
- [ ] `./test.sh` (or `make test`) passes
- [ ] `tests/test-pi-install.sh`, `tests/test-pi-auth-mount.sh`, `tests/test-pi-cage-context.sh`, `tests/test-pi-e2e.sh` all pass
- [ ] Existing `tests/test-safety-stack.sh`, `tests/test-prerequisites.sh`, `tests/test-e2e-lifecycle.sh` still pass (no Claude regressions)
- [ ] `git status` shows only intended files; `git add` lists each; `git commit` references the parent bead; `git push` to origin/main
- [ ] `bd dolt push`
- [ ] Parent bead closed; ADR-019 status flipped from `Proposed` to `Accepted`

