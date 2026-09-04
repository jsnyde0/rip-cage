#!/usr/bin/env bash
# tests/test-run-host-image-tag-move-caveat.sh — rip-cage-or84's Verification
# target: a probe that pins the rip-cage:latest image ID at run START,
# repoints it to a deliberately DIFFERENT image mid-run, and asserts
# run-host.sh reports a named TAG-MOVED condition (a "CAVEAT" line) rather
# than a bare, uninformative probe failure.
#
# Background: rip-cage-sw6s's cause-classification pass found
# tests/test-pi-install.sh going RED with "pi: executable file not found",
# root-caused to a concurrent build repointing the shared rip-cage:latest tag
# mid-suite-run -- a red that carries no information about the code under
# test. rip-cage-or84 closes the mutable-tag producers (see
# tests/test-multiplexer-lifecycle.sh / tests/test-agent-mail-concurrent.sh)
# AND makes a residual mid-run move (e.g. a concurrent `rc build` from
# outside either suite -- always possible, not fully closeable) a NAMED
# condition instead of a mystery failure. This file is the harness target
# for the second half.
#
# Host-only, no live container: run-host.sh is invoked as a real subprocess
# (same idiom as tests/test-run-host-driver.sh) but with fake docker+msb on
# PATH (same idiom as tests/test-build-flag-override.sh) so the mid-run tag
# move is SIMULATED via a stateful fake `docker image inspect`, never a real
# retag against the real docker daemon. `--only` is pointed at a basename
# that matches no registered test file, so run-host.sh's real test-execution
# loop (_run_all_tests) attempts zero subprocesses -- fast, deterministic,
# and it never runs `rc build`, never sets RC_E2E, and never touches a real
# cage.
#
# Coverage:
#   T1  POSITIVE: fake docker returns a DIFFERENT image ID on the run-end
#       resolve than on the run-start resolve (simulating a mid-run
#       rip-cage:latest repoint) -> run-host.sh's stdout contains a CAVEAT
#       line naming both IDs, and the run still exits 0 (advisory only, see
#       T3).
#   T2  NEGATIVE CONTROL: fake docker returns the SAME image ID both times
#       (no tag move) -> no CAVEAT line anywhere in stdout, exit 0. Proves
#       T1's green is not vacuous -- the probe can tell the two cases apart.
#   T3  The CAVEAT never flips run-host.sh's exit status: both T1 and T2
#       exit 0 (TOTALS: PASS=0 FAIL=0 SKIP=0 either way, since --only
#       matches nothing) -- a tag move must never turn a PASS into a FAIL.
#
# RED demonstration (rip-cage-or84 Verification target's Invalidation
# clause): before this bead's run-host.sh fix (_rh_check_image_tag_moved),
# T1 fails -- today's run-host.sh never re-resolves the digest at run end
# and never prints a CAVEAT, so the assertion that one appears when the
# fake docker's second call differs from its first is unmet. Captured
# verbatim in the rip-cage-or84 ship-record (this file's PASS/FAIL bodies
# are unchanged either way -- the RED run used a HEAD-checked-out copy of
# the pre-fix run-host.sh via `git show HEAD:tests/run-host.sh`, not a
# modified version of this probe).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_HOST="${RUN_HOST_UNDER_TEST:-${SCRIPT_DIR}/run-host.sh}"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; }

MOCK_BIN=""
COUNT_FILE=""
cleanup() {
  [[ -n "${MOCK_BIN:-}" && -d "${MOCK_BIN:-}" ]] && rm -rf "$MOCK_BIN"
  [[ -n "${COUNT_FILE:-}" ]] && rm -f "$COUNT_FILE"
}
trap cleanup EXIT

# Fake docker: only `docker image inspect --format '{{.Id}}' rip-cage:latest`
# is meaningful here (the exact call _rh_resolve_image_digest makes).
# Stateful via a call-count file: 1st call returns RC_TEST_IMAGE_ID_1, every
# subsequent call returns RC_TEST_IMAGE_ID_2 -- so a caller that sets the two
# IDs equal gets a stable "no move" fixture, and a caller that sets them
# different gets a deterministic "moved between start and end" fixture,
# without any real docker daemon or real retag involved. Everything else
# (any other docker subcommand run-host.sh might invoke) is a harmless no-op
# -- run-host.sh never calls `docker build`/`docker run`/`docker tag` itself,
# but the fallback keeps this fixture forward-compatible if it ever does.
setup_fake_docker() {
  MOCK_BIN=$(mktemp -d "${TMPDIR:-/tmp}/rc-or84-tag-move-bin-XXXXXX")
  COUNT_FILE=$(mktemp "${TMPDIR:-/tmp}/rc-or84-tag-move-count-XXXXXX")
  echo 0 > "$COUNT_FILE"
  cat > "${MOCK_BIN}/docker" <<'FAKEEOF'
#!/usr/bin/env bash
case "${1:-}" in
  image)
    case "${2:-}" in
      inspect)
        shift 2
        _fmt="" _prev=""
        for _a in "$@"; do
          [[ "$_prev" == "--format" ]] && _fmt="$_a"
          _prev="$_a"
        done
        if [[ "$_fmt" == *".Id"* ]]; then
          _n="$(cat "$RC_TEST_DOCKER_CALL_COUNT_FILE" 2>/dev/null || echo 0)"
          _n=$((_n + 1))
          echo "$_n" > "$RC_TEST_DOCKER_CALL_COUNT_FILE"
          if [[ "$_n" -le 1 ]]; then
            echo "${RC_TEST_IMAGE_ID_1:-sha256:aaaaaaaaaaaa}"
          else
            echo "${RC_TEST_IMAGE_ID_2:-sha256:aaaaaaaaaaaa}"
          fi
          exit 0
        fi
        echo '{}'
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
FAKEEOF
  chmod +x "${MOCK_BIN}/docker"
  # Fake msb: run-host.sh's _warn_leftover_scratch_cages calls `msb list` /
  # `msb inspect` before the real pass. Shimmed the same way
  # tests/test-build-flag-override.sh shims msb alongside docker, so a host
  # with a real msb installed is never consulted by this probe.
  cat > "${MOCK_BIN}/msb" <<'FAKEEOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo "[]"; exit 0 ;;
  inspect) echo '{}'; exit 0 ;;
  *) exit 0 ;;
esac
FAKEEOF
  chmod +x "${MOCK_BIN}/msb"
}

# _run_probe id1 id2 -- runs run-host.sh under the fake docker/msb with
# --only pointed at a basename no registered test file matches, so
# _run_all_tests attempts zero real subprocesses. Echoes "EXIT=<code>" as
# the last line of output so callers can split stdout from the exit code
# from a single captured string.
_run_probe() {
  local id1="$1" id2="$2"
  local out rc=0
  out=$(PATH="${MOCK_BIN}:${PATH}" \
    RC_TEST_IMAGE_ID_1="$id1" \
    RC_TEST_IMAGE_ID_2="$id2" \
    RC_TEST_DOCKER_CALL_COUNT_FILE="$COUNT_FILE" \
    bash "$RUN_HOST" --only '__rip_cage_or84_no_such_test_file__' 2>&1) || rc=$?
  echo 0 > "$COUNT_FILE"
  printf '%s\nEXIT=%s\n' "$out" "$rc"
}

# ---------------------------------------------------------------------------
# T1: POSITIVE -- fake docker's two calls disagree -> CAVEAT line naming
# both IDs, exit still 0.
# ---------------------------------------------------------------------------
setup_fake_docker
ID_A="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
ID_B="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
t1_out="$(_run_probe "$ID_A" "$ID_B")"
t1_exit="$(printf '%s\n' "$t1_out" | grep -E '^EXIT=' | tail -1 | cut -d= -f2)"

if printf '%s\n' "$t1_out" | grep -q 'CAVEAT'; then
  pass "T1a run-host.sh prints a CAVEAT line when the image digest moves mid-run"
else
  fail "T1a run-host.sh prints a CAVEAT line when the image digest moves mid-run" "$t1_out"
fi

if printf '%s\n' "$t1_out" | grep -q "$ID_A" && printf '%s\n' "$t1_out" | grep -q "$ID_B"; then
  pass "T1b CAVEAT line names both the start and end image digests"
else
  fail "T1b CAVEAT line names both the start and end image digests" "$t1_out"
fi

if [[ "$t1_exit" == "0" ]]; then
  pass "T1c/T3 a detected tag move does not change run-host.sh's exit status (still 0)"
else
  fail "T1c/T3 a detected tag move does not change run-host.sh's exit status (still 0)" "exit=$t1_exit"
fi

# ---------------------------------------------------------------------------
# T2: NEGATIVE CONTROL -- fake docker's two calls agree -> no CAVEAT line,
# exit 0. Proves T1's result is not vacuous (the probe can tell the two
# cases apart).
# ---------------------------------------------------------------------------
ID_SAME="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
t2_out="$(_run_probe "$ID_SAME" "$ID_SAME")"
t2_exit="$(printf '%s\n' "$t2_out" | grep -E '^EXIT=' | tail -1 | cut -d= -f2)"

if printf '%s\n' "$t2_out" | grep -q 'CAVEAT'; then
  fail "T2a negative control: no CAVEAT line when the image digest does not move" "$t2_out"
else
  pass "T2a negative control: no CAVEAT line when the image digest does not move"
fi

if [[ "$t2_exit" == "0" ]]; then
  pass "T2b negative control: run-host.sh exits 0 with no tag move"
else
  fail "T2b negative control: run-host.sh exits 0 with no tag move" "exit=$t2_exit"
fi

echo ""
echo "TOTAL=${TOTAL} FAILURES=${FAILURES}"
exit $FAILURES
