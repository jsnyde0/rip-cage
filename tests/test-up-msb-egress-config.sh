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
#   T5  manifest tool egress: hosts union into allowed_hosts (rip-cage-tsf2.8:
#       a composed tool declaring egress hosts must materialize them, unioned
#       with config network.allowed_hosts, order-stable)
#   T5b sentinel host materializes as an actual --net-rule allow@<host> through
#       the real _msb_flags_generate (closes the net-rule acceptance leg)
#   T6  unconfigured cage = seeded floor manifest + no config -> allowed_hosts
#       equals exactly the floor manifest's declared egress (Fable REVISE r1 F1:
#       the real unconfigured cage is NOT empty; cmd_up seeds the floor manifest)
#   T6b absent manifest file -> union skipped, config hosts pass through (the
#       defensive `-f` branch; not the cmd_up path)

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
version: 2
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
echo "=== T3: no config AND absent manifest -> empty (defensive branch, NOT the cmd_up path) ==="
# This is the genuinely-empty branch: no .rip-cage.yaml and no host tools.yaml
# (RC_MANIFEST_GLOBAL unset, none seeded here). It exercises the `-f` defensive
# guard, NOT the production unconfigured cage — cmd_up SEEDS the floor manifest
# before the builder runs, so a real unconfigured cage reaches the floor egress
# set (see T6). Kept as its own unit case; it does not model the cage contract.
setup_sandbox
T3_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _up_build_egress_config_json '${TEST_WS}'" 2>/tmp/t3-egress-cfg.err)
T3_RC=$?
if [[ "$T3_RC" -eq 0 ]]; then
  T3_EXPECT='{"allowed_hosts":[],"credentials":[]}'
  T3_GOT=$(jq -Sc '{allowed_hosts, credentials}' <<<"$T3_OUT")
  if [[ "$T3_GOT" == "$T3_EXPECT" ]]; then
    pass "T3: no config + absent manifest -> {allowed_hosts:[], credentials:[]} (defensive branch)"
  else
    fail "T3: unexpected output for absent-manifest branch" "$T3_GOT"
  fi
else
  fail "T3: _up_build_egress_config_json failed" "$(cat /tmp/t3-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== T4: output round-trips through the real _msb_flags_generate contract ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
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
echo "=== T5: manifest tool egress: hosts union into allowed_hosts (rip-cage-tsf2.8) ==="
# A composed tool declaring egress: hosts must have those hosts materialize in
# the builder's allowed_hosts, unioned with config network.allowed_hosts,
# order-stable (config hosts first, then manifest hosts not already present).
# Sentinel host is deliberately fake (never a real credential/host we depend on)
# and not on the IOC denylist, so it round-trips untouched.
setup_sandbox
SENTINEL_HOST="egress-sentinel.tsf28.test.invalid"
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [github.com, api.anthropic.com]
EOF
T5_MANIFEST="${TEST_HOME}/.config/rip-cage/tools.yaml"
cat > "$T5_MANIFEST" <<EOF
version: 1
tools:
  - name: sentinel-tool
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - ${SENTINEL_HOST}
    mounts: []
EOF
T5_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_MANIFEST_GLOBAL="$T5_MANIFEST" \
  bash -c "source '${RC}' 2>/dev/null; _up_build_egress_config_json '${TEST_WS}'" 2>/tmp/t5-egress-cfg.err)
T5_RC=$?
if [[ "$T5_RC" -eq 0 ]]; then
  T5_HOSTS=$(jq -c '.allowed_hosts' <<<"$T5_OUT")
  # Config hosts keep their order first; the single manifest host appends after.
  if [[ "$T5_HOSTS" == "[\"github.com\",\"api.anthropic.com\",\"${SENTINEL_HOST}\"]" ]]; then
    pass "T5: manifest tool egress host unions into allowed_hosts, order-stable"
  else
    fail "T5: manifest egress host did not materialize (or order churned)" "$T5_HOSTS"
  fi
else
  fail "T5: _up_build_egress_config_json failed" "$(cat /tmp/t5-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== T5b: sentinel host materializes as a --net-rule through the real generator ==="
# Closes the 'materializes as a --net-rule allow@<host>' acceptance leg at unit
# level: feed the builder's own output (which unioned the sentinel in) through
# the real _msb_flags_generate and assert the generator emits an allow rule for
# the sentinel — not merely that it appeared in the JSON.
setup_sandbox
SENTINEL_HOST="egress-sentinel.tsf28.test.invalid"
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [github.com]
EOF
T5B_MANIFEST="${TEST_HOME}/.config/rip-cage/tools.yaml"
cat > "$T5B_MANIFEST" <<EOF
version: 1
tools:
  - name: sentinel-tool
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - ${SENTINEL_HOST}
    mounts: []
EOF
T5B_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_MANIFEST_GLOBAL="$T5B_MANIFEST" \
  bash -c "
    source '${RC}' 2>/dev/null
    cfg=\$(_up_build_egress_config_json '${TEST_WS}') || exit 1
    _msb_flags_generate \"\$cfg\"
  " 2>/tmp/t5b-egress-cfg.err)
T5B_RC=$?
# The generator emits '--net-rule' and 'allow@<host>' on separate consecutive
# lines; assert both the rule flag and the sentinel allow token are present.
if [[ "$T5B_RC" -eq 0 ]] \
   && echo "$T5B_OUT" | grep -qF -- "--net-rule" \
   && echo "$T5B_OUT" | grep -qF "allow@${SENTINEL_HOST}"; then
  pass "T5b: manifest sentinel host emits a --net-rule allow@<sentinel> via _msb_flags_generate"
else
  fail "T5b: sentinel did not materialize as a --net-rule" "rc=$T5B_RC out='$T5B_OUT' err=$(cat /tmp/t5b-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== T6: unconfigured cage (seeded floor manifest, no config) -> floor egress reachable ==="
# F1 (Fable review REVISE r1): the REAL unconfigured cage is not empty. cmd_up
# seeds the floor manifest before the builder runs, so an unconfigured cage
# reaches exactly the floor manifest's declared egress and zero config hosts.
# Expected set is derived from _manifest_default_yaml (not hardcoded), so it
# tracks the floor tools automatically.
setup_sandbox
# Independent derivation of the floor egress set: raw default YAML -> yq unique.
FLOOR_HOSTS=$(HOME="$TEST_HOME" bash -c "source '${RC}' 2>/dev/null; _manifest_default_yaml" 2>/dev/null \
  | yq -o=json -I=0 '[.tools[].egress // [] | .[]] | unique' 2>/dev/null)
# No .rip-cage.yaml, no global config; seed the floor manifest exactly as cmd_up does.
T6_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '${RC}' 2>/dev/null
    _manifest_ensure_seeded >/dev/null 2>&1
    _up_build_egress_config_json '${TEST_WS}'
  " 2>/tmp/t6-egress-cfg.err)
T6_RC=$?
if [[ "$T6_RC" -eq 0 && -n "$FLOOR_HOSTS" && "$FLOOR_HOSTS" != '[]' ]]; then
  T6_GOT=$(jq -c 'sort' <<<"$(jq -c '.allowed_hosts' <<<"$T6_OUT")")
  T6_WANT=$(jq -c 'sort' <<<"$FLOOR_HOSTS")
  T6_CREDS=$(jq -c '.credentials' <<<"$T6_OUT")
  if [[ "$T6_GOT" == "$T6_WANT" && "$T6_CREDS" == '[]' ]]; then
    pass "T6: unconfigured cage reaches exactly the seeded floor manifest's declared egress (zero config hosts)"
  else
    fail "T6: unconfigured-cage egress != floor manifest egress" "got=$T6_GOT want=$T6_WANT creds=$T6_CREDS"
  fi
else
  fail "T6: _up_build_egress_config_json failed or empty floor set" "rc=$T6_RC floor='$FLOOR_HOSTS' $(cat /tmp/t6-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== T6b: manifest file absent -> union contributes nothing, config passthrough ==="
# The defensive `-f` branch: when the host manifest file does not exist, the
# union is skipped entirely and allowed_hosts is exactly the config hosts. This
# is NOT the cmd_up path (which seeds); it guards the builder being called
# before any manifest exists.
setup_sandbox
T6B_MANIFEST="${TEST_HOME}/.config/rip-cage/absent-tools.yaml"  # deliberately never created
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [example.com]
EOF
T6B_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_MANIFEST_GLOBAL="$T6B_MANIFEST" \
  bash -c "source '${RC}' 2>/dev/null; _up_build_egress_config_json '${TEST_WS}'" 2>/tmp/t6b-egress-cfg.err)
T6B_RC=$?
if [[ "$T6B_RC" -eq 0 ]]; then
  T6B_HOSTS=$(jq -c '.allowed_hosts' <<<"$T6B_OUT")
  if [[ "$T6B_HOSTS" == '["example.com"]' ]]; then
    pass "T6b: absent manifest file -> allowed_hosts == config hosts only (union skipped)"
  else
    fail "T6b: absent-manifest branch changed config passthrough" "$T6B_HOSTS"
  fi
else
  fail "T6b: _up_build_egress_config_json failed" "$(cat /tmp/t6b-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== T7: post-split runtime-invariant — tool egress X + config Y => allowed_hosts has BOTH, byte-stable (rip-cage-tsf2.10.5) ==="
# The loader-contract split (rip-cage-tsf2.10.5) added a SEPARATE manifest_egress
# field to _load_effective_config's output. This case pins that the RUNTIME
# egress builder is BEHAVIOR-UNCHANGED by that split: it still unions config
# network.allowed_hosts (Y) with the manifest tool egress (X) via
# _manifest_egress_hosts_json, and the loader's new manifest_egress field does
# NOT leak into the builder's output (no manifest_egress key; no double-union /
# duplicate host). Byte-stable with the pre-split T5 union shape [Y, X].
setup_sandbox
INV_X="post-split-x.tsf2105.test.invalid"
INV_Y="post-split-y.tsf2105.test.invalid"
cat > "${TEST_WS}/.rip-cage.yaml" <<EOF
version: 2
network:
  allowed_hosts: [${INV_Y}]
EOF
T7_MANIFEST="${TEST_HOME}/.config/rip-cage/tools.yaml"
cat > "$T7_MANIFEST" <<EOF
version: 1
tools:
  - name: inv-tool
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - ${INV_X}
    mounts: []
EOF
T7_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_MANIFEST_GLOBAL="$T7_MANIFEST" \
  bash -c "source '${RC}' 2>/dev/null; _up_build_egress_config_json '${TEST_WS}'" 2>/tmp/t7-egress-cfg.err)
T7_RC=$?
if [[ "$T7_RC" -eq 0 ]]; then
  T7_HOSTS=$(jq -c '.allowed_hosts' <<<"$T7_OUT")
  T7_HAS_ME_KEY=$(jq -r 'has("manifest_egress")' <<<"$T7_OUT")
  T7_NDUP=$(jq -r '.allowed_hosts | (length) - (unique | length)' <<<"$T7_OUT")
  T7_ok=true; T7_reason=""
  [[ "$T7_HOSTS" == "[\"${INV_Y}\",\"${INV_X}\"]" ]] || { T7_ok=false; T7_reason="allowed_hosts=$T7_HOSTS (want [Y,X])"; }
  [[ "$T7_HAS_ME_KEY" == "false" ]] || { T7_ok=false; T7_reason="${T7_reason:+$T7_reason; }builder output leaked manifest_egress key"; }
  [[ "$T7_NDUP" == "0" ]] || { T7_ok=false; T7_reason="${T7_reason:+$T7_reason; }duplicate hosts in union (${T7_NDUP})"; }
  if [[ "$T7_ok" == "true" ]]; then
    pass "T7: builder unchanged post-split — config Y ∪ manifest X, order-stable, no leaked field/dupes"
  else
    fail "T7: post-split runtime invariant regressed" "$T7_reason"
  fi
else
  fail "T7: _up_build_egress_config_json failed" "$(cat /tmp/t7-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== T8: _manifest_egress_hosts_json flattened union == union of _config_manifest_egress_map values (single-source consistency) ==="
# The view's per-tool map (_config_manifest_egress_map) and the runtime union
# (_manifest_egress_hosts_json) must derive from the SAME manifest source: the
# flattened, deduped union of the per-tool map's values must equal the runtime
# host list. This is the "nobody re-derives the merge differently" invariant.
setup_sandbox
T8_MANIFEST="${TEST_HOME}/.config/rip-cage/tools.yaml"
cat > "$T8_MANIFEST" <<'EOF'
version: 1
tools:
  - name: tool-a
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - a1.tsf2105.test.invalid
      - a2.tsf2105.test.invalid
    mounts: []
  - name: tool-b
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - b1.tsf2105.test.invalid
    mounts: []
EOF
T8_RUNTIME=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_MANIFEST_GLOBAL="$T8_MANIFEST" \
  bash -c "source '${RC}' 2>/dev/null; _manifest_egress_hosts_json" 2>/dev/null)
T8_MAP=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_MANIFEST_GLOBAL="$T8_MANIFEST" \
  bash -c "source '${RC}' 2>/dev/null; _config_manifest_egress_map" 2>/dev/null)
T8_MAP_FLAT=$(jq -c '[.[][]] | unique' <<<"$T8_MAP" 2>/dev/null)
T8_RUNTIME_SORTED=$(jq -c 'unique' <<<"$T8_RUNTIME" 2>/dev/null)
if [[ -n "$T8_MAP_FLAT" && "$T8_MAP_FLAT" == "$T8_RUNTIME_SORTED" ]]; then
  pass "T8: per-tool map flattens to the same host set the runtime union emits (single source)"
else
  fail "T8: view/runtime egress sources diverged" "map_flat=$T8_MAP_FLAT runtime=$T8_RUNTIME_SORTED"
fi
cleanup

echo ""
echo "=== test-up-msb-egress-config.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
