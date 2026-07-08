#!/usr/bin/env bash
# cli/lib/container.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# cmd_init removed — VS Code devcontainer path removed (rip-cage-kt25).
# The sole usage path is rc up (CLI/headless).

# Derive container name from last two path components
container_name() {
  local path="$1"
  local parent
  parent=$(basename "$(dirname "$path")")
  local base
  base=$(basename "$path")
  echo "${parent}-${base}" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^[.-]*//' | sed 's/-$//'
}



resolve_name() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    echo "$name"
    return
  fi

  # Try CWD-based resolution first (same logic as cmd_up):
  # derive the expected container name from the current directory and check
  # if a matching rc-managed container exists.
  local _resolve_timeout="${RC_DOCKER_CALL_TIMEOUT:-15}"
  local cwd_resolved cwd_candidate
  cwd_resolved=$(realpath "." 2>/dev/null) || true
  if [[ -n "$cwd_resolved" ]]; then
    cwd_candidate=$(container_name "$cwd_resolved")
    if [[ -n "$cwd_candidate" ]]; then
      local cwd_label
      cwd_label=$(_docker_call "$_resolve_timeout" inspect --format '{{ index .Config.Labels "rc.source.path" }}' "$cwd_candidate" 2>/dev/null || true)
      if [[ -n "$cwd_label" ]]; then
        echo "$cwd_candidate"
        return
      fi
    fi
  fi

  # Fallback: if no CWD match, use singleton auto-select
  local containers
  if ! containers=$(_docker_call "$_resolve_timeout" ps -a --filter label=rc.source.path --format '{{.Names}}'); then
    echo "Error: failed to list containers (is Docker running?)" >&2
    return 1
  fi
  local count
  count=$(echo "$containers" | grep -c . || true)
  if [[ "$count" -eq 0 ]]; then
    echo "Error: no rip-cage containers found." >&2
    return 1
  elif [[ "$count" -eq 1 ]]; then
    echo "$containers"
    return
  else
    echo "Error: multiple containers — specify a name:" >&2
    echo "$containers" >&2
    return 1
  fi
}


# _container_multiplexer — read the rc.session.multiplexer label from a running container.
# Defaults to "none" when the label is absent (pre-1f59.1 cages or label not set).
# Args: $1 = container name
_container_multiplexer() {
  local _cname="$1"
  local _mux
  _mux=$(docker inspect --format '{{ index .Config.Labels "rc.session.multiplexer" }}' "$_cname" 2>/dev/null || true)
  echo "${_mux:-none}"
}


verify_rc_container() {
  local name="$1"
  local label
  label=$(docker inspect --format '{{ index .Config.Labels "rc.source.path" }}' "$name" 2>/dev/null || true)
  if [[ -z "$label" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is not managed by rc" "CONTAINER_NOT_FOUND"
    echo "Error: container $name is not managed by rc" >&2
    exit 1
  fi
}

