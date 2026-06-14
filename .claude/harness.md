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

### `make lint` — pinned shellcheck via Docker
- **What it is:** `make lint` runs `koalaman/shellcheck:v0.11.0` via Docker against the canonical `BASH_SCRIPTS` list (`rc init-rip-cage.sh hooks/*.sh bd-wrapper.sh tests/test-prerequisites.sh tests/test-docker-daemon-hang.sh`). This is the single lint source of truth — CI mirrors it exactly.
- **Speed:** ~5-15s (Docker pull is cached after first run)
- **Catches:** quoting bugs, unused variables, SC2086 word-splitting, unsafe `cd` patterns, missing `-r` on `read`
- **Useful when:** touching any listed script — `rc` is large (~2400 lines) so shellcheck finds real bugs; run `make lint` before tagging a release
- **Less useful when:** editing a test script NOT in `BASH_SCRIPTS` (lint won't cover it — consider running shellcheck directly on the file)
- **Fail-on-info is intentional:** no `--severity` flag is passed, so info-level findings fail lint. This is the correct bar — the 3 burned v0.4.x tags came from version divergence (local 0.11.0 vs CI 0.9.0), not from the strictness level. With the pinned image, `make lint` passing locally is a reliable pre-tag gate.
- **CI mirrors `make lint`:** both ci.yml and release.yml lint jobs run `make lint` (a single step, no `apt-get install shellcheck`). Local == CI by construction.

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
- **What it is:** all tests in the ordered list (host-only + container-needing). Runs every script in `tests/run-host.sh` including NEEDS_CONTAINER tests (test-agent-cli, test-pi-*).
- **Speed:** ~1-3min for host-only tests; longer if container tests run (requires pre-built image)
- **Catches:** broader regressions than `make test` — auth refresh flow, worktree detection, dg6.2 regression guards, completion output shape, egress rules, allowlist, reload, config-init, etc.
- **Useful when:** before committing a change that touches `rc`, the init script, or shell integration
- **Less useful when:** you're iterating rapidly on one area — pick the specific script instead

### `bash tests/run-host.sh --host-only` — CI mode (no container required)
- **What it is:** same as above but skips the NEEDS_CONTAINER denylist (test-agent-cli, test-pi-e2e, test-pi-install, test-pi-auth-mount, test-pi-cage-context). Everything else runs. Prints `SKIP (needs container): <name>` per skipped test.
- **Speed:** ~1-3min (no docker image needed)
- **Safe-failure design:** newly-added tests run by default (not silently dropped); if a new test actually needs a container it fails loudly in CI → author adds it to NEEDS_CONTAINER.
- **Two skip granularities (rip-cage-ozt):** file-level via the NEEDS_CONTAINER denylist (above), AND sub-test-level via `RC_HOST_ONLY` — `--host-only` exports `RC_HOST_ONLY=1`, and a mostly-host-only test gates its few live-container blocks behind `[[ -n "$RC_HOST_ONLY" ]]` with a visible `SKIP (host-only): ...` line (e.g. test-code-review-fixes L2-a/b). Those blocks still run in the full `run-host.sh` (no flag).
- **Run-all-accumulate (rip-cage-ozt):** the driver runs EVERY test (via `if ! bash "$test_file"`), accumulates `FAILED_TESTS`, reports all at the end, and `exit 1` if any failed. It does NOT abort at the first failure — `set -e` at the driver loop was the thrashing root cause (one failure surfaced per 12-min CI cycle).
- **Useful when:** local quick validation, CI, or any context where a live cage isn't available

> **⚠ Local-vs-CI divergence checklist (rip-cage-ozt — the lesson across wn4 + ozt).** `--host-only` passing on macOS does NOT prove CI-green. The maintainer's box masks failures by construction (BSD coreutils + `rip-cage:latest` always present + warm Docker cache); a fresh Linux CI runner has GNU coreutils + no image + cold cache + Docker Hub anon rate limits. Before pushing a test/driver change, check each axis:
> - **GNU vs BSD coreutils.** `sed`/`grep`/`awk`/`date`/`stat` differ. (test-auth-refresh L10)
> - **`<cmd> | grep -q` SIGPIPE under `set -o pipefail` — NOT GNU-only (rip-cage-kd7 corrects the earlier framing).** Any pipeline `<upstream> | grep -q PATTERN` returns **141** when the upstream has MORE to write *after* grep matches: grep exits on first match and closes the pipe, the upstream's trailing write takes SIGPIPE, and pipefail reports 141 → the `if` reads false even on a match. The trigger is "upstream keeps writing past the match," not the coreutils flavor — it reproduced on the maintainer's macOS/BSD box (`rc setup | grep -q "already configured"`, flaky ~2/5), so the prior "BSD suppresses it" note was wrong. Fix: capture upstream to a var first (`out=$(cmd); grep -q PATTERN <<<"$out"`) or use a reader that consumes all input (single `awk` pass). (test-completions L112, test-auth-refresh L10)
> - **Image-absent.** CI starts with no `rip-cage:latest`. Any `rc` path that provisions the image before it's actually needed burns a 500MB pull or a ~7-min build, and pull progress on stderr corrupts `--output json`. Determine container state before provisioning (ADR-001; cmd_up reorder).
> - **No live containers / no Docker Hub pulls / no real builds in the host-only tier.** `docker run alpine` is flaky in CI (Docker Hub anon rate limits — passes one run, fails the next). Gate live-container sub-tests behind `RC_HOST_ONLY`. Never run a real `rc build`/`docker run` just to assert a log line — use a fake-docker PATH shim (test-json-output T9: 3.8s vs 7min).
> - **compaudit on non-root checkout.** Bare `compinit` trips CI's insecure-directory check (group-writable fpath); macOS passes. Use `compinit -i` + a temp `-d` dumpfile, and capture stderr so a real syntax error still surfaces. (test-completions)

### `./rc test <container-name>` — in-container safety stack
- **What it is:** runs `tests/test-safety-stack.sh` inside a running rip-cage container
- **Speed:** ~10-20s (needs a running container)
- **Catches:** DCG present (chaining-robust), ssh-bypass blocker active, Claude Code settings wired, git identity set, beads initialized, skills mounted, egress rules loaded, CAGE_HOST_ADDR injected, CLAUDE.md topology markers. Note: compound-command blocker removed in rip-cage-4r8; DCG regression tests 11f/11g/11h lock in chaining-robustness.
- **Useful when:** after `rc up`, or after changes to `Dockerfile`, `init-rip-cage.sh`, `settings.json`, `hooks/`, `egress-rules.yaml`
- **Less useful when:** the container failed to start — use `rc doctor` instead
- **Prereq:** working container. Env var `SKIP_AUTH=1` turns auth/beads/git-identity FAILs into INFO for integration runs

### `./rc test --e2e` — full lifecycle E2E
- **What it is:** `tests/test-e2e-lifecycle.sh` — up/down/destroy + regression guards across staged workspaces (22 checks, ADR-013 D1/D3)
- **Speed:** ~90-180s warm cache; much longer with `RC_E2E_REBUILD=1`
- **Catches:** container naming determinism, volume lifecycle, cleanup correctness, label-filtered destroy safety
- **Useful when:** before a release or after changing `cmd_up`/`cmd_down`/`cmd_destroy`, container naming, or volume handling
- **Less useful when:** quick iteration — the 90s+ runtime kills the feedback loop
- **Gotcha — manifest archetype e2e self-skips unless `RC_E2E=1`.** TOOL/SHELL/DAEMON/cross-cage manifest tests (`test-manifest-*.sh`) gate their real-cage tier behind `RC_E2E`, which the default suite never sets — the always-run tier proves only host-side codegen, never a real `docker build` / daemon-cage run. A daemon / worked-example / integration child is NOT verified until run with `RC_E2E=1` (see Conventions: gated-e2e false-green).

### Targeted test scripts — pick by area
| Area touched | Script |
|---|---|
| Docker image build, sudoers, entrypoint | `test-dockerfile-sudoers.sh`, `test-e2e-lifecycle.sh` (entrypoint/lifecycle/mise provisioning — absorbed test-integration.sh, deleted rip-cage-b6ia) |
| Auth refresh / credential flow | `test-auth-refresh.sh` |
| Beads (bd wrapper, host preflight, roundtrip) | `test-bd-wrapper.sh`, `test-bd-host-preflight.sh`, `test-bd-roundtrip.sh` |
| Skills mount / MCP shim | `test-skills.sh` + `test_skill_server.py` (pytest — only python test) |
| Egress firewall | `test-egress-firewall.sh` — ⚠ **structural-only on the nft backend.** On debian:trixie iptables defaults to nft, which SILENTLY no-ops the legacy-style REDIRECT/DROP rules (fail-OPEN): the test passes 18/18 while the firewall is disarmed. Green is CONDITIONAL on the Dockerfile `update-alternatives --set iptables /usr/sbin/iptables-legacy` pin (ADR-012 D10, safety-critical). After any base bump or iptables change, confirm the legacy pin AND that a denylisted host actually 403s — rule-presence ≠ enforcement (rip-cage-4c5.10). |
| Egress startup self-test guard (refuse-to-start on silent fail-open, rip-cage-fft) | `test-selftest-classifier.sh` (pure outcome-classifier unit test, no live firewall), `test-selftest-mode-gating.sh` (mode-gating via a curl PATH-shim — no production hook), `test-selftest-integration.sh` (container: positive ENFORCED path + **negative path that flushes the real nat REDIRECT** and asserts BYPASSED + non-zero exit), `test_selftest_endpoint.py` (reserved-marker endpoint, pytest). The guard lives in `init-firewall.sh` (probes a reserved host pinned to unroutable 192.0.2.1) + `rip_cage_egress.py` (local marker) + `rip-proxy-start.sh` (`connection_strategy=lazy`, load-bearing — see bd memory `mitmproxy-selftest-probe-inversion-lazy-connect`). |
| SSH agent forwarding (ADR-017) | `test-ssh-forwarding.sh` |
| Worktree / git mount | `test-worktree-support.sh` |
| Shell completions | `test-completions.sh` |
| LFS warning (ADR regression) | `test-lfs-warning.sh` |
| Security hardening | `test-security-hardening.sh` |
| Pi install / image presence (ADR-019) | `test-pi-install.sh` |
| Pi auth bind-mount + env vars (ADR-019 D1/D5) | `test-pi-auth-mount.sh` |
| Pi AGENTS.md injection + idempotency (ADR-019 D3) | `test-pi-cage-context.sh` |
| Pi end-to-end `pi -p` smoke (ADR-019) | `test-pi-e2e.sh` (skips when no host auth) |
| Pi DCG parity (ADR-019 D4, rip-cage-bl1) | `test-pi-dcg-gate.sh` (auth-free: structural + dcg-binary-via-wrapper; wired into both `rc test` branches, conditional on pi present). Compound-blocker section removed rip-cage-4r8; chaining-robustness locked in test-safety-stack.sh 11f/11g/11h. |
| In-cage multiplexer lifecycle (`session.multiplexer: none\|tmux\|herdr`, ADR-021 D6 / ADR-006 D7) | `test-multiplexer-lifecycle.sh` — **NEEDS_CONTAINER, gated `RC_E2E=1`** (self-skips visibly otherwise). Parameterized over the multiplexer value: asserts default-`none` plain-shell + **no** mux server (enumerated procs), two independent `rc exec`/`rc attach` terminals (close-one-leaves-other), `tmux` detach/reattach survival, `rc agent`/`rc sessions` retirement across dispatch/help/schema/completions/json-allowlist, and config-isolation under each mux (herdr **gating** via `HERDR_SESSION`). herdr blocked/working/done status-view is skip-with-log. This is the integration Signal for the multiplexer-decouple epic; it REPLACED `test-multi-agent-levers.sh` (rip-cage-1f59.8). Spins+tears-down 3 scratch cages (cleanup trap uses realpath-resolved labels). |
| Pi agent THROUGH the tmux mux surface — real work with >=2 distinct tool invocations (rip-cage-w621.7) | `test-multiplexer-agent-e2e.sh` — **NEEDS_CONTAINER, gated `RC_E2E=1`** (self-skips visibly otherwise; LOUD-FAIL if pi auth absent). Fills the intersection `test-multiplexer-lifecycle.sh` (attach, no agent work) and `test-pi-e2e.sh` (agent, bypasses mux via docker exec) both miss. Drives pi THROUGH tmux headlessly: `docker exec <cage> tmux send-keys -t rip-cage "bash /workspace/run-pi.sh" Enter` (run-pi.sh is written to the bind-mount before cage start — avoids multi-line quoting issues). Saves session JSONL to `/workspace/.pi-sessions` via `--session-dir`. Asserts: (a1) session JSONL includes a native `write` toolCall entry (cardinal DP6 discriminator: launcher uses bash redirection and NEVER fires pi's write tool → fires RED on the launcher revert), (a2) >=2 distinct tool names (belt-and-suspenders), (b) RESULT.txt content == expected first line of SEED.txt (agent-produced artifact). Positive-control revert: replace multi-step prompt with `"Run: head -1 /workspace/SEED.txt > /workspace/RESULT.txt"` → JSONL shows bash+read only (no write) → assertion (a1) fires RED. Proven: GREEN on HEAD (bash+read+write, exit 0), RED on launcher revert (bash+read only, exit 1). Spins+tears-down one scratch tmux cage under RC_ALLOWED_ROOTS (cleanup trap uses realpath-resolved labels). Registered in `tests/run-host.sh` NEEDS_CONTAINER denylist. |

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

### Headless pi dispatch inside the cage (`pi -p`) — guard LOAD+FIRE proof
- **What it is:** the pi analog of the Claude dispatch above. pi ships in the image; a non-interactive `pi -p "<prompt>"` fires the auto-loaded `dcg-gate.ts` extension (baked at the cage-owned container-local `<agentDir>/extensions/`, no `-e` flag). This is the *only* mechanism that proves the guard actually LOADS and FIRES under pi — structural tests (`test-pi-dcg-gate.sh`) prove the extension is baked + correct + that the dcg binary denies via the wrapper, but cannot prove pi runs it.
- **Command:** `docker exec -w /workspace <container> pi --provider <p> -p "<prompt that attempts a destructive command>"`
- **Catches:** guard auto-load (does the baked extension run on pi startup), DCG deny path, fail-loud reason surfacing. Read `tool_execution_end isError=true` + the deny reason in the JSON.
- **Gotcha:** counts against the mounted pi `auth.json` (rip-cage-hhh.12 bind-mounts host `~/.pi/agent/auth.json` RW). **Confirm `ls ~/.pi/agent/auth.json` on the host before blaming a missing token — the cage HAS auth.** (rip-cage-bl1: the live-fire proof was twice deferred as "needs auth" when auth was present the whole time.)
- **Two verification altitudes — do not conflate:** `test-pi-dcg-gate.sh` (in `rc test`, auth-free) vs. live LOAD+FIRE (this cell, authed, e2e/manual tier). `rc test` green does NOT prove the guard fires under pi. Keep live-fire out of the always-run regression — it needs auth and a real pi run.
- **Gotcha — a live pi-API e2e (one that actually SPENDS API, unlike `test-pi-dcg-gate.sh` / `test-pi-e2e.sh` which make no real model call) can fail because the cage's DEFAULT pi provider has an EXPIRED OAuth token.** `~/.pi/agent/auth.json` holds multiple providers; the default `openai-codex` is an OAuth token that expires (it lapsed 2026-06-08, breaking the first live pi e2e with "No API key for provider: openai-codex" — which reads like missing-auth but is stale-auth). The reusable lever is a static-API-key provider (no expiry): `pi --provider openrouter --model anthropic/claude-3.5-haiku -p "..."` (used by `test-agent-mail-concurrent.sh` — the repo's first real pi-API e2e). Before blaming a live-pi-e2e on missing auth, `jq '."openai-codex".expires' ~/.pi/agent/auth.json` (epoch ms) and fall back to a static-key provider, or have the human `pi /login`. Auth-free structural pi tests are unaffected.
- **See also:** `cage-claude.md` "Troubleshooting: subagent fails fast" section — codified runbook for the specific *"0 tool uses, ~2s"* pattern (auth-error narration is usually wrong; real cause is typically 1M-beta model + subagent, rate limit, or stale session).

### Direct guard probe — `dcg-guard` / `block-ssh-bypass.sh` over a JSON envelope
- **What it is:** pipe a PreToolUse envelope straight into the guard binary/script and read `permissionDecision` back. No agent, no model, no auth, no tmux session. `printf '{"tool_name":"Bash","tool_input":{"command":"echo hi && rm -rf ~"}}' | /usr/local/lib/rip-cage/bin/dcg-guard` → `deny`. Same shape for `hooks/block-ssh-bypass.sh`.
- **Speed:** sub-second.
- **Catches:** "does DCG actually block command X (including chained / substring-hidden X)" — the question, not whether an agent will *choose* to run it. The cheapest rung of the guard-verification ladder below `pi -p` / `claude -p` LOAD+FIRE.
- **Useful when:** auditing whether a guard layer is load-bearing before relaxing it (rip-cage-4r8); checking chaining-robustness after a `DCG_VERSION` bump; reproducing a deny decision in isolation. Same assertion shape `test-safety-stack.sh` checks 11f/11g/11h commit as regression.
- **Less useful when:** you need to prove the guard auto-LOADS under the agent runtime (extension/hook wiring) — that needs `pi -p` / `claude -p` (authed). This probe tests the engine, not the wiring (see `rip-cage-guard-engine-vs-policy-split`).

### Egress firewall probes
- **What it is:** `test-egress-firewall.sh` contains ready-to-copy curl/nc probes for denylisted hosts
- **Catches:** rules file not loaded, proxy misconfigured, rule regex bugs
- **Useful when:** editing `egress-rules.yaml`, `rip_cage_egress.py`, or `rip-proxy-start.sh`

### Real-hardware / remote-cage verification over SSH
- **What it is:** driving rip-cage on a real remote host (e.g. a fresh Mac mini via `ssh mac-mini`) to verify behavior the maintainer box masks — fresh-device cold-start UX, multi-arch GHCR image pull, `brew install` end-to-end. The local box always has a warm image + warm config; only a clean remote host proves the cold path. (Validated rip-cage-j86 / wo9, 2026-06-03.)
- **OrbStack PATH gotcha:** `docker` (and `~/.orbstack/bin`, `/usr/local/bin/docker`) are on PATH only in a **login** shell. A non-login `ssh host "docker ..."` finds `/opt/homebrew/bin` (so `orb` resolves) but NOT `docker`. Wrap every rc/docker command: `ssh mac-mini "zsh -lc '<cmd>'"`.
- **`rc up` over non-TTY ssh does NOT hang:** the attach helpers (`_up_attach_tmux` etc., rc ~3692-3768) are TTY-guarded (`[[ -t 0 && -t 1 ]]`). Non-TTY prints "Attach with: rc attach" and exits 0; the container (`sleep infinity`) persists. Drive in-cage work afterward via `docker exec -u agent -w /workspace <container> ...`.
- **Patched-rc without a release:** rc is a single bash script — overwrite the brew Cellar `libexec/rc` in place (siblings Dockerfile/hooks/pi/init stay intact, `_resolve_script_dir` still resolves) to test a patched rc on a real device before tagging. Restore with `brew upgrade` to the clean official build.
- **pi guard smoketest over docker exec:** a bare "run X" `pi -p` prompt yields EMPTY output when the guard blocks (pi emits no final text) — the block is invisible. Use a REPORT-style prompt: "run X, then tell me verbatim whether it ran or was blocked and paste the exact message." Same authed LOAD+FIRE altitude as the `pi -p` cell above, reached remotely.
- **Gotcha:** a prompt that itself contains `&&` / `;` / `||` trips the *local* compound hook before it ever reaches the remote shell — Write it to a `/workspace` file and feed via `pi -p "$(cat ...)"` (see bd memory `compound-hook-fires-on-remote-bound-operators`).

### Manual pre-release safety-stack validation on a fresh cage (release-gate altitude)
- **What it is:** before tagging a release, build a FRESH image and `rc up` a real cage, then by-hand confirm the safety floor holds end-to-end. Automated e2e is necessary but NOT sufficient at this altitude — it cannot prove a backend-default flip (the trixie nft regression is the canonical miss: structural tests pass 18/18 while the firewall is disarmed).
- **Checklist (run on the fresh cage; v0.6.0, 2026-06-08):** base correct (`cat /etc/os-release`) + iptables on the **legacy** backend (`iptables --version` shows legacy / `update-alternatives --query iptables` pin present, ADR-012 D10); DCG denies direct `rm -rf` AND `&&`-hidden `rm -rf`, allows a benign command (Direct guard probe cell above); ssh-bypass denies host-key-override flags; egress **ENFORCES** — a real denylisted host (`webhook.site`) returns HTTP 403 with the structured JSON body, an allowed host (`github.com`) passes, an observe-mode host (`example.com`) passes (EFFECT probe, not rule-presence — see `test-egress-firewall.sh` row + bd memory `rip-cage-firewall-rule-presence-not-enforcement`); `rc test` 76/76; manifest tools resolve in-cage + one TOOL-archetype counterfactual bake (`test-manifest-tool.sh` T1).
- **Useful when:** the pre-tag gate, ESPECIALLY after a base / dependency / iptables bump (exactly the change class automated e2e green-lights blindly).
- **Gotcha — your OWN host guard blocks the probe payload.** Feeding `rm -rf …` into the in-cage DCG probe trips the *host's* DCG guard (it matches the destructive substring in your Bash tool-call text before it reaches the cage). Write the payload to a file (Write bypasses the host hook) and feed via stdin redirect: `docker exec -i <cage> /usr/local/lib/rip-cage/bin/dcg-guard < /tmp/probe.json`. Same shape as bd memory `compound-hook-fires-on-remote-bound-operators` (DCG variant).

---

## Tools & CLIs

### `rc` (this repo's CLI) — host-only
- **Subcommands:** `build init up ls attach down destroy test doctor auth config schema completions setup exec reload`
- **Invariant:** hard-exits if `/.dockerenv` is present. It will never run inside a cage.
- **Schema:** `rc schema` prints a machine-readable command schema for agent consumption.
- **JSON mode:** `rc --output json <cmd>` for most commands.

### `bd` (beads) — issue tracking, used both host and in-container
- **What it is:** primary task tracker (see `CLAUDE.md` and `.beads/CLAUDE.md`)
- **Useful when:** you need to record/close/claim work — required over TodoWrite per CLAUDE.md
- **Host preflight:** `_bd_host_preflight` inside `rc` validates host-side dolt connectivity; runs as part of `rc test`

### Global tools assumed present (not pinned)
- `shellcheck`, `jq`, `docker`, `tmux`, `git`, `perl` (used by block-ssh-bypass.sh)
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

- **Compound commands are no longer blocked** by a PreToolUse hook (removed in rip-cage-4r8 — DCG is chaining-robust). However, the local Bash environment in this repo's hooks still runs via the global Claude Code session; if you have a compound blocker active on the host (outside the cage), you may still need to split commands in your own session.
- **`rc` is host-only.** It detects `/.dockerenv` and exits. Tests that orchestrate containers must run from the host.
- **Container-name derivation** uses `parent/basename` of the workspace path. Collisions get a 4-char hash suffix. E2E tests depend on this — stage workspaces carefully to get a deterministic name.
- **`.devcontainer/` and `.vscode/` are gitignored** — they're per-project scaffold from `rc init`. Don't commit.
- **Docker bind-mount parent dirs are created as root.** `init-rip-cage.sh` starts with `sudo chown agent:agent ~/.claude` to fix this; don't remove that line without replacing it.
- **ADR-numbered assertions** appear in test output (e.g. `[ADR-013 D1]`). Grep those IDs in `docs/decisions/` for context when a test fails.
- **SKIP_AUTH=1** downgrades auth-related failures in `test-safety-stack.sh` to INFO — use in CI/integration contexts where real credentials aren't available.
- **Driver-level fixtures in `tests/run-host.sh`** when `rc` adds a preflight that all `rc` invocations need. Pattern (ADR-023 example): `mktemp -d` a benign config, export via `:- default` (so per-test overrides work), `trap rm EXIT` cleanup. Per-file overrides via `unset RC_CONFIG_GLOBAL` at file top opt out. Adding only per-test fixtures misses tests added later. See commits `c3dc555` (driver default) and `0bd9ebc` (per-file unset).
- **Tests that print `FAIL` must `exit 1`** — not just print prose. Standard shape: maintain `FAILURES=0`, increment on `fail()`, end with `[[ $FAILURES -eq 0 ]] || exit 1`. Without this, `run-host.sh`'s `set -e` doesn't propagate; you get silent-red conditions like the pre-existing `test-code-review-fixes.sh` C2 false-positive that drifted unchecked from commit `cb8c23d` until rip-cage-3gu re-ran the full suite.
- **Dark-test detection — a `tests/test-*.sh` that no harness runs is the limit case of silent-red, zero executions (rip-cage-b6ia).** To check whether a test actually runs, grep for the ANCHORED `/test-NAME.sh` form (the driver's `${SCRIPT_DIR}/test-X.sh`), never a bare basename — `test-integration.sh` substring-collides inside `test-selftest-integration.sh` and reads as "wired" when it is truly dark. And "absent from `run-host.sh`" ≠ "never runs": 5 of 20 audited dark files ran via OTHER harnesses (`rc test`, `rc test --e2e`, `rc test --e2e-security`, `Dockerfile` build-time `RUN`), so grep ALL invokers — `tests/run-host.sh`, `rc` (the docker-exec test lists ~rc:5570-5684), `Dockerfile`, `Makefile`, CI yaml — before declaring a test dark OR assuming a sibling covers a surface. A mixed-tier file (host unit cases + live-cage cases) wired wholesale into `NEEDS_CONTAINER` drops its host cases from `--host-only` CI — legitimate only when a sibling wired test re-covers them (else it's silent host-coverage loss). Newly wiring a previously-standalone test makes it inherit the driver's exported precedence-winning env (e.g. `RC_CONFIG_GLOBAL` shadows the test's XDG sandbox) — `unset` it at the test's file top and confirm through-driver green, not just standalone green. See `rip-cage-test-fail-prose-without-exit-silent-red` (the silent-red family this extends) + `rip-cage-preflight-driver-fixture-pattern`.
- **Validate a baked config by PARSING it, not by running a fail-open consumer (rip-cage-hhh.11 / ADR-025 D5).** When `rc up`/init must confirm a baked config file (e.g. the cage-owned `DCG_CONFIG`) is well-formed before launch, do NOT gate on "ran the consumer, it exited 0" if the consumer silently skips malformed config — DCG fail-open-skips a bad `DCG_CONFIG` and still exits 0, so an exit-code check passes on a broken file (which, for DCG, re-opens the agent-writable user-layer hole). Validate with an independent strict parser that fails-closed (`python3 -c 'import tomllib; tomllib.load(open(p,"rb"))'` for TOML), and refuse to launch on parse failure (ADR-001 fail-loud). Pair the launch-time parse with a regression test that exercises the config's actual EFFECT (the floor still holds against a hostile `/workspace/.dcg.toml` or `~/.config/dcg/config.toml`) — "it loads" is not "it does the thing." Tripwire: any `if <consumer> <config> >/dev/null; then ok` style validation where `<consumer>` has a permissive/skip-bad-input loader. See `validate-config-by-parsing-not-by-running-fail-open-consumer` (bd memory).
- **DCG-policy changes: build → up → `rc test` + floor-uncrossable probe.** After touching the dcg-guard wrapper, the baked default DCG config, the `DCG_CONFIG` pin, or the `dcg.*` translation in `rc`, the fit loop is `./rc build` → `./rc up <scratch>` → `./rc test <name>` (safety-stack presence) PLUS the floor regression in `tests/test-dcg-policy.sh` / `test-safety-stack.sh` (a hostile workspace/user `.dcg.toml` must NOT weaken the guard; an additive rule MUST take effect; malformed translated config must fail `rc up` closed). Mechanism is DCG-version-coupled — on a `DCG_VERSION` bump, re-verify config-discovery-from-process-CWD and user-layer-suppression-on-`DCG_CONFIG` (ADR-025 D3/D5 "what would invalidate"). Pi cages reach the same floor via the auto-loaded `dcg-gate.ts` extension (rip-cage-bl1, SHIPPED) — it routes through the same `dcg-guard` wrapper, so the floor/additive regression applies identically; verify the pi path with `test-pi-dcg-gate.sh` (auth-free) + the headless `pi -p` LOAD+FIRE cell above (authed).
- **Release-gating signals run through repo-pinned artifacts, not CI re-implementations.** `make lint` (pinned `koalaman/shellcheck:v0.11.0`) and `tests/run-host.sh --host-only` are the single sources of truth CI invokes verbatim. Never `apt-get install` a tool in a workflow (version drifts from local) or hand-maintain a parallel test list / fixture in CI (drifts from the driver). 3 v0.4.x tags burned on shellcheck 0.9.0-vs-0.11.0 divergence (wn4). Tripwire: `apt-get install ... shellcheck` or a second test-list/fixture outside `run-host.sh` in any workflow = regression.
- **Epic/parent close: re-verify the DELTA since the last recorded re-verify, and sweep for carry-forward doc obligations.** A recorded "Parent re-verify (DATE)" note is a cursor, not a conclusion. `git log --since=<that-date>` for sibling releases/beads touching the epic's named surfaces — a release can delete a mechanism an acceptance item references by name (rip-cage-4r8 removed the compound-blocker that rip-cage-hhh's pi-parity acceptance named, after that epic's 2026-05-28 re-verify). Separately, sweep the acceptance / `--design` for cross-reference / vocab-sync / "X references Y" / "reconcile Z before close" obligations — the residue no per-bead test catches and that the close-time conjunction re-verify exists to find. Recurred across two epic closes (claude-smy, rip-cage-hhh). See `epic-close-reverify-delta-and-carry-forward-sweep` (bd memory).
- **A baked test/artifact must never depend on a fixture read from `/workspace` (or any variable mount path) (rip-cage-16t).** `test-safety-stack.sh` is `COPY`'d into the image and runs via `rc test <container>` inside ANY cage, but `/workspace` is the rip-cage repo only in the repo's own cage. Check 11e loaded its DCG rule-pack fixture from `/workspace/tests/fixtures/…`; in every other cage the fixture was absent, DCG fail-open-skipped the missing `custom_paths` entry, and the check failed — green in the dev cage, red everywhere else (it surfaced via the e2e lifecycle's in-container `rc test` checks [7]/[20]). Bake any fixture a baked test/init-script/config needs into the image (Dockerfile `COPY` to an image-local path) and resolve the baked path first with a `/workspace` fallback for repo-dev. Tripwire: a `/workspace/…` path literal inside any file that gets `COPY`'d into the image. Compounds with the fail-open-skip class above (line 231): the missing fixture didn't error, it silently no-op'd, so the test "passed absence" rather than failing loud — same family as the false-green-from-empty-source class (`rip-cage-test-fail-prose-without-exit-silent-red` bd memory).
- **A gated or stubbed e2e probe the always-run suite never executes is a false-green class — the worked-example / integration child MUST run it for real (rip-cage-4c5).** Manifest tests self-skip their e2e tier behind `RC_E2E` (`run-host.sh`); the default suite never sets it, so child-close green can mean "codegen works," never "a real cage builds/runs." C5 (rip-cage-4c5.5) closed `verdict:pass` with its daemon e2e gated — two latent build/runtime bugs (daemon-config Dockerfile step injected before `/etc/rip-cage` existed; state-dir not chown'd to agent) survived close and surfaced only when C6's first REAL `RC_E2E=1` build ran (fixed rip-cage-4c5.9). Same epic: C6 shipped `NOT-YET-IMPLEMENTED` stubs that `exit 0` under RC_E2E=1; C7 shipped authored-but-gated regressions. Host-tier codegen and gated e2e are DIFFERENT ALTITUDES — green on one says nothing about the other. This is the third false-green shape (probe-never-executed) beyond silent-red (prose-FAIL-exit-0) and absence-against-empty-source. Tripwire: closing the daemon / worked-example / integration child of a multi-archetype unit without one real `RC_E2E=1` build+run on a fresh cage. See `rip-cage-test-fail-prose-without-exit-silent-red` (data point 4).
- **For safety-guard EFFECT verification, prefer a container integration test that flushes the REAL rule over a structural-presence test (rip-cage-fft).** To prove a guard actually catches a disarmed safety layer, the load-bearing test flushes the real mechanism (e.g. `iptables -t nat -F OUTPUT` in a throwaway cage) and asserts the guard classifies BYPASSED + exits non-zero — a presence-only test is fail-open-blind (`rip-cage-firewall-rule-presence-not-enforcement`). Pair it with a PURE classifier unit test (outcome → verdict, no live firewall) for the fast loop. Two anti-patterns this surfaced: (1) a **production env-var test hook** that overrides the guard outcome is a live-path disable surface — drive tests with a curl PATH-shim instead, never an in-code override; (2) green tests do not prove invariants — an implementer "fix" (routable probe host) passed all tests while silently regressing the no-external-dependency invariant, caught only by a close-gate review that checked INVARIANTS not green. See `mitmproxy-selftest-probe-inversion-lazy-connect` (bd memory) for the probe-inversion design.
- **An agent-driven e2e where the agent merely LAUNCHES one self-contained script is a false-green: agent-as-launcher (rip-cage-swv) — a FOURTH false-green shape beyond the three in the silent-red bd memory.** When proving an agent (pi / claude) *coordinates* — not just that a CLI works — a single `pi -p "run this poll-script"` where the script does all the polling/extraction itself greens even though the agent never reasoned: the script is the agent, pi is a process launcher (≈ the bare-`am`-no-pi shortcut one level removed). swv's first impl did exactly this and passed live before review caught it. The discriminating proof is the agent's OWN iteration: **≥2 distinct tool invocations visible** (swv asserts `POLL_COUNT -ge 2` in `test-agent-mail-concurrent.sh:573` — ≥2 `am mail inbox` poll-log entries proving pi reasoned BETWEEN polls), AND the load-bearing artifact (the received body) is produced by the agent's own tool action (pi writes the result file via `am mail inbox ... --json > result`), never a wrapper's stdout. Pairs with the `pi -p` / `claude -p` LOAD+FIRE cells (which prove the guard fires, not that the agent has *agency*). Tripwire: any `<agent> -p "<prompt that hands off a complete script>"` e2e — check the prompt makes the agent iterate, not delegate. See `rip-cage-test-fail-prose-without-exit-silent-red` (bd memory, data point 6).
- **When new work needs a fixture SHARED with a CLOSED bead, give the new work its OWN fixture and revert the shared one — don't mutate the shared fixture and leave the closed bead's green unverified (rip-cage-swv).** swv's CLI path needed the agent_mail daemon in `am serve-http --no-auth` mode (the documented `mcp-agent-mail serve` returns JSON-RPC -32002 Forbidden on mutating CLI calls). The shared `tests/fixtures/manifest-agent-mail.yaml` is used by the closed T2d demo via the MCP-client path; mutating it would silently put T2d's green at risk. Fix: swv ships its own `manifest-agent-mail-concurrent.yaml` and reverts the shared one — isolation removes regression risk on closed work with certainty, vs. re-running the closed bead green with the mutation.
- **Init-ordering / first-boot behavior is invisible to a pre-initialized container — verify against a COLD `rc up`, not a warm cage (rip-cage-p1p bf657ab).** A test or subagent that runs against an already-booted cage (`RC_TEST_CONTAINER=<running>`, or `docker exec` into a warm container) exercises STEADY-STATE and never re-runs `init-rip-cage.sh`'s first-call sequence. Any bug in the ORDER of init steps — a snapshot taken after its first consumer call, an env export after its first reader, a chown after the dir is used — greens through, because by the time the verifier attaches, init already ran (correctly or not; the artifact looks identical afterward). The p1p R4 snapshot-ordering bug (a cry-wolf "no snapshot found" warning on every healthy boot, because the snapshot block ran after init's first `claude --version`) was caught ONLY by the orchestrator's own fresh `./rc up <cold scratch>` reading init's stdout in order — never by the implementer's `RC_TEST_CONTAINER` harness runs against a warm cage. Fit rule: for any change to `init-rip-cage.sh` step ORDER, or behavior gated on "first call after boot," the feedback loop MUST be `./rc build` → `./rc up <fresh workspace>` → read init's stdout/stderr in sequence — not `rc test` / a NEEDS_CONTAINER test against a warm cage. Pairs with the own-shell re-verification posture (verify a claimed green in your own shell; subagent reports describe intent, not outcome).
- **Monitoring an UNPINNED safety-relevant dependency (`@latest`) — use a content/schema drift tripwire, not a version-equality tripwire (rip-cage-9yg0).** When a safety layer's correctness rests on a dependency's surface (e.g. the pi dcg-gate only inspects the `command` field; a new pi exec-tool with a different field would pass unguarded) and that dependency is installed at `latest`, the re-verify check should assert the actual surface property (grep the installed dist for the schema/field the guard assumes; enumerate the tool set) so it fires ONLY on real drift. A version-equality tripwire (record-verified-version vs installed) fires on every bump including harmless patches → reds the safety stack constantly → banner-blind / "annoying" (ADR-019 D2). Sentinel-gate the content check so it fails-CLOSED if its grep target moves (assert the known schema/field is FOUND first; validate against the PARSED result, not a free file-grep — else a dist reformat silently vacuous-passes, blinding the tripwire). Lives in `tests/test-pi-dcg-gate.sh` §5 (reached via `rc test`). Tripwire when reviewing such a check: can it pass if its target file/format changed? If yes, it's not fail-closed.
- **A named harness skip is LEGITIMATE — and stronger than "trivial" — when the changed code branch is UNREACHABLE by the available harness (rip-cage-16c).** Distinct from the false-green family above (there the harness runs but the assertion proves nothing); here the harness correctly does NOT run, because the edited branch can't be triggered by any installed/pinned dependency version. 16c fixed an inverted-FAIL in `test-pi-dcg-gate.sh` check 4b that fires only when dcg DENIES `mcp_exec`; the current dcg fails-OPEN on `mcp_exec`, so `./rc build` → `./rc up` → `./rc test` exercises only the UNCHANGED allow branch — identical output before/after the edit, **zero discriminating power** for the change. The proportionate harness there is static review: `bash -n` + the polarity flip correct by inspection + confirm the *reached* (allow) branch stays green. Skip rationale to record on the bead is "changed branch unreachable by harness," NOT "trivial-shape" — a stronger, more honest skip. Tripwire before stamping this skip: (1) confirm the UNCHANGED reached-branch is still green (you're skipping only the unreachable delta, not the whole test); (2) confirm the branch is unreachable because the *dependency never triggers it*, not merely because *you didn't set up the input* (the latter is a real gap, not an unreachable branch). When a later dependency bump could make the branch reachable, that bump is the re-verify trigger.
- **A `docker build` of a FROM-scratch / digest-only image used as a test fixture silently no-ops under a containerd image store (rip-cage-na5j).** On Docker 29.4.0 with io.containerd.snapshotter.v1 (the DEFAULT on debian trixie), a scratch-build digest is not an inspectable local image, so `docker tag`-ing it over a tag (e.g. rip-cage:latest) does not take — the staleness/version path under test never fires. A positive test hard-reds; its asserted-absence sibling passes VACUOUSLY (ELSE branch never reached). Build fixtures from a REAL base image (e.g. a `docker build -t … -` of `FROM alpine:3.19` + a `LABEL`) so the image is inspectable, and gate the assertion on a positive sentinel that the tag swap landed (inspect the label, confirm it != the expected value) before trusting the effect. See `rip-cage-test-fail-prose-without-exit-silent-red` (bd memory, data point 7).
- **A test that reconstructs the production setup (`docker run -v`) instead of calling the shipped assembler (`cmd_up` / `_cm_build_mount_arg`) is a bypass-path false-green (rip-cage-l0u2.5)** — the real wiring has zero coverage. Fix: extract a helper + assert on it + revert→RED. See `rip-cage-test-fail-prose-without-exit-silent-red` (bd memory, data point 8).
- **A test that mutates shared LIVE host state must restore via `trap … EXIT INT TERM`, armed before the mutation (rip-cage-na5j).** When a test tags a stub over the user's real rip-cage:latest or renames the tracked VERSION file (rc re-reads VERSION unconditionally at rc:60, so an env override does NOT substitute — in-place mutation is unavoidable), a normal-path restore alone leaves an interrupt-window where Ctrl-C strands a stale image (breaks the user's next `rc up`) or a renamed VERSION (breaks the repo). Arm an IDEMPOTENT `trap '<restore>' EXIT INT TERM` before the mutation; disarm with `trap -` only after the normal-path restore. See `test-mutating-shared-live-state-needs-crash-safe-trap` (bd memory).

---

## Entrypoints

- `rc` — top-level CLI; all roads start here (usage at line 109, dispatch around line 2412)
- `init-rip-cage.sh` — what happens on first container start
- `Dockerfile` — image definition (Go → Rust → Debian runtime)
- `settings.json` — Claude Code config shipped into the container (hooks, MCP, permissions)
- `tests/run-host.sh` — canonical host-test runner
- `docs/ROADMAP.md` + `docs/decisions/` — where to go for "why"
- `.beads/` — issue state (dolt-backed; `bd prime` loads context)
