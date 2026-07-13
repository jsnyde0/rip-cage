#!/usr/bin/env bash
# Host-side tests for `rc allowlist` subcommand (rip-cage-hhh.6).
#
# Coverage:
#   A1  allowlist add appends a host to .rip-cage.yaml (new file created)
#   A2  allowlist add is idempotent — adding the same host twice = one entry
#   A3  allowlist add --output json shape: {action, host, config_file}
#   A4  allowlist add --output json with skipped host: action=skipped
#   A5  allowlist show lists configured network.allowed_hosts
#   A6  allowlist show --observed is retired: exits non-zero + prints the
#       retirement message to stderr (rip-cage-tsf2.2 loud-fail stub — the
#       in-cage egress log producer was deleted in the msb migration, so
#       this flag can no longer silently report "(none)")
#   A7  allowlist show --observed retirement message names ADR-029 and the
#       fast-follow bead rip-cage-tsf2.2
#   A8  allowlist promote --from-observed is retired: exits non-zero + prints
#       the retirement message to stderr
#   A9  allowlist promote --from-observed retirement message names ADR-029
#       and the fast-follow bead rip-cage-tsf2.2
#   A10 allowlist promote --from-observed never mutates .rip-cage.yaml — the
#       retirement guard fires before any log read or config write, so there
#       is no silent partial apply
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
# A6: allowlist show --observed is retired -- exits non-zero, prints message to stderr
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

write_egress_log "${WS}/.rip-cage/egress.log"
a6_err=$(mktemp)
a6_out=$(run_rc --output json allowlist show --observed --log-file "${WS}/.rip-cage/egress.log" 2>"$a6_err")
a6_exit=$?
a6_ok=true a6_reason=""
[[ "$a6_exit" -eq 0 ]] && a6_ok=false && a6_reason="exit 0 (want non-zero -- --observed must fail loud, not silently report)"
[[ -z "$(cat "$a6_err")" ]] && a6_ok=false && a6_reason="${a6_reason:+$a6_reason; }no stderr output emitted"
if [[ "$a6_ok" == "true" ]]; then pass 6 "allowlist show --observed exits non-zero + writes to stderr (retired)"
else fail 6 "allowlist show --observed retirement" "$a6_reason -- stdout: $a6_out stderr: $(cat "$a6_err")"; fi
rm -f "$a6_err"
teardown_sandbox

# ---------------------------------------------------------------------------
# A7: allowlist show --observed retirement message names ADR-029 + fast-follow bead
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a7_err=$(mktemp)
run_rc allowlist show --observed >/dev/null 2>"$a7_err"
a7_ok=true a7_reason=""
grep -qi "retired" "$a7_err" || { a7_ok=false; a7_reason="stderr does not say 'retired'"; }
grep -q "ADR-029" "$a7_err" || { a7_ok=false; a7_reason="${a7_reason:+$a7_reason; }stderr does not cite ADR-029"; }
grep -q "rip-cage-tsf2.2" "$a7_err" || { a7_ok=false; a7_reason="${a7_reason:+$a7_reason; }stderr does not point at fast-follow bead rip-cage-tsf2.2"; }
if [[ "$a7_ok" == "true" ]]; then pass 7 "allowlist show --observed message names ADR-029 + rip-cage-tsf2.2"
else fail 7 "allowlist show --observed message content" "$a7_reason -- stderr: $(cat "$a7_err")"; fi
rm -f "$a7_err"
teardown_sandbox

# ---------------------------------------------------------------------------
# A8: allowlist promote --from-observed is retired -- exits non-zero, prints message to stderr
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

a8_err=$(mktemp)
run_rc allowlist promote --from-observed \
  --config-file "${WS}/.rip-cage.yaml" \
  --log-file "${WS}/.rip-cage/egress.log" >/dev/null 2>"$a8_err"
a8_exit=$?
a8_ok=true a8_reason=""
[[ "$a8_exit" -eq 0 ]] && a8_ok=false && a8_reason="exit 0 (want non-zero -- --from-observed must fail loud, not silently apply nothing)"
[[ -z "$(cat "$a8_err")" ]] && a8_ok=false && a8_reason="${a8_reason:+$a8_reason; }no stderr output emitted"
if [[ "$a8_ok" == "true" ]]; then pass 8 "allowlist promote --from-observed exits non-zero + writes to stderr (retired)"
else fail 8 "allowlist promote --from-observed retirement" "$a8_reason -- stderr: $(cat "$a8_err")"; fi
rm -f "$a8_err"
teardown_sandbox

# ---------------------------------------------------------------------------
# A9: allowlist promote --from-observed retirement message names ADR-029 + fast-follow bead
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a9_err=$(mktemp)
run_rc allowlist promote --from-observed --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>"$a9_err"
a9_ok=true a9_reason=""
grep -qi "retired" "$a9_err" || { a9_ok=false; a9_reason="stderr does not say 'retired'"; }
grep -q "ADR-029" "$a9_err" || { a9_ok=false; a9_reason="${a9_reason:+$a9_reason; }stderr does not cite ADR-029"; }
grep -q "rip-cage-tsf2.2" "$a9_err" || { a9_ok=false; a9_reason="${a9_reason:+$a9_reason; }stderr does not point at fast-follow bead rip-cage-tsf2.2"; }
if [[ "$a9_ok" == "true" ]]; then pass 9 "allowlist promote --from-observed message names ADR-029 + rip-cage-tsf2.2"
else fail 9 "allowlist promote --from-observed message content" "$a9_reason -- stderr: $(cat "$a9_err")"; fi
rm -f "$a9_err"
teardown_sandbox

# ---------------------------------------------------------------------------
# A10: allowlist promote --from-observed never mutates .rip-cage.yaml (no silent partial apply)
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
a10_before=$(cat "${WS}/.rip-cage.yaml")

run_rc allowlist promote --from-observed \
  --config-file "${WS}/.rip-cage.yaml" \
  --log-file "${WS}/.rip-cage/egress.log" >/dev/null 2>&1

a10_after=$(cat "${WS}/.rip-cage.yaml")
a10_ok=true a10_reason=""
[[ "$a10_before" != "$a10_after" ]] && a10_ok=false && a10_reason=".rip-cage.yaml was mutated by a retired flag (silent partial apply)"
if [[ "$a10_ok" == "true" ]]; then pass 10 "allowlist promote --from-observed never mutates .rip-cage.yaml"
else fail 10 "allowlist promote --from-observed no-mutation" "$a10_reason"; fi
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
