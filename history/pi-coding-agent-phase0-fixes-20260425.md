# Fixes: pi-coding-agent-phase0
Date: 2026-04-25
Review passes: 1 (architecture + implementation, parallel)
Source commits: 63aa9028 (B1), 69d5035d (B2), 140f005 (B3), b193c30 (B4), 6b05232 (B6), 4931353 (B5)

## Critical

- **`init-rip-cage.sh:109`** — Guard 1 is always-true. `/pi-agent` is pre-created with `agent:agent` ownership in `Dockerfile:104-105` (B1's bind-mount-as-root prevention), so `[ -d /pi-agent ]` is true whether or not the host's `~/.pi/agent` was actually mounted. When the mount is skipped the script still enters the block and writes the cage-topology block into a container-local file pi never reads — silently incorrect, not silently benign. **Fix:** replace `if [ -d /pi-agent ] && [ -f /etc/rip-cage/cage-pi.md ]; then` with `if [ "${PI_CODING_AGENT_DIR:-}" = "/pi-agent" ] && [ -f /etc/rip-cage/cage-pi.md ]; then`. `PI_CODING_AGENT_DIR` is only exported by `_up_prepare_docker_mounts` when the host dir actually exists, so this is an authoritative mount-presence signal.

- **`tests/test-pi-cage-context.sh:112,120`** — Test 5 / 5b are broken by two compounding bugs: (1) `grep -c 'begin:rip-cage-topology$'` uses `$` anchor where the actual marker line is `<!-- begin:rip-cage-topology -->`, so the pattern matches **zero** lines on healthy input; (2) `grep -c ... 2>/dev/null || echo "0"` — when grep finds zero matches it prints `0` AND exits 1, then `|| echo "0"` runs and appends another `0`, producing `count=$'0\n0'`, which `[[ ... -eq N ]]` cannot evaluate. **Fix:** replace `grep -c 'begin:rip-cage-topology$'` with `grep -c 'begin:rip-cage-topology -->'` (Claude marker, anchored on the `-->` close). For the negative pi-marker check (Test 5b) use `grep -c 'begin:rip-cage-topology-pi -->'`. Replace the `... 2>/dev/null || echo "0"` pattern with: `count=$(docker exec ... grep -c '...' file 2>/dev/null); [[ -z "$count" ]] && count=0` — never `|| echo` a numeric command-substitution.

- **`tests/test-pi-cage-context.sh:173`** — Test 7 (mount-absent guard) cannot fail. `init_output=$(docker exec ... 2>&1) || true; init_exit=$?` — the `|| true` swallows the exit code, so `$?` is always 0 and the `init_exit -eq 0` assertion always passes. **Fix:** change to `init_output=$(docker exec "$CONTAINER2" /usr/local/bin/init-rip-cage.sh 2>&1); init_exit=$?` (drop `|| true`). Also add the assertion that the mount-absent guard actually held: `! docker exec "$CONTAINER2" test -f /pi-agent/AGENTS.md || fail "Test 7c" "AGENTS.md should not exist when mount was skipped"`. (Currently passes vacuously even with the always-true Guard 1 above.)

- **`rc:227,248,322-328`** — Devcontainer pi mount + `PI_CODING_AGENT_DIR` are unconditional, while `_up_prepare_docker_mounts` (lines 867-872) correctly conditionalizes them on `${HOME}/.pi/agent` existing. Result: VS Code "Reopen in Container" silently creates a host-level `~/.pi/agent` (or fails to start, depending on Docker version) for users who don't have pi installed; pi inside the devcontainer always points at `/pi-agent` and writes to a misconfigured path instead of triggering its own `/login` flow. Diverges from ADR-019 D1's "skip when host dir absent" intent on the devcontainer code path. **Fix:** add `mkdir -p \"\${localEnv:HOME}/.pi/agent\"` to the `initializeCommand` chain in both heredocs (lines 278, 294) so the host dir always exists before VS Code mounts it. This matches the design's "if missing, pi will fail loudly on first request via /login" behavior — pi sees an empty `/pi-agent`, no `auth.json`, and surfaces its `/login` UI. (Alternative: post-process the devcontainer.json with jq to delete the mount line when the host dir is absent at `rc init` time. The `mkdir -p` is lower friction.)

## Important

- **`rc:876`** — `_UP_RUN_ARGS+=(-e "CAGE_HOST_ADDR")` (bare form, no `=value`) silently forwards from host env if set, otherwise omits the var. The host generally has no `CAGE_HOST_ADDR` (it's a cage-internal concept), so the var ships empty/missing for non-interactive `pi -p` runs — exactly the case the design called out as needing explicit propagation. **Fix:** resolve the value on the host side using the same probe logic init-rip-cage.sh:229 uses (`host.docker.internal` / `host.orb.internal`), or accept the existing default in init-rip-cage.sh and pass it explicitly: `_UP_RUN_ARGS+=(-e "CAGE_HOST_ADDR=${CAGE_HOST_ADDR:-host.docker.internal}")`. Update the comment in rc to reflect the chosen approach. Without this, `tests/test-pi-e2e.sh` runs see `CAGE_HOST_ADDR=` empty in pi-spawned subprocess env.

- **`tests/test-pi-auth-mount.sh:109-117`** — Test 4 passes if any line starting with `CAGE_HOST_ADDR=` exists in `docker exec env`. An empty value (`CAGE_HOST_ADDR=`) passes. **Fix:** assert non-empty: `cage_addr_line=$(docker exec "$CONTAINER" env | grep '^CAGE_HOST_ADDR='); [[ "${cage_addr_line#CAGE_HOST_ADDR=}" != "" ]] && pass ... || fail ...`.

- **`tests/test-pi-auth-mount.sh:64-69`** — `cleanup()` does `rm -rf "$PI_AGENT_DIR"` then `cp -a "$PI_AGENT_BACKUP/." "$PI_AGENT_DIR/"`. If the `cp` fails (disk full, signal, permission flake), the user's real `~/.pi/agent` is gone with no rollback path. **Fix:** atomic mv-swap. Replace with `mv "$PI_AGENT_DIR" "${PI_AGENT_DIR}.evicting" && mv "$PI_AGENT_BACKUP" "$PI_AGENT_DIR" && rm -rf "${PI_AGENT_DIR}.evicting"`. Mirror the same pattern wherever `~/.pi/agent` is touched in this test.

- **`.gitignore` (new entry needed)** — B2's commit message claims `.devcontainer/.env-pi` is gitignored by the `.env.*` rule. `git check-ignore` confirms `.env.*` does NOT match `.env-pi` (the glob requires a literal dot after `.env`). The file is currently safe **only** because `.devcontainer/` itself is gitignored, which is an unrelated rule that could be changed without anyone noticing the env-pi exposure. **Fix:** add an explicit `**/.env-pi` (or simply `*/.env-pi`) entry to `.gitignore`. Update the comment near `rc` line 331 and the B2 commit-message claim.

- **`tests/test-pi-e2e.sh:33-37`** — Skip guard handles missing `~/.pi/agent/auth.json` but not missing `rip-cage:latest` image. The other pi tests skip with `SKIP: rip-cage:latest image not built` when the image is absent; this one fails with `FAIL: container did not come up` instead. **Fix:** mirror the `docker image inspect rip-cage:latest >/dev/null 2>&1 || { echo "[skip] rip-cage:latest not built"; exit 0; }` pattern from the other pi tests.

- **`tests/test-e2e-lifecycle.sh:263-270` (and the equivalent blocks for cases 2/3/4)** — Auth-warn matrix tests resolve `_acN_name` from `docker ps --filter`, then call `docker logs "$_acN_name"` without guarding on empty. If `rc up` silently failed (name collision, image error), `_acN_name=""` and `docker logs ""` returns "Error: No such container:" — `grep -q 'WARNING: No auth'` then doesn't match, falsely passing the "no warning" expected outcome. **Fix:** guard each case with `[[ -z "$_acN_name" ]] && { check "auth-warn case N" "fail" "container did not start"; continue; }`.

- **`tests/test-pi-cage-context.sh` Test 7 (in addition to fix above)** — Even with Guard 1 fixed and exit-code captured correctly, the test is asserting the wrong thing for the mount-absent guard. It asserts `init exit 0` and `no AGENTS.md error in output`. The correct assertion is that `/pi-agent/AGENTS.md` does NOT exist when the mount was skipped. **Fix:** add positive assertion (already covered in fix above): `! docker exec "$CONTAINER2" test -f /pi-agent/AGENTS.md`.

## Minor

- **`cage-pi.md:50-53`** — The Precedents section dropped the Beads Dolt server bullet, which is harness-agnostic and was mentioned in cage-claude.md. ADR-019 D3's intent was to **add** pi-specific precedents, not remove existing ones. The current pi precedents (`/pi-agent/auth.json`, `/pi-agent/extensions/`) are also conceptually mismatched with the section's framing: it's titled "Precedents inside the cage that already use this bridge" — these paths don't use the host bridge. **Fix:** keep the Beads bullet; either reframe the section title to "Notable cage paths" or move the pi-state bullets to a separate sub-section, leaving Beads + Firewall CA trust as the bridge-using precedents.

- **`.claude/harness.md`** — The harness inventory's "Targeted test scripts" list does not mention any of the new pi tests (`test-pi-install.sh`, `test-pi-auth-mount.sh`, `test-pi-cage-context.sh`, `test-pi-e2e.sh`). Project CLAUDE.md says "Consult `.claude/harness.md` when picking a feedback loop for a task." **Fix:** add a row per pi test with the same shape as existing entries.

- **`tests/run-host.sh`** — None of the new pi tests are wired into the host-runner script. Until they are added, `rc test --host` does not exercise the pi stack. The tests already guard on `docker image inspect rip-cage:latest`, so they're safe to include unconditionally. **Fix:** add `tests/test-pi-install.sh tests/test-pi-auth-mount.sh tests/test-pi-cage-context.sh tests/test-pi-e2e.sh` to the run-host.sh dispatch list.

- **`init-rip-cage.sh:277` — step "8b" numbering** — Existing init steps are numbered 1, 2, 3, …, 8, 9 monotonically. Calling the new pi-verify step "8b" deviates. **Fix:** renumber the comment to "9. Pi verify" and bump subsequent step numbers (or simply drop the explicit number — most sections in this file are now identified by section comment, not numeric).

## ADR Updates

No ADR revisions needed. The devcontainer-mount divergence (Critical #4) is an implementation gap, not a contradiction of D1 — D1 specifies the mechanism (single bind + env-var redirect); the implementation faithfully wires this into both `cmd_up` and `cmd_init`. The "skip when host dir absent" behavior is a design-doc detail that the cmd_init path missed; fixing it via `initializeCommand mkdir -p` aligns the two code paths without changing the architecture.

## Discarded

The following findings were considered and not included in the fix list:

- **`local _count` in test-pi-auth-mount.sh cleanup** (Implementation #5) — `local` is valid inside functions, even trap handlers. Stylistic note, not a bug.
- **`_resolve_container` calling realpath at call time in test-pi-e2e.sh** (Implementation #4) — current flow only calls it after `TEST_WS` is set. Structural inconsistency with other tests but no real-world risk.
- **`_pi_envfile` scope in cmd_init** (Implementation #10) — correctly in scope; the implementer specifically asked us to verify and we did.
- **`: > file` portability** (Implementation #11) — both files use `#!/usr/bin/env bash`; the redirect is valid bash and POSIX sh.
- **`${!_pi_var:-}` set -u handling** (Implementation #12) — indirect expansion with a default works correctly under `set -u` when the referenced var is unset.
- **AGENTS.md double-blank-line cosmetic** (Implementation #7) — inherited from the existing Claude path; markdown-tolerant; not worth a divergent fix in just the pi path.

These were verified during triage; if a future reviewer flags any of them again, the rationale lives here.
