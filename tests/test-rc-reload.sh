#!/usr/bin/env bash
# Host-side tests for `rc reload <cage>` (rip-cage-ocn / ADR-022 D6).
#
# Coverage (matches design doc 2026-05-13-rc-reload-design.md test plan):
#   C1   Happy path — change allowed_hosts, rc reload re-filters cache in place
#   C2   No-op — no yaml change, exit 0, file mtime unchanged
#   C3   Refuse-loud, allowed_keys CONTENT change → exit 1
#   C4   Refuse-loud, allowed_keys MOUNT-SHAPE change (null↔non-null) → exit 1
#   C5   Refuse-loud, other field (egress.mode) → exit 1
#   C6   --dry-run prints diff, does NOT mutate cache or snapshot
#   C7   Stopped cage → exit 2
#   C8   Inode preservation across reload (rip-cage-rx8 regression guard)
#   C9   Concurrent reload — second invocation gets exit 3 via mkdir lock
#   C10  Drift-hint suppression — post-reload _config_emit_hint silent on
#        eligible-only delta
#   C11  Drift-hint still warns on non-eligible delta after reload
#   C12  Cache file mode preserved across reload (0644 stays 0644)
#   C13  In-cage invocation negative test — rc not on cage PATH
#   C14  Drift-hint silent when snapshot pre-dates session.multiplexer field
#        (absent-in-snapshot + live==schema-default → non-drift, rip-cage-1f59.9)
#   C15  Generality: same absent-default suppression for mounts.symlinks.scope
#
# Tests stub `docker` via PATH shim so no real docker is required for C1-C12, C14-C15.
# C13 is docker-conditional (requires rip-cage:latest image).
#
# ADRs: ADR-022 D6 (rc reload), ADR-021 (layered config), rip-cage-rx8 (inode)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0
TEST_HOME=""

pass() { echo "PASS C$1: $2"; }
fail() { echo "FAIL C$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Build a docker stub that responds to the inspect queries cmd_reload makes.
# Args:
#   $1 stub_dir   — where to write the stub script
#   $2 cname      — expected container name
#   $3 state      — "running" or "exited" (or "missing" to fail the existence check)
#   $4 workspace  — value for rc.source.path label
make_docker_stub() {
  local stub_dir="$1" cname="$2" state="$3" workspace="$4"
  cat > "${stub_dir}/docker" <<STUB
#!/usr/bin/env bash
# Test stub: emulate docker info/inspect for rc reload.
case "\${1:-}" in
  info) exit 0 ;;
esac
case " \$* " in
  *" inspect "*"State.Status"*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo "${state}"
    exit 0
    ;;
  *" inspect "*"rc.source.path"*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo "${workspace}"
    exit 0
    ;;
  *" inspect "*"rc.config-loaded"*"${cname}"*)
    echo ""
    exit 0
    ;;
  *" inspect "*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo "{}"
    exit 0
    ;;
  *)
    echo "stub: unhandled docker args: \$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${stub_dir}/docker"
}

# Build a sandbox HOME and workspace. Writes the named fixture as project config.
# Globals set: TEST_HOME, WS, CACHE_DIR, STUB_DIR, CNAME
setup_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-reload-test-XXXXXX")
  WS="${TEST_HOME}/workspace"
  CNAME="rc-reload-test"
  CACHE_DIR="${TEST_HOME}/.cache/rip-cage/${CNAME}"
  STUB_DIR="${TEST_HOME}/stub"
  mkdir -p "$WS" "$CACHE_DIR" "$STUB_DIR" "${TEST_HOME}/.ssh"

  if [[ -n "$fixture" ]]; then
    cp "${SCRIPT_DIR}/fixtures/${fixture}" "${WS}/.rip-cage.yaml"
  fi
  # Seed host known_hosts with a representative set so the filter has data.
  cat > "${TEST_HOME}/.ssh/known_hosts" <<'KH'
github.com ssh-ed25519 AAAAfakegithubkey
switch.berlin ssh-ed25519 AAAAfakeswitchkey
example.org ssh-ed25519 AAAAfakeexamplekey
KH
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" WS="" CACHE_DIR="" STUB_DIR="" CNAME=""
}

# Run rc with sandboxed HOME + docker stub. Captures stdout/stderr/exit.
# Args: rest are rc args after the command (e.g. "reload" "$CNAME").
run_rc() {
  PATH="${STUB_DIR}:$PATH" \
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    "$RC" "$@"
}

# Write a snapshot file (the "applied config") for the cage. Used to simulate
# create-time state without running real `rc up`.
write_snapshot() {
  local cfg_json="$1"
  mkdir -p "$CACHE_DIR"
  printf '%s\n' "$cfg_json" > "${CACHE_DIR}/config-applied.json"
}

# ---------------------------------------------------------------------------
# C1: Happy path — allowed_hosts: [switch.berlin] → reload applies, cache reflects
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Pre-state: snapshot has empty allowed_hosts (so live=[switch.berlin] is a delta)
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":[]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
# Pre-state: filter cache file (empty — bypass closed by default)
: > "${CACHE_DIR}/known_hosts"

c1_out=$(run_rc reload "$CNAME" 2>&1)
c1_exit=$?
c1_ok=true c1_reason=""
[[ "$c1_exit" -ne 0 ]] && c1_ok=false && c1_reason="rc reload exited $c1_exit (want 0). Output: $c1_out"
if ! grep -q "switch.berlin" "${CACHE_DIR}/known_hosts" 2>/dev/null; then
  c1_ok=false; c1_reason="${c1_reason:+$c1_reason; }cache does not contain switch.berlin"
fi
# Snapshot was updated to live
if ! jq -e '.ssh.allowed_hosts | index("switch.berlin")' "${CACHE_DIR}/config-applied.json" >/dev/null 2>&1; then
  c1_ok=false; c1_reason="${c1_reason:+$c1_reason; }snapshot not updated to live"
fi
if [[ "$c1_ok" == "true" ]]; then pass 1 "happy path: rc reload applies allowed_hosts to cache"
else fail 1 "happy path" "$c1_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C2: No-op — snapshot already matches live, exit 0, cache file untouched
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot matches live (allowed_hosts=[switch.berlin])
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":["switch.berlin"]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
echo "switch.berlin ssh-ed25519 AAAA" > "${CACHE_DIR}/known_hosts"
c2_pre_mtime=$(stat -c %Y "${CACHE_DIR}/known_hosts" 2>/dev/null || stat -f %m "${CACHE_DIR}/known_hosts")
sleep 1  # ensure measurable mtime delta if mutation happens

c2_out=$(run_rc reload "$CNAME" 2>&1)
c2_exit=$?
c2_post_mtime=$(stat -c %Y "${CACHE_DIR}/known_hosts" 2>/dev/null || stat -f %m "${CACHE_DIR}/known_hosts")
c2_ok=true c2_reason=""
[[ "$c2_exit" -ne 0 ]] && c2_ok=false && c2_reason="exit $c2_exit"
[[ "$c2_post_mtime" -ne "$c2_pre_mtime" ]] && c2_ok=false && c2_reason="${c2_reason:+$c2_reason; }cache file was rewritten"
echo "$c2_out" | grep -qi "no changes" || { c2_ok=false; c2_reason="${c2_reason:+$c2_reason; }no 'no changes' message"; }
if [[ "$c2_ok" == "true" ]]; then pass 2 "no-op: rc reload silent on identical config"
else fail 2 "no-op" "$c2_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C3: Refuse-loud, allowed_keys content change → exit 1
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-keys-one.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot has different allowed_keys content (same shape: array, but different list)
write_snapshot '{"version":1,"ssh":{"allowed_keys":["different_key.pub"],"allowed_hosts":[]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c3_out=$(run_rc reload "$CNAME" 2>&1)
c3_exit=$?
c3_ok=true c3_reason=""
[[ "$c3_exit" -ne 1 ]] && c3_ok=false && c3_reason="exit $c3_exit (want 1)"
echo "$c3_out" | grep -q "allowed_keys" || { c3_ok=false; c3_reason="${c3_reason:+$c3_reason; }error doesn't name allowed_keys"; }
echo "$c3_out" | grep -q "rc destroy" || { c3_ok=false; c3_reason="${c3_reason:+$c3_reason; }no rc destroy hint"; }
if [[ "$c3_ok" == "true" ]]; then pass 3 "refuse-loud on allowed_keys content change"
else fail 3 "refuse allowed_keys content" "$c3_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C4: Refuse-loud, allowed_keys mount-shape change (null → [key]) → exit 1
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-keys-one.yaml"  # live: allowed_keys=[...] (non-null)
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":[]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'  # snapshot: null

c4_out=$(run_rc reload "$CNAME" 2>&1)
c4_exit=$?
c4_ok=true c4_reason=""
[[ "$c4_exit" -ne 1 ]] && c4_ok=false && c4_reason="exit $c4_exit (want 1)"
echo "$c4_out" | grep -q "allowed_keys" || { c4_ok=false; c4_reason="${c4_reason:+$c4_reason; }error doesn't name allowed_keys"; }
if [[ "$c4_ok" == "true" ]]; then pass 4 "refuse-loud on allowed_keys mount-shape (null↔non-null)"
else fail 4 "refuse mount-shape" "$c4_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C5: Refuse-loud, non-eligible field (synthetic egress.mode delta) → exit 1
# Build a fixture inline since there's no egress-mode fixture in /fixtures.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox ""
cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
ssh:
  allowed_hosts: []
YML
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot has a synthetic field NOT in the live config — diff reports it.
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":[]},"egress":{"mode":"denylist"},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c5_out=$(run_rc reload "$CNAME" 2>&1)
c5_exit=$?
c5_ok=true c5_reason=""
[[ "$c5_exit" -ne 1 ]] && c5_ok=false && c5_reason="exit $c5_exit (want 1)"
echo "$c5_out" | grep -q "egress" || { c5_ok=false; c5_reason="${c5_reason:+$c5_reason; }error doesn't name egress"; }
if [[ "$c5_ok" == "true" ]]; then pass 5 "refuse-loud on non-eligible field (egress)"
else fail 5 "refuse non-eligible" "$c5_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C6: --dry-run prints diff, does NOT mutate cache or snapshot
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":[]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
: > "${CACHE_DIR}/known_hosts"
c6_pre_kh_mtime=$(stat -c %Y "${CACHE_DIR}/known_hosts" 2>/dev/null || stat -f %m "${CACHE_DIR}/known_hosts")
c6_pre_snap_sum=$(shasum "${CACHE_DIR}/config-applied.json" | awk '{print $1}')
sleep 1

c6_out=$(run_rc reload "$CNAME" --dry-run 2>&1)
c6_exit=$?
c6_post_kh_mtime=$(stat -c %Y "${CACHE_DIR}/known_hosts" 2>/dev/null || stat -f %m "${CACHE_DIR}/known_hosts")
c6_post_snap_sum=$(shasum "${CACHE_DIR}/config-applied.json" | awk '{print $1}')
c6_ok=true c6_reason=""
[[ "$c6_exit" -ne 0 ]] && c6_ok=false && c6_reason="exit $c6_exit"
[[ "$c6_pre_kh_mtime" -ne "$c6_post_kh_mtime" ]] && c6_ok=false && c6_reason="${c6_reason:+$c6_reason; }cache was mutated"
[[ "$c6_pre_snap_sum" != "$c6_post_snap_sum" ]] && c6_ok=false && c6_reason="${c6_reason:+$c6_reason; }snapshot was mutated"
echo "$c6_out" | grep -qi "dry-run" || { c6_ok=false; c6_reason="${c6_reason:+$c6_reason; }no dry-run notice"; }
echo "$c6_out" | grep -q "switch.berlin" || { c6_ok=false; c6_reason="${c6_reason:+$c6_reason; }diff didn't mention added host"; }
if [[ "$c6_ok" == "true" ]]; then pass 6 "--dry-run: prints diff, no mutation"
else fail 6 "dry-run" "$c6_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C7: Stopped cage → exit 2
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "exited" "$WS"
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":[]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c7_out=$(run_rc reload "$CNAME" 2>&1)
c7_exit=$?
c7_ok=true c7_reason=""
[[ "$c7_exit" -ne 2 ]] && c7_ok=false && c7_reason="exit $c7_exit (want 2)"
echo "$c7_out" | grep -q "not running" || { c7_ok=false; c7_reason="${c7_reason:+$c7_reason; }no 'not running' message"; }
echo "$c7_out" | grep -q "rc up" || { c7_ok=false; c7_reason="${c7_reason:+$c7_reason; }no 'rc up' hint"; }
if [[ "$c7_ok" == "true" ]]; then pass 7 "stopped cage exits 2"
else fail 7 "stopped cage" "$c7_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C8: Inode preservation across reload (rip-cage-rx8 regression guard)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":[]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
: > "${CACHE_DIR}/known_hosts"
c8_pre_inode=$(stat -c %i "${CACHE_DIR}/known_hosts" 2>/dev/null || stat -f %i "${CACHE_DIR}/known_hosts")

run_rc reload "$CNAME" >/dev/null 2>&1
c8_exit=$?
c8_post_inode=$(stat -c %i "${CACHE_DIR}/known_hosts" 2>/dev/null || stat -f %i "${CACHE_DIR}/known_hosts")
c8_ok=true c8_reason=""
[[ "$c8_exit" -ne 0 ]] && c8_ok=false && c8_reason="exit $c8_exit"
[[ "$c8_pre_inode" != "$c8_post_inode" ]] && c8_ok=false && c8_reason="${c8_reason:+$c8_reason; }inode changed ($c8_pre_inode → $c8_post_inode)"
if [[ "$c8_ok" == "true" ]]; then pass 8 "inode preserved across reload (rip-cage-rx8)"
else fail 8 "inode preservation" "$c8_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C9: Concurrent reload — second invocation gets exit 3 via mkdir lock
# Strategy: pre-create the lock dir; rc reload should refuse loud.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":[]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

# Pre-create the lock dir (simulates a concurrent reload holding it)
mkdir -p "${CACHE_DIR}/.reload.lock.d"

c9_out=$(run_rc reload "$CNAME" 2>&1)
c9_exit=$?
# Clean up
rmdir "${CACHE_DIR}/.reload.lock.d" 2>/dev/null

c9_ok=true c9_reason=""
[[ "$c9_exit" -ne 3 ]] && c9_ok=false && c9_reason="exit $c9_exit (want 3)"
echo "$c9_out" | grep -q "in progress" || { c9_ok=false; c9_reason="${c9_reason:+$c9_reason; }no 'in progress' message"; }
if [[ "$c9_ok" == "true" ]]; then pass 9 "concurrent reload: second exits 3 (mkdir-lock contention)"
else fail 9 "concurrent reload" "$c9_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C10: Drift-hint suppression — _config_emit_hint silent after reload-eligible delta
# Source rc to call _config_emit_hint directly; stub docker to return no label.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot equals live (post-reload state)
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":["switch.berlin"]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c10_out=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '$RC'; _config_emit_hint '$WS' '$CNAME'" 2>&1) || true
c10_exit=$?

c10_ok=true c10_reason=""
[[ "$c10_exit" -ne 0 ]] && c10_ok=false && c10_reason="emit_hint exit $c10_exit"
# Should be silent — no output expected when snapshot matches live.
if [[ -n "$c10_out" ]]; then
  c10_ok=false; c10_reason="${c10_reason:+$c10_reason; }unexpected output: $c10_out"
fi
if [[ "$c10_ok" == "true" ]]; then pass 10 "drift-hint silent when snapshot matches live"
else fail 10 "drift-hint suppression" "$c10_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C11: Drift-hint still warns on non-eligible delta (eligible-fields snapshot
#      matches, but a non-eligible field diverges).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox ""
cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
ssh:
  allowed_hosts:
    - switch.berlin
YML
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot has eligible field aligned (allowed_hosts matches) but a synthetic
# non-eligible field present that live lacks → drift hint must fire.
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":["switch.berlin"]},"egress":{"mode":"denylist"},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c11_out=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '$RC'; _config_emit_hint '$WS' '$CNAME'" 2>&1) || true
c11_exit=$?

c11_ok=true c11_reason=""
[[ "$c11_exit" -ne 0 ]] && c11_ok=false && c11_reason="emit_hint exit $c11_exit"
echo "$c11_out" | grep -q "rc destroy" || { c11_ok=false; c11_reason="${c11_reason:+$c11_reason; }no rc destroy hint"; }
echo "$c11_out" | grep -qi "egress" || { c11_ok=false; c11_reason="${c11_reason:+$c11_reason; }hint doesn't name egress path"; }
if [[ "$c11_ok" == "true" ]]; then pass 11 "drift-hint still warns on non-eligible delta"
else fail 11 "drift-hint non-eligible" "$c11_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C12: Cache file mode preserved across reload (0644 stays 0644)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":[]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
: > "${CACHE_DIR}/known_hosts"
chmod 0644 "${CACHE_DIR}/known_hosts"
c12_pre_mode=$(stat -c %a "${CACHE_DIR}/known_hosts" 2>/dev/null || stat -f %Mp%Lp "${CACHE_DIR}/known_hosts")

run_rc reload "$CNAME" >/dev/null 2>&1
c12_exit=$?
c12_post_mode=$(stat -c %a "${CACHE_DIR}/known_hosts" 2>/dev/null || stat -f %Mp%Lp "${CACHE_DIR}/known_hosts")
c12_ok=true c12_reason=""
[[ "$c12_exit" -ne 0 ]] && c12_ok=false && c12_reason="exit $c12_exit"
# Don't compare exact form (macOS stat uses 100644, GNU uses 644). Just confirm same.
[[ "$c12_pre_mode" != "$c12_post_mode" ]] && c12_ok=false && c12_reason="${c12_reason:+$c12_reason; }mode changed ($c12_pre_mode → $c12_post_mode)"
if [[ "$c12_ok" == "true" ]]; then pass 12 "cache file mode preserved across reload"
else fail 12 "mode preservation" "$c12_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C14: Drift-hint suppression — snapshot MISSING session.multiplexer (old pre-1f59
#      snapshot), live config has it at schema default "none" → NO recreate hint.
#      Tests the general fix: absent-in-snapshot + live==schema-default → non-drift.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Old snapshot: no session.multiplexer field (written before rip-cage-1f59 landed).
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":["switch.berlin"]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]}}'

c14_out=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '$RC'; _config_emit_hint '$WS' '$CNAME'" 2>&1) || true
c14_exit=$?

c14_ok=true c14_reason=""
[[ "$c14_exit" -ne 0 ]] && c14_ok=false && c14_reason="emit_hint exit $c14_exit"
# Must be silent — session.multiplexer absent in snapshot but live==default("none").
if [[ -n "$c14_out" ]]; then
  c14_ok=false; c14_reason="${c14_reason:+$c14_reason; }spurious output: $c14_out"
fi
if [[ "$c14_ok" == "true" ]]; then pass 14 "drift-hint silent when only absent-default field added (session.multiplexer)"
else fail 14 "spurious recreate-hint for absent-default field" "$c14_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C15: Generality — snapshot MISSING mounts.symlinks.scope (another defaulted
#      field), live has it at schema default "file" → NO recreate hint.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-allowed-hosts-only.yaml"
make_docker_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Old snapshot: no mounts.symlinks.scope field.
write_snapshot '{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":["switch.berlin"]},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c15_out=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '$RC'; _config_emit_hint '$WS' '$CNAME'" 2>&1) || true
c15_exit=$?

c15_ok=true c15_reason=""
[[ "$c15_exit" -ne 0 ]] && c15_ok=false && c15_reason="emit_hint exit $c15_exit"
# Must be silent — mounts.symlinks.scope absent in snapshot but live==default("file").
if [[ -n "$c15_out" ]]; then
  c15_ok=false; c15_reason="${c15_reason:+$c15_reason; }spurious output: $c15_out"
fi
if [[ "$c15_ok" == "true" ]]; then pass 15 "drift-hint silent when only absent-default field added (mounts.symlinks.scope)"
else fail 15 "spurious recreate-hint for absent-default field (generality)" "$c15_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C13: In-cage invocation negative test — rc not on cage PATH.
# Docker-conditional and opt-in via RC_RELOAD_E2E=1 (spinning up a cage during
# the unit test loop slows iteration enough to be off by default). Static
# alternative: the Dockerfile contains no `COPY rc /` to a PATH location, so
# the security boundary is verifiable by inspection as well.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "${RC_RELOAD_E2E:-}" != "1" ]]; then
  echo "SKIP C13: set RC_RELOAD_E2E=1 to run docker-conditional in-cage check"
elif ! command -v docker >/dev/null 2>&1; then
  echo "SKIP C13: docker not available"
elif ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP C13: rip-cage:latest image not built"
else
  c13_out=$(docker run --rm --entrypoint /bin/bash rip-cage:latest -c 'command -v rc' 2>&1)
  c13_exit=$?
  if [[ "$c13_exit" -ne 0 ]]; then
    pass 13 "rc binary is NOT on cage PATH (in-cage invocation negative test)"
  else
    fail 13 "in-cage rc availability" "rc found at: $c13_out (rip-cage-ocn security boundary breach!)"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES of $TOTAL tests"
  exit 1
fi
echo "All $TOTAL tests passed."
