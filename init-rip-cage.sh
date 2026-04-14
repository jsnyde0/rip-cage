#!/usr/bin/env bash
set -euo pipefail

echo "[rip-cage] Initializing..."

# Beads: determine storage mode from project's metadata.json
# Embedded mode (default): bd uses in-process Dolt on the bind mount — no server needed
# Server mode: connect to host's Dolt server via host.docker.internal
if [[ -f /workspace/.beads/metadata.json ]]; then
  _beads_dolt_mode=$(jq -r '.dolt_mode // empty' /workspace/.beads/metadata.json 2>/dev/null || true)
  if [[ "$_beads_dolt_mode" != "embedded" ]] && [[ -n "$_beads_dolt_mode" ]]; then
    export BEADS_DOLT_SERVER_MODE=1
    export BEADS_DOLT_SERVER_HOST="${BEADS_DOLT_SERVER_HOST:-host.docker.internal}"
    echo "[rip-cage] Beads: server mode (dolt_mode=$_beads_dolt_mode)"
  else
    echo "[rip-cage] Beads: embedded mode — no Dolt server connection"
  fi
else
  echo "[rip-cage] Beads: no metadata.json — defaulting to embedded mode"
fi

# 1. Fix ownership of bind-mounted dirs (Docker may create them as root)
if [[ ! -L /home/agent/.claude ]]; then
  sudo chown agent:agent /home/agent/.claude 2>/dev/null || true
fi

# Overwrite settings template
mkdir -p ~/.claude
cp /etc/rip-cage/settings.json ~/.claude/settings.json
echo "[rip-cage] Settings installed"

# 2. Copy CLAUDE.md files (skip if source missing or empty)
if [ -f /home/agent/.rc-context/global-claude.md ] && [ -s /home/agent/.rc-context/global-claude.md ]; then
  mkdir -p ~/.claude
  cp /home/agent/.rc-context/global-claude.md ~/.claude/CLAUDE.md
  echo "[rip-cage] Global CLAUDE.md copied"
else
  echo "[rip-cage] No global CLAUDE.md (skipped)"
fi
if [ -f /home/agent/.rc-context/home-claude.md ] && [ -s /home/agent/.rc-context/home-claude.md ]; then
  cp /home/agent/.rc-context/home-claude.md ~/CLAUDE.md
  echo "[rip-cage] Home CLAUDE.md copied"
else
  echo "[rip-cage] No home CLAUDE.md (skipped)"
fi

# 3. Link skills and commands from host (staged via .rc-context/)
for _rc_asset in skills commands; do
  if [ -d "/home/agent/.rc-context/${_rc_asset}" ]; then
    # Remove any real directory that may exist — ln -sfn would nest inside it otherwise
    if [ -d ~/.claude/"${_rc_asset}" ] && [ ! -L ~/.claude/"${_rc_asset}" ]; then
      rm -rf ~/.claude/"${_rc_asset}"
    fi
    ln -sfn "/home/agent/.rc-context/${_rc_asset}" ~/.claude/"${_rc_asset}"
    echo "[rip-cage] ${_rc_asset} linked from host"
  fi
done
unset _rc_asset

# 4. Restore persistent state from .claude-state volume
if [ -d /home/agent/.claude-state ]; then
  if [[ ! -L /home/agent/.claude-state ]]; then
    sudo chown agent:agent /home/agent/.claude-state 2>/dev/null || true
  fi
  for dir in projects sessions; do
    mkdir -p /home/agent/.claude-state/$dir
    ln -sfn /home/agent/.claude-state/$dir ~/.claude/$dir
    echo "[rip-cage] Linked persistent $dir"
  done
fi

# 5. Verify hooks
if [ ! -x /usr/local/bin/dcg ]; then
  echo "[rip-cage] ERROR: DCG not found or not executable at /usr/local/bin/dcg" >&2
  exit 1
fi
if [ ! -x /usr/local/lib/rip-cage/hooks/block-compound-commands.sh ]; then
  echo "[rip-cage] ERROR: block-compound-commands.sh not found at /usr/local/lib/rip-cage/hooks/block-compound-commands.sh" >&2
  exit 1
fi
# Verify python3 (required for skill-server.py MCP shim)
if ! command -v python3 > /dev/null 2>&1; then
  echo "[rip-cage] ERROR: python3 not found — skill discovery (skill-server.py) will not work" >&2
  exit 1
fi
echo "[rip-cage] python3 found (skill-server.py will be available)"
echo "[rip-cage] Hooks verified"

# 6. Set git identity
git config --global user.name "${GIT_AUTHOR_NAME:-Rip Cage Agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-agent@rip-cage.local}"
echo "[rip-cage] Git identity: $(git config user.name) <$(git config user.email)>"

# 7. Verify Claude Code
if ! claude --version > /dev/null 2>&1; then
  echo "[rip-cage] ERROR: claude --version failed" >&2
  exit 1
fi
echo "[rip-cage] Claude Code $(claude --version) ready"

# Check auth (warn only, do not fail)
if [ -f ~/.claude/.credentials.json ]; then
  echo "[rip-cage] OAuth credentials found"
elif [ ! -f ~/.claude.json ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[rip-cage] WARNING: No auth found (~/.claude/.credentials.json missing, ANTHROPIC_API_KEY not set)" >&2
fi

# 8. Initialize beads
# Storage mode was determined at top of script from metadata.json.
# For server mode: BEADS_DOLT_SERVER_MODE and HOST are exported; port is re-read by bd wrapper.
# For embedded mode: no server env vars; bd uses in-process Dolt on the bind mount.
if [ -d /workspace/.beads ]; then
  # Fix bind-mount permissions — host may have 0750, bd expects 0700
  chmod 700 /workspace/.beads 2>/dev/null || true
  if [ -n "${BEADS_DOLT_SERVER_MODE:-}" ]; then
    echo "[rip-cage] Beads: connecting to host Dolt server at ${BEADS_DOLT_SERVER_HOST} (port via wrapper)"
  else
    echo "[rip-cage] Beads: using embedded Dolt on bind mount"
  fi
  if bd prime 2>/tmp/bd-prime.log; then
    echo "[rip-cage] Beads initialized"
  else
    echo "[rip-cage] WARNING: bd prime failed (non-fatal). See /tmp/bd-prime.log" >&2
  fi
fi

# 9. Start tmux (CLI mode only — skip if inside VS Code devcontainer)
if [ -z "${VSCODE_INJECTION:-}" ] && [ -z "${REMOTE_CONTAINERS:-}" ]; then
  if command -v tmux > /dev/null 2>&1; then
    tmux new-session -d -s rip-cage -c /workspace 2>/dev/null || true
    tmux set-option -t rip-cage remain-on-exit on 2>/dev/null || true
    tmux set-hook -t rip-cage pane-died 'respawn-pane -c /workspace' 2>/dev/null || true
    echo "[rip-cage] tmux session 'rip-cage' created (CLI mode)"
  fi
fi

echo "[rip-cage] Initialization complete"
