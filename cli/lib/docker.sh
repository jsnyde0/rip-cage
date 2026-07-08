#!/usr/bin/env bash
# cli/lib/docker.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# _run_with_timeout SECS CMD... — run CMD with a hard timeout, in seconds.
# macOS bash 3.2 compatible (no `timeout(1)` / `gtimeout` host dependency —
# coreutils is not in the BSD base, see _probe_tcp for the same constraint).
# Returns 124 on timeout (matches GNU coreutils `timeout` convention).
# stdout/stderr of CMD pass through; safe to use inside command substitution.
_run_with_timeout() {
  local secs=$1; shift
  "$@" &
  local pid=$!
  local elapsed=0
  local limit=$(( secs * 10 ))
  while (( elapsed < limit )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      local rc=0
      wait "$pid" 2>/dev/null || rc=$?
      return "$rc"
    fi
    sleep 0.1
    elapsed=$(( elapsed + 1 ))
  done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}


# _docker_call SECS DOCKER_ARGS... — invoke `docker DOCKER_ARGS...` with a
# bounded timeout (B per-call defense in depth). On timeout, fails loud with
# DOCKER_DAEMON_UNREACHABLE so an agent or human sees a clear error rather than
# a hung interactive session. Honors OUTPUT_FORMAT. stdout passes through.
#
# When NOT to use: long-running by design (image pulls, interactive sessions,
# in-container test scripts). Leave those alone.
_docker_call() {
  local secs=$1; shift
  local _rc=0
  _run_with_timeout "$secs" docker "$@" || _rc=$?
  if [[ "$_rc" -eq 124 ]]; then
    local _msg="Docker call timed out after ${secs}s: 'docker $*'. Daemon may have wedged mid-call. Try: 'orb restart' (OrbStack) or restart Docker Desktop."
    if [[ "${OUTPUT_FORMAT:-human}" == "json" ]]; then
      json_error "$_msg" "DOCKER_DAEMON_UNREACHABLE"
    fi
    echo "Error: $_msg" >&2
    exit 1
  fi
  return "$_rc"
}


# check_docker — verifies docker is installed and the daemon is responsive.
#
# A wedged daemon (e.g. OrbStack VM stuck mid-boot — socket file present but
# the process never replies) used to hang every rc subcommand forever because
# `docker info` had no bounded wait. The preflight now caps that at
# RC_DOCKER_PREFLIGHT_TIMEOUT seconds (default 3) and surfaces a structured
# DOCKER_DAEMON_UNREACHABLE error.
#
# ADR-001 explicitly excludes "transient infrastructure errors" from its
# fail-loud remit, but a clear actionable error is still the right behavior
# (a silent hang would be the worst possible UX).
check_docker() {
  if ! command -v docker &>/dev/null; then
    if [[ "${OUTPUT_FORMAT:-human}" == "json" ]]; then
      json_error "docker is required but not installed. Install Docker Desktop: https://docs.docker.com/get-docker/" "DOCKER_NOT_INSTALLED"
    fi
    echo "Error: 'docker' is required but not installed." >&2
    echo "  Install Docker Desktop: https://docs.docker.com/get-docker/" >&2
    exit 1
  fi
  local _preflight_timeout="${RC_DOCKER_PREFLIGHT_TIMEOUT:-3}"
  local _info_rc=0
  _run_with_timeout "$_preflight_timeout" docker info >/dev/null 2>&1 || _info_rc=$?
  if [[ "$_info_rc" -eq 0 ]]; then
    return 0
  fi
  local _msg
  if [[ "$_info_rc" -eq 124 ]]; then
    _msg="Docker daemon is unresponsive (no reply within ${_preflight_timeout}s). The daemon process may be alive but wedged. Try: 'orb restart' (OrbStack) or restart Docker Desktop, then retry. (Override the wait via RC_DOCKER_PREFLIGHT_TIMEOUT.)"
  else
    _msg="Docker daemon is not reachable (docker info exited $_info_rc). Start Docker Desktop / OrbStack, or run: sudo systemctl start docker"
  fi
  if [[ "${OUTPUT_FORMAT:-human}" == "json" ]]; then
    json_error "$_msg" "DOCKER_DAEMON_UNREACHABLE"
  fi
  echo "Error: $_msg" >&2
  exit 1
}

