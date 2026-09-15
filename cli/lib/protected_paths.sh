#!/usr/bin/env bash
# cli/lib/protected_paths.sh -- the mount-side containment floor (ADR-031 D2,
# D5(a) and D5(d); ADR-023 D2 evolved in place, D3's single-layer timing kept).
#
# THE RULE, in one paragraph. `rc up` reads a plain list of protected path
# names and, for the cage config it is about to launch: (a) REFUSES to launch a
# config that mounts a listed path directly; (b) AUTO-COVERS a listed path
# found inside a mounted tree -- an empty read-only file mount over a file, an
# empty tmpfs mount over a directory -- so the guest sees the name and none of
# the content; (c) ABORTS before any msb call if the list file is unreadable.
# If a cover cannot be expressed for an entry, `rc up` refuses rather than
# launching uncovered. Fail closed, never fail open. There is no opt-out.
#
# WHERE THE LIST LIVES (ADR-031 D5(a), amended 2026-09-15 by rip-cage-ely4.9).
# The list file is a COMPOSITION INPUT alongside the Dockerfile, the boot
# descriptor and the msb config: it is read from rc's own install or the
# operator's host config directory, and NEVER from a path inside a cage mount.
# A caged agent that could edit the list could delete the line protecting the
# thing it wants, which would make the floor self-serve.
#
# WHAT THIS IS NOT. A cover is a VISIBILITY default, not a boundary: an
# in-guest root can `umount` a covered directory in one command and read the
# host content underneath, and rip-cage's agent has passwordless sudo
# (measured on msb 0.6.18, spike rip-cage-ely4.16 Q7). That is the cage's
# blast-radius posture, stated rather than papered over -- this layer stops the
# accident and the injected instruction, not the motivated attacker.
#
# Bash 3.2 compatible (ADR-008 D5): no associative arrays, no mapfile.

# --------------------------------------------------------------------------
# Dependencies. yq reads the native msb config; jq normalizes its mount list.
# --------------------------------------------------------------------------
_protected_paths_check_deps() {
  if ! command -v yq &>/dev/null; then
    echo "Error: yq not found on PATH. yq reads the native msb cage config — install it: brew install yq (macOS) or the mikefarah/yq release binary (Linux: https://github.com/mikefarah/yq/releases) — NOT apt's yq, which is the incompatible python-yq." >&2
    return 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "Error: jq not found on PATH. jq normalizes the cage config's mount list — install it: brew install jq (macOS) or your distro's jq package." >&2
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------
# _protected_paths_resolve
#
# Echo the path of the list file rc will read. Precedence, first hit wins:
#   1. $RC_PROTECTED_PATHS          -- explicit override (tests, operators)
#   2. $XDG_CONFIG_HOME/rip-cage/protected-paths (default ~/.config/...)
#   3. <rc install dir>/share/rip-cage/protected-paths -- the shipped default
#
# Fail-closed shape: an EXPLICIT override that does not exist is an error, not
# a fall-through to the shipped default. Pointing rc at a list and silently
# getting a different one is the quiet failure this whole module exists to
# prevent.
# --------------------------------------------------------------------------
_protected_paths_resolve() {
  if [[ -n "${RC_PROTECTED_PATHS:-}" ]]; then
    if [[ ! -e "${RC_PROTECTED_PATHS}" ]]; then
      echo "Error: RC_PROTECTED_PATHS names '${RC_PROTECTED_PATHS}', which does not exist. Refusing to launch: an explicit protected-paths override must resolve, and falling back to the shipped default would silently apply a list you did not ask for." >&2
      return 1
    fi
    printf '%s\n' "${RC_PROTECTED_PATHS}"
    return 0
  fi

  local _operator="${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage/protected-paths"
  if [[ -e "${_operator}" ]]; then
    printf '%s\n' "${_operator}"
    return 0
  fi

  local _shipped="${SCRIPT_DIR}/share/rip-cage/protected-paths"
  if [[ -e "${_shipped}" ]]; then
    printf '%s\n' "${_shipped}"
    return 0
  fi

  echo "Error: no protected-paths list found. Looked at \$RC_PROTECTED_PATHS, ${_operator}, and the shipped default ${_shipped}. Refusing to launch: rip-cage will not start a cage with the mount-side floor absent (ADR-031 D2)." >&2
  return 1
}

# --------------------------------------------------------------------------
# _protected_paths_load
#
# Echo one protected name per line, comments and blanks stripped. Aborts (and
# says why) when the file is unreadable or carries no entries.
#
# An EMPTY readable list is refused on purpose. ADR-031 D2 gives the rule no
# opt-out, so a zero-entry list is an opt-out spelled sideways -- if it were
# accepted, blanking the file would be the disable switch the decision says
# does not exist.
# --------------------------------------------------------------------------
_protected_paths_load() {
  local _file
  _file="$(_protected_paths_resolve)" || return 1

  if [[ ! -r "${_file}" ]]; then
    echo "Error: the protected-paths list at ${_file} exists but is not readable. Refusing to launch before any msb call — rip-cage will not start a cage while the mount-side floor cannot be read (ADR-031 D2c). Fix the file's permissions, or point \$RC_PROTECTED_PATHS at a readable copy." >&2
    return 1
  fi

  local _entries
  _entries="$(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${_file}" | grep -v '^$' || true)"

  if [[ -z "${_entries}" ]]; then
    echo "Error: the protected-paths list at ${_file} has no entries. Refusing to launch — an empty list is an opt-out, and the mount-side floor has none (ADR-031 D2). Restore the entries, or point \$RC_PROTECTED_PATHS at a populated list." >&2
    return 1
  fi

  printf '%s\n' "${_entries}"
}

# --------------------------------------------------------------------------
# _protected_paths_path_match PATH
#
# If any COMPONENT of PATH equals a protected entry, echo that entry and
# return 0; otherwise echo nothing and return 1. Matching is component-equals,
# never substring (ADR-023 D4's rule, kept).
#
# This is the single-path form, for the generated mounts rc computes from the
# host filesystem rather than reads from the cage config -- today, the
# read-only parent mounts behind a symlinked skill or agent. Those keep
# ADR-023 D6's warn-and-skip treatment: they are a best-effort decoration
# surface, so a protected parent drops out of the mount set with a warning
# rather than failing the launch. The config's own mount list is the strict
# surface; that is _protected_paths_enforce.
# --------------------------------------------------------------------------
_protected_paths_path_match() {
  local _path="$1"
  local _entries _entry _component
  _entries="$(_protected_paths_load)" || return 1

  while IFS= read -r _entry; do
    [[ -z "${_entry}" ]] && continue
    local _oldifs="$IFS"
    IFS='/'
    # shellcheck disable=SC2206
    local -a _parts=(${_path})
    IFS="$_oldifs"
    for _component in "${_parts[@]}"; do
      if [[ "${_component}" == "${_entry}" ]]; then
        printf '%s' "${_entry}"
        return 0
      fi
    done
  done <<< "${_entries}"
  return 1
}

# --------------------------------------------------------------------------
# _protected_paths_conf_bind_mounts CONF_FILE
#
# Echo one TAB-separated "HOST<TAB>GUEST" row per BIND mount declared in the
# native msb config. Both declaration forms are read:
#   - string form: "HOST:GUEST[:opts]"
#   - map form:    { bind: HOST, target: GUEST, ... }
# Named-volume and tmpfs entries have no host path, so they carry nothing to
# protect and are skipped.
# --------------------------------------------------------------------------
_protected_paths_conf_bind_mounts() {
  local _conf="$1"
  local _json
  if ! _json="$(yq -o=json '.mounts // []' "${_conf}" 2>&1)"; then
    echo "Error: could not parse the mounts list in the cage config ${_conf}: ${_json}" >&2
    return 1
  fi

  # Both forms are normalized in jq rather than in shell: the string form's
  # trailing option field is stripped first, so the split never mistakes ":ro"
  # for a guest path.
  printf '%s\n' "${_json}" | jq -r '
    .[]?
    | if type == "string" then
        (sub(":(ro|rw)$"; "")) as $t
        | [ ($t | split(":")[0]), ($t | split(":")[1:] | join(":")) ]
      elif type == "object" and (.bind // null) != null then
        [ .bind, (.target // "") ]
      else empty end
    | select(.[0] != "" and .[1] != "")
    | @tsv
  '
}

# --------------------------------------------------------------------------
# _protected_paths_conf_outside_mounts CONF_FILE
#
# Refuse (non-zero, reason on stderr) when the cage config file itself resolves
# INSIDE one of the trees it mounts. ADR-031 D5(a): the composition inputs are
# authored where the caged agent cannot reach them. A config that mounts its own
# directory hands the agent inside the cage an edit on the file that decides
# what the next cage mounts -- which makes every other rule here advisory.
#
# The protected-paths LIST FILE is the fourth D5(a) input and gets the same
# treatment structurally rather than by a check: _protected_paths_resolve only
# ever looks at rc's own install directory or the operator's host config
# directory, never at a path derived from the cage config.
# --------------------------------------------------------------------------
_protected_paths_conf_outside_mounts() {
  local _conf="$1"
  local _conf_real
  _conf_real="$(cd "$(dirname "${_conf}")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "${_conf}")")" || _conf_real="${_conf}"

  local _mounts _host _guest _host_real
  _mounts="$(_protected_paths_conf_bind_mounts "${_conf}")" || return 1
  [[ -z "${_mounts}" ]] && return 0

  while IFS=$'\t' read -r _host _guest; do
    [[ -z "${_host}" ]] && continue
    _host_real="$(cd "${_host}" 2>/dev/null && pwd -P)" || continue
    if [[ "${_conf_real}" == "${_host_real}" || "${_conf_real}" == "${_host_real}"/* ]]; then
      echo "Error: the cage config ${_conf} sits inside ${_host}, which that same config mounts into the cage. Refusing to launch before any msb call: an agent inside the cage could edit the file that decides what the next cage mounts (ADR-031 D5(a)). Move the config to ${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage/projects/ and point rc at it there." >&2
      return 1
    fi
  done <<< "${_mounts}"
  return 0
}

# --------------------------------------------------------------------------
# _protected_paths_breadcrumb
#
# Echo the path of the rc-owned empty file used as a read-only cover over a
# protected FILE. One shared breadcrumb serves every cover: it carries no
# content by definition, so there is nothing to keep apart.
# --------------------------------------------------------------------------
_protected_paths_breadcrumb() {
  local _dir="${HOME}/.cache/rc"
  local _file="${_dir}/protected-cover.empty"
  if [[ ! -f "${_file}" ]]; then
    mkdir -p "${_dir}" || {
      echo "Error: could not create ${_dir} for the protected-path cover breadcrumb." >&2
      return 1
    }
    : > "${_file}" || {
      echo "Error: could not create the protected-path cover breadcrumb at ${_file}." >&2
      return 1
    }
    chmod 0444 "${_file}" 2>/dev/null || true
  fi
  printf '%s\n' "${_file}"
}

# --------------------------------------------------------------------------
# _protected_paths_enforce CONF_FILE
#
# The whole rule, run once per `rc up` before any msb call. Prints the cover
# flags it generated to STDOUT, one msb argv token per line (the same
# one-token-per-line contract _msb_flags_generate uses). Returns non-zero,
# with the reason on stderr, on any refusal.
#
# SCAN DEPTH. Leg (b) walks each mounted tree to $RC_PROTECTED_SCAN_DEPTH
# (default 2) -- deep enough for a credential at a project root or one level
# into a monorepo package, shallow enough that mounting a large tree does not
# stall every launch. This is a latency tradeoff, stated rather than implied:
# it is not a claim of exhaustive reach.
# --------------------------------------------------------------------------
_protected_paths_enforce() {
  local _conf="$1"
  local _depth="${RC_PROTECTED_SCAN_DEPTH:-2}"

  _protected_paths_check_deps || return 1

  local _entries
  _entries="$(_protected_paths_load)" || return 1

  local _mounts
  _mounts="$(_protected_paths_conf_bind_mounts "${_conf}")" || return 1
  [[ -z "${_mounts}" ]] && return 0

  # Build the find expression once: -name a -o -name b -o ...
  local -a _find_expr=()
  local _entry
  while IFS= read -r _entry; do
    [[ -z "${_entry}" ]] && continue
    if [[ ${#_find_expr[@]} -gt 0 ]]; then _find_expr+=(-o); fi
    _find_expr+=(-name "${_entry}")
  done <<< "${_entries}"

  local _breadcrumb=""
  local _host _guest _real _component _found _rel _guest_target
  local -a _covers=()

  while IFS=$'\t' read -r _host _guest; do
    [[ -z "${_host}" ]] && continue

    # --- (a) refuse a DIRECT mount of a listed path ------------------------
    # Component-equals against the resolved host path, so a symlink pointing
    # at ~/.ssh is caught as surely as the literal path. rc refuses before any
    # msb call, and the message never echoes the mount's contents.
    _real="$(cd "$(dirname "${_host}")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "${_host}")")" || _real="${_host}"
    while IFS= read -r _entry; do
      [[ -z "${_entry}" ]] && continue
      local _oldifs="$IFS"
      IFS='/'
      # shellcheck disable=SC2206
      local -a _parts=(${_real})
      IFS="$_oldifs"
      for _component in "${_parts[@]}"; do
        if [[ "${_component}" == "${_entry}" ]]; then
          echo "Error: the cage config ${_conf} mounts ${_host}, which is a protected path ('${_entry}' — see the protected-paths list). Refusing to launch before any msb call: rip-cage does not show a credential store into a cage (ADR-031 D2a). Remove that mount line, or remove '${_entry}' from your protected-paths list if you have decided it is not a secret." >&2
          return 1
        fi
      done
    done <<< "${_entries}"

    # --- (b) AUTO-COVER a listed path found inside the tree ----------------
    [[ ! -d "${_host}" ]] && continue

    # A directory cover already hides everything beneath it, so a second cover
    # for a listed path INSIDE it is both redundant and broken: its target sits
    # under a tmpfs msb has just created, and mounting into that tmpfs aborts
    # the boot. Findings are walked parent-first (sort) so an ancestor's cover
    # is always recorded before its children are considered.
    local -a _dir_covered=()
    local _ancestor _skip

    while IFS= read -r _found; do
      [[ -z "${_found}" ]] && continue
      _rel="${_found#"${_host}"/}"
      [[ "${_rel}" == "${_found}" ]] && continue   # not under the mount; skip

      _skip=false
      for _ancestor in ${_dir_covered[@]+"${_dir_covered[@]}"}; do
        if [[ "${_found}" == "${_ancestor}"/* ]]; then _skip=true; break; fi
      done
      [[ "${_skip}" == "true" ]] && continue

      _guest_target="${_guest%/}/${_rel}"

      if [[ -d "${_found}" ]]; then
        # A directory reads empty under a tmpfs; siblings stay visible.
        _covers+=(--tmpfs "${_guest_target}")
        _dir_covered+=("${_found}")
      elif [[ -f "${_found}" ]]; then
        # A regular file is shadowed by an empty read-only file mount. A tmpfs
        # cannot do this job: msb creates a tmpfs target as a DIRECTORY, so a
        # tmpfs over an existing file aborts the boot (measured, ely4.16 Q7).
        if [[ -z "${_breadcrumb}" ]]; then
          _breadcrumb="$(_protected_paths_breadcrumb)" || return 1
        fi
        _covers+=(--mount-file "${_breadcrumb}:${_guest_target}:ro")
      else
        # Socket, fifo, device: msb has no cover primitive for these, and
        # leaving it uncovered would be failing open.
        echo "Error: the cage config ${_conf} mounts ${_host}, which contains the protected path ${_found} — and that is neither a regular file nor a directory, so msb has no mount that can cover it. Refusing to launch rather than leaving it exposed (ADR-031 D2, fail closed). Move it out of the mounted tree, or narrow the mount." >&2
        return 1
      fi
    done < <(find "${_host}" -maxdepth "${_depth}" \( "${_find_expr[@]}" \) -print 2>/dev/null | LC_ALL=C sort)
  done <<< "${_mounts}"

  if [[ ${#_covers[@]} -gt 0 ]]; then
    printf '%s\n' "${_covers[@]}"
  fi
  return 0
}
