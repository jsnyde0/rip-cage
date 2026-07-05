#!/usr/bin/env bash
# test-image-drift-resume.sh — Host-tier tests for rip-cage-jnvb: `rc up`
# blind-resuming a stopped container pinned to a stale image after `rc build`
# (crash mechanism: new resume logic, e.g. mediator init, docker-execs a
# file baked into the NEW image but absent from the OLD container's fs ->
# raw OCI stat crash + self-stop).
#
# Design-of-record: bd show rip-cage-jnvb (decisions D-a through D-g).
#
# Coverage matrix (see the bead's "## Harness target" for the full spec):
#   T1  stopped container + mismatched image IDs -> rc up aborts BEFORE
#       docker start, non-zero exit, message names container + both short
#       IDs + destroy/re-up + RC_IMAGE remedies, no other override promised
#   T2  stopped container + matching image IDs -> resume proceeds unchanged
#       (docker start IS reached)
#   T3  running container + mismatched image IDs -> warn on stderr, proceeds,
#       exit 0 (no crash path on the running branch — D-c)
#   T4  rc build with a stale-pinned container present -> post-build warning
#       names it (isolated _build_warn_stale_containers call — build itself
#       is stubbed per the Harness target's explicit T4 allowance)
#   T5  current image ($IMAGE) absent at resume -> abort loud (rc build /
#       RC_IMAGE / destroy remedies), NOT fail-open (D-f, revised R1)
#   T6  `rc up --dry-run` on a drifted stopped container -> same hard stop
#       surfaces on the would_resume path
#   T7  (post-review M2 hardening) running container + the CONTAINER's own
#       image-inspect call fails transiently (TOCTOU-ish race) -> warn on
#       stderr, proceeds, exit 0 — never abort a live-session attach on a
#       transient inspect failure (D-c)
#
# END-TO-END REQUIREMENT (R1 finding 2, load-bearing): T1-T3 and T5-T7 drive
# the REAL `rc up` / cmd_up path through a fake-docker PATH shim that logs
# every docker argv (top-level verb only) to a file — NOT the isolated-
# resolver idiom (sourcing rc and calling the resolver directly). This proves
# the guard is actually WIRED into cmd_up before docker start, not just that
# the resolver function itself is correct in isolation. Reference technique:
# tests/test-docker-daemon-hang.sh (full-rc-through-shim) and the docker
# PATH-shim idiom from tests/test-credential-mounts.sh (CM8-CM10).
#
# Wired into tests/run-host.sh (host-only tier — no live docker container
# needed; the fake docker on PATH replaces the real binary entirely).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_HOME=""
TEST_WS=""
STUB_DIR=""

pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2 -- $3"; FAILURES=$((FAILURES + 1)); }

# tests/run-host.sh exports RC_CONFIG_GLOBAL at driver level, which would
# shadow the per-test XDG sandboxes below — unset so per-call XDG_CONFIG_HOME
# wins (mirrors test-credential-mounts.sh / test-mediator-lifecycle.sh).
unset RC_CONFIG_GLOBAL

# shellcheck disable=SC2329
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  [[ -n "${STUB_DIR:-}" && -d "${STUB_DIR:-}" ]] && rm -rf "$STUB_DIR"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fake docker: logs the top-level verb ($1) to $DRIFT_LOG, one per line, so
# the test can assert `start` presence/absence. Behavior configured via env
# vars read at RUNTIME by the stub (set per-invocation by run_rc_up below):
#   DRIFT_STATE                 exited|created|running|absent
#   DRIFT_STORED_IMAGE          sha256:... — the container's pinned image ID
#   DRIFT_CURRENT_IMAGE         sha256:... — the resolved $IMAGE's ID; empty = missing
#   DRIFT_CONTAINER_INSPECT_FAIL "true" — the `.Image}}` format query fails
#     (exit 1) while `.State.Status}}` still succeeds normally. Simulates a
#     transient docker-inspect failure / TOCTOU race (container removed
#     between the state-check and the drift guard) — T7 (M2 review finding).
# Written ONCE; every test reuses it by varying the env vars per call.
# ---------------------------------------------------------------------------
STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-drift-stub-XXXXXX")
cat > "${STUB_DIR}/docker" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "${1:-}" >> "${DRIFT_LOG}"

case "${1:-}" in
  inspect)
    shift
    _fmt="" _name=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format) shift; _fmt="${1:-}"; shift ;;
        *) _name="$1"; shift ;;
      esac
    done
    if [[ "${DRIFT_STATE:-}" == "absent" ]]; then
      echo "Error: No such object: ${_name}" >&2
      exit 1
    fi
    if [[ "$_fmt" == '{{.Image}}' && "${DRIFT_CONTAINER_INSPECT_FAIL:-}" == "true" ]]; then
      echo "Error: No such object: ${_name}" >&2
      exit 1
    fi
    case "$_fmt" in
      '{{.State.Status}}') echo "${DRIFT_STATE:-}"; exit 0 ;;
      '{{.Image}}') echo "${DRIFT_STORED_IMAGE:-}"; exit 0 ;;
      *'"rc.egress"'*) echo "on"; exit 0 ;;
      *json*) echo "[]"; exit 0 ;;
      *) echo ""; exit 0 ;;
    esac
    ;;
  image)
    shift
    if [[ "${1:-}" == "inspect" ]]; then
      shift
      if [[ -z "${DRIFT_CURRENT_IMAGE:-}" ]]; then
        exit 1
      fi
      _fmt=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --format) shift; _fmt="${1:-}"; shift ;;
          *) shift ;;
        esac
      done
      case "$_fmt" in
        '{{.Id}}') echo "${DRIFT_CURRENT_IMAGE:-}"; exit 0 ;;
        *) echo ""; exit 0 ;;
      esac
    fi
    exit 0
    ;;
  start|stop|exec|rm|build|run) exit 0 ;;
  ps) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_DIR}/docker"

# Fixed-pattern fake image IDs — distinct 12-char short forms so message
# assertions can look for the exact short ID substring.
IMG_A="sha256:$(printf 'a%.0s' $(seq 1 64))"   # short: aaaaaaaaaaaa
IMG_B="sha256:$(printf 'b%.0s' $(seq 1 64))"   # short: bbbbbbbbbbbb
SHORT_A="aaaaaaaaaaaa"
SHORT_B="bbbbbbbbbbbb"

# Build a minimal sandbox: global config (ADR-023 preflight requires one) +
# empty tools.yaml (default bundled stack, D8). Sets TEST_HOME, TEST_WS.
setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-drift-test-XXXXXX")
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

# Expected container name — mirrors rc's container_name() derivation
# (parent-dir-basename + "-" + basename, filtered to [a-zA-Z0-9_.-]).
_expected_container_name() {
  local path="$1" parent base
  parent=$(basename "$(dirname "$path")")
  base=$(basename "$path")
  echo "${parent}-${base}" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^[.-]*//' | sed 's/-$//'
}

# run_rc_up — drives the REAL rc up (or --dry-run up) through the fake-docker
# PATH shim. Args: $1 state, $2 stored_image, $3 current_image (empty =
# missing), $4 output-format ("human"|"json"), $5 dry-run ("true"|"false"),
# $6 container-inspect-fail ("true"|"false", optional, default "false" — T7 /
# M2: simulates the CONTAINER's own `.Image}}` inspect failing while the
# earlier `.State.Status}}` state-check still succeeds).
# Sets RC_OUT, RC_ERR, RC_EXIT, RC_LOG (path to the docker-call log, fresh
# per invocation).
RC_OUT="" RC_ERR="" RC_EXIT=0 RC_LOG=""
run_rc_up() {
  local _state="$1" _stored="$2" _current="$3" _fmt="$4" _dry="$5" _inspect_fail="${6:-false}"
  RC_LOG=$(mktemp "${TMPDIR:-/tmp}/rc-drift-log-XXXXXX")
  : > "$RC_LOG"
  local _outfile _errfile
  _outfile=$(mktemp) _errfile=$(mktemp)
  local -a _flags=()
  [[ "$_fmt" == "json" ]] && _flags+=(--output json)
  [[ "$_dry" == "true" ]] && _flags+=(--dry-run)

  set +e
  PATH="${STUB_DIR}:${PATH}" \
    HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="$TEST_WS" \
    DRIFT_LOG="$RC_LOG" DRIFT_STATE="$_state" \
    DRIFT_STORED_IMAGE="$_stored" DRIFT_CURRENT_IMAGE="$_current" \
    DRIFT_CONTAINER_INSPECT_FAIL="$_inspect_fail" \
    "$RC" "${_flags[@]}" up "$TEST_WS" >"$_outfile" 2>"$_errfile" < /dev/null
  RC_EXIT=$?
  set -e 2>/dev/null || true
  set +e
  RC_OUT=$(cat "$_outfile")
  RC_ERR=$(cat "$_errfile")
  rm -f "$_outfile" "$_errfile"
}

# ===========================================================================
# T1 — stopped container + mismatched image IDs -> abort BEFORE docker start,
# non-zero exit, message names container + both short IDs + destroy/re-up +
# RC_IMAGE remedies, no other override promised.
# ===========================================================================
setup_sandbox
_t1_name=$(_expected_container_name "$TEST_WS")
run_rc_up "exited" "$IMG_A" "$IMG_B" "human" "false"

_t1_ok=true _t1_reason=""
if [[ "$RC_EXIT" -eq 0 ]]; then
  _t1_ok=false; _t1_reason="rc up exited 0 (expected non-zero abort on image-ID mismatch)"
fi
if grep -qx "start" "$RC_LOG"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }docker start WAS reached (shim log contains 'start') — abort must happen BEFORE docker start"
fi
if ! echo "$RC_ERR" | grep -qF "$_t1_name"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message did not name the container ($_t1_name)"
fi
if ! echo "$RC_ERR" | grep -qF "$SHORT_A"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message did not name the stored (old) short image ID ($SHORT_A)"
fi
if ! echo "$RC_ERR" | grep -qF "$SHORT_B"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message did not name the current (new) short image ID ($SHORT_B)"
fi
if ! echo "$RC_ERR" | grep -qi "rc destroy"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message did not include 'rc destroy' remedy"
fi
if ! echo "$RC_ERR" | grep -qi "rc up"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message did not include 're-up' ('rc up') remedy"
fi
if ! echo "$RC_ERR" | grep -qi "RC_IMAGE"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message did not include the RC_IMAGE re-run nuance for custom-pinned cages"
fi
if echo "$RC_ERR" | grep -qi "rc reload\|--force\|--allow-"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message promised an override mechanism the check does not consult (reload/--force/--allow-*)"
fi

if [[ "$_t1_ok" == "true" ]]; then
  pass T1 "stopped + mismatched image IDs -> abort BEFORE docker start, names container+IDs+remedies, no other override promised"
else
  fail T1 "stopped + mismatched image IDs abort" "$_t1_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# T1b — same scenario, --output json: structured JSON error, non-zero exit,
# no docker start reached.
# ===========================================================================
setup_sandbox
run_rc_up "exited" "$IMG_A" "$IMG_B" "json" "false"

_t1b_ok=true _t1b_reason=""
if [[ "$RC_EXIT" -eq 0 ]]; then
  _t1b_ok=false; _t1b_reason="rc up --output json exited 0 (expected non-zero)"
fi
if grep -qx "start" "$RC_LOG"; then
  _t1b_ok=false; _t1b_reason="${_t1b_reason:+$_t1b_reason; }docker start WAS reached in JSON mode"
fi
if ! echo "$RC_OUT" | grep -q '"code"'; then
  _t1b_ok=false; _t1b_reason="${_t1b_reason:+$_t1b_reason; }stdout did not contain a structured JSON error (\"code\" field)"
fi

if [[ "$_t1b_ok" == "true" ]]; then
  pass T1b "stopped + mismatched image IDs, --output json -> structured JSON error, no docker start"
else
  fail T1b "JSON-mode abort" "$_t1b_reason (exit=$RC_EXIT stdout=$RC_OUT)"
fi
teardown_sandbox

# ===========================================================================
# T2 — stopped container + matching image IDs -> resume proceeds unchanged
# (docker start IS reached; fast-resume behavior not disturbed).
# ===========================================================================
setup_sandbox
run_rc_up "exited" "$IMG_A" "$IMG_A" "human" "false"

if grep -qx "start" "$RC_LOG"; then
  pass T2 "stopped + matching image IDs -> resume proceeds (docker start reached; fast-resume unchanged)"
else
  fail T2 "stopped + matching image IDs resume" "docker start NOT reached (shim log: $(cat "$RC_LOG" | tr '\n' ',')) exit=$RC_EXIT stderr=$RC_ERR"
fi
teardown_sandbox

# ===========================================================================
# T3 — running container + mismatched image IDs -> warn on stderr, proceeds,
# exit 0 (no crash path on the running branch, D-c).
# ===========================================================================
setup_sandbox
run_rc_up "running" "$IMG_A" "$IMG_B" "human" "false"

_t3_ok=true _t3_reason=""
if [[ "$RC_EXIT" -ne 0 ]]; then
  _t3_ok=false; _t3_reason="rc up exited non-zero ($RC_EXIT) on a running container with drifted image (should warn+proceed, not abort)"
fi
if ! echo "$RC_ERR" | grep -qi "warning.*image\|older image"; then
  _t3_ok=false; _t3_reason="${_t3_reason:+$_t3_reason; }no image-drift warning found on stderr"
fi
if grep -qx "start" "$RC_LOG"; then
  _t3_ok=false; _t3_reason="${_t3_reason:+$_t3_reason; }docker start was called for a RUNNING container (should never happen — attach path doesn't start)"
fi

if [[ "$_t3_ok" == "true" ]]; then
  pass T3 "running + mismatched image IDs -> warn on stderr, proceeds, exit 0"
else
  fail T3 "running + mismatched image IDs warn-only" "$_t3_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# T4 — rc build with a stale-pinned container present -> post-build warning
# names it. Isolated call to _build_warn_stale_containers (Harness target
# explicitly allows stubbing the build itself for T4) with a docker stub
# supporting only `image inspect --format {{.Id}}`, `ps -a --filter
# label=rc.source.path`, and `inspect --format {{.Image}}`.
# Positive control: a container pinned to the SAME id as the just-built
# image produces NO warning.
# ===========================================================================
setup_sandbox
_t4_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-t4-stub-XXXXXX")
cat > "${_t4_stub_dir}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"image inspect --format {{.Id}}"*) echo "${IMG_A}"; exit 0 ;;
  *"ps -a --filter label=rc.source.path --format {{.Names}}"*) printf '%s\n' "stale-cage" "current-cage"; exit 0 ;;
  *"inspect --format {{.Image}} stale-cage"*) echo "${IMG_B}"; exit 0 ;;
  *"inspect --format {{.Image}} current-cage"*) echo "${IMG_A}"; exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_t4_stub_dir}/docker"

_t4_err=$(PATH="${_t4_stub_dir}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  IMAGE='rip-cage:latest'
  _build_warn_stale_containers
" 2>&1 >/dev/null)

_t4_ok=true _t4_reason=""
if ! echo "$_t4_err" | grep -qF "stale-cage"; then
  _t4_ok=false; _t4_reason="warning did not name the stale-pinned container 'stale-cage'"
fi
if ! echo "$_t4_err" | grep -qi "rc destroy stale-cage"; then
  _t4_ok=false; _t4_reason="${_t4_reason:+$_t4_reason; }warning did not include the 'rc destroy stale-cage' remedy"
fi
if echo "$_t4_err" | grep -qF "current-cage"; then
  _t4_ok=false; _t4_reason="${_t4_reason:+$_t4_reason; }positive control failed: 'current-cage' (same image ID) was warned about"
fi

if [[ "$_t4_ok" == "true" ]]; then
  pass T4 "rc build post-success enumeration: stale-pinned container named+warned; same-ID container silent (positive control)"
else
  fail T4 "rc build stale-container warning" "$_t4_reason (stderr=$_t4_err)"
fi
rm -rf "${_t4_stub_dir}"
teardown_sandbox

# ===========================================================================
# T5 — current image ($IMAGE) absent at resume -> abort loud (rc build /
# RC_IMAGE / destroy remedies), NOT fail-open (D-f, revised R1). No docker
# start reached.
# ===========================================================================
setup_sandbox
run_rc_up "exited" "$IMG_A" "" "human" "false"

_t5_ok=true _t5_reason=""
if [[ "$RC_EXIT" -eq 0 ]]; then
  _t5_ok=false; _t5_reason="rc up exited 0 with the current image missing (must abort, not fail-open)"
fi
if grep -qx "start" "$RC_LOG"; then
  _t5_ok=false; _t5_reason="${_t5_reason:+$_t5_reason; }docker start WAS reached with the current image missing"
fi
if ! echo "$RC_ERR" | grep -qi "not found"; then
  _t5_ok=false; _t5_reason="${_t5_reason:+$_t5_reason; }message did not say the image was not found"
fi
if ! echo "$RC_ERR" | grep -qi "rc build"; then
  _t5_ok=false; _t5_reason="${_t5_reason:+$_t5_reason; }message did not include the 'rc build' remedy"
fi
if ! echo "$RC_ERR" | grep -qi "RC_IMAGE"; then
  _t5_ok=false; _t5_reason="${_t5_reason:+$_t5_reason; }message did not include the RC_IMAGE remedy"
fi
if ! echo "$RC_ERR" | grep -qi "rc destroy"; then
  _t5_ok=false; _t5_reason="${_t5_reason:+$_t5_reason; }message did not include the rc destroy remedy"
fi

if [[ "$_t5_ok" == "true" ]]; then
  pass T5 "current image absent at resume -> abort loud (rc build / RC_IMAGE / destroy), no docker start"
else
  fail T5 "current image absent at resume" "$_t5_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# T6 — `rc up --dry-run` on a drifted stopped container surfaces the same
# hard stop (would_resume path).
# ===========================================================================
setup_sandbox
run_rc_up "exited" "$IMG_A" "$IMG_B" "human" "true"

_t6_ok=true _t6_reason=""
if [[ "$RC_EXIT" -eq 0 ]]; then
  _t6_ok=false; _t6_reason="rc up --dry-run exited 0 on a drifted stopped container (should surface the same hard stop)"
fi
if grep -qx "start" "$RC_LOG"; then
  _t6_ok=false; _t6_reason="${_t6_reason:+$_t6_reason; }docker start was called under --dry-run (must never happen)"
fi
if ! echo "$RC_ERR" | grep -qi "rc destroy"; then
  _t6_ok=false; _t6_reason="${_t6_reason:+$_t6_reason; }dry-run message did not include the 'rc destroy' remedy"
fi
if ! echo "$RC_ERR" | grep -qi "RC_IMAGE"; then
  _t6_ok=false; _t6_reason="${_t6_reason:+$_t6_reason; }dry-run message did not include the RC_IMAGE remedy"
fi

if [[ "$_t6_ok" == "true" ]]; then
  pass T6 "rc up --dry-run on drifted stopped container surfaces the same hard stop (would_resume path)"
else
  fail T6 "dry-run drift hard-stop" "$_t6_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# T7 (M2 review finding) — running container + the CONTAINER's own image
# inspect fails (transient docker-inspect error / TOCTOU race — e.g. the
# container was removed between the state-check and this guard) -> warn on
# stderr, proceeds, exit 0. A hard abort here would contradict D-c: the
# running branch must never interrupt a live agent session. Positive proof
# that the leniency lives in _up_resolve_resume_image_drift_running, not by
# forking _up_image_drift_status (the comparator is still single-sourced —
# T1/T5 already prove the STOPPED wrapper still aborts on its own failure
# modes, unchanged).
# ===========================================================================
setup_sandbox
run_rc_up "running" "$IMG_A" "$IMG_A" "human" "false" "true"

_t7_ok=true _t7_reason=""
if [[ "$RC_EXIT" -ne 0 ]]; then
  _t7_ok=false; _t7_reason="rc up exited non-zero ($RC_EXIT) on a running container whose image inspect failed transiently (must warn+proceed, never abort — D-c)"
fi
if ! echo "$RC_ERR" | grep -qi "warning"; then
  _t7_ok=false; _t7_reason="${_t7_reason:+$_t7_reason; }no warning found on stderr for the failed container-inspect on the running branch"
fi
if grep -qx "start" "$RC_LOG"; then
  _t7_ok=false; _t7_reason="${_t7_reason:+$_t7_reason; }docker start was called for a RUNNING container (should never happen)"
fi

if [[ "$_t7_ok" == "true" ]]; then
  pass T7 "running + container-inspect failure (transient/TOCTOU) -> warn on stderr, proceeds, exit 0 (M2)"
else
  fail T7 "running + container-inspect failure warn-only" "$_t7_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
