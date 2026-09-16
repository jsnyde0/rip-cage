#!/usr/bin/env bash
# cli/down_destroy.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).
#
# rip-cage-tsf2.1 (msb migration epic rip-cage-tsf2): REWRITTEN onto msb --
# was docker inspect/stop/rm/volume rm. down/destroy drive a cage created
# by the msb-backed `rc up` (S6, rip-cage-rj68).
#
# THE `down` VERB IS GONE (ADR-031 D3). Stopping a cage is one msb command —
# `msb stop <cage>` — so the wrapper earned nothing. The file keeps its name
# because `destroy` still lives here.
#
# ADR-029 D4 lifecycle corollary (FIRM): any cage-stop path that must
# preserve state uses graceful stop only (`_msb_stop_graceful`, msb_runtime.sh's
# ONLY stop primitive — see that module's own comment for why there is
# deliberately no forced-stop sibling to misuse here).
#
# msb behavioral fact (migration spike): `msb remove` has NO volume-
# deletion flag -- a cage's named volumes (rc-state-<name>,
# rc-history-<name>) SURVIVE `msb remove` alone. `cmd_destroy`'s destroy
# policy (mirroring the pre-migration docker behavior it replaces, which
# explicitly ran `docker volume rm` per volume) therefore ALSO calls the
# distinct `_msb_volume_remove` primitive per volume -- never assumes
# removing the sandbox cleans its volumes.


# THE CONFIRM PROMPT AND `--force` ARE BOTH GONE (ADR-031 D3, ruled
# 2026-09-16). `rc destroy` used to stop at a TTY and ask "Destroy? [y/N]"
# unless --force was passed. Agent-first means no prompts: the verb already
# takes an exact cage name, so the prompt guarded nothing an operator had not
# already typed, and --force existed only to switch it off. With the prompt
# deleted --force reads nothing, so it is deleted too rather than left as an
# accepted no-op that silently means less than it says.
#
# An unknown flag now fails loud instead of being taken as a cage name: the
# parser's old catch-all would have read `--force` as the name to destroy.
cmd_destroy() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*)
        [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "rc destroy takes a cage name, not the flag '$1'" "DESTROY_FLAG_UNKNOWN"
        echo "Error: rc destroy takes a cage name, not '$1'." >&2
        echo "       It accepts no flags. (-f/--force retired with the confirmation prompt: ADR-031 D3, agent-first means no prompts.)" >&2
        exit 1
        ;;
      *) name="$1"; shift ;;
    esac
  done
  name=$(resolve_name "$name") || exit 1

  # rip-cage-o5ie: a sandbox that has ALREADY been removed (e.g. a prior
  # `msb remove`, or a test's own EXIT-trap teardown racing a host-side
  # destroy) must not short-circuit destroy here -- its rc-state-<name>/
  # rc-history-<name> volumes (msb `remove` never deletes volumes, see this
  # file's header comment) would otherwise leak forever. Only verify the
  # rc.source.path label (verify_rc_container) when a sandbox actually
  # exists to check; there is nothing to verify once it's already gone.
  # Either way the two volume names below are derived STRICTLY from the
  # resolved $name -- NEVER an enumerate/wildcard sweep over existing
  # volumes (tests/test-cleanup-failsafe.sh is the incident repro for that
  # class of mistake).
  local sandbox_exists=0
  if _msb_exists "$name"; then
    sandbox_exists=1
    verify_rc_container "$name"
  else
    # No sandbox AND no leftover volume under this exact name -- genuinely
    # nothing to destroy. Fail loud here (before any confirmation/dry-run
    # prompt), same as the original "container not found" short-circuit.
    if ! msb volume inspect "rc-state-${name}" >/dev/null 2>&1 \
        && ! msb volume inspect "rc-history-${name}" >/dev/null 2>&1; then
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container not found: $name" "CONTAINER_NOT_FOUND"
      echo "Error: container $name not found" >&2; exit 1
    fi
  fi

  # (the interactive confirmation lived here -- see this function's header for
  # why it and --force were deleted. `rc destroy --dry-run` is what shows you
  # what would go, and it is not a prompt.)

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      jq -nc --arg name "$name" --arg action "would_destroy" --argjson dry_run true \
        --arg vol1 "rc-state-$name" --arg vol2 "rc-history-$name" \
        '{dry_run: $dry_run, name: $name, action: $action, volumes_removed: [$vol1, $vol2]}'
    else
      echo "Would remove container $name"
      echo "Would remove volumes: rc-state-$name, rc-history-$name"
    fi
    return 0
  fi

  # msb remove --force stops (if running) then removes the sandbox. Only
  # attempted when a sandbox actually exists (rip-cage-o5ie): when it's
  # already absent, skip straight to the volume-removal loop below instead
  # of erroring out before reaching it.
  if [[ "$sandbox_exists" -eq 1 ]]; then
    if ! _msb_remove "$name" >/dev/null 2>&1; then
      [[ "$OUTPUT_FORMAT" == "json" ]] && json_error "Container not found: $name" "CONTAINER_NOT_FOUND"
      echo "Error: container $name not found" >&2; exit 1
    fi
    # Clean up worktree gitfile if it exists
    rm -f "${HOME}/.cache/rc/${name}.gitfile"
  fi
  # `msb remove` (above) does NOT delete named volumes (no volume-deletion
  # flag on that command — a separate finding from the migration spike, see
  # this file's own header comment). Explicitly delete this cage's two
  # named volumes via the distinct `msb volume remove` primitive, mirroring
  # the pre-migration docker destroy policy this replaces.
  local volumes_removed=()
  for vol in "rc-state-${name}" "rc-history-${name}"; do
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      if _msb_volume_remove "$vol" >/dev/null 2>/dev/null; then
        volumes_removed+=("$vol")
      fi
    else
      if _msb_volume_remove "$vol" 2>/dev/null; then
        volumes_removed+=("$vol")
      else
        echo "Warning: volume $vol not found"
      fi
    fi
  done
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    local vol_json
    if [[ ${#volumes_removed[@]} -eq 0 ]]; then
      vol_json="[]"
    else
      vol_json=$(printf '%s\n' "${volumes_removed[@]}" | jq -R 'select(length > 0)' | jq -sc .)
    fi
    jq -nc --arg name "$name" --arg action "destroyed" --argjson volumes_removed "$vol_json" \
      '{name: $name, action: $action, volumes_removed: $volumes_removed}'
  else
    echo "Container $name and volumes destroyed."
  fi
}

