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
#
# rip-cage-7yvy (RULING 2026-09-05, brain:rip-cage, option (a)) ADDS: the
# SAME extraction idiom, aimed at the DIFFERENT block that owns the OTHER
# _image_absent branch -- `if [[ "$_image_absent" == false ]]; then ... fi`
# (cli/up.sh, the image-PRESENT branch). Before this bead, "present" only
# ever meant "msb lists $IMAGE by NAME" (cli/up.sh:2474-2478) -- a name
# match with genuinely DIFFERENT layer content (status 1) never resynced,
# only ever warned, forever. The fix makes that branch msb-load docker's
# image, in the same shell, the same way the absent branch already does,
# then print one notice line naming both digests -- falling through to the
# EXISTING status-3/528o warning (this file's G1/R1/R2 above) when the load
# fails or can't be verified.
#
# Coverage (present-branch, this addition only):
#   P1  RED without the fix / GREEN with it: msb lists $IMAGE by name with
#       DIFFERENT diff_ids than docker (status 1) -> against the REAL
#       (fixed) cli/up.sh, the resync load fires and the notice prints;
#       against a scratch copy with the resync call site REMOVED, neither
#       does.
#   P2  exit code unchanged in the P1 scenario (both against the fixed file
#       and the neutered scratch copy).
#   P3  load-fails arm: 'msb load' reports success but msb's cache still
#       doesn't verifiably hold the image afterward (status 3) -> the
#       EXISTING rip-cage-528o warning text fires (not a duplicate/new
#       message), and exit is still 0.

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

# ===========================================================================
# rip-cage-7yvy additions below: the image-PRESENT branch
# (`if [[ "$_image_absent" == false ]]; then ... fi`).
# ===========================================================================

# extract_present_block <up.sh-shaped-file> -- same idiom as
# extract_absent_block above, aimed at the OTHER branch: the outer
# `if [[ "$_image_absent" == false ]]; then` is the only place in cli/up.sh
# with this exact bare condition (the absent branch above compares against
# "true", and the two would_action==would_create compound conditions are
# never a bare-`false` match), and the terminating `  fi` at the same
# 2-space indent is unique below it before any nested if/fi (those sit at
# 4-, 6- and 8-space indent).
extract_present_block() {
  awk '
    /^  if \[\[ "\$_image_absent" == false \]\]; then$/ { flag=1 }
    flag { print }
    flag && /^  fi$/ { exit }
  ' "$1"
}

# run_present_block <up.sh-shaped-file> <fake-bin-dir> -- extracts that
# file's present-branch drift-check block and evals it in a controlled
# shell, same shape as run_absent_block above but with two differences:
# _image_absent=false (this block never reads _pull_or_build, so no stub
# needed); the fake docker/msb PATH is a PARAMETER, since P1/P3 below need
# DIFFERENT msb fixture behaviour (a clean post-load resync vs. a load that
# reports success but still doesn't verifiably land) -- unlike the single
# shared $FAKE_BIN above, this helper takes the fixture directory
# explicitly; and the block (unlike the absent-branch one) declares its own
# `local`s (_drift_status, the two digest vars), so it is wrapped in a
# throwaway function here -- `local` outside a function is a bash error,
# and in real cli/up.sh this block already runs inside cmd_up, so the
# wrapper matches its real calling context rather than inventing a new one.
# Captures BOTH stdout+stderr AND the block's own exit status (echoed via $?
# into a trailing marker line) so callers can assert "exit code unchanged"
# (rip-cage-7yvy acceptance criterion 2) without a second re-run.
run_present_block() {
  local _up_file="$1" _fake_bin="$2"
  local _block _script _out
  _block=$(extract_present_block "$_up_file")
  _script=$(mktemp)
  {
    echo "source '${RC}' 2>/dev/null"
    echo "IMAGE=rip-cage:latest"
    echo "OUTPUT_FORMAT=''"
    echo "_image_absent=false"
    echo '_rc_test_present_block() {'
    echo "$_block"
    echo '}'
    echo '_rc_test_present_block'
    # shellcheck disable=SC2016  # intentional: literal text for the INNER
    # bash to expand later, not this outer echo. _RC_MSB_LOAD_SUCCEEDED is
    # set by _build_msb_load WITHOUT `local` (global by design -- see the
    # SUBSHELL TRAP note above), so it survives the wrapper function's
    # return just like it survives cmd_up's own scope in the real file.
    echo 'echo "RC_TEST_FLAG_AFTER=${_RC_MSB_LOAD_SUCCEEDED:-unset}"'
  } > "$_script"
  _out=$(PATH="$_fake_bin:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" bash "$_script" 2>&1)
  echo "RC_TEST_BLOCK_EXIT=$?"
  echo "$_out"
  rm -f "$_script"
}

# --- Fixture A: clean resync -- msb's cache holds $IMAGE under the SAME
# name as docker's but with DIFFERENT diff_ids (status 1, the bug this bead
# closes); after 'msb load' runs, msb's cache reports diff_ids that now
# MATCH docker's (status 0 -- a genuinely landed resync, the happy path).
# Stateful via a marker file 'msb load' touches, same call-log idiom as the
# absent-branch fixture above.
FAKE_BIN_RESYNC=$(mktemp -d)
LOAD_MARKER=$(mktemp -u)
cat > "$FAKE_BIN_RESYNC/docker" <<'FAKEEOF'
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
        elif [[ "$_fmt" == '{{.Id}}' ]]; then
          echo 'sha256:d0c4e2b1a3f5c7d9e1b3a5c7d9e1b3a5c7d9e1b3a5c7d9e1b3a5c7d9e1b3a5c7'
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
chmod +x "$FAKE_BIN_RESYNC/docker"
cat > "$FAKE_BIN_RESYNC/msb" <<FAKEEOF
#!/usr/bin/env bash
echo "msb \$*" >> "\$RC_TEST_CALL_LOG"
case "\${1:-}" in
  load)
    touch "${LOAD_MARKER}"
    exit 0
    ;;
  image)
    case "\${2:-}" in
      inspect)
        if [[ -f "${LOAD_MARKER}" ]]; then
          echo '{"layers":[{"diff_id":"sha256:aaaaaa"},{"diff_id":"sha256:bbbbbb"}]}'
        else
          echo '{"layers":[{"diff_id":"sha256:zzzzzz"}]}'
        fi
        exit 0
        ;;
      list)
        echo '[{"reference":"rip-cage:latest","digest":"sha256:5eba1ee2a1c3e5f7091b3d5f7091b3d5f7091b3d5f7091b3d5f7091b3d5f709"}]'
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
chmod +x "$FAKE_BIN_RESYNC/msb"

# ---------------------------------------------------------------------------
# P1/P2: against the REAL (fixed) cli/up.sh -- name present, content
# differs -> the resync load fires and the notice prints; exit unchanged.
# ---------------------------------------------------------------------------
echo ""
echo "=== P1/P2: real cli/up.sh -- msb holds '\$IMAGE' by name with DIFFERENT layer content than docker -> resync load fires, one notice printed, exit unchanged ==="
rm -f "$LOAD_MARKER"
: > "$CALL_LOG"
_p1_out=$(run_present_block "$UP_SH" "$FAKE_BIN_RESYNC")
_p1_ec=$(grep -o 'RC_TEST_BLOCK_EXIT=[0-9]*' <<<"$_p1_out" | head -1 | cut -d= -f2)

if grep -qF "msb load --tag rip-cage:latest" "$CALL_LOG"; then
  pass "P1a: the present-branch block really invoked msb load to resync (not a fixture skip)"
else
  fail "P1a: expected 'msb load --tag rip-cage:latest' in the call log" "$(cat "$CALL_LOG")"
fi
if grep -q "ran 'msb load' to resync msb's cache from docker" <<<"$_p1_out" && grep -q "rc doctor" <<<"$_p1_out"; then
  pass "P1b: the one-line resync notice prints and names 'rc doctor'"
else
  fail "P1b: expected the resync notice naming 'rc doctor'" "$_p1_out"
fi
if grep -qE "\(was [0-9a-f]+\).*\([0-9a-f]+\)" <<<"$_p1_out"; then
  pass "P1c: the notice names BOTH digests (msb's stale one, docker's current one)"
else
  fail "P1c: expected both digests named in the notice" "$_p1_out"
fi
if [[ "$_p1_ec" == "0" ]]; then
  pass "P2: exit code unchanged (0) for the present-branch drift-resync path"
else
  fail "P2: expected exit 0, got '$_p1_ec'" "$_p1_out"
fi

# ---------------------------------------------------------------------------
# P1-RED: RED when the resync call site is REMOVED -- scratch copy only.
# ---------------------------------------------------------------------------
echo ""
echo "=== P1-RED: resync call site REMOVED (scratch copy) -> no resync load, no notice ==="
P1R_FILE="${SCRATCH_DIR}/up-p1-removed.sh"
cp "$UP_SH" "$P1R_FILE"
sed -i '' '/^      _build_msb_load || true$/d' "$P1R_FILE" 2>/dev/null \
  || sed -i '/^      _build_msb_load || true$/d' "$P1R_FILE"

if grep -q '^\s*_build_msb_load\b' <(extract_present_block "$P1R_FILE"); then
  echo "SETUP ERROR: P1-RED scratch file still contains a _build_msb_load call in the present block" >&2
  fail "P1-RED setup: mutation did not remove the call site" "$(extract_present_block "$P1R_FILE")"
else
  rm -f "$LOAD_MARKER"
  : > "$CALL_LOG"
  _p1r_out=$(run_present_block "$P1R_FILE" "$FAKE_BIN_RESYNC")
  _p1r_ec=$(grep -o 'RC_TEST_BLOCK_EXIT=[0-9]*' <<<"$_p1r_out" | head -1 | cut -d= -f2)
  echo "--- P1-RED captured output (expected to show the RED: no resync, no notice) ---"
  echo "$_p1r_out"
  echo "--- end P1-RED captured output ---"
  if ! grep -qF "msb load --tag rip-cage:latest" "$CALL_LOG" \
      && ! grep -q "ran 'msb load' to resync msb's cache from docker" <<<"$_p1r_out"; then
    pass "P1-RED: removing the resync call site goes RED as expected -- no resync load, no notice, even though this scratch file is otherwise byte-identical to the fixed cli/up.sh"
  else
    fail "P1-RED: expected NO resync load and NO notice once the call site is removed" "$(cat "$CALL_LOG")"$'\n'"$_p1r_out"
  fi
  if [[ "$_p1r_ec" == "0" ]]; then
    pass "P1-RED exit: still exit 0 with the call site removed (the drift warning alone never gates)"
  else
    fail "P1-RED exit: expected exit 0, got '$_p1r_ec'" "$_p1r_out"
  fi
fi

# --- Fixture B: load-fails arm -- 'msb load' reports success (exit 0), but
# 'msb image inspect' still fails AFTERWARD (status 3: the load reported
# success but the cache does not verifiably hold the image) -- the EXACT
# rip-cage-528o scenario G1 above already covers on the absent branch, now
# reached via the present branch's new resync attempt.
FAKE_BIN_LOADFAILS=$(mktemp -d)
LOAD_MARKER_2=$(mktemp -u)
cp "$FAKE_BIN_RESYNC/docker" "$FAKE_BIN_LOADFAILS/docker"
chmod +x "$FAKE_BIN_LOADFAILS/docker"
cat > "$FAKE_BIN_LOADFAILS/msb" <<FAKEEOF
#!/usr/bin/env bash
echo "msb \$*" >> "\$RC_TEST_CALL_LOG"
case "\${1:-}" in
  load)
    touch "${LOAD_MARKER_2}"
    exit 0
    ;;
  image)
    case "\${2:-}" in
      inspect)
        if [[ -f "${LOAD_MARKER_2}" ]]; then
          exit 1
        fi
        echo '{"layers":[{"diff_id":"sha256:zzzzzz"}]}'
        exit 0
        ;;
      list)
        echo '[]'
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
chmod +x "$FAKE_BIN_LOADFAILS/msb"

# ---------------------------------------------------------------------------
# P3: load-fails arm -- msb load reports success but the cache still
# doesn't verifiably hold the image afterward -> falls through to the
# EXISTING rip-cage-528o warning, exit still 0.
# ---------------------------------------------------------------------------
echo ""
echo "=== P3: load-fails arm -- 'msb load' reports success but msb's cache still doesn't hold '\$IMAGE' afterward -> the EXISTING 528o warning fires, exit 0 ==="
rm -f "$LOAD_MARKER_2"
: > "$CALL_LOG"
_p3_out=$(run_present_block "$UP_SH" "$FAKE_BIN_LOADFAILS")
_p3_ec=$(grep -o 'RC_TEST_BLOCK_EXIT=[0-9]*' <<<"$_p3_out" | head -1 | cut -d= -f2)

if grep -qF "msb load --tag rip-cage:latest" "$CALL_LOG"; then
  pass "P3a: the resync load was attempted (msb load reported success -- this is what makes the arm reachable)"
else
  fail "P3a: expected 'msb load --tag rip-cage:latest' in the call log" "$(cat "$CALL_LOG")"
fi
if grep -q "could not be verified after 'msb load' reported success" <<<"$_p3_out"; then
  pass "P3b: falls through to the EXISTING rip-cage-528o warning (not a new/duplicate message)"
else
  fail "P3b: expected the existing 'could not be verified' warning" "$_p3_out"
fi
if [[ "$_p3_ec" == "0" ]]; then
  pass "P3c: exit code unchanged (0) even on the load-fails arm -- advisory, never a gate"
else
  fail "P3c: expected exit 0, got '$_p3_ec'" "$_p3_out"
fi

rm -rf "$FAKE_BIN_RESYNC" "$FAKE_BIN_LOADFAILS"
rm -f "$LOAD_MARKER" "$LOAD_MARKER_2"

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-up-msb-load-wiring.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-up-msb-load-wiring.sh: all ${TOTAL} tests passed ==="
