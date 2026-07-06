#!/usr/bin/env bash
# Host-side unit tests for auth.credential_mounts (rip-cage-seqc.4) and its
# per-tool extension auth.per_tool.{claude,pi} (rip-cage-xhgr).
#
# Design-of-record: history/2026-07-03-credential-non-possession-design.md
# §6.2 + §9.1; concrete diff design /tmp/seqc4-rc-diff-design.md (section C);
# rip-cage-xhgr --design for the per-tool extension.
#
# Coverage matrix (see design section C1):
#   CM1  default (no auth.* key) -> CC + pi mounts present, bit-for-bit (positive control)
#   CM2  auth.credential_mounts: real (explicit) -> identical to CM1 (positive control)
#   CM3  none -> CC .claude.json bind PRESENT+ro (not a credential, rip-cage-t7cu);
#                .credentials.json bind absent (positive control)
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
# Per-tool extension (rip-cage-xhgr):
#   CM12  resolver: _up_resolve_effective_credential_mounts_for_tool per_tool.T
#         override, unset-inherits-global, and default-real semantics
#   CM13  {claude:none,pi:real} -> claude .claude.json present+ro, .credentials.json
#         absent + keychain skipped; pi auth.json bind present
#   CM14  {claude:real,pi:none} -> symmetric to CM13
#   CM15  {claude:real,pi:none} -> F1 symlink-follow leaf filtered for pi only
#         (leaf-filter, not scan-root drop); claude side unaffected
#   CM16  unknown key under auth.per_tool. (typo) -> aborts loud naming key/file/allowed-set
#   CM17  resume guard: per-tool flip (pi real->none, claude unchanged) -> abort loud
#         naming "pi" specifically
#   CM18  resume guard: legacy container (no per-tool labels) resumes clean when
#         effective values unchanged; flips claude -> aborts naming "claude"
#   CM19  fingerprint: byte-identical across upgrade when effective(pi) == prior global
#   CM20  fingerprint: resume-side recompute CHANGES on a pi-only flip (claude untouched)
#   CM21  fingerprint: create/resume symmetric for a stable {claude:real,pi:none} cage
#         (resume of an unchanged mixed cage must NOT refuse)
#
# All tests are host-side only (no live docker container required); CM8-CM10,
# CM17-CM18 stub `docker inspect` via a PATH shim (M6-M8 idiom from
# test-config-ro-mount.sh).
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
# the file named by $4 (or is discarded).
# Two-value seam (rip-cage-xhgr): _UP_CREDENTIAL_MOUNTS split into
# _UP_CRED_MOUNTS_CLAUDE / _UP_CRED_MOUNTS_PI at the actual gate sites; every
# injection site (this helper, and the direct CM5/CM6 injections below) must
# set BOTH so a mis-wired gate site can't go inert and false-green.
# Args: $1 = claude cred_mounts mode (real|none), $2 = pi cred_mounts mode
#       (real|none), $3 = container name, $4 = stderr capture file (optional)
run_prepare_mounts() {
  local claude_mode="$1" pi_mode="$2" name="$3" stderr_file="${4:-/dev/null}"
  RC_SKIP_KEYCHAIN_EXTRACTION=1 HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
    source '$RC' 2>/dev/null
    _UP_RUN_ARGS=()
    wt_detected=false wt_name= wt_main_git=
    _UP_CRED_MOUNTS_CLAUDE='$claude_mode'
    _UP_CRED_MOUNTS_PI='$pi_mode'
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

_cm1_args=$(run_prepare_mounts "real" "real" "test-cage-cm1")

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

_cm2_args=$(run_prepare_mounts "real" "real" "test-cage-cm2")

if echo "$_cm2_args" | grep -qF "${TEST_HOME}/.claude.json:/home/agent/.claude.json" \
  && echo "$_cm2_args" | grep -qF "${TEST_HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json" \
  && echo "$_cm2_args" | grep -qF "${TEST_HOME}/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json"; then
  pass 2 "auth.credential_mounts: real (explicit) -> identical to default (all binds present)"
else
  fail 2 "explicit real -> CC + pi mounts present" "expected all three binds; got: $(echo "$_cm2_args" | grep -E '\.claude|\.pi/agent')"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM3: none -> CC .claude.json bind PRESENT but READ-ONLY (:ro) — rip-cage-t7cu
# re-scope: ~/.claude.json holds no token-shaped fields (account metadata +
# workflow state only), so it is no longer suppressed under non-possession;
# it downgrades to ro instead (design-review F3: ro closes the write-primitive
# an in-cage agent would otherwise have into the host's real-credential claude
# config). .credentials.json (the actual secret) stays absent — positive
# control, preserved from the original "gated as a unit" case.
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_cred_fixtures

_cm3_args=$(run_prepare_mounts "none" "none" "test-cage-cm3")

_cm3_claude_json_ro="${TEST_HOME}/.claude.json:/home/agent/.claude.json:ro"
_cm3_creds_json="${TEST_HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json"
if ! echo "$_cm3_args" | grep -qF "$_cm3_claude_json_ro"; then
  fail 3 "none -> CC .claude.json bind PRESENT and read-only (:ro)" ".claude.json:ro bind not found: $(echo "$_cm3_args" | grep -F '.claude.json')"
elif echo "$_cm3_args" | grep -qF "$_cm3_creds_json"; then
  fail 3 "none -> CC .credentials.json bind ABSENT" ".credentials.json bind was present: $(echo "$_cm3_args" | grep -F '.credentials.json')"
else
  pass 3 "none -> CC .claude.json bind present+ro (not a credential); .credentials.json bind ABSENT (positive control)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM4: none -> pi auth.json bind ABSENT; PI_CODING_AGENT_DIR STILL present
# (kept intentionally — the container env var, not a mount, per design).
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_cred_fixtures

_cm4_args=$(run_prepare_mounts "none" "none" "test-cage-cm4")

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
# Reserved-scratch predicate (rip-cage-29sp, same class as vnbd/7hrw).
#
# rc's symlink-follow reserved-path guard (rc ~1456-1480) refuses to mount
# (exit 1, aborting _up_prepare_docker_mounts entirely) any resolved symlink
# target under a Debian FHS reserved top-level (checked literally for
# /var and /tmp — rc deliberately skips canonicalizing those two to dodge
# macOS /private/var false positives).
#
# seed_symlink_auth_json's external-target-dir is nested inside TEST_HOME.
# On macOS, mktemp resolves TEST_HOME under /private/var/folders/... via
# TMPDIR ("private" is not reserved) so the guard never fires. On Linux
# (incl. CI), TMPDIR is typically unset -> mktemp resolves TEST_HOME under
# /tmp (reserved) -> the guard fires for the non-credential "other.json"
# symlink (auth.json itself is filtered earlier under cred_mounts=none, but
# "other.json" is not) -> _up_prepare_docker_mounts exits 1 before either
# CM4b's or CM15's assertions can observe real mount output. No non-reserved
# writable top-level exists for a non-root Linux user (/mnt, /srv, /opt are
# root-owned — see .claude/harness.md), so this can't be fixed by relocating
# the fixture. Key the skip on this ACTUAL reserved-ness condition (not a
# uname/OS check) — same idiom as test-secret-path-denylist.sh l-1/l-2a/l-2b.
_rc_reserved_top_levels() {
  printf '%s\n' bin boot dev etc home lib opt proc root run sbin sys usr var tmp
}

# Returns 0 (true) if the canonicalized form of path "$1" has a reserved FHS
# top-level as its first path component — i.e. rc's reserved-path guard would
# preempt the symlink-follow mount synthesis for fixtures rooted there.
_fixture_under_rc_reserved_top_level() {
  local _path_arg="$1"
  local _resolved _first_component _reserved
  _resolved=$(realpath "$_path_arg" 2>/dev/null) || return 1
  _first_component="${_resolved#/}"
  _first_component="${_first_component%%/*}"
  for _reserved in $(_rc_reserved_top_levels); do
    if [[ "$_first_component" == "$_reserved" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# CM4b (F1): none -> symlink-follow leaf filter fires for auth.json's
# resolved-target bind; a NON-credential dangling symlink in the same scan
# root still mounts under none (proves leaf-filter, not scan-root drop).
# Positive control: under real, the auth.json resolved-target bind IS present.
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_symlink_auth_json

if _fixture_under_rc_reserved_top_level "$TEST_HOME"; then
  echo "SKIP (reserved-scratch): CM4b F1 symlink-follow leaf-filter — fixture external-target-dir resolves under an rc-reserved FHS top-level (TMPDIR unset on Linux CI -> mktemp lands under /tmp); rc's reserved-path guard (rc ~1456-1480) preempts the leaf-filter this subtest exercises. Runs on macOS + full local suite. See bead rip-cage-29sp."
else
  _cm4b_real_args=$(run_prepare_mounts "real" "real" "test-cage-cm4b-real")
  _cm4b_none_args=$(run_prepare_mounts "none" "none" "test-cage-cm4b-none")

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
  _UP_CRED_MOUNTS_CLAUDE='none'
  _UP_CRED_MOUNTS_PI='none'
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-cm5-none'
" >/dev/null 2>&1

_cm5_recorder_real=$(mktemp)
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$TEST_WS" bash -c "
  source '$RC' 2>/dev/null
  _extract_credentials() { echo called >> '$_cm5_recorder_real'; return 0; }
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _UP_CRED_MOUNTS_CLAUDE='real'
  _UP_CRED_MOUNTS_PI='real'
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
  _UP_CRED_MOUNTS_CLAUDE='none'
  _UP_CRED_MOUNTS_PI='none'
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

# ---------------------------------------------------------------------------
# CM12 (resolver): _up_resolve_effective_credential_mounts_for_tool computes
# effective(T) = per_tool.T if set, else global credential_mounts, else "real"
# — the single jq expression backing every effective(T) computation site (D1).
# Pure function over an effective-config JSON blob; no docker/fixtures needed.
# ---------------------------------------------------------------------------
_cm12_helper_out() {
  local tool="$1" cfg="$2"
  HOME="$TEST_HOME" bash -c "
    source '$RC' 2>/dev/null
    _up_resolve_effective_credential_mounts_for_tool '$tool' '$cfg'
  "
}

setup_sandbox ""

_cm12_ok=true _cm12_reason=""

# Bracket with set +e/-e (idiom from CM7-CM10 above): a prior block's "set -e"
# restore leaves errexit ON for the remainder of the script, so a not-yet-
# implemented helper (RED phase) must not abort the whole suite.
set +e

# per_tool.claude set to 'none', global 'real' -> claude effective = none (override wins)
_cm12_cfg='{"config":{"auth":{"credential_mounts":"real","per_tool":{"claude":"none","pi":null}}}}'
_cm12_out=$(_cm12_helper_out "claude" "$_cm12_cfg")
if [[ "$_cm12_out" != "none" ]]; then
  _cm12_ok=false; _cm12_reason="per_tool.claude=none override -> expected 'none', got '$_cm12_out'"
fi

# per_tool.pi unset (null), global 'real' -> pi effective = real (inherits global)
_cm12_out=$(_cm12_helper_out "pi" "$_cm12_cfg")
if [[ "$_cm12_out" != "real" ]]; then
  _cm12_ok=false; _cm12_reason="${_cm12_reason:+$_cm12_reason; }per_tool.pi unset -> expected inherited 'real', got '$_cm12_out'"
fi

# global 'none', per_tool both unset -> both effective = none (bare backward-compat)
_cm12_cfg2='{"config":{"auth":{"credential_mounts":"none","per_tool":{"claude":null,"pi":null}}}}'
_cm12_out_claude=$(_cm12_helper_out "claude" "$_cm12_cfg2")
_cm12_out_pi=$(_cm12_helper_out "pi" "$_cm12_cfg2")
if [[ "$_cm12_out_claude" != "none" || "$_cm12_out_pi" != "none" ]]; then
  _cm12_ok=false; _cm12_reason="${_cm12_reason:+$_cm12_reason; }bare global 'none' -> expected both 'none', got claude='$_cm12_out_claude' pi='$_cm12_out_pi'"
fi

# no auth key at all (absent) -> default 'real'
_cm12_cfg3='{"config":{}}'
_cm12_out=$(_cm12_helper_out "claude" "$_cm12_cfg3")
if [[ "$_cm12_out" != "real" ]]; then
  _cm12_ok=false; _cm12_reason="${_cm12_reason:+$_cm12_reason; }absent auth key -> expected default 'real', got '$_cm12_out'"
fi
set -e

if [[ "$_cm12_ok" == "true" ]]; then
  pass 12 "resolver: per_tool.T override wins, unset inherits global, absent defaults to real"
else
  fail 12 "resolver effective(T) computation" "$_cm12_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM13 (mixed posture a): {claude:none, pi:real} -> claude gets NO credentials
# (keychain extraction skipped + CC .credentials.json bind absent; .claude.json
# bind IS present but read-only per rip-cage-t7cu) AND pi's auth.json bind IS
# present. Proves the two gate-site groups (claude: keychain + CC mounts; pi:
# auth.json mount) are keyed independently.
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_cred_fixtures

_cm13_recorder=$(mktemp)
_cm13_args=$(RC_ALLOWED_ROOTS="$TEST_WS" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _extract_credentials() { echo called >> '$_cm13_recorder'; return 0; }
  _UP_RUN_ARGS=()
  wt_detected=false wt_name= wt_main_git=
  _UP_CRED_MOUNTS_CLAUDE='none'
  _UP_CRED_MOUNTS_PI='real'
  _up_prepare_docker_mounts '$TEST_WS' 'test-cage-cm13'
  printf '%s\n' \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"
" 2>/dev/null)
_cm13_extract_calls=$(wc -l < "$_cm13_recorder" | tr -d ' ')
rm -f "$_cm13_recorder"

_cm13_ok=true _cm13_reason=""
if ! echo "$_cm13_args" | grep -qF "${TEST_HOME}/.claude.json:/home/agent/.claude.json:ro"; then
  _cm13_ok=false; _cm13_reason="claude:none but .claude.json:ro bind is ABSENT: $(echo "$_cm13_args" | grep -F '.claude.json')"
fi
if echo "$_cm13_args" | grep -qF "${TEST_HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json"; then
  _cm13_ok=false; _cm13_reason="${_cm13_reason:+$_cm13_reason; }claude:none but .credentials.json bind IS present"
fi
if [[ "$_cm13_extract_calls" -ne 0 ]]; then
  _cm13_ok=false; _cm13_reason="${_cm13_reason:+$_cm13_reason; }claude:none but keychain extraction WAS reached (${_cm13_extract_calls} call(s))"
fi
if ! echo "$_cm13_args" | grep -qF "${TEST_HOME}/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json"; then
  _cm13_ok=false; _cm13_reason="${_cm13_reason:+$_cm13_reason; }pi:real but auth.json bind is ABSENT"
fi

if [[ "$_cm13_ok" == "true" ]]; then
  pass 13 "mixed {claude:none,pi:real}: claude .claude.json present+ro, .credentials.json + keychain extraction absent (positive controls); pi auth.json bind present"
else
  fail 13 "mixed posture a" "$_cm13_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM14 (mixed posture b, symmetric): {claude:real, pi:none} -> claude keeps
# its credentials; pi's auth.json bind is absent.
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_cred_fixtures

_cm14_args=$(run_prepare_mounts "real" "none" "test-cage-cm14")

_cm14_ok=true _cm14_reason=""
if ! echo "$_cm14_args" | grep -qF "${TEST_HOME}/.claude.json:/home/agent/.claude.json"; then
  _cm14_ok=false; _cm14_reason="claude:real but .claude.json bind is ABSENT"
fi
if ! echo "$_cm14_args" | grep -qF "${TEST_HOME}/.claude/.credentials.json:/home/agent/.claude/.credentials.json"; then
  _cm14_ok=false; _cm14_reason="${_cm14_reason:+$_cm14_reason; }claude:real but .credentials.json bind is ABSENT"
fi
if echo "$_cm14_args" | grep -qF "${TEST_HOME}/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json"; then
  _cm14_ok=false; _cm14_reason="${_cm14_reason:+$_cm14_reason; }pi:none but auth.json bind IS present"
fi

if [[ "$_cm14_ok" == "true" ]]; then
  pass 14 "mixed {claude:real,pi:none}: symmetric to CM13 — claude binds present, pi auth.json bind absent"
else
  fail 14 "mixed posture b" "$_cm14_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM15 (mixed posture, symlink-follow gate site): {claude:real, pi:none} ->
# F1 symlink-follow leaf filtered for the pi auth.json symlink only
# (leaf-filter, not scan-root drop — the non-credential symlink still
# mounts); claude:real is irrelevant to this pi-only scan root.
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_symlink_auth_json

if _fixture_under_rc_reserved_top_level "$TEST_HOME"; then
  echo "SKIP (reserved-scratch): CM15 mixed-posture F1 symlink-follow leaf-filter — fixture external-target-dir resolves under an rc-reserved FHS top-level (TMPDIR unset on Linux CI -> mktemp lands under /tmp); rc's reserved-path guard (rc ~1456-1480) preempts the leaf-filter this subtest exercises. Runs on macOS + full local suite. See bead rip-cage-29sp."
else
  _cm15_args=$(run_prepare_mounts "real" "none" "test-cage-cm15")

  _cm15_auth_target="${NORM_AUTH_TARGET}:${NORM_AUTH_TARGET}"
  _cm15_other_target="${NORM_OTHER_TARGET}:${NORM_OTHER_TARGET}"

  _cm15_ok=true _cm15_reason=""
  if echo "$_cm15_args" | grep -qF "$_cm15_auth_target"; then
    _cm15_ok=false; _cm15_reason="pi:none but auth.json resolved-target bind IS present (F1 leaf-filter did not fire under per-tool pi:none)"
  fi
  if ! echo "$_cm15_args" | grep -qF "$_cm15_other_target"; then
    _cm15_ok=false; _cm15_reason="${_cm15_reason:+$_cm15_reason; }non-credential symlink target ABSENT (leaf-filter over-broadened to scan-root drop)"
  fi

  if [[ "$_cm15_ok" == "true" ]]; then
    pass 15 "mixed {claude:real,pi:none}: F1 symlink-follow leaf filtered for pi only, non-credential symlink still mounts"
  else
    fail 15 "mixed posture symlink-follow leaf-filter" "$_cm15_reason"
  fi
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM16 (D7 fail-closed): unknown key under auth.per_tool. (typo'd or
# unsupported tool name) -> aborts loud, stderr names the key, the file, and
# the allowed set. Mirrors CM7's --dry-run up abort idiom.
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
auth:
  per_tool:
    claud: none"   # typo: should be 'claude'

_cm16_err="" _cm16_exit=0
_cm16_tmperr=$(mktemp)
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="$TEST_WS" \
  "$RC" --dry-run up "$TEST_WS" >"${_cm16_tmperr}.out" 2>"${_cm16_tmperr}.err"
_cm16_exit=$?
set -e
_cm16_err=$(cat "${_cm16_tmperr}.err")
rm -f "${_cm16_tmperr}.out" "${_cm16_tmperr}.err"

_cm16_ok=true _cm16_reason=""
if [[ "$_cm16_exit" -eq 0 ]]; then
  _cm16_ok=false; _cm16_reason="rc up exited 0 instead of failing loud on unknown auth.per_tool.claud key"
fi
if ! echo "$_cm16_err" | grep -qi "per_tool"; then
  _cm16_ok=false; _cm16_reason="${_cm16_reason:+$_cm16_reason; }stderr did not name 'per_tool'"
fi
if ! echo "$_cm16_err" | grep -qi "claud\b"; then
  _cm16_ok=false; _cm16_reason="${_cm16_reason:+$_cm16_reason; }stderr did not name the offending key 'claud'"
fi
if ! echo "$_cm16_err" | grep -qi "claude.*pi\|allowed"; then
  _cm16_ok=false; _cm16_reason="${_cm16_reason:+$_cm16_reason; }stderr did not name the allowed set (claude, pi)"
fi

if [[ "$_cm16_ok" == "true" ]]; then
  pass 16 "unknown auth.per_tool.claud (typo) -> aborts loud, stderr names key + allowed set"
else
  fail 16 "unknown auth.per_tool key abort loud" "$_cm16_reason (exit=$_cm16_exit, stderr=$_cm16_err)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM17 (resume guard, per-tool flip): stored labels claude=real, pi=real;
# current effective config sets per_tool.pi: none (claude unchanged) ->
# _up_resolve_resume_credential_mounts aborts loud NAMING "pi" specifically
# (not a generic message — the operator must know which tool's mount shape
# changed).
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
auth:
  per_tool:
    pi: none"   # current effective: claude=real (default), pi=none

_cm17_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm17-stub-XXXXXX")
cat > "${_cm17_stub_dir}/docker" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *"rc.auth.credential-mounts.claude"*) echo "real"; exit 0 ;;
  *"rc.auth.credential-mounts.pi"*) echo "real"; exit 0 ;;
  *"rc.auth.credential-mounts"*) echo "real"; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_cm17_stub_dir}/docker"

_cm17_err="" _cm17_exit=0
set +e
PATH="${_cm17_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_credential_mounts 'rc-cm17-test' '$TEST_WS'
" >/tmp/rc-cm17-out 2>/tmp/rc-cm17-err
_cm17_exit=$?
set -e
_cm17_err=$(cat /tmp/rc-cm17-err 2>/dev/null || true)
rm -rf "${_cm17_stub_dir}" /tmp/rc-cm17-out /tmp/rc-cm17-err

_cm17_ok=true _cm17_reason=""
if [[ "$_cm17_exit" -eq 0 ]]; then
  _cm17_ok=false; _cm17_reason="resolver returned 0 (should abort: pi flipped real->none)"
fi
if ! echo "$_cm17_err" | grep -qi "\bpi\b"; then
  _cm17_ok=false; _cm17_reason="${_cm17_reason:+$_cm17_reason; }error message did not name 'pi' specifically"
fi
if ! echo "$_cm17_err" | grep -qi "rc destroy"; then
  _cm17_ok=false; _cm17_reason="${_cm17_reason:+$_cm17_reason; }error message did not include 'rc destroy' remediation hint"
fi

if [[ "$_cm17_ok" == "true" ]]; then
  pass 17 "resume guard per-tool flip (pi real->none, claude unchanged) aborts loud naming pi"
else
  fail 17 "resume guard per-tool flip" "$_cm17_reason (exit=$_cm17_exit, stderr=$_cm17_err)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# CM18 (resume guard, legacy label ladder): a pre-xhgr container has ONLY the
# global rc.auth.credential-mounts label (no per-tool labels). When the
# effective per-tool values are UNCHANGED (both inherit the stored global),
# resume must NOT refuse (upgrading rc never bricks a running cage). When
# claude's effective value then flips, resume DOES refuse, naming "claude".
# ---------------------------------------------------------------------------
_cm18_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm18-stub-XXXXXX")
cat > "${_cm18_stub_dir}/docker" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  # Legacy container: per-tool labels are absent (empty), only the global
  # label was ever set (to "real").
  *"rc.auth.credential-mounts.claude"*) echo ""; exit 0 ;;
  *"rc.auth.credential-mounts.pi"*) echo ""; exit 0 ;;
  *"rc.auth.credential-mounts"*) echo "real"; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_cm18_stub_dir}/docker"

# Sub-case A: no .rip-cage.yaml at all -> both tools inherit "real" -> matches
# the legacy global label -> resume clean (exit 0).
setup_sandbox ""

_cm18a_exit=0
set +e
PATH="${_cm18_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_credential_mounts 'rc-cm18a-test' '$TEST_WS'
" >/tmp/rc-cm18a-out 2>/tmp/rc-cm18a-err
_cm18a_exit=$?
set -e
rm -f /tmp/rc-cm18a-out /tmp/rc-cm18a-err
teardown_sandbox

# Sub-case B: per_tool.claude: none -> claude's effective value flips away
# from the legacy global "real" -> resume refuses, naming "claude".
setup_sandbox "version: 1
auth:
  per_tool:
    claude: none"

_cm18b_err="" _cm18b_exit=0
set +e
PATH="${_cm18_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_credential_mounts 'rc-cm18b-test' '$TEST_WS'
" >/tmp/rc-cm18b-out 2>/tmp/rc-cm18b-err
_cm18b_exit=$?
set -e
_cm18b_err=$(cat /tmp/rc-cm18b-err 2>/dev/null || true)
rm -rf "${_cm18_stub_dir}" /tmp/rc-cm18b-out /tmp/rc-cm18b-err
teardown_sandbox

_cm18_ok=true _cm18_reason=""
if [[ "$_cm18a_exit" -ne 0 ]]; then
  _cm18_ok=false; _cm18_reason="sub-case A (legacy label, unchanged effective values): expected exit 0, got $_cm18a_exit"
fi
if [[ "$_cm18b_exit" -eq 0 ]]; then
  _cm18_ok=false; _cm18_reason="${_cm18_reason:+$_cm18_reason; }sub-case B (claude flips away from legacy global): expected non-zero abort, got 0"
fi
if ! echo "$_cm18b_err" | grep -qi "claude"; then
  _cm18_ok=false; _cm18_reason="${_cm18_reason:+$_cm18_reason; }sub-case B error message did not name 'claude'"
fi

if [[ "$_cm18_ok" == "true" ]]; then
  pass 18 "resume guard legacy-label ladder: pre-xhgr container (no per-tool labels) resumes clean when unchanged; flip aborts naming the tool"
else
  fail 18 "resume guard legacy label ladder" "$_cm18_reason"
fi

# ---------------------------------------------------------------------------
# CM19 (fingerprint, create/upgrade stability): fixture has a pi auth.json
# symlink present. Stored fp simulates a PRE-XHGR cage (fingerprint computed
# with the plain global value "real"). Current config has no auth.* key at
# all (default real for everything) -> effective(pi) == the prior global
# value ("real") -> the resume-side recompute must produce a BYTE-IDENTICAL
# fingerprint -> no spurious refusal on rc upgrade.
# ---------------------------------------------------------------------------
setup_sandbox ""
seed_symlink_auth_json

_cm19_stored_fp=$(HOME="$TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' rw follow file '$TEST_WS' real
")

_cm19_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm19-stub-XXXXXX")
cat > "${_cm19_stub_dir}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"rc.symlink-follow-fingerprint"*) echo "${_cm19_stored_fp}"; exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_cm19_stub_dir}/docker"

_cm19_exit=0
set +e
PATH="${_cm19_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_symlink_fingerprint 'rc-cm19-test' '$TEST_WS'
" >/tmp/rc-cm19-out 2>/tmp/rc-cm19-err
_cm19_exit=$?
set -e
rm -rf "${_cm19_stub_dir}" /tmp/rc-cm19-out /tmp/rc-cm19-err
teardown_sandbox

if [[ "$_cm19_exit" -eq 0 ]]; then
  pass 19 "fingerprint byte-identical across upgrade when effective(pi) == prior global -> resume clean"
else
  fail 19 "fingerprint upgrade stability" "expected exit 0, got $_cm19_exit"
fi

# ---------------------------------------------------------------------------
# CM20 (fingerprint, pi-only flip): stored fp computed with cred_mounts=real
# (matches CM19's fixture). Current config sets per_tool.pi: none (claude
# untouched) -> effective(pi)=none -> the resume-side recompute EXCLUDES the
# auth.json leaf -> fingerprint CHANGES -> resume aborts.
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
auth:
  per_tool:
    pi: none"
seed_symlink_auth_json

_cm20_stored_fp=$(HOME="$TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' rw follow file '$TEST_WS' real
")

_cm20_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm20-stub-XXXXXX")
cat > "${_cm20_stub_dir}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"rc.symlink-follow-fingerprint"*) echo "${_cm20_stored_fp}"; exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_cm20_stub_dir}/docker"

_cm20_err="" _cm20_exit=0
set +e
PATH="${_cm20_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_symlink_fingerprint 'rc-cm20-test' '$TEST_WS'
" >/tmp/rc-cm20-out 2>/tmp/rc-cm20-err
_cm20_exit=$?
set -e
_cm20_err=$(cat /tmp/rc-cm20-err 2>/dev/null || true)
rm -rf "${_cm20_stub_dir}" /tmp/rc-cm20-out /tmp/rc-cm20-err
teardown_sandbox

_cm20_ok=true _cm20_reason=""
if [[ "$_cm20_exit" -eq 0 ]]; then
  _cm20_ok=false; _cm20_reason="expected non-zero abort on pi-only flip (real->none), got 0"
fi
if ! echo "$_cm20_err" | grep -qi "destroy"; then
  _cm20_ok=false; _cm20_reason="${_cm20_reason:+$_cm20_reason; }error message did not include 'destroy' remediation hint"
fi

if [[ "$_cm20_ok" == "true" ]]; then
  pass 20 "fingerprint resume-side recompute changes on pi-only flip (claude untouched)"
else
  fail 20 "fingerprint pi-only flip" "$_cm20_reason (exit=$_cm20_exit, stderr=$_cm20_err)"
fi

# ---------------------------------------------------------------------------
# CM21 (fingerprint, create/resume symmetry for a stable mixed cage): stored
# fp simulates what CREATE TIME computed for a {claude:real, pi:none} cage —
# i.e. effective(pi)=none, so the auth.json leaf is EXCLUDED from the stored
# fingerprint. Current config is the SAME unchanged mixed posture. The
# resume-side recompute must derive effective(pi)=none too (NOT the global
# "real") and match -> resume clean. This is the acceptance-critical case:
# a stable mixed-posture cage must not spuriously refuse resume.
# ---------------------------------------------------------------------------
setup_sandbox "version: 1
auth:
  credential_mounts: real
  per_tool:
    pi: none"
seed_symlink_auth_json

_cm21_stored_fp=$(HOME="$TEST_HOME" bash -c "
  source '$RC' 2>/dev/null
  _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' rw follow file '$TEST_WS' none
")

_cm21_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cm21-stub-XXXXXX")
cat > "${_cm21_stub_dir}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"rc.symlink-follow-fingerprint"*) echo "${_cm21_stored_fp}"; exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_cm21_stub_dir}/docker"

_cm21_exit=0
set +e
PATH="${_cm21_stub_dir}:$PATH" \
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_resume_symlink_fingerprint 'rc-cm21-test' '$TEST_WS'
" >/tmp/rc-cm21-out 2>/tmp/rc-cm21-err
_cm21_exit=$?
set -e
rm -rf "${_cm21_stub_dir}" /tmp/rc-cm21-out /tmp/rc-cm21-err
teardown_sandbox

if [[ "$_cm21_exit" -eq 0 ]]; then
  pass 21 "fingerprint create/resume symmetric for stable {claude:real,pi:none} cage -> resume clean, no spurious refusal"
else
  fail 21 "fingerprint create/resume symmetry for mixed posture" "expected exit 0, got $_cm21_exit"
fi

echo ""
echo "--- Results so far: ${FAILURES} failure(s) ---"
exit "$FAILURES"
