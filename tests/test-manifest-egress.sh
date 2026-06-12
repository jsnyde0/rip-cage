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

  # Use a fixture manifest that declares example.org as an allowed egress host.
  # The TOOL archetype requires an egress: field; we use a bundled TOOL with
  # egress: [example.org] to declare the host without needing a real install.
  local e4_manifest_home
  e4_manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-e4-home-XXXXXX")
  mkdir -p "${e4_manifest_home}/.config/rip-cage"
  cat > "${e4_manifest_home}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: beads
    archetype: TOOL
    version_pin: bundled
    egress:
      - example.org
    mounts: []
YAML

  local e4_ws_base e4_ws
  e4_ws_base=$(mktemp -d "${TMPDIR:-/tmp}/rc-e4-ws-XXXXXX")
  mkdir -p "${e4_ws_base}/rc"
  e4_ws="${e4_ws_base}/rc/manifest-e4"
  mkdir -p "$e4_ws"
  local e4_ws_resolved
  e4_ws_resolved=$(realpath "$e4_ws_base")

  # Cleanup
  # shellcheck disable=SC2329  # invoked indirectly via trap RETURN
  _e4_cleanup() {
    local _cname="rc-manifest-e4"
    docker stop "$_cname" 2>/dev/null || true
    docker rm "$_cname" 2>/dev/null || true
    docker volume rm "rc-state-${_cname}" 2>/dev/null || true
    rm -rf "$e4_manifest_home" "$e4_ws_base"
  }
  trap _e4_cleanup RETURN

  # Build with the manifest declaring example.org
  local build_out build_rc=0
  build_out=$(HOME="$e4_manifest_home" XDG_CONFIG_HOME="${e4_manifest_home}/.config" \
    RC_MANIFEST_GLOBAL="${e4_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" build 2>&1) || build_rc=$?
  if [[ "$build_rc" -ne 0 ]]; then
    fail "E4 Build failed (exit=${build_rc}): ${build_out:0:200}"
    return
  fi

  # Bring up the cage
  local up_out up_rc=0
  up_out=$(RC_ALLOWED_ROOTS="$e4_ws_resolved" \
    RC_MANIFEST_GLOBAL="${e4_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" up "$e4_ws" 2>&1) || up_rc=$?
  if [[ "$up_rc" -ne 0 ]]; then
    fail "E4 rc up failed (exit=${up_rc}): ${up_out:0:200}"
    return
  fi

  local e4_container="rc-manifest-e4"

  # POSITIVE SENTINEL: probe example.org from inside the cage.
  # rip-cage-egress-e2e-probes-need-real-hosts: HTTP 000 = never-reached-proxy.
  # A 200/301/302/400 means the proxy allowed the request (host is in allowlist).
  # A 403 means proxy blocked (host not in allowlist).
  local probe_code
  probe_code=$(docker exec "$e4_container" \
    timeout 15 curl -so /dev/null -w '%{http_code}' http://example.org 2>/dev/null) || true

  if [[ "$probe_code" == "000" ]]; then
    fail "E4 Declared-host probe: HTTP 000 — proxy never reached (plumbing error, not a block/allow result)"
  elif [[ "$probe_code" == "403" ]]; then
    fail "E4 Declared-host probe: HTTP 403 — example.org BLOCKED despite being declared in manifest egress"
  elif [[ -n "$probe_code" ]] && [[ "$probe_code" != "000" ]]; then
    pass "E4 Declared-host reachable: example.org responded HTTP ${probe_code} (declared in manifest egress, proxy allowed)"
  else
    fail "E4 Declared-host probe: no response code (curl failed or timed out)"
  fi
}

# ---------------------------------------------------------------------------
# E5 — Undeclared egress host is blocked (NEEDS_CONTAINER, RC_E2E=1)
#
# An undeclared host (not in baseline or any tool egress:) is blocked at the
# proxy (403 response, not 000).
#
# rip-cage-egress-e2e-probes-need-real-hosts: use example.net (IANA-reserved).
# Gate: positive sentinel proves proxy is live before asserting absence for
# undeclared host. The positive sentinel: the declared host (example.org) is
# reachable (same logic as E4) — if example.org passes, the proxy is live.
# ---------------------------------------------------------------------------
test_e5_undeclared_host_blocked() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER): E5 undeclared-host deny-probe — set RC_E2E=1 to run"
    return 0
  fi

  # Use the same fixture as E4 (declares example.org, NOT example.net).
  local e5_manifest_home
  e5_manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-e5-home-XXXXXX")
  mkdir -p "${e5_manifest_home}/.config/rip-cage"
  cat > "${e5_manifest_home}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: beads
    archetype: TOOL
    version_pin: bundled
    egress:
      - example.org
    mounts: []
YAML

  local e5_ws_base e5_ws
  e5_ws_base=$(mktemp -d "${TMPDIR:-/tmp}/rc-e5-ws-XXXXXX")
  mkdir -p "${e5_ws_base}/rc"
  e5_ws="${e5_ws_base}/rc/manifest-e5"
  mkdir -p "$e5_ws"
  local e5_ws_resolved
  e5_ws_resolved=$(realpath "$e5_ws_base")

  # shellcheck disable=SC2329  # invoked indirectly via trap RETURN
  _e5_cleanup() {
    local _cname="rc-manifest-e5"
    docker stop "$_cname" 2>/dev/null || true
    docker rm "$_cname" 2>/dev/null || true
    docker volume rm "rc-state-${_cname}" 2>/dev/null || true
    rm -rf "$e5_manifest_home" "$e5_ws_base"
  }
  trap _e5_cleanup RETURN

  local build_out build_rc=0
  build_out=$(HOME="$e5_manifest_home" XDG_CONFIG_HOME="${e5_manifest_home}/.config" \
    RC_MANIFEST_GLOBAL="${e5_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" build 2>&1) || build_rc=$?
  if [[ "$build_rc" -ne 0 ]]; then
    fail "E5 Build failed (exit=${build_rc}): ${build_out:0:200}"
    return
  fi

  local up_out up_rc=0
  up_out=$(RC_ALLOWED_ROOTS="$e5_ws_resolved" \
    RC_MANIFEST_GLOBAL="${e5_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" up "$e5_ws" 2>&1) || up_rc=$?
  if [[ "$up_rc" -ne 0 ]]; then
    fail "E5 rc up failed (exit=${up_rc}): ${up_out:0:200}"
    return
  fi

  local e5_container="rc-manifest-e5"

  # POSITIVE SENTINEL: declared host (example.org) must be reachable.
  # Without this, an absent/broken proxy would false-green the undeclared-block check.
  local sentinel_code
  sentinel_code=$(docker exec "$e5_container" \
    timeout 15 curl -so /dev/null -w '%{http_code}' http://example.org 2>/dev/null) || true

  if [[ "$sentinel_code" == "000" ]] || [[ "$sentinel_code" == "403" ]] || [[ -z "$sentinel_code" ]]; then
    fail "E5 SENTINEL FAILED: declared host example.org not reachable (code=${sentinel_code:-empty}) — cannot distinguish 'proxy blocking undeclared' from 'proxy not running'. Skip undeclared-host assertion."
    return
  fi
  pass "E5 SENTINEL: declared host example.org reachable (HTTP ${sentinel_code}) — proxy is live"

  # Now assert: undeclared host (example.net) is blocked by the proxy.
  # Expected: HTTP 403 (proxy denied) — NOT 000 (proxy not reached).
  local block_code
  block_code=$(docker exec "$e5_container" \
    timeout 15 curl -so /dev/null -w '%{http_code}' http://example.net 2>/dev/null) || true

  if [[ "$block_code" == "403" ]]; then
    pass "E5 Undeclared host blocked: example.net returned HTTP 403 (proxy blocked — not in manifest egress or baseline)"
  elif [[ "$block_code" == "000" ]]; then
    fail "E5 Undeclared host probe: HTTP 000 — proxy never reached (plumbing error, not a real block)"
  elif [[ -n "$block_code" ]]; then
    fail "E5 Undeclared host NOT blocked: example.net returned HTTP ${block_code} (expected 403 from proxy)"
  else
    fail "E5 Undeclared host probe: no response code (curl failed or timed out)"
  fi
}

# ---------------------------------------------------------------------------
# E6 — IOC host blocked at runtime proxy (NEEDS_CONTAINER, RC_E2E=1)
#
# Even if the build/up IOC check were bypassed, the runtime proxy still blocks
# IOC hosts. This is the ADR-012 D1 backstop.
#
# Strategy: bring up a standard cage (default manifest, no IOC declared) and
# probe an IOC host (webhook.site) directly at the proxy. The IOC block at
# proxy is unconditional — it is NOT manifest-derived (it's a denylist in
# the proxy's egress-rules.yaml config). Positive sentinel: proxy is live
# (a non-IOC declared host returns 403 rather than 000).
# ---------------------------------------------------------------------------
test_e6_ioc_blocked_at_proxy() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER): E6 IOC-host-proxy backstop — set RC_E2E=1 to run"
    return 0
  fi

  # Build + bring up a standard default cage (no manifest changes needed).
  local e6_manifest_home
  e6_manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-e6-home-XXXXXX")
  mkdir -p "${e6_manifest_home}/.config/rip-cage"
  # Empty manifest → default bundled stack, no custom egress declarations.

  local e6_ws_base e6_ws
  e6_ws_base=$(mktemp -d "${TMPDIR:-/tmp}/rc-e6-ws-XXXXXX")
  mkdir -p "${e6_ws_base}/rc"
  e6_ws="${e6_ws_base}/rc/manifest-e6"
  mkdir -p "$e6_ws"
  local e6_ws_resolved
  e6_ws_resolved=$(realpath "$e6_ws_base")

  # shellcheck disable=SC2329  # invoked indirectly via trap RETURN
  _e6_cleanup() {
    local _cname="rc-manifest-e6"
    docker stop "$_cname" 2>/dev/null || true
    docker rm "$_cname" 2>/dev/null || true
    docker volume rm "rc-state-${_cname}" 2>/dev/null || true
    rm -rf "$e6_manifest_home" "$e6_ws_base"
  }
  trap _e6_cleanup RETURN

  local build_out build_rc=0
  build_out=$(HOME="$e6_manifest_home" XDG_CONFIG_HOME="${e6_manifest_home}/.config" \
    "${RC}" build 2>&1) || build_rc=$?
  if [[ "$build_rc" -ne 0 ]]; then
    fail "E6 Build failed (exit=${build_rc}): ${build_out:0:200}"
    return
  fi

  local up_out up_rc=0
  up_out=$(RC_ALLOWED_ROOTS="$e6_ws_resolved" \
    RC_MANIFEST_GLOBAL="${e6_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" up "$e6_ws" 2>&1) || up_rc=$?
  if [[ "$up_rc" -ne 0 ]]; then
    fail "E6 rc up failed (exit=${up_rc}): ${up_out:0:200}"
    return
  fi

  local e6_container="rc-manifest-e6"

  # POSITIVE SENTINEL: proxy must be live.
  # Probe example.com (NOT in IOC denylist, not in egress baseline of a default cage).
  # A 403 means proxy is running and blocking correctly; anything other than 000 confirms proxy is live.
  local sentinel_code
  sentinel_code=$(docker exec "$e6_container" \
    timeout 15 curl -so /dev/null -w '%{http_code}' http://example.com 2>/dev/null) || true

  if [[ "$sentinel_code" == "000" ]] || [[ -z "$sentinel_code" ]]; then
    fail "E6 SENTINEL FAILED: proxy unreachable (example.com returned code=${sentinel_code:-empty}) — cannot assert IOC block"
    return
  fi
  pass "E6 SENTINEL: proxy live (example.com returned HTTP ${sentinel_code})"

  # ASSERT: IOC host (webhook.site) is blocked even in a default manifest cage.
  # webhook.site is in egress-rules.yaml deny:true (IOC denylist).
  # Expected: HTTP 403 from proxy (blocked at runtime, not at build/up time).
  local ioc_code
  ioc_code=$(docker exec "$e6_container" \
    timeout 15 curl -so /dev/null -w '%{http_code}' http://webhook.site 2>/dev/null) || true

  if [[ "$ioc_code" == "403" ]]; then
    pass "E6 IOC runtime backstop: webhook.site blocked at proxy (HTTP 403) even in default-manifest cage — ADR-012 D1 runtime backstop confirmed"
  elif [[ "$ioc_code" == "000" ]]; then
    fail "E6 IOC runtime backstop: webhook.site probe returned HTTP 000 (proxy not reached — plumbing error)"
  elif [[ -n "$ioc_code" ]]; then
    fail "E6 IOC runtime backstop: webhook.site returned HTTP ${ioc_code} — expected 403 from proxy (IOC denylist in egress-rules.yaml)"
  else
    fail "E6 IOC runtime backstop: no response from webhook.site probe (curl failed or timed out)"
  fi
}

# ---------------------------------------------------------------------------
# E7 — IOC check fires on rc reload (NEEDS_CONTAINER, RC_E2E=1)
#
# Fix 4 (rip-cage-4c5.3): a manifest edited between rc up and rc reload to add
# an IOC host must cause rc reload to exit non-zero naming the host.
#
# rc reload requires a running container (it calls `docker inspect` early), so
# this test is container-gated — cannot be exercised host-side without a live cage.
# ---------------------------------------------------------------------------
test_e7_reload_ioc_check() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER): E7 reload IOC check — rc reload requires a running cage; set RC_E2E=1 to run"
    return 0
  fi

  # Bring up a standard cage (clean manifest, no IOC host declared).
  local e7_manifest_home
  e7_manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-e7-home-XXXXXX")
  mkdir -p "${e7_manifest_home}/.config/rip-cage"
  # Start with a safe manifest (beads bundled, no egress)
  cat > "${e7_manifest_home}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: beads
    archetype: TOOL
    version_pin: bundled
    egress: []
    mounts: []
YAML

  local e7_ws_base e7_ws
  e7_ws_base=$(mktemp -d "${TMPDIR:-/tmp}/rc-e7-ws-XXXXXX")
  mkdir -p "${e7_ws_base}/rc"
  e7_ws="${e7_ws_base}/rc/manifest-e7"
  mkdir -p "$e7_ws"
  local e7_ws_resolved
  e7_ws_resolved=$(realpath "$e7_ws_base")

  # shellcheck disable=SC2329  # invoked indirectly via trap RETURN
  _e7_cleanup() {
    local _cname="rc-manifest-e7"
    docker stop "$_cname" 2>/dev/null || true
    docker rm "$_cname" 2>/dev/null || true
    docker volume rm "rc-state-${_cname}" 2>/dev/null || true
    rm -rf "$e7_manifest_home" "$e7_ws_base"
  }
  trap _e7_cleanup RETURN

  local build_out build_rc=0
  build_out=$(HOME="$e7_manifest_home" XDG_CONFIG_HOME="${e7_manifest_home}/.config" \
    RC_MANIFEST_GLOBAL="${e7_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" build 2>&1) || build_rc=$?
  if [[ "$build_rc" -ne 0 ]]; then
    fail "E7 Build failed (exit=${build_rc}): ${build_out:0:200}"
    return
  fi

  local up_out up_rc=0
  up_out=$(RC_ALLOWED_ROOTS="$e7_ws_resolved" \
    RC_MANIFEST_GLOBAL="${e7_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" up "$e7_ws" 2>&1) || up_rc=$?
  if [[ "$up_rc" -ne 0 ]]; then
    fail "E7 rc up failed (exit=${up_rc}): ${up_out:0:200}"
    return
  fi

  local e7_container="rc-manifest-e7"

  # Mutate the manifest to add an IOC host (webhook.site).
  cat > "${e7_manifest_home}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: beads
    archetype: TOOL
    version_pin: bundled
    egress:
      - webhook.site
    mounts: []
YAML

  # rc reload must detect the IOC host and exit non-zero, naming webhook.site.
  local reload_out reload_rc=0
  reload_out=$(RC_MANIFEST_GLOBAL="${e7_manifest_home}/.config/rip-cage/tools.yaml" \
    "${RC}" reload "$e7_container" 2>&1) || reload_rc=$?

  local ioc_named
  ioc_named=$(grep -E "IOC.*webhook\.site|webhook\.site.*IOC|manifest.*webhook\.site.*denylist|egress.*webhook\.site.*denied|denylist.*webhook\.site" <<<"$reload_out" | head -1)

  if [[ "$reload_rc" -ne 0 ]] && [[ -n "$ioc_named" ]]; then
    pass "E7 rc reload IOC check fires: exit=${reload_rc}, names IOC host 'webhook.site' in error — ADR-005 Fix 4 confirmed"
  elif [[ "$reload_rc" -eq 0 ]]; then
    fail "E7 rc reload did NOT fail (exit=0) — IOC check absent or not wired in reload path. output='${reload_out:0:300}'"
  else
    fail "E7 rc reload exited non-zero (exit=${reload_rc}) but did NOT name 'webhook.site' as IOC host in error. output='${reload_out:0:300}'"
  fi
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
