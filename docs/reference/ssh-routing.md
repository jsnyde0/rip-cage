# SSH Identity Routing — RETIRED

> **This page describes a retired feature.** [ADR-029](../decisions/ADR-029-msb-migration.md) D3 retires the entire ssh cluster (ADR-017 agent forwarding, ADR-018 socket discovery, ADR-020 identity routing, ADR-022 host+key allowlist) in favor of git over HTTPS with a per-cage token injected by msb `--secret`. The `--github-identity` flag, `RIP_CAGE_GITHUB_IDENTITY` env var, `~/.config/rip-cage/identity-rules`, the `--no-ssh-config`/`--no-forward-ssh` flags, the `[rip-cage] github.com: ...` banner, and the `~/.cache/rip-cage/identity-map.json` cache described below **no longer exist in `rc`** — none of this is wired into `cli/up.sh` post-cutover. This page is kept as a historical record of the pre-cutover design, not a how-to.

## What replaced it

Git authenticates over HTTPS: `https://x-access-token:$TOKEN@github.com/...`, with `$TOKEN` injected on the wire by msb `--secret` — the guest never possesses the real token, only a synthesized placeholder ([ADR-029](../decisions/ADR-029-msb-migration.md) D3/D5). The per-cage token binding **is** the identity scoping (no four-layer resolution, no rules file, no `match`/`unset`/`mismatch` banner) — you declare which token is bound to which host(s) directly in `.rip-cage.yaml`:

```yaml
# <project>/.rip-cage.yaml
version: 1
network:
  allowed_hosts:
    - github.com
auth:
  credentials:
    - source_env: GH_TOKEN     # a host env var holding a scoped GitHub PAT
      hosts: [github.com]
```

See [egress.md](egress.md) for the full worked example (reachability + credential injection are two separate declarations) and [CLAUDE.md](../../CLAUDE.md#when-you-need-a-new-host-allowed-for-egress-inside-the-cage) for the "I hit a wall" flow.

**Successor design pointer** ([ADR-029](../decisions/ADR-029-msb-migration.md) D3): if a per-project "which identity does this cage push as" selection mechanism is ever rebuilt for token-based auth, this retired page's four-layer priority shape (flag → label → rules-file → loud-unset) and `match`/`mismatch`/`unset` state machine are the named reusable designs — `gh api user` is the natural identity probe over HTTPS, parallel to the old `ssh -T git@github.com` greeting probe. Nothing along these lines is implemented today; `auth.credentials` above is the entire current surface.

## `rc reload` — also retired in its pre-cutover shape

The retired `rc reload` below hot-reloaded `ssh.allowed_hosts` in place, with no container teardown. **That hot-reload property does not survive the cutover.** The current `rc reload` (`cli/reload.sh`) applies `network.allowed_hosts`/`network.mode` changes and is a **cold-recreate** (graceful stop → remove → recreate) — see [egress.md](egress.md#the-denyfixreload-repair-loop) and [ADR-029](../decisions/ADR-029-msb-migration.md) D4 for what survives (host mounts, named volumes, the Claude session) versus what's lost (only the guest's ephemeral overlay).

---

<details>
<summary>Historical record of the pre-cutover ssh identity routing design (click to expand — not current behavior)</summary>

Rip cage carried your host SSH posture into the cage — not just the forwarded agent (ADR-017/018), but also the config that says *which* key to use for *which* destination. Without it, OpenSSH inside the cage fell back to offering every key in the agent in load order; on GitHub that meant whichever key was loaded first decided which account was used for the entire session, silently.

After `rc up`, the cage had a translated version of your `~/.ssh/config`, read-only pub key files for the keys your config referenced, and a synthesized `Host github.com` block if one was resolved. Private keys were never mounted — the forwarded agent handled signing.

**`--github-identity` flag.** `rc up --github-identity=id_ed25519_work ~/code/mapular/foo` pinned `github.com` inside the cage to the named key for that container, for the container's lifetime.

**Resolution order:** 1) `--github-identity`/`RIP_CAGE_GITHUB_IDENTITY` CLI/env, 2) `rc.github-identity` container label (resume), 3) first matching glob in `~/.config/rip-cage/identity-rules`, 4) no match (banner showed `unset`).

**Banner states:** `match` (green, resolved identity matches expected), `unset` (yellow, no pin configured), `mismatch` (red, resolved identity differs from expected — recreate required to fix), `unreachable` (yellow, the github.com SSH probe couldn't connect).

**`rc reload`** (pre-cutover): host-side hot-reload of `ssh.allowed_hosts` content changes only, re-running `_filter_known_hosts` against host `~/.ssh/known_hosts` and rewriting the cage's cached `known_hosts` bind-mount source in place — no container recreation, no daemon restart, no tmux interruption. Full design: [ADR-022](../decisions/ADR-022-ssh-allowlist.md) D6.

</details>
