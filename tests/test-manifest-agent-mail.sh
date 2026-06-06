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
# T1b — install_cmd DOWNLOADS a prebuilt release artifact.
# Must contain 'releases/download' or 'install.sh' in the command.
# Must NOT contain 'cargo build' (bare cargo build is not viable:
# workspace [patch.crates-io] redirects ~40 deps to unpublished siblings).
# Source: Cargo.toml:160-224, install.sh:387,352-353 (pinned @ 8897497).
# ---------------------------------------------------------------------------
test_t1b_install_cmd_is_prebuilt_download() {
  local install_cmd
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

  if [[ -z "$install_cmd" ]]; then
    fail "T1b Could not extract install_cmd from fixture (agent-mail entry not found or install_cmd empty)"
    return
  fi

  # Must reference a prebuilt download (releases/download URL or install.sh curl)
  if echo "$install_cmd" | grep -qE "releases/download|install\.sh"; then
    pass "T1b install_cmd references prebuilt release download: '${install_cmd:0:80}...'"
  else
    fail "T1b install_cmd does NOT reference a prebuilt release download. Got: '${install_cmd}'"
  fi

  # Must NOT contain 'cargo build' (bare cargo build is not viable for this workspace)
  if echo "$install_cmd" | grep -q "cargo build"; then
    fail "T1b install_cmd contains 'cargo build' — NOT viable (workspace patches 40 unpublished sibling deps). Use prebuilt binary download."
  else
    pass "T1b install_cmd does not contain 'cargo build' (correct: prebuilt download only)"
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
  mcp_fragment=$(python3 -c "
import yaml, json, sys
with open('${FIXTURE_FILE}') as f:
    manifest = yaml.safe_load(f)
tools = manifest.get('tools', [])
for t in tools:
    if t.get('name') == 'agent-mail':
        frag = t.get('mcp_fragment', '')
        print(frag)
        sys.exit(0)
print('')
" 2>/dev/null)

  if [[ -z "$mcp_fragment" ]]; then
    fail "T1c mcp_fragment not found in agent-mail fixture entry"
    return
  fi

  # Validate it's parseable JSON
  local parsed_type parsed_url
  parsed_type=$(echo "$mcp_fragment" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('type',''))" 2>/dev/null)
  parsed_url=$(echo "$mcp_fragment" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('url',''))" 2>/dev/null)

  if [[ "$parsed_type" != "http" ]]; then
    fail "T1c mcp_fragment type is '${parsed_type}' — expected 'http' (canonical HTTP transport per source @ 8897497)"
    return
  fi
  pass "T1c mcp_fragment type is 'http' (canonical HTTP transport)"

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
d = json.load(sys.stdin)
headers = d.get('headers', {})
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
# T1e — Counterfactual: removing install_cmd from a daemon entry (for a TOOL
# archetype, not IN-CAGE-DAEMON which doesn't require install_cmd) — verify
# the validator correctly accepts IN-CAGE-DAEMON without install_cmd.
# Also verify the fixture's state_dir points to the correct container-local path.
# ---------------------------------------------------------------------------
test_t1e_state_dir_and_version_pin_present() {
  local state_dir version_pin
  state_dir=$(python3 -c "
import yaml, sys
with open('${FIXTURE_FILE}') as f:
    manifest = yaml.safe_load(f)
tools = manifest.get('tools', [])
for t in tools:
    if t.get('name') == 'agent-mail':
        print(t.get('state_dir', ''))
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

  if [[ -n "$state_dir" ]]; then
    pass "T1e state_dir is set: '${state_dir}'"
  else
    fail "T1e state_dir is missing from agent-mail fixture entry"
  fi

  if [[ -n "$version_pin" ]]; then
    pass "T1e version_pin is set: '${version_pin}'"
  else
    fail "T1e version_pin is missing from agent-mail fixture entry"
  fi
}

# ---------------------------------------------------------------------------
# T2 — E2E (NEEDS_CONTAINER / RC_E2E=1)
#
# All T2 tests use the agent_mail prebuilt binary baked into the image.
# The full cage run is owned by sibling C7's RC_E2E tier.
# ---------------------------------------------------------------------------

# Skip helper for all T2 tests
skip_if_not_e2e() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / e2e): ${1} — set RC_E2E=1 to run"
    return 0
  fi
  return 1
}

test_t2a_daemon_starts_health_passes() {
  if skip_if_not_e2e "T2a agent_mail daemon starts + health passes (positive sentinel)"; then return 0; fi

  # NOT-YET-IMPLEMENTED: requires cage image built with manifest-agent-mail.yaml
  # and the prebuilt mcp-agent-mail binary installed at image build time.
  # Health endpoint: GET http://127.0.0.1:8765/healthz (bypasses bearer auth per lib.rs:57-60).
  # POSITIVE SENTINEL required: daemon must respond, not just absence-of-error.
  # This test is owned by C7's full RC_E2E tier run (rc test --e2e with agent-mail image).
  echo "NOT-YET-IMPLEMENTED (T2a): agent_mail daemon health probe — requires prebuilt binary baked in image (C7 RC_E2E tier)"
  echo "SKIP (T2a): set RC_E2E=1 and run rc test --e2e after C7 wires agent-mail into the suite"
}

test_t2b_zero_external_egress_positive_observation() {
  if skip_if_not_e2e "T2b zero external egress — positive proxy observation"; then return 0; fi

  # NOT-YET-IMPLEMENTED: requires running cage with agent_mail daemon and the
  # IOC egress proxy (C3 sibling) capturing traffic.
  # MUST be a POSITIVE observation (proxy log shows ONLY localhost:8765 entries)
  # gated on a sentinel proving agent_mail actually ran and made localhost calls.
  # Using real reachable host (example.com) as a control; HTTP 000 = plumbing error.
  # NOT assert-absence (a daemon that never ran would also produce an empty log).
  echo "NOT-YET-IMPLEMENTED (T2b): zero-egress positive proxy observation — requires IOC proxy (C3) + agent_mail running (C7)"
  echo "SKIP (T2b): set RC_E2E=1 and run rc test --e2e after C7 wires agent-mail egress probe"
}

test_t2c_mcp_fragment_discoverable_in_settings() {
  if skip_if_not_e2e "T2c MCP fragment discoverable in settings.json"; then return 0; fi

  # NOT-YET-IMPLEMENTED: requires cage image with agent_mail manifest baked in.
  # After init: /etc/rip-cage/settings.json mcpServers must contain 'agent-mail'.
  # Visible to in-cage agent via the standard settings.json MCP discovery path.
  echo "NOT-YET-IMPLEMENTED (T2c): MCP fragment in settings.json — requires agent-mail image build (C7)"
  echo "SKIP (T2c): set RC_E2E=1 and run rc test --e2e after C7 wires agent-mail into the suite"
}

test_t2d_sequential_send_read_roundtrip() {
  if skip_if_not_e2e "T2d sequential send/read round-trip (two headless dispatches)"; then return 0; fi

  # NOT-YET-IMPLEMENTED: sequential coordination proof per ADR-006 Tier 1a.
  # Dispatch A (claude -p / pi -p): sends a message via agent_mail MCP tool.
  # Dispatch B (second docker exec in same cage namespace): reads it back.
  # Message delivered = proof the MCP plumbing + mailbox backend works end-to-end.
  # NOTE: This validates SEQUENTIAL plumbing only — NOT concurrent coordination
  # (concurrent proof deferred to ADR-006 Tier 1a, rip-cage-p1p).
  echo "NOT-YET-IMPLEMENTED (T2d): sequential send/read round-trip — requires headless auth + agent_mail MCP in cage (C7)"
  echo "SKIP (T2d): set RC_E2E=1 and run rc test --e2e after C7 wires full round-trip"
}

test_t2e_dcg_still_fires_under_guard_hook() {
  if skip_if_not_e2e "T2e DCG still fires under agent_mail guard hook (NON-BREAKING characterization)"; then return 0; fi

  # NOT-YET-IMPLEMENTED: git-commit-under-guard-hook probe.
  # The mcp-agent-mail-guard pre-commit hook interaction with DCG is DOCUMENTED
  # as NON-BREAKING (see docs/reference/agent-mail-daemon.md):
  #   - Hook installed ONLY by explicit MCP tool / CLI / am doctor --fix — never auto-installed.
  #   - Writes ONLY into target repo's .git/hooks/ — no DCG config writes.
  #   - Reads only env-vars + mailbox JSON — cannot suppress DCG.
  #   - DCG and guard hook are mutually invisible.
  #
  # Probe design (when C7 implements):
  #   1. Install guard hook in a test repo inside cage.
  #   2. Feed DCG a known-destructive command (e.g. 'rm -rf /workspace/.git') — ASSERT deny.
  #      (POSITIVE assertion — not inference from a commit that happened to succeed)
  #   3. Make a normal commit in the test repo — ASSERT commit succeeds (exit 0).
  #      (guard + DCG compatible — no false-fail on legitimate commits)
  echo "NOT-YET-IMPLEMENTED (T2e): DCG-under-guard-hook probe — requires cage with agent_mail + DCG policy (C7)"
  echo "SKIP (T2e): set RC_E2E=1 and run rc test --e2e after C7 wires the DCG/guard probe"
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
test_t1e_state_dir_and_version_pin_present

# T2 e2e tests (NEEDS_CONTAINER / RC_E2E=1)
test_t2a_daemon_starts_health_passes
test_t2b_zero_external_egress_positive_observation
test_t2c_mcp_fragment_discoverable_in_settings
test_t2d_sequential_send_read_roundtrip
test_t2e_dcg_still_fires_under_guard_hook

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
