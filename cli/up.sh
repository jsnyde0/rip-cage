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
#
# The persistent override NAMES THE FILE THIS RUN READ (rip-cage-ely4.7.14).
# It used to print a risky-mount-exemption YAML block from the retired rip-cage
# config schema — a key nothing reads, so an operator who followed the hint
# edited a no-op and concluded the cage was broken rather than the hint. The
# protected-paths list is a plain one-name-per-line file and its location
# depends on $RC_PROTECTED_PATHS / $XDG_CONFIG_HOME, so the message resolves it
# rather than describing the search order and leaving the operator to guess.
_emit_denylist_denial() {
  local _rpath="$1" _pattern="$2"
  local _list
  _list=$(_protected_paths_resolve 2>/dev/null) || _list=""
  echo "Error: refusing to mount ${_rpath} — matched secret-path denylist pattern '${_pattern}'." >&2
  echo "  Override (one-shot):   rc up --allow-risky-mount ${_rpath} ..." >&2
  if [[ -n "$_list" ]]; then
    echo "  Override (persistent): drop that mount line from this cage's config, or — if you have" >&2
    echo "                         decided '${_pattern}' is not a secret — remove that line from the" >&2
    echo "                         protected-paths list this run read:" >&2
    echo "                           ${_list}" >&2
  else
    echo "  Override (persistent): drop that mount line from this cage's config, or remove" >&2
    echo "                         '${_pattern}' from your protected-paths list (\$RC_PROTECTED_PATHS," >&2
    echo "                         \$XDG_CONFIG_HOME/rip-cage/protected-paths, or the copy shipped" >&2
    echo "                         beside rc)." >&2
  fi
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

  # The allowed-roots containment check that used to gate this retired with the
  # guard (ADR-031 D2). What still has to hold is that the path resolved: a
  # worktree pointing at a .git/ that does not exist leaves git broken inside.
  if [[ -n "$resolved_git_dir" && -d "$resolved_git_dir" ]]; then
    wt_detected=true
    wt_main_git="$resolved_git_dir"
    log "Worktree detected: ${wt_name} (main .git/ at ${wt_main_git})"
  else
    log "Warning: worktree's main .git/ at $main_git_dir could not be resolved — git will not work"
    wt_error="main .git/ at $main_git_dir could not be resolved"
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
# NEW HELPER — distinct from _collect_symlink_parents (cli/up.sh:_collect_symlink_parents) which returns
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
      echo "Error: symlink at '$link' could not be resolved (broken symlink chain). Repair or remove the symlink to unblock." >&2
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
#   $5  cred_mounts — real|none (default: real). F1 (rip-cage-seqc.4): when
#                    none, excludes the pi_root/auth.json leaf from the hash —
#                    IDENTICAL predicate to the mount-loop leaf-filter in
#                    _up_prepare_docker_mounts, so the fingerprint never drifts
#                    from the honest post-filter mount set (label-lock /
#                    filter-the-fingerprint-too). ADR-023 D2 FIRM still holds:
#                    the fingerprint reflects the POST-protected-paths mount set,
#                    since skipped targets never reach the hash. That check needs
#                    no workspace — the protected-paths list is host-global.
# Output: sha256 hex string on stdout (always; empty set hashes to a fixed value)
_symlink_follow_fingerprint() {
  local pi_root="$1" mode="$2" on_dangling="${3:-follow}" scope="${4:-file}" cred_mounts="${5:-real}"
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
      # ADR-023 D2 FIRM: exclude protected-path-skipped mount sources from the
      # hash. Silent skip here — the warning belongs at the mount site.
      if _protected_paths_path_match "$mount_src" >/dev/null 2>&1; then
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

  # The workspace mount is a line in the cage's own config file now, not a
  # flag rc appends -- emitting it here too would declare /workspace twice.

  # Land every in-cage entry mode in the repo, not /home/agent. The image WORKDIR is
  # /home/agent — correct for build-time RUN/CMD, but /workspace is a runtime-only bind
  # mount (above) that doesn't exist at build time, so the fix belongs at container-run
  # time, not in the Dockerfile. Setting the container's runtime working dir here makes
  # `docker run` AND every subsequent `docker exec` (rc attach, multiplexer panes, rc exec,
  # the drover's cage-exec worker spawn) default into the workspace, so bd/git/rg and
  # all project-relative paths resolve without a per-session `cd /workspace`. Colocated
  # with the mount so it only applies when /workspace is actually mounted. (rip-cage-0rng)
  _UP_RUN_ARGS+=(--workdir /workspace)

  # THE WORKSPACE MOUNT, THE CONFIG SHADOW-MOUNT AND mounts.mask ALL LEFT HERE
  # (ADR-031 D2). The cage's own msb config file declares the workspace mount,
  # the session-surviving ~/.claude mounts, the skills mount and any masking
  # line, and it lives host-side outside every cage mount -- so there is no
  # in-tree policy file left to shadow read-only, and no mask list for rc to
  # read. What rc still generates here is only what no config file can hold:
  # mounts computed from the host filesystem at launch.
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

  # auth.per_tool.pi (rip-cage-xhgr): real (default) preserves today's
  # behavior bit-for-bit; none skips pi's credential surface (auth.json mount +
  # symlink-follow leaf). Callers that don't set it default to "real".
  # The Claude-side twin of this switch is gone (rip-cage-ely4.7.10): a cage
  # that wants NON-POSSESSION declares a `secrets:` binding in its own config,
  # which is stronger than suppressing a mount, and the one thing that switch
  # still gated — the host Claude config file — is now an ordinary mount line
  # in the cage config where an operator can read it (ADR-031 D2). See the
  # mount block in share/rip-cage/cage.yaml.template for the line itself.
  local _UP_CRED_MOUNTS_PI="${_UP_CRED_MOUNTS_PI:-real}"
  if [[ "${_UP_DRY_RUN_NO_SIDE_EFFECTS:-0}" == "1" ]]; then
    : # --dry-run assembles the argv without ever reaching the keychain.
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
    local _asset_tdir _skill_pat
    while IFS= read -r _asset_tdir; do
      if _skill_pat=$(_protected_paths_path_match "$_asset_tdir"); then
        echo "Warning: skipping skill symlink mount ${_asset_tdir} — it is a protected path ('${_skill_pat}', see the protected-paths list)" >&2
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
    local _agent_tdir _agent_pat
    while IFS= read -r _agent_tdir; do
      if _agent_pat=$(_protected_paths_path_match "$_agent_tdir"); then
        echo "Warning: skipping agent symlink mount ${_agent_tdir} — it is a protected path ('${_agent_pat}', see the protected-paths list)" >&2
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

  # OAuth mount (read-write, skip if missing to avoid creating an empty dir).
  # The host Claude config file is NOT mounted here: it is a plain mount line
  # in the cage config (share/rip-cage/cage.yaml.template), read-only, where an
  # operator reading the config sees every path the cage receives — ADR-031 D2,
  # rip-cage-ely4.7.10. Read-only is sufficient because init snapshots it into
  # a seed file under ~/.claude at boot (cage/init/init-rip-cage.sh) and Claude
  # Code in-cage reads that seed; read-write would hand a prompt-injected agent
  # (ADR-024, in scope) a write into the host's real Claude config.
  if [[ -f "${HOME}/.claude/.credentials.json" ]]; then
    _UP_RUN_ARGS+=(-v "${HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json")
  else
    log "Warning: ${HOME}/.claude/.credentials.json not found — skipping mount (fine if you are not using Claude Code in this cage)"
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
    /usr /var /tmp /workspace
  )

  # Symlink-follow settings are constants now (ADR-031 D2). They used to be
  # mounts.symlinks.{on_dangling,scope,mode} in the retired rip-cage schema,
  # and these are that schema's own defaults — so an unconfigured cage behaves
  # exactly as it did before. ADR-031 D2's alternatives table carries the
  # ruling that nothing remained to put in an rc-scoped config file.
  local _sfl_on_dangling="follow" _sfl_scope="file" _sfl_mode="rw"

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
      local _sfl_denied_pat
      if _sfl_denied_pat=$(_protected_paths_path_match "$_sfl_mount_src"); then
        echo "Warning: skipping symlink-follow mount ${_sfl_mount_src} — it is a protected path ('${_sfl_denied_pat}', see the protected-paths list)" >&2
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
          echo "[rip-cage] Error: dangling symlink at '${_sfl_link}' targets '${_sfl_target}'; repair or remove the symlink to unblock." >&2
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
  # and are declared in the project's own cage config mounts: block (ADR-031 D2/D4).
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
      if _pi_pat=$(_protected_paths_path_match "${_pi_host_real}"); then
        echo "Warning: skipping pi substrate mount ${_pi_host_real} — it is a protected path ('${_pi_pat}', see the protected-paths list)" >&2
        continue
      fi
      _UP_RUN_ARGS+=(-v "${_pi_host_real}:/home/agent/.rc-context/${_pi_cage_name}:ro")
    done
    unset _pi_substrate_table _pi_substrate_entry _pi_host_raw _pi_cage_name _pi_host_real _pi_pat
  fi

  # CAGE_HOST_ADDR explicit pass-through for non-interactive pi -p runs.
  # Resolve on the host side so the value is never empty inside the container.
  # rip-cage-rj68 (S6): default swapped from docker's host.docker.internal
  # to msb's equivalent synthetic host-gateway hostname,
  # host.microsandbox.internal (confirmed present in every msb-booted guest,
  # docs/2026-07-09-msb-spike-ssh-agent.md). KNOWN LIMITATION carried
  # forward from that spike, not resolved by this bead: general TCP dials to
  # host.microsandbox.internal are fake-accepted by msb's netstack for
  # arbitrary/unbound destinations (the LAN-IP host-service spike,
  # docs/2026-07-09-msb-spike-lan-ip-host-service.md, found the host's real
  # LAN IP is the only genuinely delivered guest->host path) — a caller of
  # CAGE_HOST_ADDR relying on it to reach an arbitrary host-bound port
  # should verify with a real bidirectional data check, not connect()
  # success, exactly as everywhere else in this codebase. No current
  # acceptance criterion in this bead depends on this value's live
  # reachability; only the identifier name is fixed here.
  _UP_RUN_ARGS+=(-e "CAGE_HOST_ADDR=${CAGE_HOST_ADDR:-host.microsandbox.internal}")

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

  # THE TOOL-DECLARED DATA MOUNTS WENT WITH THE MANIFEST (ADR-031 D4). A tool
  # that needs a host directory now gets it from the project's own cage config
  # mounts: block -- the same place every other mount is declared, host-side and
  # outside every cage mount (ADR-031 D5(a)). rc generates none of them, and the
  # protected-paths rule in this same command is what keeps a config from
  # showing credentials into a cage.

  # THE NAMED VOLUMES MOVED INTO THE CAGE CONFIG (ADR-031 D2). ely4.1 reported
  # that a named volume had no config-file form, which is why rc generated
  # these three flags; spike rip-cage-ely4.16 Q4 measured the map form working
  # on msb 0.6.18 (`named:` + `target:` + `create: ensure-exists`), so the
  # shipped template declares them and rc generates nothing. `rc destroy` still
  # removes rc-state-<cage> and rc-history-<cage> by name — it owns their
  # lifecycle either way, because msb remove alone orphans them.
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
_up_prepare_environment() {
  local _path="$1" _port="$2" _env_file="$3" _rc_cpus="$4" _rc_memory="$5" _rc_pids_limit="$6"

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
        # The allowed-roots gate that used to wrap this is gone with the guard
        # itself (ADR-031 D2); the protected-paths check is what still refuses a
        # redirect aimed at a credential store.
        local _beads_pat
        if _beads_pat=$(_protected_paths_path_match "$resolved_beads"); then
          _emit_denylist_denial "$resolved_beads" "${_beads_pat}"
          exit 1
        fi
        log "Beads: resolved redirect → $resolved_beads"
        beads_dir="$resolved_beads"
        # Mount the real .beads/ over the worktree's redirect
        _UP_RUN_ARGS+=(-v "${resolved_beads}:/workspace/.beads:delegated")
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
    # Resolve symlinks first: a .beads/ symlink is followed by the bind-mount,
    # so the resolved target is what actually gets shown into the cage. The
    # allowed-roots check that used to follow retired with the guard
    # (ADR-031 D2); the protected-paths rule is what still refuses a target
    # aimed at a credential store.
    resolved_main_beads=$(realpath "$main_beads_dir" 2>/dev/null || true)
    if [[ -z "$resolved_main_beads" || ! -d "$resolved_main_beads" ]]; then
      log "Warning: worktree auto-redirect — main repo .beads/ not found at $main_beads_dir; bd will fail inside the container (see wrapper diagnostic)"
    elif _wt_beads_pat=$(_protected_paths_path_match "$resolved_main_beads"); then
      log "Warning: worktree auto-redirect — main repo .beads/ at $resolved_main_beads is a protected path ('${_wt_beads_pat}'); refusing to mount"
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
    # Server/owned/external mode: connect to host's Dolt server.
    # rip-cage-rj68 (S6): msb's host-gateway hostname — see the
    # CAGE_HOST_ADDR comment above for the same swap + its known limitation.
    _UP_RUN_ARGS+=(-e "BEADS_DOLT_SERVER_MODE=1")
    _UP_RUN_ARGS+=(-e "BEADS_DOLT_SERVER_HOST=host.microsandbox.internal")
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
}


# _up_start_container — create the msb sandbox with the prepared
# _UP_RUN_ARGS (rip-cage-rj68, S6 — REWRITTEN onto msb; was `docker run`).
#
# The mount/env-building body that produces _UP_RUN_ARGS
# (_up_prepare_docker_mounts, _up_prepare_environment, DCG, manifest
# mounts) is UNCHANGED by this bead — still docker -v/-e/--label/--workdir
# shape. This function is the one seam where that shape gets: (a)
# translated to msb flags (_up_translate_docker_args_to_msb), and (b)
# joined with the net-rule/secret/tls flags S2's generator produces from
# the NEW auth.credentials config surface (_up_build_egress_config_json ->
# _msb_flags_generate) — "create moves onto S2's generator flags" per the
# bead design.
#
# Fold b (source_env preflight) gates this BEFORE any msb invocation: a
# credential whose source_env is unset/empty in the host env aborts loud
# here, naming the var, rather than silently booting a cage carrying an
# empty secret.
#
# `--log-level trace` is always passed (criterion 5, D2's deny-visibility
# re-home): cages boot with trace logging on by default so the DNS-denial
# `domain=` log line is available for the repair loop's fix-hint (see
# _reload_denied_domains_from_trace_log in cli/reload.sh).
#
# Globals read: _UP_RUN_ARGS, OUTPUT_FORMAT, IMAGE
# Parameters: $1 name — container name; $2 path — validated workspace path
#             (for the egress-config JSON build)
# Returns non-zero on failure (human mode); JSON mode calls json_error,
# which exits internally and never returns.
# _up_resolve_conf PATH NAME
#
# Echo the native msb config file rc will launch with. Precedence, first hit
# wins: `rc up --conf <path>`, then $RC_CAGE_CONF, then
# $XDG_CONFIG_HOME/rip-cage/projects/<NAME>.yaml. Fails loud, naming exactly
# what to copy, when nothing resolves -- there is no implicit default cage.
#
# ADR-031 D2/D5(a): wherever it comes from, the file must sit OUTSIDE every
# mount it declares. That is _protected_paths_conf_outside_mounts, called from
# cmd_up before any msb call.
# _up_cage_conf_sha CONF -- content hash of the cage config, or "" if unreadable.
_up_cage_conf_sha() {
  local _conf="$1"
  [[ -r "$_conf" ]] || { printf ''; return 0; }
  shasum -a 256 "$_conf" 2>/dev/null | awk '{print $1}'
}


# _up_converge_needed NAME CONF
#
# True when a STOPPED cage's config file differs from the one it was created
# from. ADR-031 D3 keeps today's converge-on-up behaviour for a stopped cage;
# with the merge engine gone, "did it change?" is a content hash of ONE file
# rather than a field-by-field diff of a merged structure.
#
# THIS IS NOT AN OPTIMISATION, it is a correctness requirement. Converging
# unconditionally would mean (a) a stopped cage could never simply be resumed
# — every `rc up` would destroy and recreate it — and (b) the recursive
# cmd_up that performs the recreate would have no termination condition but
# "the remove succeeded", so a failed remove would loop forever.
#
# A cage with no stored hash predates this label: converge, which is the safe
# direction (it lands the cage on the current config) and self-heals, since
# the recreate stamps the hash.
_up_converge_needed() {
  local _name="$1" _conf="$2"

  # RE-ENTRY GUARD, and it is structural rather than advisory. A converge ends
  # in a recursive cmd_up; if that inner call could converge again, the only
  # thing stopping an infinite loop would be the outer remove having worked.
  # A failed remove, or a cage whose label never lands, would spin forever.
  # One converge per invocation, enforced here, makes that impossible no
  # matter what any label says.
  if [[ "${_UP_CONVERGE_DONE:-false}" == "true" ]]; then
    return 1
  fi

  local _stored _current
  _stored=$(_msb_label "$_name" "rc.cage-conf-sha" 2>/dev/null || true)
  # No stored hash: a cage created before this label existed. Converge once —
  # it lands the cage on the current config and self-heals, because the
  # recreate stamps the hash.
  [[ -z "$_stored" ]] && return 0
  _current=$(_up_cage_conf_sha "$_conf")
  [[ "$_stored" != "$_current" ]]
}


# _up_warn_transcript_loss NAME
#
# rip-cage-ely4.10: the surviving half of `rc reload`'s transcript-persistence
# guard (rip-cage-aa4t). Every recreate path — `--replace` and the stopped-cage
# converge — destroys the guest's ephemeral rootfs overlay. A cage created
# before rc host-bound ~/.claude/projects keeps its caged-claude conversation
# transcripts only there, so the recreate loses them silently: herdr restores
# the pane layout faithfully and the operator finds out when `claude --resume`
# reports no conversation.
#
# WARNS, never refuses. `rc reload` refused unless --allow-transcript-loss was
# passed; that flag retired with the verb. The loud line is what the operator
# actually needed; the refusal made an operation they had already named by hand
# require a second flag to complete, which is the interruption shape ADR-031 D3
# is removing. Current `rc up` always host-binds ~/.claude/projects, so this
# only ever fires for genuinely old cages.
#
# A check that cannot reach msb says so and stays quiet about the rest — a
# transient inspect hiccup must not produce a scary line about data loss.
# _up_check_multiplexer_available CONF
#
# rip-cage-ely4.7.2: refuse, before any msb call, when $RC_MULTIPLEXER names a
# multiplexer the image does not carry.
#
# THE REGRESSION THIS CLOSES. Until the config layer retired, an out-of-set
# multiplexer was refused at config-validate time and no cage was created.
# After, the cage was created, init ran, and the failure surfaced only at
# attach — rc built something it then could not use, and left the cage behind.
# That is the fail-loud contract (ADR-001) inverted: a cheap refusal moved
# behind an expensive side effect.
#
# WHAT IT READS. The image's own boot descriptor, /etc/rip-cage/boot.json, and
# specifically its multiplexers[] names (ADR-031 D4). This USED to read an
# `rc.multiplexers` image label that `rc build` stamped from the manifest; with
# the manifest gone, rc build hands docker a fixed argv and stamps no labels, so
# a label would have to be re-declared by hand in the operator's Dockerfile and
# would drift from the descriptor that actually decides what starts. Reading the
# descriptor keeps ONE source of truth.
#
# Reading a file out of an image means starting a throwaway container for it.
# THIS IS NOT DOCKER BACK IN THE RUNTIME PATH (ADR-029 D1): the cage itself is
# an msb microVM, created below and unaffected; this is an inspection of an
# image rc built, on a branch almost no launch takes. The image reference comes
# from the cage config's own `image:` key, because that is what msb will boot
# (ADR-031 D2: rc passes no image argument).
#
# NO msb, BY CONSTRUCTION — the refusal happens while the cage still does not
# exist. rc names no multiplexer itself, here or anywhere: it compares the name
# it was handed against the set the image declares (ADR-005 D12 FIRM).
#
# RC_MULTIPLEXER=none — the default, and what almost every cage runs — costs
# nothing: the function returns before reading anything. A probe on every
# launch for a feature almost nobody uses is its own kind of wrong.
_up_check_multiplexer_available() {
  local _conf="$1"
  local _mux="${RC_MULTIPLEXER:-none}"
  [[ -z "$_mux" || "$_mux" == "none" ]] && return 0

  local _img=""
  if [[ -n "$_conf" && -r "$_conf" ]]; then
    _img=$(yq -r '.image // ""' "$_conf" 2>/dev/null) || _img=""
    [[ "$_img" == "null" ]] && _img=""
  fi
  [[ -z "$_img" ]] && _img="$IMAGE"

  local _desc=""
  if ! _desc=$(docker run --rm --entrypoint sh "$_img" -c 'cat /etc/rip-cage/boot.json' 2>/dev/null); then
    # Cannot read the image, so cannot tell. Fail closed: an operator who asked
    # for a multiplexer by name gets told to build the image that would carry
    # it, rather than a cage that boots and then cannot attach.
    echo "Error: multiplexer '${_mux}' was requested via RC_MULTIPLEXER, but image '${_img}' could not be read to check what it carries." >&2
    echo "       Run: rc build   (then retry)" >&2
    return 1
  fi

  local _declared
  _declared=$(jq -r '[(.multiplexers // [])[].name] | join(", ")' <<<"$_desc" 2>/dev/null) || _declared=""

  if jq -e --arg n "$_mux" '(.multiplexers // []) | any(.name == $n)' <<<"$_desc" >/dev/null 2>&1; then
    return 0
  fi

  echo "Error: multiplexer '${_mux}' was requested via RC_MULTIPLEXER, but image '${_img}' does not declare it — its boot descriptor declares: ${_declared:-(none)}." >&2
  echo "       Add a multiplexers[] entry for '${_mux}' to the descriptor fragment your Dockerfile merges (see examples/${_mux}/), then run: rc build --file <your Dockerfile>" >&2
  echo "       Refusing before any msb call, so no cage is created (ADR-001 fail-loud)." >&2
  return 1
}


# _up_check_network_policy CONF
#
# rip-cage-ely4.7.7: refuse, before any msb call, a cage config that does not
# declare `network.policy: none`.
#
# WHY THIS GUARD EXISTS AT ALL. Default-deny egress at the VM boundary is FIRM
# (ADR-029 D2). rc used to enforce it by generating a `--net-default deny` flag
# on every create, which meant no config could get it wrong. That flag had to
# go: measured on msb 0.6.18 (rip-cage-ely4.7.6), a CLI --net-default REPLACES
# the allow list the --conf file carries, so the very flag meant to deny
# everything-but also denied the allowed hosts. The deny now lives in the
# config's own `network.policy: none` (ADR-031 D2 -- one native config carries
# the whole network posture).
#
# Moving a FIRM property out of generated argv and into an operator-edited file
# is only safe if rc still refuses the file that omits it. Otherwise a cage
# whose config lost its `network:` block -- or set `policy: allow` -- boots with
# OPEN egress and nothing says so. That is the one failure this cannot have, so
# the check is fail-CLOSED: anything that is not literally `none` is refused,
# including an unreadable or unparseable config (yq failing yields an empty
# value, which is not `none`).
#
# NO OPT-OUT, by construction -- no flag, no env var. A cage that needs another
# host adds it to the config's `network.allow` list; it never turns the policy
# off (the deny->fix->reload loop, ADR-029 D4).
_up_check_network_policy() {
  local _conf="$1"
  local _policy=""
  if [[ -n "$_conf" && -r "$_conf" ]]; then
    _policy=$(yq -r '.network.policy // ""' "$_conf" 2>/dev/null) || _policy=""
    [[ "$_policy" == "null" ]] && _policy=""
  fi
  [[ "$_policy" == "none" ]] && return 0

  local _seen="(absent)"
  [[ -n "$_policy" ]] && _seen="'${_policy}'"
  echo "Error: the cage config ${_conf} does not set network.policy to 'none' — it reads ${_seen}." >&2
  echo "       'policy: none' is microsandbox's default-DENY: nothing leaves the cage except the hosts listed under network.allow. Default-deny egress at the VM boundary is not optional (ADR-029 D2)." >&2
  echo "       Fix — add to ${_conf}:" >&2
  echo "           network:" >&2
  echo "             policy: none" >&2
  echo "             allow:" >&2
  echo "               - \"api.anthropic.com:tcp:443\"" >&2
  echo "       (see share/rip-cage/cage.yaml.template for the full floor list). There is no opt-out flag." >&2
  echo "       Refusing before any msb call, so no cage is created (ADR-001 fail-loud)." >&2
  return 1
}


_up_warn_transcript_loss() {
  local _name="$1"
  local _tl_rc=0
  _cage_claude_projects_host_bound "$_name" || _tl_rc=$?
  case "$_tl_rc" in
    0) return 0 ;;
    1)
      log "WARNING: ~/.claude/projects is NOT host-bound on ${_name} (a legacy cage) — this recreate discards the guest's ephemeral overlay, so any in-flight caged-claude conversation transcripts on it are LOST. The recreated cage gains host session persistence going forward."
      ;;
    *)
      log "WARNING: could not determine whether ~/.claude/projects is host-bound on ${_name} (msb inspect check failed) — proceeding with the recreate without the transcript-loss check."
      ;;
  esac
  return 0
}


_up_resolve_conf() {
  local _path="$1" _name="$2"

  local _conf=""
  if [[ -n "${_UP_CONF_FLAG:-}" ]]; then
    _conf="${_UP_CONF_FLAG}"
  elif [[ -n "${RC_CAGE_CONF:-}" ]]; then
    _conf="${RC_CAGE_CONF}"
  else
    _conf="${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage/projects/${_name}.yaml"
  fi

  if [[ ! -e "$_conf" ]]; then
    echo "Error: no cage config at ${_conf}. rip-cage launches from one native microsandbox config file per project (ADR-031 D2). Copy the shipped template and edit it:" >&2
    echo "    mkdir -p $(dirname "$_conf")" >&2
    echo "    cp ${SCRIPT_DIR}/share/rip-cage/cage.yaml.template ${_conf}" >&2
    echo "  Then fill in its <ANGLE-BRACKET> placeholders (this project is ${_path})." >&2
    return 1
  fi
  if [[ ! -r "$_conf" ]]; then
    echo "Error: the cage config at ${_conf} exists but is not readable. Refusing to launch." >&2
    return 1
  fi
  printf '%s\n' "$_conf"
}


# _up_prepare_conf_secret_env CONF
#
# For every credential the config's `secrets:` block declares, put the real
# value in the host env var msb reads at boot. MUST run in this shell, never
# via $(...) -- a subshell would discard the exports.
#
# WHY rc DOES THIS AT ALL. A `secrets:` entry deliberately carries no `value:`
# (that would put the secret in the config file); msb takes it from the host
# env var of the same name instead. Requiring the operator to export it by hand
# before every launch would put a human in the loop on an unattended run, which
# is the property ADR-029 D5's `source_file` field existed to protect. rc reads
# the value from a host-side file instead, by CONVENTION over its own config
# location rather than through any config schema:
#
#     $XDG_CONFIG_HOME/rip-cage/secrets/<NAME>
#
# Same ADR-031 D5(a) class as the protected-paths list: host-side, outside every
# cage mount, never a path the cage config can point at. When the file is absent
# the host env var must already be set, and msb fails loud naming it.
_up_prepare_conf_secret_env() {
  local _conf="$1"
  local _secret_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage/secrets"
  local _sname _sfile _svalue

  command -v yq &>/dev/null || return 0
  [[ -r "$_conf" ]] || return 0

  while IFS= read -r _sname; do
    [[ -z "$_sname" ]] && continue
    # Already exported by the operator: leave it alone.
    [[ -n "${!_sname:-}" ]] && continue
    _sfile="${_secret_dir}/${_sname}"
    [[ -f "$_sfile" ]] || continue
    if [[ ! -r "$_sfile" ]]; then
      echo "Warning: ${_sfile} holds the value for secret '${_sname}' but is not readable — msb will fail loud unless ${_sname} is exported." >&2
      continue
    fi
    _svalue="$(cat "$_sfile")"
    export "${_sname}=${_svalue}"
    log "secrets: ${_sname} sourced from ${_sfile} (the value never enters the guest)"
  done < <(yq -r '.secrets // {} | keys | .[]' "$_conf" 2>/dev/null)
}


# _up_build_msb_create_argv NAME PATH
#
# Populate the global array _UP_MSB_ARGV with the exact `msb create` argv.
# This is the launcher's contract: the real create runs THIS array and
# `rc up --dry-run` prints it, so what the dry-run shows is what runs.
#
# rc generates only what no config file can hold (ADR-031 D3): --name, the
# trace log level the deny->fix->reload loop mines, --replace, the mounts
# computed from the host filesystem, and the protected-paths covers. There is
# NO image positional -- the config's own `image:` key selects the image.
#
# Reads globals: _UP_CAGE_CONF, _UP_MSB_REPLACE, _UP_RUN_ARGS,
# _UP_PROTECTED_COVERS.
_up_build_msb_create_argv() {
  local _name="$1" _path="$2"

  _UP_MSB_ARGV=(msb create --conf "${_UP_CAGE_CONF}" --name "$_name" --log-level trace)
  [[ "${_UP_MSB_REPLACE:-false}" == "true" ]] && _UP_MSB_ARGV+=(--replace)

  local _egress_cfg _egress_out _translate_out _line
  _egress_cfg=$(_up_build_egress_config_json "$_path")
  _egress_out=$(_msb_flags_generate "$_egress_cfg") || return 1
  if [[ -n "$_egress_out" ]]; then
    while IFS= read -r _line; do _UP_MSB_ARGV+=("$_line"); done <<< "$_egress_out"
  fi

  _translate_out=$(_up_translate_docker_args_to_msb "${_UP_RUN_ARGS[@]+"${_UP_RUN_ARGS[@]}"}") || return 1
  if [[ -n "$_translate_out" ]]; then
    while IFS= read -r _line; do _UP_MSB_ARGV+=("$_line"); done <<< "$_translate_out"
  fi

  # Covers go last: each is a more-specific mount over a tree declared above.
  if [[ -n "${_UP_PROTECTED_COVERS[*]:-}" ]]; then
    _UP_MSB_ARGV+=("${_UP_PROTECTED_COVERS[@]}")
  fi
  return 0
}


_up_start_container() {
  local _name="$1" _path="$2"

  local _egress_cfg
  _egress_cfg=$(_up_build_egress_config_json "$_path")

  local _preflight_err
  if ! _preflight_err=$(_msb_flags_preflight_secret_env "$_egress_cfg" 2>&1); then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "$_preflight_err" "SECRET_SOURCE_ENV_UNSET"
    fi
    echo "$_preflight_err" >&2
    return 1
  fi

  # Export each credential's real value under its synthesized guest-
  # placeholder name. MUST run in this shell (never via $(...), which would
  # run in a subshell and discard the exports) per its own contract.
  _msb_flags_prepare_secret_env "$_egress_cfg"

  # The cage config's own `secrets:` block: put each real value in the host env
  # var msb reads at boot. Same in-shell requirement as the call above.
  _up_prepare_conf_secret_env "${_UP_CAGE_CONF}"

  local _egress_out _egress_rc=0
  _egress_out=$(_msb_flags_generate "$_egress_cfg") || _egress_rc=$?
  if [[ "$_egress_rc" -ne 0 ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Failed to generate msb egress flags for $_name" "MSB_FLAGS_GENERATE_FAILED"
    fi
    echo "Error: failed to generate msb egress flags for $_name" >&2
    return 1
  fi
  local _egress_flags=()
  if [[ -n "$_egress_out" ]]; then
    local _egress_line
    while IFS= read -r _egress_line; do
      _egress_flags+=("$_egress_line")
    done <<< "$_egress_out"
  fi

  local _translate_out _translate_rc=0
  _translate_out=$(_up_translate_docker_args_to_msb "${_UP_RUN_ARGS[@]}") || _translate_rc=$?
  if [[ "$_translate_rc" -ne 0 ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Failed to translate mount/env args to msb for $_name" "MSB_ARGS_TRANSLATE_FAILED"
    fi
    return 1
  fi
  local _translated_flags=()
  if [[ -n "$_translate_out" ]]; then
    local _translated_line
    while IFS= read -r _translated_line; do
      _translated_flags+=("$_translated_line")
    done <<< "$_translate_out"
  fi

  local _UP_MSB_ARGV=()
  if ! _up_build_msb_create_argv "$_name" "$_path"; then
    echo "Error: failed to assemble the msb create argv for $_name" >&2
    return 1
  fi

  local msb_stderr
  if ! msb_stderr=$("${_UP_MSB_ARGV[@]}" 2>&1 >/dev/null); then
    if echo "$msb_stderr" | grep -q "sandbox already exists"; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        json_error "Container name $_name is already in use" "NAME_CONFLICT"
      fi
      echo "Error: Container name $_name is already in use" >&2
      return 1
    fi
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Failed to create container $_name: ${msb_stderr}" "MSB_ERROR"
    fi
    echo "Error: failed to create container $_name" >&2
    echo "$msb_stderr" >&2
    return 1
  fi
  return 0
}


# _up_init_container — run the in-guest init script (rip-cage-rj68, S6 —
# REWRITTEN onto msb; was `docker exec`). This is the SAME script
# (cage/init/init-rip-cage.sh, baked at /usr/local/bin/init-rip-cage.sh)
# re-run on EVERY create AND every resume (see cmd_up's resume branch
# below) — this is the mechanism behind ADR-029 D4's "rc re-runs init on
# each resume" corollary (bead criterion 6: git identity re-established;
# git config --global user.name/user.email are set unconditionally inside
# init-rip-cage.sh on every run) and the cockpit/herdr re-registration
# corollary (bead criterion 3: the multiplexer 'start' hook dispatch also
# lives inside this same script, section 12).
#
# Globals read:    OUTPUT_FORMAT
# Globals written: _UP_INIT_OK (set to "true" or "false")
# Parameter: $1 name — container name
_up_init_container() {
  local _name="$1"
  _UP_INIT_OK=true
  log "Running init script..."
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    _msb_exec "$_name" -- /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || _UP_INIT_OK=false
  else
    _msb_exec "$_name" -- /usr/local/bin/init-rip-cage.sh || _UP_INIT_OK=false
  fi
}


# _up_resolve_resume_image_drift_stopped (rip-cage-jnvb / D-b, D-f) — abort
# loud BEFORE msb start when the stopped container's pinned image drifted
# from (or the current image is missing relative to) $IMAGE. Slotted with the
# other _up_resolve_resume_* guards, before the single msb start call site
# (rc cmd_up stopped-branch — D-g entrypoint sweep confirmed only one). No
# auto-destroy/auto-recreate: abort-loud matches the label-lock guard family
# (ADR-021 D4a/D5). Resume must NEVER itself trigger a pull/build
# (cli/up.sh:'Resuming stopped container' invariant) — this function only compares and aborts/returns,
# it never calls _pull_or_build.
# Parameters: $1 name, $2 path
# _up_resolve_resume_image_drift_stopped NAME PATH [CONVERGE_FOLLOWS]
#
# CONVERGE_FOLLOWS ("true") says a cold-recreate is about to run. That changes
# what "drift" means, not whether the other failures matter:
#   status 1 (stale image)  -- the recreate lands on the CURRENT image, which
#                              is the repair this guard used to tell the
#                              operator to run by hand. Return 0 and let it.
#   status 2 (image absent) -- a recreate cannot conjure an image. Still abort.
#   status 3 (inspect fail) -- still abort; nothing is verifiable.
# Without this split, making converge unconditional (ADR-031 D3) would have
# swallowed the absent-image diagnostic and failed later, at `msb create`,
# with a worse message.
_up_resolve_resume_image_drift_stopped() {
  local _name="$1" _path="$2" _converge_follows="${3:-false}"
  local _status=0
  # `|| _status=$?` (not a bare call + separate `$?` read) — under set -e,
  # a plain non-conditional statement that returns non-zero aborts the
  # script right there, before `_status=$?` ever runs.
  _msb_image_drift_status "$_name" || _status=$?
  [[ "$_status" -eq 0 ]] && return 0

  if [[ "$_status" -eq 3 ]]; then
    # Container-inspect itself failed. Unchanged from the pre-M2-hardening
    # behavior (this used to live inline in the comparator) — the stopped
    # path still has no safe default here and aborts, matching every sibling
    # _up_resolve_resume_* resolver's msb-inspect-failure idiom.
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "msb inspect failed for $_name" "MSB_ERROR"
    fi
    echo "Error: msb inspect failed for $_name (is msb reachable?)" >&2
    exit 1
  fi

  if [[ "$_status" -eq 2 ]]; then
    # rip-cage-syzk (point 3): reachable from the same stranded-cage incident
    # as the stale-image abort below, so it must name the volume cost of the
    # rc destroy remedy too (R11).
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Current image '${IMAGE}' not found — cannot verify container ${_name} is compatible with it. Run: rc build (then retry rc up ${_path}), or re-run with the RC_IMAGE this cage was created from, or rc destroy ${_name} && rc up ${_path} (deletes this cage's rc-state-${_name} and rc-history-${_name} volumes)." "RESUME_IMAGE_NOT_FOUND"
    fi
    echo "Error: current image '${IMAGE}' not found — cannot verify container ${_name} is compatible with it." >&2
    echo "       Resuming would risk running mismatched resume logic against this container's filesystem (ADR-001: no safe default when compatibility is unverifiable)." >&2
    echo "       Options:" >&2
    echo "         rc build                                    (build the image, then retry: rc up ${_path})" >&2
    echo "         RC_IMAGE=<original image> rc up ${_path}    (if this cage was created from a custom-pinned image)" >&2
    echo "         rc destroy ${_name} && rc up ${_path}        (recreate from scratch — deletes this cage's rc-state-${_name} and rc-history-${_name} volumes)" >&2
    exit 1
  fi

  if [[ "$_converge_follows" == "true" ]]; then
    log "Notice: ${_name} was created from a now-stale image; the cold-recreate below moves it onto the current one."
    return 0
  fi

  # _status == 1: mismatch. rip-cage-syzk (point 4) pointed this at the
  # volume-preserving repair rather than the old destroy-then-up dance;
  # rip-cage-ely4.10 repoints it again, onto `rc up --replace`, which is where
  # `rc reload` folded (ADR-031 D3). The custom-pinned-cage escape stays a
  # plain `rc up` invocation: with the original image there is no drift, so a
  # recreate would be work for nothing.
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    json_error "Container ${_name} was created from image ${_RC_IMAGE_DRIFT_STORED} but the current image ${IMAGE} is ${_RC_IMAGE_DRIFT_CURRENT} — rc up refuses to blind-resume a container pinned to a stale image. Run: rc up --replace ${_path} (moves the cage onto the current image; named volumes and host mounts survive, only the guest's ephemeral overlay does not); or if this cage was intentionally created from a custom image, re-run rc up with the same RC_IMAGE it was created with." "IMAGE_DRIFT_STALE_CONTAINER"
  fi
  echo "Error: container ${_name} was created from image ${_RC_IMAGE_DRIFT_STORED}, but the current image ${IMAGE} is ${_RC_IMAGE_DRIFT_CURRENT}." >&2
  echo "       rc up refuses to blind-resume a container pinned to a stale image — a rebuilt image's resume logic (e.g. mediator init) can crash against this container's older filesystem." >&2
  echo "       Run:" >&2
  echo "         rc up --replace ${_path}" >&2
  echo "       (moves the cage onto the current image; named volumes rc-state-${_name}/rc-history-${_name} and host mounts survive -- only the guest's ephemeral overlay does not)" >&2
  echo "       If this cage was intentionally created from a custom-pinned image, re-run rc up with the same RC_IMAGE it was created with instead:" >&2
  echo "         RC_IMAGE=<original image> rc up ${_path}" >&2
  exit 1
}


# _up_resolve_resume_image_drift_running (rip-cage-jnvb / D-c) — warn-only on
# a running container with a drifted image, then proceed. The running branch
# never calls the init script or msb start on resume (it only execs into
# the container's OWN filesystem) — no crash path exists here, so
# refusing attach would interrupt a live agent session for no safety benefit
# (ADR-002 D5 autonomy).
#
# Post-review M2 hardening: ALL non-zero comparator statuses — including 3
# (the container's own msb-inspect call failed, e.g. a transient error or
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
  _msb_image_drift_status "$_name" || _status=$?
  [[ "$_status" -eq 0 ]] && return 0

  if [[ "$_status" -eq 3 ]]; then
    echo "Warning: could not verify container ${_name}'s image (msb inspect failed) — skipping the image-drift check for this attach." >&2
    return 0
  fi

  if [[ "$_status" -eq 2 ]]; then
    echo "Warning: current image '${IMAGE}' not found — cannot verify container ${_name} is running the expected image (run: rc build)." >&2
    return 0
  fi

  # rip-cage-syzk (point 4): a running cage is never auto-recreated implicitly
  # (ADR-029 D4), so its own image drift has no in-place repair. rip-cage-ely4.10
  # repoints the remedy off the retired `rc down && rc reload` pair onto the one
  # verb that now names the recreate out loud.
  echo "Warning: container ${_name} is running an older image (created from ${_RC_IMAGE_DRIFT_STORED}, current is ${_RC_IMAGE_DRIFT_CURRENT}) — the last 'rc build' will not apply until: rc up --replace ${_path} (or re-run with the RC_IMAGE this cage was created with, if intentionally pinned)." >&2
  return 0
}


# _up_resolve_effective_credential_mounts_for_tool (rip-cage-xhgr / D1) — the
# single jq expression backing every effective(T) computation site: the
# create-time resolver (cmd_up), the resume-side credential-mounts guard, and
# the resume-side symlink-follow fingerprint recompute all call this so the
# resolution rule (per_tool.T if set, else the global credential_mounts, else
# "real") never drifts between call sites.
# Parameters: $1 tool ("claude"|"pi"), $2 effective-config JSON (the object
#             (retired parameter; kept for the caller's signature)
# Output: "real" or "none" on stdout.
_up_resolve_effective_credential_mounts_for_tool() {
  local _tool="$1" _cfg_json="$2"
  jq -r --arg t "$_tool" '.config.auth.per_tool[$t] // .config.auth.credential_mounts // "real"' <<<"$_cfg_json"
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
  _stored_fp=$(_msb_label "$_name" "rc.symlink-follow-fingerprint" || true)

  # Compute current fingerprint — include mode, on_dangling, and scope so that
  # policy changes (not just symlink-set changes) produce fingerprint drift.
  local _sfl_cur_mode="rw" _sfl_cur_on_dangling="follow" _sfl_cur_scope="file"
  # The policy inputs are constants now (ADR-031 D2), matching create time, so
  # the recompute below differs from the stored label only when the MOUNT SET
  # itself changed on the host filesystem — which is the drift this guard was
  # always really about.
  local _sfl_cur_cred_mounts="real"
  local _current_fp
  _current_fp=$(_symlink_follow_fingerprint "${HOME}/.pi/agent" "$_sfl_cur_mode" "$_sfl_cur_on_dangling" "$_sfl_cur_scope" "$_sfl_cur_cred_mounts")

  # Missing label: pre-c1p.2 container. Only block if current state has
  # dangling symlinks (non-trivial fingerprint would mean a new second mount
  # that was never wired into the container).
  if [[ -z "$_stored_fp" ]]; then
    local _empty_fp
    # B1a call-site 3: pi_root is empty so the loop body never runs and the
    # cred_mounts filter is INERT here — pass current for signature
    # consistency only (behavior is identical either way).
    _empty_fp=$(_symlink_follow_fingerprint "" "rw" "follow" "file" "$_sfl_cur_cred_mounts")  # empty set fp
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
# _up_translate_docker_args_to_msb ARGS...
#
# rip-cage-rj68 (S6): mechanical translator from the docker-run-argv shape
# _up_prepare_docker_mounts/_up_prepare_environment build (UNCHANGED by this
# bead — the worktree, symlink-follow, DCG, credential-mount, manifest-mount
# business logic all stays exactly as it was) into msb-run/msb-create argv.
# Most flags are byte-identical between the two runtimes (docker's
# `-v SRC:DST[:OPTIONS]` and msb's `-v SOURCE:DEST[:OPTIONS]` share the same
# grammar) — this function only transforms the small set of genuine
# differences. Echoes one output token per line (mirrors msb_flags.sh's own
# output convention — callers collect it into an array with
# `while IFS= read -r line; do FLAGS+=("$line"); done < <(_up_translate_docker_args_to_msb
# "${_UP_RUN_ARGS[@]}")`), bash-3.2-safe per ADR-008 D5.
#
# Handles (see module-level docs in tests/test-up-msb-args-translate.sh for
# the full behavior matrix): -v (strips :delegated, msb doesn't recognize
# the macOS Docker-Desktop cache-hint option; :ro passthrough), -e/--label/
# --workdir/-p (byte-identical flag names, straight passthrough), --mount
# type=bind,src=X,dst=Y[,ro] (docker long-form -> msb --mount-file X:Y[:ro]
# — the sole caller of this docker long-form is the DCG-config mount),
# --cpus=/--memory= (byte-identical flag names, passthrough), --memory-swap=
# and --pids-limit= (dropped — no msb `create`-time equivalent),
# --add-host=host.docker.internal:host-gateway (dropped — msb needs no
# static gateway entry), --env-file FILE (expanded into individual -e
# KEY=VALUE tokens, one per non-comment non-blank line, matching docker's
# own env-file line format).
#
# NOT handled here: --name/the trailing IMAGE+override-command positional
# tokens some callers append to a docker-run argv — this function expects
# ONLY the flag/value body (name and image are passed to msb create as
# their own separate arguments by the caller; msb create has no
# command-override positional at all, so there is nothing to translate
# there — see cli/lib/msb_runtime.sh's _msb_create_raw).
#
# ADR-001 fail-loud: an unrecognized flag aborts loud rather than being
# silently dropped or silently passed through unmodified (either of which
# could hide a real msb/docker behavior gap).
# _up_resolve_mount_source_path SPEC
#
# rip-cage-6v34.7: msb >= 0.6.16 REFUSES any bind mount whose HOST source
# path traverses a symlink. The guest dies at boot stage `mount` with
# `mount <tag>: Not a directory (os error 20)` — a message that names the
# GUEST mount point (the tag hashes the guest path), so it never points at
# the host path that is actually at fault. Measured on 0.6.18: the same
# guest target with host `~/.cache/rc-t/link/d1` (a symlink) fails and with
# `~/.cache/rc-t/real/d1` boots clean.
#
# On macOS this bites any workspace or $HOME under `mktemp -d`, because
# `/var` is a symlink to `/private/var`.
#
# Takes a `SRC:DST[:OPTIONS]` spec, echoes it back with SRC replaced by its
# physical path. Two cases are deliberately left alone:
#
#   NAMED VOLUMES — a SRC with no leading `/` is an msb volume name
#     (rc-state-*, rc-history-*, rc-mise-cache), not a host path.
#   SRC == DST — the symlink-follow projection (cli/up.sh's `_sfl_mount_src`)
#     and the skill-source parent mounts deliberately mount a host-absolute
#     path AT THAT SAME PATH inside the cage, because in-cage symlinks
#     resolve against it (CLAUDE.md, projection contract rip-cage-1pgp.1).
#     Rewriting only the source half would silently break that pairing, so
#     the spec is passed through unchanged and msb's own error stands.
#
# This runs in the TRANSLATOR, after every validation pass (mount denylist,
# the protected-paths check) has already read the ORIGINAL path —
# so it cannot widen what rc admits. It changes how an already-admitted
# inode is NAMED to msb, not which inode is mounted.
#
# `cd && pwd -P` is the bash-3.2-portable resolver (BSD realpath has no -m,
# and ADR-008 D5 is FIRM on bash 3.2).
_up_resolve_mount_source_path() {
  local _spec="$1"
  case "$_spec" in
    /*) ;;
    *) printf '%s' "$_spec"; return 0 ;;
  esac

  local _src="${_spec%%:*}"
  local _rest="${_spec#*:}"
  # No `:` at all (not a valid mount spec) — hand it back untouched.
  if [[ "$_rest" == "$_spec" ]]; then
    printf '%s' "$_spec"
    return 0
  fi

  # SRC == DST: host-absolute projection mount, see the note above.
  if [[ "$_rest" == "$_src" || "$_rest" == "${_src}:"* ]]; then
    printf '%s' "$_spec"
    return 0
  fi

  local _real=""
  if [[ -d "$_src" ]]; then
    _real=$(cd "$_src" 2>/dev/null && pwd -P) || _real=""
  elif [[ -e "$_src" ]]; then
    local _dir _base
    _dir=$(cd "$(dirname "$_src")" 2>/dev/null && pwd -P) || _dir=""
    _base=$(basename "$_src")
    [[ -n "$_dir" ]] && _real="${_dir}/${_base}"
  fi

  # Source absent or unresolvable: emit it verbatim so msb reports the real
  # condition rather than rc swallowing it (ADR-001 fail-loud).
  if [[ -z "$_real" ]]; then
    printf '%s' "$_spec"
    return 0
  fi

  printf '%s' "${_real}:${_rest}"
}

_up_translate_docker_args_to_msb() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v)
        local _spec="$2"
        # Strip a trailing ":delegated" (macOS Docker Desktop cache hint;
        # msb has no such option and does not recognize the token).
        _spec="${_spec%:delegated}"
        _spec=$(_up_resolve_mount_source_path "$_spec")
        # printf, not echo: several flags translated here (-v, -e, -p) are
        # literally "-e"/"-p" — bash's echo builtin interprets a bare "-e"
        # (or "-n"/"-E") as ITS OWN option when it is the sole/first
        # argument, silently swallowing the token instead of printing it.
        # printf '%s\n' never interprets its argument as a flag.
        printf '%s\n' "-v" "$_spec"
        shift 2
        ;;
      -e|--label|--workdir|-p)
        printf '%s\n' "$1" "$2"
        shift 2
        ;;
      --mount)
        local _mspec="$2" _msrc="" _mdst="" _mro=""
        local _mfield
        IFS=',' read -ra _mfields <<<"$_mspec"
        for _mfield in "${_mfields[@]}"; do
          case "$_mfield" in
            src=*) _msrc="${_mfield#src=}" ;;
            dst=*) _mdst="${_mfield#dst=}" ;;
            ro) _mro=":ro" ;;
          esac
        done
        # Same host-source resolution as -v (rip-cage-6v34.7).
        printf '%s\n' "--mount-file" "$(_up_resolve_mount_source_path "${_msrc}:${_mdst}${_mro}")"
        shift 2
        ;;
      --cpus=*|--memory=*)
        printf '%s\n' "$1"
        shift
        ;;
      --memory-swap=*|--pids-limit=*|--add-host=*)
        # No msb create-time equivalent (memory-swap: no host-swap-limit
        # concept in the VM model; pids-limit: no --rlimit support on `msb
        # create`, only `msb run`; add-host: msb needs no static
        # host-gateway /etc/hosts entry). Dropped, not translated.
        shift
        ;;
      --env-file)
        local _ef="$2"
        local _efline
        while IFS= read -r _efline || [[ -n "$_efline" ]]; do
          [[ -z "$_efline" ]] && continue
          [[ "$_efline" == \#* ]] && continue
          printf '%s\n' "-e" "$_efline"
        done < "$_ef"
        shift 2
        ;;
      *)
        echo "Error: _up_translate_docker_args_to_msb: unrecognized docker arg '$1' -- no known msb translation. Refusing to silently drop or pass it through unmodified." >&2
        return 1
        ;;
    esac
  done
}


# _up_build_egress_config_json PATH
#
# rip-cage-rj68 (S6 of the msb migration epic rip-cage-tsf2): translates the
# manifest-declared tool egress into the normalized JSON contract
# cli/lib/msb_flags.sh's _msb_flags_generate expects (S2, rip-cage-kl4r,
# APPROVED as-is per the 2026-07-12 Fable fold — this function feeds it,
# does not reshape it).
#
# allowed_hosts <- network.allowed_hosts (existing schema field, unchanged).
# credentials   <- auth.credentials (rip-cage-rj68 S6 Fold a — the NEW
#                  credential->host binding surface; deliberately isomorphic
#                  to the contract's own "credentials" field, so this is a
#                  straight passthrough, not a reshaping step).
#
# mounts/possession_mounts/tls_body_rewrite/dind_volumes are intentionally
# left at their contract defaults (empty/false) here: every current mount
# (workspace, credentials, symlink-follow, DCG config, manifest mounts,
# state volumes) is already built as a docker-shaped -v/-e/--label arg by
# _up_prepare_docker_mounts/_up_prepare_environment (unchanged by this
# bead) and separately translated to msb mount flags by
# _up_translate_docker_args_to_msb — routing the SAME mounts through this
# JSON contract's mount fields too would double-emit them. Only the
# net-rule/secret/tls concern is genuinely new (msb primitives with no
# pre-msb docker equivalent) and belongs in this JSON contract.
#
# WHAT THIS RETURNS NOW: always the empty contract. Both of its former
# contributions moved into the cage config (ADR-031 D2/D4) — see the body.
_up_build_egress_config_json() {
  local _uec_path="$1"
  # BOTH CONFIG CONTRIBUTIONS ARE THE CAGE CONFIG'S OWN NOW (ADR-031 D2).
  # Egress hosts are its `network.allow` list and credential bindings are its
  # `secrets:` block, so msb reads both straight off the --conf file and rc
  # generates neither. What IS still generated here is the MANIFEST union
  # below: a composed tool declares the hosts it needs, and those have no home
  # in the project's own config file. Measured on msb 0.6.18: CLI --net-rule
  # flags UNION with the --conf allow list rather than replacing it, so the
  # manifest union still lands.
  local _uec_allowed_hosts='[]' _uec_credentials='[]'

  # THE MANIFEST EGRESS UNION IS GONE (ADR-031 D4). Tool egress used to arrive
  # here as a second declaration source unioned into allowed_hosts; the cage
  # config's own network.allow list is the only source now, so what an operator
  # reads in the config is exactly what msb enforces. Its floor entries ship in
  # the config template rather than being merged in behind the operator's back.
  #
  # Egress is default-deny at the VM boundary either way (ADR-029 D2/D4, FIRM).
  # An empty contract here is therefore SAFE, not permissive: msb allows only
  # what the --conf file names. There is no denylist gate in rip-cage and never
  # was one — the default-deny floor is the guard.

  jq -nc --argjson hosts "$_uec_allowed_hosts" --argjson creds "$_uec_credentials" \
    '{allowed_hosts: $hosts, credentials: $creds}'
}


# _up_prepare_resume_secrets PATH
#
# rip-cage-rj68 (S6): msb resolves a `--secret ENV@HOST` binding's real
# value from the host environment variable ENV at SANDBOX START TIME, not
# just at creation — confirmed live (msb start on a stopped sandbox fails
# loud, "host environment variable ... is not set", when the synthesized
# name is absent from the CURRENT process's environment, even though the
# sandbox already booted successfully once before with it present). A
# resume happening in a fresh `rc up` process therefore needs the SAME
# Fold-b preflight (fail loud, name the var, before touching msb) and the
# SAME secret-env export _up_start_container runs at create time — this is
# that same two-step, factored out so create and resume share one source
# of truth rather than drifting.
#
# Returns non-zero (preflight failure already printed to stderr by
# _msb_flags_preflight_secret_env) when a credential's source_env is unset
# or empty; the caller must not proceed to `msb start`.
_up_prepare_resume_secrets() {
  local _urs_path="$1"
  local _urs_cfg
  _urs_cfg=$(_up_build_egress_config_json "$_urs_path")
  if ! _msb_flags_preflight_secret_env "$_urs_cfg"; then
    return 1
  fi
  _msb_flags_prepare_secret_env "$_urs_cfg"
  return 0
}


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

  # auth.placeholder_env_file retired with the schema (ADR-031 D2). A cage
  # that wants extra guest env vars declares them in its own config's `env:`
  # block, which msb reads directly. $RC_PLACEHOLDER_ENV_FILE keeps the
  # host-side pointer available for a caller that still needs one.
  local _pef_pointer="${RC_PLACEHOLDER_ENV_FILE:-null}"
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
  local _pef_denied_pattern
  if _pef_denied_pattern=$(_protected_paths_path_match "$_pef_pointer"); then
    _emit_denylist_denial "$_pef_pointer" "${_pef_denied_pattern}"
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
# used by the host preflight (_bd_host_preflight, cli/up.sh) for consistency:
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
  # rip-cage-y0u0: converge-on-up is DEFAULT-ON for a STOPPED cage with
  # a stopped cage — cold-recreates against the current cage config via
  # the existing cold-recreate pipeline (loud announcement); a no-op harmless
  # plain `up` when there is no eligible drift. --no-reload opts out (the old
  # resume-stale-with-a-hint behavior tsf2.9 shipped as the default). --reload
  # is kept as an explicit-intent synonym for the default on stopped cages
  # (it also gates the RUNNING-cage "not auto-recreating" notice below). A
  # RUNNING cage is NEVER auto-recreated regardless (warn-only). RC_UP_CONVERGE
  # is RETIRED (2026-07-21 flip decision, human sign-off) — no longer read
  # anywhere; the env var is now inert.
  local rc_up_reload="" rc_up_no_reload=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --conf) [[ $# -ge 2 ]] || { echo "Error: --conf requires a path" >&2; exit 1; }; _UP_CONF_FLAG="$2"; shift 2 ;;
      --replace) _UP_MSB_REPLACE="true"; shift ;;
      --port) [[ $# -ge 2 ]] || { echo "Error: --port requires a value" >&2; exit 1; }; port="$2"; shift 2 ;;
      --env-file) [[ $# -ge 2 ]] || { echo "Error: --env-file requires a value" >&2; exit 1; }; env_file="$2"; shift 2 ;;
      --cpus) [[ $# -ge 2 ]] || { echo "Error: --cpus requires a value" >&2; exit 1; }; rc_cpus="$2"; shift 2 ;;
      --memory) [[ $# -ge 2 ]] || { echo "Error: --memory requires a value" >&2; exit 1; }; rc_memory="$2"; shift 2 ;;
      --pids-limit) [[ $# -ge 2 ]] || { echo "Error: --pids-limit requires a value" >&2; exit 1; }; rc_pids_limit="$2"; shift 2 ;;
      --new) rc_up_new_session="true"; shift ;;
      --session) [[ $# -ge 2 ]] || { echo "Error: --session requires a value" >&2; exit 1; }; rc_up_session_name="$2"; shift 2 ;;
      --allow-risky-mount) [[ $# -ge 2 ]] || { echo "Error: --allow-risky-mount requires a value" >&2; exit 1; }; RC_ALLOW_RISKY_MOUNT+=("$2"); shift 2 ;;
      --allow-config-override) rc_allow_config_override="true"; shift ;;
      --reload) rc_up_reload="true"; shift ;;
      --no-reload) rc_up_no_reload="true"; shift ;;
      *) path="$1"; shift ;;
    esac
  done
  # --new and --session are mutually exclusive
  if [[ -n "$rc_up_new_session" ]] && [[ -n "$rc_up_session_name" ]]; then
    echo "Error: --new and --session are mutually exclusive. Use one or the other." >&2
    exit 2
  fi
  # rip-cage-y0u0 point 4: --reload and --no-reload are mutually exclusive
  # (one asks to converge explicitly, the other opts out of the default).
  if [[ -n "$rc_up_reload" ]] && [[ -n "$rc_up_no_reload" ]]; then
    echo "Error: --reload and --no-reload are mutually exclusive. Use one or the other." >&2
    exit 2
  fi
  if [[ -z "$path" ]]; then
    path="."
  fi

  validate_path "$path"
  path="$VALIDATED_PATH"

  # ---------------------------------------------------------------------
  # THE MOUNT-SIDE FLOOR. Everything in this block runs BEFORE any msb call
  # — before the image probes, before any label read, before create. That
  # ordering is the whole point: a config that would show a credential store
  # into a cage, or a protected-paths list rc cannot read, must stop rc
  # while the cage still does not exist (ADR-031 D2, D5(a)/D5(d)).
  # ---------------------------------------------------------------------
  local _conf_name
  _conf_name=$(container_name "$path")
  if [[ -z "$_conf_name" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Cannot derive container name from path: $path" "PATH_INVALID"
    echo "Error: path components produce an empty container name: $path" >&2
    exit 1
  fi

  if ! _UP_CAGE_CONF=$(_up_resolve_conf "$path" "$_conf_name"); then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "No readable cage config for $path" "CAGE_CONFIG_MISSING"
    exit 1
  fi

  # rip-cage-ely4.7.7: the egress floor. rc no longer generates a default-deny
  # flag (it wiped the config's own allow list), so the config has to carry
  # `network.policy: none` itself — and a config that does not is refused here,
  # in the same before-any-msb-call block, rather than booting open.
  if ! _up_check_network_policy "$_UP_CAGE_CONF"; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Cage config ${_UP_CAGE_CONF} does not declare network.policy: none (default-deny egress is not optional, ADR-029 D2)" "NETWORK_POLICY_NOT_DENY"
    exit 1
  fi

  # rip-cage-ely4.7.2: a multiplexer the image does not carry is refused HERE,
  # in the same before-any-msb-call block as the mount-side floor, so the cage
  # never exists. See _up_check_multiplexer_available for why the check reads
  # the image label rather than a created cage.
  if ! _up_check_multiplexer_available "$_UP_CAGE_CONF"; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Requested multiplexer '${RC_MULTIPLEXER:-none}' is not carried by the cage image — run rc build" "MULTIPLEXER_NOT_IN_IMAGE"
    exit 1
  fi

  if ! _protected_paths_conf_outside_mounts "$_UP_CAGE_CONF"; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Cage config ${_UP_CAGE_CONF} resolves inside a tree it mounts" "CAGE_CONFIG_INSIDE_MOUNT"
    exit 1
  fi

  # The covers this produces are appended to the create argv; a refusal here
  # exits non-zero with nothing spawned.
  local _covers_out
  if ! _covers_out=$(_protected_paths_enforce "$_UP_CAGE_CONF"); then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Protected-paths check refused the cage config ${_UP_CAGE_CONF}" "PROTECTED_PATH_REFUSED"
    exit 1
  fi
  _UP_PROTECTED_COVERS=()
  if [[ -n "$_covers_out" ]]; then
    local _cover_line
    while IFS= read -r _cover_line; do
      _UP_PROTECTED_COVERS+=("$_cover_line")
    done <<< "$_covers_out"
  fi

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
    local _denied_pattern
    if _denied_pattern=$(_protected_paths_path_match "$resolved_env"); then
      _emit_denylist_denial "$resolved_env" "${_denied_pattern}"
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

  # Check image exists and is current — pull from GHCR (with local-build
  # fallback) if missing or version label mismatches RC_VERSION (stale).
  # Provisioning fires only on the new-container (absent) path; see below.
  # See _image_is_current / _pull_or_build / ADR-008 D6. rip-cage-rj68 (S6):
  # ALSO requires the image be present in msb's LOCAL cache — the actual
  # runtime `msb create` boots from below — not just docker's, since
  # `rc up`'s own provisioning always ends with the docker-save/msb-load
  # conversion step (_build_msb_load, S1, called just after _pull_or_build
  # succeeds — rip-cage-0v47) that puts it there; a docker image present but
  # never `rc build`- or `rc up`-provisioned into msb (e.g. a stale
  # pre-cutover local image, or one built by a plain `docker build` outside
  # rc entirely) must still trigger provisioning.
  local _image_absent=false
  if ! docker image inspect "$IMAGE" > /dev/null 2>&1 || ! _image_is_current \
      || ! msb image list --format json 2>/dev/null | jq -e --arg img "$IMAGE" \
        'any(.[]; .reference == $img)' >/dev/null 2>&1; then
    _image_absent=true
  fi

  # rip-cage-7bs3: image-present branch ONLY. This catches the bead's actual
  # repro: someone runs `docker build` directly, never enters `rc build`,
  # and every fresh cage boots msb's stale cached image. Advisory only, see
  # _msb_warn_image_layer_drift's own header (cli/lib/msb_runtime.sh).
  #
  # rip-cage-0v47: the image-ABSENT branch is handled separately, further
  # below at the new-container provisioning block -- `_pull_or_build` there
  # is immediately followed by `_build_msb_load` and this same emitter,
  # called AFTER the load so the two branches never race and the emitter
  # never runs twice in one invocation. Do not also call it here on the
  # absent path.
  if [[ "$_image_absent" == false ]]; then
    # rip-cage-7yvy (RULING 2026-09-05, brain:rip-cage, option (a)): this
    # branch only reaches "present" because _image_absent's own probe above
    # already required msb to list $IMAGE BY NAME (cli/up.sh:2474-2478) --
    # exactly the presence-by-reference gap this bead exists to close: a
    # name match here can still hide DIFFERENT layer content. Call the
    # comparator ONCE, ourselves, to decide whether an auto-resync is owed
    # (status 1). The SECOND call inside _msb_warn_image_layer_drift just
    # below is deliberate, not duplicated work -- it re-checks AFTER the
    # resync attempt (same after-the-load ordering rip-cage-7bs3/0v47
    # already enforce at cli/build.sh:561 and cli/up.sh:2988 below), so ITS
    # status-1/status-3 branches report the POST-resync state: a load that
    # failed, or reported success but didn't verifiably land, falls through
    # to that existing loud status-3/528o warning on its own -- never a
    # second copy of this notice.
    local _drift_status=0
    _msb_image_layer_drift_status || _drift_status=$?
    if [[ "$_drift_status" -eq 1 ]]; then
      local _drift_docker_digest _drift_msb_digest_before
      # `|| true` on both: display-only lookups for the notice text below,
      # guarded against `set -e` (rc:6, applied whenever `rc` is EXECUTED
      # rather than sourced) -- a failed digest lookup must never abort
      # `rc up` itself, only fall back to "unknown" in the message.
      _drift_docker_digest=$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null) || true
      _drift_msb_digest_before=$(_msb_current_image_digest "$IMAGE" 2>/dev/null) || true
      # rip-cage-0v47's mechanism, reused verbatim: msb-load docker's image.
      # THE SUBSHELL TRAP (tests/test-up-msb-load-wiring.sh's header): this
      # call must run in THIS shell, unwrapped -- _build_msb_load's success
      # signal is the _RC_MSB_LOAD_SUCCEEDED global, and a `( ... )` or `|`
      # around this call would still run a real `msb load` but silently
      # lose that global to the subshell, making the status-3 fallback
      # below go permanently quiet even on a genuinely failed resync.
      _build_msb_load || true
      if [[ "${_RC_MSB_LOAD_SUCCEEDED:-0}" -eq 1 ]]; then
        # "ran ... to resync", not "resynced": _RC_MSB_LOAD_SUCCEEDED only
        # says the 'msb load' COMMAND reported success, not that the cache
        # verifiably landed -- that verification is exactly what the
        # _msb_warn_image_layer_drift call below (its status-3 branch)
        # exists to catch, so this notice must not overclaim a completed
        # fact the next line may immediately contradict.
        echo "Notice: msb's cached '${IMAGE}' image (was $(_msb_short_image_id "${_drift_msb_digest_before:-unknown}")) had different layer content than docker's local image ($(_msb_short_image_id "${_drift_docker_digest:-unknown}")) -- ran 'msb load' to resync msb's cache from docker. Run 'rc doctor' if this recurs." >&2
      fi
    fi
    _msb_warn_image_layer_drift
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
  existing_path=$(_msb_label "$name" "rc.source.path" || true)

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
  # _msb_sandbox_state exits non-zero when the sandbox does not exist; it
  # exits 0 when the sandbox exists (running or exited/stopped). Use 'if' to
  # capture exit code without triggering set -e on failure.
  local state _inspect_exit
  if state=$(_msb_sandbox_state "$name"); then
    _inspect_exit=0
  else
    _inspect_exit=$?
    state=""
  fi

  # `rc up --replace` IS THE EXPLICIT graceful-stop-then-recreate (ADR-031 D3),
  # and it is what `rc reload` folded into. A running cage is never recreated
  # implicitly — that kills a live agent session, and agent autonomy is the
  # product (ADR-029 D4's stopped-only rule, kept). Asking for it by name is
  # the whole difference, so it happens here, before the state branch: stop,
  # remove, and let the create path below run as if the cage were absent.
  #
  # It covers a STOPPED cage too, not only a running one (rip-cage-ely4.10).
  # A stopped cage converges on a plain `rc up` only when its CONFIG changed;
  # the other repairable drift — a stale pinned image after `rc build` — leaves
  # the config hash untouched, so the plain resume hits the image-drift
  # hard-stop instead. `rc reload` used to be that cage's repair; with the verb
  # gone, --replace has to be, or the hard-stop would name no remedy at all.
  # Under --dry-run this is announced and NOT performed.
  if [[ "${_UP_MSB_REPLACE:-false}" == "true" ]] \
      && { [[ "$state" == "running" ]] || [[ "$state" == "exited" ]] || [[ "$state" == "created" ]]; }; then
    local _replace_state_word="running"
    [[ "$state" != "running" ]] && _replace_state_word="stopped"
    if [[ "$DRY_RUN" == "true" ]]; then
      log "Would graceful-stop and recreate ${_replace_state_word} cage ${name} (--replace)"
    else
      # rip-cage-ely4.10: the transcript-persistence warning `rc reload` used to
      # own. A recreate destroys the guest's ephemeral rootfs overlay, and a
      # cage predating the host-bound ~/.claude/projects mount keeps its
      # caged-claude conversation transcripts only there. reload REFUSED unless
      # --allow-transcript-loss was passed; --replace WARNS instead. The
      # refusal's override flag was one more surface, and a flag an operator
      # must pass to complete an operation they already asked for by name is
      # exactly the human-in-the-loop shape this CLI is shedding.
      _up_warn_transcript_loss "$name"
      log "Recreating ${_replace_state_word} cage ${name} (--replace): graceful stop, remove, create against the current config."
      _msb_stop_graceful "$name"
      _msb_remove "$name"
    fi
    # _inspect_exit=1, not 0 (rip-cage-ely4.10 fix). The state branch below
    # reads "absent" as `_inspect_exit != 0`, not as an empty state string:
    # with 0 here, a cleared state fell past every arm into the
    # unrecognized-state fail-loud, so `rc up --replace` removed the cage and
    # then refused to recreate it. Verified against the branch as written.
    state=""
    _inspect_exit=1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    local would_action
    if [[ "$state" == "running" ]]; then
      # rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-RUNNING BEGIN (mirrors the real
      # running branch below — see RESUME-GUARDS-REAL-RUNNING). All guards
      # here are read-only (label read + recompute + compare) —
      # safe under --dry-run.
      _up_resolve_resume_image_drift_running "$name" "$path"
      _up_resolve_resume_symlink_fingerprint "$name" "$path"
      # rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-RUNNING END
      would_action="would_attach"
    elif [[ "$state" == "exited" ]] || [[ "$state" == "created" ]]; then
      # Surface legacy/invalid-label conditions in dry-run so planners see the
      # same hard stop the actual resume would hit (ADR-001).
      # rip-cage-jnvb / D-b: image-ID drift hard-stop surfaced here too —
      # dry-run planners must see the same refusal the real resume would hit.
      # rip-cage-tsf2.9 (code-review F1) / rip-cage-y0u0 (default-on flip):
      # preview a converge HONESTLY, and in the SAME ORDER the real stopped
      # branch runs it — converge FIRST, before the abort-loud guards. That
      # ordering keeps the dry-run and the real path mirrored: on the real
      # path a converge cold-recreates and RETURNS before the guards run, so
      # a dry-run that ran the image-drift guard first would predict an abort
      # for a cage the recreate would have fixed. Converge is the DEFAULT for
      # a stopped cage (ADR-031 D3); --no-reload opts out.
      # ADR-031 D3: a STOPPED cage is recreated against the current config
      # when that config has CHANGED since the cage was created, which is a
      # content hash of one file now rather than a merged-structure diff
      # (_up_converge_needed). --no-reload opts out.
      if [[ -z "$rc_up_no_reload" ]] && _up_converge_needed "$name" "$_UP_CAGE_CONF"; then
        # A recreate fixes a STALE image but cannot fix an ABSENT one, so the
        # guard still runs — it just stops treating staleness as fatal.
        _up_resolve_resume_image_drift_stopped "$name" "$path" "true"
        would_action="would_converge"
      else
        # No converge -> mirror the real path's plain-resume: run the abort-loud
        # guards (read-only here) so planners see the same hard stops.
        # rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-STOPPED BEGIN (mirrors the real
        # stopped branch below — see RESUME-GUARDS-REAL-STOPPED). All guards
        # here are read-only (label read + recompute + compare).
        _up_resolve_resume_image_drift_stopped "$name" "$path"
        _up_resolve_resume_symlink_fingerprint "$name" "$path"
        # rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-STOPPED END
        would_action="would_resume"
      fi
    elif [[ "$_inspect_exit" -ne 0 ]]; then
      # msb inspect failed → container is absent; create new.
      would_action="would_create"
    elif [[ "$state" == "paused" ]]; then
      # msb has no pause/restarting/removing/dead concept — unreachable
      # under msb (_msb_sandbox_state never returns these); kept defensive.
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is paused. Inspect manually: msb inspect $name -- then retry: rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is paused. Inspect manually: msb inspect $name -- then retry: rc up $path" >&2; return 1
    elif [[ "$state" == "restarting" ]]; then
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is restarting. Wait, or run: msb stop $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is restarting. Wait, or run: msb stop $name && rc up $path" >&2; return 1
    elif [[ "$state" == "removing" ]]; then
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is being removed. Wait, then run: rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is being removed. Wait, then run: rc up $path" >&2; return 1
    elif [[ "$state" == "dead" ]]; then
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is dead. Run: rc destroy $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is dead. Run: rc destroy $name && rc up $path" >&2; return 1
    else
      # Unrecognized state (allowlist exhausted) — fail loud per ADR-001.
      # Reachable under msb (_msb_sandbox_state's "unknown" fallback).
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is in unrecognized state: state=$state. Inspect manually with: msb inspect $name  — if safe, rc destroy $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
      echo "Error: Container $name is in unrecognized state: state=$state. Inspect manually with: msb inspect $name  — if safe, rc destroy $name && rc up $path" >&2; return 1
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
      # rip-cage-tsf2.9: name the cold-recreate tradeoff in the converge preview.
      [[ "$would_action" == "would_converge" ]] && \
        echo "  (cold-recreate: guest scratch overlay discarded; host mounts + Claude sessions survive)"
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
          local _dry_skill_pat
          if _dry_skill_pat=$(_protected_paths_path_match "$_dry_tdir"); then
            echo "Warning: skipping skill symlink mount ${_dry_tdir} — it is a protected path ('${_dry_skill_pat}', see the protected-paths list)" >&2
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
          local _dry_agent_pat
          if _dry_agent_pat=$(_protected_paths_path_match "$_dry_agent_tdir"); then
            echo "Warning: skipping agent symlink mount ${_dry_agent_tdir} — it is a protected path ('${_dry_agent_pat}', see the protected-paths list)" >&2
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

      # THE ARGV IS THE LAUNCHER'S CONTRACT. The "Would mount" lines above are
      # a readable summary; this is the exact command. It is assembled by the
      # same _up_build_msb_create_argv the real create runs, so a dry-run that
      # prints something the real launch would not do is not possible by
      # construction — not a second rendering that can drift from the first.
      #
      # _UP_DRY_RUN_NO_SIDE_EFFECTS keeps the mount preparation read-only:
      # --dry-run must never reach the macOS keychain.
      if [[ "$would_action" == "would_create" || "$would_action" == "would_converge" ]]; then
        local _UP_RUN_ARGS=()
        local _UP_DRY_RUN_NO_SIDE_EFFECTS=1
        local _UP_MSB_ARGV=()
        if _up_prepare_docker_mounts "$path" "$name" >/dev/null 2>&1 \
            && _up_prepare_environment "$path" "$port" "$env_file" "$rc_cpus" "$rc_memory" "$rc_pids_limit" >/dev/null 2>&1 \
            && _up_build_msb_create_argv "$name" "$path"; then
          echo "Would run: ${_UP_MSB_ARGV[*]}"
        else
          echo "Would run: msb create --conf ${_UP_CAGE_CONF} --name ${name} --log-level trace [mounts]"
        fi
      fi
    fi
    return 0
  fi

  if [[ "$state" == "running" ]]; then
    # rip-cage-3y9g: RESUME-GUARDS-REAL-RUNNING BEGIN (mirrored by the
    # dry-run running sub-branch above — see RESUME-GUARDS-DRY-RUN-RUNNING)
    # rip-cage-jnvb / D-c: image-ID drift is warn-only on the running branch —
    # no crash path exists here (no msb start, no init script re-run;
    # exec runs against the container's OWN filesystem) — refusing attach
    # would interrupt a live agent session for no safety benefit (ADR-002 D5).
    _up_resolve_resume_image_drift_running "$name" "$path"
    # ADR-021 D7: config-mode mount-shape guard applies to running containers too.
    # rip-cage-c1p.2 D4: fingerprint label-lock applies to running containers too.
    # A policy change (on_dangling, scope, mode) must block resume regardless of
    # whether the container is stopped or running — the mount shape is immutable.
    _up_resolve_resume_symlink_fingerprint "$name" "$path"
    # rip-cage-seqc.4 / B1: credential-mounts mount-shape guard applies to
    # running containers too — same rationale as the two guards above.
    # rip-cage-yid0: mediator CA env guard applies to running containers too
    # — CA trust env vars are frozen at container-create time, same rationale.
    # rip-cage-3y9g: RESUME-GUARDS-REAL-RUNNING END
    # rip-cage-y0u0: a RUNNING cage is NEVER auto-recreated, converge-on-up
    # default or not — recreating would kill a live agent session (agent
    # autonomy is the product). A plain `rc up` on a RUNNING cage with drift
    # stays hint-only (via _config_emit_hint below), same as before the flip —
    # the default only applies to STOPPED cages. This notice only fires when
    # the operator EXPLICITLY asked to reload (--reload) and got a running
    # cage instead (review F7); the explicit recreate for a running cage is
    # `rc up --replace`, which the operator invokes knowingly (ADR-031 D3 —
    # `rc reload` folded into exactly that flag).
    if [[ -n "$rc_up_reload" ]]; then
      if [[ -z "$rc_up_no_reload" ]]; then
        log "Notice: ${name} is RUNNING — NOT auto-recreating despite --reload"
        log "  (a running cage keeps its live session; only a STOPPED cage auto-converges)."
        log "  To apply the drift to this running cage now, cold-recreate explicitly: rc up --replace ${path}"
      fi
    fi
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      _up_json_output "$name" "attached" "$path" "running"
      return
    fi
    # rip-cage-1f59.2 / rip-cage-61al.3: dispatch on the multiplexer label via the boot descriptor.
    # No hardcoded mux names — any declared-in-manifest provider is dispatched through
    # _container_mux_hook_cmd (ADR-005 D12 FIRM).
    local _up_run_mux
    _up_run_mux=$(_container_multiplexer "$name")
    case "$_up_run_mux" in
      none)
        [[ -n "$rc_up_new_session" || -n "$rc_up_session_name" ]] && \
          echo "warning: --new/--session ignored under multiplexer=none" >&2
        if [[ -t 0 && -t 1 ]]; then
          _msb_exec_interactive "$name" -- zsh
        else
          echo "Container $name is running (multiplexer=none). Shell into it with: msb exec $name -- zsh" >&2
        fi
        ;;
      *)
        # Descriptor dispatch: resolve the hook command from the boot descriptor and run it.
        # Fails loud if the mux was not declared in the manifest used to build this image
        # (ADR-001 fail-loud; ADR-005 D12 — no hardcoded optional-mux names in rc).
        local _up_run_hook_cmd
        if [[ -n "$rc_up_new_session" ]]; then
          _up_run_hook_cmd=$(_container_mux_hook_cmd "$_up_run_mux" "new_session" "$name") || return 1
          if [[ -z "$_up_run_hook_cmd" ]]; then
            echo "warning: multiplexer '${_up_run_mux}' has no new_session hook — falling back to attach" >&2
            _up_run_hook_cmd=$(_container_mux_hook_cmd "$_up_run_mux" "attach" "$name") || return 1
          fi
        else
          _up_run_hook_cmd=$(_container_mux_hook_cmd "$_up_run_mux" "attach" "$name") || return 1
        fi
        if [[ -z "$_up_run_hook_cmd" ]]; then
          echo "Error: multiplexer '${_up_run_mux}' has no attach hook declared in the boot descriptor for cage '$name'." >&2
          return 1
        fi
        if [[ -t 0 && -t 1 ]]; then
          # Forward --session NAME to the hook as $1 (mux-agnostic; hook may ignore if not applicable).
          _msb_exec_interactive "$name" -- sh -c "$_up_run_hook_cmd" rc-mux-hook "${rc_up_session_name:-}"
        else
          echo "Container $name is running (multiplexer=${_up_run_mux}). Attach from a terminal with: rc up $path" >&2
        fi
        ;;
    esac
    return
  elif [[ "$state" == "exited" ]] || [[ "$state" == "created" ]]; then
    # rip-cage-y0u0: converge-on-up is DEFAULT-ON for a STOPPED cage with
    # eligible config drift (flipped from tsf2.9's opt-in --reload/RC_UP_CONVERGE
    # after a soak period — human sign-off 2026-07-21). Unless --no-reload opts
    # out, cold-recreate against the now-current cage config INSTEAD of
    # resuming with stale creation-time rules. --reload remains accepted as an
    # explicit-intent synonym for the default (it also gates the RUNNING-cage
    # "not auto-recreating" notice above). This only converges the
    # LEAST-destructive, reload-eligible drift class (network.*), and only
    # after a loud announcement — the abort-loud resume-drift guard family
    # (anchored on ADR-021 D4a/D5) is preserved for everything else:
    # non-eligible/mount-shape drift is left to the guards below (never
    # double-handled — review F4). RC_UP_CONVERGE is RETIRED — no longer read.
    # Runs the SAME cold-recreate mechanic cmd_reload uses (graceful stop -> remove
    # -> recreate), but recurses cmd_up in the CURRENT output format so an
    # interactive `rc up` still attaches after the cage comes back (cmd_reload
    # forces json because it must NOT attach; up must).
    if [[ -z "$rc_up_no_reload" ]] && _up_converge_needed "$name" "$_UP_CAGE_CONF"; then
        # Same split as the dry-run mirror above: stale is converge-able,
        # absent and unverifiable are not.
        _up_resolve_resume_image_drift_stopped "$name" "$path" "true"
        _up_warn_transcript_loss "$name"
        log "Converging ${name}: cold-recreating against the current cage config (ADR-031 D3). Host mounts and named volumes survive; only the guest's ephemeral rootfs scratch is lost."
        _msb_stop_graceful "$name" 2>/dev/null || true
        _msb_remove "$name"
        # Exported, not just set: the recreate re-enters cmd_up, and under
        # --output json it does so in a subshell.
        export _UP_CONVERGE_DONE=true
        # Cage now absent -> the recursive cmd_up takes the create path (which
        # rebaselines the config-applied snapshot) and, in a TTY, attaches.
        # rip-cage-tsf2.9 (review F2): forward THIS invocation's own runtime
        # flags into the recreate so `rc up --cpus 4 --memory 8g` (etc.) is
        # honored, not silently dropped. Unlike `rc reload` (which never
        # accepted these flags), the `up` surface does — dropping them would
        # silently downgrade an explicitly-sized converge. --reload/--no-reload
        # themselves are NOT forwarded (the recreate hits the create path, so
        # there is no drift to converge and no recursion). Note: this recovers
        # the CURRENT invocation's flags only; a cage's ORIGINAL create-time
        # resources are not stored anywhere rc can read back, so a bare `rc up`
        # still recreates at defaults — the same property `rc reload` has.
        local _conv_args=()
        [[ -n "$port" ]] && _conv_args+=(--port "$port")
        [[ -n "$env_file" ]] && _conv_args+=(--env-file "$env_file")
        _conv_args+=(--cpus "$rc_cpus" --memory "$rc_memory" --pids-limit "$rc_pids_limit")
        [[ -n "$rc_up_new_session" ]] && _conv_args+=(--new)
        [[ -n "$rc_up_session_name" ]] && _conv_args+=(--session "$rc_up_session_name")
        [[ -n "$rc_allow_config_override" ]] && _conv_args+=(--allow-config-override)
        local _conv_rm
        for _conv_rm in "${RC_ALLOW_RISKY_MOUNT[@]+"${RC_ALLOW_RISKY_MOUNT[@]}"}"; do
          _conv_args+=(--allow-risky-mount "$_conv_rm")
        done
        cmd_up "${_conv_args[@]}" "$path"
        return
    fi
    # else: the config is unchanged since this cage was created (or the
    # operator passed --no-reload) -> plain resume. This is the branch that
    # makes `rc up` on a stopped cage cheap: start it, do not rebuild it.
    log "Resuming stopped container $name..."
    # rip-cage-3y9g: RESUME-GUARDS-REAL-STOPPED BEGIN (mirrored by the
    # dry-run stopped sub-branch above — see RESUME-GUARDS-DRY-RUN-STOPPED)
    # rip-cage-jnvb / D-b, D-f: image-ID drift guard — FIRST, before any other
    # resume machinery and before msb start (the _up_resolve_resume_* guards below in cli/up.sh).
    # `rc build` creates a new image but an already-existing stopped container
    # stays pinned to the OLD image ID; blind-resuming ran the NEW image's
    # resume logic (e.g. init execs a script baked into the image via msb exec)
    # against the OLD container's filesystem -> raw OCI stat crash + self-stop.
    # Aborts loud on mismatch or a missing current image — never fail-open.
    _up_resolve_resume_image_drift_stopped "$name" "$path"
    # (the config-mode mount-shape guard retired with the file it guarded)
    # was toggled between ro and rw since the container was created.
    # rip-cage-c1p.2 D4: symlink-follow fingerprint label-lock — abort loud if
    # the dangling-symlink set (or mode) changed since create time.
    _up_resolve_resume_symlink_fingerprint "$name" "$path"
    # rip-cage-seqc.4 / B1: credential-mounts mount-shape guard — abort loud if
    # auth.credential_mounts was toggled between real and none since create.
    # rip-cage-3y9g: RESUME-GUARDS-REAL-STOPPED END
    # rip-cage-rj68 (S6): msb re-resolves every --secret binding's real
    # value from the host env at START time, not just at create time (live-
    # confirmed) — the same Fold-b preflight + export create uses must run
    # again here, in THIS process, before msb start.
    if ! _up_prepare_resume_secrets "$path"; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        _up_json_output "$name" "resumed" "$path" "stopped" "failed"
        return 1
      fi
      exit 1
    fi
    # _msb_start is a resume — a fresh kernel boot, per ADR-029 D4's
    # resume-path corollary. _up_init_container immediately after re-runs
    # the SAME init script the create path runs (cockpit/herdr
    # re-registration + git-identity re-establishment, bead criteria 3/6).
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      _msb_start "$name" >/dev/null
    else
      _msb_start "$name"
    fi
    _up_init_container "$name"
    if [[ "$_UP_INIT_OK" == "false" ]]; then
      # Graceful stop ONLY (ADR-029 D4 lifecycle corollary / bead criterion
      # 2): _msb_stop_graceful never force-kills, so a completed guest write
      # from this same failed-init session is not silently discarded.
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        _msb_stop_graceful "$name" >/dev/null 2>&1
        _up_json_output "$name" "resumed" "$path" "stopped" "failed"
        return 1
      fi
      echo "Error: init failed on resume. Stopping container so next 'rc up' retries." >&2
      _msb_stop_graceful "$name"
      exit 1
    fi
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      _up_json_output "$name" "resumed" "$path" "running" "success"
      return
    fi
    # rip-cage-1f59.2 / rip-cage-61al.3: dispatch via the boot descriptor (resumed cage label is immutable).
    local _up_resume_mux
    _up_resume_mux=$(_container_multiplexer "$name")
    case "$_up_resume_mux" in
      none)
        [[ -n "$rc_up_new_session" || -n "$rc_up_session_name" ]] && \
          echo "warning: --new/--session ignored under multiplexer=none" >&2
        if [[ -t 0 && -t 1 ]]; then
          _msb_exec_interactive "$name" -- zsh
        else
          echo "Container $name is running (multiplexer=none). Shell into it with: msb exec $name -- zsh" >&2
        fi
        ;;
      *)
        local _up_resume_hook_cmd
        if [[ -n "$rc_up_new_session" ]]; then
          _up_resume_hook_cmd=$(_container_mux_hook_cmd "$_up_resume_mux" "new_session" "$name") || return 1
          if [[ -z "$_up_resume_hook_cmd" ]]; then
            echo "warning: multiplexer '${_up_resume_mux}' has no new_session hook — falling back to attach" >&2
            _up_resume_hook_cmd=$(_container_mux_hook_cmd "$_up_resume_mux" "attach" "$name") || return 1
          fi
        else
          _up_resume_hook_cmd=$(_container_mux_hook_cmd "$_up_resume_mux" "attach" "$name") || return 1
        fi
        if [[ -z "$_up_resume_hook_cmd" ]]; then
          echo "Error: multiplexer '${_up_resume_mux}' has no attach hook declared in the boot descriptor for cage '$name'." >&2
          return 1
        fi
        if [[ -t 0 && -t 1 ]]; then
          # Forward --session NAME to the hook as $1 (mux-agnostic; hook may ignore if not applicable).
          _msb_exec_interactive "$name" -- sh -c "$_up_resume_hook_cmd" rc-mux-hook "${rc_up_session_name:-}"
        else
          echo "Container $name is running (multiplexer=${_up_resume_mux}). Attach from a terminal with: rc up $path" >&2
        fi
        ;;
    esac
    return
  elif [[ "$_inspect_exit" -ne 0 ]]; then
    : # container absent — fall through to "New container" block below
  elif [[ "$state" == "paused" ]]; then
    # rip-cage-rj68 (S6): msb has no pause/restarting/removing/dead concept
    # — _msb_sandbox_state never returns these; these branches are
    # unreachable under msb (kept for defensive completeness / a future msb
    # state this bead did not anticipate) and their remedy text is
    # necessarily generic rather than msb-specific.
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is paused. Inspect manually: msb inspect $name -- then retry: rc up $path" "CONTAINER_STATE_UNSUPPORTED"
    echo "Error: Container $name is paused. Inspect manually: msb inspect $name -- then retry: rc up $path" >&2
    return 1
  elif [[ "$state" == "restarting" ]]; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is restarting. Wait, or run: msb stop $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
    echo "Error: Container $name is restarting. Wait, or run: msb stop $name && rc up $path" >&2
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
    # Unrecognized state (allowlist exhausted) — fail loud per ADR-001. This
    # IS reachable under msb (_msb_sandbox_state's "unknown" fallback for
    # any status besides Running/Stopped).
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container $name is in unrecognized state: state=$state. Inspect manually with: msb inspect $name  — if safe, rc destroy $name && rc up $path" "CONTAINER_STATE_UNSUPPORTED"
    echo "Error: Container $name is in unrecognized state: state=$state. Inspect manually with: msb inspect $name  — if safe, rc destroy $name && rc up $path" >&2
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
    # rip-cage-0v47: _pull_or_build's success legs -- the local-build leg
    # (_pull_or_build_local) and the GHCR pull+tag leg (cli/build.sh
    # ~975-979) -- never themselves convert the image into msb's cache;
    # unlike `cmd_build`, `rc up` does not route through _build_msb_load at
    # all. Placed HERE at the caller (_pull_or_build's one and only caller)
    # rather than inside _pull_or_build_local so it dominates BOTH legs, not
    # just the local-build one -- a GHCR-pulled image is exactly as absent
    # from msb's cache as a built one. Best-effort, following cmd_build's own
    # idiom (cli/build.sh:560, :592): its exit code is deliberately not
    # propagated into rc up's own.
    _build_msb_load || true
    # rip-cage-0v47: AFTER _build_msb_load, never before -- same ordering
    # rip-cage-7bs3 already enforces at cli/build.sh:561 (pre-load, msb's
    # cache still holds whatever it held before, so a pre-load compare is
    # divergent by construction). This is the image-ABSENT counterpart to the
    # image-PRESENT emitter call below -- a deliberate posture change
    # (rip-cage-0v47 acceptance criterion 2): a load that reports success but
    # doesn't land is now surfaced on the `rc up` path too, not just
    # `rc build`. Stays advisory -- stderr only, exit status untouched. The
    # status-3 branch inside _msb_warn_image_layer_drift stays gated on
    # _RC_MSB_LOAD_SUCCEEDED, so a Docker-only host, or any of
    # _build_msb_load's never-attempted-load paths, still emits nothing here.
    _msb_warn_image_layer_drift
  fi

  log "Creating container $name for $path..."
  local _UP_RUN_ARGS=()
  # rip-cage-rj68 (S6): NO "-d --name $name" prefix here (docker-specific —
  # msb create takes --name as its own argument, passed directly by
  # _up_start_container below, and has no -d/detach flag to begin with,
  # `msb create` is inherently background). Everything appended below stays
  # in docker -v/-e/--label/--workdir/--mount/--cpus shape exactly as
  # before — _up_translate_docker_args_to_msb converts it at the
  # _up_start_container call site, not here, so this whole mount/env-
  # building body (_up_prepare_docker_mounts, _up_prepare_environment,
  # DCG, manifest mounts) is untouched by the msb cutover.
  _UP_RUN_ARGS+=(--label "rc.source.path=$path")

  # Per-container cache dir (DCG merged config lives here; ssh-cluster cache
  # content — translated ssh-config, filtered known_hosts, ssh-allowed-keys
  # sentinel — retired at the msb cutover, ADR-029 D3 / rip-cage-f1qo S5).
  local _rc_cache_dir="${HOME}/.cache/rip-cage/${name}"
  mkdir -p "$_rc_cache_dir"


  # auth.credential_mounts (rip-cage-seqc.4 / E2) + auth.per_tool.{claude,pi}
  # (rip-cage-xhgr / D1): resolve the effective values BEFORE the
  # symlink-follow fingerprint call below (B1a) — the fingerprint's leaf-filter
  # (F1) must be computed with the SAME effective(pi) value that determines
  # the mount set, or the create-time fingerprint label would not match the
  # honest post-filter mount set. _UP_CREDENTIAL_MOUNTS / _UP_CRED_MOUNTS_PI
  # are globals (not `local`) so _up_prepare_docker_mounts can read them below.
  # The global label stays unchanged (byte-identical to today); the two
  # per-tool labels are emitted unconditionally alongside it (D5a) so resume
  # can detect a per-tool mount-shape flip. The claude one is now a constant:
  # its switch went with the mount it gated (rip-cage-ely4.7.10), and readers
  # of the label — cli/doctor.sh, the cc-managed-settings probes — keep the
  # value they already expect.
  _UP_CREDENTIAL_MOUNTS="real"
  _UP_CRED_MOUNTS_PI="real"
  # auth.credential_mounts / auth.per_tool retired with the schema
  # (ADR-031 D2); "real" was that schema's own default, so an unconfigured
  # cage keeps today's posture. A cage that wants NON-POSSESSION declares a
  # `secrets:` binding in its own config instead — msb injects the real value
  # on the wire and the guest holds only the placeholder, which is a stronger
  # posture than suppressing the mount ever was (ADR-029 D3/D5).
  _UP_RUN_ARGS+=(--label "rc.auth.credential-mounts=${_UP_CREDENTIAL_MOUNTS}")
  _UP_RUN_ARGS+=(--label "rc.auth.credential-mounts.claude=real")
  _UP_RUN_ARGS+=(--label "rc.auth.credential-mounts.pi=${_UP_CRED_MOUNTS_PI}")

  # The rc.config-mode and rc.config-loaded labels are gone with the file they
  # described (ADR-031 D2). rc.cage-conf replaces them: which config file this
  # cage was launched from, so `rc doctor` and a resume can say where to look.
  _UP_RUN_ARGS+=(--label "rc.cage-conf=${_UP_CAGE_CONF}")
  # ...and its CONTENT hash. This is what makes "has the config changed since
  # this cage was created?" answerable without a merge engine: one file, one
  # sha. It is the termination condition for converge-on-resume (below) and
  # the reason a stopped cage with an unchanged config is RESUMED rather than
  # recreated.
  _UP_RUN_ARGS+=(--label "rc.cage-conf-sha=$(_up_cage_conf_sha "${_UP_CAGE_CONF}")")

  # rip-cage-c1p.2 D4: persist symlink-follow fingerprint as a container label
  # so resume can detect mount-shape drift and abort loud. Computed from sorted
  # "<link> → <target> (<mode>)" lines plus a policy header (on_dangling, scope)
  # so that policy changes also produce fingerprint drift.
  # Emitted unconditionally so the label is always present for resume checks.
  # Follows the rc.config-mode label-lock precedent above.
  # Policy inputs are the retired schema's own defaults now, matching
  # _up_prepare_docker_mounts. The fingerprint still earns its place: the
  # MOUNT SET it hashes is computed from the live host filesystem at every
  # launch, so it drifts even with the policy frozen.
  local _sfl_mode_for_fp="rw" _sfl_on_dangling_for_fp="follow" _sfl_scope_for_fp="file"
  # effective(pi), NEVER effective(claude) (rip-cage-xhgr / D5b) — this
  # fingerprint's scan root is ~/.pi/agent only.
  local _sfl_fingerprint
  _sfl_fingerprint=$(_symlink_follow_fingerprint "${HOME}/.pi/agent" "$_sfl_mode_for_fp" "$_sfl_on_dangling_for_fp" "$_sfl_scope_for_fp" "$_UP_CRED_MOUNTS_PI")
  _UP_RUN_ARGS+=(--label "rc.symlink-follow-fingerprint=${_sfl_fingerprint}")
  unset _sfl_mode_for_fp _sfl_on_dangling_for_fp _sfl_scope_for_fp _sfl_fingerprint

  # rip-cage-1f59.1: which multiplexer this cage runs, threaded in as
  # RC_MULTIPLEXER (read by init-rip-cage.sh) and stamped as the
  # rc.session.multiplexer label (for attach helpers + rc ls). The provider
  # contract is unchanged; rc names no multiplexer, it forwards the name it
  # is given (ADR-005 D12).
  # session.multiplexer retired with the schema (ADR-031 D2). "none" was its
  # default and stays the default: a plain shell, no multiplexer started.
  # $RC_MULTIPLEXER selects a provider for a caller that wants one; the
  # provider contract itself is unchanged (ADR-005 D12 — rc names no
  # multiplexer, it only forwards the name it is given).
  local _rc_multiplexer="${RC_MULTIPLEXER:-none}"
  _UP_RUN_ARGS+=(-e "RC_MULTIPLEXER=${_rc_multiplexer}")
  _UP_RUN_ARGS+=(--label "rc.session.multiplexer=${_rc_multiplexer}")
  log "session.multiplexer: ${_rc_multiplexer}"
  # rip-cage-1f59.2: _rc_multiplexer intentionally NOT unset here — used by the new-container
  # attach block below. It is unset after that block.

  _up_prepare_docker_mounts "$path" "$name"

  # rip-cage-b9to: resolve the auth.placeholder_env_file pointer (create-only,
  # immediately before _up_prepare_environment consumes env_file as $3). CLI
  # --env-file always wins — the resolver itself checks env_file's current
  # value and no-ops (with a log note) when it is already non-empty.
  _up_resolve_placeholder_env_file "$path" "$env_file"
  if [[ -n "$_UP_PLACEHOLDER_ENV_FILE" ]]; then
    env_file="$_UP_PLACEHOLDER_ENV_FILE"
  fi

  _up_prepare_environment "$path" "$port" "$env_file" "$rc_cpus" "$rc_memory" "$rc_pids_limit"

  # rip-cage-hhh.6 D3 (evolved, ADR-029 D2): rc.egress.config-override label so
  # rc doctor can surface the ADR-024 D1 workspace-base-URL-override posture
  # without a per-cage docker exec. (rc.egress.mode retired with the deleted
  # in-cage router — mode was the router's observe/block posture.)
  _UP_RUN_ARGS+=(--label "rc.egress.config-override=${rc_allow_config_override:-false}")

  # DCG POLICY RIDES THE RECIPE'S OWN MOUNT NOW (ADR-025 D1 transport note, as
  # ADR-031 D2 puts it: DCG policy is the recipe's business and was never rc's).
  # rc used to translate dcg.* from the retired schema into a merged TOML and
  # mount it here; with no dcg.* to read, a recipe that wants a policy file
  # declares the mount line in its own cage config — the same place every other
  # mount is declared, rather than a special case inside the launcher.

  # rip-cage-rj68 (S6): NO trailing "$IMAGE sleep infinity" positional here
  # (docker-specific CMD override — msb create has no command-override
  # positional at all; the image's own baked CMD keeps the sandbox alive,
  # confirmed live). _up_start_container takes $IMAGE and $path as its own
  # arguments below.

  if ! _up_start_container "$name" "$path"; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      _up_json_output "$name" "created" "$path" "stopped" "failed"
      return 1
    fi
    exit 1
  fi
  _up_init_container "$name"

  if [[ "$_UP_INIT_OK" == "false" ]]; then
    # Graceful stop ONLY (ADR-029 D4 lifecycle corollary / bead criterion 2).
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      _msb_stop_graceful "$name" >/dev/null 2>&1
      _up_json_output "$name" "created" "$path" "stopped" "failed"
      return 1
    fi
    echo "Error: init failed. Stopping container so next 'rc up' retries." >&2
    _msb_stop_graceful "$name"
    exit 1
  fi

  # The applied-config snapshot is gone with the thing it snapshotted
  # (ADR-031 D2). It existed so `rc reload` could diff a MERGED effective
  # config against create-time intent; with one unmerged file read fresh at
  # every launch, the file on disk IS the current intent and the rc.cage-conf
  # label says which file that is.
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    _up_json_output "$name" "created" "$path" "running" "success"
    return
  fi
  # rip-cage-1f59.2 / rip-cage-61al.3: dispatch via the boot descriptor (new container — value still in _rc_multiplexer).
  case "${_rc_multiplexer:-none}" in
    none)
      [[ -n "$rc_up_new_session" || -n "$rc_up_session_name" ]] && \
        echo "warning: --new/--session ignored under multiplexer=none" >&2
      if [[ -t 0 && -t 1 ]]; then
        _msb_exec_interactive "$name" -- zsh
      else
        echo "Container $name is running (multiplexer=none). Shell into it with: msb exec $name -- zsh" >&2
      fi
      ;;
    *)
      local _up_new_hook_cmd
      if [[ -n "$rc_up_new_session" ]]; then
        _up_new_hook_cmd=$(_container_mux_hook_cmd "${_rc_multiplexer:-none}" "new_session" "$name") || { unset _rc_multiplexer; return 1; }
        if [[ -z "$_up_new_hook_cmd" ]]; then
          echo "warning: multiplexer '${_rc_multiplexer:-none}' has no new_session hook — falling back to attach" >&2
          _up_new_hook_cmd=$(_container_mux_hook_cmd "${_rc_multiplexer:-none}" "attach" "$name") || { unset _rc_multiplexer; return 1; }
        fi
      else
        _up_new_hook_cmd=$(_container_mux_hook_cmd "${_rc_multiplexer:-none}" "attach" "$name") || { unset _rc_multiplexer; return 1; }
      fi
      if [[ -z "$_up_new_hook_cmd" ]]; then
        echo "Error: multiplexer '${_rc_multiplexer:-none}' has no attach hook declared in the boot descriptor for cage '$name'." >&2
        unset _rc_multiplexer
        return 1
      fi
      if [[ -t 0 && -t 1 ]]; then
        # Forward --session NAME to the hook as $1 (mux-agnostic; hook may ignore if not applicable).
        _msb_exec_interactive "$name" -- sh -c "$_up_new_hook_cmd" rc-mux-hook "${rc_up_session_name:-}"
      else
        echo "Container $name is running (multiplexer=${_rc_multiplexer:-none}). Attach from a terminal with: rc up" >&2
      fi
      ;;
  esac
  unset _rc_multiplexer
}


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

