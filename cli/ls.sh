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


# _rc_ls_enumerate -- msb-side enumeration shared by cmd_ls's JSON/human
# branches below (rip-cage-tsf2.1: REWRITTEN onto msb — was `docker ps -a
# --filter label=rc.source.path`). Emits one tab-separated row per REAL
# rc-managed msb sandbox (any sandbox carrying a non-empty rc.source.path
# label — same filter semantics as the docker path it replaces):
#   name \t status(running|exited|unknown) \t uptime \t source_path \t egress
#
# rip-cage-rj68 (S6, opportunistic cleanup carried over from S5's review):
# rc.forward-ssh / rc.github-identity are RETIRED labels (ADR-029 D3, the
# ssh cluster is gone) — no cage created via `rc up` since S5 has ever set
# them; never read here.
_rc_ls_enumerate() {
  local _lse_names_json
  _lse_names_json=$(msb list --format json 2>/dev/null) || return 0
  local _lse_name
  while IFS= read -r _lse_name; do
    [[ -z "$_lse_name" ]] && continue
    local _lse_raw
    _lse_raw=$(_msb_inspect_json "$_lse_name") || continue
    local _lse_src
    _lse_src=$(jq -r '.config.labels["rc.source.path"] // empty' <<<"$_lse_raw" 2>/dev/null)
    [[ -z "$_lse_src" ]] && continue  # not rc-managed
    local _lse_egress
    _lse_egress=$(jq -r '.config.labels["rc.egress"] // empty' <<<"$_lse_raw" 2>/dev/null)
    local _lse_status_raw _lse_status _lse_running
    _lse_status_raw=$(jq -r '.status // empty' <<<"$_lse_raw" 2>/dev/null)
    _lse_running=0
    case "$_lse_status_raw" in
      Running) _lse_status="running"; _lse_running=1 ;;
      Stopped) _lse_status="exited" ;;
      *)       _lse_status="unknown" ;;
    esac
    local _lse_updated_at _lse_uptime
    _lse_updated_at=$(jq -r '.updated_at // empty' <<<"$_lse_raw" 2>/dev/null)
    _lse_uptime=$(_rc_uptime_from_state "$_lse_running" "$_lse_updated_at")
    printf '%s\t%s\t%s\t%s\t%s\n' "$_lse_name" "$_lse_status" "$_lse_uptime" "$_lse_src" "$_lse_egress"
  done < <(jq -r '.[].name' <<<"$_lse_names_json" 2>/dev/null)
}


cmd_ls() {
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # rip-cage-hhh FIX1: mode derived from source path's .rip-cage.yaml (live),
    # not the immutable rc.egress.mode label. Compute mode per-row via
    # _rc_ls_mode_from_source_path.
    local _ls_raw _ls_json
    _ls_raw=$(_rc_ls_enumerate)
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
    _ls_raw_txt=$(_rc_ls_enumerate)
    while IFS=$'\t' read -r _ls_name _ls_status _ls_uptime _ls_src _ls_egress; do
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

