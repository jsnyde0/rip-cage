#!/usr/bin/env bash
# Host-side tests for `rc allowlist` subcommand (rip-cage-hhh.6).
#
# Coverage:
#   A1  allowlist add appends a host to .rip-cage.yaml (new file created)
#   A2  allowlist add is idempotent — adding the same host twice = one entry
#   A3  allowlist add --output json shape: {action, host, config_file}
#   A4  allowlist add --output json with skipped host: action=skipped
#   A5  allowlist show lists configured network.allowed_hosts
#   A6  allowlist show --observed parses synthetic egress JSONL log and lists blocked hosts
#   A7  allowlist show --observed only lists deny/would-block events (not allow)
#   A8  allowlist promote --from-observed merges observed hosts into .rip-cage.yaml + flips mode=block
#   A9  allowlist promote --from-observed emits a diff (hosts added, mode flip)
#   A10 allowlist promote --from-observed skips hosts already in allowed_hosts (idempotent)
#   A11 add refuses when /.dockerenv present (simulated D10 host-side-only guard)
#   A12 promote refuses when /.dockerenv present (simulated D10 guard)
#   A13 allowlist show --output json shape: {allowed_hosts: [...]}
#
# Tests run entirely host-side (no docker required). D10 guard simulated by
# setting RC_TEST_FAKE_DOCKERENV=1 (same pattern as test-rc-reload.sh would use
# for the in-cage environment detection).
#
# ADRs: ADR-003 D1/D4/D5 (agent-first CLI), ADR-021 D4 (effective-config provenance),
#        ADR-022 D6 (host-side-only pattern), epic D10/D11.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0
TEST_HOME=""

pass() { echo "PASS A$1: $2"; }
fail() { echo "FAIL A$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Build a sandbox HOME and workspace.
# Globals set: TEST_HOME, WS
setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-allowlist-test-XXXXXX")
  WS="${TEST_HOME}/workspace"
  mkdir -p "$WS"
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" WS=""
}

# Run rc with sandboxed HOME.
run_rc() {
  HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    "$RC" "$@"
}

# Run rc with fake dockerenv detection (simulates in-cage).
run_rc_in_cage() {
  HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_TEST_FAKE_DOCKERENV=1 \
    "$RC" "$@"
}

# Write a synthetic egress log with deny/would-block and allow events.
write_egress_log() {
  local log_path="$1"
  mkdir -p "$(dirname "$log_path")"
  cat > "$log_path" <<'JSONL'
{"timestamp":"2026-05-27T10:00:00Z","event":"deny","rule_id":"not-whitelisted","method":"GET","host":"registry.example.com","path":"/","container_hostname":"cage1","pattern":"allowed_hosts","target":"registry.example.com","why":"Host not in allowed_hosts","fix_command":"rc allowlist add registry.example.com","config_file":".rip-cage.yaml","config_path":"network.allowed_hosts"}
{"timestamp":"2026-05-27T10:01:00Z","event":"allow","rule_id":"","method":"GET","host":"api.anthropic.com","path":"/","container_hostname":"cage1","pattern":null,"target":"api.anthropic.com","why":null,"fix_command":null,"config_file":null,"config_path":null}
{"timestamp":"2026-05-27T10:02:00Z","event":"would-block","rule_id":"not-whitelisted","method":"POST","host":"cdn.staging.myapp.io","path":"/upload","container_hostname":"cage1","pattern":"allowed_hosts","target":"cdn.staging.myapp.io","why":"Host not in allowed_hosts","fix_command":"rc allowlist add cdn.staging.myapp.io","config_file":".rip-cage.yaml","config_path":"network.allowed_hosts"}
{"timestamp":"2026-05-27T10:03:00Z","event":"deny","rule_id":"not-whitelisted","method":"GET","host":"registry.example.com","path":"/v2","container_hostname":"cage1","pattern":"allowed_hosts","target":"registry.example.com","why":"Host not in allowed_hosts","fix_command":"rc allowlist add registry.example.com","config_file":".rip-cage.yaml","config_path":"network.allowed_hosts"}
JSONL
}

# ---------------------------------------------------------------------------
# A1: allowlist add appends a host to .rip-cage.yaml (new file created)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a1_out=$(run_rc allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" 2>&1)
a1_exit=$?
a1_ok=true a1_reason=""
[[ "$a1_exit" -ne 0 ]] && a1_ok=false && a1_reason="exit $a1_exit; output: $a1_out"
if [[ "$a1_ok" == "true" ]]; then
  if ! grep -q "cdn.example.com" "${WS}/.rip-cage.yaml" 2>/dev/null; then
    a1_ok=false; a1_reason="cdn.example.com not found in .rip-cage.yaml"
  fi
fi
if [[ "$a1_ok" == "true" ]]; then pass 1 "allowlist add creates .rip-cage.yaml with host"
else fail 1 "allowlist add" "$a1_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A2: allowlist add is idempotent — adding same host twice = one entry
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

run_rc allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>&1
run_rc allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>&1
a2_count=$(grep -c "cdn.example.com" "${WS}/.rip-cage.yaml" 2>/dev/null || echo 0)
a2_ok=true a2_reason=""
[[ "$a2_count" -ne 1 ]] && a2_ok=false && a2_reason="host appears $a2_count times (want 1)"
if [[ "$a2_ok" == "true" ]]; then pass 2 "allowlist add idempotent (two adds = one entry)"
else fail 2 "allowlist add idempotent" "$a2_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A3: allowlist add --output json shape: {action, host, config_file}
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a3_out=$(run_rc --output json allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" 2>/dev/null)
a3_exit=$?
a3_ok=true a3_reason=""
[[ "$a3_exit" -ne 0 ]] && a3_ok=false && a3_reason="exit $a3_exit"
if [[ "$a3_ok" == "true" ]]; then
  a3_action=$(echo "$a3_out" | jq -r '.action' 2>/dev/null)
  a3_host=$(echo "$a3_out" | jq -r '.host' 2>/dev/null)
  a3_cf=$(echo "$a3_out" | jq -r '.config_file' 2>/dev/null)
  [[ "$a3_action" != "added" ]] && a3_ok=false && a3_reason="action=${a3_action} (want 'added')"
  [[ "$a3_host" != "cdn.example.com" ]] && a3_ok=false && a3_reason="${a3_reason:+$a3_reason; }host=${a3_host}"
  [[ -z "$a3_cf" || "$a3_cf" == "null" ]] && a3_ok=false && a3_reason="${a3_reason:+$a3_reason; }config_file missing"
fi
if [[ "$a3_ok" == "true" ]]; then pass 3 "allowlist add --output json shape: action=added, host, config_file"
else fail 3 "allowlist add json shape" "$a3_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A4: allowlist add --output json with skipped host: action=skipped
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

run_rc allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>&1
a4_out=$(run_rc --output json allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" 2>/dev/null)
a4_exit=$?
a4_ok=true a4_reason=""
[[ "$a4_exit" -ne 0 ]] && a4_ok=false && a4_reason="exit $a4_exit"
if [[ "$a4_ok" == "true" ]]; then
  a4_action=$(echo "$a4_out" | jq -r '.action' 2>/dev/null)
  [[ "$a4_action" != "skipped" ]] && a4_ok=false && a4_reason="action=${a4_action} (want 'skipped')"
fi
if [[ "$a4_ok" == "true" ]]; then pass 4 "allowlist add --output json: action=skipped when already present"
else fail 4 "allowlist add skipped json" "$a4_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A5: allowlist show lists configured network.allowed_hosts
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts:
    - registry.npmjs.org
    - example.org
YML
a5_out=$(run_rc --output json allowlist show --config-file "${WS}/.rip-cage.yaml" 2>/dev/null)
a5_exit=$?
a5_ok=true a5_reason=""
[[ "$a5_exit" -ne 0 ]] && a5_ok=false && a5_reason="exit $a5_exit"
if [[ "$a5_ok" == "true" ]]; then
  a5_count=$(echo "$a5_out" | jq -r '.allowed_hosts | length' 2>/dev/null)
  [[ "$a5_count" -ne 2 ]] && a5_ok=false && a5_reason="allowed_hosts count=${a5_count} (want 2)"
  echo "$a5_out" | jq -r '.allowed_hosts[]' 2>/dev/null | grep -q "registry.npmjs.org" || {
    a5_ok=false; a5_reason="${a5_reason:+$a5_reason; }registry.npmjs.org not in list"; }
fi
if [[ "$a5_ok" == "true" ]]; then pass 5 "allowlist show --output json lists configured network.allowed_hosts"
else fail 5 "allowlist show json" "$a5_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A6: allowlist show --observed parses synthetic egress JSONL log + lists blocked hosts
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

write_egress_log "${WS}/.rip-cage/egress.log"
a6_out=$(run_rc --output json allowlist show --observed --log-file "${WS}/.rip-cage/egress.log" 2>/dev/null)
a6_exit=$?
a6_ok=true a6_reason=""
[[ "$a6_exit" -ne 0 ]] && a6_ok=false && a6_reason="exit $a6_exit"
if [[ "$a6_ok" == "true" ]]; then
  a6_hosts=$(echo "$a6_out" | jq -r '.observed_hosts[]' 2>/dev/null)
  echo "$a6_hosts" | grep -q "registry.example.com" || {
    a6_ok=false; a6_reason="${a6_reason:+$a6_reason; }registry.example.com not in observed_hosts"; }
  echo "$a6_hosts" | grep -q "cdn.staging.myapp.io" || {
    a6_ok=false; a6_reason="${a6_reason:+$a6_reason; }cdn.staging.myapp.io not in observed_hosts"; }
fi
if [[ "$a6_ok" == "true" ]]; then pass 6 "allowlist show --observed lists blocked/would-block hosts from JSONL log"
else fail 6 "allowlist show --observed" "$a6_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A7: allowlist show --observed does NOT include allow events
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

write_egress_log "${WS}/.rip-cage/egress.log"
a7_out=$(run_rc --output json allowlist show --observed --log-file "${WS}/.rip-cage/egress.log" 2>/dev/null)
a7_ok=true a7_reason=""
a7_hosts=$(echo "$a7_out" | jq -r '.observed_hosts[]' 2>/dev/null)
echo "$a7_hosts" | grep -q "api.anthropic.com" && {
  a7_ok=false; a7_reason="api.anthropic.com (allowed event) appeared in observed_hosts"; }
if [[ "$a7_ok" == "true" ]]; then pass 7 "allowlist show --observed excludes allow events"
else fail 7 "allowlist show observed filters allow" "$a7_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A8: allowlist promote --from-observed merges observed hosts + flips mode=block
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts:
    - already.allowed.com
  mode: observe
YML
write_egress_log "${WS}/.rip-cage/egress.log"

a8_out=$(run_rc allowlist promote --from-observed \
  --config-file "${WS}/.rip-cage.yaml" \
  --log-file "${WS}/.rip-cage/egress.log" 2>&1)
a8_exit=$?
a8_ok=true a8_reason=""
[[ "$a8_exit" -ne 0 ]] && a8_ok=false && a8_reason="exit $a8_exit; output: $a8_out"

if [[ "$a8_ok" == "true" ]]; then
  # Verify YAML was mutated: observed hosts added + mode flipped
  if ! grep -q "registry.example.com" "${WS}/.rip-cage.yaml" 2>/dev/null; then
    a8_ok=false; a8_reason="${a8_reason:+$a8_reason; }registry.example.com not added to .rip-cage.yaml"
  fi
  if ! grep -q "cdn.staging.myapp.io" "${WS}/.rip-cage.yaml" 2>/dev/null; then
    a8_ok=false; a8_reason="${a8_reason:+$a8_reason; }cdn.staging.myapp.io not added"
  fi
  if ! grep -q "mode: block" "${WS}/.rip-cage.yaml" 2>/dev/null; then
    a8_ok=false; a8_reason="${a8_reason:+$a8_reason; }mode not flipped to block"
  fi
  # Existing host preserved
  if ! grep -q "already.allowed.com" "${WS}/.rip-cage.yaml" 2>/dev/null; then
    a8_ok=false; a8_reason="${a8_reason:+$a8_reason; }already.allowed.com not preserved"
  fi
fi
if [[ "$a8_ok" == "true" ]]; then pass 8 "allowlist promote merges observed hosts + flips mode=block"
else fail 8 "allowlist promote" "$a8_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A9: allowlist promote --from-observed emits a diff (hosts added + mode flip)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: []
  mode: observe
YML
write_egress_log "${WS}/.rip-cage/egress.log"

a9_out=$(run_rc allowlist promote --from-observed \
  --config-file "${WS}/.rip-cage.yaml" \
  --log-file "${WS}/.rip-cage/egress.log" 2>&1)
a9_ok=true a9_reason=""
# Diff should mention mode change + at least one added host
echo "$a9_out" | grep -qi "mode.*block\|block.*mode\|mode:" || {
  a9_ok=false; a9_reason="diff does not mention mode->block"; }
echo "$a9_out" | grep -q "registry.example.com\|cdn.staging.myapp.io" || {
  a9_ok=false; a9_reason="${a9_reason:+$a9_reason; }diff doesn't mention observed hosts"; }
if [[ "$a9_ok" == "true" ]]; then pass 9 "allowlist promote emits diff of .rip-cage.yaml mutation"
else fail 9 "allowlist promote diff" "$a9_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A10: allowlist promote --from-observed is idempotent (hosts already in list not duplicated)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts:
    - registry.example.com
    - cdn.staging.myapp.io
  mode: observe
YML
write_egress_log "${WS}/.rip-cage/egress.log"

run_rc allowlist promote --from-observed \
  --config-file "${WS}/.rip-cage.yaml" \
  --log-file "${WS}/.rip-cage/egress.log" >/dev/null 2>&1

a10_count_reg=$(grep -c "registry.example.com" "${WS}/.rip-cage.yaml" 2>/dev/null || echo 0)
a10_count_cdn=$(grep -c "cdn.staging.myapp.io" "${WS}/.rip-cage.yaml" 2>/dev/null || echo 0)
a10_ok=true a10_reason=""
[[ "$a10_count_reg" -ne 1 ]] && a10_ok=false && a10_reason="registry.example.com appears $a10_count_reg times"
[[ "$a10_count_cdn" -ne 1 ]] && a10_ok=false && a10_reason="${a10_reason:+$a10_reason; }cdn.staging.myapp.io appears $a10_count_cdn times"
if [[ "$a10_ok" == "true" ]]; then pass 10 "allowlist promote idempotent (no duplicate hosts)"
else fail 10 "allowlist promote idempotent" "$a10_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A11: allowlist add refuses when RC_TEST_FAKE_DOCKERENV=1 (D10 host-side-only guard)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a11_out=$(run_rc_in_cage allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" 2>&1)
a11_exit=$?
a11_ok=true a11_reason=""
[[ "$a11_exit" -eq 0 ]] && a11_ok=false && a11_reason="exit 0 (want non-zero — should refuse in-cage)"
echo "$a11_out" | grep -qi "host.*tool\|host.only\|inside.*container\|in-cage\|dockerenv" || {
  a11_ok=false; a11_reason="${a11_reason:+$a11_reason; }no host-only message in: $a11_out"; }
if [[ "$a11_ok" == "true" ]]; then pass 11 "allowlist add refuses when in-cage (D10 guard)"
else fail 11 "allowlist add D10 guard" "$a11_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A12: allowlist promote refuses when RC_TEST_FAKE_DOCKERENV=1 (D10 guard)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a12_out=$(run_rc_in_cage allowlist promote --from-observed \
  --config-file "${WS}/.rip-cage.yaml" \
  --log-file "${WS}/.rip-cage/egress.log" 2>&1)
a12_exit=$?
a12_ok=true a12_reason=""
[[ "$a12_exit" -eq 0 ]] && a12_ok=false && a12_reason="exit 0 (want non-zero — should refuse in-cage)"
echo "$a12_out" | grep -qi "host.*tool\|host.only\|inside.*container\|in-cage\|dockerenv" || {
  a12_ok=false; a12_reason="${a12_reason:+$a12_reason; }no host-only message in: $a12_out"; }
if [[ "$a12_ok" == "true" ]]; then pass 12 "allowlist promote refuses when in-cage (D10 guard)"
else fail 12 "allowlist promote D10 guard" "$a12_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A13: allowlist show --output json shape: has allowed_hosts array key
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts:
    - test.example.com
YML
a13_out=$(run_rc --output json allowlist show --config-file "${WS}/.rip-cage.yaml" 2>/dev/null)
a13_exit=$?
a13_ok=true a13_reason=""
[[ "$a13_exit" -ne 0 ]] && a13_ok=false && a13_reason="exit $a13_exit"
if [[ "$a13_ok" == "true" ]]; then
  if ! echo "$a13_out" | jq -e 'has("allowed_hosts")' >/dev/null 2>&1; then
    a13_ok=false; a13_reason="no allowed_hosts key in JSON output: $a13_out"
  fi
fi
if [[ "$a13_ok" == "true" ]]; then pass 13 "allowlist show --output json has allowed_hosts key"
else fail 13 "allowlist show json shape" "$a13_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES of $TOTAL tests"
  exit 1
fi
echo "All $TOTAL tests passed."
