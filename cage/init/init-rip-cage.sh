#!/usr/bin/env bash
set -euo pipefail

# The in-cage egress-firewall CA-trust-env sourcing step (Phase 1 root init,
# init-firewall.sh's firewall-env file) retired with the deleted in-cage
# engine (ADR-029 D2) -- containment is msb's job now.

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
# BASE-INFRA (pi, rip-cage-p35a.3 audit): Pi config dir is container-local
# (ADR-019 D1 evolved). Nothing in the image mkdirs .pi/agent at build time;
# it comes into existence only when 'rc up' bind-mounts auth.json into it,
# which makes Docker auto-create the parent dir root-owned (2026-07-02
# live-verified: rip-cage-fwp3). Chown top-level only (not -R): .pi/agent dir
# and its subdirs (including extensions/) should be agent-writable (olen
# retired per ADR-027 D1/D3 — the DCG guard now lives at
# /etc/rip-cage/pi/dcg-gate.ts on its own separate root-owned load path;
# extensions/ is no longer root-owned). JUSTIFICATION: this requires sudo
# (fixing a Docker-created root-owned bind-mount parent dir) and the TOOL
# 'init' boot-hook seam (rip-cage-p35a.2, ADR-005 D7) is agent-context-ONLY
# (no sudo) — there is no per-recipe root-context boot-time hook today, so
# this genuinely cannot move to pi's recipe. Stays base-infra.
if [[ ! -L /home/agent/.pi/agent ]]; then
  sudo chown agent:agent /home/agent/.pi/agent 2>/dev/null || true
fi
# rip-cage-fwp3's extensions/ mkdir RELOCATED (rip-cage-p35a.3) to pi's own
# recipe as a TOOL 'init' agent-context boot-hook (examples/pi/manifest-
# fragment.yaml, rip-cage-p35a.2 seam / ADR-005 D7) — dispatched generically
# by the "1b. TOOL archetype agent-context init hooks" block below. It no
# longer lives here: base init names no specific tool (ADR-005 D12).

# 1b. TOOL archetype agent-context init hooks (rip-cage-p35a.2, ADR-005 D7).
# Reads the baked config from /etc/rip-cage/tool-init-config.json (written at
# build time by _manifest_generate_tool_init_config_dockerfile_steps in rc).
# Each declared TOOL 'init' command runs ONCE at cage boot, in agent context
# (no sudo) — this is the generic per-recipe agent-context boot-contribution
# seam: a TOOL recipe can run boot-time setup here without rc/init-rip-cage.sh
# naming it (ADR-005 D12 — manifest DATA only, no tool-name literal gates this
# loop). Distinct from IN-CAGE-DAEMON 'start' (section 12 below), which
# launches a long-lived background service, not a one-shot hook.
# FAIL-WARN on a failing init hook — cage still starts (ADR-005 D10 / ADR-001
# asymmetry: safety floor fails-closed, user tool contribution fails-warn).
_rc_tool_init_config="/etc/rip-cage/tool-init-config.json"
if [[ -f "$_rc_tool_init_config" ]] && command -v jq >/dev/null 2>&1; then
  _rc_tool_init_count=$(jq '.tool_inits | length' "$_rc_tool_init_config" 2>/dev/null || echo "0")
  for (( _rc_tii=0; _rc_tii<_rc_tool_init_count; _rc_tii++ )); do
    _rc_tool_init_entry=$(jq -c ".tool_inits[${_rc_tii}]" "$_rc_tool_init_config" 2>/dev/null)
    _rc_tool_init_name=$(jq -r '.name // "unknown"' <<<"$_rc_tool_init_entry" 2>/dev/null)
    _rc_tool_init_cmd=$(jq -r '.init // ""' <<<"$_rc_tool_init_entry" 2>/dev/null)

    if [[ -z "$_rc_tool_init_cmd" ]]; then
      unset _rc_tool_init_entry _rc_tool_init_name _rc_tool_init_cmd
      continue
    fi

    echo "[rip-cage] TOOL '${_rc_tool_init_name}' init hook: running..."
    if eval "$_rc_tool_init_cmd"; then
      echo "[rip-cage] TOOL '${_rc_tool_init_name}' init hook: completed"
    else
      echo "[rip-cage] WARNING: TOOL '${_rc_tool_init_name}' init hook FAILED — cage continues without it." >&2
    fi
    unset _rc_tool_init_entry _rc_tool_init_name _rc_tool_init_cmd
  done
  unset _rc_tii _rc_tool_init_count
fi
unset _rc_tool_init_config

# ADR-017 D1 / ADR-018 2026-04-25: when ssh-agent forwarding is on, the
# mounted host socket arrives owned by the host uid (e.g. 501:67278 on
# macOS/OrbStack) and is inaccessible to the in-container agent user
# (uid 1000). Reassign ownership so the agent can sign. This only affects
# the container's view — the host socket file is untouched on the host side.
#
# ADR-022 D3: Two paths depending on /etc/rip-cage/ssh-allowed-keys sentinel.
#   Sentinel absent         → no key filtering (today's full-forward path)
#                             chown the upstream socket and use it as /ssh-agent.sock
#   Sentinel present, empty → zero-out: afssh with no --comment flags (forward nothing)
#   Sentinel present, N lines → filter: afssh with --comment for each non-comment line
#
# The upstream socket is always mounted as /ssh-agent-upstream.sock when any
# filtering is active. When filtering is absent, rc up mounts it directly as
# /ssh-agent.sock (today's path), so /ssh-agent-upstream.sock may not exist.
_rc_allowed_keys_sentinel="/etc/rip-cage/ssh-allowed-keys"
if [[ -f "$_rc_allowed_keys_sentinel" ]]; then
  # Key filtering active (present file = filtering requested, even if empty = zero-out).
  # The upstream socket was mounted as /ssh-agent-upstream.sock by rc up.
  # Note: the daemon is `ssh-agent-filter`, not `afssh`. afssh is a one-shot
  # ssh wrapper that starts the filter then runs `ssh -A` once and dies.
  # ssh-agent-filter forks, picks `$PWD/agent.<PID>` as its socket path, and
  # prints SSH_AUTH_SOCK / SSH_AGENT_PID to stdout (like ssh-agent does).
  # We cd to an agent-owned tmpdir, parse the printed path, then symlink
  # /ssh-agent.sock → that path so the cage's SSH_AUTH_SOCK contract holds.
  _rc_filter_args=()
  while IFS= read -r _rc_key_comment || [[ -n "$_rc_key_comment" ]]; do
    # Skip blank lines and comment lines
    [[ -z "$_rc_key_comment" || "$_rc_key_comment" == '#'* ]] && continue
    _rc_filter_args+=("--comment" "$_rc_key_comment")
  done < "$_rc_allowed_keys_sentinel"

  if [[ -S /ssh-agent-upstream.sock ]]; then
    if ! sudo -n chown agent:agent /ssh-agent-upstream.sock 2>/tmp/rc-chown-err; then
      echo "[rip-cage] WARNING: failed to chown /ssh-agent-upstream.sock — ssh-agent-filter cannot reach host ssh-agent." >&2
      echo "[rip-cage]   sudo error: $(cat /tmp/rc-chown-err 2>/dev/null)" >&2
    fi
    rm -f /tmp/rc-chown-err

    mkdir -p /tmp/rip-cage-filter
    pushd /tmp/rip-cage-filter >/dev/null
    _rc_filter_out=$(SSH_AUTH_SOCK=/ssh-agent-upstream.sock ssh-agent-filter "${_rc_filter_args[@]+"${_rc_filter_args[@]}"}" 2>/tmp/rc-filter-err)
    _rc_filter_rc=$?
    popd >/dev/null

    if [[ $_rc_filter_rc -ne 0 ]]; then
      echo "[rip-cage] WARNING: ssh-agent-filter failed (rc=$_rc_filter_rc):" >&2
      cat /tmp/rc-filter-err >&2 2>/dev/null
    else
      _rc_filter_sock=$(printf '%s\n' "$_rc_filter_out" | sed -nE "s/^SSH_AUTH_SOCK='([^']+)'.*/\1/p")
      _rc_filter_pid=$(printf '%s\n' "$_rc_filter_out" | sed -nE "s/^SSH_AGENT_PID='([0-9]+)'.*/\1/p")
      if [[ -z "$_rc_filter_sock" || -z "$_rc_filter_pid" ]]; then
        echo "[rip-cage] WARNING: could not parse ssh-agent-filter output:" >&2
        printf '%s\n' "$_rc_filter_out" >&2
      elif ! sudo -n ln -sfT "$_rc_filter_sock" /ssh-agent.sock 2>/tmp/rc-ln-err; then
        echo "[rip-cage] WARNING: failed to symlink /ssh-agent.sock → $_rc_filter_sock" >&2
        cat /tmp/rc-ln-err >&2 2>/dev/null
      else
        echo "$_rc_filter_pid" > /tmp/rip-cage.afssh.pid
        if [[ ${#_rc_filter_args[@]} -eq 0 ]]; then
          echo "[rip-cage] SSH key filter: zero-out (ssh-agent-filter PID=$_rc_filter_pid, forwarding no keys)"
        else
          echo "[rip-cage] SSH key filter: ssh-agent-filter PID=$_rc_filter_pid (${#_rc_filter_args[@]} --comment flags)"
        fi
      fi
      rm -f /tmp/rc-ln-err /tmp/rc-filter-err
    fi
    unset _rc_filter_out _rc_filter_rc _rc_filter_sock _rc_filter_pid
  else
    echo "[rip-cage] WARNING: ssh-allowed-keys sentinel present but /ssh-agent-upstream.sock absent — key filtering skipped." >&2
  fi
  unset _rc_filter_args
else
  # No key filtering: upstream socket was mounted directly as /ssh-agent.sock.
  if [[ -S /ssh-agent.sock ]]; then
    if ! sudo -n chown agent:agent /ssh-agent.sock 2>/tmp/rc-chown-err; then
      echo "[rip-cage] WARNING: failed to chown /ssh-agent.sock — agent user will not reach host ssh-agent." >&2
      echo "[rip-cage]   sudo error: $(cat /tmp/rc-chown-err 2>/dev/null)" >&2
      echo "[rip-cage]   Likely cause: stale image without sudoers grant. Rebuild with './rc build'." >&2
    fi
    rm -f /tmp/rc-chown-err
  fi
fi
unset _rc_allowed_keys_sentinel

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
# BASE-INFRA (pi, rip-cage-p35a.3 audit): ADR-019 D3 (post-c1p.1/hhh.12):
# cage-topology for pi is surfaced via reference in ~/.claude/CLAUDE.md
# (cage-owned path) rather than appended to host AGENTS.md. Post-hhh.12:
# PI_CODING_AGENT_DIR points to container-local /home/agent/.pi/agent. This
# preserves the user's canonical dotpi files intact on the host.
# JUSTIFICATION: this one-line availability echo's own MESSAGE TEXT names
# the literal path /etc/rip-cage/cage-pi.md — the TOOL init hook-bounds
# validator (ADR-005 D11) fail-closed-rejects ANY init command referencing
# '/etc/rip-cage/' (lifecycle-interceptor pattern), even in inert prose. That
# static grep is a blunt safety-floor check, not a semantic one; reformulating
# the message to dodge it isn't worth the churn for a cosmetic echo. Stays
# base-infra.
if [ "${PI_CODING_AGENT_DIR:-}" = "/home/agent/.pi/agent" ]; then
  echo "[rip-cage] Cage-pi topology available at /etc/rip-cage/cage-pi.md (not appended to host AGENTS.md — container-local pi dir preserves host dotpi files intact)"
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

# BASE-INFRA (pi, rip-cage-p35a.3 audit): 3b. Link pi substrate assets from
# host (staged via .rc-context/pi-*)
# DATA-DRIVEN table: stage_name:agent_subpath (NO per-agent if/elif branch — ADR-005 D12).
# For instruction-content assets (skills/prompts/roles/AGENTS.md/SYSTEM.md/APPEND_SYSTEM.md):
# symlink directly (skips gracefully when not present via the [ -e ] guard below).
# Pi launch extensions (e.g. the subagent extension) are no longer projected here —
# they are declared as manifest recipe fragments (mount + launch_args) and assembled
# by rc build into the pi shim (rip-cage-l72i.3, ADR-027 D3/D4); rc names no tool.
# ADR-027 D1: mounts are :ro (host→cage); symlinks here are cage-internal only.
# JUSTIFICATION: the host-side mount projection this loop consumes
# (.rc-context/pi-*) is staged by `rc up` UNCONDITIONALLY whenever
# ${HOME}/.pi/agent exists on the HOST (rc:1461) — completely decoupled from
# whether the pi-recipe TOOL entry is composed in the cage's manifest.
# Relocating this loop into pi-recipe's 'init' hook would silently break
# substrate projection for any cage that has host pi substrate mounted but
# does not compose pi-recipe — a genuine cross-recipe/host-CLI coordination
# case the ADR-005 D7 invalidation clause names explicitly ("a boot step that
# genuinely requires cross-recipe coordination not expressible per-recipe").
# Stays base-infra.
for _pi_substrate in "pi-skills:skills" "pi-prompts:prompts" "pi-roles:roles" "pi-AGENTS.md:AGENTS.md" "pi-SYSTEM.md:SYSTEM.md" "pi-APPEND_SYSTEM.md:APPEND_SYSTEM.md"; do
  _pi_stage="/home/agent/.rc-context/${_pi_substrate%%:*}"
  _pi_dest="${PI_CODING_AGENT_DIR:-/home/agent/.pi/agent}/${_pi_substrate##*:}"
  if [ -e "${_pi_stage}" ] || [ -L "${_pi_stage}" ]; then
    # Remove any real dir/file that exists — ln -sfn would nest inside a dir otherwise
    if [ -e "${_pi_dest}" ] && [ ! -L "${_pi_dest}" ]; then
      echo "[rip-cage] pi: removing pre-existing real dir/file ${_pi_dest} before linking" >&2
      # shellcheck disable=SC2115  # safe: _pi_dest is a computed specific path, not a variable-empty accident
      rm -rf "${_pi_dest}"
    fi
    ln -sfn "${_pi_stage}" "${_pi_dest}"
    echo "[rip-cage] pi ${_pi_substrate##*:} linked from host"
  fi
done
unset _pi_substrate _pi_stage _pi_dest

# BASE-INFRA (pi, rip-cage-p35a.3 audit): host-mount-coupled, stays in base init.
# This block only ECHOES the presence of an rc-up-projected ro extension mount
# (staged by rc up, same host-mount-projection class as the pi-substrate loop above);
# it provisions nothing per-recipe, so it does not belong in the pi TOOL init hook
# (ADR-005 D7 cross-recipe-coordination invalidation clause).
# Pi extension staging path: extensions composed via recipe fragments are projected
# by rc up at /home/agent/.rc-context/pi-ext-<name>/ (ro), then loaded by the assembled
# pi shim via manifest-declared launch_args -e flags (ADR-027 D3/D4 / rip-cage-l72i.3).
# No symlink into extensions/ is needed; the shim loads from the staging path directly.
# Extension mounts are declared in each recipe's mounts: entry (e.g. examples/pi/subagent-fragment.yaml)
# and assembled by _manifest_build_mount_args at rc up time — not hardcoded in rc source.
_pi_ext_stage="/home/agent/.rc-context/pi-ext-subagent"
if [ -e "${_pi_ext_stage}" ] || [ -L "${_pi_ext_stage}" ]; then
  echo "[rip-cage] pi extension: ro-mount present at ${_pi_ext_stage} (loaded via manifest-declared launch_args -e)"
fi
unset _pi_ext_stage

# 4. Claude session persistence (rip-cage-dn2)
# Preferred path: ~/.claude/projects and ~/.claude/sessions are bind-mounted
# from the host, so sessions are visible to host tools (cass) and survive
# container destroy. Inside the container, Claude Code keys sessions by
# /workspace, so we symlink ~/.claude/projects/-workspace to the host's
# encoded project key (passed in via RC_HOST_PROJECT_KEY) to unify history
# with sessions started outside the cage.
#
# Legacy fallback: when no bind mount is present (e.g. older `rc up` from
# a pre-dn2 binary), fall back to the .claude-state Docker volume.
_is_mountpoint() {
  # mountpoint(1) isn't guaranteed installed; /proc/mounts is.
  awk -v p="$1" '$2 == p { found=1; exit } END { exit !found }' /proc/mounts
}

if _is_mountpoint /home/agent/.claude/projects; then
  echo "[rip-cage] Sessions persisted to host (~/.claude/projects bind-mounted)"
  if [ -n "${RC_HOST_PROJECT_KEY:-}" ]; then
    mkdir -p "/home/agent/.claude/projects/${RC_HOST_PROJECT_KEY}"
    # Symlink the container-side key (-workspace) to the host-side key so all
    # sessions for this project land in the same folder on the host.
    if [ ! -e /home/agent/.claude/projects/-workspace ] || [ -L /home/agent/.claude/projects/-workspace ]; then
      # `--` terminator: RC_HOST_PROJECT_KEY starts with `-` (encoded "/")
      ln -sfn -- "${RC_HOST_PROJECT_KEY}" /home/agent/.claude/projects/-workspace
      echo "[rip-cage] Linked -workspace → ${RC_HOST_PROJECT_KEY}"
    else
      echo "[rip-cage] Warning: /home/agent/.claude/projects/-workspace exists as a real directory — leaving alone to avoid clobbering data" >&2
    fi
  else
    echo "[rip-cage] Warning: RC_HOST_PROJECT_KEY unset — sessions will land under -workspace/ on host (not unified with host project key)" >&2
  fi
elif [ -d /home/agent/.claude-state ]; then
  if [[ ! -L /home/agent/.claude-state ]]; then
    sudo chown agent:agent /home/agent/.claude-state 2>/dev/null || true
  fi
  for dir in projects sessions; do
    mkdir -p /home/agent/.claude-state/$dir
    ln -sfn /home/agent/.claude-state/$dir ~/.claude/$dir
    echo "[rip-cage] Linked persistent $dir (legacy volume mode — sessions NOT on host)"
  done
fi

# 5. Verify hooks
# dcg binary is opt-in via examples/dcg recipe (rip-cage-wlwc.10 / ADR-025 D2).
# Warn-only when absent — a cage without the dcg recipe has no command-guard but
# containment still holds via other layers (egress firewall, ssh-bypass blocker opt-in
# via examples/ssh-bypass recipe, etc.).
if [ ! -x /usr/local/bin/dcg ]; then
  echo "[rip-cage] INFO: DCG binary not found at /usr/local/bin/dcg — command-guard inactive (opt-in via examples/dcg recipe, ADR-025 D2)"
fi
# Verify dcg-guard wrapper + config ONLY when the dcg recipe is composed (binary present).
# When dcg is absent (recipe not composed) these artifacts do not exist — skip silently.
# When dcg IS composed: keep all checks fail-closed (ADR-025 D3/D5, ADR-001).
if [ -x /usr/local/bin/dcg ]; then
  # Verify dcg-guard wrapper (ADR-025 D3): must exist, be executable, and DCG_CONFIG must parse.
  # A missing/malformed DCG_CONFIG silently re-opens the user-layer config hole (ADR-025 D5).
  if [ ! -x /usr/local/lib/rip-cage/bin/dcg-guard ]; then
    echo "[rip-cage] ERROR: dcg-guard wrapper not found or not executable at /usr/local/lib/rip-cage/bin/dcg-guard" >&2
    exit 1
  fi
  if [ ! -f /usr/local/lib/rip-cage/dcg/config.toml ]; then
    echo "[rip-cage] ERROR: baked DCG_CONFIG not found at /usr/local/lib/rip-cage/dcg/config.toml — user-layer config hole remains open" >&2
    exit 1
  fi
  if ! python3 -c "import tomllib; tomllib.load(open('/usr/local/lib/rip-cage/dcg/config.toml','rb'))" 2>/dev/null; then
    echo "[rip-cage] ERROR: pinned DCG_CONFIG at /usr/local/lib/rip-cage/dcg/config.toml is malformed TOML — a bad config silently re-opens the user-layer config hole; refusing to start (ADR-025 D5 fail-closed)" >&2
    exit 1
  fi
  echo "[rip-cage] dcg-guard wrapper verified (CWD-anchor + pinned DCG_CONFIG active)"
fi
# NOTE: compound blocker removed in rip-cage-4r8 — DCG is chaining-robust.
# Verify python3 (required for skill-server.py MCP shim)
if ! command -v python3 > /dev/null 2>&1; then
  echo "[rip-cage] ERROR: python3 not found — skill discovery (skill-server.py) will not work" >&2
  exit 1
fi
echo "[rip-cage] python3 found (skill-server.py will be available)"
echo "[rip-cage] Hooks verified"
# 5b. Verify pi-cage guard (dcg-gate.ts extension) — when dcg IS composed AND guard recipe is present.
# PI_CODING_AGENT_DIR=/home/agent/.pi/agent is set unconditionally by rc up for ALL cages.
# Post-rip-cage-wlwc.2.2: dcg-gate.ts is provisioned by the examples/pi recipe (install_cmd),
# NOT baked into the base image. When dcg IS composed but the pi recipe is the NO-GUARD variant
# (dcg-gate.ts absent), that is a valid user choice — warn-only, do not fail.
# When dcg IS composed AND dcg-gate.ts IS present: all checks are fail-closed (ADR-001, ADR-024).
# Ownership assertion (ADR-027 D1/D3, olen retired): guard wiring lives on its OWN
# separate root-owned load path /etc/rip-cage/pi/dcg-gate.ts — NOT inside extensions/.
# extensions/ is intentionally agent-owned (not root-owned; olen retired).
# Assert: dcg-gate.ts AND its parent /etc/rip-cage/pi are both root-owned so an agent
# cannot replace or shadow the guard (unix-dir-ownership invariant). Fail-closed (ADR-001).
if [ "${PI_CODING_AGENT_DIR:-}" = "/home/agent/.pi/agent" ]; then
  if [ -x /usr/local/bin/dcg ]; then
    if [ ! -f /etc/rip-cage/pi/dcg-gate.ts ]; then
      # dcg is composed but dcg-gate.ts is absent — user chose the no-guard pi recipe variant.
      # This is intentional and valid per ADR-027 D1/D3 (rc never forces the guard).
      echo "[rip-cage] INFO: DCG composed but dcg-gate.ts absent — pi running without command guard (no-guard recipe variant; examples/pi/manifest-fragment-no-guard.yaml)"
    else
      _dcg_gate_owner=$(stat -c '%U' /etc/rip-cage/pi/dcg-gate.ts 2>/dev/null || true)
      if [ "${_dcg_gate_owner}" != "root" ]; then
        echo "[rip-cage] ERROR: /etc/rip-cage/pi/dcg-gate.ts is owned by '${_dcg_gate_owner}' (expected root) — guard is agent-writable and self-disablable; recipe install_cmd must chown root:root (ADR-027 D1/D3)" >&2
        exit 1
      fi
      _dcg_pi_dir_owner=$(stat -c '%U' /etc/rip-cage/pi 2>/dev/null || true)
      if [ "${_dcg_pi_dir_owner}" != "root" ]; then
        echo "[rip-cage] ERROR: /etc/rip-cage/pi dir is owned by '${_dcg_pi_dir_owner}' (expected root) — agent can replace guard file via dir write; recipe install_cmd must chown root:root (ADR-027 D1/D3, unix-dir-ownership)" >&2
        exit 1
      fi
      unset _dcg_gate_owner _dcg_pi_dir_owner
      if [ ! -x /usr/local/lib/rip-cage/bin/dcg-guard ]; then
        echo "[rip-cage] ERROR: dcg-guard wrapper missing — pi-cage guard cannot function (rip-cage-bl1)" >&2
        exit 1
      fi
      # rip-cage-sn1h: pi launch wrapper must be present at /usr/local/bin/pi (intercepts every
      # pi call, adds -e <dcg-gate> so the DCG guard extension loads on every launch).
      # OPEN by default (ADR-027 D1/D4, FIRM 2026-07-02; rip-cage-p35a.1): the wrapper does NOT
      # add --no-extensions — pi's own extension auto-discovery paths (/workspace/.pi/extensions/,
      # ~/.pi/agent/extensions/) stay live even with DCG composed. The accepted residual
      # ("vector-b": a prompt-injected pi writing a bypass extension into an auto-loaded path)
      # is knowingly accepted in this default; --no-extensions is a documented LOCKED opt-in
      # (see examples/dcg/README.md), not something this check enforces.
      # Ownership: must be root-owned so the agent cannot swap it for an unwrapped pi call.
      if [ ! -x /usr/local/bin/pi ]; then
        echo "[rip-cage] ERROR: pi launch wrapper missing at /usr/local/bin/pi — pi would launch without the DCG guard extension load (rip-cage-sn1h)" >&2
        exit 1
      fi
      _pi_wrapper_owner=$(stat -c '%U' /usr/local/bin/pi 2>/dev/null || true)
      if [ "${_pi_wrapper_owner}" != "root" ]; then
        echo "[rip-cage] ERROR: pi wrapper at /usr/local/bin/pi is owned by '${_pi_wrapper_owner}' (expected root) — agent could replace it to bypass the DCG guard extension load (rip-cage-sn1h)" >&2
        exit 1
      fi
      unset _pi_wrapper_owner
      echo "[rip-cage] pi-cage guard verified (dcg-gate.ts + dcg-guard + pi-wrapper all present, root-owned)"
    fi
  fi
fi

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
# multiplexer pane, and Claude-Code child process gets a uniform surface.
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

# R4: Snapshot ~/.claude.json → ~/.claude/.claude.json.seed (rip-cage-p1p)
# MUST run BEFORE the first `claude` invocation below — when the claude-recipe is
# composed (/usr/local/bin/claude wrapper present), the wrapper seeds the default
# session from this snapshot, so it has to exist before `claude --version`.
# If the claude-recipe is not composed, the snapshot is taken but unused (benign).
# ~/.claude.json is a single-file virtiofs bind mount. An atomic temp+rename
# rewrite on the host (any Claude run on the host) BREAKS the container's mount
# handle — the container then sees ENOENT while the host file is intact. The
# wrapper's cp from the live mount then copies nothing → empty seed → drops
# MCP/oauthAccount. Snapshotting once here, while the mount is intact at init,
# decouples per-session seeding from that fragile mount.
#
# Guard: only snapshot a readable, non-empty ~/.claude.json. A broken mount read
# is ENOENT (fails -f) or empty (fails -s), so this guard cannot clobber a prior
# good seed with a bad read — it simply skips and the existing seed is preserved.
#
# Non-possession synthesis (rip-cage-vwka): when the live mount is absent, a
# non-possession cage (auth.per_tool.claude: none) has no ~/.claude.json at
# all — the wrapper's seed chain then comes up empty, forcing interactive
# claude through the full theme+login onboarding wall (unusable in-cage: the
# login screen needs a browser OAuth flow, and the placeholder token +
# mediator injection already auth the API path throughout). Synthesize a
# minimal seed instead, ONLY if no seed exists yet — this must never clobber
# a prior good snapshot (e.g. one taken on an earlier boot before the host
# mount broke). Deliberately minimal and non-credential-shaped: no
# oauthAccount / claudeAiOauth fields. Proven sufficient 2026-07-06:
# {"hasCompletedOnboarding": true, "theme": "dark"} makes interactive claude
# skip theme+login and land on workspace-trust -> prompt -> model round-trip.
if [ -f ~/.claude.json ] && [ -s ~/.claude.json ]; then
  cp ~/.claude.json ~/.claude/.claude.json.seed
  echo "[rip-cage] Snapshotted ~/.claude.json → ~/.claude/.claude.json.seed (R4 stable seed)"
elif [ -s ~/.claude/.claude.json.seed ]; then
  echo "[rip-cage] NOTE: ~/.claude.json not readable/non-empty at init time — existing seed preserved (R4 stable seed)"
else
  cat > ~/.claude/.claude.json.seed <<'RIPCAGE_SEED_EOF'
{"hasCompletedOnboarding": true, "theme": "dark"}
RIPCAGE_SEED_EOF
  echo "[rip-cage] Synthesized minimal ~/.claude/.claude.json.seed (non-possession onboarding skip, rip-cage-vwka)"
fi

# 8. Verify Claude Code
if ! claude --version > /dev/null 2>&1; then
  echo "[rip-cage] ERROR: claude --version failed" >&2
  exit 1
fi
echo "[rip-cage] Claude Code $(claude --version) ready"

# BASE-INFRA (pi, rip-cage-p35a.3 audit): 9. Pi verify
# JUSTIFICATION: pi is npm-installed UNCONDITIONALLY in the base Dockerfile
# (not manifest-gated, independent of whether the pi-recipe TOOL entry is
# composed) — this check verifies that floor invariant and must run
# regardless of pi-recipe composition. It is also fail-CLOSED (FATAL, exit 1)
# while the TOOL 'init' boot-hook seam (rip-cage-p35a.2, ADR-005 D7) is
# fail-WARN by design ("cage still starts" — ADR-005 D10 asymmetry): the
# init-hook mechanism cannot express hard-fail semantics, and gating this
# check on pi-recipe composition would silently drop floor verification for
# any cage that doesn't compose pi-recipe even though the Dockerfile still
# bakes pi. Stays base-infra.
if command -v pi >/dev/null 2>&1; then
    # pi --version writes the version to stderr, not stdout (pi 0.73.x), so a bare
    # $(pi --version) captures nothing and renders a double-space. Capture via 2>&1
    # so the version shows (rip-cage-igm).
    echo "[rip-cage] pi $(pi --version 2>&1) ready"
else
    echo "[rip-cage] FATAL: pi not found in image" >&2
    exit 1
fi

# Check auth (warn only, do not fail)
# CLAUDE_CODE_OAUTH_TOKEN is the auth path under credential non-possession
# (auth.per_tool.claude: none — agent holds a placeholder, a composed mediator
# injects the real secret on egress; rip-cage-73bz). Recognized additively here
# to mirror rc test check 13's recognition set (tests/test-safety-stack.sh:187)
# without replacing the existing credentials-file / ~/.claude.json / API-key
# branches (rip-cage-df1c).
if [ -f ~/.claude/.credentials.json ]; then
  echo "[rip-cage] OAuth credentials found"
elif [ ! -f ~/.claude.json ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "[rip-cage] WARNING: No auth found (~/.claude/.credentials.json missing, ANTHROPIC_API_KEY not set)" >&2
fi

# 10. Initialize beads
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

# NOTE: the firewall-env / mediator-CA-trust-env machinery this comment used
# to describe (init-firewall.sh, init-mediator.sh, NODE_EXTRA_CA_CERTS
# threading) retired with the deleted in-cage engine (ADR-029 D2). A composed
# (opt-in) mediator recipe or msb's own primitives own CA trust threading now.

# Same pattern for cage-env (CAGE_HOST_ADDR) so interactive shells and multiplexer
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

# 11. Multiplexer-server lifecycle (rip-cage-1f59.1 / ADR-021 D6 / rip-cage-61al.3)
# RC_MULTIPLEXER is threaded in by cmd_up via -e RC_MULTIPLEXER=<value>.
# Valid values: none, or any multiplexer name declared in the manifest (default: none).
# Dispatch routes through the baked registry at /etc/rip-cage/multiplexers/<name>/start
# (ADR-005 D12 FIRM — no hardcoded optional-mux names in rc or init-rip-cage.sh).
# An unrecognised value from rc is caught by _config_validate_or_abort before
# launch (ADR-001 fail-loud); any residual invalid value here fails loud too.
_rc_mux="${RC_MULTIPLEXER:-none}"
case "$_rc_mux" in
  none)
    # No multiplexer server — plain terminal semantics.
    echo "[rip-cage] session.multiplexer=none: no multiplexer server started"
    ;;
  *)
    # Registry dispatch: run the baked 'start' hook for the declared multiplexer.
    # The hook was written to /etc/rip-cage/multiplexers/<name>/start at rc build time
    # from the MULTIPLEXER-archetype manifest entry. If the registry dir is absent,
    # the multiplexer was not declared in the manifest at build time — fail loud (ADR-001).
    _rc_mux_start_hook="/etc/rip-cage/multiplexers/${_rc_mux}/start"
    _rc_mux_registry_dir="/etc/rip-cage/multiplexers/${_rc_mux}"
    if [ ! -d "$_rc_mux_registry_dir" ]; then
      echo "[rip-cage] ERROR: multiplexer '${_rc_mux}' was not declared in the manifest used to build this image — no registry dir at ${_rc_mux_registry_dir} (ADR-001 fail-loud). Add a MULTIPLEXER manifest entry for '${_rc_mux}' (see examples/${_rc_mux}/) and rebuild, or set session.multiplexer: none." >&2
      exit 1
    fi
    if [ ! -f "$_rc_mux_start_hook" ]; then
      echo "[rip-cage] ERROR: multiplexer '${_rc_mux}' has no 'start' hook at ${_rc_mux_start_hook} — the manifest entry must declare hooks.start (ADR-001 fail-loud)." >&2
      exit 1
    fi
    echo "[rip-cage] session.multiplexer=${_rc_mux}: running start hook..."
    sh "$_rc_mux_start_hook"
    echo "[rip-cage] session.multiplexer=${_rc_mux}: start hook completed"
    unset _rc_mux_start_hook _rc_mux_registry_dir
    ;;
esac
unset _rc_mux

# 12. IN-CAGE DAEMON lifecycle block (rip-cage-4c5.5)
#
# Read the baked daemon config from /etc/rip-cage/daemon-config.json (written at
# build time by _manifest_generate_daemon_config_dockerfile_steps in rc).
# For each daemon entry:
#   1. Create state_dir (container-local, ADR-019 D1 extensions pattern).
#   2. Idempotency: if PID file exists and process is alive, SKIP (true no-op —
#      NOT kill-and-restart, which would false-green a "one binder" idempotency
#      check; assert PID is UNCHANGED between first and second init run).
#   3. Start the daemon's `start` command in the background.
#   4. Run the `health` check with a timeout (bd memory rip-cage-validate-hung-daemon).
#   5. FAIL-WARN on health failure — cage still starts (ADR-005 D10 / ADR-001
#      asymmetry: safety floor fails-closed, user daemon fails-warn).
#
# Supervisor model: init-script-start (NOT host-exec), mirroring the
# ssh-agent-filter fork+PID-parse+fail-warn pattern (init-rip-cage.sh:60-103).
# PID file: /tmp/rip-cage-daemon-<name>.pid (transient, cage-lifetime).
_rc_daemon_config="/etc/rip-cage/daemon-config.json"
if [[ -f "$_rc_daemon_config" ]] && command -v jq >/dev/null 2>&1; then
  _rc_daemon_count=$(jq '.daemons | length' "$_rc_daemon_config" 2>/dev/null || echo "0")
  for (( _rc_di=0; _rc_di<_rc_daemon_count; _rc_di++ )); do
    _rc_daemon_entry=$(jq -c ".daemons[${_rc_di}]" "$_rc_daemon_config" 2>/dev/null)
    _rc_daemon_name=$(jq -r '.name // "unknown"' <<<"$_rc_daemon_entry" 2>/dev/null)
    _rc_daemon_start=$(jq -r '.start // ""' <<<"$_rc_daemon_entry" 2>/dev/null)
    _rc_daemon_health=$(jq -r '.health // ""' <<<"$_rc_daemon_entry" 2>/dev/null)
    _rc_daemon_state_dir=$(jq -r '.state_dir // ""' <<<"$_rc_daemon_entry" 2>/dev/null)
    _rc_daemon_pidfile="/tmp/rip-cage-daemon-${_rc_daemon_name}.pid"

    if [[ -z "$_rc_daemon_start" || -z "$_rc_daemon_health" ]]; then
      echo "[rip-cage] WARNING: daemon '${_rc_daemon_name}' missing start or health — skipping." >&2
      continue
    fi

    # Create state_dir (container-local; mkdir -p is idempotent).
    if [[ -n "$_rc_daemon_state_dir" ]]; then
      mkdir -p "$_rc_daemon_state_dir" 2>/dev/null || true
    fi

    # Idempotency: if PID file exists and the process is still running, skip.
    # This is a TRUE no-op (PID unchanged) — not kill-and-restart.
    if [[ -f "$_rc_daemon_pidfile" ]]; then
      _rc_existing_pid=$(cat "$_rc_daemon_pidfile" 2>/dev/null || echo "")
      if [[ -n "$_rc_existing_pid" ]] && kill -0 "$_rc_existing_pid" 2>/dev/null; then
        echo "[rip-cage] daemon '${_rc_daemon_name}' already running (PID=$_rc_existing_pid) — skipping (idempotent no-op)"
        unset _rc_existing_pid
        continue
      fi
      # Stale PID file (process gone) — remove and restart.
      rm -f "$_rc_daemon_pidfile"
      unset _rc_existing_pid
    fi

    # Start daemon in background; capture PID.
    # Use eval to handle the start command string correctly (may have flags/args).
    eval "$_rc_daemon_start" >/tmp/rip-cage-daemon-"${_rc_daemon_name}".log 2>&1 &
    _rc_daemon_pid=$!

    # Write PID file immediately so the idempotency guard is set before we check health.
    # Guard with || true: PID write failure (e.g. /tmp full) must NOT abort init
    # under set -e — a user daemon failing to write its PID file is fail-WARN,
    # not fail-CLOSED (ADR-005 D10 / ADR-001 asymmetry).
    echo "$_rc_daemon_pid" > "$_rc_daemon_pidfile" 2>/dev/null || true
    echo "[rip-cage] daemon '${_rc_daemon_name}' started (PID=$_rc_daemon_pid)"

    # Health check with timeout (bd memory rip-cage-validate-hung-daemon):
    # A wedged daemon must NOT hang the init script. Use `timeout` (coreutils).
    # Retry a few times to allow the daemon a moment to bind its port.
    _rc_daemon_health_ok=0
    for _rc_health_attempt in 1 2 3; do
      sleep 1
      if timeout 5 bash -c "$_rc_daemon_health" >/dev/null 2>&1; then
        _rc_daemon_health_ok=1
        break
      fi
    done

    if [[ "$_rc_daemon_health_ok" -eq 1 ]]; then
      echo "[rip-cage] daemon '${_rc_daemon_name}' health OK (PID=$_rc_daemon_pid)"
    else
      # FAIL-WARN: cage still starts — do NOT abort (ADR-005 D10 / ADR-001 asymmetry).
      echo "[rip-cage] WARNING: daemon '${_rc_daemon_name}' health check FAILED (PID=$_rc_daemon_pid) — cage continues without it." >&2
    fi

    unset _rc_daemon_health_ok _rc_health_attempt _rc_daemon_pid
    unset _rc_daemon_entry _rc_daemon_name _rc_daemon_start _rc_daemon_health _rc_daemon_state_dir _rc_daemon_pidfile
  done
  unset _rc_di _rc_daemon_count
fi
unset _rc_daemon_config

# github-identity first-shell echo (ADR-020 D5). Reads the sentinels written by
# the in-cage preflight and emits a one-line identity status on first attach.
# Test-mode: RC_SENTINEL_DIR overrides /etc/rip-cage.
_rc_gi_dir="${RC_SENTINEL_DIR:-/etc/rip-cage}"
if [ -r "${_rc_gi_dir}/github-identity" ]; then
  _rc_gi=$(head -1 "${_rc_gi_dir}/github-identity" 2>/dev/null)
  _rc_gi_src=$(cat "${_rc_gi_dir}/ssh-config-source" 2>/dev/null || true)
  # `|| true` because sentinels for status=unreachable/disabled lack expected=/greeting=
  # lines; without it, grep exit=1 + pipefail + set -e aborts init before the case below.
  _rc_gi_expected=$(grep '^expected=' "${_rc_gi_dir}/github-identity" 2>/dev/null | head -1 | sed 's/^expected=//' || true)
  _rc_gi_greeting=$(grep '^greeting=' "${_rc_gi_dir}/github-identity" 2>/dev/null | head -1 | sed 's/^greeting=//' || true)
  case "$_rc_gi" in
    disabled)  : ;;
    match)     echo "[rip-cage] github.com: ${_rc_gi_expected:-${_rc_gi_greeting}} (source: ${_rc_gi_src})" ;;
    unset)     echo "[rip-cage] github.com: unset — pushes will go to ${_rc_gi_greeting}" ;;
    mismatch)  echo "[rip-cage] github.com: MISMATCH — expected ${_rc_gi_expected}, greeting ${_rc_gi_greeting}" ;;
    unreachable) echo "[rip-cage] github.com: unreachable (skipping pubkey check)" ;;
    *)         echo "[rip-cage] github.com: ${_rc_gi} (source: ${_rc_gi_src})" ;;
  esac
  unset _rc_gi _rc_gi_src _rc_gi_expected _rc_gi_greeting
fi
unset _rc_gi_dir

echo "[rip-cage] Initialization complete"
