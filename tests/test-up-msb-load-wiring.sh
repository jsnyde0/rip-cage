#!/usr/bin/env bash
# tests/test-up-msb-load-wiring.sh -- regression guard for rip-cage-0v47:
# `rc up`'s image-absent/new-container provisioning block (cli/up.sh, the
# `if [[ "$_image_absent" == "true" ]]; then ... fi` block immediately
# before container creation) must call _build_msb_load, IN THE SAME SHELL,
# right after a successful _pull_or_build -- and _msb_warn_image_layer_drift
# right after THAT -- so a load that reports success but doesn't land is
# surfaced on the `rc up` path too, not just `rc build` (rip-cage-7bs3 /
# rip-cage-528o's existing coverage there).
#
# WHY THIS HARNESS SHAPE. `rc up`'s provisioning branch lives inline inside
# the (very large) cmd_up, not behind its own callable helper, and driving
# the REAL cmd_up end-to-end would require faking manifest checks, DCG
# translation, mount building, and a real `msb create` -- none of which this
# bead touches, and the bead's own hard constraint forbids creating a real
# cage. So instead of a full cmd_up e2e (tests/test-up-run-args-e2e.sh
# already owns that surface for other concerns), this file EXTRACTS the
# literal provisioning block straight out of a given up.sh-shaped file (the
# real cli/up.sh for the green case; a scratch mutated copy for the two red
# cases) via a unique, exact-match anchor line, and evals it in a
# controlled shell with:
#   - _pull_or_build stubbed to succeed (this file is not about provisioning
#     itself, T-suite of tests/test-build-flag-override.sh already owns
#     that)
#   - the REAL _build_msb_load and _msb_warn_image_layer_drift, sourced from
#     rc itself, running against PATH-stubbed fake docker/msb -- the same
#     fixture idiom tests/test-build-msb-load.sh's T6/T7 use: docker
#     produces a real-sized `docker save` archive and a real
#     `RootFS.Layers` array, msb's `load` reports success but `image
#     inspect` still fails -- i.e. exactly the "the load reported success
#     but the cache doesn't hold it" state the status-3 emitter exists to
#     catch.
#
# THE SUBSHELL TRAP (why a bare "was _build_msb_load invoked" assertion is
# worthless here). _build_msb_load communicates success via the
# _RC_MSB_LOAD_SUCCEEDED global (set to 1 on its one success path). A call
# site wrapped in a subshell or pipeline -- e.g. `( _build_msb_load ) ||
# true` -- still runs, still invokes a real `msb load`, and still LOOKS
# correct from the outside: msb load was genuinely called and reported
# success. But the `_RC_MSB_LOAD_SUCCEEDED=1` assignment happens inside the
# subshell and never reaches the parent shell that runs
# _msb_warn_image_layer_drift afterwards -- so the emitter's status-3 branch
# reads the flag as unset/0 and stays silent even though the load reported
# success and the cache still doesn't hold the image. This file's assertion
# is therefore never "was _build_msb_load invoked" (T2b/T2c in
# test-build-msb-load.sh already cover that at the unit level) -- it is
# "does the emitter's warning-or-not behaviour on the `rc up` path change
# the way the flag says it should", i.e. the flag's EFFECT in the PARENT
# shell.
#
# Coverage:
#   G1  green: against the REAL (fixed) cli/up.sh, load succeeds but msb's
#       cache still doesn't hold the image (status 3) -> the emitter warns,
#       and the flag reads 1 in the parent shell.
#   R1  RED when the call site is REMOVED: a scratch copy of cli/up.sh with
#       both the _build_msb_load and _msb_warn_image_layer_drift lines
#       deleted from the absent-branch block -> no warning, flag stays
#       unset -- demonstrated against the scratch copy, never the live file.
#   R2  RED when the call site is SUBSHELL-WRAPPED: a scratch copy with
#       `_build_msb_load || true` rewritten as `( _build_msb_load ) || true`
#       -> msb load genuinely runs and succeeds (visible in the call log),
#       but the flag is lost to the subshell -> no warning even though the
#       load "succeeded" -- demonstrated against the scratch copy, never the
#       live file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
UP_SH="${REPO_ROOT}/cli/up.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

FAKE_BIN=$(mktemp -d)
CALL_LOG=$(mktemp)
SCRATCH_DIR=$(mktemp -d)
cleanup() { rm -rf "$FAKE_BIN" "$CALL_LOG" "$SCRATCH_DIR"; }
trap cleanup EXIT

# Fake docker: `save` writes a plausibly-sized (>=1 MiB) archive so
# _build_msb_load's real-image-size guard lets it through to `msb load`;
# `image inspect --format '{{json .RootFS.Layers}}'` returns a real,
# non-empty layer list so the layer-diff comparator reaches msb-side status
# 3 rather than docker-side status 2 -- same fixture shape as
# tests/test-build-msb-load.sh's T6/T7.
cat > "$FAKE_BIN/docker" <<'FAKEEOF'
#!/usr/bin/env bash
echo "docker $*" >> "$RC_TEST_CALL_LOG"
case "${1:-}" in
  save)
    _out="" _prev=""
    for _a in "$@"; do
      [[ "$_prev" == "-o" ]] && _out="$_a"
      _prev="$_a"
    done
    [[ -n "$_out" ]] && dd if=/dev/zero of="$_out" bs=1024 count=1200 >/dev/null 2>&1
    exit 0
    ;;
  image)
    case "${2:-}" in
      inspect)
        _fmt="" _prev=""
        for _a in "$@"; do
          [[ "$_prev" == "--format" ]] && _fmt="$_a"
          _prev="$_a"
        done
        if [[ "$_fmt" == *"RootFS.Layers"* ]]; then
          echo '["sha256:aaaaaa","sha256:bbbbbb"]'
        else
          echo '{}'
        fi
        exit 0
        ;;
    esac
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKEEOF
chmod +x "$FAKE_BIN/docker"

# Fake msb: `load` always reports success (exit 0) -- the "load succeeded"
# half of the status-3 scenario; `image inspect` always fails (exit 1) --
# the "msb's cache still doesn't hold it" half.
cat > "$FAKE_BIN/msb" <<'FAKEEOF'
#!/usr/bin/env bash
echo "msb $*" >> "$RC_TEST_CALL_LOG"
case "${1:-}" in
  load)
    exit 0
    ;;
  image)
    case "${2:-}" in
      inspect) exit 1 ;;
    esac
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKEEOF
chmod +x "$FAKE_BIN/msb"

# extract_absent_block <up.sh-shaped-file> -- pulls the literal
# `if [[ "$_image_absent" == "true" ]]; then ... fi` block out of the given
# file via a unique, exact-match start anchor (the outer if is the only
# place in cli/up.sh with this exact bare condition -- the other two
# _image_absent reads are compound `would_action == would_create &&
# _image_absent == true` conditions, and the image-PRESENT branch compares
# against `false`) and an exact-match `  fi` terminator at the SAME
# (2-space) indent level -- the nested if/fi pairs inside this block sit at
# 4- and 6-space indent, so they never falsely terminate the extraction.
extract_absent_block() {
  awk '
    /^  if \[\[ "\$_image_absent" == "true" \]\]; then$/ { flag=1 }
    flag { print }
    flag && /^  fi$/ { exit }
  ' "$1"
}

# run_absent_block <up.sh-shaped-file> -- extracts that file's absent-branch
# provisioning block and evals it in a controlled shell: rc is sourced (so
# _build_msb_load / _msb_warn_image_layer_drift / json_error are the REAL
# functions), _pull_or_build is stubbed to succeed (this file is not about
# provisioning itself), and the block's own text supplies the rest verbatim
# -- so a REMOVED or SUBSHELL-WRAPPED call site in the source file changes
# what actually runs, not just what this test happens to assert.
run_absent_block() {
  local _block _script
  _block=$(extract_absent_block "$1")
  _script=$(mktemp)
  {
    echo "source '${RC}' 2>/dev/null"
    echo "IMAGE=rip-cage:latest"
    echo "OUTPUT_FORMAT=''"
    echo "_image_absent=true"
    echo '_pull_or_build() { return 0; }'
    echo "$_block"
    # shellcheck disable=SC2016  # intentional: this literal text is written
    # into the generated script file for the INNER bash to expand later, not
    # expanded by this outer echo.
    echo 'echo "RC_TEST_FLAG_AFTER=${_RC_MSB_LOAD_SUCCEEDED:-unset}"'
  } > "$_script"
  PATH="$FAKE_BIN:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" bash "$_script" 2>&1
  rm -f "$_script"
}

# ---------------------------------------------------------------------------
# G1: green -- against the REAL (fixed) cli/up.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== G1: real cli/up.sh -- load succeeds, msb cache still doesn't hold the image -> loud warning, flag=1 in the parent shell ==="
: > "$CALL_LOG"
_g1_out=$(run_absent_block "$UP_SH")

if grep -qF "msb load --tag rip-cage:latest" "$CALL_LOG"; then
  pass "G1a: the absent-branch block really invoked msb load (not a fixture skip)"
else
  fail "G1a: expected 'msb load --tag rip-cage:latest' in the call log" "$(cat "$CALL_LOG")"
fi
if grep -q "RC_TEST_FLAG_AFTER=1" <<<"$_g1_out"; then
  pass "G1b: _RC_MSB_LOAD_SUCCEEDED reads 1 in the PARENT shell after the block runs"
else
  fail "G1b: expected RC_TEST_FLAG_AFTER=1" "$_g1_out"
fi
if grep -q "could not be verified after 'msb load' reported success" <<<"$_g1_out"; then
  pass "G1c: the status-3 emitter warns on the rc up path (rip-cage-0v47's posture change)"
else
  fail "G1c: expected the unverified-image-cache warning on stderr" "$_g1_out"
fi

# ---------------------------------------------------------------------------
# R1: RED when the call site is REMOVED -- scratch copy only, never the
# live file.
# ---------------------------------------------------------------------------
echo ""
echo "=== R1: call site REMOVED (scratch copy) -> no warning, flag stays unset ==="
R1_FILE="${SCRATCH_DIR}/up-r1-removed.sh"
cp "$UP_SH" "$R1_FILE"
# Delete the two rip-cage-0v47 call lines (both the _build_msb_load and the
# _msb_warn_image_layer_drift invocation) from the absent-branch block,
# leaving everything else -- including their surrounding comments -- intact.
sed -i '' '/^    _build_msb_load || true$/d; /^    _msb_warn_image_layer_drift$/d' "$R1_FILE" 2>/dev/null \
  || sed -i '/^    _build_msb_load || true$/d; /^    _msb_warn_image_layer_drift$/d' "$R1_FILE"

if grep -q '^\s*_build_msb_load\b' <(extract_absent_block "$R1_FILE"); then
  echo "SETUP ERROR: R1 scratch file still contains a _build_msb_load call in the absent block" >&2
  fail "R1 setup: mutation did not remove the call site" "$(extract_absent_block "$R1_FILE")"
else
  : > "$CALL_LOG"
  _r1_out=$(run_absent_block "$R1_FILE")
  echo "--- R1 captured output (expected to show the RED: no warning) ---"
  echo "$_r1_out"
  echo "--- end R1 captured output ---"
  if ! grep -q "could not be verified after 'msb load' reported success" <<<"$_r1_out"; then
    pass "R1: removing the call site goes RED as expected -- no warning fires even though this scratch file is otherwise byte-identical to the fixed cli/up.sh"
  else
    fail "R1: expected NO warning once the call site is removed, but one fired anyway" "$_r1_out"
  fi
fi

# ---------------------------------------------------------------------------
# R2: RED when the call site is SUBSHELL-WRAPPED -- scratch copy only.
# ---------------------------------------------------------------------------
echo ""
echo "=== R2: call site SUBSHELL-WRAPPED (scratch copy) -> msb load still runs, but the flag is lost to the subshell -> no warning ==="
R2_FILE="${SCRATCH_DIR}/up-r2-subshell.sh"
cp "$UP_SH" "$R2_FILE"
sed -i '' 's/^    _build_msb_load || true$/    ( _build_msb_load ) || true/' "$R2_FILE" 2>/dev/null \
  || sed -i 's/^    _build_msb_load || true$/    ( _build_msb_load ) || true/' "$R2_FILE"

if grep -q '( _build_msb_load ) || true' <(extract_absent_block "$R2_FILE"); then
  pass "R2 setup: mutation applied -- the call site is now subshell-wrapped"
else
  fail "R2 setup: mutation did not apply" "$(extract_absent_block "$R2_FILE")"
fi
: > "$CALL_LOG"
_r2_out=$(run_absent_block "$R2_FILE")
echo "--- R2 captured output (expected to show the RED: msb load ran, but no warning) ---"
echo "$_r2_out"
echo "--- end R2 captured output ---"
if grep -qF "msb load --tag rip-cage:latest" "$CALL_LOG"; then
  pass "R2a: msb load genuinely ran (the subshell-wrapped call site still executes -- this is what makes the bug subtle)"
else
  fail "R2a: expected msb load to still be invoked even though the flag is lost" "$(cat "$CALL_LOG")"
fi
if grep -q "RC_TEST_FLAG_AFTER=unset" <<<"$_r2_out" || grep -q "RC_TEST_FLAG_AFTER=0" <<<"$_r2_out"; then
  pass "R2b: _RC_MSB_LOAD_SUCCEEDED did NOT reach the parent shell (lost to the subshell)"
else
  fail "R2b: expected the flag to read unset/0 in the parent shell" "$_r2_out"
fi
if ! grep -q "could not be verified after 'msb load' reported success" <<<"$_r2_out"; then
  pass "R2c: subshell-wrapping the call site goes RED as expected -- no warning fires even though msb load genuinely reported success (a bare 'was it invoked' assertion would have missed this entirely)"
else
  fail "R2c: expected NO warning once the call site is subshell-wrapped, but one fired anyway" "$_r2_out"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-up-msb-load-wiring.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-up-msb-load-wiring.sh: all ${TOTAL} tests passed ==="
