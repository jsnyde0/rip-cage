#!/usr/bin/env bash
# cli/config.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


cmd_config() {
  local sub="${1:-}"
  if [[ -n "$sub" ]]; then shift; fi
  case "$sub" in
    show) cmd_config_show "$@" ;;
    get) cmd_config_get "$@" ;;
    "")
      echo "Usage: rc config <show|get> [flags]" >&2
      exit 1
      ;;
    *)
      echo "Error: unknown config subcommand '$sub'" >&2
      echo "Usage: rc config <show|get> [flags]" >&2
      exit 1
      ;;
  esac
}


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

