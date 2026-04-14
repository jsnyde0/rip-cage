# Zero-Config First Run

**Date:** 2026-04-13
**Decisions:** [ADR-009 D7](decisions/ADR-009-ux-overhaul.md), [ADR-003 D3](decisions/ADR-003-agent-friendly-cli.md)
**Related:** [UX Overhaul](2026-04-13-ux-overhaul-design.md)

## Problem

`RC_ALLOWED_ROOTS` is required with no default. A new user running `rc up` gets:

```
Error: RC_ALLOWED_ROOTS not set. Example: export RC_ALLOWED_ROOTS=$HOME/projects
```

...before they've seen the cage work even once. ADR-009's auto-build (D2) eliminated
`rc build` from the quickstart but this friction remains: the user still can't `rc up`
until they read docs, understand the purpose of `RC_ALLOWED_ROOTS`, and create `rc.conf`
or export the variable.

There's a related test isolation bug: tests that exercise the "RC_ALLOWED_ROOTS unset"
code path use `env -u RC_ALLOWED_ROOTS` but `rc` sources `~/.config/rip-cage/rc.conf`
at startup, which restores the variable from user config. On a configured machine those
tests silently skip the code path they're meant to cover.

## Research

Security research and industry tooling (CIS Docker Benchmark, Lima, Rancher Desktop,
confused deputy literature) informs the design:

- **Allowlist is the right model** — denylist is bypassable (confirmed by ADR-003 D3)
- **`$HOME` is the practical default** — Docker Desktop, Lima, and Rancher Desktop all
  start from the user's home directory; nobody requires allowlist config before first use
- **realpath-before-allowlist is already implemented** — the primary known bypass vector
  (symlink exchange, CVE-2021-30465) is mitigated
- **The threat model is narrow** — agent hallucinations targeting `/etc` or `/var`, not
  sophisticated adversaries; this affects what defaults are defensible
- **Config file > env var for security** — env vars leak in process listings and core
  dumps; `rc.conf` can be audited

## Design

### 1. Interactive first-run prompt (human path)

When `RC_ALLOWED_ROOTS` is unset after config loading **and** the invocation is
interactive (condition: `[[ -t 0 ]] && [[ "$OUTPUT_FORMAT" != "json" ]]`):

```
rip-cage: no allowed roots configured.
Allow projects under [/Users/alice]: 
```

- The prompt displays the **resolved** `$HOME` value (e.g., `/Users/alice`), not the
  literal `$HOME` string
- User presses Enter to accept, or types a full absolute path (e.g., `/Users/alice/code`)
- Tilde (`~`) in user input is **not** expanded by `read` — the prompt message should
  hint to use full paths if the user deviates from the default
- Path is validated: must exist and be a directory. On failure, the prompt re-asks up to
  **3 attempts** before exiting with an error
- `~/.config/rip-cage/` is created if absent (`mkdir -p`)
- Written to `~/.config/rip-cage/rc.conf` (created if absent) using the env-var-preserving
  pattern so that explicit `RC_ALLOWED_ROOTS` exports still override:
  ```bash
  RC_ALLOWED_ROOTS="${RC_ALLOWED_ROOTS:-/Users/alice}"
  ```
- File is created with default umask permissions (typically `0644`)
- Operation continues immediately — no need to re-invoke `rc`
- One-time only: `rc.conf` exists after this, so the prompt never appears again

### 2. Non-TTY / agent fallback

When `RC_ALLOWED_ROOTS` is unset **and** the invocation is non-interactive
(condition: `[[ ! -t 0 ]] || [[ "$OUTPUT_FORMAT" == "json" ]]`). This covers all
commands that call `validate_path` — including `rc up`, `rc init`, and any future
command that validates path arguments:

- Auto-allow only the exact resolved path being requested (minimum necessary grant)
- Print to stderr:
  ```
  Warning: RC_ALLOWED_ROOTS unset — allowing /resolved/path only.
  Set RC_ALLOWED_ROOTS in ~/.config/rip-cage/rc.conf for permanent access.
  ```
- In `--output json` mode: include a `"warning"` field alongside the normal response
- Does **not** write `rc.conf` — no side effects in non-interactive mode
- Subsequent `rc` calls with different paths each get this minimum grant independently

Note: A human running `rc --output json up .` in a terminal gets the non-interactive
path deliberately — JSON callers want deterministic, non-prompting behavior. This is
consistent with ADR-003 D1, which establishes `--output json` as the machine-readable path.

### 3. Test isolation fix

Tests that exercise the "RC_ALLOWED_ROOTS unset" code path must set `RC_CONFIG=/dev/null`
alongside the env var unset. This bypasses config loading entirely and gives the test a
clean environment regardless of the host machine's config.

`RC_CONFIG` is the existing documented escape hatch for the config path (line 30 of `rc`).

**`test-dg6.2.sh`** uses `env -u RC_ALLOWED_ROOTS`:

```bash
# Before:
up_err=$(env -u RC_ALLOWED_ROOTS "$RC" up "$test_dir" 2>&1) || true

# After:
up_err=$(RC_CONFIG=/dev/null env -u RC_ALLOWED_ROOTS "$RC" up "$test_dir" 2>&1) || true
```

**`test-agent-cli.sh`** uses a subshell with `unset`:

```bash
# Before:
(unset RC_ALLOWED_ROOTS; $RC up ...)

# After (WRONG — semicolon form does not export RC_CONFIG to child processes):
# (RC_CONFIG=/dev/null; unset RC_ALLOWED_ROOTS; $RC up ...)

# After (correct — command-prefix form exports RC_CONFIG via env):
RC_CONFIG=/dev/null env -u RC_ALLOWED_ROOTS "$RC" up ...
```

In bash, `VAR=value` inside `(...)` sets a local shell variable that is not exported to child
processes unless already in the environment. Use the command-prefix form (`VAR=value env ...`)
which passes the variable directly into the child process environment.

## What does NOT change

- The allowlist model itself (ADR-003 D3): preserved
- `realpath` validation before allowlist check: preserved
- The "path outside allowed roots" error: preserved — this only changes the "not set" case
- `rc.conf` format: unchanged; it's still just bash sourced at startup
- Agent invocations with `RC_ALLOWED_ROOTS` already set: completely unaffected

## Security posture

**Against the actual threat (agent hallucinations):**
- `$HOME` default still blocks `/etc`, `/var`, `/usr`, `/bin`, `/sbin`, `/proc`
- The confused deputy attack requires the agent to explicitly request `~/.ssh` or
  `~/.aws` as a project path — an unlikely hallucination, and the container's safety
  stack provides a second layer regardless
- Non-TTY minimum grant is stricter than the human default: agent invocations without
  config only get the exact path they request

**`$HOME` vs narrower default (e.g. `~/code`):**
Suggesting `~/code` as the default would be wrong — users have diverse directory layouts
(`~/projects`, `~/dev`, `~/src`, etc.). A wrong suggestion that the user has to edit
creates more friction than a permissive-but-correct `$HOME`. If users want a narrower
scope, the prompt makes it easy to type it.

## File changes summary

| Action | Files |
|--------|-------|
| **Modify** | `rc` (validate_path: TTY prompt + non-TTY minimum grant), `test-dg6.2.sh` (RC_CONFIG=/dev/null), `test-agent-cli.sh` (RC_CONFIG=/dev/null) |
| **Create** | `docs/2026-04-13-zero-config-first-run-design.md` |
| **Update** | `docs/decisions/ADR-003-agent-friendly-cli.md` (D3 revision), `docs/decisions/ADR-009-ux-overhaul.md` (D7 new, remove from Deferred) |
