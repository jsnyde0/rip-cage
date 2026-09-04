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
cleanup() { rm -rf "$FAKE_BIN" "$CALL_LOG" "${FAKE_BIN_TINY_SAVE:-}" "${FAKE_BIN_NO_MSB:-}" "${E2E_HOME:-}" "${E2E_STDERR:-}"; }
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
  image)
    case "${2:-}" in
      inspect)
        # rip-cage-528o: the layer-diff_id comparator's docker-side probe
        # (`docker image inspect $IMAGE --format '{{json .RootFS.Layers}}'`,
        # _msb_image_layer_drift_status). Content-keyed on the --format
        # template (the same idiom tests/test-build-flag-override.sh's
        # setup_fake_docker uses) so every other `image inspect` caller keeps
        # the plain '{}' default. Serving a REAL layer array here is what
        # drives the comparator to status 3 (msb-side missing) instead of
        # status 2 (docker-side missing) -- T6/T7 both need status 3.
        _fmt="" _prev=""
        for _a in "$@"; do
          [[ "$_prev" == "--format" ]] && _fmt="$_a"
          _prev="$_a"
        done
        if [[ "$_fmt" == *"RootFS.Layers"* ]]; then
          echo "${RC_TEST_DOCKER_IMAGE_LAYERS:-[]}"
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

# Fake msb: only implements `load --tag <ref> -i <path>`. Exit code
# controlled by MSB_LOAD_EXIT so tests can force the failure branch.
cat > "$FAKE_BIN/msb" <<'FAKEEOF'
#!/usr/bin/env bash
echo "msb $*" >> "$RC_TEST_CALL_LOG"
case "${1:-}" in
  load)
    exit "${MSB_LOAD_EXIT:-0}"
    ;;
  image)
    case "${2:-}" in
      inspect)
        # rip-cage-528o: the comparator's msb-side probe (`msb image inspect
        # $IMAGE --format json`). Unset/empty RC_TEST_MSB_IMAGE_INSPECT ->
        # exit 1, which is the real `msb image inspect` contract for an image
        # that is NOT in msb's cache (probed live under rip-cage-7bs3) --
        # i.e. exactly the "the load did not land" state this bead exists to
        # make loud. Same shim shape as
        # tests/test-build-flag-override.sh's setup_fake_msb.
        if [[ -n "${RC_TEST_MSB_IMAGE_INSPECT:-}" ]]; then
          echo "$RC_TEST_MSB_IMAGE_INSPECT"
          exit 0
        fi
        exit 1
        ;;
      list)
        # rip-cage-12f2: the discriminator verb _msb_image_layer_drift_status
        # falls back to when `msb image inspect` exits non-zero -- tells
        # apart "msb genuinely doesn't have $IMAGE" (status 3, list omits
        # it -- the default here) from "$IMAGE IS in msb's cache but
        # inspect itself is unusable" (status 4, list includes it).
        echo "${RC_TEST_MSB_IMAGE_LIST:-[]}"
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
  image)
    case "${2:-}" in
      inspect)
        # rip-cage-528o: the layer-diff_id comparator's docker-side probe
        # (`docker image inspect $IMAGE --format '{{json .RootFS.Layers}}'`,
        # _msb_image_layer_drift_status). Content-keyed on the --format
        # template (the same idiom tests/test-build-flag-override.sh's
        # setup_fake_docker uses) so every other `image inspect` caller keeps
        # the plain '{}' default. Serving a REAL layer array here is what
        # drives the comparator to status 3 (msb-side missing) instead of
        # status 2 (docker-side missing) -- T6/T7 both need status 3.
        _fmt="" _prev=""
        for _a in "$@"; do
          [[ "$_prev" == "--format" ]] && _fmt="$_a"
          _prev="$_a"
        done
        if [[ "$_fmt" == *"RootFS.Layers"* ]]; then
          echo "${RC_TEST_DOCKER_IMAGE_LAYERS:-[]}"
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
# T6 (rip-cage-528o): a REAL build whose `msb load` reported success, but
# msb's cache does not actually hold $IMAGE afterwards (comparator status 3
# -- `msb image inspect` fails). Post-load, that means the load did not land,
# and before this bead the whole path was SILENT: _build_msb_load returns 0
# because msb load exited 0, and _msb_warn_image_layer_drift emitted only on
# status 1. The operator was never told the image cache was unverified.
#
# Must now be LOUD (naming the resync command) while staying ADVISORY --
# brain:rip-cage's binding 2026-09-03 posture: fail-loud, never fail-closed,
# so `rc build`'s exit code is unchanged and the emitter still returns 0.
# ---------------------------------------------------------------------------
echo ""
echo "=== T6: msb load reported success but msb's cache does not hold the image -> loud, still exit 0 ==="
: > "$CALL_LOG"
_t6_rc=0
_t6_out=$(PATH="$FAKE_BIN:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" MSB_LOAD_EXIT=0 \
  RC_TEST_DOCKER_IMAGE_LAYERS='["sha256:aaaaaa","sha256:bbbbbb"]' \
  bash -c "source '${RC}' 2>/dev/null; IMAGE=rip-cage:latest; _build_msb_load; _msb_warn_image_layer_drift" 2>&1) || _t6_rc=$?

if grep -q "^msb load" "$CALL_LOG"; then
  pass "T6: msb load WAS invoked (this is the real-build path, not a fixture skip)"
else
  fail "T6: expected msb load to have been invoked" "$(cat "$CALL_LOG")"
fi
if echo "$_t6_out" | grep -qi "could not be verified"; then
  pass "T6b: stderr carries a loud line saying the image cache could not be verified"
else
  fail "T6b: expected a 'could not be verified' warning" "$_t6_out"
fi
if echo "$_t6_out" | grep -qF "docker save rip-cage:latest | msb load --tag rip-cage:latest"; then
  pass "T6c: the warning names the resync command verbatim"
else
  fail "T6c: expected the resync command in the warning" "$_t6_out"
fi
if [[ "$_t6_rc" -eq 0 ]]; then
  pass "T6d: advisory only -- the sequence still returns 0 (never a gate on rc build)"
else
  fail "T6d: expected exit 0, got $_t6_rc" "$_t6_out"
fi

# ---------------------------------------------------------------------------
# T7 (rip-cage-528o, acceptance criterion 2 -- the NEGATIVE CONTROL for T6):
# the tiny-save fixture shape (every ad-hoc fake-docker PATH shim in this
# repo that never really implements `docker save`) hits the SAME comparator
# status 3 as T6 -- docker holds the image, msb does not. The only thing
# telling the two apart is that _build_msb_load never reached its
# load-succeeded path here, so _RC_MSB_LOAD_SUCCEEDED stays 0 and the
# emitter must stay COMPLETELY silent. This is what keeps
# tests/test-seed-drift-stderr-scoping.sh (and every other suite asserting
# clean/scoped `rc build` stderr) passing for the RIGHT reason.
#
# NOT vacuous, and not a duplicate of T5d: T5d only calls _build_msb_load,
# so it cannot see an over-eager emitter. T7 runs the full build-order
# sequence (_build_msb_load THEN _msb_warn_image_layer_drift) and asserts
# the comparator really did reach status 3, so removing the
# _RC_MSB_LOAD_SUCCEEDED gate on the status-3 branch makes T7 go RED
# (demonstrated during this bead, not merely asserted).
# ---------------------------------------------------------------------------
echo ""
echo "=== T7: fixture-shaped build (no real archive) hits the same status 3 -> stays SILENT ==="
: > "$CALL_LOG"
_t7_rc=0
_t7_out=$(PATH="$FAKE_BIN_TINY_SAVE:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" MSB_LOAD_EXIT=0 \
  RC_TEST_DOCKER_IMAGE_LAYERS='["sha256:aaaaaa","sha256:bbbbbb"]' \
  bash -c "source '${RC}' 2>/dev/null; IMAGE=rip-cage:latest; _build_msb_load; _msb_warn_image_layer_drift" 2>&1) || _t7_rc=$?

# Precondition guard: prove the emitting path was genuinely REACHED with the
# same status-3 condition T6 uses (docker side answers with a real layer
# array, msb side reports it does not hold the image). Without this, "no
# output" could pass for free because the comparator short-circuited earlier.
_t7_status=0
PATH="$FAKE_BIN_TINY_SAVE:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" \
  RC_TEST_DOCKER_IMAGE_LAYERS='["sha256:aaaaaa","sha256:bbbbbb"]' \
  bash -c "source '${RC}' 2>/dev/null; IMAGE=rip-cage:latest; _msb_image_layer_drift_status" >/dev/null 2>&1 || _t7_status=$?
if [[ "$_t7_status" -eq 3 ]]; then
  pass "T7: the comparator really does reach status 3 here (same condition as T6, so the silence below is not vacuous)"
else
  fail "T7: expected _msb_image_layer_drift_status 3, got $_t7_status" "silence assertion would be vacuous"
fi
if grep -q "^msb load" "$CALL_LOG"; then
  fail "T7b: msb load must never be invoked for a fixture-shaped archive" "$(cat "$CALL_LOG")"
else
  pass "T7b: msb load was never invoked, so the load-succeeded flag stays 0"
fi
if [[ -z "$_t7_out" ]]; then
  pass "T7c: zero stderr output from the full build-order sequence (no new line for fixture-shaped builds)"
else
  fail "T7c: expected complete silence, got" "$_t7_out"
fi
if [[ "$_t7_rc" -eq 0 ]]; then
  pass "T7d: sequence still returns 0"
else
  fail "T7d: expected exit 0, got $_t7_rc" "$_t7_out"
fi

# ---------------------------------------------------------------------------
# T8/T9/T10 (rip-cage-528o fix round, adversarial finding F3): CALL-SITE
# WIRING, driven end-to-end through the REAL cmd_build.
#
# Why this exists. T6/T7 above hand-compose the sequence
# (`_build_msb_load; _msb_warn_image_layer_drift`) themselves inside `bash
# -c` and never enter cmd_build; T4 below only greps cmd_build's body for
# the STRING `_build_msb_load`. Neither can see the property the whole fix
# depends on: that the two functions run in the SAME shell at the real call
# sites, so the `_RC_MSB_LOAD_SUCCEEDED` global actually reaches the
# emitter. Demonstrated: wrapping both call sites as `( _build_msb_load ) ||
# true` (cli/build.sh:560 and :592) puts the flag's assignment in a subshell
# where it can never propagate -- acceptance criterion 1 is then dead on
# every real host -- and BOTH named suites stayed fully green (21/21 and
# 154/154). These cases go RED under exactly that mutation.
#
# Both legs are covered because cmd_build has two of them, each with its own
# copy of the call pair. NOTE THE ORDER -- the JSON leg comes FIRST in the
# file: the pair at cli/build.sh:560/566 is inside the `OUTPUT_FORMAT ==
# json` branch (the `jq -nc '{image: ..., action: "built"}'` immediately
# after :566 is the tell), and the pair at :592/595 is the human-output
# `else` branch. Verified by mutation, not by reading: deleting :566 reddens
# T9b (JSON) alone, deleting :595 reddens T8b/T8c (human) alone. T8 passes
# an empty output-format and T9 passes "json", which is the mapping that
# matters. The JSON leg additionally has to keep
# stdout a single parseable JSON object with the warning on stderr ONLY --
# that is the whole reason _msb_warn_image_layer_drift prints to stderr.
#
# Harness shape: a minimal manifest sandbox plus stubbed root-owned
# validators, the same convention tests/test-build-flag-override.sh's
# setup_sandbox/run_cmd_build uses (this suite is about the load/verify
# wiring, not the validators). The PATH fakes are this file's own: real-sized
# `docker save` + a real `docker image inspect ... RootFS.Layers` array, and
# an `msb` whose `load` exits 0 but whose `image inspect` exits 1 -- i.e. the
# load reported success and the image is still not in msb's cache.
# ---------------------------------------------------------------------------
E2E_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-528o-e2e-home-XXXXXX")
E2E_STDERR=$(mktemp)
mkdir -p "${E2E_HOME}/.config/rip-cage"
cat > "${E2E_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist:
    - ".ssh"
    - ".gnupg"
    - ".aws"
  allow_risky: null
YAML

# run_cmd_build_e2e <fake-bin-dir> <output-format> -- runs the REAL cmd_build
# with the given PATH fakes. stdout is returned on this function's stdout;
# stderr is redirected to $E2E_STDERR so the two streams can be asserted
# separately (required by the JSON leg).
run_cmd_build_e2e() {
  local _e2e_bin="$1"
  local _e2e_fmt="$2"
  PATH="${_e2e_bin}:$PATH" \
  HOME="$E2E_HOME" \
  XDG_CONFIG_HOME="${E2E_HOME}/.config" \
  RC_TEST_CALL_LOG="$CALL_LOG" \
  MSB_LOAD_EXIT=0 \
  RC_TEST_DOCKER_IMAGE_LAYERS='["sha256:aaaaaa","sha256:bbbbbb"]' \
  RC_TEST_OUTPUT_FORMAT="$_e2e_fmt" \
  bash -c '
    source "'"${RC}"'"
    SCRIPT_DIR="'"${REPO_ROOT}"'"
    OUTPUT_FORMAT="${RC_TEST_OUTPUT_FORMAT:-}"
    # Positive-control stubs (same convention as
    # tests/test-build-flag-override.sh:run_cmd_build) -- the safety-floor
    # validators are not what these cases are about, and they need a real
    # built image to inspect.
    _manifest_check_binary_root_owned() { return 0; }
    _manifest_check_mount_root_owned() { return 0; }
    cmd_build
  ' rc-test-528o 2>"$E2E_STDERR"
}

echo ""
echo "=== T8: real cmd_build (human leg) -- load reported success, msb cache does not hold the image -> warning on stderr ==="
: > "$CALL_LOG"
: > "$E2E_STDERR"
_t8_rc=0
_t8_stdout=$(run_cmd_build_e2e "$FAKE_BIN" "") || _t8_rc=$?
_t8_stderr=$(cat "$E2E_STDERR")

if grep -q "^msb load" "$CALL_LOG"; then
  pass "T8: cmd_build really reached the msb load step (this is the real-build path, not a fixture skip)"
else
  fail "T8: expected cmd_build to invoke msb load" "$(cat "$CALL_LOG")"
fi
if echo "$_t8_stderr" | grep -qi "could not be verified"; then
  pass "T8b: cmd_build's OWN stderr carries the unverified-image-cache warning (proves the flag survives the real call site)"
else
  fail "T8b: expected a 'could not be verified' warning on cmd_build stderr" "$_t8_stderr"
fi
if echo "$_t8_stderr" | grep -qF "docker save rip-cage:latest | msb load --tag rip-cage:latest"; then
  pass "T8c: the warning names the resync command verbatim"
else
  fail "T8c: expected the resync command in cmd_build's stderr" "$_t8_stderr"
fi
if [[ "$_t8_rc" -eq 0 ]]; then
  pass "T8d: advisory only -- cmd_build still returns 0 (rc build's exit code is unchanged)"
else
  fail "T8d: expected cmd_build exit 0, got $_t8_rc" "$_t8_stderr"
fi

echo ""
echo "=== T9: real cmd_build (--output json leg) -- same warning, on stderr only, stdout stays valid JSON ==="
: > "$CALL_LOG"
: > "$E2E_STDERR"
_t9_rc=0
_t9_stdout=$(run_cmd_build_e2e "$FAKE_BIN" "json") || _t9_rc=$?
_t9_stderr=$(cat "$E2E_STDERR")

if grep -q "^msb load" "$CALL_LOG"; then
  pass "T9: the JSON leg reached the msb load step too"
else
  fail "T9: expected the JSON leg to invoke msb load" "$(cat "$CALL_LOG")"
fi
if echo "$_t9_stderr" | grep -qi "could not be verified"; then
  pass "T9b: the JSON leg's stderr carries the warning (its call site is wired independently of the human leg)"
else
  fail "T9b: expected a 'could not be verified' warning on the JSON leg's stderr" "$_t9_stderr"
fi
if jq -e . >/dev/null 2>&1 <<<"$_t9_stdout"; then
  pass "T9c: stdout is still valid JSON -- the warning never contaminates the machine-readable stream"
else
  fail "T9c: expected parseable JSON on stdout" "$_t9_stdout"
fi
if ! grep -qi "could not be verified" <<<"$_t9_stdout"; then
  pass "T9d: the warning text appears on stderr ONLY, never on stdout"
else
  fail "T9d: warning leaked onto stdout" "$_t9_stdout"
fi
if [[ "$_t9_rc" -eq 0 ]]; then
  pass "T9e: the JSON leg still returns 0 (advisory, never a gate)"
else
  fail "T9e: expected cmd_build exit 0, got $_t9_rc" "$_t9_stderr"
fi

echo ""
echo "=== T10: real cmd_build, tiny-save fixture -> msb load never invoked, no warning (negative control at the SAME call site) ==="
: > "$CALL_LOG"
: > "$E2E_STDERR"
_t10_rc=0
_t10_stdout=$(run_cmd_build_e2e "$FAKE_BIN_TINY_SAVE" "") || _t10_rc=$?
_t10_stderr=$(cat "$E2E_STDERR")

if grep -q "^msb load" "$CALL_LOG"; then
  fail "T10: msb load must never be invoked for a fixture-shaped archive" "$(cat "$CALL_LOG")"
else
  pass "T10: msb load was never invoked, so _RC_MSB_LOAD_SUCCEEDED stays 0 through the real call site"
fi
if ! echo "$_t10_stderr" | grep -qi "could not be verified"; then
  pass "T10b: zero unverified-image-cache warning from a real cmd_build over a fixture-shaped build"
else
  fail "T10b: expected no warning for the fixture-shaped build" "$_t10_stderr"
fi
if [[ "$_t10_rc" -eq 0 ]]; then
  pass "T10c: cmd_build still returns 0"
else
  fail "T10c: expected cmd_build exit 0, got $_t10_rc" "$_t10_stderr"
fi

# ---------------------------------------------------------------------------
# T11 (rip-cage-12f2): a REAL build whose `msb load` reported success, but
# `msb image inspect --format json` is UNUSABLE on this msb build (verb/flag
# unsupported -- exits non-zero) even though msb's cache genuinely DOES hold
# $IMAGE (`msb image list` lists it). Before this bead this hit the SAME
# comparator status (3) as T6's "load did not land" case and printed the
# SAME "could not be verified after 'msb load' reported success" / resync
# message -- misleading, since the image did land; the problem is msb's
# inspect verb, not the load. Must now be its own status (4) with its own
# message, and must NOT print T6's did-not-land wording.
# ---------------------------------------------------------------------------
echo ""
echo "=== T11: msb load reported success, image IS in msb's cache, but 'msb image inspect' is unusable -> distinct inspect-unusable message, not the did-not-land one ==="
: > "$CALL_LOG"
_t11_rc=0
_t11_out=$(PATH="$FAKE_BIN:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" MSB_LOAD_EXIT=0 \
  RC_TEST_DOCKER_IMAGE_LAYERS='["sha256:aaaaaa","sha256:bbbbbb"]' \
  RC_TEST_MSB_IMAGE_LIST='[{"reference":"rip-cage:latest"}]' \
  bash -c "source '${RC}' 2>/dev/null; IMAGE=rip-cage:latest; _build_msb_load; _msb_warn_image_layer_drift" 2>&1) || _t11_rc=$?

# Precondition guard (same idiom as T7): prove the comparator really lands on
# status 4 here, not 3 -- otherwise the message assertions below could pass
# vacuously against the wrong (or no) branch.
_t11_status=0
PATH="$FAKE_BIN:$PATH" RC_TEST_CALL_LOG="$CALL_LOG" \
  RC_TEST_DOCKER_IMAGE_LAYERS='["sha256:aaaaaa","sha256:bbbbbb"]' \
  RC_TEST_MSB_IMAGE_LIST='[{"reference":"rip-cage:latest"}]' \
  bash -c "source '${RC}' 2>/dev/null; IMAGE=rip-cage:latest; _msb_image_layer_drift_status" >/dev/null 2>&1 || _t11_status=$?
if [[ "$_t11_status" -eq 4 ]]; then
  pass "T11: the comparator reaches status 4 (inspect unusable, image IS listed) -- not 3"
else
  fail "T11: expected _msb_image_layer_drift_status 4, got $_t11_status" "message assertions below would be unreliable"
fi

if grep -q "^msb load" "$CALL_LOG"; then
  pass "T11b: msb load WAS invoked (this is the real-build path, not a fixture skip)"
else
  fail "T11b: expected msb load to have been invoked" "$(cat "$CALL_LOG")"
fi
if echo "$_t11_out" | grep -qi "unusable"; then
  pass "T11c: stderr carries the distinct inspect-unusable message"
else
  fail "T11c: expected an inspect-unusable warning" "$_t11_out"
fi
if echo "$_t11_out" | grep -qi "could not be verified"; then
  fail "T11d: the did-not-land ('could not be verified') message must NOT fire for an inspect-unusable host" "$_t11_out"
else
  pass "T11d: the did-not-land message does not fire (status 3 and 4 stay distinct)"
fi
if [[ "$_t11_rc" -eq 0 ]]; then
  pass "T11e: advisory only -- the sequence still returns 0"
else
  fail "T11e: expected exit 0, got $_t11_rc" "$_t11_out"
fi

# ---------------------------------------------------------------------------
# T4: structural wiring check -- cmd_build's body actually calls _build_msb_load
#
# rip-cage-zqjz.2: captured into a variable FIRST, rather than piped straight
# into `grep -q` -- under this file's own `set -uo pipefail` (line 40), a
# live `awk ... | grep -q ...` pipe is a real SIGPIPE race: `grep -q` exits
# on its FIRST match and closes its read end, and if awk still has more
# output queued (true once cmd_build's body -- now much larger under the
# rip-cage-zqjz.2 allowlist -- mentions `_build_msb_load` more than once,
# e.g. in an explanatory comment before the real call), awk can be killed by
# SIGPIPE on its next write. Under `pipefail`, that non-zero (128+SIGPIPE)
# awk exit status becomes the PIPELINE's exit status, overriding grep's own
# 0 -- so `if pipeline; then` reads false even though grep genuinely
# matched. Reproduced deterministically post-rip-cage-zqjz.2 (100% of runs,
# not flaky); a plain command-substitution capture has no live pipe for
# `grep -q` to race against, so this is immune regardless of how many times
# `_build_msb_load` appears in the extracted range going forward.
# ---------------------------------------------------------------------------
echo ""
echo "=== T4: cmd_build calls _build_msb_load (wiring) ==="
_t4_cmd_build_body=$(awk '/^cmd_build\(\)/{flag=1} flag && /^}/{print; exit} flag' "${REPO_ROOT}/cli/build.sh")
if grep -q '_build_msb_load' <<<"$_t4_cmd_build_body"; then
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
