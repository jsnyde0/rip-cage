# ADR-010: Credential Hot-Swap via `rc auth refresh`

**Status:** Proposed

> **Migration status (ADR-029, 2026-07-10):** This ADR is evolved by [ADR-029](ADR-029-msb-migration.md) D5 — the refresh target shifts under credential non-possession, and D4's own invalidation predicate fires (a different file-sharing backend). The mechanisms below remain shipped and load-bearing in the Docker path until the msb cutover release lands; until then this ADR describes current behavior.

**Date:** 2026-04-14
**Design:** [Auth Refresh](../2026-04-14-auth-refresh-design.md)
**Related:** [ADR-009](ADR-009-ux-overhaul.md) (UX overhaul — auth docs), [ADR-003](ADR-003-agent-friendly-cli.md) (agent-friendly CLI)

## Context

Rip-cage bind-mounts `~/.claude/.credentials.json` read-write into containers. This file is extracted from the macOS Keychain during `rc up`. When a user switches accounts or refreshes auth on the host, the Keychain updates but the file does not — containers see stale credentials.

The current workaround is `rc destroy` + `rc up`, which destroys the Claude Code session (conversation history, context). This is disproportionate — the credentials file just needs re-extracting from the Keychain, and the bind mount propagates the update to all running containers instantly *provided the file's inode is preserved* — see D4.

## Decisions

### D1: `rc auth refresh` command

> [ADR-029 D5: EVOLVED — under credential non-possession, the refresh *target* shifts: rather than re-extracting into a file the guest possesses, the natural target becomes the host-side secret store feeding msb `--secret`, refreshed via `msb modify --secret` (proven as a live-rotation primitive). This is an EXPLORATORY direction only — capture, not build-on-pull; the possession-mode fallback (real credentials mounted, per-tool per ADR-026 D7) keeps this decision's file-refresh path, with D4's inode semantics needing re-verification on msb virtiofs (see D4's disposition).]

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

### D4: Write credentials in place (preserve inode)

> [ADR-029: RE-VERIFY (own predicate fired) — this decision's own "What would invalidate this" clause named the trigger precisely: "a future Docker Desktop release using a different file-sharing backend." msb's virtiofs guest/host share IS a different file-sharing backend than Docker/OrbStack's bind-mount mechanism (even where both happen to be named "virtiofs" — the implementation context differs: a microVM's virtiofs share vs. Docker Desktop's VM-to-container passthrough). The predicate fires, but the honest disposition is **re-verify, not "safe again"**: whether msb virtiofs tracks by inode or by path is unconfirmed, so neither the truncate-in-place pattern here nor a return to atomic-rename can be assumed correct until measured. The `rip-cage-rx8` truncate-not-mv recipe (used elsewhere, e.g. ADR-022 D6's `rc reload` cache rewrite) inherits the same open question. Scoped macOS/HVF per ADR-029 D6 until Linux/KVM reconfirmation.]

**Firmness: FIRM**

`_extract_credentials` must write `~/.claude/.credentials.json` **in place** (truncate + write the existing file) rather than via atomic rename (`mv tmp target`). The credential extraction flow:

```
( umask 077; : > "$target" )   # create with 600 perms if absent — no-op if exists
cat "$creds_tmp" > "$target"   # truncate-and-write: preserves the original inode
chmod 600 "$target"            # belt-and-suspenders perms enforcement
```

**Rationale:** Docker's single-file bind mount on macOS (Docker Desktop and OrbStack alike) tracks the *inode* of the source file at `docker run` time, not the path. `mv tmp target` is an atomic rename that allocates a new inode and unlinks the old one — instantly invalidating the bind mount in every already-running container. Symptom: `stat` returns `ENOENT` inside the container, `ls -la` shows `-?????????`, Claude Code reports "Not logged in - please run /login" even after `rc auth refresh`. Truncate-and-write keeps the inode stable, so live containers see the new content immediately via the existing bind mount — which is the entire premise of this ADR.

The trade-off is a sub-millisecond non-atomic write window for a ~1 KB JSON file read infrequently by Claude. Acceptable: a partial read fails fast and Claude retries on the next API call.

**Validation:** With the fix, on macOS `stat -f %i ~/.claude/.credentials.json` returns the same inode before and after `rc auth refresh`, and running containers' bind-mounted view of the file updates in lockstep (matching `mtime`, new token contents readable). With `mv`, the host inode changes and every pre-existing container's mount goes stale at that instant.

**What would invalidate this:** If Docker's macOS bind-mount semantics change to track by path rather than inode (e.g., a future Docker Desktop release using a different file-sharing backend), the atomic-rename pattern would become safe again. Unlikely soon; the inode-tracking behavior is consistent across Docker Desktop's `gRPC FUSE`/`virtiofs` modes and OrbStack as of 2026-05.

## Deferred

- **`rc auth status`** — Show current credential state (valid/expired/missing), which account, expiry time. Useful but not blocking.
- **`rc auth clear`** — Remove cached credentials file. Edge case cleanup.
- **Auto-refresh on token expiry** — Detect expired token inside container and auto-trigger refresh. Complex (needs host-side daemon or polling).
