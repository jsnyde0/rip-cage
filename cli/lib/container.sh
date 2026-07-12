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



# rip-cage-rj68 (S6, ADR-029 D1 hard cutover): resolve_name/verify_rc_container/
# _container_multiplexer are shared by cli/up.sh, cli/reload.sh, cli/doctor.sh
# (all rewritten onto msb by this bead) AND by cli/attach_exec.sh,
# cli/down_destroy.sh, cli/allowlist.sh, cli/ls.sh (NOT in this bead's
# scope, still docker-only elsewhere in those files). D1 is a hard cutover,
# not a dual backend, so these three functions move onto msb wholesale —
# they cannot serve both an msb-backed and a docker-backed caller at once.
# Known, flagged consequence: the not-in-scope verbs above cannot resolve/
# verify/multiplex an msb-created cage after this change (they already
# could not drive one via their own direct `docker exec`/`docker inspect`
# calls either — this does not newly break a working path, it makes an
# already-broken one fail at a different, earlier point). Follow-up child.
resolve_name() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    echo "$name"
    return
  fi

  # Try CWD-based resolution first (same logic as cmd_up):
  # derive the expected container name from the current directory and check
  # if a matching rc-managed container exists.
  local cwd_resolved cwd_candidate
  cwd_resolved=$(realpath "." 2>/dev/null) || true
  if [[ -n "$cwd_resolved" ]]; then
    cwd_candidate=$(container_name "$cwd_resolved")
    if [[ -n "$cwd_candidate" ]]; then
      local cwd_label
      cwd_label=$(_msb_label "$cwd_candidate" "rc.source.path" 2>/dev/null || true)
      if [[ -n "$cwd_label" ]]; then
        echo "$cwd_candidate"
        return
      fi
    fi
  fi

  # Fallback: if no CWD match, use singleton auto-select over ALL real msb
  # sandboxes carrying the rc.source.path label.
  local sandboxes_json
  if ! sandboxes_json=$(msb list --format json 2>/dev/null); then
    echo "Error: failed to list sandboxes (is msb running?)" >&2
    return 1
  fi
  local containers=""
  local _rn_sbx_name _rn_label
  while IFS= read -r _rn_sbx_name; do
    [[ -z "$_rn_sbx_name" ]] && continue
    _rn_label=$(_msb_label "$_rn_sbx_name" "rc.source.path" 2>/dev/null || true)
    [[ -n "$_rn_label" ]] && containers+="${_rn_sbx_name}"$'\n'
  done < <(jq -r '.[].name' <<<"$sandboxes_json" 2>/dev/null)
  containers="${containers%$'\n'}"
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
  _mux=$(_msb_label "$_cname" "rc.session.multiplexer" 2>/dev/null || true)
  echo "${_mux:-none}"
}


verify_rc_container() {
  local name="$1"
  local label
  label=$(_msb_label "$name" "rc.source.path" 2>/dev/null || true)
  if [[ -z "$label" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is not managed by rc" "CONTAINER_NOT_FOUND"
    echo "Error: container $name is not managed by rc" >&2
    exit 1
  fi
}

