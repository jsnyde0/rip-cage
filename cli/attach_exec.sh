#!/usr/bin/env bash
# cli/attach_exec.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


cmd_attach() {
  local name
  name=$(resolve_name "${1:-}") || exit 1
  # Verify the container is running (attach doesn't provision)
  local state
  state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
  if [[ "$state" != "running" ]]; then
    echo "Error: container $name is not running. Start it with: rc up" >&2
    exit 1
  fi
  # rip-cage-1f59.2 / rip-cage-61al.3: dispatch attach via baked registry (ADR-005 D12 FIRM).
  local _attach_mux
  _attach_mux=$(_container_multiplexer "$name")
  case "$_attach_mux" in
    none)
      # Plain shell: no multiplexer — attach directly into a new zsh session.
      # TTY-guard: interactive only when TTY present.
      if [[ -t 0 && -t 1 ]]; then
        docker exec -it "$name" zsh
      else
        echo "Container $name is running (multiplexer=none). Exec with: rc exec $name -- <cmd>" >&2
      fi
      ;;
    *)
      # Registry dispatch: resolve the attach hook from the baked registry and invoke it.
      # Fails loud (ADR-001) if the mux was not declared in the manifest at build time.
      local _attach_hook_path
      _attach_hook_path=$(_rc_mux_resolve_hook_path "$_attach_mux" "attach" "$name") || exit 1
      if [[ -z "$_attach_hook_path" ]]; then
        echo "Error: multiplexer '${_attach_mux}' has no attach hook in registry for cage '$name'. Inspect with: docker inspect $name" >&2
        exit 1
      fi
      if [[ -t 0 && -t 1 ]]; then
        docker exec -it "$name" sh "$_attach_hook_path"
      else
        echo "Container $name is running (multiplexer=${_attach_mux}). Attach with: rc attach $name" >&2
      fi
      ;;
  esac
}


# cmd_exec — run a one-off command in the container (non-interactive, propagates exit status).
# Usage: rc exec <cage> -- <cmd...>
# Unlike rc attach, this is safe to call from scripts (no TTY guard — docker exec -i always).
# With a TTY (stdin+stdout both TTY), passes -t for interactive use.
# With --output json, emits {name, command, exit_code, status}.
cmd_exec() {
  local name_arg="" sep_found=""
  local exec_cmd=()

  # Parse: rc exec <cage> -- <cmd...>
  # The -- separator is required to delimit the cage name from the command.
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      sep_found="true"
      shift
      exec_cmd=("$@")
      break
    fi
    if [[ -z "$name_arg" ]]; then
      name_arg="$1"
      shift
    else
      echo "Error: unexpected argument '$1' before '--' separator. Usage: rc exec <cage> -- <cmd...>" >&2
      exit 1
    fi
  done

  if [[ -z "$sep_found" ]]; then
    echo "Error: 'rc exec' requires a '--' separator. Usage: rc exec <cage> -- <cmd...>" >&2
    exit 1
  fi

  if [[ "${#exec_cmd[@]}" -eq 0 ]]; then
    echo "Error: 'rc exec' requires a command after '--'. Usage: rc exec <cage> -- <cmd...>" >&2
    exit 1
  fi

  local name
  name=$(resolve_name "${name_arg:-}") || exit 1

  # Verify the container is running
  local state
  state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
  if [[ "$state" != "running" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Container $name is not running. Start it with: rc up" "CONTAINER_NOT_RUNNING"
    fi
    echo "Error: container $name is not running. Start it with: rc up" >&2
    exit 1
  fi

  # Run the command via docker exec, propagating its exit code.
  # Non-TTY: always works (no [[ -t 0 && -t 1 ]] guard).
  # With a TTY: pass -t for interactive use.
  local docker_exec_flags=(-i)
  if [[ -t 0 && -t 1 ]]; then
    docker_exec_flags+=(-t)
  fi

  local exec_exit=0
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # ADR-003 D1: in JSON mode stdout carries ONLY the JSON envelope.
    # Route the wrapped command's stdout to stderr so a human still sees it,
    # while the JSON channel (stdout) stays clean.
    docker exec "${docker_exec_flags[@]}" "$name" "${exec_cmd[@]}" >&2 || exec_exit=$?
  else
    docker exec "${docker_exec_flags[@]}" "$name" "${exec_cmd[@]}" || exec_exit=$?
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    local _cmd_str
    _cmd_str=$(printf '%s ' "${exec_cmd[@]}" | sed 's/ $//')
    jq -nc \
      --arg name "$name" \
      --arg command "$_cmd_str" \
      --argjson exit_code "$exec_exit" \
      --arg status "$([ "$exec_exit" -eq 0 ] && echo "success" || echo "error")" \
      '{name: $name, command: $command, exit_code: $exit_code, status: $status}'
  fi
  return "$exec_exit"
}

