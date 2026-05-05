# SSH Identity Routing

Rip cage carries your host SSH posture into the cage — not just the forwarded agent (ADR-017/018), but also the config that says *which* key to use for *which* destination. Without it, OpenSSH inside the cage falls back to offering every key in the agent in load order; on GitHub that means whichever key was loaded first decides which account is used for the entire session, silently.

After `rc up`, the cage has a translated version of your `~/.ssh/config`, read-only pub key files for the keys your config references, and a synthesized `Host github.com` block if one was resolved. Private keys are never mounted — the forwarded agent handles signing.

---

## `--github-identity` flag

```
rc up --github-identity=id_ed25519_work ~/code/mapular/foo
```

Pins `github.com` inside the cage to the named key for this container. The basename identifies a key file under `~/.ssh/` on the host — no path, no extension.

After `rc up`, all `git@github.com:` URLs inside the cage authenticate using that key. The pin is immutable for the lifetime of the container: passing `--github-identity` to `rc up` on an already-running container errors loud and tells you to `rc destroy && rc up` to change it.

The same effect can be achieved without the flag by setting `RIP_CAGE_GITHUB_IDENTITY=<keyname>` in your environment before calling `rc up`.

---

## Resolution order for the github.com identity

When you run `rc up`, the cage resolves which identity to pin to `github.com` via a four-layer priority list. The first layer that produces a result wins; later layers are not consulted.

| Priority | Source | When it applies |
|----------|--------|-----------------|
| 1 | `--github-identity=<keyname>` CLI flag, or `RIP_CAGE_GITHUB_IDENTITY=<keyname>` env var | You explicitly named a key at `rc up` time |
| 2 | `rc.github-identity` container label (resume only) | A previous `rc up` already pinned the key; it carries over |
| 3 | First matching glob in `~/.config/rip-cage/identity-rules` against the project path | Your rules file declares a per-path convention |
| 4 | No match | No `Host github.com` block is synthesized; the preflight surfaces this as `unset` |

**Layer 1 example.** You're running `rc up` for a work repo and want to make the pin explicit:

```
rc up --github-identity=id_ed25519_work ~/code/mapular/my-service
```

**Layer 2 example.** You stop and resume a container that was already pinned to `id_ed25519_work`. The pin carries over automatically — no flag needed on resume.

**Layer 3 example.** Your rules file maps project paths to keys:

```
# ~/.config/rip-cage/identity-rules
~/code/mapular/*    id_ed25519_work
~/code/personal/*   id_ed25519_personal
```

When you run `rc up ~/code/mapular/my-service`, the first matching line (`~/code/mapular/*`) fires and the cage is pinned to `id_ed25519_work` without any flag.

**Layer 4 example.** You have no rules file and no `--github-identity` flag. The cage starts with no `github.com` pin; the banner shows `unset` in yellow and names which identity github.com actually sees (useful for single-identity setups where the fallback is fine).

---

## Rules file

Path on host: `~/.config/rip-cage/identity-rules`

Format: one rule per line, a glob pattern followed by a key basename. Blank lines and lines beginning with `#` are skipped. The first matching rule wins.

```
# ~/.config/rip-cage/identity-rules
~/code/mapular/*    id_ed25519_work
~/code/personal/*   id_ed25519_personal
~/dev/clients/*     id_ed25519_client
```

Globs use shell glob semantics — `*` matches path segments, but not `/` boundaries within a segment. The tilde (`~`) is expanded to your `$HOME` before matching, so `~/code/mapular/*` works as expected.

The file is read at `rc up` time (both create and resume). If the file does not exist, layer 3 produces no match and resolution falls through to layer 4.

---

## `--no-ssh-config` and `--no-forward-ssh`

### `--no-ssh-config`

An independent opt-out. When passed, `rc up` skips config translation, pubkey mounts, and the github.com identity preflight entirely. The cage behaves as before ADR-020: forwarded agent, no config, first-key-wins.

```
rc up --no-ssh-config ~/code/my-project
```

After `rc up --no-ssh-config`:
- `/home/agent/.ssh/config` is not mounted (the directory may still exist but is empty).
- No `*.pub` files are mounted.
- The github.com preflight does not run; the banner emits nothing for identity routing.

The opt-out is persisted as a container label (`rc.ssh-config=off`) so resume preserves the posture without re-passing the flag.

### `--no-forward-ssh` implies `--no-ssh-config`

Passing `--no-forward-ssh` (the ADR-017 containment flag) implies `--no-ssh-config` by default. The reasoning: a cage with a translated config and pub key mounts but no forwarded agent is a confusing half-state. When you ask for no SSH forwarding, the config routing goes away too.

To decouple the two — forwarding off, but config and pub key mounts on — pass both flags explicitly:

```
rc up --no-forward-ssh --ssh-config ~/code/my-project
```

| Flags passed | Forwarded agent | Config + pubkeys mounted | Identity preflight |
|---|---|---|---|
| (default) | yes | yes | yes |
| `--no-ssh-config` | yes | no | no |
| `--no-forward-ssh` | no | no | no |
| `--no-forward-ssh --ssh-config` | no | yes | yes |

---

## Banner states

Every new shell inside the cage (on tmux attach or devcontainer open) shows a one-line github.com identity status. The line is absent only when ssh-config is disabled.

### `match` (green)

**Condition:** The identity github.com authenticated as matches the expected key for this container.

```
[rip-cage] github.com: jonatan-mapular (source: rules-file)
```

Shown in green. The source field names which resolution layer produced the pin: `host-config`, `cli-flag`, `label`, `rules-file`, or `none`.

### `unset` (yellow)

**Condition:** No `Host github.com` block was synthesized (layer 4 — no rules file, no flag, no label), but SSH itself is active.

```
[rip-cage] github.com: unset — pushes will go to jsnyde0
```

Shown in yellow. The message names the identity github.com actually resolved to, so you can verify whether the fallback is acceptable. To pin: `rc destroy <name> && rc up --github-identity=<keyname> <path>`.

### `mismatch` (red)

**Condition:** The expected identity (from the label or flag) differs from what github.com actually resolved to — typically caused by a missing pub key file or an `IdentitiesOnly yes` block that couldn't be honored.

```
[rip-cage] github.com: MISMATCH — expected jonatan-mapular, greeting jsnyde0
```

Shown in red. To fix: `rc destroy <name> && rc up --github-identity=<keyname> <path>` (passing `--github-identity` on an existing container errors; recreate is required).

### `unreachable` (yellow)

**Condition:** The github.com SSH probe could not connect — egress firewall, no network, or github.com is down.

```
[rip-cage] github.com: unreachable (skipping pubkey check)
```

Shown in yellow. Routing configuration is still in place; the probe just couldn't confirm it. Read-only work and HTTPS git remain usable.

---

## Identity-map cache

Host path: `~/.cache/rip-cage/identity-map.json`

The cache maps key basenames to the GitHub usernames they authenticate as, so the preflight can detect `match` vs `mismatch` without a round-trip comparison requiring user input. It is populated lazily from successful preflights and shared across all containers on the host.

TTL: 24 hours. Refresh: `rc auth refresh` invalidates cache entries and triggers a fresh probe on the next `rc up`.

---

## What is observable in the cage after `rc up`

After a successful `rc up` with ssh-config enabled, `/home/agent/.ssh/` contains:

- **`config`** — the translated config derived from your host `~/.ssh/config`, read-only bind mount. `IdentityFile` paths point into `/home/agent/.ssh/`; macOS-only directives are shimmed; host-only directives (`ProxyCommand`, `ControlPath`, etc.) are stripped. If a `Host github.com` block was synthesized, it appears at the end.
- **`<keyname>.pub`** — one file per key referenced by an `IdentityFile` directive in the translated config, read-only bind mounts from `~/.ssh/<keyname>.pub` on the host.
- **`known_hosts`** — read-only bind mount from `~/.ssh/known_hosts` on the host, if it exists. Augments the cage-baked `/etc/ssh/ssh_known_hosts` (which holds `github.com` only).

**No private key material is present.** The forwarded ssh-agent handles all signing; the cage only needs the pub key files so that `IdentitiesOnly yes` can filter the agent down to the correct identity. This is the load-bearing structural invariant from ADR-017 D1.

If `--no-ssh-config` was passed (or implied by `--no-forward-ssh`), the directory exists but contains none of the above mounts.
