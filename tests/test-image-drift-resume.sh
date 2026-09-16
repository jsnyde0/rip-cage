#!/usr/bin/env bash
# test-image-drift-resume.sh — Host-tier tests for rip-cage-jnvb: `rc up`
# blind-resuming a stopped container pinned to a stale image after `rc build`
# (crash mechanism: new resume logic, e.g. mediator init, execs a file baked
# into the NEW image but absent from the OLD container's fs -> raw crash +
# self-stop).
#
# Design-of-record: bd show rip-cage-jnvb (decisions D-a through D-g).
#
# RE-TARGETED onto msb (rip-cage-qzsx, S8 of the msb migration epic
# rip-cage-tsf2 — ADR-028's image-drift sibling, D4): the fake shim on PATH
# is now `msb`, not `docker` — `cli/up.sh`'s resume path (rewritten by S6,
# rip-cage-rj68) reads container state/labels/image-digest via `msb inspect
# NAME --format json` and the current image's digest via `msb image list
# --format json` (`cli/lib/msb_runtime.sh`'s `_msb_sandbox_state` /
# `_msb_label` / `_msb_sandbox_image_digest` / `_msb_current_image_digest`),
# never `docker`. The comparator (`_up_image_drift_status` at the time --
# renamed/moved to `cli/lib/msb_runtime.sh`'s `_msb_image_drift_status` by a
# later bead, rip-cage-syzk, so cli/reload.sh could share it too), the two
# abort/warn wrappers, and every message template are UNCHANGED by the
# re-target — only the substrate the stored/current values are read from
# moved (from Docker container-ID/image-ID inspection to msb's own sandbox
# metadata + local image cache, per ADR-028 D4's re-binding).
#
# Coverage matrix (see the bead's "## Harness target" for the full spec):
#   T1  stopped sandbox + mismatched image digests -> rc up aborts BEFORE
#       msb start, non-zero exit, message names container + both short
#       IDs + destroy/re-up + RC_IMAGE remedies, no other override promised
#   T2  stopped sandbox + matching image digests -> resume proceeds unchanged
#       (msb start IS reached)
#   T3  running sandbox + mismatched image digests -> warn on stderr, proceeds,
#       exit 0 (no crash path on the running branch — D-c)
#   T4  rc build with a stale-pinned sandbox present -> post-build warning
#       names it (isolated _build_warn_stale_containers call — build itself
#       is stubbed per the Harness target's explicit T4 allowance)
#   T5  current image ($IMAGE) absent at resume -> abort loud (rc build /
#       RC_IMAGE / destroy remedies), NOT fail-open (D-f, revised R1)
#   T6  `rc up --dry-run` on a drifted stopped sandbox -> same hard stop
#       surfaces on the would_resume path
#   T7  (post-review M2 hardening) running sandbox + the SANDBOX's own
#       image-digest inspect call fails transiently (TOCTOU-ish race, msb
#       translation: the SECOND `msb inspect` call in the run — the
#       image-digest check that immediately follows the state check — fails
#       while the first, state-check, call and every later label-read call
#       still succeed) -> warn on stderr, proceeds, exit 0 — never abort a
#       live-session attach on a transient inspect failure (D-c)
#
# END-TO-END REQUIREMENT (R1 finding 2, load-bearing): T1-T3 and T5-T7 drive
# the REAL `rc up` / cmd_up path through a fake-msb PATH shim that logs
# every msb argv (top-level verb only) to a file — NOT the isolated-
# resolver idiom (sourcing rc and calling the resolver directly). This proves
# the guard is actually WIRED into cmd_up before msb start, not just that
# the resolver function itself is correct in isolation. Reference technique:
# tests/test-docker-daemon-hang.sh (full-rc-through-shim) and the docker
# PATH-shim idiom from tests/test-credential-mounts.sh (CM8-CM10) — same
# idiom, msb substrate.
#
# Wired into tests/run-host.sh (host-only tier — no live msb sandbox
# needed; the fake msb on PATH replaces the real binary entirely. The real
# `docker` binary stays on PATH unshadowed — `rc up` still runs
# check_docker first (rc:'build) check_docker') and this suite relies on a real, reachable
# docker daemon for that preflight to pass; it never calls docker beyond
# the preflight).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"

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
# Fake msb: logs the top-level verb ($1) to $DRIFT_LOG, one per line, so the
# test can assert `start` presence/absence (msb's own top-level verb names —
# "start"/"create"/"inspect" — are identical strings to docker's, so the log-
# based assertions below are unchanged from the pre-retarget version). Real
# behavior configured via env vars read at RUNTIME by the stub (set
# per-invocation by run_rc_up below):
#   DRIFT_STATE                  exited|created|running|absent
#   DRIFT_STORED_IMAGE           sha256:... — the sandbox's pinned image digest
#                                 (msb's `.config.manifest_digest`)
#   DRIFT_CURRENT_IMAGE          sha256:... — the resolved $IMAGE's digest in
#                                 msb's local image cache; empty = missing
#   DRIFT_CONTAINER_INSPECT_FAIL "true" — the DRIFT_INSPECT_FAIL_AT'th `msb
#     inspect` call in the run fails, every other call (before and after)
#     still succeeds. Simulates a transient msb-inspect failure / TOCTOU
#     race (sandbox removed between an earlier check and a later guard) —
#     T7 (M2 review finding), and R7 status-3 (rip-cage-syzk, reload's own
#     comparator call). Docker's fake shim could target this via a distinct
#     `--format` value ('{{.Image}}' vs '{{.State.Status}}'); msb's
#     `inspect NAME --format json` returns one undifferentiated JSON blob
#     per call, so the msb-native translation is call-count-based instead
#     (DRIFT_INSPECT_COUNT_FILE, reset per call by run_rc_up).
#   DRIFT_INSPECT_FAIL_AT         which inspect call (1-based) to fail when
#     DRIFT_CONTAINER_INSPECT_FAIL="true". Default 3 -- T7's `rc up` running
#     branch: the sandbox's own image-digest check, inside
#     _up_resolve_resume_image_drift_running, is the THIRD call (existing_path
#     label-read cli/up.sh:2461 is the first, the state check cli/up.sh:2496
#     the second). R7 (rip-cage-syzk) sets this to 4 for `rc reload`'s flow:
#     _msb_exists (1st), verify_rc_container's label read (2nd), the state
#     check (3rd), then _msb_image_drift_status's own
#     _msb_sandbox_image_digest read (4th) is the one that fails.
#   DRIFT_INSPECT_COUNT_FILE     scratch file the stub uses to count `inspect`
#     invocations within one run (reset per call by run_rc_up).
# Written ONCE; every test reuses it by varying the env vars per call.
# ---------------------------------------------------------------------------
# Real VERSION file content (rip-cage-7bs3, T8's docker stub default) --
# read once so the fake docker's version-label response matches whatever
# the real docker was implicitly providing pre-T8 (RC_VERSION, rc:'RC_VERSION='),
# keeping _image_is_current's "current" verdict unchanged for T1-T7.
_drift_real_version=$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo "unknown")
STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-drift-stub-XXXXXX")
cat > "${STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "${1:-}" >> "${DRIFT_LOG}"

case "${1:-}" in
  --version)
    echo "microsandbox 0.6.4 (fake)"
    exit 0
    ;;
  inspect)
    _name="${2:-}"
    if [[ "${DRIFT_STATE:-}" == "absent" ]]; then
      echo "Error: no such sandbox: ${_name}" >&2
      exit 1
    fi
    if [[ -n "${DRIFT_INSPECT_COUNT_FILE:-}" ]]; then
      _n=0
      [[ -f "$DRIFT_INSPECT_COUNT_FILE" ]] && _n=$(cat "$DRIFT_INSPECT_COUNT_FILE")
      _n=$((_n + 1))
      echo "$_n" > "$DRIFT_INSPECT_COUNT_FILE"
      _fail_at="${DRIFT_INSPECT_FAIL_AT:-3}"
      if [[ "${DRIFT_CONTAINER_INSPECT_FAIL:-}" == "true" && "$_n" -eq "$_fail_at" ]]; then
        echo "Error: no such sandbox: ${_name}" >&2
        exit 1
      fi
    fi
    _status="Stopped"
    [[ "${DRIFT_STATE:-}" == "running" ]] && _status="Running"
    # rip-cage-syzk: a real rc.source.path label (not the old empty-object
    # `labels: {}`) -- verify_rc_container (cli/lib/container.sh) and
    # cmd_reload's own workspace resolution both hard-require a non-empty
    # label, which `labels: {}` failed BEFORE any of cmd_reload's own gates
    # ever ran. DRIFT_WORKSPACE is set per-invocation by the run_rc_* helpers
    # below (real $TEST_WS, so a case that falls through to workspace
    # resolution -- e.g. R7's status-2/3 exits actually happen even earlier,
    # at the running-gate, so they don't need this to be a real directory --
    # gets a directory that genuinely exists).
    jq -nc --arg status "$_status" --arg digest "${DRIFT_STORED_IMAGE:-}" --arg ws "${DRIFT_WORKSPACE:-}" \
      '{status: $status, config: {manifest_digest: $digest, labels: {"rc.source.path": $ws}}}'
    exit 0
    ;;
  image)
    if [[ "${2:-}" == "list" ]]; then
      if [[ -z "${DRIFT_CURRENT_IMAGE:-}" ]]; then
        echo "[]"
      else
        jq -nc --arg dig "${DRIFT_CURRENT_IMAGE}" '[{reference: "rip-cage:latest", digest: $dig}]'
      fi
      exit 0
    fi
    if [[ "${2:-}" == "inspect" ]]; then
      # rip-cage-7bs3 (T8): msb-side probe for the layer-diff_id comparator
      # (_msb_image_layer_drift_status). Unset -> exit 1 (image not found in
      # msb's cache), matching the real contract on an absent image and
      # keeping every T1-T7 case (which never set this) at comparator
      # status 3 -- silent, since this suite's real-docker `rc up` call
      # already covers _image_absent separately.
      if [[ -n "${DRIFT_MSB_LAYER_INSPECT:-}" ]]; then
        echo "$DRIFT_MSB_LAYER_INSPECT"
        exit 0
      fi
      exit 1
    fi
    exit 0
    ;;
  create|start|stop|exec|remove|volume|list) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_DIR}/msb"

# Fake docker (rip-cage-7bs3, T8): this file deliberately left the REAL
# docker on PATH for T1-T7 (see the file header's END-TO-END REQUIREMENT
# note) -- check_docker's `docker info` preflight and up.sh's `_image_absent`
# computation (cli/up.sh:2473) ran against a genuinely reachable daemon and
# a genuinely present, version-current `rip-cage:latest`. T8 needs a
# CONTROLLABLE docker-side layer list for the new image-layer-drift
# comparator, so this stub now shadows docker too -- but its DEFAULTS
# reproduce exactly what the real docker was providing (image present,
# version label == the real VERSION file's content), so T1-T7 stay on the
# identical resume path they were on before this stub existed.
cat > "${STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  info) exit "\${DRIFT_DOCKER_INFO_EXIT:-0}" ;;
  image)
    case "\${2:-}" in
      inspect)
        shift 2
        _fmt="" _prev=""
        for _a in "\$@"; do
          [[ "\$_prev" == "--format" ]] && _fmt="\$_a"
          _prev="\$_a"
        done
        case "\$_fmt" in
          *RootFS.Layers*)
            echo "\${DRIFT_DOCKER_LAYERS:-[]}"
            exit 0
            ;;
          *version*)
            echo "\${DRIFT_DOCKER_VERSION_LABEL:-${_drift_real_version}}"
            exit "\${DRIFT_DOCKER_IMAGE_ABSENT:-0}"
            ;;
          *)
            # Bare existence check (up.sh:2473, no --format).
            exit "\${DRIFT_DOCKER_IMAGE_ABSENT:-0}"
            ;;
        esac
        ;;
      rm) exit 0 ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_DIR}/docker"

# Fixed-pattern fake image digests — distinct 12-char short forms so message
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
version: 2
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

# run_rc_up — drives the REAL rc up (or --dry-run up) through the fake-msb
# PATH shim. Args: $1 state, $2 stored_image, $3 current_image (empty =
# missing), $4 output-format ("human"|"json"), $5 dry-run ("true"|"false"),
# $6 sandbox-inspect-fail ("true"|"false", optional, default "false" — T7 /
# M2: simulates the SANDBOX's own image-digest `msb inspect` call failing
# transiently while the earlier state-check `msb inspect` call still
# succeeds — see DRIFT_CONTAINER_INSPECT_FAIL above for the call-count
# translation).
# Sets RC_OUT, RC_ERR, RC_EXIT, RC_LOG (path to the msb-call log, fresh
# per invocation).
RC_OUT="" RC_ERR="" RC_EXIT=0 RC_LOG=""
run_rc_up() {
  local _state="$1" _stored="$2" _current="$3" _fmt="$4" _dry="$5" _inspect_fail="${6:-false}"
  RC_LOG=$(mktemp "${TMPDIR:-/tmp}/rc-drift-log-XXXXXX")
  : > "$RC_LOG"
  local _count_file
  _count_file=$(mktemp "${TMPDIR:-/tmp}/rc-drift-count-XXXXXX")
  : > "$_count_file"
  local _outfile _errfile
  _outfile=$(mktemp) _errfile=$(mktemp)
  local -a _flags=()
  [[ "$_fmt" == "json" ]] && _flags+=(--output json)
  [[ "$_dry" == "true" ]] && _flags+=(--dry-run)

  set +e
  PATH="${STUB_DIR}:${PATH}" \
    HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CAGE_CONF="$(cage_conf_for "$TEST_WS")" \
    DRIFT_LOG="$RC_LOG" DRIFT_STATE="$_state" \
    DRIFT_STORED_IMAGE="$_stored" DRIFT_CURRENT_IMAGE="$_current" \
    DRIFT_CONTAINER_INSPECT_FAIL="$_inspect_fail" \
    DRIFT_INSPECT_COUNT_FILE="$_count_file" \
    DRIFT_WORKSPACE="$TEST_WS" \
    "$RC" "${_flags[@]}" up "$TEST_WS" >"$_outfile" 2>"$_errfile" < /dev/null
  RC_EXIT=$?
  set -e 2>/dev/null || true
  set +e
  RC_OUT=$(cat "$_outfile")
  RC_ERR=$(cat "$_errfile")
  rm -f "$_outfile" "$_errfile" "$_count_file"
}

# run_rc_reload RETIRED with its two callers, R7a and R7b (rip-cage-ely4.10 /
# ADR-031 D3). It drove the real `rc reload <name>` through the same fake-msb
# PATH shim run_rc_up uses; with the verb deleted there is nothing to drive.
# Note it left behind for whoever adds the next stopped-branch case: the shim's
# call-count targeting is what distinguishes the comparator's own failure modes
# from a plain digest mismatch -- run_rc_up carries the same machinery.

# ===========================================================================
# T1 — stopped sandbox + mismatched image digests -> abort BEFORE msb start,
# non-zero exit, message names container + both short IDs + the rc reload
# repair + RC_IMAGE remedies, no other override promised.
#
# rip-cage-syzk (point 4): repointed. This message used to sell `rc destroy
# && rc up` as the repair; it now sells `rc up --replace` (volume-preserving;
# `rc reload` carried this until the verb folded into that flag,
# rip-cage-ely4.10 / ADR-031 D3) and no longer offers `rc destroy` at all --
# R5/R11 assert the same repoint via
# pure grep over the source; this is the live end-to-end proof that the
# ACTUAL message emitted at abort time matches.
# ===========================================================================
setup_sandbox
_t1_name=$(_expected_container_name "$TEST_WS")
run_rc_up "exited" "$IMG_A" "$IMG_B" "human" "false"

_t1_ok=true _t1_reason=""
if [[ "$RC_EXIT" -eq 0 ]]; then
  _t1_ok=false; _t1_reason="rc up exited 0 (expected non-zero abort on image-ID mismatch)"
fi
if grep -qx "start" "$RC_LOG"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }msb start WAS reached (shim log contains 'start') — abort must happen BEFORE msb start"
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
if ! echo "$RC_ERR" | grep -qi "rc up --replace"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message did not include the 'rc up --replace' repair"
fi
if echo "$RC_ERR" | grep -qi "rc destroy"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message still offers 'rc destroy' as the stale-image repair (should be repointed to rc reload)"
fi
if ! echo "$RC_ERR" | grep -qi "rc up"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message did not include the custom-pinned-cage 'rc up' escape"
fi
if ! echo "$RC_ERR" | grep -qi "RC_IMAGE"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message did not include the RC_IMAGE re-run nuance for custom-pinned cages"
fi
if echo "$RC_ERR" | grep -qi -- "--force\|--allow-"; then
  _t1_ok=false; _t1_reason="${_t1_reason:+$_t1_reason; }message promised an override mechanism the check does not consult (--force/--allow-*)"
fi

if [[ "$_t1_ok" == "true" ]]; then
  pass T1 "stopped + mismatched image digests -> abort BEFORE msb start, names container+IDs+rc-reload-repair, no rc destroy, no other override promised"
else
  fail T1 "stopped + mismatched image digests abort" "$_t1_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# T1b — same scenario, --output json: structured JSON error, non-zero exit,
# no msb start reached.
# ===========================================================================
setup_sandbox
run_rc_up "exited" "$IMG_A" "$IMG_B" "json" "false"

_t1b_ok=true _t1b_reason=""
if [[ "$RC_EXIT" -eq 0 ]]; then
  _t1b_ok=false; _t1b_reason="rc up --output json exited 0 (expected non-zero)"
fi
if grep -qx "start" "$RC_LOG"; then
  _t1b_ok=false; _t1b_reason="${_t1b_reason:+$_t1b_reason; }msb start WAS reached in JSON mode"
fi
if ! echo "$RC_OUT" | grep -q '"code"'; then
  _t1b_ok=false; _t1b_reason="${_t1b_reason:+$_t1b_reason; }stdout did not contain a structured JSON error (\"code\" field)"
fi

if [[ "$_t1b_ok" == "true" ]]; then
  pass T1b "stopped + mismatched image digests, --output json -> structured JSON error, no msb start"
else
  fail T1b "JSON-mode abort" "$_t1b_reason (exit=$RC_EXIT stdout=$RC_OUT)"
fi
teardown_sandbox

# ===========================================================================
# T2 — stopped sandbox + matching image digests -> resume proceeds unchanged
# (msb start IS reached; fast-resume behavior not disturbed).
# ===========================================================================
setup_sandbox
run_rc_up "exited" "$IMG_A" "$IMG_A" "human" "false"

if grep -qx "start" "$RC_LOG"; then
  pass T2 "stopped + matching image digests -> resume proceeds (msb start reached; fast-resume unchanged)"
else
  fail T2 "stopped + matching image digests resume" "msb start NOT reached (shim log: $(cat "$RC_LOG" | tr '\n' ',')) exit=$RC_EXIT stderr=$RC_ERR"
fi
teardown_sandbox

# ===========================================================================
# T3 — running sandbox + mismatched image digests -> warn on stderr, proceeds,
# exit 0 (no crash path on the running branch, D-c).
# ===========================================================================
setup_sandbox
run_rc_up "running" "$IMG_A" "$IMG_B" "human" "false"

_t3_ok=true _t3_reason=""
if [[ "$RC_EXIT" -ne 0 ]]; then
  _t3_ok=false; _t3_reason="rc up exited non-zero ($RC_EXIT) on a running sandbox with drifted image (should warn+proceed, not abort)"
fi
if ! echo "$RC_ERR" | grep -qi "warning.*image\|older image"; then
  _t3_ok=false; _t3_reason="${_t3_reason:+$_t3_reason; }no image-drift warning found on stderr"
fi
if grep -qx "start" "$RC_LOG"; then
  _t3_ok=false; _t3_reason="${_t3_reason:+$_t3_reason; }msb start was called for a RUNNING sandbox (should never happen — attach path doesn't start)"
fi

if [[ "$_t3_ok" == "true" ]]; then
  pass T3 "running + mismatched image digests -> warn on stderr, proceeds, exit 0"
else
  fail T3 "running + mismatched image digests warn-only" "$_t3_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# T4 — rc build with a stale-pinned sandbox present -> post-build warning
# names it. Isolated call to _build_warn_stale_containers (Harness target
# explicitly allows stubbing the build itself for T4) with an msb stub
# supporting `image list --format json`, `list --format json`, and
# `inspect NAME --format json` (rip-cage-tsf2.1: this helper was ALSO
# rewritten onto msb, using the same three msb_runtime.sh primitives —
# _msb_current_image_digest / msb list / _msb_label + _msb_sandbox_image_digest).
# Positive control: a sandbox pinned to the SAME digest as the just-built
# image produces NO warning.
# ===========================================================================
setup_sandbox
_t4_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-t4-stub-XXXXXX")
cat > "${_t4_stub_dir}/msb" <<STUB
#!/usr/bin/env bash
set -u
case "\${1:-} \${2:-}" in
  "image list")
    jq -nc --arg dig "${IMG_A}" '[{reference: "rip-cage:latest", digest: \$dig}]'
    exit 0
    ;;
  "list "*|"list")
    jq -nc '[{name: "stale-cage"}, {name: "current-cage"}]'
    exit 0
    ;;
esac
case "\${1:-}" in
  inspect)
    case "\${2:-}" in
      stale-cage)
        jq -nc --arg dig "${IMG_B}" '{config: {manifest_digest: \$dig, labels: {"rc.source.path": "/some/path"}}}'
        ;;
      current-cage)
        jq -nc --arg dig "${IMG_A}" '{config: {manifest_digest: \$dig, labels: {"rc.source.path": "/some/other-path"}}}'
        ;;
      *)
        echo "stub: unhandled inspect target: \${2:-}" >&2
        exit 1
        ;;
    esac
    exit 0
    ;;
  *)
    echo "stub: unhandled args: \$*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "${_t4_stub_dir}/msb"

_t4_err=$(PATH="${_t4_stub_dir}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  IMAGE='rip-cage:latest'
  _build_warn_stale_containers
" 2>&1 >/dev/null)

_t4_ok=true _t4_reason=""
if ! echo "$_t4_err" | grep -qF "stale-cage"; then
  _t4_ok=false; _t4_reason="warning did not name the stale-pinned sandbox 'stale-cage'"
fi
if ! echo "$_t4_err" | grep -qi "rc up --replace"; then
  _t4_ok=false; _t4_reason="${_t4_reason:+$_t4_reason; }warning did not include the 'rc up --replace' repair (rip-cage-syzk repoint, re-pointed off the retired rc reload by rip-cage-ely4.10)"
fi
if echo "$_t4_err" | grep -qi "rc destroy"; then
  _t4_ok=false; _t4_reason="${_t4_reason:+$_t4_reason; }warning still offers 'rc destroy' as the stale-image repair"
fi
if echo "$_t4_err" | grep -qF "current-cage"; then
  _t4_ok=false; _t4_reason="${_t4_reason:+$_t4_reason; }positive control failed: 'current-cage' (same image digest) was warned about"
fi

if [[ "$_t4_ok" == "true" ]]; then
  pass T4 "rc build post-success enumeration: stale-pinned sandbox named+warned; same-digest sandbox silent (positive control)"
else
  fail T4 "rc build stale-container warning" "$_t4_reason (stderr=$_t4_err)"
fi
rm -rf "${_t4_stub_dir}"
teardown_sandbox

# ===========================================================================
# T5 — current image ($IMAGE) absent at resume -> abort loud (rc build /
# RC_IMAGE / destroy remedies), NOT fail-open (D-f, revised R1). No msb
# start reached.
# ===========================================================================
setup_sandbox
run_rc_up "exited" "$IMG_A" "" "human" "false"

_t5_ok=true _t5_reason=""
if [[ "$RC_EXIT" -eq 0 ]]; then
  _t5_ok=false; _t5_reason="rc up exited 0 with the current image missing (must abort, not fail-open)"
fi
if grep -qx "start" "$RC_LOG"; then
  _t5_ok=false; _t5_reason="${_t5_reason:+$_t5_reason; }msb start WAS reached with the current image missing"
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
  pass T5 "current image absent at resume -> abort loud (rc build / RC_IMAGE / destroy), no msb start"
else
  fail T5 "current image absent at resume" "$_t5_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# T6 — `rc up --dry-run` on a drifted stopped sandbox PREVIEWS THE CONVERGE.
#
# REVISED by rip-cage-ely4.9. This case used to demand the same hard stop the
# real path produced, because `rc up` had no way to fix stale-image drift and
# could only tell the operator to run `rc reload` by hand. ADR-031 D3 folds
# that repair INTO `rc up`: a stopped cage cold-recreates against its current
# config, and the recreate lands on the current image — so the drift is
# resolved rather than refused, and an abort here would be predicting a
# failure that no longer happens.
#
# What must still hold, and is what this case now guards: the preview does not
# touch anything. No `msb start`, no stop, no remove under --dry-run.
# ===========================================================================
setup_sandbox
run_rc_up "exited" "$IMG_A" "$IMG_B" "json" "true"

_t6_ok=true _t6_reason=""
if [[ "$RC_EXIT" -ne 0 ]]; then
  _t6_ok=false; _t6_reason="rc up --dry-run exited ${RC_EXIT} on a drifted stopped sandbox (the converge resolves the drift; nothing to abort)"
fi
if ! echo "$RC_OUT" | jq -e '.action == "would_converge"' >/dev/null 2>&1; then
  _t6_ok=false; _t6_reason="${_t6_reason:+$_t6_reason; }dry-run did not report would_converge (got: ${RC_OUT})"
fi
# The whole point of a preview: it previews.
for _t6_verb in start stop remove create; do
  if grep -qx "$_t6_verb" "$RC_LOG"; then
    _t6_ok=false; _t6_reason="${_t6_reason:+$_t6_reason; }msb ${_t6_verb} was called under --dry-run (must never happen)"
  fi
done

if [[ "$_t6_ok" == "true" ]]; then
  pass T6 "rc up --dry-run on a drifted stopped sandbox previews would_converge and mutates nothing"
else
  fail T6 "dry-run converge preview" "$_t6_reason (exit=$RC_EXIT stdout=$RC_OUT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# T7 (M2 review finding) — running sandbox + the SANDBOX's own image-digest
# inspect call fails (transient msb-inspect error / TOCTOU race — e.g. the
# sandbox was removed between the state-check and this guard) -> warn on
# stderr, proceeds, exit 0. A hard abort here would contradict D-c: the
# running branch must never interrupt a live agent session. Positive proof
# that the leniency lives in _up_resolve_resume_image_drift_running, not by
# forking _msb_image_drift_status (the comparator is still single-sourced —
# T1/T5 already prove the STOPPED wrapper still aborts on its own failure
# modes, unchanged).
# ===========================================================================
setup_sandbox
run_rc_up "running" "$IMG_A" "$IMG_A" "human" "false" "true"

_t7_ok=true _t7_reason=""
if [[ "$RC_EXIT" -ne 0 ]]; then
  _t7_ok=false; _t7_reason="rc up exited non-zero ($RC_EXIT) on a running sandbox whose image inspect failed transiently (must warn+proceed, never abort — D-c)"
fi
if ! echo "$RC_ERR" | grep -qi "warning"; then
  _t7_ok=false; _t7_reason="${_t7_reason:+$_t7_reason; }no warning found on stderr for the failed sandbox-inspect on the running branch"
fi
if grep -qx "start" "$RC_LOG"; then
  _t7_ok=false; _t7_reason="${_t7_reason:+$_t7_reason; }msb start was called for a RUNNING sandbox (should never happen)"
fi

if [[ "$_t7_ok" == "true" ]]; then
  pass T7 "running + sandbox-inspect failure (transient/TOCTOU) -> warn on stderr, proceeds, exit 0 (M2)"
else
  fail T7 "running + sandbox-inspect failure warn-only" "$_t7_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# T8 (rip-cage-7bs3) — msb's cached $IMAGE vs. docker's local $IMAGE, the
# NEW layer-diff_id comparator (_msb_image_layer_drift_status /
# _msb_warn_image_layer_drift, cli/lib/msb_runtime.sh) wired into `rc up`'s
# image-present branch (cli/up.sh, right after the _image_absent
# computation). Driven through the REAL cmd_up via this file's fake-docker+
# fake-msb PATH shim (this file's own END-TO-END REQUIREMENT, see header) —
# not an isolated call to the comparator/emitter.
#
# T8a positive control: matching diff_id lists -> silence, exit 0.
# T8b the divergence case: differing diff_id lists -> the loud warning
#     fires on stderr, exit 0 (advisory, never fail-closed).
# ===========================================================================
setup_sandbox
DRIFT_DOCKER_LAYERS='["sha256:layer1","sha256:layer2"]' \
DRIFT_MSB_LAYER_INSPECT='{"layers":[{"diff_id":"sha256:layer1"},{"diff_id":"sha256:layer2"}]}' \
  run_rc_up "running" "$IMG_A" "$IMG_A" "human" "false"

_t8a_ok=true _t8a_reason=""
if [[ "$RC_EXIT" -ne 0 ]]; then
  _t8a_ok=false; _t8a_reason="rc up exited non-zero ($RC_EXIT) on matching layer diff_ids"
fi
if echo "$RC_ERR" | grep -qi "STALE"; then
  _t8a_ok=false; _t8a_reason="${_t8a_reason:+$_t8a_reason; }image-layer-drift warning fired despite matching diff_id lists"
fi
if [[ "$_t8a_ok" == "true" ]]; then
  pass T8a "matching layer diff_ids -> no image-layer-drift warning (positive control), exit 0"
else
  fail T8a "positive control: matching diff_ids should stay silent" "$_t8a_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

setup_sandbox
DRIFT_DOCKER_LAYERS='["sha256:layer1","sha256:layer2"]' \
DRIFT_MSB_LAYER_INSPECT='{"layers":[{"diff_id":"sha256:layer1"},{"diff_id":"sha256:DIFFERENT"}]}' \
  run_rc_up "running" "$IMG_A" "$IMG_A" "human" "false"

_t8b_ok=true _t8b_reason=""
if [[ "$RC_EXIT" -ne 0 ]]; then
  _t8b_ok=false; _t8b_reason="rc up exited non-zero ($RC_EXIT) on a layer-drift divergence (advisory only, must stay exit 0)"
fi
if ! echo "$RC_ERR" | grep -qi "STALE"; then
  _t8b_ok=false; _t8b_reason="${_t8b_reason:+$_t8b_reason; }no image-layer-drift warning found on stderr"
fi
if [[ "$_t8b_ok" == "true" ]]; then
  pass T8b "divergent layer diff_ids -> loud image-layer-drift warning through REAL cmd_up, exit 0"
else
  fail T8b "rc up layer-drift wiring" "$_t8b_reason (exit=$RC_EXIT stderr=$RC_ERR)"
fi
teardown_sandbox

# ===========================================================================
# R7a and R7b RETIRED with `rc reload` (rip-cage-ely4.10 / ADR-031 D3).
#
# They drove cmd_reload's stopped-cage gate for the two CANNOT-CHECK image-drift
# statuses -- current image absent from msb's cache (2), and msb inspect failing
# on the sandbox's own digest (3) -- asserting exit 2, a diagnostic of its own,
# and no recreate attempted.
#
# The property survives on the verb that absorbed reload: cmd_up's own stopped
# resolver (_up_resolve_resume_image_drift_stopped) has the same
# cannot-check-so-do-not-proceed split, and T5 above proves the absent-image half
# through the REAL cmd_up -- abort loud, no msb start. What retired with the verb
# is reload's separate exit-2 code, which had no equivalent in `rc up` to move to.
# ===========================================================================

# ===========================================================================
# R5 (rip-cage-syzk) — message-repoint grep, no cage needed. cli/up.sh's
# stale-image (status-1 mismatch) abort, cli/up.sh's running-cage drift
# warning, and cli/build.sh's post-build sweep warning (the FIRST of the
# three an operator sees) all name `rc up --replace`; NONE of them offers `rc
# destroy` as the stale-image repair any more. (They named `rc reload` until
# that verb folded into the flag -- rip-cage-ely4.10 / ADR-031 D3.) Both halves are PER-LINE
# predicates: a repaired message legitimately contains both `rc reload` and
# `rc up` (the custom-pinned-cage escape), so "the escape names rc up" is
# only evaluated on the escape's own line. The rc-destroy-absence check is
# scoped to the STALE-IMAGE (status-1) abort block ONLY -- cli/up.sh's
# status-2 ("current image not found") abort, a few lines above it,
# legitimately KEEPS an rc destroy offer (R11 below covers what that one
# must additionally say).
#
# Adversarial-review finding F11 (fresh-context review of rip-cage-syzk):
# the extracted block starts AT the sed range's own anchor comment (cli/up.sh's
# "# _status == 1: mismatch." lead-in, a 7-line explanatory comment that
# itself says "rc reload" twice while explaining the repoint) -- the
# positive "names rc reload" check could pass on THAT PROSE ALONE, never
# reaching the actual echo/json_error lines. Fixed: strip comment-only
# lines (grep -v '^\s*#') before either check runs, so both are scoped to
# the CODE, not commentary about the code.
# ===========================================================================
_r5_ok=true _r5_reason=""

_r5_stale_block_raw=$(sed -n '/# _status == 1: mismatch\./,/^}/p' "${SCRIPT_DIR}/../cli/up.sh")
_r5_stale_block=$(echo "$_r5_stale_block_raw" | grep -v '^[[:space:]]*#')
if [[ -z "$_r5_stale_block" ]]; then
  _r5_ok=false; _r5_reason="could not locate the stale-image (status-1) abort block in cli/up.sh"
fi
if echo "$_r5_stale_block" | grep -qi "rc destroy"; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }stale-image abort still offers 'rc destroy' on one of its own lines"
fi
if ! echo "$_r5_stale_block" | grep -qi "rc up --replace"; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }stale-image abort does not name 'rc up --replace'"
fi
# Per-line: the custom-pinned-cage escape (the line naming RC_IMAGE=) names
# a PLAIN rc up ON ITS OWN LINE, and is NOT worded as a recreate (rejected in
# review -- with the original image there is no drift, so a recreate would be
# work for nothing).
_r5_escape_line=$(echo "$_r5_stale_block" | grep -i "RC_IMAGE=")
if [[ -z "$_r5_escape_line" ]] || ! echo "$_r5_escape_line" | grep -qi "rc up"; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }custom-pinned-cage escape line does not name 'rc up' on its own line"
fi
if echo "$_r5_escape_line" | grep -qi -- "--replace"; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }custom-pinned-cage escape is worded as a recreate"
fi

# cli/up.sh's running-cage drift warning: names the recreate, not rc destroy.
_r5_running_line=$(grep "is running an older image" "${SCRIPT_DIR}/../cli/up.sh")
if [[ -z "$_r5_running_line" ]]; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }could not locate the running-cage drift warning in cli/up.sh"
fi
if ! echo "$_r5_running_line" | grep -qi "rc up --replace"; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }running-cage drift warning does not name rc up --replace"
fi
if echo "$_r5_running_line" | grep -qi "rc destroy"; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }running-cage drift warning still offers rc destroy"
fi

# cli/build.sh's post-build sweep warning (the FIRST message an operator sees).
_r5_build_line=$(grep "was created from a different image than the one just built" "${SCRIPT_DIR}/../cli/build.sh")
if [[ -z "$_r5_build_line" ]]; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }could not locate the build post-success sweep warning in cli/build.sh"
fi
if ! echo "$_r5_build_line" | grep -qi "rc up --replace"; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }build sweep warning does not name rc up --replace"
fi
if echo "$_r5_build_line" | grep -qi "rc destroy"; then
  _r5_ok=false; _r5_reason="${_r5_reason:+$_r5_reason; }build sweep warning still offers rc destroy"
fi

if [[ "$_r5_ok" == "true" ]]; then
  pass R5 "message repoint: up.sh stale-image abort + running-cage warning + build.sh sweep warning all name rc up --replace, none names rc destroy; the custom-pinned escape stays a plain rc up on its own line"
else
  fail R5 "message repoint grep" "$_r5_reason"
fi

# ===========================================================================
# R11 (rip-cage-syzk) — every message that offers `rc destroy` as a remedy
# in an image- or reload-refusal context ALSO names rc-state- and
# rc-history- (so an operator is never silently routed into volume loss by
# a message chain that opened with "your volumes will survive"): reload's
# no-snapshot message, reload's refuse-loud (non-eligible-diff) message,
# and cli/up.sh's status-2 ("current image not found") abort.
# ===========================================================================
_r11_ok=true _r11_reason=""

# Two of R11's three original sites are gone with the machinery that produced
# them (rip-cage-ely4.9 / ADR-031 D2): reload's "no applied-config snapshot"
# refusal and its "non-reload-eligible fields" refusal both belonged to the
# config-diff engine. Neither message can route an operator into volume loss
# any more, because neither is reachable. The rule R11 encodes is unchanged
# and still enforced on the site that survives, below.

# The status-2 ("current image not found") abort block, WITHIN
# _up_resolve_resume_image_drift_stopped specifically (that same "$_status"
# -eq 2 check also appears, harmlessly, in the sibling running-branch
# resolver further down the file -- restrict to the stopped resolver's own
# function body first so a naive range-match doesn't run past it) -- every
# line inside it that offers rc destroy must also name rc-state-/rc-history-.
_r11_stopped_fn=$(sed -n '/^_up_resolve_resume_image_drift_stopped()/,/^}/p' "${SCRIPT_DIR}/../cli/up.sh")
_r11_status2_block=$(echo "$_r11_stopped_fn" | sed -n '/_status" -eq 2 \]\]; then/,/^  fi$/p')
# Exclude comment-only lines (prose ABOUT the remedy, not the remedy text
# itself, can legitimately say "rc destroy" without also saying rc-state-).
_r11_status2_destroy_lines=$(echo "$_r11_status2_block" | grep -v '^\s*#' | grep -i "rc destroy")
if [[ -z "$_r11_status2_destroy_lines" ]]; then
  _r11_ok=false; _r11_reason="${_r11_reason:+$_r11_reason; }could not locate an 'rc destroy' remedy in up.sh's status-2 abort block"
else
  while IFS= read -r _r11_line; do
    [[ -z "$_r11_line" ]] && continue
    if ! echo "$_r11_line" | grep -q "rc-state-" || ! echo "$_r11_line" | grep -q "rc-history-"; then
      _r11_ok=false; _r11_reason="${_r11_reason:+$_r11_reason; }up.sh status-2 abort's rc-destroy line does not name rc-state-/rc-history-: ${_r11_line}"
    fi
  done <<<"$_r11_status2_destroy_lines"
fi

if [[ "$_r11_ok" == "true" ]]; then
  pass R11 "every rc-destroy-as-remedy message in an image-/reload-refusal context names rc-state-/rc-history-"
else
  fail R11 "volume-cost naming grep" "$_r11_reason"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
