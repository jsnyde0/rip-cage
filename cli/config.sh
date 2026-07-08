#!/usr/bin/env bash
# cli/config.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# _config_init_emit_tip -- 1-line nudge toward `rc config init` when this
# project lacks a .rip-cage.yaml AND has at least one git SSH remote.
# Silent otherwise. Independent of yq; uses git only. Called from cmd_up after
# _config_emit_hint so the tip lands in the existing post-up status block.
_config_init_emit_tip() {
  local _ws="$1"
  [[ -f "${_ws}/.rip-cage.yaml" ]] && return 0
  git -C "$_ws" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$_ws" remote -v 2>/dev/null \
    | awk 'NF && ($2 ~ /^git@/ || $2 ~ /^ssh:\/\//) { found=1 } END { exit !found }' \
    || return 0
  log "Tip: no .rip-cage.yaml in this project — run 'rc config init' to tighten"
  log "     SSH host/key trust to what this project actually uses (~30s)."
}


cmd_config() {
  local sub="${1:-}"
  if [[ -n "$sub" ]]; then shift; fi
  case "$sub" in
    show) cmd_config_show "$@" ;;
    get) cmd_config_get "$@" ;;
    init) cmd_config_init "$@" ;;
    "")
      echo "Usage: rc config <show|get|init> [flags]" >&2
      exit 1
      ;;
    *)
      echo "Error: unknown config subcommand '$sub'" >&2
      echo "Usage: rc config <show|get|init> [flags]" >&2
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


# _config_init_detect_ssh_hosts -- extract unique SSH host names from `git remote -v`.
# Recognized URL shapes:
#   ssh://[user@]host[:port]/path
#   user@host:path                 (scp-like)
# Returns: newline-separated host list on stdout (sorted, unique, possibly empty).
_config_init_detect_ssh_hosts() {
  local _ws="$1"
  if ! git -C "$_ws" rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  git -C "$_ws" remote -v 2>/dev/null \
    | awk '{print $2}' \
    | sort -u \
    | sed -n -E '
        s|^ssh://[^@/]+@([^:/]+).*|\1|p
        s|^ssh://([^:/]+).*|\1|p
        s|^[A-Za-z0-9._-]+@([^:]+):.*|\1|p
      ' \
    | sort -u
}


# _config_init_detect_keys -- two-tier heuristic for "which host SSH key(s) does
# this project actually use?":
#
#   Tier 1 (precise): for each host, ask `ssh -G <host>` for the effective
#                     IdentityFile and emit its basename if the file exists.
#                     Only fires when the user has a Host-specific directive
#                     for the actual remote host (e.g. `Host github.com`).
#   Tier 2 (fallback): when Tier 1 finds nothing, scan loaded ssh-add -L keys
#                     and match each key's basename + comment against tokens
#                     derived from the host names and workspace path. First
#                     match wins. Covers the common case of host-alias setups
#                     (Host github-work / Host github-personal) where ssh -G
#                     against the real host falls through to the SSH defaults.
#
# Parameters:
#   $1 hosts     — newline-separated host list (output of detect_ssh_hosts)
#   $2 workspace — workspace path (used for path-component tokens)
# Returns: 0..N key basenames on stdout, order-preserving deduped.
_config_init_detect_keys() {
  local _hosts="$1" _ws="${2:-}"
  if [[ -z "$_hosts" ]]; then return 0; fi

  local _seen="" _host _ident _bn _emitted=0
  if command -v ssh >/dev/null 2>&1; then
    while IFS= read -r _host; do
      [[ -z "$_host" ]] && continue
      _ident=$(ssh -G "$_host" 2>/dev/null | awk '/^identityfile / {print $2; exit}' || true)
      [[ -z "$_ident" ]] && continue
      _ident="${_ident/#\~/$HOME}"
      _bn=$(basename "$_ident")
      if [[ ! -f "${HOME}/.ssh/${_bn}" && ! -f "${HOME}/.ssh/${_bn}.pub" ]]; then
        continue
      fi
      if [[ ":${_seen}:" != *":${_bn}:"* ]]; then
        _seen="${_seen}:${_bn}"
        printf '%s\n' "$_bn"
        _emitted=1
      fi
    done <<< "$_hosts"
  fi

  # Tier 2 fallback only when Tier 1 yielded nothing.
  if [[ "$_emitted" -eq 0 ]]; then
    _config_init_keys_by_comment_match "$_hosts" "$_ws"
  fi
}


# _config_init_keys_by_comment_match -- Tier 2 heuristic. For each key loaded
# in ssh-add -L, find its ~/.ssh/<bn>.pub file (matched by blob), then test
# whether the basename+comment string contains any token derived from:
#   - each SSH host name (and dotted parts longer than 3 chars: github.com → github)
#   - the workspace basename
#   - the workspace parent directory basename (covers ~/code/personal/foo,
#     ~/code/mapular/foo style layouts where the parent dir names the account)
# First match wins; second+ matches ignored (one identity per project is the
# common case, multi-key projects can hand-edit). Silent when ssh-add absent
# or no keys loaded.
_config_init_keys_by_comment_match() {
  local _hosts="$1" _ws="${2:-$PWD}"
  command -v ssh-add >/dev/null 2>&1 || return 0
  local _agent_out
  _agent_out=$(ssh-add -L 2>/dev/null) || return 0
  [[ -z "$_agent_out" ]] && return 0

  # Build token set.
  local _tokens="" _h _parts _p _ws_base _ws_parent
  while IFS= read -r _h; do
    [[ -z "$_h" ]] && continue
    _tokens="${_tokens} ${_h}"
    _parts=$(printf '%s' "$_h" | tr '.' ' ')
    for _p in $_parts; do
      [[ ${#_p} -gt 3 ]] && _tokens="${_tokens} ${_p}"
    done
  done <<< "$_hosts"
  _ws_base=$(basename "$_ws")
  _ws_parent=$(basename "$(dirname "$_ws")")
  _tokens="${_tokens} ${_ws_base} ${_ws_parent}"

  # For each loaded key: blob → ~/.ssh/<bn>.pub → token-match basename+comment.
  local _line _blob _comment _bn _pub _haystack _t
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _blob=$(printf '%s' "$_line" | awk '{print $2}')
    _comment=$(printf '%s' "$_line" | cut -d' ' -f3-)
    [[ -z "$_blob" ]] && continue
    _bn=""
    for _pub in "${HOME}"/.ssh/*.pub; do
      [[ -f "$_pub" ]] || continue
      if grep -qF "$_blob" "$_pub" 2>/dev/null; then
        _bn=$(basename "$_pub" .pub)
        break
      fi
    done
    [[ -z "$_bn" ]] && continue
    _haystack="${_bn} ${_comment}"
    for _t in $_tokens; do
      [[ -z "$_t" ]] && continue
      if [[ "$_haystack" == *"$_t"* ]]; then
        printf '%s\n' "$_bn"
        return 0
      fi
    done
  done <<< "$_agent_out"
}


# _config_init_build_yaml -- emit proposed .rip-cage.yaml on stdout.
# Parameters:
#   $1 hosts  — newline-separated SSH host list (may be empty)
#   $2 keys   — newline-separated key basename list (may be empty)
_config_init_build_yaml() {
  local _hosts="$1" _keys="$2"
  # shellcheck disable=SC2016  # literal backticks in generated YAML comment
  printf '# Generated by `rc config init` on %s\n' "$(date +%Y-%m-%d)"
  printf '# Detection: git remote -v + ssh -G <host>. Edit freely.\n'
  printf 'version: 1\n'
  printf 'ssh:\n'
  if [[ -n "$_hosts" ]]; then
    printf '  allowed_hosts:\n'
    while IFS= read -r _h; do
      [[ -z "$_h" ]] && continue
      printf '    - %s\n' "$_h"
    done <<< "$_hosts"
  else
    printf '  # No SSH remotes detected in this project.\n'
    printf '  allowed_hosts: []\n'
  fi
  if [[ -n "$_keys" ]]; then
    printf '  allowed_keys:\n'
    while IFS= read -r _k; do
      [[ -z "$_k" ]] && continue
      printf '    - %s\n' "$_k"
    done <<< "$_keys"
  else
    printf '  # No matching identity files. Leaving allowed_keys unset forwards all keys (default).\n'
    printf '  # allowed_keys: []   # uncomment to forward zero keys\n'
  fi
}


# cmd_config_init -- interactive bootstrap for <workspace>/.rip-cage.yaml.
# Detects git SSH remotes + the IdentityFile ssh -G would pick for each, prints
# proposed YAML with provenance comments, prompts before writing. Idempotent:
# re-running with the file present prints a unified diff against the proposal.
# Flags:
#   --yes / -y    Skip confirmation; required when stdin is not a TTY.
#   --force       Overwrite even when the existing file matches the proposal.
cmd_config_init() {
  local _yes=0 _force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) _yes=1; shift ;;
      --force) _force=1; shift ;;
      -*)
        echo "Error: unknown flag '$1' (rc config init supports --yes, --force)" >&2
        exit 1 ;;
      *)
        echo "Error: unexpected argument '$1' (rc config init takes no positional args)" >&2
        exit 1 ;;
    esac
  done

  local _ws _cfg
  _ws="$(pwd)"
  _cfg="${_ws}/.rip-cage.yaml"

  local _hosts _keys
  _hosts=$(_config_init_detect_ssh_hosts "$_ws")
  _keys=$(_config_init_detect_keys "$_hosts" "$_ws")

  if [[ -z "$_hosts" && -z "$_keys" ]]; then
    echo "rc config init: no SSH remotes or matching identity files detected." >&2
    echo "                Nothing to lock down — skipping (no .rip-cage.yaml written)." >&2
    exit 0
  fi

  local _proposed
  _proposed=$(_config_init_build_yaml "$_hosts" "$_keys")

  if [[ -f "$_cfg" ]]; then
    # Idempotent path: show diff. If no diff and not --force, exit clean.
    if diff -q "$_cfg" <(printf '%s\n' "$_proposed") >/dev/null 2>&1; then
      if [[ "$_force" -eq 0 ]]; then
        echo "rc config init: $_cfg already matches the proposal; nothing to do."
        exit 0
      fi
    else
      echo "Existing .rip-cage.yaml differs from proposed. Diff (current → proposed):"
      diff -u "$_cfg" <(printf '%s\n' "$_proposed") || true
    fi
  else
    echo "Proposed $_cfg:"
    echo "----"
    printf '%s\n' "$_proposed"
    echo "----"
  fi

  if [[ "$_yes" -eq 0 ]]; then
    if [[ ! -t 0 ]]; then
      echo "Error: stdin is not a TTY; pass --yes to write non-interactively." >&2
      exit 1
    fi
    local _ans
    printf 'Write %s? [y/N] ' "$_cfg"
    read -r _ans
    case "$_ans" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; exit 0 ;;
    esac
  fi

  printf '%s\n' "$_proposed" > "$_cfg"
  echo "Wrote $_cfg"
}

