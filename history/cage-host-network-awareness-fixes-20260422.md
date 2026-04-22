# Fixes: cage-host-network-awareness
Date: 2026-04-22
Review passes: 1 (architecture + implementation, in parallel)

## Critical

- **`cage-claude.md` + `init-rip-cage.sh:179-209`** — Doc promised a literal
  `host.docker.internal` fallback that the code did not implement. The probe's
  warning branch left `CAGE_HOST_ADDR` unset and `settings.json` un-injected,
  so tool-call `Bash` would silently expand to `''`. Fix: on probe failure,
  write the literal `host.docker.internal` to `cage-env` and still inject
  it into `settings.json`, with a distinct WARNING log line. ADR-016 D2
  updated to document the fallback.

## Important

- **`init-rip-cage.sh:255` (was grep `CAGE_HOST_ADDR`)** — `.zshrc`
  idempotency guard checked for the wrong string: the appended line sources
  `/etc/rip-cage/cage-env` but contains no `CAGE_HOST_ADDR` literal, so every
  resume re-appended the source line. Reproduced before fix: 3 `cage-env`
  lines after 3 init runs. Fix: grep for `/etc/rip-cage/cage-env` instead.
  Added test `.zshrc sources cage-env exactly once` to prevent regression.

- **`init-rip-cage.sh:201-219`** — `jq … && mv` silently skipped
  `settings.json` env injection on jq failure. Fix: explicit if/else with
  success and failure log lines; tmp file cleaned up on failure.

- **`init-rip-cage.sh:71-79`** — awk markers were unanchored; an agent
  quoting the marker verbatim elsewhere in `CLAUDE.md` could trick the strip
  pass into eating unrelated content. Fix: anchor `^<!-- begin:...` /
  `^<!-- end:...`.

- **`tests/test-safety-stack.sh:432-505`** — Original test compared
  `settings.json` `.env.CAGE_HOST_ADDR` against the shell's
  `$CAGE_HOST_ADDR`, which passes even when disk and settings disagree.
  Fix: parse `cage-env` directly and compare against settings. Added
  `.zshrc` single-source idempotency assertion. Added `SKIP_HOST_BRIDGE=1`
  escape so air-gapped CI can demote the `CAGE_HOST_ADDR resolves` check
  to INFO (mirrors existing `SKIP_AUTH` pattern).

## Minor

- **`docs/ROADMAP.md:12-15`** — ADR-016 checkboxes were left unchecked
  despite implementation landing. Ticked all four.

## Discarded

- **Arch F4 (probe ordering: before mise install)** — ADR D2 placement is
  intentional per design. The theoretical "mise uses host-local mirror" case
  is speculative; ADR-016 already says "revisit when demand appears".
- **Arch F5 (triple env-surface cache coherency)** — Probe runs once per
  init; settings.json and cage-env are both rewritten every init, so they
  converge. No re-probe mechanism exists to create the drift the reviewer
  hypothesized.
- **Arch F6 (non-zsh shells not patched)** — Pre-existing pattern from
  `firewall-env`; cage's default shell is zsh; out of scope.
- **Arch F7 (atomic tmp+mv on cage-env)** — Attempted; blocked by root-owned
  parent dir (`/etc/rip-cage`). Reverted to direct `cat >` write on the
  agent-owned file; added a comment explaining the tradeoff. Payload is
  <50 bytes, init holds single-writer at boot.
- **Arch F9 (negative-path test for probe failure)** — Hard to harness
  (requires simulating a runtime with no bridge). Manually verified the
  fallback branch by running the probe loop with bogus candidates;
  produced the literal fallback as expected. Deferred formal test.
- **Arch F10 (Linux Docker Engine `host.docker.internal`)** — Verified
  `rc` already passes `--add-host=host.docker.internal:host-gateway`
  (`rc:879`), so plain Docker Engine on Linux works. Non-issue.
- **Impl F5 (`cage-claude.md` Python one-liner quoting)** — Reviewer
  misread the snippet. Outer double-quotes expand `$CAGE_HOST_ADDR` in the
  shell before Python sees it; the inner single quotes are Python's
  string quotes. Tested: `curl` via the snippet's pattern returned HTTP
  200. No change.

## ADR Updates

- **ADR-016 D2** — Revised to document the literal-fallback behavior:
  probe still writes `host.docker.internal` as `CAGE_HOST_ADDR` on failure,
  paired with a WARNING. Rationale added to explain why empty-string
  expansion was worse than a fallback that doesn't resolve.

## Validation

- Built image, ran `rc up` against fresh workspace.
- 66/66 assertions pass in `test-safety-stack.sh` (5 new under
  "Cage Host-Network Awareness").
- End-to-end: `python3 -m http.server 8765 --bind 0.0.0.0` on host →
  `curl http://$CAGE_HOST_ADDR:8765/` from cage → HTTP 200.
- Idempotency: 3 consecutive init runs → exactly 1 `cage-env` source line
  in `.zshrc`, exactly 1 `begin:rip-cage-topology` marker pair.
- Simulated air-gapped probe (bogus candidate names): fallback literal
  was selected.
