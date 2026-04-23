# Rip Cage — Agent Context

You're working on **rip-cage**, a Docker-based sandbox for running Claude Code agents with a safety stack (DCG + compound command blocker + PreToolUse hooks) so they can operate with bypassPermissions mode without nuking anything.

## Philosophy — read this before designing anything

The cage **limits blast radius**. It does not prevent all danger, and it is not trying to. See the [README](README.md) — running with `--dangerously-skip-permissions` is never safe; rip-cage doesn't change that.

What this means in practice when you propose changes:

- **Agent autonomy is the product.** The point of the cage is that a human can walk away and let the agent keep working. Any design that forces human intervention on a legitimate operation (credential prompts, TTY dialogs, interactive approvals, "please run this on the host") defeats the purpose.
- **Layers, not walls.** DCG, compound blocker, filesystem sandbox, egress denylist, push-less defaults — each catches a class of accidents. None of them individually is a security boundary against a motivated attacker, and pretending they are leads to over-strict designs.
- **80/20, not 100/0.** The L7 egress firewall is a denylist of known-bad exfil hosts, not a whitelist of approved APIs. Same principle for everything else: block the obvious accident, don't gate the legitimate work.
- **"It's annoying" is a design signal.** If an agent hits something the cage blocks and the right human response is "just turn it off," the default is probably wrong. Revisit the decision.

Containment-flavored language ("the thing inside the cage is not you") has shown up in past ADRs and is a trap — it reads as an adversarial threat model rip-cage is not trying to meet. When in doubt, optimize for autonomous uninterrupted runs over theoretical blast-radius reduction.

## Architecture

```
Host (macOS/Linux)
├── rc                      CLI entrypoint (bash). All commands: build, init, up, ls, attach, down, destroy, test
├── Dockerfile              Multi-stage: Go (beads) → Rust (DCG) → Debian runtime
├── init-rip-cage.sh        Runs inside the container on start. Sets up auth, settings, hooks, git identity, beads
├── settings.json           Claude Code config — bypassPermissions, PreToolUse hooks
├── hooks/
│   └── block-compound-commands.sh   Denies &&, ;, || chains. Suggests splitting.
├── tests/                  Test scripts (test-safety-stack.sh, test-rc-commands.sh, etc.)
└── zshrc                   Minimal zshrc for the container agent user
```

**Two usage paths:**
- `rc init` → VS Code "Reopen in Container" (generates `.devcontainer/devcontainer.json`)
- `rc up` → CLI/headless mode (creates container, runs init, attaches tmux)

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
- `sleep infinity` is the container entrypoint for CLI mode — tmux is started by `init-rip-cage.sh`, not the Dockerfile.

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

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
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

## Session Completion

**When ending a work session**, complete the following steps:

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Commit locally** - Commit all changes to the local branch
5. **Push** - `git push` and `bd dolt push`. The cage forwards the host ssh-agent by default (ADR-017), so pushes work from inside the container. If `--no-forward-ssh` was passed at `rc up`, pushes will fail loudly — hand off to the human instead.
6. **Hand off summary** - Branch name, commits pushed, summary of work, anything still pending.
<!-- END BEADS INTEGRATION -->
