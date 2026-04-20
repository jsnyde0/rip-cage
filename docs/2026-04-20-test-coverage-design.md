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

Host-run, docker-native. Exercises the real `rc` CLI end-to-end against a disposable scratch directory and a dedicated container name (`rc-e2e-test`). Cleans up volume + container on exit.

**Checks (target: 20–25):**

Lifecycle skeleton:
1. `rc build` succeeds (skipped if `rip-cage:latest` already present and `RC_E2E_REBUILD=0`)
2. Create scratch workspace (`mktemp -d`), seed with `.git` and README
3. `rc up` headless (no tmux attach) → container running with `rc.egress=on` label
4. Scratch workspace bind-mounted at `/workspace` (verify via `docker exec ... test -f /workspace/README`)
5. `/workspace/.rip-cage/` writable by agent
6. `rc test <name>` returns 0 and reports all three suites pass
7. `rc ls` shows the container with correct source path
8. `docker stop <name>` (simulating `rc down`)
9. `rc up` on the same workspace → resume branch hit, egress mode preserved from label
10. Volume `rc-state-*` still mounted, contents intact
11. `rc test` still 59/59 after restart
12. **Regression guard for 2026-04-20 fix #3**: resume `rc up` runs from non-TTY context without emitting "the input device is not a TTY" (capture stderr, grep)
13. **Regression guard for 2026-04-20 fix #2**: non-interactive `docker exec <name> env` shows `NODE_EXTRA_CA_CERTS` set
14. `rc destroy` removes container AND volume (verify with `docker volume ls`)
15. Second container in separate scratch dir → name collision produces `-XXXX` suffix

Egress-off variant:
16. `RIP_CAGE_EGRESS=off rc up` → label reads `off`, no mitmproxy, no iptables REDIRECT, `test-egress-firewall.sh` runs its 3-check off-mode branch

Failure modes:
17. `rc up` with no scratch dir → clear error, no partial container
18. `rc up` with Docker daemon down (mockable via `DOCKER_HOST=tcp://127.0.0.1:1` if feasible) — tolerate skip

**Runtime budget:** one full build + two container lifecycles. Expected ~90–180s on a warm cache, 5–8min cold. Image build is the long pole and is skippable.

**Wiring:** new `rc test --e2e` mode (host-run). `rc test` without flags keeps its current behaviour (in-container 59 checks).

### 2. Fix broken host tests + unify entrypoint (P2)

Mechanical fix: `${SCRIPT_DIR}/rc` → `${SCRIPT_DIR}/../rc` and equivalents (`Dockerfile`, `bd-wrapper.sh`, etc.) — `${SCRIPT_DIR}/../`. Do this in one sweep, verify each test passes in isolation, then add `tests/run-host.sh`:

```bash
#!/usr/bin/env bash
# Runs every host-side test. Exits non-zero on any failure.
# Called by `rc test --host` and CI.
```

After P2 every host test is either (a) passing, (b) documented as deleted/superseded, or (c) documented as dependent on specific host state (e.g. macOS-only keychain tests). No silent rot.

### 3. Egress perimeter expansion (P3)

Add to `test-egress-firewall.sh`:

- **IPv6 check**: `ip6tables -L OUTPUT -n` — either has matching rules OR IPv6 egress is verified blocked at the interface. Today we suspect the latter (no IPv6 in container), but it's untested.
- **WebSocket denylist**: `curl -N --http1.1 -H 'Upgrade: websocket' -H 'Connection: Upgrade' https://webhook.site/...` — expect 403 with `X-Rip-Cage-Denied`. If mitmproxy doesn't intercept pre-upgrade WebSocket negotiation correctly, this is a real hole.
- **Non-HTTP outbound ports**: `nc -zv github.com 22` (git-over-ssh) — document expected behaviour (currently allowed, no proxy, direct connect). If expected-allowed, assert it works; if expected-blocked, add iptables rule + test.
- **DNS-over-TLS / DoH**: denylist already lists common DoH resolvers; add a positive test that one denies.

Decision required (captured in ADR update, see below): **are non-HTTP outbound connections in scope?** Today the firewall only intercepts TCP 80/443. Anything on other ports bypasses it entirely. This is a documented accepted risk or a real gap depending on the threat model.

## Non-goals

- **Test-level parity with ClaudeBox.** Their test surface is different because their architecture is different. We test what rip-cage uniquely ships (safety stack, egress, auth hot-swap, skill mounting).
- **Full property-based / fuzz testing of the compound blocker.** Worth doing eventually, out of scope here.
- **Replacing `rc test`'s in-container suite with e2e.** The in-container suite is fast (~20s) and runs per-session; e2e is the slow, pre-release checkpoint.

## Open questions

1. Where does `test-integration.sh` fit — is it superseded by the new e2e test, or kept as a thinner smoke test?
2. Should `rc test --e2e` auto-rebuild the image, or strictly reuse the local one? (Leaning: reuse, with `--rebuild` flag.)
3. CI integration — add GitHub Actions workflow in a follow-up? Requires docker-in-docker or self-hosted runner for the e2e job.
4. Non-HTTP egress policy (see P3 decision-required note). This needs product input, not just engineering.

## Out of scope for this doc

- Implementation of the tests themselves — this doc is the plan, not the code.
- Changes to the safety stack or egress rules. Test coverage only.
