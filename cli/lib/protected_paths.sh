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
# launching uncovered -- a listed FILE inside a read-only mount is one such
# case (rip-cage-dnwv). Fail closed, never fail open. There is no opt-out.
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
# Bash 3.2 compatible (ADR-008 D5): no bash-4-only builtins or array types.

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
# Echo one TAB-separated "HOST<TAB>GUEST<TAB>MODE" row per BIND mount declared
# in the native msb config, MODE being "ro" or "rw". Both declaration forms are
# read:
#   - string form: "HOST:GUEST[:opts]"                 (":ro" -> ro)
#   - map form:    { bind: HOST, target: GUEST, ... }   (any readonly value but
#                  absent/false -> ro: "yes" or "true" fail closed, not open)
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
        | [ ($t | split(":")[0]), ($t | split(":")[1:] | join(":")),
            (if test(":ro$") then "ro" else "rw" end) ]
      elif type == "object" and (.bind // null) != null then
        [ .bind, (.target // ""), (if (.readonly // false) != false then "ro" else "rw" end) ]
      else empty end
    | select(.[0] != "" and .[1] != "")
    | @tsv
  '
}

# --------------------------------------------------------------------------
# _protected_paths_secrets_dir
#
# Echo the CCTOK secrets directory path ($XDG_CONFIG_HOME/rip-cage/secrets),
# unresolved. The single source of that expression: every refusal/warning
# message that names the directory, and _mount_src_exposes_secrets_dir below,
# all call this rather than repeating the expression, so the path a message
# names and the path the predicate tested can never drift apart.
# --------------------------------------------------------------------------
_protected_paths_secrets_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage/secrets"
}

# --------------------------------------------------------------------------
# _mount_src_exposes_secrets_dir HOST_SRC
#
# ONE predicate for "does mounting HOST_SRC into a cage expose the CCTOK
# secrets directory" ($XDG_CONFIG_HOME/rip-cage/secrets -- the host file msb
# --secret reads the real CCTOK value from, cli/up.sh:_up_prepare_conf_secret_env
# / cli/auth.sh:_auth_cctok_file). True (exit 0) only when BOTH hold:
#   1. The secrets directory EXISTS. A nonexistent directory is always
#      false -- an unresolved fallback path would otherwise prefix-match
#      every ancestor of a directory that has never been created (e.g.
#      refusing an API-key-only user's plain `~/.config` mount for a tool
#      like nvim, naming a directory that isn't even there, with no way
#      past it -- rip-cage-ely4.7.17 fix round 4, the over-broad half of
#      the defect this predicate replaces).
#   2. HOST_SRC, resolved with the same real-path resolution used
#      throughout this file, equals the secrets directory or is an
#      ancestor of it (the secrets directory sits inside the tree
#      HOST_SRC would mount).
#
# Called at EVERY mount site that can expose the secrets dir -- the config's
# own mounts AND every rc-generated mount whose source can resolve to $HOME,
# $XDG_CONFIG_HOME, or an ancestor of either (skill/agent symlink-parent
# mounts, the symlink-follow synthesis mount and pi substrate mounts -- see the
# cli/up.sh call sites; the beads redirect mount is checked through
# _beads_redirect_refusal below). One predicate, one existence
# rule, one ancestor rule: the too-narrow half of the defect this predicate
# replaces was exactly that only the config-mount site had ANY secrets-dir
# check, leaving rc's own generated mounts (e.g. a skill symlink whose target
# lives under $HOME/.config) able to expose the same directory unchecked.
# --------------------------------------------------------------------------
_mount_src_exposes_secrets_dir() {
  local _host_src="$1"
  local _secrets_dir
  _secrets_dir="$(_protected_paths_secrets_dir)"

  # Rule 1: nonexistent secrets dir -> always false, no exceptions.
  [[ -d "${_secrets_dir}" ]] || return 1

  local _secrets_real
  _secrets_real="$(cd "${_secrets_dir}" 2>/dev/null && pwd -P)" || return 1

  # Rule 2: HOST_SRC must itself resolve to an existing directory to be
  # comparable to the secrets dir at all -- a file mount source can never
  # equal or be an ancestor of a directory.
  [[ -n "${_host_src}" ]] || return 1
  local _host_real
  _host_real="$(cd "${_host_src}" 2>/dev/null && pwd -P)" || return 1

  [[ "${_secrets_real}" == "${_host_real}" || "${_secrets_real}" == "${_host_real}"/* ]]
}

# --------------------------------------------------------------------------
# _beads_redirect_refusal RESOLVED_TARGET
#
# The one home of the .beads/redirect refusal rule. RESOLVED_TARGET is the
# realpath of an explicit redirect that resolved to an existing directory.
# Echo why rc refuses to mount it, or nothing when it may be mounted; the
# caller frames the reason (rc up refuses to launch, rc test reports a FAIL
# line). The exit status says which advice fits, so callers test it with
# `reason=$(_beads_redirect_refusal "$t") || status=$?` (rc runs set -e):
#   0  nothing to refuse, nothing echoed;
#   1  not a mountable beads dir -- the caller's "point the redirect at the
#      main repo's .beads, or delete it" advice applies;
#   2  a real beads dir under a protected path -- the reason carries its own
#      advice, because pointing at the main repo's .beads is no fix there.
#
# The target would be mounted READ-WRITE at /workspace/.beads, and the
# redirect file is workspace content (ADR-024), so "../../.claude" must never
# reach host ~/.claude hooks. Checked in this order, first hit wins:
#   1. the realpath carries no control characters (msb argv is one token per
#      line, so a newline would inject mount tokens) -- rip-cage-p4ss.1;
#   2. it is a beads dir: named .beads and holding metadata.json;
#   3. it is not inside a $HOME dotdir, and no ancestor of ~/.claude or ~/.pi;
#   4. no component matches the protected-paths list;
#   5. it does not expose the CCTOK secrets dir (ADR-031 D5(a)).
# --------------------------------------------------------------------------
_beads_redirect_refusal() {
  local _target="$1" _home_real _pat _list
  _home_real=$(realpath "$HOME" 2>/dev/null) || _home_real="$HOME"
  if [[ "$_target" =~ [[:cntrl:]] ]]; then
    echo "its resolved path contains control characters"
  elif [[ "$(basename "$_target")" != ".beads" || ! -f "${_target}/metadata.json" ]]; then
    echo "${_target} is not a .beads dir (needs the name .beads and a metadata.json)"
  elif [[ "$_target" == "${_home_real}"/.* ]]; then
    echo "${_target} is inside a home dotdir"
  elif [[ "${_home_real}/.claude" == "$_target"/* || "${_home_real}/.pi" == "$_target"/* ]]; then
    echo "${_target} is an ancestor of ~/.claude or ~/.pi"
  elif _pat=$(_protected_paths_path_match "$_target"); then
    _list=$(_protected_paths_resolve 2>/dev/null) || _list="your protected-paths list"
    echo "${_target} matched secret-path denylist pattern '${_pat}' in the protected-paths list this run read, ${_list}. If that tree holds no secret, remove or change the '${_pat}' line there; otherwise point the redirect at a .beads outside every protected path, or delete it"
    return 2
  elif _mount_src_exposes_secrets_dir "$_target"; then
    echo "${_target} is or contains $(_protected_paths_secrets_dir) -- the CCTOK secrets directory msb --secret reads the real token value from, which no cage mount may expose (ADR-031 D5(a)). Point the redirect at a .beads that does not contain it, or delete it"
    return 2
  else
    return 0
  fi
  return 1
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
#
# rip-cage-ely4.7.17 fix round 4: the CCTOK secrets directory (the fifth D5(a)
# input) moved OUT of this function into its own
# _protected_paths_conf_secrets_dir_mount below, with its own JSON error code
# (SECRETS_DIR_INSIDE_MOUNT, cli/up.sh) -- fix round 3 folded it in here under
# the shared CAGE_CONFIG_INSIDE_MOUNT code, which meant a caller could not
# tell the two refusals apart. This function is back to checking only the
# config-location case, its original scope.
# --------------------------------------------------------------------------
_protected_paths_conf_outside_mounts() {
  local _conf="$1"
  local _conf_real
  _conf_real="$(cd "$(dirname "${_conf}")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "${_conf}")")" || _conf_real="${_conf}"

  local _mounts _host _guest _mode _host_real
  _mounts="$(_protected_paths_conf_bind_mounts "${_conf}")" || return 1
  [[ -z "${_mounts}" ]] && return 0

  while IFS=$'\t' read -r _host _guest _mode; do
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
# _protected_paths_conf_secrets_dir_mount CONF_FILE
#
# Refuse (non-zero, reason on stderr) when a mount declared in the cage
# config equals or contains the CCTOK secrets directory
# ($XDG_CONFIG_HOME/rip-cage/secrets) -- the fifth D5(a) composition input
# (ADR-031 D5(a); see _mount_src_exposes_secrets_dir above for the predicate
# and the over-broad/too-narrow history it replaces). Own JSON error code
# (SECRETS_DIR_INSIDE_MOUNT, cli/up.sh) -- kept out of
# _protected_paths_conf_outside_mounts's CAGE_CONFIG_INSIDE_MOUNT so a caller
# can tell "the config sits inside its own mount" apart from "a mount exposes
# the secrets dir" (rip-cage-ely4.7.17 fix round 4).
#
# Same before-any-msb-call loop over the config's own mounts as the function
# above; the predicate's own existence check means this returns 0 (no
# refusal) whenever the secrets directory has never been created -- an
# API-key-only user's plain `~/.config` mount is never touched.
# --------------------------------------------------------------------------
_protected_paths_conf_secrets_dir_mount() {
  local _conf="$1"
  local _secrets_dir
  _secrets_dir="$(_protected_paths_secrets_dir)"

  local _mounts _host _guest _mode
  _mounts="$(_protected_paths_conf_bind_mounts "${_conf}")" || return 1
  [[ -z "${_mounts}" ]] && return 0

  while IFS=$'\t' read -r _host _guest _mode; do
    [[ -z "${_host}" ]] && continue
    if _mount_src_exposes_secrets_dir "${_host}"; then
      echo "Error: the cage config ${_conf} mounts ${_host}, which is or contains ${_secrets_dir} -- the CCTOK secrets directory msb --secret reads the real token value from. Refusing to launch before any msb call: mounting it into the cage would hand the guest the same value msb --secret exists to keep non-possessed (ADR-031 D5(a)). Remove that mount line from ${_conf}." >&2
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

  # NAME THE FILE THIS RUN READ in any refusal below (rip-cage-ely4.7.14). The
  # list's location depends on $RC_PROTECTED_PATHS / $XDG_CONFIG_HOME, so
  # "your protected-paths list" alone leaves the operator guessing which of the
  # three candidates rc actually resolved.
  local _list
  _list="$(_protected_paths_resolve 2>/dev/null)" || _list=""

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
  local _host _guest _mode _real _component _found _rel _guest_target
  local -a _covers=()

  while IFS=$'\t' read -r _host _guest _mode; do
    [[ -z "${_host}" ]] && continue

    # Normalise the source's trailing slashes (rip-cage-rsh9.3): leg (b) strips
    # "${_host}/" off each finding, and a source written proj/ or proj// made
    # that pattern never match, so every cover was silently skipped.
    while [[ "${_host}" == */ && "${_host}" != "/" ]]; do _host="${_host%/}"; done
    local _prefix="${_host%/}/"

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
          echo "Error: the cage config ${_conf} mounts ${_host}, which is a protected path ('${_entry}'). Refusing to launch before any msb call: rip-cage does not show a credential store into a cage (ADR-031 D2a). Remove that mount line from ${_conf}, or — if you have decided '${_entry}' is not a secret — remove that line from the protected-paths list this run read: ${_list:-\$RC_PROTECTED_PATHS, \$XDG_CONFIG_HOME/rip-cage/protected-paths, or the copy shipped beside rc}" >&2
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
      _rel="${_found#"${_prefix}"}"
      if [[ "${_rel}" == "${_found}" ]]; then
        # find walked ${_host}, so every finding is under it. A strip failure
        # means the cover target is unknown: refuse, never skip (fail closed).
        echo "Error: the cage config ${_conf} mounts ${_host}, and rc found the protected path ${_found} but could not place it under that mount to cover it. Refusing to launch rather than leaving it exposed (ADR-031 D2, fail closed). Check that mount line's source path." >&2
        return 1
      fi

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
        #
        # Inside a READ-ONLY mount the file cover is inexpressible: msb must
        # create the bind target in the ro share, and agentd dies at boot
        # ("failed to create bind target ...: Read-only file system", measured
        # on msb 0.7.4, rip-cage-dnwv). A directory cover over an existing dir
        # boots fine there, so only the file case refuses.
        if [[ "${_mode}" == "ro" ]]; then
          echo "Error: the cage config ${_conf} has the read-only mount ${_host}:${_guest}, and that tree holds the protected file ${_found}. rc covers a protected file with an empty file mount, and msb cannot create that mount inside a read-only mount — the cage would die at boot. Refusing to launch before any msb call (ADR-031 D2, fail closed). Narrow the mount to the subdirectories the cage needs, so ${_found} stays outside it (examples/ has a recipe that mounts subdirectories rather than a whole checkout), or move the file out of the mounted tree." >&2
          return 1
        fi
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

# --------------------------------------------------------------------------
# _git_exec_covers CONF_FILE
#
# ADR-002 D11 (evolved 2026-10-16, rip-cage-rsh9.2). A guest that can write a
# repo's .git/config can name a command the HOST runs: core.fsmonitor fires on
# the host's next `git status` or IDE refresh, and filter drivers, `!` aliases,
# core.hooksPath and core.sshCommand do the same on other verbs. So for every
# git repo inside a read-write bind mount of the cage config -- not only the
# `rc up` argument -- this prints mounts that make the exec-bearing parts
# read-only:
#
#   <repo>/.git          rw, over itself -- a PIN: a mount point cannot be
#                        renamed, so `mv .git elsewhere && git init` fails
#                        (measured: EBUSY) instead of handing the host a
#                        fresh .git/config the guest wrote
#   <repo>/.git/...      ro: every config source and pointer file git reads
#                        that exists at launch (_git_exec_ro_covers)
#
# and the same for each submodule gitdir under .git/modules (the host's `git
# status` recurses into submodules and reads their config). A `.git` FILE -- a
# submodule's or linked worktree's `gitdir:` pointer -- is mounted ro over
# itself, so it cannot be repointed at a gitdir the guest wrote; besides the
# scan, each repo's .gitmodules names where those files sit. Repos are found to
# $RC_PROTECTED_SCAN_DEPTH (default 2), the same latency bound the
# protected-paths scan uses. Read-only mounts are skipped, and so is anything
# under a read-only mount's target: a rw pin there would re-expose it.
#
# Prints msb argv tokens, one per line, for _UP_PROTECTED_COVERS.
#
# COSTS, accepted by the human ruling: in-cage git cannot write repo config, so
# `git push -u`, `--set-upstream-to` and `--track` push or branch but record
# no upstream (git prints "could not write config file", exits 0), `git remote
# add` fails, and a repo-local `git config` fails. The image's system gitconfig
# sets push.default=current so a bare `git push` still works.
#
# NOT COVERED: msb can only cover a path that exists, and the pinned .git stays
# writable, so a file git honours that is ABSENT at launch can be created:
# .git/commondir (redirects the whole config to a dir the guest wrote),
# .git/hooks or .git/info when missing. Also a repo or submodule the guest
# creates after launch, and any repo deeper than the scan depth. Like every
# cover, a guest root can umount it (see this file's header). Follow-up:
# rip-cage-rsh9.14.
# --------------------------------------------------------------------------
_git_exec_covers() {
  local _conf="$1"
  local _depth="${RC_PROTECTED_SCAN_DEPTH:-2}"
  local _mounts
  _mounts="$(_protected_paths_conf_bind_mounts "${_conf}")" || return 1
  [[ -z "${_mounts}" ]] && return 0

  # Guest targets of the read-only mounts: nothing under one gets a cover.
  local _ro_targets="" _host _guest _mode
  while IFS=$'\t' read -r _host _guest _mode; do
    [[ "${_mode}" == "ro" && -n "${_guest}" ]] && _ro_targets+="${_guest%/}"$'\n'
  done <<< "${_mounts}"

  local _entry _rel _g _sub _gitfiles _root _p _queue
  while IFS=$'\t' read -r _host _guest _mode; do
    [[ -z "${_host}" ]] && continue
    [[ "${_mode}" == "ro" ]] && continue
    while [[ "${_host}" == */ && "${_host}" != "/" ]]; do _host="${_host%/}"; done
    [[ -d "${_host}" ]] || continue

    _gitfiles=""
    _queue=""
    while IFS= read -r _entry; do
      [[ -z "${_entry}" ]] && continue
      _rel="${_entry#"${_host}/"}"
      if [[ "${_rel}" == "${_entry}" ]]; then
        echo "Error: the cage config ${_conf} mounts ${_host}, and rc found the git dir ${_entry} but could not place it under that mount to cover its config. Refusing to launch rather than leaving it writable (ADR-002 D11, fail closed)." >&2
        return 1
      fi
      _g="${_guest%/}/${_rel}"
      _git_under_ro_target "${_g}" "${_ro_targets}" && continue
      _queue+="$(dirname "${_entry}")"$'\n'
      if [[ -f "${_entry}" ]]; then
        _gitfiles+="${_entry}"$'\t'"${_g}"$'\n'
        continue
      fi
      [[ -d "${_entry}" ]] || continue
      _git_exec_covers_one "${_entry}" "${_g}" || return 1
      # Submodule gitdirs, at any nesting: a dir under .git/modules holding a
      # config beside HEAD and objects (a branch named `config` is a file
      # under refs/, with no HEAD beside it).
      if [[ -d "${_entry}/modules" ]]; then
        while IFS= read -r _sub; do
          [[ -z "${_sub}" ]] && continue
          _sub="$(dirname "${_sub}")"
          [[ -f "${_sub}/HEAD" && -d "${_sub}/objects" ]] || continue
          _git_exec_covers_one "${_sub}" "${_g}${_sub#"${_entry}"}" || return 1
        done < <(find "${_entry}/modules" -name objects -prune -o -type f -name config -print 2>/dev/null | LC_ALL=C sort)
      fi
    done < <(find "${_host}" -maxdepth "${_depth}" -name .git -print -prune 2>/dev/null | LC_ALL=C sort)

    # Submodule .git files the scan depth missed: each repo's .gitmodules
    # names their paths. Walked as a queue so nested submodules are found.
    while [[ -n "${_queue}" ]]; do
      _root="${_queue%%$'\n'*}"
      _queue="${_queue#*$'\n'}"
      [[ -f "${_root}/.gitmodules" ]] || continue
      while IFS= read -r _p; do
        [[ -z "${_p}" ]] && continue
        _entry="${_root}/${_p}/.git"
        [[ -f "${_entry}" ]] || continue
        _rel="${_entry#"${_host}/"}"
        [[ "${_rel}" == "${_entry}" ]] && continue
        _g="${_guest%/}/${_rel}"
        _git_under_ro_target "${_g}" "${_ro_targets}" && continue
        _gitfiles+="${_entry}"$'\t'"${_g}"$'\n'
        _queue+="${_root}/${_p}"$'\n'
      done < <(git config -f "${_root}/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null | cut -d' ' -f2-)
    done

    while IFS=$'\t' read -r _entry _g; do
      [[ -n "${_entry}" ]] && printf '%s\n' -v "${_entry}:${_g}:ro"
    done < <(printf '%s' "${_gitfiles}" | LC_ALL=C sort -u)
  done <<< "${_mounts}"
  return 0
}

# _git_under_ro_target GUEST_PATH RO_TARGETS -- true when GUEST_PATH is at or
# under one of RO_TARGETS (newline-separated guest paths).
_git_under_ro_target() {
  local _t
  while IFS= read -r _t; do
    [[ -n "${_t}" && ( "$1" == "${_t}" || "$1" == "${_t}/"* ) ]] && return 0
  done <<< "$2"
  return 1
}

# _git_exec_covers_one HOST_GITDIR GUEST_GITDIR -- the pin plus the ro covers
# for one gitdir (see _git_exec_covers).
_git_exec_covers_one() {
  printf '%s\n' -v "$1:$2"
  _git_exec_ro_covers "$1" "$2"
}

# _git_exec_ro_covers HOST_GITDIR GUEST_GITDIR -- ro mounts over every config
# source and pointer file git reads in one gitdir, when present:
#   config, config.worktree      the config this gitdir's git runs
#   commondir                    redirects that config to another gitdir
#   info/, hooks/                hooks are executed by git
#   worktrees/*/commondir,       the same two, per linked worktree
#   worktrees/*/config.worktree
# config.worktree is read only under extensions.worktreeConfig=true; then a
# missing one could be created, so this refuses rather than leave it open.
# Worktree mode calls this for the main .git rc mounts itself (cli/up.sh).
_git_exec_ro_covers() {
  local _h="$1" _g="$2" _wtc="" _missing="" _w _n
  [[ "$(git config -f "${_h}/config" --bool extensions.worktreeConfig 2>/dev/null)" == "true" ]] && _wtc=1
  [[ -f "${_h}/config" ]] && printf '%s\n' -v "${_h}/config:${_g}/config:ro"
  if [[ -f "${_h}/config.worktree" ]]; then
    printf '%s\n' -v "${_h}/config.worktree:${_g}/config.worktree:ro"
  elif [[ -n "${_wtc}" ]]; then
    _missing+=" ${_h}/config.worktree"
  fi
  [[ -f "${_h}/commondir" ]] && printf '%s\n' -v "${_h}/commondir:${_g}/commondir:ro"
  [[ -d "${_h}/info" ]] && printf '%s\n' -v "${_h}/info:${_g}/info:ro"
  [[ -d "${_h}/hooks" ]] && printf '%s\n' -v "${_h}/hooks:${_g}/hooks:ro"
  for _w in "${_h}"/worktrees/*/; do
    [[ -d "${_w}" ]] || continue
    _w="${_w%/}"
    _n="${_w##*/}"
    [[ -f "${_w}/commondir" ]] && printf '%s\n' -v "${_w}/commondir:${_g}/worktrees/${_n}/commondir:ro"
    if [[ -f "${_w}/config.worktree" ]]; then
      printf '%s\n' -v "${_w}/config.worktree:${_g}/worktrees/${_n}/config.worktree:ro"
    elif [[ -n "${_wtc}" ]]; then
      _missing+=" ${_w}/config.worktree"
    fi
  done
  if [[ -n "${_missing}" ]]; then
    echo "Error: ${_h}/config sets extensions.worktreeConfig=true, so git also reads config.worktree, and these do not exist:${_missing}. A guest could create one and set a key the host's git runs, and rc can only make a file that exists read-only. Create them empty on the host (touch${_missing}) and rerun. Refusing to launch rather than leaving them writable (ADR-002 D11, fail closed)." >&2
    return 1
  fi
  return 0
}
