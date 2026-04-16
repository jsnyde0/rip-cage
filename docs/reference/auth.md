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
