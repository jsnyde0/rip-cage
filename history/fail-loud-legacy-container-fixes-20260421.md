# Fixes: fail-loud-legacy-container
Date: 2026-04-21
Review passes: 1 (architecture reviewer + implementation reviewer, parallel)

## Critical

- **rc:~1191 (pre-fix)** — The initial commit validated only *presence* of the
  `rc.egress` label, not its *value*. A label of `rc.egress=maybe` (or any
  unrecognized value) was passed through and treated as "on" by the downstream
  `[[ "$rc_egress" != "off" ]]` test. This violated the very ADR (ADR-001) that
  the commit introduced ("a label with an unrecognized value must abort with a
  clear message, not default silently"). **Fixed:** extracted to helper
  `_up_resolve_resume_egress` which rejects any value other than `on|off` with
  a new `INVALID_EGRESS_LABEL` error code.

## Important

- **rc:~1119–1129 dry-run branch** — `rc --dry-run up <legacy-container>` used
  to report `would_resume` cleanly; the real `rc up` would then hard-fail.
  Dry-run shouldn't lie. **Fixed:** the new helper is also invoked from the
  dry-run `would_resume` branch, surfacing the same fail-loud exit before
  planning is considered complete.

- **rc:~1180 `docker inspect` vs missing label** — previous implementation
  used `docker inspect ... 2>/dev/null || true` and then `-z`-checked the
  result, conflating "daemon failure / TOCTOU race" with "legacy container".
  **Fixed:** helper now captures the inspect exit code distinctly and emits a
  `DOCKER_ERROR`-coded message for infrastructure failures, reserving
  `LEGACY_CONTAINER` for actual missing labels.

- **tests/test-code-review-fixes.sh** — no static coverage existed for the new
  `LEGACY_CONTAINER` path. **Fixed:** added L1 block asserting helper
  definition, both error codes, and that the helper is called from both
  dry-run and resume paths.

## ADR Updates

- No ADR revisions needed. ADR-001's written decision already enumerates the
  three cases (missing label, missing script, unknown value); the code is now
  aligned with what the ADR already says. Leaving ADR-001 as-is.

## Deferred (surfaced for alignment, NOT fixed in this pass)

These were flagged by the architecture reviewer as broader fail-loud rollouts.
They touch code paths beyond the legacy-container fix and warrant their own
commits / issues:

1. **State fallthrough in cmd_up** (rc:~1125) — `paused`, `restarting`,
   `removing`, `dead` states silently fall through to the "create new
   container" branch and then hit a name-conflict error deep in
   `_up_start_container`. ADR-001 says unknown states must abort with a clear
   message. *Recommend: file as beads task.*

2. **`cmd_ls` does not annotate legacy containers** (rc:~1279–1282) — legacy
   rows render with an empty egress column. Operators can't see which
   containers will fail-loud on resume until they try. *Recommend: file as
   beads task, tie to ADR-001 "errors are actionable" corollary.*

3. **`RC_VERSION` downgrades to "unknown" on missing VERSION file** (rc:~55) —
   arguably an ADR-001 exception worth documenting explicitly, or a fail-loud
   candidate in non-dev contexts. *Recommend: explicit ADR-001 exception note,
   low priority.*

## Discarded

- **Arch #6 (Mapular ADR reference unresolvable to external readers)** —
  discarded for this pass. Rip-cage is open-source but the reference is
  already marked as "Mapular's ADR-001" and appears in Related/provenance
  sections, which is acceptable citation style. Low-value churn.

- **Arch #7 (ADR-001 Related section omits ADR-004/ADR-007)** — discarded
  without verification of those ADRs' actual contents; speculative link.

- **Arch #8 (unrelated test-command additions bundled in commit)** —
  verified false via `git show --stat f305cea`. The commit only touches `rc`
  and the new ADR; no `test --host`/`test --e2e` code exists at the claimed
  line numbers in that commit.

- **Impl #4 (`$path` vs stored `rc.source.path` label in error message)** —
  `$path` has already been realpath-resolved and passed `RC_ALLOWED_ROOTS`
  gating; using it in the recreate hint is fine. Stored label would only
  differ in a name-disambiguation-plus-hash edge case where the user passed
  a different path; the hint still works (`rc destroy $name` is authoritative).
