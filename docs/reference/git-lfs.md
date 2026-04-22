# Git LFS

Rip-cage does not fetch git-lfs blobs from inside the container. This follows the same boundary as `git push` and `bd dolt push` (see [ADR-014](../decisions/ADR-014-push-less-cage.md)): network-touching git operations happen on the host at session boundaries; the cage consumes materialized files via the `/workspace` bind mount.

## What you'll see

If you run `rc up` or `rc init` against a repo that uses LFS and has unmaterialized pointer stubs in the working tree, rip-cage prints an advisory warning:

```
⚠ LFS pointer stubs detected in /path/to/project
  rip-cage cannot fetch LFS blobs from inside the cage (ADR-014).
  Run on the host before working in the cage:
      git -C /path/to/project lfs pull
  Files still as stubs (first 5):
      path/to/fixture.parquet
      ...
```

The warning is advisory only — `rc` does not run `git lfs pull` for you. It does not modify the host workspace.

## Fixing it

On the host, with `git-lfs` installed:

```bash
git -C /path/to/project lfs pull
```

The materialized files land in the working tree on the host. Because `/workspace` is a bind mount, the container sees the real files instantly — no container restart needed.

If you don't have `git-lfs` installed on the host, install it first (`brew install git-lfs` on macOS, `apt install git-lfs` on Debian/Ubuntu), then run `git lfs install` once per user.

## Why this boundary

Same reasoning as [ADR-014 D1](../decisions/ADR-014-push-less-cage.md): the cage has no outbound SSH/write credentials and the egress allowlist is deliberately narrow. Carving out an LFS endpoint into the allowlist would add network surface to every cage for the lifetime of every container — a permanent hole to paper over a host-hygiene step that the human already needs to do once per branch switch. The detect-and-warn path surfaces the exact action needed without crossing the host/cage boundary.

## How detection works

At `rc up` / `rc init` time, `rc` does a fast host-side check:

1. **Fast early exit.** `grep -rq --include=.gitattributes 'filter=lfs'` — if no `.gitattributes` in the project declares an LFS filter, skip entirely.
2. **Pointer-stub scan.** `find` for files under 200 bytes (real stubs are ~130 bytes) whose first line matches the LFS v1 pointer header (`version https://git-lfs.github.com/spec/v1`).
3. **Report.** If any are found, print up to 5 paths plus the host-side command to fix them.

The check runs outside the container — no extra tooling needed inside the image.
