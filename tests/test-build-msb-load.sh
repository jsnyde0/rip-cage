#!/usr/bin/env bash
# tests/test-build-msb-load.sh -- unit tests for _build_msb_load (rip-cage-7dkq,
# S1 of the msb migration epic rip-cage-tsf2).
#
# `rc build` gains a one-time image-format conversion (docker save -> msb
# load) so a cage can boot from the just-built image on microsandbox (msb).
# Design (docs/2026-07-10-tsf2-decomposition.md S1 / findings §8b): "the
# build verb stays (image is the artifact), gains a thin msb load adoption
# step". Best-effort: most hosts during the migration don't have msb
# installed yet (rc up/create still run on Docker until S6 lands), so a
# missing `msb` binary must be a silent no-op, never a build failure. If
# `msb` IS present but the load step itself fails, that's a real problem and
# must surface loud on stderr.
#
# Host-only unit tests: fake docker + fake msb on PATH, call-logged to a
# scratch file so argv shape is asserted directly (no live daemon needed).
# The REAL effect-based boot proof (a real cage actually boots and a real
# in-guest command returns real output; negative control on an absent image)
# lives in tests/test-msb-boot-smoke.sh, which needs live docker+msb+a
# pre-built image and self-skips otherwise.
#
# Coverage:
#   T1  msb absent from PATH -> silent no-op: docker save NEVER called, returns 0
#   T2  msb present, docker save produces a plausible image (>=1 MiB) ->
#       `msb load --tag $IMAGE -i <tarfile>` invoked, returns 0
#   T3  msb present, load fails -> loud stderr warning naming the image, returns 1
#   T4  structural: cmd_build's body actually calls _build_msb_load (wiring
#       check -- a passing T1-T3 alone wouldn't prove the verb calls the helper)
#   T5  REGRESSION GUARD (found live during this bead's own verification,
#       breaking test-manifest-seed-drift.sh + the golden-master harness):
#       docker save produces an implausibly small/empty archive (the shape
#       every ad-hoc fake-docker PATH-shim fixture across this repo produces
#       when it doesn't implement `save` for real) -> msb load must NEVER be
#       invoked at all, and _build_msb_load returns 0 silently. Without this
#       guard, ANY existing test that fakes `docker build`/`docker save` for
#       the default `rip-cage:latest` tag reaches the REAL msb binary (if
#       installed on the host) with garbage input, producing spurious warning
#       stderr in tests that assert clean output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

FAKE_BIN=$(mktemp -d)
CALL_LOG=$(mktemp)
cleanup() { rm -rf "$FAKE_BIN" "$CALL_LOG" "${FAKE_BIN_TINY_SAVE:-}" "${FAKE_BIN_NO_MSB:-}"; }
trap cleanup EXIT

# Fake docker: only implements `save <image> -o <path>` -- writes a
# plausibly-sized (>=1 MiB) fake tar to the given path, so the real-image
# size guard (T5) lets it through to msb load.
cat > "$FAKE_BIN/docker" <<'FAKEEOF'
#!/usr/bin/env bash
echo "docker $*" >> "$RC_TEST_CALL_LOG"
case "${1:-}" in
  save)
    # Find the -o <path> argument.
    _out=""
    _prev=""
    for _a in "$@"; do
      [[ "$_prev" == "-o" ]] && _out="$_a"
      _prev="$_a"
    done
    if [[ -n "$_out" ]]; then
      dd if=/dev/zero of="$_out" bs=1024 count=1200 >/dev/null 2>&1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKEEOF
chmod +x "$FAKE_BIN/docker"

# Fake msb: only implements `load --tag <ref> -i <path>`. Exit code
# controlled by MSB_LOAD_EXIT so tests can force the failure branch.
cat > "$FAKE_BIN/msb" <<'FAKEEOF'
#!/usr/bin/env bash
echo "msb $*" >> "$RC_TEST_CALL_LOG"
case "${1:-}" in
  load)
    exit "${MSB_LOAD_EXIT:-0}"
    ;;
  *)
    exit 0
    ;;
esac
FAKEEOF
chmod +x "$FAKE_BIN/msb"

# Fake docker variant for T5: `save -o <path>` succeeds but writes a TINY
# file (mimics every permissive/partial fake-docker fixture across this repo
# that doesn't really implement `save` -- e.g. a bare `*) exit 0` catch-all
# with zero bytes written).
FAKE_BIN_TINY_SAVE=$(mktemp -d)
cat > "$FAKE_BIN_TINY_SAVE/docker" <<'FAKEEOF'
#!/usr/bin/env bash
echo "docker $*" >> "$RC_TEST_CALL_LOG"
case "${1:-}" in
  save)
    _out=""
    _prev=""
    for _a in "$@"; do
      [[ "$_prev" == "-o" ]] && _out="$_a"
      _prev="$_a"
    done
    [[ -n "$_out" ]] && printf 'x' > "$_out"   # 1 byte -- not a real image
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKEEOF
chmod +x "$FAKE_BIN_TINY_SAVE/docker"
cp "$FAKE_BIN/msb" "$FAKE_BIN_TINY_SAVE/msb"

# ---------------------------------------------------------------------------
# T1: msb absent from PATH -> silent no-op (no docker save call, returns 0)
# ---------------------------------------------------------------------------
echo ""
echo "=== T1: msb absent -> silent no-op ==="
: > "$CALL_LOG"
FAKE_BIN_NO_MSB=$(mktemp -d)
cp "$FAKE_BIN/docker" "$FAKE_BIN_NO_MSB/docker"
# Deliberately excludes any dir that carries a real `msb` binary (e.g.
# ~/.local/bin) -- only stock system + homebrew dirs, plus the fake docker.
_t1_rc=0
_t1_out=$(PATH="$FAKE_BIN_NO_MSB:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" RC_TEST_CALL_LOG="$CALL_LOG" \
  bash -c "source '${RC}' 2>/dev/null; IMAGE=rip-cage:latest; _build_msb_load" 2>&1) || _t1_rc=$?

if [[ "$_t1_rc" -eq 0 ]]; then
  pass "T1: returns 0 when msb is absent from PATH"
else
  fail "T1: expected exit 0, got $_t1_rc" "$_t1_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T1b: docker save never invoked when msb is absent"
else
  fail "T1b: expected no docker/msb calls, got" "$(cat "$CALL_LOG")"
fi

# ---------------------------------------------------------------------------
# T2: msb present, load succeeds -> correct argv on both sides of the pipe
# ---------------------------------------------------------------------------
echo ""
echo "=== T2: msb present, plausible image -> docker save -o <tmp> then msb load --tag IMAGE -i <tmp> ==="
: > "$CALL_LOG"
_t2_rc=0
_t2_out=$(PATH="$FAKE_BIN:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" MSB_LOAD_EXIT=0 \
  bash -c "source '${RC}' 2>/dev/null; IMAGE=rip-cage:latest; _build_msb_load" 2>&1) || _t2_rc=$?

if [[ "$_t2_rc" -eq 0 ]]; then
  pass "T2: returns 0 on success"
else
  fail "T2: expected exit 0, got $_t2_rc" "$_t2_out"
fi
if grep -qF "docker save rip-cage:latest" "$CALL_LOG"; then
  pass "T2b: docker save invoked with the built image tag"
else
  fail "T2b: expected 'docker save rip-cage:latest' in call log" "$(cat "$CALL_LOG")"
fi
if grep -qE "msb load --tag rip-cage:latest -i" "$CALL_LOG"; then
  pass "T2c: msb load invoked with --tag matching the built image, reading the saved archive via -i"
else
  fail "T2c: expected 'msb load --tag rip-cage:latest -i <path>' in call log" "$(cat "$CALL_LOG")"
fi

# ---------------------------------------------------------------------------
# T3: msb present, load fails -> loud stderr warning, non-zero return
# ---------------------------------------------------------------------------
echo ""
echo "=== T3: msb present, load fails -> loud stderr warning ==="
: > "$CALL_LOG"
_t3_rc=0
_t3_out=$(PATH="$FAKE_BIN:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" MSB_LOAD_EXIT=1 \
  bash -c "source '${RC}' 2>/dev/null; IMAGE=rip-cage:latest; _build_msb_load" 2>&1) || _t3_rc=$?

if [[ "$_t3_rc" -ne 0 ]]; then
  pass "T3: returns non-zero when msb load fails"
else
  fail "T3: expected non-zero exit, got 0" "$_t3_out"
fi
if echo "$_t3_out" | grep -qi "rip-cage:latest"; then
  pass "T3b: warning names the image tag that failed to load"
else
  fail "T3b: expected the image tag in the warning" "$_t3_out"
fi
if echo "$_t3_out" | grep -qi "msb"; then
  pass "T3c: warning mentions msb (actionable, not generic)"
else
  fail "T3c: expected 'msb' in the warning text" "$_t3_out"
fi

# ---------------------------------------------------------------------------
# T5: regression guard -- implausibly small `docker save` output (the shape
# every ad-hoc fake-docker fixture across this repo produces) must NEVER
# reach msb load at all.
# ---------------------------------------------------------------------------
echo ""
echo "=== T5: tiny/fake docker-save output -> msb load NEVER invoked, silent return 0 ==="
: > "$CALL_LOG"
_t5_rc=0
_t5_out=$(PATH="$FAKE_BIN_TINY_SAVE:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" MSB_LOAD_EXIT=0 \
  bash -c "source '${RC}' 2>/dev/null; IMAGE=rip-cage:latest; _build_msb_load" 2>&1) || _t5_rc=$?

if [[ "$_t5_rc" -eq 0 ]]; then
  pass "T5: returns 0 (silent) when docker save output is implausibly small"
else
  fail "T5: expected exit 0, got $_t5_rc" "$_t5_out"
fi
if grep -qF "docker save" "$CALL_LOG"; then
  pass "T5b: docker save WAS attempted (the guard fires after inspecting its output, not before)"
else
  fail "T5b: expected docker save to have been called" "$(cat "$CALL_LOG")"
fi
if grep -q "^msb load" "$CALL_LOG"; then
  fail "T5c: msb load must NEVER be invoked for an implausibly small archive" "$(cat "$CALL_LOG")"
else
  pass "T5c: msb load was never invoked (real msb binary is never reached with garbage input)"
fi
if [[ -z "$_t5_out" ]]; then
  pass "T5d: no stderr output at all (this must be silent, not a warning -- fixture noise, not a real problem)"
else
  fail "T5d: expected zero output, got" "$_t5_out"
fi

# ---------------------------------------------------------------------------
# T4: structural wiring check -- cmd_build's body actually calls _build_msb_load
# ---------------------------------------------------------------------------
echo ""
echo "=== T4: cmd_build calls _build_msb_load (wiring) ==="
if awk '/^cmd_build\(\)/{flag=1} flag && /^}/{print; exit} flag' "${REPO_ROOT}/cli/build.sh" \
  | grep -q '_build_msb_load'; then
  pass "T4: cmd_build's body calls _build_msb_load"
else
  fail "T4: _build_msb_load call not found inside cmd_build()" "$(grep -n 'cmd_build' "${REPO_ROOT}/cli/build.sh")"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-build-msb-load.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-build-msb-load.sh: all ${TOTAL} tests passed ==="
