#!/usr/bin/env bash
# cli/manifest.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# cmd_manifest / _manifest_reconcile (rip-cage-6vt9)
#
# `rc manifest reconcile` — the reconcile path paired with the seed-drift
# warning above. Re-seeds default-derived entries in the local operator
# manifest from the CURRENT shipped manifest/default-tools.yaml, while
# PRESERVING any entry whose name is NOT present in dist (a custom/opt-in
# entry the operator added, e.g. an optional multiplexer integration). Never overwrites
# silently (ADR-005 D12 — the manifest composition is the operator's): the
# previous file is backed up before being replaced, and the new file is
# validated before it is ever moved into place.

# _manifest_reconcile_usage — shared by --help (stdout, exit 0) and the
# unrecognised-argument refusal (stderr, exit 2) in _manifest_reconcile
# below (rip-cage-xrcr).
_manifest_reconcile_usage() {
  cat <<'USAGE'
Usage: rc manifest reconcile
  Re-seed default-derived entries in ~/.config/rip-cage/tools.yaml from the
  current manifest/default-tools.yaml, preserving any custom (non-default) entries.
  Backs up the previous file first; never overwrites silently.
USAGE
}

cmd_manifest() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    reconcile) _manifest_reconcile "$@" ;;
    *)
      echo "Usage: rc manifest reconcile" >&2
      echo "  Re-seed default-derived entries in ~/.config/rip-cage/tools.yaml from the" >&2
      echo "  current manifest/default-tools.yaml, preserving any custom (non-default) entries." >&2
      echo "  Backs up the previous file first; never overwrites silently." >&2
      exit 1
      ;;
  esac
}


# _manifest_reconcile — see cmd_manifest header above for the design.
_manifest_reconcile() {
  # rip-cage-xrcr DEFECT 1: parse args at the TOP, before any filesystem
  # work or yq/jq dependency probing below -- an unrecognised trailing
  # token (including --help/--dry-run) used to fall straight through into
  # the real merge instead of being rejected.
  local _mr_arg
  for _mr_arg in "$@"; do
    case "$_mr_arg" in
      --help|-h)
        _manifest_reconcile_usage
        exit 0
        ;;
      *)
        echo "Error: rc manifest reconcile: unrecognised argument '${_mr_arg}' -- refusing to run." >&2
        echo "" >&2
        _manifest_reconcile_usage >&2
        exit 2
        ;;
    esac
  done

  local _local_path _dist_path
  _local_path=$(_manifest_global_path)
  _dist_path=$(_manifest_dist_path)

  # rip-cage-xrcr DEFECT 2: when the local manifest path is a symlink, the
  # write below must go THROUGH the link (so the symlink survives and the
  # resolved target's content changes) rather than `mv` replacing the
  # symlink itself with a regular file. Resolve now, before any write, so
  # every write-side use below (_tmp_path, backup, mv) targets the real
  # file. macOS has no GNU `readlink -f`; bare `realpath` (already used
  # elsewhere in this codebase, e.g. cli/lib/path.sh, cli/config.sh) is the
  # portable resolver -- verified on this machine to resolve a symlink
  # chain to its real target without requiring a `-f`/`-e` flag.
  local _write_path="$_local_path"
  if [[ -L "$_local_path" ]]; then
    local _mr_resolved _mr_home_real
    if ! _mr_resolved=$(realpath "$_local_path" 2>/dev/null); then
      echo "Error: '${_local_path}' is a symlink but its target could not be resolved (broken link?) -- refusing to reconcile." >&2
      return 1
    fi
    _mr_home_real=$(realpath "$HOME" 2>/dev/null) || _mr_home_real="$HOME"
    if [[ "$_mr_resolved" != "$_mr_home_real" && "$_mr_resolved" != "$_mr_home_real"/* ]]; then
      echo "Error: '${_local_path}' is a symlink pointing outside \$HOME, at '${_mr_resolved}' -- refusing to reconcile through it. Resolve or replace the symlink yourself first." >&2
      return 1
    fi
    _write_path="$_mr_resolved"
  fi

  if [[ ! -f "$_dist_path" ]]; then
    echo "Error: shipped default manifest not found at ${_dist_path} — cannot reconcile." >&2
    return 1
  fi
  if ! command -v yq &>/dev/null; then
    echo "Error: yq not found on PATH. yq is required for 'rc manifest reconcile' — install it: brew install yq (macOS) or the mikefarah/yq release binary (Linux: https://github.com/mikefarah/yq/releases) — NOT apt's yq, which is the incompatible python-yq." >&2
    return 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "Error: jq not found on PATH. jq is required for 'rc manifest reconcile'." >&2
    return 1
  fi

  local _dist_tools_json
  if ! _dist_tools_json=$(yq -o=json '.tools // []' "$_dist_path" 2>/dev/null); then
    echo "Error: failed to parse shipped default manifest '${_dist_path}' as YAML." >&2
    return 1
  fi

  local _local_tools_json="[]"
  if [[ -f "$_local_path" ]]; then
    if ! _local_tools_json=$(yq -o=json '.tools // []' "$_local_path" 2>/dev/null); then
      echo "Error: failed to parse local manifest '${_local_path}' as YAML — refusing to reconcile (fix or remove it first)." >&2
      return 1
    fi
  fi

  # Merge: dist's entries win for any name dist defines (refreshed to
  # current dist content, added if new); any local entry whose name is
  # NOT in dist is a custom entry and is preserved, appended after.
  local _merged_tools_json
  _merged_tools_json=$(jq -c -n --argjson dist "$_dist_tools_json" --argjson local "$_local_tools_json" '
    ($dist | map(.name)) as $dist_names
    | ($local | map(select(.name as $n | ($dist_names | index($n)) | not))) as $custom
    | ($dist + $custom)
  ') || {
    echo "Error: failed to compute the reconciled tool list (jq merge failed)." >&2
    return 1
  }

  # Summary of what changed, for the operator-facing report.
  local _summary
  _summary=$(jq -c -n --argjson dist "$_dist_tools_json" --argjson local "$_local_tools_json" '
    ($dist | map({key: .name, value: .}) | from_entries) as $dist_by_name
    | ($local | map({key: .name, value: .}) | from_entries) as $local_by_name
    | ($dist | map(.name)) as $dist_names
    | ($local | map(.name)) as $local_names
    | {
        added: [$dist_names[] | select(. as $n | ($local_names | index($n)) | not)],
        updated: [$dist_names[] | select(. as $n | ($local_names | index($n)) and ($dist_by_name[$n] != $local_by_name[$n]))],
        preserved: [$local_names[] | select(. as $n | ($dist_names | index($n)) | not)]
      }
  ') || _summary='{"added":[],"updated":[],"preserved":[]}'

  local _final_yaml
  if ! _final_yaml=$(jq -n --argjson tools "$_merged_tools_json" '{version: 1, tools: $tools}' | yq -p=json -o=yaml '.' 2>/dev/null); then
    echo "Error: failed to render the reconciled manifest as YAML." >&2
    return 1
  fi

  local _dist_hash
  _dist_hash=$(_manifest_seed_fingerprint_hash "$_dist_path")

  # rip-cage-xrcr DEFECT 2: $_tmp_path/$_backup_path/the final mv all target
  # $_write_path (the resolved real file when $_local_path is a symlink, or
  # $_local_path itself otherwise) -- see the resolution above. $_local_path
  # stays the path named in operator-facing messages below (it's the one the
  # operator actually configured/reads).
  local _tmp_path="${_write_path}.rc-reconcile-tmp.$$"
  {
    echo "# rc-seed-fingerprint: sha256:${_dist_hash}"
    echo "# Reconciled from $(basename "$_dist_path") by 'rc manifest reconcile' on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    printf '%s\n' "$_final_yaml"
  } > "$_tmp_path"

  if ! _manifest_validate "$_tmp_path"; then
    echo "Error: reconciled manifest failed validation — aborting; the original manifest at '${_local_path}' is untouched." >&2
    rm -f "$_tmp_path"
    return 1
  fi

  local _backup_path=""
  if [[ -f "$_write_path" ]]; then
    _backup_path="${_write_path}.bak-$(date -u +%Y%m%d%H%M%S)"
    if ! cp "$_write_path" "$_backup_path"; then
      echo "Error: failed to back up '${_local_path}' before reconciling — aborting; nothing was changed." >&2
      rm -f "$_tmp_path"
      return 1
    fi
  fi

  mkdir -p "$(dirname "$_write_path")"
  mv "$_tmp_path" "$_write_path"

  local _added _updated _preserved
  _added=$(jq -r '.added | join(", ")' <<<"$_summary")
  _updated=$(jq -r '.updated | join(", ")' <<<"$_summary")
  _preserved=$(jq -r '.preserved | join(", ")' <<<"$_summary")

  echo "rc manifest reconcile: updated ${_local_path} from $(basename "$_dist_path")." >&2
  [[ -n "$_backup_path" ]] && echo "  Backup of the previous manifest: ${_backup_path}" >&2
  # F2 (rip-cage-6vt9 review fold): the YAML-through-JSON round-trip used to
  # render the merged manifest (yq -o=json / -p=json) drops comments —
  # including any operator comment living inside a PRESERVED custom entry.
  # Disclose this honestly rather than silently; the backup is the recovery
  # path (it is a raw `cp` of the original file, comments intact).
  [[ -n "$_backup_path" ]] && echo "  Note: comments are not preserved by this merge (yq/jq round-trip) — the backup retains the original file with comments intact." >&2
  [[ -n "$_added" ]] && echo "  Added (new in dist): ${_added}" >&2
  [[ -n "$_updated" ]] && echo "  Updated (refreshed to current dist): ${_updated}" >&2
  [[ -n "$_preserved" ]] && echo "  Preserved (custom entries, not in dist): ${_preserved}" >&2
  if [[ -z "$_added" && -z "$_updated" && -z "$_preserved" ]]; then
    echo "  No changes — already matches current dist." >&2
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc \
      --arg path "$_local_path" \
      --arg backup "$_backup_path" \
      --argjson added "$(jq -c '.added' <<<"$_summary")" \
      --argjson updated "$(jq -c '.updated' <<<"$_summary")" \
      --argjson preserved "$(jq -c '.preserved' <<<"$_summary")" \
      '{manifest: $path, backup: (if $backup == "" then null else $backup end), added: $added, updated: $updated, preserved: $preserved, status: "reconciled"}'
  fi
  return 0
}


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

