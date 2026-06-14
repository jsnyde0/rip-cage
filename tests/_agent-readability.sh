#!/usr/bin/env bash
# _agent-readability.sh — pure classification helpers for agent *.md file checks.
#
# Sourced by test-skills.sh (in-cage check #10) and test-agent-readability.sh
# (host-side fixture test).  No side effects on source; only function definitions.
#
# Public API:
#   _normalize_path PATH [BASE_DIR]
#       Returns an absolute, lexically-normalized path WITHOUT requiring the
#       path to exist.  Pure-bash — works on both BSD (macOS) and GNU coreutils.
#       If PATH is relative and BASE_DIR is supplied, resolves relative to BASE_DIR.
#
#   _classify_agent_file PATH CAGE_ROOTS
#       Classifies a single *.md agent file into one of:
#         readable  — symlink chain resolves to a readable file → counts toward PASS
#         hostonly  — broken symlink whose resolved target lies OUTSIDE all cage roots → SKIP
#         corrupt   — broken symlink whose resolved target lies INSIDE a cage root,
#                     or an unreadable non-symlink file → FAIL
#       CAGE_ROOTS is colon-separated list of absolute paths.
#       Prints the classification string to stdout.
#
#   _report_agents_classification AGENTS_DIR CAGE_ROOTS
#       Classifies all *.md files in AGENTS_DIR, then emits check() calls:
#         - 0 total files  → one FAIL ("0 .md files in agents dir")
#         - 0 corrupt, readable+hostonly > 0 → one PASS summary line
#         - corrupt > 0, readable+hostonly > 0 → one PASS summary + one FAIL per corrupt
#         - corrupt > 0, readable+hostonly == 0 → one FAIL per corrupt (no phantom PASS)
#       Relies on check() being defined in the caller's scope (same sourcing pattern
#       as _classify_agents_dir).
#       Sets _CAD_READABLE, _CAD_HOSTONLY, _CAD_CORRUPT in the caller's scope.

# Guard: do not run this file directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Error: _agent-readability.sh is a helper library; source it, don't run it." >&2
  exit 1
fi

# _normalize_path PATH [BASE_DIR]
# Pure-bash lexical normalization.  Resolves /../ and /./ without needing the
# path to exist (BSD realpath -m is unavailable; readlink -f fails on missing paths
# on both BSD and GNU when the path doesn't exist).
_normalize_path() {
  local p="$1"
  local base="${2:-}"

  # Make absolute: if relative and base provided, prepend base
  if [[ "$p" != /* ]]; then
    if [[ -n "$base" ]]; then
      p="${base}/${p}"
    else
      p="${PWD}/${p}"
    fi
  fi

  # Collapse /../ and /./ by reading each component
  local result=""
  local part
  while IFS= read -r -d '/' part; do
    case "$part" in
      ""|".")
        ;;
      "..")
        result="${result%/*}"
        ;;
      *)
        result="${result}/${part}"
        ;;
    esac
  done <<< "${p}/"

  # Ensure we always return at least "/"
  echo "/${result#/}"
}

# _classify_agent_file PATH CAGE_ROOTS
# CAGE_ROOTS: colon-separated absolute paths that are "resident" in this cage.
# Default roots are /workspace and the realpath of the agents staging dir.
_classify_agent_file() {
  local file_path="$1"
  local cage_roots="$2"

  # 1. Readable → done
  if [[ -r "$file_path" ]]; then
    echo "readable"
    return 0
  fi

  # 2. Not readable. Is it a symlink?
  if [[ ! -L "$file_path" ]]; then
    # Plain file that is unreadable (permissions) or missing — corrupt
    echo "corrupt"
    return 0
  fi

  # 3. Broken symlink — get the raw target
  local raw_target
  raw_target=$(readlink "$file_path")

  # Make the target absolute (relative symlinks are resolved relative to link dir)
  local link_dir
  link_dir=$(dirname "$file_path")
  local abs_target
  abs_target=$(_normalize_path "$raw_target" "$link_dir")

  # 4. Check if the target falls under any cage resident root.
  # Iterate over colon-separated roots without subshells or IFS clobbering.
  local root_item
  local roots_remaining="${cage_roots}:"
  while [[ -n "$roots_remaining" ]]; do
    root_item="${roots_remaining%%:*}"
    roots_remaining="${roots_remaining#*:}"
    [[ -z "$root_item" ]] && continue
    local norm_root
    norm_root=$(_normalize_path "$root_item" "")
    # Prefix check: abs_target starts with norm_root/ or equals norm_root
    if [[ "$abs_target" == "${norm_root}/"* || "$abs_target" == "$norm_root" ]]; then
      echo "corrupt"
      return 0
    fi
  done

  # 5. Target is outside all cage roots — host-only broken symlink
  echo "hostonly"
  return 0
}

# _classify_agents_dir AGENTS_DIR CAGE_ROOTS
# Classifies all *.md files in AGENTS_DIR using _classify_agent_file.
# Sets three variables in the caller's scope:
#   _CAD_READABLE   — count of readable files
#   _CAD_HOSTONLY   — count of host-only broken symlinks
#   _CAD_CORRUPT    — count of genuinely corrupt files
_classify_agents_dir() {
  local agents_dir="$1"
  local cage_roots="$2"

  _CAD_READABLE=0
  _CAD_HOSTONLY=0
  _CAD_CORRUPT=0

  local f classification
  while IFS= read -r f; do
    classification=$(_classify_agent_file "$f" "$cage_roots")
    case "$classification" in
      readable) _CAD_READABLE=$((_CAD_READABLE + 1)) ;;
      hostonly) _CAD_HOSTONLY=$((_CAD_HOSTONLY + 1)) ;;
      corrupt)  _CAD_CORRUPT=$((_CAD_CORRUPT + 1)) ;;
    esac
  done < <(find -L "$agents_dir" -maxdepth 1 -name '*.md' 2>/dev/null)
}

# _report_agents_classification AGENTS_DIR CAGE_ROOTS
# Classifies all *.md files then emits check() calls to report the results.
# Requires check() to be defined in the caller's scope.
# Sets _CAD_READABLE, _CAD_HOSTONLY, _CAD_CORRUPT in the caller's scope.
#
# Behavior:
#   0 total files                      → one FAIL ("0 .md files in agents dir")
#   0 corrupt, readable+hostonly > 0   → one PASS summary line
#   corrupt > 0, readable+hostonly > 0 → one PASS summary + one FAIL per corrupt
#   corrupt > 0, readable+hostonly == 0 → one FAIL per corrupt (no phantom PASS)
_report_agents_classification() {
  local agents_dir="$1"
  local cage_roots="$2"

  _classify_agents_dir "$agents_dir" "$cage_roots"

  local total_agents
  total_agents=$((_CAD_READABLE + _CAD_HOSTONLY + _CAD_CORRUPT))

  if [[ "$total_agents" -eq 0 ]]; then
    check "Agent .md files readable (symlinks resolve)" "fail" "0 .md files in agents dir"
    return
  fi

  if [[ "$_CAD_CORRUPT" -eq 0 ]]; then
    # All files are either readable or host-only skipped — PASS
    check "Agent .md files readable (symlinks resolve)" "pass" \
      "${_CAD_READABLE} readable, ${_CAD_HOSTONLY} host-only skipped (of ${total_agents} total)"
    return
  fi

  # At least one genuinely corrupt entry.
  # Only emit the summary PASS when there is something passing to report.
  if [[ "$((_CAD_READABLE + _CAD_HOSTONLY))" -gt 0 ]]; then
    check "Agent .md files readable (symlinks resolve)" "pass" \
      "${_CAD_READABLE} readable, ${_CAD_HOSTONLY} host-only skipped (of ${total_agents} total)"
  fi

  # Emit one FAIL per corrupt entry.
  local _c=0
  local _f
  while IFS= read -r _f; do
    local _cls
    _cls=$(_classify_agent_file "$_f" "$cage_roots")
    if [[ "$_cls" == "corrupt" ]]; then
      _c=$((_c + 1))
      check "Agent .md file corrupt [${_c}]: $(basename "$_f")" "fail" \
        "broken symlink with target inside cage roots (or unreadable file)"
    fi
  done < <(find -L "$agents_dir" -maxdepth 1 -name '*.md' 2>/dev/null)
}
