# Auth

Rip cage uses your existing Claude Code OAuth session — no API keys needed.

## How it works

OAuth tokens are the primary auth method. The `rc` script extracts tokens and mounts them into the container.

- **macOS**: Tokens live in the system Keychain under `"Claude Code-credentials"`. The `rc` script extracts them to `~/.claude/.credentials.json` automatically.
- **Linux**: `~/.claude/.credentials.json` (from a previous `claude /login`) is mounted directly.
- **API key fallback**: Set `ANTHROPIC_API_KEY` in an env file and pass it with `rc up --env-file`.

## Auth flow by path

| Path | Where extraction happens |
|------|------------------------|
| `rc init` | `initializeCommand` in devcontainer.json (runs on host before container starts) |
| `rc up` | `cmd_up` function (runs on host before `docker run`) |
| `rc auth refresh` | `cmd_auth_refresh` → `_extract_credentials` (host-side, updates file for all containers) |
| `init-rip-cage.sh` | Reads the mounted `.credentials.json` — does NOT extract from Keychain (runs inside container) |

## Switching accounts

When you switch Claude Code accounts or refresh auth on the host, the macOS
Keychain updates but the file bind-mounted into containers does not. Run:

    rc auth refresh

This re-extracts credentials from the Keychain. All running containers pick up
the change immediately via bind mount — no restart needed.

On Linux (no Keychain), update `~/.claude/.credentials.json` directly. Running
containers see the change immediately.

## Account rotation

If you run multiple Claude Code accounts (e.g., to spread rate limits across profiles), any tool that rewrites `~/.claude/.credentials.json` on the host will propagate to all running containers instantly via the bind mount. No container restart needed.

The workflow:

1. Agent inside the cage hits a rate limit or auth error
2. On the host, switch to a different account (update `~/.claude/.credentials.json`)
3. The agent retries its API call and picks up the new credentials

This works because rip-cage bind-mounts the credentials file read-write. The container sees host-side file changes immediately.

**Tools that can do the switch:**

| Tool | Command | What it does |
|------|---------|-------------|
| `rc auth refresh` | `rc auth refresh` | Re-extracts current account from macOS Keychain |
| [CAAM](https://github.com/jsnyde0/caam) | `caam activate claude <profile>` | Switches between named credential profiles |
| Manual | Edit `~/.claude/.credentials.json` directly | Works on any platform |

For a step-by-step guide to multi-account rotation with CAAM, see [Multi-account rotation guide](../guides/multi-account-rotation.md).

### Platform notes

- **macOS + OrbStack/Docker Desktop (VirtioFS):** Works reliably. VirtioFS tracks file paths, so atomic file replacements (like CAAM's `mv`) propagate correctly. There is a sub-second window during the atomic swap where the file briefly disappears — Claude Code handles this naturally via retry.
- **Linux (native Docker):** Single-file bind mounts track inodes, not paths. An atomic `mv` (new inode) will NOT propagate. Use directory-level bind mounts or in-place file writes (`cat > file`) instead.

## Pi auth

Pi (`@mariozechner/pi-coding-agent`) is also supported alongside Claude Code in the same image. This section covers auth, safety model, and related projects.

### Auth file location

Pi stores credentials at `~/.pi/agent/auth.json` on the host (mode `0o600`, plain JSON, auto-refreshed via `proper-lockfile`). Inside the cage, `rc up` bind-mounts `~/.pi/agent/auth.json` read-write at `/home/agent/.pi/agent/auth.json` and sets `PI_CODING_AGENT_DIR=/home/agent/.pi/agent` (ADR-019 D1).

### First-time pi setup

On a fresh machine where `~/.pi/agent/auth.json` does not exist, `rc up` automatically seeds an empty `{}` file before binding it, so the bind mount always fires. Then, inside the cage, run:

    pi /login

Complete the OAuth or API-key flow as prompted. Pi writes credentials in place to `/home/agent/.pi/agent/auth.json`, which is the bind-mounted host file — so the credentials persist back to `~/.pi/agent/auth.json` on the host immediately. On the next `rc destroy` + `rc up`, the same file is mounted and pi is already authenticated. No re-login is required across rebuilds.

If seeding fails (e.g., the host has a dotpi-managed symlink at that path, or a permissions error), `rc up` logs a warning and skips the mount — pi will surface auth guidance on first request via its own `/login` UI (ADR-019 D2).

Rip-cage does not add a startup auth-check for pi (ADR-019 D2): startup banners get banner-blind fast, and pi's own `/login` prompt is the right surface for "you're not authed."

### Supported providers

Pi supports a wide range of providers: Anthropic (Claude), OpenAI (including Codex via ChatGPT Plus/Pro OAuth), Gemini, Mistral, Groq, Cerebras, xAI, OpenRouter, Azure OpenAI, and others. See the [pi-mono providers documentation](https://github.com/mariozechner/pi-coding-agent/blob/main/docs/providers.md) for the full list and configuration details.

`rc up` forwards a fixed set of provider API key env vars from host to container (when set and non-empty): `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `AZURE_OPENAI_API_KEY`, `GEMINI_API_KEY`, `MISTRAL_API_KEY`, `GROQ_API_KEY`, `CEREBRAS_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`, and others. When `auth.json` is also present, it takes priority (pi's own behavior).

### Subscription auth (TOS callout)

> **Note on terms of service:** Two subscription OAuth flows raise policy questions worth reading before use.
>
> - **pi → OpenAI Codex (ChatGPT Plus/Pro):** Pi-mono's documentation includes a "Personal use only" statement for the Codex OAuth flow. Using it to drive automated coding-agent sessions sits in a gray area under the [OpenAI Service Terms](https://openai.com/policies/service-terms/).
> - **pi → Anthropic OAuth (Claude Max/Pro):** This flow sends your Anthropic subscription credentials through a third-party harness (pi). Anthropic's January 2026 enforcement action against third-party Claude access tools applies here — review the [Anthropic Consumer Terms](https://www.anthropic.com/legal/consumer-terms) before use.
>
> Rip-cage does not add a runtime banner for this (ADR-019 D6: startup banners get banner-blind fast; the user has already opted in by running `pi /login`). The callout lives here, in the docs, where it is findable and version-controlled.

### Pi safety model

Inside the cage, pi enforces the same destructive-command guard (DCG) as Claude Code, via an image-baked `dcg-gate.ts` extension that auto-loads from a cage-owned path and forwards bash tool calls to the shared `dcg` binary (ADR-019 D8; shipped in rip-cage-bl1). Container isolation, non-root user (`agent`, uid 1000), `--cap-drop=ALL --no-new-privileges`, and the L7 egress firewall (ADR-012) are also active.

There is no compound-command blocker on pi or Claude Code — it was removed 2026-06-03 because DCG matches over the whole command string regardless of `&&`/`;`/`||` chaining, which made the blocker redundant for destructive-command containment (ADR-002 D5).

### Why rip-cage doesn't ship paranoid mode

Pi-coding-agent-container is a related project that takes a different approach: `LD_PRELOAD` syscall firewall (`fs-vault.so`), a Node.js V8 fs hook (`app-firewall.js`), a SUID `gh-vault` binary, and removal of privilege-escalation binaries (`su`, `mount`, `passwd`).

Rip-cage deliberately rejects these mitigations (ADR-019 D7). Pi-coding-agent-container targets a motivated-attacker threat model; rip-cage's threat model is "limit blast radius of an autonomous agent's accidents." Adversarial mitigations add complexity, fragility, and surface detection-evasion-flavored UX — when an agent's write is blocked at the `LD_PRELOAD` level it tends to retry and fail confusingly, which violates the autonomy-over-containment philosophy (see project CLAUDE.md). The layers rip-cage already runs catch the realistic failure modes.

### Auth refresh

`rc auth refresh` is Claude-only — it shells into the macOS Keychain and updates `~/.claude/.credentials.json`. Pi auto-refreshes its credentials via `proper-lockfile` against the mounted `auth.json`; no rip-cage helper is required. On Linux, both Claude and pi auth files are edited directly on the host and running containers see changes immediately via bind mount.

### Related projects

- **[pi-less-yolo](https://github.com/cjermain/pi-less-yolo)** — closest cousin; same single-bind-mount + `PI_CODING_AGENT_DIR` pattern; provider env-var passthrough list; no auth-warn startup banner.
- **pi-coding-agent-container** — different (adversarial) threat model; uses `LD_PRELOAD`/V8 hooks; see "Why rip-cage doesn't ship paranoid mode" above.
- **gondolin** — heavier sandbox (QEMU micro-VMs, host-side TS policies, allowlisted HTTP egress); useful as Phase 2+ reference for rip-cage if the threat model ever needs to escalate.
