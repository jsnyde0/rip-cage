# ADR-001 Coverage Gaps — Design
Date: 2026-04-21
Status: Proposed
Related: ADR-001 (fail-loud pattern), commits f305cea + 1017e11

## Context

The fail-loud rollout that just shipped (f305cea + 1017e11) closed the
legacy-container gap on the resume path. Parallel architecture review
surfaced three adjacent gaps that were flagged but deliberately deferred
from that commit's scope. This doc bundles them into a single change so
the ADR revision and code fixes land together.

All three are judgment calls about where ADR-001 applies. Writing them
down in one place lets us revise ADR-001 once, then execute the code
changes mechanically.

## Gaps

### Gap 1 — Unknown container states silently fall through (`cmd_up`)

**Where:** `rc:1161-1213` (dry-run and real paths)

**Current behavior:** `cmd_up` dispatches on `docker inspect .State.Status`
with three branches: `running` → attach, `exited|created` → resume,
anything else → "create new container". Docker's documented state set is
`created | restarting | running | removing | paused | exited | dead`.
Four of those (`restarting`, `removing`, `paused`, `dead`) silently fall
through to the create branch, where they fail deep inside
`_up_start_container` with a Docker name-conflict error that does not
name the root cause.

**Why it violates ADR-001:** "Unknown states — docker inspect returning
an unexpected status ... must abort with a clear message, not default
silently." The code currently defaults silently.

**Proposed fix:** Add explicit branches before the "new container"
fallthrough:

| State        | Action                                                                 |
|--------------|------------------------------------------------------------------------|
| `paused`     | Fail loud. Hint: `docker unpause $name` then retry `rc up`             |
| `restarting` | Fail loud. Hint: wait, or `docker stop $name && rc up $path`           |
| `removing`   | Fail loud. Hint: wait for removal to complete, then `rc up $path`      |
| `dead`       | Fail loud. Hint: `rc destroy $name && rc up $path`                     |
| `""` (empty) | Create new — this is the only truly-unknown case, meaning no container |

Introduce error code `CONTAINER_STATE_UNSUPPORTED` for paused/restarting/
removing/dead. Reserve `CONTAINER_NOT_FOUND` for the actual
not-managed-by-rc case.

Apply the same branching inside the `DRY_RUN` block so `rc --dry-run up`
does not lie about unsupported states.

### Gap 2 — `cmd_ls` does not flag legacy containers

**Where:** `rc:1305-1312`

**Current behavior:** `cmd_ls` renders the `rc.egress` label verbatim.
Legacy containers (missing label) render with a blank egress column.
Operators only discover they are legacy by trying to resume and hitting
the fail-loud we just added.

**Why it matters for ADR-001:** The "errors are actionable" corollary —
fail-loud surfaces a problem at a critical moment, but users should not
have to probe to discover that problem when a listing view is already
showing them all their containers. A silent blank column is precisely
the silent-degradation pattern ADR-001 exists to prevent, just applied
to inventory display rather than execution.

**Proposed fix:** Render an explicit `legacy` marker in the egress
column when the `rc.egress` label is absent, and `invalid:<value>` when
the label is present but not `on|off`. Text mode uses a postprocess
step; JSON mode sets `egress` to a normalized value (`"legacy"` /
`"invalid:<value>"` / `"on"` / `"off"`).

No new error codes — this is a display fix, not a fail path. Legacy
containers still list; they just announce themselves.

### Gap 3 — `RC_VERSION` silently falls back to `"unknown"`

**Where:** `rc:55`

**Current behavior:**
```bash
RC_VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")"
```

**Why this is NOT an ADR-001 violation:** `RC_VERSION` is informational
metadata — it appears in `rc --version` output and log lines. It is not
a safety gate, not a config value that affects container behavior, and
not load-bearing for any ADR-001 scenario (missing label / script
drift / unknown state). Failing loud when VERSION is absent would break
`git clone && ./rc` dev usage for no safety benefit.

**Proposed fix:** Do not change the code. Instead, **revise ADR-001** to
add an explicit "informational fields may degrade" exception so future
readers don't flag this as a violation. Include `RC_VERSION` as the
named example. The exception is narrow: fields that do not gate
behavior, do not appear in safety-critical decisions, and whose
degraded value is visibly labeled (`unknown`, not a plausible-looking
fake).

## ADR-001 Revisions

Two targeted edits to `docs/decisions/ADR-001-fail-loud-pattern.md`:

1. **Expand "Specific behaviors" list** to name the `cmd_up` state
   switch and `cmd_ls` annotation explicitly as in-scope applications
   of the pattern. This aligns the ADR with the full intended
   coverage, not just the label-on-resume case that motivated it.

2. **Add "Exceptions" subsection** under Decision, documenting the
   informational-fields carve-out (with `RC_VERSION` as the named
   example and the three criteria: not a safety gate, not load-bearing
   for ADR-001 scenarios, degraded value is visibly labeled).

No change to Status or the broader pattern. Consequences section
unchanged.

## Test Strategy

Extend `tests/test-code-review-fixes.sh` with an L2 block:

- Static grep assertions for `CONTAINER_STATE_UNSUPPORTED` error code
  and all four state branches (`paused|restarting|removing|dead`)
  in `cmd_up`.
- Static assertions that `cmd_ls` produces `legacy` / `invalid:`
  markers — grep the code for the normalization branch.
- Live test (if Docker available): create a container, pause it via
  `docker pause`, run `rc --output json up` against it, assert
  `.code == "CONTAINER_STATE_UNSUPPORTED"`. Clean up with
  `docker unpause && docker rm -f`.
- Live test: create a container without the `rc.egress` label,
  run `rc --output json ls`, assert the entry has `egress == "legacy"`.

No new test file. Bundle into the existing review-fixes file since this
is a continuation of the same ADR-001 rollout.

## Beads Plan

One epic covering all three:

- **EPIC** `adr001-coverage-gaps`: ADR-001 application gaps beyond legacy-container
  - **TASK** Revise ADR-001 (add state/ls to Specific behaviors; add Exceptions subsection)
  - **TASK** `cmd_up`: fail loud on paused/restarting/removing/dead states
  - **TASK** `cmd_ls`: annotate legacy and invalid-label containers
  - **TASK** Test coverage L2 block in `tests/test-code-review-fixes.sh`

Dependency: the three implementation tasks depend on the ADR revision
(so the ADR lands first and the code changes reference it cleanly).

## Out of Scope

- Broader state audit beyond `cmd_up` (e.g. `cmd_down` state handling).
  `cmd_down` already handles not-found via `CONTAINER_NOT_FOUND`; its
  remaining states are ambiguous but less load-bearing. File separately
  if it becomes a problem.
- Egress label drift detection (label says `on` but firewall isn't
  actually running). That's a different failure mode — label integrity
  vs runtime integrity — and belongs with ADR-012's health-check story.
