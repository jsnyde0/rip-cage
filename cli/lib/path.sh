#!/usr/bin/env bash
# cli/lib/path.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# _path_under_allowed_roots RESOLVED_PATH
# Returns 0 (true) if RESOLVED_PATH is under one of the RC_ALLOWED_ROOTS, 1 otherwise.
# IMPORTANT: Match exact root OR root/ prefix to prevent /code matching /code-evil.
_path_under_allowed_roots() {
  local _resolved="$1"
  local IFS=':'
  local root resolved_root
  for root in ${RC_ALLOWED_ROOTS:-}; do
    resolved_root=$(realpath "$root" 2>/dev/null) || continue
    if [[ "$_resolved" == "$resolved_root" ]] || [[ "$_resolved" == "$resolved_root"/* ]]; then
      return 0
    fi
  done
  return 1
}


validate_path() {
  local raw_path="$1"

  # Reject control characters. Null bytes can't survive bash arg passing,
  # but we check the visible range using POSIX character class.
  if [[ "$raw_path" =~ [[:cntrl:]] ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Path contains invalid characters" "PATH_INVALID"
    echo "Error: path contains control characters" >&2
    exit 1
  fi

  # Must resolve to existing directory (realpath follows symlinks -- security-critical per ADR)
  # Explicit existence check first: GNU realpath resolves non-existent paths,
  # unlike BSD realpath which fails. The -e check covers both platforms.
  local resolved
  if [[ ! -e "$raw_path" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Path does not exist: $raw_path" "PATH_NOT_FOUND"
    echo "Error: $raw_path does not exist" >&2
    exit 1
  fi
  if ! resolved=$(realpath "$raw_path" 2>/dev/null); then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Path does not exist: $raw_path" "PATH_NOT_FOUND"
    echo "Error: $raw_path does not exist" >&2
    exit 1
  fi

  if [[ ! -d "$resolved" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Not a directory: $resolved" "PATH_INVALID"
    echo "Error: $resolved is not a directory" >&2
    exit 1
  fi

  # Check RC_ALLOWED_ROOTS is set
  if [[ -z "${RC_ALLOWED_ROOTS:-}" ]]; then
    if [[ -t 0 ]] && [[ "$OUTPUT_FORMAT" != "json" ]]; then
      # Interactive: prompt user, write rc.conf, continue
      local _home
      _home="$(realpath "$HOME")"
      local _chosen=""
      local _input=""
      local _attempts=0
      while [[ $_attempts -lt 3 ]]; do
        _attempts=$((_attempts + 1))
        printf "rip-cage: no allowed roots configured.\nAllow projects under [%s]: " "$_home" >&2
        read -r _input
        _chosen="${_input:-$_home}"
        if [[ -d "$_chosen" ]]; then
          _chosen="$(realpath "$_chosen")"
          break
        else
          printf "rip-cage: '%s' does not exist or is not a directory. Use a full absolute path.\n" "$_chosen" >&2
          _chosen=""
        fi
      done
      if [[ -z "$_chosen" ]]; then
        echo "Error: no valid allowed root provided after 3 attempts" >&2
        exit 1
      fi
      mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/rip-cage"
      local _conf="${XDG_CONFIG_HOME:-$HOME/.config}/rip-cage/rc.conf"
      # shellcheck disable=SC2016  # literal ${RC_ALLOWED_ROOTS:-...} written to config file
      printf 'RC_ALLOWED_ROOTS="${RC_ALLOWED_ROOTS:-%s}"\n' "$_chosen" >> "$_conf"
      RC_ALLOWED_ROOTS="$_chosen"
    else
      # Non-interactive (no TTY or --output json): minimum grant for this path only
      local _warn_msg="RC_ALLOWED_ROOTS unset — allowing $resolved only."
      echo "Warning: $_warn_msg" >&2
      echo "Set RC_ALLOWED_ROOTS in ~/.config/rip-cage/rc.conf for permanent access." >&2
      RC_ALLOWED_ROOTS="$resolved"
      RC_VALIDATE_WARNING="${RC_VALIDATE_WARNING:-}${RC_VALIDATE_WARNING:+ }$_warn_msg"
    fi
  fi

  # Check path is under an allowed root
  if ! _path_under_allowed_roots "$resolved"; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Path resolves outside allowed roots" "PATH_INVALID"
    echo "Error: $resolved is outside allowed roots ($RC_ALLOWED_ROOTS)" >&2
    exit 1
  fi

  # Return resolved path via VALIDATED_PATH global -- read by callers in
  # other modules (e.g. cli/up.sh), which shellcheck can't see from here.
  # shellcheck disable=SC2034
  VALIDATED_PATH="$resolved"
}


# _check_secret_path_denylist <resolved-path> [workspace]
#
# Returns 0 (deny) when any component of RESOLVED_PATH (split on '/') exactly
# equals a pattern in the effective mounts.denylist AND the path is NOT present
# in mounts.allow_risky AND NOT present in RC_ALLOW_RISKY_MOUNT array.
# Returns 1 (allow) otherwise.
#
# Matching is component-equals, NOT substring — per ADR-023 D4.
# WORKSPACE defaults to '.' (current directory) when not supplied.
#
# Globals read (optional):
#   RC_ALLOW_RISKY_MOUNT  — bash array of literal resolved paths to allow
#                           despite denylist match (populated by --allow-risky-mount)
_check_secret_path_denylist() {
  local resolved_path="$1"
  local workspace="${2:-.}"

  # Load effective config for denylist + allow_risky.
  local eff_json
  if ! eff_json=$(_load_effective_config "$workspace" 2>/dev/null); then
    # Config load failed (e.g. yq missing) — fail open (allow).
    return 1
  fi

  # Extract effective denylist as newline-separated patterns.
  local denylist_json
  denylist_json=$(jq -r '.config.mounts.denylist // [] | .[]' <<<"$eff_json" 2>/dev/null)

  # Empty denylist → allow.
  if [[ -z "$denylist_json" ]]; then
    return 1
  fi

  # Check RC_ALLOW_RISKY_MOUNT (in-process array bypass).
  if [[ -n "${RC_ALLOW_RISKY_MOUNT+set}" ]] && (( ${#RC_ALLOW_RISKY_MOUNT[@]} > 0 )); then
    local arm_entry
    for arm_entry in "${RC_ALLOW_RISKY_MOUNT[@]}"; do
      if [[ "$arm_entry" == "$resolved_path" ]]; then
        return 1
      fi
    done
  fi

  # Check mounts.allow_risky (config bypass).
  local allow_risky_list
  allow_risky_list=$(jq -r '.config.mounts.allow_risky // [] | .[]' <<<"$eff_json" 2>/dev/null)
  if [[ -n "$allow_risky_list" ]]; then
    local ar_entry
    while IFS= read -r ar_entry; do
      [[ -z "$ar_entry" ]] && continue
      if [[ "$ar_entry" == "$resolved_path" ]]; then
        return 1
      fi
    done <<<"$allow_risky_list"
  fi

  # Component-equals matching: split resolved path on '/' and check each component.
  local pattern
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    # Split path on '/' and check each component.
    local component
    local IFS='/'
    for component in $resolved_path; do
      [[ -z "$component" ]] && continue
      if [[ "$component" == "$pattern" ]]; then
        return 0
      fi
    done
  done <<<"$denylist_json"

  return 1
}


# _secret_path_denylist_matched_pattern <resolved-path> [workspace]
#
# If _check_secret_path_denylist would deny RESOLVED_PATH, emit the first
# matching pattern on stdout. If no match, emit nothing and return 1.
# Used by call sites that need the pattern name for the D6 error message.
#
# WORKSPACE defaults to '.' when not supplied.
_secret_path_denylist_matched_pattern() {
  local resolved_path="$1"
  local workspace="${2:-.}"

  local eff_json
  if ! eff_json=$(_load_effective_config "$workspace" 2>/dev/null); then
    return 1
  fi

  local denylist_json
  denylist_json=$(jq -r '.config.mounts.denylist // [] | .[]' <<<"$eff_json" 2>/dev/null)
  [[ -z "$denylist_json" ]] && return 1

  local pattern
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    local component
    local IFS='/'
    for component in $resolved_path; do
      [[ -z "$component" ]] && continue
      if [[ "$component" == "$pattern" ]]; then
        printf '%s' "$pattern"
        return 0
      fi
    done
  done <<<"$denylist_json"

  return 1
}


# _lexical_normalize_path PATH
#
# Lexically normalize an absolute CONTAINER path by collapsing '..' and '.'
# components and stripping double-slashes and trailing slashes.
# This is a pure string operation — it does NOT call realpath or touch the
# host filesystem (container paths are not resolvable on the host).
#
# Used by the manifest dest-allowlist check (rip-cage-rc09) to prevent
# '..' escape attacks such as /home/agent/../etc/rip-cage/pi → /etc/rip-cage/pi.
#
# Inputs:  $1  raw_path — an absolute container path (must start with /)
# Stdout:  normalized absolute path (no trailing slash; root "/" is preserved)
_lexical_normalize_path() {
  local raw_path="$1"
  # Build a stack of path components; ".." pops the top.
  local _oldIFS="$IFS"
  IFS="/"
  local _parts=()
  read -ra _parts <<< "$raw_path"
  IFS="$_oldIFS"
  local _stack=() _slen=0 _c
  for _c in "${_parts[@]}"; do
    case "$_c" in
      ""|".")  ;;
      "..")
        if [[ $_slen -gt 0 ]]; then
          _stack=("${_stack[@]:0:$((_slen - 1))}")
          _slen=$((_slen - 1))
        fi
        ;;
      *)
        _stack[_slen]="$_c"
        _slen=$((_slen + 1))
        ;;
    esac
  done
  # Reconstruct normalized path from stack.
  local _norm="/"
  local _i
  for (( _i = 0; _i < _slen; _i++ )); do
    _norm="${_norm}${_stack[$_i]}/"
  done
  # Strip trailing slash (except bare root "/").
  if [[ "$_norm" != "/" ]]; then
    _norm="${_norm%/}"
  fi
  echo "$_norm"
}


# _manifest_dest_in_allowed_roots NORMALIZED_DEST
#
# Returns 0 (true) if NORMALIZED_DEST is exactly or nested under one of the
# agent-writable allowlist roots: /home/agent or /workspace.
# Uses boundary-safe prefix matching (== or prefix/*) to prevent /home/agentEVIL
# from matching /home/agent (reuses the same logic as _path_under_allowed_roots).
#
# Called by manifest dest-allowlist checks (rip-cage-rc09).
_manifest_dest_in_allowed_roots() {
  local _dest="$1"
  local _allowed_root
  for _allowed_root in /home/agent /workspace; do
    if [[ "$_dest" == "$_allowed_root" ]] || [[ "$_dest" == "$_allowed_root"/* ]]; then
      return 0
    fi
  done
  return 1
}


# _host_source_is_root_owned PATH
#
# Returns 0 (true) if the HOST-SIDE directory at PATH is:
#   - owned by uid 0 (root), AND
#   - not group-writable and not other-writable (mode bit check).
# Returns 1 (false) if any of those conditions fail, or if the path cannot be
# stat'd (fail-closed: unknown ownership is treated as NOT root-owned).
#
# This is a PURE HOST-SIDE check — no docker invocation.  The path must exist
# on the host filesystem.  Used by the root_owned_required carve-out gate in
# _manifest_check_mounts_denylist and _manifest_build_mount_args (rip-cage-rc09).
#
# Cross-platform stat:
#   macOS (BSD): stat -f "%u %p" — %u is numeric UID, %p is full octal (e.g. 40755)
#   Linux (GNU): stat -c "%u %a" — %u is numeric UID, %a is permission octal (e.g. 755)
# Both forms produce last-3-octal-chars as the rwxrwxrwx permission bits.
#
# Threat class: operator-accident (host-only manifest, ADR-024 host-side out of scope).
# A root_owned_required mount where the host SOURCE is NOT root-owned is not exempt
# from the dest-allowlist — the operator may have mis-pointed the flag at an
# agent-writable dir, and the host-uid is the operator (not root), so the exemption
# is NOT earned.  The legit use (a genuinely root-owned host asset mounted to a system
# dest) has host-uid == 0 → exempt.  Cite: rip-cage-rc09 / ADR-027 D1.
_host_source_is_root_owned() {
  local _hsr_path="$1"
  [[ -z "$_hsr_path" ]] && return 1
  [[ ! -d "$_hsr_path" ]] && return 1

  local _hsr_uid _hsr_mode _hsr_stat_out
  # Cross-platform stat: macOS (BSD) vs Linux (GNU).
  if [[ "$(uname)" == "Darwin" ]]; then
    _hsr_stat_out=$(stat -f "%u %p" "$_hsr_path" 2>/dev/null) || return 1
  else
    _hsr_stat_out=$(stat -c "%u %a" "$_hsr_path" 2>/dev/null) || return 1
  fi

  _hsr_uid=$(awk '{print $1}' <<<"$_hsr_stat_out")
  _hsr_mode=$(awk '{print $2}' <<<"$_hsr_stat_out")

  # Must be owned by uid 0 (root).
  [[ "$_hsr_uid" == "0" ]] || return 1

  # Mode: check last 3 octal digits for group-write or other-write bit.
  # (macOS %p may give 6 chars like "40755"; Linux %a gives 3-4 chars like "755".
  #  In both cases, last-3 gives the rwxrwxrwx bits.)
  local _hsr_mode3 _hsr_gbit _hsr_obit
  _hsr_mode3="${_hsr_mode: -3}"
  _hsr_gbit="${_hsr_mode3:1:1}"
  _hsr_obit="${_hsr_mode3:2:1}"
  local _hsr_writable=0
  case "$_hsr_gbit" in 2|3|6|7) _hsr_writable=1 ;; esac
  case "$_hsr_obit" in 2|3|6|7) _hsr_writable=1 ;; esac
  [[ "$_hsr_writable" -eq 0 ]]
}

