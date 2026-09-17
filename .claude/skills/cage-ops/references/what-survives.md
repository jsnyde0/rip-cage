# Reference: resume, recreate, destroy — what each one costs

Three operations look similar and cost very different things. Knowing which one
you are about to do is most of the answer to "will I lose the session?".

---

## Resume — `rc up <project>` on a stopped cage

**Survives:** everything on a mount, everything in a named volume, the
workspace, the Claude session.

**Lost:** every process that was running.

Under msb a resume is a **fresh kernel boot**, not an unpause. Nothing that was
running comes back on its own; `rc` re-runs init and re-registers multiplexer
state each time, which is why a resumed cage looks set up rather than empty.

A stopped cage whose config has CHANGED converges instead: `rc` recreates it
against the new config. `--no-reload` resumes as-is and ignores the change.

---

## Recreate — `rc up --replace <project>`

The cage is gracefully stopped, removed, and created again from the current
config. This is what an allowlist edit requires: msb's network rules have no
live-mutation path, so there is no hot reload to reach for.

**Survives:**

| | Why |
|---|---|
| the workspace | it is a host mount |
| the Claude session | the `~/.claude/projects` and `~/.claude/sessions` mounts |
| host skills, the host Claude config | mounts, read-only |
| `rc-state-<cage>`, `rc-history-<cage>` | named volumes outlive the sandbox |
| `rc-mise-cache` | named volume, shared across cages |

**Lost:** the guest's own ephemeral rootfs scratch. In practice: a package you
`apt-get install`ed at runtime that was never baked into the image and sits on
no mount.

That is a narrow, deliberate trade — not a session-continuity loss. If you find
yourself re-installing the same thing after every recreate, it belongs in the
image (**cage-image**).

**The one way to lose a session here** is a config without those two Claude
mounts. The shipped template has them and flags them for this reason.

---

## Destroy — `rc destroy <cage>`

Removes the sandbox **and** its two named volumes, `rc-state-<cage>` and
`rc-history-<cage>`. `msb remove` alone would leave the volumes behind, so
`rc destroy` deletes them explicitly.

**Survives:** the workspace and every other host mount — including
`~/.claude/projects` and `~/.claude/sessions`, so a Claude session is still
resumable after a destroy.

**Lost:** cage-local agent state and shell history.

**It takes the cage by name.** Given nothing, or a name it cannot resolve, it
refuses with exit 2 and lists the cages it did not touch. It does not pick one
for you. That refusal exists because an empty name from a failed lookup once
deleted the only cage on a machine, volumes and all.

`rc destroy --dry-run <cage>` prints what would go without doing it.

---

## Quick answers

| Question | Answer |
|---|---|
| Will adding an allowlist host kill my session? | No — if the config has the two Claude mounts |
| Will a recreate lose my uncommitted work? | No — the workspace is a host mount, it is the same files |
| Will a resume bring my running process back? | No — every resume is a fresh boot |
| Will destroy lose my Claude conversation? | No — transcripts live on host mounts |
| Will destroy lose my shell history? | Yes — that volume goes |
| Can I hot-reload a network rule? | No. `rc up --replace` is the only path |
| Is `rc-mise-cache` safe to delete? | It is shared; every cage re-downloads its toolchains |

---

## Before any of the three, if you are unsure

```bash
rc doctor <cage>
```

names the config the cage launched from, its mounts, and its egress posture —
enough to answer "what will I lose?" before you find out.
