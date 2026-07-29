#!/usr/bin/env bash
# Tier-2 real-cage behavioral tests for per-asset ro/rw mount mode (rip-cage-wlwc.3).
# ADR-027 D1 (per-asset ro/rw mount).
#
# ALL TESTS ARE GATED BEHIND RC_E2E=1.
# These tests require a running Docker daemon (image build/inspect only --
# rip-cage:latest is still docker-built), msb as the cage runtime (`rc up`
# creates msb sandboxes, invisible to docker ps/exec), and the ability to
# spin up a rip-cage cage. They are skipped when RC_E2E is not set.
#
# What is proven at Tier-2:
#
#   RE1 — ro mount: agent write attempt inside the cage returns EACCES/EROFS.
#          Effect: the write FAILS (not just that the :ro flag is present).
#
#   RE2 — rw mount: agent write inside the cage actually writes through to the host.
#          Effect: a file written inside the cage is visible on the HOST filesystem.
#
#   RE3 — Mixed: one cage runs an rw skill alongside an ro guard simultaneously on
#          SEPARATE load paths, both holding (floor-lock half (a) of the seam).
#          Effect: the ro guard cannot be written (EACCES), the rw skill can be written
#          and the write propagates to the host.
#
# Anti-false-green discipline:
#   * RE1 asserts the write FAILS with a permission error (not just that :ro is set).
#   * RE2 asserts the file EXISTS on the HOST after writing inside the cage.
#   * RE3 asserts both effects hold simultaneously.
#   * Every failure increments FAILURES.
#   * Script exits non-zero on any failure.
#
# To run:
#   RC_E2E=1 bash tests/test-mount-mode-e2e.sh
#   RC_E2E=1 RC_E2E_REBUILD=1 bash tests/test-mount-mode-e2e.sh  # force rc build first
#
# NOTE: These tests require a pre-built rip-cage image OR RC_E2E_REBUILD=1 to trigger
# a rebuild. If the image is missing and RC_E2E_REBUILD is not set, the tests skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

# REAL_MSB_HOME (msb-port note, mirrors test-e2e-lifecycle.sh /
# test-pi-auth-mount.sh): _spin_up_cage below overrides HOME per-invocation
# to a throwaway per-cage tmpdir for config isolation. msb derives its
# per-sandbox agent-relay Unix socket path from $HOME by default, and the
# tmpdir path is long enough on macOS to overflow the 104-byte AF_UNIX path
# limit ("agent relay socket path is too long"). Pointing MSB_HOME at the
# real, unmodified microsandbox home for that same invocation sidesteps it.
REAL_MSB_HOME="${HOME}/.microsandbox"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# Gate: RC_E2E=1 required
# ---------------------------------------------------------------------------
if [[ "${RC_E2E:-}" != "1" ]]; then
  echo "SKIP (NEEDS_CONTAINER / RC_E2E): test-mount-mode-e2e.sh — set RC_E2E=1 to run"
  echo "  RE1: ro mount write → EACCES/EROFS (effect-based, not just :ro flag present)"
  echo "  RE2: rw mount write → writes through to host filesystem"
  echo "  RE3: mixed cage: ro guard + rw skill simultaneously on separate paths, both holding"
  exit 0
fi

# ---------------------------------------------------------------------------
# Image availability check
# ---------------------------------------------------------------------------
if [[ "${RC_E2E_REBUILD:-0}" == "1" ]]; then
  echo "=== Building rip-cage:latest (RC_E2E_REBUILD=1) ==="
  if ! "${RC}" build; then
    echo "FAIL: rc build failed — cannot run Tier-2 mount mode tests."
    exit 1
  fi
  pass "Image build (RC_E2E_REBUILD=1)"
else
  if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
    echo "SKIP: rip-cage:latest not built — run ./rc build first (or set RC_E2E_REBUILD=1)"
    exit 0
  fi
  echo "Using existing rip-cage:latest (set RC_E2E_REBUILD=1 to rebuild)"
fi

# docker still builds/holds the image (checked above); msb is the cage
# runtime `rc up` drives now (rip-cage-neu7.12, Batch C).
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available — cannot spin up cages for RE1-RE3"
  exit 0
fi

echo "=== test-mount-mode-e2e.sh — real-cage ro/rw mount behavioral probes (rip-cage-wlwc.3) ==="
echo ""

# Register-array cleanup shape (incident-hardened, rip-cage-neu7.12): every
# cage this test creates is tracked here and destroyed via `rc destroy
# --force` (which also removes its rc-state/rc-history volumes) -- never
# enumerated/pattern-matched (see /tmp/msb-port-canonical.md).
CREATED_CAGES=()
_track() { CREATED_CAGES+=("$1"); }

_e2e_cleanup() {
  local cage
  for cage in "${CREATED_CAGES[@]:-}"; do
    [[ -n "$cage" ]] && "${RC}" destroy --force "$cage" >/dev/null 2>&1 || true
  done
}
trap _e2e_cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: spin up a minimal cage with a manifest-declared mount and return
# the container name. The workspace is a fresh tmpdir; the cage is daemonized.
#
# Usage: _spin_up_cage <cage_suffix> <manifest_yaml> <ws_base_tmpdir>
# Writes the container name to stdout.
# ---------------------------------------------------------------------------
_spin_up_cage() {
  local suffix="$1"
  local manifest_yaml="$2"
  local ws_base="$3"

  local cage_name="rc-mount-mode-e2e-${suffix}"
  local ws="${ws_base}/rc/${cage_name}"
  mkdir -p "$ws"

  local home_dir="${ws_base}/home-${suffix}"
  mkdir -p "${home_dir}/.config/rip-cage"
  printf '%s\n' "$manifest_yaml" > "${home_dir}/.config/rip-cage/tools.yaml"
  cat > "${home_dir}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist:
    - ".ssh"
    - ".gnupg"
    - ".aws"
  allow_risky: null
YAML

  local ws_real
  ws_real=$(realpath "$ws_base" 2>/dev/null) || ws_real="$ws_base"

  # rc up in non-TTY context — ignore the attach exit code but verify container running.
  # MSB_HOME pinned to the real microsandbox home (see REAL_MSB_HOME note above)
  # so the per-cage HOME override doesn't overflow msb's AF_UNIX socket path limit.
  #
  # rc up's own stdout+stderr is redirected to a log file, NOT left to leak
  # into this function's return value: _spin_up_cage's caller captures its
  # stdout via `$(...)` to get the cage name, and `rc up` (human mode)
  # prints many diagnostic lines (init log, warnings, etc.) — leaving those
  # unredirected corrupts the captured name into a multi-line blob (a
  # pre-existing bug, predates this msb port; caught while verifying the
  # port here since it blocks RE1-RE3 from ever reaching a real cage).
  local up_log
  up_log=$(mktemp)
  HOME="$home_dir" MSB_HOME="$REAL_MSB_HOME" XDG_CONFIG_HOME="${home_dir}/.config" \
    RC_MANIFEST_GLOBAL="${home_dir}/.config/rip-cage/tools.yaml" \
    RC_CONFIG_GLOBAL="${home_dir}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="$ws_real" \
    "${RC}" up "${ws}" >"$up_log" 2>&1 || true

  # Resolve the ACTUAL cage name by workspace/source_path (canonical port
  # idiom, /tmp/msb-port-canonical.md) rather than trusting $cage_name as
  # given to `rc up`: container_name() derives the real name from the last
  # two path components of $ws ("rc" + "$cage_name"), which prepends an
  # extra "rc-" here since $cage_name already starts with "rc-" — a
  # pre-existing naming quirk in this helper's workspace staging (predates
  # this msb port), not something the port should silently paper over by
  # assuming a name. Resolving by source_path sidesteps it and matches
  # whatever `rc up` actually created, so cleanup destroys the right cage.
  local ws_full_real
  ws_full_real=$(realpath "$ws" 2>/dev/null) || ws_full_real="$ws"
  local real_cage_name
  real_cage_name=$("${RC}" ls --output json 2>/dev/null | jq -r --arg ws "$ws_full_real" \
    '.[] | select(.source_path==$ws) | .name' | head -1)
  if [[ -z "$real_cage_name" ]]; then
    echo "_spin_up_cage(${suffix}): could not resolve cage by source_path=${ws_full_real}; rc up output:" >&2
    cat "$up_log" >&2
    real_cage_name="$cage_name"  # fallback: makes the readiness-poll fail loudly below
  fi
  rm -f "$up_log"

  # NOTE: _track is NOT called here. Callers capture this function's stdout
  # via `$(...)` (e.g. `_re1_cage=$(_spin_up_cage ...)`), which forks a
  # subshell — a `_track` call in this scope would mutate a subshell-local
  # copy of CREATED_CAGES that vanishes when the subshell exits, silently
  # leaving the cleanup trap's array empty (a real leak: verified via `rc ls`
  # after a full green run while porting this test, rip-cage-neu7.12 — same
  # subshell trap existed in the pre-port docker `_CAGES_TO_CLEAN` array).
  # Callers MUST call `_track "$real_cage_name"` themselves, in the parent
  # shell, right after capturing this function's output.
  echo "$real_cage_name"
}

# ---------------------------------------------------------------------------
# RE1 — ro mount: agent write inside cage returns EACCES/EROFS
#
# An asset declared mode: ro is mounted read-only. A write attempt by the agent
# (non-root) user must fail with a permission error (EACCES or EROFS), NOT succeed.
# ---------------------------------------------------------------------------
echo "--- RE1: ro mount — write attempt by agent → EACCES/EROFS ---"

_re1_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-e2e-re1-XXXXXX")
_re1_ro_dir="${_re1_tmpdir}/ro-asset"
mkdir -p "$_re1_ro_dir"
echo "ro-sentinel" > "${_re1_ro_dir}/sentinel.txt"

_re1_manifest=$(cat <<YAML
version: 1
tools:
  - name: ro-guard
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${_re1_ro_dir}"
        dest: "/home/agent/ro-asset"
        mode: ro
        root_owned_required: false
YAML
)

_re1_cage=$(_spin_up_cage "re1" "$_re1_manifest" "$_re1_tmpdir")
_track "$_re1_cage"  # parent-shell tracking — see _spin_up_cage's subshell note above

# Wait briefly for the container to start
_re1_ready=0
for _i in 1 2 3 4 5; do
  _re1_state=$(msb inspect "$_re1_cage" --format json 2>/dev/null | jq -r '.status // empty')
  if [[ "$_re1_state" == "Running" ]]; then
    _re1_ready=1
    break
  fi
  sleep 2
done

if [[ "$_re1_ready" -eq 0 ]]; then
  fail "RE1 cage '${_re1_cage}' is not running — cannot probe ro write"
else
  # Probe: attempt to write a file to the ro-mounted path as the agent user.
  # The write must fail (non-zero exit from rc exec).
  _re1_write_rc=0
  _re1_write_out=$("${RC}" exec "$_re1_cage" -- \
    sh -c "echo hostile > /home/agent/ro-asset/hostile.txt 2>&1") || _re1_write_rc=$?

  if [[ "$_re1_write_rc" -ne 0 ]]; then
    pass "RE1 ro mount: write attempt by agent FAILS (exit=${_re1_write_rc}) — EACCES/EROFS enforced"
  else
    fail "RE1 ro mount: write attempt SUCCEEDED (exit=0) — ro mount did NOT enforce read-only. out='${_re1_write_out}'"
  fi

  # Verify the sentinel is still readable (positive: the mount is working, not just absent).
  _re1_read_rc=0
  _re1_read_out=$("${RC}" exec "$_re1_cage" -- \
    cat /home/agent/ro-asset/sentinel.txt 2>&1) || _re1_read_rc=$?
  if [[ "$_re1_read_rc" -eq 0 ]] && grep -q "ro-sentinel" <<<"$_re1_read_out"; then
    pass "RE1 ro mount: sentinel file readable inside cage (mount is active, not just absent)"
  else
    fail "RE1 ro mount: sentinel not readable — mount may not be applied (exit=${_re1_read_rc} out='${_re1_read_out}')"
  fi
fi
rm -rf "$_re1_tmpdir"

# ---------------------------------------------------------------------------
# RE2 — rw mount: agent write inside cage writes through to the host
#
# An asset declared mode: rw is mounted read-write. A file written inside the
# cage by the agent user must appear on the HOST filesystem.
# ---------------------------------------------------------------------------
echo ""
echo "--- RE2: rw mount — agent write propagates to host filesystem ---"

_re2_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-e2e-re2-XXXXXX")
_re2_rw_dir="${_re2_tmpdir}/rw-asset"
mkdir -p "$_re2_rw_dir"
# Make agent-writable (the host dir must be writable by the agent uid=1000)
chmod 777 "$_re2_rw_dir"

_re2_manifest=$(cat <<YAML
version: 1
tools:
  - name: rw-skill
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${_re2_rw_dir}"
        dest: "/home/agent/rw-asset"
        mode: rw
YAML
)

_re2_cage=$(_spin_up_cage "re2" "$_re2_manifest" "$_re2_tmpdir")
_track "$_re2_cage"  # parent-shell tracking — see _spin_up_cage's subshell note above

# Wait for container
_re2_ready=0
for _i in 1 2 3 4 5; do
  _re2_state=$(msb inspect "$_re2_cage" --format json 2>/dev/null | jq -r '.status // empty')
  if [[ "$_re2_state" == "Running" ]]; then
    _re2_ready=1
    break
  fi
  sleep 2
done

if [[ "$_re2_ready" -eq 0 ]]; then
  fail "RE2 cage '${_re2_cage}' is not running — cannot probe rw write-through"
else
  # Write a file inside the cage as the agent user.
  _re2_sentinel_content="rw-write-through-proof-$$"
  _re2_write_rc=0
  _re2_write_out=$("${RC}" exec "$_re2_cage" -- \
    sh -c "echo '${_re2_sentinel_content}' > /home/agent/rw-asset/written-by-agent.txt 2>&1") || _re2_write_rc=$?

  if [[ "$_re2_write_rc" -ne 0 ]]; then
    fail "RE2 rw mount: write inside cage FAILED (exit=${_re2_write_rc}) — rw mount not working. out='${_re2_write_out}'"
  else
    # EFFECT: verify the file now EXISTS on the HOST filesystem.
    _re2_host_file="${_re2_rw_dir}/written-by-agent.txt"
    if [[ -f "$_re2_host_file" ]] && grep -q "$_re2_sentinel_content" "$_re2_host_file"; then
      pass "RE2 rw mount: in-cage write PROPAGATED to host at '${_re2_host_file}' (write-through verified)"
    elif [[ -f "$_re2_host_file" ]]; then
      fail "RE2 rw mount: file exists on host but content unexpected: '$(cat "$_re2_host_file")'"
    else
      fail "RE2 rw mount: file '${_re2_host_file}' NOT on host after in-cage write — write-through failed"
    fi
  fi
fi
rm -rf "$_re2_tmpdir"

# ---------------------------------------------------------------------------
# RE3 — Mixed: ro guard + rw skill on SEPARATE load paths, both holding
#
# A single cage runs an ro guard mount (dest: /home/agent/ro-guard) and an rw
# skill mount (dest: /home/agent/rw-skill) on SEPARATE paths. Both behaviors
# hold simultaneously:
#   (a) ro guard: write → EACCES
#   (b) rw skill: write → writes through to host
# ---------------------------------------------------------------------------
echo ""
echo "--- RE3: mixed cage — ro guard and rw skill simultaneously on separate paths ---"

_re3_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-e2e-re3-XXXXXX")
_re3_ro_dir="${_re3_tmpdir}/guard-asset"
_re3_rw_dir="${_re3_tmpdir}/skill-asset"
mkdir -p "$_re3_ro_dir" "$_re3_rw_dir"
echo "guard-sentinel" > "${_re3_ro_dir}/guard.txt"
chmod 777 "$_re3_rw_dir"

_re3_manifest=$(cat <<YAML
version: 1
tools:
  - name: ro-guard-tool
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${_re3_ro_dir}"
        dest: "/home/agent/ro-guard"
        mode: ro
  - name: rw-skill-tool
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${_re3_rw_dir}"
        dest: "/home/agent/rw-skill"
        mode: rw
YAML
)

_re3_cage=$(_spin_up_cage "re3" "$_re3_manifest" "$_re3_tmpdir")
_track "$_re3_cage"  # parent-shell tracking — see _spin_up_cage's subshell note above

# Wait for container
_re3_ready=0
for _i in 1 2 3 4 5; do
  _re3_state=$(msb inspect "$_re3_cage" --format json 2>/dev/null | jq -r '.status // empty')
  if [[ "$_re3_state" == "Running" ]]; then
    _re3_ready=1
    break
  fi
  sleep 2
done

if [[ "$_re3_ready" -eq 0 ]]; then
  fail "RE3 cage '${_re3_cage}' is not running — cannot probe mixed mode"
else
  # (a) ro guard: write must FAIL
  _re3_guard_write_rc=0
  "${RC}" exec "$_re3_cage" -- \
    sh -c "echo hostile > /home/agent/ro-guard/hostile.txt 2>&1" || _re3_guard_write_rc=$?
  if [[ "$_re3_guard_write_rc" -ne 0 ]]; then
    pass "RE3(a) ro guard: write attempt FAILS (exit=${_re3_guard_write_rc}) — floor-lock holds"
  else
    fail "RE3(a) ro guard: write SUCCEEDED — ro mount did NOT enforce read-only on guard path"
  fi

  # (b) rw skill: write must SUCCEED and propagate to host
  _re3_sentinel="re3-rw-proof-$$"
  _re3_skill_write_rc=0
  "${RC}" exec "$_re3_cage" -- \
    sh -c "echo '${_re3_sentinel}' > /home/agent/rw-skill/agent-edit.txt 2>&1" || _re3_skill_write_rc=$?
  if [[ "$_re3_skill_write_rc" -ne 0 ]]; then
    fail "RE3(b) rw skill: write inside cage FAILED (exit=${_re3_skill_write_rc})"
  else
    _re3_host_file="${_re3_rw_dir}/agent-edit.txt"
    if [[ -f "$_re3_host_file" ]] && grep -q "$_re3_sentinel" "$_re3_host_file"; then
      pass "RE3(b) rw skill: in-cage write PROPAGATED to host — write-through holds"
    else
      fail "RE3(b) rw skill: file NOT on host after in-cage write — write-through failed"
    fi
  fi

  # Positive control: ro guard sentinel is still readable (mount is active)
  _re3_read_rc=0
  _re3_read_out=$("${RC}" exec "$_re3_cage" -- \
    cat /home/agent/ro-guard/guard.txt 2>&1) || _re3_read_rc=$?
  if [[ "$_re3_read_rc" -eq 0 ]] && grep -q "guard-sentinel" <<<"$_re3_read_out"; then
    pass "RE3(c) ro guard: sentinel readable inside cage (mount active, not just absent)"
  else
    fail "RE3(c) ro guard: sentinel not readable (exit=${_re3_read_rc} out='${_re3_read_out}')"
  fi
fi
rm -rf "$_re3_tmpdir"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All RC_E2E tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
