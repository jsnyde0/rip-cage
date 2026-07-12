#!/usr/bin/env bash
# tests/test-default-allowlist.sh -- host-only unit tests for the curated
# default egress allowlist content (rip-cage-o2h0, S7 of the msb migration
# epic rip-cage-tsf2).
#
# D4's seed allowlist (ADR-029): api.anthropic.com is the hard entry a
# basic `claude -p` turn requires; mcp-proxy.anthropic.com and the datadog
# telemetry intake are attempted-but-nonblocking (included for
# denial-log-noise-free defaults). Discovered + proven live in the
# rip-cage-1ujn spike (docs/2026-07-09-msb-spike-session-resume.md) and
# already used as the working net-rule set for real claude turns in
# tests/test-msb-claude-home-resume.sh's NET_RULES array (S3, xuy8) --
# this bead makes that same list the SHIPPED default, not a per-test
# hand-roll.
#
# Mechanism (data/config edit, not cli/up.sh): the curated hosts live ONLY
# in cli/lib/config.sh's _config_default_global_yaml() -- the exact same
# pattern the pre-existing mounts.denylist 16-pattern seed already uses
# (schema column default stays [] both places; the curated CONTENT is
# seeded into the auto-written global config.yaml on first `rc up` /
# `rc install`, via the EXISTING, unchanged _config_ensure_global_seeded
# call in cli/up.sh's cmd_up). No cli/up.sh edits in this bead.
#
# Coverage:
#   T1  _config_default_global_yaml() output contains the 3 curated hosts
#       under network.allowed_hosts, in the D4-documented order
#   T2  a genuinely fresh `rc up` auto-seeds a global config.yaml on disk
#       whose network.allowed_hosts contains exactly the 3 curated hosts
#   T3  _up_build_egress_config_json (the REAL S6 create-path translator,
#       unchanged) returns allowed_hosts == the curated 3-host array for a
#       workspace with NO project .rip-cage.yaml, once the global config has
#       been auto-seeded -- i.e. the real create path picks up the shipped
#       defaults, not a re-implementation of the same claim
#   T4  that JSON round-trips through the REAL _msb_flags_generate contract
#       (S2, unchanged) into --net-default deny + one --net-rule allow@
#       per curated host
#   T5  tight-allowlist guard: a host NOT in the curated set (example.com)
#       never appears in the generated --net-rule output when no project
#       override adds it -- the defaults are a tight seed, not allow-all
#
# Pure host-side function/file tests -- no docker/msb required. The LIVE
# effect-based proof (real claude turn + real zero-byte denial) is
# tests/test-default-allowlist-live.sh.

set -uo pipefail

unset RC_CONFIG_GLOBAL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

# The curated default -- single literal source of truth for this test file,
# independent of cli/lib/config.sh's own implementation (an expected-value
# literal, not a recomputation of what the code does).
EXPECTED_HOSTS_JSON='["api.anthropic.com","mcp-proxy.anthropic.com","http-intake.logs.us5.datadoghq.com"]'

TEST_HOME=""
cleanup() { [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"; }
trap cleanup EXIT

setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-default-allowlist-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
}

echo ""
echo "=== T1: _config_default_global_yaml() seeds the 3 curated D4 hosts ==="
setup_sandbox
T1_YAML=$(bash -c "source '${RC}' 2>/dev/null; _config_default_global_yaml")
if echo "$T1_YAML" | grep -q "api.anthropic.com" \
  && echo "$T1_YAML" | grep -q "mcp-proxy.anthropic.com" \
  && echo "$T1_YAML" | grep -q "http-intake.logs.us5.datadoghq.com"; then
  pass "T1: default global yaml contains all 3 curated D4 hosts"
else
  fail "T1: missing one or more curated hosts in default global yaml" "$T1_YAML"
fi
cleanup

echo ""
echo "=== T2: a fresh 'rc up' auto-seeds config.yaml with the curated hosts on disk ==="
setup_sandbox
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$TEST_WS" \
  bash "$RC" up --dry-run "$TEST_WS" >/dev/null 2>&1 || true
T2_CFG="${TEST_HOME}/.config/rip-cage/config.yaml"
if [[ -f "$T2_CFG" ]] && grep -q "api.anthropic.com" "$T2_CFG" \
  && grep -q "mcp-proxy.anthropic.com" "$T2_CFG" \
  && grep -q "http-intake.logs.us5.datadoghq.com" "$T2_CFG"; then
  pass "T2: fresh rc up auto-seeds global config.yaml with the curated hosts"
else
  fail "T2: auto-seeded config.yaml missing curated hosts" "$(cat "$T2_CFG" 2>&1)"
fi
cleanup

echo ""
echo "=== T3: the REAL create-path translator (_up_build_egress_config_json) returns the curated defaults ==="
setup_sandbox
# Fresh state, no project .rip-cage.yaml -- exercise the exact rc-up sequence
# (auto-seed, THEN build the egress config), never hand-rolling the JSON.
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$TEST_WS" \
  bash "$RC" up --dry-run "$TEST_WS" >/dev/null 2>&1 || true
T3_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _up_build_egress_config_json '${TEST_WS}'" 2>/tmp/t3-default-allowlist.err)
T3_RC=$?
if [[ "$T3_RC" -eq 0 ]]; then
  T3_HOSTS=$(jq -c '.allowed_hosts' <<<"$T3_OUT")
  if [[ "$T3_HOSTS" == "$EXPECTED_HOSTS_JSON" ]]; then
    pass "T3: _up_build_egress_config_json returns exactly the curated defaults for an unconfigured workspace"
  else
    fail "T3: unexpected allowed_hosts" "got=$T3_HOSTS want=$EXPECTED_HOSTS_JSON"
  fi
else
  fail "T3: _up_build_egress_config_json failed" "$(cat /tmp/t3-default-allowlist.err)"
fi
cleanup

echo ""
echo "=== T4: the curated defaults round-trip through the REAL _msb_flags_generate contract ==="
setup_sandbox
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$TEST_WS" \
  bash "$RC" up --dry-run "$TEST_WS" >/dev/null 2>&1 || true
T4_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '${RC}' 2>/dev/null
  cfg=\$(_up_build_egress_config_json '${TEST_WS}') || exit 1
  _msb_flags_generate \"\$cfg\"
" 2>/tmp/t4-default-allowlist.err)
T4_RC=$?
if [[ "$T4_RC" -eq 0 ]] \
  && echo "$T4_OUT" | grep -qF -- "--net-default" \
  && echo "$T4_OUT" | grep -qF "allow@api.anthropic.com" \
  && echo "$T4_OUT" | grep -qF "allow@mcp-proxy.anthropic.com" \
  && echo "$T4_OUT" | grep -qF "allow@http-intake.logs.us5.datadoghq.com"; then
  pass "T4: curated defaults round-trip into --net-rule allow@ flags for all 3 hosts"
else
  fail "T4: round-trip through _msb_flags_generate failed" "rc=$T4_RC out='$T4_OUT' err=$(cat /tmp/t4-default-allowlist.err)"
fi
cleanup

echo ""
echo "=== T5: tight-allowlist guard -- an out-of-default host never appears in generated flags ==="
setup_sandbox
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$TEST_WS" \
  bash "$RC" up --dry-run "$TEST_WS" >/dev/null 2>&1 || true
T5_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '${RC}' 2>/dev/null
  cfg=\$(_up_build_egress_config_json '${TEST_WS}') || exit 1
  _msb_flags_generate \"\$cfg\"
" 2>/tmp/t5-default-allowlist.err)
if ! echo "$T5_OUT" | grep -qF "example.com"; then
  pass "T5: an out-of-default host (example.com) does not appear anywhere in the generated flags -- defaults are a tight seed, not allow-all"
else
  fail "T5: unexpected host in generated flags" "$T5_OUT"
fi
cleanup

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "=== test-default-allowlist.sh: all ${TOTAL} tests passed ==="
  exit 0
else
  echo "=== test-default-allowlist.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
