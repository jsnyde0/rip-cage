# Fixes: zero-config-first-run
Date: 2026-04-14
Review passes: 1

## Critical
(none)

## Important

- **rc:337-338** — User-typed path at interactive prompt is not `realpath`-resolved before writing to `rc.conf` or assigning to `RC_ALLOWED_ROOTS`. A user can type `../../etc` (passes `[[ -d ]]`) which lands in `rc.conf` as a relative path; on the next session it resolves against a different CWD. The `_home` default is correctly resolved via `realpath "$HOME"` (line 330), but user input is not. Fix: after `[[ -d "$_chosen" ]]` passes, apply `_chosen="$(realpath "$_chosen")"` before the break.

- **rc:744,759** — `cmd_up` calls `validate_path` twice: once for the workspace path (~line 744) and once for `dirname(env_file)` (~line 759). The non-TTY minimum-grant branch sets `RC_ALLOWED_ROOTS="$resolved"` (workspace path) as a side effect of the first call. The second call then checks whether the env-file directory is under the workspace path — which fails if the env-file is stored elsewhere (e.g., `~/.secrets/project.env`). The user gets a misleading "outside allowed roots" error pointing at the env-file, not the root cause. Fix: in `cmd_up`, when `--env-file` is given, accumulate the env-file dirname into the minimum grant before calling either `validate_path`, so both paths are covered by the temporary `RC_ALLOWED_ROOTS`.

- **test-agent-cli.sh:107** — `$RC` is unquoted in the Test 7 invocation: `$(RC_CONFIG=/dev/null env -u RC_ALLOWED_ROOTS $RC up ...)`. Every other `$RC` invocation in the file is quoted (`"$RC"`). If the script path contains spaces this silently fails. Fix: change `$RC` to `"$RC"` on that line.

- **rc:353-358 (deferred JSON warning)** — Design doc section 2 specifies: "In `--output json` mode: include a `"warning"` field alongside the normal response." The implementation emits the warning to stderr only. Agents parsing JSON output cannot programmatically distinguish a configured run from a minimum-grant fallback run — this breaks the observability contract of ADR-003 D1. Fix: in the non-TTY path when `$OUTPUT_FORMAT == "json"`, capture the warning and include it in the final JSON output (wherever `_up_json_output` or equivalent assembles the response).

## Minor

- **rc:336** — `read -r _input` writes to `_input` without a prior `local _input` declaration. All other local vars in this block (`_home`, `_chosen`, `_attempts`, `_conf`) are declared with `local`. Fix: add `local _input=""` alongside the other declarations.

## ADR Updates
- No ADR changes needed — all findings are implementation gaps, not decision conflicts.

## Discarded

- **rc.conf append idempotency** (both reviewers): `>>` can produce a second `RC_ALLOWED_ROOTS` line if the file exists but the variable is still unset. In practice the `${RC_ALLOWED_ROOTS:-...}` pattern means the first line wins on re-source; the duplicate is benign and only possible in unusual partial-config states. Not worth the complexity of a replace-or-append approach.
- **RC_ALLOWED_ROOTS not exported** (architecture reviewer): No child process currently reads this variable. Latent issue with no current impact; premature to fix.
