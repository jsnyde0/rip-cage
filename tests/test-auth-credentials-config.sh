#!/usr/bin/env bash
# tests/test-auth-credentials-config.sh -- host-side unit tests for the
# auth.credentials .rip-cage.yaml config surface (rip-cage-rj68, S6 Fold a:
# "the .rip-cage.yaml config surface that declares credential->host
# bindings"). The old manifest MEDIATOR archetype that used to carry this
# was deleted by ADR-029 D2; no on-disk field currently encodes these
# bindings until this change.
#
# Schema: auth.credentials is a union-default list (v1 name: additive_list) of
#   {source_env: "ENV_NAME", hosts: ["host1", "host2", ...]}
# objects -- deliberately isomorphic to cli/lib/msb_flags.sh's
# `credentials` input-contract field (S2, rip-cage-kl4r, APPROVED as-is
# per the 2026-07-12 Fable fold) so the real-config -> contract translation
# this bead also builds (cli/up.sh's _up_build_egress_config_json) is a
# straight pass-through of this field, not a reshaping step.
#
# Coverage:
#   T1  a project-layer auth.credentials entry appears in the effective config
#   T2  global + project auth.credentials both contribute (additive union,
#       D2 per-field-type merge rule already generic over object elements)
#   T3  a credential entry missing 'source_env' aborts loud (fail-closed,
#       ADR-001 -- mirrors the auth.per_tool unknown-key precedent already
#       in this file)
#   T4  a credential entry missing 'hosts' aborts loud
#   T5  a credential entry with hosts present but empty aborts loud (an
#       env var bound to zero hosts is a no-op the operator almost
#       certainly did not intend -- fail loud rather than silently drop)
#   T6  both files absent -> auth.credentials defaults to [] (D5 regression
#       contract: substrate-only, no behavior change when unconfigured)
#
# Pure host-side loader logic -- no docker/msb required.

set -uo pipefail

unset RC_CONFIG_GLOBAL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

# shellcheck source=/dev/null
source "$RC" 2>/dev/null

TEST_HOME=""
cleanup() { [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"; }
trap cleanup EXIT

setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-auth-creds-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
}

# ---------------------------------------------------------------------------
# T1: project-layer auth.credentials appears in the effective config.
# ---------------------------------------------------------------------------
echo ""
echo "=== T1: project auth.credentials in effective config ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
auth:
  credentials:
    - source_env: GH_TOKEN
      hosts: [github.com, api.github.com]
EOF
T1_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _load_effective_config '${TEST_WS}'" 2>/tmp/t1-auth-creds.err)
T1_RC=$?
if [[ "$T1_RC" -eq 0 ]]; then
  T1_CREDS=$(jq -c '.config.auth.credentials' <<<"$T1_OUT")
  if [[ "$T1_CREDS" == '[{"source_env":"GH_TOKEN","hosts":["github.com","api.github.com"]}]' ]]; then
    pass "T1: project auth.credentials entry present, byte-exact in effective config"
  else
    fail "T1: unexpected effective auth.credentials" "$T1_CREDS"
  fi
else
  fail "T1: _load_effective_config failed" "$(cat /tmp/t1-auth-creds.err)"
fi
cleanup

# ---------------------------------------------------------------------------
# T2: global + project both contribute (additive union).
# ---------------------------------------------------------------------------
echo ""
echo "=== T2: global + project auth.credentials additive union ==="
setup_sandbox
cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'EOF'
version: 2
auth:
  credentials:
    - source_env: ANTHROPIC_API_KEY
      hosts: [api.anthropic.com]
EOF
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
auth:
  credentials:
    - source_env: GH_TOKEN
      hosts: [github.com]
EOF
T2_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _load_effective_config '${TEST_WS}'" 2>/tmp/t2-auth-creds.err)
T2_RC=$?
if [[ "$T2_RC" -eq 0 ]]; then
  T2_COUNT=$(jq '.config.auth.credentials | length' <<<"$T2_OUT")
  T2_HAS_GH=$(jq '[.config.auth.credentials[] | select(.source_env == "GH_TOKEN")] | length' <<<"$T2_OUT")
  T2_HAS_ANTHROPIC=$(jq '[.config.auth.credentials[] | select(.source_env == "ANTHROPIC_API_KEY")] | length' <<<"$T2_OUT")
  if [[ "$T2_COUNT" -eq 2 && "$T2_HAS_GH" -eq 1 && "$T2_HAS_ANTHROPIC" -eq 1 ]]; then
    pass "T2: both global and project credentials present (additive union)"
  else
    fail "T2: expected 2 merged entries" "count=$T2_COUNT gh=$T2_HAS_GH anthropic=$T2_HAS_ANTHROPIC"
  fi
else
  fail "T2: _load_effective_config failed" "$(cat /tmp/t2-auth-creds.err)"
fi
cleanup

# ---------------------------------------------------------------------------
# T3: missing source_env aborts loud.
# ---------------------------------------------------------------------------
echo ""
echo "=== T3: credential entry missing source_env aborts loud ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
auth:
  credentials:
    - hosts: [github.com]
EOF
T3_ERR_FILE=/tmp/t3-auth-creds.err
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _load_effective_config '${TEST_WS}'" >/dev/null 2>"$T3_ERR_FILE"
T3_RC=$?
if [[ "$T3_RC" -ne 0 ]] && grep -qi "source_env" "$T3_ERR_FILE"; then
  pass "T3: missing source_env aborts loud, naming the field"
else
  fail "T3: expected non-zero exit + source_env in stderr" "rc=$T3_RC stderr=$(cat "$T3_ERR_FILE")"
fi
cleanup

# ---------------------------------------------------------------------------
# T4: missing hosts aborts loud.
# ---------------------------------------------------------------------------
echo ""
echo "=== T4: credential entry missing hosts aborts loud ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
auth:
  credentials:
    - source_env: GH_TOKEN
EOF
T4_ERR_FILE=/tmp/t4-auth-creds.err
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _load_effective_config '${TEST_WS}'" >/dev/null 2>"$T4_ERR_FILE"
T4_RC=$?
if [[ "$T4_RC" -ne 0 ]] && grep -qi "hosts" "$T4_ERR_FILE"; then
  pass "T4: missing hosts aborts loud, naming the field"
else
  fail "T4: expected non-zero exit + hosts in stderr" "rc=$T4_RC stderr=$(cat "$T4_ERR_FILE")"
fi
cleanup

# ---------------------------------------------------------------------------
# T5: empty hosts array aborts loud.
# ---------------------------------------------------------------------------
echo ""
echo "=== T5: credential entry with empty hosts array aborts loud ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
auth:
  credentials:
    - source_env: GH_TOKEN
      hosts: []
EOF
T5_ERR_FILE=/tmp/t5-auth-creds.err
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _load_effective_config '${TEST_WS}'" >/dev/null 2>"$T5_ERR_FILE"
T5_RC=$?
if [[ "$T5_RC" -ne 0 ]] && grep -qi "hosts" "$T5_ERR_FILE"; then
  pass "T5: empty hosts array aborts loud"
else
  fail "T5: expected non-zero exit + hosts in stderr" "rc=$T5_RC stderr=$(cat "$T5_ERR_FILE")"
fi
cleanup

# ---------------------------------------------------------------------------
# T6: both files absent -> defaults to [] (D5 regression contract).
# ---------------------------------------------------------------------------
echo ""
echo "=== T6: both files absent -> auth.credentials defaults to [] ==="
setup_sandbox
T6_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _load_effective_config '${TEST_WS}'" 2>/tmp/t6-auth-creds.err)
T6_RC=$?
if [[ "$T6_RC" -eq 0 ]]; then
  T6_CREDS=$(jq -c '.config.auth.credentials' <<<"$T6_OUT")
  if [[ "$T6_CREDS" == "[]" ]]; then
    pass "T6: auth.credentials defaults to [] with no config files"
  else
    fail "T6: expected []" "$T6_CREDS"
  fi
else
  fail "T6: _load_effective_config failed" "$(cat /tmp/t6-auth-creds.err)"
fi
cleanup

# ---------------------------------------------------------------------------
# T7: the guest-env bridge fields (target_env, source_file) survive the
# union-default list merge intact into the effective config (rip-cage-9dlw) — the
# per-credential objects are merged wholesale, so nested fields the generator
# consumes downstream must not be stripped.
# ---------------------------------------------------------------------------
echo ""
echo "=== T7: target_env + source_file survive into effective config ==="
setup_sandbox
cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'EOF'
version: 2
auth:
  credentials:
    - source_env: CCTOK
      source_file: /host/path/to/claude-setup-token
      hosts: [api.anthropic.com]
      target_env: [CLAUDE_CODE_OAUTH_TOKEN]
EOF
T7_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _load_effective_config '${TEST_WS}'" 2>/tmp/t7-auth-creds.err)
T7_RC=$?
if [[ "$T7_RC" -eq 0 ]]; then
  T7_SF=$(jq -r '.config.auth.credentials[0].source_file' <<<"$T7_OUT")
  T7_TE=$(jq -c '.config.auth.credentials[0].target_env' <<<"$T7_OUT")
  if [[ "$T7_SF" == "/host/path/to/claude-setup-token" && "$T7_TE" == '["CLAUDE_CODE_OAUTH_TOKEN"]' ]]; then
    pass "T7: source_file and target_env preserved through the merge"
  else
    fail "T7: bridge fields not preserved" "source_file='$T7_SF' target_env='$T7_TE'"
  fi
else
  fail "T7: _load_effective_config failed" "$(cat /tmp/t7-auth-creds.err)"
fi
cleanup

# ---------------------------------------------------------------------------
# T8: target_env on a MULTI-host credential aborts loud on the config surface
# (rip-cage-9dlw) — a fixed guest var carries a single placeholder, so a
# multi-host bridge is ambiguous. Caught at config-load, before any cage boot.
# ---------------------------------------------------------------------------
echo ""
echo "=== T8: target_env + multi-host credential aborts loud ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
auth:
  credentials:
    - source_env: CCTOK
      hosts: [api.anthropic.com, mcp-proxy.anthropic.com]
      target_env: [CLAUDE_CODE_OAUTH_TOKEN]
EOF
T8_ERR_FILE=/tmp/t8-auth-creds.err
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _load_effective_config '${TEST_WS}'" >/dev/null 2>"$T8_ERR_FILE"
T8_RC=$?
if [[ "$T8_RC" -ne 0 ]] && grep -qi "target_env" "$T8_ERR_FILE"; then
  pass "T8: target_env + multi-host aborts loud, naming target_env"
else
  fail "T8: expected non-zero exit + target_env in stderr" "rc=$T8_RC stderr=$(cat "$T8_ERR_FILE")"
fi
cleanup

echo ""
echo "=== test-auth-credentials-config.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
