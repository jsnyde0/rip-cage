# Multi-Account Rotation

Running multiple Claude Code accounts lets you spread rate limits across profiles — when one account hits its limit, switch to another and keep working. This guide shows how to set that up with rip-cage.

## How it works

Claude's login reaches the cage through msb `--secret`: a `CCTOK` secret bound to `api.anthropic.com`, sourced from a `claude setup-token` value at `~/.config/rip-cage/secrets/CCTOK`. The value is read once, at launch — there is no live mount to rewrite, and a running cage does not pick up a changed file. Rotating accounts means "put a different token in that file, then recreate the cage." Full mechanism: [auth.md](../reference/auth.md).

## Setup

Get a long-lived token for each account, once:

```bash
claude setup-token   # run once per account, logged in as that account
```

Save each one under its own name, host-side:

```
~/.config/rip-cage/secrets/CCTOK.primary
~/.config/rip-cage/secrets/CCTOK.secondary
```

mode `0600` on each file.

### Switch accounts

```bash
cp ~/.config/rip-cage/secrets/CCTOK.secondary ~/.config/rip-cage/secrets/CCTOK
chmod 600 ~/.config/rip-cage/secrets/CCTOK
rc up --replace ~/projects/my-app
```

`rc up --replace` graceful-stops and recreates the cage against the current config, which is what picks up the new secret value — msb reads `CCTOK` only at boot.

## The workflow

```bash
# 1. Start a caged agent
rc up ~/projects/my-app

# 2. Agent works... eventually hits rate limit
#    (you see "rate limit" errors in the session)

# 3. On the host, switch the token and recreate
cp ~/.config/rip-cage/secrets/CCTOK.secondary ~/.config/rip-cage/secrets/CCTOK
rc up --replace ~/projects/my-app

# 4. Attach again — the cage boots authenticated as the new account
```

This is a recreate, not a live hot-swap: the microVM restarts, though mounted state and volumes survive it ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5(a)). A Claude Code session resumes from its mounted history; expect a short restart gap, not a silent mid-session swap.

## Running two accounts at once

For genuinely parallel cages under different accounts — not rotation, but two cages up simultaneously — give each cage's config its own secret name (`CCTOK_WORK`, `CCTOK_PERSONAL`) instead of sharing `CCTOK`. That is the **cage-config** skill, [`recipes/multi-account.md`](../../.claude/skills/cage-config/recipes/multi-account.md).

## Tips

- **Name your saved tokens clearly** — `CCTOK.primary`, `CCTOK.secondary`, or by purpose (`CCTOK.work`, `CCTOK.personal`).
- **Every cage that declares plain `CCTOK` shares one active token.** Rotating it affects every cage using that name the next time each one is recreated; cages already running keep whatever token they booted with until you `rc up --replace` them too.

## See also

- [Auth reference](../reference/auth.md) — the `CCTOK` mechanism, `rc auth`, and switching accounts
- [Multi-account cage-config recipe](../../.claude/skills/cage-config/recipes/multi-account.md) — parallel cages under different identities
