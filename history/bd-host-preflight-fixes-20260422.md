# Fixes: bd-host-preflight
Date: 2026-04-22
Review passes: 1 (architecture + implementation in parallel)

## Critical
(none)

## Important
- **rc:1971, 2010** — `bd-preflight-test` dispatch entry is a hidden public CLI surface with no naming convention or internal-gate marker. An agent or user running `rc bd-preflight-test <args>` will reach it. Fix: rename dispatch to an underscore-prefixed token (e.g. `__bd-preflight-test`) or gate behind `RC_INTERNAL_CMDS=1`. Update tests/test-bd-host-preflight.sh and tests/test-rc-commands.sh (tests 16–18) to use the new dispatch name.
- **rc:1706–1719 (cmd_test worktree redirect)** — Diverges from D6 in two ways: (a) no `_path_under_allowed_roots` check before redirecting `beads_dir` to the main repo's `.beads/`; (b) no handling of an explicit `.beads/redirect` file, which takes precedence in D6. Both cause `cmd_test` to probe a different `beads_dir` than `cmd_up` mounts for the same project — an architectural divergence ADR-007 D6 explicitly warned against. Fix: mirror D6 semantics in cmd_test — first check for `.beads/redirect` (and follow it if present + under allowed roots), otherwise do worktree auto-redirect with the `_path_under_allowed_roots` guard. If either check fails, emit `PASS [0] beads-host-dolt — beads_dir outside allowed roots (skipped)` rather than silently probing the wrong path.

## Minor
- **rc:1143 (case C warning text)** — Path inside `rm` hint is unquoted: `rm ${beads_dir}/dolt-server.port`. If `beads_dir` contains spaces the copy-pasted command breaks. Fix: emit `rm "${beads_dir}/dolt-server.port"` in the warning.
- **tests/test-bd-host-preflight.sh:47,80** — Hardcoded ports 59997/59998 are fragile on busy hosts. Fix: for the healthy-state Python listener, bind to port 0 and read back the assigned port; for the stale-port fixture, probe the chosen port first and skip (with a clear message) if something unexpectedly answers. Keep the existing skip-if-python3-absent path.

## ADR Updates
- **ADR-007 D9** — Current text "[0] signals host-side" implies machine semantics the parser does not actually use (`BASH_REMATCH[2]` is discarded). Soften to "[0] is a human-readable marker for host-side checks; not machine-meaningful." Keeps the convention without overselling it.

## Discarded
- **Arch #3 (`log` writes warnings to stdout in text mode)** — Codebase-consistent with D6 and allowed-roots warnings elsewhere in `rc`. Changing only this call site would create a one-off inconsistency.
- **Arch #4 (hard-coded 127.0.0.1)** — Already documented in design "Risks" section as an acceptable tradeoff with a named escape hatch (future: read bd config). Fine as-is.
- **Arch #5 (_probe_tcp "Terminated" race)** — Benign under current use (no job-control, no `set -m` at call sites); hardening adds complexity for a theoretical issue.
- **Impl #2 (sleep 1 orphan)** — Cosmetic, within the 1-second timeout budget the design already accepts. Alternative fixes (pgid-kill, setsid) have their own bash-3.2 portability issues.
