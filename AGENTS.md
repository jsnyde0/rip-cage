# Rules for AI Agents Calling rc

These rules apply to AI agents that use `rc` programmatically (e.g., from automation scripts or other Claude Code instances).

## Behavioral rules

- Always use `--output json` when parsing output programmatically
- Always use `--dry-run` before `rc destroy` to confirm the target
- Use `rc ls --output json` to discover containers before operating on them
- Container names are derived from paths — use `rc ls` to get exact names, don't construct them
- The `name` field in `rc up --output json` is the source of truth; names may include a hash suffix when disambiguation occurs
- `rc up --output json` does NOT attach to tmux — use `rc attach` separately
- `rc attach` has no `--output json` mode — use `rc ls --output json` to verify container status before calling attach
- Never call `rc destroy` without confirming with the user first
- Use `rc auth refresh` to update credentials without destroying containers
- Set `RC_ALLOWED_ROOTS` to colon-separated absolute paths before calling `rc up` or `rc init`

## Technical reference

For JSON output format, flag details, and container naming conventions, see [docs/reference/cli-reference.md](docs/reference/cli-reference.md).
