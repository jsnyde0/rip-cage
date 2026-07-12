#!/usr/bin/env bash
# cli/up.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).

#
# Returns 0 if the workspace settings are HOSTILE (caller should refuse).
# Returns 1 if the workspace settings are OK.
#
# Sets WS_CONFIG_HOSTILE_KEY and WS_CONFIG_HOSTILE_VAL on hostile detection.
WS_CONFIG_HOSTILE_KEY=""
WS_CONFIG_HOSTILE_VAL=""

_check_workspace_config_base_url() {
  local _ws="$1"
  local _settings="${_ws}/.claude/settings.json"
  WS_CONFIG_HOSTILE_KEY=""
  WS_CONFIG_HOSTILE_VAL=""

  # No settings.json → ok
  [[ -f "$_settings" ]] || return 1

  # Keys to check (provider base-URL env vars):
  local _hostile_keys=(
    ANTHROPIC_BASE_URL
    OPENAI_BASE_URL
    ANTHROPIC_API_URL
    OPENAI_API_BASE
  )

  local _key _val
  for _key in "${_hostile_keys[@]}"; do
    _val=$(jq -r --arg k "$_key" '.env[$k] // empty' "$_settings" 2>/dev/null)
    if [[ -n "$_val" ]]; then
      WS_CONFIG_HOSTILE_KEY="$_key"
      WS_CONFIG_HOSTILE_VAL="$_val"
      return 0  # hostile
    fi
  done

  return 1  # ok
}


# _emit_workspace_config_base_url_error <key> <value>
#
# Print the ADR-024 D1 / ADR-001 fail-loud error message to stderr.
# Does not exit — caller must exit.
_emit_workspace_config_base_url_error() {
  local _key="$1" _val="$2"
  echo "Error: workspace .claude/settings.json sets ${_key}=${_val}" >&2
  echo "  This redirects all agent traffic to a non-official host, bypassing the egress firewall." >&2
  echo "  Hostile base-URL redirect is a documented prompt-injection attack vector (ADR-024 D1)." >&2
  echo "" >&2
  echo "  To allow this for this invocation (emit a warning instead):" >&2
  echo "    rc up --allow-config-override ..." >&2
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc --arg error "workspace .claude/settings.json sets ${_key}=${_val} — hostile base-URL redirect detected (ADR-024 D1)" \
           --arg code "WORKSPACE_CONFIG_BASE_URL_REDIRECT" \
           --arg key "$_key" \
           --arg val "$_val" \
           '{error: $error, code: $code, key: $key, value: $val}'
  fi
}


# _emit_workspace_config_base_url_warning <key> <value>
#
# Print the --allow-config-override warning to stderr (warn but proceed).
_emit_workspace_config_base_url_warning() {
  local _key="$1" _val="$2"
  echo "Warning: --allow-config-override: workspace .claude/settings.json sets ${_key}=${_val}" >&2
  echo "  Proceeding despite hostile base-URL redirect. Agent traffic may be routed to a non-official host." >&2
}


# _emit_denylist_denial <resolved-path> <matched-pattern>
#
# Print the ADR-023 D6 error message to stderr. Does not exit — caller must exit.
_emit_denylist_denial() {
  local _rpath="$1" _pattern="$2"
  echo "Error: refusing to mount ${_rpath} — matched secret-path denylist pattern '${_pattern}'." >&2
  echo "  Override (one-shot):   rc up --allow-risky-mount ${_rpath} ..." >&2
  echo "  Override (persistent): add to .rip-cage.yaml under mounts.allow_risky:" >&2
  echo "                           mounts:" >&2
  echo "                             allow_risky:" >&2
  echo "                               - ${_rpath}" >&2
}


# _up_json_output — emit the standard worktree-aware JSON for rc up responses.
#
# Globals read: wt_detected, wt_error, wt_name, wt_main_git, git_hooks_ro, name_disambiguated
# Parameters:
#   $1  name          — container name
#   $2  action        — e.g. "created", "resumed", "attached", "would_create"
#   $3  source_path   — validated workspace path
#   $4  status        — e.g. "running", "stopped"  (pass "" to omit)
#   $5  init          — e.g. "success", "failed"   (pass "" to omit)
#   $6  dry_run       — non-empty string to include dry_run:true (pass "" to omit)
# shellcheck disable=SC2016 # jq_filter uses jq variable syntax ($name etc.)
_up_json_output() {
  local _name="$1" _action="$2" _source_path="$3" _status="${4:-}" _init="${5:-}" _dry_run="${6:-}"

  local jq_args=()
  jq_args+=(--arg name "$_name")
  jq_args+=(--arg action "$_action")
  jq_args+=(--arg source_path "$_source_path")
  jq_args+=(--argjson name_disambiguated "$name_disambiguated")

  local jq_filter='{name: $name, action: $action, source_path: $source_path, name_disambiguated: $name_disambiguated'

  if [[ -n "${RC_VALIDATE_WARNING:-}" ]]; then
    jq_args+=(--arg warning "$RC_VALIDATE_WARNING")
    jq_filter+=', warning: $warning'
  fi
  if [[ -n "$_dry_run" ]]; then
    jq_args+=(--argjson dry_run true)
    jq_filter+=', dry_run: $dry_run'
  fi
  if [[ -n "$_status" ]]; then
    jq_args+=(--arg status "$_status")
    jq_filter+=', status: $status'
  fi
  if [[ -n "$_init" ]]; then
    jq_args+=(--arg init "$_init")
    jq_filter+=', init: $init'
  fi

  if [[ "$wt_detected" == "true" ]]; then
    jq_args+=(--argjson git_hooks_ro "$git_hooks_ro")
    jq_args+=(--arg wt_name "$wt_name")
    jq_args+=(--arg wt_main_git "$wt_main_git")
    jq_filter+=', git_hooks_ro: $git_hooks_ro, worktree: {name: $wt_name, main_git_dir: $wt_main_git}'
  elif [[ -n "$wt_error" ]]; then
    jq_args+=(--arg wt_error "$wt_error")
    jq_filter+=', worktree: {detected: true, error: $wt_error}'
  else
    jq_args+=(--argjson git_hooks_ro "$git_hooks_ro")
    jq_filter+=', git_hooks_ro: $git_hooks_ro'
  fi

  jq_filter+='}'
  jq -nc "${jq_args[@]}" "$jq_filter"
}


# _up_detect_worktree — detect and validate a git worktree at the given path.
#
# Sets globals: wt_detected, wt_name, wt_main_git, wt_error
# Parameter: $1 path — the validated workspace path
_up_detect_worktree() {
  local _path="$1"
  wt_detected=false
  wt_name=""
  wt_main_git=""
  wt_error=""

  if [[ ! -f "${_path}/.git" ]]; then
    return 0
  fi

  local gitdir_line
  gitdir_line=$(cat "${_path}/.git")
  if [[ "$gitdir_line" != gitdir:\ * ]]; then
    return 0
  fi

  local host_gitdir="${gitdir_line#gitdir: }"

  # Security: reject control characters (clear host_gitdir to prevent fallthrough)
  if [[ "$host_gitdir" =~ [[:cntrl:]] ]]; then
    log "Warning: .git file contains control characters — skipping worktree mount"
    wt_error="control characters in .git file"
    return 0
  # Resolve relative gitdir paths to absolute (Git 2.13+ allows relative)
  elif [[ "$host_gitdir" != /* ]]; then
    host_gitdir=$(realpath "${_path}/${host_gitdir}" 2>/dev/null)
    if [[ -z "$host_gitdir" ]]; then
      log "Warning: worktree .git file points to non-existent relative path — git will not work"
      wt_error="relative gitdir path does not exist"
      return 0
    fi
  fi

  # Only handle worktrees, not submodules (.git/modules/<name>)
  # Note: validate_path() does similar allowed-roots checking — see Security section
  if [[ -z "$host_gitdir" || "$host_gitdir" != *"/worktrees/"* ]]; then
    [[ -n "$host_gitdir" ]] && log "Skipping non-worktree .git file (submodule or other)"
    return 0
  fi

  wt_name=$(basename "$host_gitdir")
  if [[ -z "$wt_name" || "$wt_name" == "." || "$wt_name" == ".." ]]; then
    log "Warning: invalid worktree name '${wt_name}' — skipping worktree mount"
    wt_error="invalid worktree name"
    wt_name=""
    return 0
  fi

  local main_git_dir
  main_git_dir=$(dirname "$(dirname "$host_gitdir")")

  if [[ ! -d "$main_git_dir" ]]; then
    log "Warning: worktree's main .git/ at $main_git_dir does not exist — git will not work"
    wt_error="main .git/ at $main_git_dir does not exist"
    return 0
  fi

  local resolved_git_dir
  resolved_git_dir=$(realpath "$main_git_dir" 2>/dev/null) || true

  if _path_under_allowed_roots "$resolved_git_dir"; then
    wt_detected=true
    wt_main_git="$resolved_git_dir"
    log "Worktree detected: ${wt_name} (main .git/ at ${wt_main_git})"
  else
    log "Warning: worktree's main .git/ at $main_git_dir is outside allowed roots — git will not work"
    wt_error="main .git/ at $main_git_dir is outside allowed roots"
  fi
}


# _collect_symlink_parents — print unique parent dirs of asset symlink targets.
#
# Skills stored as host symlinks (e.g. pointing to a monorepo) become broken
# symlinks inside containers because the target paths don't exist. To fix this,
# we mount each symlink target's parent directory at the same absolute path,
# so symlinks resolve correctly inside the container.
#
# Parameters:
#   $1  asset_dir — the asset directory to scan (e.g. ~/.claude/skills)
# Output: one resolved parent path per line (deduplicated)
_collect_symlink_parents() {
  local asset_dir="$1"
  local entry target tdir seen_it d
  local seen_dirs
  seen_dirs=()
  for entry in "${asset_dir}/"*; do
    [[ -L "$entry" ]] || continue
    if ! target=$(realpath "$entry" 2>/dev/null); then
      # BSD/macOS realpath fails outright on a broken symlink.
      echo "[rc] Warning: asset symlink '$entry' is broken (unresolvable target) — skipping mount" >&2
      continue
    fi
    if [[ ! -e "$target" ]]; then
      # GNU realpath resolves a missing target instead of failing — catch it here.
      echo "[rc] Warning: asset symlink '$entry' is broken (target does not exist: $target) — skipping mount" >&2
      continue
    fi
    # Security: only mount targets within the user's home directory.
    # A symlink pointing outside $HOME (e.g. -> /etc) would mount a system
    # directory into the container — skip it with a warning.
    if [[ "$target" != "${HOME}/"* ]]; then
      echo "[rc] Warning: asset symlink '$(basename "$entry")' resolves outside \$HOME ($target) — skipping mount" >&2
      continue
    fi
    tdir=$(dirname "$target")
    seen_it=0
    for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
      [[ "$d" == "$tdir" ]] && seen_it=1 && break
    done
    if [[ "$seen_it" == 0 ]]; then
      seen_dirs+=("$tdir")
      echo "$tdir"
    fi
  done
}


# _collect_dangling_symlinks — find absolute symlinks in a host root that
# would be dangling inside the cage (i.e. their targets are not under the
# root path itself).
#
# NEW HELPER — distinct from _collect_symlink_parents (rc:794-830) which returns
# parent dirs of asset symlink targets. This helper enumerates (link, target)
# tuples for use in the symlink-follow mount synthesis (rip-cage-c1p.2).
# The existing helper has 6 callers and its semantics MUST NOT be modified.
#
# Parameters:
#   $1  root — the host directory to scan (e.g. ~/.pi/agent)
#   $2  on_dangling — follow|skip|warn|error (default: follow). Only "skip"
#       changes behaviour: a broken/unresolvable chain is skipped (warn +
#       continue) instead of aborting, so the scan keeps emitting subsequent
#       resolvable links (rip-cage-hcdn). All other values stay fail-loud.
# Output: lines of "<absolute-link-path>|<readlink-f-resolved-target>"
#         for each absolute symlink found under root.
# Errors: returns non-zero (ADR-001 D1) when readlink -f fails, EXCEPT under
#         on_dangling=skip where a broken chain is skipped rather than fatal.
_collect_dangling_symlinks() {
  local root="$1" on_dangling="${2:-follow}"
  [[ -d "$root" ]] || return 0
  # Resolve root itself (handles macOS /var → /private/var etc.) for the
  # in-root comparison below. Use realpath if available, fall back to readlink -f.
  local resolved_root
  resolved_root=$(readlink -f "$root" 2>/dev/null || printf '%s' "$root")
  local link target
  while IFS= read -r link; do
    [[ -z "$link" ]] && continue
    # Only process absolute symlinks (i.e., symlinks whose *value* is absolute)
    local link_val
    link_val=$(readlink "$link" 2>/dev/null) || {
      echo "Error: failed to read symlink '$link'" >&2
      return 1
    }
    # Skip relative symlinks — they resolve relative to the link's dir
    # and typically work inside the cage if the parent dir is mounted.
    [[ "$link_val" != /* ]] && continue
    # Resolve the absolute target via readlink -f.
    # macOS readlink -f returns a NON-EMPTY partial path with EXIT CODE 1 for a
    # truly-broken chain (e.g. /nonexistent/absolute/path/file.md → "/nonexistent").
    # Guard on exit-nonzero OR empty output so this fires on both macOS and Linux.
    if ! target=$(readlink -f "$link" 2>/dev/null) || [[ -z "$target" ]]; then
      if [[ "$on_dangling" == "skip" ]]; then
        echo "Warning: symlink at '$link' could not be resolved (broken symlink chain); skipping (mounts.symlinks.on_dangling=skip)." >&2
        continue
      fi
      echo "Error: symlink at '$link' could not be resolved (broken symlink chain). Set mounts.symlinks.on_dangling=skip in .rip-cage.yaml to unblock." >&2
      return 1
    fi
    # Skip if target is under the root itself (not dangling from cage POV).
    # Compare against resolved_root to handle OS symlink normalization
    # (e.g., macOS /var/folders → /private/var/folders).
    if [[ "$target" == "${resolved_root}/"* || "$target" == "$resolved_root" ]]; then
      continue
    fi
    printf '%s|%s\n' "$link" "$target"
  done < <(find "$root" -maxdepth 1 -type l 2>/dev/null)
}


# _symlink_follow_fingerprint — compute sha256 fingerprint over sorted
# "<link> → <target> (<mode>)" lines plus a policy header, for the
# symlink-follow mount set. Used for the rc.symlink-follow-fingerprint
# label-lock (D4).
# Parameters:
#   $1  pi_root    — host path of the pi agent dir (or "" if absent)
#   $2  mode       — ro|rw
#   $3  on_dangling — follow|skip|warn|error (default: follow)
#   $4  scope      — file|parent (default: file)
#   $5  workspace  — workspace path for denylist check (default: ".")
#                    ADR-023 D2 FIRM: fingerprint reflects post-denylist mount set.
#                    Denylist-skipped targets are silently excluded from the hash.
#   $6  cred_mounts — real|none (default: real). F1 (rip-cage-seqc.4): when
#                    none, excludes the pi_root/auth.json leaf from the hash —
#                    IDENTICAL predicate to the mount-loop leaf-filter in
#                    _up_prepare_docker_mounts, so the fingerprint never drifts
#                    from the honest post-filter mount set (label-lock /
#                    filter-the-fingerprint-too, mirrors the existing ADR-023 D2
#                    denylist exclusion above).
# Output: sha256 hex string on stdout (always; empty set hashes to a fixed value)
_symlink_follow_fingerprint() {
  local pi_root="$1" mode="$2" on_dangling="${3:-follow}" scope="${4:-file}" workspace="${5:-.}" cred_mounts="${6:-real}"
  # Prepend a policy header so that policy changes produce a different
  # fingerprint even when the scanned symlink set is identical.
  local lines="policy: on_dangling=${on_dangling}, scope=${scope}, mode=${mode}"$'\n'
  if [[ -d "$pi_root" ]]; then
    local link target mount_src
    while IFS='|' read -r link target; do
      [[ -z "$link" ]] && continue
      # F1: identical predicate to the mount-loop leaf-filter — skip the
      # credential leaf under none so the fingerprint reflects the honest
      # post-filter mount set.
      if [[ "$cred_mounts" == "none" && "$link" == "${pi_root}/auth.json" ]]; then
        continue
      fi
      # Compute the actual mount source — mirrors the scope branch in the mount loop
      # so the denylist gate and the fingerprint both reflect what actually mounts.
      # ADR-023 D7 FIRM: check/fingerprint the realpath-resolved actual mount source.
      if [[ "$scope" == "parent" ]]; then
        mount_src=$(dirname "$target")
      else
        mount_src="$target"
      fi
      # ADR-023 D2 FIRM: exclude denylist-skipped mount sources from the hash.
      # Silent skip here — the warning belongs at the mount site (Surface 1 only).
      if _check_secret_path_denylist "$mount_src" "$workspace" 2>/dev/null; then
        continue
      fi
      lines+="${link} → ${mount_src} (${mode})"$'\n'
    done < <(_collect_dangling_symlinks "$pi_root" "$on_dangling" 2>/dev/null || true)
  fi
  # Sort for stability, then hash
  printf '%s' "$lines" | sort | shasum -a 256 | awk '{print $1}'
}


# _check_lfs_stubs <path>
# If the project uses git-lfs and has unmaterialized pointer stubs in the
# working tree, print an advisory warning to stderr. rip-cage cannot fetch
# LFS blobs (ADR-014 egress posture), so materialization is the human's
# responsibility on the host. Observation-only: never mutates the workspace
# and never calls `git lfs pull`.
_check_lfs_stubs() {
  local path="$1"
  [[ -d "$path" ]] || return 0
  # Fast early exit for non-LFS repos: no .gitattributes contains filter=lfs
  if ! grep -rqI --include='.gitattributes' --exclude-dir='.git' 'filter=lfs' "$path" 2>/dev/null; then
    return 0
  fi
  # Scan working tree for LFS pointer-stub files:
  #   - size < 200 bytes (real stubs are ~130 bytes)
  #   - first line is the LFS v1 pointer header
  # `|| true`: when no file matches, `grep -l` exits 1, which propagates through
  # `find -exec ... {} +` and the pipeline under `pipefail`. That's a normal
  # "no stubs" outcome, not a failure — don't let it kill `set -e` callers.
  local stubs
  stubs=$(find "$path" -type f -size -200c ! -path '*/.git/*' \
    -exec grep -l -m1 '^version https://git-lfs.github.com/spec/v1' {} + 2>/dev/null \
    | head -5) || true
  [[ -z "$stubs" ]] && return 0

  {
    echo ""
    echo "⚠ LFS pointer stubs detected in $path"
    echo "  rip-cage cannot fetch LFS blobs from inside the cage (ADR-014)."
    echo "  Run on the host before working in the cage:"
    echo "      git -C $path lfs pull"
    echo "  Files still as stubs (first 5):"
    local _stub_line _rel
    while IFS= read -r _stub_line; do
      [[ -z "$_stub_line" ]] && continue
      _rel="${_stub_line#"$path"/}"
      echo "      $_rel"
    done <<< "$stubs"
    echo ""
  } >&2
}


# _seed_claude_home_dirs — provisioning-time directory seeding for a
# claude-home root, BEFORE it is ever mounted into a cage (rip-cage-xuy8, S3
# of the msb migration epic rip-cage-tsf2).
#
# ADR-029 D4 resume-path corollary / rip-cage-1ujn footgun: the in-guest
# claude-session-wrapper.sh (cage/substrate/claude-session-wrapper.sh) only
# symlinks ~/.claude/projects and ~/.claude/sessions into its per-session
# config dir IF those dirs already exist in the mounted claude-home at
# wrapper-run time. If either is absent on first boot, the wrapper instead
# creates fresh, EPHEMERAL copies inside the per-session dir -- Claude Code
# session state then never lands on the host-mounted claude-home, and a
# later resume attempt against a recreated cage silently finds nothing,
# with no error signal anywhere in the loop.
#
# This must run BEFORE the claude-home root is first mounted (create time),
# not just once per project -- the Docker up-path (below) and the msb
# create-path (S6) both call it on their respective claude-home root.
#
# Idempotent (mkdir -p): safe to call on every `rc up`/create, never
# clobbers content already written into projects/ or sessions/.
#
# Parameters: $1  claude_home_root — the host directory that will be (or
#                 already is) mounted as the cage's claude-home.
_seed_claude_home_dirs() {
  local _claude_home_root="$1"
  mkdir -p "${_claude_home_root}/projects" "${_claude_home_root}/sessions"
}


# _up_prepare_docker_mounts — build the mount (-v) portion of run_args.
#
# Globals read:    wt_detected, wt_name, wt_main_git (set by _up_detect_worktree)
# Globals written: _UP_RUN_ARGS (appended to)
# Parameters:
#   $1  path  — validated workspace path
#   $2  name  — container name (used for gitfile path)
_up_prepare_docker_mounts() {
  local _path="$1" _name="$2"

  # Workspace mount
  _UP_RUN_ARGS+=(-v "${_path}:/workspace:delegated")

  # Land every in-cage entry mode in the repo, not /home/agent. The image WORKDIR is
  # /home/agent — correct for build-time RUN/CMD, but /workspace is a runtime-only bind
  # mount (above) that doesn't exist at build time, so the fix belongs at container-run
  # time, not in the Dockerfile. Setting the container's runtime working dir here makes
  # `docker run` AND every subsequent `docker exec` (rc attach, multiplexer panes, rc exec,
  # the drover's cage-exec worker spawn) default into the workspace, so bd/git/rg and
  # all project-relative paths resolve without a per-session `cd /workspace`. Colocated
  # with the mount so it only applies when /workspace is actually mounted. (rip-cage-0rng)
  _UP_RUN_ARGS+=(--workdir /workspace)

  # ADR-021 D7: .rip-cage.yaml ro shadow-mount.
  # If the project config file exists and effective mounts.config_mode is not "rw",
  # add a more-specific nested :ro bind-mount over /workspace/.rip-cage.yaml.
  # This prevents a prompt-injected in-cage agent from writing containment-weakening
  # lines that a human would rubber-stamp on rc reload/rc up (ADR-024 buried-edit threat).
  # The global config (~/.config/rip-cage/config.yaml) is never mounted in-cage — untouched.
  # D5 regression contract: skip entirely when the project file is absent (no shadow-mount
  # means a new file can be authored via the rw workspace mount, which is reviewed wholesale).
  if [[ -f "${_path}/.rip-cage.yaml" ]]; then
    local _cfg_mode="ro"
    if [[ -f "$(_config_global_path)" || -f "$(_config_project_path "${_path}")" ]]; then
      local _cm_cfg_result
      if _cm_cfg_result=$(_load_effective_config "${_path}" 2>/dev/null); then
        _cfg_mode=$(jq -r '.config.mounts.config_mode // "ro"' <<<"$_cm_cfg_result")
      fi
      unset _cm_cfg_result
    fi
    if [[ "$_cfg_mode" != "rw" ]]; then
      _UP_RUN_ARGS+=(-v "${_path}/.rip-cage.yaml:/workspace/.rip-cage.yaml:ro")
      log ".rip-cage.yaml: ro shadow-mount added (mounts.config_mode=${_cfg_mode})"
    else
      log ".rip-cage.yaml: writable via workspace mount (mounts.config_mode=rw)"
    fi
    unset _cfg_mode
  fi

  # D11: .git/hooks read-only — physical enforcement against container escape
  # Worktree mode handles hooks separately (see worktree mount block below)
  if [[ "$wt_detected" != "true" ]] && [[ -d "${_path}/.git/hooks" ]]; then
    _UP_RUN_ARGS+=(-v "${_path}/.git/hooks:/workspace/.git/hooks:ro")
  fi

  # Git worktree mounts: fix .git pointer so git works inside the container
  if [[ "$wt_detected" == "true" ]]; then
    mkdir -p ~/.cache/rc
    local gitfile="${HOME}/.cache/rc/${_name}.gitfile"
    (umask 077; echo "gitdir: /workspace/.git-main/worktrees/${wt_name}" > "$gitfile")
    _UP_RUN_ARGS+=(-v "${wt_main_git}:/workspace/.git-main:delegated")
    _UP_RUN_ARGS+=(-v "${gitfile}:/workspace/.git:ro")
    _UP_RUN_ARGS+=(-v "${wt_main_git}/hooks:/workspace/.git-main/hooks:ro")
    log "Worktree: mounted main .git/ and corrected .git pointer for ${wt_name}"
  fi

  # auth.credential_mounts (rip-cage-seqc.4) + auth.per_tool.{claude,pi}
  # (rip-cage-xhgr): real (default) preserves today's behavior bit-for-bit.
  # none = non-possession posture — the per-cage keychain extraction is
  # skipped so the cage never receives a host credential. _UP_CRED_MOUNTS_CLAUDE
  # / _UP_CRED_MOUNTS_PI are each resolved once on the create path (see cmd_up,
  # near the rc.symlink-follow-fingerprint label) via
  # _up_resolve_effective_credential_mounts_for_tool (effective(T) = per_tool.T
  # if set, else the global credential_mounts, else "real") and consumed here
  # + at every other gated site below. Callers that don't set them (e.g.
  # legacy paths) default to "real" so the unset case is byte-identical to
  # today. Claude's credential surface (keychain extraction + CC .claude.json/
  # .credentials.json) is gated on effective(claude); pi's (auth.json mount +
  # symlink-follow leaf) is gated on effective(pi) — the two tools are
  # independently suppressible.
  local _UP_CRED_MOUNTS_CLAUDE="${_UP_CRED_MOUNTS_CLAUDE:-real}"
  local _UP_CRED_MOUNTS_PI="${_UP_CRED_MOUNTS_PI:-real}"
  if [[ "$_UP_CRED_MOUNTS_CLAUDE" == "none" ]]; then
    log "auth.credential_mounts=none — Claude keychain extraction intentionally skipped (non-possession posture)"
  else
    # Extract OAuth credentials from macOS keychain to file (if on macOS)
    _extract_credentials || true
  fi

  # Skills and commands: mount host's ~/.claude/skills and ~/.claude/commands read-only
  # Staged via .rc-context/ so init-rip-cage.sh can symlink them into ~/.claude/
  if [[ -d "${HOME}/.claude/skills" ]]; then
    _UP_RUN_ARGS+=(-v "${HOME}/.claude/skills:/home/agent/.rc-context/skills:ro")
    # Resolve skill symlinks: skills stored as host symlinks (e.g. pointing to a
    # monorepo) become broken symlinks inside the container because target paths
    # don't exist there. Mount each unique symlink-target parent at the same
    # absolute path so those symlinks resolve correctly.
    # ADR-023 D6 warn-and-skip: denied symlink-target parents are skipped with a
    # stderr warning; rc up continues (best-effort decoration surface).
    local _asset_tdir
    while IFS= read -r _asset_tdir; do
      if _check_secret_path_denylist "$_asset_tdir" "$_path"; then
        local _skill_pat
        _skill_pat=$(_secret_path_denylist_matched_pattern "$_asset_tdir" "$_path" 2>/dev/null || true)
        echo "Warning: skipping skill symlink mount ${_asset_tdir} — matched secret-path denylist pattern '${_skill_pat:-<unknown>}'" >&2
        continue
      fi
      _UP_RUN_ARGS+=(-v "${_asset_tdir}:${_asset_tdir}:ro")
    done < <(_collect_symlink_parents "${HOME}/.claude/skills")
  fi
  if [[ -d "${HOME}/.claude/commands" ]]; then
    _UP_RUN_ARGS+=(-v "${HOME}/.claude/commands:/home/agent/.rc-context/commands:ro")
  fi
  if [[ -d "${HOME}/.claude/agents" ]]; then
    _UP_RUN_ARGS+=(-v "${HOME}/.claude/agents:/home/agent/.rc-context/agents:ro")
    local _agent_tdir
    while IFS= read -r _agent_tdir; do
      if _check_secret_path_denylist "$_agent_tdir" "$_path"; then
        local _agent_pat
        _agent_pat=$(_secret_path_denylist_matched_pattern "$_agent_tdir" "$_path" 2>/dev/null || true)
        echo "Warning: skipping agent symlink mount ${_agent_tdir} — matched secret-path denylist pattern '${_agent_pat:-<unknown>}'" >&2
        continue
      fi
      _UP_RUN_ARGS+=(-v "${_agent_tdir}:${_agent_tdir}:ro")
    done < <(_collect_symlink_parents "${HOME}/.claude/agents")
  fi

  # D3: Credential health check — warn on expired or soon-to-expire tokens
  if [[ -s "${HOME}/.claude/.credentials.json" ]] && command -v jq &>/dev/null; then
    local expiry
    expiry=$(jq -r '.expiry // .expiresAt // empty' "${HOME}/.claude/.credentials.json" 2>/dev/null || true)
    if [[ -n "$expiry" ]]; then
      local expiry_epoch now_epoch
      expiry_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${expiry%%[.+Z]*}" "+%s" 2>/dev/null || date -d "$expiry" "+%s" 2>/dev/null || true)
      now_epoch=$(date "+%s")
      if [[ -n "$expiry_epoch" ]]; then
        local remaining=$(( expiry_epoch - now_epoch ))
        if [[ "$remaining" -lt 0 ]]; then
          echo "Warning: Claude OAuth token is EXPIRED (expired $(( -remaining / 60 )) minutes ago) — fine if you are not using Claude Code in this cage" >&2
          echo "  If you are using Claude Code, run 'claude auth login' on the host to refresh, or set ANTHROPIC_API_KEY" >&2
        elif [[ "$remaining" -lt 600 ]]; then
          echo "Warning: OAuth token expires in $(( remaining / 60 )) minutes" >&2
          echo "  Consider running 'claude auth login' on the host to refresh" >&2
        fi
      fi
    fi
  fi

  # OAuth mounts (read-write, skip if missing to avoid Docker creating empty dirs)
  # auth.credential_mounts=none (rip-cage-seqc.4) / effective(claude) (rip-cage-xhgr):
  # rip-cage-t7cu re-scope — the gated-as-a-unit set is now .credentials.json
  # (the token secret) + keychain extraction ONLY. ~/.claude.json holds no
  # token-shaped fields (account metadata + workflow state, verified by full
  # key-inventory audit) — it was swept into the original gate by association,
  # not because it is a credential. Under non-possession it still mounts, but
  # READ-ONLY (:ro): an RW bind would hand a prompt-injected in-cage agent
  # (ADR-024 in-scope) a write primitive into the host's real-credential claude
  # config (mcpServers/hooks poisoning, later executed by host claude with real
  # creds); under possession RW is no escalation, so the mount stays RW there
  # (bit-for-bit unchanged). Skip-if-missing semantics match possession.
  if [[ -f "${HOME}/.claude.json" ]]; then
    if [[ "$_UP_CRED_MOUNTS_CLAUDE" == "none" ]]; then
      _UP_RUN_ARGS+=(-v "${HOME}/.claude.json:/home/agent/.claude.json:ro")
    else
      _UP_RUN_ARGS+=(-v "${HOME}/.claude.json:/home/agent/.claude.json")
    fi
  else
    log "Warning: ${HOME}/.claude.json not found — skipping mount"
  fi
  if [[ "$_UP_CRED_MOUNTS_CLAUDE" == "none" ]]; then
    log "auth.credential_mounts=none — Claude .credentials.json mount intentionally skipped (non-possession posture)"
  else
    if [[ -f "${HOME}/.claude/.credentials.json" ]]; then
      _UP_RUN_ARGS+=(-v "${HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json")
    else
      log "Warning: ${HOME}/.claude/.credentials.json not found — skipping mount (fine if you are not using Claude Code in this cage)"
    fi
  fi

  # Symlink-follow mount synthesis (rip-cage-c1p.2 / D1-D4 FIRM).
  # Whitelist of rip-cage-managed dotfile mount roots to scan for absolute
  # symlinks that would be dangling inside the cage. /workspace is NEVER on
  # this list (D2 FIRM: whitelist not blacklist).
  # Post-hhh.12: narrow auth.json sub-mount. Scanner root is still ~/.pi/agent
  # (the dir containing the sub-mounted file) so the scanner can detect if
  # auth.json itself is a symlink (dotpi-managed state) — if so, the symlink-follow
  # machinery adds the second mount for the resolved target, exactly as before.
  # Per D3: second bind mount at host-target path (mirror), not sanitized.
  # Per ADR-001 D1: mount expansions always log to stderr.
  local _SFL_SCAN_ROOTS=()
  if [[ -d "${HOME}/.pi/agent" ]]; then
    _SFL_SCAN_ROOTS+=("${HOME}/.pi/agent")
  fi

  # Debian FHS reserved top-level paths + cage-reserved paths that must never
  # be mounted over. Collision against any of these triggers abort loud.
  local _SFL_RESERVED_CAGE_PATHS=(
    /bin /boot /dev /etc /home /lib /opt /proc /root /run /sbin /sys
    /usr /var /tmp /workspace /ssh-agent.sock
  )

  # Load effective config for symlinks settings (D5: skip if no config files).
  local _sfl_on_dangling="follow" _sfl_scope="file" _sfl_mode="rw"
  local _sfl_cfg_result
  if [[ -f "$(_config_global_path)" || -f "$(_config_project_path "${_path}")" ]]; then
    if _sfl_cfg_result=$(_load_effective_config "${_path}" 2>/dev/null); then
      _sfl_on_dangling=$(jq -r '.config.mounts.symlinks.on_dangling // "follow"' <<<"$_sfl_cfg_result")
      _sfl_scope=$(jq -r '.config.mounts.symlinks.scope // "file"' <<<"$_sfl_cfg_result")
      _sfl_mode=$(jq -r '.config.mounts.symlinks.mode // "rw"' <<<"$_sfl_cfg_result")
    fi
  fi

  local _sfl_root _sfl_link _sfl_target _sfl_collected
  for _sfl_root in "${_SFL_SCAN_ROOTS[@]+"${_SFL_SCAN_ROOTS[@]}"}"; do
    # Buffer collector output before the while loop so that a non-zero exit
    # (broken symlink chain) propagates correctly under set -e.  A process
    # substitution done < <(failing_cmd) silently swallows the failure; capturing
    # into a variable first lets the || branch abort the caller (ADR-001 D1).
    _sfl_collected=$(_collect_dangling_symlinks "$_sfl_root" "$_sfl_on_dangling") || {
      # Error message already printed by _collect_dangling_symlinks.
      exit 1
    }
    while IFS='|' read -r _sfl_link _sfl_target; do
      [[ -z "$_sfl_link" ]] && continue

      # F1 (rip-cage-seqc.4, CRITICAL) / effective(pi) (rip-cage-xhgr):
      # auth.credential_mounts=none (or per-tool pi:none) must also gate the
      # symlink-follow synthesis path — it is a SECOND, previously-ungated
      # mount route for the pi credential when auth.json is an absolute
      # dotpi-managed symlink. Filter the specific credential LEAF (not the
      # whole scan root: ~/.pi/agent may contain other legitimate absolute
      # dangling symlinks that must keep mounting under none). This is the
      # pi-only scan root — claude's effective value is irrelevant here.
      # IDENTICAL predicate to the fingerprint filter in _symlink_follow_fingerprint
      # (B1a) — the two must never diverge (label-lock / filter-the-fingerprint-too).
      if [[ "$_UP_CRED_MOUNTS_PI" == "none" && "$_sfl_link" == "${HOME}/.pi/agent/auth.json" ]]; then
        log "auth.credential_mounts=none — symlink-follow auth.json leaf intentionally skipped (non-possession posture)"
        continue
      fi

      # Collision check: target must not be in the FHS reserved set.
      # The target comes from readlink -f (canonical). On macOS, /etc → /private/etc,
      # so we also resolve each reserved path via readlink -f for matching.
      # HOWEVER: /var → /private/var on macOS, which would falsely match temp paths
      # under /private/var/folders/. We therefore only resolve /etc, /usr, /bin,
      # /sbin, /lib, /opt, /proc, /root, /run, /sys, /boot, /dev, /home (not /var or /tmp).
      local _sfl_reserved=0
      local _sfl_rp _sfl_rp_canonical
      for _sfl_rp in "${_SFL_RESERVED_CAGE_PATHS[@]}"; do
        # Resolve symlinks for stable FHS paths (not /var or /tmp which may point to
        # user-writable dirs on macOS and cause false positives).
        case "$_sfl_rp" in
          /var|/tmp) _sfl_rp_canonical="$_sfl_rp" ;;
          *) _sfl_rp_canonical=$(readlink -f "$_sfl_rp" 2>/dev/null || printf '%s' "$_sfl_rp") ;;
        esac
        if [[ "$_sfl_target" == "$_sfl_rp" || "$_sfl_target" == "${_sfl_rp}/"* \
           || "$_sfl_target" == "$_sfl_rp_canonical" || "$_sfl_target" == "${_sfl_rp_canonical}/"* ]]; then
          _sfl_reserved=1
          break
        fi
      done
      if [[ "$_sfl_reserved" -eq 1 ]]; then
        if [[ "$_sfl_on_dangling" == "skip" ]]; then
          echo "[rip-cage] Warning: symlink at '${_sfl_link}' resolves to reserved cage path '${_sfl_target}'; skipping mount (mounts.symlinks.on_dangling=skip)." >&2
          continue
        fi
        echo "[rip-cage] Error: symlink at '${_sfl_link}' resolves to reserved cage path '${_sfl_target}'; refuse to mount. Remove the symlink or set mounts.symlinks.on_dangling=skip to unblock." >&2
        exit 1
      fi

      # Also check against already-planned bind-mount targets.
      local _sfl_collision=0
      local _sfl_arg
      for _sfl_arg in "${_UP_RUN_ARGS[@]+"${_UP_RUN_ARGS[@]}"}"; do
        # -v args look like: source:dest[:opts]
        if [[ "$_sfl_arg" == /* ]]; then
          local _sfl_dest
          _sfl_dest="${_sfl_arg#*/}"
          _sfl_dest="/${_sfl_dest%%:*}"
          if [[ "$_sfl_target" == "$_sfl_dest" || "$_sfl_target" == "${_sfl_dest}/"* ]]; then
            _sfl_collision=1
            break
          fi
        fi
      done
      if [[ "$_sfl_collision" -eq 1 ]]; then
        echo "[rip-cage] Warning: symlink at '${_sfl_link}' → '${_sfl_target}' collides with existing mount; skipping." >&2
        continue
      fi

      # Determine mount source based on scope.
      local _sfl_mount_src
      if [[ "$_sfl_scope" == "parent" ]]; then
        _sfl_mount_src=$(dirname "$_sfl_target")
      else
        _sfl_mount_src="$_sfl_target"
      fi

      # ADR-023 D5/D6 incidental-tier: check the ACTUAL mount source against the denylist.
      # ADR-023 D7 FIRM: check what actually mounts — _sfl_mount_src (parent dir under
      # scope=parent, leaf under scope=file), not the leaf $_sfl_target unconditionally.
      # Warn-and-skip (not fail-loud) — dangling dotfile symlinks are incidental surfaces.
      if _check_secret_path_denylist "$_sfl_mount_src" "$_path"; then
        local _sfl_denied_pat
        _sfl_denied_pat=$(_secret_path_denylist_matched_pattern "$_sfl_mount_src" "$_path" 2>/dev/null || true)
        echo "Warning: skipping symlink-follow mount ${_sfl_mount_src} — matched secret-path denylist pattern '${_sfl_denied_pat:-<unknown>}'" >&2
        continue
      fi

      # Mount spec (mode).
      local _sfl_mode_suffix=""
      [[ "$_sfl_mode" == "ro" ]] && _sfl_mode_suffix=":ro"

      case "$_sfl_on_dangling" in
        follow|warn)
          # Always log per ADR-001 D1 (unconditional mount-expansion log).
          echo "[rip-cage] follow-symlink: ${_sfl_link} → ${_sfl_target} (${_sfl_mode})" >&2
          _UP_RUN_ARGS+=(-v "${_sfl_mount_src}:${_sfl_mount_src}${_sfl_mode_suffix}")
          ;;
        skip)
          echo "[rip-cage] Warning: dangling symlink at '${_sfl_link}' → '${_sfl_target}'; skipping mount (mounts.symlinks.on_dangling=skip)." >&2
          ;;
        error)
          echo "[rip-cage] Error: dangling symlink at '${_sfl_link}' targets '${_sfl_target}'; set mounts.symlinks.on_dangling=follow or skip in .rip-cage.yaml to unblock." >&2
          exit 1
          ;;
      esac
    done <<< "$_sfl_collected"
  done
  unset _SFL_SCAN_ROOTS _SFL_RESERVED_CAGE_PATHS
  unset _sfl_on_dangling _sfl_scope _sfl_mode _sfl_cfg_result
  unset _sfl_root _sfl_link _sfl_target _sfl_collected
  unset _sfl_reserved _sfl_rp _sfl_collision _sfl_arg _sfl_dest
  unset _sfl_mount_src _sfl_mode_suffix

  # Pi state: container-local cage-owned dir + narrow durable sub-mounts (ADR-019 D1 evolved).
  # PI_CODING_AGENT_DIR points to the container-local dir; only auth.json is
  # bind-mounted from the host (RW, cold-start-seeded so first-run pi /login persists —
  # rip-cage-wo9 / ADR-019 D1).  bin/ is intentionally NOT mounted: host macOS binaries
  # (fd/rg) don't work in Linux; the container regenerates them on first pi run.
  # PI_CODING_AGENT_DIR: explicit set equals pi's own default (config.ts getAgentDir()
  # returns join(homedir(), ".pi", "agent") when the env var is unset), so a pi-less
  # cage behaves identically — the explicit set just makes the value visible in `env`.
  # Seed an empty auth.json when absent so the bind mount below always fires (normal path).
  # A dangling symlink is left to the symlink-follow machinery (D1).
  # auth.credential_mounts=none (rip-cage-seqc.4) / effective(pi) (rip-cage-xhgr):
  # the pi auth.json bind is gated under non-possession; PI_CODING_AGENT_DIR
  # stays unconditional (it's a container-local dir pointer, not a host
  # credential mount).
  _UP_RUN_ARGS+=(-e PI_CODING_AGENT_DIR=/home/agent/.pi/agent)
  if [[ "$_UP_CRED_MOUNTS_PI" == "none" ]]; then
    log "auth.credential_mounts=none — pi credential mount (auth.json) intentionally skipped (non-possession posture)"
  else
    _ensure_pi_auth_seed
    if [[ -f "${HOME}/.pi/agent/auth.json" ]]; then
      _UP_RUN_ARGS+=(-v "${HOME}/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json")
    else
      log "Warning: ${HOME}/.pi/agent/auth.json not mounted (absent and could not be seeded, or a dangling symlink) — pi will require login on first request."
    fi
  fi

  # Pi substrate projection (rip-cage-kstk): mount pi instruction-content assets
  # read-only into .rc-context/ for init-rip-cage.sh to symlink.
  # DATA-DRIVEN table: each entry is "host-path:cage-name" (NO per-agent if/elif branch —
  # ADR-005 D12). Realpaths are resolved here so Docker mounts the real dir even when the
  # host path is a relative symlink (dotpi uses relative symlinks into ~/code/personal/dotpi/).
  # ADR-023 denylist check on each resolved host path: warn-and-skip on match.
  # ADR-027 D1: all mounts are :ro (no cage→host write-back).
  #
  # NOTE (rip-cage-l72i.3): pi extension mounts are NO LONGER hardcoded here.
  # Extensions are declared as manifest mounts in the relevant recipe fragment
  # and assembled by _manifest_build_mount_args below (ADR-005 D12 / ADR-027 D3/D4).
  if [[ -d "${HOME}/.pi/agent" ]]; then
    local _pi_substrate_entry _pi_host_raw _pi_cage_name _pi_host_real _pi_pat
    local _pi_substrate_table
    _pi_substrate_table=(
      "skills:pi-skills"
      "prompts:pi-prompts"
      "roles:pi-roles"
      "AGENTS.md:pi-AGENTS.md"
      "SYSTEM.md:pi-SYSTEM.md"
      "APPEND_SYSTEM.md:pi-APPEND_SYSTEM.md"
    )
    for _pi_substrate_entry in "${_pi_substrate_table[@]}"; do
      _pi_host_raw="${HOME}/.pi/agent/${_pi_substrate_entry%%:*}"
      _pi_cage_name="${_pi_substrate_entry##*:}"
      # Skip absent host paths (dir or file)
      if [[ ! -e "${_pi_host_raw}" ]]; then
        continue
      fi
      # Resolve realpath so relative dotpi symlinks mount the actual target
      _pi_host_real=$(realpath "${_pi_host_raw}" 2>/dev/null || echo "${_pi_host_raw}")
      # ADR-023 denylist: warn-and-skip on match
      if _check_secret_path_denylist "${_pi_host_real}" "${_path}"; then
        _pi_pat=$(_secret_path_denylist_matched_pattern "${_pi_host_real}" "${_path}" 2>/dev/null || true)
        echo "Warning: skipping pi substrate mount ${_pi_host_real} — matched secret-path denylist pattern '${_pi_pat:-<unknown>}'" >&2
        continue
      fi
      _UP_RUN_ARGS+=(-v "${_pi_host_real}:/home/agent/.rc-context/${_pi_cage_name}:ro")
    done
    unset _pi_substrate_table _pi_substrate_entry _pi_host_raw _pi_cage_name _pi_host_real _pi_pat
  fi

  # CAGE_HOST_ADDR explicit pass-through for non-interactive pi -p runs.
  # Resolve on the host side so the value is never empty inside the container.
  # host.docker.internal is the default (works on Docker Desktop/macOS/Linux with host-gateway).
  _UP_RUN_ARGS+=(-e "CAGE_HOST_ADDR=${CAGE_HOST_ADDR:-host.docker.internal}")

  # Provider env-var passthrough (ADR-019 D5 FLEXIBLE — fixed list, skip empty values)
  # PI_PACKAGE_DIR excluded: host dev path, breaks pi startup in cage
  local _pi_env_vars
  local _pi_var
  _pi_env_vars=(
    ANTHROPIC_API_KEY AZURE_OPENAI_API_KEY OPENAI_API_KEY GEMINI_API_KEY
    MISTRAL_API_KEY GROQ_API_KEY CEREBRAS_API_KEY XAI_API_KEY
    OPENROUTER_API_KEY AI_GATEWAY_API_KEY ZAI_API_KEY OPENCODE_API_KEY
    KIMI_API_KEY MINIMAX_API_KEY MINIMAX_CN_API_KEY
    PI_SKIP_VERSION_CHECK PI_CACHE_RETENTION
  )
  for _pi_var in "${_pi_env_vars[@]}"; do
    if [[ -n "${!_pi_var:-}" ]]; then
      _UP_RUN_ARGS+=(-e "${_pi_var}=${!_pi_var}")
    fi
  done
  unset _pi_env_vars _pi_var

  # CLAUDE.md mounts (read-only, only if source exists)
  if [[ -f "${HOME}/.claude/CLAUDE.md" ]]; then
    _UP_RUN_ARGS+=(-v "${HOME}/.claude/CLAUDE.md:/home/agent/.rc-context/global-claude.md:ro")
  fi
  if [[ -f "${HOME}/CLAUDE.md" ]]; then
    _UP_RUN_ARGS+=(-v "${HOME}/CLAUDE.md:/home/agent/.rc-context/home-claude.md:ro")
  fi

  # Claude session persistence to host (rip-cage-dn2)
  # Bind-mount host ~/.claude/projects and ~/.claude/sessions so JSONL session
  # logs survive container destroy and are visible to host tools (cass etc.).
  # The -workspace project key is unified with the host's encoded path key
  # inside init-rip-cage.sh, using RC_HOST_PROJECT_KEY below.
  # Dir-seed must happen before this mount (rip-cage-xuy8, ADR-029 D4
  # resume-path corollary) — see _seed_claude_home_dirs above.
  _seed_claude_home_dirs "${HOME}/.claude"
  _UP_RUN_ARGS+=(-v "${HOME}/.claude/projects:/home/agent/.claude/projects")
  _UP_RUN_ARGS+=(-v "${HOME}/.claude/sessions:/home/agent/.claude/sessions")
  local _host_project_key
  _host_project_key=$(printf '%s' "$_path" | tr '/.' '-')
  mkdir -p "${HOME}/.claude/projects/${_host_project_key}"
  _UP_RUN_ARGS+=(-e "RC_HOST_PROJECT_KEY=${_host_project_key}")

  # Manifest-declared data mounts (rip-cage-buuo.1 / ADR-005 D7, D9).
  # Turn each manifest tool's mounts: [{host, dest, mode, root_owned_required}, ...] into -v args.
  # _manifest_build_mount_args emits "host:dest:mode" lines (no -v prefix); we add
  # -v as a separate array element for the two-element docker run form.
  # mode defaults to 'ro' (rip-cage-wlwc.3 / ADR-027 D1); rw opt-in is explicit.
  # The denylist pre-check at cmd_up already fired (rc:4048); this consumer runs
  # after that gate so denylist denials here are impossible in normal flow.
  local _mba_out _mba_rc=0
  _mba_out=$(_manifest_build_mount_args "$_path") || _mba_rc=$?
  if [[ "$_mba_rc" -ne 0 ]]; then
    echo "[rip-cage] Error: manifest mount denied by denylist — rc up refused. (ADR-023 D1/D6)" >&2
    exit 1
  fi
  local _mba_line
  while IFS= read -r _mba_line; do
    [[ -z "$_mba_line" ]] && continue
    _UP_RUN_ARGS+=(-v "$_mba_line")
  done <<<"$_mba_out"
  unset _mba_line _mba_out _mba_rc

  # State volumes
  _UP_RUN_ARGS+=(-v "rc-state-${_name}:/home/agent/.claude-state")
  _UP_RUN_ARGS+=(-v "rc-history-${_name}:/commandhistory")
  _UP_RUN_ARGS+=(-v "rc-mise-cache:/home/agent/.local/share/mise")
}


# _resolve_host_ssh_sock — select the host ssh-agent socket to forward.
#
# Parameters:      $1  rc_forward_ssh — "on" or "off"
# Globals written: _RESOLVE_HOST_SSH_SOCK_RESULT (empty = nothing usable)
#
# Logic:
#   - If rc_forward_ssh == "off": return immediately with empty result.
#   - Linux/WSL2: use $SSH_AUTH_SOCK directly (same kernel as Docker, no VM
#     boundary). Reachability is checked by the in-container preflight.
#   - macOS: return /run/host-services/ssh-auth.sock unconditionally. This is
#     the only path OrbStack and Docker Desktop actually proxy across the VM
#     boundary — it's a VM-internal path (not visible on the macOS host
#     filesystem) that docker resolves at bind-mount time. Arbitrary paths
#     like $SSH_AUTH_SOCK probe OK from a host shell but yield "Connection
#     refused" inside the cage, so host-side probing was empirically
#     meaningless and has been removed (ADR-018 amendment, 2026-04-24).
_resolve_host_ssh_sock() {
  local _rc_forward_ssh="${1:-on}"
  _RESOLVE_HOST_SSH_SOCK_RESULT=""

  # Short-circuit when forwarding is disabled — no latency added.
  if [[ "$_rc_forward_ssh" == "off" ]]; then
    return
  fi

  if [[ "$(uname)" == "Darwin" ]]; then
    _RESOLVE_HOST_SSH_SOCK_RESULT="/run/host-services/ssh-auth.sock"
    return
  fi

  # Linux / WSL2: $SSH_AUTH_SOCK is a normal AF_UNIX socket on the same kernel
  # Docker runs on. Any existing socket is bind-mountable directly.
  local _candidate="${SSH_AUTH_SOCK:-}"
  if [[ -n "$_candidate" ]] && [[ -S "$_candidate" ]]; then
    _RESOLVE_HOST_SSH_SOCK_RESULT="$_candidate"
  fi
}


# _up_prepare_environment — build the env (-e), resource-limit, and beads portions of run_args.
#
# Globals written: _UP_RUN_ARGS (appended to)
# Parameters:
#   $1  path          — validated workspace path
#   $2  port          — optional host port to expose (pass "" to skip)
#   $3  env_file      — optional path to env file   (pass "" to skip)
#   $4  rc_cpus       — CPU limit
#   $5  rc_memory     — memory limit
#   $6  rc_pids_limit — PID limit
#   $7  rc_forward_ssh — ssh-agent forwarding ("on" or "off")
_up_prepare_environment() {
  local _path="$1" _port="$2" _env_file="$3" _rc_cpus="$4" _rc_memory="$5" _rc_pids_limit="$6" _rc_forward_ssh="${7:-on}"

  # Forward git identity from host
  local git_name git_email
  git_name=$(git config user.name 2>/dev/null || true)
  git_email=$(git config user.email 2>/dev/null || true)
  if [[ -n "$git_name" ]]; then
    _UP_RUN_ARGS+=(-e "GIT_AUTHOR_NAME=${git_name}")
  fi
  if [[ -n "$git_email" ]]; then
    _UP_RUN_ARGS+=(-e "GIT_AUTHOR_EMAIL=${git_email}")
  fi

  # Optional flags
  if [[ -n "$_port" ]]; then
    _UP_RUN_ARGS+=(-p "${_port}:${_port}")
  fi
  if [[ -n "$_env_file" ]]; then
    _UP_RUN_ARGS+=(--env-file "$_env_file")
  fi

  # Resource limits (D2)
  _UP_RUN_ARGS+=(--cpus="$_rc_cpus" --memory="$_rc_memory" --memory-swap="$_rc_memory" --pids-limit="$_rc_pids_limit")

  # Enable host.docker.internal on Linux Docker Engine (no-op on macOS where it exists natively)
  _UP_RUN_ARGS+=(--add-host=host.docker.internal:host-gateway)

  # Beads: configure container based on project's storage mode (metadata.json dolt_mode)
  local beads_dir="${_path}/.beads"
  # Resolve beads redirect (worktrees share .beads/ via a redirect file)
  if [[ -f "${beads_dir}/redirect" ]]; then
    local redirect_target
    redirect_target=$(cat "${beads_dir}/redirect")
    # Security: reject absolute paths and control characters in redirect
    if [[ "$redirect_target" == /* ]] || [[ "$redirect_target" =~ [[:cntrl:]] ]]; then
      log "Warning: .beads/redirect contains absolute path or control chars — ignoring"
    else
      # Redirect is relative to the workspace root (project directory)
      local resolved_beads
      resolved_beads=$(realpath "${_path}/${redirect_target}" 2>/dev/null || true)
      if [[ -n "$resolved_beads" && -d "$resolved_beads" ]]; then
        # Validate resolved path is under an allowed root (ADR-003 D3)
        if _path_under_allowed_roots "$resolved_beads"; then
          # ADR-023 D6: denylist check on .beads/redirect resolved target.
          if _check_secret_path_denylist "$resolved_beads" "$_path"; then
            local _beads_pat
            _beads_pat=$(_secret_path_denylist_matched_pattern "$resolved_beads" "$_path" 2>/dev/null || true)
            _emit_denylist_denial "$resolved_beads" "${_beads_pat:-<unknown>}"
            exit 1
          fi
          log "Beads: resolved redirect → $resolved_beads"
          beads_dir="$resolved_beads"
          # Mount the real .beads/ over the worktree's redirect
          _UP_RUN_ARGS+=(-v "${resolved_beads}:/workspace/.beads:delegated")
        else
          log "Warning: .beads/redirect resolves to $resolved_beads which is outside allowed roots — ignoring"
        fi
      else
        log "Warning: .beads/redirect points to $redirect_target but could not resolve"
      fi
    fi
  elif [[ "$wt_detected" == "true" ]] \
    && [[ ! -f "${beads_dir}/dolt-server.port" ]] \
    && [[ ! -d "${beads_dir}/dolt" ]] \
    && [[ ! -d "${beads_dir}/embeddeddolt" ]]; then
    # ADR-007 D6: worktree has no explicit redirect and no runtime Dolt data
    # (no port file, no server dolt/ dir, no embedded dolt dir). A fresh git
    # worktree inherits tracked .beads/ files (metadata.json, config.yaml) but
    # not the gitignored runtime files. Without this fallback, bd inside the
    # container would connect to host.docker.internal:0 (no port) or try to
    # use an empty embedded engine. Fix: mount the main repo's .beads/ over
    # the worktree's .beads/, same mechanism as an explicit redirect.
    local main_repo_root main_beads_dir resolved_main_beads
    main_repo_root=$(dirname "$wt_main_git")
    main_beads_dir="${main_repo_root}/.beads"
    # Resolve symlinks before the allowed-roots check (ADR-003 D3): a
    # .beads/ symlink pointing outside allowed roots would pass a string
    # check while the bind-mount would follow the symlink to the real target.
    resolved_main_beads=$(realpath "$main_beads_dir" 2>/dev/null || true)
    if [[ -z "$resolved_main_beads" || ! -d "$resolved_main_beads" ]]; then
      log "Warning: worktree auto-redirect — main repo .beads/ not found at $main_beads_dir; bd will fail inside the container (see wrapper diagnostic)"
    elif ! _path_under_allowed_roots "$resolved_main_beads"; then
      log "Warning: worktree auto-redirect — main repo .beads/ at $resolved_main_beads is outside RC_ALLOWED_ROOTS; refusing to mount (ADR-003 D3)"
    else
      log "Beads: worktree has no runtime data — auto-redirecting to main repo .beads/ ($resolved_main_beads)"
      beads_dir="$resolved_main_beads"
      _UP_RUN_ARGS+=(-v "${resolved_main_beads}:/workspace/.beads:delegated")
    fi
  fi
  # Determine beads storage mode from metadata.json
  local beads_dolt_mode=""
  if [[ -f "${beads_dir}/metadata.json" ]]; then
    beads_dolt_mode=$(jq -r '.dolt_mode // empty' "${beads_dir}/metadata.json" 2>/dev/null || true)
  fi
  if [[ "$beads_dolt_mode" == "embedded" ]] || [[ -z "$beads_dolt_mode" ]]; then
    # Embedded Dolt or no metadata: let bd use embedded engine on bind mount
    log "Beads: embedded mode — no Dolt server connection"
  else
    # Server/owned/external mode: connect to host's Dolt server
    _UP_RUN_ARGS+=(-e "BEADS_DOLT_SERVER_MODE=1")
    _UP_RUN_ARGS+=(-e "BEADS_DOLT_SERVER_HOST=host.docker.internal")
    local dolt_port_file="${beads_dir}/dolt-server.port"
    local _dolt_port_env_arg
    _dolt_port_env_arg=$(_bd_dolt_port_inject_arg "$dolt_port_file")
    if [[ -n "$_dolt_port_env_arg" ]]; then
      _UP_RUN_ARGS+=(-e "$_dolt_port_env_arg")
    fi
    log "Beads: server mode — connecting to host Dolt server"
    # ADR-007 D8: host-side pre-flight — warn if port is missing/stale/corrupt.
    # Must run AFTER D6 worktree auto-redirect (above) so beads_dir is resolved to
    # the main repo's .beads/ (matching what the container sees).
    # Warn-not-fail: bd is optional; broken bd state must not block the container
    # (explicit ADR-001 exception per ADR-007 D8 rationale).
    _bd_host_preflight "$beads_dir" "$beads_dolt_mode"
  fi

  # ssh-agent forwarding (ADR-017 + ADR-018): forward whichever host ssh-agent
  # the user actually populates. _resolve_host_ssh_sock() probes candidate
  # sockets and picks the first one with keys (or the first reachable one as
  # fallback). Keys themselves never enter the container — only signing
  # capability via the forwarded socket.
  _UP_FORWARD_SSH_HOST_SOCK=""
  _UP_NO_HOST_AGENT=""
  if [[ "$_rc_forward_ssh" != "off" ]]; then
    _resolve_host_ssh_sock "$_rc_forward_ssh"
    local _host_ssh_sock="$_RESOLVE_HOST_SSH_SOCK_RESULT"
    if [[ -n "$_host_ssh_sock" ]]; then
      # ADR-022 D3: when key filtering is active, mount host agent socket as
      # /ssh-agent-upstream.sock so ssh-agent-filter (launched by init-rip-cage.sh)
      # can read it as its upstream and expose its own filtered socket via the
      # /ssh-agent.sock symlink. When filtering is off, use the direct
      # /ssh-agent.sock destination (today's default path).
      if [[ "${_UP_SSH_FILTER_ACTIVE:-false}" == "true" ]]; then
        _UP_RUN_ARGS+=(-v "${_host_ssh_sock}:/ssh-agent-upstream.sock")
        _UP_RUN_ARGS+=(-e "SSH_AUTH_SOCK=/ssh-agent.sock")
      else
        _UP_RUN_ARGS+=(-v "${_host_ssh_sock}:/ssh-agent.sock")
        _UP_RUN_ARGS+=(-e "SSH_AUTH_SOCK=/ssh-agent.sock")
      fi
      _UP_RUN_ARGS+=(-l rc.forward-ssh=on)
      _UP_FORWARD_SSH_HOST_SOCK="$_host_ssh_sock"
    else
      log "Warning: ssh-agent forwarding requested but no reachable host agent found. Proceeding without forwarding; git push inside the cage will fail. Run 'ssh-add ~/.ssh/<key>' on host or pass --no-forward-ssh to suppress this warning."
      _UP_RUN_ARGS+=(-l rc.forward-ssh=off)
      _UP_NO_HOST_AGENT="1"
    fi
  else
    _UP_RUN_ARGS+=(-l rc.forward-ssh=off)
  fi
}


# _up_start_container — run the container with the prepared _UP_RUN_ARGS.
#
# Globals read: _UP_RUN_ARGS, OUTPUT_FORMAT
# Parameter: $1 name — container name (for error messages)
_up_start_container() {
  local _name="$1"
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    local docker_stderr
    # Note: inside $(...), redirects are evaluated left-to-right:
    # 2>&1 copies stderr to the capture pipe (stdout), then >/dev/null discards stdout —
    # capturing stderr while suppressing the container ID.
    if ! docker_stderr=$(docker run "${_UP_RUN_ARGS[@]}" 2>&1 >/dev/null); then
      if echo "$docker_stderr" | grep -q "is already in use by container"; then
        json_error "Container name $_name is already in use" "NAME_CONFLICT"
      fi
      json_error "Failed to create container $_name" "DOCKER_ERROR"
    fi
  else
    docker run "${_UP_RUN_ARGS[@]}"
  fi
}


# _up_init_container — run the in-container init script.
#
# Globals read:    OUTPUT_FORMAT
# Globals written: _UP_INIT_OK (set to "true" or "false")
# Parameter: $1 name — container name
_up_init_container() {
  local _name="$1"
  _UP_INIT_OK=true
  log "Running init script..."
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    docker exec "$_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || _UP_INIT_OK=false
  else
    docker exec "$_name" /usr/local/bin/init-rip-cage.sh || _UP_INIT_OK=false
  fi
}


# _up_resolve_resume_forward_ssh -- read and validate the rc.forward-ssh label on resume.
# ADR-017 D2: resume must preserve the original posture, not silently
# upgrade/downgrade based on current env.
# Missing label is treated as "off" (legacy pre-ADR-017 containers predate the
# label and never had forwarding wired). On success sets _UP_RESUME_FORWARD_SSH
# to "on" or "off"; fails loud on docker errors or unrecognized values.
# Parameters: $1 name, $2 path (used in the recreate hint)
_up_resolve_resume_forward_ssh() {
  local _name="$1" _path="$2"
  local _label
  if ! _label=$(docker inspect --format '{{ index .Config.Labels "rc.forward-ssh" }}' "$_name" 2>/dev/null); then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "docker inspect failed for $_name" "DOCKER_ERROR"
    fi
    echo "Error: docker inspect failed for $_name (is the Docker daemon running?)" >&2
    exit 1
  fi
  if [[ -z "$_label" ]]; then
    # Legacy container from before ADR-017 — treat as off (no forwarding was
    # configured when created). Not an error: old containers continue to work
    # in their original push-less posture.
    _UP_RESUME_FORWARD_SSH="off"
    return
  fi
  if [[ "$_label" != "on" && "$_label" != "off" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Container $_name has unrecognized rc.forward-ssh label value: '$_label' (expected on|off). Run: rc destroy $_name && rc up $_path" "INVALID_FORWARD_SSH_LABEL"
    fi
    echo "Error: container $_name has unrecognized rc.forward-ssh label value: '$_label' (expected on|off)." >&2
    echo "       Recreate it:" >&2
    echo "         rc destroy $_name" >&2
    echo "         rc up $_path" >&2
    exit 1
  fi
  _UP_RESUME_FORWARD_SSH="$_label"
}


# _up_resolve_resume_ssh_key_filter -- read and validate the rc.ssh-key-filter
# label on resume; abort loud if current effective config's ssh.allowed_keys
# state (null vs non-null) differs from the label.
#
# ADR-022: ssh.allowed_keys toggling between null and non-null is a mount-shape
# change (the /etc/rip-cage/ssh-allowed-keys bind mount appears or disappears).
# Mounts are immutable on resume, so silently re-reading effective config would
# leave init-rip-cage.sh consulting a stale sentinel (or missing one). Force
# rc destroy && rc up to apply the change. Mirrors _up_resolve_resume_ssh_config.
#
# Missing label is treated as "off" (legacy pre-ADR-022 containers predate the
# label and never had filtering wired). Sets _UP_RESUME_SSH_KEY_FILTER on success.
# Parameters: $1 name, $2 path
_up_resolve_resume_ssh_key_filter() {
  local _name="$1" _path="$2"
  local _label
  if ! _label=$(docker inspect --format '{{ index .Config.Labels "rc.ssh-key-filter" }}' "$_name" 2>/dev/null); then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "docker inspect failed for $_name" "DOCKER_ERROR"
    fi
    echo "Error: docker inspect failed for $_name (is the Docker daemon running?)" >&2
    exit 1
  fi
  if [[ -z "$_label" ]]; then
    _UP_RESUME_SSH_KEY_FILTER="off"
  elif [[ "$_label" != "on" && "$_label" != "off" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Container $_name has unrecognized rc.ssh-key-filter label value: '$_label' (expected on|off). Run: rc destroy $_name && rc up $_path" "INVALID_SSH_KEY_FILTER_LABEL"
    fi
    echo "Error: container $_name has unrecognized rc.ssh-key-filter label value: '$_label' (expected on|off)." >&2
    echo "       Recreate it:" >&2
    echo "         rc destroy $_name" >&2
    echo "         rc up $_path" >&2
    exit 1
  else
    _UP_RESUME_SSH_KEY_FILTER="$_label"
  fi

  # Compute current effective ssh.allowed_keys state from on-disk config.
  # null → "off" (no filtering); [] or [...] → "on" (filtering active).
  local _eff_result _eff_keys _current
  _eff_result=$(_load_effective_config "$_path" 2>/dev/null || true)
  if [[ -z "$_eff_result" ]]; then
    _current="off"
  else
    _eff_keys=$(jq -c '.config.ssh.allowed_keys' <<<"$_eff_result" 2>/dev/null || echo "null")
    if [[ "$_eff_keys" == "null" ]]; then
      _current="off"
    else
      _current="on"
    fi
  fi

  if [[ "$_UP_RESUME_SSH_KEY_FILTER" != "$_current" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Container $_name was created with rc.ssh-key-filter=${_UP_RESUME_SSH_KEY_FILTER} but current effective config has ssh.allowed_keys filter=${_current}. Mount shape is immutable on resume — run: rc destroy $_name && rc up $_path to apply the change." "SSH_KEY_FILTER_MOUNT_SHAPE_CHANGED"
    fi
    echo "Error: container $_name was created with rc.ssh-key-filter=${_UP_RESUME_SSH_KEY_FILTER} but current effective config has ssh.allowed_keys filter=${_current}." >&2
    echo "       The /etc/rip-cage/ssh-allowed-keys bind mount is wired at create time; toggling ssh.allowed_keys between null and non-null requires recreating the container." >&2
    echo "       Run:" >&2
    echo "         rc destroy $_name" >&2
    echo "         rc up $_path" >&2
    exit 1
  fi
}


# _up_resolve_resume_config_mode -- read and validate the rc.config-mode
# label on resume; abort loud if current effective config's mounts.config_mode
# differs from the label (ro↔rw is a mount-shape transition — the nested
# :ro shadow-mount either exists or doesn't; immutable on resume).
#
# ADR-021 D7: mounts.config_mode toggles whether a nested :ro bind-mount is
# added over /workspace/.rip-cage.yaml. Silently re-using a stale mount would
# leave the agent with a mount shape inconsistent with what the user configured.
# Mirrors _up_resolve_resume_ssh_key_filter.
#
# Missing label (legacy container, pre-cw51): treated as "ro" (the default);
# if current effective config is also ro (or absent), no mismatch.
# Parameters: $1 name, $2 path
_up_resolve_resume_config_mode() {
  local _name="$1" _path="$2"
  local _label
  if ! _label=$(docker inspect --format '{{ index .Config.Labels "rc.config-mode" }}' "$_name" 2>/dev/null); then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "docker inspect failed for $_name" "DOCKER_ERROR"
    fi
    echo "Error: docker inspect failed for $_name (is the Docker daemon running?)" >&2
    exit 1
  fi
  # Empty label = legacy container; treat as "ro" (the default, matches the
  # shadow-mount-added-by-default posture of pre-label containers).
  local _stored_mode
  if [[ -z "$_label" ]]; then
    _stored_mode="ro"
  else
    _stored_mode="$_label"
  fi

  # Compute current effective mounts.config_mode from on-disk config.
  local _eff_result _current
  _eff_result=$(_load_effective_config "$_path" 2>/dev/null || true)
  if [[ -z "$_eff_result" ]]; then
    _current="ro"
  else
    _current=$(jq -r '.config.mounts.config_mode // "ro"' <<<"$_eff_result" 2>/dev/null || echo "ro")
  fi

  if [[ "$_stored_mode" != "$_current" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Container $_name was created with rc.config-mode=${_stored_mode} but current effective config has mounts.config_mode=${_current}. Mount shape is immutable on resume — run: rc destroy $_name && rc up $_path to apply the change." "CONFIG_MODE_MOUNT_SHAPE_CHANGED"
    fi
    echo "Error: container $_name was created with rc.config-mode=${_stored_mode} but current effective config has mounts.config_mode=${_current}." >&2
    echo "       The /workspace/.rip-cage.yaml :ro shadow-mount is wired at create time; toggling mounts.config_mode between ro and rw requires recreating the container." >&2
    echo "       Run:" >&2
    echo "         rc destroy $_name" >&2
    echo "         rc up $_path" >&2
    exit 1
  fi
}


# _up_short_image_id -- strip the sha256: prefix and truncate to 12 hex chars,
# matching docker's own short-ID convention (what `docker images` displays).
# Used only for human/JSON message formatting — comparisons always use the
# full sha256:... IDs (_up_image_drift_status below).
_up_short_image_id() {
  local _id="${1#sha256:}"
  echo "${_id:0:12}"
}


# _up_image_drift_status (rip-cage-jnvb / D-a) — compare the image ID a
# container is pinned to (docker inspect --format '{{.Image}}') against the
# currently resolved $IMAGE (honors $IMAGE/RC_IMAGE, rc:45 — never hardcode
# rip-cage:latest). Both formats always return a sha256:... ID (reviewer-
# confirmed: no "<no value>" shape risk), so comparing by ID is robust to the
# old image becoming untagged/dangling after a rebuild.
#
# ROOT CAUSE this guards against: `rc build` creates a new image, but an
# already-existing stopped container stays pinned to the OLD image ID.
# Blind-resuming ran the NEW image's resume logic (e.g. mediator init
# docker-execs a script baked into the image, rc:3839) against the OLD
# container's filesystem -> raw OCI "stat ... no such file" crash + self-stop.
#
# SCOPE BOUND (design D-a): this only catches image/container ID drift. It
# does NOT catch "rc script updated without rebuild" (same image ID,
# different resume logic) — that adjacent class is rip-cage-h2hl.
#
# Single-sourced comparator behind two thin per-branch wrappers (mirrors the
# mode-arg-or-thin-wrappers guidance in the design):
#   _up_resolve_resume_image_drift_stopped — abort loud, before docker start
#   _up_resolve_resume_image_drift_running — warn-only, proceed
#
# This comparator NEVER calls exit/json_error itself (post-review M2
# hardening) — the abort-vs-warn decision belongs entirely to the calling
# wrapper. A transient docker-inspect failure on the CONTAINER (e.g. a
# TOCTOU race — the container was removed between cmd_up's state-check and
# this guard) must hard-abort on the stopped branch (unchanged, matches
# every sibling resolver's fail-loud idiom) but must NOT abort on the
# running branch (D-c: never interrupt a live agent session over an
# unverifiable-but-not-necessarily-broken drift check). Forking the compare
# logic per branch would violate the single-sourced-comparator design intent
# — instead, the failure is reported via a distinct status code and each
# wrapper decides what to do with it.
#
# Sets _UP_IMAGE_DRIFT_STORED / _UP_IMAGE_DRIFT_CURRENT (short IDs, for
# message reuse by the wrappers above; empty on status 3).
# Returns: 0 = match, 1 = mismatch, 2 = current image ($IMAGE) not found,
#          3 = docker inspect failed for the CONTAINER itself.
# Parameters: $1 name
_up_image_drift_status() {
  local _name="$1"
  local _stored_image
  if ! _stored_image=$(docker inspect --format '{{.Image}}' "$_name" 2>/dev/null); then
    _UP_IMAGE_DRIFT_STORED=""
    _UP_IMAGE_DRIFT_CURRENT=""
    return 3
  fi
  _UP_IMAGE_DRIFT_STORED=$(_up_short_image_id "$_stored_image")
  local _current_image
  if ! _current_image=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null); then
    _UP_IMAGE_DRIFT_CURRENT=""
    return 2
  fi
  _UP_IMAGE_DRIFT_CURRENT=$(_up_short_image_id "$_current_image")
  [[ "$_stored_image" == "$_current_image" ]] && return 0
  return 1
}


# _up_resolve_resume_image_drift_stopped (rip-cage-jnvb / D-b, D-f) — abort
# loud BEFORE docker start when the stopped container's pinned image drifted
# from (or the current image is missing relative to) $IMAGE. Slotted with the
# other _up_resolve_resume_* guards, before the single docker start call site
# (rc cmd_up stopped-branch — D-g entrypoint sweep confirmed only one). No
# auto-destroy/auto-recreate: abort-loud matches the label-lock guard family
# (ADR-021 D4a/D5). Resume must NEVER itself trigger a pull/build
# (rc:4550-4552 invariant) — this function only compares and aborts/returns,
# it never calls _pull_or_build.
# Parameters: $1 name, $2 path
_up_resolve_resume_image_drift_stopped() {
  local _name="$1" _path="$2"
  local _status=0
  # `|| _status=$?` (not a bare call + separate `$?` read) — under set -e,
  # a plain non-conditional statement that returns non-zero aborts the
  # script right there, before `_status=$?` ever runs.
  _up_image_drift_status "$_name" || _status=$?
  [[ "$_status" -eq 0 ]] && return 0

  if [[ "$_status" -eq 3 ]]; then
    # Container-inspect itself failed. Unchanged from the pre-M2-hardening
    # behavior (this used to live inline in the comparator) — the stopped
    # path still has no safe default here and aborts, matching every sibling
    # _up_resolve_resume_* resolver's docker-inspect-failure idiom.
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "docker inspect failed for $_name" "DOCKER_ERROR"
    fi
    echo "Error: docker inspect failed for $_name (is the Docker daemon running?)" >&2
    exit 1
  fi

  if [[ "$_status" -eq 2 ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Current image '${IMAGE}' not found — cannot verify container ${_name} is compatible with it. Run: rc build (then retry rc up ${_path}), or re-run with the RC_IMAGE this cage was created from, or rc destroy ${_name} && rc up ${_path}." "RESUME_IMAGE_NOT_FOUND"
    fi
    echo "Error: current image '${IMAGE}' not found — cannot verify container ${_name} is compatible with it." >&2
    echo "       Resuming would risk running mismatched resume logic against this container's filesystem (ADR-001: no safe default when compatibility is unverifiable)." >&2
    echo "       Options:" >&2
    echo "         rc build                                    (build the image, then retry: rc up ${_path})" >&2
    echo "         RC_IMAGE=<original image> rc up ${_path}    (if this cage was created from a custom-pinned image)" >&2
    echo "         rc destroy ${_name} && rc up ${_path}        (recreate from scratch)" >&2
    exit 1
  fi

  # _status == 1: mismatch.
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    json_error "Container ${_name} was created from image ${_UP_IMAGE_DRIFT_STORED} but the current image ${IMAGE} is ${_UP_IMAGE_DRIFT_CURRENT} — rc up refuses to blind-resume a container pinned to a stale image. Run: rc destroy ${_name} && rc up ${_path}; or if this cage was intentionally created from a custom image, re-run with the same RC_IMAGE it was created with." "IMAGE_DRIFT_STALE_CONTAINER"
  fi
  echo "Error: container ${_name} was created from image ${_UP_IMAGE_DRIFT_STORED}, but the current image ${IMAGE} is ${_UP_IMAGE_DRIFT_CURRENT}." >&2
  echo "       rc up refuses to blind-resume a container pinned to a stale image — a rebuilt image's resume logic (e.g. mediator init) can crash against this container's older filesystem." >&2
  echo "       Run:" >&2
  echo "         rc destroy ${_name}" >&2
  echo "         rc up ${_path}" >&2
  echo "       If this cage was intentionally created from a custom-pinned image, re-run with the same RC_IMAGE it was created with instead of destroying it:" >&2
  echo "         RC_IMAGE=<original image> rc up ${_path}" >&2
  exit 1
}


# _up_resolve_resume_image_drift_running (rip-cage-jnvb / D-c) — warn-only on
# a running container with a drifted image, then proceed. The running branch
# never calls mediator/firewall init or docker start on resume (it only execs
# into the container's OWN filesystem) — no crash path exists here, so
# refusing attach would interrupt a live agent session for no safety benefit
# (ADR-002 D5 autonomy).
#
# Post-review M2 hardening: ALL non-zero comparator statuses — including 3
# (the container's own docker-inspect call failed, e.g. a transient error or
# a TOCTOU race where the container vanished between cmd_up's state-check
# and this guard) — are warn-and-proceed here, never abort. A live agent
# session must not be interrupted just because the drift check itself
# couldn't be verified; that's a strictly weaker signal than a confirmed
# mismatch, so it cannot warrant a stronger (abort) response than mismatch
# already gets on this branch.
# Parameters: $1 name, $2 path
_up_resolve_resume_image_drift_running() {
  local _name="$1" _path="$2"
  local _status=0
  _up_image_drift_status "$_name" || _status=$?
  [[ "$_status" -eq 0 ]] && return 0

  if [[ "$_status" -eq 3 ]]; then
    echo "Warning: could not verify container ${_name}'s image (docker inspect failed) — skipping the image-drift check for this attach." >&2
    return 0
  fi

  if [[ "$_status" -eq 2 ]]; then
    echo "Warning: current image '${IMAGE}' not found — cannot verify container ${_name} is running the expected image (run: rc build)." >&2
    return 0
  fi

  echo "Warning: container ${_name} is running an older image (created from ${_UP_IMAGE_DRIFT_STORED}, current is ${_UP_IMAGE_DRIFT_CURRENT}) — the last 'rc build' will not apply until: rc destroy ${_name} && rc up ${_path} (or re-run with the RC_IMAGE this cage was created with, if intentionally pinned)." >&2
  return 0
}


# _up_resolve_effective_credential_mounts_for_tool (rip-cage-xhgr / D1) — the
# single jq expression backing every effective(T) computation site: the
# create-time resolver (cmd_up), the resume-side credential-mounts guard, and
# the resume-side symlink-follow fingerprint recompute all call this so the
# resolution rule (per_tool.T if set, else the global credential_mounts, else
# "real") never drifts between call sites.
# Parameters: $1 tool ("claude"|"pi"), $2 effective-config JSON (the object
#             returned by _load_effective_config, i.e. has a top-level .config)
# Output: "real" or "none" on stdout.
_up_resolve_effective_credential_mounts_for_tool() {
  local _tool="$1" _cfg_json="$2"
  jq -r --arg t "$_tool" '.config.auth.per_tool[$t] // .config.auth.credential_mounts // "real"' <<<"$_cfg_json"
}


# _up_resolve_resume_credential_mounts (rip-cage-seqc.4 / B1, per-tool grain
# rip-cage-xhgr / D5a) — clone of _up_resolve_resume_config_mode.
# auth.credential_mounts (+ per-tool overrides) is a create-time mount-shape
# decision (which host credential files get bind-mounted); it is not covered
# by mounts.config_mode's guard. Without this, flipping the effective value
# for a tool between create and resume would silently carry the create-time
# mount shape (a real cage resumed as "none" would keep believing it has no
# credentials mounted while the container still has them — or vice versa).
#
# Legacy derivation ladder per tool (D5a): stored(T) = the per-tool label
# (rc.auth.credential-mounts.claude / .pi) if present, ELSE the stored global
# label (rc.auth.credential-mounts) if present, ELSE "real" (the pre-seqc.4
# historical default). This means a container created BEFORE this bead (no
# per-tool labels at all) resumes clean as long as its effective per-tool
# values are unchanged from its stored global label — upgrading rc never
# bricks a running cage. Mismatch on EITHER tool refuses loud, naming the
# tool so the operator knows which one changed.
# Parameters: $1 name, $2 path
_up_resolve_resume_credential_mounts() {
  local _name="$1" _path="$2"

  local _label_global
  if ! _label_global=$(docker inspect --format '{{ index .Config.Labels "rc.auth.credential-mounts" }}' "$_name" 2>/dev/null); then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "docker inspect failed for $_name" "DOCKER_ERROR"
    fi
    echo "Error: docker inspect failed for $_name (is the Docker daemon running?)" >&2
    exit 1
  fi
  local _label_claude _label_pi
  _label_claude=$(docker inspect --format '{{ index .Config.Labels "rc.auth.credential-mounts.claude" }}' "$_name" 2>/dev/null || true)
  _label_pi=$(docker inspect --format '{{ index .Config.Labels "rc.auth.credential-mounts.pi" }}' "$_name" 2>/dev/null || true)

  # Empty global label = legacy container (pre-seqc.4); treat as "real".
  local _stored_global="real"
  [[ -n "$_label_global" ]] && _stored_global="$_label_global"

  # Per-tool label wins over the stored global label when both present.
  local _stored_claude="$_stored_global" _stored_pi="$_stored_global"
  [[ -n "$_label_claude" ]] && _stored_claude="$_label_claude"
  [[ -n "$_label_pi" ]] && _stored_pi="$_label_pi"

  # Compute current effective per-tool values from on-disk config.
  local _eff_result _current_claude="real" _current_pi="real"
  _eff_result=$(_load_effective_config "$_path" 2>/dev/null || true)
  if [[ -n "$_eff_result" ]]; then
    _current_claude=$(_up_resolve_effective_credential_mounts_for_tool "claude" "$_eff_result")
    _current_pi=$(_up_resolve_effective_credential_mounts_for_tool "pi" "$_eff_result")
  fi

  local _tool _stored _current
  for _tool in claude pi; do
    if [[ "$_tool" == "claude" ]]; then
      _stored="$_stored_claude"; _current="$_current_claude"
    else
      _stored="$_stored_pi"; _current="$_current_pi"
    fi
    if [[ "$_stored" != "$_current" ]]; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        json_error "Container $_name was created with effective auth.credential_mounts for ${_tool}=${_stored} but current effective config has ${_tool}=${_current}. Credential mounts are immutable on resume — run: rc destroy $_name && rc up $_path to apply the change." "CREDENTIAL_MOUNTS_MOUNT_SHAPE_CHANGED"
      fi
      echo "Error: container $_name was created with effective auth.credential_mounts for ${_tool}=${_stored} but current effective config has ${_tool}=${_current}." >&2
      echo "       Credential mounts are wired at create time; toggling auth.credential_mounts (or auth.per_tool.${_tool}) between real and none requires recreating the container." >&2
      echo "       Run:" >&2
      echo "         rc destroy $_name" >&2
      echo "         rc up $_path" >&2
      exit 1
    fi
  done
}


# _up_resolve_resume_symlink_fingerprint -- compare the rc.symlink-follow-fingerprint
# label on the existing container against the current host state. Abort loud if
# mismatch (mount-shape change — requires destroy and re-up per D4 FIRM).
# Missing label (pre-c1p.2 container) is treated as "no dangling symlinks at
# create time"; if current state also has none, no mismatch.
# Parameters: $1 name, $2 path
_up_resolve_resume_symlink_fingerprint() {
  local _name="$1" _path="$2"
  local _stored_fp
  _stored_fp=$(docker inspect --format '{{ index .Config.Labels "rc.symlink-follow-fingerprint" }}' "$_name" 2>/dev/null || true)

  # Compute current fingerprint — include mode, on_dangling, and scope so that
  # policy changes (not just symlink-set changes) produce fingerprint drift.
  local _sfl_cur_mode="rw" _sfl_cur_on_dangling="follow" _sfl_cur_scope="file"
  # rip-cage-seqc.4 / B1a call-site 2, effective(pi) (rip-cage-xhgr / D5b):
  # also read current effective(pi) — NEVER effective(claude); this
  # fingerprint's scan root is ~/.pi/agent only — so the recomputed
  # fingerprint reflects the SAME F1 leaf-filter the (immutable) create-time
  # mount set was built with. A pi flip (global or per_tool.pi) then changes
  # this fingerprint too — defense-in-depth alongside the dedicated
  # _up_resolve_resume_credential_mounts guard (B1), both fail loud, no
  # silent drift. Using effective(pi) here (not the bare global) is what
  # keeps a stable {claude:real, pi:none} cage's resume-side recompute
  # symmetric with its create-time fingerprint.
  local _sfl_cur_cred_mounts="real"
  if [[ -f "$(_config_global_path)" || -f "$(_config_project_path "${_path}")" ]]; then
    if command -v yq &>/dev/null; then
      local _sfl_cur_cfg
      if _sfl_cur_cfg=$(_load_effective_config "${_path}" 2>/dev/null); then
        _sfl_cur_mode=$(jq -r '.config.mounts.symlinks.mode // "rw"' <<<"$_sfl_cur_cfg")
        _sfl_cur_on_dangling=$(jq -r '.config.mounts.symlinks.on_dangling // "follow"' <<<"$_sfl_cur_cfg")
        _sfl_cur_scope=$(jq -r '.config.mounts.symlinks.scope // "file"' <<<"$_sfl_cur_cfg")
        _sfl_cur_cred_mounts=$(_up_resolve_effective_credential_mounts_for_tool "pi" "$_sfl_cur_cfg")
      fi
    fi
  fi
  local _current_fp
  _current_fp=$(_symlink_follow_fingerprint "${HOME}/.pi/agent" "$_sfl_cur_mode" "$_sfl_cur_on_dangling" "$_sfl_cur_scope" "$_path" "$_sfl_cur_cred_mounts")

  # Missing label: pre-c1p.2 container. Only block if current state has
  # dangling symlinks (non-trivial fingerprint would mean a new second mount
  # that was never wired into the container).
  if [[ -z "$_stored_fp" ]]; then
    local _empty_fp
    # B1a call-site 3: pi_root is empty so the loop body never runs and the
    # cred_mounts filter is INERT here — pass current for signature
    # consistency only (behavior is identical either way).
    _empty_fp=$(_symlink_follow_fingerprint "" "rw" "follow" "file" "." "$_sfl_cur_cred_mounts")  # empty set fp
    if [[ "$_current_fp" == "$_empty_fp" ]]; then
      return 0  # Both empty — no mismatch
    fi
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Container $_name predates symlink-follow mount support (no rc.symlink-follow-fingerprint label) but current host state has dangling symlinks that would require a second bind mount not wired into this container. Run: rc destroy $_name && rc up ${_path} to apply the change." "SYMLINK_FINGERPRINT_MOUNT_SHAPE_CHANGED"
    fi
    echo "Error: container $_name predates symlink-follow mount support (no rc.symlink-follow-fingerprint label)." >&2
    echo "       Current host has dangling symlinks that would require a second bind mount not wired into this container." >&2
    echo "       Run: rc destroy $_name && rc up ${_path}" >&2
    exit 1
  fi

  if [[ "$_stored_fp" != "$_current_fp" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Container $_name was created with rc.symlink-follow-fingerprint=${_stored_fp} but current host state has fingerprint=${_current_fp}. Mount shape (symlink-follow second bind mounts) is immutable on resume — run: rc destroy $_name && rc up ${_path} to apply the change." "SYMLINK_FINGERPRINT_MOUNT_SHAPE_CHANGED"
    fi
    echo "Error: container $_name was created with rc.symlink-follow-fingerprint=${_stored_fp} but current host state has fingerprint=${_current_fp}." >&2
    echo "       Mount shape (symlink-follow second bind mounts) is immutable on resume — destroy and re-up to apply mount-shape changes." >&2
    echo "       Run: rc destroy $_name && rc up ${_path}" >&2
    exit 1
  fi
}


# _tsc_process_file -- internal helper for _translate_ssh_config.
# Reads lines from $1 (file path), applies transforms 2-5, outputs to stdout.
# $2 is the effective ssh home dir (e.g., ~/.ssh, or $HOME/.ssh).
# Recursive include inlining calls this function again on include targets.
_tsc_process_file() {
  local _tsc_file="$1" _tsc_ssh_home="$2"
  local _tsc_line _tsc_indent _tsc_kw _tsc_kwlc _tsc_path _tsc_bn _tsc_lstr _tsc_lstr_lc

  while IFS= read -r _tsc_line || [[ -n "$_tsc_line" ]]; do
    # Strip leading whitespace to get keyword; lowercase for matching
    _tsc_lstr="${_tsc_line#"${_tsc_line%%[![:space:]]*}"}"
    _tsc_kw="${_tsc_lstr%%[[:space:]]*}"
    _tsc_kwlc=$(printf '%s' "$_tsc_kw" | tr '[:upper:]' '[:lower:]')
    _tsc_indent="${_tsc_line%%[! ]*}"

    case "$_tsc_kwlc" in
      # Transform 4: host-only directives → strip
      proxycommand|proxyjump|controlmaster|controlpath|identityagent)
        printf '%s# rip-cage: stripped (host-only)\n' "$_tsc_indent"
        continue
        ;;
      # Match exec is special — keyword is 'match'; only 'Match exec' is host-only
      match)
        _tsc_lstr_lc=$(printf '%s' "$_tsc_lstr" | tr '[:upper:]' '[:lower:]')
        if [[ "$_tsc_lstr_lc" =~ ^match[[:space:]]+exec([[:space:]]|$) ]]; then
          printf '%s# rip-cage: stripped (host-only)\n' "$_tsc_indent"
          continue
        fi
        ;;
      # Transform 5: ADR-014 D2 overrides — BatchMode/StrictHostKeyChecking only.
      # ADR-022 D4: UserKnownHostsFile/GlobalKnownHostsFile rewrites removed —
      # config-layer rewrites were bypassable theater (-o flag beats config);
      # mount-layer filtering via _filter_known_hosts is the real enforcement.
      batchmode)
        printf '%sBatchMode yes # rip-cage: overridden (ADR-014 D2)\n' "$_tsc_indent"
        continue
        ;;
      stricthostkeychecking)
        printf '%sStrictHostKeyChecking yes # rip-cage: overridden (ADR-014 D2)\n' "$_tsc_indent"
        continue
        ;;
      # Transform 2: IdentityFile path rewrite
      identityfile)
        # Extract path portion: strip "IdentityFile" keyword + leading spaces
        _tsc_path="${_tsc_lstr#"${_tsc_kw}"}"
        _tsc_path="${_tsc_path#"${_tsc_path%%[![:space:]]*}"}"
        # Tilde-expand
        _tsc_path="${_tsc_path/#~/$HOME}"
        _tsc_bn=$(basename "$_tsc_path")
        printf '%sIdentityFile /home/agent/.ssh/%s\n' "$_tsc_indent" "$_tsc_bn"
        continue
        ;;
      # Transform 3: Include directives
      include)
        _tsc_path="${_tsc_lstr#"${_tsc_kw}"}"
        _tsc_path="${_tsc_path#"${_tsc_path%%[![:space:]]*}"}"
        # Tilde-expand
        _tsc_path="${_tsc_path/#~/$HOME}"
        # In-home include → inline; out-of-home → strip
        if [[ "$_tsc_path" == "${_tsc_ssh_home}/"* ]]; then
          if [[ -f "$_tsc_path" ]]; then
            _tsc_process_file "$_tsc_path" "$_tsc_ssh_home"
          fi
          # Absent in-home include → silently skip
        else
          printf '%s# rip-cage: stripped (Include outside ~/.ssh/)\n' "$_tsc_indent"
        fi
        continue
        ;;
    esac

    # Default: pass through unchanged
    printf '%s\n' "$_tsc_line"
  done < "$_tsc_file"
}


# _translate_ssh_config -- ADR-020 D2 host-config translation engine.
# Applies six transforms to produce a cage-compatible SSH config:
#   1. IgnoreUnknown header (macOS directives shim)
#   2. IdentityFile path rewrite: ~/.ssh/<n> → /home/agent/.ssh/<n>
#   3. Include: in-home → inline recursively; out-of-home → strip with comment
#   4. Host-only directives strip: Match exec, ProxyCommand, ProxyJump, ControlMaster,
#      ControlPath, IdentityAgent → # rip-cage: stripped (host-only)
#   5. ADR-014 D2 overrides: BatchMode/StrictHostKeyChecking (ADR-022 D4: UserKnownHostsFile/
#      GlobalKnownHostsFile rewrites removed — mount-layer filtering is the real enforcement)
#   6. github.com synthesis: if key_basename non-empty and no Host github.com → append synth block
# Parameters:
#   $1 host_config_path    — path to host's ~/.ssh/config (may be absent)
#   $2 output_path         — idempotent write destination (parent dir must exist)
#   $3 resolved_key_basename — key basename for github.com synthesis (may be empty)
_translate_ssh_config() {
  local _hcfg="$1" _out="$2" _key_bn="$3"
  local _ssh_home="${HOME}/.ssh"

  # Check if Host github.com already present in raw input
  local _has_github=false
  if [[ -f "$_hcfg" ]]; then
    local _scan_line
    while IFS= read -r _scan_line; do
      if [[ "$_scan_line" =~ ^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+github\.com([[:space:]]|$) ]]; then
        _has_github=true
        break
      fi
    done < "$_hcfg"
  fi

  # Build output
  {
    # Transform 1: IgnoreUnknown header
    printf 'IgnoreUnknown UseKeychain,AddKeysToAgent\n'

    # Apply transforms 2-5 to host config lines (if file exists)
    if [[ -f "$_hcfg" ]]; then
      _tsc_process_file "$_hcfg" "$_ssh_home"
    fi

    # Transform 6: github.com synthesis
    if [[ -n "$_key_bn" && "$_has_github" == "false" ]]; then
      printf '\nHost github.com\n'
      printf '  User git\n'
      printf '  IdentityFile /home/agent/.ssh/%s\n' "$_key_bn"
      printf '  IdentitiesOnly yes\n'
    fi
  } > "$_out"
}


# _derive_pubkey_allowlist -- parse a translated SSH config and emit one <basename>.pub per line
# for each IdentityFile directive found. Used to build the pubkey mount allowlist (ADR-020 D1).
# Duplicates are collapsed (each basename appears once).
# Parameter: $1 translated_config_path — path to the translated ssh-config file
# Returns: newline-separated list of <basename>.pub filenames (stdout), empty if none.
_derive_pubkey_allowlist() {
  local _cfg="$1"
  local _line _kw _kw_lc _path _bn _seen_list

  if [[ ! -f "$_cfg" ]]; then
    return 0
  fi

  _seen_list=""
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    # Strip leading whitespace
    local _lstr="${_line#"${_line%%[![:space:]]*}"}"
    _kw="${_lstr%%[[:space:]]*}"
    _kw_lc=$(printf '%s' "$_kw" | tr '[:upper:]' '[:lower:]')
    if [[ "$_kw_lc" == "identityfile" ]]; then
      _path="${_lstr#"${_kw}"}"
      _path="${_path#"${_path%%[![:space:]]*}"}"
      _bn=$(basename "$_path")
      # Append .pub if not already a .pub filename
      if [[ "$_bn" != *.pub ]]; then
        _bn="${_bn}.pub"
      fi
      # Dedup: only emit if not yet seen (bash 3.2 compatible — no associative arrays)
      if [[ ":${_seen_list}:" != *":${_bn}:"* ]]; then
        _seen_list="${_seen_list}:${_bn}"
        printf '%s\n' "$_bn"
      fi
    fi
  done < "$_cfg"
}


# _assert_pubkey_exists_or_die -- enforce that a pubkey file exists on the host for an explicit pin.
# ADR-020 D4: explicit pin (layers 1-3) + missing .pub → abort non-zero with actionable error.
# For user-config-derived keys, use _build_ssh_mount_args' warn-and-skip path instead.
# Parameters:
#   $1 key_basename  — key basename WITHOUT .pub extension (e.g. id_ed25519_work)
#   $2 source_label  — human-readable source for the error message (e.g. "explicit", "rules-file")
# Returns: 0 if ~/.ssh/<key_basename>.pub exists; exits 1 with actionable error otherwise.
_assert_pubkey_exists_or_die() {
  local _kb="$1" _src="${2:-explicit}"
  local _pub_path="${HOME}/.ssh/${_kb}.pub"
  if [[ ! -f "$_pub_path" ]]; then
    echo "Error: ${_src} identity '${_kb}' selected, but ~/.ssh/${_kb}.pub does not exist on host." >&2
    echo "       Generate the key (ssh-keygen) or correct your identity rules." >&2
    return 1
  fi
}


# _filter_known_hosts -- filter ~/.ssh/known_hosts to only allowed host patterns.
# ADR-022 D3 host half: reads input file line-by-line, keeps lines where at least one
# host field matches an allowed_hosts pattern. Hashed entries (|1|salt|hash format) are
# resolved via HMAC-SHA1 against each exact (non-wildcard) pattern in the allowlist;
# matched hashed entries are written unhashed. Wildcard patterns against hashed entries
# are intractable — emit a warning with ssh-keyscan recipe and skip.
#
# Parameters:
#   $1 allowed_hosts   — space-separated list of patterns (empty = no patterns → empty output)
#   $2 input_path      — path to source known_hosts file (e.g., ~/.ssh/known_hosts)
#   $3 output_path     — path to write filtered output (created/overwritten)
# Side effects: warnings to stderr for wildcard + hashed entry conflicts; does not abort.
_filter_known_hosts() {
  local _allowed="$1" _input="$2" _output="$3"

  # Build arrays of exact vs wildcard patterns from space-separated list
  local _exact_patterns=() _wildcard_patterns=()
  local _p
  for _p in $_allowed; do
    if [[ "$_p" == *'*'* || "$_p" == *'?'* ]]; then
      _wildcard_patterns+=("$_p")
    else
      _exact_patterns+=("$_p")
    fi
  done

  # Sentinel: track which wildcards had hashed entry conflicts (warn once per pattern)
  local _wild_warned=""

  : > "$_output"

  [[ ! -f "$_input" ]] && return 0
  # No allowed patterns → empty output (bypass closed by design)
  [[ -z "$_allowed" ]] && return 0

  local _line _type _key _rest
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    # Skip blank lines and comments
    [[ -z "$_line" || "$_line" == '#'* ]] && continue

    # Hashed entry: |1|<salt_b64>|<hash_b64> <type> <key> [<comment>]
    if [[ "$_line" =~ ^\|1\|([^|]+)\|([^[:space:]]+)[[:space:]](.+)$ ]]; then
      local _salt_b64="${BASH_REMATCH[1]}" _hash_b64="${BASH_REMATCH[2]}" _rest="${BASH_REMATCH[3]}"

      # Convert salt from base64 to hex for openssl macopt
      local _salt_hex
      _salt_hex=$(printf '%s' "$_salt_b64" | base64 -d 2>/dev/null | xxd -p -c 256 2>/dev/null | tr -d '\n')
      if [[ -z "$_salt_hex" ]]; then continue; fi

      # Try each exact pattern: HMAC-SHA1 the pattern against the salt and compare
      local _matched=false
      for _p in "${_exact_patterns[@]+"${_exact_patterns[@]}"}"; do
        local _test_hash
        _test_hash=$(printf '%s' "$_p" | openssl dgst -sha1 -mac HMAC -macopt "hexkey:${_salt_hex}" -binary 2>/dev/null | base64)
        if [[ "$_test_hash" == "$_hash_b64" ]]; then
          # Match: write unhashed form
          printf '%s %s\n' "$_p" "$_rest" >> "$_output"
          _matched=true
          break
        fi
      done

      if [[ "$_matched" == "false" ]]; then
        # Wildcard patterns against hashed entries: warn once per wildcard
        for _p in "${_wildcard_patterns[@]+"${_wildcard_patterns[@]}"}"; do
          if [[ ":${_wild_warned}:" != *":${_p}:"* ]]; then
            _wild_warned="${_wild_warned}:${_p}"
            echo "Warning: '${_p}' in ssh.allowed_hosts cannot match hashed known_hosts entries." >&2
            echo "         Add unhashed entries via: ssh-keyscan -t ed25519,rsa <host> >> ~/.ssh/known_hosts" >&2
          fi
        done
      fi
      continue
    fi

    # Unhashed entry: host[,host,...] type key [comment]
    local _hosts_field
    _hosts_field="${_line%%[[:space:]]*}"

    # Split comma-separated host fields and check each against all allowed patterns
    local _keep=false _h
    IFS=',' read -ra _hfields <<< "$_hosts_field"
    for _h in "${_hfields[@]+"${_hfields[@]}"}"; do
      # Try exact patterns
      for _p in "${_exact_patterns[@]+"${_exact_patterns[@]}"}"; do
        if [[ "$_h" == "$_p" ]]; then
          _keep=true; break 2
        fi
      done
      # Try wildcard patterns (unquoted RHS for glob matching)
      for _p in "${_wildcard_patterns[@]+"${_wildcard_patterns[@]}"}"; do
        # shellcheck disable=SC2053
        if [[ "$_h" == $_p ]]; then
          _keep=true; break 2
        fi
      done
    done

    if [[ "$_keep" == "true" ]]; then
      printf '%s\n' "$_line" >> "$_output"
    fi
  done < "$_input"
}


# _up_resolve_ssh_allowlists -- read effective config, write filtered known_hosts cache
# and optional ssh-allowed-keys sentinel. Called by cmd_up (create + resume paths) after
# mkdir -p of the cache dir.
#
# ADR-022 D3:
#   - ssh.allowed_hosts (additive_list, default []) → filters host SSH known_hosts
#   - ssh.allowed_keys (selection_list, default null):
#       null   → filtering inactive (direct socket mount path preserved)
#       []     → filtering active, zero keys (all agent signing blocked)
#       [...]  → filtering active, listed keys forwarded by ssh-agent-filter
#
# Globals written:
#   _UP_SSH_FILTER_ACTIVE  — "true" when ssh.allowed_keys is non-null; else "false"
# Parameters:
#   $1 workspace   — project directory (for _load_effective_config)
#   $2 cache_dir   — per-container cache dir (known_hosts + ssh-allowed-keys written here)
_up_resolve_ssh_allowlists() {
  local _workspace="$1" _cache_dir="$2"
  _UP_SSH_FILTER_ACTIVE="false"

  # Read effective config (both layers merged). The central gate
  # _config_validate_or_abort (cmd_up, line 2452) runs upstream of every call
  # site and converts loader errors into a loud exit per ADR-001 + ADR-021 D3.
  # Do NOT swallow loader stderr or substitute a silent default here — that
  # would silently expand capability if a future call path bypasses the gate.
  local _eff_result _eff_config
  _eff_result=$(_load_effective_config "$_workspace")
  if [[ -z "$_eff_result" ]]; then
    # No config files present at either layer: schema defaults.
    _eff_config='{"ssh":{"allowed_hosts":[],"allowed_keys":null}}'
  else
    _eff_config=$(jq -c '.config' <<<"$_eff_result")
  fi

  # Extract allowed_hosts as space-separated string (additive_list).
  local _allowed_hosts_str
  _allowed_hosts_str=$(jq -r '.ssh.allowed_hosts // [] | join(" ")' <<<"$_eff_config" 2>/dev/null) || _allowed_hosts_str=""

  # Filter known_hosts → cache dir. Always write (even empty) so the bind-mount target exists.
  _filter_known_hosts "$_allowed_hosts_str" "${HOME}/.ssh/known_hosts" "${_cache_dir}/known_hosts"

  # Extract allowed_keys (selection_list: null = absent = inactive).
  local _allowed_keys_json
  _allowed_keys_json=$(jq -c '.ssh.allowed_keys' <<<"$_eff_config" 2>/dev/null) || _allowed_keys_json="null"

  if [[ "$_allowed_keys_json" == "null" ]]; then
    # Key filtering inactive — direct socket mount path preserved; no sentinel.
    _UP_SSH_FILTER_ACTIVE="false"
    return 0
  fi

  # Key filtering active (explicit [] or [...] list).
  _UP_SSH_FILTER_ACTIVE="true"

  # Write sentinel: one key comment per line (empty file for zero-out).
  local _sentinel="${_cache_dir}/ssh-allowed-keys"
  : > "$_sentinel"
  if [[ "$_allowed_keys_json" != "[]" ]]; then
    jq -r '.[]' <<<"$_allowed_keys_json" >> "$_sentinel" 2>/dev/null
  fi
}


# _build_ssh_mount_args -- compose --mount args for the SSH config + pubkey allowlist.
# ADR-020 D1: mounts translated config, each .pub from allowlist (warn+skip if missing).
# ADR-022 D3: mounts filtered known_hosts from cache (not raw ~/.ssh/known_hosts).
# This function uses the "user-config" behavior for missing pubkeys: warn+skip, never abort.
# For explicit-pin pubkeys, call _assert_pubkey_exists_or_die before calling this function.
#
# Globals read: HOME, _UP_SSH_FILTER_ACTIVE
# Parameters:
#   $1 translated_config  — path to the translated ssh-config file
#   $2 container_name     — used for the cache dir path component
#   $3 array_nameref      — name of caller's array to append mount args to
# Side effects: writes warning to stderr for each missing .pub file; does not abort.
_build_ssh_mount_args() {
  local _cfg="$1" _cname="$2" _arr_name="$3"
  local _ssh_dir="${HOME}/.ssh"
  local _pub_bn _pub_path

  # Mount translated config → /home/agent/.ssh/config (read-only)
  eval "${_arr_name}+=(\"--mount\" \"type=bind,src=${_cfg},dst=/home/agent/.ssh/config,ro\")"

  # Mount each .pub from the allowlist (warn+skip if missing)
  while IFS= read -r _pub_bn; do
    [[ -z "$_pub_bn" ]] && continue
    _pub_path="${_ssh_dir}/${_pub_bn}"
    if [[ -f "$_pub_path" ]]; then
      eval "${_arr_name}+=(\"--mount\" \"type=bind,src=${_pub_path},dst=/home/agent/.ssh/${_pub_bn},ro\")"
    else
      echo "Warning: identity pubkey ${HOME}/.ssh/${_pub_bn} not found on host — skipping mount." >&2
    fi
  done < <(_derive_pubkey_allowlist "$_cfg")

  # ADR-022 D3: mount the filtered known_hosts cache (not raw ~/.ssh/known_hosts).
  # The filtered file is at ~/.cache/rip-cage/<container>/known_hosts.
  # Always mount it (even when empty) so the host arrow surface visible inside the cage
  # is the filtered file. NB: this narrows the system-path known_hosts but does NOT,
  # by itself, defeat `ssh -o UserKnownHostsFile=/tmp/anything -o StrictHostKeyChecking=accept-new`.
  # OpenSSH CLI -o always wins over Match final blocks. The CLI-flag bypass is closed
  # by the ssh-bypass recipe (examples/ssh-bypass/, ADR-022 D5) when composed (default-on
  # in the published image). A base cage without that recipe has no CLI-flag guard here;
  # the known_hosts mount (this block) is the always-present containment floor (ADR-022 D3).
  # ADR-001 fail-loud: always emit the mount. _up_resolve_ssh_allowlists is the
  # contract for populating these files (always writes the known_hosts cache;
  # always writes the sentinel when filtering is active). If a future code path
  # reaches here with the file missing, docker mount fails loudly — preferable
  # to a silent skip that opens an unfiltered surface.
  local _filtered_kh="${HOME}/.cache/rip-cage/${_cname}/known_hosts"
  eval "${_arr_name}+=(\"--mount\" \"type=bind,src=${_filtered_kh},dst=/home/agent/.ssh/known_hosts,ro\")"

  # ADR-022 D3: when key filtering is active, mount the ssh-allowed-keys sentinel
  # read-only into /etc/rip-cage/ so init-rip-cage.sh can detect the filter path
  # (ssh-agent-filter daemon vs today's direct chown-and-use path).
  # _UP_SSH_FILTER_ACTIVE is set by _up_resolve_ssh_allowlists (called before this).
  if [[ "${_UP_SSH_FILTER_ACTIVE:-false}" == "true" ]]; then
    local _sentinel="${HOME}/.cache/rip-cage/${_cname}/ssh-allowed-keys"
    eval "${_arr_name}+=(\"--mount\" \"type=bind,src=${_sentinel},dst=/etc/rip-cage/ssh-allowed-keys,ro\")"
  fi
}


# _build_ssh_mount_args_with_posture -- wrapper around _build_ssh_mount_args that respects posture.
# When posture=off, no mounts are added. When posture=on, delegates to _build_ssh_mount_args.
# Parameters:
#   $1 translated_config  — path to the translated ssh-config file
#   $2 container_name     — container name (for _build_ssh_mount_args)
#   $3 array_nameref      — name of caller's array to append mount args to
#   $4 posture            — "on" or "off"
_build_ssh_mount_args_with_posture() {
  local _cfg="$1" _cname="$2" _arr_name="$3" _posture="$4"
  if [[ "$_posture" == "on" ]]; then
    _build_ssh_mount_args "$_cfg" "$_cname" "$_arr_name"
  fi
  # posture=off → no mounts added
}


# _resolve_ssh_config_posture -- determine the ssh-config posture from CLI flags.
# ADR-020 D7: --no-forward-ssh implies --no-ssh-config unless --ssh-config is explicitly set.
# Parameters:
#   $1 no_ssh_config_flag  — "off" if --no-ssh-config was passed, else ""
#   $2 ssh_config_flag     — "on" if --ssh-config was passed, else ""
#   $3 rc_forward_ssh      — current forward-ssh value ("on" or "off")
# Returns: "on" or "off" (stdout).
_resolve_ssh_config_posture() {
  local _no_ssh_config="$1" _ssh_config_explicit="$2" _fwd_ssh="$3"

  # Explicit --no-ssh-config always wins
  if [[ "$_no_ssh_config" == "off" ]]; then
    printf 'off'
    return 0
  fi

  # Explicit --ssh-config always wins (even if --no-forward-ssh is set)
  if [[ "$_ssh_config_explicit" == "on" ]]; then
    printf 'on'
    return 0
  fi

  # Implication chain: --no-forward-ssh without --ssh-config → --no-ssh-config
  if [[ "$_fwd_ssh" == "off" ]]; then
    printf 'off'
    return 0
  fi

  # Default: on
  printf 'on'
}


# _ssh_config_label_args -- append --label rc.ssh-config=<posture> to an array.
# Parameters:
#   $1 posture       — "on" or "off"
#   $2 array_nameref — name of caller's array to append to
_ssh_config_label_args() {
  local _posture="$1" _arr_name="$2"
  eval "${_arr_name}+=(\"rc.ssh-config=${_posture}\")"
}


# _up_resolve_resume_ssh_config -- read and validate the rc.ssh-config label on resume.
# ADR-020 D7: posture is label-persisted on create; resume reads label as ground truth.
# Missing label: treat as "on" (legacy containers predate this label; enable by default).
# Unrecognized value → fail loud per ADR-001.
# On success sets _UP_RESUME_SSH_CONFIG to "on" or "off".
# Parameters:
#   $1 name          — container name
#   $2 path          — workspace path (for recreate hint)
#   $3 cli_flag      — "--ssh-config" or "--no-ssh-config" if user passed one, else ""
_up_resolve_resume_ssh_config() {
  local _name="$1" _path="$2" _cli_flag="${3:-}"
  local _label
  if ! _label=$(docker inspect --format '{{ index .Config.Labels "rc.ssh-config" }}' "$_name" 2>/dev/null); then
    if [[ "${OUTPUT_FORMAT:-}" == "json" ]]; then
      json_error "docker inspect failed for $_name" "DOCKER_ERROR"
    fi
    echo "Error: docker inspect failed for $_name (is the Docker daemon running?)" >&2
    exit 1
  fi

  if [[ -z "$_label" ]]; then
    # Legacy container predating rc.ssh-config label → treat as on (default posture)
    _UP_RESUME_SSH_CONFIG="on"
    return
  fi

  if [[ "$_label" != "on" && "$_label" != "off" ]]; then
    if [[ "${OUTPUT_FORMAT:-}" == "json" ]]; then
      json_error "Container $_name has unrecognized rc.ssh-config label value: '$_label' (expected on|off). Run: rc destroy $_name && rc up $_path" "INVALID_SSH_CONFIG_LABEL"
    fi
    echo "Error: container $_name has unrecognized rc.ssh-config label value: '$_label' (expected on|off)." >&2
    echo "       Recreate it:" >&2
    echo "         rc destroy $_name" >&2
    echo "         rc up $_path" >&2
    exit 1
  fi

  # Conflict: user passed a conflicting CLI flag at resume → fail loud (mirrors P1 pattern)
  if [[ -n "$_cli_flag" && "$_cli_flag" != "$_label" ]]; then
    if [[ "${OUTPUT_FORMAT:-}" == "json" ]]; then
      json_error "Container $_name already has rc.ssh-config=$_label. Run: rc destroy $_name && rc up $_path to change posture." "SSH_CONFIG_LABEL_CONFLICT"
    fi
    echo "Error: container $_name already has rc.ssh-config=$_label; conflicting flag '$_cli_flag' passed." >&2
    echo "       To change posture, recreate the container:" >&2
    echo "         rc destroy $_name" >&2
    echo "         rc up $_path" >&2
    exit 1
  fi

  _UP_RESUME_SSH_CONFIG="$_label"
}


# _parse_identity_rules -- parse ~/.config/rip-cage/identity-rules (or $RIP_CAGE_IDENTITY_RULES).
# Returns (via stdout) the key basename for the first glob line that matches $2 (project path).
# Skips blank lines and '#'-prefixed comments. Tilde-expands glob patterns before matching.
# Parameters: $1 rules_file path, $2 project_path to match against
# Returns: key basename (stdout) or empty if no match or file absent.
_parse_identity_rules() {
  local _rules_file="$1" _project_path="$2"
  local _line _pattern _key _expanded

  if [[ ! -f "$_rules_file" ]]; then
    return 0
  fi

  while IFS= read -r _line || [[ -n "$_line" ]]; do
    # Skip blank lines and comments
    [[ -z "$_line" || "$_line" == \#* ]] && continue

    # Split on whitespace into pattern and key; skip malformed lines
    _pattern="${_line%%[[:space:]]*}"
    _key="${_line##*[[:space:]]}"
    [[ -z "$_pattern" || -z "$_key" || "$_pattern" == "$_key" ]] && continue

    # Tilde-expand the pattern
    _expanded="${_pattern/#~/$HOME}"

    # Glob match (bash extended glob semantics via [[)
    # shellcheck disable=SC2053
    if [[ "$_project_path" == $_expanded ]]; then
      echo "$_key"
      return 0
    fi
  done < "$_rules_file"

  return 0
}


# _resolve_github_identity -- four-layer ADR-020 D3 resolver.
# Priority: CLI flag (1) → container label on resume (2) → rules-file glob (3) → empty (4).
# Parameters:
#   $1 cli_flag      — value of --github-identity=KEY (or empty)
#   $2 container_name — existing container name for label lookup (or empty for new containers)
#   $3 project_path  — workspace path for rules-file matching
#   $4 rules_file    — path to identity rules file (default: ~/.config/rip-cage/identity-rules)
# Returns: key basename (stdout) or empty string (layer 4).
# Layer 2 (label lookup) is intentionally NOT performed here on create paths — the caller
# passes empty container_name when creating a new container. Resume label handling is done
# by _up_resolve_resume_github_identity separately.
_resolve_github_identity() {
  local _cli_flag="$1" _container_name="$2" _project_path="$3"
  local _rules_file="${4:-${RIP_CAGE_IDENTITY_RULES:-${XDG_CONFIG_HOME:-$HOME/.config}/rip-cage/identity-rules}}"
  local _result=""

  # Layer 1: CLI flag wins
  if [[ -n "$_cli_flag" ]]; then
    echo "$_cli_flag"
    return 0
  fi

  # Layer 2: existing container label (resume only — caller provides name)
  if [[ -n "$_container_name" ]]; then
    _result=$(docker inspect --format '{{ index .Config.Labels "rc.github-identity" }}' "$_container_name" 2>/dev/null || true)
    if [[ -n "$_result" ]]; then
      echo "$_result"
      return 0
    fi
  fi

  # Layer 3: rules-file glob match
  _result=$(_parse_identity_rules "$_rules_file" "$_project_path")
  if [[ -n "$_result" ]]; then
    echo "$_result"
    return 0
  fi

  # Layer 4: unset (empty) — no synthesized github.com block
  return 0
}


# _host_config_has_github -- return 0 if host ~/.ssh/config has a Host github.com block.
# Uses the same scan logic as _translate_ssh_config to be consistent.
_host_config_has_github() {
  local _hcfg="${HOME}/.ssh/config"
  [[ -f "$_hcfg" ]] || return 1
  local _scan_line
  while IFS= read -r _scan_line; do
    if [[ "$_scan_line" =~ ^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+github\.com([[:space:]]|$) ]]; then
      return 0
    fi
  done < "$_hcfg"
  return 1
}


# _resolve_github_identity_source -- determine the source layer for the resolved identity.
# Must be called AFTER _resolve_github_identity and _up_resolve_resume_github_identity.
# Sets _UP_GITHUB_IDENTITY_SOURCE global.
# Parameters:
#   $1 cli_flag           — --github-identity= value (layer 1)
#   $2 resume_label       — _UP_RESUME_GITHUB_IDENTITY value (layer 2, resume only; empty on create)
#   $3 rules_file_result  — result from _parse_identity_rules (layer 3; empty if no match)
#   $4 rc_ssh_config      — "off" → disabled
_resolve_github_identity_source() {
  local _cli_flag="$1" _resume_label="$2" _rules_result="$3" _posture="$4"
  if [[ "$_posture" == "off" ]]; then
    _UP_GITHUB_IDENTITY_SOURCE="disabled"
  elif [[ -n "$_cli_flag" ]]; then
    _UP_GITHUB_IDENTITY_SOURCE="cli-flag"
  elif [[ -n "$_resume_label" ]]; then
    _UP_GITHUB_IDENTITY_SOURCE="label"
  elif [[ -n "$_rules_result" ]]; then
    _UP_GITHUB_IDENTITY_SOURCE="rules-file"
  elif _host_config_has_github; then
    _UP_GITHUB_IDENTITY_SOURCE="host-config"
  else
    _UP_GITHUB_IDENTITY_SOURCE="none"
  fi
}


# _up_resolve_resume_github_identity -- handle label-vs-CLI conflict on resume.
# ADR-020 D3: resume must preserve the existing rc.github-identity label; a CLI
# override on resume is an error (silent relabeling is a silent-fallback, ADR-001).
# Sets _UP_RESUME_GITHUB_IDENTITY on success.
# Parameters: $1 name, $2 path (for recreate hint), $3 cli_flag (may be empty)
_up_resolve_resume_github_identity() {
  local _name="$1" _path="$2" _cli_flag="$3"
  local _existing_label
  _existing_label=$(docker inspect --format '{{ index .Config.Labels "rc.github-identity" }}' "$_name" 2>/dev/null || true)

  if [[ -n "$_cli_flag" && -n "$_existing_label" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Container $_name already labeled rc.github-identity=$_existing_label. Run: rc destroy $_name && rc up --github-identity=$_cli_flag $_path" "GITHUB_IDENTITY_LABEL_CONFLICT"
    fi
    echo "Error: container $_name already labeled rc.github-identity=$_existing_label." >&2
    echo "       To change the identity, recreate the container:" >&2
    echo "         rc destroy $_name" >&2
    echo "         rc up --github-identity=$_cli_flag $_path" >&2
    exit 1
  fi

  _UP_RESUME_GITHUB_IDENTITY="$_existing_label"
}


# _up_ssh_preflight -- probe the forwarded ssh-agent and surface status.
# ADR-017 D4: the visible failure mode for a misconfigured forward is "loud at
# rc up, visible in every multiplexer attach, visible in rc ls" — never a
# silent push-time failure.
#
# Five status values written to /etc/rip-cage/ssh-agent-status (sentinel read
# by zshrc for the shell banner):
#   ok:N          — agent reachable, N keys loaded
#   empty         — agent reachable, 0 keys (host-side fix needed)
#   unreachable   — socket mounted but agent did not respond (platform mismatch
#                   or zombie agent; also covers the timeout case)
#   no_host_agent — forwarding requested but host had no agent to forward
#                   (distinct from explicit opt-out — see _UP_NO_HOST_AGENT)
#   disabled      — forwarding explicitly off (--no-forward-ssh)
# Also echoed to stderr at rc up time.
# Parameters:
#   $1 name
#   $2 effective mode, read from either the CLI-derived rc_forward_ssh on
#      create or the rc.forward-ssh label on resume ("on"|"off"). When "off"
#      and _UP_NO_HOST_AGENT=="1", the preflight surfaces the no-host-agent
#      case rather than the generic "disabled" message.
_up_ssh_preflight() {
  local _name="$1" _fwd="$2"
  local _status=""
  if [[ "$_fwd" == "off" ]]; then
    if [[ "${_UP_NO_HOST_AGENT:-}" == "1" ]]; then
      _status="no_host_agent"
    else
      _status="disabled"
    fi
  else
    # ssh-add exits: 0 = ≥1 key, 1 = 0 keys, 2 = cannot contact agent.
    # `timeout 5` converts a pathological agent that accepts but never
    # responds (timeout exit 124) into the "unreachable" bucket rather than
    # hanging rc up indefinitely. `coreutils` ships timeout in the base image.
    # Capture stdout+stderr and the real exit code — a `|| true` tail would
    # clobber $? with 0 (bug caught during first end-to-end test).
    local _fingerprints _rc
    if _fingerprints=$(docker exec "$_name" timeout 5 ssh-add -l 2>/dev/null); then
      _rc=0
    else
      _rc=$?
    fi
    if [[ $_rc -eq 0 ]]; then
      # `ssh-add -l` prints one fingerprint per key on stdout. Count non-empty
      # lines only (printf may have appended a trailing newline that grep -c
      # would count otherwise on an empty capture).
      local _n
      _n=$(printf '%s' "$_fingerprints" | grep -c '^.')
      _status="ok:${_n}"
    elif [[ $_rc -eq 1 ]]; then
      _status="empty"
    else
      # 2 = cannot contact; 124 = timeout; 125/126/127 = docker-exec/exec failures.
      # All collapse to "unreachable" — the user-facing story is the same.
      _status="unreachable"
    fi
  fi
  # Write sentinel (consumed by zshrc banner + rc doctor). Best-effort: a
  # failure here does not break rc up — the stderr warning below still fires.
  # Values are passed via -e env vars to avoid shell injection from paths
  # containing single-quotes (e.g. /tmp/a'b would break the sh -c string).
  docker exec -u root \
    -e RC_STATUS="$_status" \
    -e RC_SOCK="${_UP_FORWARD_SSH_HOST_SOCK:-}" \
    "$_name" sh -c 'mkdir -p /etc/rip-cage \
    && printf "%s\n" "$RC_STATUS" > /etc/rip-cage/ssh-agent-status \
    && printf "%s\n" "$RC_SOCK" > /etc/rip-cage/ssh-agent-socket' >/dev/null 2>&1 || true

  case "$_status" in
    ok:*)
      log "ssh-agent forwarded (${_status#ok:} key(s) loaded)"
      ;;
    empty)
      log "Warning: ssh-agent forwarded but empty (0 keys). Push will fail."
      if [[ "${_UP_FORWARD_SSH_HOST_SOCK:-}" == "/run/host-services/ssh-auth.sock" ]]; then
        # macOS via OrbStack/Docker Desktop: only the launchd agent is proxied
        # across the VM boundary. Default 'ssh-add' adds to the user's session
        # agent and is invisible to the cage.
        log "  Host fix (macOS): SSH_AUTH_SOCK=\$(launchctl getenv SSH_AUTH_SOCK) ssh-add ~/.ssh/id_ed25519"
        log "  Then: rc down && rc up  (or pass --no-forward-ssh to skip forwarding)"
      else
        log "  Host fix: run 'ssh-add ~/.ssh/id_ed25519' on host (socket: ${_UP_FORWARD_SSH_HOST_SOCK:-<unknown>})"
        log "  Then: rc down && rc up  (or pass --no-forward-ssh to skip forwarding)"
      fi
      ;;
    unreachable)
      log "Warning: ssh-agent socket mounted but not reachable from inside the cage. Push will fail."
      log "  Socket: ${_UP_FORWARD_SSH_HOST_SOCK:-<unknown>} — verify ssh-agent is running on host"
      if [[ "${_UP_FORWARD_SSH_HOST_SOCK:-}" == "/run/host-services/ssh-auth.sock" ]]; then
        log "  Common cause on macOS: stale image without sudoers entry to chown the mounted socket."
        log "  Fix: ./rc build && rc down && rc up"
      fi
      log "  Pass --no-forward-ssh to suppress forwarding."
      ;;
    no_host_agent)
      # Warning already printed from _up_prepare_environment on create;
      # nothing to echo on resume (the sentinel-driven zshrc banner will
      # surface it on every shell).
      :
      ;;
  esac
}


# ---------------------------------------------------------------------------
# Identity-map cache: ~/.cache/rip-cage/identity-map.json
# JSON shape: {"<keyname>": {"github_username": "<user>", "ts": "<ISO8601>"}, ...}
# TTL: 24 hours. Shared across all containers on the host.
# ---------------------------------------------------------------------------

# _identity_cache_file -- return the path to the cache file.
# Respects HOME for test isolation.
_identity_cache_file() {
  echo "${HOME}/.cache/rip-cage/identity-map.json"
}


# _identity_cache_read KEYNAME
# Prints the github_username from the cache if the entry exists AND is not stale
# (younger than 24h). Prints empty string if absent or stale.
_identity_cache_read() {
  local _key="$1"
  local _cache_file
  _cache_file=$(_identity_cache_file)
  [[ -f "$_cache_file" ]] || return 0

  local _ts _username
  _username=$(jq -r --arg k "$_key" '.[$k].github_username // empty' "$_cache_file" 2>/dev/null)
  _ts=$(jq -r --arg k "$_key" '.[$k].ts // empty' "$_cache_file" 2>/dev/null)
  [[ -n "$_username" ]] || return 0
  [[ -n "$_ts" ]] || return 0

  # Check TTL: parse ts, compare to now. Both date commands (BSD/GNU) support
  # ISO-8601 with -j/-d. We use a portable approach: convert to epoch seconds.
  local _entry_epoch _now_epoch _age_seconds
  # macOS BSD date: -j -f format
  if date -j >/dev/null 2>&1; then
    _entry_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$_ts" '+%s' 2>/dev/null) || _entry_epoch=0
  else
    _entry_epoch=$(date -d "$_ts" '+%s' 2>/dev/null) || _entry_epoch=0
  fi
  _now_epoch=$(date '+%s' 2>/dev/null) || _now_epoch=0
  _age_seconds=$(( _now_epoch - _entry_epoch ))

  # 24h = 86400 seconds
  if [[ "$_age_seconds" -lt 86400 ]]; then
    echo "$_username"
  fi
  # else: stale — print nothing (caller treats as cold cache)
}


# _identity_cache_write KEYNAME USERNAME
# Upserts the entry for KEYNAME with USERNAME and current timestamp.
# Creates cache dir and file if absent. Mode 644 (world-readable, not sensitive).
_identity_cache_write() {
  local _key="$1" _username="$2"
  local _cache_file
  _cache_file=$(_identity_cache_file)
  mkdir -p "$(dirname "$_cache_file")"

  local _ts
  _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)

  # Merge: read existing JSON (or start with empty object), set key, write back.
  local _existing="{}"
  if [[ -f "$_cache_file" ]]; then
    _existing=$(cat "$_cache_file" 2>/dev/null) || _existing="{}"
    # Validate it's actually JSON — if not, start fresh
    jq -e '.' <<<"$_existing" >/dev/null 2>&1 || _existing="{}"
  fi
  local _updated
  _updated=$(jq -n \
    --argjson existing "$_existing" \
    --arg key "$_key" \
    --arg user "$_username" \
    --arg ts "$_ts" \
    '$existing + {($key): {"github_username": $user, "ts": $ts}}') || return 0
  printf '%s\n' "$_updated" > "$_cache_file"
  chmod 644 "$_cache_file" 2>/dev/null || true
}


# _identity_cache_touch_all
# Update ts for every entry in the cache to now (rc auth refresh).
# Preserves github_username values unchanged.
_identity_cache_touch_all() {
  local _cache_file
  _cache_file=$(_identity_cache_file)
  [[ -f "$_cache_file" ]] || return 0

  local _existing _ts _updated
  _existing=$(cat "$_cache_file" 2>/dev/null) || return 0
  jq -e '.' <<<"$_existing" >/dev/null 2>&1 || return 0

  _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  _updated=$(jq -n \
    --argjson existing "$_existing" \
    --arg ts "$_ts" \
    'reduce ($existing | to_entries[]) as $e ({}; . + {($e.key): ($e.value + {"ts": $ts})})') || return 0
  printf '%s\n' "$_updated" > "$_cache_file"
  chmod 644 "$_cache_file" 2>/dev/null || true
}


# _up_github_identity_preflight -- probe github.com inside the container and
# write /etc/rip-cage/github-identity + /etc/rip-cage/ssh-config-source sentinels.
# ADR-020 D5+D6.
#
# Run AFTER the container is started (so docker exec works), BEFORE init-rip-cage.sh
# reads the sentinels. Never aborts rc up (all outcomes exit 0).
#
# Sentinel semantics for github-identity:
#   "disabled"                     — rc.ssh-config=off; probe skipped
#   "unreachable\n"                — github.com not reachable from cage
#   "unset\ngreeting=<user>"       — no pin resolved (layer-4 fallback)
#   "match\nexpected=<X>\ngreeting=<X>"   — probe agrees with expected
#   "mismatch\nexpected=<X>\ngreeting=<Y>" — probe differs from expected
#   "<greeting-user>"              — source=host-config (no label compare)
#
# Sentinel semantics for ssh-config-source:
#   One of: disabled, cli-flag, label, rules-file, host-config, none
#
# Test-mode: if RC_PREFLIGHT_SENTINEL_DIR is set, sentinels are written
# to that directory instead of inside the container. This allows unit tests
# to inspect sentinel content without a running container.
#
# Parameters:
#   $1 name        — container name
#   $2 key_basename — resolved key basename (may be empty for layer-4 / disabled)
#   $3 source_layer — one of: cli-flag, label, rules-file, host-config, none, disabled
_up_github_identity_preflight() {
  local _name="$1"
  local _key_basename="$2"
  local _source_layer="$3"

  # Helper: write a sentinel (test-mode or real container).
  # $1 = filename (github-identity or ssh-config-source)
  # $2 = content (single or multi-line)
  _write_sentinel() {
    local _file="$1" _content="$2"
    if [[ -n "${RC_PREFLIGHT_SENTINEL_DIR:-}" ]]; then
      # Test-mode: write locally so tests can inspect
      printf '%b\n' "$_content" > "${RC_PREFLIGHT_SENTINEL_DIR}/${_file}"
    else
      # Real container: write as root via docker exec + tee
      docker exec -u root \
        -e RC_CONTENT="$_content" \
        "$_name" sh -c \
        'mkdir -p /etc/rip-cage \
        && printf "%b\n" "$RC_CONTENT" > /etc/rip-cage/'"$_file"' \
        && chmod 644 /etc/rip-cage/'"$_file" >/dev/null 2>&1 || true
    fi
  }

  # Disabled: rc.ssh-config=off — write disabled sentinels, skip probe
  if [[ "$_source_layer" == "disabled" ]]; then
    _write_sentinel "github-identity" "disabled"
    _write_sentinel "ssh-config-source" "disabled"
    return 0
  fi

  # Always write the source layer sentinel first
  _write_sentinel "ssh-config-source" "$_source_layer"

  # No-identity layer-4 (none): probe but don't compare
  if [[ "$_source_layer" == "none" ]]; then
    # Probe for visibility even though no pin was set
    local _greeting _probe_rc=0
    _greeting=$(docker exec "$_name" ssh -T \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      git@github.com 2>&1) || _probe_rc=$?
    local _greeting_user=""
    _greeting_user=$(printf '%s' "$_greeting" | grep -oE 'Hi [^!]+!' | sed 's/^Hi //; s/!$//') || true
    if [[ "$_probe_rc" -ne 0 ]] && [[ -z "$_greeting_user" ]]; then
      _write_sentinel "github-identity" "unreachable"
    else
      _write_sentinel "github-identity" "unset\ngreeting=${_greeting_user}"
    fi
    return 0
  fi

  # host-config branch: user's own Host github.com block carried over — no label compare.
  # Just probe and record greeting. No cache write needed (no expected value to compare).
  if [[ "$_source_layer" == "host-config" ]]; then
    local _greeting _probe_rc=0
    _greeting=$(docker exec "$_name" ssh -T \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      git@github.com 2>&1) || _probe_rc=$?
    local _greeting_user=""
    _greeting_user=$(printf '%s' "$_greeting" | grep -oE 'Hi [^!]+!' | sed 's/^Hi //; s/!$//') || true
    if [[ "$_probe_rc" -ne 0 ]] && [[ -z "$_greeting_user" ]]; then
      _write_sentinel "github-identity" "unreachable"
    else
      _write_sentinel "github-identity" "${_greeting_user}"
    fi
    return 0
  fi

  # Layers 1-3 (cli-flag, label, rules-file): we have an expected keyname.
  # Probe greeting, use/populate cache, compare.

  # 1. Probe greeting
  local _greeting _probe_rc=0
  _greeting=$(docker exec "$_name" ssh -T \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    git@github.com 2>&1) || _probe_rc=$?
  local _greeting_user=""
  _greeting_user=$(printf '%s' "$_greeting" | grep -oE 'Hi [^!]+!' | sed 's/^Hi //; s/!$//') || true

  # Unreachable: no cache write, write unreachable sentinel
  if [[ "$_probe_rc" -ne 0 ]] && [[ -z "$_greeting_user" ]]; then
    _write_sentinel "github-identity" "unreachable"
    return 0
  fi

  # 2. Cache lookup (or cold-populate)
  local _expected_user=""
  if [[ -n "$_key_basename" ]]; then
    _expected_user=$(_identity_cache_read "$_key_basename")
    if [[ -z "$_expected_user" ]]; then
      # Cold or stale: populate from greeting, then compare with self → match
      _identity_cache_write "$_key_basename" "$_greeting_user"
      _expected_user="$_greeting_user"
    fi
  fi

  # 3. Compare and write sentinel
  if [[ "$_greeting_user" == "$_expected_user" ]]; then
    _write_sentinel "github-identity" "match\nexpected=${_expected_user}\ngreeting=${_greeting_user}"
  else
    _write_sentinel "github-identity" "mismatch\nexpected=${_expected_user}\ngreeting=${_greeting_user}"
  fi
  return 0
}


# _up_validate_dcg_config — validate a generated DCG TOML config file parses.
#
# ADR-025 D5: fail-closed. A malformed DCG_CONFIG silently re-opens the
# user-layer config hole (config.rs:2417). Must exit non-zero on parse failure.
#
# Parameters:
#   $1  config_path — path to the TOML file to validate
_up_validate_dcg_config() {
  local _config_path="$1"
  if [[ ! -f "$_config_path" ]]; then
    echo "Error: DCG config file not found at ${_config_path}" >&2
    return 1
  fi
  # Guard: if python3 is absent entirely, gracefully degrade (matching the
  # missing-tomllib path inside the script at sys.exit(0) below). The host
  # check is best-effort; the authoritative fail-closed gate is
  # init-rip-cage.sh:256-267 (container-side, python3+tomllib guaranteed in
  # the image — ADR-025 D5). exit 127 (command-not-found) must not be treated
  # as a TOML parse error.
  if ! command -v python3 > /dev/null 2>&1; then
    return 0
  fi
  # Try tomllib (Python 3.11+) then tomli backport; gracefully degrade when
  # neither is available (host may have Python 3.9 — container init catches it).
  # Uses python3 -c with newlines joined as semicolons (shellcheck-safe).
  local _dcg_py_ok
  _dcg_py_ok=0
  python3 -c "
import sys; p=sys.argv[1]
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        sys.exit(0)
try:
    tomllib.load(open(p,'rb'))
except Exception as e:
    sys.stderr.write('TOML parse error: ' + str(e) + '\n')
    sys.exit(1)
" "${_config_path}" || _dcg_py_ok=1
  if [[ "$_dcg_py_ok" -ne 0 ]]; then
    echo "Error: generated DCG config at ${_config_path} is malformed TOML — refusing to launch (ADR-025 D5 fail-closed)" >&2
    echo "  Fix dcg.* in your .rip-cage.yaml and retry." >&2
    return 1
  fi
}


# _up_resolve_dcg_config — translate dcg.* from effective config into a
# merged DCG TOML config file written to the per-container cache directory.
#
# ADR-025 D1/D5: host-adoptable additive policy. Merges the baked default
# (core pack floor) with extra packs and custom_paths from dcg.packs /
# dcg.custom_rule_paths. Writes the file only when dcg.* is non-empty;
# safe-by-default: no file written, _UP_DCG_CONFIG_PATH empty when no dcg.*.
#
# Validates the generated config parses (fail-closed per D5); exits non-zero
# and does NOT launch the container on parse failure.
#
# Globals written: _UP_DCG_CONFIG_PATH (empty = no override mount needed)
# Parameters:
#   $1  workspace   — project directory (for _load_effective_config)
#   $2  cache_dir   — per-container cache dir (dcg-config.toml written here)
_up_resolve_dcg_config() {
  local _workspace="$1" _cache_dir="$2"
  _UP_DCG_CONFIG_PATH=""

  # Load effective config. Fall back gracefully when no config files are present.
  local _eff_result _eff_config
  _eff_result=$(_load_effective_config "$_workspace" 2>/dev/null) || true

  if [[ -z "$_eff_result" ]]; then
    # No config files present — safe-by-default: use baked default.
    return 0
  fi

  _eff_config=$(jq -c '.config' <<<"$_eff_result")

  # Extract dcg.packs and dcg.custom_rule_paths from effective config.
  local _dcg_packs _dcg_paths
  _dcg_packs=$(jq -r '.dcg.packs // [] | .[]' <<<"$_eff_config" 2>/dev/null || true)
  _dcg_paths=$(jq -r '.dcg.custom_rule_paths // [] | .[]' <<<"$_eff_config" 2>/dev/null || true)

  # Safe-by-default: if both are empty, no override needed.
  if [[ -z "$_dcg_packs" && -z "$_dcg_paths" ]]; then
    return 0
  fi

  # Build the merged enabled packs list: always start with "core" (floor),
  # then add extra packs from dcg.packs (additive only; deduplication via sort -u).
  local _all_packs="core"
  while IFS= read -r _pack; do
    [[ -z "$_pack" ]] && continue
    _all_packs="${_all_packs}"$'\n'"${_pack}"
  done <<<"$_dcg_packs"
  # Sort and deduplicate; format as TOML array elements.
  local _packs_toml
  _packs_toml=$(echo "$_all_packs" | sort -u | while IFS= read -r _p; do
    [[ -z "$_p" ]] && continue
    printf '"%s", ' "$_p"
  done | sed 's/, $//')

  # Build custom_paths lines: resolve workspace-relative globs to /workspace paths.
  # ADR-023 D7 realpath-first convention: normalize .. components lexically and
  # reject any entry whose resolved container path escapes /workspace/.
  # This runs on the HOST where /workspace does not exist, so we normalize the
  # conceptual container path (/workspace/<glob>) purely via string manipulation
  # (no realpath against host filesystem).
  local _custom_paths_toml=""
  while IFS= read -r _glob; do
    [[ -z "$_glob" ]] && continue
    # Lexically normalize /workspace/<glob> by resolving .. components.
    # Builds a stack of path components; ".." pops the top (bash 3.2-compat:
    # uses slice-to-trim rather than negative-index unset).
    local _raw_path="/workspace/${_glob}"
    local _norm_path=""
    local _oldIFS="$IFS"
    IFS="/"
    local _parts=()
    read -ra _parts <<< "$_raw_path"
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
    _norm_path="/"
    local _i
    for (( _i = 0; _i < _slen; _i++ )); do
      _norm_path="${_norm_path}${_stack[$_i]}/"
    done
    _norm_path="${_norm_path%/}"  # strip trailing /

    # Warn-and-skip if the normalized path escapes /workspace (ADR-023 D6 incidental tier).
    if [[ "$_norm_path" != /workspace/* && "$_norm_path" != "/workspace" ]]; then
      echo "[rc] Warning: dcg.custom_rule_paths entry '${_glob}' escapes /workspace after .. normalization (normalized: '${_norm_path}') — skipping" >&2
      continue
    fi

    # Emit the normalized path (realpath-first, ADR-023 D7): a non-escaping
    # interior ".." (e.g. a/../b) is collapsed to /workspace/b rather than
    # handed to DCG raw, so the path DCG loads matches the path we vetted.
    _custom_paths_toml="${_custom_paths_toml}\"${_norm_path}\", "
  done <<<"$_dcg_paths"
  _custom_paths_toml="${_custom_paths_toml%, }"  # strip trailing ", "

  # Write merged TOML config to cache.
  local _config_path="${_cache_dir}/dcg-config.toml"
  mkdir -p "$_cache_dir"

  {
    echo "# Rip Cage merged DCG policy config (ADR-025 D1/D5)"
    echo "# Generated by rc up from .rip-cage.yaml dcg.* fields."
    echo "# floor: core pack always present; additive only."
    echo ""
    echo "[packs]"
    echo "enabled = [${_packs_toml}]"
    if [[ -n "$_custom_paths_toml" ]]; then
      echo "custom_paths = [${_custom_paths_toml}]"
    fi
  } > "$_config_path"

  # Validate fail-closed (ADR-025 D5).
  if ! _up_validate_dcg_config "$_config_path"; then
    return 1
  fi

  _UP_DCG_CONFIG_PATH="$_config_path"
}

# Global: path to the per-cage DCG config override (empty = use baked default).
# Set by _up_resolve_dcg_config; consumed by cmd_up to add RO mount.
_UP_DCG_CONFIG_PATH=""

# _up_resolve_placeholder_env_file <path> <cli_env_file> (rip-cage-b9to)
#
# auth.placeholder_env_file is a PERSISTED POINTER to a host env file carrying
# the agent's non-secret placeholder token (e.g. CLAUDE_CODE_OAUTH_TOKEN) —
# a composed (opt-in) mediator recipe swaps it for the real credential at
# egress time, or msb's --secret non-possession path (ADR-029 D5) does for
# the default posture. This pointer's contents land in the container via
# `docker run --env-file`, i.e. in PID 1's environment, which the agent CAN
# read (/proc/1/environ) — that's the point (agent-held, non-secret by design).
#
# CREATE-ONLY: the call site in cmd_up invokes this ONLY on the create path,
# immediately before _up_prepare_environment — never on resume (container env
# is immutable across stop/start; D3) and never under --dry-run (D4).
#
# ORDER MATTERS (v3 design D2, R2 F1):
#   a. Read the effective config key FIRST. Null/absent -> return silently,
#      ZERO output — every existing --env-file CLI user (who never sets this
#      key) sees nothing new (acceptance d).
#   b. Only once the key IS set: if the CLI already supplied --env-file
#      (cli_env_file non-empty) -> log an ignore-note and return. CLI wins;
#      returns before touching anything, so same-file double-apply is
#      impossible.
#   c. Pointer fails [[ -f ]] (missing, directory, dangling symlink) -> FATAL:
#      json_error under json mode + echo>&2 + exit 1, naming
#      auth.placeholder_env_file. Create-only call site: this can never
#      strand a resume.
#   d. Run _check_secret_path_denylist on the pointer with the SAME treatment
#      the CLI --env-file path gives it (rc:~4367) — this channel IS
#      agent-readable, so an operator accidentally pointing at a real secret
#      file (~/.aws/credentials) must be refused the same way the CLI path
#      refuses it.
#   e. No tilde/HOME expansion, no relative-path resolution (raw pointer —
#      config.md documents "absolute path"). No allowed-roots check
#      (host-authored config, host-only trust). No 0600 warning (non-secret
#      by design; agent-readability of the placeholder is the point).
#
# RETURN MECHANISM (R2 F2, pinned): sets the global _UP_PLACEHOLDER_ENV_FILE
# (reset to "" at the top of every call so a stale value from a prior
# invocation in the same process can never leak forward). This function must
# NOT rely on dynamic-scope bare assignment into the caller's `env_file` and
# must NOT declare `local env_file` itself. The CALL SITE (cmd_up,
# immediately before _up_prepare_environment) is responsible for copying
# _UP_PLACEHOLDER_ENV_FILE into its own env_file when non-empty — that copy is
# part of the change, not implied by this function.
#
# Globals read: OUTPUT_FORMAT
# Globals written: _UP_PLACEHOLDER_ENV_FILE
# Parameters:
#   $1  path          — validated workspace path (effective-config resolution)
#   $2  cli_env_file  — the CLI --env-file value as seen so far by cmd_up
#                        ("" if not supplied). Needed here because --env-file
#                        only ever sets a `local env_file` inside cmd_up —
#                        there is no global to inspect, so the caller must
#                        pass its current value.
_up_resolve_placeholder_env_file() {
  local _pef_path="$1" _pef_cli_env_file="${2:-}"
  _UP_PLACEHOLDER_ENV_FILE=""

  local _pef_pointer="null"
  if [[ -f "$(_config_global_path)" || -f "$(_config_project_path "${_pef_path}")" ]]; then
    if command -v yq &>/dev/null; then
      local _pef_cfg
      if _pef_cfg=$(_load_effective_config "${_pef_path}" 2>/dev/null); then
        _pef_pointer=$(jq -r '.config.auth.placeholder_env_file // "null"' <<<"$_pef_cfg")
      fi
      unset _pef_cfg
    fi
  fi
  if [[ -z "$_pef_pointer" || "$_pef_pointer" == "null" ]]; then
    return 0
  fi

  if [[ -n "$_pef_cli_env_file" ]]; then
    log "auth.placeholder_env_file: ignored — CLI --env-file already supplied"
    return 0
  fi

  if [[ ! -f "$_pef_pointer" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "auth.placeholder_env_file points at a missing file: ${_pef_pointer}" "PLACEHOLDER_ENV_FILE_NOT_FOUND"
    fi
    echo "Error: auth.placeholder_env_file points at a missing file: ${_pef_pointer}" >&2
    exit 1
  fi

  # D2d: same treatment as the CLI --env-file path's denylist check (rc:~4367)
  # — this channel is agent-readable, unlike the mediator's docker-exec-only
  # channel, so an accidental secret-path pointer must be refused the same way.
  # Known partial parity (accepted at rip-cage-b9to impl-review): the check
  # runs on the RAW pointer (D2e: no realpath), so a symlink to a denylisted
  # secret bypasses it here while the CLI path (which realpaths first) would
  # catch it. Host-authored config, accident model — out of threat scope.
  if _check_secret_path_denylist "$_pef_pointer" "$_pef_path"; then
    local _pef_denied_pattern
    _pef_denied_pattern=$(_secret_path_denylist_matched_pattern "$_pef_pointer" "$_pef_path")
    _emit_denylist_denial "$_pef_pointer" "${_pef_denied_pattern:-<unknown>}"
    exit 1
  fi

  _UP_PLACEHOLDER_ENV_FILE="$_pef_pointer"
  log "auth.placeholder_env_file: applied ${_pef_pointer}"
}


# _probe_tcp HOST PORT — returns 0 if TCP connection succeeds within 1s, non-zero otherwise.
# Uses bash /dev/tcp — no nc or timeout(1) dependency (macOS bash 3.2 compat).
_probe_tcp() {
  local host=$1 port=$2
  (
    exec 3<>/dev/tcp/"$host"/"$port"
  ) 2>/dev/null &
  local pid=$!
  ( sleep 1; kill "$pid" 2>/dev/null ) 2>/dev/null &
  local killer=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$killer" 2>/dev/null
  return "$rc"
}


# _bd_dolt_port_inject_arg DOLT_PORT_FILE
#
# Validates .beads/dolt-server.port content BEFORE it is used to build the
# BEADS_DOLT_SERVER_PORT env-injection arg (rc:~1891 residual, rip-cage-a0h
# item (a) — ADR-007 D8 rescope). Mirrors the validation predicate already
# used by the host preflight (_bd_host_preflight, rc:4372) for consistency:
# an integer in 1-65535.
#
# On missing file: emits nothing (existing behavior — no file, no injection).
# On valid content: echoes "BEADS_DOLT_SERVER_PORT=<port>" to stdout.
# On invalid content (non-integer / out-of-range): emits NOTHING to stdout
# (caller skips the -e injection) and warns to stderr naming the file and the
# expected format — never exits non-zero (ADR-007 D8 warn-not-fail; bd is
# optional and must never block the container). Warning goes straight to
# stderr (not log()) so stdout stays clean for the `-e "$(...)"` capture
# pattern at the call site.
_bd_dolt_port_inject_arg() {
  local dolt_port_file="$1"
  [[ -f "$dolt_port_file" ]] || return 0
  local val
  val=$(cat "$dolt_port_file")
  if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val <= 0 || val >= 65536 )); then
    echo "Warning: ${dolt_port_file} contains invalid content (expected an integer port 1-65535) — skipping BEADS_DOLT_SERVER_PORT env injection." >&2
    return 0
  fi
  echo "BEADS_DOLT_SERVER_PORT=${val}"
}


# _bd_host_preflight BEADS_DIR DOLT_MODE [--test-mode]
#
# In normal mode: logs warnings via log(), always returns 0 (warn-and-continue per ADR-007 D8).
# In --test-mode: emits one PASS|FAIL [0] beads-host-dolt — <detail> line to stdout;
#                 returns non-zero for cases A/B/C so callers can capture the result.
#
# States:
#   embedded/unset   -> silent (normal) or PASS [0] ... not applicable (test mode)
#   healthy          -> silent (normal) or PASS [0] ... dolt reachable on 127.0.0.1:<N>
#   case A (missing) -> warn (normal) or FAIL [0] ... port file missing; run `bd dolt start`
#   case B (stale)   -> warn (normal) or FAIL [0] ... stale port <N>; run `bd dolt start`
#   case C (corrupt) -> warn (normal) or FAIL [0] ... corrupt port file; rm + `bd dolt start`
_bd_host_preflight() {
  local beads_dir=$1
  local dolt_mode=$2
  local test_mode=false
  [[ "${3:-}" == "--test-mode" ]] && test_mode=true

  # Skip entirely for embedded/unset
  if [[ "$dolt_mode" == "embedded" ]] || [[ -z "$dolt_mode" ]]; then
    $test_mode && echo "PASS [0] beads-host-dolt — not applicable (embedded mode)"
    return 0
  fi

  local port_file="${beads_dir}/dolt-server.port"

  # Case A: port file missing
  if [[ ! -f "$port_file" ]]; then
    if $test_mode; then
      echo "FAIL [0] beads-host-dolt — port file missing; run \`bd dolt start\`"
      return 1
    else
      log "Warning: beads server-mode enabled but .beads/dolt-server.port is missing.
  Likely cause: bd server has not been started yet in this project (or has never started successfully).
  Fix: on the host, run \`bd dolt start\` in $(dirname "$beads_dir")
  If that fails with \"database locked\", a stale dolt process is holding the lock.
  Check with: lsof -iTCP -sTCP:LISTEN -P -n | grep dolt
  Then kill the wedged PID and retry.
Continuing anyway — bd calls inside the container will fail until resolved."
      return 0
    fi
  fi

  # Read and validate port content
  local port
  port=$(cat "$port_file")

  # Case C: corrupt — empty, non-numeric, zero, or out of range
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port <= 0 || port >= 65536 )); then
    if $test_mode; then
      echo "FAIL [0] beads-host-dolt — corrupt port file; rm + \`bd dolt start\`"
      return 1
    else
      log "Warning: .beads/dolt-server.port contains invalid content (expected a port number).
  Likely cause: interrupted write, disk issue, or a non-bd writer touched the file.
  Fix: on the host, delete the file and re-run \`bd dolt start\` in $(dirname "$beads_dir"):
    rm \"${beads_dir}/dolt-server.port\"
    bd dolt start
Continuing anyway — bd calls inside the container will fail until resolved."
      return 0
    fi
  fi

  # Case B: port present and valid, but nothing listening
  if ! _probe_tcp "127.0.0.1" "$port"; then
    if $test_mode; then
      echo "FAIL [0] beads-host-dolt — stale port ${port}; run \`bd dolt start\`"
      return 1
    else
      log "Warning: .beads/dolt-server.port says port ${port}, but nothing is listening there.
  Likely cause: the bd server crashed or was killed; the port file is stale.
  Fix: on the host, run \`bd dolt start\` in $(dirname "$beads_dir")
  (this will rewrite the port file to the new port).
Continuing anyway — bd calls inside the container will fail until resolved."
      return 0
    fi
  fi

  # Healthy
  $test_mode && echo "PASS [0] beads-host-dolt — dolt reachable on 127.0.0.1:${port}"
  return 0
}


cmd_up() {
  local path="" port="" env_file=""
  local rc_cpus="2" rc_memory="4g" rc_pids_limit="500"
  # RIP_CAGE_FORWARD_SSH env provides the project/shell default,
  # --no-forward-ssh on the CLI always wins.
  local rc_forward_ssh="${RIP_CAGE_FORWARD_SSH:-on}"
  # ADR-020 D3: --github-identity=<keyname> CLI flag (layer 1 of four-layer resolver).
  # Also accepts RIP_CAGE_GITHUB_IDENTITY env var as the layer-1 source.
  local rc_github_identity_flag="${RIP_CAGE_GITHUB_IDENTITY:-}"
  # ADR-020 D7: --no-ssh-config / --ssh-config opt-out/in flags.
  # Empty = not explicitly set (implication chain applies).
  local rc_no_ssh_config_flag="" rc_ssh_config_explicit_flag=""
  # Multi-session flags: --new calls the new_session hook for a new auto-named session;
  # --session <name> forwards NAME to the attach hook.  Mutually exclusive.
  local rc_up_new_session="" rc_up_session_name=""
  # ADR-023 D6: per-invocation denylist bypass. Repeatable flag; each value is
  # appended to the RC_ALLOW_RISKY_MOUNT array. Matched literally against the
  # realpath-resolved input path (no re-realpath of the flag arg).
  RC_ALLOW_RISKY_MOUNT=()
  # ADR-024 D1 / rip-cage-hhh.5: per-invocation bypass for workspace base-URL redirect check.
  # When set, validator emits a warning instead of refusing.
  local rc_allow_config_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) [[ $# -ge 2 ]] || { echo "Error: --port requires a value" >&2; exit 1; }; port="$2"; shift 2 ;;
      --env-file) [[ $# -ge 2 ]] || { echo "Error: --env-file requires a value" >&2; exit 1; }; env_file="$2"; shift 2 ;;
      --cpus) [[ $# -ge 2 ]] || { echo "Error: --cpus requires a value" >&2; exit 1; }; rc_cpus="$2"; shift 2 ;;
      --memory) [[ $# -ge 2 ]] || { echo "Error: --memory requires a value" >&2; exit 1; }; rc_memory="$2"; shift 2 ;;
      --pids-limit) [[ $# -ge 2 ]] || { echo "Error: --pids-limit requires a value" >&2; exit 1; }; rc_pids_limit="$2"; shift 2 ;;
      --no-forward-ssh) rc_forward_ssh="off"; shift ;;
      --no-ssh-config) rc_no_ssh_config_flag="off"; shift ;;
      --ssh-config) rc_ssh_config_explicit_flag="on"; shift ;;
      --github-identity=*) rc_github_identity_flag="${1#--github-identity=}"; shift ;;
      --new) rc_up_new_session="true"; shift ;;
      --session) [[ $# -ge 2 ]] || { echo "Error: --session requires a value" >&2; exit 1; }; rc_up_session_name="$2"; shift 2 ;;
      --allow-risky-mount) [[ $# -ge 2 ]] || { echo "Error: --allow-risky-mount requires a value" >&2; exit 1; }; RC_ALLOW_RISKY_MOUNT+=("$2"); shift 2 ;;
      --allow-config-override) rc_allow_config_override="true"; shift ;;
      *) path="$1"; shift ;;
    esac
  done
  # --new and --session are mutually exclusive
  if [[ -n "$rc_up_new_session" ]] && [[ -n "$rc_up_session_name" ]]; then
    echo "Error: --new and --session are mutually exclusive. Use one or the other." >&2
    exit 2
  fi
  # ADR-020 D7: resolve ssh-config posture from flags + implication chain.
  local rc_ssh_config
  rc_ssh_config=$(_resolve_ssh_config_posture "$rc_no_ssh_config_flag" "$rc_ssh_config_explicit_flag" "$rc_forward_ssh")

  if [[ -z "$path" ]]; then
    path="."
  fi

  # Non-TTY minimum grant: when RC_ALLOWED_ROOTS is unset and an env-file is provided,
  # pre-set RC_ALLOWED_ROOTS to cover both the workspace path and the env-file dirname.
  # This prevents the second validate_path call from seeing a different effective root.
  if [[ -z "${RC_ALLOWED_ROOTS:-}" ]] && [[ -n "$env_file" ]] && ! { [[ -t 0 ]] && [[ "$OUTPUT_FORMAT" != "json" ]]; }; then
    local _pre_ws _pre_env_dir
    _pre_ws=$(realpath "$path" 2>/dev/null) || _pre_ws="$path"
    if [[ -e "$env_file" ]]; then
      local _pre_ef
      _pre_ef=$(realpath "$env_file" 2>/dev/null) || _pre_ef="$env_file"
      _pre_env_dir=$(dirname "$_pre_ef")
      RC_ALLOWED_ROOTS="${_pre_ws}:${_pre_env_dir}"
      RC_VALIDATE_WARNING="RC_ALLOWED_ROOTS unset — allowing $_pre_ws only."
      echo "Warning: RC_ALLOWED_ROOTS unset — allowing $_pre_ws only." >&2
      echo "Set RC_ALLOWED_ROOTS in ~/.config/rip-cage/rc.conf for permanent access." >&2
    fi
  fi

  validate_path "$path"
  path="$VALIDATED_PATH"

  # rip-cage-j86 / ADR-023 D6 evolution: auto-seed the global config on first run
  # BEFORE _config_validate_or_abort so the yq-presence check inside the
  # validator covers the freshly-seeded config. Seeding is the safe direction —
  # it only adds blocking, never widens capability (denylist-only config). The
  # old hard-stop that required a separate `rc install` step is removed; seeding
  # guarantees the file is present before the validator runs.
  _config_ensure_global_seeded

  # ADR-021 D3 + ADR-001: validate .rip-cage.yaml posture BEFORE any docker
  # side-effects. Aborts loud on selection-list+future-version (silent skip
  # would silently expand capability past user intent — ADR-001:13) or on
  # yq-missing-with-config-present (no silent degradation per ADR-021
  # implementation notes). No config file ⇒ silent no-op (D5).
  _config_validate_or_abort "$path"

  # LFS advisory: warn if the project uses git-lfs and has unmaterialized
  # pointer stubs. rip-cage cannot fetch blobs (ADR-014); user must run
  # `git lfs pull` on the host. Observation-only — does not mutate.
  _check_lfs_stubs "$path"

  # Validate env-file early (before dry-run exit) to catch symlink bypasses
  if [[ -n "$env_file" ]]; then
    local resolved_env
    if [[ ! -e "$env_file" ]]; then
      echo "Error: env file not found: $env_file" >&2; exit 1
    fi
    resolved_env=$(realpath "$env_file" 2>/dev/null) || {
      echo "Error: env file not found: $env_file" >&2; exit 1
    }
    if [[ ! -f "$resolved_env" ]]; then
      echo "Error: env file is not a regular file: $env_file" >&2; exit 1
    fi
    validate_path "$(dirname "$resolved_env")"
    # ADR-023 D6: denylist check — env-file surface (FIRM insertion-point discipline:
    # inside env-file branch only, after realpath, NOT at top of validate_path).
    if _check_secret_path_denylist "$resolved_env" "$path"; then
      # _check_secret_path_denylist returns 0 when the path is DENIED.
      local _denied_pattern
      _denied_pattern=$(_secret_path_denylist_matched_pattern "$resolved_env" "$path")
      _emit_denylist_denial "$resolved_env" "${_denied_pattern:-<unknown>}"
      exit 1
    fi
    env_file="$resolved_env"
  fi

  # ADR-024 D1 / rip-cage-hhh.5: workspace-trust preflight — refuse hostile
  # base-URL redirect in workspace .claude/settings.json BEFORE container start.
  if _check_workspace_config_base_url "$path"; then
    # Returns 0 = hostile (base-URL key is set)
    if [[ -n "$rc_allow_config_override" ]]; then
      # --allow-config-override: warn and proceed (per-invocation escape hatch)
      _emit_workspace_config_base_url_warning "$WS_CONFIG_HOSTILE_KEY" "$WS_CONFIG_HOSTILE_VAL"
    else
      _emit_workspace_config_base_url_error "$WS_CONFIG_HOSTILE_KEY" "$WS_CONFIG_HOSTILE_VAL"
      exit 1
    fi
  fi

  # rip-cage-4c5.3: manifest IOC egress check — BEFORE any Docker call.
  # Reject any manifest egress: entry naming a host on the IOC denylist.
  # Fires loudly naming the offending host (ADR-005 D3 / ADR-012 D1).
  _manifest_ensure_seeded
  if ! _manifest_check_ioc_egress "${SCRIPT_DIR}/cage/egress/egress-rules.yaml"; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Manifest declares an IOC-denylisted egress host — rc up refused (ADR-005 D3 / ADR-012 D1)" "MANIFEST_IOC_EGRESS_DENIED"
    fi
    exit 1
  fi

  # rip-cage-4c5.3: manifest mounts denylist check — BEFORE any Docker call.
  # Reject any manifest mounts: entry that targets a denylisted secret path.
  # Realpath-first, fail-loud (ADR-023 D1/D6).
  if ! _manifest_check_mounts_denylist "$path"; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Manifest declares a mount that matches the secret-path denylist — rc up refused (ADR-023 D1/D6)" "MANIFEST_MOUNT_DENYLIST_DENIED"
    fi
    exit 1
  fi

  # Check image exists and is current — pull from GHCR (with local-build
  # fallback) if missing or version label mismatches RC_VERSION (stale).
  # Provisioning fires only on the new-container (absent) path; see below.
  # See _image_is_current / _pull_or_build / ADR-008 D6.
  local _image_absent=false
  if ! docker image inspect "$IMAGE" > /dev/null 2>&1 || ! _image_is_current; then
    _image_absent=true
  fi

  local name_disambiguated=false

  local name
  name=$(container_name "$path")
  if [[ -z "$name" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Cannot derive container name from path: $path" "PATH_INVALID"
    echo "Error: path components produce an empty container name: $path" >&2
    exit 1
  fi

  # Check for existing container
  local existing_path
  existing_path=$(docker inspect --format '{{ index .Config.Labels "rc.source.path" }}' "$name" 2>/dev/null || true)

  if [[ -n "$existing_path" ]]; then
    # Container exists
    if [[ "$existing_path" != "$path" ]]; then
      # Different path — disambiguate with hash suffix
      local hash
      hash=$(printf '%s' "$path" | cksum | cut -d' ' -f1)
      hash=$(printf '%s' "$hash" | tail -c 4)
      name="${name}-${hash}"
      name_disambiguated=true
      log "Warning: container '$( container_name "$path" )' exists for different path. Using: $name"
    fi
  fi

  # Git worktree: fix .git pointer for container (the .git file contains host-absolute paths)
  local wt_detected wt_name wt_main_git wt_error
  _up_detect_worktree "$path"

  # D11: compute git_hooks_ro for JSON output
  # true when .git/hooks is mounted read-only:
  #   - worktree mode always mounts hooks ro (via .git-main/hooks:ro)
  #   - bind-mount mode mounts ro when .git/hooks dir exists
  local git_hooks_ro=false
  if [[ "$wt_detected" == "true" ]]; then
    git_hooks_ro=true
  elif [[ -d "${path}/.git/hooks" ]]; then
    git_hooks_ro=true
  fi

  # Check container state — distinguish "container absent" from "inspect failed".
  # docker inspect exits non-zero with "no such object" when the container does
  # not exist; it exits 0 when the container exists (even if status is blank).
  # Use 'if' to capture exit code without triggering set -e on failure.
  local state _inspect_exit
  if state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null); then
    _inspect_exit=0
  else
    _inspect_exit=$?
    state=""
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    local would_action
    if [[ "$state" == "running" ]]; then
      # rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-RUNNING BEGIN (mirrors the real
      # running branch below — see RESUME-GUARDS-REAL-RUNNING). All 6 guards
      # here are read-only (label read + _load_effective_config + compare) —
      # safe under --dry-run.
      _up_resolve_resume_image_drift_running "$name" "$path"
      _up_resolve_resume_config_mode "$name" "$path"
      _up_resolve_resume_ssh_key_filter "$name" "$path"
      _up_resolve_resume_symlink_fingerprint "$name" "$path"
      _up_resolve_resume_credential_mounts "$name" "$path"
      # rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-RUNNING END
      would_action="would_attach"
    elif [[ "$state" == "exited" ]] || [[ "$state" == "created" ]]; then
      # Surface legacy/invalid-label conditions in dry-run so planners see the
      # same hard stop the actual resume would hit (ADR-001).
      # rip-cage-jnvb / D-b: image-ID drift hard-stop surfaced here too —
      # dry-run planners must see the same refusal the real resume would hit.
      # rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-STOPPED BEGIN (mirrors the real
      # stopped branch below — see RESUME-GUARDS-REAL-STOPPED). All 10 guards
      # here are read-only (label read + _load_effective_config + compare);
      # the mkdir + _translate_ssh_config resume machinery that follows the
      # real branch's ssh_config guard is intentionally NOT pulled in here —
      # that's resume-side mutation, not a guard.
      _up_resolve_resume_image_drift_stopped "$name" "$path"
      _up_resolve_resume_forward_ssh "$name" "$path"
      _up_resolve_resume_github_identity "$name" "$path" "$rc_github_identity_flag"
      local _dry_ssh_config_cli_flag=""
      if [[ -n "$rc_no_ssh_config_flag" ]]; then
        _dry_ssh_config_cli_flag="off"
      elif [[ -n "$rc_ssh_config_explicit_flag" ]]; then
        _dry_ssh_config_cli_flag="on"
      fi
      _up_resolve_resume_ssh_config "$name" "$path" "$_dry_ssh_config_cli_flag"
      _up_resolve_resume_ssh_key_filter "$name" "$path"
      _up_resolve_resume_config_mode "$name" "$path"
      _up_resolve_resume_symlink_fingerprint "$name" "$path"
      _up_resolve_resume_credential_mounts "$name" "$path"
      # rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-STOPPED END
      would_action="would_resume"
    elif [[ "$_inspect_exit" -ne 0 ]]; then
      # docker inspect failed → container is absent; create new.
      would_action="would_create"
    elif [[ "$state" == "paused" ]]; then
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is paused. Run: docker unpause $name then retry: rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is paused. Run: docker unpause $name then retry: rc up $path" >&2; return 1
    elif [[ "$state" == "restarting" ]]; then
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is restarting. Wait, or run: docker stop $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is restarting. Wait, or run: docker stop $name && rc up $path" >&2; return 1
    elif [[ "$state" == "removing" ]]; then
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is being removed. Wait, then run: rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is being removed. Wait, then run: rc up $path" >&2; return 1
    elif [[ "$state" == "dead" ]]; then
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is dead. Run: rc destroy $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is dead. Run: rc destroy $name && rc up $path" >&2; return 1
    else
      # Unrecognized state (allowlist exhausted) — fail loud per ADR-001.
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is in unrecognized state: state=$state. Inspect manually with: docker inspect $name  — if safe, rc destroy $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is in unrecognized state: state=$state. Inspect manually with: docker inspect $name  — if safe, rc destroy $name && rc up $path" >&2; return 1
    fi

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      if [[ "$would_action" == "would_create" ]] && [[ "$_image_absent" == "true" ]]; then
        # Image absent on new-container path — emit pull/build intent in old format
        # so test-pull-first.sh assertions (would_pull / would_build fields) stay green.
        if [[ -n "${RIP_CAGE_IMAGE_REGISTRY}" ]]; then
          jq -nc --arg image "${RIP_CAGE_IMAGE_REGISTRY}:${RC_VERSION}" \
            '{dry_run: true, would_pull: true, would_build_on_fail: true, image: $image, action: "would_pull_and_create"}'
        else
          jq -nc '{dry_run: true, would_build: true, action: "would_build_and_create", message: "would build rip-cage image, then create container"}'
        fi
      else
        _up_json_output "$name" "$would_action" "$path" "" "" "true"
      fi
    else
      echo "Would ${would_action#would_} container $name for $path"
      # Image absent on new-container path — surface pull/build intent (test-pull-first.sh Tests 3+4).
      if [[ "$would_action" == "would_create" ]] && [[ "$_image_absent" == "true" ]]; then
        if [[ -n "${RIP_CAGE_IMAGE_REGISTRY}" ]]; then
          echo "Would pull ${RIP_CAGE_IMAGE_REGISTRY}:${RC_VERSION} (with local-build fallback) and create container"
        else
          echo "Would build rip-cage image and create container"
        fi
      fi
      echo "Would mount $path -> /workspace"
      if [[ "$wt_detected" == "true" ]]; then
        echo "Would mount worktree main .git/ ($wt_main_git) -> /workspace/.git-main (writable)"
        echo "Would mount corrected .git pointer -> /workspace/.git:ro"
        echo "Would mount hooks -> /workspace/.git-main/hooks:ro"
      elif [[ -d "${path}/.git/hooks" ]]; then
        echo "Would mount .git/hooks -> /workspace/.git/hooks:ro (D11)"
      fi
      if [[ -d "${HOME}/.claude/skills" ]]; then
        echo "Would mount ~/.claude/skills -> /home/agent/.rc-context/skills:ro"
        local _dry_tdir
        while IFS= read -r _dry_tdir; do
          if _check_secret_path_denylist "$_dry_tdir" "$path"; then
            local _dry_skill_pat
            _dry_skill_pat=$(_secret_path_denylist_matched_pattern "$_dry_tdir" "$path" 2>/dev/null || true)
            echo "Warning: skipping skill symlink mount ${_dry_tdir} — matched secret-path denylist pattern '${_dry_skill_pat:-<unknown>}'" >&2
            continue
          fi
          echo "Would mount ${_dry_tdir} -> ${_dry_tdir}:ro (skill symlink target)"
        done < <(_collect_symlink_parents "${HOME}/.claude/skills")
      fi
      [[ -d "${HOME}/.claude/commands" ]] && echo "Would mount ~/.claude/commands -> /home/agent/.rc-context/commands:ro"
      if [[ -d "${HOME}/.claude/agents" ]]; then
        echo "Would mount ~/.claude/agents -> /home/agent/.rc-context/agents:ro"
        local _dry_agent_tdir
        while IFS= read -r _dry_agent_tdir; do
          if _check_secret_path_denylist "$_dry_agent_tdir" "$path"; then
            local _dry_agent_pat
            _dry_agent_pat=$(_secret_path_denylist_matched_pattern "$_dry_agent_tdir" "$path" 2>/dev/null || true)
            echo "Warning: skipping agent symlink mount ${_dry_agent_tdir} — matched secret-path denylist pattern '${_dry_agent_pat:-<unknown>}'" >&2
            continue
          fi
          echo "Would mount ${_dry_agent_tdir} -> ${_dry_agent_tdir}:ro (agent symlink target)"
        done < <(_collect_symlink_parents "${HOME}/.claude/agents")
      fi
      echo "Would mount ~/.claude/projects -> /home/agent/.claude/projects (sessions persist to host, rip-cage-dn2)"
      echo "Would mount ~/.claude/sessions -> /home/agent/.claude/sessions"
      local _dry_host_key
      _dry_host_key=$(printf '%s' "$path" | tr '/.' '-')
      echo "Would set RC_HOST_PROJECT_KEY=${_dry_host_key} (unifies -workspace sessions with host project key)"
      [[ "$would_action" != "would_attach" ]] && echo "Would run init script"
    fi
    return 0
  fi

  if [[ "$state" == "running" ]]; then
    # rip-cage-3y9g: RESUME-GUARDS-REAL-RUNNING BEGIN (mirrored by the
    # dry-run running sub-branch above — see RESUME-GUARDS-DRY-RUN-RUNNING)
    # rip-cage-jnvb / D-c: image-ID drift is warn-only on the running branch —
    # no crash path exists here (no docker start, no mediator/firewall init;
    # exec runs against the container's OWN filesystem) — refusing attach
    # would interrupt a live agent session for no safety benefit (ADR-002 D5).
    _up_resolve_resume_image_drift_running "$name" "$path"
    # ADR-021 D7: config-mode mount-shape guard applies to running containers too.
    _up_resolve_resume_config_mode "$name" "$path"
    # ADR-028 D1 / rip-cage-7gr9: ssh key-filter mount-shape guard applies to
    # running containers too — the /etc/rip-cage/ssh-allowed-keys bind is
    # frozen at create time.
    _up_resolve_resume_ssh_key_filter "$name" "$path"
    # rip-cage-c1p.2 D4: fingerprint label-lock applies to running containers too.
    # A policy change (on_dangling, scope, mode) must block resume regardless of
    # whether the container is stopped or running — the mount shape is immutable.
    _up_resolve_resume_symlink_fingerprint "$name" "$path"
    # rip-cage-seqc.4 / B1: credential-mounts mount-shape guard applies to
    # running containers too — same rationale as the two guards above.
    _up_resolve_resume_credential_mounts "$name" "$path"
    # rip-cage-yid0: mediator CA env guard applies to running containers too
    # — CA trust env vars are frozen at container-create time, same rationale.
    # rip-cage-3y9g: RESUME-GUARDS-REAL-RUNNING END
    _config_emit_hint "$path" "$name"
    _config_init_emit_tip "$path"
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      _up_json_output "$name" "attached" "$path" "running"
      return
    fi
    # rip-cage-1f59.2 / rip-cage-61al.3: dispatch on the multiplexer label via the baked registry.
    # No hardcoded mux names — any declared-in-manifest provider is dispatched through
    # _rc_mux_resolve_hook_path (ADR-005 D12 FIRM).
    local _up_run_mux
    _up_run_mux=$(_container_multiplexer "$name")
    case "$_up_run_mux" in
      none)
        [[ -n "$rc_up_new_session" || -n "$rc_up_session_name" ]] && \
          echo "warning: --new/--session ignored under multiplexer=none" >&2
        if [[ -t 0 && -t 1 ]]; then
          docker exec -it "$name" zsh
        else
          echo "Container $name is running (multiplexer=none). Exec with: rc exec $name -- <cmd>" >&2
        fi
        ;;
      *)
        # Registry dispatch: resolve the hook path from the baked registry and invoke it.
        # Fails loud if the mux was not declared in the manifest used to build this image
        # (ADR-001 fail-loud; ADR-005 D12 — no hardcoded optional-mux names in rc).
        local _up_run_hook_path
        if [[ -n "$rc_up_new_session" ]]; then
          _up_run_hook_path=$(_rc_mux_resolve_hook_path "$_up_run_mux" "new_session" "$name") || return 1
          if [[ -z "$_up_run_hook_path" ]]; then
            echo "warning: multiplexer '${_up_run_mux}' has no new_session hook — falling back to attach" >&2
            _up_run_hook_path=$(_rc_mux_resolve_hook_path "$_up_run_mux" "attach" "$name") || return 1
          fi
        else
          _up_run_hook_path=$(_rc_mux_resolve_hook_path "$_up_run_mux" "attach" "$name") || return 1
        fi
        if [[ -z "$_up_run_hook_path" ]]; then
          echo "Error: multiplexer '${_up_run_mux}' has no attach hook in registry for cage '$name'." >&2
          return 1
        fi
        if [[ -t 0 && -t 1 ]]; then
          # Forward --session NAME to the hook as $1 (mux-agnostic; hook may ignore if not applicable).
          docker exec -it "$name" sh "$_up_run_hook_path" "${rc_up_session_name:-}"
        else
          echo "Container $name is running (multiplexer=${_up_run_mux}). Attach with: rc attach $name" >&2
        fi
        ;;
    esac
    return
  elif [[ "$state" == "exited" ]] || [[ "$state" == "created" ]]; then
    log "Resuming stopped container $name..."
    # rip-cage-3y9g: RESUME-GUARDS-REAL-STOPPED BEGIN (mirrored by the
    # dry-run stopped sub-branch above — see RESUME-GUARDS-DRY-RUN-STOPPED)
    # rip-cage-jnvb / D-b, D-f: image-ID drift guard — FIRST, before any other
    # resume machinery and before docker start (rc:4409-and-friends below).
    # `rc build` creates a new image but an already-existing stopped container
    # stays pinned to the OLD image ID; blind-resuming ran the NEW image's
    # resume logic (e.g. mediator init execs a script baked into the image)
    # against the OLD container's filesystem -> raw OCI stat crash + self-stop.
    # Aborts loud on mismatch or a missing current image — never fail-open.
    _up_resolve_resume_image_drift_stopped "$name" "$path"
    # ADR-017 D2: forward-ssh posture is label-persisted.
    _up_resolve_resume_forward_ssh "$name" "$path"
    rc_forward_ssh="$_UP_RESUME_FORWARD_SSH"
    # ADR-020 D3: github-identity label is immutable on resume; CLI override is an error.
    _up_resolve_resume_github_identity "$name" "$path" "$rc_github_identity_flag"
    # ADR-020 D7: read ssh-config posture label from the container (immutable on resume).
    local _resume_ssh_config_cli_flag=""
    if [[ -n "$rc_no_ssh_config_flag" ]]; then
      _resume_ssh_config_cli_flag="off"
    elif [[ -n "$rc_ssh_config_explicit_flag" ]]; then
      _resume_ssh_config_cli_flag="on"
    fi
    _up_resolve_resume_ssh_config "$name" "$path" "$_resume_ssh_config_cli_flag"
    rc_ssh_config="$_UP_RESUME_SSH_CONFIG"
    # ADR-020 D2: translate host SSH config → cage-compatible config (idempotent, re-run on resume).
    # Skip when posture=off (no translated config mounted, nothing to update).
    local _rc_ssh_cache_dir="${HOME}/.cache/rip-cage/${name}"
    mkdir -p "$_rc_ssh_cache_dir"
    if [[ "$rc_ssh_config" == "on" ]]; then
      _translate_ssh_config "${HOME}/.ssh/config" "${_rc_ssh_cache_dir}/ssh-config" "$_UP_RESUME_GITHUB_IDENTITY"
    fi
    # ADR-022 D3: refresh filtered known_hosts cache and ssh-allowed-keys sentinel
    # on resume (bind-mount content updates propagate live). Mount shape is immutable
    # on resume — if ssh.allowed_keys was toggled between null and non-null since
    # create, the rc.ssh-key-filter label resolver below aborts loud.
    _up_resolve_resume_ssh_key_filter "$name" "$path"
    # ADR-021 D7: config-mode mount-shape guard — abort loud if mounts.config_mode
    # was toggled between ro and rw since the container was created.
    _up_resolve_resume_config_mode "$name" "$path"
    # rip-cage-c1p.2 D4: symlink-follow fingerprint label-lock — abort loud if
    # the dangling-symlink set (or mode) changed since create time.
    _up_resolve_resume_symlink_fingerprint "$name" "$path"
    # rip-cage-seqc.4 / B1: credential-mounts mount-shape guard — abort loud if
    # auth.credential_mounts was toggled between real and none since create.
    _up_resolve_resume_credential_mounts "$name" "$path"
    # rip-cage-3y9g: RESUME-GUARDS-REAL-STOPPED END
    _UP_SSH_FILTER_ACTIVE="false"
    _up_resolve_ssh_allowlists "$path" "$_rc_ssh_cache_dir"
    # On resume, the socket (or lack thereof) was wired at create time. The
    # label value is the ground truth for preflight — we don't re-distinguish
    # user-opt-out from no-host-agent here. Socket cannot be changed on resume.
    # Recover the original source path from the existing bind mount so the
    # sentinel stays honest after rc down && rc up (ADR-018 D3 FIRM).
    # ADR-022: when filtering is active, the socket was mounted as /ssh-agent-upstream.sock.
    _UP_FORWARD_SSH_HOST_SOCK=$(docker inspect \
      --format '{{ range .Mounts }}{{ if eq .Destination "/ssh-agent-upstream.sock" }}{{ .Source }}{{ end }}{{ end }}' \
      "$name" 2>/dev/null || true)
    if [[ -z "$_UP_FORWARD_SSH_HOST_SOCK" ]]; then
      _UP_FORWARD_SSH_HOST_SOCK=$(docker inspect \
        --format '{{ range .Mounts }}{{ if eq .Destination "/ssh-agent.sock" }}{{ .Source }}{{ end }}{{ end }}' \
        "$name" 2>/dev/null || true)
    fi
    _UP_NO_HOST_AGENT=""
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      docker start "$name" >/dev/null
    else
      docker start "$name"
    fi
    _up_init_container "$name"
    if [[ "$_UP_INIT_OK" == "false" ]]; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        docker stop "$name" >/dev/null 2>&1
        _up_json_output "$name" "resumed" "$path" "stopped" "failed"
        return 1
      fi
      echo "Error: init failed on resume. Stopping container so next 'rc up' retries." >&2
      docker stop "$name"
      exit 1
    fi
    _up_ssh_preflight "$name" "$rc_forward_ssh"
    # ADR-020 D5+D6: github.com identity preflight — probe greeting inside cage,
    # write /etc/rip-cage/github-identity and /etc/rip-cage/ssh-config-source.
    # On resume, the resolved identity is from the container label (layer 2).
    # Source layer: disabled if posture=off; else label if label present; else rules/host-config/none.
    _resolve_github_identity_source "$rc_github_identity_flag" "${_UP_RESUME_GITHUB_IDENTITY:-}" "" "$rc_ssh_config"
    _up_github_identity_preflight "$name" "${_UP_RESUME_GITHUB_IDENTITY:-}" "$_UP_GITHUB_IDENTITY_SOURCE"
    # ADR-022 D6 / rip-cage-ocn: resume already re-applied ssh.allowed_hosts
    # (via _up_resolve_ssh_allowlists above). Merge live reload-eligible paths
    # into the applied-config snapshot so the drift hint doesn't keep nagging.
    # Non-eligible paths in the snapshot are preserved (they're locked to
    # container labels / mount shape; live drift in those still earns a hint).
    if command -v yq &>/dev/null; then
      local _ocn_applied _ocn_result _ocn_live
      if _ocn_applied=$(_config_read_applied "$name" 2>/dev/null); then
        if _ocn_result=$(_load_effective_config "$path" 2>/dev/null); then
          _ocn_live=$(jq -c '.config' <<<"$_ocn_result")
          local _ocn_merged
          _ocn_merged=$(jq -nc --argjson a "$_ocn_applied" --argjson live "$_ocn_live" \
            '$a | .ssh.allowed_hosts = ($live.ssh.allowed_hosts // [])')
          _config_write_applied "$name" "$_ocn_merged"
        fi
      fi
    fi
    _config_emit_hint "$path" "$name"
    _config_init_emit_tip "$path"
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      _up_json_output "$name" "resumed" "$path" "running" "success"
      return
    fi
    # rip-cage-1f59.2 / rip-cage-61al.3: dispatch via baked registry (resumed cage label is immutable).
    local _up_resume_mux
    _up_resume_mux=$(_container_multiplexer "$name")
    case "$_up_resume_mux" in
      none)
        [[ -n "$rc_up_new_session" || -n "$rc_up_session_name" ]] && \
          echo "warning: --new/--session ignored under multiplexer=none" >&2
        if [[ -t 0 && -t 1 ]]; then
          docker exec -it "$name" zsh
        else
          echo "Container $name is running (multiplexer=none). Exec with: rc exec $name -- <cmd>" >&2
        fi
        ;;
      *)
        local _up_resume_hook_path
        if [[ -n "$rc_up_new_session" ]]; then
          _up_resume_hook_path=$(_rc_mux_resolve_hook_path "$_up_resume_mux" "new_session" "$name") || return 1
          if [[ -z "$_up_resume_hook_path" ]]; then
            echo "warning: multiplexer '${_up_resume_mux}' has no new_session hook — falling back to attach" >&2
            _up_resume_hook_path=$(_rc_mux_resolve_hook_path "$_up_resume_mux" "attach" "$name") || return 1
          fi
        else
          _up_resume_hook_path=$(_rc_mux_resolve_hook_path "$_up_resume_mux" "attach" "$name") || return 1
        fi
        if [[ -z "$_up_resume_hook_path" ]]; then
          echo "Error: multiplexer '${_up_resume_mux}' has no attach hook in registry for cage '$name'." >&2
          return 1
        fi
        if [[ -t 0 && -t 1 ]]; then
          # Forward --session NAME to the hook as $1 (mux-agnostic; hook may ignore if not applicable).
          docker exec -it "$name" sh "$_up_resume_hook_path" "${rc_up_session_name:-}"
        else
          echo "Container $name is running (multiplexer=${_up_resume_mux}). Attach with: rc attach $name" >&2
        fi
        ;;
    esac
    return
  elif [[ "$_inspect_exit" -ne 0 ]]; then
    : # container absent — fall through to "New container" block below
  elif [[ "$state" == "paused" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is paused. Run: docker unpause $name then retry: rc up $path" "CONTAINER_STATE_UNSUPPORTED"
    echo "Error: Container $name is paused. Run: docker unpause $name then retry: rc up $path" >&2
    return 1
  elif [[ "$state" == "restarting" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is restarting. Wait, or run: docker stop $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
    echo "Error: Container $name is restarting. Wait, or run: docker stop $name && rc up $path" >&2
    return 1
  elif [[ "$state" == "removing" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is being removed. Wait, then run: rc up $path" "CONTAINER_STATE_UNSUPPORTED"
    echo "Error: Container $name is being removed. Wait, then run: rc up $path" >&2
    return 1
  elif [[ "$state" == "dead" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is dead. Run: rc destroy $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
    echo "Error: Container $name is dead. Run: rc destroy $name && rc up $path" >&2
    return 1
  else
    # Unrecognized state (allowlist exhausted) — fail loud per ADR-001.
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is in unrecognized state: state=$state. Inspect manually with: docker inspect $name  — if safe, rc destroy $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
    echo "Error: Container $name is in unrecognized state: state=$state. Inspect manually with: docker inspect $name  — if safe, rc destroy $name && rc up $path" >&2
    return 1
  fi

  # New container — provision image now if absent/stale (ADR-008 D6).
  # All other state paths (running/exited/paused/dead/etc.) never need a fresh image
  # and must NOT trigger a pull/build (ADR-001: fail fast, no wasteful side-effects).
  if [[ "$_image_absent" == "true" ]]; then
    if ! _pull_or_build; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        json_error "Image provisioning failed (pull and build both failed)" "BUILD_FAILED"
      else
        echo "Error: Image provisioning failed (pull and build both failed)." >&2
        exit 1
      fi
    fi
  fi

  log "Creating container $name for $path..."
  local _UP_RUN_ARGS=()
  _UP_RUN_ARGS+=(-d --name "$name")
  _UP_RUN_ARGS+=(--label "rc.source.path=$path")

  # ADR-020 D3: resolve github.com identity (four-layer: CLI → label → rules → unset).
  # On create, container_name is empty (no existing label yet); layer 2 is skipped.
  local _resolved_github_identity
  _resolved_github_identity=$(_resolve_github_identity "$rc_github_identity_flag" "" "$path")
  if [[ -n "$_resolved_github_identity" ]]; then
    _UP_RUN_ARGS+=(--label "rc.github-identity=$_resolved_github_identity")
  fi
  # Determine source layer for preflight sentinel (create path: no label, so layer 2 empty).
  # _rules_file_result is empty when CLI provided the key; non-empty only when rules-file matched.
  local _rules_file_result_for_source=""
  if [[ -z "$rc_github_identity_flag" ]] && [[ -n "$_resolved_github_identity" ]]; then
    _rules_file_result_for_source="$_resolved_github_identity"
  fi
  _resolve_github_identity_source "$rc_github_identity_flag" "" "$_rules_file_result_for_source" "$rc_ssh_config"

  # ADR-020 D2+D7: translate host SSH config and mount pubkeys (or skip if posture=off).
  local _rc_ssh_cache_dir="${HOME}/.cache/rip-cage/${name}"
  local _rc_ssh_cfg="${_rc_ssh_cache_dir}/ssh-config"
  mkdir -p "$_rc_ssh_cache_dir"

  # ADR-022 D3: resolve SSH allowlists from effective .rip-cage.yaml config.
  # Writes filtered known_hosts cache and (when ssh.allowed_keys is set) the
  # ssh-allowed-keys sentinel. Sets _UP_SSH_FILTER_ACTIVE which gates the
  # socket-destination swap in _up_prepare_environment.
  _UP_SSH_FILTER_ACTIVE="false"
  _up_resolve_ssh_allowlists "$path" "$_rc_ssh_cache_dir"

  # ADR-025 D1/D5: translate dcg.* from effective config into a merged DCG
  # config file. Fail-closed on malformed TOML (D5). Safe-by-default: no file
  # written and _UP_DCG_CONFIG_PATH stays empty when no dcg.* configured.
  _UP_DCG_CONFIG_PATH=""
  if ! _up_resolve_dcg_config "$path" "$_rc_ssh_cache_dir"; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "DCG config translation failed — check dcg.* in .rip-cage.yaml (ADR-025 D5 fail-closed)" "DCG_CONFIG_INVALID"
    fi
    exit 1
  fi

  if [[ "$rc_ssh_config" == "on" ]]; then
    _translate_ssh_config "${HOME}/.ssh/config" "$_rc_ssh_cfg" "$_resolved_github_identity"
    # ADR-020 D4: explicit pin (layers 1-3) + missing .pub → abort loud.
    if [[ -n "$_resolved_github_identity" ]]; then
      local _pin_source="explicit"
      _assert_pubkey_exists_or_die "$_resolved_github_identity" "$_pin_source" || exit 1
    fi
  fi
  # Persist posture as container label (D7).
  _UP_RUN_ARGS+=(--label "rc.ssh-config=${rc_ssh_config}")

  # ADR-022: persist ssh-key-filter posture as a container label so resume can
  # detect ssh.allowed_keys mount-shape transitions (null ↔ non-null) and abort
  # loud rather than silently filter against a stale sentinel. Mirrors the
  # rc.forward-ssh / rc.ssh-config / rc.github-identity label-lock pattern.
  if [[ "${_UP_SSH_FILTER_ACTIVE:-false}" == "true" ]]; then
    _UP_RUN_ARGS+=(--label "rc.ssh-key-filter=on")
  else
    _UP_RUN_ARGS+=(--label "rc.ssh-key-filter=off")
  fi

  # auth.credential_mounts (rip-cage-seqc.4 / E2) + auth.per_tool.{claude,pi}
  # (rip-cage-xhgr / D1): resolve the effective values BEFORE the
  # symlink-follow fingerprint call below (B1a) — the fingerprint's leaf-filter
  # (F1) must be computed with the SAME effective(pi) value that determines
  # the mount set, or the create-time fingerprint label would not match the
  # honest post-filter mount set. _UP_CREDENTIAL_MOUNTS / _UP_CRED_MOUNTS_CLAUDE
  # / _UP_CRED_MOUNTS_PI are globals (not `local`) so _up_prepare_docker_mounts
  # can read them below. The global label stays unchanged (byte-identical to
  # today); the two new per-tool labels are emitted unconditionally alongside
  # it (D5a) so resume can detect a per-tool mount-shape flip.
  _UP_CREDENTIAL_MOUNTS="real"
  _UP_CRED_MOUNTS_CLAUDE="real"
  _UP_CRED_MOUNTS_PI="real"
  if [[ -f "$(_config_global_path)" || -f "$(_config_project_path "$path")" ]]; then
    if command -v yq &>/dev/null; then
      local _cred_mounts_cfg
      if _cred_mounts_cfg=$(_load_effective_config "$path" 2>/dev/null); then
        _UP_CREDENTIAL_MOUNTS=$(jq -r '.config.auth.credential_mounts // "real"' <<<"$_cred_mounts_cfg")
        _UP_CRED_MOUNTS_CLAUDE=$(_up_resolve_effective_credential_mounts_for_tool "claude" "$_cred_mounts_cfg")
        _UP_CRED_MOUNTS_PI=$(_up_resolve_effective_credential_mounts_for_tool "pi" "$_cred_mounts_cfg")
      fi
      unset _cred_mounts_cfg
    fi
  fi
  _UP_RUN_ARGS+=(--label "rc.auth.credential-mounts=${_UP_CREDENTIAL_MOUNTS}")
  _UP_RUN_ARGS+=(--label "rc.auth.credential-mounts.claude=${_UP_CRED_MOUNTS_CLAUDE}")
  _UP_RUN_ARGS+=(--label "rc.auth.credential-mounts.pi=${_UP_CRED_MOUNTS_PI}")

  # ADR-021 D7: persist effective mounts.config_mode as a container label so
  # resume can detect ro↔rw mount-shape transitions and abort loud rather than
  # silently presenting a stale mount shape. Mirrors rc.ssh-key-filter pattern.
  local _cm_label_mode="ro"
  if [[ -f "$(_config_global_path)" || -f "$(_config_project_path "$path")" ]]; then
    if command -v yq &>/dev/null; then
      local _cm_label_cfg
      if _cm_label_cfg=$(_load_effective_config "$path" 2>/dev/null); then
        _cm_label_mode=$(jq -r '.config.mounts.config_mode // "ro"' <<<"$_cm_label_cfg")
      fi
      unset _cm_label_cfg
    fi
  fi
  _UP_RUN_ARGS+=(--label "rc.config-mode=${_cm_label_mode}")
  unset _cm_label_mode

  # ADR-021 D5: persist effective .rip-cage.yaml content sha as a container
  # label — but ONLY when at least one config file exists. D5 forbids new
  # labels in the both-absent case (cage posture must be byte-identical to
  # pre-loader). _config_validate_or_abort upstream guarantees that if any
  # file is present, yq + D3 validation already passed.
  if [[ -f "$(_config_global_path)" || -f "$(_config_project_path "$path")" ]]; then
    local _rc_config_sha
    _rc_config_sha=$(_config_label_value "$path")
    if [[ -n "$_rc_config_sha" ]]; then
      _UP_RUN_ARGS+=(--label "rc.config-loaded=${_rc_config_sha}")
    fi
  fi

  # rip-cage-c1p.2 D4: persist symlink-follow fingerprint as a container label
  # so resume can detect mount-shape drift and abort loud. Computed from sorted
  # "<link> → <target> (<mode>)" lines plus a policy header (on_dangling, scope)
  # so that policy changes also produce fingerprint drift.
  # Emitted unconditionally so the label is always present for resume checks.
  # Follows rc.ssh-key-filter precedent (ADR-022 / rip-cage-jxy).
  local _sfl_mode_for_fp="rw" _sfl_on_dangling_for_fp="follow" _sfl_scope_for_fp="file"
  if [[ -f "$(_config_global_path)" || -f "$(_config_project_path "$path")" ]]; then
    if command -v yq &>/dev/null; then
      local _sfl_fp_cfg
      if _sfl_fp_cfg=$(_load_effective_config "$path" 2>/dev/null); then
        _sfl_mode_for_fp=$(jq -r '.config.mounts.symlinks.mode // "rw"' <<<"$_sfl_fp_cfg")
        _sfl_on_dangling_for_fp=$(jq -r '.config.mounts.symlinks.on_dangling // "follow"' <<<"$_sfl_fp_cfg")
        _sfl_scope_for_fp=$(jq -r '.config.mounts.symlinks.scope // "file"' <<<"$_sfl_fp_cfg")
      fi
    fi
  fi
  # effective(pi), NEVER effective(claude) (rip-cage-xhgr / D5b) — this
  # fingerprint's scan root is ~/.pi/agent only.
  local _sfl_fingerprint
  _sfl_fingerprint=$(_symlink_follow_fingerprint "${HOME}/.pi/agent" "$_sfl_mode_for_fp" "$_sfl_on_dangling_for_fp" "$_sfl_scope_for_fp" "$path" "$_UP_CRED_MOUNTS_PI")
  _UP_RUN_ARGS+=(--label "rc.symlink-follow-fingerprint=${_sfl_fingerprint}")
  unset _sfl_mode_for_fp _sfl_on_dangling_for_fp _sfl_scope_for_fp _sfl_fp_cfg _sfl_fingerprint

  # rip-cage-1f59.1: resolve session.multiplexer from effective config (ADR-021 D6).
  # Defaults to "none" when unset. Invalid enum values are already caught by
  # _config_validate_or_abort (upstream) per ADR-001 fail-loud contract.
  # Threaded into the container as RC_MULTIPLEXER env var (read by init-rip-cage.sh)
  # and stamped as rc.session.multiplexer label (for attach helpers + rc ls).
  local _rc_multiplexer="none"
  if [[ -f "$(_config_global_path)" || -f "$(_config_project_path "$path")" ]]; then
    if command -v yq &>/dev/null; then
      local _mux_eff_result
      if _mux_eff_result=$(_load_effective_config "$path" 2>/dev/null); then
        _rc_multiplexer=$(jq -r '.config.session.multiplexer // "none"' <<<"$_mux_eff_result")
      fi
    fi
  fi
  _UP_RUN_ARGS+=(-e "RC_MULTIPLEXER=${_rc_multiplexer}")
  _UP_RUN_ARGS+=(--label "rc.session.multiplexer=${_rc_multiplexer}")
  log "session.multiplexer: ${_rc_multiplexer}"
  # rip-cage-1f59.2: _rc_multiplexer intentionally NOT unset here — used by the new-container
  # attach block below. It is unset after that block (after _config_init_emit_tip).
  unset _mux_eff_result

  _up_prepare_docker_mounts "$path" "$name"

  # rip-cage-b9to: resolve the auth.placeholder_env_file pointer (create-only,
  # immediately before _up_prepare_environment consumes env_file as $3). CLI
  # --env-file always wins — the resolver itself checks env_file's current
  # value and no-ops (with a log note) when it is already non-empty.
  _up_resolve_placeholder_env_file "$path" "$env_file"
  if [[ -n "$_UP_PLACEHOLDER_ENV_FILE" ]]; then
    env_file="$_UP_PLACEHOLDER_ENV_FILE"
  fi

  _up_prepare_environment "$path" "$port" "$env_file" "$rc_cpus" "$rc_memory" "$rc_pids_limit" "$rc_forward_ssh"

  # rip-cage-hhh.6 D3 (evolved, ADR-029 D2): rc.egress.config-override label so
  # rc doctor can surface the ADR-024 D1 workspace-base-URL-override posture
  # without a per-cage docker exec. (rc.egress.mode retired with the deleted
  # in-cage router — mode was the router's observe/block posture.)
  _UP_RUN_ARGS+=(--label "rc.egress.config-override=${rc_allow_config_override:-false}")

  # ADR-020 D1+D7: mount translated config + pubkeys when posture=on (after run-args are initialized).
  if [[ "$rc_ssh_config" == "on" ]]; then
    _build_ssh_mount_args_with_posture "$_rc_ssh_cfg" "$name" _UP_RUN_ARGS "on"
  fi

  # ADR-025 D1/D5: mount translated DCG config RO over the wrapper's pinned path.
  # Only added when dcg.* is configured; safe-by-default when absent.
  if [[ -n "${_UP_DCG_CONFIG_PATH:-}" ]]; then
    _UP_RUN_ARGS+=(--mount "type=bind,src=${_UP_DCG_CONFIG_PATH},dst=/usr/local/lib/rip-cage/dcg/config.toml,ro")
    log "DCG policy: merged config mounted at /usr/local/lib/rip-cage/dcg/config.toml (ADR-025 D1)"
  fi

  _UP_RUN_ARGS+=("$IMAGE" sleep infinity)

  _up_start_container "$name"
  _up_init_container "$name"

  if [[ "$_UP_INIT_OK" == "false" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      docker stop "$name" >/dev/null 2>&1
      _up_json_output "$name" "created" "$path" "stopped" "failed"
      return 1
    fi
    echo "Error: init failed. Stopping container so next 'rc up' retries." >&2
    docker stop "$name"
    exit 1
  fi

  _up_ssh_preflight "$name" "$rc_forward_ssh"
  # ADR-020 D5+D6: github.com identity preflight — probe greeting inside cage,
  # write /etc/rip-cage/github-identity and /etc/rip-cage/ssh-config-source.
  _up_github_identity_preflight "$name" "$_resolved_github_identity" "$_UP_GITHUB_IDENTITY_SOURCE"
  # ADR-022 D6 / rip-cage-ocn: write applied-config snapshot so future
  # `rc reload` invocations can diff against create-time intent and
  # `_config_emit_hint` can suppress false-positive drift after a reload.
  # Best-effort: do nothing if yq absent or no config files (sha-only hint
  # path is still correct in that case).
  if command -v yq &>/dev/null; then
    local _ocn_result _ocn_cfg
    if _ocn_result=$(_load_effective_config "$path" 2>/dev/null); then
      local _ocn_g _ocn_p
      _ocn_g=$(jq -r '.layers.global' <<<"$_ocn_result")
      _ocn_p=$(jq -r '.layers.project' <<<"$_ocn_result")
      if [[ "$_ocn_g" != "null" || "$_ocn_p" != "null" ]]; then
        _ocn_cfg=$(jq -c '.config' <<<"$_ocn_result")
        _config_write_applied "$name" "$_ocn_cfg"
      fi
    fi
  fi
  _config_emit_hint "$path" "$name"
  _config_init_emit_tip "$path"
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    _up_json_output "$name" "created" "$path" "running" "success"
    return
  fi
  # rip-cage-1f59.2 / rip-cage-61al.3: dispatch via baked registry (new container — value still in _rc_multiplexer).
  case "${_rc_multiplexer:-none}" in
    none)
      [[ -n "$rc_up_new_session" || -n "$rc_up_session_name" ]] && \
        echo "warning: --new/--session ignored under multiplexer=none" >&2
      if [[ -t 0 && -t 1 ]]; then
        docker exec -it "$name" zsh
      else
        echo "Container $name is running (multiplexer=none). Exec with: rc exec $name -- <cmd>" >&2
      fi
      ;;
    *)
      local _up_new_hook_path
      if [[ -n "$rc_up_new_session" ]]; then
        _up_new_hook_path=$(_rc_mux_resolve_hook_path "${_rc_multiplexer:-none}" "new_session" "$name") || { unset _rc_multiplexer; return 1; }
        if [[ -z "$_up_new_hook_path" ]]; then
          echo "warning: multiplexer '${_rc_multiplexer:-none}' has no new_session hook — falling back to attach" >&2
          _up_new_hook_path=$(_rc_mux_resolve_hook_path "${_rc_multiplexer:-none}" "attach" "$name") || { unset _rc_multiplexer; return 1; }
        fi
      else
        _up_new_hook_path=$(_rc_mux_resolve_hook_path "${_rc_multiplexer:-none}" "attach" "$name") || { unset _rc_multiplexer; return 1; }
      fi
      if [[ -z "$_up_new_hook_path" ]]; then
        echo "Error: multiplexer '${_rc_multiplexer:-none}' has no attach hook in registry for cage '$name'." >&2
        unset _rc_multiplexer
        return 1
      fi
      if [[ -t 0 && -t 1 ]]; then
        # Forward --session NAME to the hook as $1 (mux-agnostic; hook may ignore if not applicable).
        docker exec -it "$name" sh "$_up_new_hook_path" "${rc_up_session_name:-}"
      else
        echo "Container $name is running (multiplexer=${_rc_multiplexer:-none}). Attach with: rc attach $name" >&2
      fi
      ;;
  esac
  unset _rc_multiplexer
}


# Auto-seed the global config on first run (rip-cage-j86 / ADR-023 D6 evolution).
# If the file already exists: silent no-op (idempotent — returns 0 immediately).
# If absent: mkdir -p its directory, write the default denylist YAML, and emit a
# one-line stderr notice so the user knows what happened.
# ORDERING IS LOAD-BEARING: call this BEFORE _config_validate_or_abort in cmd_up
# so the yq-presence check inside the validator covers the freshly-seeded config.
# Seeding is the safe direction — it only adds blocking, never widens capability.
_config_ensure_global_seeded() {
  local _path
  _path=$(_config_global_path)
  if [[ -f "$_path" ]]; then
    return 0
  fi
  # Fail-loud, self-enforcing presence guarantee (ADR-001): do NOT rely on the
  # caller's `set -e`. The denylist matcher fails open without a valid config, so
  # a silent seed-failure here would re-open the very hole this seeding closes.
  if ! mkdir -p "$(dirname "$_path")"; then
    echo "Error: failed to create config directory for ${_path}." >&2
    exit 1
  fi
  if ! _config_default_global_yaml > "$_path" || [[ ! -s "$_path" ]]; then
    echo "Error: failed to seed default secret-path denylist at ${_path}. The denylist matcher fails open without a valid config; refusing to continue (ADR-023 D6 / ADR-001)." >&2
    exit 1
  fi
  echo "rip-cage: seeded default secret-path denylist at ${_path} (first run; run 'rc config show' to view, or edit to customize)." >&2
}


# _manifest_egress_hosts_json — collect all egress: hosts declared across all
# manifest entries into a JSON array (ADR-005 D3). The in-cage engine that
# used to consume this union (the deleted egress router) is retired per
# ADR-029 D2; this collector survives as the declare-time data source S6
# wires into the msb-flags generator's allowed_hosts input.
#
# Returns a JSON array of strings on stdout (may be empty: []).
_manifest_egress_hosts_json() {
  local manifest_json
  if ! manifest_json=$(_manifest_load 2>/dev/null); then
    echo "[]"
    return 0
  fi

  local count
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    echo "[]"
    return 0
  fi

  # Collect all egress hosts from all entries (deduplicated).
  jq -c '[.tools[].egress // [] | .[]] | unique' <<<"$manifest_json" 2>/dev/null || echo "[]"
}


# _manifest_build_mount_args — build the -v docker run args for all manifest
# mounts: entries (rip-cage-buuo.1 / rip-cage-wlwc.3).
#
# For each tool entry in the manifest:
#   - Iterates over mounts[] entries (objects {host, dest[, mode][, root_owned_required]}).
#   - Skips entries whose .host dir does not exist on the host (skip-if-missing).
#   - Applies realpath to resolve the host path (ADR-023 D6 FIRM).
#   - Checks against the secret-path denylist (ADR-023 D1/D6 FIRM) — fail-loud.
#   - Reads per-asset .mode field ('ro' or 'rw'; default 'ro' per ADR-027 D1).
#   - Emits "<resolved_host>:<dest>:<mode>" to stdout (one per line).
#
# The caller (_up_prepare_docker_mounts) collects these into _UP_RUN_ARGS via -v.
#
# Mounts DIRECTORIES only — never a single-file bind (host-atomic-rename tripwire).
#
# Parameters:
#   $1  workspace — passed to _check_secret_path_denylist as the workspace root
#
# Stdout: zero or more "<host>:<dest>:<mode>" lines (one per mount)
# Stderr: skip/error messages
# Returns: 0 on success, 1 on denylist-denied mount (fail-loud).
_manifest_build_mount_args() {
  local _workspace="${1:-.}"

  # Load manifest (fail-closed if invalid).
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local idx
  for (( idx=0; idx<count; idx++ )); do
    local entry mounts_count midx
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)

    mounts_count=$(jq '.mounts | length' <<<"$entry" 2>/dev/null)
    [[ -z "$mounts_count" || "$mounts_count" -eq 0 ]] && continue

    local tool_name
    tool_name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)

    for (( midx=0; midx<mounts_count; midx++ )); do
      local mount_host mount_dest expanded_host
      mount_host=$(jq -r ".mounts[${midx}].host" <<<"$entry" 2>/dev/null)
      mount_dest=$(jq -r ".mounts[${midx}].dest" <<<"$entry" 2>/dev/null)

      # Skip entries with missing/null host or dest (validator should have caught these,
      # but be defensive at the consumer level).
      [[ -z "$mount_host" || "$mount_host" == "null" ]] && continue
      [[ -z "$mount_dest" || "$mount_dest" == "null" ]] && continue

      # Expand ~/  and $HOME/${HOME} before existence check (rip-cage-buuo.5).
      # bash does NOT tilde-expand variables, so "~/.foo" in a manifest literal
      # would fail [[ -d ]] without this step.
      expanded_host=$(_manifest_expand_mount_host "$mount_host")

      # Skip-if-host-missing: if the host path does not exist, skip this mount.
      # This allows tools to declare mounts for optional data dirs — if the dir
      # doesn't exist on the host, no mount is added (no error).
      if [[ ! -d "$expanded_host" ]]; then
        echo "manifest mount for '${tool_name}': host dir '${mount_host}' not found — skipping (skip-if-host-missing)" >&2
        continue
      fi

      # Realpath-first: resolve before denylist check (ADR-023 D6 FIRM).
      local resolved_host
      resolved_host=$(realpath "$expanded_host" 2>/dev/null) || resolved_host="$expanded_host"

      # ADR-023 D1/D6: denylist check — fail-loud for manifest-managed mounts.
      if _check_secret_path_denylist "$resolved_host" "$_workspace"; then
        local _denied_pattern
        _denied_pattern=$(_secret_path_denylist_matched_pattern "$resolved_host" "$_workspace" 2>/dev/null || true)
        echo "Error: manifest-declared mount for tool '${tool_name}': '${resolved_host}' matched secret-path denylist pattern '${_denied_pattern:-<unknown>}'. Remove this path from the manifest mounts: declaration or add to mounts.allow_risky in .rip-cage.yaml. (ADR-023 D1/D6)" >&2
        return 1
      fi

      # rip-cage-rc09: dest-allowlist check — fail-loud for non-agent-writable dests.
      # CARVE-OUT (honest): root_owned_required: true mounts are exempt from
      # the dest-allowlist ONLY IF the resolved HOST SOURCE is genuinely
      # root-owned (uid 0, not group/other-writable).
      #
      # If root_owned_required: true but the source is NOT root-owned, the
      # exemption is NOT granted — fall through to the normal allowlist check.
      # This closes the bypass: a fragment with root_owned_required: true +
      # dest: /etc/rip-cage/pi + host: <agent-writable dir> is NOT exempt
      # (host uid != 0 → no exemption → allowlist rejects the system dest).
      # Cite: rip-cage-rc09 / ADR-027 D1.
      local _mba_root_owned_req _mba_allowlist_exempt=0
      _mba_root_owned_req=$(jq -r ".mounts[${midx}].root_owned_required // false" <<<"$entry" 2>/dev/null)
      if [[ "$_mba_root_owned_req" == "true" ]] && _host_source_is_root_owned "$resolved_host"; then
        _mba_allowlist_exempt=1
      fi
      if [[ "$_mba_allowlist_exempt" -ne 1 ]]; then
        local _norm_mount_dest
        _norm_mount_dest=$(_lexical_normalize_path "$mount_dest")
        if ! _manifest_dest_in_allowed_roots "$_norm_mount_dest"; then
          echo "Error: manifest-declared mount for tool '${tool_name}': dest '${mount_dest}' (normalized: '${_norm_mount_dest}') is outside the agent-writable allowlist (/home/agent, /workspace). Mounts must land in agent-writable space, or declare root_owned_required: true with a root-owned host source (ADR-027 D1). (rip-cage-rc09)" >&2
          return 1
        fi
      fi

      # Per-asset ro/rw mode (rip-cage-wlwc.3 / ADR-027 D1).
      # Default is 'ro' — opt-in write-through requires explicit mode: rw.
      local mount_mode
      mount_mode=$(jq -r ".mounts[${midx}].mode // \"ro\"" <<<"$entry" 2>/dev/null)
      [[ "$mount_mode" != "rw" ]] && mount_mode="ro"

      # Emit host:dest:mode (caller adds -v as a separate array element — two-element form).
      echo "${resolved_host}:${mount_dest}:${mount_mode}"
    done
  done

  return 0
}


# =============================================================================
# End manifest egress+mounts floor (rip-cage-4c5.3)
# End manifest binary-ownership + build-isolation assertions (rip-cage-buuo.3)
# End per-asset ro/rw mount mode + root_owned_required validator (rip-cage-wlwc.3)
# =============================================================================

# _ensure_pi_auth_seed — cold-start seeding for pi auth (rip-cage-wo9 / ADR-019 D1).
# Creates ~/.pi/agent/auth.json containing '{}' when it is absent so that an
# in-cage 'pi /login' persists across rc destroy/up cycles via the single-file
# bind mount.  The check is:
#   - if the path does NOT exist as a regular file AND is NOT a symlink: seed it.
#   - a (possibly dangling) symlink is left to the symlink-follow machinery (D1).
#   - an existing regular file (even empty) is never overwritten (idempotent).
# Seeding is transparent to _symlink_follow_fingerprint: the function hashes only
# symlinks; a seeded regular file adds no symlink, so fingerprint is unchanged.
# Honors ${HOME} — override it to make the function testable.
_ensure_pi_auth_seed() {
  local _auth_path="${HOME}/.pi/agent/auth.json"
  # A symlink at the path (even dangling) is dotpi-managed state — leave it alone.
  if [[ -L "$_auth_path" ]]; then
    return 0
  fi
  # A regular file already exists — idempotent no-op.
  if [[ -e "$_auth_path" ]]; then
    return 0
  fi
  # Path absent — seed it.
  if ! mkdir -p "$(dirname "$_auth_path")"; then
    echo "rip-cage: Warning: could not create ${HOME}/.pi/agent/ — pi auth mount may be skipped." >&2
    return 0
  fi
  if ! printf '{}' > "$_auth_path"; then
    echo "rip-cage: Warning: could not seed ${_auth_path} — pi auth mount may be skipped." >&2
    return 0
  fi
  echo "rip-cage: Seeded empty ${HOME}/.pi/agent/auth.json for first-run pi login persistence (rip-cage-wo9)." >&2
}


# Compute the rc.config-loaded label value for a workspace. Returns the
# sha256 from _load_effective_config (cheap to call; same value used by
# `rc config show`). Empty string on loader error — but callers MUST first
# pass through _config_validate_or_abort, which converts the loader-error
# case into a hard exit, so reaching the empty-string branch here implies
# yq-absent + no-config-file (substrate is silent in that case).
_config_label_value() {
  local workspace="$1"
  local result
  result=$(_load_effective_config "$workspace" 2>/dev/null) || return 0
  jq -r '.sha256' <<<"$result"
}


# First-run / drift hint emitter (D5 informational output, extended for ocn).
# Called from cmd_up after container exists. Strategy:
#   1) If the per-container "applied config" snapshot exists (post-rip-cage-ocn
#      containers, including any container that has gone through cmd_up resume
#      since the snapshot was introduced), diff live vs snapshot. Reload-eligible
#      diffs → suggest `rc reload`; non-eligible → suggest `rc destroy && rc up`;
#      no diff → silent.
#   2) Else (legacy container without snapshot), fall back to the original
#      label-sha comparison (rc.config-loaded label).
#
# No-ops silently when yq is absent (substrate must not break existing flows
# for users without yq) or when neither config file exists (per D5).
_config_emit_hint() {
  local workspace="$1" container_name="$2"
  command -v yq &>/dev/null || return 0
  local result
  result=$(_load_effective_config "$workspace" 2>/dev/null) || return 0
  local g_layer p_layer
  g_layer=$(jq -r '.layers.global' <<<"$result")
  p_layer=$(jq -r '.layers.project' <<<"$result")
  if [[ "$g_layer" == "null" && "$p_layer" == "null" ]]; then
    return 0
  fi
  local current_sha live_cfg
  current_sha=$(jq -r '.sha256' <<<"$result")
  live_cfg=$(jq -c '.config' <<<"$result")

  local applied_cfg
  if applied_cfg=$(_config_read_applied "$container_name" 2>/dev/null); then
    # Snapshot-aware path (rip-cage-ocn).
    # Pass schema defaults so absent-in-snapshot + live==default fields are non-drift
    # (handles old snapshots written before a new defaulted field was introduced — rip-cage-1f59.9).
    local _schema_defaults diff_paths
    _schema_defaults=$(_config_schema_defaults_json 2>/dev/null || echo '{}')
    diff_paths=$(_config_diff_paths "$live_cfg" "$applied_cfg" "$_schema_defaults" 2>/dev/null || true)
    if [[ -z "$diff_paths" ]]; then
      return 0  # silent — cage state matches live config
    fi
    if printf '%s\n' "$diff_paths" | _config_paths_all_reload_eligible; then
      log "Notice: .rip-cage.yaml has reload-eligible changes since last apply:"
      while IFS= read -r p; do [[ -n "$p" ]] && log "  - $p"; done <<<"$diff_paths"
      log "  Run: rc reload ${container_name}"
    else
      log "Notice: .rip-cage.yaml has changes since this container was created (paths: $(echo "$diff_paths" | tr '\n' ',' | sed 's/,$//'))."
      log "  Some fields require 'rc destroy ${container_name} && rc up' to take effect (see 'rc config show')."
    fi
    return 0
  fi

  # Legacy fallback: no snapshot file. Use label sha comparison (pre-ocn behavior).
  local existing_label
  existing_label=$(docker inspect --format '{{ index .Config.Labels "rc.config-loaded" }}' "$container_name" 2>/dev/null || true)
  if [[ -z "$existing_label" ]]; then
    log "Loaded .rip-cage.yaml (sha256:${current_sha:0:12}). Run 'rc config show' to inspect."
  elif [[ "$existing_label" != "$current_sha" ]]; then
    log "Notice: .rip-cage.yaml has changed since this container was created (label=${existing_label:0:12}, current=${current_sha:0:12})."
    log "  Some fields may require 'rc destroy && rc up' to take effect (see 'rc config show')."
  fi
}

