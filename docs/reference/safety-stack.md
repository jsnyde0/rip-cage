# Safety Stack

The safety stack intercepts every shell command via Claude Code's hook system in `settings.json`.

## PreToolUse hooks

Two hooks run before every Bash command:

1. **DCG** (`/usr/local/lib/rip-cage/bin/dcg-guard`) — Rust binary, built from source in the Dockerfile. Blocks destructive commands like `rm -rf`, `dd if=/dev/zero`, filesystem formatting, etc. DCG rules use unanchored whole-command regex matching, so operator chaining (`&&`, `;`, `||`) does **not** bypass them — verified live 2026-06-03.
2. **SSH-bypass blocker** (`hooks/block-ssh-bypass.sh`) — Perl-based detection of `ssh`/`scp`/`sftp` invocations with host-key-override flags (`-o StrictHostKeyChecking=no`, `-o UserKnownHostsFile=...`). Also whole-command (chaining-robust). See ADR-022.

> **Why no compound-command blocker?** A `block-compound-commands.sh` hook existed until rip-cage 0.6.0 (removed in rip-cage-4r8). Its only real purpose was permission-allowlist bypass — Claude Code prefix-matches only the *first* command, so an allowlisted `git add` followed by `&& rm -rf` could bypass the allowlist. Under `bypassPermissions` (the cage default) the allowlist does not gate commands at all, making that protection moot. The destructive-command class is fully covered by DCG regardless of chaining. See ADR-002 D5 for the full rationale.

## bypassPermissions

Claude Code runs with `bypassPermissions` enabled in `settings.json`. This means the permission allowlist doesn't gate commands — but DCG and the ssh-bypass blocker still fire as PreToolUse hooks on every command regardless. The hooks provide the actual safety layer.

The `deny` entries in `settings.json` (e.g., `Write(.git/hooks/*)`, `Edit(.git/hooks/*)`) are enforced independently of `bypassPermissions` — they fire as part of the permissions system and block matching tool calls even in bypass mode.

## Allowlisted commands

These commands are listed in the `permissions.allow` array in `settings.json` (auto-approved, no confirmation prompt):

- **File ops:** `ls`, `pwd`, `echo`, `mkdir`, `touch`, `wc`, `tree`, `du`, `df`
- **Path utils:** `basename`, `dirname`, `realpath`, `which`, `type`, `date`
- **Git (read):** `git log`, `git diff`, `git show`, `git status`, `git branch`, `git tag`, `git remote`, `git stash list`, `git rev-parse`
- **Git (write):** `git add`, `git commit`
- **Python:** `uv sync`, `uv lock`, `uv tree`, `uv version`, `uv python list`, `uv init`, `uv run pytest`, `uv run -m pytest`
- **Node:** `npm test`, `npm run test`, `npm run lint`, `npm install`, `npm ci`, `bun test`, `bun install`, `bun run test`, `bun run lint`
- **Beads:** `bd *`

## Hard-denied operations

Writing to `.git/hooks/*` is denied via `Write(.git/hooks/*)` and `Edit(.git/hooks/*)` entries in `settings.json`'s `permissions.deny` array. This prevents the agent from modifying git hooks. These deny rules are enforced regardless of `bypassPermissions` mode.

## Secret-path denylist

A host-side pattern denylist runs at `rc up` time, before the container exists, on every non-workspace mount surface that accepts an arbitrary host path argument. Currently covered: `--env-file` source path, `.beads/redirect` resolved target directory, and skill/agent symlink targets resolved from `~/.claude/skills/` and `~/.claude/agents/`. If any path component matches a default pattern (`.ssh`, `.aws`, `.gnupg`, `credentials`, and 12 more), `rc up` aborts with a fail-loud error naming the matched path, the matched pattern, and the escape hatches (`--allow-risky-mount` for a one-shot bypass, `mounts.allow_risky` in `.rip-cage.yaml` for a persistent per-project allow). The workspace path is never checked — it is validated by the allowed-roots gate from ADR-003, not the denylist. Projects can add custom patterns to the global floor via `.rip-cage.yaml`; they cannot remove global defaults (additive semantics). See [ADR-023](../decisions/ADR-023-secret-path-mount-denylist.md) and [`docs/reference/config.md`](config.md#mountsdenylist-and-mountsallow_risky----secret-path-denylist) for full details and escape-hatch usage.

## Running the safety tests

After starting a container, verify the safety stack:

```bash
rc test <container-name>    # all checks PASS (count grows with safety-stack additions)
```
