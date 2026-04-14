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
| `init-rip-cage.sh` | Reads the mounted `.credentials.json` — does NOT extract from Keychain (runs inside container) |

## Known issue

Credential bind mounts break if the host rewrites `~/.claude/.credentials.json` (e.g., token refresh by host Claude Code). Symptom: "Not logged in" inside container. Fix: `rc destroy <name>` then `rc up .` again.
