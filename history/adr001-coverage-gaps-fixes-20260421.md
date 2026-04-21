# Fixes: adr001-coverage-gaps
Date: 2026-04-21
Review passes: 1 (architecture [opus] + implementation [sonnet], parallel)
Commits reviewed: 1c5ba1d (rc), 199000d (tests)

## Critical
(none)

## Important

- **rc:1160-1290 — cmd_up state dispatch is a denylist, not an allowlist.**
  The fix enumerates `paused|restarting|removing|dead` explicitly, but anything
  else (future docker states, malformed output) still falls through to the
  create-new branch. ADR-001 "Specific behaviors" says unknown states must
  abort with a clear message, not default silently. Also: empty `state`
  currently conflates "inspect failed" with "container absent".
  **Fix:** Restructure dispatch as an allowlist. Route `running` → attach,
  `exited|created` → resume, empty (+ docker inspect exit 0) → create-new,
  and everything else (paused/restarting/removing/dead + anything unrecognized)
  → `CONTAINER_STATE_UNSUPPORTED` with `state=<raw>` in the message. Check
  `docker inspect` exit code separately before dispatching so inspect-failure
  does not look like absence. Apply to both the DRY_RUN and real-execution
  paths.

- **rc:1338 — text-mode cmd_ls dropped `.Status` (uptime) and reordered columns.**
  Previous output: `NAME | STATUS(Up 5 minutes) | EGRESS | SOURCE PATH`.
  Current output: `NAME | STATE(running) | SOURCE PATH | EGRESS`. Operators
  lose uptime; any doc/script using column position for egress silently
  breaks. The egress-legacy annotation did not require replacing `.Status`.
  **Fix:** Revert the docker `--format` string to `{{.Names}}\t{{.Status}}\t{{.Label "rc.source.path"}}\t{{.Label "rc.egress"}}`
  (or preserve original column order: `NAME STATUS EGRESS SOURCE PATH`) and
  apply the awk legacy/invalid normalization only to the egress column.
  Keep `.Status` (human-readable uptime), not `.State`.

- **tests/test-code-review-fixes.sh:188 — live L2-a suppresses `docker run` failure.**
  `docker run ... || true` masks the case where the target name is already
  taken by an unrelated container. The test then pauses/inspects whatever is
  there and either false-passes or false-fails.
  **Fix:** Remove `|| true` on `docker run`. Prepend `docker rm -f "$CNAME_L2" 2>/dev/null || true`
  to guarantee clean slate. Fail the test explicitly if `docker run` exits
  non-zero.

- **tests/test-code-review-fixes.sh:138-143, 155-163 — static assertions are unscoped.**
  `grep -q "\"paused\"" "$RC"` and `grep -q '"legacy"' "$RC"` match the strings
  anywhere in `rc` (comments, unrelated commands, future code). If the
  `cmd_up` or `cmd_ls` branches are accidentally deleted, the test still
  passes as long as the strings appear elsewhere.
  **Fix:** Scope greps to the relevant function. Simplest approach: use
  `awk '/^cmd_up\(\)/,/^}/' "$RC" | grep -q '"paused"'` (and same pattern
  for `cmd_ls`). Apply to all four state-branch checks and both legacy/invalid
  checks.

## Minor

- **tests/test-code-review-fixes.sh:147-152 — count threshold `>= 4` too loose.**
  Design requires both dry-run and real paths to have four branches each
  (8 total). `>= 4` would still pass if one entire path was deleted.
  **Fix:** Change threshold to `>= 8` and update the comment to "four states × two paths".

## ADR Updates

No ADR changes needed. The allowlist/denylist finding is a code-level fix —
ADR-001 already specifies the correct allowlist semantics ("unexpected
status ... must abort"). No FIRM decision needs revising.

## Discarded

- **Arch #3 (commit message misattribution)** — Commit 1c5ba1d's message
  claims to fix an "awk NR==1 header bug" that didn't exist before the commit
  (the pre-commit path used docker's native `table` header, no awk). In
  reality the commit silently fixed a real pre-existing JSON bug (missing
  `split("\n") | .[]`). Provenance is wrong but the code is correct and
  amending a pushed history ref just to rephrase a commit message is not
  worth it. Note here for future archaeology.

- **Arch #4 (json_error double-exit style)** — The `[[ "$OUTPUT_FORMAT" == "json" ]] && json_error`
  pattern relies on `json_error` calling `exit 1`, so text-mode `echo/return`
  is only reached in non-json mode. This matches the existing codebase
  pattern (e.g., `_up_init_container` failure). Refactoring to a unified
  `fail_loud` helper is a broader style change beyond this review's scope.

- **Impl #1 (dry-run one-liner vs multi-line split)** — The dry-run branches
  use `echo ...; return 1` on one line; real-execution branches split onto
  two lines. Purely stylistic; functionally identical. Not worth a targeted
  fix.
