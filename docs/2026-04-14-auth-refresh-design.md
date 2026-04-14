# Auth Refresh — Design

**Date:** 2026-04-14
**Decisions:** [ADR-010](decisions/ADR-010-auth-refresh.md)
**Related:** [ADR-009](decisions/ADR-009-ux-overhaul.md) (UX overhaul — `docs/reference/auth.md` will document this feature)

## Problem

When a user switches Claude Code accounts or refreshes auth on the host (`/login` or `claude auth login`), the macOS Keychain is updated — but the file `~/.claude/.credentials.json` is not. That file was extracted from the Keychain during `rc up` and bind-mounted into the container. The container sees stale credentials.

The current fix is `rc destroy <name>` + `rc up .`, which destroys the Claude Code session (conversation history, context, in-progress work). This is expensive and unnecessary.

## Discovery

The credentials file is bind-mounted **read-write** into containers:

```bash
-v "${HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json"
```

This means updating the file on the host propagates instantly to all running containers. The infrastructure for live credential updates already exists — the missing piece is a convenient command to trigger the keychain-to-file extraction without the user needing to remember the macOS `security` incantation.

## Design

### 1. Extract `_extract_credentials` helper

The keychain-to-file logic currently lives inline in `cmd_up` (lines 598-613 of `rc`):

```bash
# Current inline code in cmd_up:
if [[ -d "${HOME}/.claude/.credentials.json" ]]; then
  rmdir "${HOME}/.claude/.credentials.json" 2>/dev/null || \
    echo "Warning: ..." >&2
fi
if [[ "$(uname)" == "Darwin" ]]; then
  local creds_tmp
  creds_tmp=$(mktemp) || { echo "Warning: ..." >&2; return; }
  if security find-generic-password -s "Claude Code-credentials" -w > "$creds_tmp" 2>/dev/null; then
    mv "$creds_tmp" "${HOME}/.claude/.credentials.json"
  else
    rm -f "$creds_tmp"
    echo "Warning: failed to extract credentials ..." >&2
  fi
fi
```

Extract this into `_extract_credentials` so both `cmd_up` and the new `cmd_auth_refresh` can call it. The helper returns 0 on success, 1 on failure.

### 2. Add `cmd_auth_refresh`

New command: `rc auth refresh`

```bash
cmd_auth_refresh() {
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "On Linux, update ~/.claude/.credentials.json directly." >&2
    echo "Running containers will see the change immediately via bind mount." >&2
    return 0
  fi
  _extract_credentials
  if [[ $? -eq 0 ]]; then
    log "Credentials refreshed. Running containers will pick up the change on next API call."
  else
    die "Failed to extract credentials from macOS Keychain. Run 'claude auth login' first."
  fi
}
```

**Command routing:** Add `"auth") cmd_auth_refresh "$@" ;;` to the main dispatch case statement. The subcommand `refresh` is parsed inside `cmd_auth_refresh` (future-proofs for `rc auth status`, `rc auth clear`, etc.).

### 3. JSON mode

```json
// Success:
{"status": "ok", "action": "credentials_refreshed", "credentials_updated": true}

// Failure:
{"status": "error", "code": "KEYCHAIN_EXTRACTION_FAILED", "message": "..."}

// Linux:
{"status": "ok", "action": "no_op", "message": "On Linux, update ~/.claude/.credentials.json directly."}
```

### 4. Update `cmd_up` to use helper

Replace the inline extraction code in `cmd_up` with a call to `_extract_credentials`. No behavior change — pure dedup.

### 5. Documentation

Add a "Switching accounts" section to `docs/reference/auth.md` (created by the UX overhaul, ADR-009). If auth.md doesn't exist yet, add a note in README under tips.

## User workflow

```bash
# Inside rip-cage container: agent hits usage limit or wrong account
# On host:
claude auth login          # or /login in Claude Code — updates macOS Keychain
rc auth refresh            # extracts to file → bind mount propagates to all containers
# Inside container: Claude Code picks up new credentials on next API call
```

## Edge cases

- **No running containers:** Still works — updates the file for the next `rc up`.
- **Multiple running containers:** All see the update simultaneously (same bind-mounted file).
- **Token expiry check:** The existing expiry check in `cmd_up` (lines 634-652) is NOT duplicated in `cmd_auth_refresh` — freshly extracted tokens should be valid. Could add later if needed.
- **`--dry-run`:** Report what would happen without extracting. Low value for this command but keeps consistency.

## File changes summary

| Action | Files |
|--------|-------|
| **Modify** | `rc` (extract `_extract_credentials` helper, add `cmd_auth_refresh`, update `cmd_up` to use helper, add dispatch case) |
| **Create** | None (docs/reference/auth.md is created by ADR-009 UX overhaul — this adds a section to it) |

## What this does NOT change

- Container behavior — no runtime changes inside the container
- The bind mount setup — credentials were already mounted read-write
- `cmd_up` behavior — same extraction, just via helper instead of inline
- The safety stack — unrelated
