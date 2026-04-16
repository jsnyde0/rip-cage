# Multi-Account Rotation

Running multiple Claude Code accounts lets you spread rate limits across profiles — when one account hits its limit, switch to another and keep working. This guide shows how to set that up with rip-cage.

## How it works

Rip-cage bind-mounts `~/.claude/.credentials.json` read-write into every container. Any change to that file on the host propagates instantly to all running containers. Agents pick up new credentials on their next API call — no restart needed.

This means account rotation is just "rewrite the credentials file on the host."

## Setup with CAAM

[CAAM](https://github.com/jsnyde0/caam) (Coding Agent Account Manager) manages named credential profiles and handles the file swap atomically.

### Install

```bash
# macOS
brew install jsnyde0/tap/caam

# Or from source
go install github.com/jsnyde0/caam@latest
```

### Create profiles

Log in to each Claude Code account and back up its credentials:

```bash
# Log in as your primary account
claude auth login
caam backup claude primary

# Log in as your secondary account
claude auth login
caam backup claude secondary
```

### Switch accounts

```bash
# Switch to a specific profile
caam activate claude secondary

# Or rotate to the next profile automatically
caam next claude --auto
```

All running rip-cage containers pick up the change immediately.

## The workflow

```bash
# 1. Start a caged agent
rc up ~/projects/my-app

# 2. Agent works... eventually hits rate limit
#    (you see "rate limit" errors in the tmux session)

# 3. On the host, switch accounts
caam activate claude secondary
# Or: caam next claude --auto

# 4. Agent retries → works with new credentials
#    No container restart. No lost context.
```

## Without CAAM

You don't need CAAM — any method that updates `~/.claude/.credentials.json` works:

```bash
# Option A: rc auth refresh (re-extracts current account from macOS Keychain)
claude auth login    # switch account in Claude Code first
rc auth refresh

# Option B: manual file replacement
cp ~/backups/secondary-credentials.json ~/.claude/.credentials.json
```

## Platform caveats

**macOS + OrbStack or Docker Desktop (VirtioFS):** Works out of the box. CAAM's atomic file swap (`mv`) propagates correctly through VirtioFS. There's a sub-second window during the swap where the file briefly disappears — Claude Code retries naturally.

**Linux (native Docker):** Single-file bind mounts track inodes, not paths. An atomic `mv` creates a new inode that the container won't see. Two workarounds:

1. Write credentials in-place: `cat new-creds.json > ~/.claude/.credentials.json`
2. Bind-mount the directory (`~/.claude/`) instead of the single file (requires rip-cage configuration change)

## Tips

- **Label your profiles clearly** — `primary`, `secondary`, or by purpose (`work`, `personal`)
- **Back up after each `claude auth login`** — CAAM captures the current Keychain state
- **Multiple containers share one credentials file** — switching affects all running agents simultaneously. If you need per-container accounts, that's a different pattern (not yet supported)

## See also

- [Auth reference](../reference/auth.md) — how rip-cage handles credentials
- [CLI reference](../reference/cli-reference.md) — `rc auth refresh` details
