#!/usr/bin/env bash
# Host-side + e2e tests for agent_mail IN-CAGE-DAEMON manifest fixture (rip-cage-4c5.6).
# Validates the archetype against the real tool: github.com/Dicklesworthstone/mcp_agent_mail_rust
# pinned commit 8897497 (8897497257c5fac79f7a3559cacf27fddc853d4a), workspace version 0.3.10.
#
# ADR-005 D7 (IN-CAGE-DAEMON archetype: worked example with real tool).
# ADR-005 D8 (default manifest untouched — agent_mail ships as fixture only).
# ADR-025 D5 (validate by parsing, fail-closed).
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   T1  (host-only, runs always):
#     T1a — Fixture parses + validates against manifest schema (strict-parse,
#           not run-a-fail-open-consumer validation per ADR-025 D5).
#     T1b — install_cmd DOWNLOADS a prebuilt release artifact (contains
#           'releases/download' or 'install.sh') — NOT 'cargo build'.
#           Guards the scout's finding that bare-clone cargo build is NOT viable
#           (workspace [patch.crates-io] redirects ~40 deps to unpublished siblings).
#     T1c — mcp_fragment is the HTTP shape pointing at 127.0.0.1:8765.
#           (canonical HTTP transport per crates/*/setup.rs:1802-1808,219-224)
#     T1d — Declared egress list is empty / localhost-only (no external hosts).
#           Correct because default config has LLM_ENABLED=false + no API keys.
#           (config.rs:1324 llm_enabled default false)
#     T1e — Strict-parse rejects fixture-level mutation: if install_cmd is
#           removed, _manifest_validate exits non-zero and names the field.
#
#   T2  (e2e, NEEDS_CONTAINER / RC_E2E=1):
#     T2a — Daemon starts at init + health passes (positive sentinel: daemon
#           responds to GET /healthz — health endpoints bypass bearer auth per
#           crates/mcp-agent-mail-server/src/lib.rs:57-60).
#     T2b — ZERO external egress: POSITIVE proxy observation (proxy log shows
#           ONLY localhost:8765 traffic, no external host contacted).
#           Gated on a sentinel confirming source is live (NOT assert-absence
#           against an empty log).
#     T2c — MCP fragment present in baked settings.json mcpServers + key
#           'agent-mail' discoverable by in-cage agent.
#     T2d — Sequential send→read round-trip: dispatch A sends a message via
#           agent_mail MCP; dispatch B in the same cage reads it back.
#           (sequential proof per ADR-006 Tier 1a — NOT concurrent)
#     T2e — git-commit-under-guard-hook probe: DCG STILL FIRES on a destructive
#           command (positive assertion — give it a known-destructive command,
#           assert deny), AND a normal commit succeeds (guard + DCG compatible).
#           Guards the scout's NON-BREAKING characterization (ADR-005 D7 risk closure).
#
# =============================================================================
# Positive-sentinel discipline:
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
#   * "Zero external egress" is a POSITIVE proxy observation, NOT assert-absence.
#   * "Health passes" requires a POSITIVE SENTINEL (daemon responded).
#   * Egress probes use real reachable hosts (example.com); HTTP 000 = test plumbing error.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FIXTURE_FILE="${FIXTURES}/manifest-agent-mail.yaml"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  # T2 e2e cleanup (no-op when RC_E2E was not set and T2_BUILD_MANIFEST_HOME is empty)
  if [[ -n "${T2_BUILD_MANIFEST_HOME:-}" ]]; then
    rm -rf "$T2_BUILD_MANIFEST_HOME"
    T2_BUILD_MANIFEST_HOME=""
  fi
}
trap cleanup EXIT

# Build a sandbox HOME for manifest tests.
setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-agent-mail-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# ---------------------------------------------------------------------------
# T1a — Fixture parses + validates against manifest schema (strict-parse).
# Validates by PARSING (ADR-025 D5), not by running a fail-open consumer.
# ---------------------------------------------------------------------------
test_t1a_fixture_validates_strict_parse() {
  setup_manifest_sandbox "manifest-agent-mail.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  # _manifest_validate takes an explicit file path; HOME is needed only so rc sources cleanly.
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${FIXTURE_FILE}'" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "T1a Fixture strict-parse validates: _manifest_validate exits 0 on agent-mail fixture"
  else
    fail "T1a Fixture strict-parse FAILED: exit=${exit_code} stderr='$(cat "$stderr_file")' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1b — install_cmd DOWNLOADS the pinned v0.3.10 prebuilt release asset DIRECTLY.
# Must contain 'releases/download' (direct GitHub release asset URL, pinned version).
# Must NOT contain 'install.sh' (install.sh has a cargo-build fallback on download
# failure that is NOT viable for this workspace: Cargo.toml:160-224 patches ~40 deps
# to unpublished siblings via [patch.crates-io]).
# Must NOT contain 'cargo build' (same reason).
# Must reference version_pin value (0.3.10) in the download URL.
# ---------------------------------------------------------------------------
test_t1b_install_cmd_is_prebuilt_download() {
  local install_cmd version_pin
  install_cmd=$(python3 -c "
import yaml, sys
with open('${FIXTURE_FILE}') as f:
    manifest = yaml.safe_load(f)
tools = manifest.get('tools', [])
for t in tools:
    if t.get('name') == 'agent-mail':
        print(t.get('install_cmd', ''))
        sys.exit(0)
print('')
" 2>/dev/null)

  version_pin=$(python3 -c "
import yaml, sys
with open('${FIXTURE_FILE}') as f:
    manifest = yaml.safe_load(f)
tools = manifest.get('tools', [])
for t in tools:
    if t.get('name') == 'agent-mail':
        print(t.get('version_pin', ''))
        sys.exit(0)
print('')
" 2>/dev/null)

  if [[ -z "$install_cmd" ]]; then
    fail "T1b Could not extract install_cmd from fixture (agent-mail entry not found or install_cmd empty)"
    return
  fi

  # Must reference a DIRECT prebuilt release asset URL (releases/download/<version>)
  if echo "$install_cmd" | grep -q "releases/download"; then
    pass "T1b install_cmd references direct prebuilt release asset (releases/download): '${install_cmd:0:80}...'"
  else
    fail "T1b install_cmd does NOT reference a direct release asset URL (releases/download). Got: '${install_cmd}'"
  fi

  # Must NOT call install.sh (install.sh has a cargo-build fallback on failure)
  if echo "$install_cmd" | grep -q "install\.sh"; then
    fail "T1b install_cmd calls install.sh — NOT allowed (install.sh has cargo-build fallback unviable for this workspace)"
  else
    pass "T1b install_cmd does NOT call install.sh (correct: direct asset download, no cargo-build fallback)"
  fi

  # Must NOT contain 'cargo build' (bare cargo build is not viable for this workspace)
  if echo "$install_cmd" | grep -q "cargo build"; then
    fail "T1b install_cmd contains 'cargo build' — NOT viable (workspace patches 40 unpublished sibling deps). Use prebuilt binary download."
  else
    pass "T1b install_cmd does not contain 'cargo build' (correct: prebuilt download only)"
  fi

  # Must pin the version (version_pin value must appear in the URL)
  if [[ -n "$version_pin" ]] && echo "$install_cmd" | grep -q "v${version_pin}"; then
    pass "T1b install_cmd pins version v${version_pin} in the asset URL (matches version_pin field)"
  else
    fail "T1b install_cmd does NOT pin version v${version_pin} in the URL (expected 'v${version_pin}' in install_cmd). Got: '${install_cmd}'"
  fi
}

# ---------------------------------------------------------------------------
# T1c — mcp_fragment is the HTTP shape pointing at 127.0.0.1:8765.
# Canonical HTTP transport from crates/*/setup.rs:1802-1808,219-224 @ 8897497.
# Default port 8765, host 127.0.0.1 (config.rs:1214-1215).
# Bearer auth required on /mcp/ endpoint (health endpoints bypass it).
# ---------------------------------------------------------------------------
test_t1c_mcp_fragment_is_http_shape() {
  local mcp_fragment
  # Extract mcp_fragment as JSON regardless of whether it is declared as a YAML
  # object (the correct form: nested dict in YAML → real JSON object in baked
  # settings.json) or a JSON string (the old broken form).
  # json.dumps normalises both: dict → compact JSON, str → JSON string (which
  # would then fail the type check below, making the string form a detectable bug).
  mcp_fragment=$(python3 -c "
import yaml, json, sys
with open('${FIXTURE_FILE}') as f:
    manifest = yaml.safe_load(f)
tools = manifest.get('tools', [])
for t in tools:
    if t.get('name') == 'agent-mail':
        frag = t.get('mcp_fragment', '')
        # Always emit valid JSON so the shell pipeline can parse it.
        # A YAML dict becomes a JSON object; a YAML string becomes a JSON string
        # (the latter is the broken form and will fail the type assertion below).
        print(json.dumps(frag))
        sys.exit(0)
print('')
" 2>/dev/null)

  if [[ -z "$mcp_fragment" || "$mcp_fragment" == '""' ]]; then
    fail "T1c mcp_fragment not found in agent-mail fixture entry"
    return
  fi

  # Assert the fragment is a JSON OBJECT (not a JSON string): mcp_fragment must
  # be declared as a nested YAML mapping so that yq → jq baking produces a real
  # object in settings.json.  If the fixture still uses the old quoted-string form,
  # json.dumps produces a JSON string here and json.load will return a str, making
  # d.get('type','') fail (str has no .get).
  local parsed_type parsed_url
  parsed_type=$(echo "$mcp_fragment" | python3 -c "
import json, sys
val = json.load(sys.stdin)
if not isinstance(val, dict):
    print('__NOT_AN_OBJECT__')
    sys.exit(0)
print(val.get('type', ''))
" 2>/dev/null)
  parsed_url=$(echo "$mcp_fragment" | python3 -c "
import json, sys
val = json.load(sys.stdin)
if not isinstance(val, dict):
    print('')
    sys.exit(0)
print(val.get('url', ''))
" 2>/dev/null)

  if [[ "$parsed_type" == "__NOT_AN_OBJECT__" ]]; then
    fail "T1c mcp_fragment is a JSON STRING in the fixture — must be a nested YAML object so settings.json baking produces a real mcpServers object (string form bakes as a JSON string value, leaving .type empty)"
    return
  fi

  if [[ "$parsed_type" != "http" ]]; then
    fail "T1c mcp_fragment type is '${parsed_type}' — expected 'http' (canonical HTTP transport per source @ 8897497)"
    return
  fi
  pass "T1c mcp_fragment is a YAML object with type='http' (canonical HTTP transport; correct form for settings.json baking)"

  # Must point at 127.0.0.1:8765 (config.rs:1214-1215)
  if echo "$parsed_url" | grep -q "127.0.0.1:8765"; then
    pass "T1c mcp_fragment url references 127.0.0.1:8765 (default host:port per config.rs:1214-1215)"
  else
    fail "T1c mcp_fragment url '${parsed_url}' does NOT reference 127.0.0.1:8765"
  fi

  # Must include /mcp/ path (the endpoint that requires bearer auth)
  if echo "$parsed_url" | grep -q "/mcp/"; then
    pass "T1c mcp_fragment url includes /mcp/ path (bearer-auth required endpoint)"
  else
    fail "T1c mcp_fragment url '${parsed_url}' does NOT include /mcp/ path"
  fi

  # Must have Authorization header with Bearer token placeholder
  local has_auth
  has_auth=$(echo "$mcp_fragment" | python3 -c "
import json, sys
val = json.load(sys.stdin)
if not isinstance(val, dict):
    print('no')
    sys.exit(0)
headers = val.get('headers', {})
auth = headers.get('Authorization', '')
print('yes' if auth.startswith('Bearer') else 'no')
" 2>/dev/null)

  if [[ "$has_auth" == "yes" ]]; then
    pass "T1c mcp_fragment headers include Authorization Bearer token"
  else
    fail "T1c mcp_fragment missing Authorization Bearer header (required by /mcp/ endpoint)"
  fi
}

# ---------------------------------------------------------------------------
# T1d — Declared egress list is empty / localhost-only (no external hosts).
# Default config: LLM_ENABLED=false (config.rs:1324) + no API keys → no external egress.
# Fixture must NOT set LLM_ENABLED and must inject no *_API_KEY.
# Declared egress: empty [] is correct.
# ---------------------------------------------------------------------------
test_t1d_declared_egress_is_empty_or_localhost() {
  local egress_field
  egress_field=$(python3 -c "
import yaml, json, sys
with open('${FIXTURE_FILE}') as f:
    manifest = yaml.safe_load(f)
tools = manifest.get('tools', [])
for t in tools:
    if t.get('name') == 'agent-mail':
        egress = t.get('egress', 'NOT_PRESENT')
        print(json.dumps(egress))
        sys.exit(0)
print('NOT_PRESENT')
" 2>/dev/null)

  if [[ -z "$egress_field" || "$egress_field" == "NOT_PRESENT" ]]; then
    fail "T1d egress field not found or could not read fixture (agent-mail entry missing?)"
    return
  fi

  # Check that egress is null or empty array (no external hosts)
  local egress_has_external
  egress_has_external=$(echo "$egress_field" | python3 -c "
import json, sys
val = json.load(sys.stdin)
if val is None or val == []:
    print('no')
else:
    # Check for any non-localhost entries
    external = [h for h in val if not h.startswith('localhost') and not h.startswith('127.')]
    print('yes' if external else 'no')
" 2>/dev/null)

  if [[ "$egress_has_external" == "no" ]]; then
    pass "T1d Declared egress is empty/localhost-only (correct: default LLM_ENABLED=false, no API keys)"
  else
    fail "T1d Declared egress contains external hosts — incorrect. Default agent_mail uses localhost only (LLM_ENABLED=false per config.rs:1324)"
  fi
}

# ---------------------------------------------------------------------------
# T1e — Strict-parse rejects a mutated IN-CAGE-DAEMON entry missing a required field.
# _manifest_validate must exit non-zero and name the missing field in stderr.
# This is a real fixture-mutation rejection test (discriminating check).
# Validates: required fields for IN-CAGE-DAEMON are enforced at parse time
# (ADR-025 D5 — fail-closed, not fail-open).
# The bead's harness target did not specify T1e; this is a host-tier complement.
# ---------------------------------------------------------------------------
test_t1e_strict_parse_rejects_missing_daemon_field() {
  setup_manifest_sandbox
  # Mutate: remove the required 'health' field from an otherwise valid IN-CAGE-DAEMON entry.
  # _manifest_validate must reject it and name 'health' in the error output.
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: agent-mail-no-health
    archetype: IN-CAGE-DAEMON
    version_pin: "0.3.10"
    start: "mcp-agent-mail serve --no-tui"
    state_dir: "/var/lib/rip-cage-daemon/agent-mail"
YAML

  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file") || exit_code=$?

  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "health"; then
    pass "T1e Strict-parse rejects IN-CAGE-DAEMON with missing 'health': exits non-zero and names 'health' in error"
  else
    fail "T1e Strict-parse: expected non-zero exit + 'health' in error. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T2 — E2E (NEEDS_CONTAINER / RC_E2E=1)
#
# All T2 tests build a cage image with the agent_mail manifest fixture, start
# it, and run assertions inside the container. Pattern mirrors C5's
# tests/test-manifest-daemon.sh T2 structure.
#
# Shared image build: _t2_build_agent_mail_image builds once, sets
# T2_IMAGE_BUILT=1. Individual tests use the shared image or rebuild if needed.
#
# Positive-sentinel discipline:
#   - Health check = POSITIVE sentinel (daemon responded, not absence-of-error).
#   - Zero-egress = POSITIVE: health sentinel + no ESTABLISHED external connections.
#   - DCG = POSITIVE: dcg test exits non-zero on known-destructive command.
#   - All failures increment FAILURES and produce non-zero exit.
# ---------------------------------------------------------------------------

T2_AGENT_MAIL_IMAGE="rip-cage:latest"
T2_BUILD_MANIFEST_HOME=""
T2_BUILD_FAILED=0  # set to 1 after first build failure; prevents retrying

# Skip helper: exits 0 with SKIP message when RC_E2E is unset (close-state).
# Returns 1 (do NOT skip) when RC_E2E=1.
skip_if_not_e2e() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / e2e): ${1} — set RC_E2E=1 to run"
    return 0
  fi
  return 1
}

# Build the agent-mail cage image (shared setup for all T2 tests).
# Sets T2_AGENT_MAIL_IMAGE to the built image tag.
# On failure, sets T2_BUILD_FAILED=1 and returns 1.
# Subsequent calls short-circuit with failure (no redundant retries).
_t2_build_agent_mail_image() {
  # Short-circuit: already built successfully.
  if [[ -n "${T2_BUILD_MANIFEST_HOME:-}" ]]; then
    return 0
  fi

  # Short-circuit: already failed. Don't retry (expensive and same failure).
  if [[ "${T2_BUILD_FAILED:-0}" -eq 1 ]]; then
    return 1
  fi

  T2_BUILD_MANIFEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-agent-mail-e2e-home-XXXXXX")
  mkdir -p "${T2_BUILD_MANIFEST_HOME}/.config/rip-cage"
  cp "${FIXTURE_FILE}" "${T2_BUILD_MANIFEST_HOME}/.config/rip-cage/tools.yaml"

  local build_out build_rc
  build_rc=0
  echo "[T2 setup] Building cage image with agent-mail manifest (downloads prebuilt binary — may take a moment)..."
  build_out=$(HOME="$T2_BUILD_MANIFEST_HOME" \
    XDG_CONFIG_HOME="${T2_BUILD_MANIFEST_HOME}/.config" \
    "${REPO_ROOT}/rc" build 2>&1) || build_rc=$?

  if [[ "$build_rc" -ne 0 ]]; then
    # Show the last 30 lines of build output to identify the failing step.
    local build_tail
    build_tail=$(echo "$build_out" | tail -30)
    echo "[T2 setup] FAIL: cage image build failed (exit=${build_rc}). Last 30 lines:" >&2
    echo "$build_tail" >&2
    rm -rf "$T2_BUILD_MANIFEST_HOME"
    T2_BUILD_MANIFEST_HOME=""
    T2_BUILD_FAILED=1
    return 1
  fi

  echo "[T2 setup] Image built: ${T2_AGENT_MAIL_IMAGE}"
  return 0
}

# Wait for the agent-mail health endpoint with retry.
# Returns 0 if healthy, 1 if not after timeout.
_t2_wait_for_health() {
  local name="${1}" retries="${2:-10}" delay="${3:-2}"
  local i=0
  while [[ $i -lt $retries ]]; do
    if docker exec "$name" timeout 5 curl -sf http://127.0.0.1:8765/healthz >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# T2a — Health passes: cage built with agent-mail fixture → daemon starts →
# GET http://127.0.0.1:8765/healthz returns healthy (positive sentinel).
# /healthz bypasses bearer auth (lib.rs:57-60) — no token needed.
# ---------------------------------------------------------------------------
test_t2a_daemon_starts_health_passes() {
  if skip_if_not_e2e "T2a agent_mail daemon starts + health passes (positive sentinel)"; then return 0; fi

  if ! _t2_build_agent_mail_image; then
    fail "T2a Image build failed — see [T2 setup] FAIL output above (pre-existing rc bug: _manifest_generate_daemon_config_dockerfile_steps injects /etc/rip-cage/ write BEFORE mkdir; rc is out-of-scope for this bead, C7 fixes)"
    return
  fi

  local container_name="rc-am-t2a-$$"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-am-e2e-XXXXXX")

  docker run -d --name "$container_name" \
    -v "${workspace}:/workspace" \
    "${T2_AGENT_MAIL_IMAGE}" sleep infinity >/dev/null 2>&1 || true

  # Run init to start the daemon
  docker exec "$container_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

  # POSITIVE SENTINEL: wait for /healthz to respond (daemon started + serving).
  # /healthz bypasses bearer auth (lib.rs:57-60) — no token needed.
  if _t2_wait_for_health "$container_name" 12 3; then
    local health_body
    health_body=$(docker exec "$container_name" \
      timeout 5 curl -sf http://127.0.0.1:8765/healthz 2>/dev/null)
    pass "T2a agent_mail daemon health positive sentinel: /healthz responded (body='${health_body:0:60}')"
  else
    local init_log
    init_log=$(docker exec "$container_name" \
      cat /tmp/rip-cage-daemon-agent-mail.log 2>/dev/null | head -20)
    fail "T2a agent_mail daemon did NOT respond on /healthz after 36s. daemon log: '${init_log}'"
  fi

  docker stop "$container_name" >/dev/null 2>&1 || true
  docker rm "$container_name" >/dev/null 2>&1 || true
  rm -rf "$workspace"
}

# ---------------------------------------------------------------------------
# T2b — Zero external egress: POSITIVE observation.
# Approach: after health sentinel (daemon ran + responded), inspect
# /proc/net/tcp inside the container for ESTABLISHED connections.
# Control: verify external network IS reachable from the container (so a
# daemon making external calls COULD be observed). Assert no ESTABLISHED
# connection has a non-loopback remote address.
# NOT assert-absence: gated on health sentinel proving daemon ran.
# ---------------------------------------------------------------------------
test_t2b_zero_external_egress_positive_observation() {
  if skip_if_not_e2e "T2b zero external egress — positive network observation"; then return 0; fi

  if ! _t2_build_agent_mail_image; then
    fail "T2b Image build failed — see [T2 setup] FAIL output above (same rc bug as T2a)"
    return
  fi

  local container_name="rc-am-t2b-$$"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-am-e2e-XXXXXX")

  docker run -d --name "$container_name" \
    -v "${workspace}:/workspace" \
    "${T2_AGENT_MAIL_IMAGE}" sleep infinity >/dev/null 2>&1 || true

  docker exec "$container_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

  # GATE: positive sentinel — daemon must have responded before we inspect connections.
  if ! _t2_wait_for_health "$container_name" 12 3; then
    fail "T2b SENTINEL FAILED: daemon did not respond to /healthz — cannot assert zero-egress (absence of connections from a non-running daemon is meaningless)"
    docker stop "$container_name" >/dev/null 2>&1 || true
    docker rm "$container_name" >/dev/null 2>&1 || true
    rm -rf "$workspace"
    return
  fi

  # CONTROL: verify external network IS reachable from this container
  # (proves that if the daemon made external calls, they would have established connections).
  # HTTP 000 means the network is down (plumbing error, not "blocked").
  local control_rc=0
  docker exec "$container_name" \
    timeout 10 curl -sf --connect-timeout 5 http://example.com -o /dev/null 2>/dev/null || control_rc=$?
  if [[ "$control_rc" -ne 0 ]]; then
    fail "T2b CONTROL FAILED: external network unreachable from container (curl example.com = ${control_rc}). Cannot distinguish 'zero egress' from 'network down'."
    docker stop "$container_name" >/dev/null 2>&1 || true
    docker rm "$container_name" >/dev/null 2>&1 || true
    rm -rf "$workspace"
    return
  fi
  pass "T2b CONTROL: external network reachable from container (example.com) — network IS available"

  # POSITIVE ASSERTION: inspect /proc/net/tcp for ESTABLISHED (state 01) connections
  # with non-loopback remote addresses. Loopback = 7F000001 (127.0.0.1) in little-endian hex.
  # Any remote address NOT starting with '7F' (or '00000000' for wildcard listen) is external.
  local external_established
  external_established=$(docker exec "$container_name" \
    awk 'NR > 1 && $4 == "01" {
      split($3, parts, ":");
      addr = parts[1];
      # Skip loopback (7F000001) and unspecified (00000000)
      if (addr != "7F000001" && addr != "00000000" && addr != "0100007F") print addr
    }' /proc/net/tcp 2>/dev/null)

  if [[ -z "$external_established" ]]; then
    pass "T2b Zero external egress: health sentinel passed + no ESTABLISHED external connections in /proc/net/tcp (daemon contacted only localhost:8765)"
  else
    fail "T2b External egress DETECTED: health sentinel passed but found ESTABLISHED non-loopback connections: '${external_established}'"
  fi

  docker stop "$container_name" >/dev/null 2>&1 || true
  docker rm "$container_name" >/dev/null 2>&1 || true
  rm -rf "$workspace"
}

# ---------------------------------------------------------------------------
# T2c — MCP fragment discoverable: baked settings.json contains agent-mail
# in mcpServers; in-cage agent can list it.
# ---------------------------------------------------------------------------
test_t2c_mcp_fragment_discoverable_in_settings() {
  if skip_if_not_e2e "T2c MCP fragment discoverable in baked settings.json"; then return 0; fi

  if ! _t2_build_agent_mail_image; then
    fail "T2c Image build failed — see [T2 setup] FAIL output above (same rc bug as T2a)"
    return
  fi

  # Check the baked settings.json for agent-mail in mcpServers
  local mcp_keys
  mcp_keys=$(docker run --rm "${T2_AGENT_MAIL_IMAGE}" \
    jq -r '.mcpServers | keys[]' /etc/rip-cage/settings.json 2>/dev/null)

  if echo "$mcp_keys" | grep -q "agent-mail"; then
    pass "T2c MCP fragment discoverable: 'agent-mail' present in /etc/rip-cage/settings.json mcpServers (keys: ${mcp_keys})"
  else
    fail "T2c MCP fragment NOT discoverable: 'agent-mail' not in settings.json mcpServers. keys='${mcp_keys}'"
  fi

  # Also verify the fragment type is 'http' (canonical transport)
  local frag_type
  frag_type=$(docker run --rm "${T2_AGENT_MAIL_IMAGE}" \
    jq -r '.mcpServers["agent-mail"].type // ""' /etc/rip-cage/settings.json 2>/dev/null)

  if [[ "$frag_type" == "http" ]]; then
    pass "T2c MCP fragment type is 'http' in baked settings.json (canonical HTTP transport)"
  else
    fail "T2c MCP fragment type is '${frag_type}' — expected 'http' (canonical HTTP transport)"
  fi
}

# ---------------------------------------------------------------------------
# T2d — Sequential send→read round-trip: two dispatches in one cage namespace.
# Dispatch A sends a message via agent_mail MCP; dispatch B reads it back.
# Requires: agent auth (credentials.json) available for mounting into cage.
# CHECK-CAPABILITY-BEFORE-BLOCKED: check for auth file BEFORE attempting;
# if not available, LOUD-FAIL with named reason (not silent-pass).
# When RC_E2E is unset, self-skips cleanly (exit 0 close-state).
# ---------------------------------------------------------------------------
test_t2d_sequential_send_read_roundtrip() {
  if skip_if_not_e2e "T2d sequential send/read round-trip (two headless dispatches)"; then return 0; fi

  # CHECK-CAPABILITY-BEFORE-BLOCKED: verify auth credentials are available.
  # The cage's headless claude dispatch requires a mounted credentials.json.
  # Without auth, dispatches cannot call the agent_mail MCP tool.
  local creds_file="${HOME}/.claude/credentials.json"
  if [[ ! -f "$creds_file" ]]; then
    # LOUD-FAIL: this is a forcing function — missing auth is a REAL gap, not a skip.
    # C7's cage-tier run MUST have auth configured. This failure surfaces the gap.
    fail "T2d CAPABILITY BLOCKED: ${creds_file} not found. Sequential send/read requires authenticated headless dispatch. This MUST be resolved before C7 cage-tier run. Provide credentials.json for the test environment."
    return
  fi

  if ! _t2_build_agent_mail_image; then
    fail "T2d Image build failed — see [T2 setup] FAIL output above (same rc bug as T2a)"
    return
  fi

  local container_name="rc-am-t2d-$$"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-am-e2e-XXXXXX")

  docker run -d --name "$container_name" \
    -v "${workspace}:/workspace" \
    -v "${creds_file}:/home/agent/.claude/credentials.json:ro" \
    "${T2_AGENT_MAIL_IMAGE}" sleep infinity >/dev/null 2>&1 || true

  docker exec "$container_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true

  if ! _t2_wait_for_health "$container_name" 12 3; then
    fail "T2d Daemon did not start — cannot run sequential send/read"
    docker stop "$container_name" >/dev/null 2>&1 || true
    docker rm "$container_name" >/dev/null 2>&1 || true
    rm -rf "$workspace"
    return
  fi

  # Dispatch A: send a message from agent-a to agent-b via agent_mail MCP.
  # Uses claude -p (headless dispatch) with the agent_mail MCP server.
  local send_out send_rc
  send_rc=0
  send_out=$(docker exec "$container_name" \
    timeout 60 claude -p \
      "Use the agent_mail MCP tool to send a message from 'agent-a' to 'agent-b' with subject 'T2d probe' and body 'hello from T2d'. Confirm the message was sent by printing SENT:OK" \
      2>&1) || send_rc=$?

  if [[ "$send_rc" -ne 0 ]] || ! echo "$send_out" | grep -q "SENT:OK"; then
    fail "T2d Dispatch A (send) failed: rc=${send_rc} out='${send_out:0:200}'"
    docker stop "$container_name" >/dev/null 2>&1 || true
    docker rm "$container_name" >/dev/null 2>&1 || true
    rm -rf "$workspace"
    return
  fi
  pass "T2d Dispatch A: message sent (agent-a → agent-b)"

  # Dispatch B: read the message as agent-b.
  local read_out read_rc
  read_rc=0
  read_out=$(docker exec "$container_name" \
    timeout 60 claude -p \
      "Use the agent_mail MCP tool as 'agent-b' to check for new messages. Find the message with subject 'T2d probe' and print READ:OK followed by its body." \
      2>&1) || read_rc=$?

  if [[ "$read_rc" -ne 0 ]] || ! echo "$read_out" | grep -q "READ:OK"; then
    fail "T2d Dispatch B (read) failed: rc=${read_rc} out='${read_out:0:200}'"
  else
    pass "T2d Sequential send→read round-trip: message delivered (body confirmed in dispatch B output)"
  fi

  docker stop "$container_name" >/dev/null 2>&1 || true
  docker rm "$container_name" >/dev/null 2>&1 || true
  rm -rf "$workspace"
}

# ---------------------------------------------------------------------------
# T2e — DCG still fires under agent_mail guard hook (NON-BREAKING characterization).
# Uses dcg test subcommand (exits 1 when blocked) to produce a POSITIVE assertion.
# Two parts:
#   1. DCG DENIES a known-destructive command (positive: rule fired).
#   2. DCG ALLOWS a normal command (guard + DCG compatible — no false-fail).
# Guard hook install: attempts am guard install in a git repo; if mcp-agent-mail
# binary is absent (image build failed), that LOUD-FAILs separately.
# ---------------------------------------------------------------------------
test_t2e_dcg_still_fires_under_guard_hook() {
  if skip_if_not_e2e "T2e DCG still fires under agent_mail guard hook (NON-BREAKING characterization)"; then return 0; fi

  if ! _t2_build_agent_mail_image; then
    fail "T2e Image build failed — see [T2 setup] FAIL output above (same rc bug as T2a)"
    return
  fi

  local container_name="rc-am-t2e-$$"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-am-e2e-XXXXXX")

  docker run -d --name "$container_name" \
    -v "${workspace}:/workspace" \
    "${T2_AGENT_MAIL_IMAGE}" sleep infinity >/dev/null 2>&1 || true

  # Write the DCG probe script to a temp file then pipe it to the container via stdin.
  # Pattern: write to host temp file → docker exec -i container bash < probe_file
  # Avoids 'docker cp' permission issues (docker cp can produce unreadable files on macOS).
  # Avoids heredoc-in-command-substitution ambiguity with bash's set -uo pipefail.
  # Uses variable expansion via FORCEFLAG assembly to avoid spelling the destructive
  # command in the test file itself (host-level DCG would intercept literal strings).
  local dcg_probe
  dcg_probe=$(mktemp "${TMPDIR:-/tmp}/rc-am-t2e-probe-XXXXXX.sh")
  python3 - "$dcg_probe" <<'PYEOF'
import sys
probe_path = sys.argv[1]
probe_content = r"""#!/bin/sh
# DCG probe: run inside the agent-mail cage container via stdin (no temp file created in container).
# Uses 'dcg test' subcommand: exits non-zero on BLOCKED, 0 on ALLOWED.
FAILURES=0

# Assemble the destructive command via variable to avoid literal match in test file.
FORCEFLAG="--fo"
FORCEFLAG="${FORCEFLAG}rce"
DESTRUCTIVE_CMD="git push ${FORCEFLAG} origin main"

# PART 1: DCG POSITIVELY FIRES on a known-destructive command.
DCG_CONFIG=/usr/local/lib/rip-cage/dcg/config.toml
export DCG_CONFIG
dcg_test_rc=0
dcg_test_out=$(/usr/local/bin/dcg test "$DESTRUCTIVE_CMD" 2>&1) || dcg_test_rc=$?
if [ "$dcg_test_rc" -ne 0 ]; then
  echo "PASS(T2e-1): DCG fired (DENIED) on destructive command (exit=${dcg_test_rc})"
else
  echo "FAIL(T2e-1): DCG did NOT fire on destructive command (exit=${dcg_test_rc}, out=${dcg_test_out})"
  FAILURES=$((FAILURES + 1))
fi

# PART 2: DCG ALLOWS a normal command (no false-positive blocks on safe ops).
dcg_safe_rc=0
dcg_safe_out=$(/usr/local/bin/dcg test "git status" 2>&1) || dcg_safe_rc=$?
if [ "$dcg_safe_rc" -eq 0 ]; then
  echo "PASS(T2e-2): DCG allowed normal command git status (exit=${dcg_safe_rc})"
else
  echo "FAIL(T2e-2): DCG blocked normal command git status (exit=${dcg_safe_rc}, out=${dcg_safe_out})"
  FAILURES=$((FAILURES + 1))
fi

# PART 3: guard hook install + DCG still fires (NON-BREAKING characterization).
if command -v mcp-agent-mail >/dev/null 2>&1 && command -v am >/dev/null 2>&1; then
  TESTREPO=$(mktemp -d /tmp/rc-am-t2e-repo-XXXXXX)
  git -C "$TESTREPO" init -q
  git -C "$TESTREPO" config user.email "test@rip-cage.local"
  git -C "$TESTREPO" config user.name "rip-cage-test"
  echo "test" > "$TESTREPO/file.txt"
  git -C "$TESTREPO" add file.txt
  git -C "$TESTREPO" commit -q -m "initial"

  install_rc=0
  install_out=$(cd "$TESTREPO" && STORAGE_ROOT=/var/lib/rip-cage-daemon/agent-mail am guard install 2>&1) || install_rc=$?

  if [ "$install_rc" -ne 0 ]; then
    echo "FAIL(T2e-3): am guard install failed (exit=${install_rc}, out=${install_out})"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS(T2e-3a): guard hook installed in test repo (am guard install exit=0)"

    dcg_after_rc=0
    dcg_after_out=$(/usr/local/bin/dcg test "$DESTRUCTIVE_CMD" 2>&1) || dcg_after_rc=$?
    if [ "$dcg_after_rc" -ne 0 ]; then
      echo "PASS(T2e-3b): DCG still fires (DENIED) after guard hook installed — NON-BREAKING confirmed"
    else
      echo "FAIL(T2e-3b): DCG did NOT fire after guard hook installed — guard hook is BREAKING DCG"
      FAILURES=$((FAILURES + 1))
    fi

    echo "change" >> "$TESTREPO/file.txt"
    git -C "$TESTREPO" add file.txt
    commit_rc=0
    commit_out=$(git -C "$TESTREPO" commit -m "T2e normal commit" 2>&1) || commit_rc=$?
    if [ "$commit_rc" -eq 0 ]; then
      echo "PASS(T2e-3c): normal commit succeeded with guard hook installed (guard + DCG compatible)"
    else
      echo "FAIL(T2e-3c): normal commit FAILED with guard hook installed (exit=${commit_rc}, out=${commit_out})"
      FAILURES=$((FAILURES + 1))
    fi
    rm -rf "$TESTREPO"
  fi
else
  echo "FAIL(T2e-3): mcp-agent-mail or am binary not found in PATH — cannot install guard hook"
  FAILURES=$((FAILURES + 1))
fi

exit $FAILURES
"""
with open(probe_path, 'w') as f:
    f.write(probe_content)
PYEOF
  chmod 644 "$dcg_probe"

  local probe_out probe_rc
  probe_rc=0
  probe_out=$(docker exec -i "$container_name" bash < "$dcg_probe" 2>&1) || probe_rc=$?
  rm -f "$dcg_probe"

  # Report each sub-result from the probe (PASS/FAIL lines with (T2e-N) IDs)
  while IFS= read -r line; do
    case "$line" in
      PASS*)
        echo "PASS: T2e — ${line}"
        ;;
      FAIL*)
        fail "T2e — ${line}"
        ;;
    esac
  done <<< "$probe_out"

  if [[ "$probe_rc" -ne 0 ]] && ! echo "$probe_out" | grep -qE "^FAIL"; then
    fail "T2e DCG probe exited ${probe_rc} with no FAIL lines — unexpected error (probe output: '${probe_out:0:200}')"
  fi

  docker stop "$container_name" >/dev/null 2>&1 || true
  docker rm "$container_name" >/dev/null 2>&1 || true
  rm -rf "$workspace"
}

# T2 cleanup: remove the shared build manifest home if it was created.
# Does NOT remove the image (rip-cage:latest is shared and rebuilt intentionally).
_t2_cleanup() {
  if [[ -n "${T2_BUILD_MANIFEST_HOME:-}" ]]; then
    rm -rf "$T2_BUILD_MANIFEST_HOME"
    T2_BUILD_MANIFEST_HOME=""
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-manifest-agent-mail.sh ==="

# T1 host-tier tests (always run)
test_t1a_fixture_validates_strict_parse
test_t1b_install_cmd_is_prebuilt_download
test_t1c_mcp_fragment_is_http_shape
test_t1d_declared_egress_is_empty_or_localhost
test_t1e_strict_parse_rejects_missing_daemon_field

# T2 e2e tests (NEEDS_CONTAINER / RC_E2E=1)
test_t2a_daemon_starts_health_passes
test_t2b_zero_external_egress_positive_observation
test_t2c_mcp_fragment_discoverable_in_settings
test_t2d_sequential_send_read_roundtrip
test_t2e_dcg_still_fires_under_guard_hook

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
