#!/usr/bin/env bash
# _scratch-cage-lib.sh — Shared sourced helper for scratch-cage cleanup (rip-cage-aqww)
#
# Usage: source this file from any scratch-cage test, then call:
#   scratch_cage_register <container-name>
#
# On first call, installs an idempotent EXIT/INT/TERM trap that runs
# `rc destroy --force` on every registered container name when the test exits
# (normal or interrupted). Composes with any pre-existing trap so tests that
# already arm their own EXIT trap keep working.
#
# Design decisions:
# - TRAP COMPOSITION: captures current EXIT/INT/TERM body via `trap -p` before
#   installing; installs a combined handler that runs the prior body (if any) AND
#   the scratch cleanup. `trap -p` is EMPTY when no trap exists — handled cleanly.
# - TRAP ORDER (rip-cage-54q3): the scratch cleanup (cage destroy) runs BEFORE
#   the prior trap body, not after. A prior body commonly deletes the test's own
#   mktemp workspace dir; running that first, while the cage is still up, leaves
#   a running cage whose /workspace virtiofs mount source no longer exists (a
#   dead mount — msb then reports every later exec as spawn-ENOENT against the
#   program name, not the missing cwd). Destroying the cage first closes that
#   window.
# - LOUDNESS (rip-cage-54q3): each `rc destroy --force` output and exit status
#   are captured; a failed destroy is named on stderr (cage name + destroy
#   output) and counted, with a summary line when any failed. This is a REPORT,
#   not a gate: the handler preserves $? (entry status captured on first line,
#   restored before return) so a failing destroy (e.g. daemon down) never
#   alters the test's real exit status (ADR-001 D1: fail-loud on the TEST's
#   real result; cleanup never masks it).
# - rc location: ${SCRIPT_DIR}/../rc (sibling-test idiom, not bare `rc` on PATH).
#   SCRIPT_DIR must be set in the sourcing test (standard pattern across tests/).

# Guard: SCRIPT_DIR must be set by the caller.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
  echo "_scratch-cage-lib.sh: ERROR: SCRIPT_DIR is not set in the sourcing script." >&2
  return 1
fi

# Accumulate registered container names (space-separated, shell array).
_SCRATCH_CAGE_NAMES=()

# Track whether the combined trap has already been installed (idempotent).
_SCRATCH_CAGE_TRAP_ARMED=0

# _scratch_cage_cleanup — iterates _SCRATCH_CAGE_NAMES and destroys each.
# Preserves $? across the handler so the test's real exit status is not
# altered. rip-cage-54q3 SEAM 2: a failed destroy is never swallowed silently
# (a leak must not look like a clean run) — capture its exit status and
# output, name the cage and quote the output in ONE line on stderr, and count
# failures for a trailing summary line. This is a REPORT, not a gate: even
# when every destroy fails, the function still returns the caller's real
# entry $? (ADR-001 D1 — cleanup never masks the test's result).
_scratch_cage_cleanup() {
  local _exit_status=$?
  local _name _out _rc
  local _failures=0
  for _name in "${_SCRATCH_CAGE_NAMES[@]+"${_SCRATCH_CAGE_NAMES[@]}"}"; do
    _out=$("${SCRIPT_DIR}/../rc" destroy --force "$_name" 2>&1)
    _rc=$?
    if [[ "$_rc" -ne 0 ]]; then
      echo "_scratch-cage-lib.sh: WARNING: failed to destroy scratch cage '${_name}' (exit ${_rc}): ${_out}" >&2
      _failures=$((_failures + 1))
    fi
  done
  if [[ "$_failures" -gt 0 ]]; then
    echo "_scratch-cage-lib.sh: WARNING: ${_failures} scratch cage(s) failed to destroy -- see warning(s) above (this cage will leak until destroyed manually)" >&2
  fi
  return "$_exit_status"
}

# scratch_cage_register <container-name>
# Append the container name to the list. On first call, compose and install the
# EXIT/INT/TERM trap.
scratch_cage_register() {
  local _cname="$1"
  if [[ -z "$_cname" ]]; then
    echo "_scratch-cage-lib.sh: scratch_cage_register requires a container name" >&2
    return 1
  fi

  _SCRATCH_CAGE_NAMES+=("$_cname")

  if [[ "$_SCRATCH_CAGE_TRAP_ARMED" -eq 1 ]]; then
    return 0
  fi
  _SCRATCH_CAGE_TRAP_ARMED=1

  # Capture any pre-existing EXIT/INT/TERM trap body.
  # `trap -p SIG` emits: trap -- 'BODY' SIG
  # When no trap is set, it emits nothing. Extract only the body (the quoted string).
  local _prior_exit _prior_int _prior_term
  _prior_exit=$(trap -p EXIT 2>/dev/null | sed -n "s/^trap -- '\\(.*\\)' EXIT$/\\1/p" || true)
  _prior_int=$(trap -p INT 2>/dev/null | sed -n "s/^trap -- '\\(.*\\)' INT$/\\1/p" || true)
  _prior_term=$(trap -p TERM 2>/dev/null | sed -n "s/^trap -- '\\(.*\\)' TERM$/\\1/p" || true)

  # Install combined EXIT handler. rip-cage-54q3 SEAM 1: the scratch cleanup
  # (cage destroy) must run BEFORE the prior trap body, not after — a prior
  # body that deletes the test's own mktemp workspace must never get a chance
  # to run while the cage it backs is still up (that race is exactly how
  # 54q3's dead-virtiofs-mount leak happened). $?-preservation is unaffected
  # by this reordering: bash restores the pre-trap exit status once the whole
  # composed trap command finishes, regardless of what runs inside it or in
  # which order (verified empirically under this fix — see ship-record).
  if [[ -n "$_prior_exit" ]]; then
    # shellcheck disable=SC2064
    trap "_scratch_cage_cleanup; ${_prior_exit}" EXIT
  else
    trap '_scratch_cage_cleanup' EXIT
  fi

  # Install combined INT handler (same ordering rationale as EXIT above).
  if [[ -n "$_prior_int" ]]; then
    # shellcheck disable=SC2064
    trap "_scratch_cage_cleanup; ${_prior_int}" INT
  else
    trap '_scratch_cage_cleanup' INT
  fi

  # Install combined TERM handler (same ordering rationale as EXIT above).
  if [[ -n "$_prior_term" ]]; then
    # shellcheck disable=SC2064
    trap "_scratch_cage_cleanup; ${_prior_term}" TERM
  else
    trap '_scratch_cage_cleanup' TERM
  fi
}
