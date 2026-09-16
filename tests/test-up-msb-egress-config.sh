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
echo "=== T5/T5b/T6/T6b: RETIRED -- there is no second egress source (rip-cage-ely4.11) ==="
# All four asserted the manifest half of this builder: a composed tool declared
# egress: hosts, and those hosts had to materialize in allowed_hosts unioned
# with the config's own list (T5/T5b), including the floor manifest an
# unconfigured cage was seeded with (T6) and the defensive branch for a missing
# manifest file (T6b).
#
# The tools manifest retired whole (ADR-031 D4), so the union has nothing left
# to union: the cage config's network.allow list is the only source, and what an
# operator reads in the config is exactly what msb enforces. A tool that needs a
# host says so in the project's config like every other host.
#
# What survives and still runs above: T3 (the builder's own empty output) and T4
# (that output round-tripping through the real _msb_flags_generate) -- the two
# cases that were about the BUILDER rather than about the manifest feeding it.

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
