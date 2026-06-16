#!/usr/bin/env bash
# Host-side unit tests for the per-cage egress-rules file generation pipeline.
# (rip-cage-hhh.2 — config->rules pipeline)
#
# Coverage:
#   G1  baseline whitelist present when no network.* config
#   G2  IOC denylist floor present in generated file (known bad hosts)
#   G3  user allowed_hosts merged with baseline in generated file
#   G4  mode=observe emitted when config has network.mode=observe
#   G5  mode=block emitted when config has network.mode=block
#   G6  null network.mode (legacy) emits legacy-mode file (mode absent/null)
#   G7  writable_hosts NOT emitted in generated file (removed in rip-cage-ta1o.1)
#   G8  generated file is valid YAML parseable by python yaml/yq
#   G9  generation function is pure: same config in -> same file out (idempotent)
#   G10 IOC floor cannot be removed by user's allowed_hosts (floor always present)
#   G11 baseline hosts present even when user adds their own allowed_hosts
#   G12 IOC floor read from the passed rules file (not a hardcoded heredoc)
#   G13 dns_forward_to emitted iff network.dns.forward_to set (rip-cage-ta1o.2 DNS seam)
#
# Tests do NOT require docker — pure host-side function logic only.
# The function _generate_egress_rules_file takes effective config JSON on stdin
# or as $1 and emits YAML to stdout.

set -uo pipefail
# Note: -e intentionally omitted so individual test function failures don't abort the suite.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Source rc to get access to the generation function.
# RC has a sourced-vs-invoked guard; source it directly.
# shellcheck disable=SC1090
source "$RC"

# Helper: call _generate_egress_rules_file with a JSON config object.
# $1 = JSON string (the .config subtree from _load_effective_config)
# $2 = (optional) path to IOC rules file; defaults to ${REPO_ROOT}/egress-rules.yaml
# Echoes the generated YAML to stdout.
gen_rules() {
  local cfg_json="$1"
  local ioc_file="${2:-${REPO_ROOT}/egress-rules.yaml}"
  _generate_egress_rules_file "$cfg_json" "$ioc_file" 2>/dev/null || true
}

# Minimal empty-network config (no network.* set).
# Note: writable_hosts removed from all test configs (rip-cage-ta1o.1: write-gate deleted).
EMPTY_CFG='{"ssh":{"allowed_hosts":[],"allowed_keys":null},"network":{"allowed_hosts":[],"mode":null},"mounts":{"denylist":[]}}'

# Config with observe mode and some allowed_hosts.
OBSERVE_CFG='{"ssh":{"allowed_hosts":[],"allowed_keys":null},"network":{"allowed_hosts":["custom.example.com"],"mode":"observe"},"mounts":{"denylist":[]}}'

# Config with block mode (writable_hosts removed in rip-cage-ta1o.1).
BLOCK_CFG='{"ssh":{"allowed_hosts":[],"allowed_keys":null},"network":{"allowed_hosts":["api.example.com"],"mode":"block"},"mounts":{"denylist":[]}}'

# Config with null mode (legacy posture).
LEGACY_CFG='{"ssh":{"allowed_hosts":[],"allowed_keys":null},"network":{"allowed_hosts":[],"mode":null},"mounts":{"denylist":[]}}'

# Config with a DNS forward-to-specialist upstream set (rip-cage-ta1o.2).
DNS_FWD_CFG='{"ssh":{"allowed_hosts":[],"allowed_keys":null},"network":{"allowed_hosts":["api.example.com"],"mode":"block","dns":{"forward_to":"192.0.2.1:5353"}},"mounts":{"denylist":[]}}'

echo "=== test-egress-rules-gen.sh — per-cage egress rules generation ==="

# G1: baseline whitelist present when no network.* config
test_g1_baseline_whitelist_present() {
  local out
  out=$(gen_rules "$EMPTY_CFG")
  # Baseline must include at least one LLM provider API host and one package registry
  if echo "$out" | grep -q "api.anthropic.com" \
     && echo "$out" | grep -q "registry.npmjs.org"; then
    pass "G1 baseline whitelist present (api.anthropic.com, registry.npmjs.org)"
  else
    fail "G1 expected baseline whitelist hosts, got:
$out"
  fi
}

# G2: IOC denylist floor present (known-bad hosts from egress-rules.yaml class-b rules)
# Note: discord.com was removed from the IOC floor in rip-cage-ta1o.1 IOC audit
# (class-a path_prefix rules dropped; discord.com has legitimate uses, belongs in
# mediator-layer policy per egress-rules.yaml preamble). G2 uses class-b hosts
# that ARE still in the floor: webhook.site (OAST) and .ngrok.io (tunnels).
test_g2_ioc_floor_present() {
  local out
  out=$(gen_rules "$EMPTY_CFG")
  # IOC floor must contain at least one pure-exfil OAST host and one tunnel host
  if echo "$out" | grep -q "webhook.site" \
     && echo "$out" | grep -q "ngrok"; then
    pass "G2 IOC denylist floor present (webhook.site, ngrok tunnels)"
  else
    fail "G2 expected IOC denylist floor entries (webhook.site + ngrok), got:
$out"
  fi
}

# G3: user allowed_hosts merged with baseline in generated file
test_g3_user_allowed_hosts_merged() {
  local out
  out=$(gen_rules "$OBSERVE_CFG")
  # Both user host AND baseline host must be present
  if echo "$out" | grep -q "custom.example.com" \
     && echo "$out" | grep -q "api.anthropic.com"; then
    pass "G3 user allowed_hosts merged with baseline (custom.example.com + api.anthropic.com)"
  else
    fail "G3 expected both user host and baseline host, got:
$out"
  fi
}

# G4: mode=observe emitted when config has network.mode=observe
test_g4_mode_observe() {
  local out
  out=$(gen_rules "$OBSERVE_CFG")
  if echo "$out" | grep -q "mode.*observe" || echo "$out" | grep -q "^mode: observe"; then
    pass "G4 mode=observe emitted in generated file"
  else
    fail "G4 expected mode: observe in generated file, got:
$out"
  fi
}

# G5: mode=block emitted when config has network.mode=block
test_g5_mode_block() {
  local out
  out=$(gen_rules "$BLOCK_CFG")
  if echo "$out" | grep -q "mode.*block" || echo "$out" | grep -q "^mode: block"; then
    pass "G5 mode=block emitted in generated file"
  else
    fail "G5 expected mode: block in generated file, got:
$out"
  fi
}

# G6: null network.mode (legacy) emits legacy-mode compatible file
# The file must be parseable, have rules list, and mode should be null/absent
test_g6_legacy_null_mode() {
  local out
  out=$(gen_rules "$LEGACY_CFG")
  # File must have rules section (compatible with current rip_cage_egress.py)
  # and must NOT contain "mode: observe" or "mode: block"
  if echo "$out" | grep -q "^rules:" \
     && ! echo "$out" | grep -qE "^mode: (observe|block)"; then
    pass "G6 null network.mode emits legacy-compatible file (has rules, no new mode)"
  else
    fail "G6 expected legacy-compatible file (rules present, no mode: observe/block), got:
$out"
  fi
}

# G7: writable_hosts NOT emitted in generated file (rip-cage-ta1o.1: write-gate removed)
# The method-asymmetry axis (writable_hosts) was removed in rip-cage-ta1o.1.
# The generator must NOT emit a writable_hosts: section.
# api.example.com should still appear in allowed_hosts (it's in BLOCK_CFG.network.allowed_hosts).
test_g7_writable_hosts_not_emitted() {
  local out
  out=$(gen_rules "$BLOCK_CFG")
  if ! echo "$out" | grep -q "^writable_hosts:"; then
    pass "G7 writable_hosts NOT emitted in generated file (write-gate removed, rip-cage-ta1o.1)"
  else
    fail "G7 writable_hosts: section must NOT appear in generated file; found it in:
$out"
  fi
}

# G8: generated file is valid YAML (parseable by yq)
test_g8_valid_yaml() {
  local out exit_code
  out=$(gen_rules "$OBSERVE_CFG")
  exit_code=0
  echo "$out" | yq "." >/dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "G8 generated file is valid YAML (yq parse succeeds)"
  else
    fail "G8 generated file failed YAML parse (yq), output:
$out"
  fi
}

# G9: generation is idempotent (same config -> same output)
test_g9_idempotent() {
  local out1 out2
  out1=$(gen_rules "$BLOCK_CFG")
  out2=$(gen_rules "$BLOCK_CFG")
  if [[ "$out1" == "$out2" ]]; then
    pass "G9 generation is idempotent (same config -> same YAML)"
  else
    fail "G9 generation not idempotent: first run differs from second run"
  fi
}

# G10: IOC floor cannot be removed by user's allowed_hosts
# Even if a user adds webhook.site to allowed_hosts, the IOC denylist deny:true rule stays.
test_g10_ioc_floor_not_overridable() {
  # Construct config where user "allows" a known-IOC host
  local cfg_with_ioc
  cfg_with_ioc='{"network":{"allowed_hosts":["discord.com","webhook.site"],"mode":"block"},"mounts":{"denylist":[]}}'
  local out
  out=$(gen_rules "$cfg_with_ioc")
  # The IOC denylist deny:true rule for these hosts must still be present
  if echo "$out" | grep -q "webhook.site" \
     && echo "$out" | grep -q "deny: true"; then
    pass "G10 IOC floor present even when user adds IOC hosts to allowed_hosts"
  else
    fail "G10 expected IOC floor rules still present, got:
$out"
  fi
}

# G11: baseline hosts present even when user adds their own allowed_hosts
test_g11_baseline_preserved_with_user_hosts() {
  local out
  out=$(gen_rules "$BLOCK_CFG")
  # Baseline must still be present alongside user's api.example.com
  if echo "$out" | grep -q "api.example.com" \
     && echo "$out" | grep -q "api.anthropic.com" \
     && echo "$out" | grep -q "pypi.org"; then
    pass "G11 baseline preserved alongside user-added allowed_hosts"
  else
    fail "G11 expected baseline (api.anthropic.com, pypi.org) + user host (api.example.com), got:
$out"
  fi
}

# G12: IOC floor is read from the passed rules file, not a hardcoded duplicate.
# Write a temp fixture egress-rules.yaml containing a unique canary rule, pass it
# as the second arg, and assert the canary appears in the output. This proves the
# function reads from the passed file path without touching production config.
test_g12_rules_read_from_canonical_egress_rules_yaml() {
  local tmp_dir out
  tmp_dir=$(mktemp -d)
  # Write a minimal egress-rules.yaml with one canary rule to the temp dir.
  cat > "${tmp_dir}/egress-rules.yaml" <<'YAML'
version: 1
default: allow
rules:
  - id: g12-canary-rule
    deny: true
    match:
      host: "canary.test.invalid"
    reason: "G12 TDD fixture canary — unique host to verify read-from-passed-file path"
    category: test-only
YAML
  out=$(gen_rules "$EMPTY_CFG" "${tmp_dir}/egress-rules.yaml")
  rm -rf "$tmp_dir"
  if echo "$out" | grep -q "canary.test.invalid"; then
    pass "G12 IOC floor is read from passed rules file (canary rule present in output)"
  else
    fail "G12 expected canary.test.invalid from temp fixture; rules may come from hardcoded heredoc or wrong path"
  fi
}

# G13: dns_forward_to emitted when network.dns.forward_to is set; absent otherwise
# (rip-cage-ta1o.2: DNS forward-to-specialist seam). Verifies the rc -> egress-rules.yaml
# generation path that test_dns_seam.py's sidecar-read tests cannot exercise.
test_g13a_dns_forward_to_emitted_when_set() {
  local out
  out=$(gen_rules "$DNS_FWD_CFG")
  if echo "$out" | grep -q "^dns_forward_to:" && echo "$out" | grep -q "192.0.2.1:5353"; then
    pass "G13a dns_forward_to emitted with configured upstream when network.dns.forward_to set"
  else
    fail "G13a expected 'dns_forward_to: 192.0.2.1:5353' in generated file; got:
$out"
  fi
}

test_g13b_dns_forward_to_absent_when_unset() {
  local out
  out=$(gen_rules "$BLOCK_CFG")
  if ! echo "$out" | grep -q "^dns_forward_to:"; then
    pass "G13b dns_forward_to NOT emitted when network.dns.forward_to absent (sidecar defaults to 8.8.8.8)"
  else
    fail "G13b dns_forward_to: must NOT appear when forward_to is unset; found it in:
$out"
  fi
}

# Run all tests
test_g1_baseline_whitelist_present
test_g2_ioc_floor_present
test_g3_user_allowed_hosts_merged
test_g4_mode_observe
test_g5_mode_block
test_g6_legacy_null_mode
test_g7_writable_hosts_not_emitted
test_g8_valid_yaml
test_g9_idempotent
test_g10_ioc_floor_not_overridable
test_g11_baseline_preserved_with_user_hosts
test_g12_rules_read_from_canonical_egress_rules_yaml
test_g13a_dns_forward_to_emitted_when_set
test_g13b_dns_forward_to_absent_when_unset

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
