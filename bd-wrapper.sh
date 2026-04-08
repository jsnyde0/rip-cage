#!/usr/bin/env bash
# bd-wrapper.sh — wraps /usr/local/bin/bd-real
#
# Purpose:
#   1. Block `bd dolt start` when BEADS_DOLT_SERVER_MODE=1 (a host-side Dolt
#      server is already running; starting a second one would corrupt state).
#   2. Re-read the Dolt server port from /workspace/.beads/dolt-server.port on
#      every invocation so bd always connects to the right port.
#   3. Pass everything else through to the real bd binary unchanged.
#
# ADR-007 constraints:
#   D1: real binary lives at /usr/local/bin/bd-real; this wrapper is /usr/local/bin/bd
#   D2: ONLY `bd dolt start` is blocked — dolt stop, dolt status, etc. MUST pass through

set -euo pipefail

# --- Port re-read (D1: re-read on every invocation) ---
PORT_FILE="/workspace/.beads/dolt-server.port"
if [[ -f "$PORT_FILE" ]]; then
  port=$(cat "$PORT_FILE" 2>/dev/null || true)
  if [[ -n "$port" ]]; then
    export BEADS_DOLT_SERVER_PORT="$port"
  fi
fi

# --- Block `bd dolt start` when server mode is active (D2) ---
# Scan past any leading global flags (e.g. --verbose, --config=...) to find
# the first two non-flag positional arguments (subcommand pair).
if [[ "${BEADS_DOLT_SERVER_MODE:-0}" == "1" ]]; then
  sub1=""
  sub2=""
  for arg in "$@"; do
    case "$arg" in
      --*|-*)
        # global flag — skip
        ;;
      *)
        if [[ -z "$sub1" ]]; then
          sub1="$arg"
        elif [[ -z "$sub2" ]]; then
          sub2="$arg"
          break
        fi
        ;;
    esac
  done

  if [[ "$sub1" == "dolt" && "$sub2" == "start" ]]; then
    echo "BLOCKED: bd dolt start is not allowed inside the container (BEADS_DOLT_SERVER_MODE=1)." >&2
    echo "The Dolt server is managed by the host. Use 'bd dolt stop' or 'bd dolt status' as needed." >&2
    exit 1
  fi
fi

# --- Pass through to real binary ---
exec /usr/local/bin/bd-real "$@"
