# Rip Cage — Agent Context

You're working on **rip-cage**, a microsandbox (msb, libkrun microVM)-isolated sandbox for running Claude Code agents with a safety stack (the msb host/VM boundary + default-deny egress/DNS + `--secret` credential non-possession, plus the composable command-guard recipe DCG) so they can operate with bypassPermissions mode without nuking anything ([ADR-029](docs/decisions/ADR-029-msb-migration.md)). The cage image is still built from an OCI Dockerfile (`cage/Dockerfile`, via `docker build`) but *run* by msb, not `docker run`/`docker exec` — there is no Docker-runtime containment boundary anymore. DCG is a composable recipe (`examples/dcg/`) — not baked into the base image. (The former ssh-bypass command-guard sibling and its ssh cluster are retired — see [ADR-029](docs/decisions/ADR-029-msb-migration.md) D3; `block-ssh-bypass.sh` / `examples/ssh-bypass/` no longer exist.)

## Philosophy — read this before designing anything

The cage **limits blast radius**. It does not prevent all danger, and it is not trying to. See the [README](README.md) — running with `--dangerously-skip-permissions` is never safe; rip-cage doesn't change that.

What this means in practice when you propose changes:

- **Agent autonomy is the product.** The point of the cage is that a human can walk away and let the agent keep working. Any design that forces human intervention on a legitimate operation (credential prompts, TTY dialogs, interactive approvals, "please run this on the host") defeats the purpose.
- **Layers, not walls.** DCG (composable recipe), the msb microVM boundary, msb default-deny egress/DNS — each catches a class of accidents. None of them individually is a security boundary against a motivated attacker, and pretending they are leads to over-strict designs.
- **80/20, not 100/0.** Egress defaults to a curated host allowlist ([ADR-029](docs/decisions/ADR-029-msb-migration.md) D4) — msb logs nothing for allowed traffic, so pre-cutover observe-mode is retired; a fast deny→fix→reload repair loop (`rc doctor`/`rc reload` surface a fix-hint from the denial trace log) replaces it. Same principle everywhere else: block the obvious accident, don't gate the legitimate work.
- **"It's annoying" is a design signal.** If an agent hits something the cage blocks and the right human response is "just turn it off," the default is probably wrong. Revisit the decision.
- **rip-cage is a composable seam, not a bundler.** Per [ADR-005 D12](docs/decisions/ADR-005-ecosystem-tools.md), rc owns the composition *interfaces* (tool manifest, multiplexer provider contract, egress/mount declarations) and the safety floor — never specific optional tools. rc's code must never name, bundle, or "bless" an optional tool (no hardcoded multiplexer set, no built-in tool list); adding a tool — even a new multiplexer — is a manifest entry with zero rc edits. Defaults ship minimal; examples live *outside* the binary (`examples/`), never special-cased. **Convenience never earns a hardcoded exception in the seam** — if a tool feels like it should be on by default, it's either an opt-in example or genuinely *floor* (git/curl tier), never "blessed-optional." This is the principle agents keep drifting from (it's how herdr leaked into the default manifest); hold it.
- **Built for the agentic era — composition is the agent's job.** rip-cage is deterministic about what's **invariant** — the containment floor (what must hold no matter what's inside) and the mechanical seams (identical every run: manifest format, `rc build`, mount mechanics). It pushes to the **agent** what **varies by situation** — which tools, whether a guard at all, how the pieces wire together. Help the agent generously on the invariant/mechanical side: CLIs, scripts, skills, and legible `examples/` recipes *are* the job. The drift is the inverse — freezing the *varying* part (the composition, the wiring) into deterministic machinery. A `compose:` directive / installer / auto-wire / config-merge step is the classic shape, but judge by the principle ("am I automating something that's the agent's judgment?"), not by matching that list. This is the sibling of "composable seam, not a bundler" above — that one says don't bless/bundle a *tool*; this one says don't automate the *wiring*. Rationale: [ADR-005 D12](docs/decisions/ADR-005-ecosystem-tools.md) (agentic-composition premise).
- **The threat model includes prompt-injection.** Per [ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md), "accident" now also covers a non-adversarial agent following hostile instructions injected via fetched READMEs, web pages, MCP output, or workspace files — not just honest mistakes. The egress allowlist, msb DNS default-deny, and the workspace-trust validator are the layers that target it. A motivated *adversarial* agent remains explicitly out of scope.

Containment-flavored language ("the thing inside the cage is not you") has shown up in past ADRs and is a trap — it reads as an adversarial threat model rip-cage is not trying to meet. When in doubt, optimize for autonomous uninterrupted runs over theoretical blast-radius reduction.

## Architecture

```
Host (macOS/Linux)
├── rc                      CLI entrypoint (bash), sourcing cli/*.sh + cli/lib/*.sh. Commands: build, up, ls, attach, exec, down, destroy, reload, allowlist, test, doctor, auth, config, schema, completions, setup
├── cage/Dockerfile         Multi-stage: Go (beads) → Debian runtime, still built via `docker build` (msb runs the OCI image; Docker is a build-time tool only, not the runtime boundary)
├── cage/init/init-rip-cage.sh   Runs inside the sandbox on start. Sets up auth, settings, git identity, beads
├── cage/agent/settings.json     Claude Code config — bypassPermissions, deny rules
├── examples/
│   └── dcg/               Composable recipe: DCG destructive-command guard (not baked in base image).
├── tests/                  Test scripts (test-safety-stack.sh, test-rc-commands.sh, test-msb-*-effect-probes.sh, etc.)
└── cage/agent/zshrc        Minimal zshrc for the sandbox agent user
```

**Usage:** `rc up` — CLI/headless mode (creates the msb sandbox, runs init, attaches — behavior depends on `session.multiplexer` config: plain shell under `none` (default), tmux attach under `tmux`, herdr supervisor view under `herdr`). The project directory is bind-mounted at `/workspace` — file changes sync instantly, no git push needed.

> For installation, quickstart, auth, safety stack details, and full CLI reference, see [docs/reference/](docs/reference/). For the composable seams catalog (how to add tools, guards, multiplexers, mediators, and launch composition), see **[docs/reference/README.md](docs/reference/README.md)**.

## Auth flow (for contributors)

If you're modifying auth logic, the flow is:
1. `rc up`: keychain extraction happens in `cmd_up` before the msb sandbox is created (`rip-cage-rj68` — rewritten off `docker run` onto msb)
2. `init-rip-cage.sh`: reads the mounted `.credentials.json` (inside the sandbox, no keychain access)

See [docs/reference/auth.md](docs/reference/auth.md) for full details.

## Skills in Containers

Skills mounted from the host are discoverable inside containers via a Python MCP shim
(`skill-server.py`) registered as `mcpServers.meta-skill` in `settings.json`.
The shim implements the same `list`/`show`/`load` tools as the host `ms` binary.

- Skills that are broken symlinks inside the container (host-only paths) are skipped at startup
- **Skill-source symlinks (projection contract, rip-cage-1pgp.1):** rc's floor auto-mounts each
  skill-symlink target's parent dir `ro` at its **host-absolute** path (`_collect_symlink_parents`,
  rc:939-975) — that fixes **absolute** symlinks. **Relative** symlinks (e.g.
  `../../code/personal/dotpi/agent/skills/<name>`) resolve against the cage home instead
  (`/home/agent/code/...` from `~/.rc-context/skills`, same 2-level depth as `~/.claude/skills`),
  so they need the operator to compose a `ro` mount of the skills repo at that cage-side
  resolution path (a mounts-only TOOL entry in `tools.yaml` — composition, never an rc-blessed
  path, ADR-005 D12). Contract: cage-resolvable mount, not resolve+copy at init — host live-edits
  stay visible in cages. Mounts are runtime `-v` args: existing cages gain it on destroy+recreate.
- Upgrade path: when `ms` publishes Linux binaries, swap `command`/`args` in `settings.json`
  and remove `skill-server.py`; server name `meta-skill` stays unchanged
- See: `history/2026-04-14-skills-in-containers-design.md` for full design rationale

## Key gotchas

- Bind/virtiofs mounts get their parent dirs created as root. That's why `init-rip-cage.sh` starts with `sudo chown agent:agent ~/.claude`.
- `.devcontainer/` and `.vscode/` are gitignored (legacy; the VS Code devcontainer path was removed in rip-cage-kt25).
- The `container_name()` function (`cli/lib/container.sh`) derives sandbox names from the last two path components. Collisions get a 4-char hash suffix.
- Every sandbox resume is a fresh kernel boot under msb (processes die between stop/start, unlike a paused Docker container) — `rc` re-runs init and re-registers cockpit/multiplexer state on each resume (`rip-cage-1ujn`). With `session.multiplexer: none` (default), no multiplexer is started.

## When you need a new host allowed for egress inside the cage

Cages run on microsandbox (msb): egress is **default-deny** at the VM boundary, plus a curated default allowlist (`api.anthropic.com`, `github.com`, package registries, …) declared in `.rip-cage.yaml` under `network.allowed_hosts` ([ADR-029](docs/decisions/ADR-029-msb-migration.md) D2/D4). Git authenticates over HTTPS with a per-cage token injected by msb `--secret` ([ADR-029](docs/decisions/ADR-029-msb-migration.md) D3) — there is no ssh cluster anymore (ADR-017/018/020/022's mechanisms are retired; `block-ssh-bypass.sh` and `examples/ssh-bypass/` are deleted).

If you hit a denied-host wall (a request that hangs/fails against a host not on the allowlist — msb fake-accepts the TCP connect and delivers zero bytes, or the DNS query is denied and logged), that's the egress firewall, not an ssh trust gap:

1. **Surface the request in prose** — e.g. "please add `<host>` to `.rip-cage.yaml` under `network.allowed_hosts`". Do NOT attempt to edit `.rip-cage.yaml` directly inside the cage.
2. The human (or a host-side assistant they relay to) edits `.rip-cage.yaml` on the host to add the host under `network.allowed_hosts` (or runs `rc allowlist add <host> --cage <name>`, which does both the edit and step 3). `rc doctor <cage>` / the reload dry-run surface any recently-denied domains mined from the sandbox's trace log as a fix-hint, so the human doesn't have to guess the exact hostname.
3. The human runs on the host: `rc reload <cage>` — **this is a COLD-RECREATE, not a hot-reload** (`rip-cage-rj68` / [ADR-029](docs/decisions/ADR-029-msb-migration.md) D4, [ADR-022](docs/decisions/ADR-022-ssh-allowlist.md) D6's retirement note): msb's net rules have no live-mutation path on a running sandbox, so `rc reload` runs graceful-stop → remove → recreate against the now-current config. **Survives the recreate:** host mounts (the workspace, `~/.claude/{projects,sessions}` — your Claude session **resumes**, it is not lost) and named volumes (`rc-state-*`, `rc-history-*`, `rc-mise-cache`). **Lost:** only the guest's own ephemeral rootfs overlay scratch (e.g. an ad-hoc `apt-get install` you ran at runtime that wasn't baked into the image or captured by a mount) — a narrow, documented tradeoff, not a session-continuity loss.
4. Retry the failing operation after the cage comes back up (the multiplexer/cockpit state re-registers automatically on every resume).

**Why:** `.rip-cage.yaml` is **read-only inside the cage by default** ([ADR-021 D7](docs/decisions/ADR-021-layered-rip-cage-config.md) — `mounts.config_mode: ro`). This prevents a prompt-injected agent from burying a containment-weakening line in an otherwise-legitimate config edit. `rc reload` is host-side only and not on the cage's PATH — the human is the approval step. You cannot self-grant; surface the request and wait for the human to apply.

## Beads over the msb virtiofs mount — interim single-writer discipline

While a cage is up read-write on a repo, **bd writes should happen from exactly one side at a time** — in practice, let the in-cage agent do its own bookkeeping and have the host orchestrator batch writes for cage-idle windows (or relay through the in-cage agent) rather than both sides writing concurrently. This is **convention-enforced guidance, not a code-level lock**: msb virtiofs does not propagate `flock` across the guest/host boundary in either direction (version-independent — `rip-cage-9iab` Q2), so a genuine concurrent host+guest write race remains physically possible if this discipline is violated ([ADR-029](docs/decisions/ADR-029-msb-migration.md) D7, FLEXIBLE — interim posture, not a solved problem). Note this is not a msb regression: today's pre-cutover Docker/OrbStack bind-mount path doesn't propagate flock either (`rip-cage-606c` A1) — the race predates the migration.

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

## Releasing rip-cage

Cutting a release (tag → multi-arch GHCR publish → Homebrew formula pin) has rip-cage-specific steps the global `/release` skill does not know — GHCR visibility flip, `scripts/update-formula-sha.sh`, the two-repo tap sync, the pre-tag **full host suite** gate, and the formula `brew fetch` verification. The single source of truth is **[docs/reference/release-ceremony.md](docs/reference/release-ceremony.md)** — follow it step by step when tagging a version.

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
