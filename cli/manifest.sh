#!/usr/bin/env bash
# cli/manifest.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# THE `rc manifest` VERB IS GONE (ADR-031 D3). `rc manifest reconcile` re-seeded
# default-derived entries in the operator's tools.yaml from the shipped defaults.
# Its successor is: edit the file. The manifest layer itself retires next
# (ADR-031 D4, rip-cage-ely4.11), which is when this module goes with it.
#
# WHAT SURVIVES HERE, and why: `rc up` still calls _rc_mux_resolve_hook_path
# below to dispatch a cage's multiplexer through the image's baked registry.


# _rc_mux_resolve_hook_path
# Resolve a baked multiplexer hook to its in-container path under the registry.
# Prints the resolved in-container path on stdout (even when called from the host).
#
# =============================================================================
# Contract (shapes B1b — read before calling):
#
#   _rc_mux_resolve_hook_path <name> <hook_name> [<cage_name>]
#
#   name:       multiplexer name (e.g. the name declared in the manifest's MULTIPLEXER entry)
#   hook_name:  hook to resolve (start|attach|exec|new_session|teardown)
#   cage_name:  (optional) running container name for host-side callers (e.g. rc attach).
#               When provided, existence is checked INSIDE the cage via
#               `docker exec <cage_name> test ...`.
#               When omitted, the LOCAL filesystem is checked (in-container callers).
#
#   The resolved path is ALWAYS an in-container path:
#     /etc/rip-cage/multiplexers/<name>/<hook_name>
#   Host-side callers (cage_name present) should invoke the hook via docker exec.
#
# Behavior:
#   - Registry dir missing → fail loud (ADR-001), exit non-zero, name the fix.
#     NEVER silently fall through to a default.
#   - Registry dir exists, hook file ABSENT → echo empty string, exit 0.
#     Documented no-op: caller provides fallback (optional hook not declared).
#   - Registry dir exists, hook file present → echo in-container path, exit 0.
#
# Test override (in-container / local-filesystem branch only):
#   Set RC_MUX_REGISTRY_ROOT env var (or use the legacy 3rd positional arg when
#   cage_name is not a running container name) to override the local registry root.
#   This lets host-tier unit tests point at a fake temp-dir registry without Docker.
#   The public positional contract is <name> <hook> [<cage_name>]; the env var
#   override applies only when cage_name is absent.
#
# rip-cage-61al.2 (contract revised by B1b fix bead)
# =============================================================================
_rc_mux_resolve_hook_path() {
  local _rmrh_name="${1:-}"
  local _rmrh_hook="${2:-}"
  local _rmrh_cage="${3:-}"

  if [[ -z "$_rmrh_name" ]]; then
    echo "Error: _rc_mux_resolve_hook_path: multiplexer name is required." >&2
    return 1
  fi
  if [[ -z "$_rmrh_hook" ]]; then
    echo "Error: _rc_mux_resolve_hook_path: hook name is required." >&2
    return 1
  fi

  # The in-container path is always the canonical form; callers use msb exec to invoke it.
  local _rmrh_registry_in_container="/etc/rip-cage/multiplexers"
  local _rmrh_dir_in_container="${_rmrh_registry_in_container}/${_rmrh_name}"
  local _rmrh_hook_path_in_container="${_rmrh_dir_in_container}/${_rmrh_hook}"

  if [[ -n "$_rmrh_cage" ]]; then
    # -------------------------------------------------------------------------
    # HOST-SIDE CALLER: cage_name provided — existence-check via msb exec.
    # (rip-cage-vjuv fix: was `docker exec`, a docker-era remnant that fail-louds
    # against every msb cage post ADR-029 D1 cutover — the multiplexer-registry
    # check cmd_attach/cmd_up depend on. cmd_attach itself was migrated to
    # _msb_exec_interactive; this helper was missed. neu7 post-cutover epic.)
    # -------------------------------------------------------------------------

    # Fail loud if the registry dir for this name is absent inside the cage (ADR-001).
    if ! _msb_exec "${_rmrh_cage}" -- test -d "${_rmrh_dir_in_container}" 2>/dev/null; then
      echo "Error: no baked multiplexer registry for '${_rmrh_name}' in cage '${_rmrh_cage}' at ${_rmrh_dir_in_container} — multiplexer was not declared in the manifest used to build this image (ADR-001 fail-loud). Check \`msb inspect ${_rmrh_cage}\` and the manifest used during rc build." >&2
      return 1
    fi

    # Optional hook absent → return empty string (documented no-op).
    if ! _msb_exec "${_rmrh_cage}" -- test -f "${_rmrh_hook_path_in_container}" 2>/dev/null; then
      return 0
    fi

    printf '%s' "${_rmrh_hook_path_in_container}"

  else
    # -------------------------------------------------------------------------
    # IN-CONTAINER CALLER (or host-tier unit test with local root override):
    # cage_name omitted — check the LOCAL filesystem.
    # The local registry root defaults to /etc/rip-cage/multiplexers but can be
    # overridden via RC_MUX_REGISTRY_ROOT env var for host-tier unit tests.
    # -------------------------------------------------------------------------
    local _rmrh_local_root="${RC_MUX_REGISTRY_ROOT:-/etc/rip-cage/multiplexers}"
    local _rmrh_local_dir="${_rmrh_local_root}/${_rmrh_name}"
    local _rmrh_local_hook_path="${_rmrh_local_dir}/${_rmrh_hook}"

    # Fail loud if no baked registry dir for this name (ADR-001).
    if [[ ! -d "$_rmrh_local_dir" ]]; then
      echo "Error: no baked multiplexer registry for '${_rmrh_name}' at ${_rmrh_local_dir} — multiplexer was not declared in the manifest used to build this image (ADR-001 fail-loud). Check rc.multiplexers image label and the manifest used during rc build." >&2
      return 1
    fi

    # Optional hook absent → return empty string (no-op; caller provides fallback).
    if [[ ! -f "$_rmrh_local_hook_path" ]]; then
      return 0
    fi

    # In-container callers: return the canonical in-container path.
    # (When RC_MUX_REGISTRY_ROOT is set, the local path IS the hook path for tests.)
    if [[ -n "${RC_MUX_REGISTRY_ROOT:-}" ]]; then
      printf '%s' "$_rmrh_local_hook_path"
    else
      printf '%s' "${_rmrh_hook_path_in_container}"
    fi
  fi
}

