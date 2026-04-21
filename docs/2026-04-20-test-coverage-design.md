# Test Coverage Expansion — Design Doc

**Date:** 2026-04-20
**Status:** Proposed
**Related ADRs:** [ADR-004](decisions/ADR-004-phase1-hardening.md) (rc test), [ADR-012](decisions/ADR-012-egress-firewall.md) (egress)
**Beads:** TBD (filed alongside this doc)
**Triggered by:** Full destroy/rebuild validation on 2026-04-20 surfaced four real bugs (python3-venv, CA env propagation, resume TTY guard, proxy listener probe). None were caught by the existing automated suites — all found by manual e2e exercise.

## Summary

Rip-cage ships 17 test files totalling ~3,500 lines, but only **3 of them** (59 checks) run via `rc test`. The other **12 host-side tests are unwired** — no CI, no pre-commit, no `rc` subcommand runs them. Of those 12, **10 are silently broken** from a directory-layout drift (tests moved into `tests/` without updating `SCRIPT_DIR` resolution).

Result: real regressions ship unblocked. The four 2026-04-20 bugs all would have been caught by a simple e2e lifecycle test that doesn't exist.

This doc proposes three additions:

1. **New**: `tests/test-e2e-lifecycle.sh` — host-run, exercises `rc build → up → test → down → up → destroy`.
2. **Fix**: resurrect the 10 broken host tests (path drift), and wire all host tests into one `tests/run-host.sh` entrypoint invoked by a new `rc test --host` mode.
3. **Expand**: egress suite gains WebSocket, IPv6, DNS-exfil, and non-HTTP-port (22, 25) checks — the current suite validates the denylist but not the *perimeter*.

## Problem

### What the current suites cover

| Suite | Location | Wired to `rc test`? | Passing |
|---|---|---|---|
| `test-safety-stack.sh` | in container | yes | 35/35 |
| `test-skills.sh` | in container | yes | 11/11 |
| `test-egress-firewall.sh` | in container | yes | 13/13 on / 3/3 off |
| `test-rc-commands.sh` | host | no | 19 failing (path drift) |
| `test-auth-refresh.sh` | host | no | pass |
| `test-worktree-support.sh` | host | no | 0/25 (path drift) |
| `test-security-hardening.sh` | host | no | fail (path drift) |
| `test-completions.sh` | host | no | pass |
| `test-json-output.sh` | host | no | 7 failing (path drift) |
| `test-prerequisites.sh` | host | no | 14 failing (path drift) |
| `test-dockerfile-sudoers.sh` | host | no | fail (path drift) |
| `test-bd-wrapper.sh` | host | no | fail (path drift) |
| `test-agent-cli.sh` | host | no | fail (path drift) |
| `test-code-review-fixes.sh` | host | no | 5 failing (path drift) |
| `test-dg6.2.sh` | host | no | 16 failing (path drift) |
| `test-integration.sh` | host | no (but runs full image build) | unknown — docker-dependent |
| `test_skill_server.py` | host/container | no | unknown |

### Gap map — what no test guards today

**Lifecycle (the big one)**
- `rc up` → resume path (the exact TTY bug fixed 2026-04-20 shipped unguarded)
- Volume persistence across `rc down → rc up`
- `rc.egress` label read on resume (egress-mode round-trip)
- Container-name collision → `-XXXX` hash suffix
- `rc destroy` actually removing volumes

**Egress perimeter (denylist is tested; the walls aren't)**
- `ip6tables` — no IPv6 rules; if the container has IPv6 egress, the firewall is bypassed entirely
- WebSocket (`wss://`) — a standard exfil channel
- DNS exfil over UDP 53 (allowed by design today — should be an explicit test asserting the known-allowed behaviour)
- Non-HTTP ports: 22 (git-over-ssh), 25 (smtp), arbitrary high ports
- Raw sockets (if agent has `CAP_NET_RAW`; we believe it doesn't, but no test)

**Auth / identity**
- Auth hot-swap while container is running (`rc auth refresh`)
- `init-rip-cage.sh` graceful degradation when `.credentials.json` is missing
- SSH key mounting / `GIT_AUTHOR_*` propagation for commit identity

**Safety-stack edge cases**
- Compound blocker: heredocs, quoted `;` inside strings, backticks, nested `$(...)`
- DCG bypass attempts: base64-encoded destructive commands, aliasing, PATH injection
- Settings merge idempotency across *repeated* `init-rip-cage.sh` invocations (current test runs once)

### Why so many host tests are silently broken

Tests were moved into `tests/` at some point but the majority still compute:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/rc"        # resolves to tests/rc — doesn't exist
```

instead of `${SCRIPT_DIR}/../rc`. `test-auth-refresh.sh` has the correct form. The rest don't. Nothing caught it because nothing runs them.

## Proposal

### 1. New: `tests/test-e2e-lifecycle.sh` (P1)

Host-run, docker-native. Exercises the real `rc` CLI end-to-end against a disposable scratch directory and a dedicated container name (`rc-e2e-test`). Supersedes `tests/test-integration.sh` — its unique checks (tool list, CLAUDE.md leak, hook path consistency, bd-real exec bit) fold in here; running two overlapping lifecycle scripts guarantees drift.

**Pre-cleanup (crash-resistance):** before any check runs, `docker rm -f rc-e2e-test` and `docker volume rm rc-state-rc-e2e-test` (both tolerating "no such object") so a prior aborted run doesn't flip the next run into the name-collision code path. `trap CLEANUP EXIT` still handles the happy path.

**Checks (target: 22–28):**

Lifecycle skeleton:
1. `rc build` succeeds (skipped unless `RC_E2E_REBUILD=1` is set — flag polarity: `=1` means rebuild, default is reuse local image)
2. Create scratch workspace (`mktemp -d`), seed with `.git` and README
3. `rc up` headless (no tmux attach) → container running with `rc.egress=on` label
4. Scratch workspace bind-mounted at `/workspace` (verify via `docker exec ... test -f /workspace/README`)
5. `/workspace/.rip-cage/` writable by agent
6. **Regression guard for 2026-04-20 fix #1 (python3-venv)**: `docker exec <name> dpkg -s python3-venv` returns ok AND `docker exec <name> python3 -m venv /tmp/venv-probe` creates a working venv. A plain `rc build` is not a guard here — Docker will reuse a cached layer even if the Dockerfile line is deleted.
7. `rc test <name>` returns 0 and reports all three in-container suites pass
8. `rc ls` shows the container with the expected source path (assert `realpath`-equal, not literal string match — macOS `mktemp -d` returns `/var/folders/...` which resolves to `/private/var/folders/...`)
9. Expected tool set present inside the container (absorbed from `test-integration.sh`: `bd`, `ms`, `rg`, `fd`, `git`, `gh`, `jq`, `claude`, etc. — exact list pinned in the script)
10. No host secrets leaked to `/workspace/CLAUDE.md` or agent home (absorbed from `test-integration.sh`)
11. Hook path consistency: `settings.json` hook paths all resolve inside the container (absorbed from `test-integration.sh`)
12. `docker stop <name>` (simulating `rc down`)
13. `rc up` on the same workspace → resume branch hit, egress mode preserved from label
14. Volume `rc-state-*` still mounted, contents intact
15. `rc test` still 59/59 after restart
16. **Regression guard for 2026-04-20 fix #3 (resume TTY)**: `rc up <path> </dev/null` (stdin from `/dev/null`) against an already-running container returns exit 0 AND does not launch a tmux attach (check via process tree or a state sentinel). Do NOT grep stderr for the docker-CLI wording — that string varies across docker versions.
17. **Regression guard for 2026-04-20 fix #2 (CA env)**: `docker exec <name> env` shows `NODE_EXTRA_CA_CERTS` set (egress=on path)
18. `rc destroy` removes container AND volume (verify with `docker volume ls`)
19. Second container in separate scratch dir → name collision produces `-XXXX` suffix

Egress-off variant:
20. `RIP_CAGE_EGRESS=off rc up` → label reads `off`, no mitmproxy, no iptables REDIRECT, `test-egress-firewall.sh` runs its 3-check off-mode branch

Failure modes:
21. `rc up` with no scratch dir → clear error, no partial container
22. `rc up` with Docker daemon down — run in an isolated subshell (`( DOCKER_HOST=tcp://127.0.0.1:1 rc up ... )`) so the rogue `DOCKER_HOST` never leaks into the rest of the test. Tolerate skip if the subshell pattern proves flaky on some environments.

**Runtime budget:** one full build + two container lifecycles. **Target** ~90–180s warm cache, 5–8min cold — to be validated empirically on first implementation and revised if off; CI cold-build without a warm buildx cache may be longer because DCG `cargo build --release` dominates. Image build is the long pole and is skippable via the `RC_E2E_REBUILD` default.

**Wiring:** new `rc test --e2e` mode (host-run). `rc test` without flags keeps its current behaviour (in-container 59 checks). See §2 for the host-only invariant that applies to both `--e2e` and `--host`.

### 2. Fix broken host tests + unify entrypoint (P2)

**Host-only invariant:** `rc` hard-exits with "rc is a host tool" when invoked inside a container (sees `/.dockerenv`). Therefore `rc test --host` is a host-side developer/CI tool only — it will never run from inside an attached rip-cage container, and agents working inside rip-cage cannot invoke it. Document this plainly in §1's wiring note and in the `rc test --host` help text.

**Fix pattern, not a single sed.** The broken tests reference multiple repo-root paths (`rc`, `AGENTS.md`, `Dockerfile`, `bd-wrapper.sh`, `init-rip-cage.sh`, etc.), so `${SCRIPT_DIR}/rc` → `${SCRIPT_DIR}/../rc` is insufficient. Convert each script to:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# every other repo-root reference derives from REPO_ROOT
```

**Audit step (mandatory after the path fix).** Path drift was hiding content regressions. Example: `test-rc-commands.sh` Test 1 asserts the word `build` appears in `rc`'s usage output — it doesn't today, so the test will fail the moment it's resurrected. After the mechanical fix, run each resurrected test once, record pass/fail, and for each failure decide: repair the assertion, delete the test as superseded, or document it as a known-failing TODO with a beads issue. Don't wire a test into `run-host.sh` until it passes or is explicitly quarantined.

Then add `tests/run-host.sh`:

```bash
#!/usr/bin/env bash
# Runs every host-side test. Exits non-zero on any failure.
# Called by `rc test --host` and CI.
```

**Alternative considered:** bats-core (battle-tested bash testing framework with TAP output, test isolation, setup/teardown, timing, skip flags). Lower churn for the `run-host.sh` path since rip-cage already leans on plain bash for testability and avoids tooling bloat. Revisit bats in a follow-up if the JSON/TAP integration becomes painful; the migration is mechanical.

After P2 every host test is either (a) passing and wired into `run-host.sh`, (b) deleted as superseded, or (c) documented as dependent on specific host state (e.g. macOS-only keychain tests) with a skip-guard. No silent rot.

### 3. Egress perimeter expansion (P3)

**Blocker.** P3 is sequenced behind a decision on ADR-013 D4 (non-HTTP egress policy). Until D4 is promoted to FIRM (and ADR-012's open section closes in lockstep), the shape of the non-HTTP test below is undecided. P1 and P2 can ship without P3.

Add to `test-egress-firewall.sh`:

- **IPv6 perimeter (active probe, not capability check)**: `curl -6 --max-time 5 https://ipv6.google.com` from inside the container must fail (no route / blocked). A capability check like "does `ip6tables` have rules OR is `/proc/net/if_inet6` empty?" is a tautology today — the container has only `::1` and `init-firewall.sh` has zero `ip6tables` references, so the OR evaluates trivially. The active probe is environment-independent and survives Docker daemon IPv6 changes.
- **WebSocket denylist**: `curl -N --http1.1 -H 'Upgrade: websocket' -H 'Connection: Upgrade' https://webhook.site/...` — expect 403 with `X-Rip-Cage-Denied`. If mitmproxy doesn't intercept pre-upgrade WebSocket negotiation correctly, this is a real hole.
- **Non-HTTP outbound ports (iptables-level, not network probe)**: assert the iptables rule set does not REDIRECT or DROP traffic on ports other than 80/443 (verify via `iptables -t nat -L OUTPUT -n` and `iptables -L OUTPUT -n`). Do NOT use `nc -zv github.com 22` as a positive probe — hosted Docker environments (OrbStack, Docker Desktop forwarding, cloud runners) may block outbound port 22 at the network edge, making the test flaky across developer machines. If a positive network probe is needed for a specific environment, gate it behind `RC_E2E_EXPECT_INTERNET_PORT_22=1` and skip by default.
- **DNS-over-TLS / DoH**: denylist already lists common DoH resolvers; add a positive test that one denies.

Policy decision (resolve before P3 lands): **are non-HTTP outbound connections in scope?** Today the firewall only intercepts TCP 80/443. Anything on other ports bypasses it entirely. This is either a documented accepted risk or a real gap depending on the threat model. See ADR-013 D4 and ADR-012's open section; P3 is blocked on promoting D4 to FIRM.

## Non-goals

- **Test-level parity with ClaudeBox.** Their test surface is different because their architecture is different. We test what rip-cage uniquely ships (safety stack, egress, auth hot-swap, skill mounting).
- **Full property-based / fuzz testing of the compound blocker.** Worth doing eventually, out of scope here.
- **Replacing `rc test`'s in-container suite with e2e.** The in-container suite is fast (~20s) and runs per-session; e2e is the slow, pre-release checkpoint.

## Open questions

1. CI integration — add GitHub Actions workflow in a follow-up? Requires docker-in-docker or self-hosted runner for the e2e job.
2. Non-HTTP egress policy (see §3 and ADR-013 D4). Blocks P3 only; P1/P2 proceed regardless. Needs product input, not just engineering.

**Resolved during design review (2026-04-20):**
- `test-integration.sh` is superseded by `test-e2e-lifecycle.sh` — its unique checks fold in to §1.
- `rc test --e2e` reuses the local image by default; set `RC_E2E_REBUILD=1` to rebuild.

## Out of scope for this doc

- Implementation of the tests themselves — this doc is the plan, not the code.
- Changes to the safety stack or egress rules. Test coverage only.

