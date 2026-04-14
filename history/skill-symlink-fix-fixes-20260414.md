# Fixes: skill-symlink-fix
Date: 2026-04-14
Review passes: 1 (architecture + implementation reviewers)

## Important

- **rc:_collect_skill_symlink_parents** — No `$HOME` guard on resolved symlink targets. A crafted symlink like `~/.claude/skills/evil -> /etc` would emit `dirname(/etc) = /`, causing `-v /:/: ro` to mount the host root read-only into the container. Fix: skip and warn on any target where `"$target" != "${HOME}/"*`. Applied in `b57cc25`.

- **rc:_collect_skill_symlink_parents:548** — Wrong empty-array expansion idiom under `set -u`. `"${seen_dirs[@]:-}"` expands to one empty-string iteration (loop runs once with `d=""`). Correct idiom: `"${seen_dirs[@]+"${seen_dirs[@]}"}` which yields zero iterations on an empty array. Functionally safe here (empty string never matches a real tdir) but semantically wrong. Fixed in `b57cc25`.

- **rc:cmd_init:268** — Silent no-op when `jq` is absent. If jq is not installed, symlink mounts were silently omitted from devcontainer.json — container would have broken skills with no diagnostic. Fix: emit `stderr` warning. Applied in `b57cc25`.

- **test-rc-commands.sh** — No test coverage for the new helper or mount behavior. Added Test 9 (unit-tests `_collect_skill_symlink_parents`: outside-HOME filtering, inside-HOME passthrough, deduplication) and Test 10 (`rc init` end-to-end: devcontainer.json gains absolute-path mount entries for real symlinks). Applied in `b57cc25`.

## Minor

- **rc:_collect_skill_symlink_parents:547** — `local d` declared inside the inner for-loop body. `local` is function-scoped in bash, not block-scoped, so this is a no-op after the first iteration. Moved to the variable declaration block at top of function. Fixed in `b57cc25`.

## ADR Updates
- No ADR changes needed. The fix implements the "follow-on improvement" already noted in `history/2026-04-14-skills-in-containers-design.md` §Symlink Handling and ADR-002 D17/D18. The `$HOME` security boundary is consistent with the spirit of ADR-003 D3 (validate mount paths) applied to a user-authored path source.

## Discarded
- **Nested-path deduplication** (arch finding 3): deduplication is exact-match on parent strings. If skills resolve to nested dirs (one at `/foo/skills`, another at `/foo/skills/sub`), both parents would be mounted redundantly. This is an unlikely edge case and an optimization, not a bug. Discarded.
- **`_path_under_allowed_roots` check** (both reviewers suggested this): `RC_ALLOWED_ROOTS` is configured for workspace paths (e.g., `$HOME/code/personal`). Applying it to skill symlink targets would block legitimate targets in other code roots (e.g., `$HOME/code/mapular`). The `$HOME` guard is the correct boundary for user-authored symlinks. Using `RC_ALLOWED_ROOTS` directly would break the common monorepo case.
