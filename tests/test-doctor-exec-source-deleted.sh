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
#   E1  rc exec <cage> -- true: source dir removed, `msb exec` fails with
#       the real ENOENT-shaped message from rip-cage-54q3's report -> hint
#       printed BEFORE msb's own text, exit code still propagates.
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

echo ""
echo "=== test-doctor-exec-source-deleted.sh: ${FAILURES}/${TOTAL} failure(s) ==="
exit "$FAILURES"
