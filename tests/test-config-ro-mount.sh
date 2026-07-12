#!/usr/bin/env bash
# Host-side unit tests for the .rip-cage.yaml ro-mount feature (ADR-021 D7, rip-cage-cw51).
#
# Coverage:
#   M1  .rip-cage.yaml present + mounts.config_mode absent → shadow-mount :ro IS in run args
#   M2  .rip-cage.yaml present + mounts.config_mode: ro  → shadow-mount :ro IS in run args
#   M3  .rip-cage.yaml present + mounts.config_mode: rw  → shadow-mount NOT in run args
#   M4  .rip-cage.yaml ABSENT → no shadow-mount added; rc up --dry-run succeeds (D5 regression)
#   M5  Invalid mounts.config_mode: bogus → aborts loud (non-zero + stderr names field+values)
#   M6  Mount-shape lock: _up_resolve_resume_config_mode aborts when rc.config-mode label
#       disagrees with current effective config (ro→rw toggle requires destroy+re-up)
#   M7  Mount-shape lock same-state: label agrees with current config → returns 0
#   M8  Mount-shape lock missing label (legacy container): treat as "ro" (no break on existing
#       containers that predate the label, since the shadow-mount would have been added by default)
#   M9  auth.credential_mounts: none in the project file does NOT perturb the ro shadow-mount
#       (rip-cage-seqc.4 / C4 — confirms ADR-021 D7 is unaffected by the new key: the agent
#       cannot self-flip none->real in-cage regardless of which key triggered the read)
#
# All tests are host-side only (no live docker container required).
# M6-M8 stub `msb inspect` via a PATH shim (rip-cage-qzsx, S8 of the msb
# migration epic rip-cage-tsf2: _up_resolve_resume_config_mode was rewired
# onto msb by rip-cage-rj68 (S6) — it now reads `msb inspect NAME --format
# json` (cli/lib/msb_runtime.sh's _msb_label), not `docker inspect --format
# ...`; same idiom as test-ssh-allowlist.sh C20-C22 and the msb-native
# translation shipped in test-credential-mounts.sh's _write_msb_inspect_stub).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_HOME=""
TEST_WS=""

pass() { echo "PASS M$1: $2"; }
fail() { echo "FAIL M$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

# Mirror the unset from test-config-loader.sh — the driver-level RC_CONFIG_GLOBAL
# export shadows per-test XDG sandboxes; unset so per-call XDG sandboxes win.
unset RC_CONFIG_GLOBAL

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  return 0
}
trap cleanup EXIT

# Build a minimal sandbox. Sets TEST_HOME, TEST_WS, and optionally writes a
# project .rip-cage.yaml from literal content (empty string = file absent).
setup_sandbox() {
  local yaml_content="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-ro-mount-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  # Minimal global config (secret-path denylist preflight requires a global config).
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
  # Seed an empty tools.yaml so the manifest preflight passes.
  touch "${TEST_HOME}/.config/rip-cage/tools.yaml"
  if [[ -n "$yaml_content" ]]; then
    printf '%s\n' "$yaml_content" > "${TEST_WS}/.rip-cage.yaml"
  fi
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" TEST_WS=""
}

# _write_msb_inspect_stub DIR LABEL1=VALUE1 [LABEL2=VALUE2 ...]
# Writes a fake `msb` binary at DIR/msb whose `inspect NAME --format json`
# response carries a fixed labels object built from the LABEL=VALUE pairs —
# the msb-side counterpart to this suite's pre-retarget docker-inspect stub
# idiom (`docker inspect --format '{{index .Config.Labels "KEY"}}'`).
# _msb_label reads `.config.labels[$k] // empty`, so an omitted key or one
# given an empty VALUE both simulate "label absent" (legacy container).
_write_msb_inspect_stub() {
  local _dir="$1"; shift
  local _labels_json="{" _first=true _pair _key _val
  for _pair in "$@"; do
    _key="${_pair%%=*}"
    _val="${_pair#*=}"
    if [[ "$_first" == "true" ]]; then _first=false; else _labels_json+=","; fi
    _labels_json+="\"${_key}\":\"${_val}\""
  done
  _labels_json+="}"
  cat > "${_dir}/msb" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  inspect)
    echo '{"status":"Stopped","config":{"manifest_digest":"","labels":${_labels_json}}}'
    exit 0
    ;;
  *)
    echo "stub: unhandled args: \$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${_dir}/msb"
}

# ---------------------------------------------------------------------------
# M1: .rip-cage.yaml present + mounts.config_mode absent → shadow-mount :ro
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
ssh:
  allowed_hosts:
    - github.com"

_m1_args=""
set +e
_m1_args=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
  source '$RC' 2>/dev/null
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-m1' 2>/dev/null
  printf '%s\n' \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"
" 2>/dev/null)
_m1_exit=$?
set +e

_expected_shadow="${TEST_WS}/.rip-cage.yaml:/workspace/.rip-cage.yaml:ro"
if echo "$_m1_args" | grep -qF "$_expected_shadow"; then
  pass 1 ".rip-cage.yaml present + config_mode absent → shadow-mount :ro is added"
else
  fail 1 ".rip-cage.yaml present + config_mode absent → shadow-mount :ro" \
    "shadow-mount arg '${_expected_shadow}' not found in run args. Got: $(echo "$_m1_args" | grep -F ".rip-cage.yaml" || echo '(no .rip-cage.yaml args)')"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# M2: .rip-cage.yaml present + mounts.config_mode: ro → shadow-mount :ro
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
mounts:
  config_mode: ro"

_m2_args=""
set +e
_m2_args=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
  source '$RC' 2>/dev/null
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-m2' 2>/dev/null
  printf '%s\n' \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"
" 2>/dev/null)
_m2_exit=$?
set +e

_expected_shadow="${TEST_WS}/.rip-cage.yaml:/workspace/.rip-cage.yaml:ro"
if echo "$_m2_args" | grep -qF "$_expected_shadow"; then
  pass 2 ".rip-cage.yaml present + config_mode: ro → shadow-mount :ro is added"
else
  fail 2 ".rip-cage.yaml present + config_mode: ro → shadow-mount :ro" \
    "shadow-mount arg '${_expected_shadow}' not found. Got: $(echo "$_m2_args" | grep -F ".rip-cage.yaml" || echo '(none)')"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# M3: .rip-cage.yaml present + mounts.config_mode: rw → NO shadow-mount
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
mounts:
  config_mode: rw"

_m3_args=""
set +e
_m3_args=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
  source '$RC' 2>/dev/null
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-m3' 2>/dev/null
  printf '%s\n' \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"
" 2>/dev/null)
_m3_exit=$?
set +e

_rw_shadow="${TEST_WS}/.rip-cage.yaml:/workspace/.rip-cage.yaml:ro"
if echo "$_m3_args" | grep -qF "$_rw_shadow"; then
  fail 3 ".rip-cage.yaml present + config_mode: rw → NO shadow-mount" \
    "shadow-mount :ro was added but should be absent under rw opt-in"
else
  pass 3 ".rip-cage.yaml present + config_mode: rw → shadow-mount :ro NOT added (rw opt-in)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# M4: .rip-cage.yaml ABSENT → no shadow-mount; rc up --dry-run succeeds
# ADR-021 D5: both-absent posture unchanged — no new mount when file absent.
# ---------------------------------------------------------------------------
setup_sandbox ""  # no project .rip-cage.yaml

_m4_out="" _m4_err="" _m4_exit=0
_m4_tmpout=$(mktemp)
_m4_tmperr=$(mktemp)
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" \
  "$RC" --dry-run up "$TEST_WS" >"$_m4_tmpout" 2>"$_m4_tmperr"
_m4_exit=$?
set +e
_m4_out=$(cat "$_m4_tmpout")
_m4_err=$(cat "$_m4_tmperr")
rm -f "$_m4_tmpout" "$_m4_tmperr"

_m4_ok=true _m4_reason=""
if [[ "$_m4_exit" -ne 0 ]]; then
  # Some non-zero exits are expected (e.g. no docker daemon) — only fail on error
  # message output that names a .rip-cage.yaml problem.
  if echo "$_m4_err" | grep -qi "\.rip-cage\.yaml"; then
    _m4_ok=false; _m4_reason="rc up --dry-run printed .rip-cage.yaml error (exit $_m4_exit): $_m4_err"
  fi
fi
# Verify no shadow-mount :ro flag would appear in run-args when file absent.
_m4_args=""
set +e
_m4_args=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
  source '$RC' 2>/dev/null
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-m4' 2>/dev/null
  printf '%s\n' \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"
" 2>/dev/null)
set +e

_shadow_ro="${TEST_WS}/.rip-cage.yaml:/workspace/.rip-cage.yaml:ro"
if echo "$_m4_args" | grep -qF "$_shadow_ro"; then
  _m4_ok=false
  _m4_reason="${_m4_reason:+$_m4_reason; }shadow-mount :ro was added even though .rip-cage.yaml is absent (violates D5)"
fi

if [[ "$_m4_ok" == "true" ]]; then
  pass 4 ".rip-cage.yaml absent → no shadow-mount added; D5 both-absent posture preserved"
else
  fail 4 ".rip-cage.yaml absent → no shadow-mount" "$_m4_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# M5: Invalid mounts.config_mode: bogus → aborts loud
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
mounts:
  config_mode: bogus"

_m5_err="" _m5_exit=0
_m5_tmperr=$(mktemp)
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" \
  "$RC" --dry-run up "$TEST_WS" >"$_m5_tmperr.out" 2>"$_m5_tmperr.err"
_m5_exit=$?
set +e
_m5_err=$(cat "$_m5_tmperr.err")
rm -f "$_m5_tmperr.out" "$_m5_tmperr.err"

_m5_ok=true _m5_reason=""
if [[ "$_m5_exit" -eq 0 ]]; then
  _m5_ok=false; _m5_reason="rc up exited 0 instead of failing loud on invalid config_mode"
fi
if ! echo "$_m5_err" | grep -qi "config_mode"; then
  _m5_ok=false; _m5_reason="${_m5_reason:+$_m5_reason; }stderr did not name 'config_mode' field"
fi
if ! echo "$_m5_err" | grep -qi "bogus\|ro.*rw\|allowed"; then
  _m5_ok=false; _m5_reason="${_m5_reason:+$_m5_reason; }stderr did not name allowed values or invalid value"
fi

if [[ "$_m5_ok" == "true" ]]; then
  pass 5 "Invalid mounts.config_mode: bogus → aborts loud, stderr names field and allowed values"
else
  fail 5 "Invalid mounts.config_mode: bogus → abort loud" "$_m5_reason (exit=$_m5_exit, stderr=$_m5_err)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# M6: Mount-shape lock — _up_resolve_resume_config_mode aborts loud when
#     rc.config-mode label disagrees with current effective config (ro→rw).
# Stubs docker inspect via a $PATH shim (same idiom as test-ssh-allowlist.sh C20-C22).
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
mounts:
  config_mode: rw"   # current effective: rw

# Stub msb that returns "ro" for the rc.config-mode label query.
# Simulates a container created in ro mode while config is now rw → mismatch → abort.
_m6_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-m6-stub-XXXXXX")
_write_msb_inspect_stub "$_m6_stub_dir" "rc.config-mode=ro"

_m6_err="" _m6_exit=0
set +e
PATH="${_m6_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_config_mode 'rc-m6-test' '$TEST_WS'
" >/tmp/rc-m6-out 2>/tmp/rc-m6-err
_m6_exit=$?
set +e
_m6_err=$(cat /tmp/rc-m6-err 2>/dev/null || true)
rm -rf "${_m6_stub_dir}" /tmp/rc-m6-out /tmp/rc-m6-err

_m6_ok=true _m6_reason=""
if [[ "$_m6_exit" -eq 0 ]]; then
  _m6_ok=false; _m6_reason="resolver returned 0 (should abort on mount-shape mismatch ro→rw)"
fi
if ! echo "$_m6_err" | grep -qi "rc.config-mode"; then
  _m6_ok=false; _m6_reason="${_m6_reason:+$_m6_reason; }error message did not name the label 'rc.config-mode'"
fi
if ! echo "$_m6_err" | grep -qi "rc destroy"; then
  _m6_ok=false; _m6_reason="${_m6_reason:+$_m6_reason; }error message did not include 'rc destroy' remediation hint"
fi

if [[ "$_m6_ok" == "true" ]]; then
  pass 6 "mount-shape lock aborts loud when rc.config-mode label disagrees (ro→rw toggle)"
else
  fail 6 "mount-shape lock ro→rw mismatch" "$_m6_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# M7: Mount-shape lock same-state — label agrees with current config → returns 0
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
mounts:
  config_mode: ro"   # current effective: ro

_m7_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-m7-stub-XXXXXX")
_write_msb_inspect_stub "$_m7_stub_dir" "rc.config-mode=ro"

_m7_exit=0
set +e
PATH="${_m7_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_config_mode 'rc-m7-test' '$TEST_WS'
" >/tmp/rc-m7-out 2>/tmp/rc-m7-err
_m7_exit=$?
set +e
rm -rf "${_m7_stub_dir}" /tmp/rc-m7-out /tmp/rc-m7-err

if [[ "$_m7_exit" -eq 0 ]]; then
  pass 7 "mount-shape lock returns 0 when label matches current effective config (both ro)"
else
  fail 7 "mount-shape lock same-state" "expected exit 0, got $_m7_exit"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# M8: Mount-shape lock missing label (legacy container) → treat as "ro",
#     which is the default. Container was pre-label (so shadow-mount was added
#     by default); current config also ro (or absent) → no mismatch → returns 0.
# ---------------------------------------------------------------------------
setup_sandbox ""  # current effective: no .rip-cage.yaml → default ro

_m8_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-m8-stub-XXXXXX")
# No labels at all — simulates a legacy container with no rc.config-mode label.
_write_msb_inspect_stub "$_m8_stub_dir"

_m8_exit=0
set +e
PATH="${_m8_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_config_mode 'rc-m8-test' '$TEST_WS'
" >/tmp/rc-m8-out 2>/tmp/rc-m8-err
_m8_exit=$?
set +e
rm -rf "${_m8_stub_dir}" /tmp/rc-m8-out /tmp/rc-m8-err

if [[ "$_m8_exit" -eq 0 ]]; then
  pass 8 "mount-shape lock: missing label (legacy container) treated as ro; no mismatch with default effective config → returns 0"
else
  fail 8 "mount-shape lock missing-label legacy-container" "expected exit 0, got $_m8_exit"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# M9: auth.credential_mounts: none does NOT perturb the ro shadow-mount
# (rip-cage-seqc.4 / C4).
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
auth:
  credential_mounts: none"

_m9_args=""
set +e
_m9_args=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" RC_SKIP_KEYCHAIN_EXTRACTION=1 bash -c "
  source '$RC' 2>/dev/null
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _UP_CRED_MOUNTS_CLAUDE='none'
  _UP_CRED_MOUNTS_PI='none'
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-m9' 2>/dev/null
  printf '%s\n' \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"
" 2>/dev/null)
set +e

_expected_shadow="${TEST_WS}/.rip-cage.yaml:/workspace/.rip-cage.yaml:ro"
if echo "$_m9_args" | grep -qF "$_expected_shadow"; then
  pass 9 "auth.credential_mounts: none in project file does NOT perturb the ro shadow-mount (still :ro)"
else
  fail 9 "auth.credential_mounts: none + ro shadow-mount" \
    "shadow-mount arg '${_expected_shadow}' not found in run args. Got: $(echo "$_m9_args" | grep -F ".rip-cage.yaml" || echo '(no .rip-cage.yaml args)')"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "--- Results: ${FAILURES} failure(s) out of 9 checks ---"
exit "$FAILURES"
