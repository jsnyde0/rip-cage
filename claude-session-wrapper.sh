#!/usr/bin/env bash
# claude-session-wrapper.sh — Per-session Claude config isolation (rip-cage-p1p)
#
# Placed at /usr/local/bin/claude (precedes /usr/bin/claude on PATH).
# Resolves CLAUDE_CONFIG_DIR and seeds the session dir before exec-ing the real
# Claude binary at /usr/bin/claude.
#
# Resolution precedence (D4):
#   1. Explicit CLAUDE_CONFIG_DIR env var — use as-is.
#   2. Inside tmux ($TMUX set) — derive handle from session name.
#   3. Else — use ~/.claude-sessions/default (headless / no-tmux fallback).
#
# Seeding (D3):
#   Class 1 — symlink shared read-mostly inputs from ~/.claude.
#   Class 2 — copy ~/.claude.json (carries mcpServers, auth, onboarding).
#   Class 3 — own/fresh per-session dirs Claude writes (backups/, etc.).
#
# Idempotent: if the session dir already has .claude.json, skip seeding.

set -euo pipefail

REAL_CLAUDE=/usr/bin/claude
SESSIONS_BASE="${HOME}/.claude-sessions"
CLAUDE_BASE="${HOME}/.claude"
# Seed source resolution (R4 — rip-cage-p1p):
#   1. RC_P1P_JSON_BASE       — test-hook override (test fixtures only)
#   2. ~/.claude/.claude.json.seed — stable container-local snapshot (taken at init time,
#                               decoupled from the virtiofs mount that breaks on host writes)
#   3. ~/.claude.json          — live mount fallback (mount may be broken if host rewrote it)
if [[ -n "${RC_P1P_JSON_BASE:-}" ]]; then
  CLAUDE_JSON_BASE="$RC_P1P_JSON_BASE"
elif [[ -f "${CLAUDE_BASE}/.claude.json.seed" ]]; then
  CLAUDE_JSON_BASE="${CLAUDE_BASE}/.claude.json.seed"
else
  CLAUDE_JSON_BASE="${HOME}/.claude.json"
fi

# ---------------------------------------------------------------------------
# Resolve the config dir handle
# ---------------------------------------------------------------------------
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  # Case 1: caller set it explicitly — use it directly
  SESSION_DIR="$CLAUDE_CONFIG_DIR"
elif [[ -n "${TMUX:-}" ]]; then
  # Case 2: inside a tmux session — derive handle from session name
  HANDLE=$(tmux display-message -p '#S' 2>/dev/null || echo "default")
  SESSION_DIR="${SESSIONS_BASE}/${HANDLE}"
else
  # Case 3: no tmux, no explicit env — headless/no-context fallback
  SESSION_DIR="${SESSIONS_BASE}/default"
fi

export CLAUDE_CONFIG_DIR="$SESSION_DIR"

# ---------------------------------------------------------------------------
# Seed the session dir if .claude.json is absent
# Idempotent: presence of .claude.json means seeding already happened.
# ---------------------------------------------------------------------------
if [[ ! -f "${SESSION_DIR}/.claude.json" ]]; then
  mkdir -p "$SESSION_DIR"

  # Class 1 — symlink shared read-mostly inputs from ~/.claude
  # Each symlink is created with -sfn so re-runs are idempotent.
  # Only create if the source exists (skip gracefully if not present yet).
  # NOTE: mcp-needs-auth-cache.json is intentionally EXCLUDED — Claude writes it
  # per-config-dir, so it is a single-writer surface, not a shared input (R2, rip-cage-p1p).
  # Each session gets its own (Claude creates it on demand).
  for _asset in \
    .credentials.json \
    settings.json \
    CLAUDE.md \
    skills \
    commands \
    agents \
    cache
  do
    if [[ -e "${CLAUDE_BASE}/${_asset}" || -L "${CLAUDE_BASE}/${_asset}" ]]; then
      ln -sfn "${CLAUDE_BASE}/${_asset}" "${SESSION_DIR}/${_asset}"
    fi
  done

  # projects and sessions: symlink TO the shared bind-mountpoints (not per-session dirs).
  # Per D3: these are host-persisted per-id dirs, must NOT be isolated.
  # Collision-safe: Claude writes per-session-id files inside them (not a shared single file).
  for _dir in projects sessions; do
    if [[ -d "${CLAUDE_BASE}/${_dir}" || -L "${CLAUDE_BASE}/${_dir}" ]]; then
      ln -sfn "${CLAUDE_BASE}/${_dir}" "${SESSION_DIR}/${_dir}"
    fi
  done

  # Class 2 — copy ~/.claude.json (carries mcpServers, auth, onboarding state).
  # This is the load-bearing fix: an empty seed drops user-scope MCP servers.
  if [[ -f "$CLAUDE_JSON_BASE" ]]; then
    cp "$CLAUDE_JSON_BASE" "${SESSION_DIR}/.claude.json"
  else
    # Base not present (headless with no host mount) — let Claude create fresh
    : # nothing — Claude will create .claude.json on first run
  fi

  # Class 3 — own/fresh per-session writable dirs.
  # Pre-create backups/ so Claude doesn't find backups + missing .claude.json
  # (the exact trigger for the "configuration file not found" loop).
  mkdir -p "${SESSION_DIR}/backups"
fi

# ---------------------------------------------------------------------------
# Exec the real Claude binary — avoid recursion (this wrapper is at /usr/local/bin/claude)
# ---------------------------------------------------------------------------
exec "$REAL_CLAUDE" "$@"
