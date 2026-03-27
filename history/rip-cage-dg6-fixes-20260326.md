# Fixes: rip-cage-dg6
Date: 2026-03-26
Review passes: 2

## Critical
- **rc:285,376** — Init failure in JSON mode uses `return` (exit 0) instead of `return 1`/`exit 1`. Violates ADR-003 D1: "Exit code is always non-zero on error." Fix: change `return` to `return 1` on both init-failure paths.
- **rc:466** — Empty `volumes_removed` array crashes under `set -euo pipefail` with "unbound variable." Fix: pre-check array length before expansion: `if [[ ${#volumes_removed[@]} -eq 0 ]]; then vol_json="[]"; else ...`.
- **rc:184,354** — `--env-file` passed directly to `docker run` without validation. Agent could expose `/etc/shadow` or `~/.ssh/*` as env vars. Fix: run `validate_path` on `env_file` value.

## Important
- **rc:74-77** — `rc init .` skips `validate_path` entirely, bypassing FIRM ADR-003 D3. Fix: resolve `.` to absolute path via `realpath` and validate like any other path.
- **rc:183-184** — `--port` or `--env-file` as last arg triggers unbound `$2` under `set -u`. Fix: check `$# -ge 2` before accessing `$2`.
- **rc:318,323** — Bare `echo "Warning: ..."` goes to stdout, corrupting JSON output. Fix: use `log` function or redirect to stderr.
- **rc:508+dispatch** — `--dry-run` silently ignored on `build`, `ls`, `down`, `test`, `init`. Fix: reject `--dry-run` if subcommand is not `up` or `destroy`.
- **rc:392** — `cmd_ls` uses `{{.Status}}` (freeform "Up 2 hours") instead of `{{.State}}` (clean "running"/"exited"). Fix: use `{{.State}}` for `status` field, add `uptime` field with `{{.Status}}`.
- **rc:404-471** — `cmd_down`, `cmd_destroy`, `cmd_test` operate on any Docker container, not just rip-cage managed ones. Fix: verify `rc.source.path` label exists before operating.
- **rc:359-363** — `docker run` failure (port conflict, resource limits) triggers `set -e` exit with no JSON error. Fix: wrap in `if ! docker run ...` and emit `json_error`.

## Minor
- **rc:11** — `json_out()` is called once with a hardcoded literal. Uses the old unsafe `jq -c .` pattern. Fix: remove function, replace the one call site in `cmd_build` with `jq -nc '{...}'`.
- **test-json-output.sh:121-128** — `|| true` forces `$?` to 0, making the subsequent check dead code. Fix: capture exit code before `|| true`.

## ADR Updates
- No ADR changes needed. All findings align with existing ADR-003 decisions. The implementation gaps are in code, not in the design.

## Discarded
- **Signal/trap handlers for partial cleanup** — design doc aspirational, overengineered for current state
- **NAME_CONFLICT error code** — TOCTOU race is rare; wrapping docker run (I7) covers the crash
- **Duplicated init blocks in cmd_up** — refactoring, not a bug
- **Test for init failure exit code** — would need Docker mock infrastructure
- **Fragile test parsing in cmd_test** — acknowledged coupling, separate change to redesign test output
- **Undocumented error codes in design doc** — doc maintenance, not code
- **cmd_init JSON output** — design doc intentionally excludes init
- **Multiple positional args silently accepted** — minor edge case
- **Flag ordering fragility** — standard CLI behavior
- **Build output swallowed in JSON mode** — acceptable for MVP
- **Container name derivation not injective** — covered by docker run error handling
