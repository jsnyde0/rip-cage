#!/usr/bin/env bash
#
# Every case here scopes PATH to ONE invocation on purpose -- a per-command
# prefix, or a `( export PATH=...; ... )` subshell where several variables
# travel together. Shellcheck reads the subshell as an accident ("that change
# might be lost") and then flags every later per-command prefix as a leak from
# it. Both readings are wrong for this file: nothing here wants a PATH change
# to outlive its own case, because a leaked fake binary would silently poison
# the next one. (File-level, so it must sit above the first command.)
# shellcheck disable=SC2030,SC2031
set -uo pipefail

# Test prerequisite checks in rc
# Uses PATH manipulation to simulate missing tools

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

# Create temp dirs for fake binaries
FAKE_BIN=$(mktemp -d)
SYMLINK_BIN=$(mktemp -d)   # symlink farm for PATH without jq
T2_WKSP=""                 # initialized here so cleanup() can safely remove it
T2_ROOT=""                 # ditto — the rip-cage-ely4.7.2 fixture root
cleanup() {
  rm -rf "$FAKE_BIN" "$SYMLINK_BIN"
  [[ -n "$T2_WKSP" ]] && rm -rf "$T2_WKSP"
  [[ -n "$T2_ROOT" ]] && rm -rf "$T2_ROOT"
}
trap cleanup EXIT

# Fake docker that reports daemon not running
cat > "$FAKE_BIN/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
  echo "Error response from daemon: Is the docker daemon running?" >&2
  exit 1
fi
exit 0
DOCKEREOF
chmod +x "$FAKE_BIN/docker"

# Build a PATH that has no jq at all.
# Strategy: symlink every executable from the real PATH dirs into SYMLINK_BIN, skipping jq.
# This gives us a single-dir PATH that has all needed tools (bash, dirname, etc.) minus jq.
_build_nojq_path() {
  local target_dir="$1"
  local skip_tool="$2"
  # Walk each dir in PATH
  local IFS=':'
  for dir in $PATH; do
    [[ -d "$dir" ]] || continue
    for bin in "$dir"/*; do
      local name
      name="$(basename "$bin")"
      [[ "$name" == "$skip_tool" ]] && continue  # skip the tool we want absent
      [[ -x "$bin" ]] || continue
      # Only link if not already present (first-in-PATH wins)
      [[ -e "$target_dir/$name" ]] || ln -sf "$bin" "$target_dir/$name"
    done
  done
  echo "$target_dir"
}

NOJQ_BIN=$(_build_nojq_path "$SYMLINK_BIN" "jq")

# -----------------------------------------------
# Test 1: Missing jq — rc doctor --output json fails with helpful message
# -----------------------------------------------
echo ""
echo "=== Test 1: Missing jq gives helpful error for --output json ==="

# Use the symlink-farm PATH that has everything except jq
# `rc ls` was this case's original subject; it retired with the six-verb
# thinning (rip-cage-ely4.10). `rc doctor` sits behind the same check_jq
# preflight arm, so the assertion is unchanged.
output=$(RC_ALLOWED_ROOTS="$HOME" PATH="$NOJQ_BIN" "$RC" doctor --output json 2>&1 || true)
if echo "$output" | grep -qi "jq"; then
  pass "missing jq: error mentions 'jq'"
else
  fail "missing jq: error should mention 'jq'" "$output"
fi
if echo "$output" | grep -qi "install"; then
  pass "missing jq: error mentions 'install'"
else
  fail "missing jq: error should give install instructions" "$output"
fi

# -----------------------------------------------
# Test 2: a multiplexer the image does not carry is refused BEFORE any msb
# call (rip-cage-ely4.7.2 / ADR-001 fail-loud, ADR-005 D12).
#
# THE REGRESSION THIS PINS. The original Test 2 asserted that an out-of-set
# `session.multiplexer` failed at config-validate time, before any cage
# existed. rip-cage-ely4.9 retired the config schema and its validator, and
# the check went with them: `rc up` created the cage, ran init, and only
# failed at attach -- leaving a real stray cage behind on a plain repair run.
#
# "No cage was created" is the WHOLE property, and an exit-code assertion
# cannot see it: a refusal and a create-then-fail both exit non-zero. So each
# case runs with a PATH shim in front of msb that RECORDS what it was asked to
# do, drops a sentinel for any real subcommand, and answers only `--version`
# (rc's own preflight legitimately calls that before dispatch). The assertion
# is the sentinel's absence.
# -----------------------------------------------
echo ""
echo "=== Test 2: RC_MULTIPLEXER naming a multiplexer the image lacks refuses pre-create ==="

# /private/tmp, never /tmp: msb does not follow a host-side symlink in a bind
# source, and on macOS /tmp IS a symlink to /private/tmp.
T2_ROOT="$(mktemp -d /private/tmp/rc-ely472-XXXXXX)"
T2_BIN="${T2_ROOT}/bin"
T2_PROJ="${T2_ROOT}/proj"
T2_LOG="${T2_ROOT}/msb-invocations.log"
T2_SENTINEL="${T2_ROOT}/MSB_WAS_SPAWNED"
mkdir -p "$T2_BIN" "$T2_PROJ" "${T2_ROOT}/home"

cat > "${T2_BIN}/msb" <<'T2_SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${T2_LOG}"
case "${1:-}" in
  --version) echo "msb 0.6.18-test-shim"; exit 0 ;;
esac
: > "${T2_SENTINEL}"
echo "test shim: msb was invoked with: $*" >&2
exit 1
T2_SHIM
chmod +x "${T2_BIN}/msb"

cat > "${T2_ROOT}/cage.yaml" <<T2_CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${T2_PROJ}:/workspace"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
T2_CONF

# Throwaway XDG config dir so nothing here reads or writes the real
# ~/.config/rip-cage. HOME is deliberately NOT overridden -- docker resolves
# its context and socket through $HOME, and a fake one makes rc's docker
# preflight fail, which would make every case below report a daemon error
# instead of testing its own subject.
t2_run_rc() {
  ( export PATH="${T2_BIN}:${PATH}"
    export XDG_CONFIG_HOME="${T2_ROOT}/home/.config"
    export RC_CAGE_CONF="${T2_ROOT}/cage.yaml"
    export T2_LOG T2_SENTINEL T2_DOCKER_LOG
    export RC_MULTIPLEXER="$1"
    shift
    "$RC" "$@" ) 2>&1
}

# --- (a) an absent multiplexer refuses, names itself, names rc build -------
# The name is deliberately one no manifest would ever declare, so this cannot
# pass by accident on an operator image that happens to bake several.
rm -f "$T2_SENTINEL" "$T2_LOG"
t2_out=$(t2_run_rc rc-ely472-nosuchmux up "$T2_PROJ")
t2_exit=$?

if [[ "$t2_exit" -ne 0 ]]; then
  pass "2a: rc up exits non-zero for a multiplexer the image does not carry (exit ${t2_exit})"
else
  fail "2a: rc up exited 0 with RC_MULTIPLEXER naming a multiplexer no image carries" "$t2_out"
fi
if printf '%s\n' "$t2_out" | grep -q "rc-ely472-nosuchmux"; then
  pass "2a: the refusal names the requested multiplexer"
else
  fail "2a: the refusal does not name the requested multiplexer" "$t2_out"
fi
if printf '%s\n' "$t2_out" | grep -q "rc build"; then
  pass "2a: the refusal names 'rc build' as the fix"
else
  fail "2a: the refusal does not name 'rc build' as the fix" "$t2_out"
fi
if [[ -f "$T2_SENTINEL" ]]; then
  fail "2a: msb WAS spawned before the refusal — the check is fail-open" "invocations: $(cat "$T2_LOG" 2>/dev/null)"
else
  pass "2a: no msb subcommand ran — rc refused before the cage could exist"
fi

# --- (b) RC_MULTIPLEXER=none inspects no image ----------------------------
# The default must cost nothing: most cages run no multiplexer, and a probe on
# every launch for a feature almost nobody uses is its own kind of wrong. The
# observable is a docker shim that records every invocation: `docker image
# read of the image's boot descriptor must not appear under `none`.
T2_DOCKER_LOG="${T2_ROOT}/docker-invocations.log"
# The shim records, then hands off to the REAL docker by absolute path (resolved
# now, while T2_BIN is not yet on PATH) — rc's other docker calls must still
# behave, or this stops measuring the multiplexer probe and starts measuring a
# broken docker.
T2_REAL_DOCKER="$(command -v docker)"
cat > "${T2_BIN}/docker" <<T2_DOCKER
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${T2_DOCKER_LOG}"
exec "${T2_REAL_DOCKER}" "\$@"
T2_DOCKER
chmod +x "${T2_BIN}/docker"

rm -f "$T2_SENTINEL" "$T2_LOG"
: > "$T2_DOCKER_LOG"
t2_run_rc none up --dry-run "$T2_PROJ" >/dev/null 2>&1

t2_desc_probes=$(grep -c 'boot.json' "$T2_DOCKER_LOG" 2>/dev/null) || t2_desc_probes=0
if [[ "$t2_desc_probes" -eq 0 ]]; then
  pass "2b: RC_MULTIPLEXER=none reads no boot descriptor out of the image"
else
  fail "2b: RC_MULTIPLEXER=none read the image's boot descriptor" "$(cat "$T2_DOCKER_LOG")"
fi

# NEGATIVE CONTROL for 2b: the SAME run with a named multiplexer must produce
# exactly that probe. Without this, 2b would pass against a check that was
# simply never wired up.
rm -f "$T2_SENTINEL" "$T2_LOG"
: > "$T2_DOCKER_LOG"
t2_run_rc rc-ely472-nosuchmux up "$T2_PROJ" >/dev/null 2>&1

t2_named_probes=$(grep -c 'boot.json' "$T2_DOCKER_LOG" 2>/dev/null) || t2_named_probes=0
if [[ "$t2_named_probes" -gt 0 ]]; then
  pass "2b: a NAMED multiplexer does read the image's descriptor — 2b is not vacuous"
else
  fail "2b: a named multiplexer read no descriptor either — 2b proves nothing" "$(cat "$T2_DOCKER_LOG")"
fi

rm -f "${T2_BIN}/docker"

# -----------------------------------------------
echo ""
echo "=== Test 3: Docker daemon not running gives helpful error ==="

# rip-cage-d2bo kind-1 (harmless): $FAKE_BIN/docker (defined above) exits 1
# with "Is the docker daemon running?" on `docker info` specifically (any
# other subcommand, including `build`, is a silent exit-0 no-op) -- `rc
# build`'s dispatch runs check_docker first (rc:195), which calls `docker
# info` and exits loud on that failure BEFORE cmd_build ever reaches a real
# `docker build`. This is Test 3's whole point.
output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" build 2>&1 || true)
if echo "$output" | grep -qi "docker"; then
  pass "docker not running: error mentions 'docker'"
else
  fail "docker not running: error should mention 'docker'" "$output"
fi
if echo "$output" | grep -qi "running\|daemon\|start"; then
  pass "docker not running: error mentions daemon/running/start"
else
  fail "docker not running: error should mention daemon status" "$output"
fi

# -----------------------------------------------
# Test 3b: msb runtime not reachable — rc destroy fails with a helpful,
# msb-specific message (rip-cage-tsf2.1; subject moved off the retired
# `rc ls` by rip-cage-ely4.10 — same check_msb preflight arm).
# -----------------------------------------------
echo ""
echo "=== Test 3b: msb not reachable gives a helpful msb-specific error ==="

FAKE_MSB_BIN=$(mktemp -d)
cat > "$FAKE_MSB_BIN/msb" <<'FAKEMSB'
#!/usr/bin/env bash
echo "msb: connection refused" >&2
exit 1
FAKEMSB
chmod +x "$FAKE_MSB_BIN/msb"

output=$(PATH="$FAKE_MSB_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" destroy 2>&1 || true)
if echo "$output" | grep -qi "msb"; then
  pass "msb not reachable: error mentions 'msb'"
else
  fail "msb not reachable: error should mention 'msb'" "$output"
fi
if echo "$output" | grep -qi "reachable\|unresponsive"; then
  pass "msb not reachable: error mentions reachability status"
else
  fail "msb not reachable: error should mention reachability status" "$output"
fi
rm -rf "$FAKE_MSB_BIN"

# -----------------------------------------------
# Test 4: Commands that need docker check it (build); commands rewired onto
# msb by rip-cage-tsf2.1 check msb instead. That list was ls/attach/down/
# destroy/test; the six-verb thinning (rip-cage-ely4.10) leaves destroy and
# test, which is the whole surviving msb-preflight set.
# -----------------------------------------------
echo ""
echo "=== Test 4: Docker check runs for build; msb check runs for the msb-rewired verbs ==="

# rip-cage-d2bo kind-1 (harmless): same $FAKE_BIN/docker shim as Test 3 above
# -- `docker info` exits 1, check_docker (rc:195) exits loud on that BEFORE
# cmd_build ever reaches a real `docker build`.
output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" build 2>&1 || true)
if echo "$output" | grep -qi "docker"; then
  pass "docker check for 'rc build'"
else
  fail "docker check for 'rc build'" "$output"
fi

FAKE_MSB_BIN=$(mktemp -d)
cat > "$FAKE_MSB_BIN/msb" <<'FAKEMSB'
#!/usr/bin/env bash
echo "msb: connection refused" >&2
exit 1
FAKEMSB
chmod +x "$FAKE_MSB_BIN/msb"

# Both need an arg, but the msb check runs first.
for cmd in destroy test; do
  output=$(PATH="$FAKE_MSB_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" $cmd 2>&1 || true)
  if echo "$output" | grep -qi "msb"; then
    pass "msb check for 'rc $cmd'"
  else
    fail "msb check for 'rc $cmd'" "$output"
  fi
done
rm -rf "$FAKE_MSB_BIN"

# -----------------------------------------------
# Test 5: a verb needing neither runtime does NOT trigger the docker check
# -----------------------------------------------
# `rc schema` (the original docker-independent verb this smoke used) retired
# with the rip-cage config schema (rip-cage-ely4.9 / ADR-031 D2), and its
# replacement `rc completions bash` retired with the six-verb thinning
# (rip-cage-ely4.10 / ADR-031 D3). `rc --version` is what is left, and it
# proves the same thing: a path dispatched without ever reaching the
# check_docker/check_msb preflight case block in rc (see rc's "prerequisite
# checks" comment above the "Main dispatch" case) still works against the
# fake, daemon-not-running docker on PATH.
echo ""
echo "=== Test 5: a verb needing neither runtime does not require docker ==="

output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" --version 2>&1 || true)
if echo "$output" | grep -q '^rc version '; then
  pass "rc --version works without docker daemon"
else
  fail "rc --version should work without docker daemon" "$output"
fi

# -----------------------------------------------
# Test 6: RETIRED into tests/test-rc-commands.sh Test 1b (rip-cage-ely4.10)
# -----------------------------------------------
# Asserted that `rc init` falls through to usage. Test 1b there now sweeps
# every deleted verb through the same `*)` arm and checks the exit code too,
# which this case never did.

# -----------------------------------------------
# Summary
# -----------------------------------------------
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All prerequisite tests passed."
else
  echo "$FAILURES test(s) FAILED."
  exit 1
fi
