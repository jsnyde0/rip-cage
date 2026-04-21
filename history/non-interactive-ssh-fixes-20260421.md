# Fixes: non-interactive-ssh
Date: 2026-04-21
Review passes: 1 (Opus architecture + Sonnet implementation, competing)

## Context

Two reviewers converged on the same core architectural defect: the `Match final Host *` fragment is claimed to provide override-resistance against user-written `~/.ssh/config`, but does not actually do so for the options that matter most (`BatchMode`, `StrictHostKeyChecking`). OpenSSH's "first value wins" rule applies across all passes including the `Match final` re-evaluation, so any `~/.ssh/config` `Host github.com` block setting `BatchMode no` silently wins over the system fragment. The primary incident (interactive SSH hang in the default no-user-config case) is still fixed — the posture holds when no user config exists. But the stated forward-compat guarantee and the SSH_N6 regression test are both built on false premises.

No FIRM ADR decisions are violated (ADR-014 D2's incident-case posture holds), but the design narrative and ADR-014 D2 rationale need a caveat, and the test needs to be restructured to guard what is actually guaranteed.

## Critical

- **`docs/2026-04-21-non-interactive-ssh-design.md` "Interaction with existing ADRs" line about ADR-002 D11 mirror + the `Match final` override-resistance claim** — Retract the "authoritative substrate mirror" framing. `Match final` is config-level precedence, not physical enforcement; it does not defeat user-config `Host` blocks for options those blocks already set. Rewrite as: `Match final` lets our block apply during the final resolution pass, which gives us precedence *for options not already set by user config* (notably `UserKnownHostsFile`/`GlobalKnownHostsFile`/`ConnectTimeout`); it does NOT override user-file values for options like `BatchMode`/`StrictHostKeyChecking`. Remove the ADR-002 D11 parallel — D11 is a read-only bind mount (real enforcement), this is defeatable config precedence. Note that the incident-case fix (default container with no user config) is unaffected and still works.

- **`docs/decisions/ADR-014-push-less-cage.md` D2 "What would invalidate this"** — Add a caveat bullet: `Match final` cannot override (a) explicit CLI `-o` flags (command-line beats config), nor (b) user-config values for options the user already sets (`first value wins` across passes). The FIRM decision stands for the default container, but the ADR should be honest that an agent that writes a hostile `~/.ssh/config` or passes `GIT_SSH_COMMAND='ssh -o BatchMode=no'` defeats the posture. A future bot-identity or forwarded-agent scenario that needs real enforcement would require a read-only `~/.ssh` bind mount akin to ADR-002 D11 — note this as the upgrade path.

- **`tests/test-safety-stack.sh` SSH_N6 (override-resistance test)** — Replace the current override test (which will fail at runtime because `Match final` does not actually defeat the hostile user config) with a baseline-posture test: explicitly assert that *with no `~/.ssh/config` present*, `ssh -G github.com` resolves `batchmode yes` and `stricthostkeychecking (yes|true)`. Keep the test name `SSH_N6` and the "verifies non-interactive posture" intent, but reframe: "baseline posture holds" rather than "user config cannot override." Remove the hostile-config plant-and-restore dance entirely.

- **`tests/test-safety-stack.sh` SSH_N7 (CLAUDE.md text guard)** — Compound `grep 'git push' && grep 'succeeds'` is a weaker guard than the label implies; it passes even with many `git push` occurrences as long as `succeeds` is absent. Replace with a stricter assertion that catches any reintroduced push-mandate: `grep -qE 'git push.*(succeeds|required|mandatory|must stop)' CLAUDE.md; [ $? -ne 0 ]`. The `bd dolt push` guard is fine as-is (simple absence check).

## Important

- **`scripts/refresh-github-known-hosts.sh` fingerprint comment** — Current awk pipeline produces a doubled `SHA256:` prefix in the provenance header (`SHA256_ED25519: SHA256:+DiY3...`), diverging from the committed header (`SHA256_ED25519: +DiY3...`). Fix: strip the prefix with `awk -F: '{print $3}'` or `sed 's/^SHA256://'` before writing. Verify first-run output matches the committed file byte-for-byte.

- **`scripts/refresh-github-known-hosts.sh` dependency guards** — Add explicit `command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }` and `command -v curl >/dev/null || { ... }` guards at the top. Currently `set -euo pipefail` will abort on missing-command but without a user-facing hint.

- **`scripts/refresh-github-known-hosts.sh` cross-platform `ssh-keygen`** — `ssh-keygen -l -f /dev/stdin <<< "..."` fails silently on macOS. Write to a tmpfile via `trap` cleanup and pass the tmpfile path to `ssh-keygen -l -f`. Portability matters because a maintainer refreshing keys likely runs the script on their host, not in the cage.

- **`Dockerfile` lines 82-83 — defensive `mkdir -p /etc/ssh/ssh_config.d`** — `debian:bookworm` ships with this directory present, but the `COPY` relies on an implicit assumption. Add `RUN mkdir -p /etc/ssh/ssh_config.d` before the COPYs, or combine into a single `RUN` that creates + copies if BuildKit is available. One-line forward-compat against base-image churn.

- **`tests/test-integration.sh` Step 13** — Test command explicitly passes `-o BatchMode=yes -o ConnectTimeout=5`, which means Step 13 passes whether or not the system `ssh_config.d/00-rip-cage.conf` is installed. Remove the redundant `-o BatchMode=yes` and align `-o ConnectTimeout` with the system's `ConnectTimeout 10` (or remove entirely and rely on system config). This makes Step 13 actually exercise the shipped posture.

## Minor

- **`CLAUDE.md` line 60** — Stale "should be 32/32 PASS" comment. With 8 new SSH checks, the count is now 43 (non-worktree) / 48 (worktree). Update to match, or replace the count with a generic success marker that doesn't drift.

- **`docs/2026-04-21-non-interactive-ssh-design.md` Verification section** — Design lists 7 Tier 1 bullets but implementation has 8 `check()` calls (SSH_N7 is a single bullet covering two assertions). Either split N7 in the design doc's bullet list, or annotate the N7 bullet as "2 check() calls." Doc/impl consistency only.

## ADR Updates

- **ADR-014-push-less-cage.md** (paired) — Add caveat to D2 rationale and/or "What would invalidate this" section documenting the `Match final` reach limits per Critical finding #2 above. No decision change; the FIRM posture for the incident case still holds. The update is a documentation correction, not a revision of the decision.

- No other ADR changes needed. ADR-001/ADR-002/ADR-012/ADR-013 are all satisfied.

## Discarded

- **SSH_N6 backup/restore of pre-existing `~/.ssh/config`** (Arch Imp #6) — moot because SSH_N6 is being restructured to not touch `~/.ssh/config` at all (see Critical #3).

- **`COPY --chmod=0644` over separate RUN chmod** (Arch Minor #7) — marginal image-layer savings; existing idiom works; not worth the churn.

- **Step 13 move-plan scope beyond one step** (Arch Minor #8) — belongs in the ADR-013 D3 P1 migration work, not this fix cycle. The TODO comment already signals the move target.

- **Design doc "Interaction with existing ADRs" narrative about ADR-002 D11 mirror as a standalone minor** (Arch Minor #9) — folded into Critical #1 (design-doc retraction), not a separate fix.
