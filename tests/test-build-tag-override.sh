#!/usr/bin/env bash
# tests/test-build-tag-override.sh -- rip-cage-fo4z: `rc build -t <tag>` must
# produce an image tagged ONLY <tag>; rip-cage:latest must be untouched.
#
# Bug: cli/build.sh's docker build invocations hardcode `-t "$IMAGE"` (default
# rip-cage:latest) FIRST, then append caller args ("$@") -- so `rc build -t
# custom:tag` becomes `docker build -t rip-cage:latest -t custom:tag ...` and
# docker applies BOTH tags to the SAME image, silently re-tagging (clobbering)
# rip-cage:latest with whatever was just built under the custom tag. Observed
# live 2026-07-29: a scratch-HOME default-manifest test build stripped the
# operator's composed `rc.multiplexers: herdr` label off rip-cage:latest.
#
# Fix under test: cmd_build parses a caller-supplied -t/--tag (both spellings,
# plus --tag=value) OUT of "$@" and lets it OVERRIDE the effective image name
# for the WHOLE build (the docker build call itself, the post-build root-owned
# validators, and the fail-closed untag-on-violation cleanup) -- not passed
# through as a second, additional tag.
#
# Host-only unit tests: fake docker on PATH, call-logged to a scratch file so
# the constructed `docker build` argv is asserted directly -- no image build
# needed (same pattern as tests/test-build-msb-load.sh / test-manifest-mount-mode.sh
# MG1/MG2: source rc directly, call cmd_build, override the manifest validators
# as no-op positive controls since this suite is about tag plumbing, not the
# validators themselves).
#
# Coverage:
#   T1  rc build -t <custom> -> docker build argv carries exactly ONE -t, and
#       its value is <custom>, NOT the default rip-cage:latest.
#   T2  Validators (_manifest_check_binary_root_owned) are invoked with the
#       EFFECTIVE (custom) image, not the default -- critical subtlety: $IMAGE
#       is also the post-build inspection handle, not just the docker tag.
#   T3  Positive control: no -t given -> default rip-cage:latest still used,
#       exactly one -t (regression guard on the untouched default path).
#   T4  --tag <value> (separate-arg spelling) works identically to -t.
#   T5  --tag=<value> (equals-form) works identically to -t.
#   T6  -t given twice -> last one wins; still exactly one -t in the argv.
#   T7  -t with no following value -> cmd_build fails BEFORE ever invoking
#       docker (fail loud, not silently drop or crash).
#   T8  Fail-closed cleanup (`docker image rm`) on a validator violation
#       removes the EFFECTIVE (custom) image, not the default -- otherwise the
#       fail-closed untag would remove the WRONG image (ADR-001 regression).
#   T9  Non-tag caller args (e.g. --no-cache) still pass through untouched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

TEST_HOME=""
CALL_LOG=""
VALIDATOR_LOG=""

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  [[ -n "${CALL_LOG:-}" ]] && rm -f "$CALL_LOG"
  [[ -n "${VALIDATOR_LOG:-}" ]] && rm -f "$VALIDATOR_LOG"
  [[ -n "${MOCK_BIN:-}" && -d "${MOCK_BIN:-}" ]] && rm -rf "$MOCK_BIN"
}
trap cleanup EXIT

# Minimal manifest sandbox -- same shape as test-manifest-mount-mode.sh's
# setup_manifest_sandbox (denylist config.yaml required by manifest machinery).
setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-build-tag-override-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist:
    - ".ssh"
    - ".gnupg"
    - ".aws"
  allow_risky: null
YAML
}

MOCK_BIN=""

# Fake docker: logs every invocation ("docker $*") to CALL_LOG. Handles the
# subset of subcommands cmd_build's body actually calls.
setup_fake_docker() {
  MOCK_BIN=$(mktemp -d "${TMPDIR:-/tmp}/rc-build-tag-override-bin-XXXXXX")
  cat > "${MOCK_BIN}/docker" <<'FAKEEOF'
#!/usr/bin/env bash
echo "docker $*" >> "$RC_TEST_CALL_LOG"
case "${1:-}" in
  build) exit 0 ;;
  image)
    case "${2:-}" in
      inspect) echo '{}'; exit 0 ;;
      rm) exit 0 ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKEEOF
  chmod +x "${MOCK_BIN}/docker"
  setup_fake_msb
}

# Fake msb (F6): logged the same way as fake docker, and placed in the SAME
# MOCK_BIN dir (which is prepended to PATH ahead of everything else) so it
# shadows any REAL msb binary installed on the host. Without this, only
# `docker` was shimmed and _build_warn_stale_containers / _build_msb_load
# (both live, unconditionally-called helpers inside cmd_build) reached the
# operator's REAL msb -- on a host with msb installed, this suite made
# several genuine `msb image list --format json` calls against the
# operator's real sandbox cache. Configurable via RC_TEST_MSB_IMAGE_LIST /
# RC_TEST_MSB_LIST / RC_TEST_MSB_INSPECT (each defaults to an empty-ish
# value so the default fixture behaves as a no-op / no-cages-found host) --
# T15/T16 (F7) override these to simulate an existing cage.
setup_fake_msb() {
  cat > "${MOCK_BIN}/msb" <<'FAKEEOF'
#!/usr/bin/env bash
echo "msb $*" >> "$RC_TEST_CALL_LOG"
case "${1:-}" in
  image)
    case "${2:-}" in
      list) echo "${RC_TEST_MSB_IMAGE_LIST:-[]}"; exit 0 ;;
    esac
    exit 0
    ;;
  list) echo "${RC_TEST_MSB_LIST:-[]}"; exit 0 ;;
  inspect) echo "${RC_TEST_MSB_INSPECT:-{\}}"; exit 0 ;;
  load) exit "${RC_TEST_MSB_LOAD_EXIT:-0}" ;;
  *) exit 0 ;;
esac
FAKEEOF
  chmod +x "${MOCK_BIN}/msb"
}

# Count the number of -t / --tag(=...) occurrences in a logged `docker build`
# argv line, by re-tokenizing it (avoids substring false-positives like
# "-test" or "--target").
count_tag_flags() {
  local line="$1"
  local -a toks
  # shellcheck disable=SC2206
  toks=($line)
  local n=0 t
  for t in "${toks[@]}"; do
    case "$t" in
      -t|--tag|--tag=*) n=$((n + 1)) ;;
    esac
  done
  echo "$n"
}

# Extract the value immediately following a bare -t/--tag token (or the
# --tag=value suffix) in a logged docker build argv line.
extract_tag_value() {
  local line="$1"
  local -a toks
  # shellcheck disable=SC2206
  toks=($line)
  local i n="${#toks[@]}"
  for ((i = 0; i < n; i++)); do
    case "${toks[$i]}" in
      -t|--tag) echo "${toks[$((i + 1))]}"; return 0 ;;
      --tag=*) echo "${toks[$i]#--tag=}"; return 0 ;;
    esac
  done
  echo ""
}

# Run cmd_build in a subshell with the fake docker on PATH and manifest
# validators stubbed as positive controls (this suite is about tag plumbing,
# not the validators). Captures stdout+stderr and exit code.
run_cmd_build() {
  local -a args=("$@")
  local repo_root="$REPO_ROOT"
  # NOTE: `${VAR:-{}}` mis-parses in bash -- the FIRST unescaped `}` (from
  # the empty-object default literal) closes the parameter expansion early,
  # leaving a stray literal `}` appended after it (confirmed live: `x="${FOO:-{}}"`
  # with FOO set yields "$FOO}", not "$FOO"). Route the default through a
  # plain variable instead of an inline `{}` literal to sidestep the parser
  # ambiguity.
  local _default_empty_obj='{}'
  PATH="${MOCK_BIN}:$PATH" \
  HOME="$TEST_HOME" \
  XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_TEST_CALL_LOG="$CALL_LOG" \
  RC_TEST_VALIDATOR_LOG="${VALIDATOR_LOG:-/dev/null}" \
  RC_TEST_VALIDATOR_EXIT="${RC_TEST_VALIDATOR_EXIT:-0}" \
  RC_TEST_MSB_IMAGE_LIST="${RC_TEST_MSB_IMAGE_LIST:-[]}" \
  RC_TEST_MSB_LIST="${RC_TEST_MSB_LIST:-[]}" \
  RC_TEST_MSB_INSPECT="${RC_TEST_MSB_INSPECT:-$_default_empty_obj}" \
  bash -c '
    source "'"${RC}"'"
    SCRIPT_DIR="'"${repo_root}"'"
    OUTPUT_FORMAT=""
    _manifest_check_binary_root_owned() {
      [[ -n "${RC_TEST_VALIDATOR_LOG:-}" ]] && echo "binary_root_owned:$1" >> "$RC_TEST_VALIDATOR_LOG"
      return "${RC_TEST_VALIDATOR_EXIT:-0}"
    }
    _manifest_check_mount_root_owned() { return 0; }
    cmd_build "$@"
  ' rc-test-build "${args[@]+"${args[@]}"}"
}

# ---------------------------------------------------------------------------
# T1: custom -t override -> exactly ONE -t in the constructed argv, value is
#     the caller's tag, NOT the default rip-cage:latest.
# ---------------------------------------------------------------------------
echo ""
echo "=== T1: rc build -t <custom> -> exactly one -t, value is the custom tag ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t1_rc=0
_t1_out=$(run_cmd_build -t rip-cage-test-t1:custom) || _t1_rc=$?

_t1_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ -z "$_t1_build_line" ]]; then
  fail "T1: expected a 'docker build' call in the log" "log=$(cat "$CALL_LOG") out=$_t1_out rc=$_t1_rc"
else
  _t1_count=$(count_tag_flags "$_t1_build_line")
  if [[ "$_t1_count" -eq 1 ]]; then
    pass "T1a: exactly one -t/--tag flag in the constructed docker build argv"
  else
    fail "T1a: expected exactly 1 -t/--tag flag, got $_t1_count" "$_t1_build_line"
  fi
  _t1_value=$(extract_tag_value "$_t1_build_line")
  if [[ "$_t1_value" == "rip-cage-test-t1:custom" ]]; then
    pass "T1b: the tag value is the caller's custom tag"
  else
    fail "T1b: expected tag value 'rip-cage-test-t1:custom', got '$_t1_value'" "$_t1_build_line"
  fi
  if [[ "$_t1_value" != "rip-cage:latest" ]]; then
    pass "T1c: rip-cage:latest is NOT the tag applied (not clobbered)"
  else
    fail "T1c: rip-cage:latest was tagged -- clobber bug reproduced" "$_t1_build_line"
  fi
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T2: post-build validator is invoked with the EFFECTIVE (custom) image, not
#     the default -- $IMAGE is also the post-build inspection handle.
# ---------------------------------------------------------------------------
echo ""
echo "=== T2: post-build validator receives the effective (custom) image ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
VALIDATOR_LOG=$(mktemp)
_t2_rc=0
run_cmd_build -t rip-cage-test-t2:custom >/dev/null 2>&1 || _t2_rc=$?

if grep -qF "binary_root_owned:rip-cage-test-t2:custom" "$VALIDATOR_LOG"; then
  pass "T2: _manifest_check_binary_root_owned invoked with the custom tag, not the default"
else
  fail "T2: expected validator log to show the custom tag" "$(cat "$VALIDATOR_LOG") rc=$_t2_rc"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; VALIDATOR_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T3: positive control -- no -t given, default rip-cage:latest still used,
#     exactly one -t (proves the fix doesn't break the untouched default path).
# ---------------------------------------------------------------------------
echo ""
echo "=== T3: no -t given -> default rip-cage:latest, exactly one -t ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
run_cmd_build >/dev/null 2>&1 || true

_t3_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ -z "$_t3_build_line" ]]; then
  fail "T3: expected a 'docker build' call in the log" "$(cat "$CALL_LOG")"
else
  _t3_count=$(count_tag_flags "$_t3_build_line")
  _t3_value=$(extract_tag_value "$_t3_build_line")
  if [[ "$_t3_count" -eq 1 && "$_t3_value" == "rip-cage:latest" ]]; then
    pass "T3: default build still tags exactly rip-cage:latest (one -t)"
  else
    fail "T3: expected exactly one -t == rip-cage:latest, got count=$_t3_count value='$_t3_value'" "$_t3_build_line"
  fi
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T4: --tag <value> (separate-arg spelling) behaves like -t.
# ---------------------------------------------------------------------------
echo ""
echo "=== T4: --tag <value> (separate-arg form) ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
run_cmd_build --tag rip-cage-test-t4:custom >/dev/null 2>&1 || true

_t4_build_line=$(grep '^docker build' "$CALL_LOG" || true)
_t4_count=$(count_tag_flags "$_t4_build_line")
_t4_value=$(extract_tag_value "$_t4_build_line")
if [[ "$_t4_count" -eq 1 && "$_t4_value" == "rip-cage-test-t4:custom" ]]; then
  pass "T4: --tag <value> yields exactly one -t with the custom value"
else
  fail "T4: expected count=1 value='rip-cage-test-t4:custom', got count=$_t4_count value='$_t4_value'" "$_t4_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T5: --tag=<value> (equals-form) behaves like -t.
# ---------------------------------------------------------------------------
echo ""
echo "=== T5: --tag=<value> (equals form) ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
run_cmd_build --tag=rip-cage-test-t5:custom >/dev/null 2>&1 || true

_t5_build_line=$(grep '^docker build' "$CALL_LOG" || true)
_t5_count=$(count_tag_flags "$_t5_build_line")
_t5_value=$(extract_tag_value "$_t5_build_line")
if [[ "$_t5_count" -eq 1 && "$_t5_value" == "rip-cage-test-t5:custom" ]]; then
  pass "T5: --tag=<value> yields exactly one -t with the custom value"
else
  fail "T5: expected count=1 value='rip-cage-test-t5:custom', got count=$_t5_count value='$_t5_value'" "$_t5_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T6: -t given twice -> last one wins; still exactly one -t in the argv.
# ---------------------------------------------------------------------------
echo ""
echo "=== T6: -t given twice -> last one wins, still exactly one -t ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
run_cmd_build -t rip-cage-test-t6-first:custom -t rip-cage-test-t6-second:custom >/dev/null 2>&1 || true

_t6_build_line=$(grep '^docker build' "$CALL_LOG" || true)
_t6_count=$(count_tag_flags "$_t6_build_line")
_t6_value=$(extract_tag_value "$_t6_build_line")
if [[ "$_t6_count" -eq 1 && "$_t6_value" == "rip-cage-test-t6-second:custom" ]]; then
  pass "T6: repeated -t collapses to exactly one, last value wins"
else
  fail "T6: expected count=1 value='rip-cage-test-t6-second:custom', got count=$_t6_count value='$_t6_value'" "$_t6_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T7: -t with no following value -> cmd_build fails BEFORE invoking docker.
# ---------------------------------------------------------------------------
echo ""
echo "=== T7: -t with no value -> fails loud, docker never invoked ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t7_rc=0
_t7_out=$(run_cmd_build -t) || _t7_rc=$?

if [[ "$_t7_rc" -ne 0 ]]; then
  pass "T7a: cmd_build returns non-zero when -t has no value"
else
  fail "T7a: expected non-zero exit" "$_t7_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T7b: docker was never invoked when -t had no value"
else
  fail "T7b: expected no docker calls" "$(cat "$CALL_LOG")"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T8: fail-closed cleanup (docker image rm) on a validator violation removes
#     the EFFECTIVE (custom) image, not the default -- otherwise the
#     fail-closed untag would remove the WRONG image (ADR-001 regression).
# ---------------------------------------------------------------------------
echo ""
echo "=== T8: fail-closed cleanup untags the EFFECTIVE (custom) image on violation ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
RC_TEST_VALIDATOR_EXIT=1
_t8_rc=0
run_cmd_build -t rip-cage-test-t8:custom >/dev/null 2>&1 || _t8_rc=$?
unset RC_TEST_VALIDATOR_EXIT

if [[ "$_t8_rc" -ne 0 ]]; then
  pass "T8a: cmd_build fails when the validator reports a violation"
else
  fail "T8a: expected non-zero exit on validator violation" "rc=$_t8_rc"
fi
if grep -qF "docker image rm rip-cage-test-t8:custom" "$CALL_LOG"; then
  pass "T8b: fail-closed untag removed the EFFECTIVE (custom) image"
else
  fail "T8b: expected 'docker image rm rip-cage-test-t8:custom' in the call log" "$(cat "$CALL_LOG")"
fi
if grep -qF "docker image rm rip-cage:latest" "$CALL_LOG"; then
  fail "T8c: fail-closed untag must NOT touch the untouched default rip-cage:latest" "$(cat "$CALL_LOG")"
else
  pass "T8c: default rip-cage:latest was not touched by the fail-closed cleanup"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T9: non-tag caller args (e.g. --no-cache) still pass through to docker build.
# ---------------------------------------------------------------------------
echo ""
echo "=== T9: non-tag caller args pass through untouched ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
run_cmd_build -t rip-cage-test-t9:custom --no-cache >/dev/null 2>&1 || true

_t9_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t9_build_line" == *"--no-cache"* ]]; then
  pass "T9: --no-cache still present in the constructed docker build argv"
else
  fail "T9: expected --no-cache to pass through" "$_t9_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T10 (F1): -t=<value> -- single-dash EQUALS-attached spelling (docker/pflag
#     accepts this identically to --tag=<value>; verified live against real
#     `docker build -t=foo`) -- must ALSO override, not co-tag.
# ---------------------------------------------------------------------------
echo ""
echo "=== T10 (F1): -t=<value> (single-dash equals form) ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
run_cmd_build -t=rip-cage-test-t10:custom >/dev/null 2>&1 || true

_t10_build_line=$(grep '^docker build' "$CALL_LOG" || true)
_t10_count=$(count_tag_flags "$_t10_build_line")
_t10_value=$(extract_tag_value "$_t10_build_line")
if [[ "$_t10_count" -eq 1 && "$_t10_value" == "rip-cage-test-t10:custom" ]]; then
  pass "T10: -t=<value> yields exactly one -t with the custom value"
else
  fail "T10: expected count=1 value='rip-cage-test-t10:custom', got count=$_t10_count value='$_t10_value'" "$_t10_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T11 (F1): -t<value> -- single-dash ATTACHED (no equals) spelling (docker/
#     pflag: once the shorthand value-flag `t` is hit, the rest of the token
#     is its value; verified live against real `docker build -tfoo`).
# ---------------------------------------------------------------------------
echo ""
echo "=== T11 (F1): -t<value> (attached, no equals) ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
run_cmd_build -trip-cage-test-t11:custom >/dev/null 2>&1 || true

_t11_build_line=$(grep '^docker build' "$CALL_LOG" || true)
_t11_count=$(count_tag_flags "$_t11_build_line")
_t11_value=$(extract_tag_value "$_t11_build_line")
if [[ "$_t11_count" -eq 1 && "$_t11_value" == "rip-cage-test-t11:custom" ]]; then
  pass "T11: -t<value> yields exactly one -t with the custom value"
else
  fail "T11: expected count=1 value='rip-cage-test-t11:custom', got count=$_t11_count value='$_t11_value'" "$_t11_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T12 (F1): -qt <value> -- boolean-shorthand-CLUSTERED spelling (docker/
#     pflag: -q is boolean and consumes one char, `t` is then the last char
#     in the token so its value comes from the NEXT argv word; verified live
#     against real `docker build -qt foo`). The leading -q must survive as
#     its own token (quiet mode is still honored), while the tag portion
#     must still override rather than co-tag.
# ---------------------------------------------------------------------------
echo ""
echo "=== T12 (F1): -qt <value> (boolean-prefixed cluster, value from next arg) ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
run_cmd_build -qt rip-cage-test-t12:custom >/dev/null 2>&1 || true

_t12_build_line=$(grep '^docker build' "$CALL_LOG" || true)
_t12_count=$(count_tag_flags "$_t12_build_line")
_t12_value=$(extract_tag_value "$_t12_build_line")
if [[ "$_t12_count" -eq 1 && "$_t12_value" == "rip-cage-test-t12:custom" ]]; then
  pass "T12a: -qt <value> yields exactly one -t with the custom value"
else
  fail "T12a: expected count=1 value='rip-cage-test-t12:custom', got count=$_t12_count value='$_t12_value'" "$_t12_build_line"
fi
if [[ " $_t12_build_line " == *" -q "* ]]; then
  pass "T12b: the leading -q (quiet) flag survives as its own token"
else
  fail "T12b: expected a standalone -q token in the constructed argv" "$_t12_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T13 (F2): -t "" -- explicitly EMPTY value (separate-arg spelling) must fail
#     loud BEFORE any docker call, not silently fall back to the default
#     rip-cage:latest (pre-fix this was a hard docker error; round-1's
#     ${_bt_tag:-$IMAGE} regressed it into a silent clobber).
# ---------------------------------------------------------------------------
echo ""
echo "=== T13 (F2): -t \"\" (explicit empty value) -> fails loud, docker never invoked ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t13_rc=0
_t13_out=$(run_cmd_build -t "") || _t13_rc=$?

if [[ "$_t13_rc" -ne 0 ]]; then
  pass "T13a: cmd_build returns non-zero when -t is given an empty value"
else
  fail "T13a: expected non-zero exit" "$_t13_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T13b: docker was never invoked when -t was empty"
else
  fail "T13b: expected no docker calls" "$(cat "$CALL_LOG")"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T14 (F2): --tag= -- explicitly EMPTY value (equals-form spelling) must also
#     fail loud BEFORE any docker call.
# ---------------------------------------------------------------------------
echo ""
echo "=== T14 (F2): --tag= (explicit empty value, equals form) -> fails loud ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t14_rc=0
_t14_out=$(run_cmd_build --tag=) || _t14_rc=$?

if [[ "$_t14_rc" -ne 0 ]]; then
  pass "T14a: cmd_build returns non-zero when --tag= is given an empty value"
else
  fail "T14a: expected non-zero exit" "$_t14_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T14b: docker was never invoked when --tag= was empty"
else
  fail "T14b: expected no docker calls" "$(cat "$CALL_LOG")"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T15 (F7): a custom -t build must NOT warn about existing cages pinned to a
#     different (default-tag) image -- that reasoning is about "cages running
#     the image you just rebuilt", which does not apply to a scratch/fixture
#     build under a throwaway custom tag. Fixture: one msb-managed cage
#     exists, pinned to a digest that mismatches whatever gets built.
# ---------------------------------------------------------------------------
echo ""
echo "=== T15 (F7): rc build -t <custom> does NOT warn about unrelated stale cages ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
RC_TEST_MSB_LIST='[{"name":"existing-cage"}]'
RC_TEST_MSB_INSPECT='{"config":{"labels":{"rc.source.path":"/some/path"},"manifest_digest":"sha256:bbbb"}}'
RC_TEST_MSB_IMAGE_LIST='[{"reference":"rip-cage-test-t15:custom","digest":"sha256:aaaa"}]'
_t15_out=$(run_cmd_build -t rip-cage-test-t15:custom 2>&1) || true
unset RC_TEST_MSB_LIST RC_TEST_MSB_INSPECT RC_TEST_MSB_IMAGE_LIST

if [[ "$_t15_out" != *"Warning: container"* ]]; then
  pass "T15: no stale-container warning emitted for an unrelated cage on a custom-tag build"
else
  fail "T15: expected no stale-container warning" "$_t15_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T16 (F7 positive control): the SAME stale-cage fixture, but a default
# (no -t) build -- the warning must STILL fire. Regression guard proving the
# T15 fix scopes to "custom tag supplied", not "warning removed entirely".
# ---------------------------------------------------------------------------
echo ""
echo "=== T16 (F7 positive control): rc build (default tag) still warns about a stale cage ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
RC_TEST_MSB_LIST='[{"name":"existing-cage"}]'
RC_TEST_MSB_INSPECT='{"config":{"labels":{"rc.source.path":"/some/path"},"manifest_digest":"sha256:bbbb"}}'
RC_TEST_MSB_IMAGE_LIST='[{"reference":"rip-cage:latest","digest":"sha256:aaaa"}]'
_t16_out=$(run_cmd_build 2>&1) || true
unset RC_TEST_MSB_LIST RC_TEST_MSB_INSPECT RC_TEST_MSB_IMAGE_LIST

if [[ "$_t16_out" == *"Warning: container 'existing-cage'"* ]]; then
  pass "T16: default-tag build still warns about a genuinely stale cage (feature not removed)"
else
  fail "T16: expected the stale-container warning to still fire on the default path" "$_t16_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-build-tag-override.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-build-tag-override.sh: all ${TOTAL} tests passed ==="
