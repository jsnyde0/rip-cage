# Fixes: auth-refresh
Date: 2026-04-15
Review passes: 1

## Critical
- **rc:673** — `_extract_credentials` is called bare inside `_up_prepare_docker_mounts`. The helper returns 1 on macOS keychain failure. With `set -euo pipefail` (line 2), this aborts `rc up` entirely — a behavior change the design doc explicitly prohibits ("No behavior change to `cmd_up`"). The old inline code used `return;` (implicit 0) so `rc up` would warn and continue. Fix: `_extract_credentials || true` at line 673.

## Important
- **rc:616,1393** — `cmd_auth_refresh` ignores all arguments. `rc auth`, `rc auth typo`, `rc auth status` all silently perform a refresh. ADR-010 D3 says "Route `rc auth <subcommand>` through `cmd_auth`" with subcommand parsing. Fix: add a `cmd_auth` dispatcher that validates the subcommand, route dispatch to `cmd_auth` instead of `cmd_auth_refresh`:
  ```bash
  cmd_auth() {
    case "${1:-}" in
      refresh) shift; cmd_auth_refresh "$@" ;;
      *) echo "Usage: rc auth refresh" >&2; exit 1 ;;
    esac
  }
  ```
  Update dispatch line 1393: `auth) shift; cmd_auth "$@" ;;`

- **rc:1267-1321** — `rc schema` does not include the `auth` command. ADR-003 D5 requires the schema to reflect the full CLI surface. Fix: add an `"auth"` entry to the schema JSON with `refresh` subcommand.

## Minor
- **docs/reference/auth.md** — The "Auth flow by path" table lists `rc init`, `rc up`, and `init-rip-cage.sh` but not the new `rc auth refresh` path. Add a row: `rc auth refresh` / `cmd_auth_refresh` → `_extract_credentials` (host-side, updates file for all containers).

## ADR Updates
- No ADR changes needed. Findings are implementation gaps against existing ADR decisions, not conflicts requiring ADR revision.

## Discarded
- **Test suite not integrated into `rc test`**: `rc test` runs tests inside containers; auth refresh tests are host-side CLI tests. Different execution context — correct pattern.
- **JSON "ok" vs "success" inconsistency**: Design doc explicitly specifies `"status": "ok"` for all three auth paths. Following the spec.
- **CLAUDE.md architecture listing missing `auth`**: Pre-existing staleness (also missing `schema`, worktree commands). Not introduced by this change.
- **File permissions on credentials**: Pre-existing issue (old inline code had same behavior). Not a regression.
