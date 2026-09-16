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


# _lexical_normalize_path, _manifest_dest_in_allowed_roots and
# _host_source_is_root_owned went with the tools manifest (ADR-031 D4). All
# three existed to police manifest-declared mount destinations: normalize the
# dest, check it landed in agent-writable space, and grant a root-owned
# carve-out. Mounts are the cage config's own now, where the protected-paths
# rule in rc up is the check that matters, so there is no declared dest left to
# normalize (rip-cage-ely4.11).

