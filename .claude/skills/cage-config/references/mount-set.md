# Reference: the mount set, and what a recreate costs

Which mount lines keep a session alive across a cold recreate, which state
lives in named volumes, and what is genuinely lost.

The shipped lines are in
[`share/rip-cage/cage.yaml.template`](../../../../share/rip-cage/cage.yaml.template)
under `mounts:`. This page says what each one buys.

---

## Why "recreate" comes up at all

Adding an egress host — the most common config change there is — cannot be
applied to a running cage. msb's network rules have no live-mutation path, so
`rc up --replace` does a graceful stop, remove, and recreate against the
now-current config. Every cage recreates sooner or later, so the question
"what survives one?" is not an edge case.

Separately: under msb every resume is a **fresh kernel boot**. A stopped cage
that comes back is not a paused container with its processes intact —
processes die on stop. `rc` re-runs init on every resume for exactly this
reason.

---

## What survives, and why

| Mount | Carries | Lose it and |
|---|---|---|
| `<project>:/workspace` | your code | the cage has nothing to work on |
| `<home>/.claude/projects` | Claude Code transcripts, per project | the session cannot resume — the conversation is gone |
| `<home>/.claude/sessions` | session index and state | same |
| `<home>/.claude/skills:ro` | host skills, read-only | the in-cage agent sees no skills |
| `<home>/.claude.json:ro` | the host Claude config | in-cage Claude has no config to seed from |
| `rc-state-<cage>` → `/home/agent/.claude-state` | cage-local agent state | state resets each recreate |
| `rc-history-<cage>` → `/commandhistory` | shell history | history resets each recreate |
| `rc-mise-cache` → `/home/agent/.local/share/mise` | toolchain cache, **shared across cages** | every cage re-downloads its runtimes |

**The two Claude session mounts are the ones people drop and regret.** They are
what makes "add a host, recreate, keep working" a two-minute interruption
instead of a lost session. The template flags them for that reason.

---

## Read-only where read-only is enough

Two lines are `:ro` deliberately:

- **`~/.claude/skills`** — the cage reads your skills; it has no business
  rewriting them.
- **`~/.claude.json`** — the host Claude config. In-cage Claude only needs to
  READ it: init snapshots it to a seed file under `~/.claude` at boot and the
  agent works from that copy. Read-write would hand an agent that followed
  injected instructions (ADR-024, in scope) a write into `mcpServers` and
  `hooks` — entries your HOST Claude later executes with real credentials.

`ro` is not caution here; it is the whole reason the line is safe to have.

---

## What a recreate actually costs

**Lost:** only the guest's own ephemeral rootfs scratch. In practice that means
anything you installed at runtime inside the cage — an ad-hoc `apt-get install`
— that was neither baked into the image nor captured by a mount or a named
volume.

**Not lost:** the workspace, the Claude session, the named volumes, the
toolchain cache.

That is a narrow, documented trade. If you find yourself re-installing the same
package after every recreate, that package belongs in the **image** — see the
`cage-image` skill — not in a running cage.

---

## Mount rules that fail at boot, not at validation

- **Absolute paths, no symlinked component.** msb does not follow a host-side
  symlink in a bind source. On macOS `/tmp` → `/private/tmp` and `/var` →
  `/private/var`, so a `$TMPDIR` path must be resolved with
  `cd <path> && pwd -P` before it goes in the file. The failure reads
  `mount ...: Not a directory (os error 20)` and points at the mount, not at
  the symlink.
- **The source must exist.** A declared mount whose host path is absent fails
  the boot. Delete the line rather than pre-creating an empty directory to
  satisfy it — an empty directory mounted over a path the cage expects to find
  populated is a subtler failure than a missing line.

---

## Mounts rc adds that this file does not show

`rc` computes a few read-only mounts you do not write:

- **Skill-symlink parents.** A skill stored as a symlink into another repo would
  be a broken symlink inside the cage, so `rc` mounts each symlink target's
  parent directory read-only at its host-absolute path. A symlink that is
  RELATIVE resolves against the cage home instead, and needs its own mount line
  from you.
- **Protected-path covers.** A credential-shaped name found inside a mounted
  tree gets covered — an empty read-only file, or an empty tmpfs for a
  directory. See [`share/rip-cage/protected-paths`](../../../../share/rip-cage/protected-paths).

Neither is a place to add your own mounts. Yours go in the config.
