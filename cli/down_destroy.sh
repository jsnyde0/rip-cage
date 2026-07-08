#!/usr/bin/env bash
# cli/down_destroy.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


cmd_down() {
  local name
  name=$(resolve_name "${1:-}") || exit 1
  local _down_timeout="${RC_DOCKER_CALL_TIMEOUT:-15}"
  local state
  state=$(_docker_call "$_down_timeout" inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
  if [[ -z "$state" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container not found: $name" "CONTAINER_NOT_FOUND"
    echo "Error: container $name not found" >&2; exit 1
  fi
  verify_rc_container "$name"
  if [[ "$state" != "running" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is not running (state: $state)" "CONTAINER_NOT_RUNNING"
    echo "Error: container $name is not running (state: $state)" >&2; exit 1
  fi
  # `docker stop` defaults to a 10s grace period before SIGKILL; bound the
  # outer wait at 30s (2× grace + slack) so a wedged daemon doesn't hang us.
  _docker_call 30 stop "$name" >/dev/null 2>&1
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc --arg name "$name" --arg action "stopped" --arg status "exited" \
      '{name: $name, action: $action, status: $status}'
  else
    echo "Container $name stopped."
  fi
}


cmd_destroy() {
  local name="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  name=$(resolve_name "$name") || exit 1

  local _destroy_timeout="${RC_DOCKER_CALL_TIMEOUT:-15}"

  # Verify container exists and is managed by rc
  if ! _docker_call "$_destroy_timeout" inspect "$name" >/dev/null 2>&1; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container not found: $name" "CONTAINER_NOT_FOUND"
    echo "Error: container $name not found" >&2; exit 1
  fi
  verify_rc_container "$name"

  # Interactive confirmation for destructive operation (skip in JSON/non-TTY/--force)
  if [[ "$force" -eq 0 ]] && [[ "$DRY_RUN" != "true" ]] && [[ "$OUTPUT_FORMAT" != "json" ]] && [[ -t 0 ]]; then
    local source_path
    source_path=$(_docker_call "$_destroy_timeout" inspect --format '{{ index .Config.Labels "rc.source.path" }}' "$name" 2>/dev/null || true)
    echo "This will permanently remove:"
    echo "  Container:  $name"
    [[ -n "$source_path" ]] && echo "  Workspace:  $source_path"
    echo "  Volumes:    rc-state-$name, rc-history-$name"
    printf "Destroy? [y/N] "
    local reply
    read -r reply
    if [[ "$reply" != [yY] ]]; then
      echo "Aborted."
      return 0
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      jq -nc --arg name "$name" --arg action "would_destroy" --argjson dry_run true \
        --arg vol1 "rc-state-$name" --arg vol2 "rc-history-$name" \
        '{dry_run: $dry_run, name: $name, action: $action, volumes_removed: [$vol1, $vol2]}'
    else
      echo "Would remove container $name"
      echo "Would remove volumes: rc-state-$name, rc-history-$name"
    fi
    return 0
  fi

  # `docker rm -f` runs SIGKILL after a brief grace; 30s outer cap is generous.
  if ! _docker_call 30 rm -f "$name" >/dev/null 2>&1; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container not found: $name" "CONTAINER_NOT_FOUND"
    echo "Error: container $name not found" >&2; exit 1
  fi
  # Clean up worktree gitfile if it exists
  rm -f "${HOME}/.cache/rc/${name}.gitfile"
  local volumes_removed=()
  for vol in "rc-state-${name}" "rc-history-${name}"; do
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      if docker volume rm "$vol" >/dev/null 2>/dev/null; then
        volumes_removed+=("$vol")
      fi
    else
      if docker volume rm "$vol" 2>/dev/null; then
        volumes_removed+=("$vol")
      else
        echo "Warning: volume $vol not found"
      fi
    fi
  done
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    local vol_json
    if [[ ${#volumes_removed[@]} -eq 0 ]]; then
      vol_json="[]"
    else
      vol_json=$(printf '%s\n' "${volumes_removed[@]}" | jq -R 'select(length > 0)' | jq -sc .)
    fi
    jq -nc --arg name "$name" --arg action "destroyed" --argjson volumes_removed "$vol_json" \
      '{name: $name, action: $action, volumes_removed: $volumes_removed}'
  else
    echo "Container $name and volumes destroyed."
  fi
}

