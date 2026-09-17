---
name: cage-ops
description: "Run and troubleshoot a live rip-cage cage: start, resume, recreate, shell in, read its logs, fix a denied egress host, fix auth. Use when a caged agent reports something blocked or failing — 'pip is failing', 'git push hangs', 'curl gets connection refused', 'the agent says it cannot reach X' — when a cage will not start or resume, when credentials expired, or when someone asks for an rc verb that no longer exists (rc ls, rc exec, rc down, rc attach, rc reload, rc allowlist, rc config). Do NOT use for writing the config file (that is cage-config) or building the image (that is cage-image)."
---

# cage-ops

Invoke this when a cage exists and something about running it needs doing or
fixing: starting and resuming it, getting a shell in it, reading why a request
failed, adding a denied host and getting back to work, refreshing expired
credentials, or answering "what replaced `rc <verb>`?". You act on the HOST —
a caged agent cannot do any of this for itself, and the parts it cannot do are
the point, not an obstacle.

## The six verbs, and everything else

`rc` dispatches exactly six verbs: `build`, `up`, `auth`, `doctor`, `test`,
`destroy`. Everything else a cage needs is a plain `msb` command or a file
edit. `rc --help` is the current surface; the successor table below covers
every verb that used to exist.

```bash
rc up <project>            # start, or resume, and attach
rc up --replace <project>  # graceful-stop and recreate against the current config
rc doctor <cage>           # labels + live probes, including the egress fix-hint
rc destroy <cage>          # remove the cage AND its named volumes
msb list                   # what exists
msb exec <cage> -- zsh     # shell in
msb stop <cage>            # stop, keeping state
msb logs <cage> --source system --json   # the cage's own trace log
```

**`rc destroy` takes the cage by name.** Given nothing — or a name it cannot
resolve — it refuses with exit 2 and lists the cages it did not touch. It will
not pick one for you. Passing an empty string from a failed lookup is how a
daily cage got deleted once; the refusal is that incident's fix.

## The loop that comes up most: something is blocked

An agent in the cage reports that a fetch, install, clone or API call fails.
Almost always this is the egress allowlist. The cage is **default-deny**: only
hosts listed in its config's `network.allow` leave it.

**Read the trace log, or let `rc doctor` read it for you:**

```bash
rc doctor <cage>
```

It mines the sandbox's own log for lines of the form

```
DNS query denied by network policy domain=<host>
```

and prints, per denied host, the exact line to add and the config file to add
it to:

```
<host> (add "<host>:tcp:443" under network.allow)  [config: ~/.config/rip-cage/projects/<cage>.yaml — then: rc up --replace]
```

Reading the raw log yourself is the same information one step earlier:

```bash
msb logs <cage> --source system --json | grep 'denied by network policy'
```

**Then, on the host:**

1. Edit that config file — add `- "<host>:tcp:443"` under `network.allow`.
   The line names the port on purpose; a bare host opens every port and
   `host:443` without the protocol is rejected outright. Writing the file is
   the **cage-config** skill.
2. `rc up --replace <project>` — a cold recreate. msb has no live-mutation
   path for network rules, so the cage is stopped, removed and recreated.
3. Retry the operation.

**The session survives that recreate** as long as the config mounts
`~/.claude/projects` and `~/.claude/sessions`, which the shipped template does.
Named volumes survive too. Only the guest's own scratch is lost — an ad-hoc
install you did at runtime, nothing else.

Worked end to end: [`recipes/denied-host.md`](recipes/denied-host.md).

## What a denial looks like, and what leaves no trace

- **A denied domain name** fails DNS resolution client-side, immediately. This
  is the case that gets logged, and therefore the only case `rc doctor` can
  turn into a fix-hint.
- **A denied IP address** fails at TCP connect within a couple of milliseconds.
  **Nothing is logged, at any verbosity.**
- **A denied PORT on an already-allowed host** is the same silent case. If a
  host IS on the allowlist and still fails, check the port in its entry before
  anything else.

So `none observed` from `rc doctor` means "no DNS-stage denial has been
logged", never "nothing has been blocked".

(Measured on msb 0.6.18. On msb before 0.6.10 a denied connect was
fake-accepted and hung delivering zero bytes — if a cage HANGS rather than
failing fast, check the msb version.)

## Deleted-verb successor table

Every verb `rc` no longer dispatches, and what to run instead. All of them
print plain usage and exit 1.

| deleted verb            | successor                                                      |
|-------------------------|----------------------------------------------------------------|
| rc ls                   | msb list                                                        |
| rc attach [name]        | msb exec <cage> -- zsh  (or `rc up <path>` from a terminal, which attaches through the cage's multiplexer hook) |
| rc exec <cage> -- <cmd> | msb exec <cage> -- <cmd>                                        |
| rc down [name]          | msb stop <cage>                                                 |
| rc reload [name]        | rc up --replace <path>  (folded into `rc up`: a STOPPED cage converges on a plain `rc up`; `--replace` is the explicit recreate and now covers a stopped cage too) |
| rc allowlist add <host> | edit the cage config file — add a line under `network.allow` — then `rc up --replace <path>` |
| rc config show/get/set  | edit the cage config file (~/.config/rip-cage/projects/<cage>.yaml) |
| rc schema               | edit the cage config file — there is no schema to print (retired with the config layer, ely4.9) |
| rc setup                | no successor — it wrote a shell-integration line for a completion surface that no longer exists |
| rc completions <shell>  | no successor — six memorable verbs do not earn a completion surface to keep honest |
| rc manifest reconcile   | edit the file; retired with the manifest (ADR-031 D4)           |
| rc install              | retired with the manifest (ADR-031 D4)                          |
| rc generate-dockerfile  | retired with the manifest (ADR-031 D4) — once you extend the published base image with your own Dockerfile there is no composed artifact left to print |

Two behaviours moved rather than vanished, and both are named here because a
reader looking for the retired verb will look for them:

- **`rc reload`'s transcript-persistence guard** now WARNS on every recreate
  path (`--replace` and the stopped-cage converge) instead of REFUSING pending
  `--allow-transcript-loss`. That flag retired with the verb: a flag an
  operator must pass to complete an operation they already asked for by name is
  the human-in-the-loop shape this CLI is shedding.
- **`rc reload`'s fix-hint** (recently-denied domains mined from the trace log,
  and the separate secret-violation warning) did NOT move to `rc up`. Its home
  is `rc doctor`.

## Start, resume, recreate — which one you are doing

| You run | Cage state | What happens |
|---|---|---|
| `rc up <project>` | none | created from the config, init runs, attach |
| `rc up <project>` | stopped, config unchanged | resumed |
| `rc up <project>` | stopped, config changed | converged — recreated against the new config |
| `rc up <project>` | running | attach; **never** implicitly recreated |
| `rc up --replace <project>` | running or stopped | graceful stop, remove, recreate |
| `rc up --no-reload <project>` | stopped | resumed as-is, config change ignored |

**Every resume is a fresh kernel boot.** Processes die on stop; `rc` re-runs
init and re-registers multiplexer state on each resume. A stopped cage is not
a paused container.

## Auth

```bash
rc auth refresh
```

On macOS, re-extracts Claude credentials from the keychain; running cages pick
the change up on the next API call. On Linux there is no keychain — update
`~/.claude/.credentials.json` directly and the bind mount carries it straight
through.

`rc up` warns before launch when the token is expired or expiring within ten
minutes. Full diagnosis: [`recipes/auth-trouble.md`](recipes/auth-trouble.md).

A cage whose config uses a `secrets:` entry holds only the placeholder
`$MSB_<NAME>`, never the token. "The token is not in the cage" is the posture,
not a bug to fix.

## Recipes

- [`recipes/denied-host.md`](recipes/denied-host.md) — blocked request → fix
  → back to work. The most common thing this skill is for.
- [`recipes/cage-wont-start.md`](recipes/cage-wont-start.md) — `rc up` fails
  or refuses: reading which layer said no.
- [`recipes/auth-trouble.md`](recipes/auth-trouble.md) — expired, missing, or
  wrong-account credentials.

## References

- [`references/msb-verbs.md`](references/msb-verbs.md) — the msb commands that
  replaced the deleted verbs, with what each actually does.
- [`references/what-survives.md`](references/what-survives.md) — recreate,
  resume and destroy, and what each one costs.

## microsandbox itself

`rc` is a thin wrapper; the runtime is microsandbox. For msb's own surface
beyond the handful of commands here, read the maintained skill at
`~/code/personal/superradcompany-skills/microsandbox/SKILL.md` (its
`references/cli-reference.md` is the full verb list). **Read it in place** — a
copy in this repo would drift, which is what happened to the copy this skill
replaced.

## If you are INSIDE a cage reading this

You cannot fix an egress denial yourself, and that is deliberate. The config is
read-only to you and `rc` is not on your PATH as a host tool.

**Say this, in prose, to the human or the host-side agent:**

> Add `<host>` to `network.allow` in the cage config, then `rc up --replace`.

Then wait. Do not edit `.rip-cage.yaml` or any config you can see from inside.
The human is the approval step; that is the whole design.

## Done condition — report this

For whatever you did, state the outcome AND the command that showed it:

1. **The cage's state now** — `msb list`, naming the cage.
2. **The specific thing that was failing now works** — the actual retried
   command and its output, not "should work now".
3. **If you changed the config:** which file, which line, and that
   `rc up --replace` completed.
4. **If a recreate happened:** that the session came back (the agent resumed
   its conversation), or explicitly that it did not and why.

`rc doctor <cage>` is the one-command summary for points 1 and 3. Never report
a fix you have not re-run.
