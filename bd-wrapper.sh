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
# Accept only strictly-numeric content to avoid exporting garbage (trailing
# whitespace, stale lock debris) that would still pass -n but produce an
# invalid port. If the file content is non-numeric, leave BEADS_DOLT_SERVER_PORT
# unset so the D7 diagnostic below fires with the right guidance.
PORT_FILE="/workspace/.beads/dolt-server.port"
if [[ -f "$PORT_FILE" ]]; then
  port=$(cat "$PORT_FILE" 2>/dev/null || true)
  port="${port//[[:space:]]/}"  # strip all whitespace
  if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" != "0" ]]; then
    export BEADS_DOLT_SERVER_PORT="$port"
  fi
fi

# --- Diagnostic: server mode but no usable port (ADR-007 D7) ---
# If BEADS_DOLT_SERVER_MODE=1 but BEADS_DOLT_SERVER_PORT is missing/0,
# bd will dial host.docker.internal:0 and fail with a confusing timeout.
# Emit a clear diagnostic to stderr before invoking bd-real so the caller
# gets actionable info. Skip for trivially-safe commands that don't need the db.
# `:-0` default covers unset/empty and literal "0" in a single comparison.
if [[ "${BEADS_DOLT_SERVER_MODE:-0}" == "1" ]] \
   && [[ "${BEADS_DOLT_SERVER_PORT:-0}" == "0" ]]; then
  _bd_first="${1:-}"
  case "$_bd_first" in
    --version|-v|--help|-h|help) : ;;  # no-op commands don't need the server
    *)
      {
        echo "[bd-wrapper] ERROR: BEADS_DOLT_SERVER_MODE=1 but no Dolt port is available."
        echo "[bd-wrapper] Expected: /workspace/.beads/dolt-server.port (read on each call)."
        if [[ ! -f "$PORT_FILE" ]]; then
          echo "[bd-wrapper] Cause: port file does NOT exist at $PORT_FILE."
          echo "[bd-wrapper]   - If this is a git worktree, the .beads/ bind mount is probably"
          echo "[bd-wrapper]     pointing at the worktree's checkout instead of the main repo's"
          echo "[bd-wrapper]     .beads/. Recreate the container with a fresh 'rc up' — rip-cage"
          echo "[bd-wrapper]     auto-redirects worktree .beads/ to the main repo (ADR-007 D6)."
          echo "[bd-wrapper]   - Otherwise, the host Dolt server isn't running. On the host run:"
          echo "[bd-wrapper]       cd <project>"
          echo "[bd-wrapper]       bd dolt start"
        else
          echo "[bd-wrapper] Cause: port file is empty, zero, or non-numeric."
          echo "[bd-wrapper] Fix: on the host, run these in sequence to rewrite the port file:"
          echo "[bd-wrapper]   bd dolt stop"
          echo "[bd-wrapper]   bd dolt start"
        fi
      } >&2
      ;;
  esac
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
