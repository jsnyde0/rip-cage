#!/usr/bin/env bash
# cli/attach_exec.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).
#
# rip-cage-tsf2.1 (msb migration epic rip-cage-tsf2): REWRITTEN onto msb --
# was docker exec/inspect. attach/exec drive a cage created by the msb-
# backed `rc up` (S6, rip-cage-rj68). Interactive attach/exec map onto `msb
# exec -t` (real TTY size + SIGWINCH propagate; verified in the migration
# spike -- herdr sized-attach works over msb exec -t). Non-interactive exec
# uses plain `msb exec` (no pty, no -i concept on msb -- msb exec is
# non-interactive by default unless -t/--tty is passed).


cmd_attach() {
  local name
  name=$(resolve_name "${1:-}") || exit 1
  # Verify the sandbox is running (attach doesn't provision)
  local state
  state=$(_msb_sandbox_state "$name" 2>/dev/null || true)
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
        _msb_exec_interactive "$name" -- zsh
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
        echo "Error: multiplexer '${_attach_mux}' has no attach hook in registry for cage '$name'. Inspect with: msb inspect $name" >&2
        exit 1
      fi
      if [[ -t 0 && -t 1 ]]; then
        _msb_exec_interactive "$name" -- sh "$_attach_hook_path"
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

  # Verify the sandbox is running
  local state
  state=$(_msb_sandbox_state "$name" 2>/dev/null || true)
  if [[ "$state" != "running" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Container $name is not running. Start it with: rc up" "CONTAINER_NOT_RUNNING"
    fi
    echo "Error: container $name is not running. Start it with: rc up" >&2
    exit 1
  fi

  # Run the command via msb exec, propagating its exit code. msb exec is
  # non-interactive by default (no -i concept, unlike docker exec); pass
  # -t/--tty only when a real TTY is present (interactive use).
  #
  # WORKSPACE-SOURCE HINT (rip-cage-uod6, charted from rip-cage-54q3's root
  # cause): when a cage's host workspace dir is deleted while the cage runs,
  # /workspace becomes a dead virtiofs mount; msb chdir()s to
  # Workdir=/workspace before spawning and reports the resulting ENOENT
  # against the *program* name, so the raw error reads "spawn <prog>: not
  # found" and sends readers hunting a missing binary.
  # rip-cage-uod6, revised by driver drift-review (2026-09-04): the
  # workspace-source check runs BEFORE the exec rather than by capturing the
  # wrapped command's stderr and grepping it for ENOENT. Capturing meant
  # BUFFERING that stderr until the command exited, so a long-running
  # `rc exec` lost all live progress output -- which most tools write to
  # stderr. The pre-check costs one label read, leaves both streams
  # untouched and streaming, puts the hint ahead of msb's misleading text by
  # construction rather than by reordering, and reaches the interactive
  # (pty) path too, which stderr capture could not.
  #
  # It fires whether or not THIS command fails, and that is deliberate: once
  # the host source dir is gone the /workspace virtiofs mount is already
  # dead, and every later exec fails against it. msb's flip is not instant
  # (~15s observed), so a command that still succeeds inside that window is
  # exactly when naming the cause is most useful.
  local _exec_source_hint
  if _exec_source_hint=$(_rc_source_path_missing_hint "$name"); then
    echo "$_exec_source_hint" >&2
  fi

  local exec_exit=0
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # ADR-003 D1: in JSON mode stdout carries ONLY the JSON envelope.
    # Route the wrapped command's stdout to stderr so a human still sees it,
    # keeping stdout clean for the envelope emitted below.
    if [[ -t 0 && -t 1 ]]; then
      _msb_exec_interactive "$name" -- "${exec_cmd[@]}" >&2 || exec_exit=$?
    else
      _msb_exec "$name" -- "${exec_cmd[@]}" >&2 || exec_exit=$?
    fi
  else
    if [[ -t 0 && -t 1 ]]; then
      _msb_exec_interactive "$name" -- "${exec_cmd[@]}" || exec_exit=$?
    else
      _msb_exec "$name" -- "${exec_cmd[@]}" || exec_exit=$?
    fi
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

