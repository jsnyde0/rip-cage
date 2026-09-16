#!/usr/bin/env bash
if ! command -v docker > /dev/null 2>&1; then
  echo "SKIP: Docker not available -- skipping $(basename "$0")"
  exit 0
fi
set -uo pipefail

# Tests for --output json flag on the rc CLI
# These tests validate JSON output without requiring Docker containers.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# --- Test 1: rc script is valid bash ---
echo "=== Test 1: rc script is valid bash ==="
if bash -n "$RC" 2>&1; then
  pass "rc is valid bash"
else
  fail "rc has syntax errors"
fi

# --- Test 2: Usage text documents --output flag ---
echo ""
echo "=== Test 2: Usage text documents --output json ==="
usage_output=$("$RC" 2>&1 || true)
if echo "$usage_output" | grep -q "\-\-output"; then
  pass "usage mentions --output"
else
  fail "usage does not mention --output"
fi

# --- Tests 3 + 4 + 6: RETIRED with `rc ls` (rip-cage-ely4.10 / ADR-031 D3) ---
# These asserted that `--output json ls` returns a JSON array, that bare `rc ls`
# returns the human table instead, and that a global flag placed before the
# subcommand reaches it. The verb is deleted -- listing cages is `msb list`.
# The surviving half, "a global flag before the subcommand reaches it", is
# re-homed onto `rc up` in Test 7 just below, which already passes
# `--dry-run --output json` in exactly that position.

# --- Test 5: --output requires 'json' argument ---
echo ""
echo "=== Test 5: --output without json argument errors ==="
bad_output=$("$RC" --output foo doctor 2>&1) || true
if echo "$bad_output" | grep -qi "error\|requires"; then
  pass "--output foo produces error"
else
  fail "--output foo did not produce error. Got: $bad_output"
fi

# --- Test 7: rc up with no path defaults to current directory (dry-run) ---
echo ""
echo "=== Test 7: --output json up with no path defaults to current directory ==="
# rc up with no path should default to '.' — verify via dry-run (no Docker needed)
TEST_ALLOWED_DIR=$(mktemp -d)
TEST_GLOBAL_CFG_DIR=$(mktemp -d)
# The cage config must be resolved for the directory rc will default to,
# which is the cwd -- that IS what this case is checking (ADR-031 D2).
TEST_CAGE_CONF=$(cage_conf_for "$TEST_ALLOWED_DIR")
cd "$TEST_ALLOWED_DIR"
up_default=$(RC_CAGE_CONF="$TEST_CAGE_CONF" "$RC" --dry-run --output json up 2>/dev/null) || true
up_action=$(echo "$up_default" | jq -r '.action // empty' 2>/dev/null || true)
if [[ "$up_action" == would_* ]]; then
  pass "--output json up with no path defaults to '.' (dry_run action=$up_action)"
else
  fail "--output json up with no path did not default to '.'. Got: $up_default"
fi
rm -rf "$TEST_ALLOWED_DIR" "$TEST_GLOBAL_CFG_DIR"
cd "$SCRIPT_DIR"

# --- Test 8: check_docker surfaces JSON error when daemon is unreachable ---
echo ""
echo "=== Test 8: check_docker emits DOCKER_DAEMON_UNREACHABLE in JSON ==="
# Codes emitted by check_docker (rip-cage-3t1):
#   DOCKER_NOT_INSTALLED       — docker CLI absent
#   DOCKER_DAEMON_UNREACHABLE  — daemon not responsive (down OR wedged)
# Use `rc doctor --host` (which is bounded by RC_DOCKER_PREFLIGHT_TIMEOUT) as
# the precondition probe — a direct `docker info` here would hang against a
# wedged daemon, defeating the very class of bug this test guards against.
if ! "$RC" --output json doctor --host >/dev/null 2>&1; then
  up_docker_err=$("$RC" --output json up /tmp 2>&1) || true
  if echo "$up_docker_err" | jq -e '.code == "DOCKER_DAEMON_UNREACHABLE"' >/dev/null 2>&1; then
    pass "daemon-unreachable returns JSON error with DOCKER_DAEMON_UNREACHABLE code"
  else
    fail "daemon-unreachable did not return correct JSON error. Got: $up_docker_err"
  fi
else
  echo "SKIP: Docker is running, cannot test DOCKER_DAEMON_UNREACHABLE path"
fi

# --- Test 9: log function sends to stderr in JSON mode ---
echo ""
echo "=== Test 9: log sends to stderr in JSON mode ==="
# For cmd_build, in JSON mode the log message should go to stderr.
# Use a fake docker shim that returns immediately so this test completes in <5s
# even in CI where no image cache exists. rc's cmd_build emits `log "Building…"`
# to stderr BEFORE calling docker build, so the fake shim is sufficient to
# prevent the real 7-minute build while still exercising the log path.
_T9_FAKE_BIN=$(mktemp -d)
_t9_cleanup() { rm -rf "$_T9_FAKE_BIN"; }
trap '_t9_cleanup' EXIT
cat > "$_T9_FAKE_BIN/docker" <<'FAKEEOF'
#!/usr/bin/env bash
# Fake docker: accept any args and exit 0 immediately.
exit 0
FAKEEOF
chmod +x "$_T9_FAKE_BIN/docker"
build_stderr=$(PATH="$_T9_FAKE_BIN:$PATH" "$RC" --output json build 2>&1 1>/dev/null) || true
# In JSON mode, "Building..." should appear on stderr
if echo "$build_stderr" | grep -q "Building"; then
  pass "log message goes to stderr in JSON mode"
else
  # Docker may not be running, so build may fail, but the log should still appear
  fail "log message not found on stderr in JSON mode. stderr: $build_stderr"
fi
_t9_cleanup
trap - EXIT

# --- Test 10: --dry-run flag is accepted (parsed without error) ---
echo ""
echo "=== Test 10: --dry-run flag is accepted ==="
# --dry-run is supported on up and destroy only; every other verb rejects it.
# `ls` was this case's subject until it retired (rip-cage-ely4.10); `doctor` is
# a surviving verb on the same rejecting side of that split.
dryrun_exit=0
dryrun_output=$("$RC" --dry-run doctor 2>&1) || dryrun_exit=$?
if [[ $dryrun_exit -ne 0 ]]; then
  pass "--dry-run correctly rejected for the doctor command"
else
  fail "--dry-run should be rejected for doctor, but was accepted"
fi

# --- Test 11: RETIRED with `rc ls` (rip-cage-ely4.10 / ADR-031 D3) ---
# Asserted that every row of `rc ls --output json` carries a `mode` key. The
# verb is deleted; the per-cage depth it summarised is `rc doctor`, whose own
# JSON schema is pinned by tests/test-doctor-json-doc.sh.

# --- Test 12: --output json doctor labels carry rc.egress.config-override
# (rip-cage-hhh.6 D1 evolved by rip-cage-3vj2 / S4, ADR-029 D2) ---
# The doctor JSON's top-level "egress" object (mode/allowed_hosts/
# recent_blocks/ssh_allowed_hosts) probed the in-cage egress router, deleted
# per ADR-029 D2 (engine-deletion sweep). The ADR-024 D1 workspace
# base-URL-override posture (unrelated to the deleted engine) survives under
# its legacy label name in "labels".
echo ""
echo "=== Test 12: --output json doctor labels include rc.egress.config-override ==="
# rc doctor requires a running or stopped rc-managed container.
# `rc ls` used to name the first available cage; it retired with the six-verb
# thinning (rip-cage-ely4.10), so this reads the same fleet from msb directly —
# which is exactly the successor the deleted verb points at.
_doctor_test_name=$(
  msb list --format json 2>/dev/null | jq -r '(.sandboxes // . )[0].name // empty' 2>/dev/null || true
)
if [[ -n "$_doctor_test_name" ]]; then
  doctor12_output=$("$RC" --output json doctor "$_doctor_test_name" 2>/dev/null) || true
  if echo "$doctor12_output" | jq -e '.labels | has("rc.egress.config-override")' >/dev/null 2>&1; then
    pass "doctor --output json: labels include rc.egress.config-override"
  else
    fail "doctor --output json: labels missing rc.egress.config-override. Got: $doctor12_output"
  fi
else
  echo "SKIP: no rc-managed containers found — doctor egress-object test deferred (H-tier)"
fi

# --- Test 13: symlink-fingerprint MISMATCH on resume under --output json emits
# a stable {code} (rip-cage-7gr9 finding 2). Before this bead,
# _up_resolve_resume_symlink_fingerprint had no json_error path on either
# branch -- under --output json it emitted plain stderr text + exit 1 instead
# of a parseable {error, code}. Isolated-resolver idiom (source rc, stub
# `msb` for the label lookup, call the resolver directly) -- same technique
# as tests/test-dry-run-resume-guards.sh B1 / test-config-ro-mount.sh M6-M8.
# rip-cage-5iti (S10, msb migration test-suite port): retargeted the stub
# from `docker inspect --format` onto `msb inspect --format json`
# (cli/lib/msb_runtime.sh's `_msb_label`), since rip-cage-rj68 (S6) rewrote
# _up_resolve_resume_symlink_fingerprint onto msb.
echo ""
echo "=== Test 13: --output json resume symlink-fingerprint MISMATCH emits SYMLINK_FINGERPRINT_MOUNT_SHAPE_CHANGED ==="
_t13_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-t13-stub-XXXXXX")
cat > "${_t13_stub_dir}/msb" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*) echo '{"config":{"labels":{"rc.symlink-follow-fingerprint":"not-a-real-fingerprint-marker"}}}'; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${_t13_stub_dir}/msb"

_t13_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-t13-home-XXXXXX")

set +e
_t13_stdout=$(PATH="${_t13_stub_dir}:$PATH" HOME="$_t13_home" XDG_CONFIG_HOME="${_t13_home}/.config" bash -c "
  source '$RC' 2>/dev/null
  OUTPUT_FORMAT=json
  _up_resolve_resume_symlink_fingerprint 'rc-t13-test' '$_t13_home'
" 2>/tmp/rc-t13-err)
_t13_exit=$?
set +e
_t13_stderr=$(cat /tmp/rc-t13-err 2>/dev/null || true)

_t13_ok=true _t13_reason=""
if [[ "$_t13_exit" -eq 0 ]]; then
  _t13_ok=false; _t13_reason="resolver returned 0 (should abort -- stored fingerprint differs from current)"
fi
if ! echo "$_t13_stdout" | jq -e '.code == "SYMLINK_FINGERPRINT_MOUNT_SHAPE_CHANGED"' >/dev/null 2>&1; then
  _t13_ok=false; _t13_reason="${_t13_reason:+$_t13_reason; }stdout did not contain a parseable {code} JSON with SYMLINK_FINGERPRINT_MOUNT_SHAPE_CHANGED"
fi

rm -rf "${_t13_stub_dir}" "${_t13_home}"
rm -f /tmp/rc-t13-err

if [[ "$_t13_ok" == "true" ]]; then
  pass "symlink-fingerprint mismatch under --output json emits parseable {code: SYMLINK_FINGERPRINT_MOUNT_SHAPE_CHANGED}"
else
  fail "symlink-fingerprint mismatch json code -- ${_t13_reason} (exit=${_t13_exit}, stdout=${_t13_stdout}, stderr=${_t13_stderr})"
fi

# --- Cleanup ---
echo ""
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
