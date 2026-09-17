# Rip Cage — Agent Context

You're working on **rip-cage**, an opinionated distribution of [microsandbox](https://github.com/microsandbox/microsandbox) (msb, libkrun microVM) for running Claude Code and pi with permissions off: a curated agent image, one native msb config per project, a six-verb launcher, three skills, and a suite that proves the cage holds ([ADR-031](docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md)).

msb is the isolation — the microVM boundary, default-deny egress and DNS, `--secret` credential non-possession, read-only mounts. rip-cage never reimplements those and always credits them. The image is still built with `docker build`, but msb runs it; Docker is a build-time tool, not a containment boundary.

## Philosophy — read this before designing anything

The cage **limits blast radius**. It does not prevent all danger, and it is not trying to. Running with `--dangerously-skip-permissions` is never safe; rip-cage doesn't change that ([README](README.md), [ADR-009](docs/decisions/ADR-009-ux-overhaul.md) D1).

What this means when you propose changes:

- **Agent autonomy is the product.** A human should be able to walk away and let the agent keep working. Any design that forces human intervention on a legitimate operation — credential prompts, TTY dialogs, interactive approvals, "please run this on the host" — defeats the purpose.
- **Layers, not walls.** The microVM boundary, default-deny egress, the protected-paths mount rule, the floor probe: each catches a class of accidents. None is a security boundary against a motivated attacker, and pretending otherwise leads to over-strict designs.
- **80/20, not 100/0.** Egress is default-deny with a curated allowlist in the project config. msb logs nothing for allowed traffic, so there is no observe mode — a fast deny→fix→relaunch loop replaces it (`rc doctor` mines the denial trace into the exact config line). Block the obvious accident; don't gate the legitimate work.
- **"It's annoying" is a design signal.** If an agent hits something the cage blocks and the right human response is "just turn it off," the default is probably wrong. Revisit the decision.
- **rip-cage is a composable seam, not a bundler** ([ADR-005 D12](docs/decisions/ADR-005-ecosystem-tools.md)). rc owns the containment floor and the mechanical seams; it never names, bundles, or blesses an optional tool. Adding a tool is a `FROM rip-cage:latest` line in the operator's own Dockerfile, with zero rc edits. Defaults ship minimal; examples live outside the binary (`examples/`), never special-cased. **Convenience never earns a hardcoded exception in the seam.** This is the principle agents keep drifting from; hold it.
- **Built for the agentic era — composition is the agent's job.** rip-cage is deterministic about what is **invariant** (the containment floor, and mechanical seams identical every run: the config schema, `rc build`, mount mechanics) and pushes to the **agent** what **varies** (which tools, whether a guard at all, how the pieces wire together). Help the agent generously on the invariant side — CLIs, scripts, skills, legible `examples/` recipes *are* the job. The drift is the inverse: freezing the composition into machinery. An installer / auto-wire / config-merge step is the classic shape, but judge by the principle ("am I automating something that is the agent's judgment?"), not by matching that list.
- **The threat model includes prompt-injection** ([ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md)). "Accident" covers a non-adversarial agent following hostile instructions injected via fetched READMEs, web pages, MCP output, or workspace files. The egress allowlist, msb's DNS default-deny, the host-side location rule for composition inputs, and the workspace-trust validator are the layers that target it. A motivated *adversarial* agent is explicitly out of scope.

Containment-flavored language ("the thing inside the cage is not you") reads as an adversarial threat model rip-cage is not trying to meet. When in doubt, optimize for autonomous uninterrupted runs over theoretical blast-radius reduction.

## Architecture

```
Host (macOS/Linux)
├── rc                          CLI entrypoint (bash), sourcing cli/*.sh + cli/lib/*.sh.
│                               Six verbs: up, auth, doctor, build, test, destroy.
├── share/rip-cage/
│   ├── cage.yaml.template      The shipped project-config template — a native msb --conf file
│   └── protected-paths         Fail-closed list of credential locations rc refuses to mount
├── cage/Dockerfile             The base image, built via `docker build`, loaded into msb
├── cage/floor/floor-probe.sh   Fail-closed containment check ON THE BUILT IMAGE (20 checks)
├── cage/boot/boot.json         Boot descriptor — daemons + multiplexers; schema in its _readme key
├── cage/init/init-rip-cage.sh  Runs in the sandbox at start: floor probe first, then auth,
│                               settings, git identity, beads
├── cage/agent/settings.json    Claude Code config — bypassPermissions, deny rules
├── examples/                   Composition recipes (Dockerfile.snippet + boot-fragment.json + README)
└── tests/                      Tiered suites; `tests/run-host.sh --host-only` is the host gate
```

Each project launches from **one file**: `~/.config/rip-cage/projects/<cage>.yaml`, msb's own `--conf` schema, carrying its lists in full. `rc` merges nothing into it ([ADR-031](docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2). Composition inputs — the Dockerfile, the boot descriptor, the config, the protected-paths list — all live host-side, outside every cage mount (D5a).

**Usage:** `rc up <project>` creates or resumes the cage, runs init, and attaches. The project directory is mounted at `/workspace`; file changes sync live, no git push. `RC_MULTIPLEXER` selects a multiplexer, which the image's boot descriptor must declare; the default is none.

Three skills are the front door, and the only home for their how-to: [`cage-config`](.claude/skills/cage-config/SKILL.md) writes the config file, [`cage-image`](.claude/skills/cage-image/SKILL.md) writes the Dockerfile and boot fragment, [`cage-ops`](.claude/skills/cage-ops/SKILL.md) runs and repairs a live cage. Cite them; don't duplicate them. `docs/reference/` stays the mechanism reference.

## Auth flow (for contributors)

Two mechanisms, deliberately not yet bridged:

1. **The Claude login — possession.** `rc up` (and `rc auth refresh`) pull it from the macOS keychain on the host, before the sandbox exists, write it to `~/.claude/.credentials.json`, and mount that file into the cage. The real token is in the guest.
2. **`--secret` — non-possession.** A `secrets:` entry in the cage config binds a credential to its allowed hosts; msb injects the value on the wire and the guest holds only `$MSB_<NAME>`. `rc up` fills the host variable from `$XDG_CONFIG_HOME/rip-cage/secrets/<NAME>` so unattended runs need no pre-export. **The operator populates that file; rc does not put the keychain login there.**

Wiring (1) through (2) is `rip-cage-ely4.7.17` — charted, not shipped. Do not describe the Claude login as non-possessed ([ADR-031](docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D1's realized-vs-charted note). `init-rip-cage.sh` reads what the config mounted; it never touches a keychain. Full detail: [docs/reference/auth.md](docs/reference/auth.md).

## Skills in containers

Host-mounted skills are discoverable inside a cage via a Python MCP shim (`cage/substrate/skill-server.py`), registered as `mcpServers.meta-skill` in `settings.json`. It implements the same `list`/`show`/`load` tools as the host `ms` binary. Skills that are broken symlinks inside the cage (host-only paths) are skipped at startup.

**Skill-source symlinks (projection contract, rip-cage-1pgp.1):** `rc up` auto-mounts each skill-symlink target's parent dir `ro` at its **host-absolute** path (`_collect_symlink_parents` in `cli/up.sh`), which fixes **absolute** symlinks. **Relative** symlinks resolve against the cage home instead, so they need an explicit `ro` mount line in the project config at that cage-side resolution path — composition, never an rc-blessed path. The contract is a cage-resolvable mount, not resolve-and-copy at init, so host live-edits stay visible. Existing cages gain a new mount on `rc up --replace`.

Upgrade path: when `ms` publishes Linux binaries, swap `command`/`args` in `settings.json` and delete the shim; the server name `meta-skill` stays. Design rationale: `history/2026-04-14-skills-in-containers-design.md`.

## Key gotchas

- Mounts get their parent dirs created as root, which is why `init-rip-cage.sh` starts with `sudo chown agent:agent ~/.claude`.
- `container_name()` (`cli/lib/container.sh`) derives cage names from the last two path components; collisions get a 4-char hash suffix.
- Every resume is a fresh kernel boot under msb — processes die between stop and start, so `rc` re-runs init on each resume.
- msb does not follow a host-side symlink in a mount source, and the mount fails at boot rather than at validation. On macOS write `/private/tmp/...`, never `/tmp/...`.
- msb keeps its own image cache. `rc build` does `docker build` then loads into msb; a docker-only build leaves cages booting the old image.

## When a host is denied egress inside the cage

Egress is default-deny at the VM boundary, plus the allowlist in the project config's `network.allow`. A denied domain fails DNS resolution client-side in milliseconds; only that DNS-stage denial is logged, and `rc doctor` mines it into the exact line to add. A connect-stage denial (a raw IP) logs nothing at any verbosity.

If you are **inside a cage** and hit this wall, you cannot fix it yourself: the config is host-side, outside every cage mount, by design ([ADR-031](docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5a) — a prompt-injected agent must not be able to widen its own egress. **Surface the request in prose** — "please add `<host>:tcp:443` to `network.allow` in this cage's config" — and wait. Done when the human reports the cage back up.

If you are **on the host**, the loop is in [`cage-ops`](.claude/skills/cage-ops/SKILL.md): `rc doctor <cage>` names the host, you add the line, `rc up --replace <project>` recreates the cage against the current config. Host mounts and named volumes survive that recreate (the Claude session resumes); only the guest's ephemeral rootfs overlay is lost.

## Beads over the msb mount — interim single-writer discipline

While a cage is up read-write on a repo, **bd writes should happen from one side at a time** — let the in-cage agent do its own bookkeeping, and have a host orchestrator batch writes for cage-idle windows. This is convention, not a lock: msb's virtiofs does not propagate `flock` across the guest/host boundary in either direction, so a concurrent host+guest write race stays physically possible ([ADR-029](docs/decisions/ADR-029-msb-migration.md) D7, FLEXIBLE). Not an msb regression — the Docker bind-mount path didn't propagate `flock` either.

## Harness inventory

[`.claude/verification.md`](.claude/verification.md) catalogs this repo's verification mechanisms — shell syntax checks, shellcheck, tiered suites, `rc test`, `rc doctor`, egress probes, ADRs. Consult it when picking a feedback loop.

## Testing changes

After touching the Dockerfile or any file it copies in:

```bash
./rc build
./rc up /path/to/test/project
./rc test <cage-name>          # expect all checks PASS; the floor probe runs first
```

Changes to `rc` itself need no rebuild. The host gate is `bash tests/run-host.sh --host-only`.

## Releasing

Cutting a release has rip-cage-specific steps the global `/release` skill does not know. The single source of truth is [docs/reference/release-ceremony.md](docs/reference/release-ceremony.md) — follow it step by step.

## Roadmap & decisions

[docs/ROADMAP.md](docs/ROADMAP.md) for what's shipped and what's fog. [docs/decisions/INDEX.md](docs/decisions/INDEX.md) for every ADR with its retired-or-evolved status.

## Beads read-authority

`bd show` / `bd list` read the embedded Dolt store and are authoritative. `.beads/issues.jsonl` is a lagging derived export, NOT rewritten on `bd update`/`create`/`close` — reading it returns stale state. If a file reader genuinely needs current data, flush first: `bd export --all -o .beads/issues.jsonl`. Auto-export is intentionally off here; `.beads/config.yaml` carries the rationale.

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
