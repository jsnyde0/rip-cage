#!/usr/bin/env bash
# test-placeholder-env-file.sh — Host-tier unit tests for the
# auth.placeholder_env_file config pointer (rip-cage-b9to).
#
# auth.placeholder_env_file persists the placeholder-env-file pointer that
# `rc up --env-file` previously required at every create. It is resolved by a
# CREATE-SIDE, phase-aware resolver (_up_resolve_placeholder_env_file),
# modeled on _up_resolve_mediator_env_file (rc:~4029) with the v3-design
# deltas: CLI --env-file always wins, missing pointer is fatal at create only
# (never at resume — the call site never runs there), and the pointer is
# subject to _check_secret_path_denylist with the SAME treatment the CLI
# --env-file path gives it (rc:~4367) because — unlike the mediator's
# docker-exec-only channel — this pointer's contents land in the container's
# PID 1 env, which the agent CAN read (that's the point: non-secret,
# agent-held placeholder).
#
# Design-of-record: bd show rip-cage-b9to (--design v3, R1+R2 review rounds).
#
# Coverage matrix (bead's Harness target):
#   1  — key set + no CLI flag -> _UP_RUN_ARGS contains --env-file <pointer>.
#        Driver replicates cmd_up's scoping (local env_file="" -> resolver ->
#        call-site copy -> _up_prepare_environment) so a scoping no-op (the
#        resolver setting a global no one reads) cannot pass.
#   2  — both given -> CLI value survives in _UP_RUN_ARGS + ignore-log emitted.
#   2b — key unset + CLI --env-file given -> ZERO output mentioning
#        auth.placeholder_env_file (pins the read-key-first ordering /
#        acceptance d: existing --env-file users see no new output).
#   3  — key set + pointer file missing, create phase -> exit 1 naming
#        auth.placeholder_env_file.
#   3b — key set + pointer at a secret-denylisted path -> refused the same way
#        the CLI --env-file path refuses it (D2d).
#   4  — grep-anchored call-site probe: _up_resolve_placeholder_env_file is
#        invoked exactly once in rc, in the create region (after the last
#        resume/dry-run branch, before the real _up_prepare_environment
#        call) — never in a resume branch or the dry-run block.
#   5  — neither key nor flag -> args unchanged (positive control).
#
# All tests are host-side only (no live docker container required).
#
# Conventions (repo-mandated):
#   * FAILURES counter; file exits non-zero if any failure (no prose-only red)
#   * baseline `set -uo pipefail` (no -e — mirrors test-mediator-lifecycle.sh /
#     test-credential-mounts.sh)
#   * source rc with explicit path
#   * cleanup via trap
#
# Run:
#   bash tests/test-placeholder-env-file.sh
#
# Wired into tests/run-host.sh (host-only tier — no NEEDS_CONTAINER entry
# needed; auto-discovered by tests/test-*.sh glob).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
P_TEST_HOME=""
P_TEST_WS=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

# tests/run-host.sh exports RC_CONFIG_GLOBAL at driver level, which would
# shadow the per-test XDG sandboxes below — unset so per-call XDG_CONFIG_HOME
# sandboxes win (mirrors test-mediator-lifecycle.sh / test-config-loader.sh).
unset RC_CONFIG_GLOBAL

# shellcheck disable=SC2329
cleanup() {
  [[ -n "${P_TEST_HOME:-}" && -d "${P_TEST_HOME:-}" ]] && rm -rf "$P_TEST_HOME"
}
trap cleanup EXIT

echo "=== test-placeholder-env-file.sh — auth.placeholder_env_file (rip-cage-b9to) ==="
echo ""

setup_p_sandbox() {
  P_TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-pef-XXXXXX")
  mkdir -p "${P_TEST_HOME}/.config/rip-cage"
  cat > "${P_TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist: []
  allow_risky: null
YAML
  touch "${P_TEST_HOME}/.config/rip-cage/tools.yaml"
  P_TEST_WS="${P_TEST_HOME}/workspace"
  mkdir -p "$P_TEST_WS"
}

teardown_p_sandbox() {
  [[ -n "${P_TEST_HOME:-}" ]] && rm -rf "$P_TEST_HOME"
  P_TEST_HOME="" P_TEST_WS=""
}

# run_placeholder_driver — replicates cmd_up's scoping around the resolver:
# a driver FUNCTION (so `local` works) declares `local env_file=<initial>`,
# calls the resolver, does the call-site copy exactly as rc's create path
# does it, then calls the real _up_prepare_environment and prints _UP_RUN_ARGS.
# This makes a scoping no-op (resolver sets a global nobody reads) fail case 1.
#
# Args: $1=workspace $2=initial env_file (CLI value, "" if none)
#       $3=stderr capture file
run_placeholder_driver() {
  local ws="$1" initial_env_file="$2" stderr_file="$3"
  HOME="$P_TEST_HOME" XDG_CONFIG_HOME="${P_TEST_HOME}/.config" bash -c "
    source '$RC' 2>/dev/null
    _run_driver() {
      local env_file='$initial_env_file'
      _UP_RUN_ARGS=()
      _up_resolve_placeholder_env_file '$ws' \"\$env_file\"
      if [[ -n \"\$_UP_PLACEHOLDER_ENV_FILE\" ]]; then
        env_file=\"\$_UP_PLACEHOLDER_ENV_FILE\"
      fi
      _up_prepare_environment '$ws' '' \"\$env_file\" '2.0' '4g' '500' 'on' 'on'
      for arg in \"\${_UP_RUN_ARGS[@]:-}\"; do
        printf 'ARG: %s\n' \"\$arg\"
      done
    }
    _run_driver
  " 2>"$stderr_file"
}

echo "--- Case 1: key set + no CLI flag ---"
setup_p_sandbox
_c1_envfile="${P_TEST_HOME}/agent-placeholder.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=placeholder-token\n' > "$_c1_envfile"
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 2
auth:
  placeholder_env_file: ${_c1_envfile}
YAML
_c1_stderr=$(mktemp)
_c1_out=$(run_placeholder_driver "$P_TEST_WS" "" "$_c1_stderr")
_c1_exit=$?
# _UP_RUN_ARGS holds --env-file and its value as two separate array elements
# (mirrors _up_prepare_environment's _UP_RUN_ARGS+=(--env-file "$_env_file"));
# assert the two-line ARG sequence rather than a single concatenated line.
if [[ "$_c1_exit" -eq 0 ]] \
  && printf '%s\n' "$_c1_out" | grep -A1 -xF "ARG: --env-file" | grep -qxF "ARG: ${_c1_envfile}"; then
  pass "Case 1 key set + no CLI flag: --env-file ${_c1_envfile} present in _UP_RUN_ARGS"
else
  fail "Case 1 key set + no CLI flag" "exit=$_c1_exit out='$_c1_out' stderr=$(cat "$_c1_stderr")"
fi
rm -f "$_c1_stderr"
teardown_p_sandbox

echo ""
echo "--- Case 2: both given (key set + CLI --env-file) ---"
setup_p_sandbox
_c2_pointer_envfile="${P_TEST_HOME}/from-pointer.env"
printf 'SOME_VAR=from-pointer\n' > "$_c2_pointer_envfile"
_c2_cli_envfile="${P_TEST_HOME}/from-cli.env"
printf 'SOME_VAR=from-cli\n' > "$_c2_cli_envfile"
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 2
auth:
  placeholder_env_file: ${_c2_pointer_envfile}
YAML
_c2_stderr=$(mktemp)
_c2_out=$(run_placeholder_driver "$P_TEST_WS" "$_c2_cli_envfile" "$_c2_stderr")
_c2_exit=$?
_c2_err=$(cat "$_c2_stderr")
if [[ "$_c2_exit" -eq 0 ]] \
  && printf '%s\n' "$_c2_out" | grep -A1 -xF "ARG: --env-file" | grep -qxF "ARG: ${_c2_cli_envfile}" \
  && ! echo "$_c2_out" | grep -qF "$_c2_pointer_envfile" \
  && echo "$_c2_out$_c2_err" | grep -q "auth.placeholder_env_file: ignored"; then
  pass "Case 2 both given: CLI value survives in _UP_RUN_ARGS, ignore-log emitted, pointer never applied"
else
  fail "Case 2 both given" "exit=$_c2_exit out='$_c2_out' stderr=$_c2_err"
fi
rm -f "$_c2_stderr"
teardown_p_sandbox

echo ""
echo "--- Case 2b: key UNSET + CLI --env-file given ---"
setup_p_sandbox
_c2b_cli_envfile="${P_TEST_HOME}/cli-supplied.env"
printf 'SOME_VAR=cli-value\n' > "$_c2b_cli_envfile"
# No auth.placeholder_env_file in .rip-cage.yaml at all.
cat > "${P_TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
YAML
_c2b_stderr=$(mktemp)
_c2b_out=$(run_placeholder_driver "$P_TEST_WS" "$_c2b_cli_envfile" "$_c2b_stderr")
_c2b_exit=$?
_c2b_err=$(cat "$_c2b_stderr")
if [[ "$_c2b_exit" -eq 0 ]] \
  && printf '%s\n' "$_c2b_out" | grep -A1 -xF "ARG: --env-file" | grep -qxF "ARG: ${_c2b_cli_envfile}" \
  && ! echo "$_c2b_out$_c2b_err" | grep -q "auth.placeholder_env_file"; then
  pass "Case 2b key unset + CLI --env-file given: CLI value survives, ZERO auth.placeholder_env_file output (acceptance d)"
else
  fail "Case 2b key unset + CLI given" "exit=$_c2b_exit out='$_c2b_out' stderr=$_c2b_err"
fi
rm -f "$_c2b_stderr"
teardown_p_sandbox

echo ""
echo "--- Case 3: key set + pointer file missing (create phase) ---"
setup_p_sandbox
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 2
auth:
  placeholder_env_file: ${P_TEST_HOME}/nonexistent-placeholder.env
YAML
_c3_stderr=$(mktemp)
run_placeholder_driver "$P_TEST_WS" "" "$_c3_stderr" >/dev/null
_c3_exit=$?
_c3_err=$(cat "$_c3_stderr")
if [[ "$_c3_exit" -ne 0 ]] \
  && echo "$_c3_err" | grep -q "auth.placeholder_env_file" \
  && echo "$_c3_err" | grep -qi "nonexistent-placeholder.env"; then
  pass "Case 3 missing pointer file at create: exit non-zero, names auth.placeholder_env_file + the path"
else
  fail "Case 3 missing pointer file" "exit=$_c3_exit stderr=$_c3_err"
fi
rm -f "$_c3_stderr"
teardown_p_sandbox

echo ""
echo "--- Case 3b: key set + pointer at a secret-denylisted path ---"
setup_p_sandbox
# Override the global config's denylist to include a pattern the pointer's
# path will match by component (component-equals matching, ADR-023 D4).
cat > "${P_TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist: ["credentials"]
  allow_risky: null
YAML
mkdir -p "${P_TEST_HOME}/.aws"
_c3b_pointer="${P_TEST_HOME}/.aws/credentials"
printf 'aws_access_key_id=AKIAFAKE\n' > "$_c3b_pointer"
cat > "${P_TEST_WS}/.rip-cage.yaml" <<YAML
version: 2
auth:
  placeholder_env_file: ${_c3b_pointer}
YAML
_c3b_stderr=$(mktemp)
run_placeholder_driver "$P_TEST_WS" "" "$_c3b_stderr" >/dev/null
_c3b_exit=$?
_c3b_err=$(cat "$_c3b_stderr")
if [[ "$_c3b_exit" -ne 0 ]] \
  && echo "$_c3b_err" | grep -q "refusing to mount" \
  && echo "$_c3b_err" | grep -qF "$_c3b_pointer" \
  && echo "$_c3b_err" | grep -q "credentials"; then
  pass "Case 3b secret-denylisted pointer: refused the same way the CLI --env-file path refuses it (D2d)"
else
  fail "Case 3b secret-denylisted pointer" "exit=$_c3b_exit stderr=$_c3b_err"
fi
rm -f "$_c3b_stderr"
teardown_p_sandbox

echo ""
echo "--- Case 4: grep-anchored call-site probe (phase-awareness) ---"
# Static analysis, no driver needed. Anchors are resolved by grep at test run
# time (not hardcoded line numbers) so the probe survives unrelated line-count
# drift elsewhere in rc. A "no exit 1 on resume" *behavioral* check alone
# would pass vacuously (the call site could simply be absent everywhere) —
# this probe instead pins presence-exactly-once AND position.
_c4_call_count=$(grep -c '_up_resolve_placeholder_env_file "\$path"' "$RC")
_c4_call_line=$(grep -n '_up_resolve_placeholder_env_file "\$path"' "$RC" | head -1 | cut -d: -f1)
_c4_prepare_env_line=$(grep -n '_up_prepare_environment "\$path" "\$port" "\$env_file"' "$RC" | head -1 | cut -d: -f1)
_c4_create_start_line=$(grep -n '# New container — provision image now if absent/stale (ADR-008 D6)\.' "$RC" | head -1 | cut -d: -f1)
_c4_dryrun_start_line=$(grep -n '^  if \[\[ "\$DRY_RUN" == "true" \]\]; then$' "$RC" | head -1 | cut -d: -f1)
_c4_resume_running_start_line=$(grep -n '^  if \[\[ "\$state" == "running" \]\]; then$' "$RC" | head -1 | cut -d: -f1)
_c4_resume_stopped_start_line=$(grep -n '^  elif \[\[ "\$state" == "exited" \]\] || \[\[ "\$state" == "created" \]\]; then$' "$RC" | head -1 | cut -d: -f1)

_c4_ok=true
_c4_reason=""

if [[ "$_c4_call_count" -ne 1 ]]; then
  _c4_ok=false; _c4_reason="${_c4_reason:+$_c4_reason; }expected exactly 1 invocation, found ${_c4_call_count}"
fi

if [[ -z "$_c4_call_line" || -z "$_c4_prepare_env_line" || -z "$_c4_create_start_line" \
   || -z "$_c4_dryrun_start_line" || -z "$_c4_resume_running_start_line" || -z "$_c4_resume_stopped_start_line" ]]; then
  _c4_ok=false; _c4_reason="${_c4_reason:+$_c4_reason; }FATAL: one or more anchors not found — markers may have changed"
else
  # Positioned in the create region: after the create-start marker, before
  # the real _up_prepare_environment call.
  if ! [[ "$_c4_call_line" -gt "$_c4_create_start_line" && "$_c4_call_line" -lt "$_c4_prepare_env_line" ]]; then
    _c4_ok=false; _c4_reason="${_c4_reason:+$_c4_reason; }call site (line ${_c4_call_line}) not between create-start (${_c4_create_start_line}) and _up_prepare_environment (${_c4_prepare_env_line})"
  fi

  # Absent from the dry-run block (cmd_up's own, first occurrence -> the
  # resume-running block start is the block's upper bound).
  _c4_dryrun_hits=$(sed -n "${_c4_dryrun_start_line},${_c4_resume_running_start_line}p" "$RC" | grep -c '_up_resolve_placeholder_env_file' || true)
  if [[ "${_c4_dryrun_hits:-0}" -ne 0 ]]; then
    _c4_ok=false; _c4_reason="${_c4_reason:+$_c4_reason; }found in dry-run block (${_c4_dryrun_hits} hits)"
  fi

  # Absent from the resume-running branch.
  _c4_resume_running_hits=$(sed -n "${_c4_resume_running_start_line},${_c4_resume_stopped_start_line}p" "$RC" | grep -c '_up_resolve_placeholder_env_file' || true)
  if [[ "${_c4_resume_running_hits:-0}" -ne 0 ]]; then
    _c4_ok=false; _c4_reason="${_c4_reason:+$_c4_reason; }found in resume-running branch (${_c4_resume_running_hits} hits)"
  fi

  # Absent from the resume-stopped branch.
  _c4_resume_stopped_hits=$(sed -n "${_c4_resume_stopped_start_line},${_c4_create_start_line}p" "$RC" | grep -c '_up_resolve_placeholder_env_file' || true)
  if [[ "${_c4_resume_stopped_hits:-0}" -ne 0 ]]; then
    _c4_ok=false; _c4_reason="${_c4_reason:+$_c4_reason; }found in resume-stopped branch (${_c4_resume_stopped_hits} hits)"
  fi

  # The call-site copy (env_file="$_UP_PLACEHOLDER_ENV_FILE") is part of the
  # change, not implied by the resolver call alone (D2f) — without it, the
  # resolver's global write is dead code and Case 1-2's driver-replicated
  # behavior would NOT reflect what rc's real create path actually does.
  # Assert the literal copy line appears between the call site and the real
  # _up_prepare_environment call.
  _c4_copyback_hits=$(sed -n "${_c4_call_line},${_c4_prepare_env_line}p" "$RC" | grep -c 'env_file="\$_UP_PLACEHOLDER_ENV_FILE"' || true)
  if [[ "${_c4_copyback_hits:-0}" -eq 0 ]]; then
    _c4_ok=false; _c4_reason="${_c4_reason:+$_c4_reason; }call-site copy (env_file=\"\$_UP_PLACEHOLDER_ENV_FILE\") missing between resolver call and _up_prepare_environment"
  fi
fi

if [[ "$_c4_ok" == "true" ]]; then
  pass "Case 4 phase-awareness: _up_resolve_placeholder_env_file invoked exactly once, in the create region before _up_prepare_environment, absent from dry-run + both resume branches"
else
  fail "Case 4 phase-awareness" "$_c4_reason"
fi

echo ""
echo "--- Case 5: neither key nor flag (positive control) ---"
setup_p_sandbox
_c5_stderr=$(mktemp)
_c5_out=$(run_placeholder_driver "$P_TEST_WS" "" "$_c5_stderr")
_c5_exit=$?
if [[ "$_c5_exit" -eq 0 ]] && ! echo "$_c5_out" | grep -q -- "--env-file"; then
  pass "Case 5 neither key nor flag: no --env-file in _UP_RUN_ARGS (positive control)"
else
  fail "Case 5 neither key nor flag" "exit=$_c5_exit out='$_c5_out' stderr=$(cat "$_c5_stderr")"
fi
rm -f "$_c5_stderr"
teardown_p_sandbox

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
