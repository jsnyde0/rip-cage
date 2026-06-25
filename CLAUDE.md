# Rip Cage — Agent Context

You're working on **rip-cage**, a Docker-based sandbox for running Claude Code agents with a safety stack (containment floor + composable command-guard recipes: DCG, ssh-bypass blocker) so they can operate with bypassPermissions mode without nuking anything. DCG and the ssh-bypass blocker are composable recipes (`examples/dcg/`, `examples/ssh-bypass/`) — not baked into the base image.

## Philosophy — read this before designing anything

The cage **limits blast radius**. It does not prevent all danger, and it is not trying to. See the [README](README.md) — running with `--dangerously-skip-permissions` is never safe; rip-cage doesn't change that.

What this means in practice when you propose changes:

- **Agent autonomy is the product.** The point of the cage is that a human can walk away and let the agent keep working. Any design that forces human intervention on a legitimate operation (credential prompts, TTY dialogs, interactive approvals, "please run this on the host") defeats the purpose.
- **Layers, not walls.** DCG (composable recipe), ssh-bypass blocker (composable recipe), filesystem sandbox, egress whitelist — each catches a class of accidents. None of them individually is a security boundary against a motivated attacker, and pretending they are leads to over-strict designs.
- **80/20, not 100/0.** The L7 egress firewall defaults to a host whitelist, but new cages ship in observe-mode so it learns real traffic before it blocks anything. Same principle everywhere else: block the obvious accident, don't gate the legitimate work.
- **"It's annoying" is a design signal.** If an agent hits something the cage blocks and the right human response is "just turn it off," the default is probably wrong. Revisit the decision.
- **rip-cage is a composable seam, not a bundler.** Per [ADR-005 D12](docs/decisions/ADR-005-ecosystem-tools.md), rc owns the composition *interfaces* (tool manifest, multiplexer provider contract, egress/mount declarations) and the safety floor — never specific optional tools. rc's code must never name, bundle, or "bless" an optional tool (no hardcoded multiplexer set, no built-in tool list); adding a tool — even a new multiplexer — is a manifest entry with zero rc edits. Defaults ship minimal; examples live *outside* the binary (`examples/`), never special-cased. **Convenience never earns a hardcoded exception in the seam** — if a tool feels like it should be on by default, it's either an opt-in example or genuinely *floor* (git/curl tier), never "blessed-optional." This is the principle agents keep drifting from (it's how herdr leaked into the default manifest); hold it.
- **Built for the agentic era — composition is the agent's job.** rip-cage is deterministic about what's **invariant** — the containment floor (what must hold no matter what's inside) and the mechanical seams (identical every run: manifest format, `rc build`, mount mechanics). It pushes to the **agent** what **varies by situation** — which tools, whether a guard at all, how the pieces wire together. Help the agent generously on the invariant/mechanical side: CLIs, scripts, skills, and legible `examples/` recipes *are* the job. The drift is the inverse — freezing the *varying* part (the composition, the wiring) into deterministic machinery. A `compose:` directive / installer / auto-wire / config-merge step is the classic shape, but judge by the principle ("am I automating something that's the agent's judgment?"), not by matching that list. This is the sibling of "composable seam, not a bundler" above — that one says don't bless/bundle a *tool*; this one says don't automate the *wiring*. Rationale: [ADR-005 D12](docs/decisions/ADR-005-ecosystem-tools.md) (agentic-composition premise).
- **The threat model includes prompt-injection.** Per [ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md), "accident" now also covers a non-adversarial agent following hostile instructions injected via fetched READMEs, web pages, MCP output, or workspace files — not just honest mistakes. The egress whitelist, DNS inspection, ssh destination-scoping, and workspace-trust validator are the layers that target it. A motivated *adversarial* agent remains explicitly out of scope.

Containment-flavored language ("the thing inside the cage is not you") has shown up in past ADRs and is a trap — it reads as an adversarial threat model rip-cage is not trying to meet. When in doubt, optimize for autonomous uninterrupted runs over theoretical blast-radius reduction.

## Architecture

```
Host (macOS/Linux)
├── rc                      CLI entrypoint (bash). Commands: build, init, up, ls, attach, exec, down, destroy, reload, allowlist, test, doctor, auth, config, schema, completions, setup
├── Dockerfile              Multi-stage: Go (beads) → Debian runtime (dcg un-baked per rip-cage-wlwc.10)
├── init-rip-cage.sh        Runs inside the container on start. Sets up auth, settings, hooks, git identity, beads
├── settings.json           Claude Code config — bypassPermissions, deny rules
├── hooks/
│   └── block-ssh-bypass.sh          Source for the ssh-bypass composable recipe (examples/ssh-bypass/).
├── examples/
│   ├── dcg/               Composable recipe: DCG destructive-command guard (not baked in base image).
│   └── ssh-bypass/        Composable recipe: ssh host-key-override blocker (not baked in base image).
├── tests/                  Test scripts (test-safety-stack.sh, test-rc-commands.sh, etc.)
└── zshrc                   Minimal zshrc for the container agent user
```

**Two usage paths:**
- `rc init` → VS Code "Reopen in Container" (generates `.devcontainer/devcontainer.json`)
- `rc up` → CLI/headless mode (creates container, runs init, attaches — behavior depends on `session.multiplexer` config: plain shell under `none` (default), tmux attach under `tmux`, herdr supervisor view under `herdr`)

Both paths mount the project directory as a bind mount at `/workspace` — file changes sync instantly, no git push needed.

> For installation, quickstart, auth, safety stack details, and full CLI reference, see [docs/reference/](docs/reference/).

## Auth flow (for contributors)

If you're modifying auth logic, the flow is:
1. `rc init`: keychain extraction happens in `initializeCommand` (runs on host)
2. `rc up`: keychain extraction happens in `cmd_up` before `docker run`
3. `init-rip-cage.sh`: reads the mounted `.credentials.json` (inside container, no keychain access)

See [docs/reference/auth.md](docs/reference/auth.md) for full details.

## Skills in Containers

Skills mounted from the host are discoverable inside containers via a Python MCP shim
(`skill-server.py`) registered as `mcpServers.meta-skill` in `settings.json`.
The shim implements the same `list`/`show`/`load` tools as the host `ms` binary.

- Skills that are broken symlinks inside the container (host-only paths) are skipped at startup
- Upgrade path: when `ms` publishes Linux binaries, swap `command`/`args` in `settings.json`
  and remove `skill-server.py`; server name `meta-skill` stays unchanged
- See: `history/2026-04-14-skills-in-containers-design.md` for full design rationale

## Key gotchas

- Docker creates parent dirs for bind mounts as root. That's why `init-rip-cage.sh` starts with `sudo chown agent:agent ~/.claude`.
- `.devcontainer/` and `.vscode/` are gitignored — they're generated per-project by `rc init`.
- The `container_name()` function in `rc` derives names from the last two path components. Collisions get a 4-char hash suffix.
- `sleep infinity` is the container entrypoint for CLI mode. The multiplexer (if configured) is started by `init-rip-cage.sh` at first attach, not the Dockerfile. With `session.multiplexer: none` (default), no multiplexer is started.

## When you need a new SSH host trust inside the cage

If you hit a wall like `Host key verification failed` for some host (e.g. a non-github mirror), the cage is enforcing `ssh.allowed_hosts` from `.rip-cage.yaml`. To unblock:

1. Edit `.rip-cage.yaml` in the workspace (it's writable inside the cage) to add the host under `ssh.allowed_hosts`.
2. Ask the human to run on the host: `rc reload <cage>` — this hot-reloads the allowlist without tearing down the running session or losing in-flight context (rip-cage-ocn / [ADR-022](docs/decisions/ADR-022-ssh-allowlist.md) D6).
3. Retry the failing operation. No restart, no reattach.

`rc reload` is host-side only and not on the cage's PATH by design — the human is the approval step. You cannot self-grant; surface the request and wait for the human to apply.

## Harness inventory

See [`.claude/harness.md`](.claude/harness.md) for the catalog of verification mechanisms in this repo (shell syntax checks, shellcheck, tiered test suites, `rc test` / `rc test --e2e` / `rc doctor`, egress probes, ADRs). Consult it when picking a feedback loop for a task.

## Testing changes

After modifying the Dockerfile or any file that gets COPY'd into the image:
```bash
./rc build
./rc up /path/to/test/project
./rc test <container-name>    # expect all checks PASS (count grows with new safety-stack additions)
```

For changes to `rc` itself, you can test without rebuilding the image.

## Roadmap & design docs

See [docs/ROADMAP.md](docs/ROADMAP.md) for the phased plan, design docs, and ADRs.

## Beads read-authority (don't trust `issues.jsonl` for live state)

`bd show` / `bd list` are the **authoritative** read — they hit the embedded Dolt store (`.beads/embeddeddolt/`, per `.beads/metadata.json`). `.beads/issues.jsonl` is a **lagging derived export**: it is NOT rewritten on `bd update`/`create`/`close`, so a direct file read can silently return stale bead state (this burned two fresh-context review rounds — rip-cage-u7f).

- **Reading a bead** (subagents, reviewers, hooks, humans): use `bd show <id>` / `bd show <id> --json`, never a `grep` of `issues.jsonl`. Subagent and reviewer briefs must pass `bd show` output (or instruct the agent to run `bd show`), not point at the file.
- **When a file reader genuinely needs current data**, flush it first: `bd export --all -o .beads/issues.jsonl` (writes to the file — `bd export` alone goes to stdout — and includes the `bd remember` memories, so it won't trip the shrink guard).
- Auto-export (`export.auto`) is intentionally **off** here: its scope excludes memories, so it shrink-guard-fails on every write against rip-cage's memory-bearing export. See `.beads/config.yaml` for the full rationale.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
