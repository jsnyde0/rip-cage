#!/usr/bin/env bash
# test-multiplexer-default-at-create.sh — host-tier tests for rip-cage-sfo3:
# when RC_MULTIPLEXER is unset at create time, rc up defaults to the SOLE
# multiplexer the image's boot descriptor declares, instead of none. rc names
# no multiplexer itself (ADR-005 D12): the fixture names are 'fakemux' and
# 'othermux', and the default is whatever the descriptor declares.
#
# Drives the REAL `rc up` through fake msb + fake docker on PATH (same harness
# shape as tests/test-multiplexer-fixed-at-create.sh). The fake docker answers
# the boot-descriptor read with $MUX_DECLARED_JSON, so each case sets what the
# image declares; the msb create argv is asserted directly from the msb log.
#
#   D1  one declared, RC_MULTIPLEXER unset -> create carries fakemux env +
#       label, and a log line names the choice and the RC_MULTIPLEXER=none
#       override
#   D2  two declared, unset -> create carries none, stderr names both
#   D3  none declared, unset -> create carries none, no default line
#   D4  one declared, RC_MULTIPLEXER=none -> create carries none (override)
#   D5  converge recreate (stopped cage, stale config hash) of a cage labelled
#       none on an image declaring one -> recreate keeps none: the value is
#       fixed at create (rip-cage-1yqa), the default never flips a cage
#   D6  converge recreate of a cage labelled fakemux, unset -> recreate keeps
#       fakemux
#   D7  rc up --replace of a cage labelled none, one declared, unset ->
#       recreate keeps none (only an explicit RC_MULTIPLEXER=<x> changes it)
#   D8  rc up --replace of a cage labelled fakemux, unset -> keeps fakemux
#   D9  converge of a cage labelled fakemux on an image declaring none ->
#       refused before any stop/remove/start/exec/create (rip-cage-7njt), the
#       message names the stored value, the declared set and the --replace hint

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
STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-muxdef-stub-XXXXXX")
TEST_HOME=""
TEST_WS=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -rf "$STUB_DIR" "${TEST_HOME:-}"; }
trap cleanup EXIT

ONE='{"multiplexers":[{"name":"fakemux","attach":"true"}]}'
TWO='{"multiplexers":[{"name":"fakemux","attach":"true"},{"name":"othermux","attach":"true"}]}'
ZERO='{}'

# Fake msb. MUX_STATE: exited|absent. MUX_LABEL: the stored
# rc.session.multiplexer. MUX_CONF_SHA, when set, is the stored
# rc.cage-conf-sha. After `remove`, the cage reads absent.
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
    jq -nc --arg ws "${MUX_WORKSPACE:-}" --arg mux "${MUX_LABEL:-none}" --arg sha "${MUX_CONF_SHA:-}" \
      '{status: "Stopped", config: {manifest_digest: "sha256:aaaa", labels: ({"rc.source.path": $ws, "rc.session.multiplexer": $mux}
        + (if $sha == "" then {} else {"rc.cage-conf-sha": $sha} end))}}'
    exit 0
    ;;
  image)
    [[ "${2:-}" == "list" ]] && { echo '[{"reference":"rip-cage:latest","digest":"sha256:aaaa"}]'; exit 0; }
    exit 1
    ;;
  remove) : > "${MUX_LOG}.removed"; exit 0 ;;
  exec)
    [[ "$*" == *boot.json* ]] && { echo "${MUX_DECLARED_JSON}"; exit 0; }
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_DIR}/msb"

cat > "${STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  run) echo "\${MUX_DECLARED_JSON}"; exit 0 ;;
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
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-muxdef-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage" "${TEST_HOME}/workspace"
  TEST_WS=$(cd "${TEST_HOME}/workspace" && pwd -P)
}
teardown_ws() { rm -rf "$TEST_HOME"; TEST_HOME="" TEST_WS=""; }

# run_up STATE LABEL DECLARED_JSON [up flags...] — RC_MULTIPLEXER and
# MUX_CONF_SHA come from the caller's env. Unset RC_MULTIPLEXER in a subshell
# around the call for the unset cases.
RC_OUT="" RC_ERR="" RC_EXIT=0 RC_LOG="" CREATE=""
run_up() {
  local _state="$1" _label="$2" _decl="$3"; shift 3
  RC_LOG=$(mktemp "${TMPDIR:-/tmp}/rc-muxdef-log-XXXXXX")
  local _o _e; _o=$(mktemp) _e=$(mktemp)
  PATH="${STUB_DIR}:${PATH}" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CAGE_CONF="$(cage_conf_for "$TEST_WS")" \
    MUX_LOG="$RC_LOG" MUX_STATE="$_state" MUX_LABEL="$_label" MUX_WORKSPACE="$TEST_WS" \
    MUX_DECLARED_JSON="$_decl" \
    "$RC" up "$@" "$TEST_WS" >"$_o" 2>"$_e" </dev/null
  RC_EXIT=$?
  RC_OUT=$(cat "$_o"); RC_ERR=$(cat "$_e"); rm -f "$_o" "$_e"
  CREATE=$(grep -E '^create( |$)' "$RC_LOG" || true)
  rm -f "${RC_LOG}.removed"
}
# save/load carry a subshell's results out to the parent.
save() { { echo "$RC_EXIT"; echo "$CREATE"; } >"${TEST_HOME}/res"; printf '%s\n%s' "$RC_OUT" "$RC_ERR" >"${TEST_HOME}/out"; }
load() { RC_EXIT=$(sed -n 1p "${TEST_HOME}/res"); CREATE=$(sed -n 2p "${TEST_HOME}/res"); RC_ALL=$(cat "${TEST_HOME}/out"); }
creates_with() { grep -qF -- "-e RC_MULTIPLEXER=$1" <<<"$CREATE" && grep -qF -- "--label rc.session.multiplexer=$1" <<<"$CREATE"; }

# --- D1: one declared, unset -> the sole declared multiplexer --------------
setup_ws
(unset RC_MULTIPLEXER; run_up absent none "$ONE"; save); load
if creates_with fakemux \
   && grep -q "multiplexer: fakemux" <<<"$RC_ALL" \
   && grep -qF "RC_MULTIPLEXER=none" <<<"$RC_ALL"; then
  pass D1 "one declared, RC_MULTIPLEXER unset -> create carries fakemux; log names the choice and the RC_MULTIPLEXER=none override"
else
  fail D1 "sole declared becomes the default" "exit=$RC_EXIT create=[$CREATE] out=$RC_ALL"
fi
teardown_ws

# --- D2: two declared, unset -> none, names what is declared ---------------
setup_ws
(unset RC_MULTIPLEXER; run_up absent none "$TWO"; save); load
if creates_with none && grep -qF "fakemux, othermux" <<<"$RC_ALL"; then
  pass D2 "two declared, unset -> create carries none; output names fakemux, othermux"
else
  fail D2 "two declared stays none" "exit=$RC_EXIT create=[$CREATE] out=$RC_ALL"
fi
teardown_ws

# --- D3: none declared, unset -> none --------------------------------------
setup_ws
(unset RC_MULTIPLEXER; run_up absent none "$ZERO"; save); load
if creates_with none && ! grep -q "declares" <<<"$RC_ALL"; then
  pass D3 "none declared, unset -> create carries none, no default line"
else
  fail D3 "none declared stays none" "exit=$RC_EXIT create=[$CREATE] out=$RC_ALL"
fi
teardown_ws

# --- D4: one declared, explicit none -> none -------------------------------
setup_ws
RC_MULTIPLEXER=none run_up absent none "$ONE"
if creates_with none; then
  pass D4 "one declared, RC_MULTIPLEXER=none -> create carries none (explicit override)"
else
  fail D4 "explicit none overrides" "exit=$RC_EXIT create=[$CREATE] out=$RC_OUT err=$RC_ERR"
fi
teardown_ws

# --- D5: converge of a none cage keeps none --------------------------------
setup_ws
(unset RC_MULTIPLEXER; MUX_CONF_SHA=stale-sha run_up exited none "$ONE"; save); load
if [[ -n "$CREATE" ]] && creates_with none; then
  pass D5 "converge recreate of a cage labelled none, one declared, unset -> keeps none (fixed at create)"
else
  fail D5 "converge keeps stored none" "exit=$RC_EXIT create=[$CREATE] out=$RC_ALL"
fi
teardown_ws

# --- D6: converge of a fakemux cage keeps fakemux --------------------------
setup_ws
(unset RC_MULTIPLEXER; MUX_CONF_SHA=stale-sha run_up exited fakemux "$TWO"; save); load
if [[ -n "$CREATE" ]] && creates_with fakemux; then
  pass D6 "converge recreate of a cage labelled fakemux, unset -> keeps fakemux"
else
  fail D6 "converge keeps stored fakemux" "exit=$RC_EXIT create=[$CREATE] out=$RC_ALL"
fi
teardown_ws

# --- D7: --replace of a none cage keeps none -------------------------------
setup_ws
(unset RC_MULTIPLEXER; run_up exited none "$ONE" --replace; save); load
if [[ -n "$CREATE" ]] && creates_with none; then
  pass D7 "--replace of a cage labelled none, one declared, unset -> keeps none"
else
  fail D7 "--replace keeps stored none" "exit=$RC_EXIT create=[$CREATE] out=$RC_ALL"
fi
teardown_ws

# --- D8: --replace of a fakemux cage keeps fakemux -------------------------
setup_ws
(unset RC_MULTIPLEXER; run_up exited fakemux "$TWO" --replace; save); load
if [[ -n "$CREATE" ]] && creates_with fakemux; then
  pass D8 "--replace of a cage labelled fakemux, unset -> keeps fakemux"
else
  fail D8 "--replace keeps stored fakemux" "exit=$RC_EXIT create=[$CREATE] out=$RC_ALL"
fi
teardown_ws

# --- D9: converge, stored mux no longer declared -> refuse -----------------
setup_ws
(unset RC_MULTIPLEXER; MUX_CONF_SHA=stale-sha run_up exited fakemux "$ZERO"; save
 # any mutating msb verb (or exec beyond the descriptor read) is a failure
 grep -E '^(stop|remove|start|create|run)( |$)|^exec ' "$RC_LOG" | grep -v boot.json >"${TEST_HOME}/mut" || true); load
if [[ "$RC_EXIT" != 0 && -z "$CREATE" && ! -s "${TEST_HOME}/mut" ]] \
   && grep -qF "fakemux" <<<"$RC_ALL" && grep -qF "(none)" <<<"$RC_ALL" \
   && grep -qF "rc up --replace" <<<"$RC_ALL"; then
  pass D9 "converge of a cage labelled fakemux, image declares none -> refused before any msb stop/remove/start/exec/create, with the --replace hint"
else
  fail D9 "converge refuses a stored mux the image dropped" "exit=$RC_EXIT create=[$CREATE] mut=[$(cat "${TEST_HOME}/mut" 2>/dev/null)] out=$RC_ALL"
fi
teardown_ws

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
