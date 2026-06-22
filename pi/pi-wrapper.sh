#!/usr/bin/env bash
# pi-wrapper.sh — Rip Cage pi launch hardening (rip-cage-sn1h)
#
# Intercepts every `pi` invocation and adds:
#   --no-extensions -e <dcg-gate.ts>
# disabling auto-discovery so /workspace/.pi/extensions/ admits NO
# agent-dropped extension. Load order is deterministic.
#
# The real pi binary lives at /usr/bin/pi (npm-installed global).
# This wrapper is installed at /usr/local/bin/pi (earlier in PATH).
#
# ADR-024 D2: closes the workspace-path DCG bypass (rip-cage-sn1h).
# ADR-025 D3/D4: the dcg-gate.ts extension is the per-agent guard wiring
#   that must be loaded from the unwritable (root-owned) cage path.
# wlwc D5 half (b): "launch the agent so it loads guard wiring ONLY
#   from the unwritable path" — this is that launch hook, baked as a
#   recipe artifact per the composable-seam design.
#
# Vetted explicit extension set (loaded in order):
#   1. /home/agent/.pi/agent/extensions/dcg-gate.ts — baked DCG guard
#      (root-owned, agent-unwritable; rip-cage-olen / rip-cage-bl1)
#   2. /home/agent/.pi/agent/extensions/subagent/index.ts — host-projected
#      subagent extension, IF present (linked by init-rip-cage.sh at runtime)
#
# Any host-composed extensions passed via additional -e flags on the outer
# invocation are preserved (they appear AFTER these, in $@).

set -euo pipefail

REAL_PI="/usr/bin/pi"
DCG_GATE="/home/agent/.pi/agent/extensions/dcg-gate.ts"
SUBAGENT_EXT="/home/agent/.pi/agent/extensions/subagent/index.ts"

# Fail loud if the real pi binary is missing (Dockerfile regression)
if [[ ! -x "$REAL_PI" ]]; then
  echo "[rip-cage pi-wrapper] FATAL: real pi binary not found at ${REAL_PI}" >&2
  exit 1
fi

# Fail loud if dcg-gate.ts is missing (guard not baked — should never happen)
if [[ ! -f "$DCG_GATE" ]]; then
  echo "[rip-cage pi-wrapper] FATAL: DCG guard extension missing at ${DCG_GATE}" >&2
  echo "[rip-cage pi-wrapper] pi would launch without command gating — refusing to start" >&2
  exit 1
fi

# Build the vetted extension list
VETTED_EXTENSIONS=("--no-extensions" "-e" "$DCG_GATE")

# Include the subagent extension if projected (init-rip-cage.sh links it at runtime)
if [[ -f "$SUBAGENT_EXT" ]]; then
  VETTED_EXTENSIONS+=("-e" "$SUBAGENT_EXT")
fi

# Exec the real pi with vetted flags prepended, all original args preserved
exec "$REAL_PI" "${VETTED_EXTENSIONS[@]}" "$@"
