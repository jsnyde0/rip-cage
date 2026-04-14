# ADR-010: Credential Hot-Swap via `rc auth refresh`

**Status:** Proposed
**Date:** 2026-04-14
**Design:** [Auth Refresh](../2026-04-14-auth-refresh-design.md)
**Related:** [ADR-009](ADR-009-ux-overhaul.md) (UX overhaul — auth docs), [ADR-003](ADR-003-agent-friendly-cli.md) (agent-friendly CLI)

## Context

Rip-cage bind-mounts `~/.claude/.credentials.json` read-write into containers. This file is extracted from the macOS Keychain during `rc up`. When a user switches accounts or refreshes auth on the host, the Keychain updates but the file does not — containers see stale credentials.

The current workaround is `rc destroy` + `rc up`, which destroys the Claude Code session (conversation history, context). This is disproportionate — the credentials file just needs re-extracting from the Keychain, and the bind mount propagates the update to all running containers instantly.

## Decisions

### D1: `rc auth refresh` command

**Firmness: FIRM**

Add `rc auth refresh` that re-extracts OAuth credentials from the macOS Keychain to `~/.claude/.credentials.json`. The bind mount propagates the update to all running containers immediately — no restart or destroy needed.

```bash
rc auth refresh   # re-extract credentials from keychain → file → all running containers see it
```

On Linux (no Keychain), print a message directing the user to update `~/.claude/.credentials.json` directly.

**Rationale:** Destroying a container just to refresh credentials loses the Claude Code session, which is expensive (context, conversation history). The credentials file is already bind-mounted read-write, so the infrastructure for live updates exists — users just need a command to trigger the keychain re-extraction instead of remembering the `security find-generic-password -s "Claude Code-credentials" -w > ~/.claude/.credentials.json` incantation.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **`rc auth refresh`** | Simple, no restart, preserves session | New command to learn |
| **Inotify/fswatch on keychain** | Fully automatic | Complex, platform-specific, brittle |
| **Document the `security` command** | No code change | User must remember macOS-specific incantation |
| **`rc destroy` + `rc up`** | Already works | Destroys session history — the whole problem |

**What would invalidate this:** If Claude Code changes to auto-refresh the credentials file on the host when `/login` runs (making the bind-mounted file always current). Currently `/login` updates the Keychain but not the file.

### D2: Extract `_extract_credentials` helper (dedup)

**Firmness: FIRM**

Extract the existing inline keychain-to-file logic from `cmd_up` into a shared `_extract_credentials` helper. Both `cmd_up` and `cmd_auth_refresh` call it. No behavior change to `cmd_up`.

**Rationale:** The extraction logic is ~15 lines. Duplicating it would be a maintenance liability. The helper also future-proofs for `rc auth status`, `rc auth clear`, etc.

### D3: `auth` as a command namespace

**Firmness: FLEXIBLE**

Route `rc auth <subcommand>` through `cmd_auth`. Initially only `refresh` is implemented. This leaves room for future subcommands (`status`, `clear`, `check`) without CLI breaking changes.

**Rationale:** `rc auth-refresh` (hyphenated top-level) would work but doesn't compose. `rc auth refresh` is more natural and extensible.

**What would invalidate this:** If no other `auth` subcommands ever materialize. Low cost either way — the namespace routing is ~5 lines.

## Deferred

- **`rc auth status`** — Show current credential state (valid/expired/missing), which account, expiry time. Useful but not blocking.
- **`rc auth clear`** — Remove cached credentials file. Edge case cleanup.
- **Auto-refresh on token expiry** — Detect expired token inside container and auto-trigger refresh. Complex (needs host-side daemon or polling).
