#!/usr/bin/env bash
# tests/run-one.sh — hermetic single-test-file wrapper (rip-cage-w3lq).
#
# Bare per-file test runs (`bash tests/test-foo.sh`) are non-hermetic: only
# the full-suite driver (tests/run-host.sh) builds the benign config sandbox
# that neutralizes a promoted global config (e.g. a real
# ~/.config/rip-cage/config.yaml with network.egress.mediator set to
# something other than "none"). A test that forces egress=off, or otherwise
# assumes "no config"/"benign config" defaults, can silently misbehave when
# run bare on a machine with a promoted global. This wrapper builds the SAME
# sandbox tests/run-host.sh does (via the shared tests/_host-sandbox-lib.sh)
# around exactly ONE test file, so a single-file red/green cycle is as
# trustworthy as a full-suite run.
#
# Usage:
#   bash tests/run-one.sh <test-file>                 # sandboxed run (no scratch-cage sweep)
#   bash tests/run-one.sh --sweep <test-file>          # + leaked-scratch-cage sweep (slower)
#   RC_E2E=1 bash tests/run-one.sh <test-file>          # pass through to the test
#   RC_TEST_CONTAINER=name RC_IMAGE=tag bash tests/run-one.sh <test-file>  # pass through
#
# Env vars forwarded to the test file unchanged (this wrapper does not set,
# clear, or interpret them itself): RC_E2E, RC_TEST_CONTAINER, RC_IMAGE.
#
# Exit code: propagates the wrapped test file's exit code verbatim.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RO_SWEEP=false
RO_TEST_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sweep)
      RO_SWEEP=true
      shift
      ;;
    -h|--help)
      echo "Usage: bash tests/run-one.sh [--sweep] <test-file>" >&2
      exit 0
      ;;
    *)
      if [[ -n "$RO_TEST_FILE" ]]; then
        echo "ERROR: run-one.sh wraps exactly ONE test file; got a second argument: $1" >&2
        exit 2
      fi
      RO_TEST_FILE="$1"
      shift
      ;;
  esac
done

if [[ -z "$RO_TEST_FILE" ]]; then
  echo "ERROR: run-one.sh requires a test-file argument" >&2
  echo "Usage: bash tests/run-one.sh [--sweep] <test-file>" >&2
  exit 2
fi

if [[ ! -f "$RO_TEST_FILE" ]]; then
  echo "ERROR: test file not found: $RO_TEST_FILE" >&2
  exit 2
fi

# shellcheck source=tests/_host-sandbox-lib.sh
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
_host_sandbox_setup

# rip-cage-aqww D2: same self-healing scratch-cage sweep run-host.sh runs on
# every invocation, gated behind --sweep here (default OFF) — a single-file
# wrapper is meant for fast red/green cycles; a full docker ps/inspect sweep
# adds real wall-clock cost most single-file runs don't need. run-host.sh's
# own sweep is unaffected (it always sweeps; not touched by this bead).
_run_one_sweep_scratch_cages() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  local _cname _raw_sp _root _rt
  local -a _roots=()
  _rt=$(realpath "${TMPDIR:-/tmp}" 2>/dev/null || true)
  [[ -n "$_rt" ]] && _roots+=("$_rt")
  for _lit in "/private/var/folders" "/tmp" "/private/tmp"; do
    local _already=0 _existing
    for _existing in "${_roots[@]+"${_roots[@]}"}"; do
      [[ "$_existing" == "$_lit" ]] && _already=1
    done
    [[ "$_already" -eq 0 ]] && _roots+=("$_lit")
  done
  for _cname in $(docker ps -a --filter "label=rc.source.path" --format '{{.Names}}' 2>/dev/null || true); do
    _raw_sp=$(docker inspect --format '{{ index .Config.Labels "rc.source.path" }}' "$_cname" 2>/dev/null || true)
    [[ -z "$_raw_sp" ]] && continue
    for _root in "${_roots[@]+"${_roots[@]}"}"; do
      if [[ "$_raw_sp" == "${_root}"/* || "$_raw_sp" == "${_root}" ]]; then
        "${SCRIPT_DIR}/../rc" destroy --force "$_cname" >/dev/null 2>&1 || true
        break
      fi
    done
  done
}

# shellcheck disable=SC2329  # invoked indirectly via trap
_run_one_cleanup() {
  _host_sandbox_cleanup
  if [[ "$RO_SWEEP" == "true" ]]; then
    _run_one_sweep_scratch_cages
  fi
}
trap '_run_one_cleanup' EXIT INT TERM

if [[ "$RO_SWEEP" == "true" ]]; then
  _run_one_sweep_scratch_cages
fi

# Exec-and-propagate: run the ONE test file under the sandbox, with RC_E2E /
# RC_TEST_CONTAINER / RC_IMAGE passed through from this process's own
# environment (whatever the caller set/left unset — not touched here).
bash "$RO_TEST_FILE"
exit $?
