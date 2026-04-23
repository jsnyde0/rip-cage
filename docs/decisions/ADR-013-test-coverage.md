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
| bats-core framework | TAP output, isolation, setup/teardown, timing, skip flags | Adds a tooling dependency; rip-cage otherwise leans on plain bash |
| **Fix + wire via `run-host.sh`** | Preserves coverage, guards against future rot, zero new deps | One-time cleanup cost; revisit bats if TAP/JSON integration becomes painful |

### D3: E2E test owns explicit regression guards for the three 2026-04-20 product fixes

**Firmness: FIRM**

Three product fixes from 2026-04-20 get explicit assertions in `test-e2e-lifecycle.sh`:

1. **python3-venv present**: `docker exec <name> dpkg -s python3-venv` + `docker exec <name> python3 -m venv /tmp/venv-probe` succeed. A plain `rc build` is not a guard here — Docker will reuse a cached apt layer even if the Dockerfile line is deleted, so the regression ships silently on warm cache.
2. **CA env propagation**: `docker exec <name> env | grep NODE_EXTRA_CA_CERTS` succeeds when egress=on.
3. **Resume TTY guard**: `rc up <path> </dev/null` against an already-running container returns exit 0 and does not launch `tmux attach` (verified via process tree or state sentinel, NOT by grepping stderr for a docker-CLI error string — that wording drifts across docker versions).

The fourth 2026-04-20 change — `test-egress-firewall.sh` check [2] switching from curl-probe to `/proc/net/tcp` LISTEN parse — is a **test-correctness fix, not a product regression guard**. It is exercised whenever the e2e test runs `rc test`, which in turn runs the in-container egress suite. No separate assertion is added or claimed here. D3 covers three product fixes; the test-correctness fix is self-covering.

**Rationale:** bugs without a failing test aren't fixed, they're forgotten. An explicit regression guard per product fix is cheap and makes the history self-documenting. Honest count matters — D3 previously claimed four explicit guards when fix #1 was implicit-only and fix #4 was a test fix.

### D4: Egress perimeter tests expand to assert the settled non-HTTP policy

**Firmness: FIRM** (promoted 2026-04-23; ADR-012 D6 settled the non-HTTP scope question as "stays allowed, accepted risk". P3 is unblocked.)

Current egress suite validates the L7 denylist but not the L3/L4 perimeter. P3 adds:

- **IPv6 perimeter (active probe)**: `curl -6 --max-time 5 https://ipv6.google.com` from inside the container must fail. A capability check like "ip6tables rules exist OR IPv6 unavailable" is a tautology today (container has only `::1`, `init-firewall.sh` has no `ip6tables` references) and gives no active guard.
- **WebSocket denylist** enforcement against a known-denied host.
- **DNS-over-TLS / DoH** positive denial (rule already exists).
- **Non-HTTP policy assertion**: positive iptables-rule check that no REDIRECT/DROP rule targets ports other than 80/443. This is the codified form of ADR-012 D6 — "non-HTTP stays allowed" as a test, not prose. Asserted at the iptables-rule level rather than via network probes (probes are flaky across developer environments because hosted Docker may block port 22 at the edge, which would produce a test failure that is not a product regression).

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

1. Fix host-test path drift + add `rc test --host` wiring (P2 — mechanical, unblocks everything else). Includes the mandatory per-test audit step; do not wire a resurrected test until it passes or is explicitly quarantined.
2. Write `tests/test-e2e-lifecycle.sh` + `rc test --e2e` (P1 — biggest coverage gain). Supersedes `tests/test-integration.sh`; absorb its unique checks and delete it.
3. Expand egress suite (P3 — unblocked 2026-04-23; D4 is FIRM, ADR-012 D6 settled the policy).
4. CI integration (follow-up ADR).

## Consequences

**Positive:**
- Lifecycle regressions caught before shipping
- Unwired tests become wired or documented as dead
- The four 2026-04-20 bugs each get an explicit regression guard

**Negative:**
- Slower pre-PR cycle for contributors who opt into `--e2e`
- One-time churn to fix the 10 broken host tests
