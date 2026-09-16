#!/usr/bin/env bash
# tests/test-doctor-exec-source-deleted.sh -- rip-cage-uod6 (charted from
# rip-cage-54q3's root cause): a host workspace deleted while its cage keeps
# running leaves /workspace a dead virtiofs mount; msb chdir()s to
# Workdir=/workspace before spawning, gets ENOENT, and reports it against
# the *program* name -- misleading (four investigations chased a missing
# binary before 54q3 found the real cause). `rc doctor <cage>` and
# checks the cage's rc.source.path label against the host and prints one
# "Fix-hint: ..." line naming the missing path and the
# 'rc destroy --force <cage>' remedy. (`rc exec` carried the same check until
# that verb retired -- rip-cage-ely4.10 / ADR-031 D3.)
#
# Host-only: drives the REAL `rc` binary (the doctor verb) against a
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
#   E1-E4  RETIRED with the `rc exec` verb (rip-cage-ely4.10) -- see the
#       block at the end of this file for what they covered and where the
#       surviving half lives.
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
# E1-E4 RETIRED with `rc exec` (rip-cage-ely4.10 / ADR-031 D3).
#
# They asserted that `rc exec <cage> -- <cmd>` prints the Fix-hint BEFORE msb's
# misleading ENOENT text, that the hint fires even when the command succeeds,
# that a healthy source produces no hint, and that the wrapped command's stderr
# STREAMS rather than buffering until exit (a real regression the first uod6
# implementation shipped).
#
# The verb is deleted -- a one-off command in a cage is `msb exec <cage> --
# <cmd>` -- so rc no longer wraps that call and has nowhere to put a hint or a
# stream to buffer. What is NOT lost is the diagnosis itself: `rc doctor <cage>`
# prints the same Fix-hint from the same predicate, and D1/D2/J1/J2 above cover
# it in both human and JSON form, including both negative controls.
#
# The four investigations this file exists to prevent chased a missing binary
# because msb reports a dead /workspace against the PROGRAM name. An operator
# running `msb exec` directly still sees that misleading text -- `rc doctor` is
# now the only place rc can explain it, which is worth knowing before anyone
# decides this file is fully covered.
# ---------------------------------------------------------------------------

echo ""
echo "=== test-doctor-exec-source-deleted.sh: ${FAILURES}/${TOTAL} failure(s) ==="
exit "$FAILURES"
