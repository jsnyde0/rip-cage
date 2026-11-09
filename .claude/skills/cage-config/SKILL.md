---
name: cage-config
description: "Write or repair a project's rip-cage config: mounts, secrets, egress allowlist, host tools. Use on CAGE_CONFIG_MISSING, to allow a host, or to declare a host command. Not the image (cage-image) or a live cage (cage-ops)."
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
| `workdir:`, `cpus:`, `memory:` | where it lands, how big it is | `memory:` is a ceiling, not a reservation: the host backs it lazily and never hands it back while the cage runs, so size it to what the host can spare (the template's `memory:` comment has the rest) |

**Not in this file: the multiplexer.** Which multiplexer a cage runs is
declared by the image's boot descriptor and picked at create by
`RC_MULTIPLEXER`. For that, read [`cage-image`](../cage-image/SKILL.md).

Three mount rules bite in practice, all worth repeating because they surface
only when you launch, not when you write the file:

- **Absolute paths only, with no symlink in them.** msb does not follow a
  host-side symlink in a bind source. On macOS `/tmp` and `/var` are symlinks —
  write `/private/tmp/...`. Resolve with `cd <path> && pwd -P`.
- **A source that does not exist fails the boot.** Do not declare a mount
  "just in case"; declare it when the host file is there.
- **A mount that equals or contains `$XDG_CONFIG_HOME/rip-cage/secrets`
  (the CCTOK non-possession bridge's host file, see
  [`docs/reference/auth.md`](../../../docs/reference/auth.md)) is refused
  before any msb call** — remove that mount line rather than narrowing it.
  One of rc's own skill/agent/pi-substrate symlink-parent mounts that would
  contain it is skipped instead, with a stderr warning naming the mount.

## The mounts that make a session survive a recreate

Adding an allowlist host recreates the cage. The host mounts of
`~/.claude/projects` and `~/.claude/sessions` are what make the running Claude
session come back rather than vanish with it. **The config owns these two
lines; rc does not add them.** Delete them and a recreate loses the session
(`rc up` warns, naming the line to restore). Named volumes (`rc-state-*`,
`rc-history-*`, `rc-mise-cache-*`) survive too. The guest's own scratch does not.

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
sees the name and zero bytes. The file must sit inside a read-write mount:
msb cannot create a file cover inside a read-only mount, and the boot dies.
For a secret inside a read-only mount, add its name to your protected-paths
copy instead: `rc` covers listed files there from inside the cage, before
init. Every cover, either kind, is a visibility default that in-guest root
can undo, not a boundary.

These are belt and braces — declare a cover for a name NOT on the
protected-paths list. The template's mounts block shows the line shape.

## Credentials the cage never holds

A `secrets:` entry binds a credential name to the hosts it may be injected
toward, and **leaves `value:` out**. msb then takes the real value from the
host environment at boot; the guest only ever sees the placeholder
`$` + `MSB_<NAME>` — on disk, in its environment, in `/proc`. Writing a `value:`
here would put the secret in this file, which is the one thing the shape exists
to avoid.

`rc` fills that host variable from
`~/.config/rip-cage/secrets/<NAME>` when that file exists. Otherwise export it
yourself before `rc up`, or msb fails loud naming it.

**pi's model credential rides this same shape**; rc never mounts the host's
`~/.pi/agent/auth.json`. OpenRouter (API key) and openai-codex (OpenAI
subscription) are proven, and pi never uses the Anthropic subscription — see
[`recipes/pi-providers.md`](recipes/pi-providers.md).

## Egress: default-deny plus a list you maintain

`network.policy: none` is msb's default-DENY. Only the hosts under
`network.allow` leave the cage, and each entry names its port:
`"<host>:tcp:443"`. A bare host would open every port; `host:443` without the
protocol is rejected at create. The target can be any kind msb's rule grammar
names (`msb create --help`, `--net-rule`): a domain (`github.com`), a suffix
(`*.githubusercontent.com`), an IP or CIDR (`149.154.160.0/20`) for a service
that has no name, or a group (`private`). A config with no `secrets:` entry
also needs `strict: false` under `network:`: msb 0.7.3+ defaults strict on,
and without a bound secret every name in the list fails at the TLS handshake.
The template binds CCTOK, so it needs no line. `rc up` warns on the breaking shape. While
a secret is bound, a non-TLS stream or a bare-IP HTTPS call to an IP allowed
on port 443 connects, then stalls, strict on or off
([`docs/reference/egress.md`](../../../docs/reference/egress.md#strict-hostname-checking-msb-073)).
The same section carries the measured port-80 recipe for a non-TLS, IP-only
protocol under a bound secret: the CIDR allowed on `tcp:80`, and the client
pinned to port 80.

The template's list is the starting set, with each entry's reason beside it.
For which hosts a coding agent actually needs and why, see
[`references/allowlist.md`](references/allowlist.md).

**A denied host is not a bug to design around.** When a cage hits one,
`rc doctor <cage>` prints the exact line to paste. That loop belongs to
cage-ops; this skill owns the file it edits.

## Declaring host tools

Reach for this when the cage needs a host command whose credential
`secrets:` cannot swap on the wire: a protocol that is not HTTP (SSH, a
messaging session, a database wire), a key that signs a request instead of
riding it, or a reply that must hand a key back. The agent calls
`host-tool <tool> <verb> --<slot> <value>`; the host runs the one command line
you declared for that verb, after checking each value against its slot type
([ADR-032](../../../docs/decisions/ADR-032-host-tool-line.md); mechanism in
[`docs/reference/host-tool-line.md`](../../../docs/reference/host-tool-line.md)).
rc names no tool: the command is yours. A worked one is
[`examples/host-tool/`](../../../examples/host-tool/README.md); copy its
[`example.tools.yaml`](../../../examples/host-tool/example.tools.yaml) and edit it.

**Where it lives.** A sibling of the config, never inside it (msb's `--conf`
rejects unknown keys): beside the config file's **real** path, named
`<real-file-stem>.tools.yaml`. For a default config that is a plain file that is
`~/.config/rip-cage/projects/<cage-name>.tools.yaml`; if that config is a
symlink, the declaration sits beside the symlink's target, named by the
target's stem; a `--conf <path>` or `RC_CAGE_CONF` config follows the same
rule. No file means no line. Write each key once; a repeated YAML key silently
keeps the last.

```yaml
tools:
  <tool>:                # [a-z][a-z0-9_-]{0,31}, as are verb and slot names
    verbs:
      <verb>:
        argv: ["/abs/path/to/command", "sub", "--chat", "{chat}", "--limit", "{limit}"]
        slots:
          chat:  {type: string, regex: "^-?[1-9][0-9]*$", allow_dash: true}
          limit: {type: int, min: 1, max: 100, default: 20}
        timeout: 30s     # <n>s or <n>m; a verb that waits on a human declares a long one
        returns_secret: false
```

- **`argv` is an array, executed directly; no shell.** Each `{slot}` is a whole
  element, used once, and fills exactly one argv element whatever it holds.
  `argv[0]` is a literal absolute path to an existing executable file.
- **Slot types.** `string` (`max` bytes, default 4096; `regex`, a full match;
  `allow_dash`; `allow_slash`), `int` (`min`, `max`), `enum` (`values`); each may
  have a `default`. Strings reject control characters. A value starting with `-`
  needs `allow_dash: true` (a negative id); a value that contains `/` or is
  exactly `..` needs `allow_slash: true` (a message that quotes a URL); a value
  that merely contains `..`, such as `a..b`, passes. Leave both off for anything
  a tool would read as an option or a file name.
- **No path slot, and no interpreter plus a free string.** `["/usr/bin/python3",
  "{script}"]` is host code execution however `script` is typed, and so is
  `["/bin/sh", "-c", "{cmd}"]`. A tool that needs a file reads it from a mount;
  a tool that needs a program runs a fixed command, not one the agent names.

**Which literals count as paths.** rc resolves every substring of an `argv`
literal that starts at a `/`, after splitting at each `=`, and refuses the
declaration if one lies inside a directory the cage mounts. A literal that
begins `./` or `~`, or holds a `..` segment, is refused outright. So
`refs/heads/main` and `application/json` pass; `-F/path`, `@/path`, `-I../x` and
`--opt=/path` are read as paths. This is why the example installs its scripts to
`~/.local/share/host-tool-examples` and not into the project: the workspace is a
mount, and a script the cage can rewrite is host code.

**The one instruction that follows.** rc checks the files `argv` names, not the
code they load (a shebang's interpreter, a venv behind an entry point, a sourced
library). Declare tools whose whole install, interpreter, venv and libraries,
lives outside every mount. Keep `~/.local`, the rc checkout and every declared
tool's install out of your mounts. `rc up` also refuses a mount that equals or
contains the projects directory, the state directory root or this config's own
directory, or lies inside the projects or state directory (a mount strictly
inside the config's directory is allowed). Every declared slot must appear in
`argv` exactly once; the loader refuses a slot with no placeholder.

**A tool runs with no terminal and a bare environment.** Its stdin is `/dev/null`. Its
environment is exactly `PATH=/usr/bin:/bin`, `HOME` and `LANG`; its working
directory **and** `HOME` are one fresh, empty directory per call, deleted when the
call ends. A tool therefore sees no dotfiles and keeps nothing between calls,
unless the declaration or a wrapper hands it a fixed path: a gitconfig through
`-c include.path=/abs/path/gitconfig`, a wrapper's inbox, a `HOME` it sets for
itself. **Any such path is authority: keep it out of every mount.** A wrapper that
needs `SSH_AUTH_SOCK` sets it from a fixed path it owns.

**What it cannot declare yet.** A verb over the mounted workspace itself (`git
push` on the project with the host's keys): the workspace is a mount, and a tool
that reads config or hooks from it runs guest-writable code on the host. It waits
for a project that needs one and a ruling on the repo-config cover (ADR-032 D2).

**Replies.** A request and a reply are each capped at 32 KiB on the wire. A tool
that can return more pages: give it an offset or a limit slot, and have the agent
loop. A verb whose reply hands the cage a real secret sets `returns_secret: true`;
`rc doctor` lists it as possession-mode. The preferred shape is the tool writing
the new value where `secrets:` reads it, so the guest keeps its placeholder.

**When an edit takes effect.** Adding or removing the file, and changing a
declared verb, take effect on `rc up` for a stopped cage and on `rc up --replace`
for a running one (a plain `rc up` on a running cage attaches and prints that the
declaration changed). One exception: if the gatekeeper of a **running** cage is
dead, plain `rc up` restarts it from the **current** file and prints no changed
line, so an edit takes effect then without a message. Revoking a verb is the
same two commands. Repairs:
[`cage-ops`](../cage-ops/SKILL.md).

**A line bypasses the allowlist.** A host tool reaches whatever its command
reaches, and `network.allow` never sees it. `rc doctor <cage>` lists the host
tools and states they bypass `network.allow`; say it to the human when you add
one.

*Done when:* `rc up --dry-run <project>` exits 0 with no `host-tool declaration`
error, every path in the file is absolute and outside every mount you declared,
and each verb's `timeout` covers its slowest expected run.

## What rc adds that no config file can hold

`--name`, `--log-level trace`, `--replace`, reading and exporting the CCTOK
setup-token for msb `--secret`, the host skills projection, the read-only
parent mounts computed from your skill symlinks, and the protected-path covers.
Everything else belongs in this file.

**Skills arrive through rc's projection, never a config line.** rc mounts
`~/.claude/skills` read-only at `/home/agent/.rc-context/skills` and init
symlinks `~/.claude/skills` to it. A config must not mount `~/.claude/skills`
itself: `rc up` warns and init skips the symlink.

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
- [`recipes/pi-providers.md`](recipes/pi-providers.md) — in-cage pi on
  OpenRouter or the OpenAI subscription, each credential an msb secret.

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
