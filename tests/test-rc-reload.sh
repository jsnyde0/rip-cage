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
#   C15  rip-cage-aa4t pre-reload transcript-persistence guard: NOT
#        host-bound + no override -> refuse loud (exit 1), names the
#        --allow-transcript-loss override, snapshot NOT mutated
#   C16  rip-cage-aa4t guard: NOT host-bound + --allow-transcript-loss ->
#        guard does not refuse (proceeds past the guard; the subsequent
#        cold-recreate attempt against a stubbed msb is expected to fail
#        for unrelated reasons, so this only asserts the guard's own
#        decision, distinguished from the guard's own refusal wording)
#   C17  rip-cage-aa4t guard: host-bound -> guard does not refuse
#        (same distinguishing strategy as C16)
#   C18  rip-cage-aa4t guard: --dry-run reports what the guard WOULD do
#        without ever refusing, whether host-bound or not
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
# stub response covers all three readers), plus (rip-cage-syzk) an
# `msb image list --format json` arm so cmd_reload's not-running-branch
# image-drift comparator (_msb_image_drift_status, cli/lib/msb_runtime.sh)
# can be exercised.
# Args:
#   $1 stub_dir   — where to write the stub script
#   $2 cname      — expected sandbox name
#   $3 state      — "running", "exited", "unknown" (rip-cage-syzk R6 — a
#      status the msb JSON reports that isn't Running/Stopped, so
#      _msb_sandbox_state reads it back as "unknown"), or "missing" to fail
#      the existence check
#   $4 workspace  — value for rc.source.path label
#   $5 mounts_json (optional) — raw JSON array for .config.mounts (default
#      "[]" — NOT host-bound, matching this stub's pre-rip-cage-aa4t
#      behavior of omitting the mounts field entirely; `.config.mounts //
#      []` reads either the same way).
#   $6 image_drift (optional, rip-cage-syzk) — "match" (default) or
#      "mismatch". Only consulted when state=="exited" (cmd_reload only
#      calls the comparator on that branch, scoping rule 1). "match" is the
#      default so every PRE-EXISTING exited-state case (e.g. C5) keeps
#      hitting drift status 0 -- the exact same byte-identical "not
#      running... Use 'rc up'" message as before this bead, without every
#      caller having to pass an extra arg.
make_msb_stub() {
  local stub_dir="$1" cname="$2" state="$3" workspace="$4"
  local mounts_json="${5:-[]}"
  local image_drift="${6:-match}"
  local status_json
  case "$state" in
    running) status_json="Running" ;;
    exited) status_json="Stopped" ;;
    unknown) status_json="Paused" ;;
    *) status_json="" ;;
  esac
  local stored_digest current_digest
  if [[ "$image_drift" == "mismatch" ]]; then
    stored_digest="sha256:$(printf 'a%.0s' $(seq 1 64))"
    current_digest="sha256:$(printf 'b%.0s' $(seq 1 64))"
  else
    stored_digest="sha256:$(printf 'c%.0s' $(seq 1 64))"
    current_digest="$stored_digest"
  fi
  cat > "${stub_dir}/msb" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "msb 0.0.0-stub"; exit 0 ;;
  logs) exit 0 ;;
esac
case "\${1:-} \${2:-}" in
  "image list")
    echo '[{"reference":"rip-cage:latest","digest":"${current_digest}"}]'
    exit 0
    ;;
esac
case " \$* " in
  *" inspect "*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo '{"status":"${status_json}","config":{"labels":{"rc.source.path":"${workspace}"},"mounts":${mounts_json},"manifest_digest":"${stored_digest}"}}'
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

# rip-cage-aa4t: mounts[] entry shape for a host-bound ~/.claude/projects
# mount (the current, non-legacy state — cli/up.sh:999).
_RC_RELOAD_PROJECTS_HOST_BOUND_MOUNTS='[{"type":"bind","host":"/Users/jonatanpi/.claude/projects","guest":"/home/agent/.claude/projects"}]'

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
version: 2
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
version: 2
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
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
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
version: 2
network:
  allowed_hosts: []
YML
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot has a synthetic field NOT in the live config — diff reports it.
write_snapshot '{"version":2,"egress":{"mode":"denylist"},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

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
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
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
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

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
version: 2
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
version: 2
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
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

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
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

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
version: 2
network:
  allowed_hosts:
    - switch.berlin
YML
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot has eligible field aligned (allowed_hosts matches) but a synthetic
# non-eligible field present that live lacks → drift hint must fire.
write_snapshot '{"version":2,"egress":{"mode":"denylist"},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

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
version: 2
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
version: 2
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
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"]},"dcg":{"packs":[],"custom_rule_paths":[]}}'

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
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

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
# C14: Eligible-drift hint text (rip-cage-y0u0 default-on flip). Snapshot lacks
#      the added host -> emit_hint fires the reload-eligible notice, which must
#      name `rc reload` (applies now, works on a running cage) AND say the
#      NEXT plain 'rc up' converges automatically once the cage is stopped
#      (converge-on-up is default-on now — no '--reload' flag needed; that
#      wording was retired with the flip, rip-cage-tsf2.9 point 5 superseded).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS"
# Snapshot has allowed_hosts=[] but live fixture has [switch.berlin] -> eligible drift.
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c14_out=$(PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '$RC'; _config_emit_hint '$WS' '$CNAME'" 2>&1) || true
c14_exit=$?

c14_ok=true c14_reason=""
[[ "$c14_exit" -ne 0 ]] && c14_ok=false && c14_reason="emit_hint exit $c14_exit"
echo "$c14_out" | grep -q "rc reload" || { c14_ok=false; c14_reason="${c14_reason:+$c14_reason; }hint doesn't name rc reload"; }
echo "$c14_out" | grep -qi "converges automatically" || { c14_ok=false; c14_reason="${c14_reason:+$c14_reason; }hint doesn't say the next plain 'rc up' converges automatically"; }
echo "$c14_out" | grep -q "rc up --reload" && { c14_ok=false; c14_reason="${c14_reason:+$c14_reason; }hint still names retired '--reload' flag"; }
if [[ "$c14_ok" == "true" ]]; then pass 14 "eligible-drift hint offers 'rc reload' now + names the default-on 'rc up' converge (no --reload flag needed)"
else fail 14 "eligible-drift hint text" "$c14_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C15: rip-cage-aa4t pre-reload transcript-persistence guard — NOT host-bound
# + no override -> refuse loud (exit 1), snapshot NOT mutated, message names
# the --allow-transcript-loss override.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS" '[]'
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
c15_pre_snap_sum=$(shasum "${CACHE_DIR}/config-applied.json" | awk '{print $1}')

c15_out=$(run_rc reload "$CNAME" 2>&1)
c15_exit=$?
c15_post_snap_sum=$(shasum "${CACHE_DIR}/config-applied.json" | awk '{print $1}')
c15_ok=true c15_reason=""
[[ "$c15_exit" -ne 1 ]] && c15_ok=false && c15_reason="exit $c15_exit (want 1)"
echo "$c15_out" | grep -qi "not host-bound\|host-bound" || { c15_ok=false; c15_reason="${c15_reason:+$c15_reason; }no host-bound wording"; }
echo "$c15_out" | grep -q -- "--allow-transcript-loss" || { c15_ok=false; c15_reason="${c15_reason:+$c15_reason; }no --allow-transcript-loss override hint"; }
[[ "$c15_pre_snap_sum" != "$c15_post_snap_sum" ]] && c15_ok=false && c15_reason="${c15_reason:+$c15_reason; }snapshot was mutated"
if [[ "$c15_ok" == "true" ]]; then pass 15 "not host-bound + no override -> refuse loud (exit 1), names --allow-transcript-loss"
else fail 15 "transcript guard refusal" "$c15_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C16: rip-cage-aa4t guard — NOT host-bound + --allow-transcript-loss ->
# guard does NOT refuse (the distinguishing assertion: absence of the C15
# refusal wording, plus the one-line override warning). The subsequent
# cold-recreate attempt against a stubbed msb/cmd_up is expected to fail for
# unrelated environment reasons (no real image/manifest pipeline here) —
# this case only asserts the guard's own decision, not a full recreate.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS" '[]'
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c16_out=$(run_rc reload "$CNAME" --allow-transcript-loss 2>&1) || true
c16_ok=true c16_reason=""
echo "$c16_out" | grep -q "refusing to reload" && { c16_ok=false; c16_reason="guard still refused despite --allow-transcript-loss"; }
echo "$c16_out" | grep -qi "proceeding" || { c16_ok=false; c16_reason="${c16_reason:+$c16_reason; }no proceeding/override warning printed"; }
if [[ "$c16_ok" == "true" ]]; then pass 16 "not host-bound + --allow-transcript-loss -> guard does not refuse (proceeds past the guard)"
else fail 16 "transcript guard override" "$c16_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C17: rip-cage-aa4t guard — host-bound -> guard does not refuse (same
# distinguishing strategy as C16: absence of the refusal wording).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS" "$_RC_RELOAD_PROJECTS_HOST_BOUND_MOUNTS"
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c17_out=$(run_rc reload "$CNAME" 2>&1) || true
c17_ok=true c17_reason=""
echo "$c17_out" | grep -q "refusing to reload" && { c17_ok=false; c17_reason="guard refused despite host-bound mount"; }
if [[ "$c17_ok" == "true" ]]; then pass 17 "host-bound -> guard does not refuse"
else fail 17 "transcript guard host-bound" "$c17_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C18: rip-cage-aa4t guard — --dry-run reports what the guard WOULD do
# without ever refusing (exit 0), whether host-bound or not.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS" '[]'
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

c18_out=$(run_rc reload "$CNAME" --dry-run 2>&1)
c18_exit=$?
c18_ok=true c18_reason=""
[[ "$c18_exit" -ne 0 ]] && c18_ok=false && c18_reason="exit $c18_exit (want 0 — dry-run must never refuse)"
echo "$c18_out" | grep -qi "would refuse\|would REFUSE" || { c18_ok=false; c18_reason="${c18_reason:+$c18_reason; }dry-run doesn't report what the guard would do"; }
if [[ "$c18_ok" == "true" ]]; then pass 18 "--dry-run reports the guard's would-be decision without ever refusing"
else fail 18 "transcript guard dry-run report" "$c18_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# rip-cage-syzk: image-drift-as-recreate-trigger host-tier cases (design's
# "## Harness target" R2/R3/R4/R6/R8/R10 — R5/R7/R9/R11/R12 live elsewhere,
# see the bead). Generic pass/fail so the design's own R-labels show up
# verbatim in the run's output.
# ---------------------------------------------------------------------------
passr() { echo "PASS $1: $2"; }
failr() { echo "FAIL $1: $2 -- $3"; FAILURES=$((FAILURES + 1)); }

_RC_SYZK_NODIFF_SNAP='{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

# ---------------------------------------------------------------------------
# R2: stopped cage, digests MATCH -> exit 2, message byte-identical to today.
#
# Adversarial-review finding F10 (fresh-context review of rip-cage-syzk):
# the original assertion only grepped two substrings ("not running", "rc
# up") -- that's satisfiable by many different messages, not just today's
# actual one, so it didn't back the "byte-identical" claim in this case's
# own name. Fixed: compare against the FULL literal string (an independent
# literal, not derived from the production code -- copied here from a live
# capture of the real message, cli/reload.sh's own "*) ... exit 2" arm),
# with $CNAME/state substituted for the values this fixture actually uses.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS" '[]' "match"

r2_out=$(run_rc reload "$CNAME" 2>&1)
r2_exit=$?
r2_expected="Error: container ${CNAME} is not running (state: exited). Use 'rc up' to start it."
r2_ok=true r2_reason=""
[[ "$r2_exit" -ne 2 ]] && r2_ok=false && r2_reason="exit $r2_exit (want 2)"
[[ "$r2_out" != "$r2_expected" ]] && { r2_ok=false; r2_reason="${r2_reason:+$r2_reason; }message not byte-identical -- got: '${r2_out}' want: '${r2_expected}'"; }
if [[ "$r2_ok" == "true" ]]; then passr R2 "stopped + digests MATCH -> exit 2, message byte-identical to today"
else failr R2 "stopped + digests match" "$r2_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# R3: stopped + image drift (MISMATCH) + a NON-eligible config path (egress.mode)
# -> exit 1 refuse-loud. Proves the rev-1 warn-and-proceed relaxation is
# absent: drift never bypasses the refuse-loud gate.
#
# Adversarial-review finding F1 (fresh-context review of rip-cage-syzk):
# the original version of this case used mounts_json='[]' (NOT host-bound),
# so a mutated production build that skips refuse-loud when image_drift==1
# (the rejected rev-1 shape) would fall through past refuse-loud, print the
# diff summary (which contains the literal substring "egress" in "Diff:
# egress.mode: ..."), and THEN get refused anyway by the transcript guard
# (not host-bound) -- exit 1, output contains "egress", both assertions
# satisfied for entirely the WRONG reason. Fixed: use the HOST-BOUND mounts
# fixture so the transcript guard cannot fire at all here (the only possible
# source of an exit 1 is refuse-loud), and assert the actual refuse-loud
# string, not just a substring the diff-summary line also happens to contain.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS" "$_RC_RELOAD_PROJECTS_HOST_BOUND_MOUNTS" "mismatch"
write_snapshot '{"version":2,"egress":{"mode":"denylist"},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'

r3_out=$(run_rc reload "$CNAME" 2>&1)
r3_exit=$?
r3_ok=true r3_reason=""
[[ "$r3_exit" -ne 1 ]] && r3_ok=false && r3_reason="exit $r3_exit (want 1)"
echo "$r3_out" | grep -q "only handles reload-eligible field changes" || { r3_ok=false; r3_reason="${r3_reason:+$r3_reason; }error does not contain the actual refuse-loud string (a transcript-guard or other exit-1 source would not say this)"; }
echo "$r3_out" | grep -q "egress" || { r3_ok=false; r3_reason="${r3_reason:+$r3_reason; }error doesn't name egress"; }
echo "$r3_out" | grep -qi "refusing to reload" && { r3_ok=false; r3_reason="${r3_reason:+$r3_reason; }transcript guard fired instead of/alongside refuse-loud -- fixture is not isolating the refusal source"; }
if [[ "$r3_ok" == "true" ]]; then passr R3 "stopped + image drift + NON-eligible config path -> exit 1 refuse-loud (drift does not bypass this gate; host-bound fixture isolates the refusal source)"
else failr R3 "stopped + drift + non-eligible config" "$r3_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# R4: stopped + image drift (MISMATCH) + missing applied-config snapshot
# -> exit 1. Legacy no-snapshot cages stay out of scope even under drift.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS" '[]' "mismatch"
# Deliberately no write_snapshot call -- config-applied.json does not exist.

r4_out=$(run_rc reload "$CNAME" 2>&1)
r4_exit=$?
r4_ok=true r4_reason=""
[[ "$r4_exit" -ne 1 ]] && r4_ok=false && r4_reason="exit $r4_exit (want 1)"
echo "$r4_out" | grep -qi "no applied-config snapshot\|predates rc reload support" || { r4_ok=false; r4_reason="${r4_reason:+$r4_reason; }no no-snapshot message"; }
if [[ "$r4_ok" == "true" ]]; then passr R4 "stopped + image drift + missing applied-config snapshot -> exit 1"
else failr R4 "stopped + drift + missing snapshot" "$r4_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# R6: stopped cage state reads as "unknown" (msb reports a status that is
# neither Running nor Stopped) -> exit 2, and the comparator/recreate path
# is never reached (verified indirectly: a reached-but-unstubbed `msb
# remove` would abort the script with a DIFFERENT exit code under the
# shim's set -e, not a clean 2).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "unknown" "$WS" '[]' "mismatch"

r6_out=$(run_rc reload "$CNAME" 2>&1)
r6_exit=$?
r6_ok=true r6_reason=""
[[ "$r6_exit" -ne 2 ]] && r6_ok=false && r6_reason="exit $r6_exit (want 2)"
echo "$r6_out" | grep -q "not running" || { r6_ok=false; r6_reason="${r6_reason:+$r6_reason; }no 'not running' message"; }
echo "$r6_out" | grep -qi "unhandled msb args" && { r6_ok=false; r6_reason="${r6_reason:+$r6_reason; }stub received an unexpected msb call (likely _msb_remove) -- recreate path was reached"; }
if [[ "$r6_ok" == "true" ]]; then passr R6 "stopped-state-reads-unknown + image drift -> exit 2, _msb_remove never invoked"
else failr R6 "unknown state + drift" "$r6_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# R8: RUNNING cage + image drift (MISMATCH, deliberately set to prove it's
# ignored) + NO config diff -> exit 0 "nothing to reload", no recreate, no
# _msb_remove. The regression guard for scoping rule 1: image drift is a
# STOPPED-cage-only trigger; the comparator must not even be consulted on
# the running branch.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "running" "$WS" '[]' "mismatch"
write_snapshot "$_RC_SYZK_NODIFF_SNAP"

r8_out=$(run_rc reload "$CNAME" 2>&1)
r8_exit=$?
r8_ok=true r8_reason=""
[[ "$r8_exit" -ne 0 ]] && r8_ok=false && r8_reason="exit $r8_exit (want 0)"
echo "$r8_out" | grep -qi "no changes" || { r8_ok=false; r8_reason="${r8_reason:+$r8_reason; }no 'no changes' message (image drift wrongly triggered a recreate)"; }
echo "$r8_out" | grep -qi "recreating" && { r8_ok=false; r8_reason="${r8_reason:+$r8_reason; }recreate was announced for a RUNNING cage's image drift"; }
if [[ "$r8_ok" == "true" ]]; then passr R8 "RUNNING cage + image drift + no config diff -> exit 0 'nothing to reload', no recreate (scoping rule 1 regression guard)"
else failr R8 "running + drift + no diff" "$r8_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# R10: stopped + image drift (MISMATCH) + ~/.claude/projects NOT host-bound
# -> exit 1 naming --allow-transcript-loss, and _msb_remove never invoked
# (same indirect proof as R6). This is invariant 3's non-skippable proof
# that the pre-reload transcript guard still gates the recreate on the
# image-drift trigger path too.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox "config-project-network-allowed-hosts.yaml"
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS" '[]' "mismatch"
write_snapshot "$_RC_SYZK_NODIFF_SNAP"

r10_out=$(run_rc reload "$CNAME" 2>&1)
r10_exit=$?
r10_ok=true r10_reason=""
[[ "$r10_exit" -ne 1 ]] && r10_ok=false && r10_reason="exit $r10_exit (want 1)"
echo "$r10_out" | grep -qi "not host-bound\|host-bound" || { r10_ok=false; r10_reason="${r10_reason:+$r10_reason; }no host-bound wording"; }
echo "$r10_out" | grep -q -- "--allow-transcript-loss" || { r10_ok=false; r10_reason="${r10_reason:+$r10_reason; }no --allow-transcript-loss override hint"; }
echo "$r10_out" | grep -qi "unhandled msb args" && { r10_ok=false; r10_reason="${r10_reason:+$r10_reason; }stub received an unexpected msb call (likely _msb_remove) -- recreate path was reached"; }
if [[ "$r10_ok" == "true" ]]; then passr R10 "stopped + image drift + NOT host-bound -> exit 1 naming --allow-transcript-loss, _msb_remove never invoked"
else failr R10 "stopped + drift + transcript guard" "$r10_reason"; fi
teardown_sandbox

# ===========================================================================
# rip-cage-syzk Live tier: L1/L2/L3. Gated on _RC_RELOAD_HAS_LIVE_RUNTIME
# (defined above). Digest drift is manufactured WITHOUT touching
# rip-cage:latest itself (msb has no `image tag` subcommand -- the
# docker-tag + docker-save + msb-load route, pre-verified live in the
# bead's comment, is the only way): docker tag rip-cage:latest onto a
# throwaway rc-syzk-probe:v1 tag, msb load it, and re-load the SAME tag
# after a trivial rebuild to flip its digest -- msb replaces the row in
# place (confirmed: exactly one row after each load, never two). Scratch
# cages registered via tests/_scratch-cage-lib.sh scratch_cage_register,
# destroyed by registered name only.
# ---------------------------------------------------------------------------
if [[ "$_RC_RELOAD_HAS_LIVE_RUNTIME" != "true" ]]; then
  TOTAL=$((TOTAL + 1))
  echo "SKIP L1-L3: image-drift-as-recreate-trigger live tier -- needs docker+msb+pre-built rip-cage:latest image"
else
  # shellcheck source=tests/_scratch-cage-lib.sh
  source "${SCRIPT_DIR}/_scratch-cage-lib.sh"

  _SYZK_PROBE_TAG="rc-syzk-probe:v1"
  _syzk_teardown_probe_image() {
    msb image remove "$_SYZK_PROBE_TAG" >/dev/null 2>&1 || true
    docker rmi "$_SYZK_PROBE_TAG" >/dev/null 2>&1 || true
  }
  # Ordering matters: cage teardown MUST run before image teardown (a
  # still-referencing sandbox can make `msb image remove` fail).
  #
  # Adversarial-review finding F9 (fresh-context review of rip-cage-syzk):
  # the original version did `trap _syzk_final_teardown EXIT` AFTER
  # scratch_cage_register installed its own composed EXIT/INT/TERM traps --
  # that REPLACES only the EXIT trap; INT/TERM still point at
  # scratch_cage_register's handler (which never calls
  # _syzk_teardown_probe_image), so a Ctrl-C mid-run destroys the scratch
  # cage(s) but leaks rc-syzk-probe:v1 into both msb and docker. Fixed:
  # compose onto whatever's CURRENTLY installed for EACH of the three
  # signals (the same trap -p technique tests/_scratch-cage-lib.sh itself
  # uses) rather than replacing one and leaving the other two stale --
  # ordering (cage cleanup, i.e. whatever's already composed in, runs
  # BEFORE the probe-image teardown appended here) falls out automatically
  # since composition always appends.
  _syzk_compose_trap() {
    local _sig="$1"
    local _raw _prior
    _raw=$(trap -p "$_sig" 2>/dev/null)
    if [[ -n "$_raw" ]]; then
      # `trap -p` prints: trap -- 'BODY' SIGNAME -- but SIGNAME is reported
      # as "EXIT" bare, and as "SIGINT"/"SIGTERM" (SIG-prefixed) for real
      # signals (verified live: `bash -c "trap x INT; trap -p INT"` prints
      # `trap -- 'x' SIGINT`, not `... INT`). Extracting via the SINGLE-QUOTE
      # positions (not a signal-name-anchored regex) sidesteps that
      # spelling mismatch entirely -- the same class of bug this fix
      # exists to close, so the extraction technique must not reintroduce it.
      _prior="${_raw#trap -- \'}"
      _prior="${_prior%\' *}"
    else
      _prior=""
    fi
    if [[ -n "$_prior" ]]; then
      # shellcheck disable=SC2064
      trap "${_prior}; _syzk_teardown_probe_image" "$_sig"
    else
      trap '_syzk_teardown_probe_image' "$_sig"
    fi
  }

  _SYZK_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-syzk-live-XXXXXX")
  mkdir -p "${_SYZK_HOME}/.config/rip-cage"
  _SYZK_L1_WS="${_SYZK_HOME}/l1-workspace"
  _SYZK_L3_WS="${_SYZK_HOME}/l3-workspace"
  mkdir -p "$_SYZK_L1_WS" "$_SYZK_L3_WS"
  for _syzk_ws in "$_SYZK_L1_WS" "$_SYZK_L3_WS"; do
    git -C "$_syzk_ws" init -q
    touch "${_syzk_ws}/README.md"
    git -C "$_syzk_ws" add README.md
    git -C "$_syzk_ws" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m initial >/dev/null 2>&1
    cat > "${_syzk_ws}/.rip-cage.yaml" <<'YML'
version: 2
network:
  allowed_hosts: []
YML
  done

  syzk_run() {
    XDG_CONFIG_HOME="${_SYZK_HOME}/.config" RC_ALLOWED_ROOTS="${_SYZK_L1_WS}:${_SYZK_L3_WS}" \
      RC_IMAGE="$_SYZK_PROBE_TAG" "$RC" --output json "$@"
  }

  _syzk_ok=true
  _syzk_fail_reason=""
  _syzk_fail() { _syzk_ok=false; _syzk_fail_reason="${_syzk_fail_reason:+$_syzk_fail_reason; }$1"; }

  # --- digest A: tag + load ---
  docker tag rip-cage:latest "$_SYZK_PROBE_TAG" || _syzk_fail "docker tag rip-cage:latest -> probe failed"
  docker save "$_SYZK_PROBE_TAG" | msb image load --tag "$_SYZK_PROBE_TAG" >/dev/null 2>&1 || _syzk_fail "msb image load (digest A) failed"
  _SYZK_DIGEST_A=$(msb image list --format json 2>/dev/null | jq -r --arg t "$_SYZK_PROBE_TAG" '.[] | select(.reference==$t) | .digest')

  # --- L1 setup: rc up on the probe image (digest A) ---
  _SYZK_L1_UP_OUT=$(syzk_run up "$_SYZK_L1_WS" 2>&1)
  _SYZK_L1_UP_RC=$?
  if [[ "$_SYZK_L1_UP_RC" -ne 0 ]]; then
    _syzk_fail "L1 setup: rc up failed (exit $_SYZK_L1_UP_RC): $_SYZK_L1_UP_OUT"
  fi
  _SYZK_L1_CAGE=$(echo "$_SYZK_L1_UP_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
  if [[ -n "$_SYZK_L1_CAGE" ]]; then
    scratch_cage_register "$_SYZK_L1_CAGE"
  fi
  # Compose onto ALL THREE signals scratch_cage_register just installed
  # (EXIT + INT + TERM), not just EXIT (F9).
  _syzk_compose_trap EXIT
  _syzk_compose_trap INT
  _syzk_compose_trap TERM

  # Sentinels into the named-volume mount points (rc-state- -> /home/agent/.claude-state,
  # rc-history- -> /commandhistory, cli/up.sh:1027-1028).
  msb exec "$_SYZK_L1_CAGE" -- sh -c 'echo state-sentinel > /home/agent/.claude-state/syzk-sentinel.txt' >/dev/null 2>&1
  msb exec "$_SYZK_L1_CAGE" -- sh -c 'echo history-sentinel > /commandhistory/syzk-sentinel.txt' >/dev/null 2>&1
  syzk_run down "$_SYZK_L1_CAGE" >/dev/null 2>&1

  # --- L3 setup: a hand-rolled "legacy" cage pinned to digest A, NOT
  # host-bound for ~/.claude/projects (current `rc up` always host-binds it,
  # so a REAL not-host-bound cage can't be produced via `rc up` -- this is
  # the only way to manufacture the L3 precondition live). Named to match
  # what container_name(L3_WS) derives so the repair's cmd_up create branch
  # (which re-derives the name from the WORKSPACE PATH, not the old cage's
  # name) reuses the SAME name -- otherwise the post-repair cage would be
  # silently unregistered for cleanup.
  _syzk_l3_parent=$(basename "$(dirname "$_SYZK_L3_WS")")
  _syzk_l3_base=$(basename "$_SYZK_L3_WS")
  _SYZK_L3_CAGE=$(echo "${_syzk_l3_parent}-${_syzk_l3_base}" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^[.-]*//' | sed 's/-$//')
  msb create "$_SYZK_PROBE_TAG" --name "$_SYZK_L3_CAGE" \
    --label "rc.source.path=${_SYZK_L3_WS}" \
    -v "rc-state-${_SYZK_L3_CAGE}:/home/agent/.claude-state" \
    -v "rc-history-${_SYZK_L3_CAGE}:/commandhistory" \
    --quiet >/dev/null 2>&1 || _syzk_fail "L3 setup: msb create (legacy, not-host-bound) failed"
  scratch_cage_register "$_SYZK_L3_CAGE"
  msb stop "$_SYZK_L3_CAGE" >/dev/null 2>&1
  # Applied-config snapshot matching L3's live config exactly (zero diff),
  # so the only reason `rc reload` has anything to do is image drift.
  _SYZK_L3_LIVE_CFG=$(XDG_CONFIG_HOME="${_SYZK_HOME}/.config" bash -c "source '$RC' 2>/dev/null; _load_effective_config '$_SYZK_L3_WS' | jq -c '.config'")
  mkdir -p "${HOME}/.cache/rip-cage/${_SYZK_L3_CAGE}"
  printf '%s\n' "$_SYZK_L3_LIVE_CFG" > "${HOME}/.cache/rip-cage/${_SYZK_L3_CAGE}/config-applied.json"

  # --- digest B: rebuild a trivial variant, re-load the SAME tag ---
  _SYZK_DVAR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-syzk-dockerfile-XXXXXX")
  printf 'FROM rip-cage:latest\nRUN echo rc-syzk-probe-variant-b\n' > "${_SYZK_DVAR_DIR}/Dockerfile"
  docker build -q -t "$_SYZK_PROBE_TAG" -f "${_SYZK_DVAR_DIR}/Dockerfile" "$_SYZK_DVAR_DIR" >/dev/null 2>&1 || _syzk_fail "docker build (trivial variant) failed"
  docker save "$_SYZK_PROBE_TAG" | msb image load --tag "$_SYZK_PROBE_TAG" >/dev/null 2>&1 || _syzk_fail "msb image load (digest B) failed"
  rm -rf "$_SYZK_DVAR_DIR" 2>/dev/null || true
  _SYZK_DIGEST_B=$(msb image list --format json 2>/dev/null | jq -r --arg t "$_SYZK_PROBE_TAG" '.[] | select(.reference==$t) | .digest')
  _SYZK_ROW_COUNT=$(msb image list --format json 2>/dev/null | jq -c --arg t "$_SYZK_PROBE_TAG" '[.[] | select(.reference==$t)] | length')

  # --- L1: rc reload with drift -> exit 0, single image row, digest B,
  # sentinels + named volumes intact ---
  _SYZK_L1_RELOAD_OUT=$(syzk_run reload "$_SYZK_L1_CAGE" 2>&1)
  _SYZK_L1_RELOAD_RC=$?
  [[ "$_SYZK_L1_RELOAD_RC" -ne 0 ]] && _syzk_fail "L1: rc reload exit $_SYZK_L1_RELOAD_RC (want 0): $_SYZK_L1_RELOAD_OUT"
  [[ "$_SYZK_ROW_COUNT" -eq 1 ]] || _syzk_fail "L1: expected exactly one ${_SYZK_PROBE_TAG} image-list row, got $_SYZK_ROW_COUNT"
  _SYZK_L1_POST_DIGEST=$(msb inspect "$_SYZK_L1_CAGE" --format json 2>/dev/null | jq -r '.config.manifest_digest')
  [[ "$_SYZK_L1_POST_DIGEST" == "$_SYZK_DIGEST_B" ]] || _syzk_fail "L1: post-reload manifest_digest '$_SYZK_L1_POST_DIGEST' != digest B '$_SYZK_DIGEST_B'"
  # rip-cage-syzk (F8): the whole point of the docker-tag/save/load dance
  # is that the tag's digest actually CHANGED -- prove A != B, not just
  # that the post-reload digest happens to equal whatever B turned out
  # to be (a stale/no-op load would trivially satisfy the check above).
  [[ -n "$_SYZK_DIGEST_A" && -n "$_SYZK_DIGEST_B" && "$_SYZK_DIGEST_A" != "$_SYZK_DIGEST_B" ]] \
    || _syzk_fail "L1: digest A ('$_SYZK_DIGEST_A') and digest B ('$_SYZK_DIGEST_B') are not both set and distinct -- the manufactured drift may be a no-op"
  # rip-cage-syzk (adversarial-review finding F4): L1 is a PURE image-drift
  # recreate (L1_WS's .rip-cage.yaml is never edited between up and
  # reload) -- the log line must say so, not claim an "amended net-rule
  # set" that does not exist on this path.
  echo "$_SYZK_L1_RELOAD_OUT" | grep -q "move it onto the current image" \
    || _syzk_fail "L1: recreate log line does not say 'move it onto the current image' (F4)"
  echo "$_SYZK_L1_RELOAD_OUT" | grep -q "amended net-rule set" \
    && _syzk_fail "L1: recreate log line still claims an amended net-rule set on a pure image-drift path (F4)"
  _SYZK_S1=$(msb exec "$_SYZK_L1_CAGE" -- cat /home/agent/.claude-state/syzk-sentinel.txt 2>/dev/null)
  _SYZK_S2=$(msb exec "$_SYZK_L1_CAGE" -- cat /commandhistory/syzk-sentinel.txt 2>/dev/null)
  [[ "$_SYZK_S1" == "state-sentinel" ]] || _syzk_fail "L1: rc-state sentinel lost (got '$_SYZK_S1')"
  [[ "$_SYZK_S2" == "history-sentinel" ]] || _syzk_fail "L1: rc-history sentinel lost (got '$_SYZK_S2')"
  _SYZK_VOL_LIST=$(msb volume list --format json 2>/dev/null)
  echo "$_SYZK_VOL_LIST" | jq -e --arg n "rc-state-${_SYZK_L1_CAGE}" '.[] | select(.name==$n)' >/dev/null 2>&1 \
    || _syzk_fail "L1: rc-state-${_SYZK_L1_CAGE} volume missing after reload"
  echo "$_SYZK_VOL_LIST" | jq -e --arg n "rc-history-${_SYZK_L1_CAGE}" '.[] | select(.name==$n)' >/dev/null 2>&1 \
    || _syzk_fail "L1: rc-history-${_SYZK_L1_CAGE} volume missing after reload"

  TOTAL=$((TOTAL + 1))
  if [[ "$_syzk_ok" == "true" ]]; then
    passr L1 "invariant-1 proof: digest drift manufactured off rip-cage:latest, rc reload exit 0, single image row, digest B, sentinels + named volumes intact"
  else
    failr L1 "invariant-1 proof" "$_syzk_fail_reason"
  fi

  # --- L2: same scratch cage, stopped, NO drift (already on digest B) ->
  # exit 2. Proves the relaxation is drift-conditioned, not a blanket
  # "stopped cages are now reloadable". ---
  _syzk_l2_ok=true _syzk_l2_reason=""
  syzk_run down "$_SYZK_L1_CAGE" >/dev/null 2>&1
  _SYZK_L2_OUT=$(syzk_run reload "$_SYZK_L1_CAGE" 2>&1)
  _SYZK_L2_RC=$?
  [[ "$_SYZK_L2_RC" -ne 2 ]] && { _syzk_l2_ok=false; _syzk_l2_reason="exit $_SYZK_L2_RC (want 2): $_SYZK_L2_OUT"; }
  TOTAL=$((TOTAL + 1))
  if [[ "$_syzk_l2_ok" == "true" ]]; then
    passr L2 "same scratch cage, stopped, NO image drift -> rc reload exit 2"
  else
    failr L2 "no-drift stopped cage" "$_syzk_l2_reason"
  fi

  # --- L3: live half of the transcript guard -- image drift + NOT
  # host-bound + --allow-transcript-loss -> proceeds and recreates. ---
  _syzk_l3_ok=true _syzk_l3_reason=""
  _SYZK_L3_OUT=$(syzk_run reload "$_SYZK_L3_CAGE" --allow-transcript-loss 2>&1)
  _SYZK_L3_RC=$?
  [[ "$_SYZK_L3_RC" -ne 0 ]] && { _syzk_l3_ok=false; _syzk_l3_reason="exit $_SYZK_L3_RC (want 0): $_SYZK_L3_OUT"; }
  _SYZK_L3_POST_DIGEST=$(msb inspect "$_SYZK_L3_CAGE" --format json 2>/dev/null | jq -r '.config.manifest_digest')
  [[ "$_SYZK_L3_POST_DIGEST" != "$_SYZK_DIGEST_B" ]] && { _syzk_l3_ok=false; _syzk_l3_reason="${_syzk_l3_reason:+$_syzk_l3_reason; }post-reload manifest_digest '$_SYZK_L3_POST_DIGEST' != digest B '$_SYZK_DIGEST_B'"; }
  TOTAL=$((TOTAL + 1))
  if [[ "$_syzk_l3_ok" == "true" ]]; then
    passr L3 "live transcript-guard override: image drift + NOT host-bound + --allow-transcript-loss -> proceeds, recreates onto digest B"
  else
    failr L3 "transcript guard override (live)" "$_syzk_l3_reason"
  fi

  rm -rf "${HOME}/.cache/rip-cage/${_SYZK_L3_CAGE}" 2>/dev/null || true
  rm -rf "$_SYZK_HOME" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES of $TOTAL tests"
  exit 1
fi
echo "All $TOTAL tests passed."
