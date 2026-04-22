# Fixes: toolchain-provisioning
Date: 2026-04-22
Review passes: 1

## Critical
_(none)_

## Important

- **tests/test-integration.sh:52** — Step 3 safety-stack call was relaxed to `|| true`, which swallows all ~40 structural check failures (DCG wiring, compound-blocker, settings.json, mise checks, bypassPermissions) — not just the auth/beads ones it was meant to work around. Conflicts with ADR-001 (fail-loud) and ADR-013 (Tier 2 gate). Fix: remove the blanket `|| true`. Instead, run the safety-stack check normally — but filter its exit behavior at the source: `test-safety-stack.sh` already reports PASS/FAIL per check and a summary. Either (a) pass a `--skip-auth` flag that excludes the auth/beads category from the fail count, OR (b) run with a dummy credentials shim in the integration test so auth/beads checks succeed. Preferred: option (a) — add a `SKIP_AUTH=1` env var to test-safety-stack.sh that turns the auth/beads section into informational-only (no contribution to FAIL count), then call `SKIP_AUTH=1 /usr/local/lib/rip-cage/test-safety-stack.sh` from the integration test with normal exit-code propagation.

- **tests/test-safety-stack.sh (Mise section, lines 377-408)** — No assertion that `/home/agent/.config/mise/config.toml` exists with `idiomatic_version_file_enable_tools = ["node", "yarn"]`. This config is required for `.nvmrc` and `packageManager` detection; without it the Tier 2 scenarios silently fail. Fix: add two checks — (1) `[[ -f /home/agent/.config/mise/config.toml ]]`, (2) `grep -q 'idiomatic_version_file_enable_tools' /home/agent/.config/mise/config.toml`. Also bump the expected-check count in `rc` help text (see Minor below).

- **tests/test-integration.sh:181** — Step 16 (yarn) uses `zsh -ic` while steps 14/15 use `zsh -lic`. The design doc Tier 2 section explicitly specifies `zsh -lic` to confirm the login-shell activation path agents actually use. Fix: change line 181 from `zsh -ic` to `zsh -lic`.

- **init-rip-cage.sh:136-141** — jq path checks `.packageManager or .engines.node` (top-level only), but the grep fallback matches `"(packageManager|engines)"` anywhere in the JSON, including nested occurrences. Semantic divergence is a trap if jq is ever removed or check order changes. Fix: since jq is installed at Dockerfile:30 and always present, remove the grep fallback entirely and just rely on jq. Alternative: tighten the grep to `grep -qE '^[[:space:]]+"(packageManager|engines)"' /workspace/package.json` for top-level keys only.

## Minor

- **zshrc:51** — `eval "$(/usr/local/bin/mise activate zsh)"` runs unguarded on every shell start; a broken mise binary would poison every pane. Fix: wrap with `command -v /usr/local/bin/mise >/dev/null 2>&1 && eval "$(/usr/local/bin/mise activate zsh)"`.

- **rc:126** — `rc test` help string says "59 checks" but safety-stack now has 65 unconditional checks (61 pre-mise + 6 new) — and should be 67 after the two Tier 1 config.toml assertions above. Fix: update the count to reflect the final number after Important fix #2 lands.

- **docs/2026-04-22-toolchain-provisioning-design.md:161** — Design doc Tier 1 assertion text shows `grep -q 'chown agent:agent /home/agent/.local/share/mise'` (no `-R`), but the implementation uses `-R` everywhere. Fix: update to `grep -q 'chown.*-R.*agent.*mise'` (matches what test-safety-stack.sh actually uses) so the doc accurately describes the enforced check.

- **docs/2026-04-22-toolchain-provisioning-design.md:77** — Design §2 (Shared cache volume) shows non-recursive `sudo chown agent:agent` in the example, but the init-block pseudocode (§3) and implementation both use `-R`. Align §2 with §3 — switch the example in §2 to `sudo chown -R agent:agent` for internal consistency.

## ADR Updates

No ADR changes needed. Finding 1 (|| true) is a code fix, not a design revision — ADR-001 and ADR-013 remain correct as written; the integration test must honor them.

## Discarded

- **Arch-4 (go.mod always triggers mise):** Design §3 explicitly states this is intentional (Go not in base image). Not an issue.
- **Arch-5 (bash array in init script):** Script shebang is `#!/usr/bin/env bash`. Not a bug.
- **Arch-6 (cache volume no GC):** ADR-015 D2 "What would invalidate this" explicitly defers `rc mise-cache-gc` until disk pressure appears. Consistent with YAGNI posture in D5.
- **Arch-7 (step 15 WARN not FAIL on slow cache-hit):** Intentional soft gate per design — "regression guard, not strict benchmark" per bead notes from beadify pass 2. A 5s soft threshold + any cache-layout regression would also show up in step 14's node version check (which depends on cached install).
- **Arch-8 (MISE_TRUSTED_CONFIG_PATHS coupled to /workspace literal):** Tier 1 test already asserts `MISE_TRUSTED_CONFIG_PATHS=/workspace`. If the mount target ever changes, that test plus the Tier 2 scenarios (which mount `/workspace` explicitly) will catch it. No meaningful regression risk.
- **Arch-9 (init script bash doesn't activate mise post-step-7):** No current step needs mise-provisioned tools. Add only when a future step requires it.
