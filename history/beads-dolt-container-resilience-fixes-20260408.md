# Fixes: beads-dolt-container-resilience
Date: 2026-04-08
Review passes: 1

## Critical
(none)

## Important
- **test-bd-wrapper.sh:8** — Hardcoded absolute path to `bd-wrapper.sh` breaks portability. Fix: use `WRAPPER="$(cd "$(dirname "$0")" && pwd)/bd-wrapper.sh"`.
- **test-bd-wrapper.sh:71-76** — Port re-read "test" is a static grep on source code, not a runtime behavioral test. ADR-007 D3 specifies a functional test: "write a test port, run bd, verify env." Fix: add a test that creates a temp port file, creates a mock bd-real that prints `$BEADS_DOLT_SERVER_PORT`, runs the wrapper, and verifies the exported value matches the file content.
- **CLAUDE.md:15,83** — Test count says "27-check" and "27/27 PASS" but the suite now has 32+ checks (26-30 added for wrapper, plus renumbered network/disk). Fix: update to reflect current count.

## Minor
- **docs/2026-04-08-beads-dolt-container-resilience.md:67** — Design doc pseudocode gates port re-read on `BEADS_DOLT_SERVER_MODE=1`, but implementation reads unconditionally. Implementation is better. Fix: update pseudocode to match.

## ADR Updates
- No ADR changes needed.

## Discarded
- **Unconditional port re-read (bd-wrapper.sh:17-24)** — Benign architectural observation, not a bug. Current rc always sets BEADS_DOLT_SERVER_MODE=1.
- **Flag parsing fail-open for --flag value pairs (bd-wrapper.sh:32-46)** — Already documented in design doc edge cases table as an accepted tradeoff.
- **Devcontainer lacks beads redirect resolution (rc devcontainer template)** — Pre-existing gap, not introduced by this change. Out of scope.
- **set -euo pipefail + || true fragility (bd-wrapper.sh:20)** — PORT_FILE is a literal string, cannot be unset. No real risk.
- **Check 25 gates new wrapper checks (test-safety-stack.sh)** — Pre-existing test structure issue. Wrapper checks still run and report; the exit code masking is a separate concern.
