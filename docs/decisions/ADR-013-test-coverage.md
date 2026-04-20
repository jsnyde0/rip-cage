# ADR-013: Test Coverage Tiers — In-Container vs E2E vs Host-Script

**Status:** Proposed
**Date:** 2026-04-20
**Design:** [2026-04-20-test-coverage-design.md](../2026-04-20-test-coverage-design.md)
**Related:** [ADR-004](ADR-004-phase1-hardening.md) (rc test origin), [ADR-012](ADR-012-egress-firewall.md) (egress suite)

## Context

Rip-cage has three *implicit* testing tiers today, only one of which is reliable:

1. **In-container suite** (`rc test`): 3 scripts, 59 checks, ~20s. Exercises the live container from the inside. Wired, fast, trusted.
2. **Host-side scripts** (12 files, ~2,900 lines): intended to test the `rc` CLI itself. 10 of 12 silently broken by a `tests/` directory move that left `SCRIPT_DIR="${SCRIPT_DIR}/rc"` pointing at non-existent paths. Not wired into any automation.
3. **Manual e2e**: destroy/rebuild/up/down exercises done by humans. This tier caught all four bugs fixed on 2026-04-20 (python3-venv missing, CA env propagation, resume TTY, proxy listener probe).

Tier 2's rot is invisible because nothing runs it. Tier 3 is the only real guard for lifecycle regressions, and it doesn't run automatically.

## Decisions

### D1: Keep `rc test` as the fast in-container tier; add `rc test --e2e` as the slow lifecycle tier

**Firmness: FIRM**

`rc test` (no flags) continues to run only the in-container suites (safety, skills, egress). Fast (~20s), per-session, cheap enough that contributors run it routinely.

`rc test --e2e` (new) runs `tests/test-e2e-lifecycle.sh` on the host, exercising the full CLI lifecycle against a disposable scratch workspace. Slow (90s–8min depending on image cache), run before commits that touch `rc`, `init-rip-cage.sh`, or the Dockerfile.

**Rationale:** separating tiers by speed preserves the ~20s loop that contributors actually use, while giving real coverage for the lifecycle bugs the in-container suite structurally cannot see (it runs *after* the container is already up).

### D2: Host-side tests live behind `rc test --host` and have one entrypoint

**Firmness: FIRM**

Consolidate the 12 host-side scripts behind `tests/run-host.sh` and expose it as `rc test --host`. Fix the directory-layout drift in one sweep. Any script that can't be resurrected gets deleted or documented as superseded — no silent rot.

**Rationale:** unwired tests are worse than no tests. They burn contributor time on stale failures and give false confidence that surface is covered. Either something is exercised by automation or it isn't in the suite.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| Fix drift, keep unwired | Minimal churn | Won't stay fixed — will rot again |
| Delete all broken tests | Simple | Loses real coverage (worktree, sudoers pinning, DCG6.2) |
| **Fix + wire via `run-host.sh`** | Preserves coverage, guards against future rot | One-time cleanup cost |

### D3: E2E test owns regression guards for 2026-04-20 fixes

**Firmness: FIRM**

The four fixes from 2026-04-20 each get an explicit assertion in `test-e2e-lifecycle.sh`:

1. **python3-venv present**: `rc build` from a cold cache succeeds (runtime check, implicit in build step).
2. **CA env propagation**: `docker exec <name> env | grep NODE_EXTRA_CA_CERTS` succeeds when egress=on.
3. **Resume TTY guard**: `rc up` on an already-running container from non-TTY stdin produces no "input device is not a TTY" error.
4. **Proxy listener check**: `test-egress-firewall.sh` check [2] uses `/proc/net/tcp` LISTEN parse, not curl probe.

**Rationale:** bugs without a failing test aren't fixed, they're forgotten. An explicit regression guard per fix is cheap and makes the history self-documenting.

### D4: Egress perimeter tests expand; non-HTTP egress policy becomes explicit

**Firmness: PROPOSED**

Current egress suite validates the L7 denylist but not the L3/L4 perimeter. Add:

- IPv6 coverage: assert either `ip6tables` rules exist OR IPv6 egress is not available in the container. Today it's the latter, but untested.
- WebSocket denylist enforcement against a known-denied host.
- Explicit positive assertion on DNS-over-TLS / DoH denial (rule already exists).
- Explicit test of non-HTTP outbound port behaviour (22, 25, arbitrary high ports).

The non-HTTP test forces a decision: **is non-HTTP egress in scope?** Today the firewall only intercepts TCP 80/443. The answer affects whether the test is a positive assertion ("allowed — git-over-ssh works") or a negative one ("blocked — iptables rejects").

**Tentative position** (to be confirmed): non-HTTP egress remains allowed. Git-over-ssh, DNS, and NTP are legitimate agent needs. The denylist's scope is HTTP exfil channels; broader L4 blocking is a follow-up feature, not a bug. This should be documented in ADR-012 as an explicit accepted risk if confirmed.

### D5: CI integration deferred

**Firmness: PROPOSED**

A GitHub Actions workflow running `rc test --e2e` on every PR is the obvious next step, but requires either docker-in-docker or a self-hosted runner. Deferring to a follow-up ADR once the e2e test is stable locally.

**Rationale:** shipping the test locally first gives us a read on flakiness, runtime, and Docker cache behaviour before committing to CI infrastructure.

## Trade-offs accepted

- **E2E runtime**: 90s–8min is slower than contributors want on every commit. Mitigated by making it opt-in (`--e2e` flag) and cache-friendly.
- **Duplicated coverage**: a few checks will appear in both the in-container suite and the e2e suite (e.g. "egress denylist works"). That's fine — the in-container suite asserts "it works *right now*"; the e2e suite asserts "it works *end-to-end from cold*".
- **Test maintenance**: more tests = more places to update when behaviour changes. Accepted as the cost of not shipping regressions.

## Implementation notes

Roll out in order:

1. Fix host-test path drift + add `rc test --host` wiring (P2 — mechanical, unblocks everything else).
2. Write `tests/test-e2e-lifecycle.sh` + `rc test --e2e` (P1 — biggest coverage gain).
3. Expand egress suite (P3 — requires the D4 policy decision first).
4. CI integration (follow-up ADR).

## Consequences

**Positive:**
- Lifecycle regressions caught before shipping
- Unwired tests become wired or documented as dead
- The four 2026-04-20 bugs each get an explicit regression guard

**Negative:**
- Slower pre-PR cycle for contributors who opt into `--e2e`
- One-time churn to fix the 10 broken host tests
