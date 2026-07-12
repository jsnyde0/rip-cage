#!/usr/bin/env bash
# tests/test-up-msb-args-translate.sh -- unit tests for
# _up_translate_docker_args_to_msb (cli/up.sh, rip-cage-rj68 S6): the
# mechanical docker-run-argv -> msb-run-argv translator that lets the
# EXISTING mount/env-building logic (_up_prepare_docker_mounts,
# _up_prepare_environment -- worktree, symlink-follow, DCG, credential
# mounts, manifest mounts, all UNCHANGED by this bead) keep emitting its
# familiar docker `-v`/`-e`/`--label`/`--workdir` shape, while the actual
# sandbox gets created via msb. Most flags are byte-identical between the
# two runtimes (docker `-v SRC:DST[:OPTIONS]` and msb `-v SOURCE:DEST
# [:OPTIONS]` share the same grammar) -- this translator handles the small
# set of real differences.
#
# Pure host-side function test -- no docker/msb daemon required (argv
# shape only; live behavior of the translated flags is proven by the
# integration tests that actually boot a cage with them).
#
# Coverage:
#   T1  -v SRC:DST:delegated -> -v SRC:DST (delegated stripped, msb doesn't
#       recognize the macOS Docker Desktop cache-hint option)
#   T2  -v SRC:DST:ro -> passthrough unchanged
#   T3  -v SRC:DST (no options) -> passthrough unchanged
#   T4  -e KEY=VAL -> passthrough unchanged
#   T5  --label KEY=VAL -> passthrough unchanged
#   T6  --workdir DIR -> passthrough unchanged
#   T7  --mount type=bind,src=X,dst=Y,ro -> --mount-file X:Y:ro
#   T8  --cpus=N / --memory=Nm -> passthrough unchanged (same flag names)
#   T9  --memory-swap=Nm -> dropped (no msb equivalent)
#   T10 --pids-limit=N -> dropped (no msb equivalent on `msb create`)
#   T11 --add-host=host.docker.internal:host-gateway -> dropped
#   T12 --env-file FILE -> each KEY=VALUE line becomes its own -e KEY=VALUE
#       (comments and blank lines skipped, matching docker's env-file format)
#   T13 -p HOST:CONTAINER -> passthrough unchanged
#   T14 an unrecognized flag aborts loud (ADR-001 fail-loud: never silently
#       drop an unhandled docker arg)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

# shellcheck source=/dev/null
source "$RC" 2>/dev/null

run_translate() {
  # Calls _up_translate_docker_args_to_msb with "$@" as the docker-shaped
  # input array, echoes one output token per line.
  _up_translate_docker_args_to_msb "$@"
}

echo ""
echo "=== T1: -v SRC:DST:delegated -> -v SRC:DST ==="
T1_OUT=$(run_translate -v /a/b:/workspace:delegated)
T1_EXPECT=$'-v\n/a/b:/workspace'
if [[ "$T1_OUT" == "$T1_EXPECT" ]]; then
  pass "T1: :delegated stripped"
else
  fail "T1: unexpected output" "$T1_OUT"
fi

echo ""
echo "=== T2: -v SRC:DST:ro -> passthrough ==="
T2_OUT=$(run_translate -v /a/b:/c:ro)
if [[ "$T2_OUT" == $'-v\n/a/b:/c:ro' ]]; then
  pass "T2: :ro mount passthrough"
else
  fail "T2: unexpected output" "$T2_OUT"
fi

echo ""
echo "=== T3: -v SRC:DST (no options) -> passthrough ==="
T3_OUT=$(run_translate -v /a/b:/c)
if [[ "$T3_OUT" == $'-v\n/a/b:/c' ]]; then
  pass "T3: plain mount passthrough"
else
  fail "T3: unexpected output" "$T3_OUT"
fi

echo ""
echo "=== T4: -e KEY=VAL -> passthrough ==="
T4_OUT=$(run_translate -e FOO=bar)
if [[ "$T4_OUT" == $'-e\nFOO=bar' ]]; then
  pass "T4: env passthrough"
else
  fail "T4: unexpected output" "$T4_OUT"
fi

echo ""
echo "=== T5: --label KEY=VAL -> passthrough ==="
T5_OUT=$(run_translate --label "rc.source.path=/x/y")
if [[ "$T5_OUT" == $'--label\nrc.source.path=/x/y' ]]; then
  pass "T5: label passthrough"
else
  fail "T5: unexpected output" "$T5_OUT"
fi

echo ""
echo "=== T6: --workdir DIR -> passthrough ==="
T6_OUT=$(run_translate --workdir /workspace)
if [[ "$T6_OUT" == $'--workdir\n/workspace' ]]; then
  pass "T6: workdir passthrough"
else
  fail "T6: unexpected output" "$T6_OUT"
fi

echo ""
echo "=== T7: --mount type=bind,src=X,dst=Y,ro -> --mount-file X:Y:ro ==="
T7_OUT=$(run_translate --mount "type=bind,src=/host/dcg.toml,dst=/usr/local/lib/rip-cage/dcg/config.toml,ro")
T7_EXPECT=$'--mount-file\n/host/dcg.toml:/usr/local/lib/rip-cage/dcg/config.toml:ro'
if [[ "$T7_OUT" == "$T7_EXPECT" ]]; then
  pass "T7: docker long-form bind mount -> msb --mount-file"
else
  fail "T7: unexpected output" "$T7_OUT"
fi

echo ""
echo "=== T8: --cpus=N / --memory=Nm -> passthrough ==="
T8_OUT=$(run_translate --cpus=2 --memory=4g)
T8_EXPECT=$'--cpus=2\n--memory=4g'
if [[ "$T8_OUT" == "$T8_EXPECT" ]]; then
  pass "T8: cpus/memory passthrough"
else
  fail "T8: unexpected output" "$T8_OUT"
fi

echo ""
echo "=== T9: --memory-swap=Nm -> dropped ==="
T9_OUT=$(run_translate --cpus=2 --memory-swap=4g --memory=4g)
T9_EXPECT=$'--cpus=2\n--memory=4g'
if [[ "$T9_OUT" == "$T9_EXPECT" ]]; then
  pass "T9: memory-swap dropped, siblings preserved"
else
  fail "T9: unexpected output" "$T9_OUT"
fi

echo ""
echo "=== T10: --pids-limit=N -> dropped ==="
T10_OUT=$(run_translate --cpus=2 --pids-limit=500)
T10_EXPECT=$'--cpus=2'
if [[ "$T10_OUT" == "$T10_EXPECT" ]]; then
  pass "T10: pids-limit dropped, sibling preserved"
else
  fail "T10: unexpected output" "$T10_OUT"
fi

echo ""
echo "=== T11: --add-host=host.docker.internal:host-gateway -> dropped ==="
T11_OUT=$(run_translate --cpus=2 --add-host=host.docker.internal:host-gateway)
T11_EXPECT=$'--cpus=2'
if [[ "$T11_OUT" == "$T11_EXPECT" ]]; then
  pass "T11: add-host dropped, sibling preserved"
else
  fail "T11: unexpected output" "$T11_OUT"
fi

echo ""
echo "=== T12: --env-file FILE -> one -e KEY=VALUE per line ==="
T12_FILE=$(mktemp)
cat > "$T12_FILE" <<'EOF'
# a comment
FOO=bar

BAZ=qux
EOF
T12_OUT=$(run_translate --env-file "$T12_FILE")
T12_EXPECT=$'-e\nFOO=bar\n-e\nBAZ=qux'
rm -f "$T12_FILE"
if [[ "$T12_OUT" == "$T12_EXPECT" ]]; then
  pass "T12: env-file expanded to individual -e flags, comments/blanks skipped"
else
  fail "T12: unexpected output" "$T12_OUT"
fi

echo ""
echo "=== T13: -p HOST:CONTAINER -> passthrough ==="
T13_OUT=$(run_translate -p 8080:8080)
if [[ "$T13_OUT" == $'-p\n8080:8080' ]]; then
  pass "T13: port passthrough"
else
  fail "T13: unexpected output" "$T13_OUT"
fi

echo ""
echo "=== T14: unrecognized flag aborts loud ==="
T14_ERR=$(run_translate --network=host 2>&1 >/dev/null)
T14_RC=$?
if [[ "$T14_RC" -ne 0 ]] && echo "$T14_ERR" | grep -q "\-\-network"; then
  pass "T14: unrecognized flag aborts loud, naming it"
else
  fail "T14: expected non-zero exit naming the flag" "rc=$T14_RC err='$T14_ERR'"
fi

echo ""
echo "=== test-up-msb-args-translate.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
