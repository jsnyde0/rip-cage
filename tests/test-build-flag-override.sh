#!/usr/bin/env bash
# tests/test-build-flag-override.sh -- cmd_build's docker-build argv
# construction: caller-supplied flags that COLLIDE with flags rc's own
# `docker build -t "$IMAGE" ... -f "$_dockerfile" ...` invocation already
# sets. Originally test-build-tag-override.sh (rip-cage-fo4z, -t only);
# renamed and broadened under rip-cage-zqjz to also cover -f/--file, which
# shares the exact same "caller arg collides with an rc-set flag" seam and
# the exact same fake-docker+fake-msb host-only harness -- a second parallel
# test file would just duplicate this fixture machinery. Broadened again
# under rip-cage-zqjz.2 (see below) to cover the seam's POLICY INVERSION:
# from an open pass-through with a per-flag reject list, to a fail-closed
# ALLOWLIST.
#
# --- rip-cage-zqjz.2: -o/--output, and the allowlist inversion ---
# A THIRD distinct validator-defeat was found in the same seam: `docker
# build -t X -o type=local,dest=DIR .` exits 0 and exports the build result
# to the filesystem WITHOUT loading it into the docker image store. If a
# prior $IMAGE already existed (from an earlier real build), the post-build
# root-owned validators silently pass against the STALE image while `rc
# build` reports status "built" -- a FALSE GREEN on the safety floor, not
# merely a UX surprise (this is the acceptance-critical scenario: see T-FG
# below).
#
# Three distinct mechanisms in three passes (-t additive, -f last-wins, -o
# output-redirection) is unwinnable as a per-flag reject list -- docker's
# flag surface evolves outside rc's control. The fix inverts the seam to a
# FAIL-CLOSED ALLOWLIST: a small set of flags verified benign against
# docker's REAL current flag surface (docker 29.4.0 `docker build --help`)
# are explicitly admitted (pass through unmodified); -t is intercepted as
# before; -f/-o are explicitly rejected as before/newly; and EVERYTHING ELSE
# -- every other named docker flag AND any genuinely unrecognized/future
# flag AND a stray build-context positional AND a bare `--` (previously a
# literal unfiltered-passthrough hole, see T-DASHDASH) -- fails loud BEFORE
# any docker call, naming the allowlist and the `rc generate-dockerfile`
# escape hatch. See cli/build.sh's cmd_build for the full per-flag
# admit/reject rationale.
#
# --- -t/--tag (rip-cage-fo4z) ---
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
# --- -f/--file (rip-cage-zqjz) ---
# Bug: the same two docker-build call sites hardcode `-f "$_dockerfile"`
# (rc's manifest-resolved, isolation-audited Dockerfile) BEFORE caller args
# ("$@"). Unlike -t, a duplicate -f is LAST-WINS in docker (empirically
# verified: `docker build -f A -f B .` builds ONLY from B) -- so `rc build -f
# <path>` would silently replace rc's audited Dockerfile with the caller's
# file for the ACTUAL build, while _manifest_check_build_isolation (the
# pre-build isolation gate, ADR-005 D9 / ADR-024) still only ever inspects
# rc's own resolved path. That's a safety-floor validator bypass, not a UX
# surprise. Fix under test: every spelling of -f/--file is REJECTED outright
# (fail-loud, ADR-001 style, brain-ruled on the bead) BEFORE any docker call
# -- there is no "effective Dockerfile" to override to, unlike -t's IMAGE.
#
# Host-only unit tests: fake docker on PATH, call-logged to a scratch file so
# the constructed `docker build` argv is asserted directly -- no image build
# needed (same pattern as tests/test-build-msb-load.sh / test-manifest-mount-mode.sh
# MG1/MG2: source rc directly, call cmd_build, override the manifest validators
# as no-op positive controls since this suite is about flag plumbing, not the
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
#   T10 -t=<value> (single-dash equals form).
#   T11 -t<value> (single-dash attached, no equals).
#   T12 -qt <value> (boolean-prefixed cluster, -q survives as its own token).
#   T13 -t "" (explicit empty value) -> fails loud, not a silent default fallback.
#   T14 --tag= (explicit empty value, equals form) -> fails loud.
#   T15 custom -t build does NOT warn about unrelated stale cages.
#   T16 (positive control) default-tag build STILL warns about a stale cage.
#   T17 rc build -f <path> (separate-arg) -> rejected before any docker call
#       (rip-cage-zqjz).
#   T18 rc build --file <path> (long-form separate-arg) -> rejected.
#   T19 rc build --file=<path> (long-form equals) -> rejected.
#   T20 rc build -f=<path> (single-dash equals) -> rejected.
#   T21 rc build -f<path> (single-dash attached, no equals) -> rejected.
#   T22 rc build -Df<path> (boolean-prefixed cluster, attached) -> rejected.
#   T23 rc build -qf <path> (boolean-prefixed cluster, value from next arg)
#       -> rejected.
#   T24 rc build -Dqf <path> (multi-boolean-prefixed cluster) -> rejected.
#   T25 (directional) rc build -ft -> rejected -- this IS -f (value "t"), the
#       false-negative risk the bead calls out explicitly.
#   T26 (directional, regression guard) rc build -tf -> still LEGAL, tag="f"
#       -- this is -t (value "f"), NOT -f; a fix rejecting this would be a
#       false positive breaking a legal invocation.
#   T27 rc build --output json -f <path> -> single well-formed JSON error
#       object, stable error code BUILD_FILE_REJECTED, docker never invoked.
#   T28 (positive control, acceptance criterion 2b) with NO caller -f, the
#       SAME manifest-resolved Dockerfile path is the only one ever passed
#       to _manifest_check_build_isolation AND to the real docker build -f
#       argument (forces a manifest-generated temp Dockerfile via a
#       from-source TOOL fixture so the validator is actually invoked).
#
# --- rip-cage-zqjz.2 (-o/--output rejection + allowlist inversion) ---
#   T29 rc build -o <value> (separate-arg) -> rejected before any docker call.
#   T30 rc build --output <value> (long-form separate-arg) -> rejected.
#   T31 rc build --output=<value> (long-form equals) -> rejected.
#   T32 rc build -o=<value> (single-dash equals) -> rejected.
#   T33 rc build -o<value> (single-dash attached, no equals) -> rejected.
#   T34 rc build -Do<value> (boolean-prefixed cluster, attached) -> rejected.
#   T35 rc build -qo <value> (boolean-prefixed cluster, value from next arg)
#       -> rejected.
#   T36 rc build -Dqo <value> (multi-boolean-prefixed cluster) -> rejected.
#   T37 (directional) rc build -ot -> rejected -- this IS -o (value "t").
#   T38 (directional, regression guard) rc build -to -> still LEGAL, tag="o"
#       -- this is -t (value "o"), NOT -o.
#   T39 rc build --output json -o <value> -> single well-formed JSON error
#       object, stable error code BUILD_OUTPUT_REJECTED, docker never invoked.
#   T-FG (acceptance criterion 1/2, THE motivating false-green): with a
#       stale $IMAGE already "existing" (validators stubbed as a positive
#       control, simulating a validator that would happily inspect whatever
#       image is already in the store), `rc build -o ...` must NOT reach a
#       state where docker is invoked and a built/success status is
#       reported -- it must fail loud BEFORE the docker call, every time.
#   T40 rc build --build-arg RC_VERSION=evil -> rejected (separate-arg).
#   T41 rc build --build-arg=RC_VERSION=evil -> rejected (equals form).
#
# --- rip-cage-zqjz.2 F1 (round 2, adversarial-review fresh-context finding):
#     --build-arg REJECTED WHOLESALE, not admitted with an RC_VERSION-only
#     carve-out ---
#   The round-1 admit ("only ever feeds _image_is_current's staleness
#   heuristic") was falsified via the flag's VALUE namespace, not its name:
#   --build-arg BUILDKIT_SYNTAX=<image> replaces the Dockerfile FRONTEND
#   BuildKit uses to interpret the Dockerfile at all (verified live, docker
#   29.4.0), making _manifest_check_build_isolation's static text analysis of
#   rc's own Dockerfile vacuous -- a different frontend can interpret
#   whatever text it likes. A second channel: cage/Dockerfile interpolates
#   caller-settable ARGs into RUN shell strings (DOLT_VERSION et al.), so an
#   admitted --build-arg is build-time command injection into rip-cage:latest.
#   No in-repo caller and no manifest build-arg mechanism exists to preserve.
#   Ruling: reject --build-arg outright, same treatment as -f/-o.
#   T42 (POLICY FLIP from round-1's positive control) rc build --build-arg
#       OTHER_KEY=value -> now REJECTED (was admitted).
#   T59 (the motivating case) rc build --build-arg BUILDKIT_SYNTAX=<image> ->
#       rejected before any docker call.
#   T60 rc build --build-arg SOME_KEY (bare, no "=" -- docker's documented
#       inherit-from-environment form) -> rejected. Closes F2: round-1's
#       RC_VERSION carve-out matched only "== RC_VERSION=*", which requires
#       the "=" and so admitted this bare spelling; wholesale rejection
#       closes the gap by construction (no narrower guard survives to be
#       spelling-incomplete).
#   T61 rc build --build-arg=SOME_KEY (equals-attached, still the bare
#       inherit-from-env form) -> rejected.
#   T43 rc build --no-cache -> admitted, passes through (regression guard,
#       same case as T9 but via the new explicit admit path).
#   T44 rc build --pull -> admitted, passes through.
#   T45 rc build --progress=quiet -> admitted, passes through.
#   T46 rc build --progress plain -> admitted, passes through (value from
#       next arg).
#   T47 rc build -q -> admitted (bare boolean short flag), passes through.
#   T48 rc build -D -> admitted (bare boolean short flag), passes through.
#   T49 rc build -Dq -> admitted (pure boolean short cluster), passes
#       through.
#   T50 rc build --debug -> admitted (long form of -D), passes through.
#   T51 rc build --quiet -> admitted (long form of -q), passes through.
#   T52 rc build --target foo -> rejected (named: can skip stages that
#       install the safety floor -- verified against cage/Dockerfile's
#       go-builder / runtime stage split).
#   T53 rc build --label rc.multiplexers=herdr -> rejected (named: forges
#       the SOLE authoritative multiplexer-registry label,
#       cli/lib/config.sh:159).
#   T54 rc build --secret id=x -> rejected (named: build-time credential
#       injection, ADR-005 D9 / ADR-024).
#   T55 rc build --push -> rejected (named: registry side effect).
#   T56 rc build --platform linux/amd64 -> rejected (named: could produce an
#       image this host cannot run while validators still inspect it).
#   T57 (forward-compat closure) rc build --some-brand-new-docker-flag x ->
#       rejected via the GENERIC fail-closed default, not a named case --
#       proves an unknown future docker flag fails closed instead of
#       silently reaching docker (closes rip-cage-fo4z's forward-compat
#       caveat).
#   T58 (stray positional) rc build /tmp/not-a-flag -> rejected -- rc
#       supplies the build-context positional itself; a caller-supplied one
#       must fail loud in rc, not reach docker as a second positional.
#   T-DASHDASH (closes a real hole found while implementing this bead) rc
#       build -- -o type=local,dest=/tmp/x -> still rejected. Pre-existing
#       `--` handling (a51b5da/fb79d10) dumped everything after `--` into
#       the constructed argv UNFILTERED -- a caller could bypass the entire
#       allowlist (including the -o false-green) by prefixing it with `--`.
#       Closed by removing the special-cased verbatim-passthrough branch;
#       `--` now falls through to the same fail-closed default as any other
#       unrecognized token.

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
ISOLATION_LOG=""

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  [[ -n "${CALL_LOG:-}" ]] && rm -f "$CALL_LOG"
  [[ -n "${VALIDATOR_LOG:-}" ]] && rm -f "$VALIDATOR_LOG"
  [[ -n "${ISOLATION_LOG:-}" ]] && rm -f "$ISOLATION_LOG"
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

# assert_file_rejected <label> <cmd_build args...> -- shared assertion for
# every -f/--file spelling (rip-cage-zqjz): cmd_build must return non-zero,
# never invoke docker, and name -f/--file in its error output. Runs its own
# setup_sandbox/setup_fake_docker/CALL_LOG/cleanup so each case is isolated.
assert_file_rejected() {
  local label="$1"
  shift
  setup_sandbox
  setup_fake_docker
  CALL_LOG=$(mktemp)
  local _afr_rc=0
  local _afr_out
  _afr_out=$(run_cmd_build "$@" 2>&1) || _afr_rc=$?

  if [[ "$_afr_rc" -ne 0 ]]; then
    pass "${label}a: cmd_build returns non-zero"
  else
    fail "${label}a: expected non-zero exit" "$_afr_out"
  fi
  if [[ ! -s "$CALL_LOG" ]]; then
    pass "${label}b: docker was never invoked"
  else
    fail "${label}b: expected no docker calls" "$(cat "$CALL_LOG")"
  fi
  if [[ "$_afr_out" == *"-f"* || "$_afr_out" == *"--file"* ]]; then
    pass "${label}c: error message names the rejected flag"
  else
    fail "${label}c: expected error message to name -f/--file" "$_afr_out"
  fi
  cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""
}

# assert_output_rejected <label> <cmd_build args...> -- shared assertion for
# every -o/--output spelling (rip-cage-zqjz.2): cmd_build must return
# non-zero, never invoke docker, and name -o/--output in its error output.
# Same shape as assert_file_rejected above.
assert_output_rejected() {
  local label="$1"
  shift
  setup_sandbox
  setup_fake_docker
  CALL_LOG=$(mktemp)
  local _aor_rc=0
  local _aor_out
  _aor_out=$(run_cmd_build "$@" 2>&1) || _aor_rc=$?

  if [[ "$_aor_rc" -ne 0 ]]; then
    pass "${label}a: cmd_build returns non-zero"
  else
    fail "${label}a: expected non-zero exit" "$_aor_out"
  fi
  if [[ ! -s "$CALL_LOG" ]]; then
    pass "${label}b: docker was never invoked"
  else
    fail "${label}b: expected no docker calls" "$(cat "$CALL_LOG")"
  fi
  if [[ "$_aor_out" == *"-o"* || "$_aor_out" == *"--output"* ]]; then
    pass "${label}c: error message names the rejected flag"
  else
    fail "${label}c: expected error message to name -o/--output" "$_aor_out"
  fi
  cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""
}

# assert_unallowed_rejected <label> <cmd_build args...> -- generic
# fail-closed-allowlist rejection assertion (rip-cage-zqjz.2): cmd_build
# must return non-zero and never invoke docker. Used for named-reject
# flags (--target, --label, ...) and for genuinely unrecognized/future
# flags/positionals routed through the allowlist's single fail-closed
# default -- deliberately does NOT assert the exact wording of the
# rejected token (that's covered by the more specific assert_*_rejected
# helpers above for -f/-o), just the fail-closed shape.
assert_unallowed_rejected() {
  local label="$1"
  shift
  setup_sandbox
  setup_fake_docker
  CALL_LOG=$(mktemp)
  local _aur_rc=0
  local _aur_out
  _aur_out=$(run_cmd_build "$@" 2>&1) || _aur_rc=$?

  if [[ "$_aur_rc" -ne 0 ]]; then
    pass "${label}a: cmd_build returns non-zero"
  else
    fail "${label}a: expected non-zero exit" "$_aur_out"
  fi
  if [[ ! -s "$CALL_LOG" ]]; then
    pass "${label}b: docker was never invoked"
  else
    fail "${label}b: expected no docker calls" "$(cat "$CALL_LOG")"
  fi
  cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""
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

# Extract the value immediately following a bare -f token in a logged
# `docker build` argv line (rc's own -f "$_dockerfile" -- there is exactly
# one -f in the constructed argv in the no-caller-override positive control,
# since a caller-supplied -f is rejected before ever reaching this point).
extract_file_value() {
  local line="$1"
  local -a toks
  # shellcheck disable=SC2206
  toks=($line)
  local i n="${#toks[@]}"
  for ((i = 0; i < n; i++)); do
    case "${toks[$i]}" in
      -f) echo "${toks[$((i + 1))]}"; return 0 ;;
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
  RC_TEST_OUTPUT_FORMAT="${RC_TEST_OUTPUT_FORMAT:-}" \
  RC_TEST_ISOLATION_LOG="${ISOLATION_LOG:-/dev/null}" \
  bash -c '
    source "'"${RC}"'"
    SCRIPT_DIR="'"${repo_root}"'"
    OUTPUT_FORMAT="${RC_TEST_OUTPUT_FORMAT:-}"
    _manifest_check_binary_root_owned() {
      [[ -n "${RC_TEST_VALIDATOR_LOG:-}" ]] && echo "binary_root_owned:$1" >> "$RC_TEST_VALIDATOR_LOG"
      return "${RC_TEST_VALIDATOR_EXIT:-0}"
    }
    _manifest_check_mount_root_owned() { return 0; }
    # rip-cage-zqjz T28: positive-control stub (same convention as the two
    # root-owned validators above -- this suite is about flag plumbing, not
    # the validators own logic) that LOGS the Dockerfile path it was called
    # with, so T28 can assert it is the identical path handed to the real
    # docker build -f argument below.
    _manifest_check_build_isolation() {
      [[ -n "${RC_TEST_ISOLATION_LOG:-}" ]] && echo "$1" >> "$RC_TEST_ISOLATION_LOG"
      return 0
    }
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

# ---------------------------------------------------------------------------
# T17 (rip-cage-zqjz): rc build -f <path> -- separate-arg spelling -- must be
#     REJECTED before any docker call. Caller -f would silently swap rc's
#     manifest-resolved, isolation-audited Dockerfile out from under
#     _manifest_check_build_isolation (docker's -f is LAST-WINS, unlike -t).
# ---------------------------------------------------------------------------
echo ""
echo "=== T17: rc build -f <path> -> rejected before any docker call ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t17_rc=0
_t17_out=$(run_cmd_build -f /tmp/evil.Dockerfile 2>&1) || _t17_rc=$?

if [[ "$_t17_rc" -ne 0 ]]; then
  pass "T17a: cmd_build returns non-zero when -f is supplied"
else
  fail "T17a: expected non-zero exit" "$_t17_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T17b: docker was never invoked when -f was supplied"
else
  fail "T17b: expected no docker calls" "$(cat "$CALL_LOG")"
fi
if [[ "$_t17_out" == *"-f"* || "$_t17_out" == *"--file"* ]]; then
  pass "T17c: error message names the rejected flag"
else
  fail "T17c: expected error message to name -f/--file" "$_t17_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T18: rc build --file <path> -- long-form separate-arg spelling -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T18: rc build --file <path> -> rejected before any docker call ==="
assert_file_rejected T18 --file /tmp/evil.Dockerfile

# ---------------------------------------------------------------------------
# T19: rc build --file=<path> -- long-form equals spelling -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T19: rc build --file=<path> -> rejected before any docker call ==="
assert_file_rejected T19 --file=/tmp/evil.Dockerfile

# ---------------------------------------------------------------------------
# T20: rc build -f=<path> -- single-dash EQUALS-attached spelling -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T20: rc build -f=<path> (single-dash equals form) -> rejected ==="
assert_file_rejected T20 -f=/tmp/evil.Dockerfile

# ---------------------------------------------------------------------------
# T21: rc build -f<path> -- single-dash ATTACHED (no equals) spelling --
#      rejected (mirrors the -t<value> attached spelling, T11).
# ---------------------------------------------------------------------------
echo ""
echo "=== T21: rc build -f<path> (attached, no equals) -> rejected ==="
assert_file_rejected T21 -fevil.Dockerfile

# ---------------------------------------------------------------------------
# T22: rc build -Df<path> -- boolean-prefixed cluster (-D debug), ATTACHED
#      value -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T22: rc build -Df<path> (boolean-prefixed cluster, attached) -> rejected ==="
assert_file_rejected T22 -Dfevil.Dockerfile

# ---------------------------------------------------------------------------
# T23: rc build -qf <path> -- boolean-prefixed cluster (-q quiet), value from
#      the NEXT argv word -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T23: rc build -qf <path> (boolean-prefixed cluster, value from next arg) -> rejected ==="
assert_file_rejected T23 -qf /tmp/evil.Dockerfile

# ---------------------------------------------------------------------------
# T24: rc build -Dqf <path> -- multi-boolean-prefixed cluster (-D -q), value
#      from the NEXT argv word -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T24: rc build -Dqf <path> (multi-boolean-prefixed cluster) -> rejected ==="
assert_file_rejected T24 -Dqf /tmp/evil.Dockerfile

# ---------------------------------------------------------------------------
# T25 (directional): rc build -ft -- ILLEGAL. This is -f with attached value
#     "t", NOT -t with value "f" -- docker's own cluster-parsing walks left to
#     right, so the FIRST value-taking flag character (f, here) consumes the
#     rest of the token. Must be rejected (this is exactly the false-negative
#     risk called out on the bead: a fix that treats -ft as a legal tag would
#     miss the real -f clobber).
# ---------------------------------------------------------------------------
echo ""
echo "=== T25 (directional): rc build -ft -> rejected (this is -f, value \"t\") ==="
assert_file_rejected T25 -ft

# ---------------------------------------------------------------------------
# T26 (directional, regression guard): rc build -tf -- LEGAL. This is -t with
#     attached value "f" (t is the first value-taking flag character in the
#     cluster), NOT -f with value "t" -- must NOT be rejected (a false
#     positive here would break a legal invocation). Positive control proving
#     the -f rejection and the pre-existing -t override coexist correctly.
# ---------------------------------------------------------------------------
echo ""
echo "=== T26 (directional, regression guard): rc build -tf -> still legal, tag=\"f\" ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t26_rc=0
_t26_out=$(run_cmd_build -tf 2>&1) || _t26_rc=$?

if [[ "$_t26_rc" -eq 0 ]]; then
  pass "T26a: cmd_build succeeds for -tf (not rejected)"
else
  fail "T26a: expected zero exit for -tf" "$_t26_out"
fi
_t26_build_line=$(grep '^docker build' "$CALL_LOG" || true)
_t26_count=$(count_tag_flags "$_t26_build_line")
_t26_value=$(extract_tag_value "$_t26_build_line")
if [[ "$_t26_count" -eq 1 && "$_t26_value" == "f" ]]; then
  pass "T26b: -tf yields exactly one -t with value \"f\""
else
  fail "T26b: expected count=1 value='f', got count=$_t26_count value='$_t26_value'" "$_t26_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T27: rc build --output json -f <path> -- JSON mode -- single well-formed
#      JSON error object with a stable error code (BUILD_FILE_REJECTED),
#      consistent with the existing BUILD_TAG_* codes.
# ---------------------------------------------------------------------------
echo ""
echo "=== T27: rc build --output json -f <path> -> well-formed JSON error, docker never invoked ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t27_rc=0
_t27_out=$(RC_TEST_OUTPUT_FORMAT=json run_cmd_build -f /tmp/evil.Dockerfile) || _t27_rc=$?

if [[ "$_t27_rc" -ne 0 ]]; then
  pass "T27a: cmd_build returns non-zero in JSON mode"
else
  fail "T27a: expected non-zero exit" "$_t27_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T27b: docker was never invoked in JSON mode"
else
  fail "T27b: expected no docker calls" "$(cat "$CALL_LOG")"
fi
if echo "$_t27_out" | jq -e . >/dev/null 2>&1; then
  pass "T27c: stdout is well-formed JSON"
else
  fail "T27c: expected well-formed JSON on stdout" "$_t27_out"
fi
_t27_code=$(echo "$_t27_out" | jq -r '.code // empty' 2>/dev/null)
if [[ "$_t27_code" == "BUILD_FILE_REJECTED" ]]; then
  pass "T27d: JSON error code is BUILD_FILE_REJECTED"
else
  fail "T27d: expected code=BUILD_FILE_REJECTED, got '$_t27_code'" "$_t27_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T28 (rip-cage-zqjz, acceptance criterion 2b, positive control): with NO
#     caller -f, the SAME manifest-resolved Dockerfile is the only one ever
#     passed to _manifest_check_build_isolation AND to the real docker build
#     -f argument. Forces a manifest-generated temp Dockerfile (a
#     build_source/from-source TOOL entry -- the only path that produces a
#     non-empty $_tmp_dockerfile and thus actually invokes the isolation
#     validator) so this is a real path-identity assertion, not vacuously
#     true because the validator was skipped.
# ---------------------------------------------------------------------------
echo ""
echo "=== T28 (positive control): isolation validator and docker -f see the SAME path ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
ISOLATION_LOG=$(mktemp)
cp "${REPO_ROOT}/tests/fixtures/manifest-with-from-source-tool.yaml" "${TEST_HOME}/.config/rip-cage/tools.yaml"
_t28_rc=0
_t28_out=$(run_cmd_build 2>&1) || _t28_rc=$?

if [[ "$_t28_rc" -eq 0 ]]; then
  pass "T28a: cmd_build succeeds (positive-control isolation stub passes)"
else
  fail "T28a: expected zero exit" "$_t28_out"
fi
_t28_isolation_calls=$(grep -c . "$ISOLATION_LOG" 2>/dev/null || echo 0)
if [[ "$_t28_isolation_calls" -eq 1 ]]; then
  pass "T28b: _manifest_check_build_isolation was invoked exactly once (manifest-generated Dockerfile path confirmed taken)"
else
  fail "T28b: expected exactly one isolation-validator invocation, got $_t28_isolation_calls" "$(cat "$ISOLATION_LOG")"
fi
_t28_isolation_path=$(head -1 "$ISOLATION_LOG" 2>/dev/null)
_t28_build_line=$(grep '^docker build' "$CALL_LOG" || true)
_t28_docker_f_value=$(extract_file_value "$_t28_build_line")
if [[ -n "$_t28_isolation_path" && "$_t28_isolation_path" == "$_t28_docker_f_value" ]]; then
  pass "T28c: isolation validator and docker build -f received the identical path"
else
  fail "T28c: expected identical paths, got isolation='$_t28_isolation_path' docker_f='$_t28_docker_f_value'" "$_t28_build_line"
fi
if [[ "$_t28_isolation_path" != "${REPO_ROOT}/cage/Dockerfile" ]]; then
  pass "T28d: the shared path is the manifest-generated temp Dockerfile, not the original (proves the manifest path was genuinely taken)"
else
  fail "T28d: expected a manifest-generated temp Dockerfile, got the original cage/Dockerfile" "$_t28_isolation_path"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; ISOLATION_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T29 (rip-cage-zqjz.2): rc build -o <value> -- separate-arg spelling -- must
#     be REJECTED before any docker call. `docker build -t X -o
#     type=local,dest=DIR .` exits 0 and exports the build result to the
#     filesystem WITHOUT loading it into the docker image store.
# ---------------------------------------------------------------------------
echo ""
echo "=== T29: rc build -o <value> -> rejected before any docker call ==="
assert_output_rejected T29 -o type=local,dest=/tmp/rc-test-t29-out

# ---------------------------------------------------------------------------
# T30: rc build --output <value> -- long-form separate-arg -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T30: rc build --output <value> -> rejected before any docker call ==="
assert_output_rejected T30 --output type=local,dest=/tmp/rc-test-t30-out

# ---------------------------------------------------------------------------
# T31: rc build --output=<value> -- long-form equals -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T31: rc build --output=<value> -> rejected before any docker call ==="
assert_output_rejected T31 --output=type=local,dest=/tmp/rc-test-t31-out

# ---------------------------------------------------------------------------
# T32: rc build -o=<value> -- single-dash equals -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T32: rc build -o=<value> (single-dash equals form) -> rejected ==="
assert_output_rejected T32 -o=type=local,dest=/tmp/rc-test-t32-out

# ---------------------------------------------------------------------------
# T33: rc build -o<value> -- single-dash attached (no equals) -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T33: rc build -o<value> (attached, no equals) -> rejected ==="
assert_output_rejected T33 -otype=local,dest=/tmp/rc-test-t33-out

# ---------------------------------------------------------------------------
# T34: rc build -Do<value> -- boolean-prefixed cluster (-D debug), attached
#      value -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T34: rc build -Do<value> (boolean-prefixed cluster, attached) -> rejected ==="
assert_output_rejected T34 -Dotype=local,dest=/tmp/rc-test-t34-out

# ---------------------------------------------------------------------------
# T35: rc build -qo <value> -- boolean-prefixed cluster (-q quiet), value
#      from the NEXT argv word -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T35: rc build -qo <value> (boolean-prefixed cluster, value from next arg) -> rejected ==="
assert_output_rejected T35 -qo type=local,dest=/tmp/rc-test-t35-out

# ---------------------------------------------------------------------------
# T36: rc build -Dqo <value> -- multi-boolean-prefixed cluster -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T36: rc build -Dqo <value> (multi-boolean-prefixed cluster) -> rejected ==="
assert_output_rejected T36 -Dqo type=local,dest=/tmp/rc-test-t36-out

# ---------------------------------------------------------------------------
# T37 (directional): rc build -ot -- ILLEGAL. This is -o with attached value
#     "t", NOT -t with value "o" -- docker's cluster-parsing walks left to
#     right, so the FIRST value-taking flag character (o, here) consumes the
#     rest of the token. Must be rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T37 (directional): rc build -ot -> rejected (this is -o, value \"t\") ==="
assert_output_rejected T37 -ot

# ---------------------------------------------------------------------------
# T38 (directional, regression guard): rc build -to -- LEGAL. This is -t with
#     attached value "o" (t is the first value-taking flag character in the
#     cluster), NOT -o with value "t" -- must NOT be rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T38 (directional, regression guard): rc build -to -> still legal, tag=\"o\" ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t38_rc=0
_t38_out=$(run_cmd_build -to 2>&1) || _t38_rc=$?

if [[ "$_t38_rc" -eq 0 ]]; then
  pass "T38a: cmd_build succeeds for -to (not rejected)"
else
  fail "T38a: expected zero exit for -to" "$_t38_out"
fi
_t38_build_line=$(grep '^docker build' "$CALL_LOG" || true)
_t38_count=$(count_tag_flags "$_t38_build_line")
_t38_value=$(extract_tag_value "$_t38_build_line")
if [[ "$_t38_count" -eq 1 && "$_t38_value" == "o" ]]; then
  pass "T38b: -to yields exactly one -t with value \"o\""
else
  fail "T38b: expected count=1 value='o', got count=$_t38_count value='$_t38_value'" "$_t38_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T39: rc build --output json -o <value> -- JSON mode -- single well-formed
#      JSON error object with a stable error code (BUILD_OUTPUT_REJECTED).
# ---------------------------------------------------------------------------
echo ""
echo "=== T39: rc build --output json -o <value> -> well-formed JSON error, docker never invoked ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t39_rc=0
_t39_out=$(RC_TEST_OUTPUT_FORMAT=json run_cmd_build -o type=local,dest=/tmp/rc-test-t39-out) || _t39_rc=$?

if [[ "$_t39_rc" -ne 0 ]]; then
  pass "T39a: cmd_build returns non-zero in JSON mode"
else
  fail "T39a: expected non-zero exit" "$_t39_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T39b: docker was never invoked in JSON mode"
else
  fail "T39b: expected no docker calls" "$(cat "$CALL_LOG")"
fi
if echo "$_t39_out" | jq -e . >/dev/null 2>&1; then
  pass "T39c: stdout is well-formed JSON"
else
  fail "T39c: expected well-formed JSON on stdout" "$_t39_out"
fi
_t39_code=$(echo "$_t39_out" | jq -r '.code // empty' 2>/dev/null)
if [[ "$_t39_code" == "BUILD_OUTPUT_REJECTED" ]]; then
  pass "T39d: JSON error code is BUILD_OUTPUT_REJECTED"
else
  fail "T39d: expected code=BUILD_OUTPUT_REJECTED, got '$_t39_code'" "$_t39_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T-FG (rip-cage-zqjz.2, acceptance criteria 1+2, THE motivating false-green):
#     a build whose output is redirected via -o must NOT reach a state where
#     docker is invoked (and therefore must never report a built/success
#     status) -- even with the post-build root-owned validators stubbed as
#     an always-pass positive control (simulating a validator that would
#     happily inspect whatever image already happens to be sitting in the
#     store, stale or not). Pre-fix (fb79d10), cmd_build passed -o straight
#     through to docker: the fake docker "succeeds" (exit 0) regardless of
#     its args, the stubbed validators pass, and rc reports action:"built"/
#     status:"success" on stdout -- a false green structurally identical to
#     the real one (real docker would have exited 0 too, having exported to
#     a filesystem path instead of the image store, while a STALE prior
#     $IMAGE sat in the store for the validators to "pass" against).
# ---------------------------------------------------------------------------
echo ""
echo "=== T-FG: rc build -o ... never reaches a docker call or a built/success report ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_tfg_rc=0
# T-FGc's false-green check MUST inspect stdout alone (matches T39c/T39d's
# already-correct pattern) -- a combined 2>&1 capture is structurally
# unfalsifiable: log()/seed-drift notices routinely land on that same stream
# alongside the JSON, so `jq -e` on the combined text fails to PARSE (exit
# 5, not "selector didn't match") on almost every run regardless of what the
# JSON actually says, and the `else` branch (a bare parse failure) always
# reads as "pass". Verified live: at fb79d10, this same scenario emits the
# literal false green {"image":"rip-cage:latest","action":"built","status":
# "success"} on stdout with human-mode "Building ..." noise mixed onto the
# combined stream by 2>&1 -- the OLD combined-capture assertion still
# reported PASS. Capturing stdout separately makes T-FGc's jq -e see only
# the real JSON payload, so it can actually go red on this bug.
_tfg_stderr_file=$(mktemp)
_tfg_stdout=$(RC_TEST_OUTPUT_FORMAT=json run_cmd_build -o type=local,dest=/tmp/rc-test-fg-out 2>"$_tfg_stderr_file") || _tfg_rc=$?
_tfg_stderr=$(cat "$_tfg_stderr_file")
rm -f "$_tfg_stderr_file"
_tfg_out="${_tfg_stdout}${_tfg_stderr:+$'\n'}${_tfg_stderr}"

if [[ "$_tfg_rc" -ne 0 ]]; then
  pass "T-FGa: cmd_build returns non-zero for -o (never reaches a 'built' report)"
else
  fail "T-FGa: expected non-zero exit" "$_tfg_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T-FGb: docker was never invoked -- no build could have redirected output away from the image store while a stale \$IMAGE sat there for the validators to pass against"
else
  fail "T-FGb: expected no docker calls" "$(cat "$CALL_LOG")"
fi
if echo "$_tfg_stdout" | jq -e 'select(.status == "success" or .action == "built")' >/dev/null 2>&1; then
  fail "T-FGc: FALSE GREEN -- JSON output reports a built/success status for a redirected build" "$_tfg_stdout"
else
  pass "T-FGc: no false-green built/success status reported"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T40 (rip-cage-zqjz.2, re-judged rip-cage-zqjz.2 F1 round 2): rc build
#     --build-arg RC_VERSION=evil -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T40: rc build --build-arg RC_VERSION=evil -> rejected ==="
assert_unallowed_rejected T40 --build-arg RC_VERSION=evil

# ---------------------------------------------------------------------------
# T41: rc build --build-arg=RC_VERSION=evil -- equals form -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T41: rc build --build-arg=RC_VERSION=evil -> rejected ==="
assert_unallowed_rejected T41 --build-arg=RC_VERSION=evil

# ---------------------------------------------------------------------------
# T42 (rip-cage-zqjz.2 F1, round 2: POLICY FLIP -- was a positive control for
#     admission; --build-arg is now rejected WHOLESALE, not just its
#     RC_VERSION key): rc build --build-arg OTHER_KEY=value -- a DIFFERENT
#     --build-arg key -- must now be REJECTED too.
#
#     Round-1 judged this benign because "--build-arg only ever feeds
#     _image_is_current's staleness heuristic" -- true of the flag's NAME,
#     false of its VALUE namespace: `--build-arg BUILDKIT_SYNTAX=<image>`
#     replaces the Dockerfile FRONTEND BuildKit uses to interpret the
#     Dockerfile at all, so an admitted --build-arg lets a caller substitute
#     an arbitrary frontend and make _manifest_check_build_isolation's static
#     analysis of rc's OWN Dockerfile text vacuous (verified live against
#     docker 29.4.0: `docker build --build-arg BUILDKIT_SYNTAX=rip-cage-
#     bogus-frontend/nope:zzz -f Dockerfile .` -> "resolve image config for
#     docker-image://docker.io/rip-cage-bogus-frontend/nope:zzz", no `#
#     syntax=` pin in cage/Dockerfile contests it). A second, independent
#     channel: cage/Dockerfile interpolates several ARGs into RUN shell
#     strings (DOLT_VERSION, MISE_VERSION, BUN_VERSION, ...), so an admitted
#     caller --build-arg is build-time command injection into the image
#     tagged rip-cage:latest. No in-repo caller and no manifest build-arg
#     mechanism exists to preserve (grep across cli/lib/manifest*.sh,
#     manifest/, docs/reference/*.md returns nothing) -- so the ruling is
#     REJECT OUTRIGHT, same treatment as -f/-o, not a narrower RC_VERSION-only
#     carve-out. See T59-T61 below for the specific value-namespace and
#     bare-inherit-form cases this closes.
# ---------------------------------------------------------------------------
echo ""
echo "=== T42: rc build --build-arg OTHER_KEY=value -> now rejected (policy flip, F1) ==="
assert_unallowed_rejected T42 --build-arg OTHER_KEY=value

# ---------------------------------------------------------------------------
# T59 (rip-cage-zqjz.2 F1, THE motivating case): rc build --build-arg
#     BUILDKIT_SYNTAX=rip-cage-bogus-frontend/nope:zzz -- rejected before any
#     docker call. This is the exact value that hijacks the Dockerfile
#     frontend (see T42's comment) -- must never reach docker.
# ---------------------------------------------------------------------------
echo ""
echo "=== T59: rc build --build-arg BUILDKIT_SYNTAX=<image> -> rejected before any docker call ==="
assert_unallowed_rejected T59 --build-arg BUILDKIT_SYNTAX=rip-cage-bogus-frontend/nope:zzz

# ---------------------------------------------------------------------------
# T60: rc build --build-arg SOME_KEY (bare, no "=" -- docker's documented
#     inherit-from-the-caller's-environment form: `docker build --build-arg
#     V=good --build-arg V` yields V unset, verified live) -- rejected.
#     Round-1's RC_VERSION carve-out matched only "== RC_VERSION=*", which
#     REQUIRES the "=" -- this bare spelling would have slipped past it
#     (rip-cage-zqjz.2 F2). Wholesale rejection (F1's ruling) closes this
#     spelling gap too, by construction: there is no narrower guard left to
#     be spelling-incomplete.
# ---------------------------------------------------------------------------
echo ""
echo "=== T60: rc build --build-arg SOME_KEY (bare inherit-from-env form) -> rejected ==="
assert_unallowed_rejected T60 --build-arg SOME_KEY

# ---------------------------------------------------------------------------
# T61: rc build --build-arg=SOME_KEY (equals-attached, still the bare
#     inherit-from-env form -- no embedded "=" after the key) -- rejected.
# ---------------------------------------------------------------------------
echo ""
echo "=== T61: rc build --build-arg=SOME_KEY (equals-attached inherit-from-env form) -> rejected ==="
assert_unallowed_rejected T61 --build-arg=SOME_KEY

# ---------------------------------------------------------------------------
# T43 (regression guard): rc build --no-cache -- boolean, admitted (same
#     case as T9, now exercised via the explicit admit path rather than
#     blanket unrecognized-flag passthrough).
# ---------------------------------------------------------------------------
echo ""
echo "=== T43: rc build --no-cache -> admitted, passes through ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t43_rc=0
_t43_out=$(run_cmd_build --no-cache 2>&1) || _t43_rc=$?
_t43_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t43_rc" -eq 0 && "$_t43_build_line" == *"--no-cache"* ]]; then
  pass "T43: --no-cache admitted and present in the constructed argv"
else
  fail "T43: expected --no-cache to pass through, rc=$_t43_rc" "$_t43_out / $_t43_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T44: rc build --pull -- boolean, admitted.
# ---------------------------------------------------------------------------
echo ""
echo "=== T44: rc build --pull -> admitted, passes through ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t44_rc=0
_t44_out=$(run_cmd_build --pull 2>&1) || _t44_rc=$?
_t44_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t44_rc" -eq 0 && "$_t44_build_line" == *"--pull"* ]]; then
  pass "T44: --pull admitted and present in the constructed argv"
else
  fail "T44: expected --pull to pass through, rc=$_t44_rc" "$_t44_out / $_t44_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T45: rc build --progress=quiet -- equals form, admitted.
# ---------------------------------------------------------------------------
echo ""
echo "=== T45: rc build --progress=quiet -> admitted, passes through ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t45_rc=0
_t45_out=$(run_cmd_build --progress=quiet 2>&1) || _t45_rc=$?
_t45_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t45_rc" -eq 0 && "$_t45_build_line" == *"--progress=quiet"* ]]; then
  pass "T45: --progress=quiet admitted and present in the constructed argv"
else
  fail "T45: expected --progress=quiet to pass through, rc=$_t45_rc" "$_t45_out / $_t45_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T46: rc build --progress plain -- separate-arg form, admitted.
# ---------------------------------------------------------------------------
echo ""
echo "=== T46: rc build --progress plain -> admitted, passes through ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t46_rc=0
_t46_out=$(run_cmd_build --progress plain 2>&1) || _t46_rc=$?
_t46_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t46_rc" -eq 0 && "$_t46_build_line" == *"--progress plain"* ]]; then
  pass "T46: --progress plain admitted and present in the constructed argv"
else
  fail "T46: expected --progress plain to pass through, rc=$_t46_rc" "$_t46_out / $_t46_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T47: rc build -q -- bare boolean short flag, admitted.
# ---------------------------------------------------------------------------
echo ""
echo "=== T47: rc build -q -> admitted, passes through ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t47_rc=0
_t47_out=$(run_cmd_build -q 2>&1) || _t47_rc=$?
_t47_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t47_rc" -eq 0 && " $_t47_build_line " == *" -q "* ]]; then
  pass "T47: -q admitted and present as its own token in the constructed argv"
else
  fail "T47: expected a standalone -q token, rc=$_t47_rc" "$_t47_out / $_t47_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T48: rc build -D -- bare boolean short flag, admitted.
# ---------------------------------------------------------------------------
echo ""
echo "=== T48: rc build -D -> admitted, passes through ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t48_rc=0
_t48_out=$(run_cmd_build -D 2>&1) || _t48_rc=$?
_t48_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t48_rc" -eq 0 && " $_t48_build_line " == *" -D "* ]]; then
  pass "T48: -D admitted and present as its own token in the constructed argv"
else
  fail "T48: expected a standalone -D token, rc=$_t48_rc" "$_t48_out / $_t48_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T49: rc build -Dq -- pure boolean short cluster (no value-taking flag),
#      admitted.
# ---------------------------------------------------------------------------
echo ""
echo "=== T49: rc build -Dq -> admitted, passes through ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t49_rc=0
_t49_out=$(run_cmd_build -Dq 2>&1) || _t49_rc=$?
_t49_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t49_rc" -eq 0 && " $_t49_build_line " == *" -Dq "* ]]; then
  pass "T49: -Dq admitted and present as its own token in the constructed argv"
else
  fail "T49: expected a standalone -Dq token, rc=$_t49_rc" "$_t49_out / $_t49_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T50: rc build --debug -- long form of -D, admitted.
# ---------------------------------------------------------------------------
echo ""
echo "=== T50: rc build --debug -> admitted, passes through ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t50_rc=0
_t50_out=$(run_cmd_build --debug 2>&1) || _t50_rc=$?
_t50_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t50_rc" -eq 0 && "$_t50_build_line" == *"--debug"* ]]; then
  pass "T50: --debug admitted and present in the constructed argv"
else
  fail "T50: expected --debug to pass through, rc=$_t50_rc" "$_t50_out / $_t50_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T51: rc build --quiet -- long form of -q, admitted.
# ---------------------------------------------------------------------------
echo ""
echo "=== T51: rc build --quiet -> admitted, passes through ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t51_rc=0
_t51_out=$(run_cmd_build --quiet 2>&1) || _t51_rc=$?
_t51_build_line=$(grep '^docker build' "$CALL_LOG" || true)
if [[ "$_t51_rc" -eq 0 && "$_t51_build_line" == *"--quiet"* ]]; then
  pass "T51: --quiet admitted and present in the constructed argv"
else
  fail "T51: expected --quiet to pass through, rc=$_t51_rc" "$_t51_out / $_t51_build_line"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T52 (named reject): rc build --target foo -- can skip stages that install
#     the safety floor (verified: cage/Dockerfile's go-builder stage vs. the
#     final debian:trixie runtime stage -- --target go-builder would build
#     ONLY the go compiler stage, never reaching the runtime stage that sets
#     up the non-root agent user / safety-stack assets the validators check).
# ---------------------------------------------------------------------------
echo ""
echo "=== T52: rc build --target foo -> rejected ==="
assert_unallowed_rejected T52 --target foo

# ---------------------------------------------------------------------------
# T53 (named reject): rc build --label rc.multiplexers=herdr -- forges the
#     SOLE authoritative multiplexer-registry label (cli/lib/config.sh:159).
# ---------------------------------------------------------------------------
echo ""
echo "=== T53: rc build --label rc.multiplexers=herdr -> rejected ==="
assert_unallowed_rejected T53 --label rc.multiplexers=herdr

# ---------------------------------------------------------------------------
# T54 (named reject): rc build --secret id=x -- build-time credential
#     injection (ADR-005 D9 / ADR-024).
# ---------------------------------------------------------------------------
echo ""
echo "=== T54: rc build --secret id=x -> rejected ==="
assert_unallowed_rejected T54 --secret id=x

# ---------------------------------------------------------------------------
# T55 (named reject): rc build --push -- registry side effect.
# ---------------------------------------------------------------------------
echo ""
echo "=== T55: rc build --push -> rejected ==="
assert_unallowed_rejected T55 --push

# ---------------------------------------------------------------------------
# T56 (named reject): rc build --platform linux/amd64 -- could produce an
#     image this host cannot run while validators still inspect it.
# ---------------------------------------------------------------------------
echo ""
echo "=== T56: rc build --platform linux/amd64 -> rejected ==="
assert_unallowed_rejected T56 --platform linux/amd64

# ---------------------------------------------------------------------------
# T57 (forward-compat closure): rc build --some-brand-new-docker-flag x --
#     rejected via the GENERIC fail-closed default (not a named case) --
#     proves an unrecognized/future docker flag fails closed instead of
#     silently reaching docker (closes rip-cage-fo4z's forward-compat
#     caveat: "if docker build ever gains a new boolean short flag...").
# ---------------------------------------------------------------------------
echo ""
echo "=== T57 (forward-compat): rc build --some-brand-new-docker-flag x -> rejected ==="
assert_unallowed_rejected T57 --some-brand-new-docker-flag x

# ---------------------------------------------------------------------------
# T58 (stray positional): rc build /tmp/not-a-flag -- rc supplies the build
#     context positional itself; a caller-supplied one must fail loud in rc,
#     not silently become a second positional docker would otherwise
#     hard-error on.
# ---------------------------------------------------------------------------
echo ""
echo "=== T58: rc build /tmp/not-a-flag (stray positional) -> rejected ==="
assert_unallowed_rejected T58 /tmp/not-a-flag

# ---------------------------------------------------------------------------
# T62 (adversarial-review minor 1): rc build --output=json -- still REJECTED
#     (the safety posture holds: -o/--output is rejected regardless of its
#     value), but the error message must distinguish this from a genuine
#     BuildKit-output-redirect attempt -- "--output=json" is a plausible way
#     for a caller to ask for rc's own JSON display mode (rc's usage() and
#     cli-reference.md document `rc --output json <command>` / `rc build
#     --output json`, two SEPARATE words -- that spelling is intercepted
#     upstream by rc's OWN global flag scanner before cmd_build ever runs,
#     and is NOT rejected at all; only the single-token `--output=json`
#     equals-form and the short `-o json`/`-o=json`/`-ojson` spellings reach
#     this rejection). The message should name that escape hatch so the
#     caller isn't left thinking JSON output is unsupported for `rc build`.
# ---------------------------------------------------------------------------
echo ""
echo "=== T62: rc build --output=json -> still rejected, but message distinguishes rc's own --output json ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t62_rc=0
_t62_out=$(run_cmd_build --output=json 2>&1) || _t62_rc=$?
if [[ "$_t62_rc" -ne 0 ]]; then
  pass "T62a: cmd_build returns non-zero"
else
  fail "T62a: expected non-zero exit" "$_t62_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T62b: docker was never invoked"
else
  fail "T62b: expected no docker calls" "$(cat "$CALL_LOG")"
fi
if [[ "$_t62_out" == *"rc --output json"* || "$_t62_out" == *"rc build --output json"* ]]; then
  pass "T62c: error message points to rc's own --output json (two-word) form"
else
  fail "T62c: expected a hint pointing to rc's own --output json flag" "$_t62_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T63 (same as T62, short-flag spelling): rc build -o json -- rejected, same
#     distinguishing hint (a caller might plausibly try the short flag
#     thinking it mirrors rc's own global -o... except rc has no global -o
#     short spelling at all -- only --output; the hint should still fire
#     since the VALUE is "json").
# ---------------------------------------------------------------------------
echo ""
echo "=== T63: rc build -o json -> still rejected, same distinguishing hint ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t63_rc=0
_t63_out=$(run_cmd_build -o json 2>&1) || _t63_rc=$?
if [[ "$_t63_rc" -ne 0 ]]; then
  pass "T63a: cmd_build returns non-zero"
else
  fail "T63a: expected non-zero exit" "$_t63_out"
fi
if [[ ! -s "$CALL_LOG" ]]; then
  pass "T63b: docker was never invoked"
else
  fail "T63b: expected no docker calls" "$(cat "$CALL_LOG")"
fi
if [[ "$_t63_out" == *"rc --output json"* || "$_t63_out" == *"rc build --output json"* ]]; then
  pass "T63c: error message points to rc's own --output json (two-word) form"
else
  fail "T63c: expected a hint pointing to rc's own --output json flag" "$_t63_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T64 (regression guard): rc build -o type=local,dest=/tmp/x -- the REAL
#     BuildKit-output-redirect attempt, value != "json" -- must NOT get the
#     "did you mean --output json" hint (would be actively misleading for
#     the false-green scenario this reject exists for).
# ---------------------------------------------------------------------------
echo ""
echo "=== T64 (regression guard): rc build -o type=local,dest=/tmp/x -> rejected, NO json hint ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t64_out=$(run_cmd_build -o type=local,dest=/tmp/rc-test-t64-out 2>&1) || true
if [[ "$_t64_out" != *"rc --output json"* && "$_t64_out" != *"rc build --output json"* ]]; then
  pass "T64: no spurious --output-json hint for a real BuildKit output-redirect value"
else
  fail "T64: unexpected --output-json hint for a non-json value" "$_t64_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T65 (adversarial-review minor 2): rc build -f <path> (separate-arg
#     spelling) -- the -f/--file rejection message must name the allowlist
#     section AND the rc generate-dockerfile escape hatch, same as every
#     other rejection message added by rip-cage-zqjz.2 (-o, --build-arg, the
#     catch-all default). It was the one reject site NOT updated when those
#     were added (it predates rip-cage-zqjz.2, from rip-cage-zqjz).
# ---------------------------------------------------------------------------
echo ""
echo "=== T65: rc build -f <path> (separate-arg) -> message names allowlist + escape hatch ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t65_out=$(run_cmd_build -f /tmp/rc-test-t65-dockerfile 2>&1) || true
if [[ "$_t65_out" == *"flag allowlist"* ]]; then
  pass "T65a: message names the allowlist section"
else
  fail "T65a: expected message to name 'flag allowlist'" "$_t65_out"
fi
if [[ "$_t65_out" == *"generate-dockerfile"* ]]; then
  pass "T65b: message names the rc generate-dockerfile escape hatch"
else
  fail "T65b: expected message to name 'generate-dockerfile'" "$_t65_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T66 (adversarial-review minor 2, cluster-regex reject site): rc build
#     -Df<path> (boolean-prefixed cluster, attached value) -- same message
#     consistency requirement as T65, but for the SECOND -f reject site (the
#     catch-all regex branch), which had the identical staleness.
# ---------------------------------------------------------------------------
echo ""
echo "=== T66: rc build -Df<path> (cluster) -> message names allowlist + escape hatch ==="
setup_sandbox
setup_fake_docker
CALL_LOG=$(mktemp)
_t66_out=$(run_cmd_build -Df/tmp/rc-test-t66-dockerfile 2>&1) || true
if [[ "$_t66_out" == *"flag allowlist"* ]]; then
  pass "T66a: message names the allowlist section"
else
  fail "T66a: expected message to name 'flag allowlist'" "$_t66_out"
fi
if [[ "$_t66_out" == *"generate-dockerfile"* ]]; then
  pass "T66b: message names the rc generate-dockerfile escape hatch"
else
  fail "T66b: expected message to name 'generate-dockerfile'" "$_t66_out"
fi
cleanup; TEST_HOME=""; CALL_LOG=""; MOCK_BIN=""

# ---------------------------------------------------------------------------
# T-DASHDASH (closes a real hole found while implementing this bead): rc
#     build -- -o type=local,dest=/tmp/x -- must ALSO be rejected. Prior `--`
#     handling (a51b5da/fb79d10) dumped every token after `--` into the
#     constructed argv UNFILTERED (no -t/-f interception, and -- pre-dates
#     this bead's -o check too) -- a caller could bypass the entire
#     allowlist, including the -o false-green, just by prefixing it with
#     `--`. Closed by removing the special-cased verbatim-passthrough
#     branch: `--` now falls through to the same fail-closed default as any
#     other unrecognized token.
# ---------------------------------------------------------------------------
echo ""
echo "=== T-DASHDASH: rc build -- -o type=local,dest=/tmp/x -> still rejected (no bypass via --) ==="
assert_unallowed_rejected T-DASHDASH -- -o type=local,dest=/tmp/rc-test-dashdash-out

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-build-flag-override.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-build-flag-override.sh: all ${TOTAL} tests passed ==="
