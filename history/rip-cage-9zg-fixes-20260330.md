# Fixes: rip-cage-9zg (Phase 1 Hardening)
Date: 2026-03-30
Review passes: 2

## Critical
(none)

## Important

- **docs/decisions/ADR-002-rip-cage-containers.md:199-210** — ADR-002 D10 amendment says "Dolt removed per ADR-004 D1, bd uses `BD_NO_DB=true` (JSONL-only storage)." This is wrong. ADR-004 D1 (FIRM) says *keep* Dolt, connect to host's Dolt server. The Dockerfile confirms Dolt IS installed. The alternatives table still lists `bd without Dolt (BD_NO_DB=true)` as chosen. Rewrite the entire D10 amendment to: "Amended 2026-03-27: Container bd connects to host's Dolt server via `host.docker.internal` (ADR-004 D1). Dolt is kept in the image as a required dependency for bd v0.62.0+."

- **docs/ROADMAP.md:13** — Says "Drop Dolt, use bd no-db mode (ADR-004 D1)." ADR-004 D1 says the opposite. Change to: "Connect container bd to host Dolt server (ADR-004 D1)" and mark done.

- **docs/2026-03-27-phase1-hardening-design.md:167,171-173,187** — Three stale references from an earlier design iteration when "remove Dolt" was planned:
  - Line 167: "Amend D10 to note that Dolt was removed" — should say "Amend D10 to reflect host-server connection approach"
  - Line 171-173: "Image ~103MB smaller. Removing Dolt is pure savings. bd continues to work with JSONL storage." — remove entirely or replace with note about Dolt host-server approach
  - Line 187: "No new dependencies (Dolt is removed, not added)" — change to "Dolt is kept (required by bd v0.62.0+)"

- **test-safety-stack.sh:104,111** — Auth check uses `-f` (file exists) instead of `-s` (non-empty). Design doc D3 and `rc` line 346 both specify `-s` because keychain extraction can produce empty files on failure. An empty credentials file passes the `-f` check, reporting "Auth present: OAuth" (false positive). Fix: change `-f` to `-s` on both lines.

- **test-safety-stack.sh:78** — Unbalanced parenthesis in jq expression: `select(startswith("Write(.git/hooks"))` is missing a closing `)`. jq tolerates this currently but it's fragile. Fix: `select(startswith("Write(.git/hooks")))`.

- **Dockerfile:54** — Dolt installed via `latest` with no version pin: `curl ... /releases/latest/download/install.sh | bash`. Unlike DCG (`DCG_VERSION=0.4.0`) and Claude Code (`CLAUDE_CODE_VERSION`), a breaking Dolt update could silently break bd. Fix: add `ARG DOLT_VERSION=X.Y.Z` and pin the download URL.

- **rc:~410 (docker run)** — `host.docker.internal` not available on Linux Docker Engine (standard VPS runtime) without `--add-host`. ADR-002 D7 says the same image runs on Mac and VPS. Fix: add `--add-host=host.docker.internal:host-gateway` to the `docker run` invocation (no-op on macOS where the DNS already exists).

- **CLAUDE.md:49** — Claims "npm is configured with a user-writable prefix." No such configuration exists in the Dockerfile, zshrc, or init script. The actual mechanism: npm global installs aren't available (sudo for npm was removed from sudoers). Fix: rewrite to "npm global installs are not available at runtime — no sudo for npm. Global packages must be pre-installed in the Dockerfile."

## Minor

- **test-safety-stack.sh:175** — `grep -oP` (Perl regex) not available on macOS. If someone runs the test script on the host for local testing, it fails. Replace with `sed -n 's/.*Total: \([0-9]*\).*/\1/p'` or awk.

- **settings.json:68-77** — `bd prime` SessionStart/PreCompact hooks run unconditionally. If host Dolt server is down or `.beads/` doesn't exist, bd may timeout and block session startup. Guard with: `"command": "test -d /workspace/.beads && bd prime || true"` (hooks run outside compound blocker).

## ADR Updates

- **ADR-002 D10**: Needs full rewrite of amendment text (lines 199-210). Current text describes an approach that was rejected by ADR-004 D1. See Important item #1 above.
- No other ADR changes needed.

## Discarded

- **Symlink guard on .claude-state chown** (Arch P2): Reviewer claimed guard was missing. Actually present at init-rip-cage.sh:38. Wrong finding.
- **Dolt port at two layers** (Arch P1): rc sets at creation, init re-reads at start. Defense-in-depth, not a bug. init's value takes precedence.
- **Duplicate BEADS exports in init** (both passes): Documented as intentional defense-in-depth in history/phase1-hardening-fixes-20260327.md.
- **BEADS_DOLT_SERVER_PORT in devcontainer shells** (Impl P1): The export from init-rip-cage.sh dies with the postStartCommand process. However, bd inside the container reads the port file directly when BEADS_DOLT_SERVER_MODE=1 is set, so interactive bd commands work. Not a real issue.
- **O(n^2) jq loop in rc test** (Impl P1): 27 checks, trivially fast. Not worth optimizing.
- **Git committer identity** (both passes): git config set by init-rip-cage.sh handles committer fallback. Semantically imprecise but functionally correct.
- **Resource limit flag validation** (Arch P2): Docker provides clear error messages for invalid values. Unnecessary duplication.
- **Credentials file umask** (Impl P1): Mitigated by macOS home directory permissions. Host-only concern.
- **Settings overwrite vs ADR-005 hook registration** (Arch P2): Intentional design trade-off, explicitly documented in design doc. All hook registrations must be baked into image's settings.json.
- **Container name length** (Impl P2): Docker Desktop allows long names. Edge case for hypothetical runtimes.
- **--memory-swap coupling** (Arch P2): Intentional per ADR-004 D2 rationale. Documenting would be nice but not a fix.
- **No test coverage for D2/D3 features** (Impl P2): Valid observation but out of scope for this review — these would be new features, not fixes to existing code.
- **touch:*/mkdir:* writing .git/hooks** (Impl P2): DCG evaluates the full command including path arguments. `touch .git/hooks/pre-commit` would be classified as destructive. The deny rules in settings.json apply to Write/Edit tools; DCG covers the Bash tool path. Not a real gap.
- **echo:* redirection** (Arch P1): Same reasoning — DCG evaluates `echo "x" > .git/hooks/pre-commit` as a command writing to a protected path. If DCG misses this, it's a DCG issue, not an allowlist issue.
- **Test count inconsistency** (Impl P1): CLAUDE.md (27) matches actual code. Design doc says 26, ADR says 25+. Both are "at least" thresholds, not exact counts.
