#!/usr/bin/env bash
# Host-side + e2e tests for manifest-declared egress + mounts meeting the welded
# floor (rip-cage-4c5.3).
#
# ADR-005 D3 (declarations meet floor; manifest never weakens it).
# ADR-012 D1 (IOC floor runtime backstop; build/up-time IOC check is NET-NEW here).
# ADR-023 D1/D6 (mount denylist, realpath-first fail-loud).
# ADR-024 D1 (declared+host-reviewed egress is the value-add).
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   PRIMARY (host-only, runs always):
#
#     E1  IOC-declaration build fails loud — a manifest egress: entry naming an
#         IOC-floor host makes rc build exit non-zero with an error that NAMES
#         the offending host.  This fires BEFORE any Docker call (pre-build gate).
#         The IOC check must name the specific host (guard against false attribution).
#
#     E2  IOC-declaration up fails loud — same fixture makes rc up exit non-zero
#         and name the host (no cage created/started). Fires pre-Docker.
#
#     E3  Denylisted manifest mount refused — a manifest mounts: entry targeting a
#         denylisted secret path is refused fail-loud (realpath-first) BEFORE any
#         docker call. The error names the path and the denylist pattern.
#
#   REGRESSION (RC_E2E=1 only — NEEDS_CONTAINER):
#
#     E4  Declared-host allow-probe — after rc up with a manifest declaring a host,
#         that host is reachable from inside the cage.
#
#     E5  Undeclared-host deny-probe — an undeclared host is blocked.
#
#     E6  IOC-host-still-blocked-at-proxy — even if the build/up check were
#         bypassed, egress to an IOC host is blocked at the runtime proxy.
#
# =============================================================================
# Positive-sentinel discipline (rip-cage-test-fail-prose-without-exit-silent-red):
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
#   * Absence assertions MUST be gated on a positive sentinel proving the source
#     is non-empty / live first.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Build a sandbox HOME for manifest tests.
setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-egress-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run rc build inside the sandbox, capturing both stdout and stderr.
run_rc_build() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    "${RC}" build 2>&1
}

# Run rc up inside the sandbox with a given workspace path and RC_ALLOWED_ROOTS.
run_rc_up() {
  local workspace="$1"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    RC_ALLOWED_ROOTS="$workspace" \
    "${RC}" up "$workspace" 2>&1
}

# ---------------------------------------------------------------------------
# E1 — IOC-declaration BUILD fails loud (host-only, no Docker needed)
#
# A manifest egress: entry naming an IOC-floor host must make rc build exit
# non-zero AND the error message must NAME the offending IOC host.
#
# Key discriminating condition: "NAMES the IOC host" guards against false
# attribution (a Docker build error must not count as a green here).
# The IOC check must fire BEFORE any docker call.
# ---------------------------------------------------------------------------
test_e1_ioc_build_fails_loud() {
  setup_manifest_sandbox "manifest-hostile-ioc-egress.yaml"
  local out exit_code
  exit_code=0
  out=$(run_rc_build) || exit_code=$?

  # Positive sentinel: error output must specifically reference the IOC host
  # in the context of an IOC/egress denylist refusal.
  # The IOC_HOST used in the fixture is "webhook.site" (egress-rules.yaml deny:true).
  # We look for the error message format produced by _manifest_check_ioc_egress.
  local ioc_named
  ioc_named=$(grep -E "IOC.*webhook\.site|webhook\.site.*IOC|manifest.*webhook\.site.*denylist|egress.*webhook\.site.*denied|denylist.*webhook\.site" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$ioc_named" ]]; then
    pass "E1 IOC build fails loud: exit=$exit_code, names IOC host 'webhook.site' in error"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "E1 IOC build did NOT fail (exit=0) — IOC check absent or not wired. output='${out:0:300}'"
  else
    fail "E1 IOC build exited non-zero (exit=$exit_code) but error does NOT name 'webhook.site' as IOC host. output='${out:0:500}'"
  fi
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# E1b — IOC check fires for SHELL-INTEGRATION archetype (Fix 2 / rip-cage-4c5.3)
#
# A SHELL-INTEGRATION entry with egress: webhook.site must also fail rc build
# loud naming the host. The IOC check must cover ALL archetypes with egress:
# fields, not just TOOL and IN-CAGE-DAEMON.
# ---------------------------------------------------------------------------
test_e1b_shell_integration_ioc_check() {
  setup_manifest_sandbox "manifest-hostile-ioc-egress-shell-integration.yaml"
  local out exit_code
  exit_code=0
  out=$(run_rc_build) || exit_code=$?

  local ioc_named
  ioc_named=$(grep -E "IOC.*webhook\.site|webhook\.site.*IOC|manifest.*webhook\.site.*denylist|egress.*webhook\.site.*denied|denylist.*webhook\.site" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$ioc_named" ]]; then
    pass "E1b SHELL-INTEGRATION IOC check fires: exit=$exit_code, names IOC host 'webhook.site'"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "E1b SHELL-INTEGRATION IOC check did NOT fire (exit=0) — archetype skip still active. output='${out:0:300}'"
  else
    fail "E1b exited non-zero (exit=$exit_code) but error does NOT name 'webhook.site' as IOC host. output='${out:0:500}'"
  fi
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# E2 — IOC-declaration UP fails loud (host-only, no Docker needed)
#
# Same fixture: rc up must refuse BEFORE creating any Docker container.
# The error must name the IOC host (same discriminating condition as E1).
# ---------------------------------------------------------------------------
test_e2_ioc_up_fails_loud() {
  setup_manifest_sandbox "manifest-hostile-ioc-egress.yaml"
  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-up-ioc-test-XXXXXX")
  local out exit_code
  exit_code=0
  out=$(run_rc_up "$tmpdir") || exit_code=$?

  local ioc_named
  ioc_named=$(grep -E "IOC.*webhook\.site|webhook\.site.*IOC|manifest.*webhook\.site.*denylist|egress.*webhook\.site.*denied|denylist.*webhook\.site" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$ioc_named" ]]; then
    pass "E2 IOC up fails loud: exit=$exit_code, names IOC host 'webhook.site' in error"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "E2 IOC up did NOT fail (exit=0) — IOC check absent or not wired. output='${out:0:300}'"
  else
    fail "E2 IOC up exited non-zero (exit=$exit_code) but error does NOT name 'webhook.site' as IOC host. Actual output (first 500 chars): '${out:0:500}'"
  fi
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# E3 — Denylisted manifest mount refused (host-only, no Docker needed)
#
# A manifest mounts: entry targeting a denylisted path fires fail-loud BEFORE
# any docker call.  The error message must name the manifest-declared path.
#
# Uses fixture manifest-hostile-denylisted-mount.yaml which declares
# mounts: [/home/user/.ssh] — ".ssh" is in the default denylist (ADR-023).
#
# The test relies on the specific error format produced by
# _manifest_check_mounts_denylist: "manifest-declared mount ... denylist ...".
# ---------------------------------------------------------------------------
test_e3_denylisted_mount_refused() {
  setup_manifest_sandbox "manifest-hostile-denylisted-mount.yaml"
  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-up-mount-test-XXXXXX")

  # Seed the global rc config (needed for denylist to be active).
  # _config_ensure_global_seeded will create it for us on first call.
  local out exit_code
  exit_code=0
  out=$(run_rc_up "$tmpdir") || exit_code=$?

  # Specific sentinel: error must mention the manifest-declared mount and
  # the denylist refusal in a way produced ONLY by _manifest_check_mounts_denylist.
  local denied_signal
  denied_signal=$(grep -iE "manifest.*(mount|declared).*(denylist|denied|refusing)|denylist.*(manifest|declared).*mount" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$denied_signal" ]]; then
    pass "E3 Denylisted manifest mount refused: exit=$exit_code"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "E3 Denylisted manifest mount NOT refused (exit=0) — denylist check absent. output='${out:0:300}'"
  else
    fail "E3 Exited non-zero (exit=$exit_code) but message did not indicate manifest mount denylist refusal. output='${out:0:500}'"
  fi
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# E4 — Declared egress host is reachable (NEEDS_CONTAINER, RC_E2E=1)
#
# After rc up with a manifest declaring example.org as an allowed egress host,
# a curl probe from inside the cage succeeds (HTTP 200 or similar).
# example.org is IANA-reserved (RFC 2606) — always reachable.
#
# Note: rip-cage-egress-e2e-probes-need-real-hosts: 000 != 403; real hosts only.
# ---------------------------------------------------------------------------
test_e4_declared_host_reachable() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER): E4 declared-host allow-probe — set RC_E2E=1 to run"
    return 0
  fi
  echo "SKIP (NOT YET IMPLEMENTED — owned by rip-cage-4c5.8): E4 declared-host allow-probe"
  FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------------------
# E5 — Undeclared egress host is blocked (NEEDS_CONTAINER, RC_E2E=1)
#
# An undeclared host (not in baseline or any tool egress:) is blocked at the
# proxy (403 response, not 000).
#
# rip-cage-egress-e2e-probes-need-real-hosts: use example.net (IANA-reserved).
# Gate: positive sentinel proves proxy is live (returns 403 for known blocked
# host) before asserting absence for undeclared host.
# ---------------------------------------------------------------------------
test_e5_undeclared_host_blocked() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER): E5 undeclared-host deny-probe — set RC_E2E=1 to run"
    return 0
  fi
  echo "SKIP (NOT YET IMPLEMENTED — owned by rip-cage-4c5.8): E5 undeclared-host deny-probe"
  FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------------------
# E6 — IOC host blocked at runtime proxy (NEEDS_CONTAINER, RC_E2E=1)
#
# Even if the build/up IOC check were bypassed, the runtime proxy still blocks
# IOC hosts. This is the ADR-012 D1 backstop.
# ---------------------------------------------------------------------------
test_e6_ioc_blocked_at_proxy() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER): E6 IOC-host-proxy backstop — set RC_E2E=1 to run"
    return 0
  fi
  echo "SKIP (NOT YET IMPLEMENTED — owned by rip-cage-4c5.8): E6 IOC-host-proxy backstop"
  FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------------------
# E7 — IOC check fires on rc reload (NEEDS_CONTAINER, RC_E2E=1)
#
# Fix 4 (rip-cage-4c5.3): a manifest edited between rc up and rc reload to add
# an IOC host must cause rc reload to exit non-zero naming the host.
#
# rc reload requires a running container (it calls `docker inspect` early), so
# this test is container-gated — cannot be exercised host-side without a live cage.
# The non-e2e path correctly reflects this constraint.
# ---------------------------------------------------------------------------
test_e7_reload_ioc_check() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER): E7 reload IOC check — rc reload requires a running cage; set RC_E2E=1 to run"
    return 0
  fi
  echo "SKIP (NOT YET IMPLEMENTED — owned by rip-cage-4c5.8): E7 reload IOC check (NEEDS_CONTAINER)"
  FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

echo "=== test-manifest-egress.sh — manifest egress+mounts floor (rip-cage-4c5.3) ==="
echo ""
echo "--- PRIMARY: Host-only IOC build/up fails-loud + mount denylist ---"
test_e1_ioc_build_fails_loud
test_e1b_shell_integration_ioc_check
test_e2_ioc_up_fails_loud
test_e3_denylisted_mount_refused

echo ""
echo "--- REGRESSION: E2E egress allow/deny/proxy probes (NEEDS_CONTAINER) ---"
test_e4_declared_host_reachable
test_e5_undeclared_host_blocked
test_e6_ioc_blocked_at_proxy
test_e7_reload_ioc_check

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
