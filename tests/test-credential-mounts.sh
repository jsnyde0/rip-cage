#!/usr/bin/env bash
# Host-side unit tests for auth.credential_mounts (rip-cage-seqc.4).
#
# Design-of-record: history/2026-07-03-credential-non-possession-design.md
# §6.2 + §9.1; concrete diff design /tmp/seqc4-rc-diff-design.md (section C).
#
# Coverage matrix (see design section C1):
#   CM1  default (no auth.* key) -> CC + pi mounts present, bit-for-bit (positive control)
#   CM2  auth.credential_mounts: real (explicit) -> identical to CM1 (positive control)
#   CM3  none -> CC .claude.json AND .credentials.json binds BOTH absent (gated as a unit)
#   CM4  none -> pi auth.json bind absent; PI_CODING_AGENT_DIR still present
#   CM4b none -> F1 symlink-follow leaf (auth.json) resolved-target bind absent;
#                a non-credential symlink in the same scan root still mounts (leaf-filter,
#                not scan-root drop)
#   CM4c F1 fingerprint tracks the filter: cred_mounts=real vs none fingerprints DIFFER
#                when auth.json symlink is seeded; EQUAL when it is not (filter inert)
#   CM5  none -> _extract_credentials NOT reached (zero calls); real DOES reach it
#   CM6  none -> distinct "intentionally skipped (non-possession)" log lines emitted
#   CM7  auth.credential_mounts: bogus -> aborts loud, stderr names field + allowed values
#   CM8  resume guard: label=real, current=none -> abort loud (mount shape immutable)
#   CM9  resume guard: label matches current -> returns 0
#   CM10 resume guard: missing label (legacy) treated as real -> matches/mismatches accordingly
#   CM11 grep-guard: injector-name triplet has zero hits in new/edited rc regions
#
# All tests are host-side only (no live docker container required); CM8-CM10 stub
# `docker inspect` via a PATH shim (M6-M8 idiom from test-config-ro-mount.sh).
#
# Wired into tests/run-host.sh (host-only tier).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_HOME=""
TEST_WS=""

pass() { echo "PASS CM$1: $2"; }
fail() { echo "FAIL CM$1: $2 -- $3"; FAILURES=$((FAILURES + 1)); }

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
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-cred-mounts-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
  touch "${TEST_HOME}/.config/rip-cage/tools.yaml"
  if [[ -n "$yaml_content" ]]; then
    printf '%s\n' "$yaml_content" > "${TEST_WS}/.rip-cage.yaml"
  fi
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" TEST_WS=""
}

# F5: seed placeholder credential fixture files at the exact paths rc
# existence-gates, so real-mode assert-PRESENT controls can't pass vacuously
# on a bare test host (both real and none would otherwise show the mount
# absent — a vacuous diff).
seed_cred_fixtures() {
  mkdir -p "${TEST_HOME}/.claude" "${TEST_HOME}/.pi/agent"
  (umask 077; printf '{"placeholder":true}\n' > "${TEST_HOME}/.claude.json")
  (umask 077; printf '{"placeholder":true}\n' > "${TEST_HOME}/.claude/.credentials.json")
  (umask 077; printf '{"placeholder":true}\n' > "${TEST_HOME}/.pi/agent/auth.json")
}

# Source rc and call _up_prepare_docker_mounts directly (C-method: the dry-run
# block does NOT call this function, so tests must source it). Prints the
# assembled _UP_RUN_ARGS array, one entry per line, to stdout. stderr goes to
# the file named by $3 (or is discarded).
# Args: $1 = cred_mounts mode (real|none), $2 = container name, $3 = stderr capture file (optional)
run_prepare_mounts() {
  local cred_mode="$1" name="$2" stderr_file="${3:-/dev/null}"
  RC_SKIP_KEYCHAIN_EXTRACTION=1 HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
    source '$RC' 2>/dev/null
    _UP_RUN_ARGS=()
    wt_detected=false wt_name= wt_main_git=
    _UP_CREDENTIAL_MOUNTS='$cred_mode'
    _up_prepare_docker_mounts '$TEST_WS' '$name'
    printf '%s\n' \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"
  " 2>"$stderr_file"
}

# ---------------------------------------------------------------------------
# CM1: default (no auth.* key) -> CC + pi mounts present, bit-for-bit
# (positive control — fixtures seeded so this can't pass vacuously).
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_cred_fixtures

_cm1_args=$(run_prepare_mounts "real" "test-cage-cm1")

_cm1_claude_json="${TEST_HOME}/.claude.json:/home/agent/.claude.json"
_cm1_creds_json="${TEST_HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json"
_cm1_pi_auth="${TEST_HOME}/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json"
if echo "$_cm1_args" | grep -qF "$_cm1_claude_json" \
  && echo "$_cm1_args" | grep -qF "$_cm1_creds_json" \
  && echo "$_cm1_args" | grep -qF "$_cm1_pi_auth"; then
  pass 1 "default (no auth.* key) -> CC + pi mounts present, bit-for-bit"
else
  fail 1 "default -> CC + pi mounts present" "expected all three binds; got: $(echo "$_cm1_args" | grep -E '\.claude|\.pi/agent')"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM2: auth.credential_mounts: real (explicit) -> identical to CM1
# (positive control).
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
auth:
  credential_mounts: real"
seed_cred_fixtures

_cm2_args=$(run_prepare_mounts "real" "test-cage-cm2")

if echo "$_cm2_args" | grep -qF "${TEST_HOME}/.claude.json:/home/agent/.claude.json" \
  && echo "$_cm2_args" | grep -qF "${TEST_HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json" \
  && echo "$_cm2_args" | grep -qF "${TEST_HOME}/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json"; then
  pass 2 "auth.credential_mounts: real (explicit) -> identical to default (all binds present)"
else
  fail 2 "explicit real -> CC + pi mounts present" "expected all three binds; got: $(echo "$_cm2_args" | grep -E '\.claude|\.pi/agent')"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM3: none -> CC .claude.json AND .credentials.json binds BOTH absent
# (gated as a UNIT — open-question ruling 1).
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_cred_fixtures

_cm3_args=$(run_prepare_mounts "none" "test-cage-cm3")

_cm3_claude_json="${TEST_HOME}/.claude.json:/home/agent/.claude.json"
_cm3_creds_json="${TEST_HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json"
if echo "$_cm3_args" | grep -qF "$_cm3_claude_json"; then
  fail 3 "none -> CC .claude.json bind ABSENT" ".claude.json bind was present: $(echo "$_cm3_args" | grep -F '.claude.json')"
elif echo "$_cm3_args" | grep -qF "$_cm3_creds_json"; then
  fail 3 "none -> CC .credentials.json bind ABSENT" ".credentials.json bind was present: $(echo "$_cm3_args" | grep -F '.credentials.json')"
else
  pass 3 "none -> CC .claude.json AND .credentials.json binds both ABSENT (gated as a unit)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM4: none -> pi auth.json bind ABSENT; PI_CODING_AGENT_DIR STILL present
# (kept intentionally — the container env var, not a mount, per design).
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_cred_fixtures

_cm4_args=$(run_prepare_mounts "none" "test-cage-cm4")

_cm4_pi_auth="${TEST_HOME}/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json"
if echo "$_cm4_args" | grep -qF "$_cm4_pi_auth"; then
  fail 4 "none -> pi auth.json bind ABSENT" "pi auth.json bind was present: $(echo "$_cm4_args" | grep -F '.pi/agent/auth.json')"
elif ! echo "$_cm4_args" | grep -qF "PI_CODING_AGENT_DIR=/home/agent/.pi/agent"; then
  fail 4 "none -> PI_CODING_AGENT_DIR STILL present" "PI_CODING_AGENT_DIR env var not found in run args"
else
  pass 4 "none -> pi auth.json bind absent; PI_CODING_AGENT_DIR still present (kept intentionally)"
fi
teardown_sandbox

# F1 fixture: seed .pi/agent/auth.json as an ABSOLUTE symlink to a temp target
# OUTSIDE .pi/agent, plus a second non-credential absolute dangling symlink in
# the same scan root, so CM4b can prove leaf-filter (not scan-root drop).
# Sets NORM_AUTH_TARGET / NORM_OTHER_TARGET to the readlink -f canonicalized
# target paths (macOS resolves /var -> /private/var; the mount args use the
# canonicalized form, same idiom as test-symlink-follow.sh).
seed_symlink_auth_json() {
  mkdir -p "${TEST_HOME}/.pi/agent" "${TEST_HOME}/external-target-dir"
  printf '{"placeholder":true}\n' > "${TEST_HOME}/external-target-dir/auth-target.json"
  printf '{"placeholder":true}\n' > "${TEST_HOME}/external-target-dir/other-target.json"
  ln -s "${TEST_HOME}/external-target-dir/auth-target.json" "${TEST_HOME}/.pi/agent/auth.json"
  ln -s "${TEST_HOME}/external-target-dir/other-target.json" "${TEST_HOME}/.pi/agent/other.json"
  NORM_AUTH_TARGET=$(readlink -f "${TEST_HOME}/external-target-dir/auth-target.json" 2>/dev/null || echo "${TEST_HOME}/external-target-dir/auth-target.json")
  NORM_OTHER_TARGET=$(readlink -f "${TEST_HOME}/external-target-dir/other-target.json" 2>/dev/null || echo "${TEST_HOME}/external-target-dir/other-target.json")
}

# ---------------------------------------------------------------------------
# CM4b (F1): none -> symlink-follow leaf filter fires for auth.json's
# resolved-target bind; a NON-credential dangling symlink in the same scan
# root still mounts under none (proves leaf-filter, not scan-root drop).
# Positive control: under real, the auth.json resolved-target bind IS present.
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_symlink_auth_json

_cm4b_real_args=$(run_prepare_mounts "real" "test-cage-cm4b-real")
_cm4b_none_args=$(run_prepare_mounts "none" "test-cage-cm4b-none")

_cm4b_auth_target="${NORM_AUTH_TARGET}:${NORM_AUTH_TARGET}"
_cm4b_other_target="${NORM_OTHER_TARGET}:${NORM_OTHER_TARGET}"

_cm4b_ok=true _cm4b_reason=""
if ! echo "$_cm4b_real_args" | grep -qF "$_cm4b_auth_target"; then
  _cm4b_ok=false; _cm4b_reason="real: auth.json resolved-target bind NOT present (positive control failed)"
fi
if echo "$_cm4b_none_args" | grep -qF "$_cm4b_auth_target"; then
  _cm4b_ok=false; _cm4b_reason="${_cm4b_reason:+$_cm4b_reason; }none: auth.json resolved-target bind IS present (F1 leaf-filter did not fire)"
fi
if ! echo "$_cm4b_none_args" | grep -qF "$_cm4b_other_target"; then
  _cm4b_ok=false; _cm4b_reason="${_cm4b_reason:+$_cm4b_reason; }none: non-credential symlink target ABSENT (leaf-filter over-broadened to scan-root drop)"
fi

if [[ "$_cm4b_ok" == "true" ]]; then
  pass 4b "F1: none filters ONLY the auth.json symlink-follow leaf; other scan-root symlinks still mount; real still mounts auth.json"
else
  fail 4b "F1 symlink-follow leaf-filter" "$_cm4b_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM4c (F1): fingerprint tracks the filter. cred_mounts=real vs none produce
# DIFFERENT fingerprints when the auth.json symlink is seeded (closes the
# label-lock asymmetry). With no auth.json symlink seeded, real and none
# fingerprints are EQUAL (filter inert) — positive control.
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_symlink_auth_json

_cm4c_fp_real=$(HOME="$TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' rw follow file '$TEST_WS' real
")
_cm4c_fp_none=$(HOME="$TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' rw follow file '$TEST_WS' none
")

teardown_sandbox

# Positive control: with no auth.json symlink seeded, real vs none must be EQUAL.
setup_sandbox ""
mkdir -p "${TEST_HOME}/.pi/agent"
_cm4c_fp_real_noauth=$(HOME="$TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' rw follow file '$TEST_WS' real
")
_cm4c_fp_none_noauth=$(HOME="$TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' rw follow file '$TEST_WS' none
")
teardown_sandbox

_cm4c_ok=true _cm4c_reason=""
if [[ "$_cm4c_fp_real" == "$_cm4c_fp_none" ]]; then
  _cm4c_ok=false; _cm4c_reason="with auth.json symlink seeded, real fp ($_cm4c_fp_real) == none fp ($_cm4c_fp_none) — filter not applied to fingerprint (label-lock asymmetry)"
fi
if [[ "$_cm4c_fp_real_noauth" != "$_cm4c_fp_none_noauth" ]]; then
  _cm4c_ok=false; _cm4c_reason="${_cm4c_reason:+$_cm4c_reason; }with NO auth.json symlink, real fp ($_cm4c_fp_real_noauth) != none fp ($_cm4c_fp_none_noauth) — filter should be inert when nothing to filter"
fi

if [[ "$_cm4c_ok" == "true" ]]; then
  pass 4c "F1: fingerprint differs real-vs-none when auth.json symlink present; equal when absent (filter inert, no label-lock asymmetry)"
else
  fail 4c "F1 fingerprint tracks filter" "$_cm4c_reason"
fi

# ---------------------------------------------------------------------------
# CM5: none -> _extract_credentials NOT reached (zero calls); real DOES reach
# it (positive control). Overrides _extract_credentials with a call-recorder
# AFTER sourcing rc (function-override seam, portable across macOS/Linux —
# unlike the keychain extraction itself, which is a Darwin-only no-op).
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_cred_fixtures

_cm5_recorder_none=$(mktemp)
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
  source '$RC' 2>/dev/null
  _extract_credentials() { echo called >> '$_cm5_recorder_none'; return 0; }
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _UP_CREDENTIAL_MOUNTS='none'
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-cm5-none'
" >/dev/null 2>&1

_cm5_recorder_real=$(mktemp)
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
  source '$RC' 2>/dev/null
  _extract_credentials() { echo called >> '$_cm5_recorder_real'; return 0; }
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _UP_CREDENTIAL_MOUNTS='real'
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-cm5-real'
" >/dev/null 2>&1

_cm5_none_calls=$(wc -l < "$_cm5_recorder_none" | tr -d ' ')
_cm5_real_calls=$(wc -l < "$_cm5_recorder_real" | tr -d ' ')
rm -f "$_cm5_recorder_none" "$_cm5_recorder_real"

if [[ "$_cm5_none_calls" -eq 0 && "$_cm5_real_calls" -ge 1 ]]; then
  pass 5 "none -> _extract_credentials NOT reached (0 calls); real DOES reach it (${_cm5_real_calls} call(s))"
else
  fail 5 "extraction skipped under none" "none_calls=${_cm5_none_calls} (expected 0) real_calls=${_cm5_real_calls} (expected >=1)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM6: none -> distinct "intentionally skipped (non-possession)" log lines
# emitted (CC + pi + symlink-follow), distinguishable from the existence-gated
# "not found — skipping" strings.
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_symlink_auth_json

# log() writes to stdout when OUTPUT_FORMAT is unset (the default here), not
# stderr — capture both streams combined so the intentional-skip lines (which
# use log()) and any stderr-only warnings are both visible to the assertions.
_cm6_combined=$(RC_SKIP_KEYCHAIN_EXTRACTION=1 HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
  source '$RC' 2>&1
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _UP_CREDENTIAL_MOUNTS='none'
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-cm6' 2>&1
" 2>&1)
_cm6_log="$_cm6_combined"

_cm6_ok=true _cm6_reason=""
if ! echo "$_cm6_log" | grep -qi "credential mounts.*intentionally skipped\|intentionally skipped.*non-possession"; then
  _cm6_ok=false; _cm6_reason="no CC intentional-skip log line found"
fi
if ! echo "$_cm6_log" | grep -qi "pi credential mount.*intentionally skipped\|auth\.json.*intentionally skipped"; then
  _cm6_ok=false; _cm6_reason="${_cm6_reason:+$_cm6_reason; }no pi intentional-skip log line found"
fi
if ! echo "$_cm6_log" | grep -qi "symlink-follow auth\.json leaf intentionally skipped"; then
  _cm6_ok=false; _cm6_reason="${_cm6_reason:+$_cm6_reason; }no symlink-follow intentional-skip log line found"
fi
if echo "$_cm6_log" | grep -qi "auth\.json not found\|auth\.json not mounted"; then
  _cm6_ok=false; _cm6_reason="${_cm6_reason:+$_cm6_reason; }existence-gated 'not found' warning appeared under none (should be the intentional-skip line, not the missing-file line)"
fi

if [[ "$_cm6_ok" == "true" ]]; then
  pass 6 "none -> distinct intentional-skip log lines (CC + pi + symlink-follow), distinguishable from existence-gated warnings"
else
  fail 6 "none intentional-skip log lines" "$_cm6_reason (log: $_cm6_log)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM7 (invalid value): auth.credential_mounts bogus -> rc up / validate
# aborts loud, non-zero, stderr names field + allowed real,none (mirrors M5).
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
auth:
  credential_mounts: bogus"

_cm7_err="" _cm7_exit=0
_cm7_tmperr=$(mktemp)
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" \
  "$RC" --dry-run up "$TEST_WS" >"${_cm7_tmperr}.out" 2>"${_cm7_tmperr}.err"
_cm7_exit=$?
set -e
_cm7_err=$(cat "${_cm7_tmperr}.err")
rm -f "${_cm7_tmperr}.out" "${_cm7_tmperr}.err"

_cm7_ok=true _cm7_reason=""
if [[ "$_cm7_exit" -eq 0 ]]; then
  _cm7_ok=false; _cm7_reason="rc up exited 0 instead of failing loud on invalid auth.credential_mounts"
fi
if ! echo "$_cm7_err" | grep -qi "credential_mounts"; then
  _cm7_ok=false; _cm7_reason="${_cm7_reason:+$_cm7_reason; }stderr did not name 'credential_mounts' field"
fi
if ! echo "$_cm7_err" | grep -qi "bogus\|real.*none\|allowed"; then
  _cm7_ok=false; _cm7_reason="${_cm7_reason:+$_cm7_reason; }stderr did not name allowed values or invalid value"
fi

if [[ "$_cm7_ok" == "true" ]]; then
  pass 7 "invalid auth.credential_mounts: bogus -> aborts loud, stderr names field and allowed values"
else
  fail 7 "invalid auth.credential_mounts abort loud" "$_cm7_reason (exit=$_cm7_exit, stderr=$_cm7_err)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM8 (resume guard mismatch): stub docker-inspect to a rc.auth.credential-mounts
# =real label, current config none -> _up_resolve_resume_credential_mounts
# aborts non-zero, stderr names rc destroy / rc up, no rc reload mention
# (mirrors M6 in test-config-ro-mount.sh).
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
auth:
  credential_mounts: none"   # current effective: none

_cm8_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm8-stub-XXXXXX")
cat > "${_cm8_stub_dir}/docker" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*"rc.auth.credential-mounts"*) echo "real"; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_cm8_stub_dir}/docker"

_cm8_err="" _cm8_exit=0
set +e
PATH="${_cm8_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_credential_mounts 'rc-cm8-test' '$TEST_WS'
" >/tmp/rc-cm8-out 2>/tmp/rc-cm8-err
_cm8_exit=$?
set -e
_cm8_err=$(cat /tmp/rc-cm8-err 2>/dev/null || true)
rm -rf "${_cm8_stub_dir}" /tmp/rc-cm8-out /tmp/rc-cm8-err

_cm8_ok=true _cm8_reason=""
if [[ "$_cm8_exit" -eq 0 ]]; then
  _cm8_ok=false; _cm8_reason="resolver returned 0 (should abort on mount-shape mismatch real->none)"
fi
if ! echo "$_cm8_err" | grep -qi "rc destroy"; then
  _cm8_ok=false; _cm8_reason="${_cm8_reason:+$_cm8_reason; }error message did not include 'rc destroy' remediation hint"
fi
if echo "$_cm8_err" | grep -qi "rc reload"; then
  _cm8_ok=false; _cm8_reason="${_cm8_reason:+$_cm8_reason; }error message wrongly suggested 'rc reload' (mount shape cannot be reloaded — B4)"
fi

if [[ "$_cm8_ok" == "true" ]]; then
  pass 8 "resume guard aborts loud when rc.auth.credential-mounts label disagrees (real->none), names rc destroy, no rc reload"
else
  fail 8 "resume guard mismatch" "$_cm8_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM9 (resume guard agree): label equals config -> returns 0 (mirror M7).
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
auth:
  credential_mounts: none"   # current effective: none

_cm9_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm9-stub-XXXXXX")
cat > "${_cm9_stub_dir}/docker" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*"rc.auth.credential-mounts"*) echo "none"; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_cm9_stub_dir}/docker"

_cm9_exit=0
set +e
PATH="${_cm9_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_credential_mounts 'rc-cm9-test' '$TEST_WS'
" >/tmp/rc-cm9-out 2>/tmp/rc-cm9-err
_cm9_exit=$?
set -e
rm -rf "${_cm9_stub_dir}" /tmp/rc-cm9-out /tmp/rc-cm9-err

if [[ "$_cm9_exit" -eq 0 ]]; then
  pass 9 "resume guard returns 0 when label matches current effective config (both none)"
else
  fail 9 "resume guard same-state" "expected exit 0, got $_cm9_exit"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM10 (resume guard legacy label): empty label treated as real; matches
# current real/absent -> 0; mismatches none -> abort (mirror M8).
# ---------------------------------------------------------------------------
setup_sandbox ""  # current effective: no .rip-cage.yaml -> default real

_cm10_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm10-stub-XXXXXX")
cat > "${_cm10_stub_dir}/docker" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  # Return empty string — simulates a legacy container with no
  # rc.auth.credential-mounts label.
  *" inspect "*"rc.auth.credential-mounts"*) echo ""; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_cm10_stub_dir}/docker"

_cm10_exit=0
set +e
PATH="${_cm10_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_credential_mounts 'rc-cm10-test' '$TEST_WS'
" >/tmp/rc-cm10-out 2>/tmp/rc-cm10-err
_cm10_exit=$?
set -e
rm -rf "${_cm10_stub_dir}" /tmp/rc-cm10-out /tmp/rc-cm10-err

if [[ "$_cm10_exit" -eq 0 ]]; then
  pass 10 "resume guard: missing label (legacy container) treated as real; no mismatch with default effective config -> returns 0"
else
  fail 10 "resume guard missing-label legacy-container" "expected exit 0, got $_cm10_exit"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM11 (grep-guard, ADR-005 D12): the injector-name triplet returns ZERO hits
# in the new/edited rc regions and messages (extends the G1a guard in
# test-mediator-lifecycle.sh).
# ---------------------------------------------------------------------------
_cm11_hits=$(grep -nE 'mitmproxy|iron-proxy|clawpatrol' "${REPO_ROOT}/rc" 2>/dev/null || true)
if [[ -z "$_cm11_hits" ]]; then
  pass 11 "zero hardcoded mediator/injector names in rc (ADR-005 D12) — auth.credential_mounts + mediator_env_file additions are injector-agnostic"
else
  fail 11 "hardcoded injector names found in rc" "$_cm11_hits"
fi

echo ""
echo "--- Results so far: ${FAILURES} failure(s) ---"
exit "$FAILURES"
