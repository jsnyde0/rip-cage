#!/usr/bin/env bash
# Tests for ADR-019 D3 (post-c1p.1 evolution): cage-pi topology surfaced via
# reference in ~/.claude/CLAUDE.md rather than appended to host AGENTS.md.
# Post-hhh.12: container-local PI_CODING_AGENT_DIR (/home/agent/.pi/agent).
#
# Contract under test:
#   - Host ~/.pi/agent/AGENTS.md is NEVER mutated by init (content + mtime unchanged)
#   - Cage ~/.claude/CLAUDE.md contains the literal string /etc/rip-cage/cage-pi.md
#     inside the <!-- begin:rip-cage-topology --> fence
#   - /etc/rip-cage/cage-pi.md is readable inside the cage
#   - init exits 0 when pi auth mount is absent
#
# Requires docker + the rip-cage image already built (./rc build). The fence
# itself, and therefore /etc/rip-cage/cage-pi.md and /etc/rip-cage/cage-claude.md,
# are provisioned by the examples/claude/ and examples/pi/ recipes'
# install_cmd -- deliberately NOT baked into the base image (ADR-005 D12 /
# rip-cage-wlwc.2.2, cage/Dockerfile:144-146). A floor-only image build (the
# repo default; no tools.yaml composing those recipes) never gets the fence
# written at all (cage/init/init-rip-cage.sh:133 gates the whole append on
# /etc/rip-cage/cage-claude.md existing). Tests 2a/2b/3/4/7c below depend on
# that fence/file and SKIP with a named reason (rip-cage-sw6s) when it is
# absent; Test 1 is host-side and Tests 5/6/7/7b/7d already tolerate the
# absence, so they still run and are expected to PASS either way.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
SKIPPED=0
TEST_WS=""
TEST_WS2=""
CONTAINER=""
CREATED_CAGES=()

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }
skip() { echo "SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }

_track() { CREATED_CAGES+=("$1"); }

# Resolve the container name from the workspace label — robust against
# rc's collision-hash fallback and tr/sed name normalization.
_resolve_container() {
  local ws="${1:-$TEST_WS}"
  "$RC" ls --output json | jq -r --arg ws "$(realpath "$ws" 2>/dev/null || echo "$ws")" \
    '.[] | select(.source_path==$ws) | .name' | head -1
}

# ---- Self-isolate HOME (rip-cage-bh0r) ----
# This test stages a fake AGENTS.md + auth.json under $PI_AGENT_DIR and, in
# Test 7, temporarily moves that dir aside. It must NEVER do either against
# the operator's REAL ~/.pi/agent: on a host where ~/.pi/agent/AGENTS.md is
# a symlink into a sibling checkout (e.g. dotpi), an in-place overwrite
# follows the symlink and clobbers that repo's tracked file (verified on
# disk 2026-09-04, rip-cage-bh0r — 85 lines of dotpi's AGENTS.md were lost
# this way). The old cp -a/mv "backup" this test used to run against the
# real dir was never a sandbox: cp -a copies the SYMLINK, not its target,
# so restoring it puts the symlink back while the already-clobbered target
# stays clobbered. Point HOME at a throwaway dir for the lifetime of this
# script BEFORE deriving PI_AGENT_DIR, so every operation below lands in
# the sandbox regardless of how/where this test is invoked — mirrors the
# identical fix already shipped in test-pi-auth-mount.sh (rip-cage-7atw.3):
# same shape, same remedy.
#
# REAL_HOME / REAL_MSB_HOME: captured BEFORE the HOME override. msb derives
# its per-sandbox agent-relay Unix socket path from $HOME by default, and
# macOS's mktemp default TMPDIR is long enough that a temp-HOME override
# alone overflows the 104-byte AF_UNIX path limit ("agent relay socket path
# is too long"). msb's local image cache is ALSO keyed off $HOME, so a temp
# HOME sees an empty cache and would force a doomed registry pull for
# rip-cage:latest. Pointing MSB_HOME at the real, unmodified microsandbox
# home sidesteps both (mirrors test-pi-auth-mount.sh / test-e2e-lifecycle.sh).
REAL_HOME="$HOME"
REAL_MSB_HOME="${REAL_HOME}/.microsandbox"
REAL_HOME_PI_AGENT="${REAL_HOME}/.pi/agent"

# _pi_agent_identity_snapshot <dir> -- top-level entry names, types
# (symlink/dir/file), and — for symlinks — the raw unresolved link target.
# Identity-only, not full content hashing: unrelated agents/tools may be
# legitimately touching files under a live ~/.pi/agent (sessions/, cache
# manifests) during this run, and hashing those would produce false
# failures unrelated to this test. What actually broke on 2026-09-03 was a
# SYMLINK BEING REPLACED BY A REGULAR FILE (AGENTS.md stopped being a
# symlink into dotpi) — that is exactly the identity-level change this
# snapshot is built to catch, and it needs no knowledge of which sibling
# repo (if any) a symlink happens to resolve into.
_pi_agent_identity_snapshot() {
  local dir="$1"
  if [[ ! -e "$dir" ]]; then
    echo "ABSENT"
    return
  fi
  find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort | while IFS= read -r entry; do
    local name
    name=$(basename "$entry")
    if [[ -L "$entry" ]]; then
      echo "SYMLINK $name -> $(readlink "$entry")"
    elif [[ -d "$entry" ]]; then
      echo "DIR $name"
    else
      echo "FILE $name"
    fi
  done
}

# Captured before the HOME override, against the REAL, un-sandboxed
# ~/.pi/agent — so the final assertion in cleanup_all holds even if the
# sandboxing below has a bug.
BEFORE_REAL_HOME_SNAPSHOT=$(_pi_agent_identity_snapshot "$REAL_HOME_PI_AGENT")

TEST_HOME_SANDBOX=$(mktemp -d)
export HOME="$TEST_HOME_SANDBOX"
# Exported (not just per-call) since every rc/msb invocation below (rc ls,
# rc exec, rc destroy — not only rc up) must resolve against the real msb
# sandboxes registry, not an empty one under the temp HOME.
export MSB_HOME="$REAL_MSB_HOME"

CLEANUP_DONE=false
cleanup_all() {
  local prior_exit=$?
  [[ "$CLEANUP_DONE" == "true" ]] && return
  CLEANUP_DONE=true

  local _d_out _d_rc
  for c in "${CREATED_CAGES[@]:-}"; do
    if [[ -n "$c" ]]; then
      _d_out=$("$RC" destroy "$c" 2>&1)
      _d_rc=$?
      if [[ "$_d_rc" -ne 0 ]]; then
        echo "WARNING: failed to destroy '$c' (exit ${_d_rc}): ${_d_out}" >&2
      fi
    fi
  done
  [[ -n "$TEST_WS" && -d "$TEST_WS" ]] && rm -rf "$TEST_WS"
  [[ -n "$TEST_WS2" && -d "$TEST_WS2" ]] && rm -rf "$TEST_WS2"

  # Everything under $PI_AGENT_DIR (set below) lives inside
  # $TEST_HOME_SANDBOX, never the real $HOME, so a plain rm -rf of the
  # whole sandbox is always sufficient teardown — no restore dance needed
  # (contrast the old cp -a/mv "backup" this test used to run against the
  # REAL ~/.pi/agent, which was never actually a sandbox).
  [[ -n "${TEST_HOME_SANDBOX:-}" && -d "$TEST_HOME_SANDBOX" ]] && rm -rf "$TEST_HOME_SANDBOX"

  # ---- REAL-HOME SAFETY ASSERTION (rip-cage-bh0r acceptance #1) ----
  # Runs on every exit path — pass, fail, the fatal container-didn't-come-up
  # exit, or the SKIP guards below — since this trap is registered before
  # all of them.
  local after_snapshot
  after_snapshot=$(_pi_agent_identity_snapshot "$REAL_HOME_PI_AGENT")
  if [[ "$after_snapshot" == "$BEFORE_REAL_HOME_SNAPSHOT" ]]; then
    echo "PASS: real \$HOME/.pi/agent identity unchanged (entries/types/symlink-targets match before/after)"
  else
    echo "FAIL: real \$HOME/.pi/agent was mutated by this test run"
    echo "  before: $BEFORE_REAL_HOME_SNAPSHOT"
    echo "  after:  $after_snapshot"
    prior_exit=1
  fi

  exit "$prior_exit"
}
trap cleanup_all EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest image not built — run ./rc build first"
  exit 0
fi

# Guard (rip-cage-sw6s): probe the image itself (not a per-test cage) for the
# recipe artifact that gates the whole topology-fence append
# (cage/init/init-rip-cage.sh:133). Inspect stderr rather than discard it —
# a docker-level failure here (as opposed to a clean "file not found") would
# look like the same absence and should not be silently folded into it.
RECIPE_COMPOSED=true
_recipe_probe_err=$(mktemp)
if ! docker run --rm rip-cage:latest test -f /etc/rip-cage/cage-claude.md 2>"$_recipe_probe_err"; then
  RECIPE_COMPOSED=false
  if [[ -s "$_recipe_probe_err" ]]; then
    echo "  Note: recipe-composed probe stderr: $(cat "$_recipe_probe_err")"
  fi
fi
rm -f "$_recipe_probe_err"
if [[ "$RECIPE_COMPOSED" == "false" ]]; then
  echo "  examples/claude + examples/pi recipes not composed into this image (no /etc/rip-cage/cage-claude.md) — Tests 2a/2b/3/4/7c below will SKIP"
fi


# ---- Set up fake ~/.pi/agent state (auth.json + AGENTS.md), all under the
# sandboxed $HOME set above ----
PI_AGENT_DIR="${HOME}/.pi/agent"
mkdir -p "$PI_AGENT_DIR"

# Ensure AGENTS.md exists with known content so we can compare it later
AGENTS_MD_PATH="${PI_AGENT_DIR}/AGENTS.md"
AGENTS_MD_SENTINEL="# Test sentinel — must not be modified by init"
printf '%s\n' "$AGENTS_MD_SENTINEL" > "$AGENTS_MD_PATH"

# Also create a fake auth.json so rc up doesn't skip the mount
printf '{"fake":true}\n' > "${PI_AGENT_DIR}/auth.json"

# Capture host AGENTS.md content and mtime BEFORE rc up
AGENTS_CONTENT_BEFORE=$(cat "$AGENTS_MD_PATH")
AGENTS_MTIME_BEFORE=$(stat -f '%m' "$AGENTS_MD_PATH" 2>/dev/null || stat -c '%Y' "$AGENTS_MD_PATH" 2>/dev/null || true)

TEST_WS=$(mktemp -d)

# ---- Bring up the container ----
echo ""
echo "=== Bringing up container (rc up) ==="
RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true

CONTAINER=$(_resolve_container "$TEST_WS")
if [[ -z "$CONTAINER" ]]; then
  fail "container did not come up (fatal — cannot continue)"
  echo "$FAILURES test(s) FAILED (fatal — cannot continue without container)."
  exit 1
fi
_track "$CONTAINER"

# ---- Test 1: Host ~/.pi/agent/AGENTS.md content + mtime unchanged after rc up ----
echo ""
echo "=== Test 1: Host ~/.pi/agent/AGENTS.md content + mtime unchanged after rc up ==="

AGENTS_CONTENT_AFTER=$(cat "$AGENTS_MD_PATH")
AGENTS_MTIME_AFTER=$(stat -f '%m' "$AGENTS_MD_PATH" 2>/dev/null || stat -c '%Y' "$AGENTS_MD_PATH" 2>/dev/null || true)

if [[ "$AGENTS_CONTENT_AFTER" == "$AGENTS_CONTENT_BEFORE" ]]; then
  pass "Test 1a: ~/.pi/agent/AGENTS.md content unchanged after rc up"
else
  fail "Test 1a: ~/.pi/agent/AGENTS.md content was mutated by init" \
    "before='$AGENTS_CONTENT_BEFORE' after='$AGENTS_CONTENT_AFTER'"
fi

if [[ "$AGENTS_MTIME_AFTER" == "$AGENTS_MTIME_BEFORE" ]]; then
  pass "Test 1b: ~/.pi/agent/AGENTS.md mtime unchanged after rc up"
else
  fail "Test 1b: ~/.pi/agent/AGENTS.md mtime changed (file was written)" \
    "before=$AGENTS_MTIME_BEFORE after=$AGENTS_MTIME_AFTER"
fi

# ---- Test 2: Cage ~/.claude/CLAUDE.md contains /etc/rip-cage/cage-pi.md reference ----
echo ""
echo "=== Test 2: Cage ~/.claude/CLAUDE.md contains /etc/rip-cage/cage-pi.md inside topology fence ==="

RECIPE_ABSENT_REASON="examples/claude + examples/pi recipes not composed into this image (no /etc/rip-cage/cage-claude.md, ADR-005 D12 / rip-cage-wlwc.2.2) — the topology fence was never written into ~/.claude/CLAUDE.md"

# Check the reference string is present anywhere in CLAUDE.md
if [[ "$RECIPE_COMPOSED" == "false" ]]; then
  skip "Test 2a — $RECIPE_ABSENT_REASON"
elif "$RC" exec "$CONTAINER" -- grep -q '/etc/rip-cage/cage-pi.md' /home/agent/.claude/CLAUDE.md; then
  pass "Test 2a: /etc/rip-cage/cage-pi.md reference found in ~/.claude/CLAUDE.md"
else
  fail "Test 2a: /etc/rip-cage/cage-pi.md reference missing from ~/.claude/CLAUDE.md"
fi

# Check the reference is inside the rip-cage-topology fence (not outside it)
if [[ "$RECIPE_COMPOSED" == "false" ]]; then
  skip "Test 2b — $RECIPE_ABSENT_REASON"
else
  inside_fence=$("$RC" exec "$CONTAINER" -- awk '
    /^<!-- begin:rip-cage-topology -->/ { inside=1; next }
    /^<!-- end:rip-cage-topology -->/   { inside=0; next }
    inside && /\/etc\/rip-cage\/cage-pi\.md/ { found=1 }
    END { print (found ? "yes" : "no") }
  ' /home/agent/.claude/CLAUDE.md 2>/dev/null || true)

  if [[ "$inside_fence" == "yes" ]]; then
    pass "Test 2b: /etc/rip-cage/cage-pi.md reference is inside the rip-cage-topology fence"
  else
    fail "Test 2b: /etc/rip-cage/cage-pi.md reference is NOT inside the rip-cage-topology fence"
  fi
fi

# ---- Test 3: /etc/rip-cage/cage-pi.md is readable inside the cage ----
echo ""
echo "=== Test 3: /etc/rip-cage/cage-pi.md is readable inside the cage ==="

if [[ "$RECIPE_COMPOSED" == "false" ]]; then
  skip "Test 3 — examples/pi recipe not composed into this image (no /etc/rip-cage/cage-pi.md, ADR-005 D12 / rip-cage-wlwc.2.2)"
elif "$RC" exec "$CONTAINER" -- test -r /etc/rip-cage/cage-pi.md; then
  pass "Test 3: /etc/rip-cage/cage-pi.md is readable inside the cage"
else
  fail "Test 3: /etc/rip-cage/cage-pi.md not readable inside the cage"
fi

# ---- Test 4: CLAUDE.md marker count is exactly 1 (no duplication) ----
echo ""
echo "=== Test 4: CLAUDE.md has exactly one begin:rip-cage-topology (unsuffixed) marker ==="

if [[ "$RECIPE_COMPOSED" == "false" ]]; then
  skip "Test 4 — $RECIPE_ABSENT_REASON, so no marker was ever written to count"
else
  # Count the unsuffixed marker (must not match -pi suffix markers separately)
  claude_count=$("$RC" exec "$CONTAINER" -- grep -c '^<!-- begin:rip-cage-topology -->' /home/agent/.claude/CLAUDE.md 2>/dev/null || true)
  [[ -z "$claude_count" ]] && claude_count=0
  if [[ "$claude_count" -eq 1 ]]; then
    pass "Test 4: exactly one begin:rip-cage-topology marker in CLAUDE.md"
  else
    fail "Test 4: expected 1 marker, got $claude_count" "$claude_count"
  fi
fi

# ---- Test 5: No pi-topology fence markers in CLAUDE.md (pi path is reference-only) ----
echo ""
echo "=== Test 5: No rip-cage-topology-pi fence markers in CLAUDE.md ==="

pi_in_claude=$("$RC" exec "$CONTAINER" -- grep -c 'begin:rip-cage-topology-pi' /home/agent/.claude/CLAUDE.md 2>/dev/null || true)
[[ -z "$pi_in_claude" ]] && pi_in_claude=0
if [[ "$pi_in_claude" -eq 0 ]]; then
  pass "Test 5: no pi-topology fence markers in CLAUDE.md (reference-only path is clean)"
else
  fail "Test 5: pi-topology fence marker found in CLAUDE.md — should be reference-only" "$pi_in_claude"
fi

# ---- Test 6: init log line emitted when PI_CODING_AGENT_DIR=/home/agent/.pi/agent ----
echo ""
echo "=== Test 6: init log line mentions cage-pi.md when PI_CODING_AGENT_DIR=/home/agent/.pi/agent ==="

init_log_output=$("$RC" exec "$CONTAINER" -- bash -c "PI_CODING_AGENT_DIR=/home/agent/.pi/agent /usr/local/bin/init-rip-cage.sh 2>&1" || true)
if echo "$init_log_output" | grep -q '/etc/rip-cage/cage-pi.md'; then
  pass "Test 6: init log line mentions /etc/rip-cage/cage-pi.md when PI_CODING_AGENT_DIR=/home/agent/.pi/agent"
else
  fail "Test 6: init log line missing cage-pi.md reference" "$init_log_output"
fi

# ---- Test 7: mount-absent guard — init exits 0, no AGENTS.md error ----
echo ""
echo "=== Test 7: mount-absent guard — init exits 0 when pi mount was skipped ==="

# Temporarily rename ~/.pi/agent so rc up skips the mount
PI_AGENT_BACKUP_TMP="${HOME}/.pi/agent.bak-test-pi-cage-$$"
if [[ -d "$PI_AGENT_DIR" ]]; then
  mv "$PI_AGENT_DIR" "$PI_AGENT_BACKUP_TMP"
fi

TEST_WS2=$(mktemp -d)
RC_ALLOWED_ROOTS="$TEST_WS2" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS2" </dev/null >/dev/null 2>&1 || true

# Restore the pi agent dir immediately after rc up
if [[ -d "$PI_AGENT_BACKUP_TMP" ]]; then
  mv "$PI_AGENT_BACKUP_TMP" "$PI_AGENT_DIR"
fi

CONTAINER2=$(_resolve_container "$TEST_WS2")
if [[ -z "$CONTAINER2" ]]; then
  fail "Test 7: container2 did not come up"
else
  _track "$CONTAINER2"
  # Re-run init explicitly and capture exit code
  init_exit=0
  "$RC" exec "$CONTAINER2" -- /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || init_exit=$?
  if [[ $init_exit -eq 0 ]]; then
    pass "Test 7: init exits 0 even when pi mount was not wired"
  else
    fail "Test 7: init exited $init_exit (expected 0)" "$init_exit"
  fi

  # 7b: /home/agent/.pi/agent/AGENTS.md must NOT exist when auth mount was skipped
  # (init must not create host files when the auth.json sub-mount is absent)
  if ! "$RC" exec "$CONTAINER2" -- test -f /home/agent/.pi/agent/AGENTS.md; then
    pass "Test 7b: /home/agent/.pi/agent/AGENTS.md not created when auth mount was skipped"
  else
    fail "Test 7b: /home/agent/.pi/agent/AGENTS.md exists but mount was skipped — init wrote to it"
  fi

  # 7c: /etc/rip-cage/cage-pi.md must still be readable when it's actually
  # image-baked (recipe composed). On a floor-only image it is not baked at
  # all (see the RECIPE_COMPOSED guard above), so this check SKIPs there
  # rather than asserting a file the image never shipped.
  if [[ "$RECIPE_COMPOSED" == "false" ]]; then
    skip "Test 7c — examples/pi recipe not composed into this image (no /etc/rip-cage/cage-pi.md, ADR-005 D12 / rip-cage-wlwc.2.2)"
  elif "$RC" exec "$CONTAINER2" -- test -r /etc/rip-cage/cage-pi.md; then
    pass "Test 7c: /etc/rip-cage/cage-pi.md still readable even without pi mount"
  else
    fail "Test 7c: /etc/rip-cage/cage-pi.md not readable in mount-absent container"
  fi

  # 7d: Negative case — init log line must NOT be emitted when PI_CODING_AGENT_DIR is unset
  # (PI_CODING_AGENT_DIR unset means pi support is not active)
  init_log_output2=$("$RC" exec "$CONTAINER2" -- bash -c "unset PI_CODING_AGENT_DIR; /usr/local/bin/init-rip-cage.sh 2>&1" || true)
  if echo "$init_log_output2" | grep -q '/etc/rip-cage/cage-pi.md'; then
    fail "Test 7d: init log line emitted on no-pi-mount container (guard should suppress it)" "$init_log_output2"
  else
    pass "Test 7d: init log line correctly absent on no-pi-mount container"
  fi

  _d_out=$("$RC" destroy "$CONTAINER2" 2>&1)
  _d_rc=$?
  if [[ "$_d_rc" -ne 0 ]]; then
    echo "WARNING: failed to destroy '$CONTAINER2' (exit ${_d_rc}): ${_d_out}" >&2
  fi
fi

# ---- Summary ----
echo ""
# recount: 1a=1,1b=2,2a=3,2b=4,3=5,4=6,5=7,6=8,7=9,7b=10,7c=11,7d=12 = 12 total
# (2a/2b/3/4/7c report SKIP instead of PASS/FAIL when the recipe artifact
# that provisions the topology fence is absent — rip-cage-sw6s.)
TOTAL=12
if [[ "$FAILURES" -eq 0 ]]; then
  echo "$((TOTAL - SKIPPED)) of $TOTAL pi-cage-context tests passed, $SKIPPED skipped."
else
  echo "$FAILURES of $TOTAL test(s) FAILED ($SKIPPED skipped)."
  exit 1
fi
