#!/usr/bin/env bash
# tests/test-up-run-args-e2e.sh — rip-cage-9oyh §3(i) end-to-end test (the
# CRITICAL, higher-fidelity companion to test-up-run-args-full-chain.sh).
#
# Drives a REAL `rc --output json up <fixture>` through the content-keyed
# fake docker (tests/golden-master/lib/fake-bin/docker — see that file for
# the full CONTENT-KEYED contract). Per harness spec §3(i) rev.2: the shim
# responds by WHAT is inspected/run, never by call-order position -- so this
# test is robust to the decomposition reordering or adding/removing docker
# calls, as long as their CONTENT is unchanged. `--output json` pins the
# JSON branch's `json_error` -> `exit 1` (rc:2005-2015/71) so `docker run`
# failing (the shim's `run` handler always exits 1 after capturing argv)
# terminates deterministically -- the review VERIFIED the full _UP_RUN_ARGS
# argv is assembled at rc:5408 with NO intervening docker call before
# `_up_start_container` (rc:5410) reaches `docker run`.
#
# Wired into tests/run-host.sh (host-only tier — no live docker container
# needed; the fake docker on PATH replaces the real binary entirely).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
GM_FAKEBIN="${SCRIPT_DIR}/golden-master/lib/fake-bin"
# shellcheck source=golden-master/lib/scrub.sh
source "${SCRIPT_DIR}/golden-master/lib/scrub.sh"
FAILURES=0
TEST_HOME=""
TEST_WS=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

unset RC_CONFIG_GLOBAL

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  return 0
}
trap cleanup EXIT

setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-up-args-e2e-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
  touch "${TEST_HOME}/.config/rip-cage/tools.yaml"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" TEST_WS=""
}

# run_real_up — drives the REAL `rc --output json up $TEST_WS` through the
# content-keyed docker shim, configured so cmd_up takes the CREATE
# (new-container) path: `.State.Status` -> absent (GM_DOCKER_STATE unset =
# shim default "absent"), bare `docker image inspect` -> success, version
# inspect -> matches RC_VERSION (image current, no provisioning branch).
# Sets RC_OUT/RC_ERR/RC_EXIT/RUN_CAPTURE (path to the captured docker-run
# argv, one arg per line — empty/absent if `docker run` was never reached).
RC_OUT="" RC_ERR="" RC_EXIT=0 RUN_CAPTURE=""
run_real_up() {
  RUN_CAPTURE=$(mktemp "${TMPDIR:-/tmp}/rc-up-args-e2e-capture-XXXXXX")
  rm -f "$RUN_CAPTURE"  # shim appends; start absent so "never reached" is detectable
  local _outfile _errfile
  _outfile=$(mktemp) _errfile=$(mktemp)
  set +e
  PATH="${GM_FAKEBIN}:${PATH}" \
    HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="$TEST_WS" \
    GM_DOCKER_IMAGE_VERSION="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo unknown)" \
    GM_DOCKER_RUN_CAPTURE="$RUN_CAPTURE" \
    "$RC" --output json up "$TEST_WS" >"$_outfile" 2>"$_errfile" < /dev/null
  RC_EXIT=$?
  set -e 2>/dev/null || true
  set +e
  RC_OUT=$(cat "$_outfile")
  RC_ERR=$(cat "$_errfile")
  rm -f "$_outfile" "$_errfile"
}

# ---------------------------------------------------------------------------
# E1: the create path reaches `docker run` (proves the full argv-assembly
# chain rc:5136->5408->_up_start_container:5410 actually executes end to
# end through the REAL cmd_up, not a hand-replica).
# ---------------------------------------------------------------------------
setup_sandbox
run_real_up

if [[ -f "$RUN_CAPTURE" ]]; then
  pass "E1: real cmd_up reaches 'docker run' (content-keyed shim captured the argv)"
else
  fail "E1: docker run reached" "no capture file written -- cmd_up never called 'docker run'. stdout=$RC_OUT stderr=$RC_ERR"
fi

# ---------------------------------------------------------------------------
# E2: `--output json`'s json_error -> exit 1 fires deterministically (the
# shim's `docker run` always exits 1 after capturing argv -- §3(i) F2).
# ---------------------------------------------------------------------------
if [[ "$RC_EXIT" -eq 1 ]]; then
  pass "E2: rc exits 1 (json_error -> exit 1 termination, per §3(i) F2)"
else
  fail "E2: deterministic exit 1" "expected exit 1, got $RC_EXIT. stdout=$RC_OUT stderr=$RC_ERR"
fi

if echo "$RC_OUT" | grep -q '"code"'; then
  pass "E2b: stdout carries a structured JSON error (\"code\" field)"
else
  fail "E2b: structured JSON error" "stdout did not contain a \"code\" field: $RC_OUT"
fi

# ---------------------------------------------------------------------------
# E3: the captured argv contains the expected image+cmd tail (proves the
# FULL chain ran -- an early abort would leave the capture file absent,
# already caught by E1; this additionally proves the array wasn't truncated
# mid-build).
# ---------------------------------------------------------------------------
if [[ -f "$RUN_CAPTURE" ]] && grep -qF "sleep" "$RUN_CAPTURE" && grep -qF "infinity" "$RUN_CAPTURE"; then
  pass "E3: captured docker-run argv ends in the expected image+cmd append"
else
  fail "E3: argv completeness" "captured argv missing the 'sleep infinity' tail: $(cat "$RUN_CAPTURE" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# E4: determinism -- two independent runs (fresh mktemp sandbox each) yield
# the same captured argv after scrubbing the per-run TEST_HOME path. Reuses
# lib/scrub.sh's `gm_scrub_root_script` (realpath-before-nominal, raw AND
# `tr '/.' '-'`-slugified forms -- the RC_HOST_PROJECT_KEY seam) rather than
# a bespoke regex: a private regex here previously only stripped the
# mktemp-random SUFFIX, leaving the ABSOLUTE TMPDIR PREFIX (machine/CI-
# specific, e.g. macOS /var/folders/... vs Linux /tmp) baked into the
# recorded snapshot -- false-RED on any host whose TMPDIR differs from the
# one that recorded it (2026-07-08 adversarial-review Finding 1). Must be
# called while $TEST_HOME still exists (realpath resolution needs the dir),
# i.e. BEFORE teardown_sandbox.
# ---------------------------------------------------------------------------
RUN1_ARGV=$(cat "$RUN_CAPTURE" 2>/dev/null | sed -E -e "$(gm_scrub_root_script "$TEST_HOME" "TEST_HOME" true)")
teardown_sandbox

setup_sandbox
run_real_up
RUN2_ARGV=$(cat "$RUN_CAPTURE" 2>/dev/null | sed -E -e "$(gm_scrub_root_script "$TEST_HOME" "TEST_HOME" true)")
teardown_sandbox

if [[ -n "$RUN1_ARGV" && "$RUN1_ARGV" == "$RUN2_ARGV" ]]; then
  pass "E4: captured docker-run argv is deterministic across independent runs"
else
  fail "E4: argv determinism" "argv differs between two independent runs:
$(diff <(printf '%s\n' "$RUN1_ARGV") <(printf '%s\n' "$RUN2_ARGV"))"
fi

# ---------------------------------------------------------------------------
# E5: byte-identity net against a recorded golden snapshot (what the
# decomposition bead diffs against). `--record` writes it.
# ---------------------------------------------------------------------------
SNAPSHOT="${SCRIPT_DIR}/golden-master/snapshots/up-run-args-e2e.argv"
if [[ "${1:-}" == "--record" ]]; then
  mkdir -p "$(dirname "$SNAPSHOT")"
  printf '%s' "$RUN1_ARGV" > "$SNAPSHOT"
  echo "RECORDED: $SNAPSHOT"
elif [[ ! -f "$SNAPSHOT" ]]; then
  fail "E5: golden snapshot" "no recorded snapshot at $SNAPSHOT -- run: bash $0 --record"
else
  EXPECTED=$(cat "$SNAPSHOT")
  if [[ "$RUN1_ARGV" == "$EXPECTED" ]]; then
    pass "E5: captured docker-run argv matches the recorded golden snapshot"
  else
    fail "E5: golden snapshot match" "argv differs from the recorded baseline:
$(diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$RUN1_ARGV"))"
  fi
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
