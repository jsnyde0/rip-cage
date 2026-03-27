#!/usr/bin/env bash
set -euo pipefail

echo "[rip-cage] Initializing..."

# 1. Fix ownership of bind-mounted dirs (Docker may create them as root)
sudo chown agent:agent ~/.claude 2>/dev/null || true

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

# 3. Restore persistent state from .claude-state volume
if [ -d /home/agent/.claude-state ]; then
  sudo chown agent:agent /home/agent/.claude-state
  for dir in projects sessions; do
    mkdir -p /home/agent/.claude-state/$dir
    ln -sfn /home/agent/.claude-state/$dir ~/.claude/$dir
    echo "[rip-cage] Linked persistent $dir"
  done
fi

# 4. Verify hooks
if [ ! -x /usr/local/bin/dcg ]; then
  echo "[rip-cage] ERROR: DCG not found or not executable at /usr/local/bin/dcg" >&2
  exit 1
fi
if [ ! -x /usr/local/lib/rip-cage/hooks/block-compound-commands.sh ]; then
  echo "[rip-cage] ERROR: block-compound-commands.sh not found at /usr/local/lib/rip-cage/hooks/block-compound-commands.sh" >&2
  exit 1
fi
echo "[rip-cage] Hooks verified"

# 5. Set git identity
git config --global user.name "${GIT_AUTHOR_NAME:-Rip Cage Agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-agent@rip-cage.local}"
echo "[rip-cage] Git identity: $(git config user.name) <$(git config user.email)>"

# 6. Verify Claude Code
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

# 7. Initialize beads
if [ -d /workspace/.beads ]; then
  if bd prime 2>/tmp/bd-prime.log; then
    echo "[rip-cage] Beads initialized"
  else
    echo "[rip-cage] WARNING: bd prime failed (non-fatal). See /tmp/bd-prime.log" >&2
  fi
fi

# 8. Start tmux (CLI mode only — skip if inside VS Code devcontainer)
if [ -z "${VSCODE_INJECTION:-}" ] && [ -z "${REMOTE_CONTAINERS:-}" ]; then
  if command -v tmux > /dev/null 2>&1; then
    tmux new-session -d -s rip-cage -c /workspace 2>/dev/null || true
    tmux set-option -t rip-cage remain-on-exit on 2>/dev/null || true
    tmux set-hook -t rip-cage pane-died 'respawn-pane -c /workspace' 2>/dev/null || true
    echo "[rip-cage] tmux session 'rip-cage' created (CLI mode)"
  fi
fi

echo "[rip-cage] Initialization complete"
