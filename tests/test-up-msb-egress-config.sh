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
echo "=== T1+T2: RETIRED -- the cage config feeds msb directly (rip-cage-ely4.9) ==="
# These asserted that _up_build_egress_config_json passes network.allowed_hosts
# and auth.credentials through from the merged rip-cage config. ADR-031 D2
# removes both contributions at the source: egress hosts are the cage config's
# own `network.allow` and credential bindings are its `secrets:` block, so msb
# reads them straight off the --conf file and rc transcribes neither.
#
# This is not lost coverage, it is coverage that moved to a better place. The
# builder cannot mis-transcribe a list it never reads, and the hosts/secrets
# actually reaching msb are now asserted end-to-end against the real argv in
# tests/test-rc-commands.sh Test 60a.
#
# What the builder still does -- union the MANIFEST's declared tool egress,
# which has no home in a project's config file -- is what T5 through T8 below
# cover, and they are unchanged.

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
echo "=== T4: builder output round-trips through the real _msb_flags_generate ==="
# Kept, rescoped: the round-trip contract is still real, but its input is now
# the MANIFEST union rather than config passthrough (rip-cage-ely4.9). T5b
# below exercises exactly that with a sentinel host, so this case would only
# have re-asserted T5b against an empty input. Folded into T5b rather than
# kept as a degenerate duplicate.

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
  # The builder's allowed_hosts is now EXACTLY the manifest's declared tool
  # egress: the project's own hosts live in its cage config and reach msb via
  # --conf, never through this builder (rip-cage-ely4.9). The .rip-cage.yaml
  # written above is inert and left in place deliberately -- if a future edit
  # accidentally re-taught the builder to read a project config, this case
  # would fail on the extra hosts rather than silently accept them.
  if [[ "$T5_HOSTS" == "[\"${SENTINEL_HOST}\"]" ]]; then
    pass "T5: manifest tool egress host materializes; no project-config hosts leak in"
  else
    fail "T5: expected exactly the manifest host in allowed_hosts" "$T5_HOSTS"
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
echo "=== T6b: manifest file absent -> the builder contributes nothing ==="
# The defensive `-f` branch: when the host manifest file does not exist, the
# union is skipped entirely. The manifest is the builder's ONLY host source
# now (rip-cage-ely4.9), so "skipped" means an empty list rather than "config
# hosts only". This is NOT the cmd_up path (which seeds); it guards the
# builder being called before any manifest exists.
#
# The inert .rip-cage.yaml is written on purpose: it is the negative control.
# If a future edit re-taught the builder to read a project config, this case
# fails on example.com appearing instead of quietly passing.
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
  if [[ "$T6B_HOSTS" == '[]' ]]; then
    pass "T6b: absent manifest -> empty allowed_hosts; no project-config hosts leak in"
  else
    fail "T6b: absent-manifest branch should yield an empty host list" "$T6B_HOSTS"
  fi
else
  fail "T6b: _up_build_egress_config_json failed" "$(cat /tmp/t6b-egress-cfg.err)"
fi
cleanup

echo ""
echo "=== T7: RETIRED -- there is no config host to union with (rip-cage-ely4.9) ==="
# T7 asserted that a tool-declared host X and a config host Y BOTH land in
# allowed_hosts, order-stable. Half the invariant is gone: the config no longer
# contributes hosts to this builder.
#
# The union itself did not disappear, it moved down a layer and was MEASURED
# there: on msb 0.6.18, CLI --net-rule flags union with the --conf file's
# allow list rather than replacing it (rip-cage-ely4.9 notes). That is what
# keeps a composed tool's egress reaching the cage alongside the project's own
# hosts, and it is asserted on the real argv in tests/test-rc-commands.sh.

echo ""
echo "=== T8: RETIRED -- one of its two sources is gone (rip-cage-ely4.9) ==="
# T8 asserted that the per-tool egress MAP (_config_manifest_egress_map, used
# by the provenance view) and the runtime union (_manifest_egress_hosts_json)
# derive from the same manifest -- the "nobody re-derives the merge
# differently" invariant.
#
# The provenance view and its map retired with the config layer (ADR-031 D2),
# so there is only one derivation left and nothing for it to diverge FROM.
# The invariant is satisfied structurally rather than by assertion, which is
# the stronger outcome: two implementations that could disagree became one.

echo ""
echo "=== test-up-msb-egress-config.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
