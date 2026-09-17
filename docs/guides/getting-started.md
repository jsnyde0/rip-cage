# Getting Started

Your first caged session, end to end. Assumes `rc` is installed, Docker is running, and msb is installed (see the [README](../../README.md#quick-start)).

There are three steps, and the first two happen once per project.

---

## 1. Build the image

```bash
rc build
```

This builds rip-cage's base image with `docker build`, then loads it into msb's image cache. Those are two separate stores, and **cages boot from msb's** — so `rc build`, not a bare `docker build`, is what makes a new image reach your cages.

If your project needs a tool the base image lacks, this is where a Dockerfile of your own comes in. Ask your agent for the [`cage-image`](../../.claude/skills/cage-image/SKILL.md) skill; it writes one that starts `FROM rip-cage:latest`, and then `rc build --file <path>` builds that instead.

## 2. Write the cage config

Every cage launches from one file, at `~/.config/rip-cage/projects/<cage>.yaml`. `rc up` refuses to launch without it — there is no implicit default, because what a cage mounts and what it can reach should be something you read before you run it.

Ask your agent for the [`cage-config`](../../.claude/skills/cage-config/SKILL.md) skill. It copies the annotated template, fills in your paths, and hands you a file to review. Four things are worth reading before you run it:

- **the mounts** — what of your machine this cage can see, and which lines are read-only;
- **the two session mounts** — `~/.claude/projects` and `~/.claude/sessions`. They are what makes a Claude conversation survive a cage recreate;
- **`secrets:`** — which credential may travel to which host;
- **`network.allow`** — everything the cage is allowed to reach. Everything else is denied.

Field-by-field reference: [config.md](../reference/config.md).

## 3. Run it

Start on a throwaway directory the first time. The agent cannot touch anything you care about, and you get to watch the cage behave before you trust it with real work:

```bash
mkdir -p ~/scratch/rc-trial
cd ~/scratch/rc-trial
git init
rc up .
```

Your shell prompt changes — you are inside the microVM now. Type `claude` (or `pi`) and let it work.

---

## What `rc up` just did

1. Found your Claude login in the macOS keychain, so the cage starts authenticated.
2. Read the shipped protected-paths list and refused — or covered — any credential location your config would have exposed.
3. Created a libkrun microVM from your image, with your project mounted at `/workspace`. **File changes sync both ways, live.** No git push, no rebuild.
4. Ran init inside the cage, which runs the floor probe before anything else.
5. Attached you to it.

## See the cage earning its keep

The cage's default posture is **deny everything outbound except the hosts your config names**. Ask the agent to fetch something you did not allowlist:

```
curl https://example.com
→ curl: (6) Could not resolve host: example.com
```

That is the egress wall, not a network problem. It fails in milliseconds rather than hanging.

The repair loop is short, and it is the point:

```bash
rc doctor scratch-rc-trial            # names the denied host
# add "example.com:tcp:443" under network.allow in the cage config
rc up --replace ~/scratch/rc-trial
```

The recreate keeps your host mounts and named volumes — **your Claude session resumes** — and loses only whatever the guest wrote to its own ephemeral filesystem.

If you composed a command guard into your image (`examples/dcg/` is one recipe), you can watch that fire too: a destructive command is refused, and chaining it behind a harmless one does not slip it past. A guard is something you compose, not something the base image bakes in.

## Prove the cage holds

```bash
rc test scratch-rc-trial
```

This runs against **your** image, not a reference image someone else built. The floor probe goes first. A check that depends on a recipe you did not compose reports `SKIP` with a reason rather than failing.

## The commands you'll actually use

| Action | Command |
|---|---|
| Start or resume a cage | `rc up <path>` |
| Recreate a running cage against the current config | `rc up --replace <path>` |
| Find out why something is blocked | `rc doctor <cage>` |
| Prove the cage holds | `rc test <cage>` |
| Refresh expired credentials | `rc auth refresh` |
| Remove a cage and its volumes | `rc destroy <cage>` |

That is the whole daily loop. To shell into a running cage, list what is running, or stop one, use msb directly — the [`cage-ops`](../../.claude/skills/cage-ops/SKILL.md) skill has the one-liners.

## Where to go next

- **[`cage-ops`](../../.claude/skills/cage-ops/SKILL.md)** — when something is blocked, broken, or will not start.
- **[Network egress](../reference/egress.md)** — the full deny → fix → relaunch loop, and the one failure class the fix-hint cannot see.
- **[Auth](../reference/auth.md)** — the two credential postures, and which one your cage is in.
- **[The worktree workflow](../../README.md#the-worktree-workflow)** — several caged agents at once, one per git worktree.
