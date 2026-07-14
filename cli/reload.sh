#!/usr/bin/env bash
# cli/reload.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# cmd_reload — host-side hot-reload of .rip-cage.yaml allowlist changes
# (rip-cage-ocn / ADR-022 D6, carried forward past the ssh-cluster retirement
# per ADR-029 D3/D4). Today: network.allowed_hosts content only
# (network.mode retired as vestigial at the v2 schema bump, ADR-021 D9;
# the ssh.allowed_hosts-specific reload mechanism retired at the msb
# cutover, rip-cage-f1qo S5). Refuses loud on anything else. Exit codes:
#   0 — applied (or no-op when live matches snapshot)
#   1 — refuse-loud (non-reload-eligible field changed)
#   2 — container not running (`reload` promises the cage sees the change now)
#   3 — concurrent reload in progress (flock unavailable)
cmd_reload() {
  local name="" dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  # Honor global --dry-run too (stripped by the top-level argv pre-parser).
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dry_run=1
  fi
  name=$(resolve_name "$name") || exit 1

  # rip-cage-rj68 (S6): REWRITTEN onto msb.
  if ! _msb_exists "$name"; then
    echo "Error: container $name not found" >&2; exit 1
  fi
  verify_rc_container "$name"

  local state
  state=$(_msb_sandbox_state "$name" 2>/dev/null || true)
  if [[ "$state" != "running" ]]; then
    echo "Error: container $name is not running (state: $state). Use 'rc up' to start it." >&2
    exit 2
  fi

  # Workspace path comes from the container label (set by cmd_up create-time).
  local workspace
  workspace=$(_msb_label "$name" "rc.source.path" || true)
  if [[ -z "$workspace" || ! -d "$workspace" ]]; then
    echo "Error: cannot resolve workspace for $name (rc.source.path label missing or path gone)." >&2
    exit 1
  fi

  # Validate live config loudly (same gate cmd_up uses).
  _config_validate_or_abort "$workspace"

  local cache_dir="${HOME}/.cache/rip-cage/${name}"
  local lock_dir="${cache_dir}/.reload.lock.d"
  mkdir -p "$cache_dir"

  # mkdir is atomic on POSIX filesystems — portable lock primitive that
  # serializes concurrent `rc reload` invocations without depending on
  # `flock` (not present on macOS by default). Released via EXIT trap.
  # Exit 3 lets script callers branch on contention without parsing stderr.
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "Error: another rc reload is in progress (lock: $lock_dir). Try again in a moment." >&2
    exit 3
  fi
  # SC2064: $lock_dir is intentionally expanded at trap-set time (it's a function-local
  # that won't exist at trap-fire time).
  # shellcheck disable=SC2064
  trap "rmdir '$lock_dir' 2>/dev/null" EXIT

  # Load live effective config + applied snapshot.
  local live_result live_cfg
  live_result=$(_load_effective_config "$workspace") || {
    echo "Error: failed to load effective config from $workspace" >&2; exit 1; }
  live_cfg=$(jq -c '.config' <<<"$live_result")

  local applied_cfg
  if ! applied_cfg=$(_config_read_applied "$name" 2>/dev/null); then
    echo "Error: container $name predates rc reload support (no applied-config snapshot)." >&2
    echo "       Run: rc destroy $name && rc up   (to rebaseline)." >&2
    exit 1
  fi

  # ADR-021 D4 (rip-cage-tsf2.10.5, F1 fold): surface a manifest-vs-applied
  # egress delta as "requires rebuild" — INFORMATIONAL, distinct from
  # reload-eligible config drift, and NEVER part of reload eligibility or the
  # refuse-loud path. Runs BEFORE the empty-diff early-return and refuse-loud
  # gates below: it depends only on "$name" (the applied manifest-egress
  # record vs the current host manifest), not on diff_paths — a manifest-only
  # drift (config unchanged) is exactly the canonical case this hint exists
  # for, and both the empty-diff early-return (below) and the refuse-loud exit
  # (further below) would otherwise short-circuit before it ever ran.
  _reload_report_manifest_egress_delta "$name"

  # Compute differing JSON paths (e.g. "network.allowed_hosts", "egress.mode").
  # Pass schema defaults so absent-in-snapshot + live==default fields are non-drift
  # (handles old snapshots written before a new defaulted field was introduced —
  # same suppression as _config_emit_hint / rip-cage-1f59.9).
  local diff_paths _schema_defaults_reload
  _schema_defaults_reload=$(_config_schema_defaults_json 2>/dev/null || echo '{}')
  diff_paths=$(_config_diff_paths "$live_cfg" "$applied_cfg" "$_schema_defaults_reload" 2>/dev/null || true)
  unset _schema_defaults_reload

  if [[ -z "$diff_paths" ]]; then
    log "No changes since last apply — nothing to reload."
    return 0
  fi

  # Refuse loud on any non-reload-eligible path.
  if ! printf '%s\n' "$diff_paths" | _config_paths_all_reload_eligible; then
    echo "Error: 'rc reload' only handles reload-eligible field changes today (${_RC_RELOAD_ELIGIBLE_PATHS})." >&2
    echo "       Detected differing paths:" >&2
    while IFS= read -r p; do [[ -n "$p" ]] && echo "         - $p" >&2; done <<<"$diff_paths"
    echo "       Run: rc destroy $name && rc up   (to apply non-reload-eligible fields)." >&2
    exit 1
  fi

  # Print diff summary for all reload-eligible paths (network.* fields).
  # For list fields (allowed_hosts), show per-entry +/- diff. For scalar fields, show
  # the changed value.
  local _diff_p _live_v _applied_v _live_list _applied_list _l_added _l_removed _h
  while IFS= read -r _diff_p; do
    [[ -z "$_diff_p" ]] && continue
    _live_v=$(jq -r --arg p "$_diff_p" 'getpath($p | split("."))' <<<"$live_cfg" 2>/dev/null || true)
    _applied_v=$(jq -r --arg p "$_diff_p" 'getpath($p | split("."))' <<<"$applied_cfg" 2>/dev/null || true)
    # Check if the live value is an array (list field like allowed_hosts)
    if jq -e --arg p "$_diff_p" 'getpath($p | split(".")) | type == "array"' <<<"$live_cfg" >/dev/null 2>&1; then
      _live_list=$(jq -r --arg p "$_diff_p" 'getpath($p | split(".")) | .[]' <<<"$live_cfg" 2>/dev/null | sort -u)
      _applied_list=$(jq -r --arg p "$_diff_p" 'getpath($p | split(".")) // [] | .[]' <<<"$applied_cfg" 2>/dev/null | sort -u)
      _l_added=$(comm -23 <(printf '%s\n' "$_live_list") <(printf '%s\n' "$_applied_list") | grep -c . || true)
      _l_removed=$(comm -13 <(printf '%s\n' "$_live_list") <(printf '%s\n' "$_applied_list") | grep -c . || true)
      log "Diff: ${_diff_p} -- ${_l_added} added, ${_l_removed} removed."
      while IFS= read -r _h; do [[ -n "$_h" ]] && log "  + $_h"; done < <(comm -23 <(printf '%s\n' "$_live_list") <(printf '%s\n' "$_applied_list"))
      while IFS= read -r _h; do [[ -n "$_h" ]] && log "  - $_h"; done < <(comm -13 <(printf '%s\n' "$_live_list") <(printf '%s\n' "$_applied_list"))
    else
      log "Diff: ${_diff_p}: '${_applied_v}' -> '${_live_v}'"
    fi
  done <<<"$diff_paths"

  # rip-cage-rj68 (S6, ADR-029 D2's re-homed deny-visibility / bead
  # criterion 5): surface any recently-denied domains as the fix-hint the
  # repair loop consumes — this is the "domain= field rc tails" made
  # concrete at the point an operator is about to act on a diff. Shown for
  # both dry-run and real apply (informational either way).
  local _rl_denied
  _rl_denied=$(_msb_denied_domains_from_trace_log "$name" 2>/dev/null)
  if [[ -n "$_rl_denied" ]]; then
    log "Fix-hint: recently denied domain(s) on ${name} (not necessarily related to this diff):"
    while IFS= read -r _rl_d; do [[ -n "$_rl_d" ]] && log "    domain=${_rl_d}"; done <<<"$_rl_denied"
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log "(--dry-run: snapshot NOT updated, cage NOT recreated.)"
    return 0
  fi

  # rip-cage-4c5.3 Fix 4 (evolved, ADR-029 D2): IOC check still fires on rc
  # reload — a manifest edited between rc up and rc reload to add an IOC host
  # must fail loud here, naming the offending host.
  if ! _manifest_check_ioc_egress "${SCRIPT_DIR}/cage/egress/egress-rules.yaml"; then
    exit 1
  fi

  # rip-cage-rj68 (S6): net-rule changes are recreate-only under msb (no
  # live-mutation path exists for --net-rule/--net-default on a running
  # sandbox — confirmed live, docs/2026-07-09-msb-spike-egress-
  # observability.md Q1; `msb modify` has no network parameter at all).
  # ADR-029 D4 names two repair-loop mechanics: snapshot-amend (preserves
  # the guest's own writable-overlay state) or cold-recreate (mount-only
  # cages, cheaper, discards the overlay). DESIGN DECISION (this bead):
  # cold-recreate is rip-cage's default, not snapshot-amend — rip-cage
  # cages are mount-projected BY CONSTRUCTION (workspace, ~/.claude/
  # projects+sessions, pi auth.json all host-bind-mounted; rc-state-*/
  # rc-history-*/rc-mise-cache are NAMED VOLUMES, which persist and
  # reattach by name independent of the sandbox's own OCI overlay — msb-
  # confirmed live, tests/test-msb-lifecycle-reload-repair-loop.sh). The
  # only thing cold-recreate loses is state written into the guest's own
  # ephemeral rootfs overlay (e.g. an ad-hoc `apt-get install` at runtime
  # not baked into the image) — for rip-cage's actual mount topology that
  # is a narrow, documented tradeoff, not a real session-continuity loss,
  # and it is ~2.6x cheaper than snapshot-amend (0.303s vs 0.783s,
  # docs/2026-07-09-msb-spike-snapshot-amend.md). Implemented as "the SAME
  # create pipeline cmd_up's create branch uses, invoked again against the
  # NOW-current .rip-cage.yaml" (graceful stop -> remove -> cmd_up) rather
  # than a hand-rolled parallel mount-rebuild path, so create/resume/reload
  # never drift onto three separate mount-declaration implementations.
  log "Recreating ${name} to apply the amended net-rule set (cold-recreate; ADR-029 D4)..."
  _msb_stop_graceful "$name"
  _msb_remove "$name"
  # Force JSON mode for the inner create call regardless of the outer
  # invocation's format, so this recreate never accidentally drops into
  # cmd_up's interactive-attach dispatch mid-reload; the outer caller only
  # cares whether the recreate itself succeeded.
  local _rl_saved_output_format="$OUTPUT_FORMAT"
  OUTPUT_FORMAT="json"
  local _rl_create_out _rl_create_rc=0
  _rl_create_out=$(cmd_up "$workspace" 2>&1) || _rl_create_rc=$?
  OUTPUT_FORMAT="$_rl_saved_output_format"
  if [[ "$_rl_create_rc" -ne 0 ]]; then
    echo "Error: reload's cold-recreate of $name failed:" >&2
    echo "$_rl_create_out" >&2
    exit 1
  fi

  # Update snapshot to live (so subsequent emit_hint suppresses the warning).
  # ADR-021 D4 (rip-cage-tsf2.10.5): also rebaseline the applied manifest-egress
  # record — the cold-recreate above re-materialized the msb net-rules from the
  # NOW-current host manifest (the same union _up_build_egress_config_json reads),
  # so the applied per-tool egress map is the current host manifest map.
  local _rl_mem
  _rl_mem=$(_config_manifest_egress_map 2>/dev/null || echo '{}')
  _config_write_applied "$name" "$live_cfg" "$_rl_mem"

  log "Reloaded $name."
}


# _reload_report_manifest_egress_delta NAME
#
# ADR-021 D4 (rip-cage-tsf2.10.5): INFORMATIONAL only. Compares the cage's
# applied manifest-egress record (written at create/reload) against the current
# host manifest per-tool egress map. A difference means the manifest egress
# drifted since this cage was baked; the real remedy is edit-manifest + `rc
# build` + recreate (NOT `rc reload` / `rc allowlist add`), so it surfaces as
# "requires rebuild" — distinct from reload-eligible config drift and NEVER part
# of reload eligibility or the refuse-loud path. Silent when there is no applied
# record (old cage) or no delta.
_reload_report_manifest_egress_delta() {
  local name="$1"
  local applied cur
  applied=$(_config_read_manifest_egress_applied "$name" 2>/dev/null) || return 0
  cur=$(_config_manifest_egress_map 2>/dev/null || echo '{}')
  local a_c c_c
  a_c=$(jq -cS '.' <<<"$applied" 2>/dev/null || echo '{}')
  c_c=$(jq -cS '.' <<<"$cur" 2>/dev/null || echo '{}')
  if [[ "$a_c" != "$c_c" ]]; then
    log "Note: manifest egress changed since this cage was baked — requires rebuild"
    log "  (edit the manifest, then 'rc build' + recreate; this is NOT reload-eligible drift)."
    log "  applied: ${a_c}"
    log "  current: ${c_c}"
  fi
}


# Build a JSON object mapping each dotted schema key to its default JSON value.
# e.g. {"session.multiplexer":"none","mounts.symlinks.scope":"file", ...}
# Used by _config_diff_paths to suppress absent-in-snapshot + live==default drift.
_config_schema_defaults_json() {
  local pairs=()
  local key _type default _allowed
  while IFS='|' read -r key _type default _allowed; do
    [[ -z "$key" ]] && continue
    pairs+=("$(jq -nc --arg k "$key" --argjson v "$default" '{($k): $v}')")
  done < <(_config_schema_lines)
  # Merge all single-key objects into one.
  printf '%s\n' "${pairs[@]}" | jq -sc 'add // {}'
}

# Reload-eligible JSON path set (rip-cage-ocn / ADR-022 D6; ssh.allowed_hosts
# retired at the msb cutover, ADR-029 D3 — rip-cage-f1qo S5).
# Paths listed here can be mutated by `rc reload` without container recreation.
# Anything else triggers refuse-loud (exit 1) at reload time and a recreate
# hint from _config_emit_hint when label/snapshot drift is detected.
# network.allowed_hosts is the sole reload-eligible path post-schema-v2 (ADR-021
# D9): network.mode is a retired vestigial field (ADR-029, egress is msb default-
# deny — there is no observe/block mode). A change to network.allowed_hosts is
# applied by rc reload's cold-recreate against the now-current .rip-cage.yaml.
_RC_RELOAD_ELIGIBLE_PATHS='network.allowed_hosts'


# Diff two effective-config JSON objects ($1 = live, $2 = applied snapshot).
# Echoes one differing JSON path per line in dot-form (e.g. `network.allowed_hosts`,
# `egress.mode`). Arrays compared as whole values (no per-element recursion) —
# `.network.allowed_hosts` going from [a] → [a,b] is one path, not two.
# The `all(type == "string")` filter discards paths with array-index ints, so
# array contents stay opaque from the diff's perspective.
#
# Optional $3: schema-defaults JSON object ({"dotted.key": default_value, ...}).
# When provided, a path that is absent in the snapshot ($b) but whose live value
# equals the schema default is suppressed — it is NOT counted as drift (rip-cage-1f59.9).
# This handles old snapshots written before a new defaulted field was introduced.
# Invariant: only "absent-in-snapshot AND live==default" is suppressed; a field
# present in BOTH with different values is still drift; a field absent in LIVE but
# present in snapshot is a real removal and is still reported.
_config_diff_paths() {
  local live="$1" applied="$2"
  local schema_defaults="${3:-"{}"}"
  jq -nr --argjson a "$live" --argjson b "$applied" --argjson defaults "$schema_defaults" '
    def leafpaths: [paths(type != "object")] | map(select(all(type == "string"))) | unique;
    (($a | leafpaths) + ($b | leafpaths))
    | unique
    | map(. as $p |
        select( ($a | getpath($p)) != ($b | getpath($p)) )
        # Suppress: absent-in-snapshot AND live value equals schema default.
        # (handles old snapshots written before a new defaulted field was introduced)
        | select(
            (
              ($b | getpath($p)) == null
              and ($a | getpath($p)) == ($defaults[($p | join("."))])
            ) | not
          )
      )
    | .[]
    | join(".")
  '
}


# Predicate: returns 0 if every line on stdin is a reload-eligible path, 1 if
# any line is non-eligible. Empty input → 0 (nothing differs is trivially OK).
_config_paths_all_reload_eligible() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ " ${_RC_RELOAD_ELIGIBLE_PATHS} " != *" ${line} "* ]]; then
      return 1
    fi
  done
  return 0
}

