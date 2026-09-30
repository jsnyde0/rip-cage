# claude recipe — session isolation

Gives every `claude` invocation its own config directory (so parallel sessions
under different multiplexer panes never clobber each other's `.claude.json`),
and pre-accepts the bypass-permissions dialog the cage already declares as
policy.

Not floor, never on by default (ADR-005 D12 FIRM). rip-cage's own code names no
agent recipe; this directory is a recipe you compose, and nothing in `rc` knows
it exists. The `claude` binary itself ships in the base image (`npm install`) —
this recipe adds session isolation on top of it.

## What is in here

| file | what it is |
|---|---|
| `Dockerfile.snippet` | the lines to paste into your own Dockerfile |
| `boot-fragment.json` | the `tools[].launch` declaration, merged into the image's boot descriptor at build time |
| `claude-session-wrapper.sh` | the launch command: resolves `CLAUDE_CONFIG_DIR`, seeds the session dir, exec's the real binary |
| `cage-claude.md` | the cage-topology doc, surfaced via a reference in `~/.claude/CLAUDE.md` |

## Use it

1. Write your own Dockerfile outside every directory your cage config mounts —
   `rc build` refuses one inside a cage mount, fail-closed, no opt-out
   (ADR-031 D5(a)). `~/.config/rip-cage/images/` is a good home.

   ```dockerfile
   FROM ghcr.io/jsnyde0/rip-cage:latest
   # ...paste Dockerfile.snippet here...
   ```

   Copy `claude-session-wrapper.sh`, `cage-claude.md` and `boot-fragment.json`
   next to it — the `COPY` lines read from the build
   context, which is that Dockerfile's own directory.

2. Build and point your cage config's `image:` key at the result:

   ```bash
   RC_IMAGE=my-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
   ```

3. `rc up`. Every `claude` invocation now resolves through the session wrapper.

## How the launch wrapping works

The base image already moves the npm-installed `claude` binary to
`/usr/local/lib/rip-cage/bin/claude-real` and puts its own generic per-tool
launch wrapper at the original PATH name (ADR-031 D4). That wrapper reads the
boot descriptor's `tools[]` entry named `claude`: if it declares a `launch`
command, the wrapper execs that instead of the real binary directly.
`boot-fragment.json` in this recipe is exactly that declaration — it points
`launch` at `claude-session-wrapper.sh`, which does its own resolution and
seeding work and then execs `claude-real` itself.

Resolution is by **absolute path**, never PATH order — an extension that
prepends to PATH must not be able to shadow the real binary out from under the
wrapper (measured hazard, `rip-cage-ely4.16`). Do not add your own `claude`
entry to PATH ahead of this one.

## Session-dir resolution and seeding (carried over verbatim — hard-won)

- **Resolution precedence:** an explicit `CLAUDE_CONFIG_DIR` wins (the base image's own default, `/home/agent/.claude` or `$HOME/.claude`, does not count as explicit); else inside
  tmux the session name derives the handle; else inside herdr `$HERDR_SESSION`
  derives it; else it falls back to `~/.claude-sessions/default` (headless / no
  multiplexer). Multiplexer-agnostic by construction — same wrapper regardless
  of which multiplexer recipe (if any) is composed alongside it.
- **Seeding is idempotent:** a session dir with `.claude.json` already present
  is left alone. A fresh one gets three classes of seed: symlinked read-mostly
  inputs from `~/.claude` (settings, skills, commands, CLAUDE.md), a *copy* of
  `~/.claude.json` (carries `mcpServers`/auth/onboarding — a symlink here would
  make every session share one mutable file), and its own fresh writable dirs
  (`backups/`, etc).
- **The seed source is a stable init-time snapshot** (`~/.claude/.claude.json.seed`,
  taken by init before the wrapper's first invocation), not the live virtiofs
  mount — a host-side atomic rewrite of `~/.claude.json` breaks the mount
  handle the container holds, and reading through a broken handle would seed an
  empty config and silently drop MCP servers.
- **The bypass-permissions dialog is pre-accepted** in the per-session (writable)
  copy of `.claude.json`, and `--dangerously-skip-permissions` is prepended at
  argv level if absent. Both are *restating* the cage's already-declared policy
  (`permissions.defaultMode=bypassPermissions` in `cage/agent/settings.json`),
  not a new grant — the host `~/.claude.json` mount is read-only, so an
  in-session accept can never persist there, and the dialog would otherwise
  block every restored/spawned pane on every cold boot.

## Destructive-command guard

This recipe wires no guard hook. A guard recipe ships its own Claude Code hook
beside the binary that hook calls — [`examples/dcg/`](../dcg/) does, through
Claude Code's root-owned `managed-settings.json`. Compose it too if you want
destructive Bash commands blocked. Without it, Bash calls run unguarded and
print no hook error.

## Headless `claude -p` from the host

Run it with stdin closed and a bound of minutes, not seconds:

```bash
msb exec <cage> -- bash -lc 'claude -p "<prompt>" --output-format text' < /dev/null
```

- **Stdin closed is required.** When stdin is a pipe or socket (an agent's
  shell, a harness), msb waits for it to reach end-of-file before it starts
  the command (cage-ops step 1). If the caller never closes it, a timeout
  reports exit 124 with empty output.
- **Give it ten minutes.** In one cage (2 vCPUs, host at 6% free memory),
  the same one-word `claude -p` took 6 s to 8.3 min over two hours, and every
  run returned `ok` when given the time (rip-cage-2dyy). That cage also held
  two resident interactive claude sessions; while "idle", they sampled at up to
  97% and 64% of the two vCPUs. A plain CPU loop in the cage varied 4x within
  one minute. Load inside the cage and on the host is most of the spread. A
  30–60 s timeout will kill runs that were about to succeed — and that also
  shows as exit 124 with empty output. So with stdin already closed, a 124
  means the bound was too short.
- **The workspace's SessionStart hooks run first.** Claude runs them before
  the first API call, even under `-p`. A hook running `bd prime` took about
  20 s per call in that cage, and there were two. A run that needs no hook
  context can skip them: add `--settings '{"disableAllHooks":true}'`.

`tests/test-claude-headless-live.sh` checks both halves against a running
cage: `RC_HEADLESS_CAGE=<cage> bash tests/test-claude-headless-live.sh`.

## Swapping in a different launch behavior

Nothing here is claude-specific except the wrapper's own logic. A different
agent recipe declares its own `tools[].launch` for its own tool name — `rc`
dispatches on whatever the descriptor declares, and needs no edit either way.
That is the seam ADR-005 D12 protects.
