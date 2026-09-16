#!/usr/bin/env bash
# cli/reload.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# cmd_reload — host-side cold-recreate of a cage against its current config
# (rip-cage-ocn / ADR-022 D6, carried forward past the ssh-cluster retirement
# per ADR-029 D3/D4). Today: network.allowed_hosts content only
# (network.mode retired as vestigial at the v2 schema bump, ADR-021 D9;
# the ssh.allowed_hosts-specific reload mechanism retired at the msb
# cutover, rip-cage-f1qo S5). Refuses loud on anything else.
#
# rip-cage-syzk: a STOPPED cage whose pinned image has drifted from the
# current $IMAGE (`rc build` ran since this cage was created or last
# repaired) is ALSO reload-repairable now: the same cold-recreate this verb
# already does for network.allowed_hosts drift moves the cage onto the
# current image too, without touching its rc-state-/rc-history- named
# volumes (rc up's own stale-image refusal, cli/up.sh, points here). Image
# drift is a STOPPED-cage-only trigger -- a RUNNING cage's own image drift
# still has no in-place repair (ADR-029 D4: never auto-recreate a running
# cage); down it first, then reload. Repairing a stopped cage this way
# leaves it RUNNING afterward (the recreate's cmd_up takes the create path).
#
# Exit codes:
#   0 — applied (or no-op when live matches snapshot)
#   1 — refuse-loud (non-reload-eligible field changed, no applied-config
#       snapshot, or the pre-reload transcript-persistence guard refused)
#   2 — container not running AND not stopped-with-repairable-image-drift.
#       Covers "genuinely not running" (state exited with a matching or
#       unknown-unverifiable image, or state unknown/other) as well as
#       "stopped, but image staleness itself could not be checked" (current
#       image missing from msb's local cache, or msb inspect failed for the
#       sandbox) -- a caller keying on this code alone cannot distinguish
#       those sub-cases; read stderr for which one fired.
#   3 — concurrent reload in progress (flock unavailable)
cmd_reload() {
  local name="" dry_run=0 allow_transcript_loss=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --allow-transcript-loss) allow_transcript_loss=1; shift ;;
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

  # rip-cage-syzk: image_drift is read (unguarded) by the empty-diff
  # suppression far below on EVERY path but assigned only inside the
  # state == "exited" sub-branch just below -- rc runs set -euo pipefail
  # (rc:6; cli/reload.sh:3 records the shim-owns-strict-mode discipline), so
  # declaring it here keeps the running path (image_drift never touched)
  # bit-identical to pre-rip-cage-syzk behavior instead of an
  # unbound-variable abort.
  local image_drift=0
  local state
  state=$(_msb_sandbox_state "$name" 2>/dev/null || true)
  if [[ "$state" != "running" ]]; then
    if [[ "$state" == "exited" ]]; then
      # rip-cage-syzk: image drift is a STOPPED-cage-only recreate trigger
      # (scoping rule 1 -- the design's R8 is the regression guard that a
      # RUNNING cage's own drift never reaches this comparator call).
      local _rl_drift_status=0
      _msb_image_drift_status "$name" || _rl_drift_status=$?
      case "$_rl_drift_status" in
        1)
          # Mismatch: fall through into the normal reload body below --
          # the empty-diff early return is suppressed for this case (see
          # "Empty-diff" below) so a config-identical stopped cage still
          # recreates onto the current image.
          image_drift=1
          ;;
        2)
          # Current image missing from msb's local cache -- staleness itself
          # could not be checked. Its OWN message: must NOT reuse the base
          # gate's "Use 'rc up' to start it" remedy (rc up refuses in this
          # same condition too, cli/up.sh).
          echo "Error: container $name is not running (state: $state), and image staleness could not be checked: current image '${IMAGE}' was not found in msb's local cache. Run: rc build." >&2
          exit 2
          ;;
        3)
          # msb inspect failed for the sandbox itself -- staleness could not
          # be checked. Same rule: does not reuse the base remedy line.
          echo "Error: container $name is not running (state: $state), and image staleness could not be checked: msb inspect failed for $name (is msb reachable?)." >&2
          exit 2
          ;;
        *)
          # 0 (digests match) -- message byte-identical to today's.
          echo "Error: container $name is not running (state: $state). Use 'rc up' to start it." >&2
          exit 2
          ;;
      esac
    else
      # "unknown" (or any other non-running/non-exited status) -- verbatim,
      # unchanged; cmd_up itself treats unknown as fail-loud too.
      echo "Error: container $name is not running (state: $state). Use 'rc up' to start it." >&2
      exit 2
    fi
  fi

  # Workspace path comes from the container label (set by cmd_up create-time).
  local workspace
  workspace=$(_msb_label "$name" "rc.source.path" || true)
  if [[ -z "$workspace" || ! -d "$workspace" ]]; then
    echo "Error: cannot resolve workspace for $name (rc.source.path label missing or path gone)." >&2
    exit 1
  fi

  # The config gate lives in cmd_up now, where the cage config is resolved and
  # the protected-paths floor runs (ADR-031 D2). The recreate below calls
  # cmd_up, so this reload is gated by exactly the same checks a fresh launch
  # is — one implementation, not a second copy that can drift from it.

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

  # THERE IS NOTHING LEFT TO DIFF (ADR-031 D2). `rc reload` used to load a
  # MERGED effective config, compare it against a create-time snapshot, refuse
  # any change outside a reload-eligible set, and print a per-field diff. With
  # one unmerged config file read fresh at every launch, the file on disk IS
  # the current intent: "has it changed?" has no answer cheaper than recreating
  # against it, and the eligible/ineligible split has no schema to be defined
  # over. So a reload now simply cold-recreates, which is what every eligible
  # path did anyway.
  #
  # ADR-031 D3 folds this verb into `rc up --replace`; the verb itself is
  # rip-cage-ely4.10's to delete. What lands here is only the removal of its
  # dependence on the retired config layer.

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

  # rip-cage-jlu4 (denial-visibility disambiguation): a SEPARATE mined
  # list for msb's secret-violation guard (`--on-secret-violation
  # block-and-log` catching a substituted credential's placeholder sent
  # toward a disallowed host — a caught credential-misdirection / exfil
  # attempt). Presented as a DISTINCT WARNING, deliberately NEVER folded
  # into the "Fix-hint: ... add to allowlist" flow above — an operator
  # following an allowlist hint for one of these hosts would convert a
  # caught exfil attempt into an allowed one.
  local _rl_violations
  _rl_violations=$(_msb_secret_violations_from_trace_log "$name" 2>/dev/null)
  if [[ -n "$_rl_violations" ]]; then
    log "WARNING: blocked credential misdirection detected on ${name} (secret-violation guard fired — NOT an allowlist candidate; allowlisting would convert a caught exfil attempt into an allowed one):"
    while IFS= read -r _rl_v; do [[ -n "$_rl_v" ]] && log "    host=${_rl_v}"; done <<<"$_rl_violations"
  fi

  # rip-cage-aa4t: pre-reload transcript-persistence guard. `rc reload` is a
  # COLD-RECREATE (stop -> remove -> cmd_up below): a cage predating the
  # host-bind ~/.claude/projects mount (current `rc up` always adds it,
  # cli/up.sh:999 — this only fires for genuinely-old cages) keeps
  # caged-claude conversation transcripts ONLY on the guest's ephemeral
  # rootfs overlay, which the recreate destroys — silently, since herdr
  # faithfully restores the pane layout and the operator only discovers the
  # loss when a restored pane's `claude --resume` reports no conversation.
  # Evaluated BEFORE the dry-run early-return so --dry-run can report what
  # the guard WOULD do without ever refusing (real enforcement only happens
  # on a real, non-dry-run recreate attempt below).
  if [[ "$dry_run" -eq 1 ]]; then
    _reload_report_transcript_guard "$name"
    log "(--dry-run: snapshot NOT updated, cage NOT recreated.)"
    return 0
  fi
  if ! _reload_enforce_transcript_guard "$name" "$allow_transcript_loss"; then
    exit 1
  fi

  # NOTHING TO DO IS A REAL ANSWER, and on a RUNNING cage it is the important
  # one: a cold-recreate kills the live agent session, so doing it when the
  # config has not changed and the image has not drifted would cost a session
  # to achieve nothing (ADR-029 D4, ADR-031 D3 — a running cage is not
  # recreated without reason). The diff engine used to answer this; the
  # content hash answers it now, via the same predicate `rc up` uses.
  local _rl_conf
  _rl_conf=$(_msb_label "$name" "rc.cage-conf" 2>/dev/null || true)
  if [[ "$image_drift" -ne 1 ]]; then
    if [[ -z "$_rl_conf" ]]; then
      # No config label: a cage created before rc stamped one, so there is
      # nothing to compare against. On a RUNNING cage the safe answer is to do
      # nothing — killing a live agent session is a real cost and "I cannot
      # tell whether anything changed" is not a reason to pay it. A stopped
      # cage has no session to lose, so it recreates and picks up the label.
      if [[ "$state" == "running" ]]; then
        log "No changes detectable for ${name}: it carries no config record (created before rc stamped one), so nothing to reload. Leaving the running session alone — recreate explicitly with: rc up --replace <project>"
        return 0
      fi
    elif ! _up_converge_needed "$name" "$_rl_conf"; then
      log "No changes since ${name} was created — nothing to reload."
      return 0
    fi
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
  # NOW-current cage config" (graceful stop -> remove -> cmd_up) rather
  # than a hand-rolled parallel mount-rebuild path, so create/resume/reload
  # never drift onto three separate mount-declaration implementations.
  # rip-cage-syzk (adversarial-review finding F4): say WHY the recreate is
  # happening. Image drift is still distinguishable (it is a label read, not a
  # config diff); everything else is now simply "against the current config",
  # because that is all the reload knows and all it needs to know.
  if [[ "$image_drift" -eq 1 ]]; then
    log "Recreating ${name} to move it onto the current image (image drift; cold-recreate; ADR-029 D4)..."
  else
    log "Recreating ${name} against its current cage config (cold-recreate; ADR-029 D4)..."
  fi
  # Announced HERE, not earlier: the transcript guard above can still refuse,
  # and the no-op check can still decide there is nothing to do. Saying
  # "cold-recreating" before either had its say meant rc announced work it then
  # declined to perform.
  log "Reloading ${name}: cold-recreating against its current cage config."
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

  # No snapshot to rebaseline: the cage config file on disk is the record of
  # what this cage was created from, and the rc.cage-conf label says which file
  # that was (ADR-031 D2).

  log "Reloaded $name."
}


# _reload_enforce_transcript_guard NAME ALLOW_TRANSCRIPT_LOSS
#
# rip-cage-aa4t: real (non-dry-run) enforcement half of the pre-reload
# transcript-persistence guard. Calls _cage_claude_projects_host_bound
# (cli/lib/msb_runtime.sh) and:
#   host-bound (0)        -- silent, proceed.
#   not host-bound (1)     -- refuse loud (echo to stderr, return 1) UNLESS
#                             ALLOW_TRANSCRIPT_LOSS is "1", in which case
#                             print a one-line WARNING and proceed.
#   couldn't check (2, or  -- WARN (transient inspect hiccup must not
#   any other non-zero)       spuriously block a reload) and proceed.
_reload_enforce_transcript_guard() {
  local name="$1" allow_loss="$2"
  local _tg_rc=0
  _cage_claude_projects_host_bound "$name" || _tg_rc=$?
  case "$_tg_rc" in
    0)
      return 0
      ;;
    1)
      if [[ "$allow_loss" -eq 1 ]]; then
        log "WARNING: ~/.claude/projects is NOT host-bound on ${name} — proceeding with --allow-transcript-loss (any in-flight caged-claude conversation transcripts will be LOST by this cold-recreate)."
        return 0
      fi
      echo "Error: refusing to reload ${name} — ~/.claude/projects is not host-bound on this (legacy) cage." >&2
      echo "       'rc reload' cold-recreates the cage (stop -> remove -> recreate); the guest's ephemeral" >&2
      echo "       rootfs overlay is destroyed, which would silently DESTROY any in-flight caged-claude" >&2
      echo "       conversation transcripts (they are not persisted to the host on this cage today)." >&2
      echo "       Recreating gains host session persistence going forward (current 'rc up' always" >&2
      echo "       host-binds ~/.claude/projects)." >&2
      echo "       Override (you have confirmed there is no conversation to lose, or accept the loss):" >&2
      echo "         rc reload ${name} --allow-transcript-loss" >&2
      return 1
      ;;
    *)
      log "WARNING: could not determine whether ~/.claude/projects is host-bound on ${name} (msb inspect check failed) — proceeding without the transcript-loss guard."
      return 0
      ;;
  esac
}


# _reload_report_transcript_guard NAME
#
# rip-cage-aa4t: --dry-run half of the pre-reload transcript-persistence
# guard. Reports what a REAL invocation would do (refuse / proceed / warn)
# WITHOUT ever refusing or mutating anything — --dry-run's whole point is
# "show me, don't do it".
_reload_report_transcript_guard() {
  local name="$1"
  local _tg_rc=0
  _cage_claude_projects_host_bound "$name" || _tg_rc=$?
  case "$_tg_rc" in
    0)
      log "(--dry-run) transcript-persistence guard: ~/.claude/projects is host-bound on ${name} — a real reload would proceed normally."
      ;;
    1)
      log "(--dry-run) transcript-persistence guard: ~/.claude/projects is NOT host-bound on ${name} — a real reload would REFUSE (override with --allow-transcript-loss)."
      ;;
    *)
      log "(--dry-run) transcript-persistence guard: could not determine host-bind status for ~/.claude/projects on ${name} (msb inspect check failed) — a real reload would WARN and proceed."
      ;;
  esac
}


# The reload-eligible path set retired with the config diff it gated
# (ADR-031 D2). It named which merged-config fields `rc reload` would accept
# and which made it refuse; with one unmerged file read fresh at every launch
# there is no merge to classify fields of, and reload recreates unconditionally.

