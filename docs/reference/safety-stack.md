# Safety Stack

The safety stack intercepts every shell command via Claude Code's hook system in `settings.json`.

## PreToolUse hooks

Two hooks run before every Bash command:

1. **DCG** (`/usr/local/bin/dcg`) — Rust binary, built from source in the Dockerfile. Blocks destructive commands like `rm -rf`, `dd if=/dev/zero`, filesystem formatting, etc.
2. **Compound command blocker** (`hooks/block-compound-commands.sh`) — Perl-based detection of `&&`, `;`, `||` outside quotes and heredocs. Prevents permission bypass via command chaining.

## bypassPermissions

Claude Code runs with `bypassPermissions` enabled in `settings.json`. This means the allowlist and denylist are bypassed — but DCG and the compound blocker still fire as PreToolUse hooks on every command regardless. The hooks provide the actual safety layer.

## Allowlisted commands

These commands are auto-approved (no confirmation prompt):

- **File ops:** `ls`, `pwd`, `head`, `tail`, `echo`, `mkdir`, `touch`, `wc`, `tree`, `du`, `df`
- **Git (read):** `git log`, `git diff`, `git show`, `git status`, `git branch`, `git tag`, `git remote`
- **Git (write):** `git add`, `git commit`
- **Python:** `uv sync`, `uv lock`, `uv run pytest`, `uv init`
- **Node:** `npm test`, `npm install`, `npm ci`, `bun test`, `bun install`
- **Beads:** `bd *`

## Hard-denied commands

Writing to `.git/hooks/*` is hard-denied — prevents the agent from modifying git hooks.

## Running the safety tests

After starting a container, verify the safety stack:

```bash
rc test <container-name>    # should be 32/32 PASS
```
