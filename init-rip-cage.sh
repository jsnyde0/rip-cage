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

# ADR-017 D1 / ADR-018 2026-04-25: when ssh-agent forwarding is on, the
# mounted host socket arrives owned by the host uid (e.g. 501:67278 on
# macOS/OrbStack) and is inaccessible to the in-container agent user
# (uid 1000). Reassign ownership so the agent can sign. This only affects
# the container's view — the host socket file is untouched on the host side.
# Sudoers grants this exact command (Dockerfile NOPASSWD list); fail loud if
# the grant has drifted, since silent failure here was the original 2026-04-25
# bug (agent user permanently locked out of the proxied socket on macOS).
if [[ -S /ssh-agent.sock ]]; then
  if ! sudo -n chown agent:agent /ssh-agent.sock 2>/tmp/rc-chown-err; then
    echo "[rip-cage] WARNING: failed to chown /ssh-agent.sock — agent user will not reach host ssh-agent." >&2
    echo "[rip-cage]   sudo error: $(cat /tmp/rc-chown-err 2>/dev/null)" >&2
    echo "[rip-cage]   Likely cause: stale image without sudoers grant. Rebuild with './rc build'." >&2
  fi
  rm -f /tmp/rc-chown-err
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
mkdir -p ~/.claude
if [ -f /home/agent/.rc-context/global-claude.md ] && [ -s /home/agent/.rc-context/global-claude.md ]; then
  cp /home/agent/.rc-context/global-claude.md ~/.claude/CLAUDE.md
  echo "[rip-cage] Global CLAUDE.md copied"
else
  # Start with an empty file so the cage-topology append below has something to
  # write to even when the host did not provide a global CLAUDE.md.
  : > ~/.claude/CLAUDE.md
  echo "[rip-cage] No global CLAUDE.md (using empty base)"
fi
# Append cage-authored network-topology section under fenced markers (ADR-016 D1).
# Idempotent: strip any prior cage-topology block before re-appending, so repeat
# `init-rip-cage.sh` runs across container resume do not stack duplicate sections.
if [ -f /etc/rip-cage/cage-claude.md ]; then
  # Anchor marker regex at start-of-line so an agent or skill that quotes the
  # marker verbatim in unrelated content doesn't trigger the strip.
  awk '
    /^<!-- begin:rip-cage-topology -->/ { skip=1; next }
    /^<!-- end:rip-cage-topology -->/   { skip=0; next }
    !skip { print }
  ' ~/.claude/CLAUDE.md > /tmp/claude-md-base
  # Ensure a trailing blank line between host content and cage section.
  if [ -s /tmp/claude-md-base ]; then
    printf '\n' >> /tmp/claude-md-base
  fi
  cat /tmp/claude-md-base /etc/rip-cage/cage-claude.md > ~/.claude/CLAUDE.md
  rm -f /tmp/claude-md-base
  echo "[rip-cage] Cage-topology section appended to ~/.claude/CLAUDE.md"
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
  # package.json triggers mise only when it declares packageManager or engines.node —
  # most Node projects without these fields should not incur a mise install.
  # jq is always present (installed in Dockerfile) — no grep fallback needed.
  if [ -z "$_found_tool" ] && [ -f /workspace/package.json ]; then
    if jq -e '.packageManager or .engines.node' /workspace/package.json >/dev/null 2>&1; then
      _found_tool="package.json (packageManager/engines.node)"
    fi
  fi
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

# 7a. Host-bridge preflight probe (ADR-016 D2).
# DNS-only probe of well-known host-bridge hostnames. First resolvable wins.
# If none resolve (air-gapped, unusual runtime), fall back to the literal
# `host.docker.internal` and log a warning — agents will discover it doesn't
# resolve when they try to use it. This matches the fallback contract in
# /etc/rip-cage/cage-claude.md ("set by init; falls back to literal ...").
# Writes CAGE_HOST_ADDR to /etc/rip-cage/cage-env so every interactive shell,
# tmux pane, and Claude-Code child process gets a uniform surface.
_cage_host_addr=""
_cage_probe_status="resolved"
for _candidate in host.docker.internal host.orb.internal; do
  if getent hosts "$_candidate" >/dev/null 2>&1; then
    _cage_host_addr="$_candidate"
    break
  fi
done
if [ -z "$_cage_host_addr" ]; then
  _cage_host_addr="host.docker.internal"
  _cage_probe_status="fallback-literal"
  echo "[rip-cage] WARNING: no host bridge resolvable — using literal '$_cage_host_addr' as fallback (host services will be unreachable)" >&2
else
  echo "[rip-cage] Host bridge: $_cage_host_addr"
fi
# Direct truncate-and-write. /etc/rip-cage/cage-env is pre-created
# agent-writable by the Dockerfile (so no sudo needed); the parent dir stays
# root-owned (so mv-rename would fail). The written payload is <50 bytes and
# init holds a single-writer contract at boot, so a tmp+mv dance isn't worth
# the added complexity.
cat > /etc/rip-cage/cage-env <<EOF
export CAGE_HOST_ADDR="$_cage_host_addr"
EOF
export CAGE_HOST_ADDR="$_cage_host_addr"
# Inject into merged settings.json so Claude-Code-spawned Bash tool calls
# inherit $CAGE_HOST_ADDR without relying on an interactive shell. Fail-loud
# (per ADR-001) if jq fails — a silent skip here produces a settings.json
# that doesn't match cage-env, which the safety-stack test will also catch.
if [ -f ~/.claude/settings.json ]; then
  _cage_settings_tmp="$(mktemp /tmp/settings-with-env.XXXXXX)"
  if jq --arg v "$_cage_host_addr" \
        '.env = ((.env // {}) + {CAGE_HOST_ADDR: $v})' \
        ~/.claude/settings.json > "$_cage_settings_tmp"; then
    mv "$_cage_settings_tmp" ~/.claude/settings.json
    echo "[rip-cage] CAGE_HOST_ADDR injected into settings.json ($_cage_probe_status)"
  else
    rm -f "$_cage_settings_tmp"
    echo "[rip-cage] WARNING: failed to inject CAGE_HOST_ADDR into settings.json (jq error)" >&2
  fi
  unset _cage_settings_tmp
fi
unset _cage_host_addr _candidate _cage_probe_status

# 8. Verify Claude Code
if ! claude --version > /dev/null 2>&1; then
  echo "[rip-cage] ERROR: claude --version failed" >&2
  exit 1
fi
echo "[rip-cage] Claude Code $(claude --version) ready"

# 8b. Pi verify
if command -v pi >/dev/null 2>&1; then
    echo "[rip-cage] pi $(pi --version) ready"
else
    echo "[rip-cage] FATAL: pi not found in image" >&2
    exit 1
fi

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

# Same pattern for cage-env (CAGE_HOST_ADDR) so interactive shells and tmux
# panes inherit the host-bridge hostname (ADR-016 D2). Guard greps for the
# path of the appended line, not $CAGE_HOST_ADDR — the appended line sources
# the file and does not contain the variable name, so a variable-name grep
# would fail on every resume and duplicate the source line indefinitely.
if [[ -f /etc/rip-cage/cage-env ]]; then
  if ! grep -q '/etc/rip-cage/cage-env' /home/agent/.zshrc 2>/dev/null; then
    # Source via file to pick up future re-probes without needing another append.
    echo '[ -f /etc/rip-cage/cage-env ] && source /etc/rip-cage/cage-env' \
      >> /home/agent/.zshrc
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
