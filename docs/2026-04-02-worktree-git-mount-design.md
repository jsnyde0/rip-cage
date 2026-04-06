# Design: Git Worktree Support in Containers

**Date:** 2026-04-02
**Status:** Draft
**Decisions:** [ADR-002 D4 amendment](decisions/ADR-002-rip-cage-containers.md)
**Origin:** E2e validation of `rc up` against a mapular-platform worktree. Git was completely broken inside the container — all operations failed with "fatal: not a git repository".
**Related:** [Rip Cage Design](2026-03-25-rip-cage-design.md), [ADR-002](decisions/ADR-002-rip-cage-containers.md), [ADR-006 D5](decisions/ADR-006-multi-agent-architecture.md) (worktree-per-agent)

---

## Problem

When `rc up` targets a git worktree, git is broken inside the container. All git operations fail:

```
fatal: not a git repository: /Users/jonat/code/mapular/platform/mapular-platform/.git/worktrees/update-demographics
```

**This is the primary use case, not an edge case.** Worktrees are the standard workflow for running rip-cage containers — each parallel task gets its own worktree and container. Every container that targets a worktree has broken git without this fix.

**Root cause:** Git worktrees use a `.git` *file* (not directory) containing a pointer to the main repo:

```
gitdir: /Users/jonat/code/.../mapular-platform/.git/worktrees/update-demographics
```

This host-absolute path doesn't exist inside the container. The container only has the worktree directory mounted at `/workspace` — the main repo's `.git/` is nowhere to be found.

**The git worktree chain:**

```
Worktree dir/
├── .git (FILE) → "gitdir: /host/path/main-repo/.git/worktrees/<name>"
│                          ↓
Main repo/.git/
├── objects/          ← shared object store
├── refs/             ← shared refs
├── config            ← shared config (remotes, etc.)
├── hooks/            ← shared hooks (⚠ container escape risk — see Security)
└── worktrees/
    └── <name>/
        ├── HEAD      ← worktree-specific HEAD
        ├── index     ← worktree-specific index
        ├── commondir → "../.." (relative back to main .git/)
        └── gitdir    → "/host/path/worktree/.git" (reverse pointer)
```

For git to work, it needs:
1. `.git` file → valid worktree gitdir (has HEAD, index)
2. Worktree gitdir's `commondir` → main `.git/` (has objects, refs, config)

Both links are broken when only the worktree directory is mounted.

## Goal

Make `rc up <worktree-path>` transparently handle git worktrees so that git works inside the container without any user-facing flags or configuration.

## Non-Goals

- Creating worktrees inside containers (host-side operation; see ADR-006 D5 for future `--worktree` flag)
- Supporting submodules (detected and skipped — see Detection)
- Modifying any files on the host filesystem

---

## Design

### Detection

In `rc up`, after resolving the target path, detect worktrees. Both worktrees and submodules use `.git` files with `gitdir:` lines, but their paths differ:
- Worktrees: `gitdir: /path/.git/worktrees/<name>`
- Submodules: `gitdir: /path/.git/modules/<name>`

The detection must distinguish between them to avoid silently producing broken git on submodules.

```bash
if [[ -f "${path}/.git" ]]; then
  local gitdir_line
  gitdir_line=$(cat "${path}/.git")
  if [[ "$gitdir_line" == gitdir:\ * ]]; then
    local host_gitdir="${gitdir_line#gitdir: }"

    # Resolve relative gitdir paths to absolute (Git 2.13+ allows relative)
    if [[ "$host_gitdir" != /* ]]; then
      host_gitdir=$(realpath "${path}/${host_gitdir}" 2>/dev/null) || true
    fi

    # Only handle worktrees, not submodules (.git/modules/<name>)
    if [[ "$host_gitdir" == *"/worktrees/"* ]]; then
      # ... handle worktree mount
    else
      log "Skipping non-worktree .git file (submodule or other)"
    fi
  fi
fi
```

### Mount Strategy

Four mounts solve the problem:

1. **Worktree directory** → `/workspace` (existing, unchanged)
2. **Main repo's `.git/`** → `/workspace/.git-main:delegated` (new bind mount, writable — git writes objects, refs, packed-refs here)
3. **Corrected `.git` file** → `/workspace/.git:ro` (file mount overriding the host's `.git` file)
4. **Hooks directory** → `/workspace/.git-main/hooks:ro` (read-only sub-mount — prevents container escape)

**Why four mounts?** Docker processes sub-mounts after parent mounts. Mount 4 overlays the hooks directory within mount 2, making it read-only while the rest of `.git-main` stays writable. This is necessary because:
- Git needs write access to `.git/objects/`, `.git/refs/`, `.git/packed-refs` for commits, fetches, etc.
- But `.git/hooks/` is a container escape vector — hooks execute **on the host** when the user runs git commands in the main repo
- Under `bypassPermissions` mode (ADR-002 D5), deny rules in settings.json are not enforced, so deny rules alone cannot protect hooks
- The `:ro` sub-mount physically prevents hook modification regardless of permission mode

The corrected `.git` file contains:
```
gitdir: /workspace/.git-main/worktrees/<name>
```

This fixes the chain:
- `/workspace/.git` → `/workspace/.git-main/worktrees/<name>/` (has HEAD, index) ✓
- `.git-main/worktrees/<name>/commondir` → `../..` → `/workspace/.git-main/` (has objects, refs) ✓

**Mount ordering note:** Docker file bind mounts (`-v file:/workspace/.git`) overlay files within directory bind mounts (`-v dir:/workspace`). All mounts must be in the same `docker run` invocation. This is standard Docker behavior but worth noting for maintainability.

### Path Resolution

Given a worktree `.git` file containing:
```
gitdir: /Users/jonat/code/mapular/platform/mapular-platform/.git/worktrees/update-demographics
```

Derive:
- **Worktree name:** `update-demographics` (basename of gitdir path)
- **Main `.git/` path:** `/Users/jonat/code/mapular/platform/mapular-platform/.git` (strip `/worktrees/<name>`)
- **Main repo root:** `/Users/jonat/code/mapular/platform/mapular-platform` (parent of `.git/`)

Relative gitdir paths (allowed since Git 2.13) are resolved to absolute before parsing, using `realpath` relative to the worktree directory. This ensures `RC_ALLOWED_ROOTS` validation works (it requires absolute paths).

### Security

The main repo's `.git/` path must be validated against `RC_ALLOWED_ROOTS` (ADR-003 D3), same as beads redirect validation. The main repo could theoretically be outside the allowed roots if someone created a worktree with an absolute path pointing elsewhere.

Control character and null byte checks apply to the gitdir content (same as path validation elsewhere in `rc`).

**Hooks protection:** The main `.git/hooks/` directory is mounted read-only via a sub-mount (see Mount Strategy). Under `bypassPermissions` mode, deny rules are documentation-only — the `:ro` mount is the actual enforcement mechanism. This prevents an agent from writing a hook (e.g., `pre-commit`) to `.git-main/hooks/` that would execute on the host with the user's full privileges when they run git commands in the main repo. This extends ADR-002 D11's intent to the `.git-main` mount path.

### Temp File Lifecycle

The corrected `.git` file is written to a predictable host path:
```
/tmp/rc-<container-name>.gitfile
```

- **Created:** during `rc up`, before `docker run`
- **Mounted:** as a file bind mount at `/workspace/.git`
- **Cleaned up:** during `rc destroy` (alongside container and volumes)

### Implementation in `rc`

Add a worktree detection block in `cmd_up`, after the beads redirect block and before `docker run`. Detection and validation run before the dry-run exit point so that `--dry-run` can report worktree mounts; the actual mount arguments are only built in the non-dry-run path.

```bash
# Git worktree: fix .git pointer for container (the .git file contains host-absolute paths)
local wt_detected=false wt_name="" wt_main_git=""
if [[ -f "${path}/.git" ]]; then
  local gitdir_line
  gitdir_line=$(cat "${path}/.git")
  if [[ "$gitdir_line" == gitdir:\ * ]]; then
    local host_gitdir="${gitdir_line#gitdir: }"

    # Security: reject control characters
    if [[ "$host_gitdir" =~ [[:cntrl:]] ]]; then
      log "Warning: .git file contains control characters — skipping worktree mount"
    # Resolve relative gitdir paths to absolute (Git 2.13+ allows relative)
    elif [[ "$host_gitdir" != /* ]]; then
      host_gitdir=$(realpath "${path}/${host_gitdir}" 2>/dev/null) || true
    fi

    # Only handle worktrees, not submodules (.git/modules/<name>)
    if [[ -n "$host_gitdir" && "$host_gitdir" == *"/worktrees/"* ]]; then
      wt_name=$(basename "$host_gitdir")
      local main_git_dir
      main_git_dir=$(dirname "$(dirname "$host_gitdir")")

      if [[ -d "$main_git_dir" ]]; then
        local resolved_git_dir
        resolved_git_dir=$(realpath "$main_git_dir" 2>/dev/null) || true
        local git_allowed=false
        IFS=':' read -ra roots <<< "${RC_ALLOWED_ROOTS:-}"
        for root in "${roots[@]}"; do
          local resolved_root
          resolved_root=$(realpath "$root" 2>/dev/null) || continue
          if [[ "$resolved_git_dir" == "$resolved_root"/* ]] || [[ "$resolved_git_dir" == "$resolved_root" ]]; then
            git_allowed=true
            break
          fi
        done

        if [[ "$git_allowed" == "true" ]]; then
          wt_detected=true
          wt_main_git="$resolved_git_dir"
          log "Worktree detected: ${wt_name} (main .git/ at ${wt_main_git})"
        else
          log "Warning: worktree's main .git/ at $main_git_dir is outside allowed roots — git will not work"
        fi
      else
        log "Warning: worktree's main .git/ at $main_git_dir does not exist — git will not work"
      fi
    elif [[ -n "$host_gitdir" ]]; then
      log "Skipping non-worktree .git file (submodule or other)"
    fi
  fi
fi

# --- dry-run exit point can go here, with wt_detected/wt_name/wt_main_git available ---

# Build worktree mount arguments (non-dry-run path only)
if [[ "$wt_detected" == "true" ]]; then
  local gitfile="/tmp/rc-${name}.gitfile"
  echo "gitdir: /workspace/.git-main/worktrees/${wt_name}" > "$gitfile"

  # Mount main .git/ (writable for objects/refs), corrected .git file, hooks read-only
  run_args+=(-v "${wt_main_git}:/workspace/.git-main:delegated")
  run_args+=(-v "${gitfile}:/workspace/.git:ro")
  run_args+=(-v "${wt_main_git}/hooks:/workspace/.git-main/hooks:ro")
  log "Worktree: mounted main .git/ and corrected .git pointer for ${wt_name}"
fi
```

### Cleanup in `cmd_destroy`

Add to the destroy flow:
```bash
# Clean up worktree gitfile if it exists
rm -f "/tmp/rc-${name}.gitfile"
```

### JSON Output

When `--output json` is used with `rc up`, include worktree metadata in the response:

```json
{
  "name": "worktrees-update-demographics",
  "action": "created",
  "source_path": "/Users/jonat/.../update-demographics",
  "worktree": {
    "name": "update-demographics",
    "main_git_dir": "/Users/jonat/.../.git"
  }
}
```

When worktree detection fails (e.g., outside allowed roots):
```json
{
  "worktree": {
    "detected": true,
    "error": "main .git/ at /path is outside allowed roots"
  }
}
```

Non-worktree containers omit the `worktree` field entirely.

### Dry-Run Support

Worktree detection and validation run before the dry-run exit point. The `--dry-run --output json` response includes worktree metadata so orchestrators can preview the full mount setup without creating a container:

```json
{
  "action": "would_create",
  "worktree": {
    "name": "update-demographics",
    "main_git_dir": "/Users/jonat/.../.git"
  }
}
```

### What About the Reverse Pointer?

The main repo's `.git/worktrees/<name>/gitdir` file contains the host path back to the worktree:
```
/Users/jonat/code/mapular/platform/mapular-platform/.worktrees/update-demographics/.git
```

This is used by `git worktree list` and garbage collection. Inside the container, this path is invalid, but:
- `git worktree list` will show stale data — acceptable, the agent doesn't need this
- GC won't prune worktree refs — safe (better to not prune than to wrongly prune)
- All normal operations (status, add, commit, push, log, diff) work fine without this

No fix needed for the reverse pointer.

---

## Interaction with Existing Features

### Beads Redirect

Beads redirect (`.beads/redirect`) already handles a similar pattern — a pointer file that needs resolution and security validation. The worktree `.git` fix uses the same pattern: detect, resolve, validate against allowed roots, mount.

Both can coexist. Mount order doesn't matter since they target different paths (`/workspace/.beads` vs `/workspace/.git-main` and `/workspace/.git`).

### Container Naming

Container names are derived from the last two path components. Worktree paths like `.worktrees/update-demographics` already work after the `container_name()` fix (strip leading dots). No change needed.

### Devcontainer Path

**Known limitation:** Worktree support is CLI-mode only (`rc up`). The devcontainer path (`rc init` + VS Code "Reopen in Container") mounts `localWorkspaceFolder` the same way, so the `.git` file problem likely affects terminal-based git inside devcontainers too. VS Code's own Git extension resolves paths on the host side, but Claude Code uses terminal git. This is untested — devcontainer users targeting worktrees should use `rc up` instead until verified.

### Multi-Agent (ADR-006)

Multiple containers targeting the same worktree share the `.git-main` mount (writable). Git uses lock files for concurrent access (`refs/heads/<branch>.lock`, `index.lock`), so concurrent commits to different branches are safe. Concurrent commits to the same branch may see lock contention surfacing as git errors — this matches standard multi-process git behavior on a single machine.

ADR-006 D5 describes a future `--worktree` flag that **creates** new worktrees per agent. This design **handles** existing worktrees. They compose naturally: D5 creates a worktree → our detection handles it on subsequent `rc up` invocations.

---

## Testing

### Manual Verification

1. `rc up ~/code/mapular/platform/mapular-platform/.worktrees/update-demographics`
2. Inside container: `git status` → should show branch and changes
3. Inside container: `git log --oneline -5` → should show commit history
4. Inside container: `git branch` → should list branches
5. Verify `.git-main/` is visible at `/workspace/.git-main`
6. Verify hooks are read-only: `touch /workspace/.git-main/hooks/test` → should fail
7. Verify original host `.git` file is unchanged after `rc destroy`

### `rc test` Checks

Add conditional worktree checks to the test suite. When `/workspace/.git-main` exists:

- **Git functional:** `git status` exits 0 inside the container
- **Git pointer valid:** `/workspace/.git` contains `gitdir:` pointing to an existing path
- **Hooks protected:** `/workspace/.git-main/hooks` is read-only (write attempt fails)
- **Objects accessible:** `git log --oneline -1` returns a commit

When `/workspace/.git-main` does not exist (normal repo), these checks are skipped. This ensures worktree containers get validated without affecting non-worktree containers.

---

## Rejected Alternatives

### GIT_DIR / GIT_WORK_TREE Environment Variables

Set env vars to override git's directory discovery.

**Rejected:** `GIT_DIR` is global — affects ALL git operations in the container. If the agent clones a different repo or works with submodules, `GIT_DIR` would interfere. The `.git` file approach is local to the workspace.

### Mount Main .git/ at /workspace/.git (as directory)

Mount the main `.git/` directly over the worktree's `.git` file, replacing it with the full directory.

**Rejected:** Git would treat `/workspace` as the main repo, not the worktree. It would see the main repo's HEAD, not the worktree's HEAD. Worktree-specific state (branch, index) would be lost.

### Rewrite .git File In-Place via init-rip-cage.sh

Modify the bind-mounted `.git` file at container init time.

**Rejected:** Bind mounts are bidirectional — modifying `/workspace/.git` inside the container changes the host file. This would break git on the host. Using a separate file mount (`-v gitfile:/workspace/.git:ro`) avoids touching the host.

### Mount at Host-Absolute Path Inside Container

Mount `.git/worktrees/<name>/` at the exact host path inside the container (e.g., `/Users/jonat/...`).

**Rejected:** Leaks host filesystem structure into the container. Fragile — depends on host paths never changing. Creates confusing non-standard paths inside the container.

### Deny Rules for `.git-main/hooks/*`

Add `Write(.git-main/hooks/*)` and `Edit(.git-main/hooks/*)` to settings.json deny list.

**Rejected:** Under `bypassPermissions` mode (ADR-002 D5), deny rules are not enforced — they're documentation only. A read-only sub-mount physically prevents writes regardless of permission mode.
