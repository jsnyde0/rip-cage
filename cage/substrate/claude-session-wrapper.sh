#!/usr/bin/env bash
# claude-session-wrapper.sh — Per-session Claude config isolation (rip-cage-p1p)
#
# Placed at /usr/local/bin/claude (precedes /usr/bin/claude on PATH).
# Resolves CLAUDE_CONFIG_DIR and seeds the session dir before exec-ing the real
# Claude binary at /usr/bin/claude.
#
# Resolution precedence (D4, updated rip-cage-1f59.4 — multiplexer-agnostic):
#   1. Explicit CLAUDE_CONFIG_DIR env var — use as-is.
#   2. Inside tmux ($TMUX set) — derive handle from session name.
#   3. Inside herdr ($HERDR_SESSION set) — derive handle from HERDR_SESSION env var.
#   4. Else — use ~/.claude-sessions/default (headless / no-multiplexer fallback).
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
  # No snapshot present (init never took one, or it was removed). Falling back to the
  # live virtiofs mount, whose handle may be broken if the host rewrote ~/.claude.json —
  # this is the exact R4 failure mode, so make the fallback observable rather than silent.
  echo "[claude-wrapper] WARNING: no ~/.claude/.claude.json.seed snapshot found; seeding from the live ~/.claude.json mount (may be ENOENT/empty if the host rewrote it — R4, rip-cage-p1p)" >&2
  CLAUDE_JSON_BASE="${HOME}/.claude.json"
fi

# ---------------------------------------------------------------------------
# Resolve the config dir handle (multiplexer-agnostic, rip-cage-1f59.4)
# ---------------------------------------------------------------------------
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  # Case 1: caller set it explicitly — use it directly
  SESSION_DIR="$CLAUDE_CONFIG_DIR"
elif [[ -n "${TMUX:-}" ]]; then
  # Case 2: inside a tmux session — derive handle from session name
  HANDLE=$(tmux display-message -p '#S' 2>/dev/null || echo "default")
  SESSION_DIR="${SESSIONS_BASE}/${HANDLE}"
elif [[ -n "${HERDR_SESSION:-}" ]]; then
  # Case 3: inside a herdr session — derive handle from HERDR_SESSION env var
  # (herdr src/session.rs: SESSION_ENV_VAR="HERDR_SESSION"; set for named sessions)
  SESSION_DIR="${SESSIONS_BASE}/${HERDR_SESSION}"
else
  # Case 4: no multiplexer identity — headless/no-context fallback
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
# Pre-accept the bypass-permissions disclaimer (rip-cage-k8vi).
#
# bypassPermissions is already the cage's DECLARED policy (cage/agent/
# settings.json permissions.defaultMode=bypassPermissions). Claude still gates a
# one-time "Bypass Permissions mode" accept dialog on the global config field
# `bypassPermissionsModeAccepted` in $CLAUDE_CONFIG_DIR/.claude.json. Because the
# host ~/.claude.json is a READ-ONLY virtiofs mount, an in-session accept can
# never persist, so the dialog reappears on EVERY cold boot/recreate — blocking
# every restored/spawned agent pane until a human accepts per pane (defeats
# walk-away autonomy). The per-session ${SESSION_DIR}/.claude.json is a WRITABLE
# copy (NOT the ro mount), so pre-seeding the acceptance here only re-affirms
# declared policy — it is not a weakening of the ro posture, and not an
# auto-approver watching panes. Runs every invocation (OUTSIDE the seed-once
# block above) so an already-seeded session dir that survives a resume is
# retrofitted too. Fully guarded: a jq/write failure must never block the claude
# launch — worst case degrades to the pre-existing dialog, never a broken exec.
{
  _rc_bypass_json="${SESSION_DIR}/.claude.json"
  if command -v jq >/dev/null 2>&1 && [[ -f "$_rc_bypass_json" ]] \
     && [[ "$(jq -r '.bypassPermissionsModeAccepted // false' "$_rc_bypass_json" 2>/dev/null)" != "true" ]]; then
    _rc_bypass_tmp="${_rc_bypass_json}.k8vi.tmp"
    if jq '.bypassPermissionsModeAccepted = true' "$_rc_bypass_json" > "$_rc_bypass_tmp" 2>/dev/null \
       && [[ -s "$_rc_bypass_tmp" ]]; then
      mv -f "$_rc_bypass_tmp" "$_rc_bypass_json"
    else
      rm -f "$_rc_bypass_tmp"
    fi
  fi
} || true
unset _rc_bypass_json _rc_bypass_tmp 2>/dev/null || true

# ---------------------------------------------------------------------------
# Env hygiene (rip-cage-46s5, S4 spike trap): an inherited
# CLAUDE_CODE_CHILD_SESSION marker silently disables transcript saving in
# interactive panes (docs/2026-07-27-msb-spike-roster-resume.md, S4 footgun
# #2 -- two interactive sessions incl. a clean /exit wrote NO transcript
# jsonl while inheriting this marker from the launching process's own env).
# This wrapper is the single PATH-shadowing chokepoint for every claude
# invocation (herdr scripted-attach resume, -p one-shots, direct calls) --
# scrubbing it here covers every spawn/resume path uniformly, without
# special-casing herdr (or any other multiplexer)'s own start/resume hooks.
unset CLAUDE_CODE_CHILD_SESSION

# ---------------------------------------------------------------------------
# Kill the bypass-permissions accept dialog at argv level (rip-cage-k8vi).
#
# bypassPermissions is already the cage's DECLARED policy (cage/agent/
# settings.json permissions.defaultMode=bypassPermissions). Claude still gates a
# one-time "Bypass Permissions mode" accept dialog on the global field
# bypassPermissionsModeAccepted — which cannot persist (host ~/.claude.json is a
# ro virtiofs mount) and, observed live (rip-cage-k8vi), is NOT reliably honored
# from the per-session config for the interactive dialog. Passing
# --dangerously-skip-permissions states at argv what the cage already declares,
# suppressing the dialog HYPOTHESIS-INDEPENDENTLY: it works whether the field is
# read from the per-session config or not, and whether a launcher goes through
# CLAUDE_CONFIG_DIR or not. This wrapper is the single PATH chokepoint every
# launch resolves through (herdr agent start/restore drives the pane shell so
# `claude` -> this wrapper; human `claude`; scripted-attach `claude --resume`).
# The per-session field-seed above stays as belt-and-suspenders for wrapper-path
# launches. Idempotent: only prepend when absent, so an explicit caller flag is
# never doubled. (bypassPermissions being declared policy, this is alignment,
# not a new grant.)
_rc_skip_flag="--dangerously-skip-permissions"
_rc_have_skip=0
for _rc_a in "$@"; do
  if [[ "$_rc_a" == "$_rc_skip_flag" ]]; then _rc_have_skip=1; break; fi
done
if [[ "$_rc_have_skip" -eq 0 ]]; then
  set -- "$_rc_skip_flag" "$@"
fi
unset _rc_skip_flag _rc_have_skip _rc_a

# ---------------------------------------------------------------------------
# Exec the real Claude binary — avoid recursion (this wrapper is at /usr/local/bin/claude)
# ---------------------------------------------------------------------------
exec "$REAL_CLAUDE" "$@"
