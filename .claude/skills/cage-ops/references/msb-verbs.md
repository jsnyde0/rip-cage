# Reference: the msb commands you actually use

`rc` kept six verbs. Everything else is a plain `msb` command. These are the
handful that come up daily, with what each one really does — the failure modes
are what make them worth a page rather than a list.

For msb's full surface, read the maintained skill at
`~/code/personal/superradcompany-skills/microsandbox/SKILL.md` and its
`references/cli-reference.md`. Read it in place; do not copy it here.

---

## `msb list` — what exists

```bash
msb list
msb list --format json
```

Shows every sandbox, rc-managed or not. `rc` marks its own with an
`rc.source.path` label, which is how `rc` tells "a cage I made" from "some other
sandbox on this machine".

`No sandboxes found` means exactly that. A cage you stopped still appears —
stopped is a state, not a deletion.

---

## `msb exec <cage> -- <cmd>` — run something inside

```bash
msb exec <cage> -- zsh                  # interactive shell
msb exec <cage> -- ls /workspace        # one command
msb exec -e FOO=bar <cage> -- env       # with an environment variable
msb exec <cage> -- tee /tmp/f < local   # stdin is forwarded
```

Runs as the sandbox's default user — `agent` — not root. There is no
`msb cp`: forwarding stdin through `tee` is how a file gets in.

Everything after `--` goes to the guest verbatim. Shell syntax needs a shell:
`msb exec <cage> -- sh -c 'a && b'`.

---

## `msb stop <cage>` — stop, keeping state

Graceful stop. The workspace, the mounts and the named volumes are untouched;
the cage can be picked back up with `rc up <project>`.

**Processes do not survive.** Every resume is a fresh kernel boot, so a stopped
cage is not a paused container — whatever was running is gone, and `rc` re-runs
init on the way back up.

---

## `msb logs <cage> --source system --json` — the cage's own trace log

This is where egress denials appear:

```bash
msb logs <cage> --source system --json | grep 'denied by network policy'
```

Each match reads `DNS query denied by network policy domain=<host>`. That
string is what `rc doctor` mines into its fix-hint, so reading the log yourself
gets you the same answer one step earlier.

**Only DNS-stage denials are logged.** A denied IP, or a denied port on an
allowed host, fails at TCP connect and writes nothing at any verbosity. An
empty grep is not evidence that nothing was blocked.

---

## `msb inspect <cage> --format json` — the ground truth about a cage

```bash
msb inspect <cage> --format json | jq '.config.mounts'
msb inspect <cage> --format json | jq '.config.labels'
msb inspect <cage> --format json | jq '.config.network.policy'
```

Answers the questions the config file only claims to answer: which mounts this
RUNNING cage actually got, at which mode, and which network rules it is
enforcing.

A bind mount's mode is `options.readonly`, a boolean — not a `:ro` suffix on a
string. `.config.labels` carries `rc`'s own labels, including `rc.cage-conf`
(which config file this cage launched from) and `rc.source.path`.

This is the tool for "the config says X, is the cage actually X?".

---

## `msb volume list` / `msb volume remove <name>`

Named volumes are separate objects with their own lifecycle. **`msb remove`
does not delete them** — that is why `rc destroy` removes the sandbox and then
deletes `rc-state-<cage>` and `rc-history-<cage>` explicitly.

`rc-mise-cache` is deliberately shared across cages; do not delete it to clean
up after one.

---

## `msb image` — the other half of the image story

The image is `docker build`-produced and loaded into msb's own cache. The two
stores can drift, and `rc` warns when they do:

```bash
docker save rip-cage:latest | msb load --tag rip-cage:latest
```

resyncs, and so does re-running `rc build`. The two stores never report equal
image digests even from the same build — `rc` compares layer content instead,
so ignore a digest difference and trust the warning.

---

## Which verb for which retired `rc` command

The full table is in the skill body. The short version:

| Old | New |
|---|---|
| `rc ls` | `msb list` |
| `rc exec` | `msb exec` |
| `rc attach` | `msb exec <cage> -- zsh`, or `rc up <path>` |
| `rc down` | `msb stop` |
| `rc reload` | `rc up --replace` |
| `rc allowlist` / `rc config` / `rc schema` | edit the cage config file |
