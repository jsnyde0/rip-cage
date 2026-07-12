#!/usr/bin/env bash
# cli/down_destroy.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).
#
# rip-cage-tsf2.1 (msb migration epic rip-cage-tsf2): REWRITTEN onto msb --
# was docker inspect/stop/rm/volume rm. down/destroy drive a cage created
# by the msb-backed `rc up` (S6, rip-cage-rj68).
#
# ADR-029 D4 lifecycle corollary (FIRM): any cage-stop path that must
# preserve state uses graceful stop only. `cmd_down` calls
# `_msb_stop_graceful` (msb_runtime.sh's ONLY stop primitive — see that
# module's own comment for why there is deliberately no forced-stop
# sibling to misuse here).
#
# msb behavioral fact (migration spike): `msb remove` has NO volume-
# deletion flag -- a cage's named volumes (rc-state-<name>,
# rc-history-<name>) SURVIVE `msb remove` alone. `cmd_destroy`'s destroy
# policy (mirroring the pre-migration docker behavior it replaces, which
# explicitly ran `docker volume rm` per volume) therefore ALSO calls the
# distinct `_msb_volume_remove` primitive per volume -- never assumes
# removing the sandbox cleans its volumes.


cmd_down() {
  local name
  name=$(resolve_name "${1:-}") || exit 1
  local state
  state=$(_msb_sandbox_state "$name" 2>/dev/null || true)
  if [[ -z "$state" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container not found: $name" "CONTAINER_NOT_FOUND"
    echo "Error: container $name not found" >&2; exit 1
  fi
  verify_rc_container "$name"
  if [[ "$state" != "running" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is not running (state: $state)" "CONTAINER_NOT_RUNNING"
    echo "Error: container $name is not running (state: $state)" >&2; exit 1
  fi
  # Graceful stop ONLY (ADR-029 D4 FIRM) -- see module comment above.
  _msb_stop_graceful "$name" >/dev/null 2>&1
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

  # Verify sandbox exists and is managed by rc
  if ! _msb_exists "$name"; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container not found: $name" "CONTAINER_NOT_FOUND"
    echo "Error: container $name not found" >&2; exit 1
  fi
  verify_rc_container "$name"

  # Interactive confirmation for destructive operation (skip in JSON/non-TTY/--force)
  if [[ "$force" -eq 0 ]] && [[ "$DRY_RUN" != "true" ]] && [[ "$OUTPUT_FORMAT" != "json" ]] && [[ -t 0 ]]; then
    local source_path
    source_path=$(_msb_label "$name" "rc.source.path" 2>/dev/null || true)
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

  # msb remove --force stops (if running) then removes the sandbox.
  if ! _msb_remove "$name" >/dev/null 2>&1; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container not found: $name" "CONTAINER_NOT_FOUND"
    echo "Error: container $name not found" >&2; exit 1
  fi
  # Clean up worktree gitfile if it exists
  rm -f "${HOME}/.cache/rc/${name}.gitfile"
  # `msb remove` (above) does NOT delete named volumes (no volume-deletion
  # flag on that command — a separate finding from the migration spike, see
  # this file's own header comment). Explicitly delete this cage's two
  # named volumes via the distinct `msb volume remove` primitive, mirroring
  # the pre-migration docker destroy policy this replaces.
  local volumes_removed=()
  for vol in "rc-state-${name}" "rc-history-${name}"; do
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      if _msb_volume_remove "$vol" >/dev/null 2>/dev/null; then
        volumes_removed+=("$vol")
      fi
    else
      if _msb_volume_remove "$vol" 2>/dev/null; then
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

