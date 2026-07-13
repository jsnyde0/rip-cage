# Pre-cutover Part-B (container/E2E) test baseline

**Date:** 2026-07-12
**Bead:** rip-cage-7atw.14 (child of rip-cage-7atw)
**Purpose:** The behavior-preservation reference the microsandbox (msb) migration is checked against. After the engine-deletion sweep lands, the Docker-era baseline is unobtainable — so this is captured *before* the tsf2 cutover branch merges.

## Stamped identity (coherent across all `#RUN` blocks in `partb.ledger`)

| field | value |
|---|---|
| commit | `0d213e2` (pinned via `RC_TEST_STAMP_COMMIT`; captured from an isolated `git worktree` at this SHA) |
| image digest | `sha256:ca80f048de8fb8c166af9cbbd37fdfe7583d9fa1aefb2abee5ac69f845905be9` (rebuilt from the pinned worktree source) |
| cage posture | non-possession (this machine's promoted global is non-possession; possession-side coverage evidenced by rip-cage-7atw.10) |
| docker context | OrbStack, via a `/var/run/docker.sock` → OrbStack-socket compatibility symlink (see harness finding below) |
| cage | `jonatanpi-rc-e2e-baseline` (fresh, authed; `claude -p` → READY verified) |

## Result

```
TOTALS: PASS=99 FAIL=14 SKIP=0 ZERO=0 MALFORMED=0 ENUMERATED=113
```

- **ZERO=0** — every one of the 113 driver-enumerated files has a status row; no never-run files.
- **MALFORMED=0**, stamp coherence check passed — no torn rows, no stitched-across-different-identity union.
- **0 confirmed real product regressions.** All 14 non-PASS rows are stale-test-shape, an env/posture flake, or known-deferred. **The tier is a trustworthy behavior-preservation baseline.**

## Harness finding (machine-specific; also recorded for `.claude/harness.md`)

The initial run showed ~29 files failing with `Error: Docker daemon is not reachable`. Root cause (verified, **not** a rip-cage regression):

- This machine's active docker context is `orbstack`; there was **no** `/var/run/docker.sock` (the fallback the docker CLI uses when it can't resolve a named context).
- Many tests sandbox `HOME`/`XDG_CONFIG_HOME` to a temp dir to isolate `rc` from the real host global config. That side-effect loses `~/.docker/config.json` (which names the `orbstack` context), so the CLI falls back to context `default` → `/var/run/docker.sock` → ENOENT → `docker info` exits 1 → `rc check_docker()` reports "not reachable."
- **Fix:** `sudo ln -sf ~/.orbstack/run/docker.sock /var/run/docker.sock` (the standard OrbStack compatibility symlink). Verified: `HOME=/tmp/x docker info` succeeds afterward. Preferred over forcing `DOCKER_HOST`, which pins the deprecated legacy builder and confounds build-heavy tests.

**Cross-workstream heads-up:** the msb migration's own container/build tests (e.g. the mount-denylist re-verify and dind support slices) ran on this machine *before* the symlink existed. Their green verdicts may understate real coverage — worth a re-check under the corrected socket.

## Non-PASS rows (all homed — no silent reds)

| file | class | homing bead | note |
|---|---|---|---|
| test-rc-decomposition-structure.sh | stale | rip-cage-7atw.18 | hardcoded fn count 194→200 post rc-decomposition; make a floor |
| test-manifest-security.sh | stale | rip-cage-7atw.18 | greps monolithic `rc`; fn moved to `cli/lib/manifest_checks.sh`; check active |
| test-cc-dcg-managed-settings.sh | stale | rip-cage-7atw.18 | managed-settings.json un-baked to opt-in recipe (ADR-005 D12) |
| test-manifest-agent-mail.sh | stale | rip-cage-7atw.18 | probe hard-calls `/usr/local/bin/dcg` (dcg un-baked, ADR-025 D2); daemon/MCP pass |
| test-manifest-herdr.sh | stale | rip-cage-7atw.18 | pi-integration install relocated to pi recipe (rip-cage-fwp3) |
| test-skills.sh | stale | rip-cage-7atw.18 | skill-server.py path / agents-symlink / hook shapes un-baked; 71 skills still found |
| test-mount-mode-e2e.sh | stale | rip-cage-7atw.18 | runtime double `rc-` prefix vs test single-prefix name derivation |
| test-claude-concurrency.sh | stale | rip-cage-7atw.18 | non-possession posture (.claude.json.seed not .claude.json) + self-flagged weak neg-control |
| test-claude-json-seed-synthesis.sh | env | rip-cage-7atw.18 | cages fast-failed ~1s, up.out ephemeral; needs isolated re-run to capture logs |
| test-manifest-cross.sh | stale (flagged) | rip-cage-7atw.19 | self-disable-vector check vs composed-DCG-default; **confirm minimal-cage hook exposure** |
| test-manifest-egress.sh | stale (flagged) → **adjudicated** | rip-cage-7atw.20 | E5/E6 = engine-coupled proxy-403 assertions that die with the engine (retire/re-home via rip-cage-hdcl + rip-cage-5iti). **E7 adjudicated a REAL contract gap on a dying path** (Fable ruling 2026-07-12): the durable invariant — every msb flag-materialization event re-runs the manifest IOC check — is **verified PASS on the cutover at 0f1e315** (7atw.20 acceptance (1): `_manifest_check_ioc_egress` fires unconditionally at `cli/up.sh:2292` before all state branching; create/cold-recreate-reload/resume seams each PASS). Docker-era reload.sh NOT fixed (dying path). See the E7 ruling + 8-test suite-green enumeration below. |
| test-manifest-shell.sh | stale (flagged) | rip-cage-7atw.21 | baked eval-line present (T2d) but not observed via bare docker-run; **real-cage repro** |
| test-multiplexer-lifecycle.sh | known-deferred | rip-cage-xnc5 | build-heavy; no auth on baseline |
| test-multiplexer-agent-e2e.sh | known-deferred | rip-cage-2nmp | build-heavy; cage-start deferred |

## Three items flagged for Fable (harness-review confirmation)

None block the baseline (all pre-existing, honestly recorded as RED), but each hides real behavior behind a test that can no longer see it:

1. **rip-cage-7atw.19** — does a *minimal* (non-DCG-composed) cage ship PreToolUse safety hooks in the agent-writable `settings.json` **without** the managed-settings protection? If yes, that's a genuine self-disable vector; if the minimal cage ships no safety hooks (pure containment floor), the test is mis-scoped. The check is also internally inconsistent (fires on absence though its comment says present-only).
2. **rip-cage-7atw.20** — ~~is `rc reload` contractually required to re-run the manifest IOC check on config change?~~ **RESOLVED (Fable ruling 2026-07-12):** YES, contractually required — but the Docker-era `rc reload` early-returns before the check on a manifest-only change. Consequence LOW (the same early-return also skips egress-rule regeneration, so the IOC host is never opened; build/up gates remain the enforced floor). Disposition: do NOT fix the dying Docker path; the durable invariant re-homes to the msb generator and is **verified PASS at cutover 0f1e315** (see the annotated egress row above). The E7 ledger row now points at this ruling (7atw.20 acceptance (3)).
3. **rip-cage-7atw.21** — confirm the baked shell-integration eval-line fires under a real `rc up` cage (near-certainly a bare-docker-run probe artifact).

## Post-merge suite-green exclusion set — the 8 NEEDS_CONTAINER live-e2e tests (Fable ruling 5 r1)

The msb cutover ships the runtime; the safety suite migrates incrementally (S10). Fable's amended
"full host suite green" definition (2026-07-13) counts the suite green EXCEPT (i) env-caused reds
proven to flip green after the operator-config fix, and (ii) **8** NEEDS_CONTAINER live-e2e tests
classified REFACTOR-deferred and owned by open beads. Rider r1: enumerate the 8 here by name +
owning bead **so nothing silently drops**.

**Certain (2) — owned by rip-cage-7atw.22** (Fable named these explicitly):

| test file | owning bead | why deferred |
|---|---|---|
| test-skills.sh | rip-cage-7atw.22 | live meta-skill MCP handshake; skill-server.py path/agents-symlink/hook shapes un-baked, needs authed cage |
| test-claude-json-seed-synthesis.sh | rip-cage-7atw.22 | R4 seed-synthesis non-possession probes; spins own real cages via `rc up` |

**Best-evidenced 6 — owned by rip-cage-5iti** (the msb-side effect-probe / msb-exec-green umbrella).
These are the NEEDS_CONTAINER live-cage tests that are REFACTOR + NC=yes, PASSED in the Docker-era
baseline (so never got a dedicated deferral bead), and still need docker-exec→msb-exec re-platform —
leaving rip-cage-5iti (the general msb suite-port umbrella) as the only owning bead:

| test file | owning bead | why deferred |
|---|---|---|
| test-agent-cli.sh | rip-cage-5iti | full cage lifecycle via `rc up`; docker-exec→msb-exec re-platform |
| test-pi-e2e.sh | rip-cage-5iti | pi e2e; needs authed cage + msb exec |
| test-pi-install.sh | rip-cage-5iti | `docker run --rm` image probe → msb boot |
| test-pi-auth-mount.sh | rip-cage-5iti | live cage env+mounts inspection |
| test-pi-cage-context.sh | rip-cage-5iti | in-cage CLAUDE.md inspection |
| test-agent-mail-concurrent.sh | rip-cage-5iti | two concurrent pi agents via am CLI; fixture image + exec |

**⚠ Enumeration ambiguity flagged for Fable (do not let it silently resolve):** Fable stated "6 under
5iti + 2 under 7atw.22" but never wrote the 6 down, and rip-cage-7atw.22 actually owns **five**
NC/REFACTOR authed-cage files, not two — it also carries **test-cc-dcg-managed-settings.sh**,
**test-mount-mode-e2e.sh**, and **test-claude-concurrency.sh** (all REFACTOR/exec, NC=yes, in this
ledger's 14-FAIL list). Fable's count attributes only 2 of 7atw.22's 5 to the "8". Two readings both
sum to 8 and the artifacts don't adjudicate. The 6 above are the artifact-grounded best fit; the three
extra 7atw.22-deferred files are named HERE explicitly so they demonstrably do **not** silently drop —
they remain deferred under rip-cage-7atw.22 regardless of which reading Fable confirms. (NOT in the
set: test-security-model-injection.sh — owned by rip-cage-tsf2.6, ruling r2 sends it FIRST in the
post-merge test re-platform thread.)

**✔ RESOLVED — Fable ruling 9 (2026-07-13, rip-cage-tsf2 notes):** the count "8" was never binding —
it was the ledger run's red-file count relayed through the merge report, not a design decision. The
binding invariant is rider r1's substance: nothing silently drops. The suite-green exclusion set is
defined **extensionally** as exactly the enumerated files above — 6 under rip-cage-5iti + 5 under
rip-cage-7atw.22 = **11 named files**, every one owned by an open bead. There is no 6+2 split to
confirm; the 2-vs-5 attribution was an undercount in relay, and this table supersedes it.

## Reproduce / resume

Captured from the pinned worktree `/Users/jonatanpi/rc-baseline-wt` (detached at `0d213e2`), with:

```
RC_E2E=1 RC_TEST_CONTAINER=jonatanpi-rc-e2e-baseline \
RC_TEST_STAMP_COMMIT=0d213e2 \
RC_TEST_STAMP_IMAGE_DIGEST=sha256:ca80f048de8fb8c166af9cbbd37fdfe7583d9fa1aefb2abee5ac69f845905be9 \
RC_TEST_LEDGER=<ledger> bash tests/run-host.sh --batch K/8   # K=1..8
bash tests/run-host.sh --ledger-summary <ledger>            # completeness + coherence gate
```

Batch/ledger/stamp support: rip-cage-7atw.13 + rip-cage-7atw.15. Driver self-test (`tests/test-run-host-driver.sh`) was 18/18 green at `0d213e2`.
