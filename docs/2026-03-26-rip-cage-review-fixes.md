# Design: Rip Cage Review Fixes

**Date:** 2026-03-26
**Status:** Ready
**Decisions:** Updates to [ADR-002](decisions/ADR-002-rip-cage-containers.md) (D5 amended, D11-D12 added)
**Origin:** 3-pass competitive review of claude-eue implementation. Fix list: [history/claude-eue-fixes-20260326.md](../history/claude-eue-fixes-20260326.md)

---

## Problem

The Rip Cage Phase 1 implementation (claude-eue) passed review with 0 critical ADR violations but 22 implementation issues: 3 critical bugs, 14 important gaps, 5 minor issues. This design covers all fixes in a single pass.

## Scope

All fixes are targeted edits to existing files under `~/.claude/rip-cage/`. No new files. No architectural changes. ADR-002 gets two new decisions (D11, D12) and one amendment (D5).

---

## Fixes by File

### `Dockerfile`

1. **Install Dolt** — Add `dolt` binary installation before `USER agent`. Without it, `bd` is non-functional (Dolt is the storage backend). Use the official install script pinned to a version.

2. **DCG checksum verification** — After downloading DCG, verify SHA256 checksum. Pin the expected hash as a build arg.

3. **Restrict sudo** — Replace blanket `NOPASSWD:ALL` with scoped sudoers: `apt-get`, `dpkg`, `npm install -g`, `chown`. This prevents an agent from disabling its own safety stack (`sudo rm /usr/local/bin/dcg`). New decision ADR-002 D12.

4. **Fix uv install** — Copy binary to `/usr/local/bin/` instead of symlinking from `/root/.local/bin/`. Ensures `uv self update` works as agent user.

5. **Remove `python3-pip`** — uv-only policy. Saves ~30MB.

6. **Remove `PYTHON_VERSION` build arg** — Dead code. apt installs system python3 (3.11 on bookworm). If version control is needed later, use `uv python install`.

### `settings.json`

7. **Narrow allow list** — Remove `Bash(cat:*)`, `Bash(find:*)`, `Bash(grep:*)`, `Bash(rg:*)`. These auto-approve commands that can read auth files or execute arbitrary commands via `find -exec`. Let the auto-mode classifier handle them. Updated rationale in ADR-002 D5.

8. **Add `.git/hooks` deny rules** — Add `Write(.git/hooks/*)`, `Edit(.git/hooks/*)` to the deny list. An agent writing to `.git/hooks/` inside `/workspace` creates scripts that execute on the host with full privileges when the user runs git commands. New decision ADR-002 D11.

### `init-rip-cage.sh`

9. **Fix tmux working directory** — Change `tmux new-session -d -s rip-cage` to `tmux new-session -d -s rip-cage -c /workspace`.

10. **Fix beads messaging** — Use if/else so "Beads initialized" only prints on success.

11. **Fix bd prime diagnostics** — Redirect stderr to `/tmp/bd-prime.log` instead of `/dev/null`. Reference log in warning message.

12. **Fix auth check** — Add `~/.config/claude-code/auth.json` to the auth detection condition.

### `rc`

13. **Guard auth file mounts** — Check existence of `~/.claude.json` and `~/.config/claude-code/auth.json` before mounting. Warn if missing (Docker creates empty directories for missing bind sources, breaking auth).

14. **Fix failed-init resume** — After failed init on resume, `docker stop` the container so next `rc up` retries properly instead of fast-pathing to a broken "running" container.

15. **Forward git identity env vars** — Auto-detect from host git config: `-e GIT_AUTHOR_NAME="$(git config user.name)" -e GIT_AUTHOR_EMAIL="$(git config user.email)"`.

16. **Sanitize container names** — Pipe `container_name` output through `tr -cs 'a-zA-Z0-9_.-' '-'` and strip leading/trailing hyphens.

17. **Fix `cmd_attach`** — Use `tmux new-session -A -s rip-cage` (create-or-attach) instead of `tmux attach-session -t rip-cage` (fail if missing). Matches `cmd_up` behavior.

### `test-safety-stack.sh`

18. **Fix arithmetic under `set -e`** — Replace `((FAIL++))` with `FAIL=$((FAIL + 1))` and `((PASS++))` with `PASS=$((PASS + 1))`. Bash `((0++))` returns exit code 1, aborting the script on first failure.

### `test-integration.sh`

19. **Remove hardcoded platform** — Drop `--platform linux/arm64` from `docker buildx build`. Let Docker use native architecture.

### `hooks/block-compound-commands.sh`

20. **Read full input** — Replace `$_ = <STDIN>; chomp;` with `my $input = do { local $/; <STDIN> }; chomp $input;`. Multi-line commands (HEREDOCs with `&&` on later lines) currently bypass detection.

21. **Fix `;;` false positive** — Change `;` detection from `;\s*(?!;)` to `(?<!;);(?!;)` so bash case statement terminators don't trigger denial.

### Design doc + ADR

22. **Update golang version** — Change design doc from `golang:1.25-bookworm` to `golang:1.24-bookworm`.

---

## ADR Updates

### D5 amendment: narrow allow list rationale

Add to D5 rationale: "The allow list must be narrow — only commands with no security-relevant side effects. Commands that read arbitrary files (`cat`, `grep`, `find`) or that can embed execution (`find -exec`) must go through the classifier, not the allow list. The allow list is a fast path for known-safe operations, not a convenience shortcut."

### D11 (new): Deny `.git/hooks` writes in bind-mount mode

In bind-mount mode, `/workspace` IS the host filesystem. An agent writing to `.git/hooks/` creates scripts that execute on the host when the user runs git commands — a container escape via the project's own git hooks. Deny `Write(.git/hooks/*)` and `Edit(.git/hooks/*)` in settings.json. Clone mode (Phase 2) eliminates this vector entirely.

### D12 (new): Scoped sudo, not blanket NOPASSWD

The agent user needs sudo for installing project deps (`apt-get`, `npm install -g`) but blanket `NOPASSWD:ALL` lets the agent disable its own safety stack (`sudo rm /usr/local/bin/dcg`). Scope sudoers to: `apt-get`, `dpkg`, `npm install -g`, `chown`. This preserves dep installation capability while preventing safety-stack tampering.

---

## Verification

After all fixes applied:
1. `test-safety-stack.sh` passes all 6 tests (no early abort)
2. `test-integration.sh` passes on native architecture
3. `settings.json` has deny rules for `.git/hooks/*` and no `cat`/`find`/`grep`/`rg` in allow list
4. `Dockerfile` includes `dolt` installation and scoped sudoers
5. `rc up` with missing auth files produces a warning, not a broken container
6. `rc up` resume after failed init stops the container cleanly
7. Container names with special-character paths are sanitized
8. `block-compound-commands.sh` reads full multi-line input and doesn't false-positive on `;;`
