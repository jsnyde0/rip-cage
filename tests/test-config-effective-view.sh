#!/usr/bin/env bash
# tests/test-config-effective-view.sh -- loader-contract tests for the
# manifest_egress provenance split (rip-cage-tsf2.10.5, ADR-021 D4).
#
# The effective-config loader (_load_effective_config, cli/lib/config.sh) gains
# a SEPARATE top-level `manifest_egress` field (per-tool attribution) plus a
# `manifest_egress_source` field ("applied"|"pending"|"none") sourced via the
# dual-source pattern (applied snapshot when a target cage is in scope, else the
# current host manifest labeled pending). manifest_egress is NEVER folded into
# .config.network.allowed_hosts — provenance for config fields is unchanged.
#
# Pure host-side function tests -- no docker/msb required. Sandboxed via
# tests/_host-sandbox-lib.sh through tests/run-one.sh / tests/run-host.sh.
#
# Coverage:
#   T1  no cage in scope + manifest fixture (one tool w/ egress, one w/o)
#       -> manifest_egress per-tool attribution, source "pending"
#   T2  no manifest file -> manifest_egress {}, source "none"
#   T3  manifest host NEVER folded into .config.network.allowed_hosts (separation)
#   T4  cage in scope w/ applied snapshot carrying manifest_egress -> source
#       "applied", content from the snapshot NOT the (mutated) current manifest
#   T5  old-format applied state (no manifest_egress record) -> graceful
#       fallback to pending, no crash
#   T6  rc config show --json includes both fields; text mode renders section
#   T7  rc allowlist show --effective separates config vs manifest hosts
#   T8  rc reload --dry-run on a manifest-drifted cage -> requires-rebuild
#       informational line, reload eligibility UNAFFECTED (exit 0)
#   T9  manifest egress change does NOT surface in _up_eligible_drift_paths
#   T10 doctor fix-hint classifier: denied domain already reachable (applied
#       manifest egress) => not suggested for allowlist add; pending manifest
#       egress => requires-rebuild; unknown => add

set -uo pipefail

unset RC_CONFIG_GLOBAL
unset RC_MANIFEST_GLOBAL

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
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-eff-view-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
}

# Run a snippet with the sandbox HOME/XDG, no RC_MANIFEST_GLOBAL unless the
# caller exports one. `source rc` exposes the functions without dispatch.
in_sandbox() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}' 2>/dev/null; $1"
}

# ---------------------------------------------------------------------------
echo ""
echo "=== T1: no cage in scope + manifest fixture -> per-tool manifest_egress, source pending ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [config-host.test.invalid]
EOF
cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'EOF'
version: 1
tools:
  - name: tool-with-egress
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - egress-a.test.invalid
    mounts: []
  - name: tool-without-egress
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts: []
EOF
T1_OUT=$(in_sandbox "_load_effective_config '${TEST_WS}'" 2>/tmp/t1-eff-view.err)
T1_RC=$?
if [[ "$T1_RC" -eq 0 ]]; then
  T1_ME=$(jq -c '.manifest_egress' <<<"$T1_OUT")
  T1_SRC=$(jq -r '.manifest_egress_source' <<<"$T1_OUT")
  if [[ "$T1_ME" == '{"tool-with-egress":["egress-a.test.invalid"]}' ]]; then
    pass "T1: manifest_egress carries per-tool attribution (only tools w/ egress)"
  else
    fail "T1: unexpected manifest_egress map" "$T1_ME"
  fi
  if [[ "$T1_SRC" == "pending" ]]; then
    pass "T1: manifest_egress_source == pending (no cage in scope)"
  else
    fail "T1: unexpected manifest_egress_source" "$T1_SRC"
  fi
else
  fail "T1: _load_effective_config failed" "$(cat /tmp/t1-eff-view.err)"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T2: no manifest file -> manifest_egress {}, source none ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [config-host.test.invalid]
EOF
# Deliberately NO tools.yaml under the sandbox XDG path.
T2_OUT=$(in_sandbox "_load_effective_config '${TEST_WS}'" 2>/tmp/t2-eff-view.err)
T2_RC=$?
if [[ "$T2_RC" -eq 0 ]]; then
  T2_ME=$(jq -c '.manifest_egress' <<<"$T2_OUT")
  T2_SRC=$(jq -r '.manifest_egress_source' <<<"$T2_OUT")
  if [[ "$T2_ME" == '{}' && "$T2_SRC" == "none" ]]; then
    pass "T2: absent manifest -> manifest_egress {} + source none"
  else
    fail "T2: unexpected empty/none result" "me=$T2_ME src=$T2_SRC"
  fi
else
  fail "T2: _load_effective_config failed" "$(cat /tmp/t2-eff-view.err)"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T3: manifest host NEVER folded into .config.network.allowed_hosts ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [config-host.test.invalid]
EOF
cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'EOF'
version: 1
tools:
  - name: tool-with-egress
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - egress-a.test.invalid
    mounts: []
EOF
T3_OUT=$(in_sandbox "_load_effective_config '${TEST_WS}'" 2>/tmp/t3-eff-view.err)
T3_RC=$?
if [[ "$T3_RC" -eq 0 ]]; then
  T3_CFG_HOSTS=$(jq -c '.config.network.allowed_hosts' <<<"$T3_OUT")
  T3_HAS_MANIFEST_IN_CONFIG=$(jq -r '.config.network.allowed_hosts | index("egress-a.test.invalid") != null' <<<"$T3_OUT")
  if [[ "$T3_CFG_HOSTS" == '["config-host.test.invalid"]' && "$T3_HAS_MANIFEST_IN_CONFIG" == "false" ]]; then
    pass "T3: manifest egress host stays OUT of .config.network.allowed_hosts"
  else
    fail "T3: manifest host leaked into config allowed_hosts (or config churned)" "$T3_CFG_HOSTS"
  fi
else
  fail "T3: _load_effective_config failed" "$(cat /tmp/t3-eff-view.err)"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T4: cage in scope -> source applied, content from snapshot NOT current manifest ==="
# The validate-passes/runtime-fails hole: the applied snapshot records what was
# baked at create; a manifest edited AFTER the snapshot must NOT change what the
# cage-scoped view reports.
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [config-host.test.invalid]
EOF
# Applied snapshot records manifest egress {baked-tool: [baked-host]}.
in_sandbox "_config_write_applied 't4-cage' '{\"network\":{\"allowed_hosts\":[\"config-host.test.invalid\"]}}' '{\"baked-tool\":[\"baked-host.test.invalid\"]}'" 2>/tmp/t4-write.err
# Now MUTATE the current host manifest to a DIFFERENT egress set.
cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'EOF'
version: 1
tools:
  - name: drifted-tool
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - drifted-host.test.invalid
    mounts: []
EOF
T4_OUT=$(in_sandbox "_load_effective_config '${TEST_WS}' 't4-cage'" 2>/tmp/t4-eff-view.err)
T4_RC=$?
if [[ "$T4_RC" -eq 0 ]]; then
  T4_ME=$(jq -c '.manifest_egress' <<<"$T4_OUT")
  T4_SRC=$(jq -r '.manifest_egress_source' <<<"$T4_OUT")
  if [[ "$T4_ME" == '{"baked-tool":["baked-host.test.invalid"]}' && "$T4_SRC" == "applied" ]]; then
    pass "T4: cage-scoped view reads applied snapshot, ignores drifted current manifest"
  else
    fail "T4: applied-state source not honored" "me=$T4_ME src=$T4_SRC"
  fi
else
  fail "T4: _load_effective_config failed" "$(cat /tmp/t4-eff-view.err)"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T5: old-format applied state (no manifest_egress record) -> pending fallback, no crash ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [config-host.test.invalid]
EOF
cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'EOF'
version: 1
tools:
  - name: current-tool
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - current-host.test.invalid
    mounts: []
EOF
# Old-format snapshot: bare config only, NO manifest-egress applied record.
in_sandbox "_config_write_applied 't5-cage' '{\"network\":{\"allowed_hosts\":[\"config-host.test.invalid\"]}}'" 2>/tmp/t5-write.err
T5_OUT=$(in_sandbox "_load_effective_config '${TEST_WS}' 't5-cage'" 2>/tmp/t5-eff-view.err)
T5_RC=$?
if [[ "$T5_RC" -eq 0 ]]; then
  T5_ME=$(jq -c '.manifest_egress' <<<"$T5_OUT")
  T5_SRC=$(jq -r '.manifest_egress_source' <<<"$T5_OUT")
  if [[ "$T5_ME" == '{"current-tool":["current-host.test.invalid"]}' && "$T5_SRC" == "pending" ]]; then
    pass "T5: old-format applied state falls back to pending (host manifest), no crash"
  else
    fail "T5: fallback not graceful" "me=$T5_ME src=$T5_SRC"
  fi
else
  fail "T5: _load_effective_config crashed on old-format snapshot" "$(cat /tmp/t5-eff-view.err)"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T6: rc config show --json includes both fields; text mode renders section ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [config-host.test.invalid]
EOF
cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'EOF'
version: 1
tools:
  - name: tool-with-egress
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - egress-a.test.invalid
    mounts: []
EOF
T6_JSON=$(in_sandbox "cmd_config_show '${TEST_WS}' --json" 2>/tmp/t6-json.err)
T6_JSON_RC=$?
T6_TEXT=$(in_sandbox "cmd_config_show '${TEST_WS}'" 2>/tmp/t6-text.err)
T6_TEXT_RC=$?
T6_ok=true; T6_reason=""
if [[ "$T6_JSON_RC" -ne 0 ]]; then T6_ok=false; T6_reason="config show --json exit $T6_JSON_RC"; fi
if [[ "$T6_TEXT_RC" -ne 0 ]]; then T6_ok=false; T6_reason="${T6_reason:+$T6_reason; }config show text exit $T6_TEXT_RC"; fi
T6_ME=$(jq -c '.manifest_egress' <<<"$T6_JSON" 2>/dev/null || echo "ERR")
T6_SRC=$(jq -r '.manifest_egress_source' <<<"$T6_JSON" 2>/dev/null || echo "ERR")
[[ "$T6_ME" == '{"tool-with-egress":["egress-a.test.invalid"]}' ]] || { T6_ok=false; T6_reason="${T6_reason:+$T6_reason; }json manifest_egress=$T6_ME"; }
[[ "$T6_SRC" == "pending" ]] || { T6_ok=false; T6_reason="${T6_reason:+$T6_reason; }json source=$T6_SRC"; }
echo "$T6_TEXT" | grep -qi "manifest egress" || { T6_ok=false; T6_reason="${T6_reason:+$T6_reason; }text lacks manifest egress section"; }
echo "$T6_TEXT" | grep -qF "egress-a.test.invalid" || { T6_ok=false; T6_reason="${T6_reason:+$T6_reason; }text lacks the manifest host"; }
if [[ "$T6_ok" == "true" ]]; then
  pass "T6: config show --json carries manifest_egress + source; text renders the section"
else
  fail "T6: config show did not surface manifest egress" "$T6_reason"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T7: rc allowlist show --effective separates config vs manifest hosts ==="
setup_sandbox
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [config-host.test.invalid]
EOF
cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'EOF'
version: 1
tools:
  - name: tool-with-egress
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - egress-a.test.invalid
    mounts: []
EOF
T7_TEXT=$(in_sandbox "cmd_allowlist show --effective --config-file='${TEST_WS}/.rip-cage.yaml'" 2>/tmp/t7-text.err)
T7_TEXT_RC=$?
T7_JSON=$(in_sandbox "OUTPUT_FORMAT=json cmd_allowlist show --effective --config-file='${TEST_WS}/.rip-cage.yaml'" 2>/tmp/t7-json.err)
T7_ok=true; T7_reason=""
[[ "$T7_TEXT_RC" -eq 0 ]] || { T7_ok=false; T7_reason="text exit $T7_TEXT_RC"; }
echo "$T7_TEXT" | grep -qF "config-host.test.invalid" || { T7_ok=false; T7_reason="${T7_reason:+$T7_reason; }text lacks config host"; }
echo "$T7_TEXT" | grep -qi "manifest egress" || { T7_ok=false; T7_reason="${T7_reason:+$T7_reason; }text lacks manifest egress separation"; }
echo "$T7_TEXT" | grep -qF "egress-a.test.invalid" || { T7_ok=false; T7_reason="${T7_reason:+$T7_reason; }text lacks manifest host"; }
T7_JSON_ME=$(jq -c '.manifest_egress' <<<"$T7_JSON" 2>/dev/null || echo "ERR")
[[ "$T7_JSON_ME" == '{"tool-with-egress":["egress-a.test.invalid"]}' ]] || { T7_ok=false; T7_reason="${T7_reason:+$T7_reason; }json manifest_egress=$T7_JSON_ME"; }
if [[ "$T7_ok" == "true" ]]; then
  pass "T7: allowlist show --effective separates config-sourced from manifest-attributed hosts"
else
  fail "T7: allowlist show --effective did not separate sources" "$T7_reason"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T8: reload --dry-run on manifest-drifted cage -> requires-rebuild line, eligibility UNAFFECTED ==="
setup_sandbox
CNAME="rc-eff-view-cage"
CACHE_DIR="${TEST_HOME}/.cache/rip-cage/${CNAME}"
STUB_DIR="${TEST_HOME}/stub"
mkdir -p "$CACHE_DIR" "$STUB_DIR"
# msb stub: running cage, workspace label = TEST_WS.
cat > "${STUB_DIR}/msb" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "msb 0.0.0-stub"; exit 0 ;;
  logs) exit 0 ;;
esac
case " \$* " in
  *" inspect "*"${CNAME}"*)
    echo '{"status":"Running","config":{"labels":{"rc.source.path":"${TEST_WS}"}}}'
    exit 0
    ;;
  *) echo "stub: unhandled msb args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${STUB_DIR}/msb"
# Live config: allowed_hosts gains a host relative to the snapshot (eligible config drift).
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [switch.berlin]
EOF
# Applied snapshot: config-applied.json is the BARE config object (lacks
# switch.berlin -> eligible config drift); the manifest-egress applied record
# lives in its own sibling file (an OLD set that differs from the current host
# manifest -> manifest drift).
mkdir -p "$CACHE_DIR"
printf '%s\n' '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}' > "${CACHE_DIR}/config-applied.json"
printf '%s\n' '{"old-tool":["old-egress.test.invalid"]}' > "${CACHE_DIR}/manifest-egress-applied.json"
# Current host manifest declares a DIFFERENT egress set -> manifest drift.
cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'EOF'
version: 1
tools:
  - name: new-tool
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - new-egress.test.invalid
    mounts: []
EOF
T8_OUT=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  "$RC" reload "$CNAME" --dry-run 2>&1)
T8_EXIT=$?
T8_ok=true; T8_reason=""
[[ "$T8_EXIT" -eq 0 ]] || { T8_ok=false; T8_reason="exit $T8_EXIT (want 0 -- eligibility unaffected)"; }
echo "$T8_OUT" | grep -qi "requires rebuild" || { T8_ok=false; T8_reason="${T8_reason:+$T8_reason; }no requires-rebuild line"; }
echo "$T8_OUT" | grep -qi "dry-run" || { T8_ok=false; T8_reason="${T8_reason:+$T8_reason; }no dry-run notice"; }
if [[ "$T8_ok" == "true" ]]; then
  pass "T8: reload dry-run reports manifest drift as requires-rebuild, exit 0 (eligibility unaffected)"
else
  fail "T8: reload dry-run manifest-delta reporting" "$T8_reason -- out: $T8_OUT"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T8b: ISOLATED manifest-only drift (config==snapshot, no eligible config drift) -> requires-rebuild still fires ==="
# T8 bundles config drift with manifest drift, so it stays green even if the
# manifest-egress report is gated behind the early-return/refuse-loud paths
# (both of which only trigger on CONFIG drift). This case isolates the
# canonical scenario the requires-rebuild hint exists for: live config exactly
# matches the applied snapshot (the "No changes since last apply" early-return
# path) while ONLY the manifest egress has drifted. The report must still fire
# — it depends only on the cage name, not on diff_paths.
setup_sandbox
CNAME="rc-eff-view-cage8b"
CACHE_DIR="${TEST_HOME}/.cache/rip-cage/${CNAME}"
STUB_DIR="${TEST_HOME}/stub"
mkdir -p "$CACHE_DIR" "$STUB_DIR"
cat > "${STUB_DIR}/msb" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "msb 0.0.0-stub"; exit 0 ;;
  logs) exit 0 ;;
esac
case " \$* " in
  *" inspect "*"${CNAME}"*)
    echo '{"status":"Running","config":{"labels":{"rc.source.path":"${TEST_WS}"}}}'
    exit 0
    ;;
  *) echo "stub: unhandled msb args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${STUB_DIR}/msb"
# Live config EXACTLY matches the applied config snapshot -> zero config drift
# (the "No changes since last apply" early-return branch fires).
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: []
EOF
printf '%s\n' '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}' > "${CACHE_DIR}/config-applied.json"
# ONLY the manifest-egress applied record differs from the current host manifest.
printf '%s\n' '{"old-tool":["old-egress.test.invalid"]}' > "${CACHE_DIR}/manifest-egress-applied.json"
cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'EOF'
version: 1
tools:
  - name: new-tool
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - new-egress.test.invalid
    mounts: []
EOF
T8B_OUT=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  "$RC" reload "$CNAME" --dry-run 2>&1)
T8B_EXIT=$?
T8B_ok=true; T8B_reason=""
[[ "$T8B_EXIT" -eq 0 ]] || { T8B_ok=false; T8B_reason="exit $T8B_EXIT (want 0)"; }
echo "$T8B_OUT" | grep -qi "requires rebuild" || { T8B_ok=false; T8B_reason="${T8B_reason:+$T8B_reason; }no requires-rebuild line (F1 regression: report gated behind the empty-diff early-return)"; }
echo "$T8B_OUT" | grep -qi "no changes since last apply" || { T8B_ok=false; T8B_reason="${T8B_reason:+$T8B_reason; }no-op message missing (config truly matched)"; }
if [[ "$T8B_ok" == "true" ]]; then
  pass "T8b: manifest-only drift (config==snapshot) still surfaces requires-rebuild, exit 0"
else
  fail "T8b: isolated manifest-only-drift reporting" "$T8B_reason -- out: $T8B_OUT"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T9: manifest egress change does NOT surface in _up_eligible_drift_paths ==="
setup_sandbox
CNAME="rc-eff-view-cage9"
CACHE_DIR="${TEST_HOME}/.cache/rip-cage/${CNAME}"
mkdir -p "$CACHE_DIR"
# Applied config snapshot == live config (no config drift). Only the manifest
# egress applied record differs from the current host manifest.
printf '%s\n' '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["config-host.test.invalid"]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}' > "${CACHE_DIR}/config-applied.json"
printf '%s\n' '{"old-tool":["old-egress.test.invalid"]}' > "${CACHE_DIR}/manifest-egress-applied.json"
cat > "${TEST_WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [config-host.test.invalid]
EOF
cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'EOF'
version: 1
tools:
  - name: new-tool
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - new-egress.test.invalid
    mounts: []
EOF
T9_OUT=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '${RC}' 2>/dev/null; _up_eligible_drift_paths '${CNAME}' '${TEST_WS}'" 2>/tmp/t9-eff-view.err)
T9_EXIT=$?
# No config drift + only manifest drift => the comparator returns non-zero (no
# eligible paths) and prints NOTHING about manifest egress.
if echo "$T9_OUT" | grep -qi "manifest"; then
  fail "T9: manifest egress leaked into eligible drift paths" "$T9_OUT"
elif [[ "$T9_EXIT" -ne 0 && -z "$T9_OUT" ]]; then
  pass "T9: manifest egress change absent from _up_eligible_drift_paths (config-only comparator)"
else
  fail "T9: unexpected eligible-drift output" "exit=$T9_EXIT out='$T9_OUT'"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== T10: doctor fix-hint classifier routes denied domains through the loader contract ==="
setup_sandbox
# Effective view: config allows one host; manifest_egress (applied) carries a
# baked host; manifest_egress (pending) would carry an unbaked host.
EFF_APPLIED='{"config":{"network":{"allowed_hosts":["config-host.test.invalid"]}},"manifest_egress":{"baked-tool":["baked-host.test.invalid"]},"manifest_egress_source":"applied"}'
EFF_PENDING='{"config":{"network":{"allowed_hosts":["config-host.test.invalid"]}},"manifest_egress":{"pending-tool":["pending-host.test.invalid"]},"manifest_egress_source":"pending"}'
# (a) domain already in applied manifest egress -> reachable (NOT "add")
T10a=$(in_sandbox "_doctor_classify_denied_domain 'baked-host.test.invalid' '${EFF_APPLIED}'" 2>/tmp/t10a.err)
# (b) domain in config allowed_hosts -> reachable (NOT "add")
T10b=$(in_sandbox "_doctor_classify_denied_domain 'config-host.test.invalid' '${EFF_APPLIED}'" 2>/tmp/t10b.err)
# (c) domain in pending manifest egress -> requires-rebuild
T10c=$(in_sandbox "_doctor_classify_denied_domain 'pending-host.test.invalid' '${EFF_PENDING}'" 2>/tmp/t10c.err)
# (d) unknown domain -> add
T10d=$(in_sandbox "_doctor_classify_denied_domain 'totally-unknown.test.invalid' '${EFF_APPLIED}'" 2>/tmp/t10d.err)
T10_ok=true; T10_reason=""
[[ "$T10a" == "reachable" ]] || { T10_ok=false; T10_reason="applied-manifest domain classified '$T10a' (want reachable)"; }
[[ "$T10b" == "reachable" ]] || { T10_ok=false; T10_reason="${T10_reason:+$T10_reason; }config domain classified '$T10b' (want reachable)"; }
[[ "$T10c" == "requires-rebuild" ]] || { T10_ok=false; T10_reason="${T10_reason:+$T10_reason; }pending-manifest domain classified '$T10c' (want requires-rebuild)"; }
[[ "$T10d" == "add" ]] || { T10_ok=false; T10_reason="${T10_reason:+$T10_reason; }unknown domain classified '$T10d' (want add)"; }
if [[ "$T10_ok" == "true" ]]; then
  pass "T10: denied-domain classifier -> reachable / requires-rebuild / add via loader contract"
else
  fail "T10: classifier misrouted a denied domain" "$T10_reason"
fi
cleanup

# ---------------------------------------------------------------------------
echo ""
echo "=== test-config-effective-view.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
