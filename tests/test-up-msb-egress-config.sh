#!/usr/bin/env bash
# tests/test-up-msb-egress-config.sh -- unit tests for
# _up_build_egress_config_json (cli/up.sh, rip-cage-rj68 S6): translates the
# effective .rip-cage.yaml config (network.allowed_hosts + the NEW
# auth.credentials Fold-a surface, tests/test-auth-credentials-config.sh)
# into the JSON contract cli/lib/msb_flags.sh's _msb_flags_generate expects
# (S2, rip-cage-kl4r, APPROVED as-is per the 2026-07-12 Fable fold).
#
# Pure host-side function test -- no docker/msb required.
#
# Coverage:
#   T1  network.allowed_hosts -> allowed_hosts (straight passthrough)
#   T2  auth.credentials -> credentials (straight passthrough — the schema
#       was deliberately made isomorphic to the contract, Fold a design note)
#   T3  no config files present -> {"allowed_hosts":[],"credentials":[]}
#       (D5 regression contract: substrate-only, no behavior change when
#       unconfigured)
#   T4  output round-trips through _msb_flags_generate without error (proves
#       the translator's output is actually well-formed against the real
#       contract, not merely shaped like it)

set -uo pipefail

unset RC_CONFIG_GLOBAL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

TEST_HOME=""
cleanup() { [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"; }
trap cleanup EXIT

setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-egress-cfg-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
}

echo ""
echo "=== T1+T2: allowed_hosts + credentials passthrough ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 1
network:
  allowed_hosts: [github.com, api.anthropic.com]
auth:
  credentials:
    - source_env: GH_TOKEN
      hosts: [github.com]
EOF
T1_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _up_build_egress_config_json '${TEST_WS}'" 2>/tmp/t1-egress-cfg.err)
T1_RC=$?
if [[ "$T1_RC" -eq 0 ]]; then
  T1_HOSTS=$(jq -c '.allowed_hosts' <<<"$T1_OUT")
  T1_CREDS=$(jq -c '.credentials' <<<"$T1_OUT")
  if [[ "$T1_HOSTS" == '["github.com","api.anthropic.com"]' ]]; then
    pass "T1: allowed_hosts translated straight through"
  else
    fail "T1: unexpected allowed_hosts" "$T1_HOSTS"
  fi
  if [[ "$T1_CREDS" == '[{"source_env":"GH_TOKEN","hosts":["github.com"]}]' ]]; then
    pass "T2: credentials translated straight through"
  else
    fail "T2: unexpected credentials" "$T1_CREDS"
  fi
else
  fail "T1/T2: _up_build_egress_config_json failed" "$(cat /tmp/t1-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== T3: no config files -> empty allowed_hosts + credentials ==="
setup_sandbox
T3_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _up_build_egress_config_json '${TEST_WS}'" 2>/tmp/t3-egress-cfg.err)
T3_RC=$?
if [[ "$T3_RC" -eq 0 ]]; then
  T3_EXPECT='{"allowed_hosts":[],"credentials":[]}'
  T3_GOT=$(jq -Sc '{allowed_hosts, credentials}' <<<"$T3_OUT")
  if [[ "$T3_GOT" == "$T3_EXPECT" ]]; then
    pass "T3: empty config -> {allowed_hosts:[], credentials:[]}"
  else
    fail "T3: unexpected output for unconfigured workspace" "$T3_GOT"
  fi
else
  fail "T3: _up_build_egress_config_json failed" "$(cat /tmp/t3-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== T4: output round-trips through the real _msb_flags_generate contract ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 1
network:
  allowed_hosts: [example.com]
auth:
  credentials:
    - source_env: T4_TOKEN
      hosts: [example.com]
EOF
T4_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '${RC}' 2>/dev/null
  cfg=\$(_up_build_egress_config_json '${TEST_WS}') || exit 1
  _msb_flags_generate \"\$cfg\"
" 2>/tmp/t4-egress-cfg.err)
T4_RC=$?
if [[ "$T4_RC" -eq 0 ]] && echo "$T4_OUT" | grep -qF -- "--net-rule" && echo "$T4_OUT" | grep -qF "allow@example.com"; then
  pass "T4: translator output round-trips through _msb_flags_generate and yields the expected net-rule"
else
  fail "T4: round-trip through _msb_flags_generate failed" "rc=$T4_RC out='$T4_OUT' err=$(cat /tmp/t4-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== test-up-msb-egress-config.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
