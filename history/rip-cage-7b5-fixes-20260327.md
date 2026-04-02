# Fixes: rip-cage-7b5
Date: 2026-03-27
Review passes: 2

## Critical
(none)

## Important

- **docs/decisions/ADR-002-rip-cage-containers.md:235** — D12 amendment only documents npm-install removal. The chown exact-path scoping (the primary security change in this epic) is not recorded. Add a second amendment: chown scoped from wildcard to exact paths (`/home/agent/.claude`, `/home/agent/.claude-state`), pre-created directories as belt-and-suspenders, symlink risk acknowledged for Phase 1.

- **test-security-hardening.sh:73-83** — Test 4 replaced the old npm-install sudoers check entirely. No test now verifies that `npm install` stays out of sudoers. Add an assertion: `echo "$SUDOERS_LINE" | grep -q 'npm install'` should fail.

- **test-rc-commands.sh:88** — Test 6 calls `rc init` without setting `RC_ALLOWED_ROOTS`. Test always fails. Fix: `RC_ALLOWED_ROOTS="$(dirname "$TEST_DIR2")" "$RC" init`.

- **init-rip-cage.sh:7** — Uses `~/.claude` (tilde) while sudoers pins exact path `/home/agent/.claude`. Works today because HOME=/home/agent, but fragile. Change to absolute path `/home/agent/.claude` to match sudoers and line 31's convention.

- **init-rip-cage.sh:31** — `sudo chown agent:agent /home/agent/.claude-state` lacks `|| true` guard. Under `set -euo pipefail`, if sudo fails (corrupt sudoers, missing file), init crashes. Line 7 has `|| true` but line 31 does not. Add `2>/dev/null || true`.

- **test-security-hardening.sh:88-104** — Test 5 picks first container via `head -1` with no staleness check. Verified: produces false FAIL against containers built from pre-scoping images. Fix: compare container image ID against `docker image inspect rip-cage:latest --format '{{.Id}}'`; SKIP if mismatch with message about rebuilding. Also print container name for diagnostics.

## Minor

- **Dockerfile:77** — Comment says "see sudoers below" but sudoers is on line 61 (above). Change "below" to "above".

- **test-dockerfile-sudoers.sh:29** — Grep `chown agent\:agent /home/agent/.claude` also matches `.claude-state` since `.claude` is a prefix. If `.claude` entry were removed, test 2 would still pass on `.claude-state`. Fix: anchor with trailing comma: `chown agent\\:agent /home/agent/.claude,`.

- **test-security-hardening.sh + test-dockerfile-sudoers.sh** — Both files grep the Dockerfile for the same sudoers line with subtly different patterns. Not broken today, but the duplication is a maintenance trap. Consider consolidating sudoers static checks into one file.

## ADR Updates
- **ADR-002 D12**: Needs second amendment documenting chown exact-path scoping + pre-created directories. (Not yet written — this is a fix item.)

## Discarded

- **validate_path uses exit 1 instead of return 1** — Pre-existing pattern, not introduced by this change. Out of scope.
- **Three test scripts define own pass/fail helpers** — Pre-existing pattern across all test files. Consolidation is worthwhile but out of scope for this review.
- **ADR-002 D10 still references Dolt** — Pre-existing inconsistency from ADR-004, not related to this change.
- **cmd_ls lacks docker ps error handling** — Pre-existing pattern. The resolve_name fix is scoped to resolve_name; extending to cmd_ls is a separate improvement.
- **resolve_name error not JSON-compatible** — Pre-existing across all resolve_name error paths. Worth a follow-up, not this change.
- **cmd_init devcontainer.json mount path consistency** — Pre-existing architectural concern, not broken by this change.
- **Test 5 positive case is vacuous** — Testing sudoers policy (exit code), not chown functionality. Acceptable.
- **Fake docker in test 8 intercepts all subcommands** — Works for current cmd_down usage. Over-engineering to handle all subcommands.
- **Test 8 doesn't assert exit code** — Text check is sufficient for the current test scope.
- **Init exec on resume lacks -it** — Pre-existing, not broken, init doesn't need interactive input.

## Borderline (for alignment)

- **Symlink attack on exact-path sudoers (Dockerfile:61)** — The design doc explicitly acknowledges this: agent can `ln -s /usr/local/bin/dcg ~/.claude` then chown via sudoers. The doc classifies it as "acceptable risk for Phase 1." However, the fix is trivial: add `[[ -d ~/.claude ]] && [[ ! -L ~/.claude ]]` check in init-rip-cage.sh before calling chown. My lean: fix it — the cost is 2 lines and it closes a real escalation path. But this contradicts the design doc's explicit risk acceptance, so flagging for your call.
