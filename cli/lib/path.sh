#!/usr/bin/env bash
# cli/lib/path.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# validate_path RAW_PATH
#
# Shape check on a path argument: no control characters, exists, is a
# directory. Publishes the resolved path as VALIDATED_PATH.
#
# THE ALLOWED-ROOTS GUARD IS GONE (ADR-031 D2, ADR-003 D3 evolved in place).
# It existed to stop `rc up` being pointed at a surprising directory back when
# `rc` assembled the mount set itself from flags and a layered config. Every
# mount is now an explicit line in the project's own msb config file, authored
# host-side outside every cage mount, so there is no longer a surprising
# directory for the guard to catch — and the mount-side floor that DOES still
# matter is the protected-paths rule (cli/lib/protected_paths.sh), which reads
# the real mount list rather than one path argument.
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

  # Return resolved path via VALIDATED_PATH global -- read by callers in
  # other modules (e.g. cli/up.sh), which shellcheck can't see from here.
  # shellcheck disable=SC2034
  VALIDATED_PATH="$resolved"
}


# THE SECRET-PATH DENYLIST MOVED (ADR-023 D2, evolved in place by ADR-031 D2).
# _check_secret_path_denylist and _secret_path_denylist_matched_pattern used to
# pattern-match ONE path argument against a denylist read out of the layered
# rip-cage config, and they failed OPEN when that config could not be loaded.
# Both properties are gone. The rule now reads the cage's own mount list, covers
# what it finds rather than only refusing, and fails CLOSED when its list is
# unreadable: see cli/lib/protected_paths.sh.


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
# from matching /home/agent.
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

