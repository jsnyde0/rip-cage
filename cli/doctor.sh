#!/usr/bin/env bash
# cli/doctor.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# cmd_completions() removed — the fast-path at the top of the script is the
# canonical handler for `rc completions`. It intercepts every invocation before
# reaching this dispatch table (and before the container guard), so this
# function was unreachable dead code.

# _doctor_host — daemon/runtime-level diagnostic (no container required).
#
# rip-cage-rj68 (S6): reports BOTH docker (still needed for `rc build`/`rc
# ls`/`rc attach`/`rc exec`/`rc down`/`rc destroy`/`rc test`, out of this
# bead's scope) AND msb (the lifecycle-verb runtime as of this bead)
# reachability, with the same bounded-timeout discipline the preflights
# use. Intentionally bypasses check_docker/check_msb (the dispatcher skips
# both for `rc doctor --host`), because the whole point of this mode is to
# tell the user *why* everything else is failing — exiting silently from
# the preflight would defeat the purpose. Overall exit status is non-zero
# if EITHER runtime is unreachable (either one being down breaks some rc
# verb).
_doctor_host() {
  local _t="${RC_DOCKER_PREFLIGHT_TIMEOUT:-3}"
  local _docker_path _docker_installed=1
  if ! _docker_path=$(command -v docker 2>/dev/null); then
    _docker_installed=0
  fi
  local _rc=0 _daemon_status
  if [[ "$_docker_installed" -eq 0 ]]; then
    _rc=127
    _daemon_status="FAIL — docker CLI not installed"
  else
    _run_with_timeout "$_t" docker info >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -eq 0 ]]; then
      _daemon_status="OK — daemon reachable within ${_t}s"
    elif [[ "$_rc" -eq 124 ]]; then
      _daemon_status="FAIL — daemon unresponsive (no reply within ${_t}s; likely wedged)"
    else
      _daemon_status="FAIL — docker info exited $_rc"
    fi
  fi

  local _msb_t="${RC_MSB_PREFLIGHT_TIMEOUT:-5}"
  local _msb_path _msb_installed=1
  if ! _msb_path=$(command -v msb 2>/dev/null); then
    _msb_installed=0
  fi
  local _msb_rc=0 _msb_status
  if [[ "$_msb_installed" -eq 0 ]]; then
    _msb_rc=127
    _msb_status="FAIL — msb CLI not installed"
  else
    _run_with_timeout "$_msb_t" msb --version >/dev/null 2>&1 || _msb_rc=$?
    if [[ "$_msb_rc" -eq 0 ]]; then
      _msb_status="OK — reachable within ${_msb_t}s"
    elif [[ "$_msb_rc" -eq 124 ]]; then
      _msb_status="FAIL — unresponsive (no reply within ${_msb_t}s)"
    else
      _msb_status="FAIL — msb --version exited $_msb_rc"
    fi
  fi

  # rip-cage-j86: prerequisite checks — yq and global config (non-fatal; surface
  # fresh-device gaps at once instead of discovering them one rc up at a time).
  local _yq_path _yq_status
  if _yq_path=$(command -v yq 2>/dev/null); then
    _yq_status="OK — ${_yq_path}"
  else
    _yq_status="WARNING — yq not found on PATH (install: brew install yq / mikefarah releases binary — apt's yq is incompatible)"
  fi
  local _global_cfg_path _global_cfg_status
  _global_cfg_path=$(_config_global_path)
  if [[ -f "$_global_cfg_path" ]]; then
    _global_cfg_status="OK — ${_global_cfg_path}"
  else
    _global_cfg_status="WARNING — not found at ${_global_cfg_path} (first rc up will auto-seed)"
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc \
      --arg scope "host" \
      --arg daemon "$_daemon_status" \
      --argjson rc "$_rc" \
      --argjson timeout "$_t" \
      --arg docker_path "${_docker_path:-}" \
      --arg msb "$_msb_status" \
      --argjson msb_rc "$_msb_rc" \
      --arg msb_path "${_msb_path:-}" \
      --arg yq "$_yq_status" \
      --arg global_config "$_global_cfg_status" \
      '{scope: $scope, daemon: $daemon, docker_info_rc: $rc, timeout_seconds: $timeout, docker_path: $docker_path, msb: $msb, msb_rc: $msb_rc, msb_path: $msb_path, yq: $yq, global_config: $global_config}'
  else
    printf "Scope:        host (daemon/runtime liveness)\n"
    printf "Docker path:  %s\n" "${_docker_path:-<not installed>}"
    printf "Daemon:       %s\n" "$_daemon_status"
    printf "msb path:     %s\n" "${_msb_path:-<not installed>}"
    printf "msb:          %s\n" "$_msb_status"
    printf "yq:           %s\n" "$_yq_status"
    printf "Global config: %s\n" "$_global_cfg_status"
    if [[ "$_docker_installed" -eq 0 ]]; then
      printf "\nRemedy: install Docker Desktop or OrbStack — https://docs.docker.com/get-docker/\n"
    elif [[ "$_rc" -ne 0 ]]; then
      printf "\nRemedy: 'orb restart' (OrbStack) or restart Docker Desktop, then retry.\n"
    fi
    if [[ "$_msb_installed" -eq 0 ]]; then
      printf "\nRemedy: install msb — https://github.com/microsandbox/microsandbox\n"
    elif [[ "$_msb_rc" -ne 0 ]]; then
      printf "\nRemedy: msb is unresponsive — check the msb agent process, then retry.\n"
    fi
  fi
  if [[ "$_rc" -ne 0 || "$_msb_rc" -ne 0 ]]; then
    exit 1
  fi
}


# _doctor_bd_version_compare <host_version_raw> <cage_version_raw>
#
# rip-cage-2cks D3: host-vs-cage bd version-skew comparator for `rc doctor`.
# Extracts the numeric x.y.z from each raw `bd --version` string (ignoring a
# trailing build-provenance suffix like "(dev)" or "(Homebrew)" — comparing
# on provenance would WARN on every single cage, since the in-cage bd is
# always built from source and the host bd is whatever the operator's package
# manager shipped; that's noise, not skew) and echoes exactly one of:
#   ok <host_norm> <cage_norm>     -- numeric versions match
#   warn <host_norm> <cage_norm>   -- numeric versions differ
#   skip <reason>                  -- one or both strings didn't parse
#
# Deliberately never returns "fail": a bare version mismatch does not by
# itself prove the store won't parse (rip-cage-aq70's actual symptom) — that
# invariant belongs to the workspace-resolution check. This function is pure
# string logic so it's unit-testable without docker (test-doctor-version-skew.sh).
_doctor_bd_version_compare() {
  local host_raw="$1" cage_raw="$2"
  local host_norm cage_norm
  host_norm=$(echo "$host_raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  cage_norm=$(echo "$cage_raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [[ -z "$host_norm" || -z "$cage_norm" ]]; then
    echo "skip could-not-parse-version (host='${host_raw}' cage='${cage_raw}')"
    return
  fi
  if [[ "$host_norm" == "$cage_norm" ]]; then
    echo "ok $host_norm $cage_norm"
  else
    echo "warn $host_norm $cage_norm"
  fi
}


# cmd_doctor — per-container diagnostic view.
#
# Complements `rc ls` (fleet view) with depth for a single container: posture
# labels (rc.egress.config-override, rc.source.path) plus live probes when
# the container is running (msb posture/deny-visibility, beads port, auth
# creds, skills, cwd floor, workspace resolution, bd version skew —
# rip-cage-2cks). rip-cage-rj68 (S6): the engine-process probe (in-cage
# egress router) is retired per ADR-029 D2 — containment is now an
# msb-runtime property verified by the msb effect-probe test suite, not an
# rc doctor live process check; replaced by _doctor_format_posture_probe
# (declared net policy + recent denied domains). The ssh-add live probe and
# rc.forward-ssh/rc.github-identity label reads are REMOVED (S5 review
# carryover, ADR-029 D3 — the ssh cluster is retired).
# Labels are readable whether the container is running or stopped; live probes
# report "not running, no live probe" when the container is stopped.
# Resolves via resolve_name (CWD convention — same as rc attach/down/destroy).
#
# `rc doctor --host` is a separate mode (no container, daemon liveness only)
# and is dispatched here so the existing JSON/help wiring is shared.
# _doctor_dead_file_mounts <name>
#
# rip-cage-uben: generic dead-handle detection for single-FILE Docker bind
# mounts. A host atomic-rename (write tmp + rename over — the standard
# safe-rewrite idiom, e.g. a host Claude Code session rewriting
# ~/.claude/.credentials.json) severs the inode a single-file bind mount
# tracks: `docker inspect` keeps listing the mount, but the in-cage
# destination path goes ENOENT (dead handle). DIRECTORY mounts do NOT have
# this problem (the dentry re-resolves) — only DIRECTORY-sourced mounts are
# skipped up front (host `-d`, no docker-exec probe issued — no stat storm);
# everything else (regular file, socket, or a host path that no longer
# exists at all) gets exactly one docker-exec destination probe.
#
# DESTINATION-FIRST predicate (rip-cage-uben live-negative-control fix,
# 2026-07-06): the in-cage DESTINATION is probed BEFORE looking at the host
# source's type/existence, and a healthy destination is reported HEALTHY
# UNCONDITIONALLY — regardless of what the host source looks like. This
# matters because some legitimate mounts (the ssh-agent-forwarding socket,
# `/run/host-services/ssh-auth.sock` on macOS/OrbStack) have a host source
# path that is NEVER host-visible at all — OrbStack materializes it only
# inside the container's mount namespace — yet the mount works perfectly
# in-cage. Checking host-source-existence FIRST (the original shape) treated
# every one of those as "source missing" and WARNed on every single healthy
# macOS cage forever: exactly the cry-wolf desensitization the ops docs warn
# about. Only once the destination is confirmed DEAD do we look at the host
# source to give an honest, differentiated diagnosis instead of always
# claiming atomic-rename.
#
# Enumerates ALL bind mounts on the container (not hardcoded to
# .credentials.json — a second single-file mount, ~/.claude.json, exists
# under possession today and non-possession is adding another). Prints one
# line per finding:
#   "HEALTHY <dst>"            — in-cage destination resolves. Reported
#                                regardless of host source state (missing,
#                                socket, or regular file all count as
#                                healthy here) — a working mount is never a
#                                fault.
#   "SEEDED <dst> <seed>"      — destination dead (atomic-rename hazard), BUT
#                                a non-empty destination-sibling seed snapshot
#                                exists in-cage at <dirname(dst)>/.claude/
#                                <basename(dst)>.seed (rip-cage-i7s9: matches
#                                init-rip-cage.sh:576-580's R4 naming
#                                convention). Benign by design: init snapshots
#                                the mount once at container start (while the
#                                handle was intact) and all runtime consumers
#                                read the snapshot, never the live mount, so a
#                                post-init dead handle has zero functional
#                                impact. Generic classifier — not keyed on any
#                                specific mount path; keyed on the seed
#                                sibling's existence.
#   "DEAD <dst>"               — destination dead; host source IS a regular
#                                file; NO usable seed sibling found. The
#                                classic atomic-rename hazard, actionable
#                                (e.g. .credentials.json, where the live mount
#                                IS the refresh channel — no seed convention
#                                covers it).
#   "DEAD_OTHER <dst> <src>"   — destination dead; host source exists but is
#                                NOT a regular file (socket, FIFO, etc.).
#                                NOT the atomic-rename hazard (that requires
#                                a plain file source) — reported with plain
#                                wording instead of misdiagnosing a rename.
#   "MISSING <dst> <src>"      — destination dead; host source does not
#                                exist at ALL (deleted, not renamed). Also
#                                distinct from the atomic-rename hazard.
# Directory-sourced mounts print nothing (skipped before any probe).
#
# Pure enumeration only — never aborts on a dead handle (a probe, not a
# guard); exits 0 whenever the mount list itself was readable, matching
# cmd_doctor's existing convention that only container-not-found aborts.
# rip-cage-rj68 (S6): REWRITTEN onto msb. `msb inspect NAME --format json`'s
# `.config.mounts[]` array carries `type` ("Bind"/"Tmpfs"/...), `host`, and
# `guest` fields (msb-side counterparts to docker's `.Mounts[].Type`/
# `.Source`/`.Destination`) — only `type == "Bind"` entries have a `host`
# field at all (Tmpfs/other mount kinds don't), so this filters on
# `.host != null` as the msb-side "is this a host-path bind mount"
# predicate, matching the prior `select(.Type == "bind")` intent.
_doctor_dead_file_mounts() {
  local name="$1"
  local mounts_json
  mounts_json=$(_msb_inspect_json "$name" | jq -c '.config.mounts // []' 2>/dev/null) || return 0
  [[ -z "$mounts_json" || "$mounts_json" == "null" ]] && return 0

  local src dst
  while IFS=$'\t' read -r src dst; do
    [[ -z "$src" || -z "$dst" ]] && continue
    if [[ -d "$src" ]]; then
      # Directory-sourced bind mount — the dentry re-resolves; immune to
      # this bug class. Skip WITHOUT probing (no stat storm).
      continue
    fi
    if _msb_exec "$name" -- test -e "$dst" >/dev/null 2>&1; then
      # Destination resolves in-cage — healthy, full stop. Do NOT look at
      # the host source at all here: a host source that isn't host-visible
      # (ssh-agent socket magic paths) with a WORKING mount is not a fault.
      echo "HEALTHY ${dst}"
      continue
    fi
    # Destination is dead. Only now classify by host source state.
    if [[ -f "$src" ]]; then
      # rip-cage-i7s9: before crying DEAD, check for a non-empty destination-
      # sibling seed snapshot (the naming convention init-rip-cage.sh:576-580
      # R4 writes: <dirname(dst)>/.claude/<basename(dst)>.seed). If present,
      # the dead live handle is benign — init already snapshotted it once
      # while intact, and runtime consumers read the snapshot, not the live
      # mount. Generic classifier: not keyed on any specific mount path.
      local _seed_path
      _seed_path="$(dirname "$dst")/.claude/$(basename "$dst").seed"
      if _msb_exec "$name" -- test -s "$_seed_path" >/dev/null 2>&1; then
        echo "SEEDED ${dst} ${_seed_path}"
      else
        echo "DEAD ${dst}"
      fi
    elif [[ -e "$src" ]]; then
      echo "DEAD_OTHER ${dst} ${src}"
    else
      echo "MISSING ${dst} ${src}"
    fi
  done < <(printf '%s' "$mounts_json" | jq -r '.[]? | select(.host != null) | [.host, .guest] | @tsv' 2>/dev/null)
}


# _doctor_format_dead_mounts <name> <source_path>
#
# Renders _doctor_dead_file_mounts' raw findings into the doctor probe
# display string (OK/WARN/FAIL, matching the convention of the other live
# probes in cmd_doctor). Kept separate from the raw enumerator so it's
# independently unit-testable (test-doctor-dead-mount.sh stubs docker and
# calls each helper directly — no live cage / no full cmd_doctor stub surface
# needed).
_doctor_format_dead_mounts() {
  local name="$1" src_path="$2"
  local raw
  raw=$(_doctor_dead_file_mounts "$name")

  if [[ -z "$raw" ]]; then
    echo "OK — no single-file bind mounts to check"
    return
  fi

  local dead_list=() dead_other_list=() missing_list=() seeded_list=() healthy_count=0
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      SEEDED\ *) seeded_list+=("${line#SEEDED }") ;;
      DEAD_OTHER\ *) dead_other_list+=("${line#DEAD_OTHER }") ;;
      DEAD\ *) dead_list+=("${line#DEAD }") ;;
      MISSING\ *) missing_list+=("${line#MISSING }") ;;
      HEALTHY\ *) healthy_count=$((healthy_count + 1)) ;;
    esac
  done <<< "$raw"

  if [[ ${#dead_list[@]} -gt 0 ]]; then
    local joined
    joined=$(printf '%s, ' "${dead_list[@]}")
    joined="${joined%, }"
    echo "FAIL — dead handle(s): ${joined} (host file was replaced by atomic rename; the mount still points at the old inode; fix: rc down ${name} && rc up ${src_path:-<path>} to re-bind)"
  elif [[ ${#dead_other_list[@]} -gt 0 ]]; then
    local ojoined
    ojoined=$(printf '%s, ' "${dead_other_list[@]}")
    ojoined="${ojoined%, }"
    echo "WARN — mount destination unreachable, host source exists but is not a regular file (socket/FIFO/other): ${ojoined} (not the atomic-rename hazard)"
  elif [[ ${#missing_list[@]} -gt 0 ]]; then
    local mjoined
    mjoined=$(printf '%s, ' "${missing_list[@]}")
    mjoined="${mjoined%, }"
    echo "WARN — mount source no longer exists on host: ${mjoined} (deleted, not renamed — not the atomic-rename dead-handle hazard)"
  elif [[ ${#seeded_list[@]} -gt 0 ]]; then
    # rip-cage-i7s9: dead live handle, but init already snapshotted the mount
    # to a destination-sibling seed file and all runtime consumers read the
    # snapshot — benign by design. INFO, not FAIL; no re-bind advice (re-
    # binding would not change anything runtime-observable).
    local _sd
    local sdst_list=()
    for _sd in "${seeded_list[@]}"; do
      sdst_list+=("${_sd%% *}")
    done
    local sjoined
    sjoined=$(printf '%s, ' "${sdst_list[@]}")
    sjoined="${sjoined%, }"
    echo "INFO — seed-only mount(s), dead live handle is benign: ${sjoined} (snapshotted at init, runtime reads the snapshot; no action needed)"
  else
    echo "OK — ${healthy_count} single-file mount(s) healthy"
  fi
}


# _doctor_format_auth_probe <name>
#
# rip-cage-ebdd: posture-aware auth probe. A cage running the credential
# non-possession posture (auth.per_tool.claude: none — agent holds a
# placeholder token, a composed mediator injects the real secret on egress)
# has neither a mounted credentials file nor ANTHROPIC_API_KEY, and the
# original probe cried FAIL on it despite the cage being perfectly healthy.
# Recognizes the posture via, in order:
#   1. Existing credentials file / ANTHROPIC_API_KEY (today's healthy paths,
#      unchanged).
#   2. The rc.auth.credential-mounts.claude=none container label (stamped at
#      create time, rc:5129) — host-side `docker inspect`, cheap and not
#      forgeable by an in-cage agent. Checked before the env var per the
#      scoping review (label preferred, env second).
#   3. CLAUDE_CODE_OAUTH_TOKEN present in-cage — mirrors the check
#      tests/test-safety-stack.sh already uses (~line 187) via docker exec,
#      for cages that recognize the posture through the env var alone (e.g.
#      pre-label containers).
# A cage with NEITHER credentials NOR a recognized posture still FAILs
# exactly as before. Kept as its own pure/testable helper (same idiom as
# _doctor_format_dead_mounts) so it's unit-testable without a live cage.
_doctor_format_auth_probe() {
  local name="$1"
  if _msb_exec "$name" -- test -s /home/agent/.claude/.credentials.json >/dev/null 2>&1; then
    echo "OK — ~/.claude/.credentials.json present"
    return
  fi
  # shellcheck disable=SC2016 # deliberately single-quoted: expands inside the GUEST shell, not the host
  if _msb_exec "$name" -- sh -c 'test -n "${ANTHROPIC_API_KEY:-}"' >/dev/null 2>&1; then
    echo "OK — ANTHROPIC_API_KEY set (no OAuth creds)"
    return
  fi
  local _cred_mounts_claude_label
  _cred_mounts_claude_label=$(_msb_label "$name" "rc.auth.credential-mounts.claude" || true)
  if [[ "$_cred_mounts_claude_label" == "none" ]]; then
    echo "OK — non-possession posture (claude credentials deliberately not mounted; rc.auth.credential-mounts.claude=none)"
    return
  fi
  # shellcheck disable=SC2016 # deliberately single-quoted: expands inside the GUEST shell, not the host
  if _msb_exec "$name" -- sh -c 'test -n "${CLAUDE_CODE_OAUTH_TOKEN:-}"' >/dev/null 2>&1; then
    echo "OK — non-possession posture (CLAUDE_CODE_OAUTH_TOKEN present; mediator-injected auth)"
    return
  fi
  echo "FAIL — no credentials and no ANTHROPIC_API_KEY"
}


# _doctor_format_posture_probe NAME
#
# rip-cage-rj68 (S6): the doctor's NEW msb-side posture-inspection story
# (bead criterion 4 — the old in-cage engine-process probe is gone per S4;
# containment is an msb-runtime property now, verified by the msb effect-
# probe test suite, not by a live process check here). Reports the
# declared network policy (default action + rule count, read from `msb
# inspect`'s own config — a DECLARATION read, not a live enforcement
# claim; live enforcement is what tests/test-msb-*-effect-probes.sh prove)
# and any RECENT denied-egress domains mined from the trace log (bead
# criterion 5's readable fix-hint,
# _msb_denied_domains_from_trace_log) so an operator can see, at a glance,
# what a stuck agent turn was actually blocked on.
_doctor_format_posture_probe() {
  local name="$1"
  local cfg_json
  cfg_json=$(_msb_inspect_json "$name") || { echo "INFO — could not read posture (msb inspect failed)"; return; }
  local default_egress rule_count
  default_egress=$(jq -r '.config.network.policy.default_egress // "unknown"' <<<"$cfg_json" 2>/dev/null)
  rule_count=$(jq -r '.config.network.policy.rules // [] | length' <<<"$cfg_json" 2>/dev/null)
  local denied
  denied=$(_msb_denied_domains_from_trace_log "$name" 2>/dev/null)
  local denied_summary="none observed"
  if [[ -n "$denied" ]]; then
    denied_summary=$(echo "$denied" | tr '\n' ',' | sed 's/,$//')
  fi
  echo "OK — net-default=${default_egress}, ${rule_count} allow-rule(s); recently denied: ${denied_summary}"
}


cmd_doctor() {
  if [[ "${1:-}" == "--host" ]]; then
    _doctor_host
    return
  fi
  local name
  name=$(resolve_name "${1:-}") || exit 1
  if ! _msb_exists "$name"; then
    [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container not found: $name" "CONTAINER_NOT_FOUND"
    echo "Error: container $name not found" >&2; exit 1
  fi
  verify_rc_container "$name"

  # Read state + labels (work on stopped containers too). rip-cage-rj68
  # (S6): REWRITTEN onto msb. rc.forward-ssh / rc.github-identity label
  # reads and the ssh-add live probe are REMOVED here (S5 review
  # carryover, ADR-029 D3 — the ssh cluster is retired; these labels no
  # longer exist on any msb-created cage).
  local state source_path updated_at
  local egress_config_override_label
  state=$(_msb_sandbox_state "$name" 2>/dev/null || echo "unknown")
  source_path=$(_msb_label "$name" "rc.source.path" || true)
  # updated_at is the closest msb-side counterpart to docker's
  # State.StartedAt for uptime display (it changes on start/stop
  # transitions) — not a byte-identical semantic, an honest approximation.
  updated_at=$(_msb_inspect_json "$name" 2>/dev/null | jq -r '.updated_at // empty')
  # ADR-024 D1 workspace base-URL-override posture (unrelated to the deleted
  # in-cage egress engine — retained under its legacy label name).
  egress_config_override_label=$(_msb_label "$name" "rc.egress.config-override" || true)
  [[ -z "$egress_config_override_label" ]] && egress_config_override_label="false"

  local running=0
  [[ "$state" == "running" ]] && running=1

  # Live probes (only when running). Each probe returns a status string and detail.
  local beads_probe="not running, no live probe"
  local auth_probe="not running, no live probe"
  local skills_probe="not running, no live probe"
  # rip-cage-uben: generic dead-handle detection over single-file bind mounts.
  local dead_mounts_probe="not running, no live probe"
  # rip-cage-2cks: runnability probes (cwd floor, workspace resolution, bd version skew).
  local cwd_probe="not running, no live probe"
  local workspace_probe="not running, no live probe"
  local bd_version_probe="not running, no live probe"
  # rip-cage-rj68 (S6): the new msb posture-inspection probe (bead
  # criterion 4 — replaces the retired in-cage engine-process probe;
  # criterion 5 — surfaces the deny-visibility fix-hint).
  local posture_probe="not running, no live probe"

  if [[ "$running" -eq 1 ]]; then
    posture_probe=$(_doctor_format_posture_probe "$name")

    # Beads server probe: look for dolt-server.port + process.
    local port_file_exists=0 port_val="" dolt_running=0
    if _msb_exec "$name" -- test -f /workspace/.beads/dolt-server.port >/dev/null 2>&1; then
      port_file_exists=1
      port_val=$(_msb_exec "$name" -- cat /workspace/.beads/dolt-server.port 2>/dev/null | tr -d '[:space:]' || true)
    fi
    if _msb_exec "$name" -- pgrep -f 'dolt sql-server' >/dev/null 2>&1; then
      dolt_running=1
    fi
    if [[ "$port_file_exists" -eq 1 && "$dolt_running" -eq 1 && -n "$port_val" ]]; then
      beads_probe="OK — dolt sql-server on port ${port_val}"
    elif [[ "$port_file_exists" -eq 0 && "$dolt_running" -eq 0 ]]; then
      beads_probe="INFO — no beads/dolt server (workspace may not use beads)"
    else
      beads_probe="WARN — port_file=${port_file_exists} dolt_running=${dolt_running} port='${port_val}'"
    fi

    # Auth probe: credentials file presence + nonzero, or a recognized
    # non-possession posture (rip-cage-ebdd — see _doctor_format_auth_probe).
    auth_probe=$(_doctor_format_auth_probe "$name")

    # Dead-handle probe: generic sweep over ALL single-file bind mounts
    # (rip-cage-uben). Distinct from auth_probe above — auth_probe's `test -s`
    # would ALSO come back false on a severed .credentials.json handle,
    # attributing the symptom to "no credentials" rather than the actual
    # broken-mount cause; this probe names the real cause + repair directly.
    dead_mounts_probe=$(_doctor_format_dead_mounts "$name" "$source_path")

    # Skills mount probe: count entries under ~/.claude/skills (symlink to
    # /home/agent/.rc-context/skills). Report broken symlinks.
    local skills_count=0 skills_broken=0
    if _msb_exec "$name" -- test -d /home/agent/.claude/skills >/dev/null 2>&1; then
      skills_count=$(_msb_exec "$name" -- sh -c 'ls -1 /home/agent/.claude/skills 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]' || echo 0)
      skills_broken=$(_msb_exec "$name" -- sh -c 'find /home/agent/.claude/skills/ -maxdepth 2 -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]' || echo 0)
      if [[ "$skills_broken" -gt 0 ]]; then
        skills_probe="WARN — ${skills_count} entries, ${skills_broken} broken symlink(s)"
      else
        skills_probe="OK — ${skills_count} skill entries"
      fi
    else
      skills_probe="INFO — no skills mount"
    fi

    # rip-cage-2cks D1: cwd floor probe. Guards rip-cage-0rng: a fresh exec's
    # cwd must land in /workspace, not /home/agent (the WORKDIR default).
    # --workdir only takes effect at sandbox CREATE time — a resumed
    # sandbox from before the fix silently keeps the old workdir, so the
    # fail hint names recreation explicitly.
    local _cwd_actual
    _cwd_actual=$(_msb_exec "$name" -- pwd 2>/dev/null || true)
    if [[ "$_cwd_actual" == "/workspace" ]]; then
      cwd_probe="OK — fresh exec cwd is /workspace"
    else
      cwd_probe="FAIL — fresh exec cwd is '${_cwd_actual:-<unknown>}', not /workspace (likely fix: recreate the container — 'rc destroy' + 'rc up', not 'rc down'/'up' reuse; --workdir only applies at container create time)"
    fi

    # rip-cage-2cks D2: workspace-resolution probe. Guards rip-cage-aq70: bd
    # reading a store written by a different bd release can schema-error
    # (e.g. the depends_on_id class) even though the workspace mount itself
    # is fine. Use `bd status` specifically (not `bd ready`) — `bd ready`
    # does not exercise the blocked-IDs query that surfaces the schema
    # mismatch, so it stays clean even when the store genuinely can't be
    # read by this bd (empirically confirmed against a real skewed cage).
    # A workspace with no .beads/ or no git repo skips that leg with a note
    # rather than failing — not every cage workspace is a beads/git project.
    # NOTE: rc runs under `set -euo pipefail` when executed (rc:5-7), so every
    # probe below that captures a possibly-failing msb exec must use the
    # `var=$(cmd) || rc=$?` idiom or an `if cmd; then` conditional — a bare
    # `cmd && var=1` / `var=$(cmd); rc=$?` aborts cmd_doctor silently on the
    # first failing probe (caught live against the aq70 schema-error
    # fixture during implementation).
    local _has_beads=0 _has_git=0
    if _msb_exec "$name" -- test -d /workspace/.beads >/dev/null 2>&1; then
      _has_beads=1
    fi
    if _msb_exec "$name" -- sh -c 'git -C /workspace rev-parse --is-inside-work-tree' >/dev/null 2>&1; then
      _has_git=1
    fi

    local _bd_leg _bd_state="skip" _bd_out _bd_rc=0
    if [[ "$_has_beads" -eq 1 ]]; then
      _bd_out=$(msb exec -w /workspace "$name" -- bd status 2>&1) || _bd_rc=$?
      if [[ "$_bd_rc" -eq 0 ]]; then
        _bd_state="ok"
        _bd_leg="bd status OK"
      else
        _bd_state="fail"
        _bd_leg="bd status failed: $(echo "$_bd_out" | head -1)"
      fi
    else
      _bd_leg="no .beads/ in workspace (skipped)"
    fi

    local _git_leg _git_state="skip" _git_out _git_rc=0
    if [[ "$_has_git" -eq 1 ]]; then
      _git_out=$(msb exec -w /workspace "$name" -- git status 2>&1) || _git_rc=$?
      if [[ "$_git_rc" -eq 0 ]]; then
        _git_state="ok"
        _git_leg="git status OK"
      else
        _git_state="fail"
        _git_leg="git status failed: $(echo "$_git_out" | head -1)"
      fi
    else
      _git_leg="not a git repo (skipped)"
    fi

    if [[ "$_bd_state" == "fail" || "$_git_state" == "fail" ]]; then
      workspace_probe="FAIL — ${_bd_leg}; ${_git_leg} (likely fix: baked bd doesn't match the release that wrote this store — rebuild the image with a matching bd pin, ADR-005 D9/D11)"
    elif [[ "$_bd_state" == "ok" || "$_git_state" == "ok" ]]; then
      workspace_probe="OK — ${_bd_leg}; ${_git_leg}"
    else
      workspace_probe="INFO — ${_bd_leg}; ${_git_leg}"
    fi

    # rip-cage-2cks D3: bd version-skew probe. A bare mismatch WARNs only —
    # the workspace-resolution probe above owns "does the store parse".
    if ! command -v bd >/dev/null 2>&1; then
      bd_version_probe="INFO — host has no bd on PATH (skipped; can't compare)"
    else
      local _host_bd_raw _cage_bd_raw
      _host_bd_raw=$(bd --version 2>&1 || true)
      _cage_bd_raw=$(_msb_exec "$name" -- bd --version 2>&1 || true)
      if ! _msb_exec "$name" -- sh -c 'command -v bd' >/dev/null 2>&1; then
        bd_version_probe="INFO — no bd in-cage (skipped)"
      else
        local _cmp
        _cmp=$(_doctor_bd_version_compare "$_host_bd_raw" "$_cage_bd_raw")
        case "$_cmp" in
          ok\ *)
            bd_version_probe="OK — host and in-cage bd both ${_cmp#ok }" ;;
          warn\ *)
            local _wh _wc
            read -r _ _wh _wc <<< "$_cmp"
            bd_version_probe="WARN — host bd ${_wh} vs in-cage bd ${_wc} (version skew alone is not a failure — see workspace-resolution probe for whether the store actually parses)" ;;
          *)
            bd_version_probe="INFO — could not parse bd version strings (host='${_host_bd_raw}' cage='${_cage_bd_raw}')" ;;
        esac
      fi
    fi

  fi

  # Uptime (humanized) — derive from updated_at ISO timestamp (msb's closest
  # counterpart to docker's State.StartedAt — see the field-read comment
  # above).
  local uptime="—"
  if [[ "$running" -eq 1 && -n "$updated_at" ]]; then
    local started_epoch now_epoch diff
    started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${updated_at%%.*}" +%s 2>/dev/null \
      || date -d "$updated_at" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    if [[ "$started_epoch" -gt 0 ]]; then
      diff=$((now_epoch - started_epoch))
      if [[ "$diff" -lt 3600 ]]; then
        uptime="$((diff / 60))m"
      elif [[ "$diff" -lt 86400 ]]; then
        uptime="$((diff / 3600))h $(((diff % 3600) / 60))m"
      else
        uptime="$((diff / 86400))d $(((diff % 86400) / 3600))h"
      fi
    fi
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc \
      --arg name "$name" \
      --arg state "$state" \
      --arg uptime "$uptime" \
      --arg source_path "$source_path" \
      --arg posture_probe "$posture_probe" \
      --arg beads_probe "$beads_probe" \
      --arg auth_probe "$auth_probe" \
      --arg dead_mounts_probe "$dead_mounts_probe" \
      --arg skills_probe "$skills_probe" \
      --arg cwd_probe "$cwd_probe" \
      --arg workspace_probe "$workspace_probe" \
      --arg bd_version_probe "$bd_version_probe" \
      --arg egress_config_override "$egress_config_override_label" \
      '{
        name: $name,
        state: $state,
        uptime: $uptime,
        source_path: $source_path,
        labels: {
          "rc.egress.config-override": $egress_config_override
        },
        probes: {
          posture: $posture_probe,
          beads_server: $beads_probe,
          auth: $auth_probe,
          dead_mounts: $dead_mounts_probe,
          skills_mount: $skills_probe,
          cwd: $cwd_probe,
          workspace_resolution: $workspace_probe,
          bd_version_skew: $bd_version_probe
        }
      }'
  else
    echo "Container:  $name"
    echo "State:      $state${running:+}$([[ $running -eq 1 ]] && echo " (up $uptime)")"
    echo "Workspace:  ${source_path:-<unset>}"
    echo ""
    echo "Labels:"
    echo "  rc.egress.config-override = $egress_config_override_label"
    echo ""
    echo "Live probes:"
    echo "  posture        : $posture_probe"
    echo "  beads-server   : $beads_probe"
    echo "  auth           : $auth_probe"
    echo "  dead-mounts    : $dead_mounts_probe"
    echo "  skills-mount   : $skills_probe"
    echo ""
    echo "Runnability:"
    echo "  cwd                  : $cwd_probe"
    echo "  workspace-resolution : $workspace_probe"
    echo "  bd-version-skew      : $bd_version_probe"
  fi
}

