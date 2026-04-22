#!/usr/bin/env bash
set -euo pipefail

# Source firewall CA trust vars if firewall init has run (Phase 1 root init).
# Makes NODE_EXTRA_CA_CERTS, SSL_CERT_FILE, etc. active for this script and for
# any Claude Code process it spawns.
if [[ -f /etc/rip-cage/firewall-env ]]; then
  source /etc/rip-cage/firewall-env
fi

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

# Install settings template — merge with workspace project settings if present to
# preserve project-level mcpServers and hooks (rip-cage fields take precedence).
# Source is /workspace/.claude/settings.json, NOT ~/.claude/settings.json, so that
# re-running init on container resume doesn't re-merge rip-cage settings into
# themselves (which doubled hooks and caused a jq precedence crash).
mkdir -p ~/.claude
if [ -f /workspace/.claude/settings.json ]; then
  jq -s '
    .[0] as $project |
    .[1] as $rip_cage |
    $rip_cage
    | .mcpServers = (($project.mcpServers // {}) + ($rip_cage.mcpServers // {}))
    | .hooks = (
        (($project.hooks // {}) | to_entries) +
        (($rip_cage.hooks // {}) | to_entries)
        | group_by(.key)
        | map({key: .[0].key, value: (map(.value) | flatten)})
        | from_entries
      )
  ' /workspace/.claude/settings.json /etc/rip-cage/settings.json > /tmp/merged-settings.json
  mv /tmp/merged-settings.json ~/.claude/settings.json
else
  cp /etc/rip-cage/settings.json ~/.claude/settings.json
fi
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
for _rc_asset in skills commands agents; do
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

# 7. Project toolchain provisioning (mise)
#    No-op unless /workspace declares tools via .tool-versions / .mise.toml / .nvmrc / etc.
if [ -r /workspace ]; then
  _toolfiles=(.mise.toml mise.toml .tool-versions .nvmrc .node-version .python-version .ruby-version rust-toolchain.toml go.mod)
  _found_tool=""
  for f in "${_toolfiles[@]}"; do
    if [ -f "/workspace/$f" ]; then _found_tool="$f"; break; fi
  done
  if [ -n "$_found_tool" ]; then
    echo "[rip-cage] Toolchain: detected /workspace/$_found_tool — running mise install"
    # Ensure cache volume is writable by agent — guard on actual ownership mismatch to
    # avoid a recursive chown on every boot once the shared cache grows large.
    if [ ! -L /home/agent/.local/share/mise ] \
       && [ "$(stat -c %U /home/agent/.local/share/mise 2>/dev/null)" != "agent" ]; then
      sudo chown -R agent:agent /home/agent/.local/share/mise 2>/dev/null || true
    fi
    # Fail-loud on install errors so the agent sees them; but don't block container start —
    # a broken lockfile shouldn't render the whole cage unusable.
    if (cd /workspace && mise install 2>&1 | tee /tmp/mise-install.log); then
      echo "[rip-cage] Toolchain: mise install complete"
    else
      echo "[rip-cage] WARNING: mise install failed (see /tmp/mise-install.log). Toolchain may be unavailable." >&2
    fi
  else
    echo "[rip-cage] Toolchain: no tool-version files detected — skipping"
  fi
  unset _toolfiles _found_tool
fi

# 8. Verify Claude Code
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

# 9. Initialize beads
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

# Append firewall env vars to agent's .zshrc so interactive shell sessions
# and tmux panes inherit CA trust on every new shell.
# Guard is idempotent: skip if already present (avoids growing .zshrc on every resume).
if [[ -f /etc/rip-cage/firewall-env ]]; then
  if ! grep -q 'NODE_EXTRA_CA_CERTS' /home/agent/.zshrc 2>/dev/null; then
    cat /etc/rip-cage/firewall-env >> /home/agent/.zshrc
  fi
fi

# 10. Start tmux (CLI mode only — skip if inside VS Code devcontainer)
if [ -z "${VSCODE_INJECTION:-}" ] && [ -z "${REMOTE_CONTAINERS:-}" ]; then
  if command -v tmux > /dev/null 2>&1; then
    tmux new-session -d -s rip-cage -c /workspace 2>/dev/null || true
    tmux set-option -t rip-cage remain-on-exit on 2>/dev/null || true
    tmux set-hook -t rip-cage pane-died 'respawn-pane -c /workspace' 2>/dev/null || true
    echo "[rip-cage] tmux session 'rip-cage' created (CLI mode)"
  fi
fi

echo "[rip-cage] Initialization complete"
