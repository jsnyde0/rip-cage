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
