#!/usr/bin/env bash
# cli/lib/msb_runtime.sh -- msb-backed runtime primitives (rip-cage-rj68, S6
# of the msb migration epic rip-cage-tsf2). NOTE: sourced by the rc shim;
# must NOT set -euo pipefail (shim owns strict mode once).
#
# This module is the msb-side counterpart to cli/lib/docker.sh, providing the
# same class of primitive (state read, label read, exec, create, stop/start)
# for the lifecycle-verb code paths this bead rewires (cli/up.sh's create/
# resume, cli/reload.sh, cli/doctor.sh, and the shared resolve_name/
# verify_rc_container/_container_multiplexer helpers in cli/lib/container.sh
# — ADR-029 D1 is a hard cutover, not a dual backend, so these replace their
# docker-backed equivalents at every call site those modules touch; they do
# not coexist with them there).
#
# `docker.sh` itself is untouched and stays live for the verb modules NOT in
# this bead's scope (cli/attach_exec.sh, cli/down_destroy.sh, cli/allowlist.sh,
# cli/build.sh, cli/manifest.sh, cli/ls.sh's live probes, cli/test.sh) — a
# known, flagged gap: a cage created via the new `rc up` is an msb sandbox,
# not a docker container, so those still-docker verbs cannot currently drive
# it. Out of S6's stated scope (create/resume/reload/doctor); left for a
# follow-up child.


# check_msb -- verifies the msb CLI is installed and responsive (msb-side
# counterpart to docker.sh's check_docker). `rc doctor` skips this the same
# way `rc doctor --host` skips check_docker, for the same reason: doctor's
# job on that path IS to diagnose an unreachable runtime.
check_msb() {
  if ! command -v msb &>/dev/null; then
    if [[ "${OUTPUT_FORMAT:-human}" == "json" ]]; then
      json_error "msb is required but not installed. Install: https://github.com/microsandbox/microsandbox" "MSB_NOT_INSTALLED"
    fi
    echo "Error: 'msb' is required but not installed." >&2
    echo "  Install: https://github.com/microsandbox/microsandbox" >&2
    exit 1
  fi
  local _preflight_timeout="${RC_MSB_PREFLIGHT_TIMEOUT:-5}"
  local _rc=0
  _run_with_timeout "$_preflight_timeout" msb --version >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]]; then
    return 0
  fi
  local _msg
  if [[ "$_rc" -eq 124 ]]; then
    _msg="msb is unresponsive (no reply within ${_preflight_timeout}s)."
  else
    _msg="msb is not reachable (msb --version exited $_rc)."
  fi
  if [[ "${OUTPUT_FORMAT:-human}" == "json" ]]; then
    json_error "$_msg" "MSB_UNREACHABLE"
  fi
  echo "Error: $_msg" >&2
  exit 1
}


# _msb_call SECS ARGS... -- invoke `msb ARGS...` with a bounded timeout
# (msb-side counterpart to docker.sh's _docker_call). stdout passes through.
_msb_call() {
  local secs=$1; shift
  local _rc=0
  _run_with_timeout "$secs" msb "$@" || _rc=$?
  if [[ "$_rc" -eq 124 ]]; then
    local _msg="msb call timed out after ${secs}s: 'msb $*'."
    if [[ "${OUTPUT_FORMAT:-human}" == "json" ]]; then
      json_error "$_msg" "MSB_UNREACHABLE"
    fi
    echo "Error: $_msg" >&2
    exit 1
  fi
  return "$_rc"
}


# _msb_inspect_json NAME -- raw `msb inspect NAME --format json` output on
# stdout. Returns non-zero (no output) when the sandbox does not exist —
# every reader below (_msb_sandbox_state, _msb_label, _msb_exists) composes
# on this single call shape, matching docker.sh's `docker inspect` idiom.
_msb_inspect_json() {
  local name="$1"
  msb inspect "$name" --format json 2>/dev/null
}


# _msb_sandbox_state NAME -- echoes "running" or "exited" for a real sandbox
# (msb's Running/Stopped, translated onto the docker.State.Status vocabulary
# cli/up.sh's existing state-branch logic already reads, so that logic keeps
# working unchanged), or "" with a non-zero return when the sandbox is
# absent. Any other reported status prints "unknown" (defensive — msb has no
# paused/restarting/removing/dead concept observed live, but a future msb
# release adding one must not silently be misread as running/exited).
_msb_sandbox_state() {
  local name="$1"
  local raw
  raw=$(_msb_inspect_json "$name") || { echo ""; return 1; }
  local status
  status=$(jq -r '.status // empty' <<<"$raw" 2>/dev/null)
  case "$status" in
    Running) echo "running" ;;
    Stopped) echo "exited" ;;
    "") echo ""; return 1 ;;
    *) echo "unknown" ;;
  esac
}


# _msb_label NAME KEY -- echoes the real label value from `msb inspect`
# (`.config.labels[KEY]`), or empty (never an error string) when the
# sandbox or the key is absent. Returns non-zero only when the sandbox
# itself does not exist (mirrors docker.sh's `docker inspect --format`
# idiom, which callers rely on for the "container absent" branch).
_msb_label() {
  local name="$1" key="$2"
  local raw
  raw=$(_msb_inspect_json "$name") || return 1
  jq -r --arg k "$key" '.config.labels[$k] // empty' <<<"$raw" 2>/dev/null
}


# _msb_exists NAME -- true (0) if a real sandbox by this name exists
# (running or stopped), false (1) otherwise.
_msb_exists() {
  local name="$1"
  _msb_inspect_json "$name" >/dev/null
}


# _msb_sandbox_image_digest NAME -- echoes the sha256:... digest of the
# image a real sandbox was created from (`.config.manifest_digest`).
# Returns non-zero with empty output when the sandbox is absent. Feeds
# cli/up.sh's _up_image_drift_status (msb-side counterpart to comparing
# `docker inspect --format '{{.Image}}'` against `docker image inspect
# --format '{{.Id}}'`).
_msb_sandbox_image_digest() {
  local name="$1"
  local raw
  raw=$(_msb_inspect_json "$name") || return 1
  jq -r '.config.manifest_digest // empty' <<<"$raw" 2>/dev/null
}


# _msb_current_image_digest IMAGE -- echoes the sha256:... digest of the
# named image in msb's LOCAL image cache (`msb image list`), or empty with
# non-zero return when the image is not present locally.
_msb_current_image_digest() {
  local image="$1"
  local raw
  raw=$(msb image list --format json 2>/dev/null) || return 1
  local digest
  digest=$(jq -r --arg img "$image" '.[] | select(.reference == $img) | .digest' <<<"$raw" 2>/dev/null | head -1)
  [[ -n "$digest" ]] || return 1
  echo "$digest"
}


# _msb_exec NAME ARGS... -- run a real command in a running sandbox
# non-interactively (msb-side counterpart to `docker exec NAME ARGS...`).
# stdout/stderr pass through; exit code propagates.
_msb_exec() {
  local name="$1"; shift
  msb exec "$name" "$@"
}


# _msb_exec_interactive NAME ARGS... -- run a command in a running sandbox
# with a pty (msb-side counterpart to `docker exec -it NAME ARGS...`).
_msb_exec_interactive() {
  local name="$1"; shift
  msb exec -t "$name" "$@"
}


# _msb_start NAME -- resume a stopped sandbox (msb-side counterpart to
# `docker start NAME`).
_msb_start() {
  local name="$1"
  msb start "$name"
}


# _msb_stop_graceful NAME -- stop a sandbox WITHOUT --force (ADR-029 D4's
# lifecycle corollary: any cage-stop path that must preserve state uses
# graceful stop only — --force hard-kills and silently discards guest
# writes that already reported success, rip-cage-9iab Q4). This is the ONLY
# stop primitive this module exposes on purpose — there is no
# `_msb_stop_forced` sibling here; a caller that genuinely needs a forced
# kill must call `msb stop --force` directly and carry its own justification
# inline, so a forced stop is never one accidental flag away on a
# state-bearing cage (bead rip-cage-rj68 acceptance criterion 2 regression
# guard).
_msb_stop_graceful() {
  local name="$1"
  msb stop "$name"
}


# _msb_denied_domains_from_trace_log NAME
#
# rip-cage-rj68 (S6, ADR-029 D2's re-homed deny-visibility): mines a real
# sandbox's trace-level system log for DNS-stage egress denials
# (`microsandbox_network::dns::forwarder: DNS query denied by network
# policy domain=<X>`, confirmed live in
# docs/2026-07-09-msb-spike-egress-observability.md Q3 -- only present at
# `--log-level trace`, which _up_start_container always passes at create
# time for exactly this reason) and turns them into a human-readable
# fix-hint, one denied domain per line, deduplicated, in first-seen order.
#
# This is the "readable fix-hint" the bead's criterion 5 asks for -- NOT
# merely "the domain string is present somewhere in a raw `msb logs`
# dump" (the raw JSONL line is a Rust-debug-formatted log record embedded
# in a `"d":"..."` field; a caller consuming it wants a domain name, not a
# log line to re-parse itself). Consumed by cli/doctor.sh's posture probe
# and referenced by cli/reload.sh's repair-loop guidance.
#
# Only TCP/DNS-stage domain denials are covered (the sole channel the
# 2026-07-09 spike found actually logged at any verbosity — the
# TCP-connect-stage case, e.g. right-domain-wrong-port, logs nothing at
# any tested level, a documented msb-side gap this bead does not attempt
# to work around).
#
# Echoes empty (never errors) when the sandbox has no logs yet or no
# denials occurred.
#
# rip-cage-5iti (S10 finding): `grep -o` exits 1 on zero matches -- the
# common/default case for a healthy cage with no denials. Callers'
# real dispatch context (rc's shim) runs under `set -euo pipefail`; without
# the `|| true` guard below, pipefail propagates that non-zero through the
# whole pipe, and an unguarded `x=$(_msb_denied_domains_from_trace_log
# ...)` assignment at either call site (cli/reload.sh's cmd_reload,
# cli/doctor.sh's posture probe) then aborts the CALLER under errexit --
# violating this function's own "never errors" contract above (proven live
# by tests/test-msb-runtime.sh R7 against a real sandbox with zero
# denials). The guard absorbs only the expected zero-match case; a genuine
# `msb logs` failure is already discarded via `2>/dev/null` on msb itself.
_msb_denied_domains_from_trace_log() {
  local name="$1"
  msb logs "$name" --source system --json 2>/dev/null \
    | { grep -o 'DNS query denied by network policy domain=[^\\"]*' || true; } \
    | sed 's/^DNS query denied by network policy domain=//' \
    | awk '!seen[$0]++'
}


# _msb_remove NAME -- remove a sandbox entirely (msb-side counterpart to
# `docker rm -f NAME`).
_msb_remove() {
  local name="$1"
  msb remove --force "$name"
}


# _msb_volume_remove NAME -- delete one msb named volume (msb-side
# counterpart to `docker volume rm NAME`). rip-cage-tsf2.1: `msb remove`
# (above) has NO volume-deletion flag -- named volumes SURVIVE a sandbox
# remove+recreate by design (migration spike finding). `rc destroy`'s own
# destroy policy (mirroring the pre-migration docker behavior it replaces)
# explicitly deletes the cage's own rc-state-<name>/rc-history-<name>
# volumes via this primitive, a DISTINCT command (`msb volume remove`, not
# `msb remove`) — never assume `_msb_remove` alone cleans volumes.
_msb_volume_remove() {
  local name="$1"
  msb volume remove "$name"
}
