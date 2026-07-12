#!/usr/bin/env bash
# cli/ls.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# _rc_ls_mode_from_source_path -- derive the CURRENT egress mode from the source
# workspace's .rip-cage.yaml (the live source of truth post-promote/reload).
#
# Docker labels are stamped at create time (immutable); this helper reads the
# file that rc reload rewrites, so it reflects the actual running mode instead
# of the stale create-time label.
#
# Parameter: $1 source_path -- path to the cage's workspace (rc.source.path label value)
# Prints:    "block" | "observe" | "off" | "legacy" (absent file or absent/null network.mode)
#
# Falls back to "legacy" on any error (no-op for pre-hhh workspaces).
_rc_ls_mode_from_source_path() {
  local src_path="$1"
  local yaml_file="${src_path}/.rip-cage.yaml"
  if [[ ! -f "$yaml_file" ]]; then
    echo "legacy"
    return
  fi
  local mode
  if ! command -v yq &>/dev/null; then
    echo "legacy"
    return
  fi
  mode=$(yq '.network.mode // "legacy"' "$yaml_file" 2>/dev/null | tr -d '"' | tr -d "'" || echo "legacy")
  mode="${mode:-legacy}"
  if [[ "$mode" == "null" || "$mode" == "~" ]]; then
    mode="legacy"
  fi
  echo "$mode"
}


cmd_ls() {
  local _ls_timeout="${RC_DOCKER_CALL_TIMEOUT:-15}"
  # rip-cage-rj68 (S6, opportunistic cleanup carried over from S5's review):
  # rc.forward-ssh / rc.github-identity are RETIRED labels (ADR-029 D3, the
  # ssh cluster is gone) — no cage created via `rc up` since S5 has ever set
  # them. Dropped from both the docker format string and the output shape
  # rather than left reading empty forever.
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # rip-cage-hhh FIX1: mode derived from source path's .rip-cage.yaml (live),
    # not the immutable rc.egress.mode label. Include rc.source.path in format
    # and compute mode per-row via _rc_ls_mode_from_source_path.
    local _ls_raw _ls_json
    _ls_raw=$(_docker_call "$_ls_timeout" ps -a --filter label=rc.source.path --format '{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Label "rc.source.path"}}\t{{.Label "rc.egress"}}' 2>/dev/null || true)
    _ls_json="["
    local _ls_first="true"
    while IFS=$'\t' read -r _ls_name _ls_status _ls_uptime _ls_src _ls_egress; do
      [[ -z "$_ls_name" ]] && continue
      local _ls_mode
      _ls_mode=$(_rc_ls_mode_from_source_path "$_ls_src")
      local _ls_egress_norm
      if [[ "$_ls_egress" == "" ]]; then _ls_egress_norm="legacy"
      elif [[ "$_ls_egress" == "on" || "$_ls_egress" == "off" ]]; then _ls_egress_norm="$_ls_egress"
      else _ls_egress_norm="invalid:${_ls_egress}"; fi
      local _ls_entry
      _ls_entry=$(jq -nc \
        --arg name "$_ls_name" \
        --arg status "$_ls_status" \
        --arg uptime "$_ls_uptime" \
        --arg source_path "$_ls_src" \
        --arg egress "$_ls_egress_norm" \
        --arg mode "$_ls_mode" \
        '{name:$name, status:$status, uptime:$uptime, source_path:$source_path, egress:$egress, mode:$mode}' \
        2>/dev/null || true)
      if [[ -n "$_ls_entry" ]]; then
        if [[ "$_ls_first" == "true" ]]; then
          _ls_json="${_ls_json}${_ls_entry}"
          _ls_first="false"
        else
          _ls_json="${_ls_json},${_ls_entry}"
        fi
      fi
    done <<EOF
${_ls_raw}
EOF
    _ls_json="${_ls_json}]"
    echo "$_ls_json"
  else
    # rip-cage-hhh FIX1: MODE column derived from source path's .rip-cage.yaml (live),
    # not the immutable rc.egress.mode label. Build per-row with a while-read loop.
    echo -e "NAME\tSTATUS\tEGRESS\tMODE\tSOURCE PATH"
    local _ls_raw_txt
    _ls_raw_txt=$(_docker_call "$_ls_timeout" ps -a --filter label=rc.source.path --format '{{.Names}}\t{{.Status}}\t{{.Label "rc.source.path"}}\t{{.Label "rc.egress"}}' 2>/dev/null || true)
    while IFS=$'\t' read -r _ls_name _ls_uptime _ls_src _ls_egress; do
      [[ -z "$_ls_name" ]] && continue
      local _ls_mode _ls_egress_out
      _ls_mode=$(_rc_ls_mode_from_source_path "$_ls_src")
      if [[ "$_ls_egress" == "" ]]; then _ls_egress_out="legacy"
      elif [[ "$_ls_egress" == "on" || "$_ls_egress" == "off" ]]; then _ls_egress_out="$_ls_egress"
      else _ls_egress_out="invalid:${_ls_egress}"; fi
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$_ls_name" "$_ls_uptime" "$_ls_egress_out" "$_ls_mode" "$_ls_src"
    done <<EOF
${_ls_raw_txt}
EOF
  fi
}

