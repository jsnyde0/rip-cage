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
#   REGRESSION E4-E7 (declared/undeclared-host live-proxy probes + IOC runtime
#   backstop + reload IOC check) retired: they asserted against the in-cage
#   egress router/proxy, deleted per ADR-029 D2 (engine-deletion sweep). The
#   engine-absence + msb selective-enforcement coverage those probes provided
#   is re-homed to tests/test-msb-flags-effect-probes-engine-deletion.sh
#   (rip-cage-3vj2, S4 of the msb migration epic). PRIMARY (E1/E1b/E2/E3) is
#   unaffected — the host-side IOC pre-flight gate (_manifest_check_ioc_egress)
#   and the mount denylist survive as declare-time, non-engine checks.
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
# Seeds both tools.yaml (manifest) and config.yaml (denylist) in the sandbox
# so tests are self-contained regardless of the driver's RC_CONFIG_GLOBAL.
setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-egress-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
  # Seed config.yaml with the DEFAULT denylist patterns so denylist checks
  # work correctly even when the driver exports RC_CONFIG_GLOBAL with an empty
  # denylist. This makes E3 self-contained (not dependent on the user's real config).
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist:
    - ".ssh"
    - ".gnupg"
    - ".aws"
    - ".gcloud"
    - "credentials"
    - ".netrc"
    - ".git-credentials"
    - "id_rsa"
    - "id_ed25519"
    - "id_ecdsa"
    - ".kube"
    - ".docker"
    - ".npmrc"
    - ".pypirc"
    - ".cargo/credentials"
    - ".m2/settings.xml"
  allow_risky: null
YAML
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run rc build inside the sandbox, capturing both stdout and stderr.
run_rc_build() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    "${RC}" build 2>&1
}

# Run rc up inside the sandbox with a given workspace path and RC_ALLOWED_ROOTS.
# Sets RC_CONFIG_GLOBAL to the sandbox config so denylist checks use the sandbox
# patterns rather than the driver-level empty denylist.
run_rc_up() {
  local workspace="$1"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
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
# mounts: [{host: /home/user/.ssh, dest: /home/agent/ssh-data}]
# — ".ssh" is in the default denylist (ADR-023).
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
# Run all tests
# ---------------------------------------------------------------------------

echo "=== test-manifest-egress.sh — manifest egress+mounts floor (rip-cage-4c5.3) ==="
echo ""
echo "--- PRIMARY: Host-only IOC build/up fails-loud + mount denylist ---"
test_e1_ioc_build_fails_loud
test_e1b_shell_integration_ioc_check
test_e2_ioc_up_fails_loud
test_e3_denylisted_mount_refused

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
