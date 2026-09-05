#!/usr/bin/env bash
# tests/test-doctor-exec-source-deleted.sh -- rip-cage-uod6 (charted from
# rip-cage-54q3's root cause): a host workspace deleted while its cage keeps
# running leaves /workspace a dead virtiofs mount; msb chdir()s to
# Workdir=/workspace before spawning, gets ENOENT, and reports it against
# the *program* name -- misleading (four investigations chased a missing
# binary before 54q3 found the real cause). `rc doctor <cage>` and
# `rc exec <cage> -- <cmd>` now check the cage's rc.source.path label
# against the host and print one "Fix-hint: ..." line naming the missing
# path and the 'rc destroy --force <cage>' remedy.
#
# Host-only: drives the REAL `rc` binary (doctor + exec verbs) against a
# fake `msb` on PATH -- no live cage, no docker, no msb daemon, no `rc
# build`/`msb load`/`msb create`. Mirrors the FAKE_BIN / RC_TEST_CALL_LOG
# PATH-shim idiom from tests/test-build-msb-load.sh and the setup_fake_msb
# shape from tests/test-build-flag-override.sh.
#
# `rc doctor` cases use a STOPPED cage deliberately: the new
# source-path-missing check (_rc_source_path_missing_hint,
# cli/lib/container.sh) is a pure host-side `test -d`, placed in cmd_doctor
# BEFORE the "if running" branch (cli/doctor.sh) -- it runs identically on a
# stopped cage, and a stopped cage lets the fake msb skip every live-probe
# `msb exec` shape (beads/auth/skills/cwd/workspace/bd-version), keeping
# this shim minimal and honest about what the check actually depends on.
# `rc exec` requires a RUNNING cage (cmd_exec's own state guard), so those
# cases use Running state and a configurable `msb exec` outcome instead.
#
# Coverage:
#   D1  rc doctor <cage>: source dir removed -> prints the Fix-hint line
#       naming the missing path and 'rc destroy --force <cage>'.
#   D2  rc doctor <cage>: source dir present (healthy) -> prints NEITHER
#       this hint nor anything resembling one (negative control).
#   J1  rc doctor --output json <cage>: source dir removed -> carries a
#       source_path_missing_hint field naming the missing path
#       (rip-cage-u625, Surface 2 of rip-cage-uod6's follow-up).
#   J2  rc doctor --output json <cage>: source dir present (healthy) ->
#       carries NO source_path_missing_hint key at all (negative control).
#   E1  rc exec <cage> -- true: source dir removed, `msb exec` fails with
#       the real ENOENT-shaped message from rip-cage-54q3's report -> hint
#       printed BEFORE msb's own text, exit code still propagates.
#   E3  rc exec <cage> -- true: source dir removed but the command
#       SUCCEEDS -> the hint still fires (pre-exec check semantics)
#   E4  regression guard: the wrapped command's stderr STREAMS live and is
#       never buffered until exit (the first uod6 implementation buffered it)
#   E2  rc exec <cage> -- true: source dir present, exec succeeds -> no
#       hint, no spurious text, exit 0 (negative control).
#
# Wired into tests/run-host.sh (host-only tier).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

echo "=== test-doctor-exec-source-deleted.sh ==="
echo ""

FAKE_BIN=$(mktemp -d)
TEST_HOME=$(mktemp -d)
MISSING_SOURCE="${TEST_HOME}/deleted-workspace"    # deliberately never created
HEALTHY_SOURCE="${TEST_HOME}/healthy-workspace"
mkdir -p "$HEALTHY_SOURCE" "${TEST_HOME}/.config/rip-cage"
touch "${TEST_HOME}/.config/rip-cage/tools.yaml"
cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist: []
  allow_risky: null
YAML

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$FAKE_BIN" "$TEST_HOME"; }
trap cleanup EXIT

# Fake msb: `inspect` reports FAKE_MSB_STATE (default Running) and the
# rc.source.path label FAKE_MSB_SOURCE_PATH; `exec` exits/emits per
# FAKE_MSB_EXEC_EXIT / FAKE_MSB_EXEC_STDERR (both default to a clean
# success -- each case below overrides only what it needs).
cat > "${FAKE_BIN}/msb" <<'FAKEEOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    echo "msb 0.0.0-fake"
    exit 0
    ;;
  inspect)
    jq -nc \
      --arg status "${FAKE_MSB_STATE:-Running}" \
      --arg source_path "${FAKE_MSB_SOURCE_PATH:-}" \
      '{status: $status, updated_at: null, config: {manifest_digest: "sha256:fake", labels: {"rc.source.path": $source_path}, mounts: []}}'
    exit 0
    ;;
  exec)
    if [[ -n "${FAKE_MSB_EXEC_STDERR:-}" ]]; then
      printf '%s\n' "$FAKE_MSB_EXEC_STDERR" >&2
    fi
    # FAKE_MSB_EXEC_SLEEP holds the process open AFTER writing stderr, so a
    # caller can observe whether that stderr reached the terminal live or was
    # buffered until exit (E4).
    if [[ -n "${FAKE_MSB_EXEC_SLEEP:-}" ]]; then
      sleep "$FAKE_MSB_EXEC_SLEEP"
    fi
    exit "${FAKE_MSB_EXEC_EXIT:-0}"
    ;;
  *)
    exit 0
    ;;
esac
FAKEEOF
chmod +x "${FAKE_BIN}/msb"

run_rc() {
  PATH="${FAKE_BIN}:${PATH}" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" "$RC" "$@"
}

# ---------------------------------------------------------------------------
# D1: rc doctor, deleted workspace source -> Fix-hint line
# ---------------------------------------------------------------------------
echo "-- D1: rc doctor <cage>, source dir removed -- Fix-hint printed --"
export FAKE_MSB_STATE="Stopped"
export FAKE_MSB_SOURCE_PATH="$MISSING_SOURCE"
D1_OUT=$(run_rc doctor d1-cage 2>&1)
D1_RC=$?
unset FAKE_MSB_STATE FAKE_MSB_SOURCE_PATH

if echo "$D1_OUT" | grep -qF "Fix-hint: workspace source deleted — '${MISSING_SOURCE}' no longer exists on the host"; then
  pass "D1a rc doctor names the missing source path"
else
  fail "D1a rc doctor names the missing source path" "got: $D1_OUT"
fi
if echo "$D1_OUT" | grep -qF "rc destroy --force d1-cage"; then
  pass "D1b rc doctor names the destroy remedy"
else
  fail "D1b rc doctor names the destroy remedy" "got: $D1_OUT"
fi
if [[ "$D1_RC" -eq 0 ]]; then
  pass "D1c rc doctor still exits 0 (a probe finding, not an abort)"
else
  fail "D1c rc doctor still exits 0" "got exit $D1_RC"
fi

# ---------------------------------------------------------------------------
# D2: rc doctor, healthy workspace source -> negative control, no hint
# ---------------------------------------------------------------------------
echo "-- D2: rc doctor <cage>, source dir present -- no hint (negative control) --"
export FAKE_MSB_STATE="Stopped"
export FAKE_MSB_SOURCE_PATH="$HEALTHY_SOURCE"
D2_OUT=$(run_rc doctor d2-cage 2>&1)
D2_RC=$?
unset FAKE_MSB_STATE FAKE_MSB_SOURCE_PATH

if ! echo "$D2_OUT" | grep -qF "Fix-hint"; then
  pass "D2a rc doctor prints no Fix-hint for a healthy workspace source"
else
  fail "D2a rc doctor prints no Fix-hint for a healthy workspace source" "got: $D2_OUT"
fi
if [[ "$D2_RC" -eq 0 ]]; then
  pass "D2b rc doctor exits 0"
else
  fail "D2b rc doctor exits 0" "got exit $D2_RC"
fi

# ---------------------------------------------------------------------------
# J1: rc doctor --output json, deleted workspace source -> hint field present,
#     naming the missing path (rip-cage-u625, scope narrowed to Surface 2
#     only -- see the bead's NARROWED comment). Parse with jq, not substring
#     matching of raw output.
# ---------------------------------------------------------------------------
echo "-- J1: rc doctor --output json <cage>, source dir removed -- hint field present --"
export FAKE_MSB_STATE="Stopped"
export FAKE_MSB_SOURCE_PATH="$MISSING_SOURCE"
J1_OUT=$(run_rc --output json doctor j1-cage 2>&1)
J1_RC=$?
unset FAKE_MSB_STATE FAKE_MSB_SOURCE_PATH

J1_HINT=$(echo "$J1_OUT" | jq -r '.source_path_missing_hint // empty' 2>/dev/null)
if [[ "$J1_HINT" == "Fix-hint: workspace source deleted — '${MISSING_SOURCE}' no longer exists on the host; remedy: rc destroy --force j1-cage" ]]; then
  pass "J1a rc doctor --output json carries a hint field naming the missing source path"
else
  fail "J1a rc doctor --output json carries a hint field naming the missing source path" "got: $J1_OUT"
fi
if [[ "$J1_RC" -eq 0 ]]; then
  pass "J1b rc doctor --output json still exits 0"
else
  fail "J1b rc doctor --output json still exits 0" "got exit $J1_RC; output: $J1_OUT"
fi

# ---------------------------------------------------------------------------
# J2: rc doctor --output json, healthy workspace source -> negative control:
#     no hint field at all (not merely an empty-string value -- a healthy
#     cage's JSON must not carry the key).
# ---------------------------------------------------------------------------
echo "-- J2: rc doctor --output json <cage>, source dir present -- no hint field (negative control) --"
export FAKE_MSB_STATE="Stopped"
export FAKE_MSB_SOURCE_PATH="$HEALTHY_SOURCE"
J2_OUT=$(run_rc --output json doctor j2-cage 2>&1)
J2_RC=$?
unset FAKE_MSB_STATE FAKE_MSB_SOURCE_PATH

if echo "$J2_OUT" | jq -e 'has("source_path_missing_hint")' >/dev/null 2>&1; then
  fail "J2a rc doctor --output json carries no hint field for a healthy workspace source" "got: $J2_OUT"
else
  pass "J2a rc doctor --output json carries no hint field for a healthy workspace source"
fi
if [[ "$J2_RC" -eq 0 ]]; then
  pass "J2b rc doctor --output json exits 0"
else
  fail "J2b rc doctor --output json exits 0" "got exit $J2_RC; output: $J2_OUT"
fi

# ---------------------------------------------------------------------------
# E1: rc exec, deleted workspace source, real ENOENT-shaped msb failure ->
#     hint printed BEFORE msb's own (misleading) text.
# ---------------------------------------------------------------------------
echo "-- E1: rc exec <cage> -- true, source dir removed -- hint before msb's ENOENT text --"
export FAKE_MSB_STATE="Running"
export FAKE_MSB_SOURCE_PATH="$MISSING_SOURCE"
export FAKE_MSB_EXEC_EXIT=1
export FAKE_MSB_EXEC_STDERR='error: failed to exec "true" -> not found: spawn "true": No such file or directory (os error 2) (ENOENT)'
E1_OUT=$(run_rc exec e1-cage -- true 2>&1)
E1_RC=$?
unset FAKE_MSB_STATE FAKE_MSB_SOURCE_PATH FAKE_MSB_EXEC_EXIT FAKE_MSB_EXEC_STDERR

if echo "$E1_OUT" | grep -qF "Fix-hint: workspace source deleted — '${MISSING_SOURCE}' no longer exists on the host"; then
  pass "E1a rc exec names the missing source path"
else
  fail "E1a rc exec names the missing source path" "got: $E1_OUT"
fi
if echo "$E1_OUT" | grep -qF "rc destroy --force e1-cage"; then
  pass "E1b rc exec names the destroy remedy"
else
  fail "E1b rc exec names the destroy remedy" "got: $E1_OUT"
fi
_e1_hint_line=$(echo "$E1_OUT" | grep -n "Fix-hint" | head -1 | cut -d: -f1)
_e1_enoent_line=$(echo "$E1_OUT" | grep -n "ENOENT" | head -1 | cut -d: -f1)
if [[ -n "$_e1_hint_line" && -n "$_e1_enoent_line" && "$_e1_hint_line" -lt "$_e1_enoent_line" ]]; then
  pass "E1c hint line precedes msb's raw ENOENT text"
else
  fail "E1c hint line precedes msb's raw ENOENT text" "hint_line=$_e1_hint_line enoent_line=$_e1_enoent_line; got: $E1_OUT"
fi
if [[ "$E1_RC" -eq 1 ]]; then
  pass "E1d rc exec still propagates msb's real exit code (1)"
else
  fail "E1d rc exec still propagates msb's real exit code (1)" "got exit $E1_RC"
fi

# ---------------------------------------------------------------------------
# E2: rc exec, healthy workspace source, exec succeeds -> negative control
# ---------------------------------------------------------------------------
echo "-- E2: rc exec <cage> -- true, source dir present -- no hint (negative control) --"
export FAKE_MSB_STATE="Running"
export FAKE_MSB_SOURCE_PATH="$HEALTHY_SOURCE"
export FAKE_MSB_EXEC_EXIT=0
export FAKE_MSB_EXEC_STDERR=""
E2_OUT=$(run_rc exec e2-cage -- true 2>&1)
E2_RC=$?
unset FAKE_MSB_STATE FAKE_MSB_SOURCE_PATH FAKE_MSB_EXEC_EXIT FAKE_MSB_EXEC_STDERR

if ! echo "$E2_OUT" | grep -qF "Fix-hint"; then
  pass "E2a rc exec prints no Fix-hint for a healthy workspace source"
else
  fail "E2a rc exec prints no Fix-hint for a healthy workspace source" "got: $E2_OUT"
fi
if [[ "$E2_RC" -eq 0 ]]; then
  pass "E2b rc exec exits 0"
else
  fail "E2b rc exec exits 0" "got exit $E2_RC; output: $E2_OUT"
fi

# ---------------------------------------------------------------------------
# E3: rc exec, deleted workspace source, but the wrapped command SUCCEEDS.
#
# The hint must still fire. This pins the semantics chosen when the driver's
# drift-review replaced the original stderr-capture-and-grep-for-ENOENT
# approach with a pre-exec check: a deleted host source dir means the
# /workspace virtiofs mount is ALREADY dead and every later exec will fail
# against it. msb's flip to a hard failure is not instant (~15s observed), so
# a command that still succeeds inside that window is precisely when naming
# the cause earns its keep. Under the old capture approach this case printed
# nothing at all.
# ---------------------------------------------------------------------------
echo "-- E3: rc exec <cage> -- true, source dir removed, command SUCCEEDS -- hint still printed --"
export FAKE_MSB_STATE="Running"
export FAKE_MSB_SOURCE_PATH="$MISSING_SOURCE"
export FAKE_MSB_EXEC_EXIT=0
export FAKE_MSB_EXEC_STDERR=""
E3_OUT=$(run_rc exec e3-cage -- true 2>&1)
E3_RC=$?
unset FAKE_MSB_STATE FAKE_MSB_SOURCE_PATH FAKE_MSB_EXEC_EXIT FAKE_MSB_EXEC_STDERR

if echo "$E3_OUT" | grep -qF "Fix-hint: workspace source deleted"; then
  pass "E3a hint fires on a deleted source even when the command succeeds"
else
  fail "E3a hint fires on a deleted source even when the command succeeds" "got: $E3_OUT"
fi
if [[ "$E3_RC" -eq 0 ]]; then
  pass "E3b the hint does not alter a successful exec's exit code"
else
  fail "E3b the hint does not alter a successful exec's exit code" "got exit $E3_RC; output: $E3_OUT"
fi

# ---------------------------------------------------------------------------
# E4: the wrapped command's stderr STREAMS -- it is not buffered until exit.
#
# REGRESSION GUARD (driver drift-review on rip-cage-uod6, 2026-09-04): the
# first implementation of the hint captured the wrapped command's stderr to a
# temp file so it could be grepped for ENOENT, and cat-ed it only after the
# command exited. That silently turned every `rc exec` into a buffered one --
# a long-running command inside a cage lost all live progress output, and
# most tools write progress to stderr. This arm fails if anything
# reintroduces that buffering.
#
# Method: the fake msb writes its stderr line and then holds the process open
# for FAKE_MSB_EXEC_SLEEP seconds. We start `rc exec` in the background with
# stderr redirected to a file, wait a fraction of that window, and require the
# line to have ALREADY landed. Margins are deliberately wide (write at t=0,
# observe at t=1s, process exits at t=4s) so an ordinary loaded machine does
# not flake.
# ---------------------------------------------------------------------------
echo "-- E4: rc exec streams the wrapped command's stderr, never buffers it to exit --"
export FAKE_MSB_STATE="Running"
export FAKE_MSB_SOURCE_PATH="$HEALTHY_SOURCE"
export FAKE_MSB_EXEC_EXIT=0
export FAKE_MSB_EXEC_STDERR="STREAM-PROBE: emitted at t=0"
export FAKE_MSB_EXEC_SLEEP=4
_e4_err=$(mktemp)
run_rc exec e4-cage -- true >/dev/null 2>"$_e4_err" &
_e4_pid=$!
sleep 1
_e4_seen_early=0
grep -qF "STREAM-PROBE" "$_e4_err" 2>/dev/null && _e4_seen_early=1
wait "$_e4_pid" || true
_e4_seen_final=0
grep -qF "STREAM-PROBE" "$_e4_err" 2>/dev/null && _e4_seen_final=1
rm -f "$_e4_err"
unset FAKE_MSB_STATE FAKE_MSB_SOURCE_PATH FAKE_MSB_EXEC_EXIT FAKE_MSB_EXEC_STDERR FAKE_MSB_EXEC_SLEEP

if [[ "$_e4_seen_final" -eq 1 ]]; then
  pass "E4a the wrapped command's stderr reaches the caller at all"
else
  fail "E4a the wrapped command's stderr reaches the caller at all" "stderr file never contained STREAM-PROBE"
fi
if [[ "$_e4_seen_early" -eq 1 ]]; then
  pass "E4b that stderr arrives WHILE the command is still running (not buffered until exit)"
else
  fail "E4b that stderr arrives WHILE the command is still running (not buffered until exit)" "STREAM-PROBE was absent 1s in but present after exit -- rc exec is buffering the wrapped command's stderr again"
fi

echo ""
echo "=== test-doctor-exec-source-deleted.sh: ${FAILURES}/${TOTAL} failure(s) ==="
exit "$FAILURES"
