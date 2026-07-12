#!/usr/bin/env bash
# Host-side tests for `rc reload <cage>` (rip-cage-ocn / ADR-022 D6, carried
# forward past the ssh-cluster retirement per ADR-029 D3/D4 -- the `rc
# reload` verb itself, the refuse-loud taxonomy, and the applied-config
# snapshot machinery all survive; only the ssh.allowed_hosts-specific
# content (known_hosts cache re-filtering, ssh.allowed_keys mount-shape
# lock) retired with the rest of the ssh cluster, rip-cage-f1qo S5).
#
# Reload-eligible content today is network.allowed_hosts / network.mode
# (the egress allowlist, cli/allowlist.sh's domain -- unaffected by the ssh
# retirement). Fixtures/assertions below were re-pointed from ssh.* to
# network.* to match. `rc reload` for network.* fields currently only
# updates the applied-config snapshot + refuses/diffs -- it does NOT
# re-apply a live in-cage effect (the old known_hosts cache-file rewrite
# mechanism retired with ssh; net-rule re-application onto a running msb
# sandbox is deferred to S6's snapshot-amend lifecycle work, per
# cli/reload.sh's own comment). Tests that asserted the retired cache-file
# side effect (inode/mode preservation) were re-pointed to the
# config-applied.json snapshot file instead, which _config_write_applied
# truncate-writes with the exact same rip-cage-rx8 inode-preserving idiom.
#
# Coverage:
#   C1   Happy path — network.allowed_hosts change → reload applies (exit
#        0, diff printed, snapshot updated to live)
#   C2   No-op — no yaml change, exit 0, snapshot file mtime unchanged
#   C3   Refuse-loud, other field (egress.mode) → exit 1
#   C4   --dry-run prints diff, does NOT mutate the snapshot
#   C5   Stopped cage → exit 2
#   C6   Inode preservation across reload (rip-cage-rx8 regression guard,
#        applied-config snapshot file)
#   C7   Concurrent reload — second invocation gets exit 3 via mkdir lock
#   C8   Drift-hint suppression — post-reload _config_emit_hint silent on
#        eligible-only delta
#   C9   Drift-hint still warns on non-eligible delta after reload
#   C10  Snapshot file mode preserved across reload (0644 stays 0644)
#   C11  Drift-hint silent when snapshot pre-dates session.multiplexer field
#        (absent-in-snapshot + live==schema-default → non-drift, rip-cage-1f59.9)
#   C12  Generality: same absent-default suppression for mounts.symlinks.scope
#   C13  In-cage invocation negative test — rc not on cage PATH
#
# Tests stub `msb` via PATH shim so no real msb daemon is required for
# C1-C12. C13 is docker-conditional (requires rip-cage:latest image, still
# docker-side image provisioning).
#
# rip-cage-5iti (S10, msb migration test-suite port): retargeted from a
# `docker inspect --format` stub onto an `msb inspect --format json` stub --
# rip-cage-rj68 (S6) rewrote cmd_reload onto msb (`_msb_exists`,
# `_msb_sandbox_state`, `_msb_label`, all backed by a single `msb inspect
# NAME --format json` call), so `docker info`/`docker inspect` are never
# called by cmd_reload any more.
#
# ADRs: ADR-022 D6 (rc reload origin), ADR-029 D3/D4 (ssh-cluster retirement
# + carry-forward), ADR-021 (layered config), rip-cage-rx8 (inode)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0
TEST_HOME=""

pass() { echo "PASS C$1: $2"; }
fail() { echo "FAIL C$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }
skip() { echo "SKIP C$1: $2"; }

# rip-cage-5iti (S10, msb migration test-suite port) -- whether a real
# docker+msb+pre-built rip-cage:latest image are available to drive C1/C6/
# C10's real `rc up`/cold-recreate `rc reload` path (see those cases'
# comments below for why they can no longer be host-only-stubbed).
_RC_RELOAD_HAS_LIVE_RUNTIME=false
if command -v docker >/dev/null 2>&1 && docker image inspect rip-cage:latest >/dev/null 2>&1 \
  && command -v msb >/dev/null 2>&1 && msb image list --format json 2>/dev/null | grep -qF "rip-cage:latest"; then
  _RC_RELOAD_HAS_LIVE_RUNTIME=true
fi

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Build an msb stub that responds to the `msb inspect NAME --format json`
# call cmd_reload's _msb_exists/_msb_sandbox_state/_msb_label all compose on
# (cli/lib/msb_runtime.sh's _msb_inspect_json — a single call shape, so one
# stub response covers all three readers).
# Args:
#   $1 stub_dir   — where to write the stub script
#   $2 cname      — expected sandbox name
#   $3 state      — "running" or "exited" (or "missing" to fail the existence check)
#   $4 workspace  — value for rc.source.path label
make_msb_stub() {
  local stub_dir="$1" cname="$2" state="$3" workspace="$4"
  local status_json
  case "$state" in
    running) status_json="Running" ;;
    exited) status_json="Stopped" ;;
    *) status_json="" ;;
  esac
  cat > "${stub_dir}/msb" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "msb 0.0.0-stub"; exit 0 ;;
  logs) exit 0 ;;
esac
case " \$* " in
  *" inspect "*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo '{"status":"${status_json}","config":{"labels":{"rc.source.path":"${workspace}"}}}'
    exit 0
    ;;
  *)
    echo "stub: unhandled msb args: \$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${stub_dir}/msb"
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
  mkdir -p "$WS" "$CACHE_DIR" "$STUB_DIR"

  if [[ -n "$fixture" ]]; then
    cp "${SCRIPT_DIR}/fixtures/${fixture}" "${WS}/.rip-cage.yaml"
  fi
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
# C1: Happy path — network.allowed_hosts: [switch.berlin] → reload applies
# (snapshot updated to live; diff printed the added host).
#
# rip-cage-5iti (S10, msb migration test-suite port) — CANNOT stay a
# host-only `msb inspect`-stub case any more. Unlike C2-C5/C7-C12 (which
# all return before reaching the apply path — no-op/refuse/not-running/
# lock-contention/dry-run/drift-hint-only), the "apply" path itself changed
# shape at the msb cutover: cli/reload.sh's own comment documents that
# net-rule changes are now COLD-RECREATE-only under msb (no live-mutation
# path exists on a running sandbox — `msb modify` has no network
# parameter), so a successful C1 apply calls `_msb_stop_graceful` +
# `_msb_remove` + a REAL `cmd_up` create pipeline (image checks, manifest
# validation, mount/egress-flag generation, `msb create`) — far beyond what
# a PATH-stubbed `msb` can honestly simulate without reimplementing cmd_up
# itself inside the stub. Retargeted onto a real `rc up` + `rc reload`
# round-trip (same idiom as tests/test-msb-lifecycle-reload-repair-loop.sh,
# which already proves the cold-recreate mechanic's DEEPER claim -- real
# bidirectional egress data before/after the fix); self-skips honestly
# without docker+msb+a pre-built rip-cage:latest image.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_RELOAD_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 1 "happy path — needs docker+msb+pre-built rip-cage:latest image"
else
  RCL_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-reload-live-XXXXXX")
  RCL_WS="${RCL_HOME}/workspace"
  mkdir -p "${RCL_HOME}/.config/rip-cage" "$RCL_WS"
  git -C "$RCL_WS" init -q
  touch "${RCL_WS}/README.md"
  git -C "$RCL_WS" add README.md
  git -C "$RCL_WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial" >/dev/null 2>&1
  cat > "${RCL_WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: []
YML
  RCL_CAGE=""
  rcl_run() { XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json "$@"; }

  rcl_up_out=$(rcl_run up "$RCL_WS" 2>&1)
  rcl_up_exit=$?
  if [[ "$rcl_up_exit" -ne 0 ]]; then
    fail 1 "happy path" "live setup: rc up failed (exit $rcl_up_exit): $rcl_up_out"
  else
    RCL_CAGE=$(echo "$rcl_up_out" | tail -1 | jq -r '.name' 2>/dev/null)
    # Add switch.berlin to allowed_hosts, then reload for real.
    cat > "${RCL_WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: [switch.berlin]
YML
    c1_out=$(rcl_run reload "$RCL_CAGE" 2>&1) || true
    c1_exit=$?
    c1_ok=true c1_reason=""
    [[ "$c1_exit" -ne 0 ]] && c1_ok=false && c1_reason="rc reload exited $c1_exit. Output: $c1_out"
    RCL_SNAP="${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json"
    if ! jq -e '.network.allowed_hosts | index("switch.berlin")' "$RCL_SNAP" >/dev/null 2>&1; then
      c1_ok=false; c1_reason="${c1_reason:+$c1_reason; }snapshot not updated to live (path: $RCL_SNAP)"
    fi
    if [[ "$c1_ok" == "true" ]]; then pass 1 "happy path: real rc reload cold-recreates ${RCL_CAGE}, snapshot updated"
    else fail 1 "happy path" "$c1_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "$RCL_CAGE" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "$RCL_HOME"
fi

# ---------------------------------------------------------------------------
# C2: No-op — snapshot already matches live, exit 0, snapshot mtime unchanged
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot matches live (network.allowed_hosts=[switch.berlin])
write_snapshot '{"version":1,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
c2_pre_mtime=$(stat -c %Y "${CACHE_DIR}/config-applied.json" 2>/dev/null || stat -f %m "${CACHE_DIR}/config-applied.json")
sleep 1  # ensure measurable mtime delta if mutation happens

c2_out=$(run_rc reload "$CNAME" 2>&1)
c2_exit=$?
c2_post_mtime=$(stat -c %Y "${CACHE_DIR}/config-applied.json" 2>/dev/null || stat -f %m "${CACHE_DIR}/config-applied.json")
c2_ok=true c2_reason=""
[[ "$c2_exit" -ne 0 ]] && c2_ok=false && c2_reason="exit $c2_exit"
[[ "$c2_post_mtime" -ne "$c2_pre_mtime" ]] && c2_ok=false && c2_reason="${c2_reason:+$c2_reason; }snapshot was rewritten"
echo "$c2_out" | grep -qi "no changes" || { c2_ok=false; c2_reason="${c2_reason:+$c2_reason; }no 'no changes' message"; }
if [[ "$c2_ok" == "true" ]]; then pass 2 "no-op: rc reload silent on identical config"
else fail 2 "no-op" "$c2_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C3: Refuse-loud, non-eligible field (synthetic egress.mode delta) → exit 1
# Build a fixture inline since there's no egress-mode fixture in /fixtures.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox ""
cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: []
YML
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot has a synthetic field NOT in the live config — diff reports it.
write_snapshot '{"version":1,"egress":{"mode":"denylist"},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c3_out=$(run_rc reload "$CNAME" 2>&1)
c3_exit=$?
c3_ok=true c3_reason=""
[[ "$c3_exit" -ne 1 ]] && c3_ok=false && c3_reason="exit $c3_exit (want 1)"
echo "$c3_out" | grep -q "egress" || { c3_ok=false; c3_reason="${c3_reason:+$c3_reason; }error doesn't name egress"; }
echo "$c3_out" | grep -q "rc destroy" || { c3_ok=false; c3_reason="${c3_reason:+$c3_reason; }no rc destroy hint"; }
if [[ "$c3_ok" == "true" ]]; then pass 3 "refuse-loud on non-eligible field (egress)"
else fail 3 "refuse non-eligible" "$c3_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C4: --dry-run prints diff, does NOT mutate the snapshot
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
write_snapshot '{"version":1,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
c4_pre_snap_sum=$(shasum "${CACHE_DIR}/config-applied.json" | awk '{print $1}')

c4_out=$(run_rc reload "$CNAME" --dry-run 2>&1)
c4_exit=$?
c4_post_snap_sum=$(shasum "${CACHE_DIR}/config-applied.json" | awk '{print $1}')
c4_ok=true c4_reason=""
[[ "$c4_exit" -ne 0 ]] && c4_ok=false && c4_reason="exit $c4_exit"
[[ "$c4_pre_snap_sum" != "$c4_post_snap_sum" ]] && c4_ok=false && c4_reason="${c4_reason:+$c4_reason; }snapshot was mutated"
echo "$c4_out" | grep -qi "dry-run" || { c4_ok=false; c4_reason="${c4_reason:+$c4_reason; }no dry-run notice"; }
echo "$c4_out" | grep -q "switch.berlin" || { c4_ok=false; c4_reason="${c4_reason:+$c4_reason; }diff didn't mention added host"; }
if [[ "$c4_ok" == "true" ]]; then pass 4 "--dry-run: prints diff, no mutation"
else fail 4 "dry-run" "$c4_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C5: Stopped cage → exit 2
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS"
write_snapshot '{"version":1,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c5_out=$(run_rc reload "$CNAME" 2>&1)
c5_exit=$?
c5_ok=true c5_reason=""
[[ "$c5_exit" -ne 2 ]] && c5_ok=false && c5_reason="exit $c5_exit (want 2)"
echo "$c5_out" | grep -q "not running" || { c5_ok=false; c5_reason="${c5_reason:+$c5_reason; }no 'not running' message"; }
echo "$c5_out" | grep -q "rc up" || { c5_ok=false; c5_reason="${c5_reason:+$c5_reason; }no 'rc up' hint"; }
if [[ "$c5_ok" == "true" ]]; then pass 5 "stopped cage exits 2"
else fail 5 "stopped cage" "$c5_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C6: Inode preservation across reload (rip-cage-rx8 regression guard).
# Re-pointed from the retired ssh known_hosts cache file to the
# applied-config snapshot file, which _config_write_applied truncate-writes
# with the identical inode-preserving idiom (never mv-into-place).
#
# rip-cage-5iti (S10, msb migration test-suite port): same cold-recreate
# retarget as C1 above (this case reaches the same real-apply path) --
# self-skips honestly without docker+msb+a pre-built rip-cage:latest image.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_RELOAD_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 6 "inode preservation — needs docker+msb+pre-built rip-cage:latest image"
else
  RCL_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-reload-live-XXXXXX")
  RCL_WS="${RCL_HOME}/workspace"
  mkdir -p "${RCL_HOME}/.config/rip-cage" "$RCL_WS"
  git -C "$RCL_WS" init -q
  touch "${RCL_WS}/README.md"
  git -C "$RCL_WS" add README.md
  git -C "$RCL_WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial" >/dev/null 2>&1
  cat > "${RCL_WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: []
YML
  RCL_CAGE=""
  rcl_run() { XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json "$@"; }

  rcl_up_out=$(rcl_run up "$RCL_WS" 2>&1)
  rcl_up_exit=$?
  if [[ "$rcl_up_exit" -ne 0 ]]; then
    fail 6 "inode preservation" "live setup: rc up failed (exit $rcl_up_exit): $rcl_up_out"
  else
    RCL_CAGE=$(echo "$rcl_up_out" | tail -1 | jq -r '.name' 2>/dev/null)
    RCL_SNAP="${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json"
    c6_pre_inode=$(stat -c %i "$RCL_SNAP" 2>/dev/null || stat -f %i "$RCL_SNAP")
    cat > "${RCL_WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: [switch.berlin]
YML
    rcl_run reload "$RCL_CAGE" >/dev/null 2>&1
    c6_exit=$?
    c6_post_inode=$(stat -c %i "$RCL_SNAP" 2>/dev/null || stat -f %i "$RCL_SNAP")
    c6_ok=true c6_reason=""
    [[ "$c6_exit" -ne 0 ]] && c6_ok=false && c6_reason="exit $c6_exit"
    [[ "$c6_pre_inode" != "$c6_post_inode" ]] && c6_ok=false && c6_reason="${c6_reason:+$c6_reason; }inode changed ($c6_pre_inode → $c6_post_inode)"
    if [[ "$c6_ok" == "true" ]]; then pass 6 "inode preserved across real rc reload (rip-cage-rx8, applied-config snapshot)"
    else fail 6 "inode preservation" "$c6_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "$RCL_CAGE" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "$RCL_HOME"
fi

# ---------------------------------------------------------------------------
# C7: Concurrent reload — second invocation gets exit 3 via mkdir lock
# Strategy: pre-create the lock dir; rc reload should refuse loud.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
write_snapshot '{"version":1,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

# Pre-create the lock dir (simulates a concurrent reload holding it)
mkdir -p "${CACHE_DIR}/.reload.lock.d"

c7_out=$(run_rc reload "$CNAME" 2>&1)
c7_exit=$?
# Clean up
rmdir "${CACHE_DIR}/.reload.lock.d" 2>/dev/null

c7_ok=true c7_reason=""
[[ "$c7_exit" -ne 3 ]] && c7_ok=false && c7_reason="exit $c7_exit (want 3)"
echo "$c7_out" | grep -q "in progress" || { c7_ok=false; c7_reason="${c7_reason:+$c7_reason; }no 'in progress' message"; }
if [[ "$c7_ok" == "true" ]]; then pass 7 "concurrent reload: second exits 3 (mkdir-lock contention)"
else fail 7 "concurrent reload" "$c7_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C8: Drift-hint suppression — _config_emit_hint silent after reload-eligible delta
# Source rc to call _config_emit_hint directly; stub docker to return no label.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot equals live (post-reload state)
write_snapshot '{"version":1,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c8_out=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '$RC'; _config_emit_hint '$WS' '$CNAME'" 2>&1) || true
c8_exit=$?

c8_ok=true c8_reason=""
[[ "$c8_exit" -ne 0 ]] && c8_ok=false && c8_reason="emit_hint exit $c8_exit"
# Should be silent — no output expected when snapshot matches live.
if [[ -n "$c8_out" ]]; then
  c8_ok=false; c8_reason="${c8_reason:+$c8_reason; }unexpected output: $c8_out"
fi
if [[ "$c8_ok" == "true" ]]; then pass 8 "drift-hint silent when snapshot matches live"
else fail 8 "drift-hint suppression" "$c8_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C9: Drift-hint still warns on non-eligible delta (eligible-fields snapshot
#      matches, but a non-eligible field diverges).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox ""
cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts:
    - switch.berlin
YML
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot has eligible field aligned (allowed_hosts matches) but a synthetic
# non-eligible field present that live lacks → drift hint must fire.
write_snapshot '{"version":1,"egress":{"mode":"denylist"},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c9_out=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '$RC'; _config_emit_hint '$WS' '$CNAME'" 2>&1) || true
c9_exit=$?

c9_ok=true c9_reason=""
[[ "$c9_exit" -ne 0 ]] && c9_ok=false && c9_reason="emit_hint exit $c9_exit"
echo "$c9_out" | grep -q "rc destroy" || { c9_ok=false; c9_reason="${c9_reason:+$c9_reason; }no rc destroy hint"; }
echo "$c9_out" | grep -qi "egress" || { c9_ok=false; c9_reason="${c9_reason:+$c9_reason; }hint doesn't name egress path"; }
if [[ "$c9_ok" == "true" ]]; then pass 9 "drift-hint still warns on non-eligible delta"
else fail 9 "drift-hint non-eligible" "$c9_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C10: Applied-config snapshot file mode preserved across reload (0644 stays 0644)
#
# rip-cage-5iti (S10, msb migration test-suite port): same cold-recreate
# retarget as C1/C6 above — self-skips honestly without docker+msb+a
# pre-built rip-cage:latest image.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_RELOAD_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 10 "mode preservation — needs docker+msb+pre-built rip-cage:latest image"
else
  RCL_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-reload-live-XXXXXX")
  RCL_WS="${RCL_HOME}/workspace"
  mkdir -p "${RCL_HOME}/.config/rip-cage" "$RCL_WS"
  git -C "$RCL_WS" init -q
  touch "${RCL_WS}/README.md"
  git -C "$RCL_WS" add README.md
  git -C "$RCL_WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial" >/dev/null 2>&1
  cat > "${RCL_WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: []
YML
  RCL_CAGE=""
  rcl_run() { XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json "$@"; }

  rcl_up_out=$(rcl_run up "$RCL_WS" 2>&1)
  rcl_up_exit=$?
  if [[ "$rcl_up_exit" -ne 0 ]]; then
    fail 10 "mode preservation" "live setup: rc up failed (exit $rcl_up_exit): $rcl_up_out"
  else
    RCL_CAGE=$(echo "$rcl_up_out" | tail -1 | jq -r '.name' 2>/dev/null)
    RCL_SNAP="${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json"
    chmod 0644 "$RCL_SNAP"
    c10_pre_mode=$(stat -c %a "$RCL_SNAP" 2>/dev/null || stat -f %Mp%Lp "$RCL_SNAP")
    cat > "${RCL_WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: [switch.berlin]
YML
    rcl_run reload "$RCL_CAGE" >/dev/null 2>&1
    c10_exit=$?
    c10_post_mode=$(stat -c %a "$RCL_SNAP" 2>/dev/null || stat -f %Mp%Lp "$RCL_SNAP")
    c10_ok=true c10_reason=""
    [[ "$c10_exit" -ne 0 ]] && c10_ok=false && c10_reason="exit $c10_exit"
    # Don't compare exact form (macOS stat uses 100644, GNU uses 644). Just confirm same.
    [[ "$c10_pre_mode" != "$c10_post_mode" ]] && c10_ok=false && c10_reason="${c10_reason:+$c10_reason; }mode changed ($c10_pre_mode → $c10_post_mode)"
    if [[ "$c10_ok" == "true" ]]; then pass 10 "applied-config snapshot mode preserved across real rc reload"
    else fail 10 "mode preservation" "$c10_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "$RCL_CAGE" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "$RCL_HOME"
fi

# ---------------------------------------------------------------------------
# C11: Drift-hint suppression — snapshot MISSING session.multiplexer (old pre-1f59
#      snapshot), live config has it at schema default "none" → NO recreate hint.
#      Tests the general fix: absent-in-snapshot + live==schema-default → non-drift.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Old snapshot: no session.multiplexer field (written before rip-cage-1f59 landed).
write_snapshot '{"version":1,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]}}'

c11_out=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '$RC'; _config_emit_hint '$WS' '$CNAME'" 2>&1) || true
c11_exit=$?

c11_ok=true c11_reason=""
[[ "$c11_exit" -ne 0 ]] && c11_ok=false && c11_reason="emit_hint exit $c11_exit"
# Must be silent — session.multiplexer absent in snapshot but live==default("none").
if [[ -n "$c11_out" ]]; then
  c11_ok=false; c11_reason="${c11_reason:+$c11_reason; }spurious output: $c11_out"
fi
if [[ "$c11_ok" == "true" ]]; then pass 11 "drift-hint silent when only absent-default field added (session.multiplexer)"
else fail 11 "spurious recreate-hint for absent-default field" "$c11_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C12: Generality — snapshot MISSING mounts.symlinks.scope (another defaulted
#      field), live has it at schema default "file" → NO recreate hint.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Old snapshot: no mounts.symlinks.scope field.
write_snapshot '{"version":1,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c12_out=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '$RC'; _config_emit_hint '$WS' '$CNAME'" 2>&1) || true
c12_exit=$?

c12_ok=true c12_reason=""
[[ "$c12_exit" -ne 0 ]] && c12_ok=false && c12_reason="emit_hint exit $c12_exit"
# Must be silent — mounts.symlinks.scope absent in snapshot but live==default("file").
if [[ -n "$c12_out" ]]; then
  c12_ok=false; c12_reason="${c12_reason:+$c12_reason; }spurious output: $c12_out"
fi
if [[ "$c12_ok" == "true" ]]; then pass 12 "drift-hint silent when only absent-default field added (mounts.symlinks.scope)"
else fail 12 "spurious recreate-hint for absent-default field (generality)" "$c12_reason"; fi
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
