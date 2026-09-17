---
name: cage-config
description: "Write or repair the one config file a rip-cage cage launches from — a native microsandbox config at ~/.config/rip-cage/projects/<cage>.yaml. Use when setting up a cage for a project, when `rc up` refuses with CAGE_CONFIG_MISSING, when a host must be added to the egress allowlist, when a mount or secret needs declaring, or when the human says 'set up a cage here', 'configure the cage', 'add <host> to the allowlist'. Do NOT use for building the image (that is cage-image) or for running and troubleshooting a live cage (that is cage-ops)."
---

# cage-config

Invoke this when a project needs a cage config written, read, or repaired: a
fresh project with no config, an `rc up` that refused because it found none, a
denied egress host that needs a line, a new mount, a new secret, or a human
asking what a line in an existing config does. The artifact you produce is one
YAML file a human can read before any cage starts — never a running cage.

## The one file, and where it lives

A cage launches from a **single native microsandbox config file**, per project:

```
~/.config/rip-cage/projects/<cage-name>.yaml
```

`rc up` takes the first of `rc up --conf <path>`, `$RC_CAGE_CONF`, then that
default path. `rc` reads this file and never writes it — writing it is your job
([ADR-031](../../../docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2).

**Start from the shipped template, never a blank file:**
[`share/rip-cage/cage.yaml.template`](../../../share/rip-cage/cage.yaml.template).
Every section carries its own reason in a comment. Read it before you write —
it is the source of truth for the shape, and this skill deliberately does not
copy its contents.

**One file, lists complete.** msb overlays two `--conf` files per FIELD but
REPLACES lists. A defaults file plus a project overlay would silently drop the
session mounts or the whole allowlist. So there is no merge and no layering:
this file carries its lists in full.

## The cage name is derived, not chosen

`<cage-name>` comes from the last two components of the project path
(`~/code/personal/myapp` → `personal-myapp`), with a 4-char hash suffix on a
collision. Get it from `rc` rather than deriving it by hand:

```bash
bash -c "source /path/to/rc; container_name \"\$(cd <project> && pwd -P)\""
```

*Done when:* the filename you wrote matches what that command prints.

## Five things the file decides

Read the template for the syntax; this is what each section is FOR.

| Section | Decides | Get it wrong and |
|---|---|---|
| `image:` | which image the cage boots | the cage lacks a tool, or boots a stale build |
| `mounts:` | every host path the cage can see | a session dies on recreate, or a secret is readable |
| `secrets:` | credentials the guest never holds | the token lands on disk inside the cage |
| `network:` | which hosts the cage may reach | the agent stalls on a denied host mid-task |
| `workdir:`, `cpus:`, `memory:` | where it lands, how big it is | nothing subtle |

Two mount rules bite in practice, both stated in the template and both worth
repeating because they fail at BOOT rather than at validation:

- **Absolute paths only, with no symlink in them.** msb does not follow a
  host-side symlink in a bind source. On macOS `/tmp` and `/var` are symlinks —
  write `/private/tmp/...`. Resolve with `cd <path> && pwd -P`.
- **A source that does not exist fails the boot.** Do not declare a mount
  "just in case"; declare it when the host file is there.

## The mounts that make a session survive a recreate

Adding an allowlist host recreates the cage. The host mounts of
`~/.claude/projects` and `~/.claude/sessions` are what make the running Claude
session come back rather than vanish with it. Named volumes (`rc-state-*`,
`rc-history-*`, `rc-mise-cache`) survive too. The guest's own scratch does not.

Full list and what each one buys:
[`references/mount-set.md`](references/mount-set.md).

## The floor you do not write: protected paths

Independent of this file, `rc up` reads a list of path components that must
never reach a cage — credential stores, key directories — and enforces it
before any msb call:
[`share/rip-cage/protected-paths`](../../../share/rip-cage/protected-paths).

Its own header states exactly what each line does (refuse a direct mount,
auto-cover an occurrence inside a mounted tree, abort if the list is
unreadable). Read it there; do not restate it.

**To add a name:** copy the shipped file to
`~/.config/rip-cage/protected-paths` and add a line to your copy. A new
credential store is a line in that file, never an `rc` change.

*Done when:* `rc up --dry-run <project>` completes without a protected-path
refusal, and the name you added appears in your copy.

## Secret covers: masking what the floor does not know about

The protected-paths list covers well-known names. A secret file specific to
this project (`config/local-secrets.toml`, a `.env` the agent has no business
reading) is yours to cover: mount an empty read-only file over it. The cage
sees the name and zero bytes.

These are belt and braces — declare a cover for a name NOT on the
protected-paths list. The template's mounts block shows the line shape.

## Credentials the cage never holds

A `secrets:` entry binds a credential name to the hosts it may be injected
toward, and **leaves `value:` out**. msb then takes the real value from the
host environment at boot; the guest only ever sees the placeholder
`$MSB_<NAME>` — on disk, in its environment, in `/proc`. Writing a `value:`
here would put the secret in this file, which is the one thing the shape exists
to avoid.

`rc` fills that host variable from
`~/.config/rip-cage/secrets/<NAME>` when that file exists. Otherwise export it
yourself before `rc up`, or msb fails loud naming it.

## Egress: default-deny plus a list you maintain

`network.policy: none` is msb's default-DENY. Only the hosts under
`network.allow` leave the cage, and each entry names its port:
`"<host>:tcp:443"`. A bare host would open every port; `host:443` without the
protocol is rejected at create.

The template's list is the starting set, with each entry's reason beside it.
For which hosts a coding agent actually needs and why, see
[`references/allowlist.md`](references/allowlist.md).

**A denied host is not a bug to design around.** When a cage hits one,
`rc doctor <cage>` prints the exact line to paste. That loop belongs to
cage-ops; this skill owns the file it edits.

## What rc adds that no config file can hold

`--name`, `--log-level trace`, `--replace`, the keychain→`--secret` credential
bridge, the read-only parent mounts computed from your skill symlinks, and the
protected-path covers. Everything else belongs in this file.

## Two things never to do

1. **Never edit this file from inside a cage.** It sits outside every cage
   mount on purpose, and `rc` refuses a config that resolves inside a tree that
   same config mounts. An agent inside a cage that wants a host added
   **says so in prose** and waits for the human. It cannot self-grant.
2. **Never invent a key.** This is a native microsandbox config, not an rc
   schema. If a key is not in the template, check the upstream microsandbox
   skill — see below — before assuming it exists.

## microsandbox itself

`rc` is a thin opinionated wrapper; the config format, its keys, and their
semantics are microsandbox's. The maintained skill for msb lives at
`~/code/personal/superradcompany-skills/microsandbox/SKILL.md`, with its
`references/cli-reference.md` alongside. Read it for anything about msb the
template does not answer. **Do not copy it into this repo** — a copy diverges,
which is how the skill this one replaced went stale.

## Recipes

- [`recipes/first-cage.md`](recipes/first-cage.md) — a project with no cage,
  taken to a running one: config → `rc build` → `rc up`. Start here.
- [`recipes/walk-away-cage.md`](recipes/walk-away-cage.md) — a config tuned for
  an agent running unattended for hours.
- [`recipes/multi-account.md`](recipes/multi-account.md) — two cages on one
  host under different accounts, without either seeing the other's credential.

## References

- [`references/allowlist.md`](references/allowlist.md) — the default allowlist,
  per-host rationale, and the port-443 rule.
- [`references/mount-set.md`](references/mount-set.md) — the mounts that make a
  session survive a cold recreate, and what a recreate costs.

## Done condition — report this

State all four, each with the command that showed it:

1. **The path you wrote**, and that it is the path `rc up` will read.
2. **`rc up --dry-run <project>` exits 0** and its argv names your config.
3. **Every mount source exists on the host** and contains no symlinked
   component (`cd <src> && pwd -P` equals the path you wrote).
4. **Every `secrets:` entry has no `value:`**, and the matching host variable
   resolves (a file under `~/.config/rip-cage/secrets/`, or an exported var).

If any of the four is not green, say which one and stop — do not start the cage
to find out.
