#!/usr/bin/env bash
# tests/test-up-run-args-e2e.sh — rip-cage-9oyh §3(i) end-to-end test (the
# CRITICAL, higher-fidelity companion to test-up-run-args-full-chain.sh).
#
# Drives a REAL `rc --output json up <fixture>` through the content-keyed
# fake docker + fake msb (tests/golden-master/lib/fake-bin/{docker,msb} —
# see those files for the full CONTENT-KEYED contract). Per harness spec
# §3(i) rev.2: the shims respond by WHAT is inspected/created, never by
# call-order position -- so this test is robust to the decomposition
# reordering or adding/removing docker/msb calls, as long as their CONTENT
# is unchanged. `--output json` pins the JSON branch's `json_error` ->
# `exit 1` (rc:2005-2015/71) so `msb create` failing (the shim's `create`
# handler always exits 1 after capturing argv, mirroring the pre-migration
# `docker run` shim's same deterministic-failure design) terminates
# deterministically.
#
# rip-cage-5iti (S10, msb migration test-suite port): retargeted from
# capturing `docker run`'s argv onto capturing `msb create`'s argv --
# rip-cage-rj68 (S6) rewrote _up_start_container onto
# `msb create --name NAME --log-level trace <flags...> IMAGE` (cli/up.sh)
# -- `docker run` is no longer on cmd_up's create-path call graph at all.
# `msb create` has no trailing command argument the way `docker run ...
# IMAGE sleep infinity` did (an msb sandbox's persistent-background boot is
# msb's own responsibility, not a caller-supplied keep-alive command), so
# the old "argv ends in sleep infinity" completion proof is retargeted to
# "argv ends in the image name" (the actual last positional arg
# _up_start_container appends) -- still proves the chain wasn't truncated
# mid-build, just against the real post-migration call shape.
#
# Wired into tests/run-host.sh (host-only tier — no live docker/msb daemon
# needed; the fake binaries on PATH replace the real ones entirely).

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
# content-keyed docker+msb shims, configured so cmd_up takes the CREATE
# (new-sandbox) path: msb inspect -> absent (GM_DOCKER_STATE unset = shim
# default "absent"), bare `docker image inspect` -> success, version
# inspect -> matches RC_VERSION (image current, no provisioning branch).
# Sets RC_OUT/RC_ERR/RC_EXIT/RUN_CAPTURE (path to the captured `msb create`
# argv, one arg per line — empty/absent if `msb create` was never reached).
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
    GM_MSB_CREATE_CAPTURE="$RUN_CAPTURE" \
    "$RC" --output json up "$TEST_WS" >"$_outfile" 2>"$_errfile" < /dev/null
  RC_EXIT=$?
  set -e 2>/dev/null || true
  set +e
  RC_OUT=$(cat "$_outfile")
  RC_ERR=$(cat "$_errfile")
  rm -f "$_outfile" "$_errfile"
}

# ---------------------------------------------------------------------------
# E1: the create path reaches `msb create` (proves the full argv-assembly
# chain rc:5136->5408->_up_start_container:5410 actually executes end to
# end through the REAL cmd_up, not a hand-replica).
# ---------------------------------------------------------------------------
setup_sandbox
run_real_up

if [[ -f "$RUN_CAPTURE" ]]; then
  pass "E1: real cmd_up reaches 'msb create' (content-keyed shim captured the argv)"
else
  fail "E1: msb create reached" "no capture file written -- cmd_up never called 'msb create'. stdout=$RC_OUT stderr=$RC_ERR"
fi

# ---------------------------------------------------------------------------
# E2: `--output json`'s json_error -> exit 1 fires deterministically (the
# shim's `msb create` always exits 1 after capturing argv -- §3(i) F2).
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
# E3: the captured argv ends in the image name (proves the FULL chain ran
# -- an early abort would leave the capture file absent, already caught by
# E1; this additionally proves the array wasn't truncated mid-build).
# rip-cage-5iti (S10): `msb create` has no trailing command argument the
# way `docker run ... IMAGE sleep infinity` did -- an msb sandbox's
# persistent-background boot is msb's own responsibility, not a
# caller-supplied keep-alive command (_up_start_container's own call:
# `msb create --name NAME --log-level trace <flags...> IMAGE`, IMAGE is the
# LAST positional arg, no tail after it).
# ---------------------------------------------------------------------------
if [[ -f "$RUN_CAPTURE" ]] && [[ "$(tail -1 "$RUN_CAPTURE" 2>/dev/null)" == "rip-cage:latest" ]]; then
  pass "E3: captured msb-create argv ends in the expected image name"
else
  fail "E3: argv completeness" "captured argv does not end in 'rip-cage:latest': $(cat "$RUN_CAPTURE" 2>/dev/null)"
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
  pass "E4: captured msb-create argv is deterministic across independent runs"
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
