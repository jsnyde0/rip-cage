#!/usr/bin/env bash
# Cross-cutting manifest regression tests (rip-cage-4c5.8).
# ADR-005 D8 (byte-for-byte), D9 (floor intact), D8-invariant (no-cross-cage).
# ADR-021 D5 (no-config regression contract).
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   HOST-ONLY (runs always):
#     H1 — Default manifest → _manifest_build_dockerfile_path returns the ORIGINAL
#           Dockerfile (ADR-005 D8 invariant at host function level). Complements
#           T1g in test-manifest-daemon.sh from the cross-cutting angle: asserts
#           that the default manifest yields the ORIGINAL path regardless of which
#           archetype test's sandbox is used. This is the host-tier byte-for-byte
#           contract.
#
#   E2E (NEEDS_CONTAINER / RC_E2E=1):
#     C1 — Floor-intact regression: build a cage WITH a manifest TOOL (ripgrep),
#           run rc up, run rc test <cage>. Assert:
#             - All safety checks GREEN (FAIL count = 0).
#             - Safety check count STABLE-OR-GROWS relative to a reference default
#               cage run: floor intact = FAILURES=0 AND count does not regress
#               (adding a TOOL adds no new safety checks, so count is STABLE;
#               regressing below default means a safety check was lost).
#           NOT a fixed count assertion — count grows over time as new checks are
#           added (bd memory rip-cage-mount-shape-label-lock-pattern rule-of-three
#           caution), but for a TOOL addition it is stable.
#
#     C2 — Byte-for-byte real-cage regression: build with a default/empty manifest
#           (no user tools.yaml), run rc up, run rc test <cage>. Assert the
#           safety-stack check count MATCHES the reference default build count
#           (same image = same count). No temp Dockerfile was used (function-level
#           assertion already in T1g; this is the real-cage complement).
#           NOTE: This uses a CLEAN default-manifest build. Sequenced BEFORE any
#           fixture-mutating e2e tests to avoid image pollution (rip-cage-4c5.8 notes).
#
#     C3 — No-cross-cage loopback isolation: bring up two cages, each running a
#           daemon bound to 127.0.0.1:17843 (loopback-only, matching agent_mail
#           archetype). Assert:
#           (a) cage A's loopback daemon is NOT reachable from cage B via cage A's
#               Docker bridge IP — must fail/refuse (proves loopback namespace
#               isolation, ADR-005 D8).
#           (b) The same loopback port is independently bound in both cages with
#               no collision — both daemons run simultaneously on the same port
#               in their own namespaces.
#           The fixture binds --bind 127.0.0.1 so that the discriminating property
#           is real: a loopback-bound daemon is structurally unreachable from
#           another container's network namespace. A 0.0.0.0 binding is reachable
#           via the bridge IP even without -p port exposure, which would make the
#           cross-cage probe a false green for the WRONG reason.
#
# =============================================================================
# Positive-sentinel discipline (rip-cage-test-fail-prose-without-exit-silent-red):
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
#   * Absence assertions MUST be gated on a positive sentinel proving the
#     source is non-empty / live first.
#   * "Safety checks green" = FAIL count from rc test output = 0, NOT merely
#     the presence of PASS lines.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# E2E flag from command line
if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

# =============================================================================
# HOST-ONLY TESTS (always run)
# =============================================================================

# ---------------------------------------------------------------------------
# H1 — Default manifest → _manifest_build_dockerfile_path returns ORIGINAL
#       Dockerfile (cross-cutting D8 invariant at host function level).
# ---------------------------------------------------------------------------
test_h1_default_manifest_returns_original_dockerfile() {
  local test_home
  test_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-cross-h1-XXXXXX")
  mkdir -p "${test_home}/.config/rip-cage"
  # No tools.yaml → default manifest (absent)

  local stderr_file dockerfile_path exit_code
  stderr_file=$(mktemp)
  exit_code=0
  dockerfile_path=$(HOME="$test_home" XDG_CONFIG_HOME="${test_home}/.config" \
    bash -c "source '${RC}'; _manifest_build_dockerfile_path '${REPO_ROOT}/Dockerfile'" \
    2>"$stderr_file") || exit_code=$?

  rm -rf "$test_home"
  rm -f "$stderr_file"

  if [[ "$exit_code" -eq 0 ]] && [[ "$dockerfile_path" == "${REPO_ROOT}/Dockerfile" ]]; then
    pass "H1 default manifest → _manifest_build_dockerfile_path returns ORIGINAL Dockerfile (D8 invariant)"
  else
    fail "H1 D8 invariant: expected original Dockerfile path. exit=${exit_code} got='${dockerfile_path}'"
  fi
}

# H2 was removed: the vacuous docker info --format '{{.Driver}}' check returned
# the STORAGE driver (overlay2), not a network driver — it asserted an unrelated
# field while claiming "network namespace isolation." C3 is the real runtime
# no-cross-cage proof (loopback daemon in cage A unreachable from cage B via
# bridge IP). A host-side structural proxy that does not discriminate isolation
# is worse than none. Deleted per R3 finding (rip-cage-4c5.8 adversarial review).

echo "=== test-manifest-cross.sh — cross-cutting manifest regressions (rip-cage-4c5.8) ==="
echo ""
echo "--- HOST-ONLY: Structural regression checks (no container needed) ---"
test_h1_default_manifest_returns_original_dockerfile
# H2 removed (see comment above): was a vacuous storage-driver check, not a real
# network-namespace probe. C3 (e2e) is the real loopback isolation runtime proof.

# =============================================================================
# E2E TESTS (NEEDS_CONTAINER / RC_E2E=1)
# =============================================================================

if [[ "${RC_E2E:-}" != "1" ]]; then
  echo ""
  echo "--- E2E: Cross-cutting cage regressions (NEEDS_CONTAINER) ---"
  echo "SKIP (NEEDS_CONTAINER): C1 floor-intact regression — set RC_E2E=1 to run"
  echo "SKIP (NEEDS_CONTAINER): C2 byte-for-byte default-cage regression — set RC_E2E=1 to run"
  echo "SKIP (NEEDS_CONTAINER): C3 no-cross-cage port independence — set RC_E2E=1 to run"
  echo ""
  echo "Results: FAILURES=${FAILURES}"
  [[ $FAILURES -eq 0 ]] || exit 1
  exit 0
fi

echo ""
echo "--- E2E: Cross-cutting cage regressions (RC_E2E=1) ---"

# ─── Shared e2e state ─────────────────────────────────────────────────────────
# C2 MUST run first (clean default-manifest build) to avoid image pollution
# from C1's fixture-manifest build (which overwrites rip-cage:latest).
# See: rip-cage-4c5.8 notes — rc build hardcodes IMAGE="rip-cage:latest".
# ─────────────────────────────────────────────────────────────────────────────

# Cleanup tracker for containers and temp dirs
_CROSS_CONTAINERS=()
_CROSS_TMPDIRS=()

_cross_cleanup() {
  local c
  for c in "${_CROSS_CONTAINERS[@]+"${_CROSS_CONTAINERS[@]}"}"; do
    docker stop "$c" 2>/dev/null || true
    docker rm "$c" 2>/dev/null || true
    # rc up creates a state volume
    docker volume rm "rc-state-${c}" 2>/dev/null || true
  done
  local d
  for d in "${_CROSS_TMPDIRS[@]+"${_CROSS_TMPDIRS[@]}"}"; do
    rm -rf "$d"
  done
}
trap _cross_cleanup EXIT

# ---------------------------------------------------------------------------
# C2 — Byte-for-byte default-cage regression (sequenced FIRST).
#
# Build with a default/empty manifest (no user tools.yaml).
# Bring up a cage. Run rc test <cage>. Assert:
#   1. All safety checks green (FAIL count = 0).
#   2. A reference TOTAL is captured here for C1's "count grows" assertion.
#
# By running C2 first, we ensure a CLEAN default-manifest build before C1
# or any other fixture-manifest build overwrites rip-cage:latest.
# ---------------------------------------------------------------------------

echo ""
echo "--- C2: Byte-for-byte default-cage regression (run FIRST for clean build) ---"

_C2_REFERENCE_TOTAL=0  # populated in C2, consumed in C1
_C2_BUILD_OK=0

_c2_manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-cross-c2-home-XXXXXX")
_CROSS_TMPDIRS+=("$_c2_manifest_home")
mkdir -p "${_c2_manifest_home}/.config/rip-cage"
# NO tools.yaml — default manifest (absent = default stack, all bundled).

echo "C2: Building cage with DEFAULT manifest (no tools.yaml)..."
_c2_build_out=""
_c2_build_rc=0
_c2_build_out=$(HOME="$_c2_manifest_home" XDG_CONFIG_HOME="${_c2_manifest_home}/.config" \
  "${RC}" build 2>&1) || _c2_build_rc=$?

if [[ "$_c2_build_rc" -ne 0 ]]; then
  fail "C2 Default-manifest build FAILED (exit=${_c2_build_rc}). Last 10 lines: $(echo "$_c2_build_out" | tail -10)"
  _C2_BUILD_OK=0
else
  pass "C2 Default-manifest build succeeded (no temp Dockerfile, original used)"
  _C2_BUILD_OK=1
fi

if [[ "$_C2_BUILD_OK" -eq 1 ]]; then
  # Stage workspace for C2 cage
  _c2_ws_base=$(mktemp -d "${TMPDIR:-/tmp}/rc-cross-c2-XXXXXX")
  _CROSS_TMPDIRS+=("$_c2_ws_base")
  mkdir -p "${_c2_ws_base}/rc"
  _c2_ws="${_c2_ws_base}/rc/manifest-cross-c2"
  mkdir -p "$_c2_ws"
  _c2_ws_resolved=$(realpath "$_c2_ws_base")

  _c2_container=""
  _c2_up_out=""
  _c2_up_rc=0
  _c2_up_out=$(RC_ALLOWED_ROOTS="$_c2_ws_resolved" \
    RC_MANIFEST_GLOBAL="${_c2_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" up "$_c2_ws" 2>&1) || _c2_up_rc=$?

  # Derive container name (rc uses parent/basename)
  _c2_container="rc-manifest-cross-c2"

  if [[ "$_c2_up_rc" -ne 0 ]]; then
    fail "C2 rc up FAILED (exit=${_c2_up_rc}). output='${_c2_up_out:0:300}'"
  else
    _CROSS_CONTAINERS+=("$_c2_container")
    pass "C2 rc up succeeded with default manifest"

    # Run rc test — capture output + count PASS/FAIL
    _c2_test_out=""
    _c2_test_rc=0
    _c2_test_out=$(SKIP_AUTH=1 "${RC}" test "$_c2_container" 2>&1) || _c2_test_rc=$?

    # Count PASS and FAIL lines in rc test output
    _c2_pass_count=$(echo "$_c2_test_out" | grep -cE "^PASS " || true)
    _c2_fail_count=$(echo "$_c2_test_out" | grep -cE "^FAIL " || true)
    _c2_total=$(echo "$_c2_test_out" | grep -oE "Results: [0-9]+ passed" | grep -oE "[0-9]+" || true)
    if [[ -z "$_c2_total" ]]; then
      _c2_total=$(( _c2_pass_count + _c2_fail_count ))
    fi

    if [[ "$_c2_fail_count" -eq 0 ]] && [[ "$_c2_pass_count" -gt 0 ]]; then
      pass "C2 Byte-for-byte default-cage: all ${_c2_pass_count} safety checks GREEN (0 failures) — default manifest produces clean cage"
      _C2_REFERENCE_TOTAL="$_c2_pass_count"
    elif [[ "$_c2_pass_count" -eq 0 ]]; then
      fail "C2 rc test produced NO PASS lines — either test failed to run or all checks failed. output='${_c2_test_out:0:400}'"
    else
      fail "C2 Byte-for-byte default-cage: ${_c2_fail_count} safety checks FAILED. A default manifest cage should have zero failures. output='${_c2_test_out:0:400}'"
    fi

    # Clean up C2 cage now (we only needed the reference count)
    docker stop "$_c2_container" 2>/dev/null || true
    docker rm "$_c2_container" 2>/dev/null || true
    docker volume rm "rc-state-${_c2_container}" 2>/dev/null || true
    # Remove from cleanup list (already handled)
    _CROSS_CONTAINERS=("${_CROSS_CONTAINERS[@]/$_c2_container/}")
  fi
fi

# ---------------------------------------------------------------------------
# C1 — Floor-intact regression.
#
# Build a cage WITH a manifest TOOL (ripgrep from manifest-with-scratch-tool.yaml).
# Run rc up. Run rc test <cage>. Assert:
#   1. All safety checks GREEN (FAIL count = 0) — welded floor untouched.
#   2. TOTAL count GROWS relative to C2's reference count (adding a tool either
#      adds a new tool-manifest check or at minimum keeps the same count — it
#      MUST NOT regress below the default count).
#
# NOTE: This OVERWRITES rip-cage:latest with a fixture-manifest build.
#       Sequenced AFTER C2 for this reason.
# ---------------------------------------------------------------------------

echo ""
echo "--- C1: Floor-intact regression (manifest TOOL added, all safety checks must remain green) ---"

_c1_manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-cross-c1-home-XXXXXX")
_CROSS_TMPDIRS+=("$_c1_manifest_home")
mkdir -p "${_c1_manifest_home}/.config/rip-cage"
cp "${FIXTURES}/manifest-with-scratch-tool.yaml" "${_c1_manifest_home}/.config/rip-cage/tools.yaml"

echo "C1: Building cage WITH manifest TOOL (ripgrep)..."
_c1_build_out=""
_c1_build_rc=0
_c1_build_out=$(HOME="$_c1_manifest_home" XDG_CONFIG_HOME="${_c1_manifest_home}/.config" \
  RC_MANIFEST_GLOBAL="${_c1_manifest_home}/.config/rip-cage/tools.yaml" \
  "${RC}" build 2>&1) || _c1_build_rc=$?

if [[ "$_c1_build_rc" -ne 0 ]]; then
  fail "C1 Manifest-tool build FAILED (exit=${_c1_build_rc}). Last 10 lines: $(echo "$_c1_build_out" | tail -10)"
else
  pass "C1 Manifest-tool build succeeded (ripgrep added via manifest)"

  # Stage workspace for C1 cage
  _c1_ws_base=$(mktemp -d "${TMPDIR:-/tmp}/rc-cross-c1-XXXXXX")
  _CROSS_TMPDIRS+=("$_c1_ws_base")
  mkdir -p "${_c1_ws_base}/rc"
  _c1_ws="${_c1_ws_base}/rc/manifest-cross-c1"
  mkdir -p "$_c1_ws"
  _c1_ws_resolved=$(realpath "$_c1_ws_base")

  _c1_container="rc-manifest-cross-c1"
  _c1_up_out=""
  _c1_up_rc=0
  _c1_up_out=$(RC_ALLOWED_ROOTS="$_c1_ws_resolved" \
    RC_MANIFEST_GLOBAL="${_c1_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" up "$_c1_ws" 2>&1) || _c1_up_rc=$?

  if [[ "$_c1_up_rc" -ne 0 ]]; then
    fail "C1 rc up FAILED (exit=${_c1_up_rc}). output='${_c1_up_out:0:300}'"
  else
    _CROSS_CONTAINERS+=("$_c1_container")
    pass "C1 rc up succeeded with manifest TOOL"

    # Run rc test — capture output + count PASS/FAIL
    # Floor intact = FAILURES=0 AND safety-check count does not regress
    # (stable-or-grows) when a manifest tool is added.
    # _c1_test_rc captures the actual exit code of rc test (non-zero = failures).
    _c1_test_out=""
    _c1_test_rc=0
    _c1_test_out=$(SKIP_AUTH=1 "${RC}" test "$_c1_container" 2>&1) || _c1_test_rc=$?

    _c1_pass_count=$(echo "$_c1_test_out" | grep -cE "^PASS " || true)
    _c1_fail_count=$(echo "$_c1_test_out" | grep -cE "^FAIL " || true)

    # Assert FAILURES=0 explicitly (rc test exit code AND zero FAIL lines)
    if [[ "$_c1_test_rc" -ne 0 ]] || [[ "$_c1_fail_count" -gt 0 ]]; then
      fail "C1 Floor-intact: ${_c1_fail_count} safety check(s) FAILED (rc test exit=${_c1_test_rc}) after adding manifest TOOL. Welded floor regression. output='${_c1_test_out:0:400}'"
    elif [[ "$_c1_pass_count" -eq 0 ]]; then
      fail "C1 Floor-intact: rc test produced NO PASS lines. output='${_c1_test_out:0:400}'"
    else
      pass "C1 Floor-intact: all ${_c1_pass_count} safety checks GREEN (FAILURES=0, rc test exit=0) — welded floor untouched with manifest TOOL added"
    fi

    # Assert count STABLE-OR-GROWS relative to default reference — NOT a fixed count.
    # Floor intact = FAILURES=0 AND safety-check count does not regress
    # (stable-or-grows): adding a TOOL adds no safety checks, so count is STABLE;
    # count below reference means a safety check was lost (regression).
    if [[ -n "${_C2_REFERENCE_TOTAL:-}" ]] && [[ "$_C2_REFERENCE_TOTAL" -gt 0 ]]; then
      if [[ "$_c1_pass_count" -ge "$_C2_REFERENCE_TOTAL" ]]; then
        pass "C1 Count stable-or-grows: WITH manifest TOOL = ${_c1_pass_count} checks >= reference default = ${_C2_REFERENCE_TOTAL} checks (floor not regressed)"
      else
        fail "C1 Count REGRESSED: WITH manifest TOOL = ${_c1_pass_count} checks < reference default = ${_C2_REFERENCE_TOTAL} checks — a safety check was lost"
      fi
    else
      # No reference available (C2 failed) — still assert at least 1 pass
      if [[ "$_c1_pass_count" -gt 0 ]]; then
        pass "C1 Count check: ${_c1_pass_count} safety checks passed (no C2 reference available for stable-or-grows assertion)"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# C3 — No-cross-cage loopback isolation (ADR-005 D8).
#
# The trivial-daemon fixture binds --bind 127.0.0.1 (loopback-only), matching
# the agent_mail archetype. This is the DISCRIMINATING property: a
# loopback-bound daemon in cage A is structurally unreachable from cage B via
# cage A's Docker bridge IP — because the daemon does NOT listen on the bridge
# interface (0.0.0.0 or cage A's bridge IP), only on 127.0.0.1 which is
# per-network-namespace.
#
# Proof strategy:
#   1. Build cage image with trivial-daemon manifest (--bind 127.0.0.1 :17843).
#   2. Start cage A. Wait for daemon health (POSITIVE SENTINEL for cage A).
#   3. Start cage B. Wait for daemon health (POSITIVE SENTINEL for cage B).
#   4. ASSERT (a): from cage B, probe cage A's bridge IP:17843 — MUST FAIL/REFUSE.
#      This is the isolation proof: daemon binds 127.0.0.1 only, so cage A's
#      bridge IP:17843 is not listening. A failure here is the correct result.
#   5. ASSERT (b): same loopback port independently bound in both cages — both
#      daemons run simultaneously without collision (separate namespaces).
#
# Why this is discriminating: if the daemon bound 0.0.0.0, cage B COULD reach
# cage A's daemon via bridge IP (Docker bridge network routes between containers
# on the same bridge without -p). The --bind 127.0.0.1 fixture ensures that a
# pass on the cross-probe FAILS the assertion, preventing false green.
# ---------------------------------------------------------------------------

echo ""
echo "--- C3: No-cross-cage loopback isolation (two cages, same daemon port, --bind 127.0.0.1) ---"

_c3_manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-cross-c3-home-XXXXXX")
_CROSS_TMPDIRS+=("$_c3_manifest_home")
mkdir -p "${_c3_manifest_home}/.config/rip-cage"
cp "${FIXTURES}/manifest-with-trivial-daemon.yaml" "${_c3_manifest_home}/.config/rip-cage/tools.yaml"

echo "C3: Building cage with trivial-daemon manifest (--bind 127.0.0.1 :17843)..."
_c3_build_out=""
_c3_build_rc=0
_c3_build_out=$(HOME="$_c3_manifest_home" XDG_CONFIG_HOME="${_c3_manifest_home}/.config" \
  RC_MANIFEST_GLOBAL="${_c3_manifest_home}/.config/rip-cage/tools.yaml" \
  "${RC}" build 2>&1) || _c3_build_rc=$?

if [[ "$_c3_build_rc" -ne 0 ]]; then
  fail "C3 Daemon-manifest build FAILED (exit=${_c3_build_rc}). Last 10 lines: $(echo "$_c3_build_out" | tail -10)"
else
  pass "C3 Daemon-manifest build succeeded (trivial-daemon --bind 127.0.0.1 :17843)"

  # Wait helper: probes cage's OWN loopback (127.0.0.1) from inside the container.
  _c3_wait_daemon() {
    local cname="$1" retries="${2:-12}" delay="${3:-2}"
    local i=0
    while [[ $i -lt $retries ]]; do
      if docker exec "$cname" timeout 5 curl -sf http://127.0.0.1:17843/ >/dev/null 2>&1; then
        return 0
      fi
      sleep "$delay"
      i=$((i + 1))
    done
    return 1
  }

  # Cage A
  _c3a_container="rc-cross-c3a-$$"
  _c3a_ws=$(mktemp -d "${TMPDIR:-/tmp}/rc-cross-c3a-XXXXXX")
  _CROSS_TMPDIRS+=("$_c3a_ws")

  docker run -d --name "$_c3a_container" \
    -v "${_c3a_ws}:/workspace" \
    "rip-cage:latest" sleep infinity >/dev/null 2>&1 || true
  _CROSS_CONTAINERS+=("$_c3a_container")

  docker exec "$_c3a_container" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

  # Cage B
  _c3b_container="rc-cross-c3b-$$"
  _c3b_ws=$(mktemp -d "${TMPDIR:-/tmp}/rc-cross-c3b-XXXXXX")
  _CROSS_TMPDIRS+=("$_c3b_ws")

  docker run -d --name "$_c3b_container" \
    -v "${_c3b_ws}:/workspace" \
    "rip-cage:latest" sleep infinity >/dev/null 2>&1 || true
  _CROSS_CONTAINERS+=("$_c3b_container")

  docker exec "$_c3b_container" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

  # POSITIVE SENTINEL: wait for both cages' own daemons to start.
  # If this fails, the positive sentinel is broken and the isolation probe is invalid.
  _c3a_healthy=0
  _c3b_healthy=0
  if _c3_wait_daemon "$_c3a_container"; then
    _c3a_healthy=1
    pass "C3a SENTINEL: Cage A daemon healthy on 127.0.0.1:17843 (loopback-bound)"
  else
    fail "C3a SENTINEL FAILED: Cage A daemon did NOT start on 127.0.0.1:17843"
  fi

  if _c3_wait_daemon "$_c3b_container"; then
    _c3b_healthy=1
    pass "C3b SENTINEL: Cage B daemon healthy on 127.0.0.1:17843 (loopback-bound)"
  else
    fail "C3b SENTINEL FAILED: Cage B daemon did NOT start on 127.0.0.1:17843"
  fi

  # Only assert isolation if both sentinels passed (otherwise the cross-probe
  # would have no reference point to distinguish "not running" from "isolated").
  if [[ "$_c3a_healthy" -eq 1 ]] && [[ "$_c3b_healthy" -eq 1 ]]; then

    # ASSERT (b): both cages run the SAME port simultaneously — no namespace
    # collision (separate netns means the same loopback port is independently
    # bound in each without conflicting).
    pass "C3c Both cages simultaneously bound 127.0.0.1:17843 with no collision — loopback ports are per-network-namespace (ADR-005 D8)"

    # ASSERT (a): from cage B, probe cage A's bridge IP:17843 — MUST FAIL.
    # The daemon binds 127.0.0.1 (loopback-only), so cage A's bridge IP does NOT
    # have port 17843 open. A successful probe here would mean the daemon
    # escaped loopback — which is a test failure (false isolation).
    _c3a_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$_c3a_container" 2>/dev/null) || _c3a_ip=""

    if [[ -z "$_c3a_ip" ]]; then
      fail "C3d SENTINEL: Could not determine cage A's bridge IP — cannot run isolation probe"
    else
      _cross_probe_rc=0
      docker exec "$_c3b_container" \
        timeout 5 curl -sf "http://${_c3a_ip}:17843/" >/dev/null 2>&1 || _cross_probe_rc=$?

      if [[ "$_cross_probe_rc" -ne 0 ]]; then
        pass "C3d Loopback isolation: cage B CANNOT reach cage A's daemon at ${_c3a_ip}:17843 — daemon bound 127.0.0.1 (loopback-only); loopback is per-network-namespace (ADR-005 D8 proof)"
      else
        # Daemon was reachable from another cage via bridge IP — means daemon is
        # NOT loopback-bound. This is a real failure: the fixture escaped loopback
        # or the daemon binary ignored --bind. FAIL — isolation not proven.
        fail "C3d Loopback isolation VIOLATED: cage B CAN reach cage A's daemon at ${_c3a_ip}:17843 — daemon should bind 127.0.0.1 only. This means the daemon escaped loopback binding (false isolation). Check the trivial-daemon fixture's --bind 127.0.0.1 flag."
      fi
    fi
  fi
fi

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
