#!/usr/bin/env bash
# cli/config.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


cmd_config() {
  local sub="${1:-}"
  if [[ -n "$sub" ]]; then shift; fi
  case "$sub" in
    show) cmd_config_show "$@" ;;
    get) cmd_config_get "$@" ;;
    set) cmd_config_set "$@" ;;
    add) cmd_config_add "$@" ;;
    remove) cmd_config_remove "$@" ;;
    "")
      echo "Usage: rc config <show|get|set|add|remove> [flags]" >&2
      exit 1
      ;;
    *)
      echo "Error: unknown config subcommand '$sub'" >&2
      echo "Usage: rc config <show|get|set|add|remove> [flags]" >&2
      exit 1
      ;;
  esac
}


# _config_write_verb -- shared arg-parse + dispatch for the host-side write
# verbs (rc config set/add/remove, ADR-021 D8). Positional args: <key> then
# <value|item> then an optional [workspace-path] (project scope only, default
# pwd). Required flag: --scope global|project (no default guessing — the verb
# routes intent to the right home, so the operator declares which). Host-side
# only: refuses in-cage (defense-in-depth; rc is not on the cage PATH anyway).
# Global scope on an absent file seeds the canonical global template first
# (_config_ensure_global_seeded), then applies the edit; project scope on an
# absent file lets the edit engine create a minimal version: 2 file.
#   $1 verb (set|add|remove); $@ (rest) = the verb's args
_config_write_verb() {
  local verb="$1"; shift
  local key="" value="" ws="" scope="" key_set=0 value_set=0 ws_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope) scope="${2:-}"; shift 2 ;;
      --scope=*) scope="${1#--scope=}"; shift ;;
      -*) echo "Error: unknown flag '$1' (rc config ${verb} <key> <value> --scope global|project [path])" >&2; exit 1 ;;
      *)
        if [[ "$key_set" -eq 0 ]]; then key="$1"; key_set=1
        elif [[ "$value_set" -eq 0 ]]; then value="$1"; value_set=1
        elif [[ "$ws_set" -eq 0 ]]; then ws="$1"; ws_set=1
        else echo "Error: unexpected extra argument '$1'" >&2; exit 1; fi
        shift
        ;;
    esac
  done

  if [[ "$key_set" -eq 0 || "$value_set" -eq 0 ]]; then
    echo "Error: rc config ${verb} requires <key> and <value|item>" >&2
    echo "Usage: rc config ${verb} <key> <value> --scope global|project [path]" >&2
    exit 1
  fi
  if [[ "$scope" != "global" && "$scope" != "project" ]]; then
    echo "Error: rc config ${verb} requires --scope global|project (no default — declare where the change lives)" >&2
    exit 1
  fi

  # Host-side only (D8 / ADR-024 threat model): refuse in-cage.
  if _allowlist_is_in_cage; then
    echo "Error: 'rc config ${verb}' is a host-only command — it edits the cage's own posture files, which are read-only inside the cage by default (ADR-021 D7)." >&2
    echo "You appear to be inside a rip-cage container. To change config:" >&2
    echo "  - Surface the request in prose to the human (e.g. 'please run rc config ${verb} ${key} ...')" >&2
    echo "  - The human (or a host-side assistant) edits the file on the host, then rc reload <cage>" >&2
    exit 1
  fi

  local file
  if [[ "$scope" == "global" ]]; then
    _config_ensure_global_seeded
    file=$(_config_global_path)
  else
    local workspace="${ws:-$(pwd)}"
    file=$(_config_project_path "$workspace")
  fi

  # NOTE: the shim owns `set -e`; a bare (non-conditional) call to a command
  # returning non-zero (edit_rc==2 for the idempotent add no-op) would abort
  # the whole script before `local edit_rc=$?` ever ran. The `||` makes this
  # a conditional context so errexit does not fire, and edit_rc still
  # captures the real exit code (0 default only reached on success).
  local edit_rc=0
  _config_edit_apply "$verb" "$key" "$value" "$file" || edit_rc=$?
  if [[ "$edit_rc" -eq 1 ]]; then
    exit 1
  fi

  case "$verb" in
    set)    echo "Set ${key} = ${value} in ${file}" ;;
    add)
      if [[ "$edit_rc" -eq 2 ]]; then
        echo "'${value}' already present in ${key} in ${file} — no changes made."
      else
        echo "Added '${value}' to ${key} in ${file}"
      fi
      ;;
    remove) echo "Removed '${value}' from ${key} in ${file}" ;;
  esac
}


cmd_config_set()    { _config_write_verb set    "$@"; }
cmd_config_add()    { _config_write_verb add    "$@"; }
cmd_config_remove() { _config_write_verb remove "$@"; }


cmd_config_show() {
  local fmt="yaml"
  local path_arg="" path_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) fmt="json"; shift ;;
      -*) echo "Error: unknown flag '$1' (rc config show supports --json)" >&2; exit 1 ;;
      *)
        if [[ "$path_set" -eq 1 ]]; then
          echo "Error: unexpected extra argument '$1' (rc config show takes at most one <path>)" >&2
          exit 1
        fi
        path_arg="$1"
        path_set=1
        shift
        ;;
    esac
  done

  _config_check_yq

  _config_resolve_workspace_arg "$path_arg" "$fmt"
  local workspace="$_CONFIG_RESOLVED_WORKSPACE"

  local result
  if ! result=$(_load_effective_config "$workspace"); then
    exit 1
  fi

  if [[ "$fmt" == "json" ]]; then
    echo "$result" | jq '.'
  else
    _config_format_yaml "$result"
  fi
}


# _config_resolve_workspace_arg -- validate an optional <path> positional for
# `rc config show`/`rc config get` (rip-cage-08q). On success, sets global
# _CONFIG_RESOLVED_WORKSPACE to the resolved absolute path. On an invalid or
# nonexistent path: prints a clear error (json_error under --json) and exits
# 1. Empty <path> resolves to pwd, unvalidated — preserves the pre-rip-cage-08q
# no-arg default behavior byte-for-byte.
# NOTE: must be called directly (NOT inside a command substitution) so error
# output reaches the real stdout/stderr instead of being captured by $(...).
# Args: $1 = raw path arg (possibly empty ⇒ pwd), $2 = "json"|"yaml" (fmt)
_config_resolve_workspace_arg() {
  local raw="$1" fmt="$2"
  if [[ -z "$raw" ]]; then
    _CONFIG_RESOLVED_WORKSPACE="$(pwd)"
    return 0
  fi
  local resolved
  if ! resolved=$(realpath "$raw" 2>/dev/null); then
    if [[ "$fmt" == "json" ]]; then
      json_error "path not found: '$raw'" "PATH_NOT_FOUND"
    else
      echo "Error: path not found: '$raw'" >&2
      exit 1
    fi
  fi
  if [[ ! -d "$resolved" ]]; then
    if [[ "$fmt" == "json" ]]; then
      json_error "path is not a directory: '$raw'" "PATH_INVALID"
    else
      echo "Error: path is not a directory: '$raw'" >&2
      exit 1
    fi
  fi
  _CONFIG_RESOLVED_WORKSPACE="$resolved"
}


cmd_config_get() {
  local fmt="raw"
  local key="" path_arg="" key_set=0 path_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) fmt="json"; shift ;;
      -*) echo "Error: unknown flag '$1' (rc config get supports --json)" >&2; exit 1 ;;
      *)
        if [[ "$key_set" -eq 0 ]]; then
          key="$1"; key_set=1; shift
        elif [[ "$path_set" -eq 0 ]]; then
          path_arg="$1"; path_set=1; shift
        else
          echo "Error: unexpected extra argument '$1' (rc config get takes <dotted.key> [path])" >&2
          exit 1
        fi
        ;;
    esac
  done

  if [[ "$key_set" -eq 0 ]]; then
    echo "Error: rc config get requires a <dotted.key>" >&2
    exit 1
  fi

  _config_check_yq

  _config_resolve_workspace_arg "$path_arg" "$fmt"
  local workspace="$_CONFIG_RESOLVED_WORKSPACE"

  local result
  if ! result=$(_load_effective_config "$workspace"); then
    exit 1
  fi

  # Distinguish an ABSENT key from a legitimate null VALUE (e.g.
  # mounts.allow_risky defaults to null) — presence is determined by whether
  # the parent object actually contains the leaf key, not by whether the
  # resolved value is null.
  # rip-cage-08q adversarial review: a key whose parent path descends
  # THROUGH a scalar/array intermediate (e.g. mounts.config_mode.foo.bar,
  # where mounts.config_mode is a string) makes `getpath` error ("Cannot
  # index string with string"). Wrap in try/catch so that degrades to
  # "not present" (false) instead of a jq exit-5 crash that — under this
  # script's `set -euo pipefail` (rc:6) — would abort rc entirely before the
  # `present != "true"` check below ever runs. Precedent for guarding this
  # construct against errexit: rc:11575 (`... 2>/dev/null || echo
  # "___RC_ABSENT___"`). Belt-and-suspenders: the shell-side `|| printf
  # 'false'` covers a non-jq failure of the assignment too.
  local present
  present=$(jq -r --arg k "$key" '
    try (
      ($k | split(".")) as $p
      | ($p[0:-1]) as $pp
      | ($p[-1]) as $leaf
      | (.config | getpath($pp)) as $parent
      | (($parent|type)=="object") and ($parent|has($leaf))
    ) catch false
  ' <<<"$result" 2>/dev/null || printf 'false')

  if [[ "$present" != "true" ]]; then
    if [[ "$fmt" == "json" ]]; then
      json_error "key not found in effective config: $key" "KEY_NOT_FOUND"
    else
      echo "Error: key not found in effective config: $key" >&2
      exit 1
    fi
  fi

  if [[ "$fmt" == "json" ]]; then
    jq --arg k "$key" '.config | getpath($k | split("."))' <<<"$result"
  else
    jq -r --arg k "$key" '.config | getpath($k | split("."))' <<<"$result"
  fi
}

