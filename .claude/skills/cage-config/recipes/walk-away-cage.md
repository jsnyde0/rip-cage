# Recipe: a config for an agent you walk away from

Use this when the point is to start an agent and leave — hours, overnight — and
come back to finished work rather than to a prompt waiting for an answer.

This is a **delta on the shipped template**, not a second template. Write the
template first ([`first-cage.md`](first-cage.md)), then apply these four
changes. Each one removes a way the run can stall.

---

## 1. Egress: add what the work needs, before it starts

A denied host does not queue or retry. It fails immediately — a denied name
fails DNS resolution client-side, a denied IP fails at TCP connect within a
couple of milliseconds — and the agent sits there having hit a wall it cannot
open, because the config is host-side and read-only to it.

So spend two minutes up front. Ask what this run will actually reach:

- the model API and your git forge — already in the template
- the registries for THIS project's language (npm, PyPI, crates.io, proxy.golang.org)
- documentation and API hosts the task names
- your issue tracker's sync endpoint

Each as `"<host>:tcp:443"`. Over-listing costs nothing you care about; a missing
host costs the whole unattended window. See
[`../references/allowlist.md`](../references/allowlist.md).

*Done when:* you can name, for each thing the task will fetch, the line that
lets it.

---

## 2. Session mounts: make a recreate survivable

You will discover a missing host mid-run and add it, which recreates the cage.
Without the two Claude session mounts, the recreate takes the session with it
and the walk-away is over.

Keep both lines from the template
(`~/.claude/projects`, `~/.claude/sessions`), and keep the named volumes. See
[`../references/mount-set.md`](../references/mount-set.md) for what each buys.

*Done when:* both mount lines and the `rc-state-*` / `rc-history-*` volumes are
in the file.

---

## 3. Resources: size it for the work, not for the default

`cpus: 2` and `memory: 4G` are a starting point. A long unattended build, a
test suite, or a database in the cage wants more. A cage that gets OOM-killed
at hour three is the same lost window as a denied host.

*Done when:* the numbers reflect the heaviest thing this run does, not the
template's default.

---

## 4. Credentials: the cage holds a placeholder, not a token

Keep the `secrets:` entry with **no `value:`**. msb injects the real value on
the wire toward the hosts you named; the guest holds only `$MSB_<NAME>`. An
unattended agent that follows injected instructions cannot exfiltrate a token
it never had.

Put the real value host-side, once:

```bash
mkdir -p ~/.config/rip-cage/secrets
chmod 700 ~/.config/rip-cage/secrets
# write the value into ~/.config/rip-cage/secrets/<NAME>, mode 600
```

`rc` reads it there and bridges it to the host variable msb expects.

*Done when:* `rc up --dry-run <project>` exits 0 and no `value:` appears
anywhere in the config.

---

## What this recipe deliberately does not do

- **No guard is configured here.** A command guard is baked into the IMAGE, not
  declared in this file — `cage-image`, and `examples/dcg/`.
- **No multiplexer is configured here.** Same: the image declares it, via the
  boot descriptor.
- **No `network.policy` other than `none`.** `rc up` refuses anything else.
  Default-deny is the floor, not a setting.

---

## Before you walk away

```bash
rc doctor <cage>
```

Read the egress posture line. `none observed` under denials means nothing has
been blocked yet — it is not a promise that nothing will be. That is what step
1 was for.
