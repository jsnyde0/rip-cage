#!/usr/bin/env bash
# test-multiplexer-fixed-at-create.sh — host-tier tests for rip-cage-1yqa:
# the multiplexer is a creation-time property of a cage. rc stamps
# RC_MULTIPLEXER into the cage env and the rc.session.multiplexer label at
# `msb create`; a later `rc up` with a DIFFERENT RC_MULTIPLEXER used to be a
# silent no-op that reported the stored value. It must now refuse before any
# msb start/exec, naming the stored value and the exact --replace command.
#
# Drives the REAL `rc up` through fake msb + fake docker on PATH (same
# harness shape as tests/test-image-drift-resume.sh). Every msb argv is
# logged, one line per call, so "no start/exec" and the create argv are
# asserted directly. The fixture multiplexer is 'fakemux' — rc names no
# multiplexer itself (ADR-005 D12).
#
#   M1  stopped cage labelled none + RC_MULTIPLEXER=fakemux -> non-zero,
#       no msb start/exec, stderr names 'none' and the --replace command
#   M1b same, --output json -> stable code MULTIPLEXER_FIXED_AT_CREATE
#   M1c same on a RUNNING cage -> refused, no msb exec
#   M1d stopped cage whose config CHANGED (stored rc.cage-conf-sha stale, so
#       the converge recreate is due) + RC_MULTIPLEXER=fakemux -> refused, no
#       msb start/exec/create. Before f35a9d5 the converge recreate carried
#       the new value; that path now needs --replace (review, rip-cage-1yqa).
#   M1e control for M1d: same stale hash, RC_MULTIPLEXER unset -> the
#       converge recreate runs (msb remove + create), so M1d's fixture really
#       reaches the converge branch
#   M2  running cage labelled fakemux, RC_MULTIPLEXER unset -> proceeds,
#       reports multiplexer=fakemux (today's behaviour)
#   M2b RC_MULTIPLEXER equal to the stored label -> proceeds
#   M3  RC_MULTIPLEXER=fakemux rc up --replace on a cage labelled none ->
#       msb create carries -e RC_MULTIPLEXER=fakemux and the fakemux label

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"

FAILURES=0
pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2 -- ${3:-}"; FAILURES=$((FAILURES + 1)); }

_real_version=$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo "unknown")
STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-mux-stub-XXXXXX")
TEST_HOME=""
TEST_WS=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -rf "$STUB_DIR" "${TEST_HOME:-}"; }
trap cleanup EXIT

# Fake msb. MUX_STATE: exited|running|absent. MUX_LABEL: the cage's stored
# rc.session.multiplexer. MUX_CONF_SHA, when set, is the stored
# rc.cage-conf-sha. After `remove`, the cage reads absent (--replace).
cat > "${STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${MUX_LOG}"
case "${1:-}" in
  --version) echo "microsandbox 0.7.4 (fake)"; exit 0 ;;
  inspect)
    if [[ "${MUX_STATE:-}" == "absent" || -f "${MUX_LOG}.removed" ]]; then
      echo "Error: no such sandbox: ${2:-}" >&2; exit 1
    fi
    _status="Stopped"; [[ "${MUX_STATE:-}" == "running" ]] && _status="Running"
    jq -nc --arg status "$_status" --arg ws "${MUX_WORKSPACE:-}" --arg mux "${MUX_LABEL:-none}" \
      --arg sha "${MUX_CONF_SHA:-}" \
      '{status: $status, config: {manifest_digest: "sha256:aaaa", labels: ({"rc.source.path": $ws, "rc.session.multiplexer": $mux}
        + (if $sha == "" then {} else {"rc.cage-conf-sha": $sha} end))}}'
    exit 0
    ;;
  image)
    [[ "${2:-}" == "list" ]] && { echo '[{"reference":"rip-cage:latest","digest":"sha256:aaaa"}]'; exit 0; }
    exit 1
    ;;
  remove) : > "${MUX_LOG}.removed"; exit 0 ;;
  exec)
    # The attach path reads the in-cage boot descriptor via msb exec.
    [[ "$*" == *boot.json* ]] && { echo '{"multiplexers":[{"name":"fakemux","attach":"true"}]}'; exit 0; }
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_DIR}/msb"

# Fake docker: image present and version-current; `docker run ... boot.json`
# answers with a descriptor declaring fakemux, so the image-carries-it
# preflight passes and the create-time/existing-cage logic is what's tested.
cat > "${STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  run) echo '{"multiplexers":[{"name":"fakemux"}]}'; exit 0 ;;
  image)
    case "\$*" in
      *version*) echo "${_real_version}"; exit 0 ;;
      *RootFS.Layers*) echo '[]'; exit 0 ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_DIR}/docker"

setup_ws() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-mux-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  mkdir -p "${TEST_HOME}/workspace"
  TEST_WS=$(cd "${TEST_HOME}/workspace" && pwd -P)
}
teardown_ws() { rm -rf "$TEST_HOME"; TEST_HOME="" TEST_WS=""; }

# run_up STATE LABEL [up flags...] — RC_MULTIPLEXER and RC_GLOBAL_FLAGS
# (e.g. "--output json") come from the caller's env.
RC_OUT="" RC_ERR="" RC_EXIT=0 RC_LOG=""
run_up() {
  local _state="$1" _label="$2"; shift 2
  RC_LOG=$(mktemp "${TMPDIR:-/tmp}/rc-mux-log-XXXXXX")
  local _o _e; _o=$(mktemp) _e=$(mktemp)
  local -a _g=(); read -r -a _g <<<"${RC_GLOBAL_FLAGS:-}"
  PATH="${STUB_DIR}:${PATH}" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CAGE_CONF="$(cage_conf_for "$TEST_WS")" \
    MUX_LOG="$RC_LOG" MUX_STATE="$_state" MUX_LABEL="$_label" MUX_WORKSPACE="$TEST_WS" \
    "$RC" ${_g[@]+"${_g[@]}"} up "$@" "$TEST_WS" >"$_o" 2>"$_e" </dev/null
  RC_EXIT=$?
  RC_OUT=$(cat "$_o"); RC_ERR=$(cat "$_e"); rm -f "$_o" "$_e"
}
no_start_or_exec() { ! grep -qE '^(start|exec|create)( |$)' "$RC_LOG"; }

# --- M1: stopped, label none, RC_MULTIPLEXER=fakemux -> refused ------------
setup_ws
RC_MULTIPLEXER=fakemux run_up exited none
if [[ "$RC_EXIT" -ne 0 ]] && no_start_or_exec \
   && grep -qF "created with multiplexer 'none'" <<<"$RC_ERR" \
   && grep -qF "RC_MULTIPLEXER=fakemux rc up --replace /" <<<"$RC_ERR"; then
  pass M1 "stopped cage labelled none + RC_MULTIPLEXER=fakemux -> refused before start/exec, names 'none' and the --replace command"
else
  fail M1 "stopped mismatch refusal" "exit=$RC_EXIT log=$(tr '\n' ';' <"$RC_LOG") stderr=$RC_ERR"
fi
teardown_ws

# --- M1b: same, JSON -> stable error code ---------------------------------
setup_ws
RC_GLOBAL_FLAGS="--output json" RC_MULTIPLEXER=fakemux run_up exited none
if [[ "$RC_EXIT" -ne 0 ]] && no_start_or_exec \
   && [[ "$(jq -r '.code' <<<"$RC_OUT" 2>/dev/null)" == "MULTIPLEXER_FIXED_AT_CREATE" ]]; then
  pass M1b "JSON mode -> code MULTIPLEXER_FIXED_AT_CREATE, no start/exec"
else
  fail M1b "JSON mismatch refusal" "exit=$RC_EXIT stdout=$RC_OUT"
fi
teardown_ws

# --- M1c: running cage -> refused too, no exec ----------------------------
setup_ws
RC_MULTIPLEXER=fakemux run_up running none
if [[ "$RC_EXIT" -ne 0 ]] && no_start_or_exec \
   && grep -qF "created with multiplexer 'none'" <<<"$RC_ERR"; then
  pass M1c "running cage labelled none + RC_MULTIPLEXER=fakemux -> refused, no exec"
else
  fail M1c "running mismatch refusal" "exit=$RC_EXIT log=$(tr '\n' ';' <"$RC_LOG") stderr=$RC_ERR"
fi
teardown_ws

# --- M1d: stopped + changed config (converge due) + differing value -------
setup_ws
MUX_CONF_SHA=stale-sha RC_MULTIPLEXER=fakemux run_up exited none
if [[ "$RC_EXIT" -ne 0 ]] && no_start_or_exec \
   && ! grep -qE '^remove( |$)' "$RC_LOG" \
   && grep -qF "created with multiplexer 'none'" <<<"$RC_ERR" \
   && grep -qF "RC_MULTIPLEXER=fakemux rc up --replace /" <<<"$RC_ERR"; then
  pass M1d "stopped cage with a changed config + RC_MULTIPLEXER=fakemux -> refused before converge, no remove/start/exec/create"
else
  fail M1d "converge-path mismatch refusal" "exit=$RC_EXIT log=$(tr '\n' ';' <"$RC_LOG") stderr=$RC_ERR"
fi
rm -f "${RC_LOG}.removed"
teardown_ws

# --- M1e: control -- same fixture, RC_MULTIPLEXER unset -> converge runs ----
setup_ws
(unset RC_MULTIPLEXER; MUX_CONF_SHA=stale-sha run_up exited none; cp "$RC_LOG" "${TEST_HOME}/log"; rm -f "${RC_LOG}.removed")
if grep -qE '^remove( |$)' "${TEST_HOME}/log" && grep -qE '^create( |$)' "${TEST_HOME}/log"; then
  pass M1e "control: stale config hash, RC_MULTIPLEXER unset -> converge recreate runs (remove + create)"
else
  fail M1e "converge control" "log=$(tr '\n' ';' <"${TEST_HOME}/log")"
fi
teardown_ws

# --- M2: unset on a cage labelled fakemux -> today's behaviour ------------
setup_ws
(unset RC_MULTIPLEXER; run_up running fakemux; echo "$RC_EXIT" >"${TEST_HOME}/exit"; printf '%s\n%s' "$RC_OUT" "$RC_ERR" >"${TEST_HOME}/out")
_m2_exit=$(cat "${TEST_HOME}/exit"); _m2_out=$(cat "${TEST_HOME}/out")
if ! grep -q "MULTIPLEXER_FIXED_AT_CREATE\|created with multiplexer" <<<"$_m2_out" \
   && grep -q "multiplexer=fakemux" <<<"$_m2_out"; then
  pass M2 "RC_MULTIPLEXER unset on a cage labelled fakemux -> no refusal, reports multiplexer=fakemux"
else
  fail M2 "unset keeps stored value" "exit=$_m2_exit out=$_m2_out"
fi
teardown_ws

# --- M2b: RC_MULTIPLEXER equal to the stored label -> no refusal ----------
setup_ws
RC_MULTIPLEXER=fakemux run_up running fakemux
if ! grep -q "created with multiplexer" <<<"$RC_ERR" && grep -q "multiplexer=fakemux" <<<"$RC_OUT$RC_ERR"; then
  pass M2b "RC_MULTIPLEXER equal to the stored label -> proceeds"
else
  fail M2b "matching value proceeds" "exit=$RC_EXIT out=$RC_OUT err=$RC_ERR"
fi
teardown_ws

# --- M3: --replace recreates with the requested multiplexer ---------------
setup_ws
RC_MULTIPLEXER=fakemux run_up exited none --replace
_m3_create=$(grep -E '^create( |$)' "$RC_LOG" || true)
if ! grep -q "created with multiplexer" <<<"$RC_ERR" \
   && grep -qF -- "-e RC_MULTIPLEXER=fakemux" <<<"$_m3_create" \
   && grep -qF -- "--label rc.session.multiplexer=fakemux" <<<"$_m3_create"; then
  pass M3 "RC_MULTIPLEXER=fakemux rc up --replace -> msb create carries the fakemux env and label"
else
  fail M3 "--replace honours RC_MULTIPLEXER" "exit=$RC_EXIT create=[$_m3_create] log=$(tr '\n' ';' <"$RC_LOG") stderr=$RC_ERR"
fi
rm -f "${RC_LOG}.removed"
teardown_ws

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
