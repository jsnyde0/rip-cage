# Fixes: beads-worktree-autoredirect
Date: 2026-04-21
Review passes: 1 (architecture + implementation in parallel)

## Critical
(none)

## Important (applied)
- **rc:874-881 → 874-889** — Auto-redirect path did not `realpath` the main repo's `.beads/` before the allowed-roots check. A `.beads/` symlink pointing outside `RC_ALLOWED_ROOTS` would pass a string-only check while the bind-mount followed the symlink to the real target (same class of threat ADR-003 D3 calls out). Fixed by resolving via `realpath` first, then checking `_path_under_allowed_roots` on the resolved path.
- **rc:877 (original)** — Silent fallthrough when main repo's `.beads/` was absent or outside allowed roots: the branch did nothing and `beads_dir` stayed pointing at the worktree's empty `.beads/`, with no log line. Inconsistent with the explicit-redirect block which logs warnings. Fixed by splitting the guard into explicit failure branches, each with a `log "Warning: ..."` line.

## Minor (applied)
- **bd-wrapper.sh:19-24** — Port re-read accepted any non-empty content (whitespace, garbage) and exported it. Diagnostic then missed this realistic corruption mode. Fixed by stripping whitespace and requiring strictly-numeric non-zero content; non-numeric content leaves `BEADS_DOLT_SERVER_PORT` unset so D7 fires.
- **bd-wrapper.sh:32 (original)** — Dead clause `-z "${BEADS_DOLT_SERVER_PORT:-}"` was unreachable given the preceding `:-0` default. Simplified to a single `== "0"` comparison.
- **bd-wrapper.sh:35 (original)** — `completion` case arm was unjustified (bd has no such top-level subcommand). Removed.
- **bd-wrapper.sh:50 (original)** — Diagnostic text told the user to run `bd dolt stop && bd dolt start` — a compound command, which this repo explicitly blocks via PreToolUse hook. Split into separate lines.
- **docs/decisions/ADR-007-beads-dolt-container-resilience.md:3-4** — Compound Date header (`2026-04-08 (D1-D5), 2026-04-21 (D6-D7)`) diverged from repo convention. Reverted to a single Date; D6/D7 keep their internal `Added: 2026-04-21` markers.

## ADR Updates (applied as part of this change)
- **ADR-007** — Added D6 (worktree auto-redirect) and D7 (wrapper diagnostic) as FIRM decisions; status flipped Proposed → Accepted.

## ADR hygiene (done alongside, answering user's audit question)
- **ADR-001** — Normalized lowercase `accepted` → `Accepted`.
- **ADR-003** (agent-friendly CLI, D3 allowed-roots) — Flipped Proposed → Accepted. Implemented in `_path_under_allowed_roots` and load-bearing for ADR-007 D1, D6.
- **ADR-004** (phase-1 hardening, D1 host Dolt connection) — Flipped Proposed → Accepted. Fully implemented (rc ~lines 892-898); cross-referenced as authoritative by ADR-007.
- **ADR-012** (egress firewall) — Flipped Proposed → Accepted. Implementation shipped in recent commits (`1c47164`, `69a98d4`, `f305cea`).

## Discarded
- **Architecture #2** (nested redirect chase in auto path) — Overengineering. Main repos don't have `redirect` files (those are worktree-local by design per `.beads/.gitignore`).
- **Architecture #5** (wrapper diagnostic prints on every invocation, no rate-limit) — Acceptable tradeoff. Agents benefit from repeatedly seeing the error; a once-per-session sentinel adds complexity for marginal log-volume benefit. In a broken container the right move is to recreate it, not squelch the warning.
- **Implementation #4** (pre-existing test 15 failure in test-worktree-support.sh) — Not introduced by this change. Flagged for a separate cleanup but out of scope here.

## Verification
- `bash tests/test-bd-wrapper.sh` → 10/10 PASS
- `bash tests/test-worktree-support.sh` → 34/35 PASS (the 1 failure is pre-existing test 15, unrelated)
- `bash -n rc` and `bash -n bd-wrapper.sh` → both clean
- Manual wrapper smoke test confirms diagnostic text is compound-command-free.

## End-to-end validation (2026-04-21)
Validated on a disposable test worktree (`/Users/jonat/code/personal/rip-cage-wt-validation`) to avoid touching the user's active send-it container.

**Unit harness (11/11 PASS)** — `/tmp/validate-d6.sh`, duplicates rc:837-890 against fixtures:
- S1: worktree with no `.beads/` dir → auto-redirect mounts main's `.beads/`
- S2: worktree with `dolt-server.port` → no auto-redirect
- S3: worktree with explicit `.beads/redirect` → explicit wins
- S4: non-worktree project → auto-redirect skipped entirely
- S5: main `.beads/` outside `RC_ALLOWED_ROOTS` → refused, warning logged
- S6: main `.beads/` missing → warning logged, no mount
- S7: `.beads` symlink pointing outside allowed roots → `realpath` normalization catches it, refused

**Real end-to-end:**
```
rc up /Users/jonat/code/personal/rip-cage-wt-validation
# → "Beads: worktree has no runtime data — auto-redirecting to main repo .beads/ (/Users/jonat/code/personal/rip-cage/.beads)"
# → "Beads: embedded mode — no Dolt server connection"
docker inspect ... → confirmed /Users/jonat/code/personal/rip-cage/.beads -> /workspace/.beads
docker exec ... bd list --status=open → returned open issues
docker exec ... bd show rip-cage-buh → full issue payload
rc destroy ... → clean
```

User's active `worktrees-feat-mp-c34-formula-input-coalesce` container is server-mode (not embedded); that path is covered by S1-S7 (mode-agnostic logic) but the specific container was not recreated. If you want, destroy+recreate it and the first log line from `rc up` will confirm D6 fired.
