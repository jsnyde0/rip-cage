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

## The one real hazard: atomic rename

The credential mount is a **single-file** mount, and a rotation tool that swaps accounts the safe way — write a temp file, `mv` over the target — allocates a **new inode**. A single-file mount bound to the old one is left holding a dead handle: the host path looks perfectly fine, and the in-cage path goes `ENOENT`.

The caged agent's symptom is `Not logged in — Please run /login`, possibly long after the swap.

**This was confirmed live under the pre-cutover Docker bind mount, and has not been re-tested under msb's virtiofs** — tracked in `rip-cage-9mbw`. Treat it as the working assumption, not a proven msb fact. [auth.md](../reference/auth.md#gotcha-an-atomic-rename-on-the-host-can-sever-a-live-single-file-mount) has the full mechanism.

**Avoid it** by writing in place rather than renaming:

```bash
cat new-creds.json > ~/.claude/.credentials.json
```

`rc auth refresh` already does this — it truncate-and-writes the same inode, so rip-cage's own rotation never severs the mount. The hazard is external writers.

**Detect it** with `rc doctor <cage>`; its `dead_mounts` probe names any single-file mount whose in-cage destination has gone dead. **Repair it** with `rc up --replace <path>`, which re-binds every mount against the current inode.

## Tips

- **Label your profiles clearly** — `primary`, `secondary`, or by purpose (`work`, `personal`)
- **Back up after each `claude auth login`** — CAAM captures the current keychain state
- **Every cage shares one credentials file**, so switching affects all running agents at once. Per-cage accounts are a different pattern, and not supported today.

## See also

- [Auth reference](../reference/auth.md) — how rip-cage handles credentials
- [CLI reference](../reference/cli-reference.md) — `rc auth refresh` details
