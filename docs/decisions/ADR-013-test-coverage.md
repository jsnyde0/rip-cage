# ADR-013: Test Coverage Tiers — In-Container vs E2E vs Host-Script

**Status:** Accepted (revised 2026-05-29 — D5 implemented; D6 added: host-only CI tier determinism)
**Date:** 2026-04-20
**Design:** [2026-04-20-test-coverage-design.md](../2026-04-20-test-coverage-design.md)
**Related:** [ADR-004](ADR-004-phase1-hardening.md) (rc test origin), [ADR-012](ADR-012-egress-firewall.md) (egress suite), [ADR-001](ADR-001-fail-loud-pattern.md) (fail-loud; D6 image-absence rule), [ADR-008](ADR-008-open-source-publication.md) (D4 local==CI; D5/D6 build on it)

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
2. **CA env absence** (updated per `rip-cage-ta1o.1`): the pure SNI router terminates no TLS and installs no rip-cage CA, so `docker exec <name> env | grep NODE_EXTRA_CA_CERTS` returns NOTHING when egress=on, and no `rip-cage-proxy.crt` exists in the trust store. (Pre-`rip-cage-ta1o.1` this asserted the opposite — that the var was *present* — under the TLS-MITM design; the assertion inverted when the CA was removed.)
3. **Resume TTY guard**: `rc up <path> </dev/null` against an already-running container returns exit 0 and does not launch `tmux attach` (verified via process tree or state sentinel, NOT by grepping stderr for a docker-CLI error string — that wording drifts across docker versions).

The fourth 2026-04-20 change — `test-egress-firewall.sh` check [2] switching from curl-probe to `/proc/net/tcp` LISTEN parse — is a **test-correctness fix, not a product regression guard**. It is exercised whenever the e2e test runs `rc test`, which in turn runs the in-container egress suite. No separate assertion is added or claimed here. D3 covers three product fixes; the test-correctness fix is self-covering.

**Rationale:** bugs without a failing test aren't fixed, they're forgotten. An explicit regression guard per product fix is cheap and makes the history self-documenting. Honest count matters — D3 previously claimed four explicit guards when fix #1 was implicit-only and fix #4 was a test fix.

### D4: Egress perimeter tests expand to assert the settled non-HTTP policy

**Firmness: FIRM** (promoted 2026-04-23; ADR-012 D8 settled the non-HTTP scope question as "stays allowed, accepted risk". P3 is unblocked.)

Current egress suite validates the L7 denylist but not the L3/L4 perimeter. P3 adds:

- **IPv6 perimeter (active probe)**: `curl -6 --max-time 5 https://ipv6.google.com` from inside the container must fail. A capability check like "ip6tables rules exist OR IPv6 unavailable" is a tautology today (container has only `::1`, `init-firewall.sh` has no `ip6tables` references) and gives no active guard.
- **WebSocket denylist** enforcement against a known-denied host.
- **DNS-over-TLS / DoH** positive denial (rule already exists).
- **Non-HTTP policy assertion**: positive iptables-rule check that no REDIRECT/DROP rule targets ports other than 80/443. This is the codified form of ADR-012 D8 — "non-HTTP stays allowed" as a test, not prose. Asserted at the iptables-rule level rather than via network probes (probes are flaky across developer environments because hosted Docker may block port 22 at the edge, which would produce a test failure that is not a product regression).

### D5: CI runs lint + build + the host-only test tier (implemented)

**Firmness: FIRM** (was PROPOSED; implemented + promoted 2026-05-29 — CI is live and green on `main`)

`.github/workflows/ci.yml` runs three jobs on every push / PR to `main`:

1. **Lint** — `make lint` (pinned `koalaman/shellcheck:v0.11.0`; ADR-008 D4 local==CI by construction).
2. **Build** — `docker build` of the multi-stage image (Go beads + Rust DCG + Debian runtime), proving the toolchain compiles.
3. **Test (host-only)** — `bash tests/run-host.sh --host-only` on `ubuntu-latest`.

The `rc test --e2e` lifecycle tier (D1/D3) stays OUT of CI: it needs a live container, which `ubuntu-latest` cannot provide deterministically (docker-in-docker / self-hosted runner is still the prerequisite, now tracked as backlog rip-cage-rat). The "follow-up ADR" this decision originally deferred to is folded here in-place rather than spun out, per ADR-011 D1.

**Rationale:** shipping the host-only tier in CI first gives a real gate on the cross-platform (GNU-Linux) and image-absent behaviour that the maintainer's macOS box masks — without paying for DinD infrastructure. The constraints this imposes on the host-only tier are codified in D6.

### D6: The `--host-only` CI tier must be deterministic and self-contained

**Firmness: FLEXIBLE** (added 2026-05-29; warrant: three latent violations surfaced the moment D5's CI went live — rip-cage-ozt)

The `bash tests/run-host.sh --host-only` job is the "no container" tier. On a fresh CI runner it MUST be deterministic:

- **No live container creation, no Docker Hub pull, no real `docker build`.** A host-only test that needs to exercise a build/run code path uses a fake-`docker` PATH shim (returns instantly) rather than provisioning anything. A test with a few genuinely container-needing blocks gates those blocks behind `RC_HOST_ONLY` (exported by `--host-only`) and prints a visible `SKIP (host-only): …`; file-level container tests use the NEEDS_CONTAINER denylist (D2). Live `docker run <public-image>` (e.g. `alpine`) is forbidden in this tier — Docker Hub anonymous rate limits make it flaky (it passes one run and fails the next).
- **Image-absence-safe.** CI starts with no `rip-cage:latest`. `rc` paths reachable host-only must not provision the image before they actually need it (ADR-001 fail-loud; the `cmd_up` reorder determines container state *before* pull/build, so an unsupported-state container fails fast with no 500MB pull or ~7-min build, and no `{"status":"pulling"}` stderr preamble corrupting `--output json`).
- **Run-all-accumulate driver contract.** `run-host.sh` runs every test (`if ! bash "$test_file"`), accumulates failures, reports them all, and exits non-zero if any failed. It MUST NOT abort at the first failing test (`set -e` propagation at the driver loop) — abort-at-first hides the failure tail and forces one-failure-per-CI-cycle debugging (the rip-cage-ozt thrashing root cause).

Live-container assertions are not lost: the full `run-host.sh` (no flag) runs them locally with a container present, and a future DinD / self-hosted job (rip-cage-rat) can run them in CI.

**Rationale:** the maintainer's environment — macOS + BSD coreutils + `rip-cage:latest` always present + warm Docker cache — masks these failures by construction; a fresh Linux CI runner (GNU coreutils + no image + cold cache + Docker Hub rate limits) does not. Determinism in the host-only tier is what makes CI a trustworthy gate rather than a flaky one. The cross-platform divergence checklist lives in `.claude/harness.md` ("Local-vs-CI divergence checklist").

**Alternatives considered:**

| Approach | Rejected because |
|---|---|
| Run live-container integration in the host-only CI job | `reasoned:` contradicts the "no container" tier definition; `direct:` `docker run alpine` flaked in rip-cage-ozt CI run 26628167292 (Docker Hub anon rate limit) |
| Authenticate / pre-pull from Docker Hub so live runs are reliable in CI | `reasoned:` adds CI secrets + maintenance, duplicates the build job's work, and still puts container work in the wrong tier |
| Keep `set -e` abort-at-first-failure (simpler driver) | `direct:` caused ~5 red cycles in rip-cage-ozt — each surfaced only one failure, hiding the rest of the tail behind it |
| Move mixed host/container test files wholesale into NEEDS_CONTAINER | `reasoned:` drops their static grep/source-introspection checks from CI; sub-test `RC_HOST_ONLY` gating preserves those while skipping only the live blocks |

**What would invalidate this:** a docker-in-docker or self-hosted CI runner lands (rip-cage-rat) — then live-container assertions can run in a dedicated CI job and the "no live container" rule relaxes *for that job*, not for the host-only tier; OR an authenticated pull-through Docker Hub cache removes the rate-limit flakiness (weakens the no-live-`docker run` rationale, though the tier-name and image-absence arguments stand independently).

## Trade-offs accepted

- **E2E runtime**: 90s–8min is slower than contributors want on every commit. Mitigated by making it opt-in (`--e2e` flag) and cache-friendly.
- **Duplicated coverage**: a few checks will appear in both the in-container suite and the e2e suite (e.g. "egress denylist works"). That's fine — the in-container suite asserts "it works *right now*"; the e2e suite asserts "it works *end-to-end from cold*".
- **Test maintenance**: more tests = more places to update when behaviour changes. Accepted as the cost of not shipping regressions.

## Implementation notes

Roll out in order:

1. Fix host-test path drift + add `rc test --host` wiring (P2 — mechanical, unblocks everything else). Includes the mandatory per-test audit step; do not wire a resurrected test until it passes or is explicitly quarantined.
2. Write `tests/test-e2e-lifecycle.sh` + `rc test --e2e` (P1 — biggest coverage gain). Supersedes `tests/test-integration.sh`; absorb its unique checks and delete it.
3. Expand egress suite (P3 — unblocked 2026-04-23; D4 is FIRM, ADR-012 D8 settled the policy).
4. CI integration — DONE (D5, 2026-05-29): lint + build + host-only test on `ubuntu-latest`, green on `main`. Host-only tier determinism codified in D6. Live-container CI (DinD / self-hosted) remains backlog (rip-cage-rat).

## Consequences

**Positive:**
- Lifecycle regressions caught before shipping
- Unwired tests become wired or documented as dead
- The four 2026-04-20 bugs each get an explicit regression guard

**Negative:**
- Slower pre-PR cycle for contributors who opt into `--e2e`
- One-time churn to fix the 10 broken host tests

## canonical_refs

- [ADR-001](ADR-001-fail-loud-pattern.md) (fail-loud) — D6's image-absence-safe rule; `cmd_up` fails loud on unsupported container state *before* provisioning the image.
- [ADR-008](ADR-008-open-source-publication.md) D4 (local==CI by construction) — D5's pinned `make lint`; D6 extends the same local==CI principle from lint to the host-test tier.
- [ADR-012](ADR-012-egress-firewall.md) (egress firewall) — the egress suite runs inside the host-only tier.
- [ADR-023](ADR-023-secret-path-mount-denylist.md) (secret-path denylist / RC_CONFIG_GLOBAL) — `run-host.sh`'s driver-level config fixture the host-only tier depends on.
- bead rip-cage-ozt — the CI-green episode that surfaced D6's invariant (three latent violations: a real build to check a log line, a live `docker run alpine`, and `set -e` abort-at-first-failure).
- bead rip-cage-wn4 — established the single-driver + pinned-lint local==CI baseline D5/D6 build on.
