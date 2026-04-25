# Rip Cage — Harness Inventory

Feedback mechanisms available in this repo. The agent picks what fits the task; this is a pantry, not a pipeline.

**Shape of the project:** bash CLI (`rc`) + Dockerfile + init script + hooks, with a large shell-based test suite split across host-only and in-container tiers. No compiled code in the repo itself (Go/Rust binaries are built inside the image). That means most feedback is bash-level: syntax checks, shellcheck, and running test scripts.

---

## Static / fast signals

### `bash -n <script>` — shell syntax check
- **Speed:** <1s per file
- **Catches:** syntax errors, unclosed quotes/heredocs, broken control flow
- **Useful when:** you've edited `rc`, `init-rip-cage.sh`, a hook, or any `tests/*.sh` — run before anything else
- **Less useful when:** logic bugs (it only validates parsing)

### `make lint` → `shellcheck rc init-rip-cage.sh hooks/block-compound-commands.sh bd-wrapper.sh tests/test-prerequisites.sh`
- **What it is:** shellcheck on the canonical bash scripts list from the Makefile
- **Speed:** ~2-5s
- **Catches:** quoting bugs, unused variables, SC2086 word-splitting, unsafe `cd` patterns, missing `-r` on `read`
- **Useful when:** touching any listed script — `rc` is large (~2400 lines) so shellcheck finds real bugs
- **Less useful when:** editing a test script NOT in `BASH_SCRIPTS` (lint won't cover it — consider running `shellcheck` directly on the file)
- **Note:** shellcheck is not repo-pinned; teammates need it installed (`brew install shellcheck`)

### `jq` on JSON files (`settings.json`, `devcontainer.json`, `.beads/metadata.json`)
- **What it is:** JSON validator / structural query tool
- **Command:** `jq . settings.json` (validate) or `jq -r '.permissions.allow[]' settings.json` (query)
- **Speed:** <1s
- **Catches:** malformed JSON from hand-edits, missing keys, accidentally-stringified arrays
- **Useful when:** editing `settings.json`, adding a hook, adjusting permissions
- **Less useful when:** the shape is valid but the semantics are wrong (hook ordering, matcher regex) — use the hook probe instead

---

## Test suites

The repo splits tests into three tiers. See `tests/run-host.sh` for the canonical host-only runner and ADR-013 for the coverage policy.

### `make test` — host-only smoke tier
- **What it is:** Makefile target; runs `test-prerequisites.sh`, `test-rc-commands.sh`, `test-json-output.sh`
- **Speed:** ~10-30s (no container, no docker build)
- **Catches:** `rc` CLI arg parsing, usage output, prerequisite detection, `--output json` contract breaks
- **Useful when:** editing `rc` subcommand dispatch, usage text, JSON output shape
- **Less useful when:** touching anything that runs *inside* the container

### `bash tests/run-host.sh` — full host suite
- **What it is:** all host-side tests (12 scripts: rc commands, worktree, security-hardening, json, prerequisites, dockerfile-sudoers, bd-wrapper, agent-cli, code-review-fixes, dg6.2, auth-refresh, completions)
- **Speed:** ~1-3min depending on docker image state
- **Catches:** broader regressions than `make test` — auth refresh flow, worktree detection, dg6.2 regression guards, completion output shape
- **Useful when:** before committing a change that touches `rc`, the init script, or shell integration
- **Less useful when:** you're iterating rapidly on one area — pick the specific script instead

### `./rc test <container-name>` — in-container safety stack (61 checks)
- **What it is:** runs `tests/test-safety-stack.sh` inside a running rip-cage container
- **Speed:** ~10-20s (needs a running container)
- **Catches:** DCG present, compound blocker active, Claude Code settings wired, git identity set, beads initialized, skills mounted, egress rules loaded, CAGE_HOST_ADDR injected, CLAUDE.md topology markers
- **Useful when:** after `rc up`, or after changes to `Dockerfile`, `init-rip-cage.sh`, `settings.json`, `hooks/`, `egress-rules.yaml`
- **Less useful when:** the container failed to start — use `rc doctor` instead
- **Prereq:** working container. Env var `SKIP_AUTH=1` turns auth/beads/git-identity FAILs into INFO for integration runs

### `./rc test --e2e` — full lifecycle E2E
- **What it is:** `tests/test-e2e-lifecycle.sh` — up/down/destroy + regression guards across staged workspaces (22 checks, ADR-013 D1/D3)
- **Speed:** ~90-180s warm cache; much longer with `RC_E2E_REBUILD=1`
- **Catches:** container naming determinism, volume lifecycle, cleanup correctness, label-filtered destroy safety
- **Useful when:** before a release or after changing `cmd_up`/`cmd_down`/`cmd_destroy`, container naming, or volume handling
- **Less useful when:** quick iteration — the 90s+ runtime kills the feedback loop

### Targeted test scripts — pick by area
| Area touched | Script |
|---|---|
| Docker image build, sudoers, entrypoint | `test-dockerfile-sudoers.sh`, `test-integration.sh` |
| Auth refresh / credential flow | `test-auth-refresh.sh` |
| Beads (bd wrapper, host preflight, roundtrip) | `test-bd-wrapper.sh`, `test-bd-host-preflight.sh`, `test-bd-roundtrip.sh` |
| Skills mount / MCP shim | `test-skills.sh` + `test_skill_server.py` (pytest — only python test) |
| Egress firewall | `test-egress-firewall.sh` |
| SSH agent forwarding (ADR-017) | `test-ssh-forwarding.sh` |
| Worktree / git mount | `test-worktree-support.sh` |
| Shell completions | `test-completions.sh` |
| LFS warning (ADR regression) | `test-lfs-warning.sh` |
| Security hardening | `test-security-hardening.sh` |
| Pi install / image presence (ADR-019) | `test-pi-install.sh` |
| Pi auth bind-mount + env vars (ADR-019 D1/D5) | `test-pi-auth-mount.sh` |
| Pi AGENTS.md injection + idempotency (ADR-019 D3) | `test-pi-cage-context.sh` |
| Pi end-to-end `pi -p` smoke (ADR-019) | `test-pi-e2e.sh` (skips when no host auth) |

All follow the same PASS/FAIL/TOTAL convention; grep for `FAIL` in output.

---

## Runtime / observable

### `./rc doctor <name>` — per-container diagnostic
- **What it is:** labels + live probes for one container (introduced in the commit before this audit)
- **Speed:** <5s
- **Catches:** misconfigured labels, missing mounts, auth state drift, "why is my container broken"
- **Useful when:** a container won't behave as expected but is running
- **Less useful when:** no container exists yet (start one with `rc up`)

### `./rc ls` — list rip-cage containers with state
- **Speed:** <1s
- **Catches:** stale / leftover containers from failed tests, name collisions
- **Useful when:** cleaning up before an E2E run; checking which container `rc attach` would pick

### `docker logs <container>` / `docker exec <container> cat ~/.claude/CLAUDE.md`
- **What it is:** raw observation of container state
- **Speed:** <1s
- **Catches:** init-rip-cage.sh output, appended topology markers, hook stderr
- **Useful when:** `rc test` fails on a CLAUDE.md check and you want to see the actual file contents
- **Less useful when:** the failure is deterministic — reproduce in a test harness instead

### Headless Claude dispatch inside the cage (`claude -p`)
- **What it is:** Claude Code ships inside the rip-cage image at `/usr/bin/claude`. Running `claude -p "<prompt>"` (with optional `--model sonnet`, `--debug`, `--debug-file /tmp/claude-debug.log`) produces a non-interactive completion — you can invoke it from the host via `docker exec` and get stdout back. Subagent dispatch, tool calls, and hook interactions all work.
- **Command:** `docker exec -w /workspace <container> claude -p --model sonnet --debug --debug-file /tmp/claude-debug.log "<prompt>"`
- **Speed:** seconds to minutes depending on the prompt
- **Catches:** behaviors that require a real Claude Code session in the cage — subagent dispatch success/failure, MCP tool discovery, CA-trust propagation to forked node procs, hook firing order, settings.json actually being loaded, auth token usage path
- **Useful when:** you're debugging a *runtime* behavior that no test script covers (e.g. "subagents fail fast with 0 tokens"), or you want to confirm a fix from the host without bouncing work back to the user's interactive session. Pair with `docker exec <c> tail -f ~/.claude/logs/*.log` in another shell to watch what the caged agent sees.
- **Less useful when:** the failure is deterministic at the env/config level — a shellcheck or `rc test` check is faster. Also costs tokens, so don't reach for it when a cheaper signal exists.
- **Gotcha:** `claude -p` counts against the credentials mounted into the container, so authenticated subscription state matters. Confirm with `cat ~/.claude/.credentials.json | jq '.claudeAiOauth.expiresAt'` before blaming a bug.
- **Why this matters:** without this, a host-side agent investigating an in-cage Claude Code bug can only inspect *static* state (env vars, files, mounts) and then hand the "push the button" step back to the user. With `claude -p`, the host agent can close the loop itself — run the repro, read the debug log, and confirm or refute a hypothesis in one session. It turns the cage from an opaque box into an observable subprocess.
- **See also:** `cage-claude.md` "Troubleshooting: subagent fails fast" section — codified runbook for the specific *"0 tool uses, ~2s"* pattern (auth-error narration is usually wrong; real cause is typically 1M-beta model + subagent, rate limit, or stale session).

### Egress firewall probes
- **What it is:** `test-egress-firewall.sh` contains ready-to-copy curl/nc probes for denylisted hosts
- **Catches:** rules file not loaded, proxy misconfigured, rule regex bugs
- **Useful when:** editing `egress-rules.yaml`, `rip_cage_egress.py`, or `rip-proxy-start.sh`

---

## Tools & CLIs

### `rc` (this repo's CLI) — host-only
- **Subcommands:** `build init up ls attach down destroy test doctor auth schema completions setup`
- **Invariant:** hard-exits if `/.dockerenv` is present. It will never run inside a cage.
- **Schema:** `rc schema` prints a machine-readable command schema for agent consumption.
- **JSON mode:** `rc --output json <cmd>` for most commands.

### `bd` (beads) — issue tracking, used both host and in-container
- **What it is:** primary task tracker (see `CLAUDE.md` and `.beads/CLAUDE.md`)
- **Useful when:** you need to record/close/claim work — required over TodoWrite per CLAUDE.md
- **Host preflight:** `_bd_host_preflight` inside `rc` validates host-side dolt connectivity; runs as part of `rc test`

### Global tools assumed present (not pinned)
- `shellcheck`, `jq`, `docker`, `tmux`, `git`, `perl` (used by compound-blocker hook)
- Teammates without these installed will get prerequisite failures from `test-prerequisites.sh`

---

## Grounding & design context

### ADRs — `docs/decisions/ADR-001` through `ADR-017`
- **What it is:** decision records; each feature references one. Checked into the repo.
- **Useful when:** about to change behavior around auth, beads/dolt, egress firewall, SSH forwarding, toolchain provisioning, CAGE_HOST_ADDR — read the ADR first; tests assert on ADR-numbered invariants (e.g. `ADR-013 D1/D3`, `ADR-016 D2`)
- **Less useful when:** changing internal plumbing that no ADR covers — proceed normally

### Design docs — `docs/YYYY-MM-DD-<topic>-design.md`
- **What it is:** longer-form design docs that predate (or accompany) ADRs
- **Useful when:** an ADR is too terse and you need the rationale

### ROADMAP — `docs/ROADMAP.md`
- **What it is:** phased plan; crosses ADRs with test coverage state
- **Useful when:** choosing what to work on next, or checking whether a feature is "done-done"

### CLAUDE.md + `cage-claude.md`
- **What it is:** project-level agent guide (this repo) and the container-injected topology/context file (`cage-claude.md` → `/etc/rip-cage/cage-claude.md`)
- **Useful when:** reasoning about what the in-cage agent sees vs the host agent

---

## Build-it patterns

When no existing mechanism fits, build one of these:

- **Targeted shell test.** Copy the shape of any `tests/test-*.sh` (the `PASS/FAIL/TOTAL` convention is consistent). Host-only → add to `tests/run-host.sh`. In-container → wire into `test-safety-stack.sh`. ADR-013 codifies the tiering.
- **Throwaway probe.** One-liner `docker exec <name> <cmd>` to poke a specific piece of container state. Don't commit; delete when answered.
- **Minimal repro workspace.** `mktemp -d` a staging dir, `git init`, `rc up $dir`, exercise. The E2E test uses this pattern (staging under `/var/folders/.../rc/e2e-test` for deterministic container names).
- **Python test (rare).** Only `test_skill_server.py` is pytest-based. If testing the MCP skill shim, extend that file; everything else should be shell.
- **Dry-run.** Most `rc` subcommands accept `--dry-run` for previewing without side effects. Good for verifying argument parsing without launching containers.
- **End-to-end repro via `claude -p`.** When debugging an in-cage Claude Code behavior (subagent dispatch, MCP tools, hooks at runtime), use the "Headless Claude dispatch" mechanism above instead of handing the repro back to the user. The host agent can close the loop itself: `rc up` a scratch workspace → `docker exec ... claude -p ...` → read `/tmp/claude-debug.log`. Pair with `rc up --no-forward-ssh`, `--cpus`, `--memory`, or running without the egress firewall (by editing the image / toggling proxy start) to A/B-isolate the variable under suspicion.

---

## Conventions worth knowing

- **Compound commands are blocked** by `hooks/block-compound-commands.sh` (active in this session too — see the hook error if you try `&&`/`;`/`||` in a single Bash call). Split commands into separate tool calls.
- **`rc` is host-only.** It detects `/.dockerenv` and exits. Tests that orchestrate containers must run from the host.
- **Container-name derivation** uses `parent/basename` of the workspace path. Collisions get a 4-char hash suffix. E2E tests depend on this — stage workspaces carefully to get a deterministic name.
- **`.devcontainer/` and `.vscode/` are gitignored** — they're per-project scaffold from `rc init`. Don't commit.
- **Docker bind-mount parent dirs are created as root.** `init-rip-cage.sh` starts with `sudo chown agent:agent ~/.claude` to fix this; don't remove that line without replacing it.
- **ADR-numbered assertions** appear in test output (e.g. `[ADR-013 D1]`). Grep those IDs in `docs/decisions/` for context when a test fails.
- **SKIP_AUTH=1** downgrades auth-related failures in `test-safety-stack.sh` to INFO — use in CI/integration contexts where real credentials aren't available.

---

## Entrypoints

- `rc` — top-level CLI; all roads start here (usage at line 109, dispatch around line 2412)
- `init-rip-cage.sh` — what happens on first container start
- `Dockerfile` — image definition (Go → Rust → Debian runtime)
- `settings.json` — Claude Code config shipped into the container (hooks, MCP, permissions)
- `tests/run-host.sh` — canonical host-test runner
- `docs/ROADMAP.md` + `docs/decisions/` — where to go for "why"
- `.beads/` — issue state (dolt-backed; `bd prime` loads context)
